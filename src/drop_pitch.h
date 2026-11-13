#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace NAMRig {

// Low-latency polyphonic pitch shifter for pre-amp guitar Drop Tuning /
// Virtual Capo (-12 to +12 semitones).
//
// A single resampling read tap follows the write head. The tap output is the
// exact resampled input, so there is no window modulation between splices.
// When the tap drifts away from the write head (drop) or reaches it (capo),
// the tap jumps by a waveform-matched distance and a short crossfade hides
// the splice:
//  - Drop: the tap jumps toward the write head as soon as one matched period
//    of drift is available, so the delay stays below one period of the note.
//  - Capo: the tap jumps back by the best matched distance when it reaches
//    the write head.
//  - Pick attacks move the tap to the write head immediately, so attacks are
//    not delayed, smeared, skipped, or played twice.
//  - Silence parks the tap at the write head.
//  - Splice positions use integer-lag matching on raw samples plus parabolic
//    sub-sample refinement.
//  - Zero heap allocations and bit-identical bypass when semitones == 0.
class DropPitch {
 public:
  static constexpr int kMinSemitones = -12;
  static constexpr int kMaxSemitones = 12;
  static constexpr int kRingSize = 65536;
  static constexpr int kRingMask = kRingSize - 1;
  static constexpr int kSnapRingSize = 8192;
  static constexpr int kSnapRingMask = kSnapRingSize - 1;

  DropPitch() { prepare(48000.0); }

  void prepare(double sampleRate) noexcept {
    sampleRate_ = std::clamp(sampleRate > 0.0 ? sampleRate : 48000.0, 22050.0, 192000.0);
    const auto ms = [this](double v) { return static_cast<int>(std::lround(sampleRate_ * v * 0.001)); };

    templateLen_ = std::max(64, ms(10.0));
    shortTemplateLen_ = std::max(16, ms(1.5));
    minJump_ = std::max(32, ms(2.5));
    maxSpan_ = std::max(minJump_ * 2, ms(42.0));
    attemptStep_ = std::max(4, ms(0.75));
    coarseStride_ = std::clamp(static_cast<int>(std::lround(sampleRate_ / 12000.0)), 1, kMaxStride);
    fineStride_ = std::max(1, (coarseStride_ + 1) / 2);
    xfadeMin_ = std::max(16, ms(3.0));
    xfadeMax_ = std::max(xfadeMin_, ms(8.0));
    xfadePostAttack_ = std::max(xfadeMin_, ms(4.0));
    xfadeFloor_ = std::max(8, ms(1.0));
    xfadeLowRho_ = std::max(xfadeFloor_, ms(2.0));
    xfadeTransient_ = std::max(6, ms(0.35));
    upXfadeCap_ = std::max(16, ms(5.0));
    preRoll_ = std::max(8, ms(2.0));
    transientGuard_ = std::max(16, ms(4.0));
    transientProtect_ = std::max(32, ms(12.0));
    postAttackWindow_ = std::max(transientProtect_, ms(45.0));
    quietHoldSamples_ = std::max(32, ms(18.0));
    minResyncGain_ = std::max(2, ms(0.25));
    minResyncGainDrop_ = std::max(8, ms(0.9));
    nominalSwing_ = std::max(8, ms(8.0));
    fadeSamples_ = std::max(1, ms(5.0));

    fastCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.0005));
    slowCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.024));
    transientCooldownSamples_ = std::max(32, ms(24.0));
    vetoCooldownSamples_ = std::max(16, ms(2.0));

    snapHoldSamples_ = std::max(6, ms(1.8));
    snapAttackCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.00005));
    snapDecayFactor_ = std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.0018));
    snapXoverCoeff_ = 1.0f - std::exp(-6.28318530717958647692f * 1600.0f / static_cast<float>(sampleRate_));

    detHpf_.setHighPass(sampleRate_, 850.0, 0.707);
    reset();
  }

  void reset() noexcept {
    ring_.fill(0.0f);
    snapRing_.fill(0.0f);
    writePos_ = 0;
    active_ = false;
    currentSemitones_ = 0;
    ratio_ = 1.0;
    wetMix_ = 0.0f;
    overlapRho_ = 1.0f;
    fastEnv_ = 0.0f;
    slowEnv_ = 0.0f;
    transientCooldown_ = 0;
    transientPending_ = false;
    lastTransientPos_ = -1;
    quietRun_ = kRingSize;
    appliedFilterSt_ = 0;
    subHpf_.reset();
    presenceShelf_.reset();
    detHpf_.reset();
    dryLpState_ = 0.0f;
    snapMix_ = 0.0f;
    snapEnv_ = 0.0f;
    snapGateLeft_ = 0;
    snapDelay_ = kHeadMargin;
    for (Voice& v : voices_) v = Voice{};
    lead_ = 0;
    fadeLen_ = 0;
    fadePos_ = 0;
    lastAttemptDelay_ = 0.0;
  }

  // Typical delay of a sustained note. The real delay follows the played
  // pitch and stays between the minimum tap delay and one matched period.
  int latencySamples(int semitones) const noexcept {
    const int st = clampSemitones(semitones);
    if (st == 0) return 0;
    const double ratio = std::pow(2.0, static_cast<double>(st) / 12.0);
    const double low = ratio < 1.0 ? static_cast<double>(kHeadMargin) : upLowDelay(ratio);
    return static_cast<int>(std::lround(low)) + nominalSwing_ / 2;
  }

  void process(float* samples, uint32_t count, int semitones) noexcept {
    if (!samples || count == 0) return;
    const int targetSt = clampSemitones(semitones);

    if (targetSt == 0 && !active_) {
      for (uint32_t i = 0; i < count; ++i) {
        pushInputSample(samples[i]);
      }
      transientPending_ = false;
      return;
    }

    if (targetSt != 0 && !active_) {
      active_ = true;
      currentSemitones_ = targetSt;
      ratio_ = std::pow(2.0, static_cast<double>(targetSt) / 12.0);
      wetMix_ = 0.0f;
      overlapRho_ = 1.0f;
      subHpf_.reset();
      presenceShelf_.reset();
      appliedFilterSt_ = 0;
      transientPending_ = false;
      lastTransientPos_ = -1;
      snapEnv_ = 0.0f;
      snapGateLeft_ = 0;
      snapDelay_ = kHeadMargin;
      startVoices();
    } else if (targetSt != 0 && targetSt != currentSemitones_) {
      currentSemitones_ = targetSt;
      ratio_ = std::pow(2.0, static_cast<double>(targetSt) / 12.0);
      lastAttemptDelay_ = leadDelay();
    }

    if (currentSemitones_ != appliedFilterSt_) {
      configureToneCompensation(currentSemitones_);
      appliedFilterSt_ = currentSemitones_;
    }

    const float fadeStep = 1.0f / static_cast<float>(fadeSamples_);
    const float targetWet = targetSt != 0 ? 1.0f : 0.0f;

    for (uint32_t i = 0; i < count; ++i) {
      const float dry = samples[i];
      pushInputSample(dry);

      if (transientPending_) {
        transientPending_ = false;
        handleTransient();
      }
      updateSplice();

      float wet = renderVoices();
      if (currentSemitones_ < 0) {
        wet = subHpf_.process(wet);
      }
      wet = presenceShelf_.process(wet);

      if (currentSemitones_ < 0 && (snapEnv_ > 0.0f || snapGateLeft_ > 0)) {
        if (snapGateLeft_ > 0) {
          --snapGateLeft_;
          snapEnv_ += (1.0f - snapEnv_) * snapAttackCoeff_;
        } else {
          snapEnv_ *= snapDecayFactor_;
          if (snapEnv_ < 1.0e-5f) snapEnv_ = 0.0f;
        }
        if (snapEnv_ > 0.0f) {
          const size_t snapIdx = static_cast<size_t>(
              (static_cast<int64_t>(writePos_) - snapDelay_) & kSnapRingMask);
          wet += (snapEnv_ * snapMix_) * snapRing_[snapIdx];
        }
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
      appliedFilterSt_ = 0;
      subHpf_.reset();
      presenceShelf_.reset();
      snapMix_ = 0.0f;
      snapEnv_ = 0.0f;
      snapGateLeft_ = 0;
    }
  }

  static int clampSemitones(int semitones) noexcept {
    return std::clamp(semitones, kMinSemitones, kMaxSemitones);
  }

 private:
  static constexpr int kHeadMargin = 4;
  static constexpr int kMaxStride = 16;
  static constexpr int kVoiceCount = 4;
  static constexpr int kMaxTemplateTaps = 512;
  static constexpr float kQuietLevel = 2.0e-4f;
  static constexpr float kEarlyAcceptSimilarity = 0.95f;
  static constexpr float kForcedAcceptSimilarity = 0.90f;
  static constexpr float kPeriodicVetoSimilarity = 0.80f;
  static constexpr float kDelayPenalty = 0.03f;

  struct Voice {
    double pos = 0.0;
    float startGain = 0.0f;
    bool on = false;
  };

  struct Match {
    double jump = 0.0;
    float similarity = 0.0f;
    float rho = 1.0f;
    bool interior = false;
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
      const double subHz = 20.0 + 0.25 * static_cast<double>(-semitones);
      subHpf_.setHighPass(sampleRate_, subHz, 0.707);
      const double boostDb = std::min(3.8, 0.42 * static_cast<double>(-semitones));
      presenceShelf_.setHighShelf(sampleRate_, 2400.0, boostDb, 0.707);
      const float depth = std::clamp(static_cast<float>(-semitones) / 12.0f, 0.0f, 1.0f);
      snapMix_ = 0.32f + 0.32f * std::sqrt(depth);
    } else if (semitones > 0) {
      subHpf_.reset();
      const double cutDb = -std::min(3.5, 0.40 * static_cast<double>(semitones));
      presenceShelf_.setHighShelf(sampleRate_, 2800.0, cutDb, 0.707);
      snapMix_ = 0.0f;
    }
  }

  void pushInputSample(float dry) noexcept {
    const float absIn = std::fabs(dry);
    const float detHp = detHpf_.process(dry);
    dryLpState_ += (dry - dryLpState_) * snapXoverCoeff_;
    const float snapHp = dry - dryLpState_;
    const float impulse = 0.008f * absIn + std::fabs(detHp);
    fastEnv_ += (impulse - fastEnv_) * fastCoeff_;
    slowEnv_ += (impulse - slowEnv_) * slowCoeff_;

    if (transientCooldown_ > 0) --transientCooldown_;
    if (transientCooldown_ == 0 && fastEnv_ > 0.0020f && fastEnv_ > slowEnv_ * 2.2f) {
      transientPending_ = true;
    }

    if (absIn < kQuietLevel) {
      if (quietRun_ < kRingSize) ++quietRun_;
    } else {
      quietRun_ = 0;
    }

    ring_[static_cast<size_t>(writePos_ & kRingMask)] = dry;
    snapRing_[static_cast<size_t>(writePos_ & kSnapRingMask)] = snapHp;
    ++writePos_;
  }

  double upLowDelay(double ratio) const noexcept {
    return static_cast<double>(kHeadMargin) + static_cast<double>(upXfadeCap_) * (ratio - 1.0);
  }

  double upHeadroom(double ratio) const noexcept {
    return static_cast<double>(transientGuard_ + preRoll_ + minJump_) * (ratio - 1.0) / ratio;
  }

  double leadDelay() const noexcept {
    return static_cast<double>(writePos_) - voices_[static_cast<size_t>(lead_)].pos;
  }

  void startVoices() noexcept {
    for (Voice& v : voices_) v = Voice{};
    lead_ = 0;
    const double delay = ratio_ < 1.0 ? static_cast<double>(kHeadMargin)
                                      : upLowDelay(ratio_) + static_cast<double>(minJump_);
    voices_[0].pos = static_cast<double>(writePos_) - delay;
    voices_[0].on = true;
    fadeLen_ = 0;
    fadePos_ = 0;
    lastAttemptDelay_ = delay;
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

  float fadeShape() const noexcept {
    const float t = static_cast<float>(fadePos_) / static_cast<float>(fadeLen_);
    return t * t * (3.0f - 2.0f * t);
  }

  float voiceGain(int index) const noexcept {
    const Voice& v = voices_[static_cast<size_t>(index)];
    if (!v.on) return 0.0f;
    if (fadePos_ >= fadeLen_) return index == lead_ ? 1.0f : 0.0f;
    const float s = fadeShape();
    return index == lead_ ? s : v.startGain * (1.0f - s);
  }

  float renderVoices() noexcept {
    const double maxPos = static_cast<double>(writePos_) - static_cast<double>(kHeadMargin);
    float wet = 0.0f;
    if (fadePos_ < fadeLen_) {
      ++fadePos_;
      const float s = fadeShape();
      float sum = 0.0f;
      float squares = 0.0f;
      for (int i = 0; i < kVoiceCount; ++i) {
        Voice& v = voices_[static_cast<size_t>(i)];
        if (!v.on) continue;
        if (v.pos > maxPos) v.pos = maxPos;
        const float g = i == lead_ ? s : v.startGain * (1.0f - s);
        sum += g * readCubic(v.pos);
        squares += g * g;
        v.pos += ratio_;
      }
      const float power = squares + overlapRho_ * (1.0f - squares);
      wet = sum / std::sqrt(std::max(0.5f, power));
      if (fadePos_ >= fadeLen_) {
        for (int i = 0; i < kVoiceCount; ++i) {
          if (i != lead_) voices_[static_cast<size_t>(i)].on = false;
        }
      }
    } else {
      Voice& v = voices_[static_cast<size_t>(lead_)];
      if (v.pos > maxPos) v.pos = maxPos;
      wet = readCubic(v.pos);
      v.pos += ratio_;
    }
    return wet;
  }

  void splice(double newPos, int fadeLen, float rho) noexcept {
    std::array<float, kVoiceCount> gains{};
    int slot = -1;
    int quietest = 0;
    for (int i = 0; i < kVoiceCount; ++i) {
      gains[static_cast<size_t>(i)] = voiceGain(i);
      if (gains[static_cast<size_t>(i)] <= 0.0f) {
        voices_[static_cast<size_t>(i)].on = false;
        if (slot < 0) slot = i;
      }
      if (gains[static_cast<size_t>(i)] < gains[static_cast<size_t>(quietest)]) quietest = i;
    }
    if (slot < 0) {
      slot = quietest;
      gains[static_cast<size_t>(slot)] = 0.0f;
    }
    float total = 0.0f;
    for (float g : gains) total += g;
    const float scale = total > 1.0e-6f ? 1.0f / total : 0.0f;
    for (int i = 0; i < kVoiceCount; ++i) {
      voices_[static_cast<size_t>(i)].startGain = gains[static_cast<size_t>(i)] * scale;
    }
    Voice& lead = voices_[static_cast<size_t>(slot)];
    lead.pos = newPos;
    lead.startGain = 0.0f;
    lead.on = true;
    lead_ = slot;
    fadeLen_ = std::max(2, fadeLen);
    fadePos_ = 0;
    overlapRho_ = std::clamp(rho, 0.0f, 1.0f);
    lastAttemptDelay_ = static_cast<double>(writePos_) - newPos;
  }

  struct Template {
    std::array<float, kMaxTemplateTaps> taps{};
    float energy = 0.0f;
    int count = 0;
    int stride = 1;
  };

  void loadTemplate(Template& t, int64_t q0, int tLen, int stride) const noexcept {
    t.stride = stride;
    t.count = std::min(kMaxTemplateTaps, (tLen + stride - 1) / stride);
    t.energy = 0.0f;
    for (int k = 0; k < t.count; ++k) {
      const float r = ring_[static_cast<size_t>((q0 + static_cast<int64_t>(k) * stride) & kRingMask)];
      t.taps[static_cast<size_t>(k)] = r;
      t.energy += r * r;
    }
  }

  void evaluateLag(const Template& t, int64_t q0, int lag, float& similarity, float& rho) const noexcept {
    float dot = 0.0f;
    float candE = 0.0f;
    const size_t start = static_cast<size_t>((q0 + lag) & kRingMask);
    const size_t stride = static_cast<size_t>(t.stride);
    if (start + static_cast<size_t>(t.count) * stride < static_cast<size_t>(kRingSize)) {
      const float* cand = ring_.data() + start;
      for (int k = 0; k < t.count; ++k) {
        const float v = cand[static_cast<size_t>(k) * stride];
        dot += t.taps[static_cast<size_t>(k)] * v;
        candE += v * v;
      }
    } else {
      for (int k = 0; k < t.count; ++k) {
        const float v = ring_[(start + static_cast<size_t>(k) * stride) & static_cast<size_t>(kRingMask)];
        dot += t.taps[static_cast<size_t>(k)] * v;
        candE += v * v;
      }
    }
    const float energy = t.energy + candE;
    if (energy < 1.0e-10f) {
      similarity = 0.0f;
      rho = 1.0f;
      return;
    }
    similarity = 2.0f * dot / energy;
    rho = dot / std::sqrt(t.energy * candE + 1.0e-20f);
  }

  // Finds the lag in [lagLo, lagHi] at which the tLen samples that end at
  // refPos best match the samples that end at refPos + lag. refDelay is the
  // delay of refPos behind the write head; shorter landing delays score higher.
  Match findJump(double refPos, int tLen, int lagLo, int lagHi, double refDelay) noexcept {
    Match match;
    const int64_t q0 = static_cast<int64_t>(std::floor(refPos)) - tLen + 1;
    const float penaltyScale = kDelayPenalty / static_cast<float>(maxSpan_);
    const auto score = [&](const Template& t, int lag, float& similarity, float& rho) {
      evaluateLag(t, q0, lag, similarity, rho);
      const float matchQuality = 0.50f * similarity + 0.50f * rho;
      return matchQuality - penaltyScale * static_cast<float>(refDelay - static_cast<double>(lag));
    };

    loadTemplate(coarseTemplate_, q0, tLen, coarseStride_);
    float bestScore = -1.0e30f;
    int bestCoarse = lagLo;
    for (int lag = lagLo;; lag += coarseStride_) {
      if (lag > lagHi) lag = lagHi;
      float similarity = 0.0f;
      float rho = 1.0f;
      const float s = score(coarseTemplate_, lag, similarity, rho);
      if (s > bestScore) {
        bestScore = s;
        bestCoarse = lag;
      }
      if (lag == lagHi) break;
    }

    loadTemplate(fineTemplate_, q0, tLen, fineStride_);
    const int fineLo = std::max(lagLo, bestCoarse - coarseStride_);
    const int fineHi = std::min(lagHi, bestCoarse + coarseStride_);
    std::array<float, 2 * kMaxStride + 1> fineScores{};
    bestScore = -1.0e30f;
    int bestLag = bestCoarse;
    for (int lag = fineLo; lag <= fineHi; ++lag) {
      float similarity = 0.0f;
      float rho = 1.0f;
      const float s = score(fineTemplate_, lag, similarity, rho);
      fineScores[static_cast<size_t>(lag - fineLo)] = s;
      if (s > bestScore) {
        bestScore = s;
        bestLag = lag;
        match.similarity = similarity;
        match.rho = rho;
      }
    }

    match.jump = static_cast<double>(bestLag);
    match.interior = bestLag > lagLo && bestLag < lagHi;
    if (bestLag > fineLo && bestLag < fineHi) {
      const float left = fineScores[static_cast<size_t>(bestLag - 1 - fineLo)];
      const float right = fineScores[static_cast<size_t>(bestLag + 1 - fineLo)];
      const float curvature = left - 2.0f * bestScore + right;
      if (curvature < -1.0e-9f) {
        match.jump += static_cast<double>(std::clamp(0.5f * (left - right) / curvature, -0.5f, 0.5f));
      }
    }
    return match;
  }

  int spliceFadeLength(double jump, bool postAttack = false, float rho = 1.0f) const noexcept {
    const double distance = std::fabs(jump);
    double maxFade = static_cast<double>(postAttack ? xfadePostAttack_ : xfadeMax_);
    if (rho < 0.88f) {
      const double t = std::clamp((0.88 - static_cast<double>(rho)) / 0.28, 0.0, 1.0);
      const double lowRhoCap = maxFade + t * (static_cast<double>(xfadeLowRho_) - maxFade);
      maxFade = std::min(maxFade, lowRhoCap);
    }
    double len = std::clamp(distance, static_cast<double>(xfadeFloor_), maxFade);
    if (rho >= 0.88f && !postAttack) {
      len = std::max(len, std::min(distance, static_cast<double>(xfadeMin_)));
    }
    len = std::min(len, 0.8 * distance / std::max(1.0e-3, std::fabs(1.0 - ratio_)));
    if (ratio_ > 1.0) len = std::min(len, static_cast<double>(upXfadeCap_));
    return std::max(xfadeFloor_, static_cast<int>(len));
  }

  double findDropOnsetDelay() const noexcept {
    const int maxD = kHeadMargin + preRoll_;
    float peakSnap = 0.0f;
    for (int d = 1; d <= maxD; ++d) {
      const float v = std::fabs(snapRing_[static_cast<size_t>((static_cast<int64_t>(writePos_) - d) & kSnapRingMask)]);
      if (v > peakSnap) peakSnap = v;
    }
    if (peakSnap <= 1.0e-5f) return static_cast<double>(maxD);
    const float thresh = 0.18f * peakSnap;
    int onsetD = kHeadMargin;
    for (int d = maxD; d >= kHeadMargin; --d) {
      const float v = std::fabs(snapRing_[static_cast<size_t>((static_cast<int64_t>(writePos_) - d) & kSnapRingMask)]);
      if (v >= thresh) {
        onsetD = std::min(maxD, d + xfadeTransient_);
        break;
      }
    }
    return static_cast<double>(std::clamp(onsetD, kHeadMargin, maxD));
  }

  bool isPeriodicPeak(double periodicJump) const noexcept {
    if (fastEnv_ > slowEnv_ * 3.0f) return false;
    const int lag = static_cast<int>(std::llround(periodicJump));
    const int64_t base = static_cast<int64_t>(writePos_) - shortTemplateLen_;
    float curSnapE = 0.0f;
    float pastSnapE = 0.0f;
    for (int k = 0; k < shortTemplateLen_; ++k) {
      const float c = snapRing_[static_cast<size_t>((base + k) & kSnapRingMask)];
      const float p = snapRing_[static_cast<size_t>((base + k + lag) & kSnapRingMask)];
      curSnapE += c * c;
      pastSnapE += p * p;
    }
    if (curSnapE > pastSnapE * 2.0f + 1.0e-8f) return false;
    return true;
  }

  void handleTransient() noexcept {
    const Voice& lead = voices_[static_cast<size_t>(lead_)];
    const double delay = static_cast<double>(writePos_) - lead.pos;

    // A waveform peak of a sustained note repeats one period earlier. A pick
    // attack does not (and a re-pick over a sustained chord carries a burst
    // of high-frequency pick energy).
    const Match periodic = findJump(static_cast<double>(writePos_ - 1), shortTemplateLen_,
                                    -maxSpan_, -minJump_, 0.0);
    if (periodic.similarity >= kPeriodicVetoSimilarity && isPeriodicPeak(periodic.jump)) {
      transientCooldown_ = vetoCooldownSamples_;
      return;
    }

    transientCooldown_ = transientCooldownSamples_;
    lastTransientPos_ = static_cast<int64_t>(writePos_);
    if (ratio_ < 1.0) {
      const double target = findDropOnsetDelay();
      const double gain = delay - target;
      if (gain >= static_cast<double>(minResyncGainDrop_) || fadePos_ < fadeLen_) {
        const double landDelay = gain >= 0.0 ? target : delay;
        splice(static_cast<double>(writePos_) - landDelay, xfadeTransient_, 0.0f);
        snapDelay_ = std::clamp(static_cast<int>(std::llround(landDelay)), 0, kSnapRingSize - 1);
      } else {
        snapDelay_ = std::clamp(static_cast<int>(std::llround(delay)), 0, kSnapRingSize - 1);
      }
      snapGateLeft_ = snapHoldSamples_;
      return;
    }

    const double target = upLowDelay(ratio_) + upHeadroom(ratio_) + static_cast<double>(preRoll_);
    const double gain = std::fabs(delay - target);
    if (gain < static_cast<double>(minResyncGain_) && fadePos_ >= fadeLen_) return;
    splice(static_cast<double>(writePos_) - target, xfadeTransient_, 0.0f);
  }

  void updateSplice() noexcept {
    const Voice& lead = voices_[static_cast<size_t>(lead_)];
    const double delay = static_cast<double>(writePos_) - lead.pos;

    if (ratio_ < 1.0) {
      const double drift = delay - static_cast<double>(kHeadMargin);
      if (drift < static_cast<double>(attemptStep_)) return;
      if (quietRun_ >= quietHoldSamples_) {
        if (fadePos_ < fadeLen_) return;
        if (delay >= static_cast<double>(quietRun_ - kHeadMargin) ||
            delay > static_cast<double>(kHeadMargin + minJump_)) {
          splice(static_cast<double>(writePos_ - kHeadMargin), fadeSamples_, 1.0f);
        } else {
          for (int i = 0; i < kVoiceCount; ++i) {
            voices_[static_cast<size_t>(i)].on = (i == lead_);
          }
          voices_[static_cast<size_t>(lead_)].pos = static_cast<double>(writePos_ - kHeadMargin);
          fadeLen_ = 0;
          fadePos_ = 0;
          lastAttemptDelay_ = static_cast<double>(kHeadMargin);
        }
        return;
      }
      if (drift < static_cast<double>(minJump_ + 2)) return;
      const int64_t sinceTransient =
          lastTransientPos_ >= 0 ? static_cast<int64_t>(writePos_) - lastTransientPos_ : kRingSize;
      const bool forced = drift >= static_cast<double>(maxSpan_);
      if (!forced) {
        if (sinceTransient < static_cast<int64_t>(transientProtect_)) return;
        if (delay - lastAttemptDelay_ < static_cast<double>(attemptStep_)) return;
        // An attack that the detector did not confirm yet can be at the write head.
        if (fastEnv_ > 0.0020f && fastEnv_ > slowEnv_ * 1.6f) return;
      }
      lastAttemptDelay_ = delay;

      const int lagHi = static_cast<int>(std::floor(drift));
      const int lagLo = std::max(minJump_, lagHi - maxSpan_);
      const Match match = findJump(lead.pos, templateLen_, lagLo, lagHi, delay);
      const bool postAttack = sinceTransient < static_cast<int64_t>(postAttackWindow_);
      if (!forced) {
        if (!match.interior) return;
        const float x = static_cast<float>(drift) / static_cast<float>(maxSpan_);
        const float threshold =
            x < 0.5f ? kEarlyAcceptSimilarity
                     : kEarlyAcceptSimilarity -
                           (x - 0.5f) * 2.0f * (kEarlyAcceptSimilarity - kForcedAcceptSimilarity);
        const float rhoMin = x < 0.45f ? 0.945f : 0.945f - (x - 0.45f) * (0.045f / 0.55f);
        const float simMin = x < 0.45f ? 0.82f : 0.76f;
        const bool decayPeriodOk = match.rho >= rhoMin && match.similarity >= simMin;
        if (match.similarity < threshold && !decayPeriodOk) return;
      }
      splice(lead.pos + match.jump, spliceFadeLength(match.jump, postAttack, match.rho), match.rho);
      return;
    }

    if (delay > upLowDelay(ratio_)) return;

    const int quietJump = minJump_ + kHeadMargin;
    if (static_cast<double>(quietRun_) >= std::max(delay + static_cast<double>(quietJump + 2),
                                                   static_cast<double>(quietHoldSamples_))) {
      splice(lead.pos - static_cast<double>(quietJump), spliceFadeLength(quietJump), 1.0f);
      return;
    }

    int lagLo = -maxSpan_;
    const int lagHi = -minJump_;
    if (lastTransientPos_ >= 0) {
      // Do not jump back to a pick attack that the tap already played.
      const double limit = static_cast<double>(lastTransientPos_ + transientGuard_);
      if (lead.pos > static_cast<double>(lastTransientPos_ - preRoll_) &&
          lead.pos - static_cast<double>(maxSpan_) < limit) {
        lagLo = static_cast<int>(std::ceil(limit - lead.pos));
      }
    }
    if (lagLo >= lagHi) {
      splice(lead.pos - static_cast<double>(minJump_), spliceFadeLength(minJump_), 0.5f);
      return;
    }
    const Match match = findJump(lead.pos, templateLen_, lagLo, lagHi, delay);
    splice(lead.pos + match.jump, spliceFadeLength(match.jump), match.rho);
  }

  double sampleRate_ = 48000.0;
  int templateLen_ = 480;
  int shortTemplateLen_ = 72;
  int minJump_ = 120;
  int maxSpan_ = 2016;
  int attemptStep_ = 36;
  int coarseStride_ = 4;
  int fineStride_ = 2;
  int xfadeMin_ = 144;
  int xfadeMax_ = 384;
  int xfadePostAttack_ = 192;
  int xfadeFloor_ = 48;
  int xfadeLowRho_ = 96;
  int xfadeTransient_ = 17;
  int upXfadeCap_ = 240;
  int preRoll_ = 96;
  int transientGuard_ = 192;
  int transientProtect_ = 576;
  int postAttackWindow_ = 2160;
  int quietHoldSamples_ = 864;
  int minResyncGain_ = 12;
  int minResyncGainDrop_ = 43;
  int nominalSwing_ = 384;
  int fadeSamples_ = 240;

  float fastCoeff_ = 0.045f;
  float slowCoeff_ = 0.00087f;
  int transientCooldownSamples_ = 1152;
  int vetoCooldownSamples_ = 96;
  int snapHoldSamples_ = 86;
  float snapAttackCoeff_ = 0.13f;
  float snapDecayFactor_ = 0.988f;
  float snapXoverCoeff_ = 0.27f;

  std::array<float, kRingSize> ring_{};
  std::array<float, kSnapRingSize> snapRing_{};
  uint64_t writePos_ = 0;
  std::array<Voice, kVoiceCount> voices_{};
  int lead_ = 0;
  int fadeLen_ = 0;
  int fadePos_ = 0;
  double lastAttemptDelay_ = 0.0;
  Template coarseTemplate_;
  Template fineTemplate_;
  double ratio_ = 1.0;
  bool active_ = false;
  int currentSemitones_ = 0;
  float wetMix_ = 0.0f;
  float overlapRho_ = 1.0f;

  float fastEnv_ = 0.0f;
  float slowEnv_ = 0.0f;
  int transientCooldown_ = 0;
  bool transientPending_ = false;
  int64_t lastTransientPos_ = -1;
  int quietRun_ = kRingSize;

  float dryLpState_ = 0.0f;
  float snapMix_ = 0.0f;
  float snapEnv_ = 0.0f;
  int snapGateLeft_ = 0;
  int snapDelay_ = kHeadMargin;

  int appliedFilterSt_ = 0;
  Biquad subHpf_;
  Biquad presenceShelf_;
  Biquad detHpf_;
};

}  // namespace NAMRig
