// Offline mirror of the engine's linear post-cab section, plus a closed-form fit
// of its controls to a target. Linear filters commute with the cab IR, so a
// render with this section neutral can be re-voiced exactly without the engine.
#pragma once
#include "local_tone_learning.h"
#include "pin_eq.h"
#include <vector>

namespace NAMRig::LocalTone {
inline constexpr uint32_t kBassPort = 12, kMidPort = 13, kTreblePort = 14;
inline constexpr uint32_t kLowCutPort = 26, kHighCutPort = 27, kConsolePort = 78;
inline constexpr double kToneStackQ = 0.7071067811865476; // nam_rig_plugin.cpp kEqQ

// nam_rig_plugin.cpp processPostChain: cab low/high cut and Cab Console pins
// run only when a cab was processed and the console rack is on; Bass (150 Hz
// low shelf), Mid (700 Hz bell) and Treble (3 kHz high shelf) always run.
struct PostEq {
  double bass = 0, mid = 0, treble = 0;
  double lowCut = 0, highCut = 20000;
  bool console = true; // cab processed && console rack on
  PinBands pins{};     // Cab Console pins
};

inline std::vector<PinCoeffs> postEqSections(const PostEq& eq, double rate) {
  std::vector<PinCoeffs> sections;
  if (eq.console) {
    if (eq.lowCut >= 20) sections.push_back(pinPassCoefficients(true, eq.lowCut, rate));
    const double highCut = std::min(eq.highCut, rate * .45);
    if (highCut < 19990) sections.push_back(pinPassCoefficients(false, std::max(1000.0, highCut), rate));
    for (const auto& b : eq.pins)
      if (b.shape != kPinOff && b.gainDb != 0) sections.push_back(pinCoefficients(b.shape, b.freq, b.gainDb, b.q, rate));
  }
  if (eq.bass != 0) sections.push_back(pinCoefficients(kPinLowShelf, 150, eq.bass, kToneStackQ, rate));
  if (eq.mid != 0) sections.push_back(pinCoefficients(kPinBell, 700, eq.mid, kToneStackQ, rate));
  if (eq.treble != 0) sections.push_back(pinCoefficients(kPinHighShelf, 3000, eq.treble, kToneStackQ, rate));
  return sections;
}

inline double postEqMagnitudeDb(const PostEq& eq, double hz, double rate) {
  double db = 0;
  for (const auto& s : postEqSections(eq, rate)) db += pinMagnitudeDb(s, hz, rate);
  return db;
}
// Energy-average response across a 1/3-octave feature band (flat spectrum assumed).
inline double postEqBandDb(const PostEq& eq, size_t band, double rate) {
  const double center = bandCenter(band);
  double power = 0;
  for (int i = -4; i <= 4; ++i) power += std::pow(10.0, postEqMagnitudeDb(eq, center * std::pow(2.0, i / 24.0), rate) / 10);
  return 10 * std::log10(power / 9);
}

// Interleaved, in place, double-precision transposed direct form II.
inline void applyPostEq(const PostEq& eq, float* audio, size_t frames, size_t channels, double rate) {
  for (const auto& s : postEqSections(eq, rate)) {
    for (size_t c = 0; c < channels; ++c) {
      double z1 = 0, z2 = 0;
      for (size_t f = 0; f < frames; ++f) {
        const double x = audio[f * channels + c], y = s.b0 * x + z1;
        z1 = s.b1 * x - s.a1 * y + z2; z2 = s.b2 * x - s.a2 * y;
        audio[f * channels + c] = static_cast<float>(y);
      }
    }
  }
}

struct LinearFit {
  PostEq eq;
  Features predicted{};
  double score = 0;
};

// Fits Bass/Mid/Treble (±12 dB) and the cab cuts (grid) so that `measured`
// (features of audio rendered with `fixed`'s pins/console flag and a neutral
// tone stack and cuts) best matches `goal`. Band energies are RMS-relative,
// so a free common offset absorbs the level change of the EQ; texture features
// are assumed unchanged. Small ridge keeps the EQ from chasing noise. The
// prediction is approximate; fitLinear verifies and corrects it.
inline LinearFit solveLinear(const Features& measured, const Features& goal, double rate, PostEq fixed,
                             const Weights& weights = defaultWeights()) {
  constexpr size_t kGains = 3;
  constexpr double kRidge = .02, kLimit = 12;
  const double lowCuts[] = {0, 60, 80, 100, 130, 170};
  const double highCuts[] = {20000, 12000, 9000, 7000, 5500, 4500};
  // Each tone-stack control's band shape per dB, evaluated at a typical gain.
  auto shapeAt = [&](size_t k, double gain) {
    std::array<double, kBands> shape{};
    PostEq one; one.console = false;
    (k == 0 ? one.bass : k == 1 ? one.mid : one.treble) = gain;
    for (size_t b = 0; b < kBands; ++b) shape[b] = postEqBandDb(one, b, rate) / gain;
    return shape;
  };
  std::array<std::array<double, kBands>, kGains> shapes{shapeAt(0, 6), shapeAt(1, 6), shapeAt(2, 6)};
  std::array<bool, kBands> usable{};
  for (size_t b = 0; b < kBands; ++b) usable[b] = bandCenter(b) < rate * .45 && goal[b] > -79 && measured[b] > -79;

  LinearFit best; best.score = 1e300;
  for (int pass = 0; pass < 2; ++pass) {
    for (double lowCut : lowCuts) {
      for (double highCut : highCuts) {
        PostEq cuts = fixed;
        cuts.bass = cuts.mid = cuts.treble = 0; cuts.lowCut = lowCut; cuts.highCut = highCut;
        std::array<double, kBands> base{};
        for (size_t b = 0; b < kBands; ++b) base[b] = measured[b] + postEqBandDb(cuts, b, rate);
        // Least squares in (gains, offset) with simple active-set clamping.
        std::array<double, kGains> gains{};
        std::array<bool, kGains> free{true, true, true};
        double offset = 0;
        for (int iteration = 0; iteration < 4; ++iteration) {
          constexpr size_t n = kGains + 1;
          std::array<std::array<double, n + 1>, n> system{};
          for (size_t b = 0; b < kBands; ++b) {
            if (!usable[b]) continue;
            std::array<double, n> x{};
            double target = goal[b] - base[b];
            for (size_t k = 0; k < kGains; ++k) {
              if (free[k]) x[k] = shapes[k][b]; else target -= gains[k] * shapes[k][b];
            }
            x[kGains] = 1;
            for (size_t i = 0; i < n; ++i) {
              for (size_t j = 0; j < n; ++j) system[i][j] += weights[b] * x[i] * x[j];
              system[i][n] += weights[b] * x[i] * target;
            }
          }
          for (size_t k = 0; k < kGains; ++k) system[k][k] += free[k] ? kRidge : 1; // Pinned gains solve to 0.
          for (size_t col = 0; col < n; ++col) {
            size_t pivot = col;
            for (size_t r = col + 1; r < n; ++r) if (std::fabs(system[r][col]) > std::fabs(system[pivot][col])) pivot = r;
            std::swap(system[col], system[pivot]);
            if (std::fabs(system[col][col]) < 1e-12) continue;
            const double d = system[col][col];
            for (double& v : system[col]) v /= d;
            for (size_t r = 0; r < n; ++r) if (r != col) {
              const double factor = system[r][col];
              for (size_t j = 0; j <= n; ++j) system[r][j] -= factor * system[col][j];
            }
          }
          bool clamped = false;
          for (size_t k = 0; k < kGains; ++k) {
            if (!free[k]) continue;
            gains[k] = system[k][n];
            if (std::fabs(gains[k]) > kLimit) { gains[k] = std::copysign(kLimit, gains[k]); free[k] = false; clamped = true; }
          }
          offset = system[kGains][n];
          if (!clamped) break;
        }
        LinearFit fit;
        fit.eq = cuts; fit.eq.bass = gains[0]; fit.eq.mid = gains[1]; fit.eq.treble = gains[2];
        fit.predicted = measured;
        for (size_t b = 0; b < kBands; ++b) {
          double value = base[b] + offset;
          for (size_t k = 0; k < kGains; ++k) value += gains[k] * shapes[k][b];
          fit.predicted[b] = usable[b] ? value : measured[b];
        }
        fit.score = distance(fit.predicted, goal, weights);
        if (fit.score < best.score) best = fit;
      }
    }
    // Shelves are not exactly linear in dB: re-evaluate shapes at the chosen gains.
    for (size_t k = 0; k < kGains; ++k) {
      const double g = k == 0 ? best.eq.bass : k == 1 ? best.eq.mid : best.eq.treble;
      if (std::fabs(g) > .5) shapes[k] = shapeAt(k, g);
    }
  }
  return best;
}

// Tone-stack parameters in comparable units: gains in dB, low cut in tens of Hz
// (< 2 = off). Index 0 bass, 1 mid, 2 treble, 3 low cut.
inline constexpr double kToneStackLow[4] = {-12, -12, -12, 0}, kToneStackHigh[4] = {12, 12, 12, 20};
inline double toneStackGet(const PostEq& eq, size_t k) {
  return k == 0 ? eq.bass : k == 1 ? eq.mid : k == 2 ? eq.treble : eq.lowCut / 10;
}
inline void toneStackSet(PostEq& eq, size_t k, double v) {
  v = std::clamp(v, kToneStackLow[k], kToneStackHigh[k]);
  (k == 0 ? eq.bass : k == 1 ? eq.mid : k == 2 ? eq.treble : eq.lowCut) = k < 3 ? v : (v < 2 ? 0 : v * 10);
}
inline double toneStackProbe(const PostEq& eq, size_t k) {
  const double x = toneStackGet(eq, k);
  if (k == 3 && x < 2) return 4 - x; // From "off" to a 40 Hz cut.
  return x + 1.5 > kToneStackHigh[k] ? -1.5 : 1.5;
}

// Damped Gauss-Newton over `dims` parameters of a PostEq against *all* features,
// with a finite-difference Jacobian from real measurements (measureWith). The
// per-parameter ridge(k) pulls toward 0 (keeps corrections subtle); a step is
// accepted only if the measured distance improves. Costs dims + 1..2 measurements
// per iteration. get/set/probe: (PostEq, k) accessors; probe returns the FD step.
inline constexpr size_t kMaxRefineDims = 10;
template <typename Get, typename Set, typename Probe, typename Ridge, typename MeasureWith>
inline LinearFit refineGaussNewton(LinearFit best, const Features& goal, size_t dims, Get&& get, Set&& set,
                                   Probe&& probe, Ridge&& ridge, MeasureWith&& measureWith, int iterations,
                                   const Weights& weights) {
  dims = std::min(dims, kMaxRefineDims);
  double damping = .05;
  for (int iteration = 0; iteration < iterations && best.score > .02; ++iteration) {
    std::array<Features, kMaxRefineDims> jacobian{};
    for (size_t k = 0; k < dims; ++k) {
      PostEq moved = best.eq;
      const double x = get(best.eq, k), h = probe(best.eq, k);
      set(moved, k, x + h);
      const double actual = get(moved, k) - x; // After clamping/snapping.
      if (std::fabs(actual) < 1e-9) continue;
      const Features measured = measureWith(moved);
      for (size_t f = 0; f < kFeatures; ++f) jacobian[k][f] = (measured[f] - best.predicted[f]) / actual;
    }
    for (int attempt = 0; attempt < 2; ++attempt) {
      // (JᵀWJ + λ_ridge I + damping·diag) δ = -JᵀW r - λ_ridge x
      double system[kMaxRefineDims][kMaxRefineDims + 1] = {};
      for (size_t f = 0; f < kFeatures; ++f) {
        const double r = best.predicted[f] - goal[f];
        for (size_t i = 0; i < dims; ++i) {
          for (size_t j = 0; j < dims; ++j) system[i][j] += weights[f] * jacobian[i][f] * jacobian[j][f];
          system[i][dims] -= weights[f] * jacobian[i][f] * r;
        }
      }
      for (size_t i = 0; i < dims; ++i) {
        system[i][i] += ridge(i) + damping * (1 + system[i][i]);
        system[i][dims] -= ridge(i) * get(best.eq, i);
      }
      for (size_t col = 0; col < dims; ++col) {
        size_t pivot = col;
        for (size_t row = col + 1; row < dims; ++row) if (std::fabs(system[row][col]) > std::fabs(system[pivot][col])) pivot = row;
        for (size_t j = 0; j <= dims; ++j) std::swap(system[col][j], system[pivot][j]);
        if (std::fabs(system[col][col]) < 1e-12) continue;
        const double d = system[col][col];
        for (size_t j = 0; j <= dims; ++j) system[col][j] /= d;
        for (size_t row = 0; row < dims; ++row) if (row != col) {
          const double factor = system[row][col];
          for (size_t j = 0; j <= dims; ++j) system[row][j] -= factor * system[col][j];
        }
      }
      LinearFit trial = best;
      for (size_t k = 0; k < dims; ++k) set(trial.eq, k, get(trial.eq, k) + system[k][dims]);
      trial.predicted = measureWith(trial.eq);
      trial.score = distance(trial.predicted, goal, weights);
      if (trial.score < best.score) { best = trial; damping = std::max(.01, damping * .5); break; }
      damping *= 8;
    }
  }
  return best;
}

// Verified fit: (1) solve the band model, apply the EQ to the real audio
// (measureWith), correct the model by the observed error and re-solve; then
// (2) Gauss-Newton on the tone stack (+ low cut when a cab is processed)
// against all features (EQ also moves flatness/crest). Returns the best
// measured result (predicted = actual). measureWith(PostEq) -> Features; costs
// about 2 + 5 * refinements measurements.
template <typename MeasureWith>
inline LinearFit fitLinear(const Features& neutral, const Features& goal, double rate, const PostEq& fixed,
                           MeasureWith&& measureWith, int refinements = 3, const Weights& weights = defaultWeights()) {
  Features model = neutral;
  LinearFit best; best.score = 1e300;
  for (int i = 0; i < 2; ++i) {
    LinearFit fit = solveLinear(model, goal, rate, fixed, weights);
    const Features actual = measureWith(fit.eq);
    const double score = distance(actual, goal, weights);
    if (score < best.score) { best = fit; best.predicted = actual; best.score = score; }
    for (size_t b = 0; b < kBands; ++b) model[b] += actual[b] - fit.predicted[b];
    for (size_t f = kBands; f < kFeatures; ++f) model[f] = actual[f];
  }
  return refineGaussNewton(best, goal, fixed.console ? 4 : 3, toneStackGet, toneStackSet, toneStackProbe,
                           [](size_t) { return 0.0; }, measureWith, refinements, weights);
}

// "Mix EQ": six gentle Cab Console pins (100 Hz low shelf, bells at 250/600/1500/
// 3500 Hz, 8 kHz high shelf; ±6 dB) for what amp/cab/tone stack cannot explain —
// typically the target mix's EQ. Pins only exist when a cab is processed.
inline constexpr double kMixEqLimit = 6;
inline void setMixPins(PostEq& eq, const std::array<double, kPinEqBandCount>& gains) {
  for (size_t b = 0; b < kPinEqBandCount; ++b) {
    const int shape = b == 0 ? kPinLowShelf : b + 1 == kPinEqBandCount ? kPinHighShelf : kPinBell;
    eq.pins[b] = {shape, kPinFreqDefaults[b], std::clamp(gains[b], -kMixEqLimit, kMixEqLimit),
                  shape == kPinBell ? .9 : kToneStackQ};
  }
}
// Starts from a verified tone-stack fit (start.predicted = its measured features).
// Band-model ridge solve for the six gains, then joint Gauss-Newton on pins + tone
// stack + low cut (the tone stack may have bent to imitate the mix), with a ridge on
// the pins only so just worthwhile corrections survive. Returns start when nothing helps.
template <typename MeasureWith>
inline LinearFit fitMixEq(const LinearFit& start, const Features& goal, double rate, MeasureWith&& measureWith,
                          int refinements = 3, const Weights& weights = defaultWeights()) {
  if (!start.eq.console) return start;
  // One joint band-model step from the tone-only fit: tone-stack changes plus pin
  // gains plus a common offset, ridged on the *absolute* tone-stack values and pin
  // gains, so it jumps to the smallest overall adjustment rather than keeping the
  // extremes a pin-less fit may have needed.
  constexpr size_t pinCount = kPinEqBandCount, tone = 3, n = tone + pinCount + 1;
  std::array<std::array<double, kBands>, tone + pinCount> shapes{};
  for (size_t k = 0; k < tone; ++k) {
    PostEq one; one.console = false;
    toneStackSet(one, k, 6);
    for (size_t b = 0; b < kBands; ++b) shapes[k][b] = postEqBandDb(one, b, rate) / 6;
  }
  for (size_t p = 0; p < pinCount; ++p) {
    std::array<double, kPinEqBandCount> unit{}; unit[p] = 3;
    PostEq one; one.console = true; setMixPins(one, unit);
    for (size_t b = 0; b < kBands; ++b) shapes[tone + p][b] = postEqBandDb(one, b, rate) / 3;
  }
  double system[n][n + 1] = {};
  for (size_t b = 0; b < kBands; ++b) {
    if (bandCenter(b) >= rate * .45 || goal[b] < -79) continue;
    double x[n]; for (size_t k = 0; k < tone + pinCount; ++k) x[k] = shapes[k][b]; x[n - 1] = 1;
    const double r = goal[b] - start.predicted[b];
    for (size_t i = 0; i < n; ++i) {
      for (size_t j = 0; j < n; ++j) system[i][j] += weights[b] * x[i] * x[j];
      system[i][n] += weights[b] * x[i] * r;
    }
  }
  // Ridge against the weighted squared residual sum (~23 × distance²): a 3 dB pin
  // costs about as much as 0.1 dB of distance, so pins move only when they pay off.
  for (size_t k = 0; k < tone; ++k) { system[k][k] += .01; system[k][n] -= .01 * toneStackGet(start.eq, k); }
  for (size_t p = 0; p < pinCount; ++p) system[tone + p][tone + p] += .05;
  for (size_t col = 0; col < n; ++col) {
    size_t pivot = col;
    for (size_t row = col + 1; row < n; ++row) if (std::fabs(system[row][col]) > std::fabs(system[pivot][col])) pivot = row;
    for (size_t j = 0; j <= n; ++j) std::swap(system[col][j], system[pivot][j]);
    if (std::fabs(system[col][col]) < 1e-12) continue;
    const double d = system[col][col];
    for (size_t j = 0; j <= n; ++j) system[col][j] /= d;
    for (size_t row = 0; row < n; ++row) if (row != col) {
      const double factor = system[row][col];
      for (size_t j = 0; j <= n; ++j) system[row][j] -= factor * system[col][j];
    }
  }
  std::array<double, kPinEqBandCount> gains{};
  for (size_t p = 0; p < pinCount; ++p) gains[p] = system[tone + p][n];
  LinearFit best = start, trial = start;
  for (size_t k = 0; k < tone; ++k) toneStackSet(trial.eq, k, toneStackGet(start.eq, k) + system[k][n]);
  setMixPins(trial.eq, gains);
  trial.predicted = measureWith(trial.eq);
  trial.score = distance(trial.predicted, goal, weights);
  if (trial.score < best.score) best = trial;
  else { setMixPins(best.eq, {}); best.predicted = measureWith(best.eq); best.score = distance(best.predicted, goal, weights); }
  constexpr size_t pins = kPinEqBandCount;
  auto get = [](const PostEq& eq, size_t k) { return k < pins ? eq.pins[k].gainDb : toneStackGet(eq, k - pins); };
  auto set = [](PostEq& eq, size_t k, double v) {
    if (k < pins) eq.pins[k].gainDb = std::clamp(v, -kMixEqLimit, kMixEqLimit); else toneStackSet(eq, k - pins, v);
  };
  auto probe = [](const PostEq& eq, size_t k) {
    return k < pins ? (eq.pins[k].gainDb + 1.5 > kMixEqLimit ? -1.5 : 1.5) : toneStackProbe(eq, k - pins);
  };
  best = refineGaussNewton(best, goal, pins + 4, get, set, probe, // Pins and tone stack overlap (100 Hz/150 Hz shelves, 600 Hz/700 Hz bells, 8 kHz/3 kHz
  // shelves): the valley of equal fits is long, so ridge both and take the smallest
  // adjustment that fits, with pins dearer than the amp's own controls.
  [](size_t k) { return k < pins ? .01 : k < pins + 3 ? .002 : 0.0; },
                           measureWith, refinements, weights);
  return best.score < start.score ? best : start;
}
} // namespace NAMRig::LocalTone
