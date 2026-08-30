#pragma once

#include <algorithm>

namespace NAMRig {

// Static soft-knee compressor curve. Returns positive gain reduction in dB.
inline float compressorReductionDb(float levelDb, float thresholdDb,
                                    float ratio, float kneeDb = 6.0f) {
  ratio = std::max(1.0f, ratio);
  const float slope = 1.0f - 1.0f / ratio;
  const float over = levelDb - thresholdDb;
  if (over <= -0.5f * kneeDb) return 0.0f;
  if (over >= 0.5f * kneeDb) return slope * over;
  const float x = over + 0.5f * kneeDb;
  return slope * x * x / (2.0f * kneeDb);
}

} // namespace NAMRig
