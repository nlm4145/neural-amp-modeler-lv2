#include "dynamics.h"

#include <cmath>
#include <cstdio>
#include <vector>
#include <limits>

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
    const float levelDb = 20.0f * std::log10(0.5f);
    const float expectedGain = std::pow(10.0f, (6.0f -
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
  return 0;
}
