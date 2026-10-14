#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace NAMRig {

// Zero-lookahead, hysteretic downward expander. Opening and tail tracking use
// separate envelopes so a short release does not swallow the next pick.
class NoiseGate {
 public:
  void configure(double rate, float thresholdDb, float releaseMs) {
    active_ = thresholdDb > -79.99f;
    if (!active_) {
      onset_ = tail_ = muteReference_ = 0.0f;
      gain_ = 1.0f;
      open_ = true;
      muted_ = false;
      hold_ = qualification_ = onsetGap_ = muteQualification_ = 0;
      return;
    }
    openLevel_ = std::pow(10.0f, thresholdDb * 0.05f);
    closeLevel_ = openLevel_ * 0.501187234f; // 6 dB hysteresis
    const double release = std::max(0.020, releaseMs * 0.001);
    const auto coeff = [rate](double seconds) {
      return static_cast<float>(-std::expm1(-1.0 / (rate * seconds)));
    };
    onsetAttack_ = coeff(0.00015);
    onsetRelease_ = coeff(0.006);
    tailAttack_ = coeff(0.001);
    tailRelease_ = coeff(std::max(0.025, release * 0.5));
    muteReferenceRelease_ = coeff(0.025);
    muteRelease_ = coeff(0.003);
    gainAttack_ = coeff(0.0001);
    gainRelease_ = coeff(release);
    naturalRelease_ = coeff(release * 2.0);
    holdSamples_ = static_cast<uint32_t>(std::ceil(rate * 0.020));
    muteHoldSamples_ = static_cast<uint32_t>(std::ceil(rate * 0.005));
    qualificationSamples_ = static_cast<uint32_t>(std::ceil(rate * 0.00008));
    onsetGapSamples_ = static_cast<uint32_t>(std::ceil(rate * 0.00015));
    muteQualificationSamples_ = static_cast<uint32_t>(std::ceil(rate * 0.003));
  }

  float process(float input) {
    if (!active_) return input;
    const float level = std::fabs(input);
    onset_ += (level - onset_) * (level > onset_ ? onsetAttack_ : onsetRelease_);
    // Accumulate real above-threshold energy across short AC troughs, but
    // discard evidence between isolated spikes rather than counting aftermath.
    if (level >= openLevel_) {
      onsetGap_ = 0;
      if (qualification_ < qualificationSamples_) ++qualification_;
    } else {
      if (onsetGap_ < onsetGapSamples_) ++onsetGap_;
      if (onsetGap_ >= onsetGapSamples_) qualification_ = 0;
    }
    if (qualification_ >= qualificationSamples_ && onset_ >= closeLevel_) {
      open_ = true;
      muted_ = false;
      muteQualification_ = 0;
      hold_ = holdSamples_;
    }
    // The mute reference is independent of Release: long tail settings must
    // not turn gradual decay into an apparent rapid collapse. Debounce troughs.
    muteReference_ += (level - muteReference_) *
        (level > muteReference_ ? tailAttack_ : muteReferenceRelease_);
    if (!muted_ && onset_ < muteReference_ * 0.25f && onset_ < closeLevel_ * 0.5f) {
      if (muteQualification_ < muteQualificationSamples_) ++muteQualification_;
      if (muteQualification_ >= muteQualificationSamples_) {
        muted_ = true;
        hold_ = std::min(hold_, muteHoldSamples_);
      }
    } else {
      muteQualification_ = 0;
    }
    // An unqualified spike must not lift the closed gate's expansion target.
    const float tailInput = !open_ && level >= openLevel_ ? std::min(level, tail_) : level;
    tail_ += (tailInput - tail_) * (tailInput > tail_ ? tailAttack_
                                  : muted_ ? muteRelease_ : tailRelease_);
    if (open_) {
      if (!muted_ && tail_ >= closeLevel_) {
        hold_ = holdSamples_;
      } else if (hold_ > 0) {
        --hold_;
      } else {
        open_ = false;
      }
    }
    const float relativeTail = tail_ / std::max(closeLevel_, 1.0e-9f);
    const float target = open_ ? 1.0f : std::clamp(relativeTail, 0.001f, 1.0f);
    // Natural tails ease into expansion; deep idle noise and mutes use the
    // requested release. Never extend a deliberate mute's gain release.
    const float tailWeight = muted_ ? 0.0f : std::min(1.0f, relativeTail);
    const float closing = gainRelease_ + (naturalRelease_ - gainRelease_) * tailWeight;
    gain_ += (target - gain_) * (target > gain_ ? gainAttack_ : closing);
    return input * gain_;
  }

 private:
  bool active_ = false, open_ = true, muted_ = false;
  float onset_ = 0.0f, tail_ = 0.0f, muteReference_ = 0.0f, gain_ = 1.0f;
  float openLevel_ = 0.0f, closeLevel_ = 0.0f;
  float onsetAttack_ = 0.0f, onsetRelease_ = 0.0f;
  float tailAttack_ = 0.0f, tailRelease_ = 0.0f, muteRelease_ = 0.0f;
  float muteReferenceRelease_ = 0.0f;
  float gainAttack_ = 0.0f, gainRelease_ = 0.0f, naturalRelease_ = 0.0f;
  uint32_t hold_ = 0, qualification_ = 0, onsetGap_ = 0, muteQualification_ = 0;
  uint32_t holdSamples_ = 0, muteHoldSamples_ = 0, qualificationSamples_ = 0;
  uint32_t onsetGapSamples_ = 0, muteQualificationSamples_ = 0;
};

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
