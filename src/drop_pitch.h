#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace NAMRig {

// Low-latency polyphonic WSOLA (Waveform Similarity Overlap-Add) pitch shifter
// for pre-amp guitar Drop Tuning / Virtual Capo (-12 to +12 semitones).
//
// Designed for real-time audio threads: zero heap allocations, deterministic
// CPU cost, and exact bit-identical bypass when semitones == 0.
class DropPitch {
 public:
  static constexpr int kMinSemitones = -12;
  static constexpr int kMaxSemitones = 12;
  static constexpr int kRingSize = 32768;
  static constexpr int kRingMask = kRingSize - 1;
  static constexpr int kMaxWindow = 4096;
  static constexpr int kMaxCorr = 512;

  DropPitch() { prepare(48000.0); }

  void prepare(double sampleRate) noexcept {
    sampleRate_ = std::clamp(sampleRate > 0.0 ? sampleRate : 48000.0, 22050.0, 192000.0);
    // ~11 ms half-window hop (22 ms Hann grain), forced even via winLen = 2 * hs.
    hs_ = std::clamp(static_cast<int>(std::lround(sampleRate_ * 0.011)), 256, kMaxWindow / 2);
    winLen_ = hs_ * 2;
    // ~8.5 ms search radius (+/- 8.5 ms = 17 ms span, covers down to ~59 Hz B1).
    searchRadius_ = std::clamp(static_cast<int>(std::lround(sampleRate_ * 0.0085)), 192, 1600);
    // ~3.0 ms correlation window.
    corrLen_ = std::clamp(static_cast<int>(std::lround(sampleRate_ * 0.003)), 64, kMaxCorr);
    fadeSamples_ = std::max(1, static_cast<int>(std::lround(sampleRate_ * 0.005)));

    constexpr double kTwoPi = 6.28318530717958647692;
    for (int i = 0; i < winLen_; ++i) {
      hann_[static_cast<size_t>(i)] =
          static_cast<float>(0.5 * (1.0 - std::cos(kTwoPi * static_cast<double>(i) / winLen_)));
    }
    reset();
  }

  void reset() noexcept {
    ring_.fill(0.0f);
    writePos_ = 0;
    active_ = false;
    currentSemitones_ = 0;
    wetMix_ = 0.0f;
    initGrains(1.0);
  }

  int latencySamples(int semitones) const noexcept {
    const int st = clampSemitones(semitones);
    if (st == 0) return 0;
    const double ratio = std::pow(2.0, static_cast<double>(st) / 12.0);
    return searchRadius_ + minDelayForRatio(ratio);
  }

  void process(float* samples, uint32_t count, int semitones) noexcept {
    if (!samples || count == 0) return;
    const int targetSt = clampSemitones(semitones);

    if (targetSt == 0 && !active_) return;

    if (targetSt != 0 && !active_) {
      ring_.fill(0.0f);
      writePos_ = 0;
      active_ = true;
      currentSemitones_ = targetSt;
      wetMix_ = 0.0f;
      initGrains(std::pow(2.0, static_cast<double>(targetSt) / 12.0));
    } else if (targetSt != 0 && targetSt != currentSemitones_) {
      currentSemitones_ = targetSt;
    }

    const double targetRatio = std::pow(2.0, static_cast<double>(currentSemitones_) / 12.0);
    const float fadeStep = 1.0f / static_cast<float>(fadeSamples_);
    const float targetWet = targetSt != 0 ? 1.0f : 0.0f;

    for (uint32_t i = 0; i < count; ++i) {
      const float dry = samples[i];
      ring_[static_cast<size_t>(writePos_ & kRingMask)] = dry;
      ++writePos_;

      float wet = 0.0f;
      for (int g = 0; g < 2; ++g) {
        Grain& gr = grains_[static_cast<size_t>(g)];
        if (gr.phase >= winLen_) {
          restartGrain(g, targetRatio);
        }
        const float w = hann_[static_cast<size_t>(gr.phase)];
        wet += readCubic(gr.readPos) * w;
        gr.readPos += gr.ratio;
        ++gr.phase;
      }

      if (wetMix_ < targetWet) {
        wetMix_ = std::min(targetWet, wetMix_ + fadeStep);
      } else if (wetMix_ > targetWet) {
        wetMix_ = std::max(targetWet, wetMix_ - fadeStep);
      }

      samples[i] = dry + (wet - dry) * wetMix_;
    }

    if (targetSt == 0 && wetMix_ <= 0.0f) {
      active_ = false;
      currentSemitones_ = 0;
    }
  }

  static int clampSemitones(int semitones) noexcept {
    return std::clamp(semitones, kMinSemitones, kMaxSemitones);
  }

 private:
  static constexpr int kSafetyMargin = 32;

  struct Grain {
    double readPos = 0.0;
    double ratio = 1.0;
    int phase = 0;
  };

  int minDelayForRatio(double ratio) const noexcept {
    const int corrLookahead = static_cast<int>(std::ceil(static_cast<double>(corrLen_) * ratio));
    const int grainLookahead = ratio > 1.0 ? static_cast<int>(std::ceil(winLen_ * (ratio - 1.0))) : 0;
    return kSafetyMargin + std::max(corrLookahead, grainLookahead);
  }

  void initGrains(double ratio) noexcept {
    const double startPos =
        static_cast<double>(writePos_) - static_cast<double>(searchRadius_ + minDelayForRatio(ratio));
    grains_[0] = {startPos, ratio, 0};
    grains_[1] = {startPos, ratio, hs_};
  }

  float readCubic(double pos) const noexcept {
    const int64_t i1 = static_cast<int64_t>(std::floor(pos));
    const float t = static_cast<float>(pos - static_cast<double>(i1));
    const float y0 = ring_[static_cast<size_t>((i1 - 1) & kRingMask)];
    const float y1 = ring_[static_cast<size_t>(i1 & kRingMask)];
    const float y2 = ring_[static_cast<size_t>((i1 + 1) & kRingMask)];
    const float y3 = ring_[static_cast<size_t>((i1 + 2) & kRingMask)];
    const float c0 = y1;
    const float c1 = 0.5f * (y2 - y0);
    const float c2 = y0 - 2.5f * y1 + 2.0f * y2 - 0.5f * y3;
    const float c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
    return ((c3 * t + c2) * t + c1) * t + c0;
  }

  void restartGrain(int gIdx, double nextRatio) noexcept {
    const Grain& other = grains_[static_cast<size_t>(1 - gIdx)];
    float refEnergy = 0.0f;
    for (int m = 0; m < corrLen_; ++m) {
      const float s = readCubic(other.readPos + static_cast<double>(m) * other.ratio);
      refBuf_[static_cast<size_t>(m)] = s;
      refEnergy += s * s;
    }

    const int targetDelay = searchRadius_ + minDelayForRatio(nextRatio);
    const double nominal = static_cast<double>(writePos_) - static_cast<double>(targetDelay);

    int bestDelta = 0;
    if (refEnergy > 1.0e-8f) {
      const int coarseStep = std::max(1, searchRadius_ / 100);
      const int corrStep = std::max(1, corrLen_ / 72);
      float bestScore = -1.0e30f;
      int bestCoarse = 0;

      for (int d = -searchRadius_; d <= searchRadius_; d += coarseStep) {
        float dot = 0.0f;
        float candEnergy = 0.0f;
        const double base = nominal + static_cast<double>(d);
        for (int m = 0; m < corrLen_; m += corrStep) {
          const int64_t idx = static_cast<int64_t>(base + static_cast<double>(m) * nextRatio);
          const float v = ring_[static_cast<size_t>(idx & kRingMask)];
          dot += refBuf_[static_cast<size_t>(m)] * v;
          candEnergy += v * v;
        }
        const float score = dot / std::sqrt(candEnergy + 1.0e-12f);
        if (score > bestScore) {
          bestScore = score;
          bestCoarse = d;
        }
      }

      const int fineLo = std::max(-searchRadius_, bestCoarse - coarseStep);
      const int fineHi = std::min(searchRadius_, bestCoarse + coarseStep);
      const int fineStep = std::max(1, corrLen_ / 144);
      bestScore = -1.0e30f;
      bestDelta = bestCoarse;
      for (int d = fineLo; d <= fineHi; ++d) {
        float dot = 0.0f;
        float candEnergy = 0.0f;
        const double base = nominal + static_cast<double>(d);
        for (int m = 0; m < corrLen_; m += fineStep) {
          const int64_t idx = static_cast<int64_t>(base + static_cast<double>(m) * nextRatio);
          const float v = ring_[static_cast<size_t>(idx & kRingMask)];
          dot += refBuf_[static_cast<size_t>(m)] * v;
          candEnergy += v * v;
        }
        const float score = dot / std::sqrt(candEnergy + 1.0e-12f);
        if (score > bestScore) {
          bestScore = score;
          bestDelta = d;
        }
      }
    }

    grains_[static_cast<size_t>(gIdx)] = {
        nominal + static_cast<double>(bestDelta), nextRatio, 0};
  }

  double sampleRate_ = 48000.0;
  int hs_ = 528;
  int winLen_ = 1056;
  int searchRadius_ = 408;
  int corrLen_ = 144;
  int fadeSamples_ = 240;

  std::array<float, kRingSize> ring_{};
  std::array<float, kMaxWindow> hann_{};
  std::array<float, kMaxCorr> refBuf_{};
  uint64_t writePos_ = 0;
  std::array<Grain, 2> grains_{};
  bool active_ = false;
  int currentSemitones_ = 0;
  float wetMix_ = 0.0f;
};

}  // namespace NAMRig
