// Play-along DTW alignment and frame-level spectral distance for Axe FX.
// Header-only, dependency-free. Aligns candidate audio with target performance
// using onset envelopes and constrained Dynamic Time Warping.
#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <numeric>
#include <vector>

namespace NAMRig::LocalTone {

struct AlignmentResult {
  bool confident = false;
  double confidence = 0.0;         // Normalized correlation peak [0, 1]
  int64_t coarseOffsetFrames = 0;   // Coarse timing offset in samples
  double alignedDistance = 0.0;     // Mean dB spectral distance over aligned voiced frames

  double blendedScore(double statScore) const {
    if (!confident) return statScore;
    return 0.5 * statScore + 0.5 * alignedDistance;
  }
};

namespace detail {

inline constexpr size_t kAlignBands = 8;
inline constexpr double kAlignBandCenters[kAlignBands] = {
  90.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 12000.0
};

struct FrameData {
  double rmsDb = -120.0;
  double onset = 0.0;
  std::array<double, kAlignBands> bands{};
};

// Filter state for a second-order bandpass filter
struct Biquad {
  double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
  double z1 = 0, z2 = 0;

  static Biquad bandpass(double f0, double q, double rate) {
    Biquad b;
    const double w0 = 2.0 * M_PI * std::clamp(f0, 20.0, rate * 0.45) / rate;
    const double alpha = std::sin(w0) / (2.0 * std::max(0.1, q));
    const double a0 = 1.0 + alpha;
    b.b0 = alpha / a0;
    b.b1 = 0.0;
    b.b2 = -alpha / a0;
    b.a1 = (-2.0 * std::cos(w0)) / a0;
    b.a2 = (1.0 - alpha) / a0;
    return b;
  }

  inline double process(double in) {
    const double out = b0 * in + z1;
    z1 = b1 * in - a1 * out + z2;
    z2 = b2 * in - a2 * out;
    return out;
  }
};

inline std::vector<FrameData> extractFrames(const float* audio, size_t frames,
                                           size_t channels, double rate) {
  if (!audio || !frames || !channels || rate < 8000) return {};

  const size_t hopSize = std::max<size_t>(1, static_cast<size_t>(rate * 0.010)); // 10 ms hop
  const size_t winSize = std::max<size_t>(hopSize, static_cast<size_t>(rate * 0.025)); // 25 ms window
  const size_t numFrames = frames >= winSize ? (frames - winSize) / hopSize + 1 : 0;
  if (!numFrames) return {};

  // Initialize bandpass filters
  std::array<Biquad, kAlignBands> filters;
  for (size_t b = 0; b < kAlignBands; ++b) {
    filters[b] = Biquad::bandpass(kAlignBandCenters[b], 2.0, rate);
  }

  // Pre-filter audio into band signals (mono sum)
  std::vector<float> mono(frames);
  for (size_t i = 0; i < frames; ++i) {
    double sum = 0;
    for (size_t c = 0; c < channels; ++c) sum += audio[i * channels + c];
    mono[i] = static_cast<float>(sum / channels);
  }

  std::vector<std::vector<float>> bandSignals(kAlignBands, std::vector<float>(frames));
  for (size_t b = 0; b < kAlignBands; ++b) {
    Biquad filter = filters[b];
    for (size_t i = 0; i < frames; ++i) {
      bandSignals[b][i] = static_cast<float>(filter.process(mono[i]));
    }
  }

  std::vector<FrameData> result(numFrames);
  double prevEnergy = 0.0;

  for (size_t f = 0; f < numFrames; ++f) {
    const size_t start = f * hopSize;
    double frameEnergy = 0.0;

    for (size_t i = 0; i < winSize; ++i) {
      const double s = mono[start + i];
      frameEnergy += s * s;
    }
    frameEnergy /= winSize;
    const double rms = std::sqrt(frameEnergy);
    const double rmsDb = rms > 1e-6 ? 20.0 * std::log10(rms) : -120.0;
    result[f].rmsDb = rmsDb;

    // Spectral flux onset
    double flux = 0.0;
    for (size_t b = 0; b < kAlignBands; ++b) {
      double bEnergy = 0.0;
      for (size_t i = 0; i < winSize; ++i) {
        const double s = bandSignals[b][start + i];
        bEnergy += s * s;
      }
      bEnergy /= winSize;
      const double bDb = bEnergy > 1e-12 ? 10.0 * std::log10(bEnergy) : -120.0;
      result[f].bands[b] = bDb - rmsDb; // Level-normalized band shape
      flux += std::max(0.0, std::sqrt(bEnergy) - std::sqrt(prevEnergy));
    }
    result[f].onset = flux + std::max(0.0, frameEnergy - prevEnergy);
    prevEnergy = frameEnergy;
  }

  return result;
}

} // namespace detail

inline AlignmentResult alignAudio(const float* candidate, size_t candidateFrames, size_t candidateChannels,
                                  const float* target, size_t targetFrames, size_t targetChannels,
                                  double rate, bool demucs = false) {
  AlignmentResult res;
  if (!candidate || !candidateFrames || !target || !targetFrames || rate < 8000) return res;

  const auto candFrames = detail::extractFrames(candidate, candidateFrames, candidateChannels, rate);
  const auto targFrames = detail::extractFrames(target, targetFrames, targetChannels, rate);

  const size_t N = candFrames.size();
  const size_t M = targFrames.size();
  if (N < 5 || M < 5) return res;

  // 1. Coarse offset via normalized cross-correlation of onset envelopes
  std::vector<double> x(N), y(M);
  double meanX = 0, meanY = 0;
  for (size_t i = 0; i < N; ++i) { x[i] = candFrames[i].onset; meanX += x[i]; }
  for (size_t j = 0; j < M; ++j) { y[j] = targFrames[j].onset; meanY += y[j]; }
  meanX /= N; meanY /= M;

  double normX = 0, normY = 0;
  for (size_t i = 0; i < N; ++i) { x[i] -= meanX; normX += x[i] * x[i]; }
  for (size_t j = 0; j < M; ++j) { y[j] -= meanY; normY += y[j] * y[j]; }
  normX = std::sqrt(normX); normY = std::sqrt(normY);

  if (normX < 1e-6 || normY < 1e-6) return res;

  // Search lag within ±1.5s (or up to half length)
  const int maxLag = std::min<int>(static_cast<int>(rate * 0.010 * 150), static_cast<int>(std::max(N, M)));
  int bestLag = 0;
  double bestCorr = -1.0;

  for (int lag = -maxLag; lag <= maxLag; ++lag) {
    double sum = 0.0;
    size_t count = 0;
    for (size_t i = 0; i < N; ++i) {
      const int j = static_cast<int>(i) + lag;
      if (j >= 0 && j < static_cast<int>(M)) {
        sum += x[i] * y[j];
        ++count;
      }
    }
    if (count > 5) {
      const double corr = sum / (normX * normY);
      if (corr > bestCorr) {
        bestCorr = corr;
        bestLag = lag;
      }
    }
  }

  res.confidence = std::clamp(bestCorr, 0.0, 1.0);
  const size_t hopSamples = std::max<size_t>(1, static_cast<size_t>(rate * 0.010));
  res.coarseOffsetFrames = -static_cast<int64_t>(bestLag) * hopSamples;

  if (res.confidence < 0.5) {
    res.confident = false;
    return res;
  }

  // 2. Constrained Dynamic Time Warping (DTW) around the best lag
  // Band weights (optional Demucs de-weighting at <100 Hz and >8 kHz)
  std::array<double, detail::kAlignBands> weights;
  for (size_t b = 0; b < detail::kAlignBands; ++b) {
    const double f = detail::kAlignBandCenters[b];
    weights[b] = (demucs && (f < 100.0 || f > 8000.0)) ? 0.3 : 1.0;
  }

  auto frameDistance = [&](size_t i, size_t j) -> double {
    double sum = 0.0, weightSum = 0.0;
    for (size_t b = 0; b < detail::kAlignBands; ++b) {
      const double diff = candFrames[i].bands[b] - targFrames[j].bands[b];
      sum += weights[b] * diff * diff;
      weightSum += weights[b];
    }
    return std::sqrt(sum / std::max(1e-6, weightSum));
  };

  const int windowRadius = 25; // ±250 ms Sakoe-Chiba constraint
  constexpr double kInf = 1e9;
  std::vector<std::vector<double>> cost(N, std::vector<double>(M, kInf));

  // Initialize DTW matrix
  for (size_t i = 0; i < N; ++i) {
    const int centerJ = static_cast<int>(i) + bestLag;
    const int jMin = std::max<int>(0, centerJ - windowRadius);
    const int jMax = std::min<int>(static_cast<int>(M) - 1, centerJ + windowRadius);
    for (int j = jMin; j <= jMax; ++j) {
      const double d = frameDistance(i, static_cast<size_t>(j));
      if (i == 0 && j == 0) {
        cost[i][j] = d;
      } else {
        double prev = kInf;
        if (i > 0) prev = std::min(prev, cost[i - 1][j]);
        if (j > 0) prev = std::min(prev, cost[i][j - 1]);
        if (i > 0 && j > 0) prev = std::min(prev, cost[i - 1][j - 1]);
        cost[i][j] = d + prev;
      }
    }
  }

  // Traceback optimal warp path
  int currI = static_cast<int>(N) - 1;
  int currJ = std::clamp<int>(static_cast<int>(N) - 1 + bestLag, 0, static_cast<int>(M) - 1);

  // Find best ending point in the window around N - 1 + bestLag
  double minEndCost = kInf;
  const int endJCenter = static_cast<int>(N) - 1 + bestLag;
  for (int j = std::max(0, endJCenter - windowRadius); j <= std::min(static_cast<int>(M) - 1, endJCenter + windowRadius); ++j) {
    if (cost[N - 1][j] < minEndCost) {
      minEndCost = cost[N - 1][j];
      currJ = j;
    }
  }

  if (minEndCost >= kInf * 0.5) {
    res.confident = false;
    return res;
  }

  double totalVoicedDist = 0.0;
  size_t voicedCount = 0;

  // Voiced threshold: within 40 dB of peak RMS
  double peakRms = -120.0;
  for (const auto& f : targFrames) peakRms = std::max(peakRms, f.rmsDb);
  const double voicedFloor = peakRms - 40.0;

  while (currI > 0 || currJ > 0) {
    const size_t ui = static_cast<size_t>(currI);
    const size_t uj = static_cast<size_t>(currJ);

    if (candFrames[ui].rmsDb > voicedFloor && targFrames[uj].rmsDb > voicedFloor) {
      totalVoicedDist += frameDistance(ui, uj);
      ++voicedCount;
    }

    double bestPrev = kInf;
    int nextI = currI, nextJ = currJ;
    if (currI > 0 && currJ > 0 && cost[currI - 1][currJ - 1] < bestPrev) {
      bestPrev = cost[currI - 1][currJ - 1];
      nextI = currI - 1; nextJ = currJ - 1;
    }
    if (currI > 0 && cost[currI - 1][currJ] < bestPrev) {
      bestPrev = cost[currI - 1][currJ];
      nextI = currI - 1; nextJ = currJ;
    }
    if (currJ > 0 && cost[currI][currJ - 1] < bestPrev) {
      bestPrev = cost[currI][currJ - 1];
      nextI = currI; nextJ = currJ - 1;
    }

    if (nextI == currI && nextJ == currJ) break; // Reached boundary or dead end
    currI = nextI; currJ = nextJ;
  }

  if (voicedCount >= 10) {
    res.alignedDistance = totalVoicedDist / voicedCount;
    res.confident = true;
  } else {
    res.confident = false;
  }

  return res;
}

} // namespace NAMRig::LocalTone
