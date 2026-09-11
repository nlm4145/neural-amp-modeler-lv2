#include "speaker_dynamics.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

static int failures = 0;
#define CHECK(c, m) do { if (c) std::printf("  PASS  %s\n", m); else { ++failures; std::printf("  FAIL  %s\n", m); } } while (0)

static std::vector<float> signal(size_t count, double rate) {
  std::vector<float> x(count);
  for (size_t i = 0; i < count; ++i) {
    const double t = i / rate;
    x[i] = static_cast<float>(0.34 * std::sin(2.0 * M_PI * 82.0 * t) +
                              0.17 * std::sin(2.0 * M_PI * 220.0 * t) +
                              0.08 * std::sin(2.0 * M_PI * 3100.0 * t));
  }
  return x;
}

static double difference(const std::vector<float>& a, const std::vector<float>& b) {
  double sum = 0.0;
  for (size_t i = 0; i < a.size(); ++i) sum += std::fabs(a[i] - b[i]);
  return sum;
}

int main() {
  for (double rate : {48000.0, 768000.0}) {
    auto input = signal(8192, rate);
    auto output = input;
    NAMRig::SpeakerDynamics speaker;
    speaker.process(output.data(), output.size(), rate, NAMRig::SpeakerDynamics::kCaptured,
                    100.0f, 100.0f, 100.0f, 100.0f);
    CHECK(std::memcmp(input.data(), output.data(), input.size() * sizeof(float)) == 0,
          rate < 100000.0 ? "Captured/Off is bit-exact at 48 kHz"
                          : "Captured/Off is bit-exact at 768 kHz");
  }

  for (int profile = NAMRig::SpeakerDynamics::kResistive;
       profile < NAMRig::SpeakerDynamics::kProfileCount; ++profile) {
    for (double rate : {48000.0, 96000.0, 768000.0}) {
      auto output = signal(16384, rate);
      NAMRig::SpeakerDynamics speaker;
      speaker.process(output.data(), output.size(), rate, profile,
                      100.0f, 100.0f, 100.0f, 100.0f);
      bool finite = true;
      float peak = 0.0f;
      for (float x : output) { finite &= std::isfinite(x); peak = std::max(peak, std::fabs(x)); }
      CHECK(finite && peak < 4.0f, "profile remains finite and bounded");
    }
  }

  auto input = signal(32768, 96000.0);
  auto mild = input, strong = input;
  NAMRig::SpeakerDynamics a, b;
  a.process(mild.data(), mild.size(), 96000.0, NAMRig::SpeakerDynamics::kModern412,
            0.0f, 0.0f, 0.0f, 0.0f);
  b.process(strong.data(), strong.size(), 96000.0, NAMRig::SpeakerDynamics::kModern412,
            100.0f, 100.0f, 100.0f, 100.0f);
  CHECK(difference(input, mild) < 1.0e-6, "zero amounts leave an enabled profile neutral");
  CHECK(difference(input, strong) > 10.0, "speaker controls audibly alter the signal");

  auto whole = signal(32768, 96000.0), chunked = whole;
  NAMRig::SpeakerDynamics wholeSpeaker, chunkedSpeaker;
  wholeSpeaker.process(whole.data(), whole.size(), 96000.0,
                       NAMRig::SpeakerDynamics::kOpenBack,
                       70.0f, 65.0f, 80.0f, 75.0f);
  const size_t chunks[] = {1, 7, 64, 3, 511, 29, 128};
  size_t offset = 0, chunk = 0;
  while (offset < chunked.size()) {
    const size_t n = std::min(chunks[chunk++ % 7], chunked.size() - offset);
    chunkedSpeaker.process(chunked.data() + offset, n, 96000.0,
                           NAMRig::SpeakerDynamics::kOpenBack,
                           70.0f, 65.0f, 80.0f, 75.0f);
    offset += n;
  }
  CHECK(difference(whole, chunked) < 1.0e-5,
        "processing is invariant to host block boundaries");

  CHECK(NAMRig::SpeakerDynamics::profileFromCabPath("/IRs/Mesa Oversized V30.wav") ==
            NAMRig::SpeakerDynamics::kModern412,
        "Auto associates Mesa/V30 cabinets with Modern 4x12");
  CHECK(NAMRig::SpeakerDynamics::profileFromCabPath("/IRs/Marshall Greenback G12M.wav") ==
            NAMRig::SpeakerDynamics::kUK412,
        "Auto associates Greenback cabinets with UK 4x12");
  CHECK(NAMRig::SpeakerDynamics::profileFromCabPath("/IRs/Blue Alnico Open Back.wav") ==
            NAMRig::SpeakerDynamics::kVintageAlnico,
        "Auto precedence selects Vintage Alnico");
  CHECK(NAMRig::SpeakerDynamics::profileFromCabPath("/IRs/unknown.wav") ==
            NAMRig::SpeakerDynamics::kResistive,
        "Auto falls back to Resistive");

  std::printf(failures ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n", failures);
  return failures ? 1 : 0;
}
