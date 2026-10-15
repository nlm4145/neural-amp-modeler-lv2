#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

#include "space_fx.h"

namespace NAMRig {

// Dispersive spring tank. The pre-delayed mono input feeds one spring per
// output channel: a 30-60 ms feedback loop whose path carries a chain of 16
// second-order allpass sections centred between 2 and 4 kHz, a damping
// one-pole and a soft limiter. Each trip through the chain delays the band
// around the spring's transition frequency further behind the lows, so an
// impulse turns into the familiar rising chirp and later echoes smear more
// than earlier ones. A shorter parallel loop fed from the dispersed signal
// fills in echo density. The two springs use different allpass seeds and loop
// lengths for stereo width. Loop gain stays below one after damping and the
// limiter only ever attenuates, so full decay is long but bounded.
// Mix 0 is an exact bypass; the tank is cleared while bypassed so re-engaging
// starts silent.
class SpringReverb {
 public:
  void initialize(double rate) {
    rate_ = rate > 0.0 ? rate : 48000.0;
    predelay_.allocate(static_cast<size_t>(std::ceil(rate_ * 0.1)) + 8);
    for (size_t c = 0; c < 2; ++c) {
      spring_[c].loop.allocate(
          static_cast<size_t>(std::ceil(rate_ * kMaxLoopSeconds * kLoopRatio[c])) + 8);
      spring_[c].density.allocate(
          static_cast<size_t>(std::ceil(rate_ * kMaxDensitySeconds * kDensityRatio[c])) + 8);
    }
    reset();
  }
  void reset() {
    predelay_.clear();
    for (Spring& s : spring_) {
      s.loop.clear();
      s.density.clear();
      s.damp = s.densityDamp = 0.0f;
      for (Allpass& a : s.chain) a.reset();
    }
    smoothedMix_ = 0.0f;
    appliedSize_ = appliedDamping_ = -1.0f;
    primed_ = false;
    cleared_ = true;
  }
  // Stereo in place. mixPercent 0 (settled) is an EXACT bypass (bit-identical, history cleared).
  // decayPercent: tail length; sizePercent: spring length/tension (shifts the chirp and the
  // echo density); dampingPercent: high-frequency loss; predelayMs 0–100.
  void process(float* left, float* right, size_t count, float mixPercent, float decayPercent,
               float sizePercent, float dampingPercent, float predelayMs) {
    const float mixTarget = unit(mixPercent);
    if (mixTarget <= 0.0f && smoothedMix_ <= 0.0f) {
      if (!cleared_) reset();
      return;
    }
    cleared_ = false;
    const float decayTarget = unit(decayPercent);
    const float sizeTarget = unit(sizePercent);
    const float dampingTarget = unit(dampingPercent);
    const float predelayTarget =
        static_cast<float>(clampFinite(predelayMs, 0.0f, 100.0f) * 0.001 * rate_);
    if (!primed_) {
      smoothedDecay_ = decayTarget;
      smoothedSize_ = sizeTarget;
      smoothedDamping_ = dampingTarget;
      smoothedPredelay_ = predelayTarget;
      primed_ = true;
    }
    const float glide = chunkGlide(0.020);
    const float sizeGlide = chunkGlide(0.250);
    for (size_t start = 0; start < count; start += kChunk) {
      const size_t m = std::min(kChunk, count - start);
      const float mixFrom = smoothedMix_;
      glideValue(smoothedMix_, mixTarget, glide, 1.0e-4f);
      glideValue(smoothedDecay_, decayTarget, glide, 1.0e-4f);
      glideValue(smoothedDamping_, dampingTarget, glide, 1.0e-4f);
      glideValue(smoothedSize_, sizeTarget, sizeGlide, 1.0e-4f);
      glideValue(smoothedPredelay_, predelayTarget, glide, 1.0e-3f);
      if (smoothedSize_ != appliedSize_) {
        configureSize(smoothedSize_);
        appliedSize_ = smoothedSize_;
      }
      if (smoothedDamping_ != appliedDamping_) {
        const double cutoff = 5000.0 * std::pow(0.25, static_cast<double>(smoothedDamping_));
        dampCoeff_ = static_cast<float>(1.0 - std::exp(-2.0 * kPi * cutoff / rate_));
        appliedDamping_ = smoothedDamping_;
      }
      const float g = 0.50f + 0.44f * smoothedDecay_;
      const float g2 = 0.80f * g;
      const float mixStep = (smoothedMix_ - mixFrom) / static_cast<float>(m);
      float mix = mixFrom;
      for (size_t i = start; i < start + m; ++i) {
        mix += mixStep;
        const float in = 0.5f * (left[i] + right[i]);
        predelay_.write(in);
        const float pre = predelay_.readFrac(smoothedPredelay_);
        left[i] += mix * tick(spring_[0], pre, g, g2, dampCoeff_);
        right[i] += mix * tick(spring_[1], pre, g, g2, dampCoeff_);
      }
    }
  }

 private:
  static constexpr size_t kChunk = 32;
  static constexpr size_t kSections = 16;
  static constexpr double kPi = 3.14159265358979323846;
  static constexpr double kMaxLoopSeconds = 0.060;
  static constexpr double kMaxDensitySeconds = 0.020;
  static constexpr double kLoopRatio[2] = {1.0, 1.063};
  static constexpr double kDensityRatio[2] = {1.0, 1.19};
  static constexpr double kChainBaseHz[2] = {2000.0, 2080.0};
  static constexpr double kChainBandwidthHz[2] = {1200.0, 1350.0};

  // Second-order allpass (Zölzer), transposed direct form II in double.
  struct Allpass {
    double k0 = 0.0, k1 = 0.0;
    double z1 = 0.0, z2 = 0.0;
    void set(double centerHz, double bandwidthHz, double rate) {
      const double t = std::tan(kPi * bandwidthHz / rate);
      const double c = (t - 1.0) / (t + 1.0);
      const double d = -std::cos(2.0 * kPi * centerHz / rate);
      k0 = -c;
      k1 = d * (1.0 - c);
    }
    double process(double x) {
      const double y = k0 * x + z1;
      z1 = k1 * x - k1 * y + z2;
      z2 = x - k0 * y;
      return y;
    }
    void reset() { z1 = z2 = 0.0; }
  };

  struct Spring {
    DelayLine loop, density;
    Allpass chain[kSections];
    double loopDelay = 1.0, densityDelay = 1.0;
    float damp = 0.0f, densityDamp = 0.0f;
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
  static float soft(float x) { return x / std::sqrt(1.0f + 0.25f * x * x); }
  float chunkGlide(double seconds) const {
    return static_cast<float>(1.0 - std::exp(-static_cast<double>(kChunk) / (rate_ * seconds)));
  }

  void configureSize(float size) {
    // A longer, looser spring has a lower transition frequency and wider echoes.
    const double chirp = 1.15 - 0.30 * static_cast<double>(size);
    const double maxHz = 0.45 * rate_;
    for (size_t c = 0; c < 2; ++c) {
      Spring& s = spring_[c];
      for (size_t k = 0; k < kSections; ++k) {
        const double center = std::min(maxHz,
            kChainBaseHz[c] * std::pow(2.0, static_cast<double>(k) / (kSections - 1)) * chirp);
        s.chain[k].set(center, kChainBandwidthHz[c] * chirp, rate_);
      }
      // The read happens before this sample is written, so the line's newest
      // sample is already one behind the input.
      s.loopDelay = std::max(1.0,
          (0.030 + 0.030 * static_cast<double>(size)) * rate_ * kLoopRatio[c] - 1.0);
      s.densityDelay = std::max(1.0,
          (0.009 + 0.008 * static_cast<double>(size)) * rate_ * kDensityRatio[c] - 1.0);
    }
  }

  static float tick(Spring& s, float in, float g, float g2, float dampCoeff) {
    const float tap = s.loop.readFrac(s.loopDelay);
    s.damp += (tap - s.damp) * dampCoeff;
    double v = soft(in + g * s.damp);
    for (Allpass& a : s.chain) v = a.process(v);
    const float dispersed = static_cast<float>(v);
    s.loop.write(dispersed);
    const float dense = s.density.readFrac(s.densityDelay);
    s.densityDamp += (dense - s.densityDamp) * dampCoeff;
    s.density.write(soft(dispersed + g2 * s.densityDamp));
    return 0.7f * tap + 0.3f * dense;
  }

  double rate_ = 48000.0;
  DelayLine predelay_;
  Spring spring_[2];
  float dampCoeff_ = 1.0f;
  float smoothedMix_ = 0.0f, smoothedDecay_ = 0.0f, smoothedSize_ = 0.0f;
  float smoothedDamping_ = 0.0f, smoothedPredelay_ = 0.0f;
  float appliedSize_ = -1.0f, appliedDamping_ = -1.0f;
  bool primed_ = false;
  bool cleared_ = true;
};

}  // namespace NAMRig
