#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace NAMRig {

// Optional post-capture amp shaping. Every control has a neutral value and
// both entry points return without touching samples when all controls are
// neutral, preserving the captured model and the established post-chain EQ.
class AmpAdvanced {
 public:
  void reset() noexcept {
    bright_.reset();
    inputEq_.reset();
    depth_.reset();
    presence_.reset();
    feedbackState_ = 0.0f;
    sagEnvelope_ = 0.0f;
  }

  void processPreAmp(float* samples, size_t count, double rate,
                     float brightAmount, float inputEqAmount) noexcept {
    const float bright = clamp01(brightAmount * 0.01f);
    const float inputEq = clamp01(inputEqAmount * 0.01f);
    if (bright <= 0.0001f && inputEq <= 0.0001f) {
      bright_.reset();
      inputEq_.reset();
      return;
    }
    if (inputEq > 0.0001f)
      setHighPass(inputEq_, 20.0f + 160.0f * inputEq, rate);
    else
      inputEq_.reset();
    if (bright > 0.0001f)
      setHighShelf(bright_, 6.0f * bright, 2200.0f, rate);
    else
      bright_.reset();
    for (size_t i = 0; i < count; ++i) {
      float x = samples[i];
      if (inputEq > 0.0001f) x = inputEq_.process(x);
      if (bright > 0.0001f) x = bright_.process(x);
      samples[i] = x;
    }
  }

  void processPostAmp(float* samples, size_t count, double rate,
                      float presenceDb, float depthDb, float sagAmount,
                      float biasAmount, float feedbackAmount,
                      float masterAmount) noexcept {
    const float sag = clamp01(sagAmount * 0.01f);
    const float bias = std::max(-1.0f, std::min(1.0f, biasAmount * 0.01f));
    const float feedback = clamp01(feedbackAmount * 0.01f);
    const float master = clamp01(masterAmount * 0.01f);
    const bool presenceOn = std::fabs(presenceDb) > 0.0001f;
    const bool depthOn = std::fabs(depthDb) > 0.0001f;
    const bool dynamicsOn = sag > 0.0001f || std::fabs(bias) > 0.0001f ||
                            feedback > 0.0001f || master > 0.0001f;
    if (!presenceOn && !depthOn && !dynamicsOn) {
      presence_.reset();
      depth_.reset();
      feedbackState_ = 0.0f;
      sagEnvelope_ = 0.0f;
      return;
    }

    if (depthOn) setLowShelf(depth_, depthDb, 110.0f, rate);
    else depth_.reset();
    if (presenceOn) setHighShelf(presence_, presenceDb, 3200.0f, rate);
    else presence_.reset();

    const float sagAttack = 1.0f - std::exp(-1.0f / static_cast<float>(rate * 0.015));
    const float sagRelease = 1.0f - std::exp(-1.0f / static_cast<float>(rate * 0.220));
    const float feedbackCoeff = 1.0f - std::exp(-1.0f / static_cast<float>(rate * 0.004));
    const float drive = 1.0f + 7.0f * master;
    const float driveNorm = dynamicsOn ? 1.0f / std::tanh(drive) : 1.0f;

    for (size_t i = 0; i < count; ++i) {
      float x = samples[i];
      if (feedback > 0.0001f) {
        feedbackState_ += (x - feedbackState_) * feedbackCoeff;
        x -= feedback * 0.35f * feedbackState_;
      }
      if (master > 0.0001f || std::fabs(bias) > 0.0001f) {
        const float shifted = x * drive + 0.45f * bias;
        const float zero = std::tanh(0.45f * bias);
        x = (std::tanh(shifted) - zero) * driveNorm;
      }
      if (sag > 0.0001f) {
        const float level = std::fabs(x);
        sagEnvelope_ += (level - sagEnvelope_) *
            (level > sagEnvelope_ ? sagAttack : sagRelease);
        x *= 1.0f / (1.0f + sag * 1.8f * sagEnvelope_);
      }
      if (depthOn) x = depth_.process(x);
      if (presenceOn) x = presence_.process(x);
      samples[i] = x;
    }
  }

 private:
  struct Filter {
    float b0 = 0.0f, b1 = 0.0f, b2 = 0.0f, a1 = 0.0f, a2 = 0.0f;
    float z1 = 0.0f, z2 = 0.0f;
    float process(float x) noexcept {
      const float y = b0 * x + z1;
      z1 = b1 * x - a1 * y + z2;
      z2 = b2 * x - a2 * y;
      return y;
    }
    void reset() noexcept { z1 = z2 = 0.0f; }
  };

  static constexpr double kPi = 3.14159265358979323846;
  static constexpr float kQ = 0.7071067811865476f;
  static float clamp01(float x) noexcept { return std::max(0.0f, std::min(1.0f, x)); }

  static void setHighPass(Filter& f, float frequency, double rate) noexcept {
    const double w0 = 2.0 * kPi * frequency / rate;
    const double c = std::cos(w0), s = std::sin(w0);
    const double alpha = s / (2.0 * kQ), a0 = 1.0 + alpha;
    f.b0 = static_cast<float>((1.0 + c) * 0.5 / a0);
    f.b1 = static_cast<float>(-(1.0 + c) / a0);
    f.b2 = f.b0;
    f.a1 = static_cast<float>(-2.0 * c / a0);
    f.a2 = static_cast<float>((1.0 - alpha) / a0);
  }

  static void setLowShelf(Filter& f, float gainDb, float frequency,
                          double rate) noexcept {
    setShelf(f, gainDb, frequency, rate, false);
  }
  static void setHighShelf(Filter& f, float gainDb, float frequency,
                           double rate) noexcept {
    setShelf(f, gainDb, frequency, rate, true);
  }
  static void setShelf(Filter& f, float gainDb, float frequency, double rate,
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
    f.b0 = static_cast<float>(b0 / a0);
    f.b1 = static_cast<float>(b1 / a0);
    f.b2 = static_cast<float>(b2 / a0);
    f.a1 = static_cast<float>(a1 / a0);
    f.a2 = static_cast<float>(a2 / a0);
  }

  Filter bright_, inputEq_, depth_, presence_;
  float feedbackState_ = 0.0f;
  float sagEnvelope_ = 0.0f;
};

}  // namespace NAMRig
