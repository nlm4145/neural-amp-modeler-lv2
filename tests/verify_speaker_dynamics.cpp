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

  std::printf(failures ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n",
              failures);
  return failures ? 1 : 0;
}
