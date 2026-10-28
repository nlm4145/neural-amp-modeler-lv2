// Small, dependency-free local surrogate. Training examples come from real
// offline rig renders; predictions only nominate candidates for real testing.
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <stdexcept>
#include <vector>

namespace NAMRig::LocalTone {
// Feature set v2: 1/3-octave band balance (80 Hz–10 kHz) plus performance-tolerant
// saturation/dynamics descriptors. All values are level-invariant.
inline constexpr size_t kBands = 22;
inline constexpr size_t kRegions = 3; // low < 400 Hz, mid 400–2500 Hz, high > 2500 Hz
inline constexpr size_t kCrestIndex = kBands, kDynamicsIndex = kBands + 1;
inline constexpr size_t kPeakinessIndex = kBands + 2, kFlatnessIndex = kPeakinessIndex + kRegions;
inline constexpr size_t kDecayIndex = kFlatnessIndex + kRegions;
inline constexpr size_t kFeatures = kDecayIndex + 1, kParameters = 6;
inline constexpr int kFeatureVersion = 2;
using Features = std::array<double, kFeatures>;
using Parameters = std::array<double, kParameters>;
inline constexpr double kRegionEdges[kRegions - 1] = {400, 2500};
inline double bandCenter(size_t band) { return 80 * std::pow(2.0, band / 3.0); }
inline size_t regionOf(double frequency) {
  return frequency < kRegionEdges[0] ? 0 : frequency < kRegionEdges[1] ? 1 : 2;
}
struct Measurement {
  Features features{};
  double peak = 0, rms = 0;
};

// In-place iterative radix-2 FFT (n must be a power of two). Small and
// dependency-free so the feature code stays testable without Accelerate.
inline void fft(std::vector<double>& re, std::vector<double>& im) {
  const size_t n = re.size();
  for (size_t i = 1, j = 0; i < n; ++i) {
    size_t bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) { std::swap(re[i], re[j]); std::swap(im[i], im[j]); }
  }
  // Twiddles once per stage (n trig calls in total), not once per butterfly.
  for (size_t len = 2; len <= n; len <<= 1) {
    const double angle = -2 * 3.14159265358979323846 / len;
    for (size_t k = 0; k < len / 2; ++k) {
      const double c = std::cos(angle * k), s = std::sin(angle * k);
      for (size_t i = 0; i < n; i += len) {
        const size_t a = i + k, b = a + len / 2;
        const double tr = re[b] * c - im[b] * s, ti = re[b] * s + im[b] * c;
        re[b] = re[a] - tr; im[b] = im[a] - ti; re[a] += tr; im[a] += ti;
      }
    }
  }
}

// Stereo energy is measured per channel, never downmixed (phase cancellation).
// Active windows exclude long gaps; all spectral values are relative to RMS,
// so turning the output up cannot win the match.
inline Measurement measure(const float* audio, size_t frames, size_t channels, double rate) {
  constexpr double pi = 3.14159265358979323846;
  if (!audio || frames < 256 || (channels != 1 && channels != 2) ||
      !std::isfinite(rate) || rate < 22050 || rate > 192000)
    throw std::runtime_error("Need at least a short mono/stereo guitar excerpt at 22.05–192 kHz.");
  size_t window = std::max<size_t>(1, static_cast<size_t>(rate * .02));
  std::vector<double> energies((frames + window - 1) / window, 0);
  double maxEnergy = 0, peak = 0;
  for (size_t f = 0; f < frames; ++f) {
    for (size_t c = 0; c < channels; ++c) {
      double x = audio[f * channels + c];
      if (!std::isfinite(x)) throw std::runtime_error("Audio contains non-finite samples.");
      energies[f / window] += x * x;
      peak = std::max(peak, std::fabs(x));
    }
  }
  for (size_t w = 0; w < energies.size(); ++w) {
    energies[w] /= std::min(window, frames - w * window) * channels;
    maxEnergy = std::max(maxEnergy, energies[w]);
  }
  if (maxEnergy < 1e-10) throw std::runtime_error("The excerpt is silent or too quiet to match.");
  auto active = [&](size_t w) { return energies[w] >= maxEnergy * .001; };
  std::vector<double> levels, windowDb(energies.size());
  double energy = 0; size_t count = 0;
  for (size_t w = 0; w < energies.size(); ++w) {
    windowDb[w] = 10 * std::log10(std::max(energies[w], maxEnergy * 1e-6));
    if (!active(w)) continue;
    size_t n = std::min(window, frames - w * window) * channels;
    energy += energies[w] * n; count += n;
    levels.push_back(windowDb[w]);
  }
  Measurement result;
  result.rms = std::sqrt(energy / count); result.peak = peak;

  // 1/3-octave band energy and per-band peakiness (kurtosis in dB: a clean
  // sine is ~1.8 dB, dense distortion products approach Gaussian ~4.8 dB).
  std::array<double, kRegions> peakiness{}, peakinessCount{};
  for (size_t band = 0; band < kBands; ++band) {
    const double center = bandCenter(band);
    if (center >= rate * .45) { result.features[band] = -80; continue; }
    double w = 2 * pi * center / rate;
    double alpha = std::sin(w) / (2 * 4.3), b = alpha / (1 + alpha);
    double a1 = -2 * std::cos(w) / (1 + alpha), a2 = (1 - alpha) / (1 + alpha);
    double filteredEnergy = 0, fourth = 0;
    for (size_t c = 0; c < channels; ++c) {
      double z1 = 0, z2 = 0;
      for (size_t f = 0; f < frames; ++f) {
        double x = audio[f * channels + c], y = b * x + z1;
        z1 = -a1 * y + z2; z2 = -b * x - a2 * y;
        if (active(f / window)) { filteredEnergy += y * y; fourth += y * y * y * y; }
      }
    }
    const double meanSquare = filteredEnergy / count;
    result.features[band] = std::clamp(10 * std::log10(std::max(1e-12, meanSquare) /
        (result.rms * result.rms)), -80.0, 20.0);
    // Only bands carrying real energy say anything about saturation texture.
    if (result.features[band] > -40 && meanSquare > 0) {
      const size_t region = regionOf(center);
      peakiness[region] += std::clamp(10 * std::log10((fourth / count) / (meanSquare * meanSquare)), 0.0, 20.0);
      peakinessCount[region] += 1;
    }
  }
  for (size_t r = 0; r < kRegions; ++r)
    result.features[kPeakinessIndex + r] = peakinessCount[r] ? peakiness[r] / peakinessCount[r] : 0;

  // Spectral flatness (dB, geometric/arithmetic mean) per region, averaged over
  // active frames and channels. Frames are a fixed 42.7 ms, zero-padded 2x, and
  // power is sampled on a fixed 23.4 Hz grid so every sample rate sees the same
  // analysis frequencies.
  const size_t frameLength = static_cast<size_t>(std::lround(rate * 2048.0 / 48000.0));
  size_t fftSize = 256;
  while (fftSize < 2 * frameLength) fftSize <<= 1;
  std::array<double, kRegions> flatness{}; size_t flatFrames = 0;
  if (frameLength <= frames) {
    constexpr double gridStep = 48000.0 / 2048.0;
    const double top = std::min(10000.0, rate * .45);
    // 4-term Blackman-Harris: sidelobes (-92 dB) stay under the flatness floor.
    std::vector<double> re(fftSize), im(fftSize), taper(frameLength), grid;
    for (size_t i = 0; i < frameLength; ++i) {
      const double x = 2 * pi * i / frameLength;
      taper[i] = .35875 - .48829 * std::cos(x) + .14128 * std::cos(2 * x) - .01168 * std::cos(3 * x);
    }
    for (double f = std::ceil(80 / gridStep) * gridStep; f <= top; f += gridStep) grid.push_back(f);
    std::vector<double> power(grid.size());
    for (size_t c = 0; c < channels; ++c) {
      for (size_t start = 0; start + frameLength <= frames; start += frameLength / 2) {
        if (!active((start + frameLength / 2) / window)) continue;
        std::fill(re.begin(), re.end(), 0); std::fill(im.begin(), im.end(), 0);
        for (size_t i = 0; i < frameLength; ++i) re[i] = audio[(start + i) * channels + c] * taper[i];
        fft(re, im);
        double frameMax = 0;
        for (size_t j = 0; j < grid.size(); ++j) {
          const double position = grid[j] * fftSize / rate;
          const size_t k = static_cast<size_t>(position); const double t = position - k;
          const double p0 = re[k] * re[k] + im[k] * im[k], p1 = re[k + 1] * re[k + 1] + im[k + 1] * im[k + 1];
          power[j] = p0 + (p1 - p0) * t; frameMax = std::max(frameMax, power[j]);
        }
        // A floor 50 dB under the frame's strongest component keeps near-pure
        // tones and empty regions from measuring numerical noise.
        // Regions whose strongest component is >30 dB under the frame peak are
        // effectively empty: count them as tonal (-40 dB), not "flat".
        std::array<double, kRegions> logSum{}, sum{}, bins{}, regionMax{};
        for (size_t j = 0; j < grid.size(); ++j) {
          const size_t region = regionOf(grid[j]);
          const double value = std::max(power[j], frameMax * 1e-5) + 1e-20;
          logSum[region] += std::log(value); sum[region] += value; bins[region] += 1;
          regionMax[region] = std::max(regionMax[region], power[j]);
        }
        for (size_t r = 0; r < kRegions; ++r) {
          const double ratio = bins[r] && regionMax[r] >= frameMax * 1e-3 ?
              std::exp(logSum[r] / bins[r]) / (sum[r] / bins[r]) : 1e-4;
          flatness[r] += std::clamp(10 * std::log10(std::max(ratio, 1e-12)), -40.0, 0.0);
        }
        ++flatFrames;
      }
    }
  }
  for (size_t r = 0; r < kRegions; ++r)
    result.features[kFlatnessIndex + r] = flatFrames ? flatness[r] / flatFrames : -40;

  // Note decay: median level slope (dB per 100 ms) over the 300 ms after each
  // onset (a >= 6 dB jump between 20 ms windows). Sag and compression flatten it.
  std::vector<double> slopes;
  const size_t span = 15;
  for (size_t w = 1; w + 5 < windowDb.size(); ++w) {
    if (!active(w) || windowDb[w] - windowDb[w - 1] < 6) continue;
    size_t end = std::min(windowDb.size(), w + span), n = 0;
    double sx = 0, sy = 0, sxx = 0, sxy = 0;
    for (size_t i = w; i < end; ++i) {
      if (i > w && windowDb[i] - windowDb[i - 1] >= 6) break; // Next onset.
      double x = (i - w) * .2; // 20 ms windows in units of 100 ms.
      sx += x; sy += windowDb[i]; sxx += x * x; sxy += x * windowDb[i]; ++n;
    }
    if (n >= 5) slopes.push_back((n * sxy - sx * sy) / (n * sxx - sx * sx));
  }
  if (!slopes.empty()) {
    std::nth_element(slopes.begin(), slopes.begin() + slopes.size() / 2, slopes.end());
    result.features[kDecayIndex] = std::clamp(slopes[slopes.size() / 2], -30.0, 5.0);
  }

  std::sort(levels.begin(), levels.end());
  result.features[kCrestIndex] = std::clamp(20 * std::log10(peak / result.rms), 0.0, 40.0);
  result.features[kDynamicsIndex] = levels[(levels.size() - 1) * 9 / 10] - levels[(levels.size() - 1) / 10];
  return result;
}

// Average features over several excerpts (dB domain); peak is the maximum.
inline Measurement average(const std::vector<Measurement>& parts) {
  if (parts.empty()) throw std::runtime_error("No excerpts to measure.");
  Measurement out;
  for (const auto& m : parts) {
    for (size_t i = 0; i < kFeatures; ++i) out.features[i] += m.features[i] / parts.size();
    out.peak = std::max(out.peak, m.peak); out.rms += m.rms / parts.size();
  }
  return out;
}

struct Span { size_t start, count; };
inline std::vector<Span> spansAtRate(const std::vector<Span>& spans, double fromRate, double toRate) {
  if (!std::isfinite(fromRate) || !std::isfinite(toRate) || fromRate < 22050 || fromRate > 192000 ||
      toRate < 22050 || toRate > 192000)
    throw std::runtime_error("Invalid excerpt sample rate.");
  std::vector<Span> result;
  for (const Span& span : spans) {
    const size_t start = size_t(std::llround(span.start * toRate / fromRate));
    const size_t end = size_t(std::llround((span.start + span.count) * toRate / fromRate));
    result.push_back({start, end - start});
  }
  return result;
}
// Validate every span before pointer arithmetic. Never silently shorten a span:
// candidates must be scored over the same excerpt durations.
inline Measurement measureSpans(const float* audio, size_t frames, size_t channels,
                                const std::vector<Span>& spans, double rate) {
  if (!audio || (channels != 1 && channels != 2))
    throw std::runtime_error("Invalid excerpt audio format.");
  for (const Span& span : spans)
    if (span.start > frames || span.count > frames - span.start)
      throw std::runtime_error("Audio is too short for the requested matching excerpts.");
  std::vector<Measurement> parts;
  for (const Span& span : spans)
    parts.push_back(measure(audio + span.start * channels, span.count, channels, rate));
  return average(parts);
}

using Weights = Features;
// Band weights follow a gentle equal-loudness tilt; texture features count less
// because they are noisier across different performances.
inline Weights defaultWeights(bool demucs = false) {
  Weights w{};
  for (size_t band = 0; band < kBands; ++band) {
    const double f = bandCenter(band);
    w[band] = f < 160 ? .6 : f > 6000 ? .6 : 1.0;
    if (demucs && (f < 100 || f > 8000)) w[band] *= 0.3;
  }
  w[kCrestIndex] = w[kDynamicsIndex] = .2;
  for (size_t r = 0; r < kRegions; ++r) { w[kPeakinessIndex + r] = .5; w[kFlatnessIndex + r] = .1; }
  w[kDecayIndex] = .2;
  return w;
}
inline double distance(const Features& a, const Features& b, const Weights& weights = defaultWeights()) {
  double sum = 0, total = 0;
  for (size_t i = 0; i < kFeatures; ++i) {
    double d = a[i] - b[i];
    sum += weights[i] * d * d; total += weights[i];
  }
  return std::sqrt(sum / total);
}

struct Example { Parameters parameters{}; Features features{}; };
struct Surrogate {
  std::array<Features, kParameters + 1> coefficients{};
  void train(const std::vector<Example>& examples) {
    if (examples.size() < kParameters + 1) throw std::runtime_error("Not enough local training renders.");
    constexpr size_t n = kParameters + 1;
    std::array<std::array<double, n + kFeatures>, n> system{};
    for (const auto& e : examples) {
      std::array<double, n> x{}; x[0] = 1;
      std::copy(e.parameters.begin(), e.parameters.end(), x.begin() + 1);
      for (size_t i = 0; i < n; ++i) {
        for (size_t j = 0; j < n; ++j) system[i][j] += x[i] * x[j];
        for (size_t f = 0; f < kFeatures; ++f) system[i][n + f] += x[i] * e.features[f];
      }
    }
    for (size_t i = 1; i < n; ++i) system[i][i] += .05; // Ridge regularization.
    for (size_t col = 0; col < n; ++col) {
      size_t pivot = col;
      for (size_t r = col + 1; r < n; ++r)
        if (std::fabs(system[r][col]) > std::fabs(system[pivot][col])) pivot = r;
      std::swap(system[col], system[pivot]);
      if (std::fabs(system[col][col]) < 1e-12) throw std::runtime_error("Local training matrix is singular.");
      double divisor = system[col][col];
      for (double& v : system[col]) v /= divisor;
      for (size_t r = 0; r < n; ++r) if (r != col) {
        double factor = system[r][col];
        for (size_t j = 0; j < n + kFeatures; ++j) system[r][j] -= factor * system[col][j];
      }
    }
    for (size_t i = 0; i < n; ++i)
      std::copy(system[i].begin() + n, system[i].end(), coefficients[i].begin());
  }
  Features predict(const Parameters& parameters) const {
    Features out = coefficients[0];
    for (size_t p = 0; p < kParameters; ++p)
      for (size_t f = 0; f < kFeatures; ++f) out[f] += parameters[p] * coefficients[p + 1][f];
    return out;
  }
};
} // namespace NAMRig::LocalTone
