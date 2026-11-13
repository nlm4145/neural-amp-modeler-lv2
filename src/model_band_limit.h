#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>

namespace NAMRig {

// Low-pass in front of a NAM model that runs above its training rate.
//
// A model is trained on audio below half of its own sample rate. In an
// oversampled domain, an upstream nonlinear stage (overdrive, pedal model)
// sends it content above that limit, and the model treats that content with
// the gain it learned for the folded frequency. This filter removes it:
// default 8th-order Chebyshev type I, 0.05 dB ripple, 20.5 kHz passband edge
// (0.427 of a 48 kHz model rate), with user-configurable cutoff, slope
// (2nd/4th/6th/8th order), and passband ripple.
//
// The on/off control fades over 5 ms. The filter is skipped (bit-identical
// bypass) when it is off and when the domain rate does not exceed the model rate.
class ModelBandLimit {
 public:
  static constexpr double kPassbandOfModelRate = 0.427;
  static constexpr double kRippleDb = 0.05;
  static constexpr float kMinCutoffHz = 4000.0f;
  static constexpr float kMaxCutoffHz = 24000.0f;
  static constexpr float kDefaultCutoffHz = 20500.0f;
  static constexpr int kMinSlope = 0;
  static constexpr int kMaxSlope = 3;
  static constexpr int kDefaultSlope = 3;  // 0..3 => 1..4 biquads (12..48 dB/oct)
  static constexpr float kMinRippleDb = 0.01f;
  static constexpr float kMaxRippleDb = 1.00f;
  static constexpr float kDefaultRippleDb = 0.05f;
  static constexpr int kMaxSections = 4;

  struct Params {
    float cutoffHz = kDefaultCutoffHz;
    int slope = kDefaultSlope;
    float rippleDb = kDefaultRippleDb;
  };

  static float clampCutoffHz(float v) noexcept {
    return std::isfinite(v) ? std::clamp(v, kMinCutoffHz, kMaxCutoffHz) : kDefaultCutoffHz;
  }

  static int clampSlope(float v) noexcept {
    return std::isfinite(v)
               ? std::clamp(static_cast<int>(std::lround(v)), kMinSlope, kMaxSlope)
               : kDefaultSlope;
  }

  static float clampRippleDb(float v) noexcept {
    return std::isfinite(v) ? std::clamp(v, kMinRippleDb, kMaxRippleDb) : kDefaultRippleDb;
  }

  void reset() noexcept {
    for (Section& s : sections_) {
      s.z1 = 0.0;
      s.z2 = 0.0;
    }
    mix_ = 0.0f;
  }

  static bool applies(double domainRate, double modelRate) noexcept {
    return modelRate > 0.0 && domainRate > modelRate * 1.01;
  }

  void process(float* samples, size_t count, double domainRate, double modelRate,
               bool enabled) noexcept {
    process(samples, count, domainRate, modelRate, enabled, Params{});
  }

  void process(float* samples, size_t count, double domainRate, double modelRate,
               bool enabled, const Params& rawParams) noexcept {
    if (!samples || count == 0) return;
    const Params target = sanitizeParams(rawParams);
    const bool wanted = enabled && applies(domainRate, modelRate);
    if (!wanted && mix_ <= 0.0f) {
      smoothCutoffHz_ = target.cutoffHz;
      smoothRippleDb_ = target.rippleDb;
      return;
    }

    const int targetSections = target.slope + 1;
    if (mix_ <= 0.0f && wanted) {
      smoothCutoffHz_ = target.cutoffHz;
      smoothRippleDb_ = target.rippleDb;
      design(domainRate, modelRate, smoothCutoffHz_, targetSections, smoothRippleDb_);
      for (Section& s : sections_) {
        s.z1 = 0.0;
        s.z2 = 0.0;
      }
    } else if (domainRate != domainRate_ || modelRate != modelRate_) {
      design(domainRate, modelRate, smoothCutoffHz_, targetSections, smoothRippleDb_);
      for (Section& s : sections_) {
        s.z1 = 0.0;
        s.z2 = 0.0;
      }
    }

    const float targetMix = wanted ? 1.0f : 0.0f;
    const float step = static_cast<float>(1.0 / (domainRate * 0.005));
    const double smoothTau = std::max(1.0, domainRate * 0.005);
    constexpr size_t kCtrlChunk = 32;

    for (size_t offset = 0; offset < count; offset += kCtrlChunk) {
      const size_t chunkEnd = std::min(count, offset + kCtrlChunk);
      const size_t chunkLen = chunkEnd - offset;

      if (smoothCutoffHz_ != target.cutoffHz || smoothRippleDb_ != target.rippleDb) {
        const double alpha = 1.0 - std::exp(-static_cast<double>(chunkLen) / smoothTau);
        const auto glide = [alpha](double& cur, double tgt) noexcept {
          if (std::fabs(tgt - cur) < 1.0e-3) cur = tgt;
          else cur += (tgt - cur) * alpha;
        };
        glide(smoothCutoffHz_, target.cutoffHz);
        glide(smoothRippleDb_, target.rippleDb);
      }

      if (targetSections != activeSections_ ||
          smoothCutoffHz_ != designedCutoffHz_ ||
          smoothRippleDb_ != designedRippleDb_) {
        const int prevSections = activeSections_;
        design(domainRate, modelRate, smoothCutoffHz_, targetSections, smoothRippleDb_);
        for (int s = prevSections; s < activeSections_; ++s) {
          sections_[static_cast<size_t>(s)].z1 = 0.0;
          sections_[static_cast<size_t>(s)].z2 = 0.0;
        }
      }

      for (size_t i = offset; i < chunkEnd; ++i) {
        double y = samples[i];
        for (int s = 0; s < activeSections_; ++s) {
          Section& sec = sections_[static_cast<size_t>(s)];
          const double out = sec.b0 * y + sec.z1;
          sec.z1 = sec.b1 * y - sec.a1 * out + sec.z2;
          sec.z2 = sec.b2 * y - sec.a2 * out;
          y = out;
        }
        if (mix_ < targetMix) mix_ = std::min(targetMix, mix_ + step);
        else if (mix_ > targetMix) mix_ = std::max(targetMix, mix_ - step);
        samples[i] += mix_ * (static_cast<float>(y) - samples[i]);
      }
    }

    if (!wanted && mix_ <= 0.0f) reset();
  }

  // Magnitude response in dB of the filter for this domain and model rate.
  static double responseDb(double hz, double domainRate, double modelRate) noexcept {
    return responseDb(hz, domainRate, modelRate, Params{});
  }

  static double responseDb(double hz, double domainRate, double modelRate,
                           const Params& rawParams) noexcept {
    const Params p = sanitizeParams(rawParams);
    ModelBandLimit filter;
    filter.design(domainRate, modelRate, p.cutoffHz, p.slope + 1, p.rippleDb);
    constexpr double kPi = 3.14159265358979323846;
    const double w = 2.0 * kPi * hz / domainRate;
    double db = 0.0;
    for (int i = 0; i < filter.activeSections_; ++i) {
      const Section& s = filter.sections_[static_cast<size_t>(i)];
      const double c1 = std::cos(w), s1 = std::sin(w), c2 = std::cos(2.0 * w), s2 = std::sin(2.0 * w);
      const double numRe = s.b0 + s.b1 * c1 + s.b2 * c2, numIm = -(s.b1 * s1 + s.b2 * s2);
      const double denRe = 1.0 + s.a1 * c1 + s.a2 * c2, denIm = -(s.a1 * s1 + s.a2 * s2);
      db += 10.0 * std::log10((numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm));
    }
    return db;
  }

 private:
  struct Section {
    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;
    double z1 = 0.0, z2 = 0.0;
  };

  static Params sanitizeParams(const Params& p) noexcept {
    return Params{
        clampCutoffHz(p.cutoffHz),
        clampSlope(static_cast<float>(p.slope)),
        clampRippleDb(p.rippleDb),
    };
  }

  void design(double domainRate, double modelRate, double cutoffHz,
              int sections, double rippleDb) noexcept {
    domainRate_ = domainRate;
    modelRate_ = modelRate;
    designedCutoffHz_ = cutoffHz;
    designedRippleDb_ = rippleDb;
    activeSections_ = std::clamp(sections, 1, kMaxSections);
    constexpr double kPi = 3.14159265358979323846;
    const int order = 2 * activeSections_;
    const double edge = std::min(cutoffHz, 0.45 * domainRate);
    const double k = std::tan(kPi * edge / domainRate);
    const double epsilon = std::sqrt(std::pow(10.0, rippleDb / 10.0) - 1.0);
    const double mu = std::asinh(1.0 / epsilon) / order;
    for (int i = 0; i < activeSections_; ++i) {
      const double theta = kPi * (2.0 * i + 1.0) / (2.0 * order);
      const double sigma = std::sinh(mu) * std::sin(theta);
      const double omega = std::cosh(mu) * std::cos(theta);
      const double w = k * k * (sigma * sigma + omega * omega);
      const double a0 = 1.0 + 2.0 * k * sigma + w;
      Section& s = sections_[static_cast<size_t>(i)];
      s.b0 = w / a0;
      s.b1 = 2.0 * w / a0;
      s.b2 = w / a0;
      s.a1 = 2.0 * (w - 1.0) / a0;
      s.a2 = (1.0 - 2.0 * k * sigma + w) / a0;
    }
    for (int i = activeSections_; i < kMaxSections; ++i) {
      sections_[static_cast<size_t>(i)] = Section{};
    }
  }

  std::array<Section, kMaxSections> sections_{};
  double domainRate_ = 0.0;
  double modelRate_ = 0.0;
  double designedCutoffHz_ = kDefaultCutoffHz;
  double designedRippleDb_ = kDefaultRippleDb;
  double smoothCutoffHz_ = kDefaultCutoffHz;
  double smoothRippleDb_ = kDefaultRippleDb;
  int activeSections_ = kDefaultSlope + 1;
  float mix_ = 0.0f;
};

}  // namespace NAMRig
