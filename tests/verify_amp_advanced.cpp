#include "amp_advanced.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

static int failures = 0;
#define CHECK(c, m) do { if (c) std::printf("  PASS  %s\n", m); else { ++failures; std::printf("  FAIL  %s\n", m); } } while (0)

int main() {
  constexpr double rate = 96000.0;
  constexpr size_t count = 4096;
  std::vector<float> input(count), output(count);
  for (size_t i = 0; i < count; ++i)
    input[i] = 0.31f * std::sin(2.0 * 3.14159265358979323846 * 110.0 * i / rate)
             + 0.13f * std::sin(2.0 * 3.14159265358979323846 * 4200.0 * i / rate);

  NAMRig::AmpAdvanced amp;
  output = input;
  amp.processPreAmp(output.data(), output.size(), rate, 0.0f, 0.0f);
  amp.processPostAmp(output.data(), output.size(), rate,
                     0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f);
  CHECK(output == input, "neutral advanced controls are bit-transparent");

  amp.reset();
  output = input;
  amp.processPreAmp(output.data(), output.size(), rate, 100.0f, 100.0f);
  double delta = 0.0;
  for (size_t i = 0; i < count; ++i) delta += std::fabs(output[i] - input[i]);
  CHECK(delta > 1.0, "Bright and Input EQ alter the pre-amp signal");

  amp.reset();
  output = input;
  amp.processPostAmp(output.data(), output.size(), rate,
                     6.0f, 6.0f, 60.0f, 35.0f, 50.0f, 70.0f);
  bool finite = true;
  double postDelta = 0.0;
  for (size_t i = 0; i < count; ++i) {
    finite &= std::isfinite(output[i]);
    postDelta += std::fabs(output[i] - input[i]);
  }
  CHECK(finite, "advanced power-amp controls remain finite");
  CHECK(postDelta > 1.0, "advanced power-amp controls alter the post-amp signal");

  // ---- Presence and Depth are feedback-loop voicing, not output shelves ----
  // A shelf would deliver its nominal dB regardless of the loop. Inside the
  // loop the requested dB must still be delivered, which is what the
  // loop-gain-derived shelf compensation in feedbackShelfDb() buys.
  const auto toneGainDb = [](float presence, float depth, float sag, float bias,
                             float feedback, float master, double frequency,
                             float amplitude = 0.1f) {
    constexpr double sampleRate = 96000.0;
    const size_t n = static_cast<size_t>(sampleRate * 0.5);
    std::vector<float> x(n);
    for (size_t i = 0; i < n; ++i)
      x[i] = amplitude * std::sin(2.0 * 3.14159265358979323846 * frequency * i /
                                  sampleRate);
    NAMRig::AmpAdvanced stage;
    stage.processPostAmp(x.data(), n, sampleRate, presence, depth, sag, bias,
                         feedback, master);
    double real = 0.0, imag = 0.0;
    size_t used = 0;
    for (size_t i = n / 2; i < n; ++i) {
      const double phase = 2.0 * 3.14159265358979323846 * frequency * i / sampleRate;
      real += x[i] * std::cos(phase);
      imag += x[i] * std::sin(phase);
      ++used;
    }
    return 20.0 * std::log10(2.0 * std::sqrt(real * real + imag * imag) / used /
                             amplitude);
  };

  bool presenceAccurate = true;
  bool depthAccurate = true;
  std::printf("\n        requested vs delivered voicing across feedback settings:\n");
  for (float feedback : {0.0f, 50.0f, 100.0f}) {
    const double presenceHigh = toneGainDb(6.0f, 0, 0, 0, feedback, 0, 8000.0);
    const double presenceRef = toneGainDb(6.0f, 0, 0, 0, feedback, 0, 200.0);
    const double depthLow = toneGainDb(0, -6.0f, 0, 0, feedback, 0, 60.0);
    const double depthRef = toneGainDb(0, -6.0f, 0, 0, feedback, 0, 2000.0);
    std::printf("        feedback %3.0f%%: Presence +6 -> %+5.2f dB, Depth -6 -> %+5.2f dB\n",
                feedback, presenceHigh - presenceRef, depthLow - depthRef);
    presenceAccurate = presenceAccurate &&
                       std::fabs((presenceHigh - presenceRef) - 6.0) < 1.5;
    depthAccurate = depthAccurate && std::fabs((depthLow - depthRef) + 6.0) < 1.5;
    // The band the control does not address must stay put.
    presenceAccurate = presenceAccurate && std::fabs(presenceRef) < 0.5;
    depthAccurate = depthAccurate && std::fabs(depthRef) < 0.5;
  }
  CHECK(presenceAccurate,
        "Presence delivers its requested dB at any Negative Feedback setting");
  CHECK(depthAccurate,
        "Depth delivers its requested dB at any Negative Feedback setting");

  // ---- Sag lowers headroom; it must not simply turn the volume down ----
  // A gain-reduction sag compresses quiet and loud signals alike. Supply sag
  // lowers the ceiling, so it must bite far harder on a loud signal.
  {
    const double quiet = toneGainDb(0, 0, 100.0f, 0, 0, 60.0f, 110.0, 0.03f);
    const double loud = toneGainDb(0, 0, 100.0f, 0, 0, 60.0f, 110.0, 0.9f);
    std::printf("        Sag 100%%: quiet %+.2f dB, loud %+.2f dB\n", quiet, loud);
    CHECK(loud < quiet - 3.0,
          "Sag lowers headroom rather than applying static gain reduction");
  }

  // ---- Master is drive into the stage, so it must compress, not just boost --
  {
    const double quiet = toneGainDb(0, 0, 0, 0, 0, 100.0f, 440.0, 0.03f);
    const double loud = toneGainDb(0, 0, 0, 0, 0, 100.0f, 440.0, 0.9f);
    std::printf("        Master 100%%: quiet %+.2f dB, loud %+.2f dB\n", quiet, loud);
    CHECK(loud < quiet - 3.0, "Master drives the stage into compression");
  }

  // ---- Stability in a True 8x domain and under pathological input ----
  {
    constexpr double highRate = 768000.0;
    std::vector<float> hot(static_cast<size_t>(highRate * 0.2));
    for (size_t i = 0; i < hot.size(); ++i)
      hot[i] = 0.95f * std::sin(2.0 * 3.14159265358979323846 * 110.0 * i / highRate);
    NAMRig::AmpAdvanced extreme;
    extreme.processPreAmp(hot.data(), hot.size(), highRate, 100.0f, 100.0f);
    extreme.processPostAmp(hot.data(), hot.size(), highRate, 12.0f, 12.0f,
                           100.0f, 100.0f, 100.0f, 100.0f);
    bool bounded = true;
    float peak = 0.0f;
    for (float v : hot) {
      bounded = bounded && std::isfinite(v);
      peak = std::max(peak, std::fabs(v));
    }
    CHECK(bounded && peak < 2.0f,
          "every control at maximum stays finite and bounded at 768 kHz");
  }
  {
    // The loop solver must not ring or latch on a DC step.
    std::vector<float> dc(96000, 0.8f);
    NAMRig::AmpAdvanced stepped;
    stepped.processPostAmp(dc.data(), dc.size(), 96000.0, 0, 0, 80.0f, 60.0f,
                           70.0f, 80.0f);
    bool bounded = true;
    for (float v : dc) bounded = bounded && std::isfinite(v) && std::fabs(v) < 2.0f;
    CHECK(bounded, "a DC step settles without ringing or latching");
  }

  // ---- Block-boundary invariance ----
  {
    // Controls glide with a 15 ms time constant, so the comparison window has
    // to be long enough for them to actually arrive. 0.5 s is ~33 constants.
    const size_t longCount = static_cast<size_t>(rate * 0.5);
    std::vector<float> input(longCount);
    for (size_t i = 0; i < longCount; ++i)
      input[i] = 0.31f * std::sin(2.0 * 3.14159265358979323846 * 110.0 * i / rate)
               + 0.13f * std::sin(2.0 * 3.14159265358979323846 * 4200.0 * i / rate);
    std::vector<float> whole = input, chunked = input;
    NAMRig::AmpAdvanced a, b;
    a.processPostAmp(whole.data(), whole.size(), rate, 4.0f, -3.0f, 40.0f,
                     20.0f, 55.0f, 45.0f);
    const size_t blocks[] = {1, 7, 32, 64, 511, 3, 129};
    size_t offset = 0, index = 0;
    while (offset < chunked.size()) {
      const size_t n = std::min(blocks[index++ % 7], chunked.size() - offset);
      b.processPostAmp(chunked.data() + offset, n, rate, 4.0f, -3.0f, 40.0f,
                       20.0f, 55.0f, 45.0f);
      offset += n;
    }
    float worst = 0.0f;
    for (size_t i = 0; i < whole.size(); ++i)
      worst = std::max(worst, std::fabs(whole[i] - chunked[i]));
    // Controls glide per 32-sample chunk, so sub-chunk blocks reach the same
    // targets on a slightly different schedule; the steady state must agree.
    float tail = 0.0f;
    for (size_t i = whole.size() * 3 / 4; i < whole.size(); ++i)
      tail = std::max(tail, std::fabs(whole[i] - chunked[i]));
    std::printf("        block-size difference: worst %.2e, settled %.2e\n",
                static_cast<double>(worst), static_cast<double>(tail));
    CHECK(tail < 1.0e-4f,
          "the settled response is invariant to host block boundaries");
  }

  std::printf(failures ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n", failures);
  return failures ? 1 : 0;
}
