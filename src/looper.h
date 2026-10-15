#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

namespace NAMRig {

// Single-loop stereo looper. The buffer is allocated once in initialize and
// never resized on the audio thread. Material written into the loop is faded
// over ~5 ms at the loop start (at write time) and at the loop end (when the
// length is fixed, or at write time while overdubbing), so the seam never
// clicks; playback stops through a 5 ms gain ramp. The dry input always
// passes through.
class Looper {
 public:
  enum State { kStop = 0, kRecord, kPlay, kOverdub, kStateCount };

  void initialize(double rate, double maxSeconds) {
    rate_ = rate > 0.0 ? rate : 48000.0;
    if (!std::isfinite(maxSeconds) || maxSeconds <= 0.0) maxSeconds = 1.0;
    capacity_ = std::max<size_t>(1, static_cast<size_t>(std::ceil(rate_ * maxSeconds)));
    left_.assign(capacity_, 0.0f);
    right_.assign(capacity_, 0.0f);
    fadeSamples_ = std::max<size_t>(1, static_cast<size_t>(std::lround(rate_ * 0.005)));
    fadeStep_ = 1.0f / static_cast<float>(fadeSamples_);
    reset();
  }
  void reset() {
    length_ = 0;
    position_ = 0;
    state_ = kStop;
    playGain_ = 0.0f;
    levelPrimed_ = false;
  }
  // Stereo in place: while kRecord/kOverdub the input is written into the loop; while kPlay/kOverdub
  // the loop is mixed in: out = in + loop * level. The dry input always passes.
  // Transitions (driven by the requested `state` each block):
  //   kStop -> kRecord: erase and start a new loop.    kRecord -> kPlay/kOverdub: fix the loop length.
  //   kPlay <-> kOverdub: layer onto the loop (overdub writes in + existing with soft limiting).
  //   any -> kStop: stop playback (loop kept). kStop -> kPlay: play the existing loop from the start.
  //   Recording beyond maxSeconds auto-switches to kPlay.
  // A ~5 ms crossfade at the loop seam and on start/stop avoids clicks.
  void process(float* left, float* right, size_t count, int state, float levelDb) {
    if (capacity_ == 0 || left_.empty()) return;
    if (state >= 0 && state < kStateCount) transition(static_cast<State>(state));
    const float db = std::isfinite(levelDb) ? std::max(-60.0f, std::min(12.0f, levelDb)) : 0.0f;
    const float levelTarget = db <= -59.99f ? 0.0f : std::pow(10.0f, db * 0.05f);
    if (!levelPrimed_) {
      smoothedLevel_ = levelTarget;
      levelPrimed_ = true;
    }
    const float glide = static_cast<float>(1.0 - std::exp(-static_cast<double>(kChunk) / (rate_ * 0.020)));
    for (size_t start = 0; start < count; start += kChunk) {
      const size_t m = std::min(kChunk, count - start);
      const float levelFrom = smoothedLevel_;
      glideValue(smoothedLevel_, levelTarget, glide, 1.0e-4f);
      const float levelStep = (smoothedLevel_ - levelFrom) / static_cast<float>(m);
      float level = levelFrom;
      for (size_t i = start; i < start + m; ++i) {
        level += levelStep;
        const float inL = left[i], inR = right[i];
        switch (state_) {
          case kRecord: {
            const float w = position_ < fadeSamples_
                ? static_cast<float>(position_ + 1) * fadeStep_ : 1.0f;
            left_[position_] = inL * w;
            right_[position_] = inR * w;
            if (++position_ >= capacity_) {
              fixLength();
              state_ = kPlay;
              playGain_ = 1.0f;
            }
            break;
          }
          case kPlay:
          case kOverdub: {
            playGain_ = std::min(1.0f, playGain_ + fadeStep_);
            const float loopL = left_[position_], loopR = right_[position_];
            left[i] = inL + loopL * playGain_ * level;
            right[i] = inR + loopR * playGain_ * level;
            if (state_ == kOverdub) {
              const float w = seamWindow(position_);
              left_[position_] = limit(loopL + inL * w);
              right_[position_] = limit(loopR + inR * w);
            }
            if (++position_ >= length_) position_ = 0;
            break;
          }
          case kStop:
          default: {
            if (playGain_ <= 0.0f || length_ == 0) break;
            playGain_ -= fadeStep_;
            if (playGain_ <= 0.0f) {
              playGain_ = 0.0f;
              position_ = 0;
              break;
            }
            left[i] = inL + left_[position_] * playGain_ * level;
            right[i] = inR + right_[position_] * playGain_ * level;
            if (++position_ >= length_) position_ = 0;
            break;
          }
        }
      }
    }
  }
  bool hasLoop() const { return length_ > 0; }
  double lengthSeconds() const { return static_cast<double>(length_) / rate_; }
  // 0..1 through the loop, 0 when stopped. While recording it is the progress toward maxSeconds.
  float positionFraction() const {
    if (state_ == kStop) return 0.0f;
    if (state_ == kRecord) return static_cast<float>(position_) / static_cast<float>(capacity_);
    return length_ > 0 ? static_cast<float>(position_) / static_cast<float>(length_) : 0.0f;
  }
  State state() const { return state_; }

 private:
  static constexpr size_t kChunk = 32;

  static void glideValue(float& value, float target, float coeff, float snap) {
    value += (target - value) * coeff;
    if (std::fabs(target - value) < snap) value = target;
  }
  // Identity below 0.8, then a tanh bend that never exceeds 1.0, so stacked
  // overdubs cannot clip while untouched material stays bit-exact.
  static float limit(float x) {
    constexpr float t = 0.8f;
    const float a = std::fabs(x);
    if (a <= t) return x;
    const float y = t + (1.0f - t) * std::tanh((a - t) / (1.0f - t));
    return x < 0.0f ? -y : y;
  }
  float seamWindow(size_t position) const {
    const float in = static_cast<float>(position + 1) * fadeStep_;
    const float out = static_cast<float>(length_ - position) * fadeStep_;
    return std::min(1.0f, std::min(in, out));
  }
  void fixLength() {
    length_ = position_;
    position_ = 0;
    if (length_ == 0) return;
    const size_t fade = std::min(fadeSamples_, length_);
    for (size_t k = 0; k < fade; ++k) {
      const size_t idx = length_ - 1 - k;
      const float w = static_cast<float>(k + 1) * fadeStep_;
      left_[idx] *= w;
      right_[idx] *= w;
    }
  }
  void transition(State requested) {
    if (requested == state_) return;
    switch (requested) {
      case kRecord:
        length_ = 0;
        position_ = 0;
        playGain_ = 0.0f;
        state_ = kRecord;
        break;
      case kPlay:
      case kOverdub:
        if (state_ == kRecord) {
          fixLength();
          playGain_ = 1.0f;
        }
        if (length_ == 0) {
          state_ = kStop;
          position_ = 0;
          playGain_ = 0.0f;
          break;
        }
        if (state_ == kStop) position_ = 0;
        state_ = requested;
        break;
      case kStop:
      default:
        if (state_ == kRecord) fixLength();
        state_ = kStop;
        break;
    }
  }

  double rate_ = 48000.0;
  std::vector<float> left_, right_;
  size_t capacity_ = 0, length_ = 0, position_ = 0;
  size_t fadeSamples_ = 1;
  float fadeStep_ = 1.0f;
  float playGain_ = 0.0f;
  float smoothedLevel_ = 1.0f;
  bool levelPrimed_ = false;
  State state_ = kStop;
};

}  // namespace NAMRig
