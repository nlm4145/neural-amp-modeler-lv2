#include "dynamics.h"

#include <cmath>
#include <cstdio>
#include <vector>
#include <limits>

namespace {

constexpr double kTwoPi = 6.28318530717958647692;

struct Ballistics {
  double attackMs = -1.0;
  double releaseMs = -1.0;
};

// Sends a 1 kHz burst from -40 dBFS to loudAmplitude and back at Amount 100,
// and returns the times at which the gain in dB covers 63% of its change.
Ballistics measureBallistics(double rate, float attackMs, float releaseMs, double loudAmplitude) {
  const size_t n = static_cast<size_t>(rate * 4.0);
  const size_t on = static_cast<size_t>(rate * 1.0), off = static_cast<size_t>(rate * 2.0);
  std::vector<float> left(n), right(n), dry(n);
  for (size_t i = 0; i < n; ++i) {
    const double amplitude = (i >= on && i < off) ? loudAmplitude : 0.01;
    dry[i] = left[i] = right[i] =
        static_cast<float>(amplitude * std::sin(kTwoPi * 1000.0 * static_cast<double>(i) / rate));
  }
  NAMRig::StereoCompressor comp;
  comp.initialize(rate);
  comp.process(left.data(), right.data(), static_cast<uint32_t>(n), 100, attackMs, releaseMs, true);
  const size_t window = static_cast<size_t>(rate * 0.001);
  const auto gainDb = [&](size_t start) {
    double wet = 0.0, ref = 0.0;
    for (size_t k = start; k < start + window; ++k) {
      wet += static_cast<double>(left[k]) * left[k];
      ref += static_cast<double>(dry[k]) * dry[k];
    }
    return 10.0 * std::log10(wet / ref);
  };
  const double quiet = gainDb(on - window * 100), loud = gainDb(off - window * 100);
  Ballistics result;
  const size_t step = std::max<size_t>(1, window / 4);
  for (size_t i = on; i < off; i += step) {
    if (gainDb(i) <= quiet + 0.632 * (loud - quiet)) {
      result.attackMs = 1000.0 * static_cast<double>(i - on) / rate;
      break;
    }
  }
  for (size_t i = off; i + window < n; i += step) {
    if (gainDb(i) >= loud + 0.632 * (quiet - loud)) {
      result.releaseMs = 1000.0 * static_cast<double>(i - off) / rate;
      break;
    }
  }
  return result;
}

// Settled output peak in dBFS of a steady tone (hz 0 = constant input).
double settledPeakDb(double rate, double hz, double inputPeakDb, float amount) {
  const size_t n = static_cast<size_t>(rate * 2.0);
  const double amplitude = std::pow(10.0, inputPeakDb / 20.0);
  std::vector<float> left(n), right(n);
  for (size_t i = 0; i < n; ++i)
    left[i] = right[i] = static_cast<float>(
        hz > 0.0 ? amplitude * std::sin(kTwoPi * hz * static_cast<double>(i) / rate) : amplitude);
  NAMRig::StereoCompressor comp;
  comp.initialize(rate);
  comp.process(left.data(), right.data(), static_cast<uint32_t>(n), amount, 8, 120, true);
  float peak = 0.0f;
  for (size_t i = n / 2; i < n; ++i) peak = std::max(peak, std::fabs(left[i]));
  return 20.0 * std::log10(static_cast<double>(peak));
}

// Spread in dB of the gain across the cycles of a steady low note.
double lowNoteGainRippleDb(double rate, double hz, float attackMs, float releaseMs) {
  const size_t n = static_cast<size_t>(rate * 2.0);
  std::vector<float> left(n), right(n), dry(n);
  for (size_t i = 0; i < n; ++i)
    dry[i] = left[i] = right[i] =
        static_cast<float>(0.5 * std::sin(kTwoPi * hz * static_cast<double>(i) / rate));
  NAMRig::StereoCompressor comp;
  comp.initialize(rate);
  comp.process(left.data(), right.data(), static_cast<uint32_t>(n), 100, attackMs, releaseMs, true);
  double lo = 1.0e9, hi = -1.0e9;
  for (size_t i = n / 2; i < n; ++i) {
    if (std::fabs(dry[i]) < 0.05f) continue;
    const double gain = 20.0 * std::log10(static_cast<double>(left[i]) / dry[i]);
    lo = std::min(lo, gain);
    hi = std::max(hi, gain);
  }
  return hi - lo;
}

}  // namespace

int main() {
  int failures = 0;
  const float threshold = -24.0f;
  const float ratio = 4.0f;
  if (NAMRig::compressorReductionDb(-40.0f, threshold, ratio) != 0.0f)
    ++failures;
  const float expected = (1.0f - 1.0f / ratio) * 12.0f;
  const float above = NAMRig::compressorReductionDb(-12.0f, threshold, ratio);
  if (std::fabs(above - expected) > 1.0e-5f) ++failures;
  float previous = 0.0f;
  for (int db = -60; db <= 0; ++db) {
    const float reduction = NAMRig::compressorReductionDb((float)db,
                                                           threshold, ratio);
    if (reduction + 1.0e-6f < previous || !std::isfinite(reduction)) ++failures;
    previous = reduction;
  }
  if (NAMRig::compressorReductionDb(0.0f, threshold, 1.0f) != 0.0f)
    ++failures;
  for (double rate : {44100.0, 48000.0, 96000.0}) {
    const size_t n = static_cast<size_t>(rate * 2);
    std::vector<float> left(n, 0.5f), right(n, -0.125f);
    NAMRig::StereoCompressor comp;
    comp.initialize(rate);
    comp.process(left.data(), right.data(), n, 0, 8, 120, true);
    for (size_t i = 0; i < n; ++i)
      if (left[i] != 0.5f || right[i] != -0.125f) ++failures;
    comp.process(left.data(), right.data(), n, 100, 8, 120, false);
    if (left.back() != 0.5f || right.back() != -0.125f) ++failures;

    comp.reset();
    std::fill(left.begin(), left.end(), 0.5f);
    std::fill(right.begin(), right.end(), -0.125f);
    comp.process(left.data(), right.data(), n, 100, 8, 120, true);
    // A constant input reaches the detector 6 dB down: the sidechain
    // high-pass removes it, and the detector floor is half of the input.
    const float levelDb = 20.0f * std::log10(0.5f * 0.5f);
    const float expectedGain = std::pow(10.0f, (NAMRig::compressorMakeupDb(-36, 6) -
        NAMRig::compressorReductionDb(levelDb, -36, 6)) * 0.05f);
    if (std::fabs(left.back() - 0.5f * expectedGain) > 2.0e-4f) {
      std::fprintf(stderr, "steady gain at %.0f Hz: got %.8f expected %.8f\n", rate, left.back(), 0.5f * expectedGain);
      ++failures;
    }
    for (size_t i = 0; i < n; ++i)
      if (right[i] != -0.25f * left[i] || !std::isfinite(left[i])) ++failures;

    // Swapping channels must give the same linked result.
    NAMRig::StereoCompressor swapped;
    swapped.initialize(rate);
    std::vector<float> a(n, -0.125f), b(n, 0.5f);
    swapped.process(a.data(), b.data(), n, 100, 8, 120, true);
    if (a != right || b != left) { std::fprintf(stderr, "channel swap at %.0f Hz\n", rate); ++failures; }

    // Block boundaries cannot alter detector, control smoothing or gain.
    NAMRig::StereoCompressor sliced;
    sliced.initialize(rate);
    std::fill(a.begin(), a.end(), 0.5f);
    std::fill(b.begin(), b.end(), -0.125f);
    for (size_t off = 0; off < n; off += 137)
      sliced.process(a.data() + off, b.data() + off, std::min<size_t>(137, n - off), 100, 8, 120, true);
    if (a != left || b != right) { std::fprintf(stderr, "block slicing at %.0f Hz\n", rate); ++failures; }

    // Bypass glides rather than jumping and eventually restores bit-exact dry.
    std::fill(a.begin(), a.end(), 0.5f);
    std::fill(b.begin(), b.end(), -0.125f);
    sliced.process(a.data(), b.data(), n, 100, 8, 120, false);
    if (std::fabs(a.front() - left.back()) > 0.002f || a.back() != 0.5f || b.back() != -0.125f) {
      std::fprintf(stderr, "bypass at %.0f Hz: first %.8f previous %.8f last %.8f\n", rate, a.front(), left.back(), a.back());
      ++failures;
    }
    sliced.process(a.data(), b.data(), n, std::numeric_limits<float>::quiet_NaN(),
                   std::numeric_limits<float>::infinity(), -100, true);
    if (!std::isfinite(a.back())) ++failures;
    comp.process(a.data(), b.data(), n, 0, 8, 120, true);
    if (a.back() != 0.5f || b.back() != -0.125f) ++failures;
  }
  // Attack and Release independently change transient/recovery behavior.
  NAMRig::StereoCompressor fast, slow;
  fast.initialize(48000);
  slow.initialize(48000);
  std::vector<float> fastL(48000, 0.5f), fastR = fastL;
  std::vector<float> slowL = fastL, slowR = fastL;
  fast.process(fastL.data(), fastR.data(), 48000, 80, 1, 10, true);
  slow.process(slowL.data(), slowR.data(), 48000, 80, 100, 1000, true);
  if (slowL[2400] <= fastL[2400]) ++failures;
  std::fill(fastL.begin(), fastL.end(), 0.01f);
  std::fill(fastR.begin(), fastR.end(), 0.01f);
  std::fill(slowL.begin(), slowL.end(), 0.01f);
  std::fill(slowR.begin(), slowR.end(), 0.01f);
  fast.process(fastL.data(), fastR.data(), 48000, 80, 8, 10, true);
  slow.process(slowL.data(), slowR.data(), 48000, 80, 8, 1000, true);
  if (slowL[12000] >= fastL[12000]) ++failures;
  if (failures) {
    std::fprintf(stderr, "FAIL compressor curve (%d failures)\n", failures);
    return 1;
  }
  std::puts("  PASS  compressor curve, stereo linking, rate/block invariance and smoothed exact bypass");

  // Attack and Release are the time constants of the gain reduction in dB.
  // The level detector is the peak of the last 10 ms, so the release starts
  // 10 ms after the burst ends.
  for (double rate : {44100.0, 48000.0, 96000.0}) {
    const float settings[3][2] = {{8.0f, 120.0f}, {1.0f, 50.0f}, {30.0f, 400.0f}};
    for (const auto& setting : settings) {
      const Ballistics b = measureBallistics(rate, setting[0], setting[1], 0.5);
      const double releaseTarget = setting[1] + 10.0;
      if (std::fabs(b.attackMs - setting[0]) > 0.15 * setting[0] + 0.5 ||
          std::fabs(b.releaseMs - releaseTarget) > 0.10 * releaseTarget) {
        std::fprintf(stderr, "timing at %.0f Hz, controls %.0f / %.0f ms: measured %.1f / %.1f ms\n",
                     rate, setting[0], setting[1], b.attackMs, b.releaseMs);
        ++failures;
      }
    }
    // The release time does not depend on how loud the burst was.
    const Ballistics loud = measureBallistics(rate, 8.0f, 120.0f, 0.5);
    const Ballistics soft = measureBallistics(rate, 8.0f, 120.0f, 0.1);
    if (std::fabs(loud.releaseMs - soft.releaseMs) > 0.10 * loud.releaseMs) {
      std::fprintf(stderr, "release at %.0f Hz depends on level: %.1f ms loud, %.1f ms soft\n",
                   rate, loud.releaseMs, soft.releaseMs);
      ++failures;
    }
    // A low note does not modulate the gain, even with the fastest release.
    for (double hz : {61.74, 82.41, 110.0}) {
      const double ripple = lowNoteGainRippleDb(rate, hz, 1.0f, 10.0f);
      if (ripple > 0.02) {
        std::fprintf(stderr, "gain ripple at %.0f Hz on a %.2f Hz note: %.4f dB\n", rate, hz, ripple);
        ++failures;
      }
    }
  }
  if (failures) {
    std::fprintf(stderr, "FAIL compressor ballistics (%d failures)\n", failures);
    return 1;
  }
  std::puts("  PASS  attack and release match the controls at every level; low notes do not modulate the gain");

  // Makeup: a peak at the reference level keeps its level at every Amount.
  if (NAMRig::compressorMakeupDb(-12.0f, 1.0f) != 0.0f) ++failures;
  if (std::fabs(NAMRig::compressorMakeupDb(-36.0f, 6.0f) - 20.0f) > 1.0e-4f) ++failures;
  for (double rate : {44100.0, 48000.0, 96000.0}) {
    for (float amount : {10.0f, 25.0f, 50.0f, 75.0f, 100.0f}) {
      const double out = settledPeakDb(rate, 1000.0, NAMRig::kCompressorReferenceDb, amount);
      if (std::fabs(out - NAMRig::kCompressorReferenceDb) > 0.5) {
        std::fprintf(stderr, "makeup at %.0f Hz, Amount %.0f: -12 dBFS peak leaves at %.2f dBFS\n",
                     rate, amount, out);
        ++failures;
      }
    }
    // A louder peak is still reduced, and a quieter one is raised.
    if (settledPeakDb(rate, 1000.0, -3.0, 100.0f) > -9.5 ||
        settledPeakDb(rate, 1000.0, -30.0, 100.0f) < -16.5) {
      std::fprintf(stderr, "compression range at %.0f Hz\n", rate);
      ++failures;
    }
    // Sidechain high-pass: a low-string fundamental gets 2 to 4 dB less
    // reduction than the midrange, and the tone above the filter is not affected.
    const double mid = settledPeakDb(rate, 1000.0, -12.0, 100.0f);
    const double lowE = settledPeakDb(rate, 82.41, -12.0, 100.0f) - mid;
    const double high = settledPeakDb(rate, 330.0, -12.0, 100.0f) - mid;
    if (lowE < 2.0 || lowE > 4.0 || std::fabs(high) > 0.6) {
      std::fprintf(stderr, "sidechain at %.0f Hz: 82 Hz %+.2f dB, 330 Hz %+.2f dB against 1 kHz\n",
                   rate, lowE, high);
      ++failures;
    }
    // Detector floor: content far below the filter is at most 5.5 dB hotter
    // than the midrange, so it cannot pass with the full makeup gain.
    for (double hz : {0.0, 20.0, 41.2}) {
      const double excess = settledPeakDb(rate, hz, -12.0, 100.0f) - mid;
      if (excess > 5.5) {
        std::fprintf(stderr, "detector floor at %.0f Hz: %.1f Hz content is %+.2f dB against 1 kHz\n",
                     rate, hz, excess);
        ++failures;
      }
    }
  }
  if (failures) {
    std::fprintf(stderr, "FAIL compressor makeup and sidechain (%d failures)\n", failures);
    return 1;
  }
  std::puts("  PASS  makeup keeps a -12 dBFS peak at its level; sidechain high-pass with a bounded detector floor");
  return 0;
}
