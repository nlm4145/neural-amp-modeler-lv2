#pragma once

#include <algorithm>
#include <cctype>
#include <cmath>
#include <complex>
#include <cstddef>
#include <cstring>

namespace NAMRig {

// Optional speaker-load and excursion response between the amp and cabinet.
// A NAM capture normally includes its original load interaction, so profile 0
// is an exact bypass. Other profiles provide generic, non-branded load families.
//
// The impedance curve has two parts: the low mechanical resonance and the
// rising voice-coil inductance above roughly 1.5 kHz. A tube output stage
// follows that curve in proportion to its output impedance, so the power amp's
// negative feedback (damping) scales both parts down.
class SpeakerDynamics {
 public:
  static constexpr int kCaptured = 0;
  static constexpr int kAuto = 1;
  static constexpr int kResistive = 2;
  static constexpr int kOpenBack = 3;
  static constexpr int kVintageAlnico = 4;
  static constexpr int kUK412 = 5;
  static constexpr int kModern412 = 6;
  static constexpr int kBass = 7;
  static constexpr int kProfileCount = 8;
  static constexpr int kMatchCabA = kProfileCount;
  static constexpr int kProfileBCount = kProfileCount + 1;

  static int clampProfile(int profile) noexcept {
    return std::max(kCaptured, std::min(kBass, profile));
  }

  static int clampProfileB(int profile) noexcept {
    return std::max(kCaptured, std::min(kMatchCabA, profile));
  }

  static const char* profileName(int profile) noexcept {
    switch (clampProfile(profile)) {
      case kCaptured: return "Captured / Off";
      case kAuto: return "Auto";
      case kResistive: return "Resistive";
      case kOpenBack: return "Open Back";
      case kVintageAlnico: return "Vintage Alnico";
      case kUK412: return "UK 4x12";
      case kModern412: return "Modern 4x12";
      case kBass: return "Bass";
      default: return "Unknown";
    }
  }

  static const char* profileBName(int profile) noexcept {
    profile = clampProfileB(profile);
    if (profile == kMatchCabA) return "Match Cab A";
    return profileName(profile);
  }

  static const char* profileDescription(int profile) noexcept {
    switch (clampProfile(profile)) {
      case kCaptured:
        return "Captured / Off — Exact bypass. Preserves the original speaker load and interaction already present in the NAM model without adding reactive impedance or cone dynamics.";
      case kAuto:
        return "Auto — Automatically detects and selects a matching reactive speaker load based on the loaded Cabinet A impulse response or model name. Defaults to Resistive if unrecognized.";
      case kResistive:
        return "Resistive — Flat resistive dummy load (attenuator style). Nearly flat impedance with minimal 95 Hz resonance and gentle 2.5 kHz inductive rise for transparent, uncolored dynamic response.";
      case kOpenBack:
        return "Open Back — American combo-style open-back cabinet (1x12 or 2x12). Resonant peak at 92 Hz, loose excursion bloom, longer compression decay, and open high-frequency chime above 1.8 kHz.";
      case kVintageAlnico:
        return "Vintage Alnico — British vintage alnico magnet drivers (Celestion Blue/Gold/Cream). Warm, pronounced cone breakup and compression, 105 Hz resonance, and rich upper-mid inductive rise at 1.6 kHz.";
      case kUK412:
        return "UK 4x12 — Classic British 4x12 closed-back stack with ceramic greenbacks (Marshall 1960). Strong 118 Hz resonance, punchy mid-bass bark, quick excursion response, and 2.0 kHz inductance rise.";
      case kModern412:
        return "Modern 4x12 — Oversized American closed-back 4x12 with Vintage 30s (Rectifier style). Deep 82 Hz resonance, heavy sub-bass thump, tight excursion control, and 2.2 kHz presence bite.";
      case kBass:
        return "Bass — Heavyweight multi-driver bass enclosure (8x10, 4x10, 1x15). Deep 58 Hz low-end resonance, massive 48 Hz sub-bass thump, extended excursion release, and subdued top-end response.";
      default:
        return "";
    }
  }

  // Whole-token matching on the file name: a token is a maximal run of
  // letters and digits, compared case-insensitively.
  static int profileFromCabPath(const char* path) noexcept {
    const char* name = path ? path : "";
    for (const char* p = name; *p; ++p)
      if (*p == '/' || *p == '\\') name = p + 1;
    const auto has = [&](const char* term) {
      const size_t needleLength = std::strlen(term);
      const char* start = name;
      while (*start) {
        while (*start && !std::isalnum(static_cast<unsigned char>(*start))) ++start;
        const char* end = start;
        while (*end && std::isalnum(static_cast<unsigned char>(*end))) ++end;
        if (static_cast<size_t>(end - start) == needleLength) {
          size_t i = 0;
          while (i < needleLength &&
                 std::tolower(static_cast<unsigned char>(start[i])) ==
                     std::tolower(static_cast<unsigned char>(term[i])))
            ++i;
          if (i == needleLength) return true;
        }
        start = end;
      }
      return false;
    };
    if (has("alnico") || has("blue") || has("gold") || has("cream") || has("creamback"))
      return kVintageAlnico;
    if (has("bass") || has("8x10") || has("6x10") || has("4x10") || has("1x15"))
      return kBass;
    if (has("mesa") || has("recto") || has("rectifier") || has("oversized") ||
        has("v30") || has("vintage30") || has("modern412") || has("modern"))
      return kModern412;
    if (has("marshall") || has("plexi") || has("greenback") || has("g12m") ||
        has("g12h") || has("g12t75") || has("uk412") || has("1960"))
      return kUK412;
    if (has("openback") || has("open") || has("combo") || has("deluxe") ||
        has("twin") || has("1x12") || has("2x12"))
      return kOpenBack;
    return kResistive;
  }

  void reset() noexcept {
    resonance_.reset();
    thump_.reset();
    inductance_.reset();
    excursionLow_ = excursion_ = driveLow_ = 0.0;
    resetBreakupStates();
    smoothedDrive_ = smoothedCompression_ = smoothedThump_ = 0.0;
    smoothedResonance_ = smoothedDamping_ = 0.0;
    profile_ = kCaptured;
    sampleRate_ = 0.0;
  }

  void bypassDamping() noexcept { smoothedDamping_ = 0.0; }

  // Quiet-signal magnitude (dB) of the load filters at `hz`, as process() runs
  // them once the smoothers settle: resonance, inductance and thump blended by
  // their amounts (0..100) and the power amp's damping (0..1). Excursion
  // compression and drive depend on level and are excluded. Profiles 0 and 1
  // (Auto must be resolved first) return 0 dB.
  static double responseDb(int profile, double hz, double sampleRate,
                           float thumpAmount, float resonanceAmount,
                           float dampingAmount) noexcept {
    profile = clampProfile(profile);
    if (profile == kCaptured || profile == kAuto) return 0.0;
    sampleRate = std::max(8000.0, sampleRate);
    const Profile& p = kProfiles_[profile];
    Biquad resonance, thump, inductance;
    setPeaking(resonance, p.resonanceHz, p.resonanceDb, p.resonanceQ, sampleRate);
    setPeaking(thump, p.thumpHz, p.thumpDb, p.thumpQ, sampleRate);
    setHighShelf(inductance, std::min(p.inductanceHz, sampleRate * 0.2), p.inductanceDb,
                 sampleRate);
    const double loadScale = clamp01(resonanceAmount * 0.01f) * (1.0 - 0.6 * clamp01(dampingAmount));
    const double thumpWet = clamp01(thumpAmount * 0.01f);
    const std::complex<double> z1 = std::polar(1.0, -2.0 * kPi * hz / sampleRate);
    const auto blend = [&](const Biquad& f, double wet) {
      const std::complex<double> h = (f.b0 + f.b1 * z1 + f.b2 * z1 * z1) /
                                     (1.0 + f.a1 * z1 + f.a2 * z1 * z1);
      return 1.0 + wet * (h - 1.0);
    };
    const double magnitude = std::abs(blend(resonance, loadScale) * blend(inductance, loadScale) *
                                      blend(thump, thumpWet));
    return 20.0 * std::log10(std::max(1.0e-12, magnitude));
  }

  void process(float* samples, size_t count, double sampleRate, int profile,
               float driveAmount, float compressionAmount, float thumpAmount,
               float resonanceAmount, float dampingAmount) noexcept {
    if (!samples || count == 0) return;
    profile = clampProfile(profile);
    if (profile == kCaptured || profile == kAuto) {
      if (profile_ != kCaptured) reset();
      return;
    }
    sampleRate = std::max(8000.0, sampleRate);
    if (profile != profile_ || std::fabs(sampleRate - sampleRate_) > 0.5)
      configure(profile, sampleRate);

    const Profile& p = kProfiles_[profile];
    const double smooth = 1.0 - std::exp(-1.0 / (sampleRate * 0.010));
    const double driveTarget = clamp01(driveAmount * 0.01f);
    const double compressionTarget = clamp01(compressionAmount * 0.01f);
    const double thumpTarget = clamp01(thumpAmount * 0.01f);
    const double resonanceTarget = clamp01(resonanceAmount * 0.01f);
    const double dampingTarget = clamp01(dampingAmount);
    const double excursionCoeff = 1.0 - std::exp(-2.0 * kPi * p.excursionHz / sampleRate);
    // ZDF/TPT Linkwitz-Riley LR2 (-12 dB/oct) crossover for the excursion band.
    const double driveFc = std::min(4.0 * p.excursionHz, sampleRate * 0.2);
    const double driveTan = std::tan(kPi * driveFc / sampleRate);
    const double lrK = driveTan / (1.0 + driveTan);
    // ZDF SVF bandpass for upper-mid cone modal breakup.
    const double coneFc = std::min(p.coneBreakupHz, sampleRate * 0.25);
    const double coneG = std::tan(kPi * coneFc / sampleRate);
    const double coneK = 1.0 / std::max(0.5, p.coneBreakupQ);
    const double coneA1 = 1.0 / (1.0 + coneG * (coneG + coneK));
    const double coneA2 = coneG * coneA1;
    const double coneA3 = coneG * coneA2;
    const double dcR = std::exp(-2.0 * kPi * 5.0 / sampleRate);
    const double attack = 1.0 - std::exp(-1.0 / (sampleRate * p.attackSeconds));
    const double release = 1.0 - std::exp(-1.0 / (sampleRate * p.releaseSeconds));

    for (size_t i = 0; i < count; ++i) {
      smoothedDrive_ += (driveTarget - smoothedDrive_) * smooth;
      smoothedCompression_ += (compressionTarget - smoothedCompression_) * smooth;
      smoothedThump_ += (thumpTarget - smoothedThump_) * smooth;
      smoothedResonance_ += (resonanceTarget - smoothedResonance_) * smooth;
      smoothedDamping_ += (dampingTarget - smoothedDamping_) * smooth;

      // Filters run at each profile's maximum response; wet interpolation
      // gives smooth controls without recalculating coefficients per sample.
      const double loadScale = smoothedResonance_ * (1.0 - 0.6 * smoothedDamping_);
      const double resonanceWet =
          loadScale / (1.0 + 2.0 * p.compression * smoothedCompression_ * excursion_);
      const double dry = samples[i];
      const double resonant = resonance_.process(dry);
      double x = dry + resonanceWet * (resonant - dry);
      const double inductive = inductance_.process(x);
      x += loadScale * (inductive - x);
      const double thumped = thump_.process(x);
      x += smoothedThump_ * (thumped - x);

      excursionLow_ += excursionCoeff * (x - excursionLow_);
      const double level = std::fabs(excursionLow_);
      excursion_ += (level - excursion_) * (level > excursion_ ? attack : release);
      x *= 1.0 / (1.0 + p.compression * smoothedCompression_ * excursion_);

      if (driveTarget > 1.0e-6 || smoothedDrive_ > 1.0e-6) crossoverEngaged_ = true;
      if (crossoverEngaged_) {
        // LR2 split: lp2 and negHp2 (= ap1 - lp2 = -HP_LR2) sum to unity-gain allpass ap1.
        const double v1 = (x - lrState1_) * lrK;
        const double lp1 = v1 + lrState1_;
        lrState1_ = lp1 + v1;
        const double v2 = (lp1 - lrState2_) * lrK;
        driveLow_ = v2 + lrState2_;
        lrState2_ = driveLow_ + v2;
        const double negHp2 = (2.0 * lp1 - x) - driveLow_;

        double nonlinearResidual = 0.0;
        if (smoothedDrive_ > 1.0e-6) {
          const double gain = 1.0 + p.drive * smoothedDrive_;
          const double bias = p.asymmetry * smoothedDrive_;
          double lowResStep = 0.0;
          if (bias <= 1.0e-12 && std::fabs(driveLow_ - prevDriveLow_) < 1.0e-6) {
            const double rdSteady = sigmoid(driveLow_ * gain) / gain - driveLow_;
            lowResStep = 0.25 * prevLowResidual_ + 0.75 * rdSteady;
            prevDriveLow_ = driveLow_;
            prevLowResidual_ = rdSteady;
          } else {
            lowResStep = evalAdaa2xStep(driveLow_, prevDriveLow_, prevLowResidual_, gain, bias);
          }
          const double lowResidual = p.saturationMix * smoothedDrive_ * lowResStep;

          // Keep the upper-mid cone breakup path phase-aligned with the LR2 allpass sum.
          const double xAfterLow = (driveLow_ + negHp2) + lowResidual;
          const double svfV3 = xAfterLow - coneIc2_;
          const double svfV1 = coneA1 * coneIc1_ + coneA2 * svfV3;
          const double svfV2 = coneIc2_ + coneA2 * coneIc1_ + coneA3 * svfV3;
          coneIc1_ = 2.0 * svfV1 - coneIc1_;
          coneIc2_ = 2.0 * svfV2 - coneIc2_;
          const double coneBand = coneK * svfV1;

          const double coneGain = 1.0 + p.coneBreakupDrive * smoothedDrive_;
          const double coneBias = 0.4 * bias;
          const double coneResidual = p.coneBreakupMix * smoothedDrive_ *
              evalAdaa2xStep(coneBand, prevConeBand_, prevConeResidual_, coneGain, coneBias);

          nonlinearResidual = lowResidual + coneResidual;
        } else {
          prevDriveLow_ = driveLow_;
          prevLowResidual_ = 0.0;
          prevConeBand_ = prevConeResidual_ = 0.0;
          coneIc1_ = coneIc2_ = 0.0;
        }

        // Block DC only on the asymmetric nonlinear residual.
        const double dcBalanced = nonlinearResidual - dcPrevIn_ + dcR * dcPrevOut_;
        dcPrevIn_ = nonlinearResidual;
        dcPrevOut_ = dcBalanced;
        x = (driveLow_ + negHp2) + dcBalanced;

        if (driveTarget <= 1.0e-6 && smoothedDrive_ <= 1.0e-6 && std::fabs(x) < 1.0e-6 &&
            std::fabs(lrState1_) < 1.0e-6 && std::fabs(lrState2_) < 1.0e-6 &&
            std::fabs(dcPrevOut_) < 1.0e-6) {
          resetBreakupStates();
        }
      }
      samples[i] = static_cast<float>(x);
    }
  }

 private:
  struct Biquad {
    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;
    double z1 = 0.0, z2 = 0.0;
    double process(double x) noexcept {
      const double y = b0 * x + z1;
      z1 = b1 * x - a1 * y + z2;
      z2 = b2 * x - a2 * y;
      return y;
    }
    void reset() noexcept { z1 = z2 = 0.0; }
  };

  struct Profile {
    double resonanceHz, resonanceDb, resonanceQ;
    double thumpHz, thumpDb, thumpQ;
    double inductanceHz, inductanceDb;
    double excursionHz, drive, saturationMix, compression;
    double attackSeconds, releaseSeconds;
    double asymmetry;
    double coneBreakupHz, coneBreakupQ, coneBreakupMix, coneBreakupDrive;
  };

  static constexpr Profile kProfiles_[kProfileCount] = {
      // 0. Captured / Off: exact bypass, no added load or excursion response
      {80, 0, .7, 90, 0, .7, 2000, 0, 90, 0, 0, 0, .004, .080, 0.0, 1600, 2.5, 0.0, 0.0},
      // 1. Auto: resolved dynamically from the cabinet IR path (defaults to Resistive)
      {80, 0, .7, 90, 0, .7, 2000, 0, 90, 0, 0, 0, .004, .080, 0.0, 1600, 2.5, 0.0, 0.0},
      // 2. Resistive: flat attenuator dummy load; minimal 95 Hz resonance, 2.5 kHz inductance
      {95, .35, .60, 82, .25, .55, 2500, 1.0, 90, 1.1, .10, .35, .003, .060, 0.04, 1700, 2.8, 0.05, 0.8},
      // 3. Open Back: 1x12/2x12 combo; 92 Hz resonance, loose bloom, 1.8 kHz open chime
      {92, 2.0, .66, 72, 1.8, .58, 1800, 3.5, 76, 2.0, .22, .90, .006, .160, 0.24, 1650, 2.5, 0.22, 1.3},
      // 4. Vintage Alnico: Blue/Gold/Cream; 105 Hz resonance, warm cone breakup, 1.6 kHz rise
      {105, 2.4, .78, 88, 1.5, .65, 1600, 4.5, 92, 2.8, .32, 1.25, .010, .220, 0.28, 1550, 2.5, 0.28, 1.5},
      // 5. UK 4x12: Greenback 1960 stack; strong 118 Hz bark, punchy thump, 2.0 kHz inductance
      {118, 3.0, .95, 105, 1.8, .75, 2000, 3.5, 110, 2.5, .28, 1.05, .005, .110, 0.18, 1600, 2.5, 0.24, 1.4},
      // 6. Modern 4x12: Oversized Rectifier V30; deep 82 Hz resonance, tight thump, 2.2 kHz bite
      {82, 2.5, .82, 68, 2.3, .72, 2200, 3.0, 82, 2.2, .24, .78, .003, .075, 0.10, 1700, 2.6, 0.16, 1.1},
      // 7. Bass: Multi-driver bass cab (8x10/4x10/1x15); 58 Hz sub resonance, 48 Hz thump
      {58, 2.1, .72, 48, 2.5, .65, 1500, 2.0, 55, 1.5, .16, .62, .008, .240, 0.12, 1200, 2.4, 0.12, 1.0},
  };

  static constexpr double kPi = 3.14159265358979323846;
  static double clamp01(double x) noexcept { return std::max(0.0, std::min(1.0, x)); }
  static double sigmoid(double x) noexcept { return x / std::sqrt(1.0 + x * x); }
  static double asymResidual(double x, double gain, double bias, double sig0,
                             double deriv0) noexcept {
    if (bias <= 1.0e-12) return sigmoid(x * gain) / gain - x;
    return (sigmoid(x * gain + bias) - sig0) / (gain * deriv0) - x;
  }
  // Exact 1st-order antiderivative of asymResidual(x) for alias-suppressed waveshaping.
  static double asymAntiderivativeResidual(double x, double gain, double bias, double sig0,
                                           double deriv0) noexcept {
    if (bias <= 1.0e-12) return std::sqrt(1.0 + (x * gain) * (x * gain)) / (gain * gain) - 0.5 * x * x;
    const double u = x * gain + bias;
    const double prim = std::sqrt(1.0 + u * u) / gain - sig0 * x;
    return prim / (gain * deriv0) - 0.5 * x * x;
  }
  static double evalAdaaResidual(double xPrev, double xCur, double gain, double bias,
                                 double sig0, double deriv0) noexcept {
    const double dx = xCur - xPrev;
    if (std::fabs(dx) < 1.0e-6)
      return asymResidual(0.5 * (xPrev + xCur), gain, bias, sig0, deriv0);
    return (asymAntiderivativeResidual(xCur, gain, bias, sig0, deriv0) -
            asymAntiderivativeResidual(xPrev, gain, bias, sig0, deriv0)) / dx;
  }
  // 2x midpoint-oversampled ADAA1 step with [0.25, 0.5, 0.25] residual decimation.
  static double evalAdaa2xStep(double xCur, double& prevX, double& prevResidual,
                               double gain, double bias) noexcept {
    const double sig0 = bias > 1.0e-12 ? sigmoid(bias) : 0.0;
    const double deriv0 = bias > 1.0e-12 ? std::pow(1.0 + bias * bias, -1.5) : 1.0;
    const double xMid = 0.5 * (prevX + xCur);
    const double rMid = evalAdaaResidual(prevX, xMid, gain, bias, sig0, deriv0);
    const double rCur = evalAdaaResidual(xMid, xCur, gain, bias, sig0, deriv0);
    const double out = 0.25 * prevResidual + 0.5 * rMid + 0.25 * rCur;
    prevX = xCur;
    prevResidual = rCur;
    return out;
  }
  static void setPeaking(Biquad& f, double hz, double gainDb, double q,
                         double rate) noexcept {
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w = 2.0 * kPi * hz / rate;
    const double c = std::cos(w), s = std::sin(w);
    const double alpha = s / (2.0 * q), a0 = 1.0 + alpha / A;
    f.b0 = (1.0 + alpha * A) / a0;
    f.b1 = -2.0 * c / a0;
    f.b2 = (1.0 - alpha * A) / a0;
    f.a1 = -2.0 * c / a0;
    f.a2 = (1.0 - alpha / A) / a0;
  }
  static void setHighShelf(Biquad& f, double hz, double gainDb, double rate) noexcept {
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w = 2.0 * kPi * hz / rate;
    const double c = std::cos(w), s = std::sin(w);
    const double alpha = s / (2.0 * 0.7071067811865476);
    const double sqA = 2.0 * std::sqrt(A) * alpha;
    const double a0 = (A + 1) - (A - 1) * c + sqA;
    f.b0 = A * ((A + 1) + (A - 1) * c + sqA) / a0;
    f.b1 = -2.0 * A * ((A - 1) + (A + 1) * c) / a0;
    f.b2 = A * ((A + 1) + (A - 1) * c - sqA) / a0;
    f.a1 = 2.0 * ((A - 1) - (A + 1) * c) / a0;
    f.a2 = ((A + 1) - (A - 1) * c - sqA) / a0;
  }
  void resetBreakupStates() noexcept {
    crossoverEngaged_ = false;
    lrState1_ = lrState2_ = 0.0;
    driveLow_ = 0.0;
    prevDriveLow_ = prevLowResidual_ = 0.0;
    coneIc1_ = coneIc2_ = 0.0;
    prevConeBand_ = prevConeResidual_ = 0.0;
    dcPrevIn_ = dcPrevOut_ = 0.0;
  }

  void configure(int profile, double rate) noexcept {
    profile_ = profile;
    sampleRate_ = rate;
    resonance_.reset();
    thump_.reset();
    inductance_.reset();
    excursionLow_ = excursion_ = 0.0;
    resetBreakupStates();
    const Profile& p = kProfiles_[profile_];
    setPeaking(resonance_, p.resonanceHz, p.resonanceDb, p.resonanceQ, rate);
    setPeaking(thump_, p.thumpHz, p.thumpDb, p.thumpQ, rate);
    setHighShelf(inductance_, std::min(p.inductanceHz, rate * 0.2), p.inductanceDb, rate);
  }

  int profile_ = kCaptured;
  double sampleRate_ = 0.0;
  Biquad resonance_, thump_, inductance_;
  double excursionLow_ = 0.0, excursion_ = 0.0, driveLow_ = 0.0;
  double lrState1_ = 0.0, lrState2_ = 0.0;
  double prevDriveLow_ = 0.0, prevLowResidual_ = 0.0;
  double coneIc1_ = 0.0, coneIc2_ = 0.0;
  double prevConeBand_ = 0.0, prevConeResidual_ = 0.0;
  double dcPrevIn_ = 0.0, dcPrevOut_ = 0.0;
  bool crossoverEngaged_ = false;
  double smoothedDrive_ = 0.0, smoothedCompression_ = 0.0;
  double smoothedThump_ = 0.0, smoothedResonance_ = 0.0, smoothedDamping_ = 0.0;
};

}  // namespace NAMRig
