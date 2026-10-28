#include "local_tone_post_eq.h"
#include <cassert>
#include <cstdio>

int main() {
  using namespace NAMRig;
  using namespace NAMRig::LocalTone;
  constexpr double rate = 48000, pi = 3.141592653589793;
  // Analytic magnitude agrees with actually filtering a steady sine.
  PostEq eq; eq.bass = 4; eq.mid = -3; eq.treble = 5; eq.lowCut = 100; eq.highCut = 9000;
  eq.pins[1] = {kPinBell, 1500, 6, 1.0};
  for (double hz : {70.0, 150.0, 700.0, 1500.0, 3000.0, 8000.0}) {
    std::vector<float> x(48000);
    for (size_t i = 0; i < x.size(); ++i) x[i] = float(.1 * std::sin(2 * pi * hz * i / rate));
    std::vector<float> y = x; applyPostEq(eq, y.data(), y.size(), 1, rate);
    double ex = 0, ey = 0;
    for (size_t i = 24000; i < x.size(); ++i) { ex += double(x[i]) * x[i]; ey += double(y[i]) * y[i]; }
    const double measured = 10 * std::log10(ey / ex), predicted = postEqMagnitudeDb(eq, hz, rate);
    if (std::fabs(measured - predicted) > .05) std::printf("%g Hz: measured %.3f predicted %.3f\n", hz, measured, predicted);
    assert(std::fabs(measured - predicted) < .05);
  }
  // Console-gated parts disappear when no cab is processed.
  PostEq bypassed = eq; bypassed.console = false;
  assert(std::fabs(postEqMagnitudeDb(bypassed, 1500, rate) - postEqMagnitudeDb({4, -3, 5, 0, 20000, false, {}}, 1500, rate)) < 1e-9);

  // A dense, driven chord stands in for a guitar render.
  std::vector<float> render(size_t(rate * 3));
  for (size_t i = 0; i < render.size(); ++i) {
    const double t = i / rate;
    double x = 0;
    for (double f : {82.4, 123.5, 164.8, 207.7, 246.9}) x += std::sin(2 * pi * f * t);
    render[i] = float(.25 * std::tanh(4 * x) * (1 - .2 * std::fmod(t, 1.0)));
  }
  auto measured = measure(render.data(), render.size(), 1, rate);
  // Neutral target: nothing to fix.
  PostEq none;
  auto neutral = solveLinear(measured.features, measured.features, rate, none);
  assert(std::fabs(neutral.eq.bass) < .5 && std::fabs(neutral.eq.mid) < .5 && std::fabs(neutral.eq.treble) < .5);
  assert(neutral.eq.lowCut == 0 && neutral.eq.highCut == 20000 && neutral.score < .05);
  // Recover a known tone stack + cut from features alone.
  PostEq truth; truth.bass = 5; truth.mid = -4; truth.treble = -6; truth.lowCut = 80; truth.highCut = 20000;
  std::vector<float> target = render; applyPostEq(truth, target.data(), target.size(), 1, rate);
  auto goal = measure(target.data(), target.size(), 1, rate);
  const double before = distance(measured.features, goal.features);
  auto measureWith = [&](const PostEq& candidate) {
    std::vector<float> y = render; applyPostEq(candidate, y.data(), y.size(), 1, rate);
    return measure(y.data(), y.size(), 1, rate).features;
  };
  auto oneShot = solveLinear(measured.features, goal.features, rate, none);
  const double oneShotVerified = distance(measureWith(oneShot.eq), goal.features);
  auto fit = fitLinear(measured.features, goal.features, rate, none, measureWith);
  const double after = distance(measureWith(fit.eq), goal.features);
  assert(std::fabs(after - fit.score) < 1e-9 && after <= oneShotVerified + 1e-9);
  std::printf("fit bass %.2f mid %.2f treble %.2f lowcut %.0f highcut %.0f; one-shot %.3f, verified %.3f -> %.3f dB\n",
              fit.eq.bass, fit.eq.mid, fit.eq.treble, fit.eq.lowCut, fit.eq.highCut, oneShotVerified, before, after);
  assert(after < before * .05 && after < .1);
  // Gauss-Newton on all features recovers the knobs themselves, not just a look-alike.
  assert(std::fabs(fit.eq.bass - 5) < 1 && std::fabs(fit.eq.mid + 4) < 1 && std::fabs(fit.eq.treble + 6) < 1 && std::fabs(fit.eq.lowCut - 80) < 15);
  // Mix EQ: a target voiced by pins the tone stack cannot reproduce (narrow-ish
  // 600 Hz cut, 1.5 kHz and 3.5 kHz moves) is mostly recovered by the pins.
  {
    PostEq console; console.console = true;
    PostEq mixTruth = console; mixTruth.bass = 2;
    setMixPins(mixTruth, {0, 0, -5, 3, -4, 0});
    std::vector<float> mixed = render; applyPostEq(mixTruth, mixed.data(), mixed.size(), 1, rate);
    const auto mixGoal = measure(mixed.data(), mixed.size(), 1, rate).features;
    auto toneOnly = fitLinear(measured.features, mixGoal, rate, console, measureWith);
    auto withMix = fitMixEq(toneOnly, mixGoal, rate, measureWith);
    assert(std::fabs(distance(measureWith(withMix.eq), mixGoal) - withMix.score) < 1e-9);
    std::printf("mix EQ: tone stack only %.3f -> with pins %.3f dB; pins %+.1f %+.1f %+.1f %+.1f %+.1f %+.1f\n",
                toneOnly.score, withMix.score, withMix.eq.pins[0].gainDb, withMix.eq.pins[1].gainDb, withMix.eq.pins[2].gainDb,
                withMix.eq.pins[3].gainDb, withMix.eq.pins[4].gainDb, withMix.eq.pins[5].gainDb);
    assert(withMix.score < toneOnly.score * .5 && withMix.score < .2);
    // Ridge keeps pins subtle and the tone stack's 700 Hz mid shares the 600 Hz cut: check direction.
    assert(withMix.eq.pins[2].gainDb < -1 && withMix.eq.pins[3].gainDb > 1 && withMix.eq.pins[4].gainDb < -1);
    // Nothing to explain: the pins stay (near) flat and never make it worse.
    auto plain = fitLinear(measured.features, goal.features, rate, console, measureWith);
    auto plainMix = fitMixEq(plain, goal.features, rate, measureWith);
    assert(plainMix.score <= plain.score + 1e-12);
    for (const auto& pin : plainMix.eq.pins) assert(std::fabs(pin.gainDb) < 1.5);
    // No cab processed: no Console pins to use.
    PostEq noCab; noCab.console = false;
    auto rigOnly = fitLinear(measured.features, mixGoal, rate, noCab, measureWith);
    auto rigMix = fitMixEq(rigOnly, mixGoal, rate, measureWith);
    assert(rigMix.score == rigOnly.score && rigMix.eq.pins[2].gainDb == 0);
  }
  std::puts("PASS local post EQ: analytic response, console gating, neutral and recovered tone-stack fits, mix-EQ pins");
}
