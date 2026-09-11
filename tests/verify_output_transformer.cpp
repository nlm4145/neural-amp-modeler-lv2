#include "output_transformer.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

namespace {
constexpr double kPi = 3.14159265358979323846;

double toneRms(int profile, double frequency, float amplitude = 0.2f) {
  constexpr double rate = 48000.0;
  constexpr size_t count = 48000;
  std::vector<float> samples(count);
  for (size_t i = 0; i < count; ++i)
    samples[i] = amplitude * std::sin(2.0 * kPi * frequency * i / rate);
  NAMRig::OutputTransformer transformer;
  transformer.process(samples.data(), samples.size(), rate, profile);
  double energy = 0.0;
  for (size_t i = count / 2; i < count; ++i)
    energy += static_cast<double>(samples[i]) * samples[i];
  return std::sqrt(energy / (count / 2));
}

double responseDb(int profile, double frequency, double reference = 1000.0) {
  return 20.0 * std::log10(toneRms(profile, frequency, 0.1f) /
                           toneRms(profile, reference, 0.1f));
}

double harmonic(const std::vector<float>& samples, double frequency,
                double rate, size_t begin) {
  double real = 0.0, imag = 0.0;
  const size_t count = samples.size() - begin;
  for (size_t i = 0; i < count; ++i) {
    const double phase = 2.0 * kPi * frequency * i / rate;
    real += samples[begin + i] * std::cos(phase);
    imag -= samples[begin + i] * std::sin(phase);
  }
  return 2.0 * std::sqrt(real * real + imag * imag) / count;
}
} // namespace

int main() {
  int failures = 0;
  auto check = [&](bool ok, const char* label) {
    std::printf("  %s  %s\n", ok ? "PASS" : "FAIL", label);
    if (!ok) ++failures;
  };

  // Existing sessions must be numerically untouched at the default setting.
  std::vector<float> dry(4096), bypass;
  for (size_t i = 0; i < dry.size(); ++i)
    dry[i] = 0.73f * std::sin(2.0 * kPi * 997.0 * i / 48000.0);
  bypass = dry;
  NAMRig::OutputTransformer neutral;
  neutral.process(bypass.data(), bypass.size(), 48000.0,
                  NAMRig::OutputTransformer::kCaptured);
  check(std::memcmp(dry.data(), bypass.data(), dry.size() * sizeof(float)) == 0,
        "Captured / Off is bit-transparent");
  check(NAMRig::OutputTransformer::clampProfile(-100) ==
        NAMRig::OutputTransformer::kCaptured &&
        NAMRig::OutputTransformer::clampProfile(100) ==
            NAMRig::OutputTransformer::kBassIron,
        "profile selection clamps across the expanded range");

  // Small iron has intentionally narrower top-end bandwidth than modern iron.
  const double modernHigh = toneRms(NAMRig::OutputTransformer::kModern, 12000.0);
  const double smallHigh = toneRms(NAMRig::OutputTransformer::kSmallIron, 12000.0);
  check(smallHigh < modernHigh * 0.78,
        "Small Iron rolls off 12 kHz more than Modern Iron");

  // Every neighboring profile needs an audible in-band voicing change after
  // the cabinet has removed the extreme top end. Compare level-independent
  // response signatures at low E / 1 kHz / upper presence.
  double lowDb[4] = {}, highDb[4] = {}, midRms[4] = {};
  for (int p = NAMRig::OutputTransformer::kModern;
       p <= NAMRig::OutputTransformer::kSmallIron; ++p) {
    const int i = p - 1;
    const double low = toneRms(p, 82.0, 0.1f);
    const double mid = toneRms(p, 1000.0, 0.1f);
    const double high = toneRms(p, 4000.0, 0.1f);
    lowDb[i] = 20.0 * std::log10(low / mid);
    highDb[i] = 20.0 * std::log10(high / mid);
    midRms[i] = mid;
    std::printf("        profile %d: low %+.2f dB, presence %+.2f dB, 1k %.4f RMS\n",
                p, lowDb[i], highDb[i], midRms[i]);
  }
  bool separated = true;
  for (int i = 1; i < 4; ++i) {
    const double dl = lowDb[i] - lowDb[i - 1];
    const double dh = highDb[i] - highDb[i - 1];
    separated = separated && std::sqrt(dl * dl + dh * dh) > 1.0;
  }
  check(separated, "every adjacent profile has a distinct in-band response");
  const auto [minLevel, maxLevel] = std::minmax_element(midRms, midRms + 4);
  check(20.0 * std::log10(*maxLevel / *minLevel) < 2.0,
        "profile comparison is level-matched within 2 dB at 1 kHz");

  // Its more strongly driven core should also create more harmonics.
  constexpr double rate = 48000.0;
  constexpr double fundamental = 375.0;  // integer periods in the analysis window
  const size_t begin = 48000;
  double distortion[4] = {};
  for (int p = NAMRig::OutputTransformer::kModern;
       p <= NAMRig::OutputTransformer::kSmallIron; ++p) {
    std::vector<float> driven(96000);
    for (size_t i = 0; i < driven.size(); ++i)
      driven[i] = 0.9f * std::sin(2.0 * kPi * fundamental * i / rate);
    NAMRig::OutputTransformer tx;
    tx.process(driven.data(), driven.size(), rate, p);
    const double h1 = harmonic(driven, fundamental, rate, begin);
    const double higher = harmonic(driven, 2 * fundamental, rate, begin) +
                          harmonic(driven, 3 * fundamental, rate, begin);
    distortion[p - 1] = higher / h1;
    std::printf("        profile %d: H2+H3 %.1f dB below fundamental\n", p,
                20.0 * std::log10(distortion[p - 1]));
  }
  bool progressivelyDriven = true;
  for (int i = 1; i < 4; ++i)
    progressivelyDriven = progressivelyDriven && distortion[i] > distortion[i - 1] * 1.15;
  check(progressivelyDriven,
        "core harmonic intensity increases across the four profiles");

  // Metal profiles are deliberately functional rather than four names for
  // the same curve: tight rhythm, low-tuned clarity, thrash cut and doom bloom.
  const double tightLow = responseDb(NAMRig::OutputTransformer::kTightMetal, 82.0);
  const double tightSub = responseDb(NAMRig::OutputTransformer::kTightMetal, 46.25);
  const double extendedSub =
      responseDb(NAMRig::OutputTransformer::kExtendedRange, 46.25);
  const double tightPresence =
      responseDb(NAMRig::OutputTransformer::kTightMetal, 2850.0);
  const double thrashPresence =
      responseDb(NAMRig::OutputTransformer::kThrashBite, 2850.0);
  const double doomLow = responseDb(NAMRig::OutputTransformer::kDoomIron, 82.0);
  const double doomHigh = responseDb(NAMRig::OutputTransformer::kDoomIron, 4000.0);
  std::printf("        metal: tight low %+.2f dB, tight/extended sub %+.2f/%+.2f dB\n",
              tightLow, tightSub, extendedSub);
  std::printf("        metal: tight/thrash presence %+.2f/%+.2f dB, doom low/high %+.2f/%+.2f dB\n",
              tightPresence, thrashPresence, doomLow, doomHigh);
  check(tightLow < -0.5, "Tight Metal controls palm-mute low end");
  check(extendedSub > tightSub + 2.0,
        "Extended Range retains more low-string fundamental than Tight Metal");
  check(thrashPresence > tightPresence + 0.7,
        "Thrash Bite adds more upper-mid cut than Tight Metal");
  check(doomLow > tightLow + 1.0 && doomHigh < tightPresence - 2.0,
        "Doom Iron is bass-heavier and darker than Tight Metal");

  // The additional profiles cover non-metal jobs that the original set did
  // not: transparent studio use, loose combo bloom, class-A chime and bass.
  const double studioAir =
      responseDb(NAMRig::OutputTransformer::kStudioLinear, 12000.0);
  const double tweedLow =
      responseDb(NAMRig::OutputTransformer::kTweedBloom, 82.0);
  const double tweedPresence =
      responseDb(NAMRig::OutputTransformer::kTweedBloom, 4000.0);
  const double classALow =
      responseDb(NAMRig::OutputTransformer::kClassAChime, 82.0);
  const double classAPresence =
      responseDb(NAMRig::OutputTransformer::kClassAChime, 4000.0);
  const double bassSub =
      responseDb(NAMRig::OutputTransformer::kBassIron, 41.2);
  const double classASub =
      responseDb(NAMRig::OutputTransformer::kClassAChime, 41.2);
  std::printf("        general: studio air %+.2f dB, tweed low/presence %+.2f/%+.2f dB\n",
              studioAir, tweedLow, tweedPresence);
  std::printf("        general: class-A low/presence %+.2f/%+.2f dB, bass sub %+.2f dB\n",
              classALow, classAPresence, bassSub);
  check(studioAir > -1.0,
        "Studio Linear preserves wide-band high-frequency response");
  check(tweedLow > classALow + 1.0 && tweedPresence < classAPresence - 1.0,
        "Tweed Bloom is warmer and darker than Class-A Chime");
  check(classAPresence > 1.0,
        "Class-A Chime provides a clear upper-mid lift");
  check(bassSub > classASub + 3.0,
        "Bass Iron retains substantially more deep fundamental than Class-A Chime");

  // Streaming state must not depend on the host's block boundaries.
  std::vector<float> whole = dry, chunked = dry;
  NAMRig::OutputTransformer a, b;
  a.process(whole.data(), whole.size(), 96000.0,
            NAMRig::OutputTransformer::kUKVintage);
  size_t offset = 0;
  const size_t chunks[] = {1, 17, 64, 511, 7, 1024, 89};
  size_t ci = 0;
  while (offset < chunked.size()) {
    const size_t n = std::min(chunks[ci++ % 7], chunked.size() - offset);
    b.process(chunked.data() + offset, n, 96000.0,
              NAMRig::OutputTransformer::kUKVintage);
    offset += n;
  }
  float worst = 0.0f;
  for (size_t i = 0; i < whole.size(); ++i)
    worst = std::max(worst, std::fabs(whole[i] - chunked[i]));
  check(worst < 1.0e-7f, "processing is invariant to host block boundaries");

  // A pathological hot/DC input must settle without NaN or runaway output.
  bool finite = true;
  float peak = 0.0f;
  for (int p = NAMRig::OutputTransformer::kModern;
       p < NAMRig::OutputTransformer::kProfileCount; ++p) {
    std::vector<float> hot(48000, 20.0f);
    NAMRig::OutputTransformer stressed;
    stressed.process(hot.data(), hot.size(), 48000.0, p);
    for (float x : hot) {
      finite = finite && std::isfinite(x);
      peak = std::max(peak, std::fabs(x));
    }
  }
  check(finite && peak < 25.0f,
        "hot/DC input remains finite and bounded for every profile");

  std::printf(failures ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n",
              failures);
  return failures ? 1 : 0;
}
