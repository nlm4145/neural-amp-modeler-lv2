#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <vector>

namespace NAMRig {

// Streaming rational sample-rate converter: output rate = input rate * up / down.
//
// Polyphase Kaiser-windowed sinc. The prototype low-pass runs at
// input rate * up with its cutoff at the lower of the two Nyquist rates, so
// the same prototype removes images (up > down) and aliases (up < down).
// Output k is emitted as soon as its newest input sample arrives, so the
// sample stream does not depend on the block size. The delay is
// (protoLength - 1) / 2 prototype samples.
//
// configure() and reset() allocate and belong to the host thread. process()
// does not allocate.
class RationalResampler {
 public:
  void configure(int up, int down, int protoLength, double stopbandDb, size_t maxInput) {
    up_ = std::max(1, up);
    down_ = std::max(1, down);
    const int length = std::max(3, protoLength | 1);
    taps_ = (length + up_ - 1) / up_;
    maxInput_ = std::max<size_t>(1, maxInput);

    constexpr double kPi = 3.14159265358979323846;
    const double beta = stopbandDb > 50.0 ? 0.1102 * (stopbandDb - 8.7) : 5.0;
    const double i0Beta = besselI0(beta);
    const double center = 0.5 * static_cast<double>(length - 1);
    const double cutoff = 0.5 / static_cast<double>(std::max(up_, down_));
    std::vector<double> proto(static_cast<size_t>(length));
    double sum = 0.0;
    for (int n = 0; n < length; ++n) {
      const double m = static_cast<double>(n) - center;
      const double r = m / center;
      const double window = besselI0(beta * std::sqrt(std::max(0.0, 1.0 - r * r))) / i0Beta;
      const double x = 2.0 * cutoff * m;
      const double sinc = m == 0.0 ? 1.0 : std::sin(kPi * x) / (kPi * x);
      proto[static_cast<size_t>(n)] = sinc * window;
      sum += proto[static_cast<size_t>(n)];
    }
    const double scale = static_cast<double>(up_) / sum;

    // Row p holds the taps of phase p with the newest input sample last, so a
    // phase output is one forward dot product over the input window.
    bank_.assign(static_cast<size_t>(up_) * static_cast<size_t>(taps_), 0.0f);
    for (int p = 0; p < up_; ++p) {
      for (int k = 0; k < taps_; ++k) {
        const int index = p + (taps_ - 1 - k) * up_;
        if (index < length) {
          bank_[static_cast<size_t>(p) * static_cast<size_t>(taps_) + static_cast<size_t>(k)] =
              static_cast<float>(proto[static_cast<size_t>(index)] * scale);
        }
      }
    }
    work_.assign(static_cast<size_t>(taps_ - 1) + maxInput_, 0.0f);
    reset();
  }

  void reset() {
    std::fill(work_.begin(), work_.end(), 0.0f);
    phase_ = 0;
  }

  bool configured() const { return !bank_.empty(); }
  size_t maxInput() const { return maxInput_; }
  size_t maxOutput(size_t n) const {
    return n * static_cast<size_t>(up_) / static_cast<size_t>(down_) + 2;
  }

  // out must hold maxOutput(n) floats. n must not exceed maxInput().
  // Returns the number of samples written.
  size_t process(const float* in, size_t n, float* out) noexcept {
    if (bank_.empty() || n > maxInput_) return 0;
    const size_t history = static_cast<size_t>(taps_ - 1);
    std::memcpy(work_.data() + history, in, n * sizeof(float));
    size_t written = 0;
    for (size_t i = 0; i < n; ++i) {
      const float* window = work_.data() + i;
      while (phase_ < up_) {
        const float* row = bank_.data() + static_cast<size_t>(phase_) * static_cast<size_t>(taps_);
        float a0 = 0.0f, a1 = 0.0f, a2 = 0.0f, a3 = 0.0f;
        int k = 0;
        for (; k + 4 <= taps_; k += 4) {
          a0 += window[k] * row[k];
          a1 += window[k + 1] * row[k + 1];
          a2 += window[k + 2] * row[k + 2];
          a3 += window[k + 3] * row[k + 3];
        }
        for (; k < taps_; ++k) a0 += window[k] * row[k];
        out[written++] = (a0 + a1) + (a2 + a3);
        phase_ += down_;
      }
      phase_ -= up_;
    }
    std::memmove(work_.data(), work_.data() + n, history * sizeof(float));
    return written;
  }

 private:
  static double besselI0(double x) {
    double sum = 1.0, term = 1.0;
    for (int k = 1; k < 200; ++k) {
      term *= (x / (2.0 * k)) * (x / (2.0 * k));
      sum += term;
      if (term < 1e-18 * sum) break;
    }
    return sum;
  }

  int up_ = 1;
  int down_ = 1;
  int taps_ = 0;
  int phase_ = 0;
  size_t maxInput_ = 0;
  std::vector<float> bank_;
  std::vector<float> work_;
};

// Session rates of the 44.1 kHz family do not divide the 48 kHz rate that NAM
// models are trained at, so a model cannot be rate-adapted to them. The rig
// then runs at the matching 48 kHz-family rate and converts at its edges.
struct HostRateAdapter {
  static constexpr int kUp = 160;
  static constexpr int kDown = 147;
  // Passband to 20 kHz, 100 dB stopband from 24.1 kHz at a 44.1 kHz session.
  static constexpr int kProtoLength = 11201;
  static constexpr double kStopbandDb = 100.0;
  // Input converter plus output converter, in session frames.
  static constexpr int kLatencyFrames = (kProtoLength - 1) / kUp;

  static double internalRate(double hostRate) {
    for (double multiple : {1.0, 2.0, 4.0}) {
      if (std::fabs(hostRate - 44100.0 * multiple) < 1.0) return 48000.0 * multiple;
    }
    return hostRate;
  }

  static size_t internalFrames(size_t hostFrames) {
    return (hostFrames * kUp + kDown - 1) / kDown + 2;
  }
};

}  // namespace NAMRig
