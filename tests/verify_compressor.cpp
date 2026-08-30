#include "dynamics.h"

#include <cmath>
#include <cstdio>

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
  if (failures) {
    std::fprintf(stderr, "FAIL compressor curve (%d failures)\n", failures);
    return 1;
  }
  std::puts("  PASS  compressor soft-knee curve and bypass ratio");
  return 0;
}
