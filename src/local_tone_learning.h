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
inline constexpr size_t kBands = 11, kFeatures = kBands + 2, kParameters = 6;
using Features = std::array<double, kFeatures>;
using Parameters = std::array<double, kParameters>;
inline constexpr double kCenters[kBands] = {100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 8000};
struct Measurement {
  Features features{};
  double peak = 0, rms = 0;
};

// Stereo energy is measured per channel, never downmixed (phase cancellation).
// Active windows exclude long gaps; all spectral values are relative to RMS,
// so turning the output up cannot win the match.
inline Measurement measure(const float* audio, size_t frames, size_t channels, double rate) {
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
  std::vector<double> levels;
  double energy = 0; size_t count = 0;
  for (size_t w = 0; w < energies.size(); ++w) {
    if (energies[w] < maxEnergy * .001) continue;
    size_t n = std::min(window, frames - w * window) * channels;
    energy += energies[w] * n; count += n;
    levels.push_back(10 * std::log10(energies[w]));
  }
  Measurement result;
  result.rms = std::sqrt(energy / count); result.peak = peak;
  for (size_t band = 0; band < kBands; ++band) {
    double w = 2 * 3.14159265358979323846 * kCenters[band] / rate;
    double alpha = std::sin(w) / (2 * 1.2), b = alpha / (1 + alpha);
    double a1 = -2 * std::cos(w) / (1 + alpha), a2 = (1 - alpha) / (1 + alpha);
    double filteredEnergy = 0;
    for (size_t c = 0; c < channels; ++c) {
      double z1 = 0, z2 = 0;
      for (size_t f = 0; f < frames; ++f) {
        double x = audio[f * channels + c], y = b * x + z1;
        z1 = -a1 * y + z2; z2 = -b * x - a2 * y;
        if (energies[f / window] >= maxEnergy * .001) filteredEnergy += y * y;
      }
    }
    result.features[band] = std::clamp(10 * std::log10(std::max(1e-12, filteredEnergy / count) /
        (result.rms * result.rms)), -80.0, 20.0);
  }
  std::sort(levels.begin(), levels.end());
  result.features[kBands] = std::clamp(20 * std::log10(peak / result.rms), 0.0, 40.0);
  result.features[kBands + 1] = levels[(levels.size() - 1) * 9 / 10] - levels[(levels.size() - 1) / 10];
  return result;
}
inline double distance(const Features& a, const Features& b) {
  double sum = 0;
  for (size_t i = 0; i < kFeatures; ++i) {
    double d = a[i] - b[i];
    sum += (i < kBands ? 1.0 : .2) * d * d;
  }
  return std::sqrt(sum / (kBands + .4));
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
