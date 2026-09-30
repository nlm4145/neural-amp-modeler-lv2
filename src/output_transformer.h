#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

#include "transformer_controls.h"

namespace NAMRig {

// Lightweight output-transformer coloration for the amp stage.  A NAM amp
// capture normally already contains its real transformer's response, so mode
// 0 is deliberately a bit-transparent default.
//
// Core saturation acts on flux, the integral of the primary voltage, so low
// frequencies saturate first.  The flux path is a leaky integrator, a smooth
// saturator, and the inverse of that integrator back to the voltage domain.
// Without saturation the path is exactly identity.  Bandwidth limits and a
// high leakage-inductance resonance complete the profile; the low-frequency
// resonance of the load lives in SpeakerDynamics.
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

  struct Parameters {
    double lowCutHz;
    double highCutHz;
    double leakageHz;
    double leakageDb;
    double leakageQ;
    double voiceHz;
    double voiceDb;
    double voiceQ;
    double fluxHz;
    double drive;
    double saturationMix;
    double asymmetry;
    double makeup;
  };

  static int clampProfile(int profile) {
    return std::max(kCaptured, std::min(kBassIron, profile));
  }

  static Parameters parametersForProfile(
      int profile,
      const TransformerAdjustments& adjustments = kTransformerControlDefaults) {
    Parameters p = kProfiles_[clampProfile(profile)];
    const auto trim = [&](size_t i) -> double {
      const auto& c = kTransformerControls[i];
      return std::isfinite(adjustments[i])
          ? std::clamp(adjustments[i], c.minimum, c.maximum) : c.defaultValue;
    };
    p.lowCutHz = std::clamp(p.lowCutHz * trim(0), 5.0, 300.0);
    p.highCutHz = std::clamp(p.highCutHz * trim(1), 2000.0, 24000.0);
    p.drive = std::clamp(p.drive * trim(2), 0.5, 10.0);
    p.saturationMix = std::clamp(p.saturationMix + trim(3) * 0.01, 0.0, 1.0);
    p.fluxHz = std::clamp(p.fluxHz * trim(4), 20.0, 400.0);
    p.voiceHz = std::clamp(p.voiceHz * trim(5), 100.0, 12000.0);
    p.voiceDb = std::clamp(p.voiceDb + trim(6), -12.0, 12.0);
    p.voiceQ = std::clamp(p.voiceQ * trim(7), 0.2, 4.0);
    p.leakageHz = std::clamp(p.leakageHz * trim(8), 100.0, 12000.0);
    p.leakageDb = std::clamp(p.leakageDb + trim(9), -12.0, 12.0);
    p.leakageQ = std::clamp(p.leakageQ * trim(10), 0.2, 4.0);
    return p;
  }

  static std::array<float, 11> controlValues(const Parameters& p) {
    return {static_cast<float>(p.lowCutHz), static_cast<float>(p.highCutHz),
            static_cast<float>(p.drive), static_cast<float>(p.saturationMix * 100.0),
            static_cast<float>(p.fluxHz), static_cast<float>(p.voiceHz),
            static_cast<float>(p.voiceDb), static_cast<float>(p.voiceQ),
            static_cast<float>(p.leakageHz), static_cast<float>(p.leakageDb),
            static_cast<float>(p.leakageQ)};
  }

  void reset() {
    flux_ = 0.0;
    saturatedFlux_ = 0.0;
    highPass_.reset();
    leakage_.reset();
    voice_.reset();
    highCut_.reset();
    chunkRemaining_ = 0;
  }

  void process(float* samples, size_t count, double sampleRate, int profile,
               const TransformerAdjustments& adjustments = kTransformerControlDefaults) {
    if (!samples || count == 0) return;
    profile = clampProfile(profile);
    sampleRate = std::isfinite(sampleRate) ? std::max(8000.0, sampleRate) : 48000.0;
    TransformerAdjustments target;
    for (size_t i = 0; i < target.size(); ++i) {
      const auto& c = kTransformerControls[i];
      target[i] = std::isfinite(adjustments[i])
          ? std::clamp(adjustments[i], c.minimum, c.maximum) : c.defaultValue;
    }
    if (profile != profile_ || std::fabs(sampleRate - sampleRate_) > 0.5)
      configure(profile, sampleRate, target);
    if (profile_ == kCaptured) return;

    for (size_t i = 0; i < count; ++i) {
      if (chunkRemaining_ == 0) {
        bool changed = false;
        TransformerAdjustments smoothed;
        for (size_t j = 0; j < target.size(); ++j) {
          const double previous = adjustments_[j];
          adjustments_[j] += smoothCoeff_ * (target[j] - adjustments_[j]);
          if (std::fabs(target[j] - adjustments_[j]) < 1.0e-7)
            adjustments_[j] = target[j];
          changed = changed || adjustments_[j] != previous;
          smoothed[j] = static_cast<float>(adjustments_[j]);
        }
        if (changed) applyParameters(parametersForProfile(profile_, smoothed));
        // Keep this cadence across calls, including partial host blocks.
        chunkRemaining_ = 32;
      }
      --chunkRemaining_;
      double x = highPass_.process(samples[i]);
      x = voice_.process(x);

      flux_ += fluxCoeff_ * (x - flux_);
      const double saturated =
          (sigmoid(drive_ * flux_ + asymmetry_) - sigmoid(asymmetry_)) / drive_;
      const double coreVoltage =
          (saturated - (1.0 - fluxCoeff_) * saturatedFlux_) / fluxCoeff_;
      saturatedFlux_ = saturated;
      double y = x + saturationMix_ * (coreVoltage - x);

      y = leakage_.process(y);
      samples[i] = static_cast<float>(highCut_.process(y) * makeup_);
    }
  }

private:
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

  static constexpr Parameters kProfiles_[kProfileCount] = {
      {5.0, 24000.0, 9000.0, 0.0, 1.0, 2500.0, 0.0, 0.707, 90.0, 1.0, 0.0, 0.0, 1.0},
      // Broad-band, oversized modern iron: almost linear, gently rounded.
      {10.0, 22000.0, 8500.0, 0.60, 1.20, 3200.0, 0.50, 0.65, 90.0, 1.60, 0.24, 0.000, 1.020},
      // Large US-style vintage iron: deep lows and restrained upper presence.
      {18.0, 17500.0, 7000.0, 1.20, 1.10, 1750.0, -1.20, 0.68, 105.0, 2.20, 0.38, 0.025, 1.080},
      // UK stack-style iron: tighter bass, more compression and mid-bass bark.
      {40.0, 10500.0, 5600.0, 1.80, 1.00, 2400.0, 1.75, 0.82, 130.0, 3.25, 0.52, 0.040, 1.000},
      // Smaller vintage iron: earliest core saturation and narrowest bandwidth.
      {68.0, 7500.0, 4200.0, 2.40, 0.90, 1050.0, 2.20, 0.72, 165.0, 4.80, 0.68, 0.065, 0.930},
      // Fast, oversized metal iron: trims flub but keeps pick attack and air.
      {58.0, 18000.0, 7800.0, 1.00, 1.20, 3400.0, 1.80, 0.78, 115.0, 2.30, 0.32, 0.012, 1.030},
      // Extended-range iron: preserves low fundamentals with disciplined core drive.
      {30.0, 20000.0, 8200.0, 0.70, 1.20, 4200.0, 1.25, 0.74, 78.0, 1.90, 0.27, 0.010, 1.020},
      // Lean low end, cutting upper mids and a harder-driven core for thrash.
      {72.0, 14000.0, 6500.0, 1.60, 1.10, 2850.0, 2.75, 0.88, 150.0, 3.00, 0.44, 0.028, 1.010},
      // Big, slow and dark: heavy core bloom and rolled-off highs.
      {22.0, 8500.0, 4600.0, 2.00, 0.90, 950.0, 1.90, 0.75, 95.0, 4.50, 0.70, 0.060, 0.940},
      // Studio-grade wide-band iron: clean headroom, polished presence.
      {7.0, 23000.0, 9500.0, 0.40, 1.30, 4600.0, 0.90, 0.70, 78.0, 1.60, 0.18, 0.005, 1.020},
      // Loose American combo feel: warm low-mid bloom and a soft top.
      {25.0, 9000.0, 4800.0, 1.50, 0.90, 850.0, 1.50, 0.70, 105.0, 4.10, 0.64, 0.070, 0.950},
      // Small class-A-style iron: controlled bass with an open, chiming voice.
      {44.0, 15500.0, 7200.0, 2.20, 1.10, 3300.0, 2.35, 0.78, 138.0, 2.75, 0.45, 0.060, 1.000},
      // Large bass iron: deep fundamentals, restrained presence and high headroom.
      {11.0, 13500.0, 6000.0, 0.80, 1.10, 1350.0, -0.85, 0.70, 68.0, 1.65, 0.22, 0.010, 1.030},
  };

  static constexpr double kPi = 3.14159265358979323846;

  static double sigmoid(double x) { return x / std::sqrt(1.0 + x * x); }

  static void setHighPass(Biquad& f, double hz, double rate) {
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

  static void setLowPass(Biquad& f, double hz, double rate) {
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

  static void setPeaking(Biquad& f, double hz, double gainDb, double q,
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

  void configure(int profile, double rate, const TransformerAdjustments& target) {
    profile_ = clampProfile(profile);
    sampleRate_ = rate;
    reset();
    std::copy(target.begin(), target.end(), adjustments_.begin());
    smoothCoeff_ = 1.0 - std::exp(-32.0 / (sampleRate_ * 0.020));
    if (profile_ == kCaptured) return;
    applyParameters(parametersForProfile(profile_, target));
  }

  void applyParameters(const Parameters& p) {
    const double band = sampleRate_ * 0.42;
    setHighPass(highPass_, p.lowCutHz, sampleRate_);
    setPeaking(voice_, std::min(p.voiceHz, band), p.voiceDb, p.voiceQ, sampleRate_);
    setPeaking(leakage_, std::min(p.leakageHz, band * 0.9), p.leakageDb,
               p.leakageQ, sampleRate_);
    setLowPass(highCut_, std::min(p.highCutHz, band), sampleRate_);
    // Both flux samples must use the same drive curve, or the inverse
    // integrator amplifies the curve change into a voltage impulse.
    if (p.drive != drive_)
      saturatedFlux_ =
          (sigmoid(p.drive * flux_ + p.asymmetry) - sigmoid(p.asymmetry)) / p.drive;
    fluxCoeff_ = 1.0 - std::exp(-2.0 * kPi * p.fluxHz / sampleRate_);
    drive_ = p.drive;
    saturationMix_ = p.saturationMix;
    asymmetry_ = p.asymmetry;
    makeup_ = p.makeup;
  }

  int profile_ = kCaptured;
  double sampleRate_ = 0.0;
  std::array<double, kTransformerControlCount> adjustments_{};
  double smoothCoeff_ = 1.0;
  size_t chunkRemaining_ = 0;
  Biquad highPass_, leakage_, voice_, highCut_;
  double flux_ = 0.0;
  double saturatedFlux_ = 0.0;
  double fluxCoeff_ = 1.0;
  double drive_ = 1.0;
  double saturationMix_ = 0.0;
  double asymmetry_ = 0.0;
  double makeup_ = 1.0;
};

} // namespace NAMRig
