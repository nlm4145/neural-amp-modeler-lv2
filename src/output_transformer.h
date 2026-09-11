#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace NAMRig {

// Lightweight output-transformer coloration for the amp stage.  A NAM amp
// capture normally already contains its real transformer's response, so mode
// 0 is deliberately a bit-transparent default.  The other profiles are not
// branded transformer part numbers; they are useful, repeatable families of
// low-frequency core saturation, leakage/bandwidth, resonance and sag.
class OutputTransformer {
public:
  static constexpr int kCaptured = 0;
  static constexpr int kModern = 1;
  static constexpr int kUSVintage = 2;
  static constexpr int kUKVintage = 3;
  static constexpr int kSmallIron = 4;
  static constexpr int kTightMetal = 5;
  static constexpr int kExtendedRange = 6;
  static constexpr int kThrashBite = 7;
  static constexpr int kDoomIron = 8;
  static constexpr int kStudioLinear = 9;
  static constexpr int kTweedBloom = 10;
  static constexpr int kClassAChime = 11;
  static constexpr int kBassIron = 12;
  static constexpr int kProfileCount = 13;

  static int clampProfile(int profile) {
    return std::max(kCaptured, std::min(kBassIron, profile));
  }

  void reset() {
    lowBand_ = 0.0f;
    envelope_ = 0.0f;
    highPass_.reset();
    resonance_.reset();
    voice_.reset();
    highCut_.reset();
  }

  void process(float* samples, size_t count, double sampleRate, int profile) {
    if (!samples || count == 0) return;
    profile = clampProfile(profile);
    if (profile != profile_ || std::fabs(sampleRate - sampleRate_) > 0.5)
      configure(profile, sampleRate);
    if (profile_ == kCaptured) return;  // exact bypass for existing sessions

    for (size_t i = 0; i < count; ++i) {
      float x = highPass_.process(samples[i]);
      x = resonance_.process(x);
      x = voice_.process(x);

      // The core's flux is dominated by low frequencies.  Feeding that slow
      // component harder into the saturating branch makes palm-muted bass
      // compress before the upper mids, like finite transformer iron.
      lowBand_ += lowBandCoeff_ * (x - lowBand_);
      const float coreInput = x + coreCoupling_ * lowBand_;
      const float biased = coreInput + asymmetry_;
      const float saturated =
          (fastTanh(drive_ * biased) - fastTanh(drive_ * asymmetry_)) / drive_;
      float y = x + saturationMix_ * (saturated - coreInput);

      // A modest program-dependent loss approximates supply/primary copper
      // compression without turning this block into a separate compressor.
      const float level = std::fabs(coreInput);
      envelope_ += (level - envelope_) *
                   (level > envelope_ ? envelopeAttack_ : envelopeRelease_);
      y *= 1.0f / (1.0f + sag_ * envelope_);
      samples[i] = highCut_.process(y * makeup_);
    }
  }

private:
  struct Biquad {
    // Double precision is important here even though the surrounding audio
    // is float. In a True-8x domain (up to 768 kHz), the poles of Studio
    // Linear's 7 Hz high-pass are so close to the unit circle that rounded
    // float coefficients/state can turn a small NAM-model DC offset into a
    // large low-frequency runaway. Keeping the recursive math in double
    // prevents that host-muting burst while preserving float I/O.
    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;
    double z1 = 0.0, z2 = 0.0;
    float process(float x) {
      const double input = x;
      const double y = b0 * input + z1;
      z1 = b1 * input - a1 * y + z2;
      z2 = b2 * input - a2 * y;
      return static_cast<float>(y);
    }
    void reset() { z1 = z2 = 0.0; }
  };

  struct Profile {
    float lowCutHz;
    float highCutHz;
    float resonanceHz;
    float resonanceDb;
    float resonanceQ;
    float voiceHz;
    float voiceDb;
    float voiceQ;
    float fluxHz;
    float coreCoupling;
    float drive;
    float saturationMix;
    float asymmetry;
    float sag;
    float makeup;
  };

  static constexpr Profile kProfiles_[kProfileCount] = {
      // Bypass values are unused.
      {5.0f, 24000.0f, 90.0f, 0.0f, 0.707f,
       2500.0f, 0.0f, 0.707f, 90.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 1.0f},
      // Broad-band, oversized modern iron: almost linear, gently rounded.
      {10.0f, 22000.0f, 82.0f, 0.50f, 0.70f,
       3200.0f, 0.50f, 0.65f, 90.0f, 0.30f, 1.60f, 0.24f, 0.000f, 0.025f, 1.030f},
      // Large US-style vintage iron: deep lows and restrained upper presence.
      {18.0f, 17500.0f, 88.0f, 1.45f, 0.78f,
       1750.0f, -1.20f, 0.68f, 105.0f, 0.58f, 2.20f, 0.38f, 0.025f, 0.060f, 1.118f},
      // UK stack-style iron: tighter bass, more compression and mid-bass bark.
      {40.0f, 10500.0f, 125.0f, 2.30f, 0.90f,
       2400.0f, 1.75f, 0.82f, 130.0f, 0.78f, 3.25f, 0.52f, 0.040f, 0.100f, 0.992f},
      // Smaller vintage iron: earliest core saturation and narrowest bandwidth.
      {68.0f, 7500.0f, 165.0f, 3.40f, 1.00f,
       1050.0f, 2.20f, 0.72f, 165.0f, 1.05f, 4.80f, 0.68f, 0.065f, 0.165f, 0.889f},
      // Fast, oversized metal iron: trims flub but keeps pick attack and air.
      {58.0f, 18000.0f, 105.0f, 0.55f, 0.72f,
       3400.0f, 1.80f, 0.78f, 115.0f, 0.42f, 2.30f, 0.32f, 0.012f, 0.025f, 1.035f},
      // Extended-range iron: preserves low F#/E while keeping the sub-bass
      // resonance and core compression disciplined.
      {30.0f, 20000.0f, 72.0f, 0.35f, 0.68f,
       4200.0f, 1.25f, 0.74f, 78.0f, 0.34f, 1.90f, 0.27f, 0.010f, 0.018f, 1.025f},
      // Lean low end, cutting upper mids and a harder-driven core for thrash.
      {72.0f, 14000.0f, 145.0f, 1.15f, 0.82f,
       2850.0f, 2.75f, 0.88f, 150.0f, 0.56f, 3.00f, 0.44f, 0.028f, 0.050f, 1.015f},
      // Big, slow and dark: low resonance, heavy core bloom and pronounced sag.
      {22.0f, 8500.0f, 82.0f, 5.50f, 0.84f,
       950.0f, 1.90f, 0.75f, 95.0f, 1.10f, 4.50f, 0.70f, 0.060f, 0.180f, 0.900f},
      // Studio-grade wide-band iron: clean headroom with audible low-end
      // weight and polished presence, but less core distortion than Modern.
      {7.0f, 23000.0f, 70.0f, 0.45f, 0.68f,
       4600.0f, 0.90f, 0.70f, 78.0f, 0.23f, 1.60f, 0.18f, 0.005f, 0.015f, 1.020f},
      // Loose American combo feel: warm low-mid bloom, soft top and deep sag.
      {25.0f, 9000.0f, 92.0f, 4.50f, 0.82f,
       850.0f, 1.50f, 0.70f, 105.0f, 0.96f, 4.10f, 0.64f, 0.070f, 0.200f, 0.925f},
      // Small class-A-style iron: controlled bass with an open, chiming voice.
      {44.0f, 15500.0f, 132.0f, 1.35f, 0.80f,
       3300.0f, 2.35f, 0.78f, 138.0f, 0.62f, 2.75f, 0.45f, 0.060f, 0.075f, 1.000f},
      // Large bass iron: deep fundamentals, restrained presence and high headroom.
      {11.0f, 13500.0f, 58.0f, 1.00f, 0.72f,
       1350.0f, -0.85f, 0.70f, 68.0f, 0.34f, 1.65f, 0.22f, 0.010f, 0.020f, 1.040f},
  };

  static constexpr double kPi = 3.14159265358979323846;

  // Stable, monotonic tanh approximation.  It is much cheaper than std::tanh
  // in an 8x domain and reaches exactly +/-1 at the clamp points.
  static float fastTanh(float x) {
    x = std::max(-3.0f, std::min(3.0f, x));
    const float x2 = x * x;
    return x * (27.0f + x2) / (27.0f + 9.0f * x2);
  }

  static void setHighPass(Biquad& f, float hz, double rate) {
    const double w = 2.0 * kPi * hz / rate;
    const double c = std::cos(w), s = std::sin(w);
    const double alpha = s / (2.0 * 0.7071067811865476);
    const double a0 = 1.0 + alpha;
    f.b0 = (1.0 + c) * 0.5 / a0;
    f.b1 = -(1.0 + c) / a0;
    f.b2 = f.b0;
    f.a1 = -2.0 * c / a0;
    f.a2 = (1.0 - alpha) / a0;
  }

  static void setLowPass(Biquad& f, float hz, double rate) {
    const double w = 2.0 * kPi * hz / rate;
    const double c = std::cos(w), s = std::sin(w);
    const double alpha = s / (2.0 * 0.7071067811865476);
    const double a0 = 1.0 + alpha;
    f.b0 = (1.0 - c) * 0.5 / a0;
    f.b1 = (1.0 - c) / a0;
    f.b2 = f.b0;
    f.a1 = -2.0 * c / a0;
    f.a2 = (1.0 - alpha) / a0;
  }

  static void setPeaking(Biquad& f, float hz, float gainDb, float q,
                         double rate) {
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w = 2.0 * kPi * hz / rate;
    const double c = std::cos(w), s = std::sin(w);
    const double alpha = s / (2.0 * q);
    const double a0 = 1.0 + alpha / A;
    f.b0 = (1.0 + alpha * A) / a0;
    f.b1 = -2.0 * c / a0;
    f.b2 = (1.0 - alpha * A) / a0;
    f.a1 = -2.0 * c / a0;
    f.a2 = (1.0 - alpha / A) / a0;
  }

  void configure(int profile, double rate) {
    profile_ = clampProfile(profile);
    sampleRate_ = std::max(8000.0, rate);
    reset();
    if (profile_ == kCaptured) return;
    const Profile& p = kProfiles_[profile_];
    setHighPass(highPass_, p.lowCutHz, sampleRate_);
    setPeaking(resonance_, p.resonanceHz, p.resonanceDb, p.resonanceQ,
               sampleRate_);
    setPeaking(voice_, p.voiceHz, p.voiceDb, p.voiceQ, sampleRate_);
    setLowPass(highCut_, std::min(p.highCutHz,
                                 static_cast<float>(sampleRate_ * 0.42)),
               sampleRate_);
    lowBandCoeff_ = 1.0f - std::exp(static_cast<float>(
        -2.0 * kPi * p.fluxHz / sampleRate_));
    envelopeAttack_ = 1.0f - std::exp(-1.0f / static_cast<float>(0.004 * sampleRate_));
    envelopeRelease_ = 1.0f - std::exp(-1.0f / static_cast<float>(0.090 * sampleRate_));
    coreCoupling_ = p.coreCoupling;
    drive_ = p.drive;
    saturationMix_ = p.saturationMix;
    asymmetry_ = p.asymmetry;
    sag_ = p.sag;
    makeup_ = p.makeup;
  }

  int profile_ = kCaptured;
  double sampleRate_ = 0.0;
  Biquad highPass_, resonance_, voice_, highCut_;
  float lowBand_ = 0.0f;
  float envelope_ = 0.0f;
  float lowBandCoeff_ = 0.0f;
  float envelopeAttack_ = 0.0f;
  float envelopeRelease_ = 0.0f;
  float coreCoupling_ = 0.0f;
  float drive_ = 1.0f;
  float saturationMix_ = 0.0f;
  float asymmetry_ = 0.0f;
  float sag_ = 0.0f;
  float makeup_ = 1.0f;
};

} // namespace NAMRig
