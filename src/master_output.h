#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace NAMRig {

// Final stereo utility. No lookahead, makeup gain, allocation, or added latency.
// Ceiling 0 means OFF, not a 0 dBFS limiter. Neutral skips all sample writes.
class MasterOutput {
  float limiterGain = 1.0f;
  float balanceState = 0.0f;
  float release = 0.0f, balanceCoeff = 1.0f;
  float meterDb = 0.0f;
  double rate = 48000.0;
public:
  void initialize(double sampleRate) {
    rate = sampleRate;
    release = static_cast<float>(std::exp(-1.0 / (rate * 0.080)));
    balanceCoeff = static_cast<float>(1.0 - std::exp(-1.0 / (rate * 0.005)));
    limiterGain = 1.0f;
    balanceState = meterDb = 0.0f;
  }

  float process(float* left, float* right, uint32_t count, float ceilingDb, float balance) {
    ceilingDb = std::isfinite(ceilingDb) ? std::clamp(ceilingDb, -24.0f, 0.0f) : 0.0f;
    balance = std::isfinite(balance) ? std::clamp(balance, -100.0f, 100.0f) * 0.01f : 0.0f;
    const bool limiting = ceilingDb < 0.0f;
    // Returning either control to neutral immediately removes its history too.
    if (!limiting) limiterGain = 1.0f;
    if (balance == 0.0f) balanceState = 0.0f;
    if (!limiting && balance == 0.0f) { meterDb = 0.0f; return 0.0f; }
    const float ceiling = limiting ? std::pow(10.0f, ceilingDb * 0.05f) : 1.0f;
    float minimumGain = 1.0f;
    for (uint32_t i = 0; i < count; ++i) {
      if (balance != 0.0f) {
        balanceState += (balance - balanceState) * balanceCoeff;
        if (std::fabs(balance - balanceState) < 1e-4f) balanceState = balance;
        // Balance attenuates one channel; it never boosts the other.
        if (balanceState > 0.0f) left[i] *= 1.0f - balanceState;
        else if (balanceState < 0.0f) right[i] *= 1.0f + balanceState;
      }
      if (limiting) {
        const float peak = std::max(std::fabs(left[i]), std::fabs(right[i]));
        const float required = peak > ceiling ? ceiling / peak : 1.0f;
        limiterGain = std::min(required, 1.0f - (1.0f - limiterGain) * release);
        minimumGain = std::min(minimumGain, limiterGain);
        if (limiterGain < 1.0f) {
          left[i] *= limiterGain;
          right[i] *= limiterGain;
        }
      }
    }
    const float reduction = -20.0f * std::log10(std::max(minimumGain, 1e-12f));
    meterDb = limiting ? std::max(reduction, meterDb - static_cast<float>(24.0 * count / rate)) : 0.0f;
    return meterDb;
  }
};
} // namespace NAMRig
