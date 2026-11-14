#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <string>

#include "power_tube_controls.h"

namespace NAMRig {

// Freeform "pin" EQ placed directly on the Sculpt, Transformer, Cab Console
// and Speaker graphs. Each pane owns kPinEqBandCount bands; every band is four appended
// control ports (shape, frequency, gain, Q), so pins automate and recall with
// presets like any other control. Shape 0 means "no pin"; a band without a pin
// or at 0 dB is skipped entirely, so the default state is exact bypass.
//
//   Sculpt      - pre-amp, after Bright/Input EQ/Mid Push, in the amp's True domain
//   Transformer - after the output transformer, before the speaker, in the domain
//   Cab Console - after the cab cuts on the stereo cabinet mix, at session rate
//   Speaker     - after the speaker load/excursion, before the cab, in the domain
// Panes are appended in port order (Speaker came last), not signal order.
enum class PinEqPane : size_t { Sculpt = 0, Transformer = 1, CabConsole = 2, Speaker = 3 };
inline constexpr size_t kPinEqPaneCount = 4;
inline constexpr size_t kPinEqBandCount = 6;
inline constexpr size_t kPinEqBandParams = 4;
inline constexpr size_t kPinEqPanePorts = kPinEqBandCount * kPinEqBandParams;
static_assert(kPinEqPortCount == kPinEqPaneCount * kPinEqPanePorts);

enum PinEqParam : size_t { kPinShape = 0, kPinFreq = 1, kPinGain = 2, kPinQ = 3 };
enum PinEqShape : int { kPinOff = 0, kPinBell = 1, kPinLowShelf = 2, kPinHighShelf = 3 };
inline constexpr int kPinShapeCount = 4;

inline constexpr float kPinFreqMin = 20.0f;
inline constexpr float kPinFreqMax = 20000.0f;
inline constexpr float kPinGainMax = 18.0f;
inline constexpr float kPinQMin = 0.1f;
inline constexpr float kPinQMax = 10.0f;
inline constexpr float kPinQDefault = 1.0f;
inline constexpr std::array<float, kPinEqBandCount> kPinFreqDefaults = {
    100.0f, 250.0f, 600.0f, 1500.0f, 3500.0f, 8000.0f};
inline constexpr std::array<const char*, kPinEqPaneCount> kPinEqPaneSymbols = {
    "sculpt", "transformer", "cab_console", "speaker"};
inline constexpr std::array<const char*, kPinEqBandParams> kPinEqParamSymbols = {
    "shape", "freq", "gain", "q"};

constexpr uint32_t pinEqPort(PinEqPane pane, size_t band, size_t param) noexcept {
  return kPinEqFirstPort + static_cast<uint32_t>(
      (static_cast<size_t>(pane) * kPinEqBandCount + band) * kPinEqBandParams + param);
}
constexpr bool isPinEqPort(uint32_t port) noexcept {
  return port >= kPinEqFirstPort && port < kPinEqFirstPort + kPinEqPortCount;
}
constexpr size_t pinEqParamOf(uint32_t port) noexcept {
  return (port - kPinEqFirstPort) % kPinEqBandParams;
}
constexpr size_t pinEqBandOf(uint32_t port) noexcept {
  return ((port - kPinEqFirstPort) / kPinEqBandParams) % kPinEqBandCount;
}
constexpr size_t pinEqPaneOf(uint32_t port) noexcept {
  return (port - kPinEqFirstPort) / kPinEqPanePorts;
}

constexpr float pinEqDefault(uint32_t port) noexcept {
  switch (pinEqParamOf(port)) {
    case kPinFreq: return kPinFreqDefaults[pinEqBandOf(port)];
    case kPinQ: return kPinQDefault;
    default: return 0.0f;
  }
}

constexpr std::array<float, kPinEqPortCount> pinEqDefaults() noexcept {
  std::array<float, kPinEqPortCount> out{};
  for (uint32_t i = 0; i < kPinEqPortCount; ++i) out[i] = pinEqDefault(kPinEqFirstPort + i);
  return out;
}

inline float clampPinEqValue(uint32_t port, float value) noexcept {
  if (!std::isfinite(value)) return pinEqDefault(port);
  switch (pinEqParamOf(port)) {
    case kPinShape:
      return static_cast<float>(std::clamp(static_cast<int>(value + 0.5f), 0, kPinShapeCount - 1));
    case kPinFreq: return std::clamp(value, kPinFreqMin, kPinFreqMax);
    case kPinGain: return std::clamp(value, -kPinGainMax, kPinGainMax);
    default: return std::clamp(value, kPinQMin, kPinQMax);
  }
}

// LV2 symbol, e.g. "sculpt_pin3_freq".
inline std::string pinEqSymbol(uint32_t port) {
  return std::string(kPinEqPaneSymbols[pinEqPaneOf(port)]) + "_pin" +
         std::to_string(pinEqBandOf(port) + 1) + "_" + kPinEqParamSymbols[pinEqParamOf(port)];
}

struct PinBand {
  int shape = kPinOff;
  double freq = 1000.0, gainDb = 0.0, q = kPinQDefault;
};
using PinBands = std::array<PinBand, kPinEqBandCount>;

// Reads one pane's bands from its 24 consecutive values (ports or UI state).
template <typename Get>
inline PinBands readPinBands(PinEqPane pane, Get&& get) {
  PinBands bands;
  for (size_t b = 0; b < kPinEqBandCount; ++b) {
    const auto value = [&](size_t param) {
      const uint32_t port = pinEqPort(pane, b, param);
      return clampPinEqValue(port, get(port));
    };
    bands[b].shape = static_cast<int>(value(kPinShape));
    bands[b].freq = value(kPinFreq);
    bands[b].gainDb = value(kPinGain);
    bands[b].q = value(kPinQ);
  }
  return bands;
}

// Tone EQ owns seven bands on independent, append-only ports.
inline constexpr size_t kToneEqBandCount = 7;
using ToneEqBands = std::array<PinBand, kToneEqBandCount>;
inline constexpr std::array<float, kToneEqBandCount> kToneEqFreqDefaults = {
    40.0f, 80.0f, 240.0f, 750.0f, 2200.0f, 6600.0f, 12000.0f};
static_assert(kToneEqControlCount == 1 + kToneEqBandCount * kPinEqBandParams);
inline uint32_t toneEqPort(size_t band, size_t param) {
  return kToneEqFirstPort + static_cast<uint32_t>(band * kPinEqBandParams + param);
}
inline float toneEqDefault(uint32_t port) {
  if (port == kToneEqModePort) return 0.0f;
  const size_t index = port - kToneEqFirstPort;
  switch (index % kPinEqBandParams) {
    case kPinFreq: return kToneEqFreqDefaults[index / kPinEqBandParams];
    case kPinQ: return kPinQDefault;
    case kPinShape: return kPinBell;
    default: return 0.0f;
  }
}
inline float clampToneEqValue(uint32_t port, float value) {
  if (port == kToneEqModePort) return std::isfinite(value) && value >= 0.5f ? 1.0f : 0.0f;
  if ((port - kToneEqFirstPort) % kPinEqBandParams != kPinGain || !std::isfinite(value))
    return toneEqDefault(port);
  // Clamp by parameter type; no dependency on the six-band pane layout.
  return clampPinEqValue(kPinEqFirstPort + (port - kToneEqFirstPort) % kPinEqBandParams, value);
}
inline std::array<float, kToneEqControlCount> toneEqDefaults() {
  std::array<float, kToneEqControlCount> values{};
  for (uint32_t i = 0; i < values.size(); ++i) values[i] = toneEqDefault(kToneEqModePort + i);
  return values;
}
template <typename Get>
inline ToneEqBands readToneEqBands(Get&& get) {
  ToneEqBands bands;
  for (size_t b = 0; b < bands.size(); ++b) {
    auto value = [&](size_t param) {
      const auto port = toneEqPort(b, param);
      return clampToneEqValue(port, get(port));
    };
    bands[b] = {static_cast<int>(value(kPinShape)), value(kPinFreq), value(kPinGain), value(kPinQ)};
  }
  return bands;
}

struct PinCoeffs {
  double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;
};

inline constexpr double kButterworthQ = 0.70710678118654752440;
inline constexpr int kCabCutSlope12 = 0;
inline constexpr int kCabCutSlope18 = 1;
inline constexpr int kCabCutSlope24 = 2;

inline int clampCabCutSlope(float value) noexcept {
  if (!std::isfinite(value)) return kCabCutSlope12;
  return std::clamp(static_cast<int>(std::lround(value)), kCabCutSlope12, kCabCutSlope24);
}

struct PinPassChain {
  size_t count = 1;
  std::array<PinCoeffs, 2> stages{};
};

namespace detail {
inline constexpr double kPinPi = 3.14159265358979323846;

inline PinCoeffs rbjBellOrShelf(int shape, double w0, double A, double q) noexcept {
  const double c = std::cos(w0), s = std::sin(w0);
  const double alpha = s / (2.0 * std::max(0.01, q));
  double b0, b1, b2, a0, a1, a2;
  if (shape == kPinBell) {
    b0 = 1.0 + alpha * A;
    b1 = -2.0 * c;
    b2 = 1.0 - alpha * A;
    a0 = 1.0 + alpha / A;
    a1 = -2.0 * c;
    a2 = 1.0 - alpha / A;
  } else {
    const double sqA = 2.0 * std::sqrt(A) * alpha;
    if (shape == kPinHighShelf) {
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
  }
  PinCoeffs f;
  f.b0 = b0 / a0;
  f.b1 = b1 / a0;
  f.b2 = b2 / a0;
  f.a1 = a1 / a0;
  f.a2 = a2 / a0;
  return f;
}

inline PinCoeffs rbjPass(bool highPass, double w0, double q) noexcept {
  const double c = std::cos(w0);
  const double alpha = std::sin(w0) / (2.0 * std::max(0.01, q));
  const double a0 = 1.0 + alpha;
  PinCoeffs f;
  f.b0 = (highPass ? (1.0 + c) : (1.0 - c)) * 0.5 / a0;
  f.b1 = (highPass ? -(1.0 + c) : (1.0 - c)) / a0;
  f.b2 = f.b0;
  f.a1 = -2.0 * c / a0;
  f.a2 = (1.0 - alpha) / a0;
  return f;
}

// Orfanidis Nyquist-prescribed quadratic solver in tan(w/2)^2 for Bell and Shelf.
inline bool solveOrfanidisQuad(double u1, double u2, double W2,
                               double G02, double G12,
                               double T1, double T2,
                               PinCoeffs& out) noexcept {
  if (!(u1 > 0.0 && u2 > 0.0 && std::abs(T1 - T2) > 1.0e-12)) return false;
  const double rhs1 = T1 * (u1 + W2 * W2 / u1) - (G12 * u1 + G02 * W2 * W2 / u1);
  const double rhs2 = T2 * (u2 + W2 * W2 / u2) - (G12 * u2 + G02 * W2 * W2 / u2);
  const double Y = (rhs2 - rhs1) / (T1 - T2);
  const double X = rhs1 + T1 * Y;
  const double alpha2 = Y + 2.0 * W2;
  const double beta2 = X + 2.0 * std::sqrt(G02 * G12) * W2;
  if (!(alpha2 > 1.0e-18 && beta2 > 1.0e-18 &&
        std::isfinite(alpha2) && std::isfinite(beta2)))
    return false;
  const double alpha = std::sqrt(alpha2);
  const double beta = std::sqrt(beta2);
  const double g0 = std::sqrt(G02);
  const double g1 = std::sqrt(G12);
  const double a0 = 1.0 + alpha + W2;
  out.b0 = (g1 + beta + g0 * W2) / a0;
  out.b1 = 2.0 * (g0 * W2 - g1) / a0;
  out.b2 = (g1 - beta + g0 * W2) / a0;
  out.a1 = 2.0 * (W2 - 1.0) / a0;
  out.a2 = (1.0 - alpha + W2) / a0;
  return true;
}

inline void vicanekPoles(double w0, double q,
                         double& a1, double& a2,
                         double& A0, double& A1, double& A2) noexcept {
  a2 = std::exp(-w0 / q);
  const double d = 1.0 - 1.0 / (4.0 * q * q);
  if (d >= 0.0) {
    a1 = -2.0 * std::exp(-w0 / (2.0 * q)) * std::cos(w0 * std::sqrt(d));
  } else {
    a1 = -2.0 * std::exp(-w0 / (2.0 * q)) * std::cosh(w0 * std::sqrt(-d));
  }
  A0 = (1.0 + a1 + a2) * (1.0 + a1 + a2);
  A1 = (1.0 - a1 + a2) * (1.0 - a1 + a2);
  A2 = -4.0 * a2;
}
} // namespace detail

// Nyquist-un-cramped matched bell / shelves (Orfanidis Nyquist-prescribed
// magnitude response; falls back smoothly to double RBJ when w0 < 0.05 or high-Q
// shelf roots cross into RBJ domain). Q sets the shelf slope (0.707 = Butterworth).
inline PinCoeffs pinCoefficients(int shape, double freq, double gainDb, double q,
                                 double rate) noexcept {
  PinCoeffs f;
  if (shape == kPinOff || rate <= 0.0 || std::abs(gainDb) < 1.0e-12) return f;
  freq = std::clamp(freq, 1.0, rate * 0.45);
  q = std::max(0.01, q);
  const double A = std::pow(10.0, gainDb / 40.0);
  const double w0 = 2.0 * detail::kPinPi * freq / rate;
  if (w0 < 0.05) return detail::rbjBellOrShelf(shape, w0, A, q);

  const double t0 = std::tan(0.5 * w0);
  const double uNyq = detail::kPinPi / w0;
  if (shape == kPinBell) {
    const double G = A * A;
    const double dw = 1.0 / q;
    const double nyqDiff = uNyq * uNyq - 1.0;
    const double nyqTerm = nyqDiff * nyqDiff;
    const double dwNyq2 = (dw * uNyq) * (dw * uNyq);
    const double G12 = (nyqTerm + (G * G) * dwNyq2) / (nyqTerm + dwNyq2);
    const double gm2 = G * G;
    const double gb2 = G;
    const double W2 = t0 * t0 * std::sqrt(std::abs(gm2 - G12) / std::abs(gm2 - 1.0));
    const double bwHalf = 0.5 / q;
    const double wLo = w0 * (std::sqrt(1.0 + bwHalf * bwHalf) - bwHalf);
    const double ta = std::tan(0.5 * wLo);
    if (detail::solveOrfanidisQuad(t0 * t0, ta * ta, W2, 1.0, G12, gm2, gb2, f))
      return f;
    return detail::rbjBellOrShelf(shape, w0, A, q);
  }

  const bool highShelf = (shape == kPinHighShelf);
  const double G02 = highShelf ? 1.0 : (A * A * A * A);
  auto analogShelfMagSq = [&](double u) {
    const double u2 = u * u;
    const double sqAQ2 = A / (q * q);
    const double nRe = highShelf ? (1.0 - A * u2) : (A - u2);
    const double dRe = highShelf ? (A - u2) : (1.0 - A * u2);
    return (A * A) * (nRe * nRe + sqAQ2 * u2) / (dRe * dRe + sqAQ2 * u2);
  };
  const double G12 = analogShelfMagSq(uNyq);
  const double gm2 = A * A;
  const double W2 = t0 * t0 * std::sqrt(std::abs(G12 - gm2) / std::abs(gm2 - G02));
  const double wA = highShelf ? (0.65 * w0) : std::min(0.85 * detail::kPinPi, 1.5 * w0);
  const double ta = std::tan(0.5 * wA);
  const double Ta = analogShelfMagSq(wA / w0);
  if (detail::solveOrfanidisQuad(t0 * t0, ta * ta, W2, G02, G12, gm2, Ta, f))
    return f;
  return detail::rbjBellOrShelf(shape, w0, A, q);
}

// Vicanek matched 2nd-order high/low pass (eliminates 48 kHz Nyquist cramping).
inline PinCoeffs pinPassCoefficients(bool highPass, double freq, double rate,
                                     double q = kButterworthQ) noexcept {
  if (rate <= 0.0) return {};
  freq = std::clamp(freq, 1.0, rate * 0.45);
  q = std::max(0.01, q);
  const double w0 = 2.0 * detail::kPinPi * freq / rate;
  if (w0 < 0.05) return detail::rbjPass(highPass, w0, q);

  double a1 = 0.0, a2 = 0.0, A0 = 0.0, A1 = 0.0, A2 = 0.0;
  detail::vicanekPoles(w0, q, a1, a2, A0, A1, A2);
  PinCoeffs f;
  f.a1 = a1;
  f.a2 = a2;
  if (highPass) {
    const double s = std::sin(0.5 * w0);
    const double s2 = s * s;
    const double p0 = 1.0 - s2;
    const double p2 = 4.0 * p0 * s2;
    const double den = A0 * p0 + A1 * s2 + A2 * p2;
    const double g = std::sqrt(q * q * den) / (4.0 * s2);
    f.b0 = g;
    f.b1 = -2.0 * g;
    f.b2 = g;
    return f;
  }

  auto analogLpSq = [&](double w) {
    const double u = w / w0;
    const double u2 = u * u;
    const double t = 1.0 - u2;
    return 1.0 / (t * t + u2 / (q * q));
  };
  const double w1 = 0.5 * w0, w2 = w0;
  const double s1 = std::sin(0.5 * w1) * std::sin(0.5 * w1);
  const double p01 = 1.0 - s1, p21 = 4.0 * p01 * s1;
  const double s2 = std::sin(0.5 * w2) * std::sin(0.5 * w2);
  const double p02 = 1.0 - s2, p22 = 4.0 * p02 * s2;
  const double B0 = A0;
  const double r1 = analogLpSq(w1) * (A0 * p01 + A1 * s1 + A2 * p21) - B0 * p01;
  const double r2 = analogLpSq(w2) * (A0 * p02 + A1 * s2 + A2 * p22) - B0 * p02;
  const double det = s1 * p22 - s2 * p21;
  if (std::abs(det) < 1.0e-18) return detail::rbjPass(false, w0, q);
  const double B1 = std::max(0.0, (r1 * p22 - r2 * p21) / det);
  const double B2 = (s1 * r2 - s2 * r1) / det;
  const double sq0 = std::sqrt(B0), sq1 = std::sqrt(B1);
  const double W = 0.5 * (sq0 + sq1);
  const double disc = std::max(0.0, W * W + B2);
  const double root = std::sqrt(disc);
  f.b0 = 0.5 * (W + root);
  f.b1 = 0.5 * (sq0 - sq1);
  f.b2 = 0.5 * (W - root);
  return f;
}

// Matched 1st-order high/low pass (used by 18 dB/oct Butterworth slope).
inline PinCoeffs pinPassFirstOrder(bool highPass, double freq, double rate) noexcept {
  if (rate <= 0.0) return {};
  freq = std::clamp(freq, 1.0, rate * 0.45);
  const double w0 = 2.0 * detail::kPinPi * freq / rate;
  PinCoeffs f;
  if (w0 < 0.05) {
    const double W = std::tan(0.5 * w0);
    const double inv = 1.0 / (1.0 + W);
    f.b0 = (highPass ? 1.0 : W) * inv;
    f.b1 = (highPass ? -1.0 : W) * inv;
    f.a1 = (W - 1.0) * inv;
    return f;
  }
  if (highPass) {
    const double a1 = -std::exp(-w0);
    const double c = std::cos(w0), s = std::sin(w0);
    const double den = std::hypot(1.0 + a1 * c, -a1 * s);
    const double num = std::hypot(1.0 - c, s);
    const double b0 = 0.70710678118654752440 * den / num;
    f.b0 = b0;
    f.b1 = -b0;
    f.a1 = a1;
    return f;
  }
  const double uNyq = detail::kPinPi / w0;
  const double G1 = 1.0 / std::sqrt(1.0 + uNyq * uNyq);
  const double W = std::tan(0.5 * w0) * std::sqrt(std::max(0.0, 1.0 - 2.0 * G1 * G1));
  const double inv = 1.0 / (1.0 + W);
  f.b0 = (W + G1) * inv;
  f.b1 = (W - G1) * inv;
  f.a1 = (W - 1.0) * inv;
  return f;
}

// Butterworth cut filter chain: 0 = 12 dB/oct, 1 = 18 dB/oct, 2 = 24 dB/oct.
inline PinPassChain pinPassStages(bool highPass, double freq, int slopeIndex,
                                  double rate) noexcept {
  PinPassChain chain;
  const int slope = std::clamp(slopeIndex, kCabCutSlope12, kCabCutSlope24);
  if (slope == kCabCutSlope12) {
    chain.count = 1;
    chain.stages[0] = pinPassCoefficients(highPass, freq, rate, kButterworthQ);
  } else if (slope == kCabCutSlope18) {
    chain.count = 2;
    chain.stages[0] = pinPassFirstOrder(highPass, freq, rate);
    chain.stages[1] = pinPassCoefficients(highPass, freq, rate, 1.0);
  } else {
    chain.count = 2;
    chain.stages[0] = pinPassCoefficients(highPass, freq, rate, 0.54119610014619698);
    chain.stages[1] = pinPassCoefficients(highPass, freq, rate, 1.3065629648763766);
  }
  return chain;
}

inline double pinMagnitudeDb(const PinCoeffs& f, double hz, double rate) noexcept {
  constexpr double kPi = 3.14159265358979323846;
  const double w = 2.0 * kPi * hz / rate;
  const double c = std::cos(w), s = std::sin(w);
  const double c2 = std::cos(2.0 * w), s2 = std::sin(2.0 * w);
  const double num = std::hypot(f.b0 + f.b1 * c + f.b2 * c2, -(f.b1 * s + f.b2 * s2));
  const double den = std::hypot(1.0 + f.a1 * c + f.a2 * c2, -(f.a1 * s + f.a2 * s2));
  return 20.0 * std::log10(std::max(1.0e-12, num / den));
}

// Sum of every placed pin's response (dB) at `hz`.
template <size_t BandCount>
inline double pinBandsMagnitudeDb(const std::array<PinBand, BandCount>& bands, double hz, double rate) noexcept {
  double db = 0.0;
  for (const auto& b : bands)
    if (b.shape != kPinOff && b.gainDb != 0.0)
      db += pinMagnitudeDb(pinCoefficients(b.shape, b.freq, b.gainDb, b.q, rate), hz, rate);
  return db;
}

// Up to two channels of click-free pin EQ. Gain, frequency and Q glide over
// ~20 ms on a 32-sample cadence; a shape change glides the band to 0 dB,
// switches at unity and glides back, so adding, removing or reshaping a pin
// never steps the filter.
template <size_t BandCount>
class BasicPinEq {
 public:
  static constexpr size_t kMaxChannels = 2;

  void reset() noexcept {
    for (auto& st : bands_) st = BandState{};
    primed_ = false;
    rate_ = 0.0;
  }

  void process(float* const* channels, size_t channelCount, size_t count, double rate,
               const std::array<PinBand, BandCount>& targets) noexcept {
    channelCount = std::min(channelCount, kMaxChannels);
    if (rate != rate_) {
      // A new processing domain: histories at the old rate mean nothing.
      for (auto& st : bands_) { st.clearHistory(); st.dirty = true; }
      rate_ = rate;
    }
    // Targets stay fixed throughout this call, including every smoothing chunk.
    bool anyActiveOrTargetActive = false;
    for (size_t b = 0; b < BandCount; ++b) {
      auto& st = bands_[b];
      const auto& t = targets[b];
      if (t.freq != st.cachedFreq) {
        st.targetLogFreq = std::log(clampFreq(t.freq));
        st.cachedFreq = t.freq;
      }
      if (t.q != st.cachedQ) {
        st.targetLogQ = std::log(t.q);
        st.cachedQ = t.q;
      }
      if (st.gainDb != 0.0 || (t.shape != kPinOff && t.gainDb != 0.0)) {
        anyActiveOrTargetActive = true;
      }
    }
    if (!primed_) {
      for (size_t b = 0; b < BandCount; ++b) {
        auto& st = bands_[b];
        st.shape = targets[b].shape;
        st.gainDb = st.shape == kPinOff ? 0.0 : targets[b].gainDb;
        st.logFreq = st.targetLogFreq;
        st.logQ = st.targetLogQ;
        st.dirty = true;
      }
      primed_ = true;
    }
    if (!anyActiveOrTargetActive && count > 0) {
      for (size_t b = 0; b < BandCount; ++b) {
        auto& st = bands_[b];
        const auto& t = targets[b];
        if (t.shape != st.shape) {
          st.shape = t.shape;
          st.dirty = true;
        }
        st.dirty |= st.logFreq != st.targetLogFreq || st.logQ != st.targetLogQ;
        st.logFreq = st.targetLogFreq;
        st.logQ = st.targetLogQ;
      }
      return;
    }
    const double fullGlide = 1.0 - std::exp(-static_cast<double>(kChunk) / (rate * 0.020));
    for (size_t start = 0; start < count; start += kChunk) {
      const size_t n = std::min(kChunk, count - start);
      const double glide = (n == kChunk)
          ? fullGlide
          : (1.0 - std::exp(-static_cast<double>(n) / (rate * 0.020)));
      for (size_t b = 0; b < BandCount; ++b) {
        auto& st = bands_[b];
        const auto& t = targets[b];
        const double gainTarget = (t.shape == st.shape && t.shape != kPinOff) ? t.gainDb : 0.0;
        const bool wasActive = st.active();
        st.dirty |= glideTo(st.gainDb, gainTarget, glide, 1.0e-3);
        if (st.gainDb == 0.0 && t.shape != st.shape) {
          st.shape = t.shape;
          st.dirty = true;
        }
        const double freqTarget = st.targetLogFreq;
        const double qTarget = st.targetLogQ;
        if (st.active()) {
          st.dirty |= glideTo(st.logFreq, freqTarget, glide, 1.0e-5);
          st.dirty |= glideTo(st.logQ, qTarget, glide, 1.0e-5);
        } else {
          st.dirty |= st.logFreq != freqTarget || st.logQ != qTarget;
          st.logFreq = freqTarget;
          st.logQ = qTarget;
        }
        if (!st.active()) continue;
        if (!wasActive) st.clearHistory();
        if (st.dirty) {
          st.c = pinCoefficients(st.shape, std::exp(st.logFreq), st.gainDb,
                                 std::exp(st.logQ), rate);
          st.dirty = false;
        }
        for (size_t ch = 0; ch < channelCount; ++ch) {
          float* s = channels[ch] + start;
          double z1 = st.z[ch][0], z2 = st.z[ch][1];
          const PinCoeffs& c = st.c;
          for (size_t i = 0; i < n; ++i) {
            const double x = s[i];
            const double y = c.b0 * x + z1;
            z1 = c.b1 * x - c.a1 * y + z2;
            z2 = c.b2 * x - c.a2 * y;
            s[i] = static_cast<float>(y);
          }
          st.z[ch][0] = z1;
          st.z[ch][1] = z2;
        }
      }
    }
  }

 private:
  static constexpr size_t kChunk = 32;

  struct BandState {
    int shape = kPinOff;
    float cachedFreq = -1.0f, cachedQ = -1.0f;
    double targetLogFreq = 0.0, targetLogQ = 0.0;
    double gainDb = 0.0, logFreq = 0.0, logQ = 0.0;
    PinCoeffs c;
    double z[kMaxChannels][2] = {};
    bool dirty = true;
    bool active() const noexcept { return shape != kPinOff && gainDb != 0.0; }
    void clearHistory() noexcept {
      for (auto& ch : z) ch[0] = ch[1] = 0.0;
    }
  };

  double clampFreq(double hz) const noexcept {
    return std::clamp(hz, static_cast<double>(kPinFreqMin),
                      std::min(static_cast<double>(kPinFreqMax), rate_ * 0.45));
  }
  static bool glideTo(double& value, double target, double coeff, double snap) noexcept {
    if (value == target) return false;
    value += (target - value) * coeff;
    if (std::fabs(target - value) < snap) value = target;
    return true;
  }

  std::array<BandState, BandCount> bands_{};
  bool primed_ = false;
  double rate_ = 0.0;
};

using PinEq = BasicPinEq<kPinEqBandCount>;
using ToneEq = BasicPinEq<kToneEqBandCount>;

}  // namespace NAMRig
