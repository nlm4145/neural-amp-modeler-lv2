// Verifies the output-transformer block's design intent.
//
// The block models finite iron: bandwidth limits, a high leakage-inductance
// resonance, a voicing bell, and core saturation in the FLUX domain (a leaky
// integrator, a smooth saturator, then the inverse of that integrator). Flux
// is dominated by low frequencies, so a driven transformer compresses bass
// long before the midrange. The low mechanical resonance belongs to the
// speaker block and the supply behaviour to the power stage, so neither may
// reappear here.
//
// Measurements use ABSOLUTE gain at each frequency. Normalizing by 1 kHz (as
// an earlier revision did) is invalid across profiles: several voicing bells
// sit near 1 kHz, so the reference itself moves and hides real differences.
//
// Build: clang++ -O2 -std=c++17 -Isrc tests/verify_output_transformer.cpp
#include "output_transformer.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

namespace {
constexpr double kPi = 3.14159265358979323846;
using Tx = NAMRig::OutputTransformer;

const char* kNames[Tx::kProfileCount] = {
    "Captured", "Modern", "US Vintage", "UK Vintage", "Small Iron",
    "Tight Metal", "Extended Range", "Thrash Bite", "Doom Iron",
    "Studio Linear", "Tweed Bloom", "Class-A Chime", "Bass Iron"};

// Magnitude of the fundamental, in dB relative to the input amplitude. The
// analysis window is the second half of the run, so the filters have settled.
double gainDb(int profile, double frequency, float amplitude,
              double rate = 48000.0) {
  const size_t count = static_cast<size_t>(rate);
  std::vector<float> samples(count);
  for (size_t i = 0; i < count; ++i)
    samples[i] = amplitude * std::sin(2.0 * kPi * frequency * i / rate);
  Tx transformer;
  transformer.process(samples.data(), count, rate, profile);
  double real = 0.0, imag = 0.0;
  size_t used = 0;
  for (size_t i = count / 2; i < count; ++i) {
    const double phase = 2.0 * kPi * frequency * i / rate;
    real += samples[i] * std::cos(phase);
    imag += samples[i] * std::sin(phase);
    ++used;
  }
  return 20.0 * std::log10(2.0 * std::sqrt(real * real + imag * imag) / used /
                           amplitude);
}

// H2 + H3 relative to the fundamental, in dB. 375 Hz gives whole periods in
// the analysis window at 48 kHz.
double distortionDb(int profile, float amplitude) {
  constexpr double rate = 48000.0;
  constexpr double fundamental = 375.0;
  constexpr size_t count = 96000;
  constexpr size_t begin = 48000;
  std::vector<float> samples(count);
  for (size_t i = 0; i < count; ++i)
    samples[i] = amplitude * std::sin(2.0 * kPi * fundamental * i / rate);
  Tx transformer;
  transformer.process(samples.data(), count, rate, profile);
  const auto harmonic = [&](double frequency) {
    double real = 0.0, imag = 0.0;
    for (size_t i = begin; i < count; ++i) {
      const double phase = 2.0 * kPi * frequency * (i - begin) / rate;
      real += samples[i] * std::cos(phase);
      imag -= samples[i] * std::sin(phase);
    }
    return 2.0 * std::sqrt(real * real + imag * imag) / (count - begin);
  };
  const double h1 = harmonic(fundamental);
  const double higher = harmonic(2.0 * fundamental) + harmonic(3.0 * fundamental);
  return 20.0 * std::log10(higher / std::max(h1, 1.0e-12));
}

int failures = 0;
void check(bool ok, const char* label) {
  std::printf("  %s  %s\n", ok ? "PASS" : "FAIL", label);
  if (!ok) ++failures;
}
} // namespace

int main() {
  // ---- Existing sessions must be numerically untouched at the default. ----
  std::vector<float> dry(4096);
  for (size_t i = 0; i < dry.size(); ++i)
    dry[i] = 0.73f * std::sin(2.0 * kPi * 997.0 * i / 48000.0);
  std::vector<float> bypass = dry;
  Tx neutral;
  neutral.process(bypass.data(), bypass.size(), 48000.0, Tx::kCaptured);
  check(std::memcmp(dry.data(), bypass.data(), dry.size() * sizeof(float)) == 0,
        "Captured / Off is bit-transparent");
  check(Tx::clampProfile(-100) == Tx::kCaptured &&
            Tx::clampProfile(100) == Tx::kBassIron,
        "profile selection clamps across the expanded range");

  // ---- Small-signal response signature per profile. ----
  constexpr double kFreqs[] = {41.2, 82.0, 300.0, 1000.0, 2850.0, 4000.0, 12000.0};
  constexpr size_t kFreqCount = sizeof(kFreqs) / sizeof(kFreqs[0]);
  double small[Tx::kProfileCount][kFreqCount] = {};
  double hot82[Tx::kProfileCount] = {};
  double hot1k[Tx::kProfileCount] = {};
  double thdQuiet[Tx::kProfileCount] = {};
  double thdHot[Tx::kProfileCount] = {};

  std::printf("\n        small-signal absolute gain (dB) and drive:\n");
  std::printf("        %-14s %7s %7s %7s %7s %7s %7s %7s | %8s %8s\n",
              "profile", "41Hz", "82Hz", "300Hz", "1kHz", "2.85k", "4kHz",
              "12kHz", "THD@-34", "THD@-1");
  for (int p = Tx::kModern; p < Tx::kProfileCount; ++p) {
    for (size_t f = 0; f < kFreqCount; ++f)
      small[p][f] = gainDb(p, kFreqs[f], 0.02f);
    hot82[p] = gainDb(p, 82.0, 0.9f);
    hot1k[p] = gainDb(p, 1000.0, 0.9f);
    thdQuiet[p] = distortionDb(p, 0.02f);
    thdHot[p] = distortionDb(p, 0.9f);
    std::printf("        %-14s %+7.2f %+7.2f %+7.2f %+7.2f %+7.2f %+7.2f %+7.2f | %8.1f %8.1f\n",
                kNames[p], small[p][0], small[p][1], small[p][2], small[p][3],
                small[p][4], small[p][5], small[p][6], thdQuiet[p], thdHot[p]);
  }

  // Profiles are voicings, not level changes: the makeup keeps them within a
  // couple of dB at 1 kHz so A/B comparison is honest.
  double minMid = 1.0e9, maxMid = -1.0e9;
  for (int p = Tx::kModern; p < Tx::kProfileCount; ++p) {
    minMid = std::min(minMid, small[p][3]);
    maxMid = std::max(maxMid, small[p][3]);
  }
  check(maxMid - minMid < 2.5,
        "every profile is level-matched within 2.5 dB at 1 kHz");

  // The low mechanical resonance moved to the speaker block. No profile may
  // lift the 40-120 Hz region above its own 300 Hz level.
  bool noLowResonance = true;
  for (int p = Tx::kModern; p < Tx::kProfileCount; ++p)
    noLowResonance = noLowResonance && small[p][1] <= small[p][2] + 0.25 &&
                     small[p][0] <= small[p][2] + 0.25;
  check(noLowResonance,
        "no profile adds a low resonance (that belongs to the speaker block)");

  // ---- Bandwidth ordering follows each profile's low cut / high cut. ----
  check(small[Tx::kSmallIron][6] < small[Tx::kModern][6] - 6.0,
        "Small Iron rolls off 12 kHz far more than Modern Iron");
  check(small[Tx::kStudioLinear][0] > small[Tx::kUKVintage][0] + 2.0 &&
            small[Tx::kUKVintage][0] > small[Tx::kSmallIron][0] + 2.0,
        "low-frequency extension orders Studio > UK Vintage > Small Iron");
  check(small[Tx::kStudioLinear][6] > -1.0,
        "Studio Linear preserves wide-band high-frequency response");

  // ---- Every adjacent profile is a distinct object. ----
  // Response alone is not the whole design: Modern and Studio Linear are
  // deliberately close curves that differ in core drive. The signature
  // therefore includes distortion, scaled so 4 dB of THD counts like 1 dB of
  // response.
  bool separated = true;
  for (int p = Tx::kModern + 1; p < Tx::kProfileCount; ++p) {
    double sum = 0.0;
    for (size_t f = 0; f < kFreqCount; ++f) {
      const double d = small[p][f] - small[p - 1][f];
      sum += d * d;
    }
    const double drive = (thdHot[p] - thdHot[p - 1]) * 0.25;
    sum += drive * drive;
    separated = separated && std::sqrt(sum) > 1.5;
  }
  check(separated,
        "every adjacent profile differs audibly in response or core drive");

  // ---- Core drive is progressive across the four original profiles. ----
  bool progressive = true;
  for (int p = Tx::kUSVintage; p <= Tx::kSmallIron; ++p)
    progressive = progressive && thdHot[p] > thdHot[p - 1] + 1.2;
  check(progressive,
        "core harmonic intensity rises Modern -> US -> UK -> Small Iron");
  check(thdHot[Tx::kStudioLinear] < thdHot[Tx::kModern] - 1.0,
        "Studio Linear stays cleaner than Modern Iron when driven");

  // ---- Flux-domain saturation: bass compresses before the midrange. ----
  // This is the whole point of integrating to flux before the saturator. A
  // waveshaper placed directly in the voltage path cannot do this.
  std::printf("\n        level-dependent gain change from -34 dBFS to -1 dBFS:\n");
  bool bassCompresses = true;
  for (int p = Tx::kModern; p < Tx::kProfileCount; ++p) {
    const double bass = hot82[p] - small[p][1];
    const double mid = hot1k[p] - small[p][3];
    std::printf("        %-14s 82 Hz %+6.2f dB, 1 kHz %+6.2f dB\n", kNames[p],
                bass, mid);
    bassCompresses = bassCompresses && bass < mid - 0.3;
  }
  check(bassCompresses,
        "every profile compresses 82 Hz more than 1 kHz when driven");
  check(hot82[Tx::kDoomIron] - small[Tx::kDoomIron][1] < -3.0,
        "Doom Iron's core bloom compresses palm-muted bass by over 3 dB");
  check(std::fabs(hot82[Tx::kStudioLinear] - small[Tx::kStudioLinear][1]) < 1.0,
        "Studio Linear keeps its low end nearly linear at full level");

  // ---- Named profiles behave the way their names promise. ----
  check(small[Tx::kTightMetal][0] < small[Tx::kModern][0] - 3.0,
        "Tight Metal controls palm-mute low end");
  check(small[Tx::kExtendedRange][0] > small[Tx::kTightMetal][0] + 2.0,
        "Extended Range retains more low-string fundamental than Tight Metal");
  check(small[Tx::kThrashBite][4] > small[Tx::kTightMetal][4] + 0.7,
        "Thrash Bite adds more upper-mid cut than Tight Metal");
  check(small[Tx::kDoomIron][0] > small[Tx::kTightMetal][0] + 2.0 &&
            small[Tx::kDoomIron][6] < small[Tx::kTightMetal][6] - 4.0,
        "Doom Iron is bass-heavier and darker than Tight Metal");
  check(small[Tx::kTweedBloom][0] > small[Tx::kClassAChime][0] + 1.0 &&
            small[Tx::kTweedBloom][6] < small[Tx::kClassAChime][6] - 4.0,
        "Tweed Bloom is warmer and darker than Class-A Chime");
  check(small[Tx::kClassAChime][5] > 1.0,
        "Class-A Chime provides a clear upper-mid lift");
  check(small[Tx::kBassIron][0] > small[Tx::kClassAChime][0] + 3.0,
        "Bass Iron retains substantially more deep fundamental than Class-A");

  // ---- Streaming state must not depend on the host's block boundaries. ----
  std::vector<float> whole = dry, chunked = dry;
  Tx a, b;
  a.process(whole.data(), whole.size(), 96000.0, Tx::kUKVintage);
  size_t offset = 0;
  const size_t chunks[] = {1, 17, 64, 511, 7, 1024, 89};
  size_t index = 0;
  while (offset < chunked.size()) {
    const size_t n = std::min(chunks[index++ % 7], chunked.size() - offset);
    b.process(chunked.data() + offset, n, 96000.0, Tx::kUKVintage);
    offset += n;
  }
  float worst = 0.0f;
  for (size_t i = 0; i < whole.size(); ++i)
    worst = std::max(worst, std::fabs(whole[i] - chunked[i]));
  check(worst < 1.0e-7f, "processing is invariant to host block boundaries");

  // ---- Pathological input must settle without NaN or runaway. ----
  bool finite = true;
  float peak = 0.0f;
  for (int p = Tx::kModern; p < Tx::kProfileCount; ++p) {
    std::vector<float> hot(48000, 20.0f);
    Tx stressed;
    stressed.process(hot.data(), hot.size(), 48000.0, p);
    for (float x : hot) {
      finite = finite && std::isfinite(x);
      peak = std::max(peak, std::fabs(x));
    }
  }
  check(finite && peak < 25.0f,
        "hot/DC input remains finite and bounded for every profile");

  // ---- True 8x domain (up to 768 kHz). ----
  bool highRateFinite = true;
  bool highRateAudible = true;
  for (int p = Tx::kModern; p < Tx::kProfileCount; ++p) {
    constexpr double highRate = 768000.0;
    std::vector<float> signal(76800);
    for (size_t i = 0; i < signal.size(); ++i)
      signal[i] = 0.2f * std::sin(2.0 * kPi * 997.0 * i / highRate);
    Tx transformer;
    transformer.process(signal.data(), signal.size(), highRate, p);
    double energy = 0.0;
    for (size_t i = signal.size() / 2; i < signal.size(); ++i) {
      highRateFinite = highRateFinite && std::isfinite(signal[i]);
      energy += static_cast<double>(signal[i]) * signal[i];
    }
    highRateAudible =
        highRateAudible && std::sqrt(energy / (signal.size() / 2)) > 0.05;
  }
  check(highRateFinite && highRateAudible,
        "every profile remains finite and audible in a True 8x domain");

  // NAM captures can emit appreciable DC. At 768 kHz the poles of a 7 Hz
  // high-pass sit extremely close to the unit circle; the stage DC blockers
  // upstream should keep this benign, but the block must survive it alone.
  bool dcFinite = true;
  bool dcBounded = true;
  for (int p = Tx::kModern; p < Tx::kProfileCount; ++p) {
    constexpr double highRate = 768000.0;
    std::vector<float> signal(768000, 0.2f);
    Tx transformer;
    transformer.process(signal.data(), signal.size(), highRate, p);
    float profilePeak = 0.0f;
    for (float x : signal) {
      dcFinite = dcFinite && std::isfinite(x);
      profilePeak = std::max(profilePeak, std::fabs(x));
    }
    dcBounded = dcBounded && profilePeak < 1.0f;
  }
  check(dcFinite && dcBounded,
        "DC remains finite and bounded in a True 8x domain");

  std::printf(failures ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n",
              failures);
  return failures ? 1 : 0;
}
