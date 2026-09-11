// Verifies the post-cabinet space effects in src/space_fx.h:
//   AlignDelay  - Cab B phase alignment (0..10 ms)
//   StereoDelay - damped, soft-limited feedback delay
//   PlateReverb - Dattorro tank plus a diffused early-reflection cluster
//
// Replaces the old verify_stereo_space.cpp: Width is no longer a Haas delay
// (it moved into the cabinet mixer in nam_rig_plugin.cpp, guarded by
// tests/test_stereo_output_contract.py), and Room is now this reverb's early
// reflections rather than four fixed taps.
//
// Build: clang++ -O2 -std=c++17 -Isrc tests/verify_space_fx.cpp
#include "space_fx.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

namespace {
constexpr double kPi = 3.14159265358979323846;

int failures = 0;
void check(bool ok, const char* label) {
  std::printf("  %s  %s\n", ok ? "PASS" : "FAIL", label);
  if (!ok) ++failures;
}

bool allFinite(const std::vector<float>& x) {
  for (float v : x) if (!std::isfinite(v)) return false;
  return true;
}

double energy(const std::vector<float>& x, size_t begin, size_t end) {
  double sum = 0.0;
  for (size_t i = begin; i < std::min(end, x.size()); ++i)
    sum += static_cast<double>(x[i]) * x[i];
  return sum;
}

// Energy above roughly 4 kHz, via a crude one-pole complement. Enough to
// prove a damping control is doing something in the right direction.
double highEnergy(const std::vector<float>& x, double rate) {
  const double coeff = 1.0 - std::exp(-2.0 * kPi * 4000.0 / rate);
  double low = 0.0, sum = 0.0;
  for (float v : x) {
    low += (v - low) * coeff;
    const double high = v - low;
    sum += high * high;
  }
  return sum;
}

std::vector<float> impulse(size_t count) {
  std::vector<float> x(count, 0.0f);
  x[0] = 1.0f;
  return x;
}

std::vector<float> tone(size_t count, double rate, double frequency) {
  std::vector<float> x(count);
  for (size_t i = 0; i < count; ++i)
    x[i] = 0.25f * std::sin(2.0 * kPi * frequency * i / rate);
  return x;
}
} // namespace

int main() {
  constexpr double rate = 96000.0;

  // ---- DelayLine bounds safety -------------------------------------------
  {
    NAMRig::DelayLine line;
    line.allocate(64);
    for (int i = 0; i < 200; ++i) line.write(static_cast<float>(i));
    // A stale control value must clamp, never read outside the buffer.
    const float far = line.read(1'000'000);
    const float farFrac = line.readFrac(1.0e9);
    const float zero = line.readFrac(0.0);
    check(std::isfinite(far) && std::isfinite(farFrac) && std::isfinite(zero),
          "DelayLine clamps out-of-range reads instead of reading past the end");
    check(line.capacity() == 64,
          "DelayLine reports the usable capacity it was allocated for");
  }

  // ---- AlignDelay --------------------------------------------------------
  {
    NAMRig::AlignDelay align;
    align.initialize(rate, 10.0);
    auto left = impulse(4096), right = impulse(4096);
    const auto reference = left;
    align.process(left.data(), right.data(), left.size(), 0.0f);
    check(std::memcmp(left.data(), reference.data(),
                      left.size() * sizeof(float)) == 0,
          "AlignDelay at 0 ms is bit-transparent");
  }
  {
    NAMRig::AlignDelay align;
    align.initialize(rate, 10.0);
    auto left = impulse(4096), right = impulse(4096);
    align.process(left.data(), right.data(), left.size(), 5.0f);
    size_t peak = 0;
    for (size_t i = 0; i < left.size(); ++i)
      if (std::fabs(left[i]) > std::fabs(left[peak])) peak = i;
    const size_t expected = static_cast<size_t>(rate * 0.005);
    // The control glides, so the first block lands on the target only because
    // the line primes itself on its first call.
    check(peak == expected,
          "AlignDelay places the impulse at exactly the requested 5 ms");
    check(std::fabs(left[peak] - 1.0f) < 1.0e-5f,
          "AlignDelay preserves the impulse amplitude");
  }
  {
    // A request beyond the allocation must clamp to the maximum, not wrap.
    NAMRig::AlignDelay align;
    align.initialize(rate, 10.0);
    auto left = impulse(8192), right = impulse(8192);
    align.process(left.data(), right.data(), left.size(), 1000.0f);
    size_t peak = 0;
    for (size_t i = 0; i < left.size(); ++i)
      if (std::fabs(left[i]) > std::fabs(left[peak])) peak = i;
    check(allFinite(left) && peak <= static_cast<size_t>(rate * 0.010) + 2,
          "AlignDelay clamps an over-range request to its maximum");
  }

  // ---- StereoDelay ------------------------------------------------------
  {
    NAMRig::StereoDelay delay;
    delay.initialize(rate);
    auto left = impulse(96000), right = impulse(96000);
    const auto reference = left;
    delay.process(left.data(), right.data(), left.size(), 400.0f, 50.0f, 40.0f,
                  0.0f);
    check(std::memcmp(left.data(), reference.data(),
                      left.size() * sizeof(float)) == 0,
          "StereoDelay at Mix 0 is bit-transparent");
  }
  {
    NAMRig::StereoDelay delay;
    delay.initialize(rate);
    auto left = impulse(96000), right = impulse(96000);
    delay.process(left.data(), right.data(), left.size(), 100.0f, 50.0f, 40.0f,
                  100.0f);
    const size_t tap = static_cast<size_t>(rate * 0.1);
    const double first = energy(left, tap - 8, tap + 8);
    const double second = energy(left, 2 * tap - 8, 2 * tap + 8);
    const double third = energy(left, 3 * tap - 8, 3 * tap + 8);
    check(allFinite(left) && first > 0.1 && second < first && third < second &&
              third > 0.0,
          "StereoDelay repeats at the requested time and decays");
  }
  {
    // Damping must remove treble from the repeats, not the dry signal.
    NAMRig::StereoDelay bright, dark;
    bright.initialize(rate);
    dark.initialize(rate);
    auto brightL = impulse(48000), brightR = impulse(48000);
    auto darkL = impulse(48000), darkR = impulse(48000);
    bright.process(brightL.data(), brightR.data(), brightL.size(), 50.0f, 70.0f,
                   0.0f, 100.0f);
    dark.process(darkL.data(), darkR.data(), darkL.size(), 50.0f, 70.0f, 100.0f,
                 100.0f);
    const size_t tail = static_cast<size_t>(rate * 0.06);
    std::vector<float> brightTail(brightL.begin() + tail, brightL.end());
    std::vector<float> darkTail(darkL.begin() + tail, darkL.end());
    check(highEnergy(darkTail, rate) < highEnergy(brightTail, rate) * 0.5,
          "StereoDelay damping darkens the repeats");
  }
  {
    // Maximum feedback must be soft-limited, never a runaway.
    NAMRig::StereoDelay delay;
    delay.initialize(rate);
    auto left = tone(static_cast<size_t>(rate * 4.0), rate, 220.0);
    auto right = left;
    delay.process(left.data(), right.data(), left.size(), 60.0f, 100.0f, 30.0f,
                  100.0f);
    float peak = 0.0f;
    for (float v : left) peak = std::max(peak, std::fabs(v));
    check(allFinite(left) && peak < 4.0f,
          "StereoDelay feedback at 100% stays finite and soft-limited");
  }
  {
    NAMRig::StereoDelay whole, split;
    whole.initialize(rate);
    split.initialize(rate);
    auto wholeL = tone(48000, rate, 317.0), wholeR = wholeL;
    auto splitL = wholeL, splitR = wholeL;
    whole.process(wholeL.data(), wholeR.data(), wholeL.size(), 120.0f, 45.0f,
                  35.0f, 60.0f);
    const size_t blocks[] = {1, 17, 64, 511, 128, 3, 997};
    size_t offset = 0, index = 0;
    while (offset < splitL.size()) {
      const size_t n = std::min(blocks[index++ % 7], splitL.size() - offset);
      split.process(splitL.data() + offset, splitR.data() + offset, n, 120.0f,
                    45.0f, 35.0f, 60.0f);
      offset += n;
    }
    float worst = 0.0f;
    for (size_t i = 0; i < wholeL.size(); ++i)
      worst = std::max(worst, std::fabs(wholeL[i] - splitL[i]));
    check(worst < 1.0e-6f,
          "StereoDelay is invariant to host block boundaries");
  }

  // ---- PlateReverb ------------------------------------------------------
  {
    NAMRig::PlateReverb reverb;
    reverb.initialize(rate);
    auto left = impulse(48000), right = impulse(48000);
    const auto reference = left;
    reverb.process(left.data(), right.data(), left.size(), 0.0f, 0.0f, 50.0f,
                   50.0f, 50.0f, 10.0f);
    check(std::memcmp(left.data(), reference.data(),
                      left.size() * sizeof(float)) == 0,
          "PlateReverb at Room 0 / Mix 0 is bit-transparent");
  }
  {
    NAMRig::PlateReverb reverb;
    reverb.initialize(rate);
    auto left = impulse(static_cast<size_t>(rate * 2.0));
    auto right = left;
    reverb.process(left.data(), right.data(), left.size(), 0.0f, 100.0f, 100.0f,
                   100.0f, 0.0f, 0.0f);
    const size_t span = static_cast<size_t>(rate * 0.15);
    const double first = energy(left, span, 2 * span);
    const double middle = energy(left, 6 * span, 7 * span);
    const double last = energy(left, 11 * span, 12 * span);
    check(allFinite(left) && first > middle && middle > last && last > 1.0e-9,
          "PlateReverb tail decays monotonically and stays finite");
    double difference = 0.0;
    for (size_t i = 0; i < left.size(); ++i)
      difference += std::fabs(left[i] - right[i]);
    check(difference > 1.0,
          "PlateReverb output is decorrelated between channels");
  }
  {
    // Room must give early reflections WITHOUT the long tank tail, so it is
    // usable on its own as a tight cabinet room.
    NAMRig::PlateReverb reverb;
    reverb.initialize(rate);
    auto left = impulse(static_cast<size_t>(rate * 1.0));
    auto right = left;
    reverb.process(left.data(), right.data(), left.size(), 100.0f, 0.0f, 100.0f,
                   50.0f, 50.0f, 0.0f);
    const double early = energy(left, 1, static_cast<size_t>(rate * 0.08));
    const double late = energy(left, static_cast<size_t>(rate * 0.4),
                               left.size());
    check(allFinite(left) && early > 1.0e-6 && late < early * 1.0e-3,
          "Room alone gives early reflections with no long tank tail");
  }
  {
    // Decay and size must both extend the tail; damping must darken it.
    const auto tailEnergy = [&](float decay, float size, float damping) {
      NAMRig::PlateReverb reverb;
      reverb.initialize(rate);
      auto left = impulse(static_cast<size_t>(rate * 2.0));
      auto right = left;
      reverb.process(left.data(), right.data(), left.size(), 0.0f, 100.0f,
                     decay, size, damping, 0.0f);
      return energy(left, static_cast<size_t>(rate * 1.0), left.size());
    };
    check(tailEnergy(100.0f, 50.0f, 0.0f) > tailEnergy(0.0f, 50.0f, 0.0f) * 4.0,
          "Reverb Decay lengthens the tail");
    check(tailEnergy(80.0f, 100.0f, 0.0f) > tailEnergy(80.0f, 0.0f, 0.0f),
          "Reverb Size lengthens the tail");

    const auto tailHigh = [&](float damping) {
      NAMRig::PlateReverb reverb;
      reverb.initialize(rate);
      auto left = impulse(static_cast<size_t>(rate * 1.0));
      auto right = left;
      reverb.process(left.data(), right.data(), left.size(), 0.0f, 100.0f,
                     90.0f, 50.0f, damping, 0.0f);
      std::vector<float> tail(left.begin() + static_cast<size_t>(rate * 0.2),
                              left.end());
      return highEnergy(tail, rate);
    };
    check(tailHigh(100.0f) < tailHigh(0.0f) * 0.5,
          "Reverb Damping darkens the tail");
  }
  {
    // Pre-delay must hold the wet signal back so the pick attack stays clear.
    NAMRig::PlateReverb reverb;
    reverb.initialize(rate);
    auto left = impulse(static_cast<size_t>(rate * 0.5));
    auto right = left;
    reverb.process(left.data(), right.data(), left.size(), 100.0f, 100.0f,
                   80.0f, 50.0f, 0.0f, 50.0f);
    const size_t quiet = static_cast<size_t>(rate * 0.04);
    check(energy(left, 1, quiet) < 1.0e-7,
          "Reverb Pre-Delay keeps the first 40 ms after the attack clean");
  }
  {
    NAMRig::PlateReverb whole, split;
    whole.initialize(rate);
    split.initialize(rate);
    auto wholeL = tone(48000, rate, 317.0), wholeR = wholeL;
    auto splitL = wholeL, splitR = wholeL;
    whole.process(wholeL.data(), wholeR.data(), wholeL.size(), 62.0f, 48.0f,
                  55.0f, 40.0f, 35.0f, 12.0f);
    const size_t blocks[] = {1, 17, 64, 511, 128, 3, 997};
    size_t offset = 0, index = 0;
    while (offset < splitL.size()) {
      const size_t n = std::min(blocks[index++ % 7], splitL.size() - offset);
      split.process(splitL.data() + offset, splitR.data() + offset, n, 62.0f,
                    48.0f, 55.0f, 40.0f, 35.0f, 12.0f);
      offset += n;
    }
    float worst = 0.0f;
    for (size_t i = 0; i < wholeL.size(); ++i) {
      worst = std::max(worst, std::fabs(wholeL[i] - splitL[i]));
      worst = std::max(worst, std::fabs(wholeR[i] - splitR[i]));
    }
    check(worst < 1.0e-6f,
          "PlateReverb is invariant to host block boundaries");
  }
  {
    // Re-engaging after a bypass must start from silence, not from a stale
    // tank full of the previous take.
    NAMRig::PlateReverb reverb;
    reverb.initialize(rate);
    auto loudL = tone(48000, rate, 220.0), loudR = loudL;
    reverb.process(loudL.data(), loudR.data(), loudL.size(), 0.0f, 100.0f,
                   100.0f, 50.0f, 0.0f, 0.0f);
    // Mix glides to zero instead of cutting the tail, so the first block at
    // Mix 0 still runs the tank; the next fully-bypassed block clears it.
    std::vector<float> glideL(24000, 0.0f), glideR(24000, 0.0f);
    reverb.process(glideL.data(), glideR.data(), glideL.size(), 0.0f, 0.0f,
                   100.0f, 50.0f, 0.0f, 0.0f);
    std::vector<float> offL(24000, 0.0f), offR(24000, 0.0f);
    reverb.process(offL.data(), offR.data(), offL.size(), 0.0f, 0.0f, 100.0f,
                   50.0f, 0.0f, 0.0f);
    check(energy(offL, 0, offL.size()) == 0.0,
          "PlateReverb stops writing once Mix has glided to zero");
    std::vector<float> backL(24000, 0.0f), backR(24000, 0.0f);
    reverb.process(backL.data(), backR.data(), backL.size(), 0.0f, 100.0f,
                   100.0f, 50.0f, 0.0f, 0.0f);
    check(energy(backL, 0, backL.size()) < 1.0e-12,
          "PlateReverb clears its tank once bypassed, so re-engaging starts silent");
  }

  // ---- Session rates other than 96 kHz ----------------------------------
  for (double sessionRate : {44100.0, 48000.0, 192000.0}) {
    NAMRig::PlateReverb reverb;
    NAMRig::StereoDelay delay;
    NAMRig::AlignDelay align;
    reverb.initialize(sessionRate);
    delay.initialize(sessionRate);
    align.initialize(sessionRate, 10.0);
    auto left = tone(static_cast<size_t>(sessionRate * 0.5), sessionRate, 196.0);
    auto right = left;
    align.process(left.data(), right.data(), left.size(), 3.5f);
    delay.process(left.data(), right.data(), left.size(), 250.0f, 60.0f, 50.0f,
                  70.0f);
    reverb.process(left.data(), right.data(), left.size(), 70.0f, 70.0f, 70.0f,
                   70.0f, 40.0f, 20.0f);
    float peak = 0.0f;
    for (float v : left) peak = std::max(peak, std::fabs(v));
    char label[96];
    std::snprintf(label, sizeof(label),
                  "the full space chain is finite and bounded at %.0f Hz",
                  sessionRate);
    check(allFinite(left) && allFinite(right) && peak < 4.0f, label);
  }

  std::printf(failures ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n",
              failures);
  return failures ? 1 : 0;
}
