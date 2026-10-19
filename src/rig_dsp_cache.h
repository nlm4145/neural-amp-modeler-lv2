#pragma once

#include <algorithm>
#include <cmath>

namespace NAMRig {

// Audio-thread-owned caches. Rounding is part of each key so host fenv changes
// cannot reuse a coefficient calculated under a different rounding mode.
struct DbGainCache {
  float db = 0.0f, gain = 1.0f;
  int rounding = -1;
  float get(float value, int mode) noexcept {
    if (value != db || mode != rounding) {
      db = value;
      rounding = mode;
      gain = std::pow(10.0f, value * 0.05f);
    }
    return gain;
  }
};

struct RigRateCache {
  double rate = 0.0;
  int rounding = -1;
  float glide10 = 0.0f, chunkGlide = 0.0f;
  float envAttack = 0.0f, envRelease = 0.0f;
  void configure(double value, int mode) noexcept {
    if (value == rate && mode == rounding) return;
    rate = value;
    rounding = mode;
    glide10 = 1.0f - std::exp(-1.0f / static_cast<float>(value * 0.010));
    chunkGlide = 1.0f - std::exp(-static_cast<float>(32) /
                                static_cast<float>(value * 0.020));
    envAttack = 1.0f - std::exp(-1.0f / (value * 0.001));
    envRelease = 1.0f - std::exp(-1.0f / (value * 0.080));
  }
};

struct CompressorTimingCache {
  double rate = 0.0;
  float attack = 0.0f, release = 0.0f;
  float gainAttack = 0.0f, gainRelease = 0.0f;
  int rounding = -1;
  void configure(double value, float attackMs, float releaseMs, int mode) noexcept {
    if (value == rate && attackMs == attack && releaseMs == release && mode == rounding) return;
    rate = value;
    attack = attackMs;
    release = releaseMs;
    rounding = mode;
    gainAttack = 1.0f - std::exp(-1.0f / (value * (attackMs * 0.001f)));
    gainRelease = 1.0f - std::exp(-1.0f / (value * (releaseMs * 0.001f)));
  }
};

struct AmpDriveRateCache {
  double rate = 0.0;
  float coefficient = 0.0f;
  int rounding = -1;
  float get(double value, int mode) noexcept {
    if (value != rate || mode != rounding) {
      rate = value;
      rounding = mode;
      coefficient = 1.0f - std::exp(-1.0f /
          static_cast<float>(std::max(1.0, value) * 0.010));
    }
    return coefficient;
  }
};

struct WidthGainCache {
  float width = -1.0f, near = 0.0f, far = 0.0f, coherent = 1.0f;
  int rounding = -1;
  void configure(float value, int mode) noexcept {
    if (value == width && mode == rounding) return;
    width = value;
    rounding = mode;
    const float theta = static_cast<float>(3.14159265358979323846) * 0.25f * (1.0f - value);
    near = std::cos(theta);
    far = std::sin(theta);
    coherent = std::max(1.0f, near + far);
  }
};

}  // namespace NAMRig
