#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

#include "space_fx.h"

namespace NAMRig {

// Stereo modulation rack: one of six effects chosen by Type, all driven by
// sine LFOs whose phase runs continuously across blocks. Rate, Depth,
// Feedback, and Mix glide over 20 ms in 32-sample chunks.
//
// Control reuse per type (the knob labels stay, the meaning changes):
//   Chorus   Feedback is a gentle regeneration (0 .. 0.3) on the first voice.
//   Tremolo  Feedback is the stereo phase offset: 0 is a mono tremolo,
//            100 puts the right channel 180 degrees from the left.
//   Vibrato  Feedback is unused.
//   Rotary   Feedback is the horn/drum balance: 0 drum only, 50 equal,
//            100 horn only.
//
// Mix is a linear dry/wet crossfade; Chorus, Flanger, and Phaser give their
// classic comb and notch sound around Mix 50, and Mix 100 is the wet path
// alone. Mix 0 is an exact bypass once the glide settles: the input passes
// untouched and the history is cleared so re-engaging starts silent. A type
// change fades the wet path out over 10 ms, clears the history, then fades
// the new type in, so no stale delay or filter state is ever heard.
class ModulationFx {
 public:
  enum Type { kChorus = 0, kFlanger, kPhaser, kTremolo, kVibrato, kRotary, kTypeCount };
  static constexpr float kRateMinHz = 0.05f, kRateMaxHz = 10.0f;

  void initialize(double rate) {
    rate_ = rate > 0.0 ? rate : 48000.0;
    const size_t capacity = static_cast<size_t>(std::ceil(rate_ * kMaxDelayMs * 0.001)) + 8;
    for (size_t c = 0; c < 2; ++c) {
      lineA_[c].allocate(capacity);
      lineB_[c].allocate(capacity);
    }
    maxDelay_ = static_cast<double>(capacity) - 4.0;
    reset();
  }

  void reset() {
    clearHistory();
    phase_[0] = phase_[1] = 0.0;
    smoothedRate_ = 1.0f;
    smoothedDepth_ = smoothedFeedback_ = smoothedMix_ = 0.0f;
    fade_ = 0.0f;
    wetGain_ = 0.0f;
    activeType_ = kChorus;
    primed_ = false;
    cleared_ = true;
  }

  // Stereo, in place. mixPercent 0 (after the mix glide settles) is an EXACT bypass:
  // output bit-identical to input and all history cleared.
  void process(float* left, float* right, size_t count, int type, float rateHz,
               float depthPercent, float feedbackPercent, float mixPercent) {
    const float mixTarget = std::isfinite(mixPercent) ? clamp01(mixPercent * 0.01f) : 0.0f;
    if (mixTarget <= 0.0f && smoothedMix_ <= 0.0f) {
      if (!cleared_) reset();
      return;
    }
    cleared_ = false;
    const int requested = std::clamp(type, 0, static_cast<int>(kTypeCount) - 1);
    const float rateTarget = std::isfinite(rateHz)
        ? std::clamp(rateHz, kRateMinHz, kRateMaxHz) : 1.0f;
    const float depthTarget = std::isfinite(depthPercent)
        ? clamp01(depthPercent * 0.01f) : 0.5f;
    const float feedbackTarget = std::isfinite(feedbackPercent)
        ? clamp01(feedbackPercent * 0.01f) : 0.0f;
    if (!primed_) {
      // Engaging starts from the current settings; the mix glide fades it in.
      smoothedRate_ = rateTarget;
      smoothedDepth_ = depthTarget;
      smoothedFeedback_ = feedbackTarget;
      activeType_ = requested;
      fade_ = 1.0f;
      primed_ = true;
    }
    for (size_t start = 0; start < count; start += kChunk) {
      const size_t n = std::min(kChunk, count - start);
      const float ctl = glideCoeff(n, 0.020);
      const float fadeCoeff = glideCoeff(n, 0.010);
      glide(smoothedMix_, mixTarget, ctl);
      glide(smoothedRate_, rateTarget, ctl);
      glide(smoothedDepth_, depthTarget, ctl);
      glide(smoothedFeedback_, feedbackTarget, ctl);
      glide(fade_, requested == activeType_ ? 1.0f : 0.0f, fadeCoeff);
      // The wet gain ramps per sample inside the chunk so it never zippers.
      const float gainEnd = smoothedMix_ * fade_;
      const float gainStep = (gainEnd - wetGain_) / static_cast<float>(n);
      const double step = kTwoPi * static_cast<double>(smoothedRate_) / rate_;
      float* l = left + start;
      float* r = right + start;
      switch (activeType_) {
        case kChorus:  runChorus(l, r, n, step, wetGain_, gainStep); break;
        case kFlanger: runFlanger(l, r, n, step, wetGain_, gainStep); break;
        case kPhaser:  runPhaser(l, r, n, step, wetGain_, gainStep); break;
        case kTremolo: runTremolo(l, r, n, step, wetGain_, gainStep); break;
        case kVibrato: runVibrato(l, r, n, step, wetGain_, gainStep); break;
        default:       runRotary(l, r, n, step, wetGain_, gainStep); break;
      }
      wetGain_ = gainEnd;
      phase_[0] = wrapPhase(phase_[0] + static_cast<double>(n) * step);
      phase_[1] = wrapPhase(phase_[1] + static_cast<double>(n) * step * kRotaryDrumRatio);
      if (fade_ <= 0.0f && requested != activeType_) {
        clearHistory();
        activeType_ = requested;
      }
    }
  }

 private:
  static constexpr size_t kChunk = 32;
  static constexpr double kPi = 3.14159265358979323846;
  static constexpr double kTwoPi = 2.0 * kPi;
  static constexpr double kSin120 = 0.86602540378443864676;
  static constexpr double kMaxDelayMs = 32.0;

  static constexpr double kChorusBaseMs[2] = {11.0, 13.0};
  static constexpr double kChorusSweepMs = 8.0;
  static constexpr float kChorusFeedbackMax = 0.3f;

  static constexpr double kFlangerMinMs = 0.5, kFlangerMaxMs = 7.0;
  static constexpr float kFlangerFeedbackMax = 0.9f;

  static constexpr int kPhaserStages = 6;
  static constexpr double kPhaserLowHz = 200.0, kPhaserHighHz = 2500.0;
  static constexpr float kPhaserFeedbackMax = 0.8f;

  static constexpr double kVibratoBaseMs = 3.5, kVibratoSweepMs = 3.0;

  static constexpr double kRotaryCrossoverHz = 800.0;
  static constexpr double kRotaryDrumRatio = 0.6;
  static constexpr double kHornBaseMs = 1.0, kHornDopplerMs = 0.5;
  static constexpr double kDrumBaseMs = 0.75, kDrumDopplerMs = 0.25;
  static constexpr float kHornAm = 0.45f, kDrumAm = 0.30f;
  static constexpr float kHornPan = 0.8f, kDrumPan = 0.5f;

  // Sine/cosine pair stepped by rotation, re-synced from the phase
  // accumulator at every chunk so no sin() runs per sample.
  struct Phasor {
    double s = 0.0, c = 1.0, ds = 0.0, dc = 1.0;
    void start(double phase, double step) {
      s = std::sin(phase);
      c = std::cos(phase);
      ds = std::sin(step);
      dc = std::cos(step);
    }
    void advance() {
      const double next = s * dc + c * ds;
      c = c * dc - s * ds;
      s = next;
    }
  };

  static float clamp01(float x) { return std::max(0.0f, std::min(1.0f, x)); }
  static float soft(float x) { return x / std::sqrt(1.0f + x * x); }
  static double wrapPhase(double p) { return p >= kTwoPi ? p - kTwoPi * std::floor(p / kTwoPi) : p; }
  static void glide(float& value, float target, float coeff) {
    value += (target - value) * coeff;
    if (std::fabs(target - value) < 1.0e-5f) value = target;
  }
  float glideCoeff(size_t n, double seconds) const {
    return 1.0f - static_cast<float>(std::exp(-static_cast<double>(n) / (rate_ * seconds)));
  }
  float onePole(double hz) const {
    return static_cast<float>(1.0 - std::exp(-kTwoPi * std::min(hz, 0.45 * rate_) / rate_));
  }
  // Taps are read before the current sample is written, so the line's newest
  // sample is already one behind the input.
  double tapDelay(double samples) const {
    return std::min(std::max(samples, 2.0), maxDelay_) - 1.0;
  }

  void clearHistory() {
    for (size_t c = 0; c < 2; ++c) {
      lineA_[c].clear();
      lineB_[c].clear();
      for (int k = 0; k < kPhaserStages; ++k) apState_[c][k] = 0.0f;
      phaserOut_[c] = 0.0f;
      crossoverLp_[c] = 0.0f;
    }
  }

  void runChorus(float* l, float* r, size_t n, double step, float gain, float gainStep) {
    const double unit = rate_ * 0.001;
    const double base0 = kChorusBaseMs[0] * unit;
    const double base1 = kChorusBaseMs[1] * unit;
    const double sweep = kChorusSweepMs * unit * smoothedDepth_;
    const float fb = kChorusFeedbackMax * smoothedFeedback_;
    Phasor lfo;
    lfo.start(phase_[0], step);
    for (size_t i = 0; i < n; ++i) {
      gain += gainStep;
      lfo.advance();
      // Voices sit 120 degrees apart; the right channel runs 90 degrees ahead.
      const double sL1 = lfo.s;
      const double sL2 = -0.5 * lfo.s + kSin120 * lfo.c;
      const double sR1 = lfo.c;
      const double sR2 = -kSin120 * lfo.s - 0.5 * lfo.c;
      const float tL1 = lineA_[0].readFrac(tapDelay(base0 + sweep * sL1));
      const float tL2 = lineA_[0].readFrac(tapDelay(base1 + sweep * sL2));
      const float tR1 = lineA_[1].readFrac(tapDelay(base0 + sweep * sR1));
      const float tR2 = lineA_[1].readFrac(tapDelay(base1 + sweep * sR2));
      lineA_[0].write(l[i] + soft(fb * tL1));
      lineA_[1].write(r[i] + soft(fb * tR1));
      l[i] += gain * (0.5f * (tL1 + tL2) - l[i]);
      r[i] += gain * (0.5f * (tR1 + tR2) - r[i]);
    }
  }

  void runFlanger(float* l, float* r, size_t n, double step, float gain, float gainStep) {
    const double unit = rate_ * 0.001;
    const double center = 0.5 * (kFlangerMinMs + kFlangerMaxMs) * unit;
    const double sweep = 0.5 * (kFlangerMaxMs - kFlangerMinMs) * unit * smoothedDepth_;
    const float fb = kFlangerFeedbackMax * smoothedFeedback_;
    Phasor lfo;
    lfo.start(phase_[0], step);
    for (size_t i = 0; i < n; ++i) {
      gain += gainStep;
      lfo.advance();
      const float tL = lineA_[0].readFrac(tapDelay(center + sweep * lfo.s));
      const float tR = lineA_[1].readFrac(tapDelay(center + sweep * lfo.c));
      lineA_[0].write(l[i] + soft(fb * tL));
      lineA_[1].write(r[i] + soft(fb * tR));
      l[i] += gain * (tL - l[i]);
      r[i] += gain * (tR - r[i]);
    }
  }

  // First-order allpass coefficient for H(z) = (c + z^-1) / (1 + c z^-1),
  // 90 degrees at the LFO-swept break frequency (log sweep about 707 Hz).
  double phaserCoeff(double lfo) const {
    const double octaves = 0.5 * std::log2(kPhaserHighHz / kPhaserLowHz);
    const double center = std::sqrt(kPhaserLowHz * kPhaserHighHz);
    const double hz = std::min(center * std::exp2(octaves * smoothedDepth_ * lfo), 0.45 * rate_);
    const double t = std::tan(kPi * hz / rate_);
    return (t - 1.0) / (t + 1.0);
  }
  float phaserChannel(size_t c, float x, float coef, float fb) {
    float v = x + soft(fb * phaserOut_[c]);
    for (int k = 0; k < kPhaserStages; ++k) {
      const float y = coef * v + apState_[c][k];
      apState_[c][k] = v - coef * y;
      v = y;
    }
    phaserOut_[c] = v;
    return v;
  }
  void runPhaser(float* l, float* r, size_t n, double step, float gain, float gainStep) {
    // The coefficient is evaluated at both chunk ends and ramped between them;
    // at 10 Hz a chunk spans under 3 degrees of LFO so the ramp is inaudible.
    const double endPhase = phase_[0] + static_cast<double>(n) * step;
    const double cL0 = phaserCoeff(std::sin(phase_[0]));
    const double cR0 = phaserCoeff(std::cos(phase_[0]));
    const double dL = (phaserCoeff(std::sin(endPhase)) - cL0) / static_cast<double>(n);
    const double dR = (phaserCoeff(std::cos(endPhase)) - cR0) / static_cast<double>(n);
    const float fb = kPhaserFeedbackMax * smoothedFeedback_;
    double cL = cL0, cR = cR0;
    for (size_t i = 0; i < n; ++i) {
      gain += gainStep;
      cL += dL;
      cR += dR;
      const float wL = phaserChannel(0, l[i], static_cast<float>(cL), fb);
      const float wR = phaserChannel(1, r[i], static_cast<float>(cR), fb);
      l[i] += gain * (wL - l[i]);
      r[i] += gain * (wR - r[i]);
    }
  }

  void runTremolo(float* l, float* r, size_t n, double step, float gain, float gainStep) {
    const double offset = kPi * static_cast<double>(smoothedFeedback_);
    const double so = std::sin(offset), co = std::cos(offset);
    const float half = 0.5f * smoothedDepth_;
    Phasor lfo;
    lfo.start(phase_[0], step);
    for (size_t i = 0; i < n; ++i) {
      gain += gainStep;
      lfo.advance();
      const float cL = static_cast<float>(lfo.c);
      const float cR = static_cast<float>(lfo.c * co - lfo.s * so);
      const float gL = 1.0f - half * (1.0f - cL);
      const float gR = 1.0f - half * (1.0f - cR);
      l[i] += gain * (l[i] * gL - l[i]);
      r[i] += gain * (r[i] * gR - r[i]);
    }
  }

  void runVibrato(float* l, float* r, size_t n, double step, float gain, float gainStep) {
    const double unit = rate_ * 0.001;
    const double base = kVibratoBaseMs * unit;
    const double sweep = kVibratoSweepMs * unit * smoothedDepth_;
    Phasor lfo;
    lfo.start(phase_[0], step);
    for (size_t i = 0; i < n; ++i) {
      gain += gainStep;
      lfo.advance();
      const double d = tapDelay(base + sweep * lfo.s);
      const float tL = lineA_[0].readFrac(d);
      const float tR = lineA_[1].readFrac(d);
      lineA_[0].write(l[i]);
      lineA_[1].write(r[i]);
      l[i] += gain * (tL - l[i]);
      r[i] += gain * (tR - r[i]);
    }
  }

  float rotaryChannel(size_t c, float x, float lpCoeff, double hornDelay, double drumDelay,
                      float hornAmp, float drumAmp) {
    crossoverLp_[c] += lpCoeff * (x - crossoverLp_[c]);
    const float low = crossoverLp_[c];
    const float high = x - low;
    const float horn = lineA_[c].readFrac(hornDelay);
    const float drum = lineB_[c].readFrac(drumDelay);
    lineA_[c].write(high);
    lineB_[c].write(low);
    return hornAmp * horn + drumAmp * drum;
  }
  void runRotary(float* l, float* r, size_t n, double step, float gain, float gainStep) {
    const double unit = rate_ * 0.001;
    const float depth = smoothedDepth_;
    const double hornBase = kHornBaseMs * unit, hornDop = kHornDopplerMs * unit * depth;
    const double drumBase = kDrumBaseMs * unit, drumDop = kDrumDopplerMs * unit * depth;
    const float hornAm = 0.5f * kHornAm * depth, drumAm = 0.5f * kDrumAm * depth;
    const float hornPan = 0.5f * kHornPan * depth, drumPan = 0.5f * kDrumPan * depth;
    const float balance = smoothedFeedback_;
    const float hornGain = std::min(1.0f, 2.0f * balance);
    const float drumGain = std::min(1.0f, 2.0f * (1.0f - balance));
    const float lpCoeff = onePole(kRotaryCrossoverHz);
    Phasor horn, drum;
    horn.start(phase_[0], step);
    drum.start(phase_[1], step * kRotaryDrumRatio);
    for (size_t i = 0; i < n; ++i) {
      gain += gainStep;
      horn.advance();
      drum.advance();
      // Nearest to the listener at phase 0: shortest path, loudest, centred.
      const double dH = tapDelay(hornBase - hornDop * horn.c);
      const double dD = tapDelay(drumBase - drumDop * drum.c);
      const float hs = static_cast<float>(horn.s), hc = static_cast<float>(horn.c);
      const float ds = static_cast<float>(drum.s), dc = static_cast<float>(drum.c);
      const float aH = hornGain * (1.0f - hornAm * (1.0f - hc));
      const float aD = drumGain * (1.0f - drumAm * (1.0f - dc));
      const float wL = rotaryChannel(0, l[i], lpCoeff, dH, dD,
                                     aH * (1.0f - hornPan * (1.0f - hs)),
                                     aD * (1.0f - drumPan * (1.0f - ds)));
      const float wR = rotaryChannel(1, r[i], lpCoeff, dH, dD,
                                     aH * (1.0f - hornPan * (1.0f + hs)),
                                     aD * (1.0f - drumPan * (1.0f + ds)));
      l[i] += gain * (wL - l[i]);
      r[i] += gain * (wR - r[i]);
    }
  }

  double rate_ = 48000.0;
  double maxDelay_ = 0.0;
  DelayLine lineA_[2], lineB_[2];
  float apState_[2][kPhaserStages] = {};
  float phaserOut_[2] = {0.0f, 0.0f};
  float crossoverLp_[2] = {0.0f, 0.0f};
  double phase_[2] = {0.0, 0.0};
  float smoothedRate_ = 1.0f;
  float smoothedDepth_ = 0.0f, smoothedFeedback_ = 0.0f, smoothedMix_ = 0.0f;
  float fade_ = 0.0f, wetGain_ = 0.0f;
  int activeType_ = kChorus;
  bool primed_ = false;
  bool cleared_ = true;
};

}  // namespace NAMRig
