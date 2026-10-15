#pragma once

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstddef>

namespace NAMRig {

// Drive pedal voicings 1..5 in front of the amp (kScreamer is Overdrive in
// overdrive.h). Runs in the amp's True domain, so the clippers are oversampled
// with the capture. Each voicing is input high-pass -> gain -> clip -> DC
// blocker -> tone -> level, loosely after the circuit it is named for:
//   Blues       100 Hz HP, 1..30x, asymmetric soft clip, tone LP 1..10 kHz.
//   Distortion  RAT. 60 Hz HP, 1.5 kHz pre-emphasis, 4..1000x, hard clip with
//               a short knee, tone LP 700 Hz..8 kHz.
//   Fuzz        Germanium Fuzz Face. 2..500x, strongly asymmetric clip whose
//               bias follows the input envelope so hot notes gate and sputter
//               on the decay, fixed 4 kHz LP, tone LP 800 Hz..8 kHz.
//   TrebleBoost Rangemaster. 700 Hz 6 dB/oct HP, 1..20x, mild asymmetric
//               clip, slight tone LP 2..12 kHz.
//   CleanBoost  0..+20 dB linear, tilt EQ +-6 dB about 1 kHz, no clipping.
// Drive 0 is an exact bypass once the ~10 ms engage fade has settled. A type
// change while engaged fades out, clears the filter states, then fades in.
class DrivePedal {
 public:
  // kScreamer (0) is implemented elsewhere (src/overdrive.h); this class handles 1..5.
  enum Type { kScreamer = 0, kBlues, kDistortion, kFuzz, kTrebleBoost, kCleanBoost, kTypeCount };

  static constexpr float kToneDefault = 50.0f;
  static constexpr float kLevelMinDb = -12.0f, kLevelMaxDb = 12.0f;

  void reset() noexcept {
    resetStates();
    smoothOn_ = smoothDrive_ = smoothTone_ = smoothLevel_ = 0.0f;
    type_ = kBlues;
    pending_ = -1;
    primed_ = false;
  }

  bool active() const noexcept { return smoothOn_ > 0.0f; }

  // Mono, in place, at `rate` which may be an oversampled domain rate (up to 16 x 96 kHz = 1.536 MHz).
  // drivePercent 0 (after the ~10 ms engage fade) is an EXACT bypass: output bit-identical to input.
  void process(float* samples, size_t count, double rate, int type, float drivePercent,
               float tonePercent, float levelDb) noexcept {
    rate = std::isfinite(rate) && rate > 1.0 ? rate : 48000.0;
    const bool validType = type > kScreamer && type < kTypeCount;
    const float driveTarget = std::isfinite(drivePercent)
        ? std::clamp(drivePercent * 0.01f, 0.0f, 1.0f) : 0.0f;
    const bool engaged = validType && driveTarget > 0.0f;
    if (!engaged && smoothOn_ <= 0.0f) {
      reset();
      return;
    }
    const float toneTarget = std::isfinite(tonePercent)
        ? std::clamp(tonePercent * 0.01f, 0.0f, 1.0f) : kToneDefault * 0.01f;
    const float levelTarget = std::isfinite(levelDb)
        ? std::clamp(levelDb, kLevelMinDb, kLevelMaxDb) : 0.0f;
    if (!primed_) {
      // Engaging starts from the current settings and fades in via smoothOn_.
      type_ = type;
      smoothDrive_ = driveTarget;
      smoothTone_ = toneTarget;
      smoothLevel_ = levelTarget;
      primed_ = true;
    } else if (validType) {
      pending_ = type != type_ ? type : -1;
    }
    const double envAttack = -std::expm1(-1.0 / (rate * 0.002));
    const double envRelease = -std::expm1(-1.0 / (rate * 0.100));
    for (size_t start = 0; start < count; start += kChunk) {
      const size_t n = std::min(kChunk, count - start);
      const float smooth = 1.0f - static_cast<float>(
          std::exp(-static_cast<double>(n) / (rate * 0.010)));
      if (pending_ >= 0 && smoothOn_ <= 1.0e-3f) {
        type_ = pending_;
        pending_ = -1;
        resetStates();
        smoothOn_ = 0.0f;
      }
      const float onTarget = (engaged && pending_ < 0) ? 1.0f : 0.0f;
      const float onStart = smoothOn_;
      glide(smoothOn_, onTarget, smooth);
      if (engaged) glide(smoothDrive_, driveTarget, smooth);
      glide(smoothTone_, toneTarget, smooth);
      glide(smoothLevel_, levelTarget, smooth);

      const Voicing v = voicing(type_, smoothDrive_, smoothTone_, smoothLevel_, rate);
      // Ramp the engage fade per sample so it never zippers.
      double on = onStart;
      const double onStep = (static_cast<double>(smoothOn_) - onStart) / static_cast<double>(n);
      float* s = samples + start;
      switch (type_) {
        case kDistortion:
          for (size_t i = 0; i < n; ++i) {
            on += onStep;
            const double x = s[i];
            hp1_ += v.inK * (x - hp1_);
            const double in = x - hp1_;
            hp2_ += v.emphK * (in - hp2_);
            const double c = ratClip(v.gain * (in + kRatEmphasis * (in - hp2_)));
            dc_ += v.dcK * (c - dc_);
            tone_ += v.toneK * ((c - dc_) - tone_);
            s[i] = static_cast<float>(x + on * (tone_ * v.level - x));
          }
          break;
        case kFuzz:
          for (size_t i = 0; i < n; ++i) {
            on += onStep;
            const double x = s[i];
            hp1_ += v.inK * (x - hp1_);
            const double in = x - hp1_;
            const double a = std::fabs(in);
            env_ += (a - env_) * (a > env_ ? envAttack : envRelease);
            const double bias = kFuzzBiasMax * std::min(1.0, env_ * v.gain * 0.5);
            const double c = fuzzClip(v.gain * in - bias);
            dc_ += v.dcK * (c - dc_);
            lp_ += v.lpK * ((c - dc_) - lp_);
            tone_ += v.toneK * (lp_ - tone_);
            s[i] = static_cast<float>(x + on * (tone_ * v.level - x));
          }
          break;
        case kTrebleBoost:
          for (size_t i = 0; i < n; ++i) {
            on += onStep;
            const double x = s[i];
            hp1_ += v.inK * (x - hp1_);
            const double c = trebleClip(v.gain * (x - hp1_));
            dc_ += v.dcK * (c - dc_);
            tone_ += v.toneK * ((c - dc_) - tone_);
            s[i] = static_cast<float>(x + on * (tone_ * v.level - x));
          }
          break;
        case kCleanBoost:
          for (size_t i = 0; i < n; ++i) {
            on += onStep;
            const double x = s[i];
            lp_ += v.lpK * (x - lp_);
            const double y = v.gain * (v.tiltLow * lp_ + v.tiltHigh * (x - lp_));
            s[i] = static_cast<float>(x + on * (y * v.level - x));
          }
          break;
        default:  // kBlues
          for (size_t i = 0; i < n; ++i) {
            on += onStep;
            const double x = s[i];
            hp1_ += v.inK * (x - hp1_);
            const double c = bluesClip(v.gain * (x - hp1_));
            dc_ += v.dcK * (c - dc_);
            tone_ += v.toneK * ((c - dc_) - tone_);
            s[i] = static_cast<float>(x + on * (tone_ * v.level - x));
          }
          break;
      }
      if (!std::isfinite(hp1_) || !std::isfinite(hp2_) || !std::isfinite(dc_) ||
          !std::isfinite(lp_) || !std::isfinite(tone_) || !std::isfinite(env_)) {
        resetStates();
      }
    }
    if (!engaged && smoothOn_ < 1.0e-4f) reset();
  }

  // Linear post-clip response (tone + level) in dB at hz, for the UI graph.
  static double postClipResponseDb(double hz, double rate, int type, float tonePercent,
                                   float levelDb) noexcept {
    rate = std::isfinite(rate) && rate > 1.0 ? rate : 48000.0;
    hz = std::isfinite(hz) ? std::clamp(hz, 1.0, 0.499 * rate) : 1000.0;
    const float tone = std::isfinite(tonePercent)
        ? std::clamp(tonePercent * 0.01f, 0.0f, 1.0f) : kToneDefault * 0.01f;
    const float level = std::isfinite(levelDb)
        ? std::clamp(levelDb, kLevelMinDb, kLevelMaxDb) : 0.0f;
    const Voicing v = voicing(type, 0.0f, tone, 0.0f, rate);
    const double w = 2.0 * kPi * hz / rate;
    std::complex<double> h(1.0, 0.0);
    switch (type) {
      case kBlues:
      case kDistortion:
      case kTrebleBoost:
        h = lpZ(v.toneK, w) * (1.0 - lpZ(v.dcK, w));
        break;
      case kFuzz:
        h = lpZ(v.toneK, w) * lpZ(v.lpK, w) * (1.0 - lpZ(v.dcK, w));
        break;
      case kCleanBoost: {
        const std::complex<double> lp = lpZ(v.lpK, w);
        h = v.tiltLow * lp + v.tiltHigh * (1.0 - lp);
        break;
      }
      default:
        break;
    }
    return 20.0 * std::log10(std::max(std::abs(h), 1.0e-9)) + level;
  }

  static double gain(int type, float drive01) noexcept {
    const double d = drive01;
    switch (type) {
      case kDistortion: return 4.0 * std::pow(250.0, d);
      case kFuzz: return 2.0 * std::pow(250.0, d);
      case kTrebleBoost: return std::pow(20.0, d);
      case kCleanBoost: return std::pow(10.0, d);
      default: return std::pow(30.0, d);
    }
  }
  static double toneHz(int type, float tone01) noexcept {
    const double t = tone01;
    switch (type) {
      case kDistortion: return 700.0 * std::pow(8000.0 / 700.0, t);
      case kFuzz: return 800.0 * std::pow(10.0, t);
      case kTrebleBoost: return 2000.0 * std::pow(6.0, t);
      default: return 1000.0 * std::pow(10.0, t);
    }
  }

  // tanh above, a wider knee below.
  static double bluesClip(double u) noexcept {
    return u >= 0.0 ? std::tanh(u) : 1.25 * std::tanh(u / 1.25);
  }
  // Hard clip to +-1 with a short knee: u / (1 + u^8)^(1/8).
  static double ratClip(double u) noexcept {
    const double u2 = u * u, u4 = u2 * u2;
    return u / std::sqrt(std::sqrt(std::sqrt(1.0 + u4 * u4)));
  }
  // Germanium pair: full swing above, collapsed rail below.
  static double fuzzClip(double u) noexcept {
    return u >= 0.0 ? std::tanh(u) : 0.6 * std::tanh(u / 0.6);
  }
  static double trebleClip(double u) noexcept {
    return u >= 0.0 ? 1.5 * std::tanh(u / 1.5) : std::tanh(u);
  }

  static constexpr double kDcHz = 10.0;
  static constexpr double kRatEmphasis = 2.0;
  static constexpr double kFuzzBiasMax = 0.7;

 private:
  static constexpr size_t kChunk = 32;
  static constexpr double kPi = 3.14159265358979323846;

  struct Voicing {
    double inK, emphK, dcK, lpK, toneK, gain, level, tiltLow, tiltHigh;
  };

  static Voicing voicing(int type, float drive01, float tone01, float levelDb,
                         double rate) noexcept {
    Voicing v{};
    v.level = std::pow(10.0, levelDb / 20.0);
    v.dcK = onePole(kDcHz, rate);
    v.gain = gain(type, drive01);
    v.toneK = onePole(std::min(toneHz(type, tone01), 0.45 * rate), rate);
    switch (type) {
      case kDistortion:
        v.inK = onePole(60.0, rate);
        v.emphK = onePole(std::min(1500.0, 0.45 * rate), rate);
        break;
      case kFuzz:
        v.inK = onePole(40.0, rate);
        v.lpK = onePole(std::min(4000.0, 0.45 * rate), rate);
        break;
      case kTrebleBoost:
        v.inK = onePole(700.0, rate);
        break;
      case kCleanBoost: {
        const double tilt = 2.0 * tone01 - 1.0;
        v.lpK = onePole(1000.0, rate);
        v.tiltHigh = std::pow(10.0, 6.0 * tilt / 20.0);
        v.tiltLow = std::pow(10.0, -6.0 * tilt / 20.0);
        break;
      }
      default:
        v.inK = onePole(100.0, rate);
        break;
    }
    return v;
  }
  static double onePole(double hz, double rate) noexcept {
    return 1.0 - std::exp(-2.0 * kPi * hz / std::max(1.0, rate));
  }
  // H(z) of y += k (x - y).
  static std::complex<double> lpZ(double k, double w) noexcept {
    return k / (1.0 - (1.0 - k) * std::polar(1.0, -w));
  }
  static void glide(float& value, float target, float coeff) noexcept {
    value += (target - value) * coeff;
    if (std::fabs(target - value) < 1.0e-5f) value = target;
  }
  void resetStates() noexcept { hp1_ = hp2_ = dc_ = lp_ = tone_ = env_ = 0.0; }

  double hp1_ = 0.0, hp2_ = 0.0, dc_ = 0.0, lp_ = 0.0, tone_ = 0.0, env_ = 0.0;
  float smoothOn_ = 0.0f, smoothDrive_ = 0.0f, smoothTone_ = 0.0f, smoothLevel_ = 0.0f;
  int type_ = kBlues, pending_ = -1;
  bool primed_ = false;
};

}  // namespace NAMRig
