#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

// Frozen pre-Power/Tube post stage from amp_advanced.h. Preserve statements and
// arithmetic order, including smoothing, for exact comparisons with FMA enabled.
namespace LegacyAmp {
class AmpAdvanced {
 public:
  void processPostAmp(float* samples, size_t count, double rate,
                      float presenceDb, float depthDb, float sagAmount,
                      float biasAmount, float feedbackAmount,
                      float masterAmount) noexcept {
    const float presenceTarget = std::max(-12.0f, std::min(12.0f, presenceDb));
    const float depthTarget = std::max(-12.0f, std::min(12.0f, depthDb));
    const float sagTarget = clamp01(sagAmount * 0.01f);
    const float biasTarget = std::max(-1.0f, std::min(1.0f, biasAmount * 0.01f));
    const float feedbackTarget = clamp01(feedbackAmount * 0.01f);
    const float masterTarget = clamp01(masterAmount * 0.01f);
    const bool targetsNeutral = presenceTarget == 0.0f && depthTarget == 0.0f &&
                                sagTarget == 0.0f && biasTarget == 0.0f &&
                                feedbackTarget == 0.0f && masterTarget == 0.0f;
    const bool stateNeutral = smoothPresence_ == 0.0f && smoothDepth_ == 0.0f &&
                              smoothSag_ == 0.0f && smoothBias_ == 0.0f &&
                              smoothFeedback_ == 0.0f && smoothMaster_ == 0.0f;
    if (targetsNeutral && stateNeutral) {
      resetLoop();
      return;
    }

    for (size_t start = 0; start < count; start += kChunk) {
      const size_t n = std::min(kChunk, count - start);
      const float smooth = chunkCoeff(rate, n);
      glide(smoothPresence_, presenceTarget, smooth);
      glide(smoothDepth_, depthTarget, smooth);
      glide(smoothSag_, sagTarget, smooth);
      glide(smoothBias_, biasTarget, smooth);
      glide(smoothFeedback_, feedbackTarget, smooth);
      glide(smoothMaster_, masterTarget, smooth);

      const double beta = 0.15 + 0.75 * smoothFeedback_;
      const double loopGain = kOpenLoopGain * beta;
      if (smoothPresence_ != appliedPresence_ || smoothFeedback_ != appliedFeedback_ ||
          smoothDepth_ != appliedDepth_) {
        setShelf(presence_, feedbackShelfDb(smoothPresence_, loopGain), 3200.0f, rate, true);
        setShelf(depth_, feedbackShelfDb(smoothDepth_, loopGain), 110.0f, rate, false);
        appliedPresence_ = smoothPresence_;
        appliedDepth_ = smoothDepth_;
        appliedFeedback_ = smoothFeedback_;
      }
      const double drive = std::pow(10.0, 1.8 * smoothMaster_);
      const double inputScale = drive * (1.0 + loopGain) / kOpenLoopGain;
      const double outputScale = 1.0 / std::sqrt(drive);
      const double sagDepth = 0.5 * smoothSag_;
      const double excursionDepth = 0.4 * smoothSag_;
      const double biasStatic = 0.45 * smoothBias_;
      const double nonlinearAmount = std::max(
          std::max(static_cast<double>(smoothSag_),
                   std::fabs(static_cast<double>(smoothBias_))),
          std::max(static_cast<double>(smoothFeedback_),
                   static_cast<double>(smoothMaster_)));
      const double attack = 1.0 - std::exp(-1.0 / (rate * 0.015));
      const double release = 1.0 - std::exp(-1.0 / (rate * 0.220));

      float* s = samples + start;
      for (size_t i = 0; i < n; ++i) {
        const double f0 = depth_.b0 * presence_.b0;
        const double partial = presence_.b0 * depth_.z1 + presence_.z1;
        const double c = s[i] * inputScale - beta * partial;
        const double k = beta * f0;
        const double headroom = 1.0 - sagDepth * supplyEnvelope_;
        const double bias = biasStatic - excursionDepth * supplyEnvelope_;
        const double biasOut = sat(bias);
        const double solved = solve(kOpenLoopGain / headroom, k * headroom,
                                    c + k * headroom * biasOut +
                                        bias * headroom / kOpenLoopGain);
        const double normalized = solved - biasOut;
        const double nonlinearY = headroom * normalized;
        const double linearY = kOpenLoopGain * c / (1.0 + kOpenLoopGain * k);
        const double y = linearY + nonlinearAmount * (nonlinearY - linearY);
        const double level = std::fabs(normalized);
        supplyEnvelope_ += (level - supplyEnvelope_) *
                           (level > supplyEnvelope_ ? attack : release);
        presence_.advance(depth_.advance(y));
        s[i] = static_cast<float>(y * outputScale);
      }
    }
  }

 private:
  static constexpr size_t kChunk = 32;
  static constexpr double kOpenLoopGain = 10.0;
  static constexpr double kKnee = 0.7;
  static constexpr double kPi = 3.14159265358979323846;
  static constexpr double kQ = 0.7071067811865476;

  struct Filter {
    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;
    double z1 = 0.0, z2 = 0.0;
    double advance(double x) noexcept {
      const double y = b0 * x + z1;
      z1 = b1 * x - a1 * y + z2;
      z2 = b2 * x - a2 * y;
      return y;
    }
    void reset() noexcept { z1 = z2 = 0.0; }
    void identity() noexcept {
      b0 = 1.0; b1 = b2 = a1 = a2 = 0.0;
      reset();
    }
  };

  void resetLoop() noexcept {
    presence_.identity();
    depth_.identity();
    smoothPresence_ = smoothDepth_ = smoothSag_ = smoothBias_ = 0.0f;
    smoothFeedback_ = smoothMaster_ = 0.0f;
    appliedPresence_ = appliedDepth_ = appliedFeedback_ = 1.0e9f;
    supplyEnvelope_ = 0.0;
  }

  static float clamp01(float x) noexcept { return std::max(0.0f, std::min(1.0f, x)); }
  static float chunkCoeff(double rate, size_t n) noexcept {
    return 1.0f - static_cast<float>(std::exp(-static_cast<double>(n) / (rate * 0.015)));
  }
  static void glide(float& value, float target, float coeff) noexcept {
    value += (target - value) * coeff;
    if (std::fabs(target - value) < 1.0e-4f) value = target;
  }

  static double feedbackShelfDb(double targetDb, double loopGain) noexcept {
    const double t = std::pow(10.0, targetDb / 20.0);
    double g = ((1.0 + loopGain) / t - 1.0) / loopGain;
    g = std::max(0.02, std::min(50.0, g));
    return 20.0 * std::log10(g);
  }

  static double sat(double u) noexcept {
    const double a = std::fabs(u);
    if (a <= kKnee) return u;
    const double d = 1.0 - kKnee;
    const double v = a - kKnee;
    const double w = d * v / (d + v);
    return u < 0.0 ? -(kKnee + w) : kKnee + w;
  }

  static double solve(double A, double k, double c) noexcept {
    const double lin = A * c / (1.0 + A * k);
    if (std::fabs(lin) <= kKnee) return lin;
    const double sign = c < 0.0 ? -1.0 : 1.0;
    c = std::fabs(c);
    const double t = kKnee, d = 1.0 - kKnee;
    const double a2 = A * k;
    const double b2 = -(A * (c - k * t + k * d) + d - t);
    const double c2 = d * (A * (c - k * t) - t);
    const double disc = std::max(0.0, b2 * b2 - 4.0 * a2 * c2);
    const double w = 2.0 * c2 / (-b2 + std::sqrt(disc));
    return sign * (t + std::min(w, d));
  }

  static void setShelf(Filter& f, double gainDb, float frequency, double rate,
                       bool high) noexcept {
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w0 = 2.0 * kPi * frequency / rate;
    const double c = std::cos(w0), s = std::sin(w0);
    const double alpha = s / (2.0 * kQ);
    const double sqA = 2.0 * std::sqrt(A) * alpha;
    double b0, b1, b2, a0, a1, a2;
    if (high) {
      b0 = A * ((A + 1) + (A - 1) * c + sqA);
      b1 = -2.0 * A * ((A - 1) + (A + 1) * c);
      b2 = A * ((A + 1) + (A - 1) * c - sqA);
      a0 = (A + 1) - (A - 1) * c + sqA;
      a1 = 2.0 * ((A - 1) - (A + 1) * c);
      a2 = (A + 1) - (A - 1) * c - sqA;
    } else {
      b0 = A * ((A + 1) - (A - 1) * c + sqA);
      b1 = 2.0 * A * ((A - 1) - (A + 1) * c);
      b2 = A * ((A + 1) - (A - 1) * c - sqA);
      a0 = (A + 1) + (A - 1) * c + sqA;
      a1 = -2.0 * ((A - 1) + (A + 1) * c);
      a2 = (A + 1) + (A - 1) * c - sqA;
    }
    f.b0 = b0 / a0;
    f.b1 = b1 / a0;
    f.b2 = b2 / a0;
    f.a1 = a1 / a0;
    f.a2 = a2 / a0;
  }

  Filter depth_, presence_;
  float smoothPresence_ = 0.0f, smoothDepth_ = 0.0f, smoothSag_ = 0.0f;
  float smoothBias_ = 0.0f, smoothFeedback_ = 0.0f, smoothMaster_ = 0.0f;
  float appliedPresence_ = 1.0e9f, appliedDepth_ = 1.0e9f, appliedFeedback_ = 1.0e9f;
  double supplyEnvelope_ = 0.0;
};
} // namespace LegacyAmp
