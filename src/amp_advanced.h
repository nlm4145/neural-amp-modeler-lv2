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
    midPush_.reset();
    smoothBright_ = smoothInputEq_ = smoothMidPush_ = 0.0f;
    appliedBright_ = appliedMidPush_ = -1.0f;
    appliedBrightDrive_ = 1.0e9f;
    tightHpfState_ = 0.0;
    lowDetectState_ = 0.0;
    tightEnv_ = 0.0;
  }

  void resetPostAmp(bool preserveTubeCharacter = false) noexcept {
    if (preserveTubeCharacter) {
      const bool powerAlreadyNeutral =
          smoothPresence_ == 0.0f && smoothDepth_ == 0.0f &&
          smoothSag_ == 0.0f && smoothBias_ == 0.0f &&
          smoothFeedback_ == 0.0f && smoothMaster_ == 0.0f;
      if (powerAlreadyNeutral) {
        // Power controls were already neutral; leave the active Tube's live
        // envelopes, grid-blocking state, and DC blocker undisturbed.
        return;
      }
      const float character = smoothTubeCharacter_;
      resetLoop();
      smoothTubeCharacter_ = character;
      return;
    }
    resetLoop();
  }
  void resetTubeCharacter() noexcept { smoothTubeCharacter_ = 0.0f; }
  bool hasTubeCharacter() const noexcept { return smoothTubeCharacter_ > 0.0f; }
  double lastDynamicDamping() const noexcept { return dynamicDamping_; }

  void processPreAmp(float* samples, size_t count, double rate,
                     float brightAmount, float inputEqAmount,
                     float midPushAmount = 0.0f,
                     float ampDriveDb = 0.0f) noexcept {
    const float brightTarget = clamp01(brightAmount * 0.01f);
    const float inputEqTarget = clamp01(inputEqAmount * 0.01f);
    const float midPushTarget = std::isfinite(midPushAmount) ? clamp01(midPushAmount * 0.01f) : 0.0f;
    if (brightTarget <= 0.0f && inputEqTarget <= 0.0f && midPushTarget <= 0.0f &&
        smoothBright_ <= 0.0f && smoothInputEq_ <= 0.0f && smoothMidPush_ <= 0.0f) {
      bright_.reset();
      midPush_.reset();
      tightHpfState_ = 0.0;
      lowDetectState_ = 0.0;
      tightEnv_ = 0.0;
      appliedBright_ = appliedMidPush_ = -1.0f;
      appliedBrightDrive_ = 1.0e9f;
      return;
    }
    if (rate != appliedPreRate_) {
      appliedBright_ = appliedMidPush_ = -1.0f;
      appliedBrightDrive_ = 1.0e9f;
      appliedPreRate_ = rate;
    }
    const float safeDriveDb = std::isfinite(ampDriveDb)
        ? std::clamp(ampDriveDb, -24.0f, 24.0f) : 0.0f;
    const float fullSmooth = chunkCoeff(rate, kChunk);
    const double safeRate = std::max(8000.0, rate);
    const double lowDetectCoeff = 1.0 - std::exp(-2.0 * kPi * 160.0 / safeRate);
    const double tightAttack = 1.0 - std::exp(-1.0 / (safeRate * 0.003));
    const double tightRelease = 1.0 - std::exp(-1.0 / (safeRate * 0.045));

    for (size_t start = 0; start < count; start += kChunk) {
      const size_t n = std::min(kChunk, count - start);
      const float smooth = (n == kChunk) ? fullSmooth : chunkCoeff(rate, n);
      glide(smoothBright_, brightTarget, smooth);
      glide(smoothInputEq_, inputEqTarget, smooth);
      glide(smoothMidPush_, midPushTarget, smooth);

      if (smoothInputEq_ <= 0.0f) {
        tightHpfState_ = 0.0;
        lowDetectState_ = 0.0;
        tightEnv_ = 0.0;
      }
      // Gain-coupled Bright Cap: strongest (+7.5 dB @ 2.6 kHz) at low/unity drive,
      // naturally tapering down to +2.5 dB as Amp Drive increases toward +24 dB.
      if (smoothBright_ != appliedBright_ ||
          std::fabs(safeDriveDb - appliedBrightDrive_) > 0.05f) {
        if (smoothBright_ > 0.0f) {
          const double driveNorm = std::clamp(static_cast<double>(safeDriveDb) / 24.0, 0.0, 1.0);
          const double brightMaxDb = 7.5 - 5.0 * driveNorm;
          const double brightDb = brightMaxDb * static_cast<double>(smoothBright_);
          setShelf(bright_, brightDb, 2600.0f, rate, true);
        } else {
          bright_.reset();
        }
        appliedBright_ = smoothBright_;
        appliedBrightDrive_ = safeDriveDb;
      }
      if (smoothMidPush_ != appliedMidPush_) {
        if (smoothMidPush_ > 0.0f) {
          const double midDb = kMidPushMaxDb * static_cast<double>(smoothMidPush_);
          setPeak(midPush_, midDb, kMidPushHz, kMidPushQ, rate);
        } else {
          midPush_.reset();
        }
        appliedMidPush_ = smoothMidPush_;
      }
      const bool eqOn = smoothInputEq_ > 0.0f;
      const bool brightOn = smoothBright_ > 0.0f;
      const bool midOn = smoothMidPush_ > 0.0f;
      const double eqAmt = static_cast<double>(smoothInputEq_);
      const double baseFc = 40.0 + 240.0 * eqAmt;
      const double tightWet = std::min(1.0, eqAmt * 10.0);
      const double invRate = 1.0 / safeRate;
      float* s = samples + start;
      for (size_t i = 0; i < n; ++i) {
        double x = s[i];
        if (eqOn) {
          // 6 dB/oct passive-style TPT HPF + dynamic palm-mute tightening on < 160 Hz chugs.
          lowDetectState_ += lowDetectCoeff * (x - lowDetectState_);
          const double lowLevel = std::fabs(lowDetectState_);
          tightEnv_ += (lowLevel - tightEnv_) *
                       (lowLevel > tightEnv_ ? tightAttack : tightRelease);
          const double chug = std::clamp((tightEnv_ - 0.04) * 3.0, 0.0, 1.0);
          const double fc = std::min(rate * 0.25, baseFc * (1.0 + 0.46 * chug * eqAmt));
          const double u = kPi * fc * invRate;
          const double g = (u < 0.2) ? (u * (1.0 + (u * u) * (1.0 / 3.0))) : std::tan(u);
          const double k = g / (1.0 + g);
          const double v = (x - tightHpfState_) * k;
          const double lp = v + tightHpfState_;
          tightHpfState_ = lp + v;
          x = x - tightWet * lp;
        }
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
    const double safeRate = std::max(8000.0, rate);
    const double postDcR = std::exp(-2.0 * kPi * 5.0 / safeRate);

    // Calibrated +8 dB internal operating point so loudness-normalized NAM peaks
    // (-12 dBFS) genuinely engage the tube knee while quiet playing stays linear;
    // sane Master curve (+0..+13 dB with <= +4.6 dB small-signal boost); low-weighted
    // + overdrive-driven dual-rail sag preserving initial charged-cap pick snap;
    // symmetric Class AB crossover & grid-current blocking; live NFB collapse &
    // tube plate-resistance damping output.
    constexpr double kNominalBoost = 2.5;
    const double screenAttack = 1.0 - std::exp(-1.0 / (safeRate * 0.014));
    const double screenRelease = 1.0 - std::exp(-1.0 / (safeRate * 0.048));
    const double reservoirAttack = 1.0 - std::exp(-1.0 / (safeRate * 0.045));
    const double reservoirRelease = 1.0 - std::exp(-1.0 / (safeRate * 0.240));
    const double lowWeightCoeff = 1.0 - std::exp(-2.0 * kPi * 220.0 / safeRate);
    const double gridBlockAttack = 1.0 - std::exp(-1.0 / (safeRate * 0.004));
    const double gridBlockRelease = 1.0 - std::exp(-1.0 / (safeRate * 0.035));
    const double dampAttack = 1.0 - std::exp(-1.0 / (safeRate * 0.003));
    const double dampRelease = 1.0 - std::exp(-1.0 / (safeRate * 0.035));

    float cachedMaster = -1.0f;
    double masterDrive = 1.0;
    double totalDrive = kNominalBoost;
    double baseOutputScale = 1.0 / kNominalBoost;

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

      const double character = Legacy ? 0.0 : static_cast<double>(smoothTubeCharacter_);
      const double baseKnee = kKnee + character * (profile.knee - kKnee);
      const double tubeHeadroom = 1.0 + character * (profile.headroom - 1.0);
      const double biasSensitivity = 1.0 + character * (profile.biasSensitivity - 1.0);
      const double asymmetry = character * profile.asymmetry;
      // Pentode (EL34) has higher plate resistance -> lower natural speaker damping
      // than beam tetrode (6L6).
      double tubeRpFactor = 1.0;
      if (tubeProfile == PowerTube::kEL34) {
        tubeRpFactor = 1.0 - 0.22 * character;
      } else if (tubeProfile == PowerTube::k6L6) {
        tubeRpFactor = 1.0 - 0.05 * character;
      }
      // Gentle auto-level matching across tube headroom differences (EL34 0.58 vs 6L6 0.85).
      const double tubeMakeup = 1.0 / std::pow(std::max(0.25, tubeHeadroom), 0.35);

      const double beta = 0.15 + 0.75 * smoothFeedback_;
      const double loopGain = kOpenLoopGain * beta;
      if (smoothPresence_ != appliedPresence_ || smoothFeedback_ != appliedFeedback_ ||
          smoothDepth_ != appliedDepth_ || rate != appliedPostRate_) {
        const double presDb = feedbackShelfDb(smoothPresence_, loopGain);
        const double depDb = feedbackShelfDb(smoothDepth_, loopGain);
        setShelf(presence_, presDb, 3200.0f, rate, true);
        setShelf(depth_, depDb, 110.0f, rate, false);
        appliedPresence_ = smoothPresence_;
        appliedDepth_ = smoothDepth_;
        appliedFeedback_ = smoothFeedback_;
        appliedPostRate_ = rate;
      }
      if (smoothMaster_ != cachedMaster) {
        masterDrive = std::pow(10.0, 0.65 * static_cast<double>(smoothMaster_));
        totalDrive = kNominalBoost * masterDrive;
        baseOutputScale = 1.0 / (kNominalBoost * std::pow(masterDrive, 0.65));
        cachedMaster = smoothMaster_;
      }

      const double outputScale = baseOutputScale * tubeMakeup;
      const double inputScale = totalDrive * (1.0 + loopGain) / kOpenLoopGain;
      const double sagDepth = 0.48 * static_cast<double>(smoothSag_);
      const double hotBias = std::max(0.0, static_cast<double>(smoothBias_));
      const double coldBias = std::max(0.0, -static_cast<double>(smoothBias_));
      const double effKnee = std::max(0.32, baseKnee - 0.16 * hotBias);
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
        const double driveIn = s[i] * inputScale;
        const double c = driveIn - beta * partial;
        const double k = beta * f0;
        const double linearY = kOpenLoopGain * c / (1.0 + kOpenLoopGain * k);

        double y = linearY;
        double satSlope = 1.0;
        if (nonlinearAmount > 1.0e-5) {
          const double sagEnv = 0.55 * supplyEnvelope_ + 0.45 * reservoirEnvelope_;
          const double rawHeadroom = tubeHeadroom * std::max(kMinHeadroom, 1.0 - sagDepth * sagEnv);
          // Continuous ceiling engagement (no dry/wet parallel unclipped spike blend).
          const double effHeadroom = rawHeadroom / std::max(1.0e-4, nonlinearAmount);
          const double bias = biasSensitivity * (0.12 * hotBias - 0.08 * smoothSag_ * sagEnv)
                              + asymmetry;
          const double biasOut = satC2(bias, effKnee);
          double uSolved = 0.0;
          const double solved = solveBiasedC2(kOpenLoopGain / effHeadroom, k * effHeadroom,
                                              c, bias, biasOut, effKnee, &uSolved);
          const double normalized = solved - biasOut;
          double nonlinearY = effHeadroom * normalized;

          // Symmetric Class AB crossover & overdrive grid-current blocking (zero DC).
          const double t0 = 0.65 * effKnee;
          const double odExcess = std::max(0.0, std::fabs(uSolved) - t0);
          gridBlockEnv_ += (std::tanh(odExcess) - gridBlockEnv_) *
                           (odExcess > gridBlockEnv_ ? gridBlockAttack : gridBlockRelease);
          const double coldCrossover = std::min(0.46,
              0.30 * coldBias * biasSensitivity + 0.14 * gridBlockEnv_ * nonlinearAmount);
          if (coldCrossover > 1.0e-6) {
            const double z = nonlinearY / std::max(0.08, 0.14 * rawHeadroom);
            nonlinearY *= 1.0 - coldCrossover / (1.0 + z * z);
          }
          y = nonlinearY;
          satSlope = satC2Deriv(uSolved, effKnee);

          // Low-frequency-weighted + overdrive screen-current dual-rail sag.
          xLow_ += lowWeightCoeff * (driveIn - xLow_);
          const double lowPower = std::fabs(xLow_) / std::max(0.25, rawHeadroom);
          const double rawCurrent = 0.40 * std::fabs(normalized)
                                  + 0.60 * lowPower
                                  + 0.55 * odExcess;
          const double conduction = std::tanh(0.65 * rawCurrent);
          supplyEnvelope_ += (conduction - supplyEnvelope_) *
                             (conduction > supplyEnvelope_ ? screenAttack : screenRelease);
          reservoirEnvelope_ += (conduction - reservoirEnvelope_) *
                                (conduction > reservoirEnvelope_ ? reservoirAttack : reservoirRelease);
        } else {
          // Decay dynamic states smoothly when operating purely linearly (Presence/Depth only).
          supplyEnvelope_ *= (1.0 - screenRelease);
          reservoirEnvelope_ *= (1.0 - reservoirRelease);
          gridBlockEnv_ *= (1.0 - gridBlockRelease);
          xLow_ *= (1.0 - lowWeightCoeff);
        }

        // Track live NFB collapse & tube plate resistance for SpeakerDynamics damping.
        const double targetDamp = std::clamp(tubeRpFactor * (0.30 + 0.70 * satSlope), 0.25, 1.0);
        dynamicDamping_ += (targetDamp - dynamicDamping_) *
                           (targetDamp < dynamicDamping_ ? dampAttack : dampRelease);

        presence_.advance(depth_.advance(y));
        const double nonlinRes = y - linearY;
        const double resDc = nonlinRes - postDcIn_ + postDcR * postDcOut_;
        postDcIn_ = nonlinRes;
        postDcOut_ = resDc;
        const double yOut = linearY + resDc;
        s[i] = static_cast<float>(yOut * outputScale);
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
    xLow_ = 0.0;
    gridBlockEnv_ = 0.0;
    dynamicDamping_ = 1.0;
    postDcIn_ = 0.0;
    postDcOut_ = 0.0;
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

  static double satC2Deriv(double u, double knee) noexcept {
    const double t0 = 0.65 * knee;
    const double a = std::fabs(u);
    if (a <= t0) return 1.0;
    const double d = 1.0 - t0;
    const double v = (a - t0) / d;
    const double denom = 1.0 + v + v * v;
    return (1.0 + 2.0 * v) / (denom * denom);
  }

  // Exact biased ZDF solver in the saturator input coordinate u:
  //   u + G * satC2(u, knee) = r,  where G = A * k >= 0, r = A * c + G * biasOut + bias
  // Returns s = satC2(u, knee), optionally writing solved u to outU.
  static double solveBiasedC2(double A, double k, double c, double bias,
                              double biasOut, double knee,
                              double* outU = nullptr) noexcept {
    const double G = std::max(0.0, A * k);
    const double r = A * c + G * biasOut + bias;
    const double t0 = 0.65 * knee;
    const double uLin = r / (1.0 + G);
    if (std::fabs(uLin) <= t0) {
      if (outU) *outU = uLin;
      return uLin;
    }
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
    if (outU) *outU = sign * (t0 + d * v);
    const double vv = v * v;
    const double phi = (v + vv) / (1.0 + v + vv);
    return sign * (t0 + d * std::min(phi, 1.0));
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

  Filter bright_, midPush_, depth_, presence_;
  float smoothBright_ = 0.0f, smoothInputEq_ = 0.0f, smoothMidPush_ = 0.0f;
  float appliedBright_ = -1.0f, appliedMidPush_ = -1.0f;
  float appliedBrightDrive_ = 1.0e9f;
  float smoothPresence_ = 0.0f, smoothDepth_ = 0.0f, smoothSag_ = 0.0f;
  float smoothBias_ = 0.0f, smoothFeedback_ = 0.0f, smoothMaster_ = 0.0f;
  float smoothTubeCharacter_ = 0.0f;
  float appliedPresence_ = 1.0e9f, appliedDepth_ = 1.0e9f, appliedFeedback_ = 1.0e9f;
  double supplyEnvelope_ = 0.0;
  double reservoirEnvelope_ = 0.0;
  double tightHpfState_ = 0.0;
  double lowDetectState_ = 0.0;
  double tightEnv_ = 0.0;
  double xLow_ = 0.0;
  double gridBlockEnv_ = 0.0;
  double dynamicDamping_ = 1.0;
  double postDcIn_ = 0.0;
  double postDcOut_ = 0.0;
  double appliedPostRate_ = 0.0;
  double appliedPreRate_ = 0.0;
};

}  // namespace NAMRig
