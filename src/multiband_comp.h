#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

#include "dynamics.h"

namespace NAMRig {

// Three-band compressor on Linkwitz-Riley 4th order crossovers (two cascaded
// Butterworth biquads per slope). The low band passes through the high
// crossover's allpass (LP4 + HP4 of the same poles) so the recombined bands
// sum to a flat magnitude. Each band carries the rig's one-knob compressor:
// amount lowers threshold (-12 -> -36 dB), raises ratio (1:1 -> 6:1) and adds
// up to 6 dB makeup, with a 6 dB soft knee, 8 ms attack (15 ms on the low
// band) and 120 ms release on a stereo-linked peak detector (1 ms / 80 ms).
// All three amounts at zero is an exact bypass; the crossover is not run.
class MultibandCompressor {
 public:
  void initialize(double rate) {
    rate_ = rate > 0.0 ? rate : 48000.0;
    envAttack_ = coeff(0.001);
    envRelease_ = coeff(0.080);
    gainRelease_ = coeff(0.120);
    band_[0].gainAttack = coeff(0.015);
    band_[1].gainAttack = coeff(0.008);
    band_[2].gainAttack = coeff(0.008);
    reset();
  }
  void reset() {
    for (Channel& ch : channel_) ch.reset();
    for (Band& b : band_) {
      b.envelope = 0.0f;
      b.gain = 1.0f;
      b.smoothed = 0.0f;
    }
    appliedLow_ = appliedHigh_ = -1.0f;
    primed_ = false;
    cleared_ = true;
  }
  // Stereo in place, stereo-linked detection. All three amounts 0 (settled) is an EXACT bypass
  // (bit-identical output; the crossover is not applied at all).
  void process(float* left, float* right, size_t count, float lowXoverHz, float highXoverHz,
               float lowPercent, float midPercent, float highPercent) {
    const float targets[3] = {unit(lowPercent), unit(midPercent), unit(highPercent)};
    bool idle = true;
    for (size_t b = 0; b < 3; ++b)
      if (targets[b] > 0.0f || band_[b].smoothed > 0.0f) idle = false;
    if (idle) {
      if (!cleared_) reset();
      return;
    }
    cleared_ = false;
    const float lowTarget = clampFinite(lowXoverHz, 60.0f, 500.0f);
    const float highTarget = std::min(static_cast<float>(0.45 * rate_),
        std::max(2.0f * lowTarget, clampFinite(highXoverHz, 1000.0f, 8000.0f)));
    if (!primed_) {
      smoothedLow_ = lowTarget;
      smoothedHigh_ = highTarget;
      primed_ = true;
    }
    const float glide = static_cast<float>(1.0 - std::exp(-static_cast<double>(kChunk) / (rate_ * 0.020)));
    for (size_t start = 0; start < count; start += kChunk) {
      const size_t m = std::min(kChunk, count - start);
      glideValue(smoothedLow_, lowTarget, glide, 0.01f);
      glideValue(smoothedHigh_, highTarget, glide, 0.01f);
      if (smoothedLow_ != appliedLow_) {
        for (Channel& ch : channel_) setCrossover(ch.lowLp, ch.lowHp, nullptr, smoothedLow_);
        appliedLow_ = smoothedLow_;
      }
      if (smoothedHigh_ != appliedHigh_) {
        for (Channel& ch : channel_) setCrossover(ch.highLp, ch.highHp, &ch.highAp, smoothedHigh_);
        appliedHigh_ = smoothedHigh_;
      }
      float thresholdDb[3], ratio[3], makeupDb[3];
      bool active[3];
      for (size_t b = 0; b < 3; ++b) {
        glideValue(band_[b].smoothed, targets[b], glide, 1.0e-4f);
        const float amount = band_[b].smoothed;
        active[b] = amount > 0.0f;
        thresholdDb[b] = -12.0f - 24.0f * amount;
        ratio[b] = 1.0f + 5.0f * amount;
        makeupDb[b] = 6.0f * amount;
        if (!active[b]) {
          band_[b].envelope = 0.0f;
          band_[b].gain = 1.0f;
        }
      }
      for (size_t i = start; i < start + m; ++i) {
        float bandL[3], bandR[3];
        channel_[0].split(left[i], bandL);
        channel_[1].split(right[i], bandR);
        for (size_t b = 0; b < 3; ++b) {
          if (!active[b]) continue;
          Band& band = band_[b];
          const float level = std::max(std::fabs(bandL[b]), std::fabs(bandR[b]));
          band.envelope += (level - band.envelope) *
              (level > band.envelope ? envAttack_ : envRelease_);
          const float levelDb = band.envelope > 1.0e-9f
              ? 20.0f * std::log10(band.envelope) : -180.0f;
          const float reductionDb = compressorReductionDb(levelDb, thresholdDb[b], ratio[b], 6.0f);
          const float targetGain = std::pow(10.0f, (makeupDb[b] - reductionDb) * 0.05f);
          band.gain += (targetGain - band.gain) *
              (targetGain < band.gain ? band.gainAttack : gainRelease_);
          bandL[b] *= band.gain;
          bandR[b] *= band.gain;
        }
        left[i] = bandL[0] + bandL[1] + bandL[2];
        right[i] = bandR[0] + bandR[1] + bandR[2];
      }
    }
  }

 private:
  static constexpr size_t kChunk = 32;
  static constexpr double kPi = 3.14159265358979323846;

  struct Biquad {
    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;
    double z1 = 0.0, z2 = 0.0;
    double process(double x) {
      const double y = b0 * x + z1;
      z1 = b1 * x - a1 * y + z2;
      z2 = b2 * x - a2 * y;
      return y;
    }
    void reset() { z1 = z2 = 0.0; }
  };

  struct Channel {
    Biquad lowLp[2], lowHp[2], highLp[2], highHp[2], highAp;
    void reset() {
      for (size_t k = 0; k < 2; ++k) {
        lowLp[k].reset();
        lowHp[k].reset();
        highLp[k].reset();
        highHp[k].reset();
      }
      highAp.reset();
    }
    void split(float x, float* bands) {
      const double in = x;
      const double low = highAp.process(lowLp[1].process(lowLp[0].process(in)));
      const double rest = lowHp[1].process(lowHp[0].process(in));
      bands[0] = static_cast<float>(low);
      bands[1] = static_cast<float>(highLp[1].process(highLp[0].process(rest)));
      bands[2] = static_cast<float>(highHp[1].process(highHp[0].process(rest)));
    }
  };

  struct Band {
    float envelope = 0.0f, gain = 1.0f, smoothed = 0.0f;
    float gainAttack = 0.0f;
  };

  static float unit(float percent) { return clampFinite(percent, 0.0f, 100.0f) * 0.01f; }
  static float clampFinite(float x, float lo, float hi) {
    if (!std::isfinite(x)) return lo;
    return std::max(lo, std::min(hi, x));
  }
  static void glideValue(float& value, float target, float coeff, float snap) {
    value += (target - value) * coeff;
    if (std::fabs(target - value) < snap) value = target;
  }
  float coeff(double seconds) const {
    return static_cast<float>(1.0 - std::exp(-1.0 / (rate_ * seconds)));
  }

  // Butterworth (Q = 1/sqrt2) low/high pair for both cascade stages, plus the
  // matching allpass (numerator is the reversed denominator).
  void setCrossover(Biquad* lp, Biquad* hp, Biquad* ap, double hz) const {
    const double w = 2.0 * kPi * hz / rate_;
    const double c = std::cos(w), s = std::sin(w);
    const double alpha = s / (2.0 * 0.7071067811865476);
    const double a0 = 1.0 + alpha;
    const double a1 = -2.0 * c / a0;
    const double a2 = (1.0 - alpha) / a0;
    for (size_t k = 0; k < 2; ++k) {
      lp[k].b0 = 0.5 * (1.0 - c) / a0;
      lp[k].b1 = (1.0 - c) / a0;
      lp[k].b2 = lp[k].b0;
      lp[k].a1 = a1;
      lp[k].a2 = a2;
      hp[k].b0 = 0.5 * (1.0 + c) / a0;
      hp[k].b1 = -(1.0 + c) / a0;
      hp[k].b2 = hp[k].b0;
      hp[k].a1 = a1;
      hp[k].a2 = a2;
    }
    if (ap) {
      ap->b0 = a2;
      ap->b1 = a1;
      ap->b2 = 1.0;
      ap->a1 = a1;
      ap->a2 = a2;
    }
  }

  double rate_ = 48000.0;
  Channel channel_[2];
  Band band_[3];
  float envAttack_ = 0.0f, envRelease_ = 0.0f, gainRelease_ = 0.0f;
  float smoothedLow_ = 0.0f, smoothedHigh_ = 0.0f;
  float appliedLow_ = -1.0f, appliedHigh_ = -1.0f;
  bool primed_ = false;
  bool cleared_ = true;
};

}  // namespace NAMRig
