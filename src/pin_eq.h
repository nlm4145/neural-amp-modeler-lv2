#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <string>

#include "power_tube_controls.h"

namespace NAMRig {

// Freeform "pin" EQ placed directly on the Sculpt, Transformer and Cab Console
// graphs. Each pane owns kPinEqBandCount bands; every band is four appended
// control ports (shape, frequency, gain, Q), so pins automate and recall with
// presets like any other control. Shape 0 means "no pin"; a band without a pin
// or at 0 dB is skipped entirely, so the default state is exact bypass.
//
//   Sculpt      - pre-amp, after Bright/Input EQ/Mid Push, in the amp's True domain
//   Transformer - after the output transformer, before the speaker, in the domain
//   Cab Console - after the cab cuts on the stereo cabinet mix, at session rate
enum class PinEqPane : size_t { Sculpt = 0, Transformer = 1, CabConsole = 2 };
inline constexpr size_t kPinEqPaneCount = 3;
inline constexpr size_t kPinEqBandCount = 6;
inline constexpr size_t kPinEqBandParams = 4;
inline constexpr size_t kPinEqPanePorts = kPinEqBandCount * kPinEqBandParams;
static_assert(kPinEqPortCount == kPinEqPaneCount * kPinEqPanePorts);

enum PinEqParam : size_t { kPinShape = 0, kPinFreq = 1, kPinGain = 2, kPinQ = 3 };
enum PinEqShape : int { kPinOff = 0, kPinBell = 1, kPinLowShelf = 2, kPinHighShelf = 3 };
inline constexpr int kPinShapeCount = 4;

inline constexpr float kPinFreqMin = 20.0f;
inline constexpr float kPinFreqMax = 20000.0f;
inline constexpr float kPinGainMax = 18.0f;
inline constexpr float kPinQMin = 0.1f;
inline constexpr float kPinQMax = 10.0f;
inline constexpr float kPinQDefault = 1.0f;
inline constexpr std::array<float, kPinEqBandCount> kPinFreqDefaults = {
    100.0f, 250.0f, 600.0f, 1500.0f, 3500.0f, 8000.0f};
inline constexpr std::array<const char*, kPinEqPaneCount> kPinEqPaneSymbols = {
    "sculpt", "transformer", "cab_console"};
inline constexpr std::array<const char*, kPinEqBandParams> kPinEqParamSymbols = {
    "shape", "freq", "gain", "q"};

constexpr uint32_t pinEqPort(PinEqPane pane, size_t band, size_t param) noexcept {
  return kPinEqFirstPort + static_cast<uint32_t>(
      (static_cast<size_t>(pane) * kPinEqBandCount + band) * kPinEqBandParams + param);
}
constexpr bool isPinEqPort(uint32_t port) noexcept {
  return port >= kPinEqFirstPort && port < kPinEqFirstPort + kPinEqPortCount;
}
constexpr size_t pinEqParamOf(uint32_t port) noexcept {
  return (port - kPinEqFirstPort) % kPinEqBandParams;
}
constexpr size_t pinEqBandOf(uint32_t port) noexcept {
  return ((port - kPinEqFirstPort) / kPinEqBandParams) % kPinEqBandCount;
}
constexpr size_t pinEqPaneOf(uint32_t port) noexcept {
  return (port - kPinEqFirstPort) / kPinEqPanePorts;
}

constexpr float pinEqDefault(uint32_t port) noexcept {
  switch (pinEqParamOf(port)) {
    case kPinFreq: return kPinFreqDefaults[pinEqBandOf(port)];
    case kPinQ: return kPinQDefault;
    default: return 0.0f;
  }
}

constexpr std::array<float, kPinEqPortCount> pinEqDefaults() noexcept {
  std::array<float, kPinEqPortCount> out{};
  for (uint32_t i = 0; i < kPinEqPortCount; ++i) out[i] = pinEqDefault(kPinEqFirstPort + i);
  return out;
}

inline float clampPinEqValue(uint32_t port, float value) noexcept {
  if (!std::isfinite(value)) return pinEqDefault(port);
  switch (pinEqParamOf(port)) {
    case kPinShape:
      return static_cast<float>(std::clamp(static_cast<int>(value + 0.5f), 0, kPinShapeCount - 1));
    case kPinFreq: return std::clamp(value, kPinFreqMin, kPinFreqMax);
    case kPinGain: return std::clamp(value, -kPinGainMax, kPinGainMax);
    default: return std::clamp(value, kPinQMin, kPinQMax);
  }
}

// LV2 symbol, e.g. "sculpt_pin3_freq".
inline std::string pinEqSymbol(uint32_t port) {
  return std::string(kPinEqPaneSymbols[pinEqPaneOf(port)]) + "_pin" +
         std::to_string(pinEqBandOf(port) + 1) + "_" + kPinEqParamSymbols[pinEqParamOf(port)];
}

struct PinBand {
  int shape = kPinOff;
  double freq = 1000.0, gainDb = 0.0, q = kPinQDefault;
};
using PinBands = std::array<PinBand, kPinEqBandCount>;

// Reads one pane's bands from its 24 consecutive values (ports or UI state).
template <typename Get>
inline PinBands readPinBands(PinEqPane pane, Get&& get) {
  PinBands bands;
  for (size_t b = 0; b < kPinEqBandCount; ++b) {
    const auto value = [&](size_t param) {
      const uint32_t port = pinEqPort(pane, b, param);
      return clampPinEqValue(port, get(port));
    };
    bands[b].shape = static_cast<int>(value(kPinShape));
    bands[b].freq = value(kPinFreq);
    bands[b].gainDb = value(kPinGain);
    bands[b].q = value(kPinQ);
  }
  return bands;
}

struct PinCoeffs {
  double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;
};

// RBJ cookbook bell / shelves. Q sets the shelf slope too (0.707 = no overshoot).
inline PinCoeffs pinCoefficients(int shape, double freq, double gainDb, double q,
                                 double rate) noexcept {
  constexpr double kPi = 3.14159265358979323846;
  PinCoeffs f;
  if (shape == kPinOff || rate <= 0.0) return f;
  freq = std::clamp(freq, 1.0, rate * 0.45);
  const double A = std::pow(10.0, gainDb / 40.0);
  const double w0 = 2.0 * kPi * freq / rate;
  const double c = std::cos(w0), s = std::sin(w0);
  const double alpha = s / (2.0 * std::max(0.01, q));
  double b0, b1, b2, a0, a1, a2;
  if (shape == kPinBell) {
    b0 = 1.0 + alpha * A;
    b1 = -2.0 * c;
    b2 = 1.0 - alpha * A;
    a0 = 1.0 + alpha / A;
    a1 = -2.0 * c;
    a2 = 1.0 - alpha / A;
  } else {
    const double sqA = 2.0 * std::sqrt(A) * alpha;
    if (shape == kPinHighShelf) {
      b0 = A * ((A + 1) + (A - 1) * c + sqA);
      b1 = -2.0 * A * ((A - 1) + (A + 1) * c);
      b2 = A * ((A + 1) + (A - 1) * c - sqA);
      a0 = (A + 1) - (A - 1) * c + sqA;
      a1 = 2.0 * ((A - 1) - (A + 1) * c);
      a2 = (A + 1) - (A - 1) * c - sqA;
    } else {
      b0 = A * ((A + 1) - (A - 1) * c + sqA);
      b1 = 2.0 * A * ((A - 1) - (A + 1) * c);
      b2 = A * ((A + 1) - (A - 1) * c - sqA);
      a0 = (A + 1) + (A - 1) * c + sqA;
      a1 = -2.0 * ((A - 1) + (A + 1) * c);
      a2 = (A + 1) + (A - 1) * c - sqA;
    }
  }
  f.b0 = b0 / a0;
  f.b1 = b1 / a0;
  f.b2 = b2 / a0;
  f.a1 = a1 / a0;
  f.a2 = a2 / a0;
  return f;
}

// 2nd-order Butterworth high/low pass, for drawing the fixed cut filters.
inline PinCoeffs pinPassCoefficients(bool highPass, double freq, double rate) noexcept {
  constexpr double kPi = 3.14159265358979323846;
  freq = std::clamp(freq, 1.0, rate * 0.45);
  const double w0 = 2.0 * kPi * freq / rate;
  const double c = std::cos(w0), alpha = std::sin(w0) / (2.0 * 0.7071067811865476);
  const double a0 = 1.0 + alpha;
  PinCoeffs f;
  f.b0 = (highPass ? (1.0 + c) : (1.0 - c)) * 0.5 / a0;
  f.b1 = (highPass ? -(1.0 + c) : (1.0 - c)) / a0;
  f.b2 = f.b0;
  f.a1 = -2.0 * c / a0;
  f.a2 = (1.0 - alpha) / a0;
  return f;
}

inline double pinMagnitudeDb(const PinCoeffs& f, double hz, double rate) noexcept {
  constexpr double kPi = 3.14159265358979323846;
  const double w = 2.0 * kPi * hz / rate;
  const double c = std::cos(w), s = std::sin(w);
  const double c2 = std::cos(2.0 * w), s2 = std::sin(2.0 * w);
  const double num = std::hypot(f.b0 + f.b1 * c + f.b2 * c2, -(f.b1 * s + f.b2 * s2));
  const double den = std::hypot(1.0 + f.a1 * c + f.a2 * c2, -(f.a1 * s + f.a2 * s2));
  return 20.0 * std::log10(std::max(1.0e-12, num / den));
}

// Sum of every placed pin's response (dB) at `hz`.
inline double pinBandsMagnitudeDb(const PinBands& bands, double hz, double rate) noexcept {
  double db = 0.0;
  for (const auto& b : bands)
    if (b.shape != kPinOff && b.gainDb != 0.0)
      db += pinMagnitudeDb(pinCoefficients(b.shape, b.freq, b.gainDb, b.q, rate), hz, rate);
  return db;
}

// Up to two channels of click-free pin EQ. Gain, frequency and Q glide over
// ~20 ms on a 32-sample cadence; a shape change glides the band to 0 dB,
// switches at unity and glides back, so adding, removing or reshaping a pin
// never steps the filter.
class PinEq {
 public:
  static constexpr size_t kMaxChannels = 2;

  void reset() noexcept {
    for (auto& st : bands_) st = BandState{};
    primed_ = false;
    rate_ = 0.0;
  }

  void process(float* const* channels, size_t channelCount, size_t count, double rate,
               const PinBands& targets) noexcept {
    channelCount = std::min(channelCount, kMaxChannels);
    if (rate != rate_) {
      // A new processing domain: histories at the old rate mean nothing.
      for (auto& st : bands_) { st.clearHistory(); st.dirty = true; }
      rate_ = rate;
    }
    if (!primed_) {
      for (size_t b = 0; b < kPinEqBandCount; ++b) {
        auto& st = bands_[b];
        st.shape = targets[b].shape;
        st.gainDb = st.shape == kPinOff ? 0.0 : targets[b].gainDb;
        st.logFreq = std::log(clampFreq(targets[b].freq));
        st.logQ = std::log(targets[b].q);
        st.dirty = true;
      }
      primed_ = true;
    }
    for (size_t start = 0; start < count; start += kChunk) {
      const size_t n = std::min(kChunk, count - start);
      const double glide = 1.0 - std::exp(-static_cast<double>(n) / (rate * 0.020));
      for (size_t b = 0; b < kPinEqBandCount; ++b) {
        auto& st = bands_[b];
        const auto& t = targets[b];
        const double gainTarget = (t.shape == st.shape && t.shape != kPinOff) ? t.gainDb : 0.0;
        const bool wasActive = st.active();
        st.dirty |= glideTo(st.gainDb, gainTarget, glide, 1.0e-3);
        if (st.gainDb == 0.0 && t.shape != st.shape) {
          st.shape = t.shape;
          st.dirty = true;
        }
        const double freqTarget = std::log(clampFreq(t.freq));
        const double qTarget = std::log(t.q);
        if (st.active()) {
          st.dirty |= glideTo(st.logFreq, freqTarget, glide, 1.0e-5);
          st.dirty |= glideTo(st.logQ, qTarget, glide, 1.0e-5);
        } else {
          st.dirty |= st.logFreq != freqTarget || st.logQ != qTarget;
          st.logFreq = freqTarget;
          st.logQ = qTarget;
        }
        if (!st.active()) continue;
        if (!wasActive) st.clearHistory();
        if (st.dirty) {
          st.c = pinCoefficients(st.shape, std::exp(st.logFreq), st.gainDb,
                                 std::exp(st.logQ), rate);
          st.dirty = false;
        }
        for (size_t ch = 0; ch < channelCount; ++ch) {
          float* s = channels[ch] + start;
          double z1 = st.z[ch][0], z2 = st.z[ch][1];
          const PinCoeffs& c = st.c;
          for (size_t i = 0; i < n; ++i) {
            const double x = s[i];
            const double y = c.b0 * x + z1;
            z1 = c.b1 * x - c.a1 * y + z2;
            z2 = c.b2 * x - c.a2 * y;
            s[i] = static_cast<float>(y);
          }
          st.z[ch][0] = z1;
          st.z[ch][1] = z2;
        }
      }
    }
  }

 private:
  static constexpr size_t kChunk = 32;

  struct BandState {
    int shape = kPinOff;
    double gainDb = 0.0, logFreq = 0.0, logQ = 0.0;
    PinCoeffs c;
    double z[kMaxChannels][2] = {};
    bool dirty = true;
    bool active() const noexcept { return shape != kPinOff && gainDb != 0.0; }
    void clearHistory() noexcept {
      for (auto& ch : z) ch[0] = ch[1] = 0.0;
    }
  };

  double clampFreq(double hz) const noexcept {
    return std::clamp(hz, static_cast<double>(kPinFreqMin),
                      std::min(static_cast<double>(kPinFreqMax), rate_ * 0.45));
  }
  static bool glideTo(double& value, double target, double coeff, double snap) noexcept {
    if (value == target) return false;
    value += (target - value) * coeff;
    if (std::fabs(target - value) < snap) value = target;
    return true;
  }

  std::array<BandState, kPinEqBandCount> bands_{};
  bool primed_ = false;
  double rate_ = 0.0;
};

}  // namespace NAMRig
