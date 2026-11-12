#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace NAMRig {

// Low-latency polyphonic transient-preserving WSOLA pitch shifter for pre-amp
// guitar Drop Tuning / Virtual Capo (-12 to +12 semitones).
//
// Improvements over v1:
//  - 36 ms Hann grains / +/-10 ms search span / 12 ms bidirectional matching
//    window ([-6 ms, +6 ms]) with energy-consistent similarity so low notes
//    (down to B1/A1) lock cleanly to full cycles.
//  - Anti-flam / anti-skip transient lock: detects guitar pick attacks and
//    locks both overlapping grains to the same read position across the attack
//    so chugs pass through without overlap smearing or double attacks.
//  - Correlation-adaptive power normalization across crossfades to remove
//    18 ms AM flutter on chords.
//  - Gentle pickup-character / presence shelf & sub-rumble filter when active
//    so shifted tones keep their bite before hitting overdrive/amp models.
//  - Zero heap allocations and bit-identical bypass when semitones == 0.
class DropPitch {
 public:
  static constexpr int kMinSemitones = -12;
  static constexpr int kMaxSemitones = 12;
  static constexpr int kRingSize = 65536;
  static constexpr int kRingMask = kRingSize - 1;
  static constexpr int kMaxWindow = 8192;
  static constexpr int kMaxCorr = 2560;

  DropPitch() { prepare(48000.0); }

  void prepare(double sampleRate) noexcept {
    sampleRate_ = std::clamp(sampleRate > 0.0 ? sampleRate : 48000.0, 22050.0, 192000.0);
    // ~18 ms half-window hop (36 ms Hann grain), forced even via winLen = 2 * hs.
    hs_ = std::clamp(static_cast<int>(std::lround(sampleRate_ * 0.018)), 384, kMaxWindow / 2);
    winLen_ = hs_ * 2;
    // ~10 ms search radius (+/- 10 ms = 20 ms span, covers full period down to 50 Hz).
    searchRadius_ = std::clamp(static_cast<int>(std::lround(sampleRate_ * 0.010)), 220, 2048);
    // ~12 ms bidirectional correlation template ([-corrHalf_, +corrHalf_)).
    corrHalf_ = std::clamp(static_cast<int>(std::lround(sampleRate_ * 0.006)), 128, kMaxCorr / 2);
    corrLen_ = corrHalf_ * 2;
    fadeSamples_ = std::max(1, static_cast<int>(std::lround(sampleRate_ * 0.005)));

    // Transient detector and anti-flam window (~14 ms mark, ~28 ms cooldown).
    fastCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.001));
    slowCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.035));
    attackMarkSamples_ = std::max(16, static_cast<int>(std::lround(sampleRate_ * 0.014)));
    transientCooldownSamples_ = std::max(32, static_cast<int>(std::lround(sampleRate_ * 0.028)));
    maxTransientDrift_ = std::max(64, static_cast<int>(std::lround(sampleRate_ * 0.015)));

    constexpr double kTwoPi = 6.28318530717958647692;
    for (int i = 0; i < winLen_; ++i) {
      hann_[static_cast<size_t>(i)] =
          static_cast<float>(0.5 * (1.0 - std::cos(kTwoPi * static_cast<double>(i) / winLen_)));
    }
    reset();
  }

  void reset() noexcept {
    ring_.fill(0.0f);
    transientRing_.fill(0);
    writePos_ = 0;
    active_ = false;
    currentSemitones_ = 0;
    wetMix_ = 0.0f;
    overlapRho_ = 1.0f;
    prevDry_ = 0.0f;
    fastEnv_ = 0.0f;
    slowEnv_ = 0.0f;
    transientCooldown_ = 0;
    transientMarkLeft_ = 0;
    lastTransientEndPos_ = -1;
    appliedFilterSt_ = 0;
    subHpf_.reset();
    presenceShelf_.reset();
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

    if (targetSt == 0 && !active_) {
      // Keep the history and transient detector warm so engaging has real
      // audio immediately; output stays bit-identical.
      for (uint32_t i = 0; i < count; ++i) {
        pushInputSample(samples[i]);
      }
      return;
    }

    if (targetSt != 0 && !active_) {
      active_ = true;
      currentSemitones_ = targetSt;
      wetMix_ = 0.0f;
      overlapRho_ = 1.0f;
      subHpf_.reset();
      presenceShelf_.reset();
      appliedFilterSt_ = 0;
      initGrains(std::pow(2.0, static_cast<double>(targetSt) / 12.0));
    } else if (targetSt != 0 && targetSt != currentSemitones_) {
      currentSemitones_ = targetSt;
    }

    if (currentSemitones_ != appliedFilterSt_) {
      configureToneCompensation(currentSemitones_);
      appliedFilterSt_ = currentSemitones_;
    }

    const double targetRatio = std::pow(2.0, static_cast<double>(currentSemitones_) / 12.0);
    const float fadeStep = 1.0f / static_cast<float>(fadeSamples_);
    const float targetWet = targetSt != 0 ? 1.0f : 0.0f;

    for (uint32_t i = 0; i < count; ++i) {
      const float dry = samples[i];
      pushInputSample(dry);

      float w[2] = {0.0f, 0.0f};
      float y[2] = {0.0f, 0.0f};
      for (int g = 0; g < 2; ++g) {
        Grain& gr = grains_[static_cast<size_t>(g)];
        if (gr.phase >= winLen_) {
          restartGrain(g, targetRatio);
        }
        w[g] = hann_[static_cast<size_t>(gr.phase)];
        y[g] = readCubic(gr.readPos);
        gr.readPos += gr.ratio;
        ++gr.phase;
      }

      const float powerVar =
          w[0] * w[0] + w[1] * w[1] + 2.0f * w[0] * w[1] * overlapRho_;
      const float norm = 1.0f / std::sqrt(std::max(0.5f, powerVar));
      float wet = (y[0] * w[0] + y[1] * w[1]) * norm;
      if (currentSemitones_ < 0) {
        wet = subHpf_.process(wet);
      }
      wet = presenceShelf_.process(wet);

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
      appliedFilterSt_ = 0;
      subHpf_.reset();
      presenceShelf_.reset();
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

  struct Biquad {
    float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f, a1 = 0.0f, a2 = 0.0f;
    float z1 = 0.0f, z2 = 0.0f;

    void reset() noexcept { z1 = z2 = 0.0f; }

    void setHighPass(double rate, double freqHz, double q) noexcept {
      const double w0 = 6.28318530717958647692 * freqHz / rate;
      const double cosw = std::cos(w0);
      const double alpha = std::sin(w0) / (2.0 * q);
      const double a0 = 1.0 + alpha;
      b0 = static_cast<float>((1.0 + cosw) * 0.5 / a0);
      b1 = static_cast<float>(-(1.0 + cosw) / a0);
      b2 = b0;
      a1 = static_cast<float>(-2.0 * cosw / a0);
      a2 = static_cast<float>((1.0 - alpha) / a0);
    }

    void setHighShelf(double rate, double freqHz, double dbGain, double slope = 0.707) noexcept {
      const double A = std::pow(10.0, dbGain / 40.0);
      const double w0 = 6.28318530717958647692 * freqHz / rate;
      const double cosw = std::cos(w0);
      const double sinw = std::sin(w0);
      const double alpha = sinw * 0.5 * std::sqrt((A + 1.0 / A) * (1.0 / slope - 1.0) + 2.0);
      const double twoSqrtAAlpha = 2.0 * std::sqrt(A) * alpha;
      const double a0 = (A + 1.0) - (A - 1.0) * cosw + twoSqrtAAlpha;
      b0 = static_cast<float>((A * ((A + 1.0) + (A - 1.0) * cosw + twoSqrtAAlpha)) / a0);
      b1 = static_cast<float>((-2.0 * A * ((A - 1.0) + (A + 1.0) * cosw)) / a0);
      b2 = static_cast<float>((A * ((A + 1.0) + (A - 1.0) * cosw - twoSqrtAAlpha)) / a0);
      a1 = static_cast<float>((2.0 * ((A - 1.0) - (A + 1.0) * cosw)) / a0);
      a2 = static_cast<float>(((A + 1.0) - (A - 1.0) * cosw - twoSqrtAAlpha) / a0);
    }

    float process(float x) noexcept {
      const float y = b0 * x + z1;
      z1 = b1 * x - a1 * y + z2;
      z2 = b2 * x - a2 * y;
      return y;
    }
  };

  void configureToneCompensation(int semitones) noexcept {
    if (semitones < 0) {
      subHpf_.setHighPass(sampleRate_, 26.0, 0.707);
      const double boostDb = std::min(4.2, 0.50 * static_cast<double>(-semitones));
      presenceShelf_.setHighShelf(sampleRate_, 2400.0, boostDb, 0.707);
    } else if (semitones > 0) {
      subHpf_.reset();
      const double cutDb = -std::min(3.5, 0.40 * static_cast<double>(semitones));
      presenceShelf_.setHighShelf(sampleRate_, 2800.0, cutDb, 0.707);
    }
  }

  void pushInputSample(float dry) noexcept {
    const float absIn = std::fabs(dry);
    const float hf = std::fabs(dry - prevDry_);
    prevDry_ = dry;
    const float impulse = 0.65f * absIn + 0.85f * hf;
    fastEnv_ += (impulse - fastEnv_) * fastCoeff_;
    slowEnv_ += (impulse - slowEnv_) * slowCoeff_;

    if (transientCooldown_ > 0) --transientCooldown_;
    if (transientCooldown_ == 0 && fastEnv_ > 0.004f && fastEnv_ > slowEnv_ * 2.3f) {
      transientMarkLeft_ = attackMarkSamples_;
      transientCooldown_ = transientCooldownSamples_;
    }

    const size_t slot = static_cast<size_t>(writePos_ & kRingMask);
    ring_[slot] = dry;
    if (transientMarkLeft_ > 0) {
      transientRing_[slot] = 1;
      lastTransientEndPos_ = static_cast<int64_t>(writePos_);
      --transientMarkLeft_;
    } else {
      transientRing_[slot] = 0;
    }
    ++writePos_;
  }

  int minDelayForRatio(double ratio) const noexcept {
    const int corrLookahead = static_cast<int>(std::ceil(static_cast<double>(corrHalf_) * ratio));
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

  bool hasTransientInSpan(int64_t startIdx, int64_t endIdx) const noexcept {
    if (endIdx < startIdx) return false;
    const int step = std::max(1, attackMarkSamples_ / 16);
    for (int64_t idx = startIdx; idx <= endIdx; idx += step) {
      if (transientRing_[static_cast<size_t>(idx & kRingMask)]) return true;
    }
    return transientRing_[static_cast<size_t>(endIdx & kRingMask)] != 0;
  }

  void restartGrain(int gIdx, double nextRatio) noexcept {
    const Grain& other = grains_[static_cast<size_t>(1 - gIdx)];
    const int minDelay = minDelayForRatio(nextRatio);
    const int targetDelay = searchRadius_ + minDelay;
    const double nominal = static_cast<double>(writePos_) - static_cast<double>(targetDelay);
    const double maxReadAllowed = static_cast<double>(writePos_) - static_cast<double>(minDelay);
    const double minReadAllowed = static_cast<double>(writePos_) -
                                  static_cast<double>(targetDelay + maxTransientDrift_);

    // 1. Transient lock: if a pick attack is entering or spanning the active
    //    grain's window (or lies between other.readPos and the jump target),
    //    lock the new grain to other.readPos so both grains play the identical
    //    trajectory with zero crossfade smearing or attack skipping.
    const int64_t checkStart = static_cast<int64_t>(std::floor(other.readPos)) - corrHalf_ / 4;
    const int64_t checkEnd = static_cast<int64_t>(std::ceil(
        std::max(other.readPos + static_cast<double>(hs_) * other.ratio,
                 nominal + static_cast<double>(searchRadius_))));
    const bool lockSafe =
        (other.ratio == nextRatio) &&
        (other.readPos <= maxReadAllowed) &&
        (other.readPos >= minReadAllowed) &&
        (static_cast<double>(writePos_) - other.readPos < static_cast<double>(kRingSize - kMaxWindow * 2));

    if (lockSafe && hasTransientInSpan(checkStart, checkEnd)) {
      grains_[static_cast<size_t>(gIdx)] = {other.readPos, nextRatio, 0};
      overlapRho_ = 1.0f;
      return;
    }

    // 2. Sustained-body WSOLA: 12 ms bidirectional correlation template centered
    //    at the splice point, scored by energy-consistent normalized similarity.
    float refEnergy = 0.0f;
    for (int m = 0; m < corrLen_; ++m) {
      const int offset = m - corrHalf_;
      const float s = readCubic(other.readPos + static_cast<double>(offset) * other.ratio);
      refBuf_[static_cast<size_t>(m)] = s;
      refEnergy += s * s;
    }

    int bestDelta = 0;
    float bestRho = 1.0f;
    if (refEnergy > 1.0e-8f) {
      const int coarseStep = std::max(1, searchRadius_ / 110);
      const int corrStep = std::max(1, corrLen_ / 96);
      float bestScore = -1.0e30f;
      int bestCoarse = 0;

      const bool blockJumpBackPastTransient =
          lastTransientEndPos_ >= 0 &&
          lastTransientEndPos_ < static_cast<int64_t>(std::floor(other.readPos));

      const auto evalOffset = [&](int d, int step, float& outRho) -> float {
        const double candCenter = nominal + static_cast<double>(d);
        // Reject jumping backward to or before an already-played pick transient (anti-flam).
        if (blockJumpBackPastTransient &&
            static_cast<int64_t>(std::llround(candCenter)) <= lastTransientEndPos_) {
          outRho = 0.0f;
          return -1.0e20f;
        }
        float dot = 0.0f;
        float refSubE = 0.0f;
        float candE = 0.0f;
        for (int m = 0; m < corrLen_; m += step) {
          const int offset = m - corrHalf_;
          const int64_t idx =
              static_cast<int64_t>(std::floor(candCenter + static_cast<double>(offset) * nextRatio));
          const float r = refBuf_[static_cast<size_t>(m)];
          const float v = ring_[static_cast<size_t>(idx & kRingMask)];
          dot += r * v;
          refSubE += r * r;
          candE += v * v;
        }
        const float denomEnergy = refSubE + candE + 1.0e-12f;
        const float energyConsistentScore = (2.0f * dot) / denomEnergy;
        const float distPenalty =
            0.01f * static_cast<float>(std::abs(d)) / static_cast<float>(searchRadius_);
        outRho = dot / std::sqrt((refSubE * candE) + 1.0e-12f);
        return energyConsistentScore - distPenalty;
      };

      for (int d = -searchRadius_; d <= searchRadius_; d += coarseStep) {
        float rho = 0.0f;
        const float score = evalOffset(d, corrStep, rho);
        if (score > bestScore) {
          bestScore = score;
          bestCoarse = d;
          bestRho = rho;
        }
      }

      const int fineLo = std::max(-searchRadius_, bestCoarse - coarseStep);
      const int fineHi = std::min(searchRadius_, bestCoarse + coarseStep);
      const int fineStep = std::max(1, corrLen_ / 192);
      bestScore = -1.0e30f;
      bestDelta = bestCoarse;
      for (int d = fineLo; d <= fineHi; ++d) {
        float rho = 0.0f;
        const float score = evalOffset(d, fineStep, rho);
        if (score > bestScore) {
          bestScore = score;
          bestDelta = d;
          bestRho = rho;
        }
      }
    }

    grains_[static_cast<size_t>(gIdx)] = {
        nominal + static_cast<double>(bestDelta), nextRatio, 0};
    overlapRho_ = std::clamp(bestRho, 0.0f, 1.0f);
  }

  double sampleRate_ = 48000.0;
  int hs_ = 864;
  int winLen_ = 1728;
  int searchRadius_ = 480;
  int corrHalf_ = 288;
  int corrLen_ = 576;
  int fadeSamples_ = 240;

  float fastCoeff_ = 0.02f;
  float slowCoeff_ = 0.0006f;
  int attackMarkSamples_ = 672;
  int transientCooldownSamples_ = 1344;
  int maxTransientDrift_ = 720;

  std::array<float, kRingSize> ring_{};
  std::array<uint8_t, kRingSize> transientRing_{};
  std::array<float, kMaxWindow> hann_{};
  std::array<float, kMaxCorr> refBuf_{};
  uint64_t writePos_ = 0;
  std::array<Grain, 2> grains_{};
  bool active_ = false;
  int currentSemitones_ = 0;
  float wetMix_ = 0.0f;
  float overlapRho_ = 1.0f;

  float prevDry_ = 0.0f;
  float fastEnv_ = 0.0f;
  float slowEnv_ = 0.0f;
  int transientCooldown_ = 0;
  int transientMarkLeft_ = 0;
  int64_t lastTransientEndPos_ = -1;

  int appliedFilterSt_ = 0;
  Biquad subHpf_;
  Biquad presenceShelf_;
};

}  // namespace NAMRig
