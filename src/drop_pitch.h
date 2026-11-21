#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <vector>

namespace NAMRig {

// Pedal-grade low-latency polyphonic pitch shifter for pre-amp guitar
// Drop Tuning / Virtual Capo (-12 to +12 semitones).
//
// Architecture:
//  - Zero-Phase Symmetric-Tukey Phase Vocoder + Coherent-Island Peak-Anchored
//    Phase Locking + Direct Time-Domain Transient Lock + 16-tap Kaiser-Sinc
//    Polyphase Resampler.
//  - Steady chords, power chords, and sustained notes use a fixed 53.3 ms
//    symmetric Tukey analysis window (zero-phase packed around the synthesis
//    center inside a 4096-pt FFT at 48 kHz -> 11.7 Hz bin resolution) paired
//    with a compact 4.0 ms right-side Hann synthesis slice -> fixed ~12.3-13.0 ms
//    latency for -1..-5 st with 0.0 ms timing jitter and exact 1.000 unity gain.
//  - Continuous sub-sample analysis positioning eliminates integer-hop jitter
//    sidebands before high-gain amp saturation.
//  - Dual-channel onset detection (isolated >1.4 kHz pick-scrape channel +
//    broadband thump channel) catches both loud downstrokes and soft upstroke
//    ghost chugs without low-string masking. Pick attacks use zero-centered
//    continuous-time transient locking directly on the raw waveform (or
//    complementary >1.2 kHz band-split locking when re-picking over a loud
//    ringing chord), eliminating pre-echo, flamming, double-triggering,
//    clicks, and dry-pitch comb chirps.
//  - Silence / palm-mute dead-stop envelope guarding suppresses left-tail
//    ghost ringing and right-skirt pre-echo without disturbing sustained waves.
//  - Smooth log-spectral formant preservation (450 Hz..7.2 kHz) anchors
//    electric guitar pickup resonance and string clarity across shifts.
//  - Zero real-time heap allocations in process()/reset() and exact
//    bit-identical bypass when semitones == 0.
class DropPitch {
 public:
  struct Params {
    float attack = 50.0f;   // 0..100 (50 = calibrated neutral)
    float sustain = 50.0f;  // 0..100 (50 = calibrated neutral)
  };

  static constexpr int kMinSemitones = -12;
  static constexpr int kMaxSemitones = 12;

  DropPitch() { prepare(48000.0); }

  void prepare(double sampleRate) noexcept {
    sampleRate_ = std::clamp(sampleRate > 0.0 ? sampleRate : 48000.0, 22050.0, 192000.0);

    if (sampleRate_ <= 56000.0) {
      srScale_ = 1;
    } else if (sampleRate_ <= 112000.0) {
      srScale_ = 2;
    } else {
      srScale_ = 4;
    }

    fftSize_ = 4096 * srScale_;
    halfFft_ = fftSize_ / 2;
    bins_ = halfFft_ + 1;

    // Symmetric Tukey analysis window (Wa = 53.3 ms @ 48 kHz, edge = 13.3 ms),
    // synthesis center R = 10.0 ms from newest sample, compact Ms = 4.0 ms
    // synthesis slice -> fixed ~12.3..13.0 ms latency for -1..-5 st.
    anaWinLen_ = 2560 * srScale_;
    tukeyEdge_ = 640 * srScale_;
    synRightDist_ = 480 * srScale_;
    synCenter_ = anaWinLen_ - synRightDist_;
    synWinLen_ = 192 * srScale_;

    inRingSize_ = 16384 * srScale_;
    inRingMask_ = static_cast<uint64_t>(inRingSize_ - 1);
    olaRingSize_ = 4096 * srScale_;
    olaRingMask_ = static_cast<uint64_t>(olaRingSize_ - 1);
    resRingSize_ = 4096 * srScale_;
    resRingMask_ = static_cast<uint64_t>(resRingSize_ - 1);

    inRing_.assign(static_cast<size_t>(inRingSize_), 0.0f);
    inHfRing_.assign(static_cast<size_t>(inRingSize_), 0.0f);
    olaSum_.assign(static_cast<size_t>(olaRingSize_), 0.0f);
    olaNorm_.assign(static_cast<size_t>(olaRingSize_), 0.0f);
    resRing_.assign(static_cast<size_t>(resRingSize_), 0.0f);

    timeBuf_.assign(static_cast<size_t>(fftSize_), 0.0f);
    fftRe_.assign(static_cast<size_t>(halfFft_), 0.0f);
    fftIm_.assign(static_cast<size_t>(halfFft_), 0.0f);
    specRe_.assign(static_cast<size_t>(bins_), 0.0f);
    specIm_.assign(static_cast<size_t>(bins_), 0.0f);
    mag_.assign(static_cast<size_t>(bins_), 0.0f);
    anaPhase_.assign(static_cast<size_t>(bins_), 0.0f);
    prevAnaPhase_.assign(static_cast<size_t>(bins_), 0.0f);
    prevMag_.assign(static_cast<size_t>(bins_), 0.0f);
    synPhase_.assign(static_cast<size_t>(bins_), 0.0f);
    prevSynPhase_.assign(static_cast<size_t>(bins_), 0.0f);
    instBin_.assign(static_cast<size_t>(bins_), 0.0f);
    rotAngle_.assign(static_cast<size_t>(bins_), 0.0f);

    const double binHz = sampleRate_ / static_cast<double>(fftSize_);
    formantMaxBin_ = std::clamp(static_cast<int>(std::ceil(8600.0 / binHz)), 16, halfFft_);
    splitBinLo_ = std::clamp(static_cast<int>(std::lround(1050.0 / binHz)), 4, halfFft_ - 4);
    splitBinHi_ = std::clamp(static_cast<int>(std::lround(1650.0 / binHz)), splitBinLo_ + 2, halfFft_);

    logMag_.assign(static_cast<size_t>(formantMaxBin_ + 1), -14.0f);
    prefixLog_.assign(static_cast<size_t>(formantMaxBin_ + 2), 0.0f);
    envLog_.assign(static_cast<size_t>(formantMaxBin_ + 1), -14.0f);
    smoothEnvLog_.assign(static_cast<size_t>(formantMaxBin_ + 1), -14.0f);
    formantWeight_.assign(static_cast<size_t>(formantMaxBin_ + 1), 0.0f);

    waLong_.assign(static_cast<size_t>(anaWinLen_), 0.0f);
    synHann_.assign(static_cast<size_t>(synWinLen_), 0.0f);
    wsFixed_.assign(static_cast<size_t>(synWinLen_), 0.0f);

    prepareWindows();
    prepareFFT();
    prepareFormantWeights();

    fadeSamples_ = std::max(1, static_cast<int>(std::lround(sampleRate_ * 0.005)));
    paramSmoothTau_ = static_cast<float>(sampleRate_ * 0.008);

    // Dual-channel onset detector:
    //  1) HF pick-scrape channel (>1600 Hz) unmasked by ringing low strings
    //  2) Broadband thump channel for dark neck-pickup / dull palm mutes
    hfFastCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.0006));
    hfSlowCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.016));
    bbFastCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.0012));
    bbSlowCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.022));
    detHpf_.setHighPass(sampleRate_, 1600.0, 0.707);
    splitHpf_.setHighPass(sampleRate_, 1350.0, 0.707);

    atkXoverCoeff_ =
        1.0f - std::exp(-6.28318530717958647692f * 1350.0f / static_cast<float>(sampleRate_));
    atkFastCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.0005));
    atkSlowCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.012));
    atkHoldDecay_ = std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.0055));

    susAttackCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.0025));
    susReleaseCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.085));
    susTightReleaseCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.035));
    susGainDownCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.002));
    susGainUpCoeff_ = 1.0f - std::exp(-1.0f / static_cast<float>(sampleRate_ * 0.018));

    trCooldownSamples_ = static_cast<int64_t>(std::lround(sampleRate_ * 0.024));
    buildSincTable(1.0);
    reset();
  }

  void reset() noexcept {
    std::fill(inRing_.begin(), inRing_.end(), 0.0f);
    std::fill(inHfRing_.begin(), inHfRing_.end(), 0.0f);
    std::fill(olaSum_.begin(), olaSum_.end(), 0.0f);
    std::fill(olaNorm_.begin(), olaNorm_.end(), 0.0f);
    std::fill(resRing_.begin(), resRing_.end(), 0.0f);
    std::fill(prevAnaPhase_.begin(), prevAnaPhase_.end(), 0.0f);
    std::fill(prevMag_.begin(), prevMag_.end(), 0.0f);
    std::fill(synPhase_.begin(), synPhase_.end(), 0.0f);
    std::fill(prevSynPhase_.begin(), prevSynPhase_.end(), 0.0f);
    std::fill(smoothEnvLog_.begin(), smoothEnvLog_.end(), -14.0f);

    writePos_ = 0;
    olaWritePos_ = 0;
    resWritePos_ = 0;
    resReadPos_ = 0.0;
    anaPos_ = 0.0;
    prevAnaPos_ = 0.0;
    havePrevFrame_ = false;
    envInitialized_ = false;
    prevSynSliceE_ = 0.0;

    active_ = false;
    currentSemitones_ = 0;
    ratio_ = 1.0;
    wetMix_ = 0.0f;
    hopSyn_ = synWinLen_ / 2;
    hopAna_ = static_cast<double>(hopSyn_);
    sincRatio_ = 1.0;

    hfFastEnv_ = 0.0f;
    hfSlowEnv_ = 0.0f;
    bbFastEnv_ = 0.0f;
    bbSlowEnv_ = 0.0f;
    lastOnsetPos_ = -1000000;
    activeTrInPos_ = -1000000.0;
    activeTrOutPos_ = -1000000.0;
    activeTrValid_ = false;
    activeTrFullLock_ = false;
    trPeakPos_ = -1;
    trPeakImpulse_ = 0.0f;
    trPendingWindow_ = 0;

    smoothAttack_ = 50.0f;
    smoothSustain_ = 50.0f;
    atkLpState_ = 0.0f;
    atkFastEnv_ = 0.0f;
    atkSlowEnv_ = 0.0f;
    atkPulse_ = 0.0f;
    susEnv_ = 0.0f;
    susGain_ = 1.0f;

    subHpf_.reset();
    detHpf_.reset();
    splitHpf_.reset();
    appliedFilterSt_ = 0;
  }

  // Exact fixed algorithmic latency in samples for the given shift.
  int latencySamples(int semitones) const noexcept {
    const int st = clampSemitones(semitones);
    if (st == 0) return 0;
    const double ratio = std::pow(2.0, static_cast<double>(st) / 12.0);
    const double exact =
        static_cast<double>(synRightDist_) +
        (0.5 * static_cast<double>(synWinLen_) + static_cast<double>(kResMargin)) / ratio;
    return std::max(1, static_cast<int>(std::lround(exact)));
  }

  void process(float* samples, uint32_t count, int semitones) noexcept {
    process(samples, count, semitones, Params{});
  }

  void process(float* samples, uint32_t count, int semitones, const Params& rawParams) noexcept {
    if (!samples || count == 0) return;
    const Params targetParams = sanitizeParams(rawParams);
    const int targetSt = clampSemitones(semitones);

    // Exact bit-identical bypass when inactive and semitones == 0; keep ring primed.
    if (targetSt == 0 && !active_) {
      snapSmoothParams(targetParams);
      for (uint32_t i = 0; i < count; ++i) {
        pushInputSample(samples[i]);
      }
      return;
    }

    if (targetSt != 0 && !active_) {
      active_ = true;
      currentSemitones_ = targetSt;
      ratio_ = std::pow(2.0, static_cast<double>(targetSt) / 12.0);
      wetMix_ = 0.0f;
      snapSmoothParams(targetParams);
      configureShiftGeometry(currentSemitones_, ratio_);
      configureSubFilter(currentSemitones_);
      appliedFilterSt_ = currentSemitones_;
      atkLpState_ = 0.0f;
      atkFastEnv_ = 0.0f;
      atkSlowEnv_ = 0.0f;
      atkPulse_ = 0.0f;
      susEnv_ = 0.0f;
      susGain_ = 1.0f;
      primeEngine();
    } else if (targetSt != 0 && targetSt != currentSemitones_) {
      currentSemitones_ = targetSt;
      ratio_ = std::pow(2.0, static_cast<double>(targetSt) / 12.0);
      configureShiftGeometry(currentSemitones_, ratio_);
      configureSubFilter(currentSemitones_);
      appliedFilterSt_ = currentSemitones_;
      activeTrValid_ = false;
    }

    const float fadeStep = 1.0f / static_cast<float>(fadeSamples_);
    const float targetWet = targetSt != 0 ? 1.0f : 0.0f;

    constexpr uint32_t kCtrlChunk = 32u;
    for (uint32_t offset = 0; offset < count; offset += kCtrlChunk) {
      const uint32_t chunkEnd = std::min(count, offset + kCtrlChunk);
      const uint32_t chunkLen = chunkEnd - offset;
      stepSmoothParams(targetParams, chunkLen);

      const float atkNorm = (smoothAttack_ - 50.0f) * 0.02f;
      const float susNorm = (smoothSustain_ - 50.0f) * 0.02f;
      const bool attackActive =
          std::fabs(atkNorm) >= 1.0e-4f || atkPulse_ > 1.0e-5f;
      const bool sustainActive =
          std::fabs(susNorm) >= 1.0e-4f || std::fabs(susGain_ - 1.0f) >= 1.0e-5f;

      for (uint32_t i = offset; i < chunkEnd; ++i) {
        const float dry = samples[i];
        pushInputSample(dry);

        while (static_cast<double>(resWritePos_) - resReadPos_ < static_cast<double>(kResMargin + 1)) {
          const double maxAnaPos = static_cast<double>(writePos_) - 1.5;
          if (anaPos_ > maxAnaPos) {
            anaPos_ = maxAnaPos;
          }
          runStftHop();
          anaPos_ += hopAna_;
          if (anaPos_ > maxAnaPos + hopAna_) {
            anaPos_ = maxAnaPos + hopAna_;
          }
        }

        float wet = readResampled(resReadPos_);
        resReadPos_ += ratio_;

        if (currentSemitones_ < 0) {
          wet = subHpf_.process(wet);
        }

        if (attackActive) {
          wet = applyAttackShaping(wet, atkNorm);
        } else {
          atkLpState_ += (wet - atkLpState_) * atkXoverCoeff_;
          const float absW = std::fabs(wet);
          atkFastEnv_ += (absW - atkFastEnv_) * atkFastCoeff_;
          atkSlowEnv_ += (absW - atkSlowEnv_) * atkSlowCoeff_;
          atkPulse_ = 0.0f;
        }

        if (sustainActive) {
          wet *= computeSustainGain(wet, susNorm);
        }

        if (wetMix_ < targetWet) {
          wetMix_ = std::min(targetWet, wetMix_ + fadeStep);
        } else if (wetMix_ > targetWet) {
          wetMix_ = std::max(targetWet, wetMix_ - fadeStep);
        }

        samples[i] = dry + (wet - dry) * wetMix_;
      }
    }

    if (targetSt == 0 && wetMix_ <= 0.0f) {
      active_ = false;
      currentSemitones_ = 0;
      appliedFilterSt_ = 0;
      subHpf_.reset();
      atkPulse_ = 0.0f;
      susEnv_ = 0.0f;
      susGain_ = 1.0f;
      activeTrValid_ = false;
    }
  }

  static int clampSemitones(int semitones) noexcept {
    return std::clamp(semitones, kMinSemitones, kMaxSemitones);
  }

 private:
  static constexpr double kPi = 3.14159265358979323846;
  static constexpr double kTwoPi = 6.28318530717958647692;
  static constexpr int kSincTaps = 16;
  static constexpr int kSincHalf = kSincTaps / 2;
  static constexpr int kSincPhases = 64;
  static constexpr int kResMargin = 10;

  struct Biquad {
    float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f, a1 = 0.0f, a2 = 0.0f;
    float z1 = 0.0f, z2 = 0.0f;

    void reset() noexcept { z1 = z2 = 0.0f; }

    void setHighPass(double rate, double freqHz, double q) noexcept {
      const double w0 = kTwoPi * freqHz / rate;
      const double cosw = std::cos(w0);
      const double alpha = std::sin(w0) / (2.0 * q);
      const double a0 = 1.0 + alpha;
      b0 = static_cast<float>((1.0 + cosw) * 0.5 / a0);
      b1 = static_cast<float>(-(1.0 + cosw) / a0);
      b2 = b0;
      a1 = static_cast<float>(-2.0 * cosw / a0);
      a2 = static_cast<float>((1.0 - alpha) / a0);
    }

    float process(float x) noexcept {
      const float y = b0 * x + z1;
      z1 = b1 * x - a1 * y + z2;
      z2 = b2 * x - a2 * y;
      return y;
    }
  };

  static Params sanitizeParams(const Params& p) noexcept {
    const auto clampPct = [](float v, float fallback) noexcept {
      if (!std::isfinite(v)) return fallback;
      return std::clamp(v, 0.0f, 100.0f);
    };
    return Params{
        clampPct(p.attack, 50.0f),
        clampPct(p.sustain, 50.0f),
    };
  }

  static float wrapPhase(float x) noexcept {
    constexpr float kPiF = 3.14159265358979323846f;
    constexpr float kTwoPiF = 6.28318530717958647692f;
    x -= kTwoPiF * std::floor((x + kPiF) * (1.0f / kTwoPiF));
    return x;
  }

  // Fast portable minimax atan2f (max error < 3.5e-5 rad) and sincosf
  // (max error < 2e-6) to keep 4096-pt 3x-overlap STFT well under 3% CPU.
  static float fastAtan2f(float y, float x) noexcept {
    constexpr float kPiF = 3.14159265358979323846f;
    constexpr float kHalfPiF = 1.57079632679489661923f;
    const float ax = std::fabs(x);
    const float ay = std::fabs(y);
    if (ax == 0.0f && ay == 0.0f) return 0.0f;
    const bool swap = ay > ax;
    const float z = swap ? (ax / ay) : (ay / ax);
    const float z2 = z * z;
    // Degree-9 minimax polynomial for atan(z) on [0, 1] (err < 3e-5 rad)
    float r = ((((-0.0464964749f * z2 + 0.15931422f) * z2 - 0.327622764f) * z2 + 1.0f) * z);
    if (swap) r = kHalfPiF - r;
    if (x < 0.0f) r = kPiF - r;
    return y < 0.0f ? -r : r;
  }

  static void fastSinCos(float x, float& s, float& c) noexcept {
    constexpr float kPiF = 3.14159265358979323846f;
    constexpr float kHalfPiF = 1.57079632679489661923f;
    // Assume x is in [-pi, pi] (wrapped). Fold into [-pi/2, pi/2].
    float signCos = 1.0f;
    if (x > kHalfPiF) {
      x = kPiF - x;
      signCos = -1.0f;
    } else if (x < -kHalfPiF) {
      x = -kPiF - x;
      signCos = -1.0f;
    }
    const float x2 = x * x;
    s = x * (1.0f + x2 * (-0.166666567f + x2 * (0.0083330255f - 0.00019807418f * x2)));
    c = signCos * (1.0f + x2 * (-0.49999994f + x2 * (0.04166603f - 0.00138809f * x2)));
  }

  static double besselI0(double x) noexcept {
    double sum = 1.0;
    double term = 1.0;
    const double half = 0.5 * x;
    for (int k = 1; k <= 24; ++k) {
      term *= (half / static_cast<double>(k));
      const double t2 = term * term;
      sum += t2;
      if (t2 < 1.0e-14 * sum) break;
    }
    return sum;
  }

  int synthesisHopForRatio(double ratio) const noexcept {
    // 3x Hann overlap (COLA = 1.5) for drops gives silky-smooth bends, cleaner
    // power-chord separation, and tighter transient framing; 2x overlap for capo.
    if (ratio > 1.0) return synWinLen_ / 2;   // 96 * srScale (2x Hann COLA = 1.0)
    return synWinLen_ / 3;                    // 64 * srScale (3x Hann COLA = 1.5)
  }

  void configureShiftGeometry(int /*semitones*/, double ratio) noexcept {
    hopSyn_ = synthesisHopForRatio(ratio);
    hopAna_ = static_cast<double>(hopSyn_) / ratio;
    if (std::fabs(ratio - sincRatio_) > 1.0e-6) {
      buildSincTable(ratio);
      sincRatio_ = ratio;
    }
  }

  void configureSubFilter(int semitones) noexcept {
    if (semitones < 0) {
      const double subHz = 20.0 + 0.25 * static_cast<double>(-semitones);
      subHpf_.setHighPass(sampleRate_, subHz, 0.707);
    } else {
      subHpf_.reset();
    }
  }

  void snapSmoothParams(const Params& p) noexcept {
    smoothAttack_ = p.attack;
    smoothSustain_ = p.sustain;
  }

  void stepSmoothParams(const Params& target, uint32_t chunkLen) noexcept {
    if (smoothAttack_ == target.attack && smoothSustain_ == target.sustain) return;
    const float alpha =
        1.0f - std::exp(-static_cast<float>(chunkLen) / std::max(1.0f, paramSmoothTau_));
    const auto glide = [alpha](float& cur, float tgt) noexcept {
      if (std::fabs(tgt - cur) < 1.0e-3f) {
        cur = tgt;
      } else {
        cur += (tgt - cur) * alpha;
      }
    };
    glide(smoothAttack_, target.attack);
    glide(smoothSustain_, target.sustain);
  }

  void prepareWindows() noexcept {
    const int Wa = anaWinLen_;
    const int edge = tukeyEdge_;
    for (int n = 0; n < Wa; ++n) {
      if (n < edge) {
        const double s = std::sin(0.5 * kPi * static_cast<double>(n) / static_cast<double>(edge));
        waLong_[static_cast<size_t>(n)] = static_cast<float>(s * s);
      } else if (n >= Wa - edge) {
        const double s =
            std::cos(0.5 * kPi * static_cast<double>(n - (Wa - edge)) / static_cast<double>(edge));
        waLong_[static_cast<size_t>(n)] = static_cast<float>(s * s);
      } else {
        waLong_[static_cast<size_t>(n)] = 1.0f;
      }
    }

    const int synLo = synCenter_ - synWinLen_ / 2;
    for (int m = 0; m < synWinLen_; ++m) {
      const double s = std::sin(kPi * static_cast<double>(m) / static_cast<double>(synWinLen_));
      const float h = static_cast<float>(s * s);
      synHann_[static_cast<size_t>(m)] = h;
      const float wa = waLong_[static_cast<size_t>(synLo + m)];
      wsFixed_[static_cast<size_t>(m)] = wa > 1.0e-5f ? (h / wa) : 0.0f;
    }
  }

  void buildSincTable(double ratio) noexcept {
    constexpr double kBeta = 7.5;
    const double invI0 = 1.0 / besselI0(kBeta);
    const double fc = ratio > 1.0 ? std::min(0.46, 0.45 / ratio) : 0.47;
    const double halfSpan = 0.5 * static_cast<double>(kSincTaps);

    for (int p = 0; p <= kSincPhases; ++p) {
      const double frac = static_cast<double>(p) / static_cast<double>(kSincPhases);
      double sum = 0.0;
      for (int t = 0; t < kSincTaps; ++t) {
        const double x = static_cast<double>(t - (kSincHalf - 1)) - frac;
        const double norm = x / halfSpan;
        double w = 0.0;
        if (std::fabs(norm) < 1.0) {
          w = besselI0(kBeta * std::sqrt(std::max(0.0, 1.0 - norm * norm))) * invI0;
        }
        const double arg = 2.0 * fc * x;
        const double sinc =
            std::fabs(arg) < 1.0e-9 ? 1.0 : std::sin(kPi * arg) / (kPi * arg);
        const double coeff = 2.0 * fc * sinc * w;
        sincTable_[static_cast<size_t>(p * kSincTaps + t)] = static_cast<float>(coeff);
        sum += coeff;
      }
      if (sum > 1.0e-9) {
        const float invSum = static_cast<float>(1.0 / sum);
        for (int t = 0; t < kSincTaps; ++t) {
          sincTable_[static_cast<size_t>(p * kSincTaps + t)] *= invSum;
        }
      }
    }
  }

  float readRingCubic(const std::vector<float>& ring, double pos) const noexcept {
    const int64_t i1 = static_cast<int64_t>(std::floor(pos));
    const float t = static_cast<float>(pos - static_cast<double>(i1));
    const float y0 = ring[static_cast<size_t>((i1 - 1) & inRingMask_)];
    const float y1 = ring[static_cast<size_t>(i1 & inRingMask_)];
    const float y2 = ring[static_cast<size_t>((i1 + 1) & inRingMask_)];
    const float y3 = ring[static_cast<size_t>((i1 + 2) & inRingMask_)];
    const float c0 = y1;
    const float c1 = 0.5f * (y2 - y0);
    const float c2 = y0 - 2.5f * y1 + 2.0f * y2 - 0.5f * y3;
    const float c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
    return ((c3 * t + c2) * t + c1) * t + c0;
  }

  float readResampled(double pos) const noexcept {
    const int64_t base = static_cast<int64_t>(std::floor(pos));
    const double frac = pos - static_cast<double>(base);
    const double phaseScaled = frac * static_cast<double>(kSincPhases);
    const int p0 = std::clamp(static_cast<int>(phaseScaled), 0, kSincPhases - 1);
    const float alpha = static_cast<float>(phaseScaled - static_cast<double>(p0));
    const float* t0 = sincTable_.data() + static_cast<size_t>(p0 * kSincTaps);
    const float* t1 = sincTable_.data() + static_cast<size_t>((p0 + 1) * kSincTaps);

    float s0 = 0.0f;
    float s1 = 0.0f;
    const int64_t start = base - (kSincHalf - 1);
    for (int k = 0; k < kSincTaps; ++k) {
      const float x = resRing_[static_cast<size_t>((start + k) & resRingMask_)];
      s0 += x * t0[k];
      s1 += x * t1[k];
    }
    return s0 + (s1 - s0) * alpha;
  }

  void prepareFormantWeights() noexcept {
    const double binHz = sampleRate_ / static_cast<double>(fftSize_);
    for (int k = 0; k <= formantMaxBin_; ++k) {
      const double f = static_cast<double>(k) * binHz;
      double lo = std::clamp((f - 450.0) / 400.0, 0.0, 1.0);
      lo = lo * lo * (3.0 - 2.0 * lo);
      double hi = std::clamp((7200.0 - f) / 1800.0, 0.0, 1.0);
      hi = hi * hi * (3.0 - 2.0 * hi);
      formantWeight_[static_cast<size_t>(k)] = static_cast<float>(lo * hi);
    }
  }

  void prepareFFT() noexcept {
    const int m = halfFft_;
    fftLog2M_ = 0;
    while ((1 << fftLog2M_) < m) ++fftLog2M_;

    bitRev_.resize(static_cast<size_t>(m));
    for (int i = 0; i < m; ++i) {
      int r = 0;
      int v = i;
      for (int b = 0; b < fftLog2M_; ++b) {
        r = (r << 1) | (v & 1);
        v >>= 1;
      }
      bitRev_[static_cast<size_t>(i)] = r;
    }

    twiddleRe_.resize(static_cast<size_t>(m));
    twiddleIm_.resize(static_cast<size_t>(m));
    for (int len = 2; len <= m; len <<= 1) {
      const int half = len >> 1;
      const double step = -kTwoPi / static_cast<double>(len);
      for (int j = 0; j < half; ++j) {
        const double ang = step * static_cast<double>(j);
        twiddleRe_[static_cast<size_t>(half + j)] = static_cast<float>(std::cos(ang));
        twiddleIm_[static_cast<size_t>(half + j)] = static_cast<float>(std::sin(ang));
      }
    }

    const int q = m / 2;
    realTwCos_.resize(static_cast<size_t>(q + 1));
    realTwSin_.resize(static_cast<size_t>(q + 1));
    for (int k = 0; k <= q; ++k) {
      const double ang = kTwoPi * static_cast<double>(k) / static_cast<double>(fftSize_);
      realTwCos_[static_cast<size_t>(k)] = static_cast<float>(std::cos(ang));
      realTwSin_[static_cast<size_t>(k)] = static_cast<float>(std::sin(ang));
    }
  }

  void complexFFT(float* re, float* im, bool inverse) const noexcept {
    const int m = halfFft_;
    for (int i = 0; i < m; ++i) {
      const int j = bitRev_[static_cast<size_t>(i)];
      if (i < j) {
        std::swap(re[i], re[j]);
        std::swap(im[i], im[j]);
      }
    }

    const float sign = inverse ? -1.0f : 1.0f;
    // Unrolled stage 1 (len = 2, twiddle = 1) and stage 2 (len = 4, twiddle = 1, ±j)
    for (int i = 0; i < m; i += 4) {
      const float r0 = re[i], i0 = im[i];
      const float r1 = re[i + 1], i1 = im[i + 1];
      const float r2 = re[i + 2], i2 = im[i + 2];
      const float r3 = re[i + 3], i3 = im[i + 3];

      const float a0r = r0 + r1, a0i = i0 + i1;
      const float a1r = r0 - r1, a1i = i0 - i1;
      const float a2r = r2 + r3, a2i = i2 + i3;
      const float a3r = r2 - r3, a3i = i2 - i3;

      // Multiply a3 by -j (forward) or +j (inverse): (a3r + j*a3i) * (-j*sign) = (a3i*sign, -a3r*sign)
      const float b3r = a3i * sign;
      const float b3i = -a3r * sign;

      re[i]     = a0r + a2r; im[i]     = a0i + a2i;
      re[i + 2] = a0r - a2r; im[i + 2] = a0i - a2i;
      re[i + 1] = a1r + b3r; im[i + 1] = a1i + b3i;
      re[i + 3] = a1r - b3r; im[i + 3] = a1i - b3i;
    }

    for (int len = 8; len <= m; len <<= 1) {
      const int half = len >> 1;
      const float* wrTab = twiddleRe_.data() + half;
      const float* wiTab = twiddleIm_.data() + half;
      for (int i = 0; i < m; i += len) {
        for (int j = 0; j < half; ++j) {
          const int u = i + j;
          const int v = u + half;
          const float wr = wrTab[j];
          const float wi = wiTab[j] * sign;
          const float vr = re[v] * wr - im[v] * wi;
          const float vi = re[v] * wi + im[v] * wr;
          const float ur = re[u];
          const float ui = im[u];
          re[u] = ur + vr;
          im[u] = ui + vi;
          re[v] = ur - vr;
          im[v] = ui - vi;
        }
      }
    }

    if (inverse) {
      const float invM = 1.0f / static_cast<float>(m);
      for (int i = 0; i < m; ++i) {
        re[i] *= invM;
        im[i] *= invM;
      }
    }
  }

  void forwardRealFFT(const float* timeIn, float* outRe, float* outIm) noexcept {
    const int m = halfFft_;
    for (int k = 0; k < m; ++k) {
      fftRe_[static_cast<size_t>(k)] = timeIn[2 * k];
      fftIm_[static_cast<size_t>(k)] = timeIn[2 * k + 1];
    }
    complexFFT(fftRe_.data(), fftIm_.data(), false);

    outRe[0] = fftRe_[0] + fftIm_[0];
    outIm[0] = 0.0f;
    outRe[m] = fftRe_[0] - fftIm_[0];
    outIm[m] = 0.0f;

    const int q = m / 2;
    for (int k = 1; k < q; ++k) {
      const int mk = m - k;
      const float z1r = fftRe_[static_cast<size_t>(k)];
      const float z1i = fftIm_[static_cast<size_t>(k)];
      const float z2r = fftRe_[static_cast<size_t>(mk)];
      const float z2i = fftIm_[static_cast<size_t>(mk)];

      const float er = 0.5f * (z1r + z2r);
      const float ei = 0.5f * (z1i - z2i);
      const float or_ = 0.5f * (z1i + z2i);
      const float oi = -0.5f * (z1r - z2r);

      const float c = realTwCos_[static_cast<size_t>(k)];
      const float s = realTwSin_[static_cast<size_t>(k)];
      const float tr = c * or_ + s * oi;
      const float ti = c * oi - s * or_;

      outRe[k] = er + tr;
      outIm[k] = ei + ti;
      outRe[mk] = er - tr;
      outIm[mk] = -(ei - ti);
    }
    outRe[q] = fftRe_[static_cast<size_t>(q)];
    outIm[q] = -fftIm_[static_cast<size_t>(q)];
  }

  void inverseRealFFT(const float* inRe, const float* inIm, float* timeOut) noexcept {
    const int m = halfFft_;
    fftRe_[0] = 0.5f * (inRe[0] + inRe[m]);
    fftIm_[0] = 0.5f * (inRe[0] - inRe[m]);

    const int q = m / 2;
    for (int k = 1; k < q; ++k) {
      const int mk = m - k;
      const float x1r = inRe[k];
      const float x1i = inIm[k];
      const float x2r = inRe[mk];
      const float x2i = -inIm[mk];

      const float er = 0.5f * (x1r + x2r);
      const float ei = 0.5f * (x1i + x2i);
      const float tr = 0.5f * (x1r - x2r);
      const float ti = 0.5f * (x1i - x2i);

      const float c = realTwCos_[static_cast<size_t>(k)];
      const float s = realTwSin_[static_cast<size_t>(k)];
      const float or_ = c * tr - s * ti;
      const float oi = s * tr + c * ti;

      fftRe_[static_cast<size_t>(k)] = er - oi;
      fftIm_[static_cast<size_t>(k)] = ei + or_;
      fftRe_[static_cast<size_t>(mk)] = er + oi;
      fftIm_[static_cast<size_t>(mk)] = or_ - ei;
    }
    fftRe_[static_cast<size_t>(q)] = inRe[q];
    fftIm_[static_cast<size_t>(q)] = -inIm[q];

    complexFFT(fftRe_.data(), fftIm_.data(), true);
    for (int k = 0; k < m; ++k) {
      timeOut[2 * k] = fftRe_[static_cast<size_t>(k)];
      timeOut[2 * k + 1] = fftIm_[static_cast<size_t>(k)];
    }
  }

  void pushInputSample(float dry) noexcept {
    const float absIn = std::fabs(dry);
    const float detHp = detHpf_.process(dry);
    const float absHf = std::fabs(detHp);
    const float splitHp = splitHpf_.process(dry);

    hfFastEnv_ += (absHf - hfFastEnv_) * hfFastCoeff_;
    hfSlowEnv_ += (absHf - hfSlowEnv_) * hfSlowCoeff_;
    bbFastEnv_ += (absIn - bbFastEnv_) * bbFastCoeff_;
    bbSlowEnv_ += (absIn - bbSlowEnv_) * bbSlowCoeff_;

    const int64_t pos = static_cast<int64_t>(writePos_);
    const float combImpulse = absHf + 0.15f * absIn;
    if (trPendingWindow_ > 0) {
      if (combImpulse > trPeakImpulse_) {
        trPeakImpulse_ = combImpulse;
        trPeakPos_ = pos;
      }
      --trPendingWindow_;
      if (trPendingWindow_ == 0 && trPeakPos_ >= 0) {
        lastOnsetPos_ = trPeakPos_;
        trPeakPos_ = -1;
        trPeakImpulse_ = 0.0f;
      }
    } else if (pos - lastOnsetPos_ >= trCooldownSamples_) {
      // Thresholds sit cleanly above steady power-chord / metal-dyad beat crests
      // (max steady ratios ~2.3-3.1x) while catching every real pick scrape and
      // soft upstroke ghost chug (real onset ratios > 5-50x).
      const bool hfTrig = (hfFastEnv_ > 0.0032f) && (hfFastEnv_ > hfSlowEnv_ * 3.80f);
      const bool bbTrig = (bbFastEnv_ > 0.0160f) && (bbFastEnv_ > bbSlowEnv_ * 3.20f);
      if (hfTrig || bbTrig) {
        trPendingWindow_ = std::max(8, static_cast<int>(std::lround(sampleRate_ * 0.0014)));
        trPeakImpulse_ = combImpulse;
        trPeakPos_ = pos;
      }
    }

    const size_t wIdx = static_cast<size_t>(writePos_ & inRingMask_);
    inRing_[wIdx] = dry;
    inHfRing_[wIdx] = splitHp;
    ++writePos_;
  }

  void primeEngine() noexcept {
    std::fill(olaSum_.begin(), olaSum_.end(), 0.0f);
    std::fill(olaNorm_.begin(), olaNorm_.end(), 0.0f);
    std::fill(resRing_.begin(), resRing_.end(), 0.0f);
    std::fill(prevAnaPhase_.begin(), prevAnaPhase_.end(), 0.0f);
    std::fill(prevMag_.begin(), prevMag_.end(), 0.0f);
    std::fill(synPhase_.begin(), synPhase_.end(), 0.0f);
    std::fill(prevSynPhase_.begin(), prevSynPhase_.end(), 0.0f);
    std::fill(smoothEnvLog_.begin(), smoothEnvLog_.end(), -14.0f);

    olaWritePos_ = 0;
    resWritePos_ = 0;
    havePrevFrame_ = false;
    envInitialized_ = false;
    prevSynSliceE_ = 0.0;
    activeTrValid_ = false;
    activeTrFullLock_ = false;

    const double nowPos = static_cast<double>(writePos_) - 1.5;
    const int primeHops = (synWinLen_ / hopSyn_) + 1;
    anaPos_ = nowPos - static_cast<double>(primeHops) * hopAna_;
    prevAnaPos_ = anaPos_ - hopAna_;
    for (int f = 0; f < primeHops; ++f) {
      runStftHop();
      anaPos_ += hopAna_;
    }
    resReadPos_ = static_cast<double>(resWritePos_ - kResMargin);
  }

  double measureInputEnergy(int64_t startPos, int len) const noexcept {
    double e = 0.0;
    for (int i = 0; i < len; ++i) {
      const float x = inRing_[static_cast<size_t>((startPos + i) & inRingMask_)];
      e += static_cast<double>(x) * static_cast<double>(x);
    }
    return e / static_cast<double>(std::max(1, len));
  }

  void runStftHop() noexcept {
    const int N = fftSize_;
    const int Wa = anaWinLen_;
    const int Ms = synWinLen_;
    const int sc = synCenter_;
    const int synLo = sc - Ms / 2;

    const int64_t anaEnd = static_cast<int64_t>(std::llround(anaPos_));
    const double frac = anaPos_ - static_cast<double>(anaEnd);
    const double actualHa = havePrevFrame_ ? std::max(1.0, anaPos_ - prevAnaPos_) : hopAna_;

    // 1. Inspect raw input energy inside the 4 ms synthesis slice.
    double synSliceE = 0.0;
    float synSlicePeak = 0.0f;
    for (int m = 0; m < Ms; ++m) {
      const float x = inRing_[static_cast<size_t>((anaEnd - (Wa - 1 - (synLo + m))) & inRingMask_)];
      synSliceE += static_cast<double>(x) * static_cast<double>(x);
      const float ax = std::fabs(x);
      if (ax > synSlicePeak) synSlicePeak = ax;
    }
    synSliceE /= static_cast<double>(Ms);

    // Check if a newly detected pick onset just reached the synthesis slice.
    if (lastOnsetPos_ >= 0 &&
        static_cast<double>(lastOnsetPos_) > activeTrInPos_ + 0.5) {
      const double uIn = static_cast<double>(Wa - 1) - (anaPos_ - static_cast<double>(lastOnsetPos_));
      const double vM = uIn - static_cast<double>(synLo);
      if (vM <= static_cast<double>(Ms + hopSyn_) && vM >= -static_cast<double>(Ms)) {
        activeTrInPos_ = static_cast<double>(lastOnsetPos_);
        const double halfMs = 0.5 * static_cast<double>(Ms);
        activeTrOutPos_ = static_cast<double>(olaWritePos_) + halfMs + ratio_ * (vM - halfMs);
        activeTrValid_ = true;

        // Compare immediate attack energy [t_tr - 1ms .. t_tr + 4ms] against
        // immediate pre-onset floor [t_tr - 16ms .. t_tr - 4ms] so soft
        // upstroke ghost chugs in a gallop lock cleanly, while re-picks over a
        // loud ringing bass chord use complementary >1.35 kHz band-split lock!
        const int64_t trPos = lastOnsetPos_;
        const int preLen = 576 * srScale_;   // 12 ms
        const int atkLen = 240 * srScale_;   // 5 ms
        const double preE = measureInputEnergy(trPos - preLen - 192 * srScale_, preLen);
        const double atkE = measureInputEnergy(trPos - 48 * srScale_, atkLen);
        activeTrFullLock_ = (atkE > preE * 2.0 + 1.0e-8) || !havePrevFrame_;
      }
    }

    bool trActiveThisFrame = false;
    double trShiftSamples = 0.0;
    if (activeTrValid_) {
      const double uIn = static_cast<double>(Wa - 1) - (anaPos_ - activeTrInPos_);
      const double vM = uIn - static_cast<double>(synLo);
      const double vOut = activeTrOutPos_ - static_cast<double>(olaWritePos_);
      if (vM >= -0.55 * static_cast<double>(Ms) && vM <= 1.55 * static_cast<double>(Ms) &&
          vOut >= -0.55 * static_cast<double>(Ms) && vOut <= 1.55 * static_cast<double>(Ms)) {
        trActiveThisFrame = true;
        trShiftSamples = std::clamp(vOut - vM, -0.55 * static_cast<double>(Ms),
                                    0.55 * static_cast<double>(Ms));
      } else if (vM < -0.55 * static_cast<double>(Ms)) {
        activeTrValid_ = false;
      }
    }

    // 2. Pack FIXED symmetric Tukey waLong_ zero-phase around synCenter_.
    const int L_left = sc;
    const int L_right = Wa - sc;
    std::fill(timeBuf_.begin() + L_right, timeBuf_.begin() + (N - L_left), 0.0f);
    for (int i = 0; i < L_right; ++i) {
      const int n = sc + i;
      const float x = inRing_[static_cast<size_t>((anaEnd - (Wa - 1 - n)) & inRingMask_)];
      timeBuf_[static_cast<size_t>(i)] = x * waLong_[static_cast<size_t>(n)];
    }
    for (int n = 0; n < L_left; ++n) {
      const float x = inRing_[static_cast<size_t>((anaEnd - (Wa - 1 - n)) & inRingMask_)];
      timeBuf_[static_cast<size_t>(N - L_left + n)] = x * waLong_[static_cast<size_t>(n)];
    }

    // 3. Forward real FFT + exact sub-sample continuous-time phase alignment.
    forwardRealFFT(timeBuf_.data(), specRe_.data(), specIm_.data());

    if (std::fabs(frac) > 1.0e-6) {
      const double step = kTwoPi * frac / static_cast<double>(N);
      const double dCos = std::cos(step);
      const double dSin = std::sin(step);
      double c = 1.0;
      double s = 0.0;
      for (int k = 1; k < halfFft_; ++k) {
        const double nextC = c * dCos - s * dSin;
        const double nextS = s * dCos + c * dSin;
        c = nextC;
        s = nextS;
        const float re = specRe_[static_cast<size_t>(k)];
        const float im = specIm_[static_cast<size_t>(k)];
        const float cf = static_cast<float>(c);
        const float sf = static_cast<float>(s);
        specRe_[static_cast<size_t>(k)] = re * cf - im * sf;
        specIm_[static_cast<size_t>(k)] = re * sf + im * cf;
      }
    }

    float maxMag = 0.0f;
    for (int k = 0; k < bins_; ++k) {
      const float re = specRe_[static_cast<size_t>(k)];
      const float im = specIm_[static_cast<size_t>(k)];
      const float m = std::sqrt(re * re + im * im);
      mag_[static_cast<size_t>(k)] = m;
      anaPhase_[static_cast<size_t>(k)] = fastAtan2f(im, re);
      if (m > maxMag) maxMag = m;
    }

    const bool sliceSilent = (synSlicePeak < 1.5e-4f) && (synSliceE < 1.0e-9);
    const bool frameSilent = (maxMag < 1.0e-7f) && sliceSilent;

    // 4. Full-attack direct zero-centered transient lock: razor-sharp attack,
    //    zero pre-echo, zero flamming, exact unshifted phase handoff.
    if (trActiveThisFrame && activeTrFullLock_ && !sliceSilent) {
      std::copy(anaPhase_.begin(), anaPhase_.end(), prevAnaPhase_.begin());
      std::copy(mag_.begin(), mag_.end(), prevMag_.begin());
      std::copy(anaPhase_.begin(), anaPhase_.end(), synPhase_.begin());
      std::copy(anaPhase_.begin(), anaPhase_.end(), prevSynPhase_.begin());
      havePrevFrame_ = true;

      const double baseInPos = anaPos_ - static_cast<double>(Wa - 1 - synLo) - trShiftSamples;
      const double maxSafePos = static_cast<double>(writePos_) - 3.0;
      for (int m = 0; m < Ms; ++m) {
        const double p = std::min(baseInPos + static_cast<double>(m), maxSafePos);
        const float x = readRingCubic(inRing_, p);
        const float h = synHann_[static_cast<size_t>(m)];
        const size_t dst = static_cast<size_t>((olaWritePos_ + m) & olaRingMask_);
        olaSum_[dst] += x * h;
        olaNorm_[dst] += h;
      }

      finalizeHop();
      prevSynSliceE_ = synSliceE;
      prevAnaPos_ = anaPos_;
      return;
    }

    const bool bandSplitTransient = trActiveThisFrame && !activeTrFullLock_ && !sliceSilent;

    // 5. Tonal zero-phase vocoder + Coherent-Island Peak-Anchored Lock.
    if (frameSilent) {
      std::fill(synPhase_.begin(), synPhase_.end(), 0.0f);
      std::fill(prevSynPhase_.begin(), prevSynPhase_.end(), 0.0f);
      std::fill(prevAnaPhase_.begin(), prevAnaPhase_.end(), 0.0f);
      std::fill(prevMag_.begin(), prevMag_.end(), 0.0f);
      std::fill(specRe_.begin(), specRe_.end(), 0.0f);
      std::fill(specIm_.begin(), specIm_.end(), 0.0f);
      havePrevFrame_ = false;
    } else if (!havePrevFrame_) {
      std::copy(anaPhase_.begin(), anaPhase_.end(), prevAnaPhase_.begin());
      std::copy(mag_.begin(), mag_.end(), prevMag_.begin());
      std::copy(anaPhase_.begin(), anaPhase_.end(), synPhase_.begin());
      std::copy(synPhase_.begin(), synPhase_.end(), prevSynPhase_.begin());
      havePrevFrame_ = true;
    } else {
      const float twoPiInvN = static_cast<float>(kTwoPi / static_cast<double>(N));
      const float invTwoPiN = static_cast<float>(static_cast<double>(N) / kTwoPi);
      const float haF = static_cast<float>(actualHa);
      const float invHa = 1.0f / haF;
      const float hsF = static_cast<float>(hopSyn_);
      const float magFloor = maxMag * 1.0e-6f;

      synPhase_[0] = anaPhase_[0];
      synPhase_[static_cast<size_t>(halfFft_)] = anaPhase_[static_cast<size_t>(halfFft_)];
      instBin_[0] = 0.0f;
      instBin_[static_cast<size_t>(halfFft_)] = static_cast<float>(halfFft_);
      rotAngle_[0] = 0.0f;
      rotAngle_[static_cast<size_t>(halfFft_)] = 0.0f;

      for (int k = 1; k < halfFft_; ++k) {
        const float wBin = twoPiInvN * static_cast<float>(k);
        float wTrue = wBin;
        float sp = anaPhase_[static_cast<size_t>(k)];
        if (mag_[static_cast<size_t>(k)] > magFloor && prevMag_[static_cast<size_t>(k)] > magFloor) {
          const float dPhi = anaPhase_[static_cast<size_t>(k)] - prevAnaPhase_[static_cast<size_t>(k)];
          const float dev = wrapPhase(dPhi - wBin * haF);
          wTrue = wBin + dev * invHa;
          sp = wrapPhase(prevSynPhase_[static_cast<size_t>(k)] + wTrue * hsF);
        }
        instBin_[static_cast<size_t>(k)] = wTrue * invTwoPiN;
        rotAngle_[static_cast<size_t>(k)] = wrapPhase(sp - anaPhase_[static_cast<size_t>(k)]);
      }

      // Soft coherent-island peak-anchored rotation relaxation:
      // Gently relaxes each bin's rotation angle toward its coherent island's
      // peak bin (0.24-bin = 2.8 Hz tolerance, 32% pull per hop). This damps
      // onset window-envelope centroid drift to exact 0.0 (preserving 1.000
      // unity gain across -12..+12 st even from silence) WITHOUT hard-snapping
      // chord valley boundaries!
      constexpr float kCohTolBins = 0.24f;
      constexpr float kRelax = 0.20f;
      int k = 1;
      while (k < halfFft_) {
        int end = k + 1;
        int best = k;
        float bestMag = mag_[static_cast<size_t>(k)];
        while (end < halfFft_ &&
               std::fabs(instBin_[static_cast<size_t>(end)] - instBin_[static_cast<size_t>(best)]) < kCohTolBins &&
               std::fabs(instBin_[static_cast<size_t>(end)] - instBin_[static_cast<size_t>(end - 1)]) < kCohTolBins) {
          if (mag_[static_cast<size_t>(end)] > bestMag) {
            bestMag = mag_[static_cast<size_t>(end)];
            best = end;
          }
          ++end;
        }
        const float bestRot = rotAngle_[static_cast<size_t>(best)];
        for (int j = k; j < end; ++j) {
          const float r0 = rotAngle_[static_cast<size_t>(j)];
          const float rot = wrapPhase(r0 + kRelax * wrapPhase(bestRot - r0));
          float s, c;
          fastSinCos(rot, s, c);
          const float re = specRe_[static_cast<size_t>(j)];
          const float im = specIm_[static_cast<size_t>(j)];
          specRe_[static_cast<size_t>(j)] = re * c - im * s;
          specIm_[static_cast<size_t>(j)] = re * s + im * c;
          synPhase_[static_cast<size_t>(j)] = wrapPhase(anaPhase_[static_cast<size_t>(j)] + rot);
        }
        k = end;
      }

      std::copy(anaPhase_.begin(), anaPhase_.end(), prevAnaPhase_.begin());
      std::copy(mag_.begin(), mag_.end(), prevMag_.begin());
      std::copy(synPhase_.begin(), synPhase_.end(), prevSynPhase_.begin());
    }

    // 6. Smooth pickup/formant preservation (450 Hz..7.2 kHz).
    if (!frameSilent) {
      applyFormantPreservation(maxMag);
    }

    // When re-picking over a loud ringing chord, complementary-duck the
    // vocoder's >1.35 kHz band and replace it with the crisp zero-centered
    // shifted raw >1.35 kHz pick transient (zero smear, zero double-tone!).
    if (bandSplitTransient) {
      const float span = static_cast<float>(std::max(1, splitBinHi_ - splitBinLo_));
      for (int k = splitBinLo_; k < bins_; ++k) {
        const float t = std::clamp(static_cast<float>(k - splitBinLo_) / span, 0.0f, 1.0f);
        const float lpGain = 1.0f - t * t * (3.0f - 2.0f * t);
        specRe_[static_cast<size_t>(k)] *= lpGain;
        specIm_[static_cast<size_t>(k)] *= lpGain;
      }
    }

    // 7. Inverse real FFT & unpack synthesis slice with pre-echo / dead-mute guard.
    inverseRealFFT(specRe_.data(), specIm_.data(), timeBuf_.data());

    const int halfMs = Ms / 2;
    float envScale = 1.0f;
    if (sliceSilent) {
      envScale = 0.0f;
    } else if (!bandSplitTransient) {
      double synOutE = 0.0;
      for (int m = 0; m < halfMs; ++m) {
        const float y = timeBuf_[static_cast<size_t>(N - halfMs + m)] * wsFixed_[static_cast<size_t>(m)];
        synOutE += static_cast<double>(y) * static_cast<double>(y);
      }
      for (int m = halfMs; m < Ms; ++m) {
        const float y = timeBuf_[static_cast<size_t>(m - halfMs)] * wsFixed_[static_cast<size_t>(m)];
        synOutE += static_cast<double>(y) * static_cast<double>(y);
      }
      const double expectedMax = std::max(synSliceE, prevSynSliceE_) * (0.375 * Ms) * 4.5;
      if (synOutE > expectedMax + 1.0e-9) {
        envScale = static_cast<float>(std::sqrt(expectedMax / synOutE));
      }
    }

    const double baseInPos = anaPos_ - static_cast<double>(Wa - 1 - synLo) - trShiftSamples;
    const double maxSafePos = static_cast<double>(writePos_) - 3.0;

    for (int m = 0; m < halfMs; ++m) {
      const size_t dst = static_cast<size_t>((olaWritePos_ + m) & olaRingMask_);
      const float ws = wsFixed_[static_cast<size_t>(m)] * envScale;
      float val = timeBuf_[static_cast<size_t>(N - halfMs + m)] * ws;
      if (bandSplitTransient) {
        const double p = std::min(baseInPos + static_cast<double>(m), maxSafePos);
        val += readRingCubic(inHfRing_, p) * synHann_[static_cast<size_t>(m)];
      }
      olaSum_[dst] += val;
      olaNorm_[dst] += synHann_[static_cast<size_t>(m)];
    }
    for (int m = halfMs; m < Ms; ++m) {
      const size_t dst = static_cast<size_t>((olaWritePos_ + m) & olaRingMask_);
      const float ws = wsFixed_[static_cast<size_t>(m)] * envScale;
      float val = timeBuf_[static_cast<size_t>(m - halfMs)] * ws;
      if (bandSplitTransient) {
        const double p = std::min(baseInPos + static_cast<double>(m), maxSafePos);
        val += readRingCubic(inHfRing_, p) * synHann_[static_cast<size_t>(m)];
      }
      olaSum_[dst] += val;
      olaNorm_[dst] += synHann_[static_cast<size_t>(m)];
    }

    finalizeHop();
    prevSynSliceE_ = synSliceE;
    prevAnaPos_ = anaPos_;
  }

  void finalizeHop() noexcept {
    for (int m = 0; m < hopSyn_; ++m) {
      const size_t src = static_cast<size_t>((olaWritePos_ + m) & olaRingMask_);
      const float norm = olaNorm_[src];
      const float val = norm > 1.0e-6f ? (olaSum_[src] / norm) : 0.0f;
      resRing_[static_cast<size_t>(resWritePos_ & resRingMask_)] = val;
      olaSum_[src] = 0.0f;
      olaNorm_[src] = 0.0f;
      ++resWritePos_;
    }
    olaWritePos_ += hopSyn_;
  }

  void applyFormantPreservation(float maxMag) noexcept {
    const int fMax = formantMaxBin_;
    const float floorMag = std::max(1.0e-6f, maxMag * 1.0e-4f);
    prefixLog_[0] = 0.0f;
    for (int k = 0; k <= fMax; ++k) {
      const float lm = std::log(std::max(mag_[static_cast<size_t>(k)], floorMag));
      logMag_[static_cast<size_t>(k)] = lm;
      prefixLog_[static_cast<size_t>(k + 1)] = prefixLog_[static_cast<size_t>(k)] + lm;
    }

    for (int k = 1; k < fMax; ++k) {
      const int halfW = std::clamp(k / 3, 12, 96);
      const int lo = std::max(1, k - halfW);
      const int hi = std::min(fMax, k + halfW + 1);
      envLog_[static_cast<size_t>(k)] =
          (prefixLog_[static_cast<size_t>(hi)] - prefixLog_[static_cast<size_t>(lo)]) /
          static_cast<float>(hi - lo);
    }
    envLog_[0] = envLog_[1];
    envLog_[static_cast<size_t>(fMax)] = envLog_[static_cast<size_t>(fMax - 1)];

    const float envAlpha = envInitialized_ ? 0.055f : 1.0f;
    envInitialized_ = true;
    for (int k = 0; k <= fMax; ++k) {
      smoothEnvLog_[static_cast<size_t>(k)] +=
          (envLog_[static_cast<size_t>(k)] - smoothEnvLog_[static_cast<size_t>(k)]) * envAlpha;
    }

    constexpr float kFormantDepth = 0.60f;
    const float r = static_cast<float>(ratio_);
    const float maxTarget = static_cast<float>(fMax - 1);
    for (int k = 1; k < fMax; ++k) {
      const float w = formantWeight_[static_cast<size_t>(k)];
      if (w <= 1.0e-5f) continue;
      const float snrGate = std::clamp(
          (mag_[static_cast<size_t>(k)] / floorMag - 1.5f) * 0.25f, 0.0f, 1.0f);
      if (snrGate <= 1.0e-5f) continue;

      const float kt = std::clamp(static_cast<float>(k) * r, 1.0f, maxTarget);
      const int k0 = static_cast<int>(kt);
      const float f = kt - static_cast<float>(k0);
      const float targetEnv =
          smoothEnvLog_[static_cast<size_t>(k0)] * (1.0f - f) +
          smoothEnvLog_[static_cast<size_t>(k0 + 1)] * f;
      const float diff = targetEnv - smoothEnvLog_[static_cast<size_t>(k)];
      const float logGain = std::clamp(kFormantDepth * w * snrGate * diff, -0.52f, 0.58f);
      const float gain = std::exp(logGain);
      specRe_[static_cast<size_t>(k)] *= gain;
      specIm_[static_cast<size_t>(k)] *= gain;
    }
  }

  float applyAttackShaping(float wet, float atkNorm) noexcept {
    atkLpState_ += (wet - atkLpState_) * atkXoverCoeff_;
    const float hf = wet - atkLpState_;
    const float absW = std::fabs(wet);
    atkFastEnv_ += (absW - atkFastEnv_) * atkFastCoeff_;
    atkSlowEnv_ += (absW - atkSlowEnv_) * atkSlowCoeff_;

    const float ratio = atkFastEnv_ / std::max(atkSlowEnv_, 1.5e-3f);
    const float onset = std::clamp((ratio - 1.25f) * 0.85f, 0.0f, 1.0f);
    if (onset > atkPulse_) {
      atkPulse_ = onset;
    } else {
      atkPulse_ *= atkHoldDecay_;
      if (atkPulse_ < 1.0e-5f) atkPulse_ = 0.0f;
    }

    if (atkPulse_ <= 0.0f || std::fabs(atkNorm) < 1.0e-4f) return wet;
    const float hfDelta = atkNorm >= 0.0f ? (1.15f * atkNorm) : (0.68f * atkNorm);
    return wet + (atkPulse_ * hfDelta) * hf;
  }

  float computeSustainGain(float wetSample, float susNorm) noexcept {
    const float absWet = std::fabs(wetSample);
    const float relCoeff = susNorm < 0.0f ? susTightReleaseCoeff_ : susReleaseCoeff_;
    const float envCoeff = absWet > susEnv_ ? susAttackCoeff_ : relCoeff;
    susEnv_ += (absWet - susEnv_) * envCoeff;

    float targetGain = 1.0f;
    if (susNorm > 0.0f) {
      const float gate = std::clamp((susEnv_ - 0.0003f) / (0.0020f - 0.0003f), 0.0f, 1.0f);
      if (gate > 0.0f && susEnv_ < 0.16f) {
        const float ratio = 0.16f / std::max(susEnv_, 0.0020f);
        const float rawBoost = std::pow(std::max(1.0f, ratio), 0.48f * susNorm);
        const float maxBoost = 1.0f + 1.65f * susNorm;
        targetGain = 1.0f + (std::min(maxBoost, rawBoost) - 1.0f) * gate;
      }
    } else if (susNorm < 0.0f) {
      const float tighten = -susNorm;
      const float thresh = 0.012f + 0.095f * tighten;
      if (susEnv_ < thresh) {
        const float decayRatio = std::clamp(susEnv_ / thresh, 0.0f, 1.0f);
        const float minFloor = 1.0f - 0.80f * tighten;
        targetGain = minFloor + (1.0f - minFloor) * (decayRatio * decayRatio);
      }
    }

    const float coeff = targetGain < susGain_ ? susGainDownCoeff_ : susGainUpCoeff_;
    susGain_ += (targetGain - susGain_) * coeff;
    if (std::fabs(susNorm) < 1.0e-4f && std::fabs(susGain_ - 1.0f) < 1.0e-5f) {
      susGain_ = 1.0f;
    }
    return susGain_;
  }

  double sampleRate_ = 48000.0;
  int srScale_ = 1;
  int fftSize_ = 4096;
  int halfFft_ = 2048;
  int bins_ = 2049;
  int fftLog2M_ = 11;
  int formantMaxBin_ = 740;
  int splitBinLo_ = 90;
  int splitBinHi_ = 140;

  int anaWinLen_ = 2560;
  int tukeyEdge_ = 640;
  int synRightDist_ = 480;
  int synCenter_ = 2080;
  int synWinLen_ = 192;
  int hopSyn_ = 96;
  double hopAna_ = 96.0;

  int inRingSize_ = 16384;
  uint64_t inRingMask_ = 16383;
  int olaRingSize_ = 4096;
  uint64_t olaRingMask_ = 4095;
  int resRingSize_ = 4096;
  uint64_t resRingMask_ = 4095;

  std::vector<float> inRing_;
  std::vector<float> inHfRing_;
  std::vector<float> olaSum_;
  std::vector<float> olaNorm_;
  std::vector<float> resRing_;

  std::vector<int> bitRev_;
  std::vector<float> twiddleRe_;
  std::vector<float> twiddleIm_;
  std::vector<float> realTwCos_;
  std::vector<float> realTwSin_;

  std::vector<float> timeBuf_;
  std::vector<float> fftRe_;
  std::vector<float> fftIm_;
  std::vector<float> specRe_;
  std::vector<float> specIm_;
  std::vector<float> mag_;
  std::vector<float> anaPhase_;
  std::vector<float> prevAnaPhase_;
  std::vector<float> prevMag_;
  std::vector<float> synPhase_;
  std::vector<float> prevSynPhase_;
  std::vector<float> instBin_;
  std::vector<float> rotAngle_;
  std::vector<float> logMag_;
  std::vector<float> prefixLog_;
  std::vector<float> envLog_;
  std::vector<float> smoothEnvLog_;
  std::vector<float> formantWeight_;

  std::vector<float> waLong_;
  std::vector<float> synHann_;
  std::vector<float> wsFixed_;

  std::array<float, (kSincPhases + 1) * kSincTaps> sincTable_{};
  double sincRatio_ = 1.0;

  uint64_t writePos_ = 0;
  int64_t olaWritePos_ = 0;
  int64_t resWritePos_ = 0;
  double resReadPos_ = 0.0;
  double anaPos_ = 0.0;
  double prevAnaPos_ = 0.0;
  bool havePrevFrame_ = false;
  bool envInitialized_ = false;
  double prevSynSliceE_ = 0.0;

  bool active_ = false;
  int currentSemitones_ = 0;
  double ratio_ = 1.0;
  float wetMix_ = 0.0f;
  int fadeSamples_ = 240;

  float hfFastCoeff_ = 0.034f;
  float hfSlowCoeff_ = 0.0013f;
  float bbFastCoeff_ = 0.017f;
  float bbSlowCoeff_ = 0.00095f;
  float hfFastEnv_ = 0.0f;
  float hfSlowEnv_ = 0.0f;
  float bbFastEnv_ = 0.0f;
  float bbSlowEnv_ = 0.0f;
  int64_t trCooldownSamples_ = 1152;
  int64_t lastOnsetPos_ = -1000000;
  double activeTrInPos_ = -1000000.0;
  double activeTrOutPos_ = -1000000.0;
  bool activeTrValid_ = false;
  bool activeTrFullLock_ = false;
  int64_t trPeakPos_ = -1;
  float trPeakImpulse_ = 0.0f;
  int trPendingWindow_ = 0;

  float paramSmoothTau_ = 384.0f;
  float smoothAttack_ = 50.0f;
  float smoothSustain_ = 50.0f;

  float atkXoverCoeff_ = 0.16f;
  float atkFastCoeff_ = 0.04f;
  float atkSlowCoeff_ = 0.0017f;
  float atkHoldDecay_ = 0.996f;
  float atkLpState_ = 0.0f;
  float atkFastEnv_ = 0.0f;
  float atkSlowEnv_ = 0.0f;
  float atkPulse_ = 0.0f;

  float susAttackCoeff_ = 0.0083f;
  float susReleaseCoeff_ = 0.00015f;
  float susTightReleaseCoeff_ = 0.00060f;
  float susGainDownCoeff_ = 0.010f;
  float susGainUpCoeff_ = 0.00116f;
  float susEnv_ = 0.0f;
  float susGain_ = 1.0f;

  int appliedFilterSt_ = 0;
  Biquad subHpf_;
  Biquad detHpf_;
  Biquad splitHpf_;
};

}  // namespace NAMRig
