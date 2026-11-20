#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

#include "amp_engine_mode.h"

namespace NAMRig {

// Zero-lookahead (baseline) or 0.75 ms lookahead + band-limited sidechain
// (enhanced), hysteretic downward expander. Opening and tail tracking use
// separate envelopes so a short release does not swallow the next pick.
class NoiseGate {
 public:
  static constexpr uint32_t kDelayCapacity = 512u;
  static constexpr uint32_t kDelayMask = kDelayCapacity - 1u;

  static uint32_t lookaheadForRate(double rate, float thresholdDb,
                                   bool enhanced) noexcept {
    if (!enhanced || thresholdDb <= -79.99f || rate <= 0.0) return 0u;
    const uint32_t samples = static_cast<uint32_t>(std::lround(rate * 0.00075));
    return std::clamp(samples, 1u, kDelayCapacity - 1u);
  }

  uint32_t latencySamples() const noexcept {
    return (active_ && configuredEnhanced_) ? lookaheadSamples_ : 0u;
  }

  void reset() noexcept {
    onset_ = tail_ = muteReference_ = 0.0f;
    gain_ = 1.0f;
    open_ = true;
    muted_ = false;
    hold_ = qualification_ = onsetGap_ = muteQualification_ = 0;
    delayBuf_.fill(0.0f);
    delayWrite_ = 0u;
    scHpfZ1_ = scHpfZ2_ = 0.0;
    scHpf2Z1_ = scHpf2Z2_ = 0.0;
    scLpfState_ = 0.0;
  }

  void configure(double rate, float thresholdDb, float releaseMs) {
    const bool enhanced = EngineMode::has(EngineMode::kGateAndCompDynamics);
    if (active_ && rate == configuredRate_ && thresholdDb == configuredThreshold_ &&
        releaseMs == configuredRelease_ && enhanced == configuredEnhanced_) return;
    const bool modeChanged = (enhanced != configuredEnhanced_) || (rate != configuredRate_);
    active_ = thresholdDb > -79.99f;
    configuredEnhanced_ = enhanced;
    if (!active_) {
      reset();
      configuredRate_ = rate;
      configuredThreshold_ = thresholdDb;
      configuredRelease_ = releaseMs;
      lookaheadSamples_ = 0u;
      return;
    }
    if (modeChanged) {
      delayBuf_.fill(0.0f);
      delayWrite_ = 0u;
      scHpfZ1_ = scHpfZ2_ = 0.0;
      scHpf2Z1_ = scHpf2Z2_ = 0.0;
      scLpfState_ = 0.0;
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
    lookaheadSamples_ = lookaheadForRate(rate, thresholdDb, enhanced);
    // Detector-only sidechain filter (enhanced): cascaded 4th-order (24 dB/oct)
    // HPF at 110 Hz strongly rejects 50/60 Hz mains hum (-21..-27 dB) & palm-rest
    // rumble while passing guitar harmonics & pick transients cleanly; 1-pole LPF
    // at 4.5 kHz rejects pickup RF hiss.
    constexpr double kPi = 3.14159265358979323846;
    const double safeRate = std::max(8000.0, rate);
    const double w0 = 2.0 * kPi * 110.0 / safeRate;
    const double cs = std::cos(w0), sn = std::sin(w0);
    const double alpha = sn / (2.0 * 0.7071067811865476);
    const double a0 = 1.0 + alpha;
    scHpfB0_ = (1.0 + cs) * 0.5 / a0;
    scHpfB1_ = -(1.0 + cs) / a0;
    scHpfB2_ = scHpfB0_;
    scHpfA1_ = -2.0 * cs / a0;
    scHpfA2_ = (1.0 - alpha) / a0;
    scLpfCoeff_ = 1.0 - std::exp(-2.0 * kPi * std::min(4500.0, safeRate * 0.42) / safeRate);
    configuredRate_ = rate;
    configuredThreshold_ = thresholdDb;
    configuredRelease_ = releaseMs;
  }

  float process(float input) {
    if (!active_) return input;
    const bool enhanced = configuredEnhanced_;
    float audioSample = input;
    float detectorSample = input;
    if (enhanced) {
      delayBuf_[delayWrite_] = input;
      audioSample = delayBuf_[(delayWrite_ + kDelayCapacity - lookaheadSamples_) & kDelayMask];
      delayWrite_ = (delayWrite_ + 1u) & kDelayMask;
      const double x = static_cast<double>(input);
      const double hp1 = scHpfB0_ * x + scHpfZ1_;
      scHpfZ1_ = scHpfB1_ * x - scHpfA1_ * hp1 + scHpfZ2_;
      scHpfZ2_ = scHpfB2_ * x - scHpfA2_ * hp1;
      const double hp2 = scHpfB0_ * hp1 + scHpf2Z1_;
      scHpf2Z1_ = scHpfB1_ * hp1 - scHpfA1_ * hp2 + scHpf2Z2_;
      scHpf2Z2_ = scHpfB2_ * hp1 - scHpfA2_ * hp2;
      scLpfState_ += scLpfCoeff_ * (hp2 - scLpfState_);
      detectorSample = static_cast<float>(scLpfState_);
    }
    const float level = std::fabs(detectorSample);
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
    float target = 1.0f;
    if (!open_) {
      if (enhanced && muted_) {
        // 4:1 downward closure on deliberate palm-mute stops for crisp silence between chugs.
        const float r = std::clamp(relativeTail, 0.0f, 1.0f);
        target = std::clamp(r * r * r, 0.0005f, 1.0f);
      } else {
        target = std::clamp(relativeTail, 0.001f, 1.0f);
      }
    }
    // Natural tails ease into expansion; deep idle noise and mutes use the
    // requested release. Never extend a deliberate mute's gain release.
    const float tailWeight = muted_ ? 0.0f : std::min(1.0f, relativeTail);
    const float closing = gainRelease_ + (naturalRelease_ - gainRelease_) * tailWeight;
    gain_ += (target - gain_) * (target > gain_ ? gainAttack_ : closing);
    return audioSample * gain_;
  }

 private:
  double configuredRate_ = 0.0;
  float configuredThreshold_ = -80.0f, configuredRelease_ = 0.0f;
  bool configuredEnhanced_ = false;
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
  uint32_t lookaheadSamples_ = 0u;
  std::array<float, kDelayCapacity> delayBuf_{};
  uint32_t delayWrite_ = 0u;
  double scHpfB0_ = 1.0, scHpfB1_ = 0.0, scHpfB2_ = 0.0, scHpfA1_ = 0.0, scHpfA2_ = 0.0;
  double scHpfZ1_ = 0.0, scHpfZ2_ = 0.0;
  double scHpf2Z1_ = 0.0, scHpf2Z2_ = 0.0;
  double scLpfCoeff_ = 1.0, scLpfState_ = 0.0;
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

// Detector and gain follower shared by the input and the post-FX compressor.
// Baseline uses 1 ms / 80 ms linear envelope smoothing; enhanced mode adds a
// 110 Hz sidechain HPF (when driven with signed audio), fast 0.2 ms / 12 ms
// peak tracking so user Release controls aren't floored at 80 ms, dB-domain
// gain reduction smoothing, and noise-floor-safe makeup attenuation.
class CompressorCore {
 public:
  void prepare(double rate) noexcept {
    const double safeRate = std::max(1.0, rate);
    if (safeRate == rate_) return;
    rate_ = safeRate;
    envAttack_ = static_cast<float>(-std::expm1(-1.0 / (rate_ * 0.001)));
    envRelease_ = static_cast<float>(-std::expm1(-1.0 / (rate_ * 0.080)));
    fastEnvAttack_ = static_cast<float>(-std::expm1(-1.0 / (rate_ * 0.0002)));
    fastEnvRelease_ = static_cast<float>(-std::expm1(-1.0 / (rate_ * 0.012)));
    activityAttack_ = static_cast<float>(-std::expm1(-1.0 / (rate_ * 0.002)));
    activityRelease_ = static_cast<float>(-std::expm1(-1.0 / (rate_ * 0.120)));
    constexpr double kPi = 3.14159265358979323846;
    scHpfCoeff_ = static_cast<float>(1.0 - std::exp(-2.0 * kPi * 110.0 / rate_));
    reset();
  }

  void reset() noexcept {
    envelope_ = 0.0f;
    gain_ = 1.0f;
    reductionDb_ = 0.0f;
    activityEnv_ = 0.0f;
    scLpL_ = 0.0f;
    scLpR_ = 0.0f;
  }

  // Returns the smoothed linear gain for one sample from the detector level.
  float process(float level, float thresholdDb, float ratio, float makeupDb,
                float attackCoeff, float releaseCoeff) noexcept {
    if (!EngineMode::has(EngineMode::kGateAndCompDynamics)) {
      envelope_ += (level - envelope_) * (level > envelope_ ? envAttack_ : envRelease_);
      if (envelope_ < 1.0e-20f) envelope_ = 0.0f;
      const float db = envelope_ > 1.0e-9f ? 20.0f * std::log10(envelope_) : -180.0f;
      const float reduction = compressorReductionDb(db, thresholdDb, ratio);
      const float targetGain = std::pow(10.0f, (makeupDb - reduction) * 0.05f);
      gain_ += (targetGain - gain_) * (targetGain < gain_ ? attackCoeff : releaseCoeff);
      return gain_;
    }
    return processEnhancedDetector(level, level, thresholdDb, ratio, makeupDb,
                                   attackCoeff, releaseCoeff);
  }

  // Signed mono entry point so enhanced mode can apply the 110 Hz sidechain HPF
  // (preventing palm-mute low-E fundamentals from ducking upper-mid pick attack).
  float processSigned(float signedSample, float thresholdDb, float ratio, float makeupDb,
                      float attackCoeff, float releaseCoeff) noexcept {
    const float rawLevel = std::fabs(signedSample);
    if (!EngineMode::has(EngineMode::kGateAndCompDynamics)) {
      return process(rawLevel, thresholdDb, ratio, makeupDb, attackCoeff, releaseCoeff);
    }
    scLpL_ += scHpfCoeff_ * (signedSample - scLpL_);
    const float scLevel = std::fabs(signedSample - scLpL_);
    return processEnhancedDetector(scLevel, rawLevel, thresholdDb, ratio, makeupDb,
                                   attackCoeff, releaseCoeff);
  }

  // Signed stereo entry point for linked stereo compression.
  float processStereoSigned(float leftSample, float rightSample, float thresholdDb,
                            float ratio, float makeupDb,
                            float attackCoeff, float releaseCoeff) noexcept {
    const float rawLevel = std::max(std::fabs(leftSample), std::fabs(rightSample));
    if (!EngineMode::has(EngineMode::kGateAndCompDynamics)) {
      return process(rawLevel, thresholdDb, ratio, makeupDb, attackCoeff, releaseCoeff);
    }
    scLpL_ += scHpfCoeff_ * (leftSample - scLpL_);
    scLpR_ += scHpfCoeff_ * (rightSample - scLpR_);
    const float scLevel = std::max(std::fabs(leftSample - scLpL_),
                                   std::fabs(rightSample - scLpR_));
    return processEnhancedDetector(scLevel, rawLevel, thresholdDb, ratio, makeupDb,
                                   attackCoeff, releaseCoeff);
  }

 private:
  float processEnhancedDetector(float scLevel, float rawLevel, float thresholdDb,
                                float ratio, float makeupDb,
                                float attackCoeff, float releaseCoeff) noexcept {
    envelope_ += (scLevel - envelope_) *
                 (scLevel > envelope_ ? fastEnvAttack_ : fastEnvRelease_);
    if (envelope_ < 1.0e-20f) envelope_ = 0.0f;
    const float db = envelope_ > 1.0e-9f ? 20.0f * std::log10(envelope_) : -180.0f;
    const float targetReduction = compressorReductionDb(db, thresholdDb, ratio);
    reductionDb_ += (targetReduction - reductionDb_) *
                    (targetReduction > reductionDb_ ? attackCoeff : releaseCoeff);
    if (reductionDb_ < 1.0e-6f) reductionDb_ = 0.0f;

    // Fade makeup gain smoothly to 0 dB below idle pickup noise (-62..-44 dBFS)
    // so the compressor doesn't hiss noise floor into high-gain amp stages.
    activityEnv_ += (rawLevel - activityEnv_) *
                    (rawLevel > activityEnv_ ? activityAttack_ : activityRelease_);
    if (activityEnv_ < 1.0e-20f) activityEnv_ = 0.0f;
    const float activityDb = activityEnv_ > 1.0e-9f ? 20.0f * std::log10(activityEnv_) : -180.0f;
    const float makeupGate = std::clamp((activityDb + 62.0f) / 18.0f, 0.0f, 1.0f);
    gain_ = std::pow(10.0f, (makeupDb * makeupGate - reductionDb_) * 0.05f);
    return gain_;
  }

  double rate_ = 0.0;
  float envAttack_ = 0.02f;
  float envRelease_ = 0.00026f;
  float fastEnvAttack_ = 0.1f;
  float fastEnvRelease_ = 0.0017f;
  float activityAttack_ = 0.01f;
  float activityRelease_ = 0.00017f;
  float scHpfCoeff_ = 0.014f;
  float envelope_ = 0.0f;
  float gain_ = 1.0f;
  float reductionDb_ = 0.0f;
  float activityEnv_ = 0.0f;
  float scLpL_ = 0.0f;
  float scLpR_ = 0.0f;
};

// Feed-forward, zero-lookahead stereo compressor. Both channels receive the
// same gain, driven by the louder channel, so compression never shifts the image.
// Amount follows the input compressor's curve; control/bypass changes glide.
class StereoCompressor {
 public:
  void initialize(double rate) {
    rate_ = std::max(1.0, rate);
    controlCoeff_ = coefficient(10.0f);
    core_.prepare(rate_);
    reset();
  }

  void reset() {
    amount_ = wet_ = 0.0f;
    core_.reset();
  }

  void process(float* left, float* right, uint32_t count, float amount,
               float attackMs, float releaseMs, bool enabled) {
    const float targetAmount = finiteClamp(amount, 0.0f, 100.0f, 0.0f) * 0.01f;
    const float targetWet = enabled && targetAmount > 0.0f ? 1.0f : 0.0f;
    const float attack = coefficient(finiteClamp(attackMs, 1.0f, 100.0f, 8.0f));
    const float release = coefficient(finiteClamp(releaseMs, 10.0f, 1000.0f, 120.0f));
    const bool enhanced = EngineMode::has(EngineMode::kGateAndCompDynamics);
    for (uint32_t i = 0; i < count; ++i) {
      amount_ = glide(amount_, targetAmount);
      wet_ = glide(wet_, targetWet);
      if (wet_ == 0.0f) {
        core_.reset();
        continue; // Settled OFF / Amount 0 is bit-exact, including stereo IRs.
      }
      const float gain = enhanced
          ? core_.processStereoSigned(left[i], right[i], -12.0f - 24.0f * amount_,
                                      1.0f + 5.0f * amount_, 6.0f * amount_, attack, release)
          : core_.process(std::max(std::fabs(left[i]), std::fabs(right[i])),
                          -12.0f - 24.0f * amount_, 1.0f + 5.0f * amount_,
                          6.0f * amount_, attack, release);
      const float linkedGain = 1.0f + wet_ * (gain - 1.0f);
      left[i] *= linkedGain;
      right[i] *= linkedGain;
    }
  }

 private:
  static float finiteClamp(float value, float lo, float hi, float fallback) {
    return std::isfinite(value) ? std::clamp(value, lo, hi) : fallback;
  }
  float coefficient(float ms) const {
    return static_cast<float>(-std::expm1(-1.0 / (rate_ * ms * 0.001)));
  }
  float glide(float current, float target) const {
    return std::fabs(current - target) < 1.0e-5f ? target
        : current + (target - current) * controlCoeff_;
  }
  double rate_ = 48000.0;
  float controlCoeff_ = 0.002f;
  float amount_ = 0.0f, wet_ = 0.0f;
  CompressorCore core_;
};

} // namespace NAMRig
