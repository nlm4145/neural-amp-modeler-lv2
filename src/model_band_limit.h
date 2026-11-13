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
// 8th-order Chebyshev type I, 0.05 dB ripple, passband edge at 0.427 of the
// model rate (20.5 kHz for a 48 kHz model), 32 dB down at 0.58 of the model
// rate and 56 dB down at 0.75.
//
// The on/off control fades over 5 ms. The filter is skipped when it is off
// and when the domain rate does not exceed the model rate.
class ModelBandLimit {
 public:
  static constexpr double kPassbandOfModelRate = 0.427;
  static constexpr double kRippleDb = 0.05;

  void reset() noexcept {
    for (Section& s : sections_) s.z1 = s.z2 = 0.0;
    mix_ = 0.0f;
  }

  static bool applies(double domainRate, double modelRate) noexcept {
    return modelRate > 0.0 && domainRate > modelRate * 1.01;
  }

  void process(float* samples, size_t count, double domainRate, double modelRate,
               bool enabled) noexcept {
    const bool wanted = enabled && applies(domainRate, modelRate);
    if (!wanted && mix_ <= 0.0f) return;
    if (domainRate != domainRate_ || modelRate != modelRate_) {
      design(domainRate, modelRate);
      for (Section& s : sections_) s.z1 = s.z2 = 0.0;
    }
    const float target = wanted ? 1.0f : 0.0f;
    const float step = static_cast<float>(1.0 / (domainRate * 0.005));
    for (size_t i = 0; i < count; ++i) {
      double y = samples[i];
      for (Section& s : sections_) {
        const double out = s.b0 * y + s.z1;
        s.z1 = s.b1 * y - s.a1 * out + s.z2;
        s.z2 = s.b2 * y - s.a2 * out;
        y = out;
      }
      if (mix_ < target) mix_ = std::min(target, mix_ + step);
      else if (mix_ > target) mix_ = std::max(target, mix_ - step);
      samples[i] += mix_ * (static_cast<float>(y) - samples[i]);
    }
    if (!wanted && mix_ <= 0.0f) reset();
  }

  // Magnitude response in dB of the filter for this domain and model rate.
  static double responseDb(double hz, double domainRate, double modelRate) noexcept {
    ModelBandLimit filter;
    filter.design(domainRate, modelRate);
    constexpr double kPi = 3.14159265358979323846;
    const double w = 2.0 * kPi * hz / domainRate;
    double db = 0.0;
    for (const Section& s : filter.sections_) {
      const double c1 = std::cos(w), s1 = std::sin(w), c2 = std::cos(2.0 * w), s2 = std::sin(2.0 * w);
      const double numRe = s.b0 + s.b1 * c1 + s.b2 * c2, numIm = -(s.b1 * s1 + s.b2 * s2);
      const double denRe = 1.0 + s.a1 * c1 + s.a2 * c2, denIm = -(s.a1 * s1 + s.a2 * s2);
      db += 10.0 * std::log10((numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm));
    }
    return db;
  }

 private:
  static constexpr int kSections = 4;

  struct Section {
    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;
    double z1 = 0.0, z2 = 0.0;
  };

  void design(double domainRate, double modelRate) noexcept {
    domainRate_ = domainRate;
    modelRate_ = modelRate;
    constexpr double kPi = 3.14159265358979323846;
    constexpr int order = 2 * kSections;
    const double edge = std::min(kPassbandOfModelRate * modelRate, 0.45 * domainRate);
    const double k = std::tan(kPi * edge / domainRate);
    const double epsilon = std::sqrt(std::pow(10.0, kRippleDb / 10.0) - 1.0);
    const double mu = std::asinh(1.0 / epsilon) / order;
    for (int i = 0; i < kSections; ++i) {
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
  }

  std::array<Section, kSections> sections_{};
  double domainRate_ = 0.0;
  double modelRate_ = 0.0;
  float mix_ = 0.0f;
};

}  // namespace NAMRig
