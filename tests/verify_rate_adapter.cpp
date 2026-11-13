// Validates src/rate_adapter.h: the rational converter pair that lets a
// 44.1 kHz-family session run the rig at the matching 48 kHz-family rate.
//   1. rate mapping and reported latency
//   2. round trip is an exact 70-frame delay, identical at every block size
//   3. the round trip never emits fewer frames than it consumed
//   4. passband flat to 20 kHz
//   5. image rejection of the input converter
#include "rate_adapter.h"

#include <cmath>
#include <cstdio>
#include <random>
#include <vector>

using NAMRig::HostRateAdapter;
using NAMRig::RationalResampler;

namespace {

constexpr double kTwoPi = 6.28318530717958647692;
constexpr size_t kMaxBlock = 4096;
int failures = 0;

void check(bool ok, const char* message) {
  std::printf("  %s  %s\n", ok ? "PASS" : "FAIL", message);
  if (!ok) ++failures;
}

// Session -> internal -> session with the given block size (0 = random sizes).
// Sets deficit when a block produced fewer total frames than it consumed.
std::vector<float> roundTrip(const std::vector<float>& in, size_t block, bool& deficit,
                             size_t& maxSurplus) {
  RationalResampler up, down;
  const size_t internalMax = HostRateAdapter::internalFrames(kMaxBlock);
  up.configure(HostRateAdapter::kUp, HostRateAdapter::kDown, HostRateAdapter::kProtoLength,
               HostRateAdapter::kStopbandDb, kMaxBlock);
  down.configure(HostRateAdapter::kDown, HostRateAdapter::kUp, HostRateAdapter::kProtoLength,
                 HostRateAdapter::kStopbandDb, internalMax);
  std::vector<float> mid(internalMax + 8), back(down.maxOutput(internalMax) + 8), out;
  std::mt19937 rng(5);
  size_t consumed = 0;
  for (size_t off = 0; off < in.size();) {
    size_t n = block ? block : 1 + rng() % 700;
    n = std::min(n, in.size() - off);
    const size_t m = up.process(in.data() + off, n, mid.data());
    if (m > internalMax) deficit = true;
    const size_t k = down.process(mid.data(), m, back.data());
    out.insert(out.end(), back.begin(), back.begin() + static_cast<long>(k));
    consumed += n;
    if (out.size() < consumed) deficit = true;
    else maxSurplus = std::max(maxSurplus, out.size() - consumed);
    off += n;
  }
  out.resize(in.size());
  return out;
}

}  // namespace

int main() {
  std::puts("== 1. rate mapping ==");
  check(HostRateAdapter::internalRate(44100.0) == 48000.0 &&
        HostRateAdapter::internalRate(88200.0) == 96000.0 &&
        HostRateAdapter::internalRate(176400.0) == 192000.0,
        "44.1 / 88.2 / 176.4 kHz sessions map to 48 / 96 / 192 kHz");
  check(HostRateAdapter::internalRate(48000.0) == 48000.0 &&
        HostRateAdapter::internalRate(96000.0) == 96000.0 &&
        HostRateAdapter::internalRate(192000.0) == 192000.0 &&
        HostRateAdapter::internalRate(32000.0) == 32000.0,
        "other session rates are not converted");
  check(HostRateAdapter::kLatencyFrames == 70, "converter pair reports 70 session frames");

  std::puts("== 2. exact delay at every block size ==");
  const size_t total = 1 << 15;
  std::vector<float> impulse(total, 0.0f);
  impulse[1000] = 1.0f;
  bool deficit = false;
  size_t maxSurplus = 0;
  const std::vector<float> reference = roundTrip(impulse, 64, deficit, maxSurplus);
  size_t peak = 0;
  for (size_t i = 0; i < total; ++i)
    if (std::fabs(reference[i]) > std::fabs(reference[peak])) peak = i;
  check(peak == 1000 + static_cast<size_t>(HostRateAdapter::kLatencyFrames) && reference[peak] > 0.95f,
        "impulse arrives exactly kLatencyFrames later");
  bool symmetric = true;
  for (size_t i = 1; i < 400; ++i)
    symmetric &= std::fabs(reference[peak + i] - reference[peak - i]) < 1e-5f;
  check(symmetric, "round trip response is linear phase");
  bool identical = true;
  for (size_t block : {size_t{1}, size_t{7}, size_t{480}, size_t{4096}, size_t{0}}) {
    const std::vector<float> other = roundTrip(impulse, block, deficit, maxSurplus);
    for (size_t i = 0; i < total; ++i) identical &= other[i] == reference[i];
  }
  check(identical, "output stream is bit-identical at block sizes 1, 7, 64, 480, 4096 and random");

  std::puts("== 3. frame accounting ==");
  check(!deficit, "every block returns at least as many session frames as it consumed");
  check(maxSurplus <= 2, "surplus stays within the 8-frame output queue");

  std::puts("== 4. passband ==");
  const double rate = 44100.0;
  double worstGain = 0.0, worstError = -200.0;
  for (double f : {40.0, 100.0, 1000.0, 5000.0, 10000.0, 15000.0, 18000.0, 19000.0, 20000.0}) {
    std::vector<float> x(total);
    for (size_t i = 0; i < total; ++i) x[i] = static_cast<float>(std::sin(kTwoPi * f * static_cast<double>(i) / rate));
    const std::vector<float> y = roundTrip(x, 256, deficit, maxSurplus);
    double eOut = 0.0, eRef = 0.0, eErr = 0.0;
    for (size_t i = 4096; i < total - 4096; ++i) {
      const double ref = x[i - static_cast<size_t>(HostRateAdapter::kLatencyFrames)];
      eOut += static_cast<double>(y[i]) * y[i];
      eRef += ref * ref;
      eErr += (y[i] - ref) * (y[i] - ref);
    }
    worstGain = std::max(worstGain, std::fabs(10.0 * std::log10(eOut / eRef)));
    worstError = std::max(worstError, 10.0 * std::log10(eErr / eRef));
  }
  std::printf("  worst gain error %.4f dB, worst waveform error %.1f dB\n", worstGain, worstError);
  check(worstGain < 0.01, "gain within 0.01 dB from 40 Hz to 20 kHz");
  check(worstError < -90.0, "round trip equals the delayed input to -90 dB up to 20 kHz");

  std::puts("== 5. image rejection ==");
  RationalResampler up;
  up.configure(HostRateAdapter::kUp, HostRateAdapter::kDown, HostRateAdapter::kProtoLength,
               HostRateAdapter::kStopbandDb, total);
  double worstImage = -200.0;
  for (double f : {10000.0, 15000.0, 19000.0, 20000.0}) {
    std::vector<float> x(total), y(HostRateAdapter::internalFrames(total) + 8);
    for (size_t i = 0; i < total; ++i) x[i] = static_cast<float>(std::sin(kTwoPi * f * static_cast<double>(i) / rate));
    const size_t m = up.process(x.data(), total, y.data());
    const size_t start = 4096, len = 16384;
    auto magnitude = [&](double hz) {
      double re = 0.0, im = 0.0;
      for (size_t i = 0; i < len && start + i < m; ++i) {
        const double w = 0.5 - 0.5 * std::cos(kTwoPi * static_cast<double>(i) / len);
        const double angle = kTwoPi * hz * static_cast<double>(i) / 48000.0;
        re += w * y[start + i] * std::cos(angle);
        im += w * y[start + i] * std::sin(angle);
      }
      return std::sqrt(re * re + im * im);
    };
    worstImage = std::max(worstImage, 20.0 * std::log10(magnitude(rate - f) / magnitude(f)));
  }
  std::printf("  worst image %.1f dB\n", worstImage);
  check(worstImage < -95.0, "images of tones up to 20 kHz are below -95 dB");

  std::printf("%s\n", failures ? "FAILED" : "verify_rate_adapter: all checks passed");
  return failures ? 1 : 0;
}
