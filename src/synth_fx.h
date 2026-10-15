#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace NAMRig {

// Monophonic guitar synth mixed in parallel with the dry signal.
//
// Pitch: the input runs through a 2-pole 1.2 kHz low-pass, then upward
// crossings of a hysteresis band (8 % of the envelope) time the period with
// linear interpolation. Periods outside 60..1200 Hz are rejected, the median
// of the last three is kept, and the pitch holds through short dropouts.
// Amplitude: an envelope follower (3 ms / 80 ms) scales the oscillator so the
// synth follows the playing; a smoothed gate silences it below -50 dBFS.
// Oscillator: sine, polyBLEP square and saw, or a square one octave down.
// Filter: a resonant 2-pole TPT low-pass, cutoff from Filter (200 Hz..8 kHz)
// lifted by the envelope. Frequency glides over ~10 ms so detector jitter
// does not warble. Wave Off or Mix 0 (settled) is an exact bypass.
class GuitarSynth {
 public:
  enum Wave { kOff = 0, kSine, kSquare, kSaw, kSubOctave, kWaveCount };

  static constexpr float kFilterDefault = 50.0f;
  static constexpr double kMinHz = 60.0, kMaxHz = 1200.0;

  void initialize(double rate) noexcept {
    rate_ = std::isfinite(rate) && rate > 1.0 ? rate : 48000.0;
    envAttack_ = -std::expm1(-1.0 / (rate_ * 0.003));
    envRelease_ = -std::expm1(-1.0 / (rate_ * 0.080));
    gateK_ = -std::expm1(-1.0 / (rate_ * 0.005));
    const double g = std::tan(kPi * std::min(1200.0, 0.45 * rate_) / rate_);
    detK_ = std::sqrt(2.0);
    detA1_ = 1.0 / (1.0 + g * (g + detK_));
    detA2_ = g * detA1_;
    detA3_ = g * detA2_;
    holdSamples_ = static_cast<uint32_t>(std::ceil(rate_ * 0.150));
    silenceSamples_ = static_cast<uint32_t>(std::ceil(rate_ * 0.250));
    reset();
  }

  void reset() noexcept {
    detIc1_ = detIc2_ = 0.0;
    prevDet_ = 0.0;
    high_ = false;
    sinceCross_ = 0;
    prevFrac_ = 0.0;
    periods_[0] = periods_[1] = periods_[2] = 0.0;
    periodIndex_ = periodCount_ = 0;
    hz_ = smoothHz_ = 0.0;
    env_ = 0.0;
    gateOpen_ = false;
    closedFor_ = 0;
    gate_ = 0.0;
    resetVoice();
    smoothMix_ = smoothFilter_ = 0.0f;
    wave_ = kSine;
    primed_ = false;
  }

  // Mono, in place: samples[i] += synth * mix. wave kOff or mixPercent 0 (settled) is an EXACT bypass.
  void process(float* samples, size_t count, int wave, float mixPercent,
               float filterPercent) noexcept {
    if (rate_ <= 0.0) initialize(48000.0);
    const bool waveOn = wave > kOff && wave < kWaveCount;
    const float mixTarget = waveOn && std::isfinite(mixPercent)
        ? std::clamp(mixPercent * 0.01f, 0.0f, 1.0f) : 0.0f;
    const float filterTarget = std::isfinite(filterPercent)
        ? std::clamp(filterPercent * 0.01f, 0.0f, 1.0f) : kFilterDefault * 0.01f;
    if (waveOn) wave_ = wave;
    if (!primed_) {
      // Engaging fades the mix in from zero at the current filter setting.
      smoothMix_ = 0.0f;
      smoothFilter_ = filterTarget;
      primed_ = true;
    }
    for (size_t start = 0; start < count; start += kChunk) {
      const size_t n = std::min(kChunk, count - start);
      const float smooth = 1.0f - static_cast<float>(
          std::exp(-static_cast<double>(n) / (rate_ * 0.010)));
      glide(smoothMix_, mixTarget, smooth);
      glide(smoothFilter_, filterTarget, smooth);
      if (hz_ > 0.0) {
        // A note from silence starts on pitch; otherwise glide.
        if (smoothHz_ <= 0.0 || gate_ < 0.01) smoothHz_ = hz_;
        else smoothHz_ += (hz_ - smoothHz_) * smooth;
      }
      const bool render = smoothMix_ > 0.0f;
      if (!render) resetVoice();
      const double inc = smoothHz_ / rate_;
      const double lift = 1.0 + std::min(1.0, env_ * 3.0);
      const double cutoff = std::min(filterHz(smoothFilter_) * lift, std::min(0.45 * rate_, 20000.0));
      const double fg = std::tan(kPi * cutoff / rate_);
      const double fa1 = 1.0 / (1.0 + fg * (fg + kFilterK));
      const double fa2 = fg * fa1;
      const double fa3 = fg * fa2;
      const double mix = smoothMix_;
      float* s = samples + start;
      for (size_t i = 0; i < n; ++i) {
        const double x = s[i];
        track(x);
        if (!render) continue;
        phase_ += inc;
        if (phase_ >= 1.0) phase_ -= 1.0;
        subPhase_ += 0.5 * inc;
        if (subPhase_ >= 1.0) subPhase_ -= 1.0;
        double osc;
        switch (wave_) {
          case kSquare: osc = square(phase_, inc); break;
          case kSaw: osc = 2.0 * phase_ - 1.0 - blep(phase_, inc); break;
          case kSubOctave: osc = square(subPhase_, 0.5 * inc); break;
          default: osc = std::sin(2.0 * kPi * phase_); break;
        }
        const double in = osc * env_ * gate_;
        const double v3 = in - fIc2_;
        const double v1 = fa1 * fIc1_ + fa2 * v3;
        const double v2 = fIc2_ + fa2 * fIc1_ + fa3 * v3;
        fIc1_ = 2.0 * v1 - fIc1_;
        fIc2_ = 2.0 * v2 - fIc2_;
        s[i] = static_cast<float>(x + v2 * mix);
      }
      if (!std::isfinite(fIc1_) || !std::isfinite(fIc2_)) fIc1_ = fIc2_ = 0.0;
      if (!std::isfinite(detIc1_) || !std::isfinite(detIc2_) || !std::isfinite(env_)) {
        detIc1_ = detIc2_ = env_ = prevDet_ = 0.0;
      }
    }
  }

  float trackedHz() const noexcept { return static_cast<float>(hz_); }  // 0 when no pitch

  static double filterHz(float filter01) noexcept {
    return 200.0 * std::pow(40.0, static_cast<double>(filter01));
  }

 private:
  static constexpr size_t kChunk = 32;
  static constexpr double kPi = 3.14159265358979323846;
  static constexpr double kFilterK = 1.0 / 2.5;          // resonant 2-pole, Q 2.5
  static constexpr double kGateOpen = 0.00316227766;     // -50 dBFS
  static constexpr double kGateClose = 0.00158489319;    // -56 dBFS
  static constexpr double kHysteresis = 0.08;

  void track(double x) noexcept {
    const double a = std::fabs(x);
    env_ += (a - env_) * (a > env_ ? envAttack_ : envRelease_);
    if (env_ > kGateOpen) gateOpen_ = true;
    else if (env_ < kGateClose) gateOpen_ = false;
    if (gateOpen_) {
      closedFor_ = 0;
    } else if (closedFor_ < silenceSamples_) {
      ++closedFor_;
    } else {
      hz_ = 0.0;
      periodCount_ = 0;
    }
    const double gateTarget = (gateOpen_ && hz_ > 0.0) ? 1.0 : 0.0;
    gate_ += (gateTarget - gate_) * gateK_;

    const double v3 = x - detIc2_;
    const double v1 = detA1_ * detIc1_ + detA2_ * v3;
    const double v2 = detIc2_ + detA2_ * detIc1_ + detA3_ * v3;
    detIc1_ = 2.0 * v1 - detIc1_;
    detIc2_ = 2.0 * v2 - detIc2_;
    const double d = v2;
    const double thr = std::max(kHysteresis * env_, 1.0e-4);
    if (sinceCross_ < holdSamples_) ++sinceCross_;
    if (!high_ && d > thr) {
      high_ = true;
      const double rise = d - prevDet_;
      const double frac = rise > 0.0 ? std::clamp((thr - prevDet_) / rise, 0.0, 1.0) : 1.0;
      const double period = static_cast<double>(sinceCross_) + frac - prevFrac_;
      const double hz = period > 0.0 ? rate_ / period : 0.0;
      if (hz >= kMinHz && hz <= kMaxHz) pushPeriod(period);
      sinceCross_ = 0;
      prevFrac_ = frac;
    } else if (high_ && d < -thr) {
      high_ = false;
    }
    prevDet_ = d;
    if (sinceCross_ >= holdSamples_) {
      hz_ = 0.0;
      periodCount_ = 0;
    }
  }

  void pushPeriod(double period) noexcept {
    if (periodCount_ == 0) {
      periods_[0] = periods_[1] = periods_[2] = period;
      periodIndex_ = 0;
    } else {
      periods_[periodIndex_] = period;
    }
    periodIndex_ = (periodIndex_ + 1) % 3;
    periodCount_ = std::min<uint32_t>(3, periodCount_ + 1);
    const double lo = std::min(periods_[0], std::min(periods_[1], periods_[2]));
    const double hi = std::max(periods_[0], std::max(periods_[1], periods_[2]));
    const double median = periods_[0] + periods_[1] + periods_[2] - lo - hi;
    hz_ = rate_ / median;
  }

  void resetVoice() noexcept {
    phase_ = subPhase_ = 0.0;
    fIc1_ = fIc2_ = 0.0;
  }

  static double blep(double t, double dt) noexcept {
    if (t < dt) {
      t /= dt;
      return t + t - t * t - 1.0;
    }
    if (t > 1.0 - dt) {
      t = (t - 1.0) / dt;
      return t * t + t + t + 1.0;
    }
    return 0.0;
  }
  static double square(double phase, double dt) noexcept {
    double v = phase < 0.5 ? 1.0 : -1.0;
    v += blep(phase, dt);
    double t = phase + 0.5;
    if (t >= 1.0) t -= 1.0;
    return v - blep(t, dt);
  }
  static void glide(float& value, float target, float coeff) noexcept {
    value += (target - value) * coeff;
    if (std::fabs(target - value) < 1.0e-5f) value = target;
  }

  double rate_ = 0.0;
  double envAttack_ = 0.0, envRelease_ = 0.0, gateK_ = 0.0;
  double detK_ = 0.0, detA1_ = 0.0, detA2_ = 0.0, detA3_ = 0.0;
  double detIc1_ = 0.0, detIc2_ = 0.0, prevDet_ = 0.0, prevFrac_ = 0.0;
  double periods_[3] = {0.0, 0.0, 0.0};
  double hz_ = 0.0, smoothHz_ = 0.0, env_ = 0.0, gate_ = 0.0;
  double phase_ = 0.0, subPhase_ = 0.0, fIc1_ = 0.0, fIc2_ = 0.0;
  uint32_t holdSamples_ = 0, silenceSamples_ = 0, sinceCross_ = 0, closedFor_ = 0;
  uint32_t periodIndex_ = 0, periodCount_ = 0;
  float smoothMix_ = 0.0f, smoothFilter_ = 0.0f;
  int wave_ = kSine;
  bool high_ = false, gateOpen_ = false, primed_ = false;
};

}  // namespace NAMRig
