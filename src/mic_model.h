#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

#include "space_fx.h"

namespace NAMRig {

// Microphone distance and position after a cabinet IR. Distance pulls the
// capsule back from the grille: proximity bass falls (low shelf at 120 Hz),
// air rolls off (first-order lowpass from 20 kHz down to 9 kHz), the sound
// arrives later (0 to ~3 ms) and quieter (0 to -4 dB) with a small room
// high-shelf dip. Position slides the capsule from the dust cap to the cone
// edge: a high shelf at 3.5 kHz down to -9 dB, a dip around 1.6 kHz and a
// small low-mid lift at 250 Hz. All filters are RBJ biquads in double; the
// coefficients are rebuilt per 32-sample chunk only when a glided control
// moved. Both controls at zero (settled) is an exact bypass.
class MicModel {
 public:
  void initialize(double rate) {
    rate_ = rate > 0.0 ? rate : 48000.0;
    delay_.allocate(static_cast<size_t>(std::ceil(rate_ * 0.001 * kMaxDelayMs)) + 8);
    reset();
  }
  void reset() {
    delay_.clear();
    resetDistanceFilters();
    resetPositionFilters();
    smoothedDistance_ = smoothedPosition_ = 0.0f;
    appliedDistance_ = appliedPosition_ = -1.0f;
    cleared_ = true;
  }
  // Mono in place at the session rate, after a cabinet IR. distancePercent 0 AND positionPercent 0
  // (settled) is an EXACT bypass (bit-identical output).
  void process(float* samples, size_t count, float distancePercent, float positionPercent) {
    const float distanceTarget = unit(distancePercent);
    const float positionTarget = unit(positionPercent);
    if (distanceTarget <= 0.0f && positionTarget <= 0.0f &&
        smoothedDistance_ <= 0.0f && smoothedPosition_ <= 0.0f) {
      if (!cleared_) reset();
      return;
    }
    cleared_ = false;
    const float glide = static_cast<float>(1.0 - std::exp(-static_cast<double>(kChunk) / (rate_ * 0.020)));
    for (size_t start = 0; start < count; start += kChunk) {
      const size_t m = std::min(kChunk, count - start);
      glideValue(smoothedDistance_, distanceTarget, glide, 1.0e-4f);
      glideValue(smoothedPosition_, positionTarget, glide, 1.0e-4f);
      const double delayFrom = delaySamples_;
      const double levelFrom = level_;
      if (smoothedDistance_ != appliedDistance_) {
        if (smoothedDistance_ > 0.0f) {
          Coefficients c;
          computeDistance(c, smoothedDistance_, rate_);
          proximity_.set(c.proximity);
          room_.set(c.room);
          airCoeff_ = c.airCoeff;
          delaySamples_ = c.delaySamples;
          level_ = c.level;
        } else {
          resetDistanceFilters();
        }
        appliedDistance_ = smoothedDistance_;
      }
      if (smoothedPosition_ != appliedPosition_) {
        if (smoothedPosition_ > 0.0f) {
          Coefficients c;
          computePosition(c, smoothedPosition_, rate_);
          presence_.set(c.presence);
          dip_.set(c.dip);
          lift_.set(c.lift);
        } else {
          resetPositionFilters();
        }
        appliedPosition_ = smoothedPosition_;
      }
      const bool distanceOn = smoothedDistance_ > 0.0f;
      const bool positionOn = smoothedPosition_ > 0.0f;
      const double delayStep = (delaySamples_ - delayFrom) / static_cast<double>(m);
      const double levelStep = (level_ - levelFrom) / static_cast<double>(m);
      double delay = delayFrom, level = levelFrom;
      for (size_t i = start; i < start + m; ++i) {
        delay += delayStep;
        level += levelStep;
        double x = samples[i];
        delay_.write(samples[i]);
        if (distanceOn) {
          x = delay_.readFrac(delay);
          x = proximity_.process(x);
          air_ += (x - air_) * airCoeff_;
          x = room_.process(air_) * level;
        }
        if (positionOn) {
          x = presence_.process(x);
          x = dip_.process(x);
          x = lift_.process(x);
        }
        samples[i] = static_cast<float>(x);
      }
    }
  }
  // Magnitude response in dB at hz for the UI graph.
  static double responseDb(double hz, double rate, float distancePercent, float positionPercent) {
    if (!(rate > 0.0)) rate = 48000.0;
    if (!std::isfinite(hz)) hz = 1000.0;
    hz = std::max(1.0, std::min(0.5 * rate, hz));
    const float distance = unit(distancePercent);
    const float position = unit(positionPercent);
    const double w = 2.0 * kPi * hz / rate;
    double db = 0.0;
    if (distance > 0.0f) {
      Coefficients c;
      computeDistance(c, distance, rate);
      db += magnitudeDb(c.proximity, w) + magnitudeDb(c.room, w);
      // One-pole lowpass y += (x - y) * k: H = k / (1 - (1 - k) z^-1).
      const double re = 1.0 - (1.0 - c.airCoeff) * std::cos(w);
      const double im = (1.0 - c.airCoeff) * std::sin(w);
      db += 20.0 * std::log10(c.airCoeff / std::sqrt(re * re + im * im));
      db += 20.0 * std::log10(c.level);
    }
    if (position > 0.0f) {
      Coefficients c;
      computePosition(c, position, rate);
      db += magnitudeDb(c.presence, w) + magnitudeDb(c.dip, w) + magnitudeDb(c.lift, w);
    }
    return db;
  }

 private:
  static constexpr size_t kChunk = 32;
  static constexpr double kPi = 3.14159265358979323846;
  static constexpr double kMaxDelayMs = 3.5;

  struct Coeff {
    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;
  };
  struct Biquad {
    Coeff c;
    double z1 = 0.0, z2 = 0.0;
    void set(const Coeff& k) { c = k; }
    double process(double x) {
      const double y = c.b0 * x + z1;
      z1 = c.b1 * x - c.a1 * y + z2;
      z2 = c.b2 * x - c.a2 * y;
      return y;
    }
    void reset() { z1 = z2 = 0.0; }
  };
  struct Coefficients {
    Coeff proximity, room, presence, dip, lift;
    double airCoeff = 1.0, delaySamples = 0.0, level = 1.0;
  };

  static float unit(float percent) {
    if (!std::isfinite(percent)) return 0.0f;
    return std::max(0.0f, std::min(100.0f, percent)) * 0.01f;
  }
  static void glideValue(float& value, float target, float coeff, float snap) {
    value += (target - value) * coeff;
    if (std::fabs(target - value) < snap) value = target;
  }
  static double safeHz(double hz, double rate) { return std::min(hz, 0.45 * rate); }

  static void setLowShelf(Coeff& f, double hz, double gainDb, double slope, double rate) {
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w = 2.0 * kPi * safeHz(hz, rate) / rate;
    const double c = std::cos(w), s = std::sin(w);
    const double alpha = 0.5 * s * std::sqrt((A + 1.0 / A) * (1.0 / slope - 1.0) + 2.0);
    const double sqA = 2.0 * std::sqrt(A) * alpha;
    const double a0 = (A + 1.0) + (A - 1.0) * c + sqA;
    f.b0 = A * ((A + 1.0) - (A - 1.0) * c + sqA) / a0;
    f.b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * c) / a0;
    f.b2 = A * ((A + 1.0) - (A - 1.0) * c - sqA) / a0;
    f.a1 = -2.0 * ((A - 1.0) + (A + 1.0) * c) / a0;
    f.a2 = ((A + 1.0) + (A - 1.0) * c - sqA) / a0;
  }
  static void setHighShelf(Coeff& f, double hz, double gainDb, double slope, double rate) {
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w = 2.0 * kPi * safeHz(hz, rate) / rate;
    const double c = std::cos(w), s = std::sin(w);
    const double alpha = 0.5 * s * std::sqrt((A + 1.0 / A) * (1.0 / slope - 1.0) + 2.0);
    const double sqA = 2.0 * std::sqrt(A) * alpha;
    const double a0 = (A + 1.0) - (A - 1.0) * c + sqA;
    f.b0 = A * ((A + 1.0) + (A - 1.0) * c + sqA) / a0;
    f.b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * c) / a0;
    f.b2 = A * ((A + 1.0) + (A - 1.0) * c - sqA) / a0;
    f.a1 = 2.0 * ((A - 1.0) - (A + 1.0) * c) / a0;
    f.a2 = ((A + 1.0) - (A - 1.0) * c - sqA) / a0;
  }
  static void setPeaking(Coeff& f, double hz, double gainDb, double q, double rate) {
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w = 2.0 * kPi * safeHz(hz, rate) / rate;
    const double c = std::cos(w), s = std::sin(w);
    const double alpha = s / (2.0 * q);
    const double a0 = 1.0 + alpha / A;
    f.b0 = (1.0 + alpha * A) / a0;
    f.b1 = -2.0 * c / a0;
    f.b2 = (1.0 - alpha * A) / a0;
    f.a1 = -2.0 * c / a0;
    f.a2 = (1.0 - alpha / A) / a0;
  }
  static double magnitudeDb(const Coeff& f, double w) {
    const double c1 = std::cos(w), s1 = std::sin(w);
    const double c2 = std::cos(2.0 * w), s2 = std::sin(2.0 * w);
    const double nr = f.b0 + f.b1 * c1 + f.b2 * c2;
    const double ni = -(f.b1 * s1 + f.b2 * s2);
    const double dr = 1.0 + f.a1 * c1 + f.a2 * c2;
    const double di = -(f.a1 * s1 + f.a2 * s2);
    return 10.0 * std::log10(std::max(1.0e-30, (nr * nr + ni * ni) / (dr * dr + di * di)));
  }

  static void computeDistance(Coefficients& c, float distance, double rate) {
    const double d = distance;
    setLowShelf(c.proximity, 120.0, -5.0 * d, 1.5, rate);
    setHighShelf(c.room, 6000.0, -1.5 * d, 1.0, rate);
    const double airHz = safeHz(20000.0 * std::pow(9000.0 / 20000.0, d), rate);
    c.airCoeff = 1.0 - std::exp(-2.0 * kPi * airHz / rate);
    c.delaySamples = 3.0 * d * 0.001 * rate;
    c.level = std::pow(10.0, -4.0 * d / 20.0);
  }
  static void computePosition(Coefficients& c, float position, double rate) {
    const double p = position;
    setHighShelf(c.presence, 3500.0, -9.0 * p, 1.5, rate);
    setPeaking(c.dip, 1600.0, -3.0 * p, 2.0, rate);
    setPeaking(c.lift, 250.0, 1.5 * p, 1.0, rate);
  }
  void resetDistanceFilters() {
    proximity_.reset();
    room_.reset();
    air_ = 0.0;
    delaySamples_ = 0.0;
    level_ = 1.0;
  }
  void resetPositionFilters() {
    presence_.reset();
    dip_.reset();
    lift_.reset();
  }

  double rate_ = 48000.0;
  DelayLine delay_;
  Biquad proximity_, room_, presence_, dip_, lift_;
  double air_ = 0.0, airCoeff_ = 1.0;
  double delaySamples_ = 0.0, level_ = 1.0;
  float smoothedDistance_ = 0.0f, smoothedPosition_ = 0.0f;
  float appliedDistance_ = -1.0f, appliedPosition_ = -1.0f;
  bool cleared_ = true;
};

}  // namespace NAMRig
