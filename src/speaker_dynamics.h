#pragma once

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstddef>
#include <cstring>

namespace NAMRig {

// Optional speaker-load and excursion response between the amp and cabinet.
// A NAM capture normally includes its original load interaction, so profile 0
// is an exact bypass. Other profiles provide generic, non-branded load families.
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

  static int clampProfile(int profile) noexcept {
    return std::max(kCaptured, std::min(kBass, profile));
  }

  static int profileFromCabPath(const char* path) noexcept {
    const auto has = [&](const char* term) {
      if (!path || !term) return false;
      const size_t needleLength = std::strlen(term);
      for (const char* start = path; *start; ++start) {
        size_t i = 0;
        while (i < needleLength && start[i] &&
               std::tolower(static_cast<unsigned char>(start[i])) ==
                   std::tolower(static_cast<unsigned char>(term[i])))
          ++i;
        if (i == needleLength) return true;
      }
      return false;
    };
    // Specific speaker construction wins over cabinet geometry.
    if (has("alnico") || has("blue") || has("gold") || has("cream"))
      return kVintageAlnico;
    if (has("bass") || has("8x10") || has("6x10"))
      return kBass;
    if (has("mesa") || has("recto") || has("oversized") || has("v30") ||
        has("modern412") || has("modern-4x12"))
      return kModern412;
    if (has("marshall") || has("plexi") || has("greenback") || has("g12m") ||
        has("g12h") || has("uk412") || has("uk-4x12"))
      return kUK412;
    if (has("openback") || has("open-back") || has("open_back") || has("combo") ||
        has("1x12-open") || has("2x12-open"))
      return kOpenBack;
    return kResistive;
  }

  void reset() noexcept {
    resonance_.reset();
    thump_.reset();
    excursion_ = 0.0;
    smoothedDrive_ = smoothedCompression_ = smoothedThump_ = smoothedResonance_ = 0.0;
    profile_ = kCaptured;
    sampleRate_ = 0.0;
  }

  void process(float* samples, size_t count, double sampleRate, int profile,
               float driveAmount, float compressionAmount, float thumpAmount,
               float resonanceAmount) noexcept {
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
    const double excursionCoeff = 1.0 - std::exp(-2.0 * kPi * p.excursionHz / sampleRate);
    const double attack = 1.0 - std::exp(-1.0 / (sampleRate * p.attackSeconds));
    const double release = 1.0 - std::exp(-1.0 / (sampleRate * p.releaseSeconds));

    for (size_t i = 0; i < count; ++i) {
      smoothedDrive_ += (driveTarget - smoothedDrive_) * smooth;
      smoothedCompression_ += (compressionTarget - smoothedCompression_) * smooth;
      smoothedThump_ += (thumpTarget - smoothedThump_) * smooth;
      smoothedResonance_ += (resonanceTarget - smoothedResonance_) * smooth;

      // Filters are configured once at each profile's maximum response. Wet
      // interpolation gives smooth controls without recalculating pow/cos in
      // the audio loop (especially important in a 768 kHz True-8x domain).
      const double dry = samples[i];
      const double resonant = resonance_.process(dry);
      double x = dry + smoothedResonance_ * (resonant - dry);
      const double thumped = thump_.process(x);
      x += smoothedThump_ * (thumped - x);

      excursionLow_ += excursionCoeff * (x - excursionLow_);
      const double level = std::fabs(excursionLow_);
      excursion_ += (level - excursion_) * (level > excursion_ ? attack : release);
      x *= 1.0 / (1.0 + p.compression * smoothedCompression_ * excursion_);

      if (smoothedDrive_ > 1.0e-6) {
        const double drive = 1.0 + p.drive * smoothedDrive_;
        const double saturated = fastTanh(x * drive) / fastTanh(drive);
        const double mix = p.saturationMix * smoothedDrive_;
        x += mix * (saturated - x);
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
    double excursionHz, drive, saturationMix, compression;
    double attackSeconds, releaseSeconds;
  };

  static constexpr Profile kProfiles_[kProfileCount] = {
      {80, 0, .7, 90, 0, .7, 90, 0, 0, 0, .004, .080},
      {80, 0, .7, 90, 0, .7, 90, 0, 0, 0, .004, .080},
      {95, .35, .60, 82, .25, .55, 90, 1.1, .10, .35, .003, .060},
      {92, 2.0, .66, 72, 1.8, .58, 76, 2.0, .22, .90, .006, .160},
      {105, 2.4, .78, 88, 1.5, .65, 92, 2.8, .32, 1.25, .010, .220},
      {118, 3.0, .95, 105, 1.8, .75, 110, 2.5, .28, 1.05, .005, .110},
      {82, 2.5, .82, 68, 2.3, .72, 82, 2.2, .24, .78, .003, .075},
      {58, 2.1, .72, 48, 2.5, .65, 55, 1.5, .16, .62, .008, .240},
  };

  static constexpr double kPi = 3.14159265358979323846;
  static double clamp01(double x) noexcept { return std::max(0.0, std::min(1.0, x)); }
  static double fastTanh(double x) noexcept {
    x = std::max(-3.0, std::min(3.0, x));
    const double x2 = x * x;
    return x * (27.0 + x2) / (27.0 + 9.0 * x2);
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
  void configure(int profile, double rate) noexcept {
    profile_ = profile;
    sampleRate_ = rate;
    resonance_.reset();
    thump_.reset();
    excursionLow_ = excursion_ = 0.0;
    const Profile& p = kProfiles_[profile_];
    setPeaking(resonance_, p.resonanceHz, p.resonanceDb, p.resonanceQ, rate);
    setPeaking(thump_, p.thumpHz, p.thumpDb, p.thumpQ, rate);
  }

  int profile_ = kCaptured;
  double sampleRate_ = 0.0;
  Biquad resonance_, thump_;
  double excursionLow_ = 0.0, excursion_ = 0.0;
  double smoothedDrive_ = 0.0, smoothedCompression_ = 0.0;
  double smoothedThump_ = 0.0, smoothedResonance_ = 0.0;
};

}  // namespace NAMRig
