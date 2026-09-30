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
#include <limits>
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

// Independent reference of the pre-edit processing path. Keep the original
// arithmetic order so neutral trims must reproduce factory audio bit-for-bit.
std::vector<float> factoryReference(std::vector<float> samples, double rate, int profile) {
  if (profile == Tx::kCaptured) return samples;
  const auto p = Tx::parametersForProfile(profile);
  struct Filter {
    double b0, b1, b2, a1, a2, z1 = 0, z2 = 0;
    double process(double x) {
      const double y = b0 * x + z1;
      z1 = b1 * x - a1 * y + z2;
      z2 = b2 * x - a2 * y;
      return y;
    }
  };
  const auto cut = [&](double hz, bool highPass) {
    const double w = 2.0 * kPi * hz / rate;
    const double c = std::cos(w), s = std::sin(w);
    const double alpha = s / (2.0 * 0.7071067811865476), a0 = 1.0 + alpha;
    const double b0 = (highPass ? 1.0 + c : 1.0 - c) * 0.5 / a0;
    return Filter{b0, (highPass ? -(1.0 + c) : 1.0 - c) / a0,
                  b0, -2.0 * c / a0, (1.0 - alpha) / a0};
  };
  const auto bell = [&](double hz, double db, double q) {
    const double A = std::pow(10.0, db / 40.0), w = 2.0 * kPi * hz / rate;
    const double c = std::cos(w), s = std::sin(w);
    const double alpha = s / (2.0 * q), a0 = 1.0 + alpha / A;
    return Filter{(1.0 + alpha * A) / a0, -2.0 * c / a0,
                  (1.0 - alpha * A) / a0, -2.0 * c / a0,
                  (1.0 - alpha / A) / a0};
  };
  auto hp = cut(p.lowCutHz, true), lp = cut(std::min(p.highCutHz, rate * 0.42), false);
  auto voice = bell(p.voiceHz, p.voiceDb, p.voiceQ);
  auto leak = bell(std::min(p.leakageHz, rate * 0.42 * 0.9), p.leakageDb, p.leakageQ);
  const double coeff = 1.0 - std::exp(-2.0 * kPi * p.fluxHz / rate);
  const auto sigmoid = [](double x) { return x / std::sqrt(1.0 + x * x); };
  double flux = 0, saturatedFlux = 0;
  for (float& sample : samples) {
    const double x = voice.process(hp.process(sample));
    flux += coeff * (x - flux);
    const double saturated = (sigmoid(p.drive * flux + p.asymmetry) -
                              sigmoid(p.asymmetry)) / p.drive;
    const double core = (saturated - (1.0 - coeff) * saturatedFlux) / coeff;
    saturatedFlux = saturated;
    sample = static_cast<float>(lp.process(leak.process(
        x + p.saturationMix * (core - x))) * p.makeup);
  }
  return samples;
}

void verifyAdjustments() {
  using NAMRig::TransformerAdjustments;
  const auto defaults = NAMRig::kTransformerControlDefaults;
  const double expected[Tx::kProfileCount][13] = {
      {5,24000,9000,0,1,2500,0,.707,90,1,0,0,1},
      {10,22000,8500,.60,1.20,3200,.50,.65,90,1.60,.24,0,1.020},
      {18,17500,7000,1.20,1.10,1750,-1.20,.68,105,2.20,.38,.025,1.080},
      {40,10500,5600,1.80,1,2400,1.75,.82,130,3.25,.52,.040,1},
      {68,7500,4200,2.40,.90,1050,2.20,.72,165,4.80,.68,.065,.930},
      {58,18000,7800,1,1.20,3400,1.80,.78,115,2.30,.32,.012,1.030},
      {30,20000,8200,.70,1.20,4200,1.25,.74,78,1.90,.27,.010,1.020},
      {72,14000,6500,1.60,1.10,2850,2.75,.88,150,3,.44,.028,1.010},
      {22,8500,4600,2,.90,950,1.90,.75,95,4.50,.70,.060,.940},
      {7,23000,9500,.40,1.30,4600,.90,.70,78,1.60,.18,.005,1.020},
      {25,9000,4800,1.50,.90,850,1.50,.70,105,4.10,.64,.070,.950},
      {44,15500,7200,2.20,1.10,3300,2.35,.78,138,2.75,.45,.060,1},
      {11,13500,6000,.80,1.10,1350,-.85,.70,68,1.65,.22,.010,1.030}};
  const double Tx::Parameters::* fields[] = {
      &Tx::Parameters::lowCutHz, &Tx::Parameters::highCutHz,
      &Tx::Parameters::leakageHz, &Tx::Parameters::leakageDb, &Tx::Parameters::leakageQ,
      &Tx::Parameters::voiceHz, &Tx::Parameters::voiceDb, &Tx::Parameters::voiceQ,
      &Tx::Parameters::fluxHz, &Tx::Parameters::drive, &Tx::Parameters::saturationMix,
      &Tx::Parameters::asymmetry, &Tx::Parameters::makeup};
  bool factoryExact = true, metadata = true;
  for (size_t i = 0; i < defaults.size(); ++i)
    metadata &= defaults[i] == NAMRig::kTransformerControls[i].defaultValue;
  for (int profile = 0; profile < Tx::kProfileCount; ++profile) {
    const auto p = Tx::parametersForProfile(profile, defaults);
    for (size_t i = 0; i < 13; ++i) factoryExact &= p.*fields[i] == expected[profile][i];
  }
  check(factoryExact && metadata, "neutral trims preserve all 13 factory fields in every profile");

  TransformerAdjustments edited = {2, .5f, 2, 10, 2, 2, -3, 2, .5f, 3, 2};
  const auto p = Tx::parametersForProfile(Tx::kUKVintage, edited);
  const std::array<float, 11> effective = {80,5250,6.5f,62,260,4800,-1.25f,1.64f,2800,4.8f,2};
  const auto values = Tx::controlValues(p);
  bool mapping = true;
  for (size_t i = 0; i < values.size(); ++i) mapping &= std::fabs(values[i] - effective[i]) < 1.0e-5f;
  check(mapping && p.asymmetry == .040 && p.makeup == 1,
        "control order maps ratios, additive dB and mix percentage points correctly");

  std::vector<float> input(48000);
  for (size_t i = 0; i < input.size(); ++i)
    input[i] = .35f * std::sin(2 * kPi * 82 * i / 48000) +
               .2f * std::sin(2 * kPi * 997 * i / 48000) +
               .1f * std::sin(2 * kPi * 5701 * i / 48000);
  bool exactAudio = true;
  for (double rate : {44100.0,48000.0,96000.0,192000.0,768000.0}) {
    for (int profile = 0; profile < Tx::kProfileCount; ++profile) {
      auto audio = input;
      Tx tx;
      tx.process(audio.data(), audio.size(), rate, profile, defaults);
      const auto reference = factoryReference(input, rate, profile);
      exactAudio &= std::memcmp(audio.data(), reference.data(), audio.size() * sizeof(float)) == 0;
    }
  }
  check(exactAudio, "neutral audio is bit-exact against the original DSP at base/oversampled rates");

  auto factory = input;
  Tx base;
  base.process(factory.data(), factory.size(), 48000, Tx::kUKVintage);
  bool allAudible = true;
  for (size_t control = 0; control < defaults.size(); ++control) {
    auto trims = defaults;
    trims[control] = NAMRig::kTransformerControls[control].maximum;
    auto audio = input;
    Tx tx;
    tx.process(audio.data(), audio.size(), 48000, Tx::kUKVintage, trims);
    double energy = 0;
    for (size_t i = input.size() / 2; i < input.size(); ++i) {
      const double difference = audio[i] - factory[i];
      energy += difference * difference;
    }
    allAudible &= std::sqrt(energy / (input.size() / 2)) > 1.0e-4;
  }
  check(allAudible, "each of the 11 edits changes the audio measurably");

  bool partitionExact = true, historyPreserved = true, settles = true;
  for (double rate : {8000.0,48000.0,96000.0,192000.0,768000.0}) {
    const size_t length = static_cast<size_t>(rate * .3);
    std::vector<float> whole(length), split;
    for (size_t i = 0; i < length; ++i) whole[i] = .3f * std::sin(2 * kPi * 997 * i / rate);
    split = whole;
    Tx a, b;
    size_t begin = 0;
    const size_t boundaries[] = {101, static_cast<size_t>(rate * .15), length};
    for (size_t event = 0; event < 3; ++event) {
      const auto& trims = event == 1 ? edited : defaults;
      a.process(whole.data() + begin, boundaries[event] - begin, rate, Tx::kUKVintage, trims);
      size_t offset = begin, chunk = 0;
      constexpr size_t chunks[] = {1,17,31,64,511,7,1024};
      while (offset < boundaries[event]) {
        const size_t count = std::min(chunks[chunk++ % 7], boundaries[event] - offset);
        b.process(split.data() + offset, count, rate, Tx::kUKVintage, trims);
        offset += count;
      }
      begin = boundaries[event];
    }
    partitionExact &= std::memcmp(whole.data(), split.data(), length * sizeof(float)) == 0;

    Tx unchanged, moving;
    auto reference = input, glide = input;
    unchanged.process(reference.data(), 101, rate, Tx::kUKVintage);
    moving.process(glide.data(), 101, rate, Tx::kUKVintage);
    unchanged.process(reference.data() + 101, 27, rate, Tx::kUKVintage);
    moving.process(glide.data() + 101, 27, rate, Tx::kUKVintage, edited);
    historyPreserved &= std::memcmp(reference.data(), glide.data(), 128 * sizeof(float)) == 0;

    auto wet = std::vector<float>(length, .2f), smooth = wet;
    Tx instant, gradual;
    instant.process(wet.data(), length, rate, Tx::kUKVintage, edited);
    gradual.process(smooth.data(), 32, rate, Tx::kUKVintage);
    gradual.process(smooth.data() + 32, length - 32, rate, Tx::kUKVintage, edited);
    double difference = 0;
    for (size_t i = length - 100; i < length; ++i) difference += std::fabs(wet[i] - smooth[i]);
    settles &= difference / 100 < 1.0e-4;
  }
  check(partitionExact, "automated trims are bit-exact across arbitrary block partitions at all rates");
  check(historyPreserved, "trim edits retain filter/flux histories and the partial 32-sample cadence");
  check(settles, "20 ms trim glide settles at base and True 8x rates");

  Tx tail;
  std::array<float, 64> impulse{};
  impulse[0] = .5f;
  tail.process(impulse.data(), 32, 48000, Tx::kUKVintage);
  auto gentle = defaults;
  gentle[6] = 1;
  tail.process(impulse.data() + 32, 32, 48000, Tx::kUKVintage, gentle);
  double tailEnergy = 0;
  for (size_t i = 32; i < impulse.size(); ++i) tailEnergy += std::fabs(impulse[i]);
  check(tailEnergy > .001, "filter and flux impulse tails survive a trim update at a chunk boundary");

  bool gradualAtBoundary = true;
  for (double rate : {48000.0,768000.0}) {
    const size_t warmup = static_cast<size_t>(rate * .1) / 32 * 32;
    std::vector<float> warm(warmup);
    for (size_t i = 0; i < warm.size(); ++i) warm[i] = .3f * std::sin(2 * kPi * 2400 * i / rate);
    Tx moving;
    moving.process(warm.data(), warm.size(), rate, Tx::kUKVintage);
    Tx factory = moving;
    std::array<float, 32> neutralBlock{}, glideBlock{};
    for (size_t i = 0; i < neutralBlock.size(); ++i)
      neutralBlock[i] = .3f * std::sin(2 * kPi * 2400 * (warmup + i) / rate);
    glideBlock = neutralBlock;
    factory.process(neutralBlock.data(), neutralBlock.size(), rate, Tx::kUKVintage);
    auto trims = defaults;
    trims[6] = 12;
    moving.process(glideBlock.data(), glideBlock.size(), rate, Tx::kUKVintage, trims);
    double delta = 0;
    for (size_t i = 0; i < neutralBlock.size(); ++i) delta += std::fabs(glideBlock[i] - neutralBlock[i]);
    gradualAtBoundary &= delta > 0 && delta / neutralBlock.size() < .01;
  }
  check(gradualAtBoundary, "a full +12 dB gain edit starts gradually rather than jumping at a chunk boundary");

  // Sustained bass holds appreciable flux at each 32-sample update. A stale
  // saturated history turns drive changes into impulses in the inverse path.
  for (double rate : {48000.0,768000.0}) {
    for (int edit = 0; edit < 3; ++edit) {
      const size_t warmup = static_cast<size_t>(rate * .12) + 5;
      const size_t span = static_cast<size_t>(rate * .09) + 7;
      std::vector<float> whole(warmup + 4 * span), split;
      for (size_t i = 0; i < whole.size(); ++i)
        whole[i] = .9f * std::sin(2 * kPi * 41.2 * i / rate);
      split = whole;
      Tx moving, partitioned;
      auto trims = defaults;
      trims[2] = .25f;
      trims[3] = 100;
      trims[4] = .25f;
      moving.process(whole.data(), warmup, rate, Tx::kModern, trims);
      partitioned.process(split.data(), warmup, rate, Tx::kModern, trims);
      Tx unchanged = moving;
      std::vector<float> reference(whole.size() - warmup);
      for (size_t i = 0; i < reference.size(); ++i)
        reference[i] = .9f * std::sin(2 * kPi * 41.2 * (warmup + i) / rate);
      unchanged.process(reference.data(), reference.size(), rate, Tx::kModern, trims);
      for (size_t event = 0; event < 4; ++event) {
        const float target = event % 2 == 0 ? 4.0f : .25f;
        if (edit != 1) trims[2] = target;
        if (edit != 0) trims[4] = target;
        const size_t begin = warmup + event * span;
        moving.process(whole.data() + begin, span, rate, Tx::kModern, trims);
        constexpr size_t chunks[] = {1,17,31,64,511,7,1024};
        size_t offset = 0, chunk = 0;
        while (offset < span) {
          const size_t count = std::min(chunks[chunk++ % 7], span - offset);
          partitioned.process(split.data() + begin + offset, count, rate, Tx::kModern, trims);
          offset += count;
        }
      }
      double peak = 0, step = 0, curvature = 0, difference = 0;
      bool finite = true;
      for (size_t i = warmup; i < whole.size(); ++i) {
        finite &= std::isfinite(whole[i]);
        peak = std::max(peak, std::fabs(static_cast<double>(whole[i])));
        step = std::max(step, std::fabs(static_cast<double>(whole[i]) - whole[i - 1]));
        curvature = std::max(curvature, std::fabs(static_cast<double>(whole[i]) -
            2.0 * whole[i - 1] + whole[i - 2]));
        difference += std::fabs(whole[i] - reference[i - warmup]);
      }
      char label[256];
      std::snprintf(label, sizeof(label),
          "%s glide at %.0f kHz: peak %.4f, step %.5f, curvature %.5f, partition-exact",
          edit == 0 ? "drive" : edit == 1 ? "flux" : "drive + flux", rate / 1000,
          peak, step, curvature);
      // Allow the intended 32-sample curve glide, but reject inverse-path
      // impulses. Oversampling must reduce steps, not merely hide their peaks.
      const double rateScale = 48000.0 / rate;
      check(finite && peak < 1.0 && step < .03 * rateScale &&
                curvature < .03 * rateScale * rateScale &&
                difference / reference.size() > .01 &&
                std::memcmp(whole.data(), split.data(), whole.size() * sizeof(float)) == 0,
            label);
    }
  }

  bool safe = true, offExact = true, bounded = true;
  const float malformed[] = {std::numeric_limits<float>::quiet_NaN(),
      std::numeric_limits<float>::infinity(), -std::numeric_limits<float>::infinity(),
      std::numeric_limits<float>::max(), -std::numeric_limits<float>::max(), 0};
  const float minima[] = {5,2000,.5f,0,20,100,-12,.2f,100,-12,.2f};
  const float maxima[] = {300,24000,10,100,400,12000,12,4,12000,12,4};
  for (float value : malformed) {
    TransformerAdjustments trims;
    trims.fill(value);
    for (int profile = 0; profile < Tx::kProfileCount; ++profile) {
      const auto controls = Tx::controlValues(Tx::parametersForProfile(profile, trims));
      for (size_t i = 0; i < controls.size(); ++i)
        bounded &= std::isfinite(controls[i]) && controls[i] >= minima[i] && controls[i] <= maxima[i];
      for (double rate : {8000.0,48000.0,768000.0}) {
        auto audio = input;
        Tx tx;
        tx.process(audio.data(), 101, rate, profile);
        tx.process(audio.data() + 101, audio.size() - 101, rate, profile, trims);
        for (float sample : audio) safe &= std::isfinite(sample);
        if (profile == Tx::kCaptured)
          offExact &= std::memcmp(audio.data(), input.data(), audio.size() * sizeof(float)) == 0;
      }
    }
  }
  auto bypass = input;
  Tx off;
  off.process(bypass.data(), bypass.size(), 48000, Tx::kCaptured, edited);
  offExact &= std::memcmp(bypass.data(), input.data(), input.size() * sizeof(float)) == 0;
  check(bounded && safe, "NaN/Inf/extreme trims stay within absolute limits and produce finite audio");
  check(offExact, "Off stays bit-transparent with edited and malformed trims");
}
} // namespace

int main() {
  verifyAdjustments();
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
