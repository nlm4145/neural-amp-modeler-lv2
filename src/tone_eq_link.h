#pragma once

#include "pin_eq.h"

namespace NAMRig {
using ToneKnobGains = std::array<float, 3>;
using ToneLeverGains = std::array<float, kToneEqBandCount>;

inline PinCoeffs toneKnobCoefficients(size_t band, double gain) {
  constexpr int shapes[] = {kPinLowShelf, kPinBell, kPinHighShelf};
  constexpr double hz[] = {150, 700, 3000};
  return pinCoefficients(shapes[band], hz[band], gain, 0.7071067811865476, 48000);
}
inline PinCoeffs toneLeverCoefficients(size_t band, double gain) {
  return pinCoefficients(kPinBell, kToneEqFreqDefaults[band], gain, kPinQDefault, 48000);
}

// Least-squares projection of the complete response, rather than copying knob
// numbers into arbitrary fader groups. Only the displayed approximation changes;
// the last edited controls remain the audio source when the view is switched.
template <size_t TargetCount, size_t SourceCount, typename TargetFilter, typename SourceFilter>
inline std::array<float, TargetCount> fitToneEq(
    const std::array<float, SourceCount>& gains, TargetFilter targetFilter,
    SourceFilter sourceFilter, double limit) {
  std::array<PinCoeffs, SourceCount> source;
  for (size_t i = 0; i < SourceCount; ++i) source[i] = sourceFilter(i, gains[i]);
  std::array<PinCoeffs, TargetCount> basis;
  for (size_t i = 0; i < TargetCount; ++i) basis[i] = targetFilter(i, 1.0);
  double system[TargetCount][TargetCount + 1] = {};
  for (size_t sample = 0; sample < 40; ++sample) {
    const double hz = 30 * std::pow(600., sample / 39.);
    double desired = 0;
    for (const auto& filter : source) desired += pinMagnitudeDb(filter, hz, 48000);
    double weights[TargetCount];
    for (size_t i = 0; i < TargetCount; ++i) weights[i] = pinMagnitudeDb(basis[i], hz, 48000);
    for (size_t i = 0; i < TargetCount; ++i) {
      system[i][TargetCount] += weights[i] * desired;
      for (size_t j = 0; j < TargetCount; ++j) system[i][j] += weights[i] * weights[j];
    }
  }
  for (size_t i = 0; i < TargetCount; ++i) system[i][i] += 0.001;
  for (size_t col = 0; col < TargetCount; ++col) {
    size_t pivot = col;
    for (size_t row = col + 1; row < TargetCount; ++row)
      if (std::abs(system[row][col]) > std::abs(system[pivot][col])) pivot = row;
    for (size_t j = 0; j <= TargetCount; ++j) std::swap(system[col][j], system[pivot][j]);
    const double divisor = system[col][col];
    for (size_t j = col; j <= TargetCount; ++j) system[col][j] /= divisor;
    for (size_t row = 0; row < TargetCount; ++row) {
      if (row == col) continue;
      const double factor = system[row][col];
      for (size_t j = col; j <= TargetCount; ++j) system[row][j] -= factor * system[col][j];
    }
  }
  std::array<float, TargetCount> result;
  for (size_t i = 0; i < TargetCount; ++i)
    result[i] = static_cast<float>(std::clamp(system[i][TargetCount], -limit, limit));
  return result;
}
inline ToneLeverGains toneLeversFromKnobs(const ToneKnobGains& knobs) {
  return fitToneEq<kToneEqBandCount>(knobs, toneLeverCoefficients, toneKnobCoefficients, kPinGainMax);
}
inline ToneKnobGains toneKnobsFromLevers(const ToneLeverGains& levers) {
  return fitToneEq<3>(levers, toneKnobCoefficients, toneLeverCoefficients, 12);
}
} // namespace NAMRig
