#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace NAMRig {

// Wah / auto-wah / state-variable filter ahead of the amp, at the session rate.
//
// Every mode runs the same TPT (Zavalishin) state-variable core in double. The
// core is the bilinear transform of the analog SVF, so responseDb evaluates the
// analog prototype at the pre-warped frequency and matches the audio path
// exactly. Wah is the Cry Baby shape, a resonant low-pass with a band-pass
// emphasis (0.7 bp + 0.3 lp) normalised to unity at the peak, so Resonance
// changes the shape and not the level. Auto-wah pushes Position up from an
// envelope follower of the input, scaled by Sensitivity. Low/Band/High are the
// plain SVF outputs with Resonance as Q.
class WahFilter {
 public:
  enum Mode { kWah = 0, kAutoWah, kLowPass, kBandPass, kHighPass, kModeCount };

  static constexpr float kPositionDefault = 50.0f;
  static constexpr float kResonanceDefault = 50.0f;
  static constexpr float kSensitivityDefault = 50.0f;

  void initialize(double rate) noexcept {
    rate_ = std::isfinite(rate) && rate > 1.0 ? rate : 48000.0;
    envAttack_ = -std::expm1(-1.0 / (rate_ * 0.005));
    envRelease_ = -std::expm1(-1.0 / (rate_ * 0.120));
    reset();
  }

  void reset() noexcept {
    ic1_ = ic2_ = 0.0;
    env_ = 0.0;
    smoothPos_ = smoothRes_ = 0.0f;
    primed_ = false;
  }

  // Mono, in place, at the session rate (44.1–192 kHz). The caller bypasses the block when its
  // rack is off; engaging/disengaging is handled by the caller's fade.
  void process(float* samples, size_t count, int mode, float positionPercent,
               float resonancePercent, float sensitivityPercent) noexcept {
    if (rate_ <= 0.0) initialize(48000.0);
    const int m = validMode(mode);
    const float pos = percent(positionPercent, kPositionDefault);
    const float res = percent(resonancePercent, kResonanceDefault);
    const float sens = percent(sensitivityPercent, kSensitivityDefault);
    if (!primed_) {
      smoothPos_ = pos;
      smoothRes_ = res;
      primed_ = true;
    }
    for (size_t start = 0; start < count; start += kChunk) {
      const size_t n = std::min(kChunk, count - start);
      const float smooth = 1.0f - static_cast<float>(
          std::exp(-static_cast<double>(n) / (rate_ * 0.010)));
      const float posTarget = m == kAutoWah ? autoPosition(pos, sens, env_) : pos;
      glide(smoothPos_, posTarget, smooth);
      glide(smoothRes_, res, smooth);
      const Coeffs c = coefficients(m, smoothPos_, smoothRes_, rate_);
      float* s = samples + start;
      for (size_t i = 0; i < n; ++i) {
        const double x = s[i];
        const double a = std::fabs(x);
        env_ += (a - env_) * (a > env_ ? envAttack_ : envRelease_);
        const double v3 = x - ic2_;
        const double v1 = c.a1 * ic1_ + c.a2 * v3;
        const double v2 = ic2_ + c.a2 * ic1_ + c.a3 * v3;
        ic1_ = 2.0 * v1 - ic1_;
        ic2_ = 2.0 * v2 - ic2_;
        const double hp = x - c.k * v1 - v2;
        s[i] = static_cast<float>(c.lpGain * v2 + c.bpGain * v1 + c.hpGain * hp);
      }
      if (!std::isfinite(ic1_) || !std::isfinite(ic2_)) ic1_ = ic2_ = 0.0;
      if (!std::isfinite(env_)) env_ = 0.0;
    }
  }

  // Magnitude response in dB at hz for the current mode/position/resonance (UI graph).
  static double responseDb(double hz, double rate, int mode, float positionPercent,
                           float resonancePercent) noexcept {
    rate = std::isfinite(rate) && rate > 1.0 ? rate : 48000.0;
    const Coeffs c = coefficients(validMode(mode), percent(positionPercent, kPositionDefault),
                                  percent(resonancePercent, kResonanceDefault), rate);
    hz = std::isfinite(hz) ? std::clamp(hz, 1.0, 0.499 * rate) : 1000.0;
    // Analog prototype at the pre-warped frequency: s = jW, W = tan(pi f / fs) / g.
    const double W = std::tan(kPi * hz / rate) / c.g;
    const double W2 = W * W;
    const double dRe = 1.0 - W2, dIm = c.k * W;
    const double nRe = c.lpGain - c.hpGain * W2, nIm = c.bpGain * W;
    const double mag = std::sqrt((nRe * nRe + nIm * nIm) / (dRe * dRe + dIm * dIm));
    return 20.0 * std::log10(std::max(mag, 1.0e-9));
  }

  static double wahHz(float pos01) noexcept {
    return 350.0 * std::pow(2200.0 / 350.0, static_cast<double>(pos01));
  }
  static double wahQ(float res01) noexcept {
    return 2.0 * std::pow(6.0, static_cast<double>(res01));
  }
  static double filterHz(float pos01) noexcept {
    return 80.0 * std::pow(100.0, static_cast<double>(pos01));
  }
  static double filterQ(float res01) noexcept {
    return 0.5 * std::pow(20.0, static_cast<double>(res01));
  }

 private:
  static constexpr size_t kChunk = 32;
  static constexpr double kPi = 3.14159265358979323846;
  static constexpr double kWahBp = 0.7, kWahLp = 0.3;

  struct Coeffs {
    double g, k, a1, a2, a3, lpGain, bpGain, hpGain;
  };

  static int validMode(int mode) noexcept {
    return (mode >= 0 && mode < kModeCount) ? mode : kWah;
  }
  static float percent(float value, float fallback) noexcept {
    return std::isfinite(value) ? std::clamp(value * 0.01f, 0.0f, 1.0f) : fallback * 0.01f;
  }
  // -40 dBFS keeps the pedal at the Position knob, -10 dBFS opens it fully.
  static float autoPosition(float pos01, float sens01, double env) noexcept {
    const double db = 20.0 * std::log10(std::max(env, 1.0e-6));
    const double open = std::clamp((db + 40.0) / 30.0, 0.0, 1.0);
    return std::clamp(pos01 + sens01 * static_cast<float>(open), 0.0f, 1.0f);
  }
  static Coeffs coefficients(int mode, float pos01, float res01, double rate) noexcept {
    const bool wah = mode == kWah || mode == kAutoWah;
    const double hz = std::min(wah ? wahHz(pos01) : filterHz(pos01), 0.45 * rate);
    const double q = wah ? wahQ(res01) : filterQ(res01);
    Coeffs c{};
    c.g = std::tan(kPi * hz / rate);
    c.k = 1.0 / q;
    c.a1 = 1.0 / (1.0 + c.g * (c.g + c.k));
    c.a2 = c.g * c.a1;
    c.a3 = c.g * c.a2;
    switch (mode) {
      case kLowPass: c.lpGain = 1.0; break;
      case kBandPass: c.bpGain = c.k; break;  // unity at the peak
      case kHighPass: c.hpGain = 1.0; break;
      default: {
        // At the peak bp = Q and lp = -jQ, so |0.7 bp + 0.3 lp| = Q sqrt(0.7^2 + 0.3^2).
        const double norm = 1.0 / (q * std::sqrt(kWahBp * kWahBp + kWahLp * kWahLp));
        c.bpGain = kWahBp * norm;
        c.lpGain = kWahLp * norm;
        break;
      }
    }
    return c;
  }
  static void glide(float& value, float target, float coeff) noexcept {
    value += (target - value) * coeff;
    if (std::fabs(target - value) < 1.0e-5f) value = target;
  }

  double rate_ = 0.0;
  double envAttack_ = 0.0, envRelease_ = 0.0;
  double ic1_ = 0.0, ic2_ = 0.0, env_ = 0.0;
  float smoothPos_ = 0.0f, smoothRes_ = 0.0f;
  bool primed_ = false;
};

}  // namespace NAMRig
