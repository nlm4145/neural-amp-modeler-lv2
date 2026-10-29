#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace NAMRig {

// Tube Screamer-style overdrive at the front of Pre-Amp Tonal Sculpt, ahead of
// Amp Drive, like a pedal in front of the amp. It runs in the amp's True
// domain, so the clipper is oversampled with the capture.
//
// The TS9 gain stage is a non-inverting op-amp with a diode pair across its
// feedback network. The clean input reaches the output at unity, and only the
// feedback branch clips:
//
//   y = tone(x + clip(g * bp(x))) * level
//
// bp is the 720 Hz high-pass (4.7k / 47n) and the feedback-cap low-pass
// (51p across 51k + Drive), g = (51k + Drive) / 4.7k. Bass never reaches the
// clipper, which is why a TS tightens the amp and keeps the pick attack.
// Tone is a 6 dB/oct treble roll-off swept 700 Hz..8.4 kHz, Level a dB trim.
// Bypassed when the Pre-Amp Boost card is toggled off. At Drive 0%, it operates
// as a distortionless clean boost through Tone and Level; higher Drive settings
// add the selected diode saturation. Clean / No Diodes keeps the feedback branch
// linear at every Drive setting, with Tight, Tone and Level still active.
class Overdrive {
 public:
  enum class Voicing : int {
    ClassicTS = 0,   // Symmetric silicon (TS808 / TS9)
    Asymmetric = 1,  // Asymmetric silicon (Boss SD-1 style: 2 diodes pos, 1 diode neg, even harmonics)
    LedTurbo = 2,    // Red LEDs (Turbo / Guv'nor style: high headroom, open crunch)
    Germanium = 3,   // Germanium diodes (vintage soft saturation, low threshold, warm compression)
    Clean = 4,       // Linear feedback branch, without diode clipping or self-bias
    Count = 5
  };

  static constexpr float kToneDefault = 50.0f;
  static constexpr float kTightDefault = 720.0f;
  static constexpr float kTightMinHz = 100.0f;
  static constexpr float kTightMaxHz = 1500.0f;
  static constexpr float kVoicingDefault = 0.0f;
  static constexpr float kLevelMinDb = -12.0f;
  static constexpr float kLevelMaxDb = 12.0f;

  void reset() noexcept {
    bass_ = lp_ = tone_ = bias_ = 0.0;
    smoothOn_ = smoothDrive_ = smoothTone_ = smoothLevel_ = 0.0f;
    smoothTight_ = kTightDefault;
    currentVoicing_ = targetVoicing_ = 0;
    voicingFade_ = 1.0f;
    primed_ = false;
  }

  bool active() const noexcept { return smoothOn_ > 0.0f; }

  // Dynamic self-biasing drift voltage across the feedback capacitor network (V).
  // Settles dynamically during pick attack with ~25 ms time constant.
  double dynamicBias() const noexcept { return bias_; }

  void process(float* samples, size_t count, double rate, float driveAmount,
               float toneAmount, float levelDb, bool enabled) noexcept {
    process(samples, count, rate, driveAmount, toneAmount, levelDb, kTightDefault, 0.0f, enabled);
  }

  void process(float* samples, size_t count, double rate, float driveAmount,
               float toneAmount, float levelDb, float tightHz, bool enabled) noexcept {
    process(samples, count, rate, driveAmount, toneAmount, levelDb, tightHz, 0.0f, enabled);
  }

  void process(float* samples, size_t count, double rate, float driveAmount,
               float toneAmount, float levelDb, float tightHz = kTightDefault,
               float voicingMode = 0.0f, bool enabled = true) noexcept {
    const float onTarget = enabled ? 1.0f : 0.0f;
    if (onTarget == 0.0f && smoothOn_ <= 0.0f) {
      reset();
      return;
    }
    const float driveTarget = std::isfinite(driveAmount)
        ? std::clamp(driveAmount * 0.01f, 0.0f, 1.0f) : 0.0f;
    const float toneTarget = std::isfinite(toneAmount)
        ? std::clamp(toneAmount * 0.01f, 0.0f, 1.0f) : kToneDefault * 0.01f;
    const float levelTarget = std::isfinite(levelDb)
        ? std::clamp(levelDb, kLevelMinDb, kLevelMaxDb) : 0.0f;
    const float tightTarget = std::isfinite(tightHz)
        ? std::clamp(tightHz, kTightMinHz, kTightMaxHz) : kTightDefault;
    const int newTargetVoicing = std::isfinite(voicingMode)
        ? std::clamp(static_cast<int>(voicingMode + 0.5f), 0, static_cast<int>(Voicing::Count) - 1) : 0;
    if (!primed_) {
      // Engaging starts from the current settings and fades in via smoothOn_.
      smoothDrive_ = driveTarget;
      smoothTone_ = toneTarget;
      smoothLevel_ = levelTarget;
      smoothTight_ = tightTarget;
      currentVoicing_ = targetVoicing_ = newTargetVoicing;
      voicingFade_ = 1.0f;
      primed_ = true;
    } else if (newTargetVoicing != targetVoicing_) {
      if (voicingFade_ >= 1.0f) {
        currentVoicing_ = targetVoicing_;
        voicingFade_ = 0.0f;
      }
      targetVoicing_ = newTargetVoicing;
    }
    for (size_t start = 0; start < count; start += kChunk) {
      const size_t n = std::min(kChunk, count - start);
      const float smooth = 1.0f - static_cast<float>(
          std::exp(-static_cast<double>(n) / (std::max(1.0, rate) * 0.010)));
      const float onStart = smoothOn_;
      glide(smoothOn_, onTarget, smooth);
      glide(smoothDrive_, driveTarget, smooth);
      glide(smoothTight_, tightTarget, smooth);
      glide(smoothTone_, toneTarget, smooth);
      glide(smoothLevel_, levelTarget, smooth);

      const double g = branchGain(smoothDrive_);
      const double hpK = onePole(smoothTight_, rate);
      const double lpK = onePole(std::min(feedbackLowPassHz(smoothDrive_), 0.45 * rate), rate);
      const double toneK = onePole(std::min(toneHz(smoothTone_), 0.45 * rate), rate);
      const double level = std::pow(10.0, smoothLevel_ / 20.0);
      const float fadeStep = static_cast<float>(1.0 / (std::max(1.0, rate) * 0.010));
      // Dynamic bias drift tracking: tau = 25 ms virtual-ground sag / feedback cap memory
      const double biasK = 1.0 - std::exp(-1.0 / (std::max(1.0, rate) * 0.025));
      // Ramp the engage fade per sample so it never zippers.
      double on = onStart;
      const double onStep = (static_cast<double>(smoothOn_) - onStart) / static_cast<double>(n);
      float* s = samples + start;
      for (size_t i = 0; i < n; ++i) {
        on += onStep;
        const double x = s[i];
        bass_ += hpK * (x - bass_);
        lp_ += lpK * ((x - bass_) - lp_);
        // Clipper input is modulated by dynamic bias drift
        const double u = g * lp_ - bias_;
        const bool currentClean = currentVoicing_ == static_cast<int>(Voicing::Clean);
        double clipped = clip(currentClean ? g * lp_ : u, currentVoicing_);
        double biasSignal = currentClean ? 0.0 : clipped;
        if (voicingFade_ < 1.0f) {
          const bool targetClean = targetVoicing_ == static_cast<int>(Voicing::Clean);
          const double c1 = clip(targetClean ? g * lp_ : u, targetVoicing_);
          clipped = (1.0 - voicingFade_) * clipped + voicingFade_ * c1;
          biasSignal = (1.0 - voicingFade_) * biasSignal + voicingFade_ * (targetClean ? 0.0 : c1);
          voicingFade_ += fadeStep;
          if (voicingFade_ >= 1.0f) {
            voicingFade_ = 1.0f;
            currentVoicing_ = targetVoicing_;
          }
        }
        // Leak integrator models dynamic self-biasing charge (tau = 25 ms, 15% coupling factor)
        bias_ += biasK * (0.15 * biasSignal - bias_);
        const double pedal = x + smoothDrive_ * clipped;
        tone_ += toneK * (pedal - tone_);
        s[i] = static_cast<float>(x + on * (tone_ * level - x));
      }
    }
    if (onTarget == 0.0f && smoothOn_ < 1.0e-4f) reset();
  }

  // Pre-clip high-pass filter response (dB) for the variable tight/cut control.
  static double preClipHighPassResponseDb(double hz, double rate, float tightHz) noexcept {
    const float tight = std::isfinite(tightHz)
        ? std::clamp(tightHz, kTightMinHz, kTightMaxHz) : kTightDefault;
    const double k = onePole(tight, rate);
    const double w = 2.0 * kPi * hz / rate;
    const double re = 1.0 - (1.0 - k) * std::cos(w);
    const double im = (1.0 - k) * std::sin(w);
    const double numRe = (1.0 - k) * (1.0 - std::cos(w));
    const double numIm = (1.0 - k) * std::sin(w);
    const double denMagSq = re * re + im * im;
    const double numMagSq = numRe * numRe + numIm * numIm;
    if (denMagSq <= 0.0 || numMagSq <= 0.0) return -60.0;
    return 10.0 * std::log10(numMagSq / denMagSq);
  }

  // Linear part after the clipper (Tone + Level), as drawn on the Sculpt graph.
  static double postClipResponseDb(double hz, double rate, float toneAmount,
                                   float levelDb) noexcept {
    const float tone = std::isfinite(toneAmount)
        ? std::clamp(toneAmount * 0.01f, 0.0f, 1.0f) : kToneDefault * 0.01f;
    const float level = std::isfinite(levelDb)
        ? std::clamp(levelDb, kLevelMinDb, kLevelMaxDb) : 0.0f;
    // |H| of y += k (x - y): k / |1 - (1 - k) e^-jw|.
    const double k = onePole(std::min(toneHz(tone), 0.45 * rate), rate);
    const double w = 2.0 * kPi * hz / rate;
    const double re = 1.0 - (1.0 - k) * std::cos(w);
    const double im = (1.0 - k) * std::sin(w);
    return 20.0 * std::log10(k / std::sqrt(re * re + im * im)) + level;
  }

  static double toneHz(float tone01) noexcept {
    return 700.0 * std::pow(12.0, static_cast<double>(tone01));
  }
  // Audio-taper 500k Drive pot.
  static double driveOhms(float drive01) noexcept {
    return 500.0e3 * (std::pow(100.0, static_cast<double>(drive01)) - 1.0) / 99.0;
  }
  static double branchGain(float drive01) noexcept {
    return (51.0e3 + driveOhms(drive01)) / 4.7e3;
  }
  static double feedbackLowPassHz(float drive01) noexcept {
    return 1.0 / (2.0 * kPi * (51.0e3 + driveOhms(drive01)) * 51.0e-12);
  }
  // Four diode curves plus a linear, diode-free feedback branch:
  // 0: Classic TS (symmetric silicon, Vth = 0.25V, conduction knee p = 2)
  // 1: Asymmetric SD-1 (silicon diode array: 2 pos 0.50V, 1 neg 0.25V, p = 2)
  // 2: LED Turbo (red LEDs, Vth = 0.60V, sharp forward conduction knee p = 4)
  // 3: Germanium (vintage Ge diodes, Vth = 0.15V, soft warm compression knee p = 4/3)
  // 4: Clean / No Diodes (linear boost; Drive, Tight, Tone and Level still apply)
  static double clip(double u, int voicing = 0) noexcept {
    switch (voicing) {
      case static_cast<int>(Voicing::Clean):
        return u;
      case 1: { // Asymmetric SD-1 (silicon array, p = 2)
        if (u >= 0.0) {
          const double v = u / 0.50;
          return 0.50 * v / std::sqrt(1.0 + v * v);
        } else {
          const double v = u / 0.25;
          return 0.25 * v / std::sqrt(1.0 + v * v);
        }
      }
      case 2: { // LED Turbo (High headroom red LEDs with sharp knee p = 4)
        const double v = u / 0.60;
        const double v2 = v * v;
        return 0.60 * v / std::sqrt(std::sqrt(1.0 + v2 * v2));
      }
      case 3: { // Germanium (Warm, early compression with soft vintage knee p = 4/3)
        const double v = u / 0.15;
        const double absV = std::fabs(v);
        const double z = 1.0 + absV * std::cbrt(absV);
        return 0.15 * v / std::sqrt(z * std::sqrt(z));
      }
      case 0:   // Classic TS (Symmetric silicon, p = 2)
      default: {
        const double v = u / kDiodeLevel;
        return kDiodeLevel * v / std::sqrt(1.0 + v * v);
      }
    }
  }

  static constexpr double kHighPassHz = 720.0;
  static constexpr double kDiodeLevel = 0.25;

 private:
  static constexpr size_t kChunk = 32;
  static constexpr double kPi = 3.14159265358979323846;

  static double onePole(double hz, double rate) noexcept {
    return 1.0 - std::exp(-2.0 * kPi * hz / std::max(1.0, rate));
  }
  static void glide(float& value, float target, float coeff) noexcept {
    value += (target - value) * coeff;
    if (std::fabs(target - value) < 1.0e-5f) value = target;
  }

  double bass_ = 0.0, lp_ = 0.0, tone_ = 0.0, bias_ = 0.0;
  float smoothOn_ = 0.0f, smoothDrive_ = 0.0f, smoothTight_ = kTightDefault, smoothTone_ = 0.0f, smoothLevel_ = 0.0f;
  int currentVoicing_ = 0, targetVoicing_ = 0;
  float voicingFade_ = 1.0f;
  bool primed_ = false;
};

}  // namespace NAMRig
