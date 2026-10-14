// Standalone regression: clang++ -O3 -mcpu=native -ffp-contract=fast -std=c++17
//   -Isrc tests/verify_control_work.cpp -o /tmp/verify_control_work
// Optional HEAD snapshot: -DBASELINE_HEADERS=/absolute/snapshot/src
// Run checks by default; --bench also runs alternating before/after medians.
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#include "power_tube_controls.h"
#include "dynamics.h"
#include "pin_eq.h"

#ifdef BASELINE_HEADERS
// Preinclude dependencies so the namespace macro affects only snapshot DSP.
namespace Baseline {
using NAMRig::kPinEqFirstPort;
using NAMRig::kPinEqPortCount;
}
#define CONTROL_HEADER_TEXT_(path) #path
#define CONTROL_HEADER_TEXT(path) CONTROL_HEADER_TEXT_(path)
#define NAMRig Baseline
#include CONTROL_HEADER_TEXT(BASELINE_HEADERS/dynamics.h)
#include CONTROL_HEADER_TEXT(BASELINE_HEADERS/pin_eq.h)
#undef NAMRig
#undef CONTROL_HEADER_TEXT
#undef CONTROL_HEADER_TEXT_
#endif

namespace {
constexpr std::array<size_t, 8> kBlocks = {1, 31, 32, 33, 64, 128, 512, 4096};
constexpr std::array<double, 6> kRates = {8000, 44100, 48000, 96000, 768000, 1536000};
uint64_t gateChecks = 0, eqChecks = 0;
#ifdef BASELINE_HEADERS
volatile double sink = 0.0;
#endif

uint32_t bits(float value) {
  uint32_t out;
  std::memcpy(&out, &value, sizeof(out));
  return out;
}

void same(float actual, float expected, const char* label, double rate,
          size_t block, size_t phase, size_t sample) {
  if (bits(actual) != bits(expected) || !std::isfinite(actual)) {
    std::fprintf(stderr, "FAIL %s rate=%.0f block=%zu phase=%zu sample=%zu: "
                         "%08x != %08x\n", label, rate, block, phase, sample,
                 bits(actual), bits(expected));
    std::exit(1);
  }
}

float signal(size_t sample, double rate, size_t channel = 0) {
  uint32_t hash = static_cast<uint32_t>(sample) * 747796405u +
                  static_cast<uint32_t>(channel) * 2891336453u + 12345u;
  hash = (hash ^ (hash >> 16)) * 2246822519u;
  const float noise = static_cast<float>(hash >> 8) / 8388608.0f - 1.0f;
  const double t = static_cast<double>(sample) / rate;
  const double phase = std::fmod(t, 0.16);
  const double amplitude = phase < 0.035 ? 0.12 :
                           phase < 0.09 ? 0.04 * std::exp(-(phase - 0.035) / 0.012)
                                        : 0.0002;
  if (sample % 997 == 0) return channel == 0 ? 0.7f : -0.4f;
  if (sample % 101 == 0) return channel == 0 ? 0.0f : -0.0f;
  return static_cast<float>(amplitude * std::cos(6.283185307179586 *
                           (channel == 0 ? 82.0 : 137.0) * t)) + noise * 0.0001f;
}

void verifyGate() {
  const std::array<float, 16> thresholds = {
      -40, -40, -60, -60, -60, -79.98f, -79.99f, -40,
      -80, -40, -40, -12, -12, -96, -12, -40};
  const std::array<float, 16> releases = {
      20, 20, 20, 150, 150, 1, 150, 20, 20, 20, 1000, 1000, 20, 20, 20, 20};
  for (double baseRate : kRates) {
    for (size_t block : kBlocks) {
      NAMRig::NoiseGate current, forced;
#ifdef BASELINE_HEADERS
      Baseline::NoiseGate original;
#endif
      size_t cursor = 0;
      for (size_t phase = 0; phase < thresholds.size(); ++phase) {
        const double rate = phase == 4 ? baseRate * 2.0 : baseRate;
        const float threshold = thresholds[phase], release = releases[phase];
        if (phase == 10) {
          // OFF -> ON with no bypass samples, after repeated active configure.
          for (int repeat = 0; repeat < 3; ++repeat) {
            current.configure(rate, -80, release);
            forced.configure(rate, -80, release);
#ifdef BASELINE_HEADERS
            original.configure(rate, -80, release);
#endif
          }
        }
        if (phase == 15) {
          current = NAMRig::NoiseGate{};
          forced = NAMRig::NoiseGate{};
#ifdef BASELINE_HEADERS
          original = Baseline::NoiseGate{};
#endif
        }
        const size_t count = static_cast<size_t>(rate * 0.08) + 33;
        for (size_t start = 0; start < count; start += block) {
          current.configure(rate, threshold, release);
          // Change a coefficient input without processing between calls. This
          // forces recomputation without resetting detector/envelope histories.
          forced.configure(rate, threshold,
                           std::nextafter(release, std::numeric_limits<float>::infinity()));
          forced.configure(rate, threshold, release);
#ifdef BASELINE_HEADERS
          original.configure(rate, threshold, release);
#endif
          const size_t n = std::min(block, count - start);
          for (size_t i = 0; i < n; ++i, ++cursor) {
            const float x = signal(cursor, rate);
            const float y = current.process(x);
            same(y, forced.process(x), "gate forced-recalc", rate, block, phase, start + i);
#ifdef BASELINE_HEADERS
            same(y, original.process(x), "gate HEAD", rate, block, phase, start + i);
#endif
            if (threshold <= -79.99f)
              same(y, x, "gate OFF bypass", rate, block, phase, start + i);
            ++gateChecks;
          }
        }
      }
    }
  }
}

NAMRig::PinBands targetsFor(size_t phase) {
  NAMRig::PinBands bands{};
  for (size_t b = 0; b < bands.size(); ++b) bands[b].freq = NAMRig::kPinFreqDefaults[b];
  if (phase == 0 || phase == 9) return bands;
  for (size_t b = 0; b < bands.size(); ++b) {
    bands[b] = {1 + static_cast<int>(b % 3), NAMRig::kPinFreqDefaults[b],
                b % 2 == 0 ? 4.5 : -3.0, 0.707 + 0.25 * b};
    if (phase == 1) bands[b].gainDb = 0;
    if (phase >= 3) {
      bands[b].freq *= 1.7;
      bands[b].q = b % 2 == 0 ? 0.1 : 10.0;
      bands[b].gainDb = b % 2 == 0 ? -7.0 : 6.0;
    }
    if (phase == 4 || phase == 5 || phase == 13)
      bands[b].shape = 1 + static_cast<int>((b + 1) % 3);
    if (phase == 6 || phase == 7) bands[b].shape = NAMRig::kPinOff;
    if (phase == 10 || phase == 11) {
      // Exercise both the UI bounds and rate-dependent Nyquist clamp.
      bands[b].freq = b % 2 == 0 ? 1.0 : 100000.0;
      bands[b].q = b % 2 == 0 ? 0.1 : 10.0;
    }
    if (phase == 12) bands[b].gainDb = 0;
  }
  return bands;
}

#ifdef BASELINE_HEADERS
Baseline::PinBands baselineTargets(const NAMRig::PinBands& bands) {
  Baseline::PinBands out;
  for (size_t b = 0; b < bands.size(); ++b)
    out[b] = {bands[b].shape, bands[b].freq, bands[b].gainDb, bands[b].q};
  return out;
}
#endif

void verifyEqCase(double baseRate, size_t block, size_t channels, bool longGlides) {
  NAMRig::PinEq current, subdivided;
#ifdef BASELINE_HEADERS
  Baseline::PinEq original;
#endif
  std::array<std::vector<float>, 2> input, whole, chunks;
#ifdef BASELINE_HEADERS
  std::array<std::vector<float>, 2> before;
#endif
  for (size_t ch = 0; ch < channels; ++ch) {
    input[ch].resize(block);
    whole[ch].resize(block);
    chunks[ch].resize(block);
#ifdef BASELINE_HEADERS
    before[ch].resize(block);
#endif
  }
  size_t cursor = 0;
  for (size_t phase = 0; phase < 14; ++phase) {
    const auto targets = targetsFor(phase);
#ifdef BASELINE_HEADERS
    const auto oldTargets = baselineTargets(targets);
#endif
    const double rate = phase == 10 ? 8000.0 : phase == 11 ? 48000.0 : baseRate;
    if (phase == 9) {
      current.reset();
      subdivided.reset();
#ifdef BASELINE_HEADERS
      original.reset();
#endif
    }
    if (phase % 4 == 0) {
      // Zero-count priming/rate updates must not disturb subsequent smoothing.
      float* empty[2] = {whole[0].data(), whole[1].data()};
      current.process(empty, channels, 0, rate, targets);
      subdivided.process(empty, channels, 0, rate, targets);
#ifdef BASELINE_HEADERS
      original.process(empty, channels, 0, rate, oldTargets);
#endif
    }
    const size_t count = longGlides ? static_cast<size_t>(rate * 0.26) + 33 : 8193;
    for (size_t start = 0; start < count; start += block) {
      const size_t n = std::min(block, count - start);
      float* wholePtrs[2] = {}, *chunkPtrs[2] = {};
#ifdef BASELINE_HEADERS
      float* beforePtrs[2] = {};
#endif
      for (size_t ch = 0; ch < channels; ++ch) {
        for (size_t i = 0; i < n; ++i) input[ch][i] = signal(cursor + i, rate, ch);
        std::copy_n(input[ch].data(), n, whole[ch].data());
        std::copy_n(input[ch].data(), n, chunks[ch].data());
        wholePtrs[ch] = whole[ch].data();
#ifdef BASELINE_HEADERS
        std::copy_n(input[ch].data(), n, before[ch].data());
        beforePtrs[ch] = before[ch].data();
#endif
      }
      current.process(wholePtrs, channels, n, rate, targets);
#ifdef BASELINE_HEADERS
      original.process(beforePtrs, channels, n, rate, oldTargets);
#endif
      // Preserve each call's exact 32-sample cadence, including its short tail.
      // Arbitrary splits would change the existing smoothing algorithm.
      for (size_t offset = 0; offset < n; offset += 32) {
        for (size_t ch = 0; ch < channels; ++ch)
          chunkPtrs[ch] = chunks[ch].data() + offset;
        subdivided.process(chunkPtrs, channels, std::min<size_t>(32, n - offset), rate, targets);
      }
      for (size_t ch = 0; ch < channels; ++ch) {
        for (size_t i = 0; i < n; ++i) {
          same(whole[ch][i], chunks[ch][i], "EQ 32-boundary subdivision", rate,
               block, phase, start + i);
#ifdef BASELINE_HEADERS
          same(whole[ch][i], before[ch][i], "EQ HEAD", rate, block, phase, start + i);
#endif
          if (phase == 0 || phase == 1 || phase == 9)
            same(whole[ch][i], input[ch][i], "EQ neutral bypass", rate, block, phase, start + i);
          ++eqChecks;
        }
      }
      cursor += n;
    }
  }
}

#ifdef BASELINE_HEADERS
// Volatile controls model port reads and prevent compile-time specialization
// or loop-hoisting of the original configure/target math. Values stay stable.
struct RuntimeControls {
  volatile double rate = 48000;
  volatile float threshold = -40, release = 150;
  volatile int shape[6] = {};
  volatile double freq[6] = {}, gain[6] = {}, q[6] = {};
};

struct Timing { double nsPerSample, checksum; };

template <class Gate>
__attribute__((noinline)) Timing timeGate(RuntimeControls& controls, size_t block, size_t iterations) {
  Gate gate;
  const size_t signalLength = std::max<size_t>(4096, static_cast<size_t>(controls.rate * 0.64));
  std::vector<float> input(((signalLength + block - 1) / block) * block);
  for (size_t i = 0; i < input.size(); ++i) input[i] = signal(i, controls.rate);
  double checksum = 0.0;
  const auto start = std::chrono::steady_clock::now();
  for (size_t k = 0; k < iterations; ++k) {
    gate.configure(controls.rate, controls.threshold, controls.release);
    const size_t offset = (k * block) % input.size();
    for (size_t i = 0; i < block; ++i) checksum += gate.process(input[offset + i]);
  }
  const double ns = std::chrono::duration<double, std::nano>(
      std::chrono::steady_clock::now() - start).count();
  sink += checksum;
  return {ns / static_cast<double>(block * iterations), checksum};
}

template <class Eq, class Bands>
__attribute__((noinline)) Timing timeEq(RuntimeControls& controls, size_t block,
                                        size_t channels, size_t iterations) {
  Eq eq;
  Bands targets;
  std::array<std::vector<float>, 2> input, output;
  float* ptrs[2] = {};
  const size_t signalLength = std::max<size_t>(4096, static_cast<size_t>(controls.rate * 0.64));
  const size_t inputLength = ((signalLength + block - 1) / block) * block;
  for (size_t ch = 0; ch < channels; ++ch) {
    input[ch].resize(inputLength);
    output[ch].resize(block);
    ptrs[ch] = output[ch].data();
    for (size_t i = 0; i < input[ch].size(); ++i)
      input[ch][i] = signal(i, controls.rate, ch);
  }
  double checksum = 0.0;
  const auto start = std::chrono::steady_clock::now();
  for (size_t k = 0; k < iterations; ++k) {
    for (size_t b = 0; b < targets.size(); ++b)
      targets[b] = {controls.shape[b], controls.freq[b], controls.gain[b], controls.q[b]};
    const size_t offset = (k * block) % inputLength;
    for (size_t ch = 0; ch < channels; ++ch)
      std::copy_n(input[ch].data() + offset, block, output[ch].data());
    eq.process(ptrs, channels, block, controls.rate, targets);
    // Consume every output, not just a sample which could leave bypass work dead.
    for (size_t ch = 0; ch < channels; ++ch)
      for (size_t i = 0; i < block; ++i) checksum += output[ch][i];
  }
  const double ns = std::chrono::duration<double, std::nano>(
      std::chrono::steady_clock::now() - start).count();
  sink += checksum;
  return {ns / static_cast<double>(block * channels * iterations), checksum};
}

template <class Before, class After>
void medians(const char* label, double rate, size_t block, size_t channels,
             Before before, After after, size_t iterations, size_t trials) {
  // Warm both code paths; alternate order to reduce drift/thermal bias.
  before(iterations / 4);
  after(iterations / 4);
  std::vector<double> oldTimes, newTimes, ratios;
  double checksum = 0.0;
  for (size_t trial = 0; trial < trials; ++trial) {
    Timing oldResult, newResult;
    if (trial % 2 == 0) {
      oldResult = before(iterations);
      newResult = after(iterations);
    } else {
      newResult = after(iterations);
      oldResult = before(iterations);
    }
    if (oldResult.checksum != newResult.checksum || !std::isfinite(oldResult.checksum)) {
      std::fprintf(stderr, "FAIL benchmark checksum %s %.17g != %.17g\n",
                   label, oldResult.checksum, newResult.checksum);
      std::exit(1);
    }
    checksum = oldResult.checksum;
    oldTimes.push_back(oldResult.nsPerSample);
    newTimes.push_back(newResult.nsPerSample);
    ratios.push_back(oldResult.nsPerSample / newResult.nsPerSample);
  }
  std::sort(oldTimes.begin(), oldTimes.end());
  std::sort(newTimes.begin(), newTimes.end());
  std::sort(ratios.begin(), ratios.end());
  const size_t mid = trials / 2;
  std::printf("%-10s %6.0f Hz %4zu frames %zu ch: %.3f -> %.3f ns/sample/ch; "
              "%.2fx paired median; checksum %.9g\n", label, rate, block, channels,
              oldTimes[mid], newTimes[mid], ratios[mid], checksum);
}

void benchmark(size_t frames, size_t trials) {
  RuntimeControls controls;
  std::printf("Benchmark: %zu frames/path/trial, %zu alternating trials + warmup\n", frames, trials);
  for (double rate : {48000.0, 768000.0}) {
    controls.rate = rate;
    for (size_t block : {size_t{64}, size_t{128}}) {
      medians("gate", rate, block, 1,
              [&](size_t n) { return timeGate<Baseline::NoiseGate>(controls, block, n); },
              [&](size_t n) { return timeGate<NAMRig::NoiseGate>(controls, block, n); },
              std::max<size_t>(4, frames / block), trials);
    }
    for (int active = 0; active < 2; ++active) {
      const auto bands = targetsFor(active ? 2 : 0);
      for (size_t b = 0; b < bands.size(); ++b) {
        controls.shape[b] = bands[b].shape;
        controls.freq[b] = bands[b].freq;
        controls.gain[b] = bands[b].gainDb;
        controls.q[b] = bands[b].q;
      }
      for (size_t channels : {size_t{1}, size_t{2}}) {
        // Session 64/128-frame blocks become 1024/2048 at a 16x domain.
        for (size_t sessionBlock : {size_t{64}, size_t{128}}) {
          const size_t block = sessionBlock * (rate == 768000 ? 16 : 1);
          medians(active ? "EQ active" : "EQ neutral", rate, block, channels,
                  [&](size_t n) { return timeEq<Baseline::PinEq, Baseline::PinBands>(
                      controls, block, channels, n); },
                  [&](size_t n) { return timeEq<NAMRig::PinEq, NAMRig::PinBands>(
                      controls, block, channels, n); },
                  std::max<size_t>(4, frames / block), trials);
        }
      }
    }
  }
}
#endif
} // namespace

int main(int argc, char** argv) {
  bool bench = false;
  size_t frames = 1u << 20, trials = 9;
  for (int arg = 1; arg < argc; ++arg) {
    if (std::strcmp(argv[arg], "--bench") == 0) bench = true;
    else if (std::strcmp(argv[arg], "--frames") == 0 && arg + 1 < argc)
      frames = std::strtoull(argv[++arg], nullptr, 10);
    else if (std::strcmp(argv[arg], "--trials") == 0 && arg + 1 < argc)
      trials = std::strtoull(argv[++arg], nullptr, 10);
    else {
      std::fprintf(stderr, "Usage: %s [--bench] [--frames N] [--trials odd-N>=3]\n", argv[0]);
      return 2;
    }
  }
  if (frames < 4096 || trials < 3 || trials % 2 == 0) return 2;
#ifndef BASELINE_HEADERS
  if (bench) {
    std::fprintf(stderr, "--bench requires -DBASELINE_HEADERS=/absolute/snapshot/src\n");
    return 2;
  }
#endif
  verifyGate();
  for (double rate : kRates)
    for (size_t channels : {size_t{1}, size_t{2}})
      for (size_t block : kBlocks) verifyEqCase(rate, block, channels, false);
  for (double rate : {48000.0, 768000.0})
    for (size_t channels : {size_t{1}, size_t{2}})
      verifyEqCase(rate, 512, channels, true);
  std::printf("PASS bit-exact: %llu gate samples, %llu EQ channel-samples; "
#ifdef BASELINE_HEADERS
              "HEAD equivalence + "
#endif
              "forced gate recalculation + 32-boundary EQ subdivision\n",
              static_cast<unsigned long long>(gateChecks),
              static_cast<unsigned long long>(eqChecks));
#ifdef BASELINE_HEADERS
  if (bench) benchmark(frames, trials);
#endif
  return 0;
}
