#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

namespace NAMRig {

// Post-rig stereo width and compact room ambience. The width path delays only
// the right channel (0..12 ms); Room adds four low-level, decorrelated early
// reflections (roughly 17..43 ms). Both controls bypass bit-transparently at 0.
class StereoSpace {
public:
  void initialize(double sampleRate) {
    rate_ = sampleRate > 0.0 ? sampleRate : 48000.0;
    const size_t capacity = static_cast<size_t>(std::ceil(rate_ * 0.060)) + 2;
    history_.assign(capacity, 0.0f);
    write_ = 0;
    smoothedWidth_ = 0.0f;
    smoothedRoom_ = 0.0f;
  }

  void reset() {
    std::fill(history_.begin(), history_.end(), 0.0f);
    write_ = 0;
    smoothedWidth_ = 0.0f;
    smoothedRoom_ = 0.0f;
  }

  void process(float* left, float* right, size_t count,
               float widthPercent, float roomPercent) {
    if (!left || !right || history_.empty()) return;
    const float widthTarget = clamp01(widthPercent * 0.01f);
    const float roomTarget = clamp01(roomPercent * 0.01f);
    if (widthTarget == 0.0f && roomTarget == 0.0f &&
        smoothedWidth_ == 0.0f && smoothedRoom_ == 0.0f) {
      for (size_t i = 0; i < count; ++i) right[i] = left[i];
      return;
    }

    const float smooth = 1.0f - std::exp(-1.0f /
        static_cast<float>(rate_ * 0.010));
    for (size_t i = 0; i < count; ++i) {
      const float dry = left[i];
      history_[write_] = dry;
      smoothedWidth_ += (widthTarget - smoothedWidth_) * smooth;
      smoothedRoom_ += (roomTarget - smoothedRoom_) * smooth;

      // A short right-only delay creates width without changing the established
      // left path. At maximum the offset is 12 ms; at zero it is exact dual mono.
      const size_t widthDelay = static_cast<size_t>(
          std::lround(rate_ * 0.012 * smoothedWidth_));
      const float widenedRight = delayed(widthDelay);
      float outLeft = dry;
      float outRight = dry + (widenedRight - dry) * smoothedWidth_;

      // Sparse early reflections approximate a small studio room. Unequal taps
      // and opposite routing decorrelate the sides without a feedback tail.
      const float room = smoothedRoom_;
      if (room > 0.0f) {
        const float earlyLeft = 0.55f * delayedMs(17.0) +
                                0.30f * delayedMs(37.0);
        const float earlyRight = 0.50f * delayedMs(23.0) -
                                 0.28f * delayedMs(43.0);
        const float wet = 0.32f * room;
        outLeft = dry * (1.0f - 0.10f * room) + earlyLeft * wet;
        outRight = outRight * (1.0f - 0.10f * room) + earlyRight * wet;
      }
      left[i] = outLeft;
      right[i] = outRight;
      write_ = (write_ + 1) % history_.size();
    }
  }

private:
  static float clamp01(float value) {
    return std::max(0.0f, std::min(1.0f, value));
  }
  float delayed(size_t samples) const {
    samples = std::min(samples, history_.size() - 1);
    return history_[(write_ + history_.size() - samples) % history_.size()];
  }
  float delayedMs(double milliseconds) const {
    return delayed(static_cast<size_t>(std::lround(rate_ * milliseconds * 0.001)));
  }

  double rate_ = 48000.0;
  std::vector<float> history_;
  size_t write_ = 0;
  float smoothedWidth_ = 0.0f;
  float smoothedRoom_ = 0.0f;
};

} // namespace NAMRig
