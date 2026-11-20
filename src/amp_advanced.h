#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

#include "power_tube_controls.h"

namespace NAMRig {

// Optional post-capture amp shaping. Every control has a neutral value and
// both entry points return without touching samples when all controls are
// neutral, preserving the captured model and the established post-chain EQ.
//
// The post-amp section is a virtual power stage with a negative-feedback loop:
//
//   y = L * [ sat(u / L + b) - sat(b) ],   u = A * (x - beta * F(y))
//
// A is the open-loop gain, beta the feedback fraction (Negative Feedback),
// F the feedback filter (Presence lowers its high-frequency gain, Depth its
// low-frequency gain), L the supply headroom (Sag) and b the bias point
// (Bias plus envelope-driven excursion). The loop is solved exactly per
// sample: the saturator is linear below a knee and rational above it, so the
// implicit equation reduces to a quadratic.
class AmpAdvanced {
 public:
  void reset() noexcept {
    resetPreAmp();
    resetPostAmp();
  }

  void resetPreAmp() noexcept {
    bright_.reset();
    inputEq_.reset();
    midPush_.reset();
    smoothBright_ = smoothInputEq_ = smoothMidPush_ = 0.0f;
    appliedBright_ = appliedInputEq_ = appliedMidPush_ = -1.0f;
  }

  void resetPostAmp(bool preserveTubeCharacter = false) noexcept {
    const float character = smoothTubeCharacter_;
    resetLoop();
    if (preserveTubeCharacter) smoothTubeCharacter_ = character;
  }
  void resetTubeCharacter() noexcept { smoothTubeCharacter_ = 0.0f; }
  bool hasTubeCharacter() const noexcept { return smoothTubeCharacter_ > 0.0f; }

  void processPreAmp(float* samples, size_t count, double rate,
                     float brightAmount, float inputEqAmount,
                     float midPushAmount = 0.0f) noexcept {
    const float brightTarget = clamp01(brightAmount * 0.01f);
    const float inputEqTarget = clamp01(inputEqAmount * 0.01f);
    const float midPushTarget = std::isfinite(midPushAmount) ? clamp01(midPushAmount * 0.01f) : 0.0f;
    if (brightTarget <= 0.0f && inputEqTarget <= 0.0f && midPushTarget <= 0.0f &&
        smoothBright_ <= 0.0f && smoothInputEq_ <= 0.0f && smoothMidPush_ <= 0.0f) {
      bright_.reset();
      inputEq_.reset();
      midPush_.reset();
      appliedBright_ = appliedInputEq_ = appliedMidPush_ = -1.0f;
      return;
    }
    if (rate != appliedPreRate_) {
      appliedBright_ = appliedInputEq_ = appliedMidPush_ = -1.0f;
      appliedPreRate_ = rate;
    }
    const float fullSmooth = chunkCoeff(rate, kChunk);
    for (size_t start = 0; start < count; start += kChunk) {
      const size_t n = std::min(kChunk, count - start);
      const float smooth = (n == kChunk) ? fullSmooth : chunkCoeff(rate, n);
      glide(smoothBright_, brightTarget, smooth);
      glide(smoothInputEq_, inputEqTarget, smooth);
      glide(smoothMidPush_, midPushTarget, smooth);
      if (smoothInputEq_ != appliedInputEq_) {
        if (smoothInputEq_ > 0.0f)
          setHighPass(inputEq_, 20.0f + 160.0f * smoothInputEq_, rate);
        else
          inputEq_.reset();
        appliedInputEq_ = smoothInputEq_;
      }
      if (smoothBright_ != appliedBright_) {
        if (smoothBright_ > 0.0f)
          setShelf(bright_, 6.0f * smoothBright_, 2200.0f, rate, true);
        else
          bright_.reset();
        appliedBright_ = smoothBright_;
      }
      // Overdrive-style mid hump in front of the capture (Tube Screamer /
      // tight-boost voicing); pair with Input EQ for the low cut.
      if (smoothMidPush_ != appliedMidPush_) {
        if (smoothMidPush_ > 0.0f)
          setPeak(midPush_, kMidPushMaxDb * smoothMidPush_, kMidPushHz, kMidPushQ, rate);
        else
          midPush_.reset();
        appliedMidPush_ = smoothMidPush_;
      }
      const bool eqOn = smoothInputEq_ > 0.0f;
      const bool brightOn = smoothBright_ > 0.0f;
      const bool midOn = smoothMidPush_ > 0.0f;
      float* s = samples + start;
      for (size_t i = 0; i < n; ++i) {
        double x = s[i];
        if (eqOn) x = inputEq_.advance(x);
        if (brightOn) x = bright_.advance(x);
        if (midOn) x = midPush_.advance(x);
        s[i] = static_cast<float>(x);
      }
    }
  }

  void processPostAmp(float* samples, size_t count, double rate,
                      float presenceDb, float depthDb, float sagAmount,
                      float biasAmount, float feedbackAmount,
                      float masterAmount, int tubeProfile = PowerTube::kCaptured,
                      float tubeCharacter = kPowerTubeCharacterDefault) noexcept {
    tubeProfile = PowerTube::clampProfile(tubeProfile);
    const float characterTarget = tubeProfile == PowerTube::kCaptured ? 0.0f
        : PowerTube::clampCharacter(tubeCharacter) * 0.01f;
    if (tubeProfile == PowerTube::kCaptured) resetTubeCharacter();
    // Specialize neutral character so the compiler retains the legacy arithmetic.
    if (characterTarget == 0.0f && smoothTubeCharacter_ == 0.0f)
      processPostAmpImpl<true>(samples, count, rate, presenceDb, depthDb, sagAmount,
                               biasAmount, feedbackAmount, masterAmount,
                               tubeProfile, characterTarget);
    else
      processPostAmpImpl<false>(samples, count, rate, presenceDb, depthDb, sagAmount,
                                biasAmount, feedbackAmount, masterAmount,
                                tubeProfile, characterTarget);
  }

 private:
  template <bool Legacy>
  void processPostAmpImpl(float* samples, size_t count, double rate,
                         float presenceDb, float depthDb, float sagAmount,
                         float biasAmount, float feedbackAmount, float masterAmount,
                         int tubeProfile, float characterTarget) noexcept {
    const float presenceTarget = std::max(-12.0f, std::min(12.0f, presenceDb));
    const float depthTarget = std::max(-12.0f, std::min(12.0f, depthDb));
    const float sagTarget = clamp01(sagAmount * 0.01f);
    const float biasTarget = std::max(-1.0f, std::min(1.0f, biasAmount * 0.01f));
    const float feedbackTarget = clamp01(feedbackAmount * 0.01f);
    const float masterTarget = clamp01(masterAmount * 0.01f);
    const auto& profile = PowerTube::kProfiles[static_cast<size_t>(tubeProfile)];
    const bool targetsNeutral = presenceTarget == 0.0f && depthTarget == 0.0f &&
                                sagTarget == 0.0f && biasTarget == 0.0f &&
                                feedbackTarget == 0.0f && masterTarget == 0.0f &&
                                characterTarget == 0.0f;
    const bool stateNeutral = smoothPresence_ == 0.0f && smoothDepth_ == 0.0f &&
                              smoothSag_ == 0.0f && smoothBias_ == 0.0f &&
                              smoothFeedback_ == 0.0f && smoothMaster_ == 0.0f &&
                              smoothTubeCharacter_ == 0.0f;
    if (targetsNeutral && stateNeutral) {
      resetLoop();
      return;
    }

    const float fullSmooth = chunkCoeff(rate, kChunk);
    const double screenAttack = 1.0 - std::exp(-1.0 / (rate * 0.008));
    const double screenRelease = 1.0 - std::exp(-1.0 / (rate * 0.055));
    const double reservoirAttack = 1.0 - std::exp(-1.0 / (rate * 0.040));
    const double reservoirRelease = 1.0 - std::exp(-1.0 / (rate * 0.280));
    float cachedMaster = -1.0f;
    double drive = 1.0;
    double outputScale = 1.0;

    for (size_t start = 0; start < count; start += kChunk) {
      const size_t n = std::min(kChunk, count - start);
      const float smooth = (n == kChunk) ? fullSmooth : chunkCoeff(rate, n);
      glide(smoothPresence_, presenceTarget, smooth);
      glide(smoothDepth_, depthTarget, smooth);
      glide(smoothSag_, sagTarget, smooth);
      glide(smoothBias_, biasTarget, smooth);
      glide(smoothFeedback_, feedbackTarget, smooth);
      glide(smoothMaster_, masterTarget, smooth);
      if constexpr (!Legacy) glide(smoothTubeCharacter_, characterTarget, smooth);

      const double character = Legacy ? 0.0 : smoothTubeCharacter_;
      const double knee = kKnee + character * (profile.knee - kKnee);
      const double tubeHeadroom = 1.0 + character * (profile.headroom - 1.0);
      const double biasSensitivity = 1.0 + character * (profile.biasSensitivity - 1.0);
      const double asymmetry = character * profile.asymmetry;

      const double beta = 0.15 + 0.75 * smoothFeedback_;
      const double loopGain = kOpenLoopGain * beta;
      if (smoothPresence_ != appliedPresence_ || smoothFeedback_ != appliedFeedback_ ||
          smoothDepth_ != appliedDepth_ || rate != appliedPostRate_) {
        setShelf(presence_, feedbackShelfDb(smoothPresence_, loopGain), 3200.0f, rate, true);
        setShelf(depth_, feedbackShelfDb(smoothDepth_, loopGain), 110.0f, rate, false);
        appliedPresence_ = smoothPresence_;
        appliedDepth_ = smoothDepth_;
        appliedFeedback_ = smoothFeedback_;
        appliedPostRate_ = rate;
      }
      if (smoothMaster_ != cachedMaster) {
        drive = std::pow(10.0, 1.8 * smoothMaster_);
        outputScale = 1.0 / std::sqrt(drive);
        cachedMaster = smoothMaster_;
      }
      const double inputScale = drive * (1.0 + loopGain) / kOpenLoopGain;
      const double sagDepth = 0.5 * smoothSag_;
      const double excursionDepth = 0.4 * smoothSag_;
      const double biasStatic = 0.45 * smoothBias_;
      // Presence and Depth can use the linear feedback loop on their own.
      // The power-stage saturation is introduced continuously by the dynamic
      // controls, so moving any control away from exact neutral cannot switch
      // a fully driven nonlinear stage into the signal path at once.
      const double legacyNonlinearAmount = std::max(
          std::max(static_cast<double>(smoothSag_),
                   std::fabs(static_cast<double>(smoothBias_))),
          static_cast<double>(smoothMaster_));
      const double nonlinearAmount = Legacy ? legacyNonlinearAmount
                                            : std::max(legacyNonlinearAmount, character);

      float* s = samples + start;
      for (size_t i = 0; i < n; ++i) {
        const double f0 = depth_.b0 * presence_.b0;
        const double partial = presence_.b0 * depth_.z1 + presence_.z1;
        const double c = s[i] * inputScale - beta * partial;
        const double k = beta * f0;
        const double sagEnv = 0.55 * supplyEnvelope_ + 0.45 * reservoirEnvelope_;
        const double effKnee = (Legacy || character == 0.0) ? kKnee : knee;
        const double headroom = ((Legacy || character == 0.0) ? 1.0 : tubeHeadroom) *
            std::max(kMinHeadroom, 1.0 - sagDepth * sagEnv);
        const double bias = ((Legacy || character == 0.0) ? 1.0 : biasSensitivity) *
            (biasStatic - excursionDepth * sagEnv) +
            ((Legacy || character == 0.0) ? 0.0 : asymmetry);
        const double biasOut = satC2(bias, effKnee);
        const double solved = solveBiasedC2(kOpenLoopGain / headroom, k * headroom,
                                            c, bias, biasOut, effKnee);
        const double normalized = solved - biasOut;
        const double nonlinearY = headroom * normalized;
        const double linearY = kOpenLoopGain * c / (1.0 + kOpenLoopGain * k);
        const double y = linearY + nonlinearAmount * (nonlinearY - linearY);
        const double absNorm = std::fabs(normalized);
        const double conduction = absNorm * (0.65 + 0.35 * std::min(1.5, absNorm));
        supplyEnvelope_ += (conduction - supplyEnvelope_) *
                           (conduction > supplyEnvelope_ ? screenAttack : screenRelease);
        reservoirEnvelope_ += (conduction - reservoirEnvelope_) *
                              (conduction > reservoirEnvelope_ ? reservoirAttack : reservoirRelease);
        presence_.advance(depth_.advance(y));
        s[i] = static_cast<float>(y * outputScale);
      }
    }
  }

  static constexpr size_t kChunk = 32;
  static constexpr double kOpenLoopGain = 10.0;
  static constexpr double kKnee = 0.7;
  // Sag and bias excursion lower the supply ceiling; the loop gain divides by
  // it, so the ceiling keeps a floor instead of collapsing toward zero.
  static constexpr double kMinHeadroom = 1.0e-3;
  static constexpr double kPi = 3.14159265358979323846;
  static constexpr double kQ = 0.7071067811865476;
  static constexpr double kMidPushMaxDb = 9.0;
  static constexpr float kMidPushHz = 750.0f;
  static constexpr double kMidPushQ = 0.8;

  struct Filter {
    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;
    double z1 = 0.0, z2 = 0.0;
    double advance(double x) noexcept {
      const double y = b0 * x + z1;
      z1 = b1 * x - a1 * y + z2;
      z2 = b2 * x - a2 * y;
      return y;
    }
    void reset() noexcept { z1 = z2 = 0.0; }
    void identity() noexcept {
      b0 = 1.0; b1 = b2 = a1 = a2 = 0.0;
      reset();
    }
  };

  void resetLoop() noexcept {
    presence_.identity();
    depth_.identity();
    smoothPresence_ = smoothDepth_ = smoothSag_ = smoothBias_ = 0.0f;
    smoothFeedback_ = smoothMaster_ = 0.0f;
    smoothTubeCharacter_ = 0.0f;
    appliedPresence_ = appliedDepth_ = appliedFeedback_ = 1.0e9f;
    appliedPostRate_ = 0.0;
    supplyEnvelope_ = 0.0;
    reservoirEnvelope_ = 0.0;
  }

  static float clamp01(float x) noexcept { return std::max(0.0f, std::min(1.0f, x)); }
  static float chunkCoeff(double rate, size_t n) noexcept {
    return 1.0f - static_cast<float>(std::exp(-static_cast<double>(n) / (rate * 0.015)));
  }
  static void glide(float& value, float target, float coeff) noexcept {
    value += (target - value) * coeff;
    if (std::fabs(target - value) < 1.0e-4f) value = target;
  }

  // Feedback-path shelf gain that yields `targetDb` of closed-loop shaping:
  // closed loop = (1 + G) / (1 + G * g) relative to the flat response.
  static double feedbackShelfDb(double targetDb, double loopGain) noexcept {
    const double t = std::pow(10.0, targetDb / 20.0);
    double g = ((1.0 + loopGain) / t - 1.0) / loopGain;
    g = std::max(0.02, std::min(50.0, g));
    return 20.0 * std::log10(g);
  }

  // C^2-continuous soft-knee tube saturator:
  //   |u| <= t0: u
  //   |u| >  t0: sign(u) * (t0 + d * (v + v^2) / (1 + v + v^2)), v = (|u| - t0) / d
  // Matches value (t0), 1st derivative (1), and 2nd derivative (0) at |u| = t0.
  static double satC2(double u, double knee) noexcept {
    const double t0 = 0.65 * knee;
    const double a = std::fabs(u);
    if (a <= t0) return u;
    const double d = 1.0 - t0;
    const double v = (a - t0) / d;
    const double vv = v * v;
    const double phi = (v + vv) / (1.0 + v + vv);
    return u < 0.0 ? -(t0 + d * phi) : (t0 + d * phi);
  }

  // Exact biased ZDF solver in the saturator input coordinate u:
  //   u + G * satC2(u, knee) = r,  where G = A * k >= 0, r = A * c + G * biasOut + bias
  // Returns s = satC2(u, knee).
  static double solveBiasedC2(double A, double k, double c, double bias,
                              double biasOut, double knee) noexcept {
    const double G = std::max(0.0, A * k);
    const double r = A * c + G * biasOut + bias;
    const double t0 = 0.65 * knee;
    const double uLin = r / (1.0 + G);
    if (std::fabs(uLin) <= t0) return uLin;
    const double sign = r < 0.0 ? -1.0 : 1.0;
    const double d = 1.0 - t0;
    const double rho = (std::fabs(r) - (1.0 + G) * t0) / d;
    const double bq = 1.0 + G - rho;
    const double disc = std::max(0.0, bq * bq + 4.0 * rho);
    double v = (bq >= 0.0) ? (2.0 * rho) / (bq + std::sqrt(disc))
                           : (-bq + std::sqrt(disc)) * 0.5;
    for (int iter = 0; iter < 4; ++iter) {
      const double vv = v * v;
      const double D = 1.0 + v + vv;
      const double invD = 1.0 / D;
      const double phi = (v + vv) * invD;
      const double dphi = (1.0 + 2.0 * v) * invD * invD;
      const double err = v + G * phi - rho;
      v = std::max(0.0, v - err / (1.0 + G * dphi));
    }
    const double vv = v * v;
    const double phi = (v + vv) / (1.0 + v + vv);
    return sign * (t0 + d * std::min(phi, 1.0));
  }

  static void setHighPass(Filter& f, float frequency, double rate) noexcept {
    const double w0 = 2.0 * kPi * frequency / rate;
    const double c = std::cos(w0), s = std::sin(w0);
    const double alpha = s / (2.0 * kQ), a0 = 1.0 + alpha;
    f.b0 = (1.0 + c) * 0.5 / a0;
    f.b1 = -(1.0 + c) / a0;
    f.b2 = f.b0;
    f.a1 = -2.0 * c / a0;
    f.a2 = (1.0 - alpha) / a0;
  }

  static void setPeak(Filter& f, double gainDb, float frequency, double q,
                      double rate) noexcept {
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w0 = 2.0 * kPi * frequency / rate;
    const double c = std::cos(w0), alpha = std::sin(w0) / (2.0 * q);
    const double a0 = 1.0 + alpha / A;
    f.b0 = (1.0 + alpha * A) / a0;
    f.b1 = -2.0 * c / a0;
    f.b2 = (1.0 - alpha * A) / a0;
    f.a1 = f.b1;
    f.a2 = (1.0 - alpha / A) / a0;
  }

  static void setShelf(Filter& f, double gainDb, float frequency, double rate,
                       bool high) noexcept {
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w0 = 2.0 * kPi * frequency / rate;
    const double c = std::cos(w0), s = std::sin(w0);
    const double alpha = s / (2.0 * kQ);
    const double sqA = 2.0 * std::sqrt(A) * alpha;
    double b0, b1, b2, a0, a1, a2;
    if (high) {
      b0 = A * ((A + 1) + (A - 1) * c + sqA);
      b1 = -2.0 * A * ((A - 1) + (A + 1) * c);
      b2 = A * ((A + 1) + (A - 1) * c - sqA);
      a0 = (A + 1) - (A - 1) * c + sqA;
      a1 = 2.0 * ((A - 1) - (A + 1) * c);
      a2 = (A + 1) - (A - 1) * c - sqA;
    } else {
      b0 = A * ((A + 1) - (A - 1) * c + sqA);
      b1 = 2.0 * A * ((A - 1) - (A + 1) * c);
      b2 = A * ((A + 1) - (A - 1) * c - sqA);
      a0 = (A + 1) + (A - 1) * c + sqA;
      a1 = -2.0 * ((A - 1) + (A + 1) * c);
      a2 = (A + 1) + (A - 1) * c - sqA;
    }
    f.b0 = b0 / a0;
    f.b1 = b1 / a0;
    f.b2 = b2 / a0;
    f.a1 = a1 / a0;
    f.a2 = a2 / a0;
  }

  Filter bright_, inputEq_, midPush_, depth_, presence_;
  float smoothBright_ = 0.0f, smoothInputEq_ = 0.0f, smoothMidPush_ = 0.0f;
  float appliedBright_ = -1.0f, appliedInputEq_ = -1.0f, appliedMidPush_ = -1.0f;
  float smoothPresence_ = 0.0f, smoothDepth_ = 0.0f, smoothSag_ = 0.0f;
  float smoothBias_ = 0.0f, smoothFeedback_ = 0.0f, smoothMaster_ = 0.0f;
  float smoothTubeCharacter_ = 0.0f;
  float appliedPresence_ = 1.0e9f, appliedDepth_ = 1.0e9f, appliedFeedback_ = 1.0e9f;
  double supplyEnvelope_ = 0.0;
  double reservoirEnvelope_ = 0.0;
  double appliedPostRate_ = 0.0;
  double appliedPreRate_ = 0.0;
};

}  // namespace NAMRig
