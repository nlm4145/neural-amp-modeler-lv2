#include "local_tone_learning.h"
#include <cassert>
#include <cstdio>
#include <limits>

int main() {
  using namespace NAMRig::LocalTone;
  std::vector<float> signal(48000), quiet(48000), antiphase(96000);
  for (size_t i = 0; i < signal.size(); ++i) {
    signal[i] = .1f * std::sin(2 * 3.141592653589793 * 250 * i / 48000) +
        .05f * std::sin(2 * 3.141592653589793 * 2500 * i / 48000);
    quiet[i] = signal[i] * .1f;
    antiphase[2 * i] = signal[i]; antiphase[2 * i + 1] = -signal[i];
  }
  auto a = measure(signal.data(), signal.size(), 1, 48000);
  auto b = measure(quiet.data(), quiet.size(), 1, 48000);
  auto stereo = measure(antiphase.data(), signal.size(), 2, 48000);
  assert(distance(a.features, b.features) < 1e-5);
  assert(distance(a.features, stereo.features) < 1e-5);
  // References and DI can come from different interfaces/sample rates.
  std::vector<float> otherRate(44100);
  for (size_t i = 0; i < otherRate.size(); ++i) otherRate[i] =
      .1f * std::sin(2 * 3.141592653589793 * 250 * i / 44100) +
      .05f * std::sin(2 * 3.141592653589793 * 2500 * i / 44100);
  auto differentRate = measure(otherRate.data(), otherRate.size(), 1, 44100);
  assert(distance(a.features, differentRate.features) < .15);
  // FFT agrees with a naive DFT.
  {
    std::vector<double> re(64), im(64, 0), x(64);
    for (size_t i = 0; i < x.size(); ++i) x[i] = re[i] = std::sin(.7 * i) + .3 * std::cos(2.1 * i * i);
    fft(re, im);
    for (size_t k = 0; k < x.size(); ++k) {
      double r = 0, m = 0;
      for (size_t n = 0; n < x.size(); ++n) {
        r += x[n] * std::cos(2 * 3.141592653589793 * k * n / x.size());
        m -= x[n] * std::sin(2 * 3.141592653589793 * k * n / x.size());
      }
      assert(std::fabs(r - re[k]) < 1e-9 && std::fabs(m - im[k]) < 1e-9);
    }
  }
  // Saturation texture: a hard-driven chord is flatter/denser than a clean one.
  {
    std::vector<float> clean(48000), driven(48000);
    for (size_t i = 0; i < clean.size(); ++i) {
      double t = i / 48000.0, x = std::sin(2 * 3.141592653589793 * 110 * t) +
          std::sin(2 * 3.141592653589793 * 164.8 * t) + std::sin(2 * 3.141592653589793 * 220 * t);
      clean[i] = static_cast<float>(.05 * x);
      driven[i] = static_cast<float>(.3 * std::tanh(8 * x));
    }
    auto c = measure(clean.data(), clean.size(), 1, 48000), d = measure(driven.data(), driven.size(), 1, 48000);
    for (size_t r = 0; r < kRegions; ++r) assert(d.features[kFlatnessIndex + r] > c.features[kFlatnessIndex + r] + 3);
    assert(d.features[kCrestIndex] < c.features[kCrestIndex]);
    assert(distance(c.features, d.features) > 1);
  }
  // Decay slope: plucked notes that die faster measure steeper.
  {
    auto plucks = [](double decayPerSecond) {
      std::vector<float> x(96000);
      for (size_t i = 0; i < x.size(); ++i) {
        double t = (i % 24000) / 48000.0;
        x[i] = static_cast<float>(.2 * std::exp(-decayPerSecond * t) * std::sin(2 * 3.141592653589793 * 196 * i / 48000));
      }
      return measure(x.data(), x.size(), 1, 48000).features[kDecayIndex];
    };
    double slow = plucks(2), fast = plucks(10);
    assert(slow < 0 && fast < slow - 2);
  }
  bool rejected = false;
  signal[0] = std::numeric_limits<float>::quiet_NaN();
  try { measure(signal.data(), signal.size(), 1, 48000); } catch (...) { rejected = true; }
  assert(rejected);
  std::fill(signal.begin(), signal.end(), 0); rejected = false;
  try { measure(signal.data(), signal.size(), 1, 48000); } catch (...) { rejected = true; }
  assert(rejected);
  std::vector<Example> examples;
  auto add = [&](Parameters x) {
    Features y{};
    for (size_t f = 0; f < kFeatures; ++f) {
      y[f] = 1 + .2 * f;
      for (size_t p = 0; p < kParameters; ++p) y[f] += x[p] * (.3 + .1 * p + .05 * f);
    }
    examples.push_back({x, y});
  };
  add({});
  for (size_t p = 0; p < kParameters; ++p) for (double d : {-1., 1.}) { Parameters x{}; x[p] = d; add(x); }
  Surrogate model; model.train(examples);
  Parameters test{.2, -.5, .3, .1, -.2, .4}; add(test);
  assert(distance(model.predict(test), examples.back().features) < .03);
  // Degenerate perturbations at control limits remain finite via ridge regularization.
  examples.assign(13, Example{}); model.train(examples);
  for (double x : model.predict(test)) assert(std::isfinite(x));
  // Demucs-aware weights attenuate bleed (< 100 Hz) and separation smear (> 8 kHz) by 0.3x.
  const Weights standard = defaultWeights(false), demucsW = defaultWeights(true);
  for (size_t b = 0; b < kBands; ++b) {
    const double f = bandCenter(b);
    if (f < 100 || f > 8000) {
      assert(std::fabs(demucsW[b] - standard[b] * 0.3) < 1e-9);
    } else {
      assert(std::fabs(demucsW[b] - standard[b]) < 1e-9);
    }
  }
  std::puts("PASS local features v2: level/rate invariance, stereo phase, FFT, saturation texture, decay slope, guards, learned predictions");
}
