#pragma once

#include <algorithm>
#include <array>
#include <cmath>

namespace NAMRig {

// Applies mono-sum-preserving Mid/Side width expansion for a single stereo IR.
// At width == 0.0 the native stereo image passes bit-identically. Increasing
// width scales Side up to 1.8x while keeping (L + R) * 0.5 strictly invariant.
inline void applySingleStereoWidthSample(float& l, float& r, float widthNormalized) noexcept {
  const float w = std::max(0.0f, std::min(1.0f, widthNormalized));
  if (w <= 0.0f) return;
  const float m = 0.5f * (l + r);
  const float s = 0.5f * (l - r) * (1.0f + 0.8f * w);
  l = m + s;
  r = m - s;
}

// Centered-blend stereoizer for dual-cabinet rigs: keeps BOTH Left and Right
// spectrally balanced with the blended (A + B) tone instead of panning Cab A left
// and Cab B right. Uses a 12-stage conformal bilinear Dome 90-degree phase-
// difference all-pass pair with a 150 Hz sub-bass mono lock on the synthesized
// Side component so mono sums remain 100% comb-free across all sample rates.
class DomeHilbertStereoizer {
 public:
  static constexpr size_t kStages = 6;
  static constexpr float kMaxSpread = 0.65f;
  static constexpr float kSideHighPassHz = 150.0f;
  static constexpr float kSideLowPassHz = 8000.0f;

  void prepare(double rate) noexcept {
    sampleRate = std::max(8000.0, rate);
    constexpr double kPi = 3.14159265358979323846;
    // Conformal continuous-domain equiripple poles covering ~65 Hz..22 kHz
    // mapped via t = pi * f / fs so |arg(H_b) - arg(H_a)| stays within
    // 90 +/- 0.6 degrees across 80 Hz..12 kHz at 44.1/48/96/192 kHz.
    static constexpr std::array<double, kStages> kPolesA = {
        20.2578, 120.5756, 450.9541, 1650.1137, 6157.2717, 22843.6005};
    static constexpr std::array<double, kStages> kPolesB = {
        62.5996, 232.2457, 866.6070, 3171.0544, 11859.7747, 70589.9864};
    for (size_t i = 0; i < kStages; ++i) {
      const double ta = kPi * kPolesA[i] / sampleRate;
      const double tb = kPi * kPolesB[i] / sampleRate;
      coeffA[i] = static_cast<float>((ta - 1.0) / (ta + 1.0));
      coeffB[i] = static_cast<float>((tb - 1.0) / (tb + 1.0));
    }

    // Sub-bass mono lock (150 Hz LR2 HPF) + upper fizz taper (8 kHz LR2 LPF) on
    // synthesized Side, phase-matched with exact Z-domain 1st-order all-pass
    // stages on Mid and natural Side so L/R keep true 90-deg quadrature and
    // equal spectral balance across all frequencies and sample rates.
    const double hpK = std::tan(
        kPi * std::min(static_cast<double>(kSideHighPassHz), sampleRate * 0.45) / sampleRate);
    const double lpK = std::tan(
        kPi * std::min(static_cast<double>(kSideLowPassHz), sampleRate * 0.45) / sampleRate);
    const float hpP = static_cast<float>((1.0 - hpK) / (1.0 + hpK));
    const float lpP = static_cast<float>((1.0 - lpK) / (1.0 + lpK));
    hpSide1.p = hpSide2.p = hpApM.p = hpApS.p = hpP;
    lpSide1.p = lpSide2.p = lpApM.p = lpApS.p = lpP;
    reset();
  }

  void reset() noexcept {
    stateM.fill(0.0f);
    stateSNat.fill(0.0f);
    stateB.fill(0.0f);
    hpSide1.reset();
    hpSide2.reset();
    lpSide1.reset();
    lpSide2.reset();
    hpApM.reset();
    lpApM.reset();
    hpApS.reset();
    lpApS.reset();
  }

  void processSample(float mixL, float mixR, float widthNormalized,
                     float& outL, float& outR) noexcept {
    const float w = std::max(0.0f, std::min(1.0f, widthNormalized));
    const float mIn = 0.5f * (mixL + mixR);
    const float sNatIn = 0.5f * (mixL - mixR);

    float mAllpass = runAllPass(coeffA, stateM, mIn);
    mAllpass = lpApM.processAllPassLp(hpApM.processAllPassHp(mAllpass));

    float sNatAllpass = runAllPass(coeffA, stateSNat, sNatIn);
    sNatAllpass = lpApS.processAllPassLp(hpApS.processAllPassHp(sNatAllpass));

    float sSynth = runAllPass(coeffB, stateB, mIn);
    sSynth = hpSide2.processHp(hpSide1.processHp(sSynth));
    sSynth = lpSide2.processLp(lpSide1.processLp(sSynth));

    const float g = kMaxSpread * w;
    const float sNatGain = 1.0f + 0.8f * w;
    const float norm = 1.0f / std::sqrt(1.0f + g * g);
    const float totalSide = g * sSynth + sNatGain * sNatAllpass;
    outL = norm * (mAllpass + totalSide);
    outR = norm * (mAllpass - totalSide);
  }

 private:
  struct FirstOrderSection {
    float p = 0.0f;
    float x1 = 0.0f, y1 = 0.0f;
    float processHp(float x) noexcept {
      const float y = 0.5f * (1.0f + p) * (x - x1) + p * y1;
      x1 = x;
      y1 = y;
      return y;
    }
    float processLp(float x) noexcept {
      const float y = 0.5f * (1.0f - p) * (x + x1) + p * y1;
      x1 = x;
      y1 = y;
      return y;
    }
    float processAllPassHp(float x) noexcept {
      const float y = p * x - x1 + p * y1;
      x1 = x;
      y1 = y;
      return y;
    }
    float processAllPassLp(float x) noexcept {
      const float y = -p * x + x1 + p * y1;
      x1 = x;
      y1 = y;
      return y;
    }
    void reset() noexcept { x1 = y1 = 0.0f; }
  };

  static float runAllPass(const std::array<float, kStages>& coeffs,
                          std::array<float, kStages>& states,
                          float x) noexcept {
    for (size_t i = 0; i < kStages; ++i) {
      const float c = coeffs[i];
      const float out = c * x + states[i];
      states[i] = x - c * out;
      x = out;
    }
    return x;
  }

  double sampleRate = 48000.0;
  std::array<float, kStages> coeffA{};
  std::array<float, kStages> coeffB{};
  std::array<float, kStages> stateM{};
  std::array<float, kStages> stateSNat{};
  std::array<float, kStages> stateB{};
  FirstOrderSection hpSide1, hpSide2, lpSide1, lpSide2;
  FirstOrderSection hpApM, lpApM, hpApS, lpApS;
};

}  // namespace NAMRig
