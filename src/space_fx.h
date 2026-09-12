#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

namespace NAMRig {

// Circular delay line with integer and linearly interpolated reads. Delay
// values are clamped to the allocated length so a stale control value can
// never read outside the buffer.
class DelayLine {
 public:
  void allocate(size_t samples) {
    buffer_.assign(std::max<size_t>(samples, 4) + 2, 0.0f);
    write_ = 0;
  }
  void clear() {
    std::fill(buffer_.begin(), buffer_.end(), 0.0f);
    write_ = 0;
  }
  size_t capacity() const { return buffer_.empty() ? 0 : buffer_.size() - 2; }
  void write(float x) {
    buffer_[write_] = x;
    write_ = write_ + 1 == buffer_.size() ? 0 : write_ + 1;
  }
  // delay 0 returns the most recently written sample, so a write-then-read
  // caller gets exactly the delay it requested.
  float read(size_t delay) const {
    delay = std::min(delay, capacity());
    const size_t n = buffer_.size();
    return buffer_[(write_ + n - 1 - delay) % n];
  }
  float readFrac(double delay) const {
    delay = std::min(std::max(delay, 0.0), static_cast<double>(capacity()));
    const size_t whole = static_cast<size_t>(delay);
    const float frac = static_cast<float>(delay - static_cast<double>(whole));
    const float a = read(whole);
    const float b = read(whole + 1);
    return a + (b - a) * frac;
  }

 private:
  std::vector<float> buffer_;
  size_t write_ = 0;
};

// Short stereo alignment delay for the second cabinet (0 .. maxMs).
class AlignDelay {
 public:
  void initialize(double rate, double maxMs) {
    rate_ = rate > 0.0 ? rate : 48000.0;
    maxSamples_ = rate_ * maxMs * 0.001;
    left_.allocate(static_cast<size_t>(std::ceil(maxSamples_)) + 4);
    right_.allocate(static_cast<size_t>(std::ceil(maxSamples_)) + 4);
    smoothed_ = 0.0;
  }
  void reset() {
    left_.clear();
    right_.clear();
    smoothed_ = 0.0;
    primed_ = false;
  }
  void process(float* left, float* right, size_t count, float delayMs) {
    const double target = std::max(0.0, std::min(maxSamples_,
        static_cast<double>(delayMs) * 0.001 * rate_));
    if (!primed_) {
      smoothed_ = target;
      primed_ = true;
    }
    if (target == 0.0 && smoothed_ == 0.0) {
      for (size_t i = 0; i < count; ++i) {
        left_.write(left[i]);
        right_.write(right[i]);
      }
      return;
    }
    const double coeff = 1.0 - std::exp(-1.0 / (rate_ * 0.020));
    for (size_t i = 0; i < count; ++i) {
      smoothed_ += (target - smoothed_) * coeff;
      if (std::fabs(target - smoothed_) < 1.0e-3) smoothed_ = target;
      left_.write(left[i]);
      right_.write(right[i]);
      left[i] = left_.readFrac(smoothed_);
      right[i] = right_.readFrac(smoothed_);
    }
  }

 private:
  double rate_ = 48000.0;
  double maxSamples_ = 0.0;
  double smoothed_ = 0.0;
  bool primed_ = false;
  DelayLine left_, right_;
};

// Stereo delay with a damped, softly limited feedback path. Mix 0 is an exact
// bypass; the lines are cleared while bypassed so re-engaging starts silent.
class StereoDelay {
 public:
  void initialize(double rate) {
    rate_ = rate > 0.0 ? rate : 48000.0;
    const size_t capacity = static_cast<size_t>(std::ceil(rate_ * 2.1)) + 8;
    left_.allocate(capacity);
    right_.allocate(capacity);
    reset();
  }
  void reset() {
    left_.clear();
    right_.clear();
    dampL_ = dampR_ = 0.0f;
    smoothedTime_ = 0.0;
    smoothedMix_ = 0.0f;
    cleared_ = true;
  }
  void process(float* left, float* right, size_t count, float timeMs,
               float feedbackPercent, float dampingPercent, float mixPercent) {
    const float mixTarget = clamp01(mixPercent * 0.01f);
    if (mixTarget <= 0.0f && smoothedMix_ <= 0.0f) {
      if (!cleared_) reset();
      return;
    }
    cleared_ = false;
    const double timeTarget = std::max(1.0, std::min(static_cast<double>(left_.capacity()) - 2.0,
        static_cast<double>(timeMs) * 0.001 * rate_));
    if (smoothedTime_ <= 0.0) smoothedTime_ = timeTarget;
    const float feedback = clamp01(feedbackPercent * 0.01f) * 0.95f;
    const double cutoff = 12000.0 * std::pow(0.125, clamp01(dampingPercent * 0.01f));
    const float dampCoeff = static_cast<float>(1.0 - std::exp(-2.0 * kPi * cutoff / rate_));
    const double timeCoeff = 1.0 - std::exp(-1.0 / (rate_ * 0.080));
    const float mixCoeff = static_cast<float>(1.0 - std::exp(-1.0 / (rate_ * 0.020)));
    for (size_t i = 0; i < count; ++i) {
      smoothedTime_ += (timeTarget - smoothedTime_) * timeCoeff;
      smoothedMix_ += (mixTarget - smoothedMix_) * mixCoeff;
      if (std::fabs(mixTarget - smoothedMix_) < 1.0e-4f) smoothedMix_ = mixTarget;
      // The read happens before this sample is written, so the line's newest
      // sample is already one behind the input.
      const double tapTime = smoothedTime_ - 1.0;
      const float tapL = left_.readFrac(tapTime);
      const float tapR = right_.readFrac(tapTime);
      dampL_ += (tapL - dampL_) * dampCoeff;
      dampR_ += (tapR - dampR_) * dampCoeff;
      left_.write(left[i] + soft(feedback * dampL_));
      right_.write(right[i] + soft(feedback * dampR_));
      left[i] += smoothedMix_ * tapL;
      right[i] += smoothedMix_ * tapR;
    }
  }

 private:
  static constexpr double kPi = 3.14159265358979323846;
  static float clamp01(float x) { return std::max(0.0f, std::min(1.0f, x)); }
  static float soft(float x) { return x / std::sqrt(1.0f + 0.25f * x * x); }

  double rate_ = 48000.0;
  DelayLine left_, right_;
  float dampL_ = 0.0f, dampR_ = 0.0f;
  double smoothedTime_ = 0.0;
  float smoothedMix_ = 0.0f;
  bool cleared_ = true;
};

// Plate reverb after Dattorro (1997) with an early-reflection cluster fed from
// the diffused input. Room controls the early reflections, Mix the plate tank.
// Both at zero is an exact bypass.
class PlateReverb {
 public:
  void initialize(double rate) {
    rate_ = rate > 0.0 ? rate : 48000.0;
    unit_ = rate_ / 29761.0;
    const double maxScale = unit_ * kMaxSize;
    predelay_.allocate(static_cast<size_t>(rate_ * 0.12) + 8);
    for (size_t i = 0; i < 4; ++i) inputAp_[i].allocate(sized(kInputAp[i], maxScale));
    early_.allocate(sized(48.0, rate_ * 0.001 * kMaxSize));
    tankAp1_[0].allocate(sized(672.0 + 2.0 * kModDepth, maxScale));
    tankAp1_[1].allocate(sized(908.0 + 2.0 * kModDepth, maxScale));
    tankDelay1_[0].allocate(sized(4453.0, maxScale));
    tankDelay1_[1].allocate(sized(4217.0, maxScale));
    tankAp2_[0].allocate(sized(1800.0, maxScale));
    tankAp2_[1].allocate(sized(2656.0, maxScale));
    tankDelay2_[0].allocate(sized(3720.0, maxScale));
    tankDelay2_[1].allocate(sized(3163.0, maxScale));
    reset();
  }
  void reset() {
    predelay_.clear();
    early_.clear();
    for (size_t i = 0; i < 4; ++i) inputAp_[i].clear();
    for (size_t b = 0; b < 2; ++b) {
      tankAp1_[b].clear();
      tankDelay1_[b].clear();
      tankAp2_[b].clear();
      tankDelay2_[b].clear();
      tankOut_[b] = 0.0f;
      damp_[b] = 0.0f;
    }
    bandwidth_ = 0.0f;
    earlyLpL_ = earlyLpR_ = 0.0f;
    lfoPhase_ = 0.0;
    smoothedRoom_ = smoothedMix_ = 0.0f;
    smoothedSize_ = -1.0f;
    cleared_ = true;
  }
  void process(float* left, float* right, size_t count, float roomPercent,
               float mixPercent, float decayPercent, float sizePercent,
               float dampingPercent, float predelayMs) {
    const float roomTarget = clamp01(roomPercent * 0.01f);
    const float mixTarget = clamp01(mixPercent * 0.01f);
    if (roomTarget <= 0.0f && mixTarget <= 0.0f &&
        smoothedRoom_ <= 0.0f && smoothedMix_ <= 0.0f) {
      if (!cleared_) reset();
      return;
    }
    cleared_ = false;
    const float sizeTarget = 0.6f + 0.8f * clamp01(sizePercent * 0.01f);
    if (smoothedSize_ < 0.0f) smoothedSize_ = sizeTarget;
    const float decay = 0.30f + 0.68f * clamp01(decayPercent * 0.01f);
    const double dampCutoff = 15000.0 * std::pow(0.1, clamp01(dampingPercent * 0.01f));
    const float dampCoeff = static_cast<float>(1.0 - std::exp(-2.0 * kPi * dampCutoff / rate_));
    const float bandwidthCoeff = static_cast<float>(1.0 - std::exp(-2.0 * kPi * 10000.0 / rate_));
    const double predelaySamples = std::max(1.0, std::min(rate_ * 0.1,
        static_cast<double>(predelayMs) * 0.001 * rate_));
    const float ctlCoeff = static_cast<float>(1.0 - std::exp(-1.0 / (rate_ * 0.020)));
    const float sizeCoeff = static_cast<float>(1.0 - std::exp(-1.0 / (rate_ * 0.250)));
    const double lfoStep = 2.0 * kPi * 0.9 / rate_;
    const double msUnit = rate_ * 0.001;

    for (size_t i = 0; i < count; ++i) {
      smoothedRoom_ += (roomTarget - smoothedRoom_) * ctlCoeff;
      smoothedMix_ += (mixTarget - smoothedMix_) * ctlCoeff;
      if (std::fabs(roomTarget - smoothedRoom_) < 1.0e-4f) smoothedRoom_ = roomTarget;
      if (std::fabs(mixTarget - smoothedMix_) < 1.0e-4f) smoothedMix_ = mixTarget;
      smoothedSize_ += (sizeTarget - smoothedSize_) * sizeCoeff;
      const double scale = unit_ * smoothedSize_;
      const double earlyScale = msUnit * smoothedSize_;
      lfoPhase_ += lfoStep;
      if (lfoPhase_ > 2.0 * kPi) lfoPhase_ -= 2.0 * kPi;
      const double mod = kModDepth * scale * std::sin(lfoPhase_);

      const float input = 0.5f * (left[i] + right[i]);
      predelay_.write(input);
      const float pre = predelay_.readFrac(predelaySamples);
      bandwidth_ += (pre - bandwidth_) * bandwidthCoeff;
      float v = bandwidth_;
      v = allpass(inputAp_[0], v, kInputAp[0] * scale, 0.75f);
      v = allpass(inputAp_[1], v, kInputAp[1] * scale, 0.75f);
      v = allpass(inputAp_[2], v, kInputAp[2] * scale, 0.625f);
      v = allpass(inputAp_[3], v, kInputAp[3] * scale, 0.625f);

      early_.write(v);
      float earlyL = 0.0f, earlyR = 0.0f;
      for (size_t t = 0; t < 5; ++t) {
        earlyL += kEarlyGainL[t] * early_.readFrac(kEarlyMsL[t] * earlyScale);
        earlyR += kEarlyGainR[t] * early_.readFrac(kEarlyMsR[t] * earlyScale);
      }
      earlyLpL_ += (earlyL - earlyLpL_) * dampCoeff;
      earlyLpR_ += (earlyR - earlyLpR_) * dampCoeff;

      const float inL = v + decay * tankOut_[1];
      const float inR = v + decay * tankOut_[0];
      float a = allpass(tankAp1_[0], inL, 672.0 * scale + mod, -0.7f);
      tankDelay1_[0].write(a);
      damp_[0] += (tankDelay1_[0].readFrac(4453.0 * scale) - damp_[0]) * dampCoeff;
      a = allpass(tankAp2_[0], damp_[0] * decay, 1800.0 * scale, 0.5f);
      tankDelay2_[0].write(a);
      float b = allpass(tankAp1_[1], inR, 908.0 * scale - mod, -0.7f);
      tankDelay1_[1].write(b);
      damp_[1] += (tankDelay1_[1].readFrac(4217.0 * scale) - damp_[1]) * dampCoeff;
      b = allpass(tankAp2_[1], damp_[1] * decay, 2656.0 * scale, 0.5f);
      tankDelay2_[1].write(b);
      tankOut_[0] = tankDelay2_[0].readFrac(3720.0 * scale);
      tankOut_[1] = tankDelay2_[1].readFrac(3163.0 * scale);

      const float tankL = 0.6f * (tankDelay1_[1].readFrac(266.0 * scale) +
                                  tankDelay1_[1].readFrac(2974.0 * scale) -
                                  tankAp2_[1].readFrac(1913.0 * scale) +
                                  tankDelay2_[1].readFrac(1996.0 * scale) -
                                  tankDelay1_[0].readFrac(1990.0 * scale) -
                                  tankAp2_[0].readFrac(187.0 * scale) -
                                  tankDelay2_[0].readFrac(1066.0 * scale));
      const float tankR = 0.6f * (tankDelay1_[0].readFrac(353.0 * scale) +
                                  tankDelay1_[0].readFrac(3627.0 * scale) -
                                  tankAp2_[0].readFrac(1228.0 * scale) +
                                  tankDelay2_[0].readFrac(2673.0 * scale) -
                                  tankDelay1_[1].readFrac(2111.0 * scale) -
                                  tankAp2_[1].readFrac(335.0 * scale) -
                                  tankDelay2_[1].readFrac(121.0 * scale));

      left[i] += 0.35f * smoothedRoom_ * earlyLpL_ + smoothedMix_ * tankL;
      right[i] += 0.35f * smoothedRoom_ * earlyLpR_ + smoothedMix_ * tankR;
    }
  }

 private:
  static constexpr double kPi = 3.14159265358979323846;
  static constexpr double kMaxSize = 1.4;
  static constexpr double kModDepth = 12.0;
  static constexpr double kInputAp[4] = {142.0, 107.0, 379.0, 277.0};
  static constexpr double kEarlyMsL[5] = {11.3, 19.7, 27.1, 34.9, 41.3};
  static constexpr double kEarlyMsR[5] = {13.1, 17.3, 29.9, 37.7, 44.9};
  static constexpr float kEarlyGainL[5] = {0.90f, -0.70f, 0.55f, -0.40f, 0.30f};
  static constexpr float kEarlyGainR[5] = {0.85f, 0.75f, -0.50f, 0.45f, -0.28f};

  static size_t sized(double base, double scale) {
    return static_cast<size_t>(std::ceil(base * scale)) + 8;
  }
  static float clamp01(float x) { return std::max(0.0f, std::min(1.0f, x)); }
  static float allpass(DelayLine& line, float x, double delay, float g) {
    const float out = line.readFrac(delay);
    const float v = x - g * out;
    line.write(v);
    return out + g * v;
  }

  double rate_ = 48000.0;
  double unit_ = 1.0;
  DelayLine predelay_;
  DelayLine inputAp_[4];
  DelayLine early_;
  DelayLine tankAp1_[2], tankDelay1_[2], tankAp2_[2], tankDelay2_[2];
  float tankOut_[2] = {0.0f, 0.0f};
  float damp_[2] = {0.0f, 0.0f};
  float bandwidth_ = 0.0f;
  float earlyLpL_ = 0.0f, earlyLpR_ = 0.0f;
  double lfoPhase_ = 0.0;
  float smoothedRoom_ = 0.0f, smoothedMix_ = 0.0f, smoothedSize_ = -1.0f;
  bool cleared_ = true;
};

}  // namespace NAMRig
