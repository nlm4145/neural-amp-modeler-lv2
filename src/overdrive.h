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
// Drive 0 is an exact bypass; Tone and Level only apply while it is engaged.
class Overdrive {
 public:
  static constexpr float kToneDefault = 50.0f;
  static constexpr float kLevelMinDb = -12.0f;
  static constexpr float kLevelMaxDb = 12.0f;

  void reset() noexcept {
    bass_ = lp_ = tone_ = 0.0;
    smoothOn_ = smoothDrive_ = smoothTone_ = smoothLevel_ = 0.0f;
    primed_ = false;
  }

  bool active() const noexcept { return smoothOn_ > 0.0f; }

  void process(float* samples, size_t count, double rate, float driveAmount,
               float toneAmount, float levelDb) noexcept {
    const float driveTarget = std::isfinite(driveAmount)
        ? std::clamp(driveAmount * 0.01f, 0.0f, 1.0f) : 0.0f;
    const float onTarget = driveTarget > 0.0f ? 1.0f : 0.0f;
    if (onTarget == 0.0f && smoothOn_ <= 0.0f) {
      reset();
      return;
    }
    const float toneTarget = std::isfinite(toneAmount)
        ? std::clamp(toneAmount * 0.01f, 0.0f, 1.0f) : kToneDefault * 0.01f;
    const float levelTarget = std::isfinite(levelDb)
        ? std::clamp(levelDb, kLevelMinDb, kLevelMaxDb) : 0.0f;
    if (!primed_) {
      // Engaging starts from the current settings and fades in via smoothOn_.
      smoothDrive_ = driveTarget;
      smoothTone_ = toneTarget;
      smoothLevel_ = levelTarget;
      primed_ = true;
    }
    for (size_t start = 0; start < count; start += kChunk) {
      const size_t n = std::min(kChunk, count - start);
      const float smooth = 1.0f - static_cast<float>(
          std::exp(-static_cast<double>(n) / (std::max(1.0, rate) * 0.010)));
      const float onStart = smoothOn_;
      glide(smoothOn_, onTarget, smooth);
      if (onTarget > 0.0f) glide(smoothDrive_, driveTarget, smooth);
      glide(smoothTone_, toneTarget, smooth);
      glide(smoothLevel_, levelTarget, smooth);

      const double g = branchGain(smoothDrive_);
      const double hpK = onePole(kHighPassHz, rate);
      const double lpK = onePole(std::min(feedbackLowPassHz(smoothDrive_), 0.45 * rate), rate);
      const double toneK = onePole(std::min(toneHz(smoothTone_), 0.45 * rate), rate);
      const double level = std::pow(10.0, smoothLevel_ / 20.0);
      // Ramp the engage fade per sample so it never zippers.
      double on = onStart;
      const double onStep = (static_cast<double>(smoothOn_) - onStart) / static_cast<double>(n);
      float* s = samples + start;
      for (size_t i = 0; i < n; ++i) {
        on += onStep;
        const double x = s[i];
        bass_ += hpK * (x - bass_);
        lp_ += lpK * ((x - bass_) - lp_);
        const double pedal = x + clip(g * lp_);
        tone_ += toneK * (pedal - tone_);
        s[i] = static_cast<float>(x + on * (tone_ * level - x));
      }
    }
    if (onTarget == 0.0f && smoothOn_ < 1.0e-4f) reset();
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
  // Soft symmetric diode-pair limit on the feedback branch.
  static double clip(double u) noexcept {
    const double v = u / kDiodeLevel;
    return kDiodeLevel * v / std::sqrt(1.0 + v * v);
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

  double bass_ = 0.0, lp_ = 0.0, tone_ = 0.0;
  float smoothOn_ = 0.0f, smoothDrive_ = 0.0f, smoothTone_ = 0.0f, smoothLevel_ = 0.0f;
  bool primed_ = false;
};

}  // namespace NAMRig
