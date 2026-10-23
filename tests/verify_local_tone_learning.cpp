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
  std::puts("PASS local features: level invariance, stereo phase, finite/silent guards, learned predictions");
}
