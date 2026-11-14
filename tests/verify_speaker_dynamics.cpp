// Verifies the speaker load block.
//
// A guitar speaker presents two impedance features to the amp: the low
// mechanical resonance and the rising voice-coil inductance above roughly
// 1.5 kHz. A tube output stage follows that curve in proportion to its own
// output impedance, so the power amp's negative feedback (damping) flattens
// BOTH features. Cone and suspension nonlinearity acts on excursion, so
// Speaker Drive must saturate the low band only.
//
// Build: clang++ -O2 -std=c++17 -Isrc tests/verify_speaker_dynamics.cpp
#include "speaker_dynamics.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>

namespace {
constexpr double kPi = 3.14159265358979323846;
using Spk = NAMRig::SpeakerDynamics;

const char* kNames[Spk::kProfileCount] = {
    "Captured", "Auto", "Resistive", "Open Back", "Vintage Alnico",
    "UK 4x12", "Modern 4x12", "Bass"};

// Each profile's low resonance frequency, mirroring kProfiles_.
constexpr double kResonanceHz[Spk::kProfileCount] = {80, 80, 95, 92, 105,
                                                     118, 82, 58};

std::vector<float> program(size_t count, double rate) {
  std::vector<float> x(count);
  for (size_t i = 0; i < count; ++i) {
    const double t = i / rate;
    x[i] = static_cast<float>(0.34 * std::sin(2.0 * kPi * 82.0 * t) +
                              0.17 * std::sin(2.0 * kPi * 220.0 * t) +
                              0.08 * std::sin(2.0 * kPi * 3100.0 * t));
  }
  return x;
}

double difference(const std::vector<float>& a, const std::vector<float>& b) {
  double sum = 0.0;
  for (size_t i = 0; i < a.size(); ++i) sum += std::fabs(a[i] - b[i]);
  return sum;
}

// Fundamental gain in dB at one frequency, after the filters have settled.
double gainDb(int profile, double frequency, float amplitude, float drive,
              float compression, float thump, float resonance, float damping,
              double rate = 96000.0) {
  const size_t count = static_cast<size_t>(rate * 0.5);
  std::vector<float> samples(count);
  for (size_t i = 0; i < count; ++i)
    samples[i] = amplitude * std::sin(2.0 * kPi * frequency * i / rate);
  Spk speaker;
  speaker.process(samples.data(), count, rate, profile, drive, compression,
                  thump, resonance, damping);
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

int failures = 0;
void check(bool ok, const char* label) {
  std::printf("  %s  %s\n", ok ? "PASS" : "FAIL", label);
  if (!ok) ++failures;
}
} // namespace

int main() {
  // ---- Captured / Off is an exact bypass at any rate. ----
  for (double rate : {48000.0, 768000.0}) {
    auto input = program(8192, rate);
    auto output = input;
    Spk speaker;
    speaker.process(output.data(), output.size(), rate, Spk::kCaptured,
                    100.0f, 100.0f, 100.0f, 100.0f, 0.0f);
    check(std::memcmp(input.data(), output.data(),
                      input.size() * sizeof(float)) == 0,
          rate < 100000.0 ? "Captured/Off is bit-exact at 48 kHz"
                          : "Captured/Off is bit-exact at 768 kHz");
  }
  // Auto is resolved to a concrete profile by the caller, so the block itself
  // must also treat it as a bypass rather than guessing.
  {
    auto input = program(4096, 96000.0);
    auto output = input;
    Spk speaker;
    speaker.process(output.data(), output.size(), 96000.0, Spk::kAuto,
                    100.0f, 100.0f, 100.0f, 100.0f, 1.0f);
    check(std::memcmp(input.data(), output.data(),
                      input.size() * sizeof(float)) == 0,
          "unresolved Auto is bit-exact (the DSP resolves it before calling)");
  }

  // ---- Stability across every profile and rate. ----
  bool stable = true;
  for (int profile = Spk::kResistive; profile < Spk::kProfileCount; ++profile) {
    for (double rate : {48000.0, 96000.0, 768000.0}) {
      auto output = program(16384, rate);
      Spk speaker;
      speaker.process(output.data(), output.size(), rate, profile,
                      100.0f, 100.0f, 100.0f, 100.0f, 0.0f);
      float peak = 0.0f;
      for (float x : output) {
        stable = stable && std::isfinite(x);
        peak = std::max(peak, std::fabs(x));
      }
      stable = stable && peak < 4.0f;
    }
  }
  check(stable, "every profile stays finite and bounded at 48/96/768 kHz");

  // ---- Zero amounts leave an enabled profile exactly neutral. ----
  auto input = program(32768, 96000.0);
  auto mild = input, strong = input;
  Spk a, b;
  a.process(mild.data(), mild.size(), 96000.0, Spk::kModern412,
            0.0f, 0.0f, 0.0f, 0.0f, 0.0f);
  b.process(strong.data(), strong.size(), 96000.0, Spk::kModern412,
            100.0f, 100.0f, 100.0f, 100.0f, 0.0f);
  check(difference(input, mild) < 1.0e-6,
        "zero amounts leave an enabled profile neutral");
  check(difference(input, strong) > 10.0,
        "speaker controls audibly alter the signal");

  // ---- The impedance curve has BOTH a low resonance and an HF rise. ----
  std::printf("\n        impedance curve at Resonance 100%%, damping 0 vs 1 (dB):\n");
  std::printf("        %-15s %15s %15s %15s\n", "profile", "resonance",
              "500 Hz", "6 kHz");
  bool hasCurve = true;
  bool dampingFlattens = true;
  for (int p = Spk::kResistive; p < Spk::kProfileCount; ++p) {
    const double lowFree = gainDb(p, kResonanceHz[p], 0.05f, 0, 0, 0, 100, 0);
    const double lowDamped = gainDb(p, kResonanceHz[p], 0.05f, 0, 0, 0, 100, 1);
    const double midFree = gainDb(p, 500.0, 0.05f, 0, 0, 0, 100, 0);
    const double midDamped = gainDb(p, 500.0, 0.05f, 0, 0, 0, 100, 1);
    const double highFree = gainDb(p, 6000.0, 0.05f, 0, 0, 0, 100, 0);
    const double highDamped = gainDb(p, 6000.0, 0.05f, 0, 0, 0, 100, 1);
    std::printf("        %-15s %+6.2f/%+6.2f %+6.2f/%+6.2f %+6.2f/%+6.2f\n",
                kNames[p], lowFree, lowDamped, midFree, midDamped, highFree,
                highDamped);
    // Both features must sit above the 500 Hz reference.
    hasCurve = hasCurve && lowFree > midFree + 0.25 && highFree > midFree + 0.5;
    // Full damping must at least halve each feature, in dB.
    dampingFlattens = dampingFlattens &&
                      lowDamped < lowFree * 0.65 + 1.0e-6 &&
                      highDamped < highFree * 0.65 + 1.0e-6;
  }
  check(hasCurve,
        "every profile has both a low resonance and a rising HF inductance");
  check(dampingFlattens,
        "Negative Feedback damping flattens both ends of the curve");
  check(gainDb(Spk::kUK412, 118.0, 0.05f, 0, 0, 0, 100, 0) >
            gainDb(Spk::kResistive, 95.0, 0.05f, 0, 0, 0, 100, 0) + 2.0,
        "UK 4x12 has a far stronger resonance than the Resistive load");

  // ---- Speaker Drive saturates excursion (the low band) only. ----
  std::printf("\n        Speaker Drive 100%% gain change at -3 dBFS (dB):\n");
  bool lowBandOnly = true;
  for (int p = Spk::kResistive; p < Spk::kProfileCount; ++p) {
    const double low = gainDb(p, 80.0, 0.7f, 100, 0, 0, 0, 0) -
                       gainDb(p, 80.0, 0.7f, 0, 0, 0, 0, 0);
    const double high = gainDb(p, 4000.0, 0.7f, 100, 0, 0, 0, 0) -
                        gainDb(p, 4000.0, 0.7f, 0, 0, 0, 0, 0);
    std::printf("        %-15s 80 Hz %+6.2f, 4 kHz %+6.2f\n", kNames[p], low,
                high);
    lowBandOnly = lowBandOnly && low < -0.25 && std::fabs(high) < 0.05;
  }
  check(lowBandOnly,
        "Speaker Drive compresses the excursion band and leaves 4 kHz alone");

  // ---- Excursion compression is level dependent and damps the resonance. ----
  std::printf("\n        Compression 100%% at the resonance, quiet vs loud (dB):\n");
  bool levelDependent = true;
  for (int p = Spk::kResistive; p < Spk::kProfileCount; ++p) {
    const double quiet = gainDb(p, kResonanceHz[p], 0.05f, 0, 100, 0, 100, 0);
    const double loud = gainDb(p, kResonanceHz[p], 0.9f, 0, 100, 0, 100, 0);
    std::printf("        %-15s quiet %+6.2f, loud %+6.2f\n", kNames[p], quiet,
                loud);
    levelDependent = levelDependent && loud < quiet - 1.0;
  }
  check(levelDependent,
        "excursion compression lowers the resonance as level rises");
  check(gainDb(Spk::kUK412, 60.0, 0.05f, 0, 0, 100, 0, 0) > 0.5,
        "Thump lifts the sub-resonance excursion region");

  // ---- Block-boundary invariance. ----
  auto whole = program(32768, 96000.0), chunked = whole;
  Spk wholeSpeaker, chunkedSpeaker;
  wholeSpeaker.process(whole.data(), whole.size(), 96000.0, Spk::kOpenBack,
                       70.0f, 65.0f, 80.0f, 75.0f, 0.4f);
  const size_t chunks[] = {1, 7, 64, 3, 511, 29, 128};
  size_t offset = 0, chunk = 0;
  while (offset < chunked.size()) {
    const size_t n = std::min(chunks[chunk++ % 7], chunked.size() - offset);
    chunkedSpeaker.process(chunked.data() + offset, n, 96000.0, Spk::kOpenBack,
                           70.0f, 65.0f, 80.0f, 75.0f, 0.4f);
    offset += n;
  }
  check(difference(whole, chunked) < 1.0e-5,
        "processing is invariant to host block boundaries");

  // ---- Auto profile matching works on whole tokens. ----
  check(Spk::profileFromCabPath("/IRs/Mesa Oversized V30.wav") == Spk::kModern412,
        "Auto associates Mesa/V30 cabinets with Modern 4x12");
  check(Spk::profileFromCabPath("/IRs/Marshall Greenback G12M.wav") == Spk::kUK412,
        "Auto associates Greenback cabinets with UK 4x12");
  check(Spk::profileFromCabPath("/IRs/Celestion Blue Alnico.wav") ==
            Spk::kVintageAlnico,
        "Auto precedence selects Vintage Alnico");
  check(Spk::profileFromCabPath("/IRs/unknown.wav") == Spk::kResistive,
        "Auto falls back to Resistive");
  // Substring matching used to fire on "blue" inside "Bluesbreaker" and on
  // "bass" inside unrelated words. Matching whole tokens fixes both.
  check(Spk::profileFromCabPath("/IRs/Bluesbreaker 2x12 G12M.wav") == Spk::kUK412,
        "'Bluesbreaker' does not match the 'blue' alnico token");
  check(Spk::profileFromCabPath("/IRs/Bassbreaker Combo.wav") == Spk::kOpenBack,
        "'Bassbreaker' does not match the 'bass' cabinet token");
  // Only the file name matters; a directory name must not decide the profile.
  check(Spk::profileFromCabPath("/Users/bass/IRs/Marshall 1960.wav") == Spk::kUK412,
        "a parent directory name cannot override the cabinet file name");

  // ---- LR2 crossover IMD & quiet allpass flatness ----
  {
    const double fs = 48000.0;
    const size_t count = 48000;
    std::vector<float> twoTone(count);
    for (size_t i = 0; i < count; ++i) {
      const double t = i / fs;
      twoTone[i] = static_cast<float>(0.40 * std::sin(2.0 * kPi * 82.4 * t) +
                                      0.20 * std::sin(2.0 * kPi * 2400.0 * t));
    }
    Spk spk;
    spk.process(twoTone.data(), twoTone.size(), fs, Spk::kUK412, 100.0f, 0.0f, 0.0f, 0.0f, 0.0f);
    const auto dftAmp = [&](double f) {
      double re = 0.0, im = 0.0;
      const size_t start = count / 2;
      for (size_t i = start; i < count; ++i) {
        const double ph = 2.0 * kPi * f * i / fs;
        re += twoTone[i] * std::cos(ph);
        im += twoTone[i] * std::sin(ph);
      }
      const double n = static_cast<double>(count - start);
      return 2.0 * std::hypot(re, im) / n;
    };
    const double carrier = dftAmp(2400.0);
    const double imd = std::max(dftAmp(2400.0 - 82.4), dftAmp(2400.0 + 82.4));
    const double imdDb = 20.0 * std::log10(std::max(1.0e-12, imd) / std::max(1.0e-12, carrier));
    std::printf("\n        LR2 two-tone IMD (82.4 Hz + 2.4 kHz @ 48 kHz): %.2f dBc\n", imdDb);
    check(imdDb < -45.0, "LR2 crossover suppresses upper-band IMD below -45 dBc");
  }

  // ---- Asymmetric excursion H2 + DC balance ----
  {
    const double fs = 48000.0;
    const size_t count = 48000;
    std::vector<float> tone(count);
    for (size_t i = 0; i < count; ++i)
      tone[i] = 0.7f * std::sin(2.0 * kPi * 80.0 * i / fs);
    Spk spk;
    spk.process(tone.data(), tone.size(), fs, Spk::kVintageAlnico, 100.0f, 0.0f, 0.0f, 0.0f, 0.0f);
    const size_t start = count / 2;
    double dc = 0.0;
    const auto harmAmp = [&](int k) {
      double re = 0.0, im = 0.0;
      for (size_t i = start; i < count; ++i) {
        const double ph = 2.0 * kPi * (80.0 * k) * i / fs;
        re += tone[i] * std::cos(ph);
        im += tone[i] * std::sin(ph);
      }
      return 2.0 * std::hypot(re, im) / static_cast<double>(count - start);
    };
    for (size_t i = start; i < count; ++i) dc += tone[i];
    dc /= static_cast<double>(count - start);
    const double h1 = harmAmp(1), h2 = harmAmp(2), h3 = harmAmp(3);
    const double h2Db = 20.0 * std::log10(std::max(1.0e-12, h2) / h1);
    const double h3Db = 20.0 * std::log10(std::max(1.0e-12, h3) / h1);
    std::printf("        Vintage Alnico 80 Hz harmonics: H2 %.1f dBc, H3 %.1f dBc, DC %.2e\n",
                h2Db, h3Db, dc);
    check(h2Db > -45.0 && h2Db < -20.0 && h3Db > -40.0,
          "asymmetric excursion produces warm H2 even harmonics alongside H3");
    check(std::fabs(dc) < 1.0e-5, "asymmetric saturation residual is DC-balanced");
  }

  // ---- Upper-mid cone modal breakup & 48 kHz alias suppression ----
  {
    const double coneGainDelta = gainDb(Spk::kUK412, 1600.0, 0.7f, 100, 0, 0, 0, 0, 48000.0) -
                                 gainDb(Spk::kUK412, 1600.0, 0.7f, 0, 0, 0, 0, 0, 48000.0);
    std::printf("        UK 4x12 cone breakup (1.6 kHz @ -3 dBFS): %+.2f dB\n", coneGainDelta);
    check(coneGainDelta < -0.35, "upper-mid cone breakup softly compresses near 1.6 kHz");

    const double fs = 48000.0;
    const size_t count = 32768;
    const double f0 = 1553.0;
    std::vector<float> tone(count);
    for (size_t i = 0; i < count; ++i)
      tone[i] = static_cast<float>(0.9 * std::sin(2.0 * kPi * f0 * i / fs));
    Spk spk;
    spk.process(tone.data(), tone.size(), fs, Spk::kVintageAlnico, 100.0f, 0.0f, 0.0f, 0.0f, 0.0f);
    const size_t start = count / 2;
    const auto binAmp = [&](double f) {
      double re = 0.0, im = 0.0;
      for (size_t i = start; i < count; ++i) {
        const double ph = 2.0 * kPi * f * i / fs;
        re += tone[i] * std::cos(ph);
        im += tone[i] * std::sin(ph);
      }
      return 2.0 * std::hypot(re, im) / static_cast<double>(count - start);
    };
    const double h1 = binAmp(f0);
    double worstAlias = 0.0;
    for (int k = 2; k <= 34; ++k) {
      const double fa = std::fabs(k * f0 - std::round(k * f0 / fs) * fs);
      if (fa < 50.0 || fa > 16000.0) continue;
      bool isHarm = false;
      for (int h = 1; h <= 10; ++h)
        if (std::fabs(fa - h * f0) < 50.0) isHarm = true;
      if (!isHarm) worstAlias = std::max(worstAlias, binAmp(fa));
    }
    const double aliasDb = 20.0 * std::log10(std::max(1.0e-12, worstAlias) / h1);
    std::printf("        48 kHz 2x ADAA worst audible alias (1553 Hz): %.1f dBc\n", aliasDb);
    check(aliasDb < -38.0, "2x ADAA keeps 48 kHz aliasing well controlled");
  }

  // ---- Click-free Drive sweep across 0% <-> 25% ----
  {
    const double fs = 48000.0;
    Spk spk;
    float prev = 0.0f;
    double maxStep = 0.0;
    size_t idx = 0;
    for (int seg = 0; seg < 4; ++seg) {
      const float drv = (seg == 0 || seg == 2) ? 25.0f : 0.0f;
      std::vector<float> blk(512);
      for (size_t i = 0; i < blk.size(); ++i, ++idx)
        blk[i] = static_cast<float>(0.5 * std::sin(2.0 * kPi * 220.0 * idx / fs));
      spk.process(blk.data(), blk.size(), fs, Spk::kUK412, drv, 0.0f, 0.0f, 0.0f, 0.0f);
      for (size_t i = 0; i < blk.size(); ++i) {
        if (idx > 64) maxStep = std::max(maxStep, static_cast<double>(std::fabs(blk[i] - prev)));
        prev = blk[i];
      }
    }
    check(maxStep < 0.03, "Drive 25% <-> 0% automation sweep stays click-free");
  }

  // ---- Regression: cold 0% -> 25% & post-decay 25% -> 0% -> 25% stay click-free. ----
  // Exercises LR2 crossover engagement at both 220 Hz and 2400 Hz with no initial
  // sample skip (prevents polarity-inversion click on sample 0 of Drive > 0%).
  for (double testFreq : {220.0, 2400.0}) {
    const double fs = 48000.0;
    const double naturalStep = 0.5 * 2.0 * kPi * testFreq / fs;
    Spk spk;
    float prev = 0.0f;
    double maxDiff = 0.0;
    size_t idx = 0;
    const int lengths[] = {512, 512, 16384, 512};
    const float drives[] = {0.0f, 25.0f, 0.0f, 25.0f};
    for (int seg = 0; seg < 4; ++seg) {
      std::vector<float> blk(static_cast<size_t>(lengths[seg]));
      for (size_t i = 0; i < blk.size(); ++i, ++idx)
        blk[i] = static_cast<float>(0.5 * std::sin(2.0 * kPi * testFreq * idx / fs));
      spk.process(blk.data(), blk.size(), fs, Spk::kUK412,
                  drives[seg], 0.0f, 0.0f, 0.0f, 0.0f);
      for (size_t i = 0; i < blk.size(); ++i) {
        const size_t globalIdx = idx - blk.size() + i;
        if (globalIdx > 0)
          maxDiff = std::max(maxDiff, static_cast<double>(std::fabs(blk[i] - prev)));
        prev = blk[i];
      }
    }
    char label[128];
    std::snprintf(label, sizeof(label),
                  "cold & decayed 0%% -> 25%% Drive transition is click-free at %.0f Hz",
                  testFreq);
    check(maxDiff < naturalStep + 0.025, label);
  }

  // ---- NaN / Inf parameter & sampleRate safety ----
  {
    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float inf = std::numeric_limits<float>::infinity();
    Spk spk;
    std::vector<float> blk(256);
    for (size_t i = 0; i < blk.size(); ++i)
      blk[i] = static_cast<float>(0.25 * std::sin(2.0 * kPi * 220.0 * i / 48000.0));
    spk.process(blk.data(), blk.size(), nan, -99, nan, inf, -nan, inf, nan);
    bool allFinite = true;
    for (float s : blk) allFinite = allFinite && std::isfinite(s);
    // Recover on a normal valid block to confirm no internal state became NaN.
    for (size_t i = 0; i < blk.size(); ++i)
      blk[i] = static_cast<float>(0.25 * std::sin(2.0 * kPi * 220.0 * i / 48000.0));
    spk.process(blk.data(), blk.size(), 48000.0, Spk::kUK412,
                50.0f, 50.0f, 50.0f, 50.0f, 0.5f);
    for (float s : blk) allFinite = allFinite && std::isfinite(s);
    check(allFinite, "NaN/Inf parameters and sampleRate stay finite and recoverable");
  }

  // ---- Profile names and descriptions. ----
  bool descriptionsValid = true;
  for (int p = 0; p < Spk::kProfileCount; ++p) {
    const char* name = Spk::profileName(p);
    const char* desc = Spk::profileDescription(p);
    descriptionsValid = descriptionsValid && name != nullptr && std::strlen(name) > 0 &&
                        desc != nullptr && std::strlen(desc) > 0;
  }
  check(descriptionsValid && Spk::clampProfileB(99) == Spk::kMatchCabA &&
            std::strcmp(Spk::profileBName(Spk::kMatchCabA), "Match Cab A") == 0,
        "every profile has a non-empty name/description and Cab B supports Match Cab A");
  check(std::strstr(Spk::profileDescription(Spk::kResistive), "Resistive") != nullptr &&
        std::strstr(Spk::profileDescription(Spk::kResistive), "dummy load") != nullptr,
        "Resistive description contains 'Resistive' and 'dummy load'");

  std::printf(failures ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n",
              failures);
  return failures ? 1 : 0;
}
