#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "space_fx.h"

namespace NAMRig {

// Time-domain granular pitch shifter. Two read heads sweep a delay line at
// speed (1 - ratio) under a raised-cosine crossfade, so each head travels one
// ~40 ms window per life and is silent where it is re-placed. A re-placed head
// lands on the delay (within half a window of nominal) whose recent history
// best correlates with the live head, which removes the phase slip of a fixed
// half-window head spacing. Up to two voices share one delay line per channel.
// Pitch, mix and voice gains glide over ~20 ms; Mix 0 is an exact bypass that
// also clears the lines.
//
//  kShift:   wet = voice 1 shifted by semitones1 (+ detuneCents)
//            out = dry * (1 - mix) + wet * mix
//  kDetune:  voice 1 = +detuneCents, voice 2 = -detuneCents
//            out = dry + (v1 + v2) * 0.5 * mix
//  kHarmony: voice 1 = semitones1, voice 2 = semitones2 (both + detuneCents)
//            out = dry + (v1 + v2) * mix
//  kWhammy:  wet = shifted by semitones1 * whammy01 (+ detuneCents)
//            out = dry * (1 - mix) + wet * mix
// In stereo two-voice modes, voice 1 leans left and voice 2 leans right.
class PitchShifter {
 public:
  enum Mode { kShift = 0, kDetune, kHarmony, kWhammy, kModeCount };
  static constexpr float kMaxSemitones = 24.0f;
  static constexpr float kMaxDetuneCents = 100.0f;

  void initialize(double rate) {
    rate_ = rate > 0.0 ? rate : 48000.0;
    window_ = windowSamples(rate_);
    windowInt_ = static_cast<int>(window_);
    span_ = std::max(16, static_cast<int>(std::lround(window_ * kSpanRatio)));
    corr_ = std::max(16, static_cast<int>(std::lround(window_ * kCorrRatio)));
    coarse_ = std::max(1, static_cast<int>(std::lround(rate_ / 12000.0)));
    const size_t capacity = static_cast<size_t>(std::ceil(2.0 * window_)) + 16;
    left_.allocate(capacity);
    right_.allocate(capacity);
    mono_.allocate(capacity);
    ref_.assign(static_cast<size_t>(corr_), 0.0f);
    cand_.assign(static_cast<size_t>(span_ + corr_), 0.0f);
    energy_.assign(static_cast<size_t>(span_ + corr_) + 1, 0.0);
    reset();
  }
  void reset() {
    left_.clear();
    right_.clear();
    mono_.clear();
    for (Voice& v : voices_) {
      resetHeads(v);
      v.semitones = 0.0f;
      v.gain = 0.0f;
    }
    mix_ = 0.0f;
    dry_ = 1.0f;
    spread_ = 0.0f;
    primed_ = false;
    cleared_ = true;
  }

  // In place. `right` may be nullptr (mono). mixPercent 0 (after the glide
  // settles) is an exact bypass: bit-identical output and cleared history.
  void process(float* left, float* right, size_t count, int mode, float semitones1,
               float semitones2, float detuneCents, float mixPercent, float whammy01) {
    const float mixTarget = std::isfinite(mixPercent)
        ? std::clamp(mixPercent * 0.01f, 0.0f, 1.0f) : 0.0f;
    if (mixTarget <= 0.0f && mix_ <= 0.0f) {
      if (!cleared_) reset();
      return;
    }
    cleared_ = false;
    if (mode < 0 || mode >= kModeCount) mode = kShift;
    const float s1 = finiteClamp(semitones1, kMaxSemitones);
    const float s2 = finiteClamp(semitones2, kMaxSemitones);
    const float cents = finiteClamp(detuneCents, kMaxDetuneCents) * 0.01f;
    const float whammy = std::isfinite(whammy01) ? std::clamp(whammy01, 0.0f, 1.0f) : 0.0f;
    const bool crossfade = mode == kShift || mode == kWhammy;
    const bool twoVoices = mode == kDetune || mode == kHarmony;

    float pitchTarget[2] = {0.0f, 0.0f};
    float gainTarget[2] = {1.0f, 0.0f};
    switch (mode) {
      case kDetune:
        pitchTarget[0] = cents;
        pitchTarget[1] = -cents;
        gainTarget[0] = gainTarget[1] = 0.5f;
        break;
      case kHarmony:
        pitchTarget[0] = s1 + cents;
        pitchTarget[1] = s2 + cents;
        gainTarget[0] = gainTarget[1] = 1.0f;
        break;
      case kWhammy:
        pitchTarget[0] = s1 * whammy + cents;
        break;
      default:
        pitchTarget[0] = s1 + cents;
        break;
    }
    const float pitchLimit = kMaxSemitones + kMaxDetuneCents * 0.01f;
    for (int v = 0; v < 2; ++v) pitchTarget[v] = std::clamp(pitchTarget[v], -pitchLimit, pitchLimit);
    const float dryTarget = crossfade ? 1.0f - mixTarget : 1.0f;
    const float spreadTarget = (twoVoices && right != nullptr) ? 1.0f : 0.0f;
    if (!primed_) {
      // Engaging starts at the requested pitch and fades in via mix_.
      for (int v = 0; v < 2; ++v) voices_[v].semitones = pitchTarget[v];
      spread_ = spreadTarget;
      primed_ = true;
    }

    const double twoPi = 2.0 * kPi;
    const double maxDelay = static_cast<double>(left_.capacity());
    for (size_t start = 0; start < count; start += kChunk) {
      const size_t n = std::min(kChunk, count - start);
      const float coeff = 1.0f - static_cast<float>(
          std::exp(-static_cast<double>(n) / (rate_ * 0.020)));
      const double invN = 1.0 / static_cast<double>(n);

      const double dryStart = dry_;
      const double mixStart = mix_;
      double gainStart[2], incStart[2];
      for (int v = 0; v < 2; ++v) {
        gainStart[v] = voices_[v].gain;
        incStart[v] = increment(voices_[v].semitones);
      }
      glide(dry_, dryTarget, coeff);
      glide(mix_, mixTarget, coeff);
      glide(spread_, spreadTarget, coeff);
      for (int v = 0; v < 2; ++v) {
        glide(voices_[v].gain, gainTarget[v], coeff);
        glide(voices_[v].semitones, pitchTarget[v], coeff);
      }
      const double dryStep = (static_cast<double>(dry_) - dryStart) * invN;
      const double mixStep = (static_cast<double>(mix_) - mixStart) * invN;
      double gainStep[2], incStep[2], panL[2], panR[2];
      bool active[2];
      for (int v = 0; v < 2; ++v) {
        gainStep[v] = (static_cast<double>(voices_[v].gain) - gainStart[v]) * invN;
        incStep[v] = (increment(voices_[v].semitones) - incStart[v]) * invN;
        active[v] = gainStart[v] > 0.0 || voices_[v].gain > 0.0f;
        if (!active[v]) resetHeads(voices_[v]);
        const double near = 1.0 + (kPanNear - 1.0) * spread_;
        const double far = 1.0 + (kPanFar - 1.0) * spread_;
        panL[v] = v == 0 ? near : far;
        panR[v] = v == 0 ? far : near;
      }

      float* l = left + start;
      float* r = right != nullptr ? right + start : nullptr;
      double dry = dryStart, mix = mixStart;
      double gain[2] = {gainStart[0], gainStart[1]};
      double inc[2] = {incStart[0], incStart[1]};
      for (size_t i = 0; i < n; ++i) {
        dry += dryStep;
        mix += mixStep;
        const float inL = l[i];
        left_.write(inL);
        double outL = inL * dry;
        double outR = 0.0;
        if (r != nullptr) {
          const float inR = r[i];
          right_.write(inR);
          mono_.write(0.5f * (inL + inR));
          outR = inR * dry;
        } else {
          mono_.write(inL);
        }
        for (int v = 0; v < 2; ++v) {
          gain[v] += gainStep[v];
          inc[v] += incStep[v];
          if (!active[v]) continue;
          Voice& voice = voices_[v];
          voice.phase += inc[v];
          if (voice.phase >= 1.0) voice.phase -= 1.0;
          else if (voice.phase < 0.0) voice.phase += 1.0;
          const double step = inc[v] * window_;
          double headGain[2];
          headGain[0] = 0.5 - 0.5 * std::cos(twoPi * voice.phase);
          headGain[1] = 1.0 - headGain[0];
          for (int h = 0; h < 2; ++h) {
            Head& head = voice.head[h];
            head.delay = std::clamp(head.delay + step, 0.0, maxDelay);
            if (headGain[h] < kSilentGain) {
              // A silent head is re-placed once per life, aligned to the
              // head that is currently carrying the signal.
              if (!head.fresh && inc[v] != 0.0) {
                head.delay = alignedDelay(voice.head[1 - h].delay, inc[v] < 0.0);
                head.fresh = true;
              }
            } else if (headGain[h] > 0.5) {
              head.fresh = false;
            }
          }
          const double level = mix * gain[v];
          const double dA = voice.head[0].delay, dB = voice.head[1].delay;
          outL += level * panL[v] * (headGain[0] * left_.readSinc8(dA) +
                                      headGain[1] * left_.readSinc8(dB));
          if (r != nullptr) {
            outR += level * panR[v] * (headGain[0] * right_.readSinc8(dA) +
                                        headGain[1] * right_.readSinc8(dB));
          }
        }
        l[i] = static_cast<float>(outL);
        if (r != nullptr) r[i] = static_cast<float>(outR);
      }
    }
    if (mixTarget <= 0.0f && mix_ <= 0.0f) reset();
  }

  // Nominal processing delay of the wet path in frames at this rate: the
  // mid-life delay of a head placed at the centre of its placement range.
  // Splice alignment moves individual grains by up to a quarter window.
  static uint32_t latencyFrames(double rate) {
    return static_cast<uint32_t>(std::lround(kNominalDelayRatio *
        windowSamples(rate > 0.0 ? rate : 48000.0)));
  }

 private:
  struct Head {
    double delay = 0.0;
    bool fresh = false;
  };
  struct Voice {
    double phase = 0.5;
    Head head[2];
    float semitones = 0.0f;
    float gain = 0.0f;
  };

  static constexpr size_t kChunk = 32;
  static constexpr double kPi = 3.14159265358979323846;
  static constexpr double kWindowSeconds = 0.040;
  // Placement range width and correlation length as fractions of the window.
  static constexpr double kSpanRatio = 0.5;
  static constexpr double kCorrRatio = 0.25;
  static constexpr double kNominalDelayRatio = 0.75;
  static constexpr double kSilentGain = 1.0e-3;
  static constexpr double kCentrePenalty = 0.1;
  // Constant-power pan about 30% off centre.
  static constexpr double kPanNear = 0.8526;
  static constexpr double kPanFar = 0.5225;

  static double windowSamples(double rate) {
    return std::max(64.0, std::round(rate * kWindowSeconds));
  }
  static float finiteClamp(float x, float limit) {
    return std::isfinite(x) ? std::clamp(x, -limit, limit) : 0.0f;
  }
  static void glide(float& value, float target, float coeff) {
    value += (target - value) * coeff;
    if (std::fabs(target - value) < 1.0e-5f) value = target;
  }
  // Head speed through the window, in windows per sample.
  double increment(float semitones) const {
    return (1.0 - std::exp2(static_cast<double>(semitones) / 12.0)) / window_;
  }
  void resetHeads(Voice& v) const {
    v.phase = 0.5;
    v.head[0].delay = kNominalDelayRatio * window_;
    v.head[0].fresh = false;
    v.head[1].delay = kNominalDelayRatio * window_;
    v.head[1].fresh = false;
  }

  // Delay for a head starting a new life. The head travels one window during
  // its life, so a decreasing delay must start in [W, W + span] and an
  // increasing one in [0, span]. Within that range, pick the delay whose
  // recent history has the highest normalized correlation with the live
  // head's, with a mild preference for the centre of the range.
  double alignedDelay(double liveDelay, bool decreasing) {
    const int lo = decreasing ? windowInt_ : 0;
    const int span = span_;
    const int len = corr_;
    const size_t refStart = static_cast<size_t>(std::lround(
        std::clamp(liveDelay, 0.0, static_cast<double>(mono_.capacity()))));
    double refEnergy = 0.0;
    for (int m = 0; m < len; ++m) {
      const float x = mono_.read(refStart + static_cast<size_t>(m));
      ref_[static_cast<size_t>(m)] = x;
      refEnergy += static_cast<double>(x) * x;
    }
    energy_[0] = 0.0;
    for (int k = 0; k < span + len; ++k) {
      const float x = mono_.read(static_cast<size_t>(lo + k));
      cand_[static_cast<size_t>(k)] = x;
      energy_[static_cast<size_t>(k) + 1] = energy_[static_cast<size_t>(k)] + static_cast<double>(x) * x;
    }
    const double refNorm = std::sqrt(refEnergy);
    const double halfSpan = 0.5 * span;
    auto score = [&](int k) {
      const float* c = cand_.data() + k;
      double sum = 0.0;
      for (int m = 0; m < len; ++m) sum += static_cast<double>(ref_[static_cast<size_t>(m)]) * c[m];
      const double candNorm = std::sqrt(energy_[static_cast<size_t>(k + len)] - energy_[static_cast<size_t>(k)]);
      const double ncc = sum / (refNorm * candNorm + 1.0e-12);
      return ncc - kCentrePenalty * std::fabs(k - halfSpan) / halfSpan;
    };
    int best = span / 2;
    double bestScore = -1.0e9;
    for (int k = 0; k <= span; k += coarse_) {
      const double s = score(k);
      if (s > bestScore) { bestScore = s; best = k; }
    }
    const int from = std::max(0, best - coarse_ + 1);
    const int to = std::min(span, best + coarse_ - 1);
    for (int k = from; k <= to; ++k) {
      if (k == best) continue;
      const double s = score(k);
      if (s > bestScore) { bestScore = s; best = k; }
    }
    return static_cast<double>(lo + best);
  }

  double rate_ = 48000.0;
  double window_ = 1920.0;
  int windowInt_ = 1920;
  int span_ = 960;
  int corr_ = 480;
  int coarse_ = 4;
  DelayLine left_, right_, mono_;
  std::vector<float> ref_, cand_;
  std::vector<double> energy_;
  Voice voices_[2];
  float mix_ = 0.0f, dry_ = 1.0f, spread_ = 0.0f;
  bool primed_ = false;
  bool cleared_ = true;
};

}  // namespace NAMRig
