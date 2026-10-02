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
    for (size_t start = 0; start < count; start += kChunk) {
      const size_t n = std::min(kChunk, count - start);
      const float smooth = chunkCoeff(rate, n);
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

    for (size_t start = 0; start < count; start += kChunk) {
      const size_t n = std::min(kChunk, count - start);
      const float smooth = chunkCoeff(rate, n);
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
      const double drive = std::pow(10.0, 1.8 * smoothMaster_);
      const double inputScale = drive * (1.0 + loopGain) / kOpenLoopGain;
      const double outputScale = 1.0 / std::sqrt(drive);
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
          std::max(static_cast<double>(smoothFeedback_),
                   static_cast<double>(smoothMaster_)));
      const double nonlinearAmount = Legacy ? legacyNonlinearAmount
                                            : std::max(legacyNonlinearAmount, character);
      const double attack = 1.0 - std::exp(-1.0 / (rate * 0.015));
      const double release = 1.0 - std::exp(-1.0 / (rate * 0.220));

      float* s = samples + start;
      for (size_t i = 0; i < n; ++i) {
        const double f0 = depth_.b0 * presence_.b0;
        const double partial = presence_.b0 * depth_.z1 + presence_.z1;
        const double c = s[i] * inputScale - beta * partial;
        const double k = beta * f0;
        double normalized, nonlinearY;
        if (Legacy || character == 0.0) {
          const double headroom = 1.0 - sagDepth * supplyEnvelope_;
          const double bias = biasStatic - excursionDepth * supplyEnvelope_;
          const double biasOut = sat<true>(bias, kKnee);
          const double solved = solve<true>(kOpenLoopGain / headroom, k * headroom,
                                           c + k * headroom * biasOut +
                                               bias * headroom / kOpenLoopGain, kKnee);
          normalized = solved - biasOut;
          nonlinearY = headroom * normalized;
        } else {
          const double headroom = tubeHeadroom * (1.0 - sagDepth * supplyEnvelope_);
          const double bias = biasSensitivity * (biasStatic - excursionDepth * supplyEnvelope_) +
                              asymmetry;
          const double biasOut = sat<false>(bias, knee);
          const double solved = solve<false>(kOpenLoopGain / headroom, k * headroom,
                                            c + k * headroom * biasOut +
                                                bias * headroom / kOpenLoopGain, knee);
          normalized = solved - biasOut;
          nonlinearY = headroom * normalized;
        }
        const double linearY = kOpenLoopGain * c / (1.0 + kOpenLoopGain * k);
        const double y = linearY + nonlinearAmount * (nonlinearY - linearY);
        const double level = std::fabs(normalized);
        supplyEnvelope_ += (level - supplyEnvelope_) *
                           (level > supplyEnvelope_ ? attack : release);
        presence_.advance(depth_.advance(y));
        s[i] = static_cast<float>(y * outputScale);
      }
    }
  }

  static constexpr size_t kChunk = 32;
  static constexpr double kOpenLoopGain = 10.0;
  static constexpr double kKnee = 0.7;
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

  // Compile-time legacy knee retains the original constant-folding arithmetic.
  template <bool Legacy>
  static double sat(double u, double profileKnee) noexcept {
    const double knee = Legacy ? kKnee : profileKnee;
    const double a = std::fabs(u);
    if (a <= knee) return u;
    const double d = 1.0 - knee;
    const double v = a - knee;
    const double w = d * v / (d + v);
    return u < 0.0 ? -(knee + w) : knee + w;
  }

  // Solves y = sat(A * (c - k * y)) for y.
  template <bool Legacy>
  static double solve(double A, double k, double c, double profileKnee) noexcept {
    const double knee = Legacy ? kKnee : profileKnee;
    const double lin = A * c / (1.0 + A * k);
    if (std::fabs(lin) <= knee) return lin;
    const double sign = c < 0.0 ? -1.0 : 1.0;
    c = std::fabs(c);
    const double t = knee, d = 1.0 - knee;
    const double a2 = A * k;
    const double b2 = -(A * (c - k * t + k * d) + d - t);
    const double c2 = d * (A * (c - k * t) - t);
    const double disc = std::max(0.0, b2 * b2 - 4.0 * a2 * c2);
    const double w = 2.0 * c2 / (-b2 + std::sqrt(disc));
    return sign * (t + std::min(w, d));
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
  double appliedPostRate_ = 0.0;
};

}  // namespace NAMRig
