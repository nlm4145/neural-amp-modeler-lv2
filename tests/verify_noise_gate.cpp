// Direct production-class regressions; no mirrored detector or gain DSP.
// Build: clang++ -O2 -std=c++17 -Isrc tests/verify_noise_gate.cpp
#include "dynamics.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>

namespace {
using Gate = NAMRig::NoiseGate;
constexpr double kPi = 3.14159265358979323846;
constexpr float kThresholdDb = -40.0f;
const float kOpen = std::pow(10.0f, kThresholdDb / 20.0f);
int failures = 0;

int samples(double rate, double ms) {
  return static_cast<int>(std::lround(rate * ms / 1000.0));
}

float noise(uint32_t& state) {
  state = state * 1664525u + 1013904223u;
  return static_cast<float>(state >> 8) / 8388608.0f - 1.0f;
}

void settle(Gate& gate, double rate, float input = kOpen * 0.03f,
            double ms = 600.0) {
  // A new enabled gate starts open. Do not mistake that startup for a reopen.
  for (int i = 0; i < samples(rate, ms); ++i) gate.process(input);
}

bool exact(float a, float b) {
  return std::memcmp(&a, &b, sizeof(float)) == 0;
}

void check(bool ok, double rate, const char* label, double observed) {
  std::printf("  %s  %g kHz: %s (observed %.6g)\n",
              ok ? "PASS" : "FAIL", rate / 1000.0, label, observed);
  if (!ok) ++failures;
}
} // namespace

int main() {
  for (double rate : {44100.0, 48000.0, 96000.0, 192000.0}) {
    // OFF must return the original bits and discard both closed and held-open
    // histories. Re-enabling must be indistinguishable from a fresh gate.
    bool bypassExact = true, resetExact = true;
    const float bypassInputs[] = {
        0.0f, -0.0f, 0.1234567f, -0.7654321f,
        std::numeric_limits<float>::denorm_min(),
        -std::numeric_limits<float>::denorm_min(),
        std::numeric_limits<float>::min(),
        std::numeric_limits<float>::max(),
        -std::numeric_limits<float>::max()};
    for (float offDb : {-80.0f, -79.99f, -96.0f}) {
      Gate closed, held, fresh;
      closed.configure(rate, kThresholdDb, 20.0f);
      held.configure(rate, kThresholdDb, 20.0f);
      settle(closed, rate);
      settle(held, rate, kOpen * 4.0f, 100.0);
      closed.configure(rate, offDb, 150.0f);
      held.configure(rate, offDb, 150.0f);
      for (int block = 0; block < 4; ++block) {
        closed.configure(rate, offDb, 150.0f);
        held.configure(rate, offDb, 150.0f);
        for (float x : bypassInputs) {
          bypassExact &= exact(closed.process(x), x);
          bypassExact &= exact(held.process(x), x);
        }
      }
      closed.configure(rate, kThresholdDb, 20.0f);
      held.configure(rate, kThresholdDb, 20.0f);
      fresh.configure(rate, kThresholdDb, 20.0f);
      for (int i = 0; i < samples(rate, 400.0); ++i) {
        if (i % 64 == 0) {
          closed.configure(rate, kThresholdDb, 20.0f);
          held.configure(rate, kThresholdDb, 20.0f);
          fresh.configure(rate, kThresholdDb, 20.0f);
        }
        const double t = i / rate;
        const float x = t < 0.15 ? kOpen * 0.03f
                                : kOpen * 1.5f * std::cos(2.0 * kPi * 82.0 * t);
        const float expected = fresh.process(x);
        resetExact &= exact(closed.process(x), expected);
        resetExact &= exact(held.process(x), expected);
      }
      // Reset on configure(OFF), even if no bypass audio is processed.
      settle(closed, rate);
      closed.configure(rate, offDb, 20.0f);
      closed.configure(rate, kThresholdDb, 20.0f);
      Gate untouched;
      untouched.configure(rate, kThresholdDb, 20.0f);
      for (int i = 0; i < samples(rate, 100.0); ++i)
        resetExact &= exact(closed.process(kOpen * 0.03f),
                            untouched.process(kOpen * 0.03f));
    }
    check(bypassExact && resetExact, rate,
          "OFF is bit-exact; re-enable resets all state", bypassExact && resetExact);
    {
      Gate gate;
      gate.configure(rate, -79.98f, 20.0f);
      const float x = std::pow(10.0f, -79.98f / 20.0f) * 0.03f;
      settle(gate, rate, x);
      const float gain = gate.process(x) / x;
      check(gain < 0.10f, rate, "just above the OFF boundary is enabled", gain);
    }

    // A modest pick must reopen quickly, not wait for the slow tail envelope.
    {
      Gate gate;
      gate.configure(rate, kThresholdDb, 20.0f);
      settle(gate, rate);
      const float idleGain = gate.process(kOpen * 0.03f) / (kOpen * 0.03f);
      int firstUnity = -1;
      float minimumAfterAttack = 1.0f;
      for (int i = 0; i < samples(rate, 10.0); ++i) {
        const float x = kOpen * 1.3f;
        const float gain = gate.process(x) / x;
        if (gain > 0.95f && firstUnity < 0) firstUnity = i;
        if (i >= samples(rate, 0.8))
          minimumAfterAttack = std::min(minimumAfterAttack, gain);
      }
      const double onsetMs = firstUnity < 0 ? 999.0 : (firstUnity + 1) * 1000.0 / rate;
      check(idleGain < 0.10f && onsetMs <= 0.8 && minimumAfterAttack > 0.95f,
            rate, "1.3x-threshold pick reaches gain >0.95 within 0.8 ms", onsetMs);
    }

    // Isolated impulses must not trigger a delayed opening after the impulse.
    {
      Gate gate;
      gate.configure(rate, kThresholdDb, 20.0f);
      settle(gate, rate);
      float maximumGain = 0.0f;
      bool finite = true;
      for (float spike : {kOpen * 1.3f, kOpen * 8.0f, 1.0f}) {
        const float spikeGain = gate.process(spike) / spike;
        finite &= std::isfinite(spikeGain);
        maximumGain = std::max(maximumGain, spikeGain);
        for (int i = 0; i < samples(rate, 100.0); ++i) {
          const float x = kOpen * 0.03f;
          const float gain = gate.process(x) / x;
          finite &= std::isfinite(gain);
          maximumGain = std::max(maximumGain, gain);
        }
      }
      check(finite && maximumGain < 0.15f, rate,
            "single-sample spikes never open (including their aftermath)", maximumGain);
    }

    // Rejected pulses must not accumulate a unity expansion target between them.
    {
      Gate gate;
      gate.configure(rate, kThresholdDb, 20.0f);
      settle(gate, rate);
      const int width = samples(rate, 0.0625); // Less than 80 us at every test rate.
      const int period = samples(rate, 1.0);
      float maximumGain = 0.0f;
      bool finite = true;
      for (int i = 0; i < samples(rate, 600.0); ++i) {
        const bool pulse = i < samples(rate, 500.0) && i % period < width;
        const float x = pulse ? 1.0f : kOpen * 0.03f;
        const float gain = gate.process(x) / x;
        finite &= std::isfinite(gain);
        maximumGain = std::max(maximumGain, gain);
      }
      check(finite && maximumGain < 0.10f, rate,
            "sub-80 us full-scale pulses every 1 ms keep idle and aftermath suppressed",
            maximumGain);
    }

    // Test silence, coherent hum, random idle noise, and the retained expansion
    // floor. All observations are after the initial open state has settled.
    {
      float maximumIdleGain = 0.0f;
      bool silenceExact = true, finite = true;
      for (int kind = 0; kind < 3; ++kind) {
        Gate gate;
        gate.configure(rate, kThresholdDb, 20.0f);
        uint32_t state = 0x12345678u;
        for (int i = 0; i < samples(rate, 1600.0); ++i) {
          const float x = kind == 0 ? 0.0f : kOpen * 0.03f *
              (kind == 1 ? static_cast<float>(std::sin(2.0 * kPi * 60.0 * i / rate))
                         : noise(state));
          const float y = gate.process(x);
          finite &= std::isfinite(y);
          if (i < samples(rate, 600.0)) continue;
          if (kind == 0) silenceExact &= y == 0.0f;
          if (std::fabs(x) > kOpen * 1.0e-5f)
            maximumIdleGain = std::max(maximumIdleGain, std::fabs(y / x));
        }
      }
      float gains[3];
      for (int i = 0; i < 3; ++i) {
        Gate gate;
        gate.configure(rate, kThresholdDb, 20.0f);
        const float x = kOpen * (i == 2 ? 1.0e-6f : 0.01f * (i + 1));
        settle(gate, rate, x);
        gains[i] = gate.process(x) / x;
      }
      const float expansionRatio = gains[1] / gains[0];
      check(finite && silenceExact && maximumIdleGain < 0.10f &&
                expansionRatio > 1.8f && expansionRatio < 2.2f &&
                std::fabs(gains[2] - 0.001f) < 0.0001f,
            rate, "idle hum/noise suppressed; 2:1 expansion and 0.001 floor retained",
            maximumIdleGain);
      if (!(expansionRatio > 1.8f && expansionRatio < 2.2f &&
            std::fabs(gains[2] - 0.001f) < 0.0001f))
        std::printf("        expansion gain ratio %.6g, floor %.6g\n", expansionRatio, gains[2]);
    }

    {
      float minimumGain = 1.0f;
      double worstHz = 0.0;
      bool finite = true;
      for (double hz : {31.0, 41.0, 82.0}) {
        Gate gate;
        gate.configure(rate, kThresholdDb, 20.0f);
        settle(gate, rate);
        for (int i = 0; i < samples(rate, 700.0); ++i) {
          const float x = kOpen * 1.5f * std::sin(2.0 * kPi * hz * i / rate);
          const float y = gate.process(x);
          finite &= std::isfinite(y);
          // Ignore only the initial onset and numerically tiny zero crossings.
          if (i >= samples(rate, 70.0) && std::fabs(x) > kOpen * 1.0e-4f) {
            const float gain = y / x;
            if (gain < minimumGain) { minimumGain = gain; worstHz = hz; }
          }
        }
      }
      check(finite && minimumGain > 0.98f, rate,
            "31/41/82 Hz notes at 1.5x threshold stay unity with 20 ms release",
            minimumGain);
      if (minimumGain <= 0.98f) std::printf("        worst frequency %g Hz\n", worstHz);
    }

    {
      Gate gate;
      gate.configure(rate, kThresholdDb, 20.0f);
      settle(gate, rate);
      double slowestOnsetMs = 0.0;
      float maximumGapGain = 0.0f;
      bool reopened = true;
      for (int burst = 0; burst < 5; ++burst) {
        int firstUnity = -1;
        for (int i = 0; i < samples(rate, 12.0); ++i) {
          const float x = kOpen * 1.3f;
          const float gain = gate.process(x) / x;
          if (gain > 0.95f && firstUnity < 0) firstUnity = i;
          if (i >= samples(rate, 0.8)) reopened &= gain > 0.95f;
        }
        slowestOnsetMs = std::max(slowestOnsetMs,
            firstUnity < 0 ? 999.0 : (firstUnity + 1) * 1000.0 / rate);
        float gapGain = 1.0f;
        for (int i = 0; i < samples(rate, 90.0); ++i) {
          const float x = kOpen * 0.03f;
          gapGain = gate.process(x) / x;
        }
        maximumGapGain = std::max(maximumGapGain, gapGain);
      }
      check(reopened && slowestOnsetMs <= 0.8 && maximumGapGain < 0.12f,
            rate, "palm-muted bursts close and promptly reopen on every pick",
            slowestOnsetMs);
      if (maximumGapGain >= 0.12f)
        std::printf("        maximum gain at end of mute %.6g\n", maximumGapGain);
    }

    // A brief bright pick followed by between-threshold sustain must reopen
    // through the onset path, not slowly recover through the tail detector.
    for (double hz : {2000.0, 4000.0}) {
      Gate gate, reference;
      gate.configure(rate, kThresholdDb, 20.0f);
      reference.configure(rate, kThresholdDb, 20.0f);
      settle(gate, rate, kOpen * 1.5f, 120.0);
      settle(reference, rate, kOpen * 1.5f, 120.0);
      settle(gate, rate);
      settle(reference, rate);
      int firstUnity = -1;
      float minimumGain = 1.0f, minimumRelativeGain = 1.0f;
      bool finite = true;
      for (int i = 0; i < samples(rate, 20.0); ++i) {
        const double t = i / rate;
        const bool attack = t < 0.0006;
        const float x = kOpen * (attack ? 1.3f : 0.6f) *
            std::cos(2.0 * kPi * (attack ? hz : 82.0) * t);
        const float referenceInput = kOpen * (attack ? 1.3f : 0.6f) *
            std::cos(2.0 * kPi * 82.0 * t);
        const float y = gate.process(x);
        const float referenceOutput = reference.process(referenceInput);
        finite &= std::isfinite(y) && std::isfinite(referenceOutput);
        if (std::fabs(x) <= kOpen * 1.0e-4f ||
            std::fabs(referenceInput) <= kOpen * 1.0e-4f) continue;
        const float gain = y / x;
        if (gain > 0.95f && firstUnity < 0) firstUnity = i;
        if (t >= 0.001) {
          minimumGain = std::min(minimumGain, gain);
          minimumRelativeGain = std::min(minimumRelativeGain,
              gain / (referenceOutput / referenceInput));
        }
      }
      const double onsetMs = firstUnity < 0 ? 999.0 : (firstUnity + 1) * 1000.0 / rate;
      check(finite && onsetMs <= 1.0 && minimumGain > 0.95f &&
                minimumRelativeGain > 0.95f, rate,
            "0.6 ms AC pick after mute recovers within 1 ms like a low-string pick",
            onsetMs);
      std::printf("        %g Hz attack: minimum gain after 1 ms %.4f, relative %.4f\n",
                  hz, minimumGain, minimumRelativeGain);
    }

    // Compare gain, not output amplitude: the two inputs have different levels.
    // A 40 ms exponential decay is a natural tail, not an abrupt level step.
    {
      float natural[2] = {}, muted[2] = {}, naturalEnd[2] = {}, mutedEnd[2] = {};
      for (int r = 0; r < 2; ++r) {
        const float release = r == 0 ? 20.0f : 150.0f;
        Gate tail, mute;
        tail.configure(rate, kThresholdDb, release);
        mute.configure(rate, kThresholdDb, release);
        settle(tail, rate, kOpen * 1.5f, 120.0);
        settle(mute, rate, kOpen * 1.5f, 120.0);
        for (int i = 0; i < samples(rate, 300.0); ++i) {
          const double t = (i + 1) / rate;
          const float tailInput = kOpen * 1.5f * std::exp(-t / 0.040);
          const float muteInput = kOpen * 0.03f;
          naturalEnd[r] = tail.process(tailInput) / tailInput;
          mutedEnd[r] = mute.process(muteInput) / muteInput;
          if (i + 1 == samples(rate, 140.0)) {
            natural[r] = naturalEnd[r];
            muted[r] = mutedEnd[r];
          }
        }
      }
      check(natural[0] > muted[0] + 0.03f && natural[1] > muted[1] + 0.03f &&
                natural[1] > natural[0] + 0.15f && muted[1] > muted[0] + 0.15f &&
                naturalEnd[0] < 0.10f && mutedEnd[0] < 0.10f,
            rate, "natural tails attenuate slower than mutes; 150 ms slower than 20 ms",
            natural[0] - muted[0]);
      std::printf("        gain at 140 ms: natural %.4f/%.4f, mute %.4f/%.4f (20/150 ms); "
                  "at 300 ms: natural %.4f/%.4f, mute %.4f/%.4f\n",
                   natural[0], natural[1], muted[0], muted[1],
                   naturalEnd[0], naturalEnd[1], mutedEnd[0], mutedEnd[1]);
    }

    // Long Release must not mistake a gradual low-string decay for a mute.
    {
      float gainAt300[2] = {};
      for (int kind = 0; kind < 3; ++kind) {
        const float release = kind == 0 ? 150.0f : 1000.0f;
        const double decayMs = kind == 2 ? 300.0 : 40.0;
        Gate tail, mute;
        tail.configure(rate, kThresholdDb, release);
        mute.configure(rate, kThresholdDb, release);
        const int warmup = samples(rate, 300.0);
        for (int i = 0; i < warmup; ++i) {
          const float x = kOpen * 1.5f *
              std::cos(2.0 * kPi * 31.0 * (i - warmup) / rate);
          tail.process(x);
          mute.process(x);
        }
        const double endMs = kind == 2 ? 600.0 : 140.0;
        float minimumGain = 1.0f, minimumMargin = 1.0f;
        bool finite = true;
        for (int i = 0; i < samples(rate, kind == 2 ? 900.0 : 300.0); ++i) {
          const double ms = (i + 1) * 1000.0 / rate;
          const float x = kOpen * 1.5f * std::exp(-ms / decayMs) *
              std::cos(2.0 * kPi * 31.0 * i / rate);
          const float y = tail.process(x);
          const float muteGain = mute.process(kOpen * 0.03f) / (kOpen * 0.03f);
          finite &= std::isfinite(y) && std::isfinite(muteGain);
          if (std::fabs(x) <= kOpen * 1.0e-4f) continue;
          const float gain = y / x;
          if (ms >= endMs - 20.0 && ms <= endMs) {
            minimumGain = std::min(minimumGain, gain);
            minimumMargin = std::min(minimumMargin, gain - muteGain);
          }
          if (kind < 2 && i + 1 == samples(rate, 300.0)) gainAt300[kind] = gain;
        }
        check(finite && minimumGain > 0.98f &&
                  minimumMargin > (kind == 1 ? 0.08f : 0.30f), rate,
              "31 Hz natural decay retains smooth gain longer than an abrupt mute",
              minimumGain);
        std::printf("        %.0f ms decay / %.0f ms release: minimum gain margin %.4f\n",
                    decayMs, release, minimumMargin);
      }
      check(gainAt300[1] > gainAt300[0] + 0.15f, rate,
            "31 Hz / 40 ms decay closes more gently at 1000 ms than 150 ms release",
            gainAt300[1] - gainAt300[0]);
    }

    // Reconfigure once per block, including one-sample blocks and boundaries
    // inside onset qualification, hold, mute detection, and release.
    {
      std::vector<float> input(samples(rate, 900.0));
      uint32_t state = 0xabcdef01u;
      for (size_t i = 0; i < input.size(); ++i) {
        const double ms = i * 1000.0 / rate;
        const double phase = std::fmod(ms - 300.0, 120.0);
        input[i] = ms < 300.0 || phase >= 40.0 ? kOpen * 0.03f * noise(state)
            : kOpen * 1.5f * std::cos(2.0 * kPi * 82.0 * i / rate);
      }
      const size_t irregular[] = {1, 7, 64, 3, 511, 29, 128};
      auto render = [&](int mode) {
        Gate gate;
        std::vector<float> output(input.size());
        size_t offset = 0, block = 0;
        while (offset < input.size()) {
          const size_t length = mode == 0 ? input.size() : mode == 1 ? 1
              : irregular[block++ % 7];
          const size_t end = std::min(input.size(), offset + length);
          gate.configure(rate, kThresholdDb, 20.0f);
          while (offset < end) {
            output[offset] = gate.process(input[offset]);
            ++offset;
          }
        }
        return output;
      };
      const auto whole = render(0), singles = render(1), chunks = render(2);
      const size_t bytes = whole.size() * sizeof(float);
      check(std::memcmp(whole.data(), singles.data(), bytes) == 0 &&
                std::memcmp(whole.data(), chunks.data(), bytes) == 0,
            rate, "identical configure calls preserve state at any block size", 0.0);
    }

    {
      bool safe = true;
      float maximumExcess = 0.0f;
      const float tiny = std::numeric_limits<float>::denorm_min();
      const float probes[] = {0.0f, -0.0f, tiny, -tiny, 1.0e-20f, -1.0e-20f,
                              kOpen * 0.03f, -kOpen * 1.3f, 1.0f, -4.0f};
      uint32_t state = 0x87654321u;
      Gate gate;
      for (float threshold : {-79.98f, -60.0f, -40.0f, -12.0f, 0.0f, -80.0f}) {
        for (float release : {20.0f, 150.0f}) {
          for (int i = 0; i < samples(rate, 200.0); ++i) {
            if (i % 64 == 0) gate.configure(rate, threshold, release);
            const float x = i % 2 == 0 ? probes[(i / 2) % 10] : 4.0f * noise(state);
            const float y = gate.process(x);
            safe &= std::isfinite(y) && (x >= 0.0f ? y >= 0.0f : y <= 0.0f);
            maximumExcess = std::max(maximumExcess, std::fabs(y) - std::fabs(x));
            // Multiplicative, latency-free attenuation cannot emit on silence.
            if (x == 0.0f) safe &= y == 0.0f;
          }
        }
      }
      check(safe && maximumExcess <= 1.0e-6f, rate,
            "finite inputs stay finite, sign-preserving and bounded without latency",
            maximumExcess);
    }
  }
  std::printf("\n%s (%d failures)\n", failures ? "FAILED" : "ALL PASSED", failures);
  return failures ? 1 : 0;
}
