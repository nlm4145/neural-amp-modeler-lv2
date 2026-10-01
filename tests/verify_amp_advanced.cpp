#include "amp_advanced.h"
#include "legacy_amp_post.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <limits>
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

  // Approaching neutral must also approach the bypassed signal. Previously an
  // infinitesimal Presence value enabled the entire baseline saturator, making
  // the exact-zero bypass a discontinuity for hot model output.
  {
    std::vector<float> nearInput(count, 1.5f), nearOutput = nearInput;
    NAMRig::AmpAdvanced nearNeutral;
    nearNeutral.processPostAmp(nearOutput.data(), nearOutput.size(), rate,
                               0.0001f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f);
    float worst = 0.0f;
    for (size_t i = count / 2; i < count; ++i)
      worst = std::max(worst, std::fabs(nearOutput[i] - nearInput[i]));
    CHECK(worst < 1.0e-3f,
          "the power stage approaches bypass continuously at neutral");
  }

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

  // Exact comparisons against independent legacy arithmetic, not two calls to
  // the new default path. Include startup smoothing and a partial final chunk.
  {
    bool capturedExact = true, zeroExact = true;
    for (double sampleRate : {44100.0, 48000.0, 96000.0, 768000.0}) {
      std::vector<float> signal(static_cast<size_t>(sampleRate * .2) + 7);
      for (size_t i = 0; i < signal.size(); ++i)
        signal[i] = 1.1f * std::sin(6.283185307179586 * 375 * i / sampleRate)
                  + .23f * std::sin(6.283185307179586 * 3200 * i / sampleRate);
      for (const auto& c : {std::array<float, 6>{}, {6, -4, 65, -35, 80, 70},
                            {-12, 12, 100, 100, 100, 100}, {4, -3, 0, 0, 0, 0}}) {
        auto reference = signal;
        LegacyAmp::AmpAdvanced legacy;
        legacy.processPostAmp(reference.data(), reference.size(), sampleRate,
            c[0], c[1], c[2], c[3], c[4], c[5]);
        for (int profile = 0; profile < NAMRig::PowerTube::kProfileCount; ++profile) {
          auto actual = signal;
          NAMRig::AmpAdvanced stage;
          stage.processPostAmp(actual.data(), actual.size(), sampleRate,
              c[0], c[1], c[2], c[3], c[4], c[5], profile, profile == 0 ? 100 : 0);
          if (profile == 0) capturedExact &= actual == reference;
          else zeroExact &= actual == reference;
        }
      }
    }
    CHECK(capturedExact, "Captured reproduces pre-Power/Tube DSP bit-for-bit across controls/rates");
    CHECK(zeroExact, "both active profiles at Character 0 reproduce legacy DSP bit-for-bit");
  }
  {
    constexpr double sampleRate = 48000;
    constexpr size_t n = 24000;
    std::array<std::vector<float>, 3> profiles;
    bool quietUnity = true, zeroNeutral = true;
    for (int profile = 0; profile < NAMRig::PowerTube::kProfileCount; ++profile) {
      std::vector<float> quiet(n), loud(n);
      for (size_t i = 0; i < n; ++i) {
        quiet[i] = .001f * std::sin(6.283185307179586 * 400 * i / sampleRate);
        loud[i] = 1.4f * std::sin(6.283185307179586 * 400 * i / sampleRate);
      }
      const auto dry = quiet;
      NAMRig::AmpAdvanced stage;
      stage.processPostAmp(quiet.data(), n, sampleRate, 0, 0, 0, 0, 0, 0, profile, 100);
      for (size_t i = n / 2; i < n; ++i) quietUnity &= std::fabs(quiet[i] - dry[i]) < 1e-7f;
      stage.reset();
      profiles[profile] = loud;
      stage.processPostAmp(profiles[profile].data(), n, sampleRate, 0, 0, 0, 0, 0, 0, profile, 100);
      stage.reset();
      stage.processPostAmp(loud.data(), n, sampleRate, 0, 0, 0, 0, 0, 0, profile, 0);
      zeroNeutral &= loud == profiles[0];
    }
    bool distinctShape = true;
    for (size_t a = 0; a < profiles.size(); ++a) {
      for (size_t b = a + 1; b < profiles.size(); ++b) {
        double dot = 0, aa = 0, bb = 0, residual = 0;
        for (size_t i = n / 2; i < n; ++i) {
          dot += static_cast<double>(profiles[a][i]) * profiles[b][i];
          aa += static_cast<double>(profiles[a][i]) * profiles[a][i];
          bb += static_cast<double>(profiles[b][i]) * profiles[b][i];
        }
        const double bestGain = dot / aa;
        for (size_t i = n / 2; i < n; ++i)
          residual += std::pow(profiles[b][i] - bestGain * profiles[a][i], 2);
        std::printf("        profiles %zu/%zu gain-matched shape residual %.4f\n", a, b, std::sqrt(residual / bb));
        distinctShape &= std::sqrt(residual / bb) > .01;
      }
    }
    CHECK(quietUnity, "all profiles retain quiet-signal unity without makeup gain");
    CHECK(zeroNeutral, "Character 0 is bit-transparent with otherwise neutral Power controls");
    CHECK(distinctShape, "Captured, 6L6 and EL34 differ in waveform shape, not merely loudness");
  }
  {
    bool finiteProfiles = true, sanitizesCharacter = true;
    for (double sampleRate : {8000.0, 44100.0, 48000.0, 96000.0, 192000.0, 768000.0}) {
      for (int profile : {-100, 0, 1, 2, 100}) {
        for (float character : {-100.0f, 0.0f, 50.0f, 100.0f, 10000.0f,
                                std::numeric_limits<float>::quiet_NaN(),
                                std::numeric_limits<float>::infinity()}) {
          std::vector<float> hot(static_cast<size_t>(sampleRate * .15));
          for (size_t i = 0; i < hot.size(); ++i) hot[i] = i % 3 == 0 ? 0 : i % 2 ? -16 : 16;
          NAMRig::AmpAdvanced stage;
          stage.processPostAmp(hot.data(), hot.size(), sampleRate, 100, -100,
                               10000, -10000, 10000, 10000, profile, character);
          // Presence/Depth can boost the unsaturated startup signal. This bound
          // allows that transient while rejecting runaway feedback/filter state.
          bool bounded = true;
          for (float x : hot) bounded &= std::isfinite(x) && std::fabs(x) < 128;
          if (!bounded) std::printf("        extreme failure: rate %g profile %d character %g\n", sampleRate, profile, character);
          finiteProfiles &= bounded;
        }
      }
    }
    for (float character : {std::numeric_limits<float>::quiet_NaN(),
                            std::numeric_limits<float>::infinity()}) {
      auto invalid = input, fallback = input;
      NAMRig::AmpAdvanced a, b;
      a.processPostAmp(invalid.data(), count, rate, 0, 0, 0, 0, 0, 0, 2, character);
      b.processPostAmp(fallback.data(), count, rate, 0, 0, 0, 0, 0, 0, 2, NAMRig::kPowerTubeCharacterDefault);
      sanitizesCharacter &= invalid == fallback;
    }
    CHECK(finiteProfiles, "tube profiles remain finite/bounded under extreme controls, inputs and 8..768 kHz rates");
    CHECK(sanitizesCharacter, "nonfinite Character uses the documented default exactly");
  }

  // Tube curves share the normalized supply envelope and feedback filters.
  // Changing curves must not require resetting those established Power states.
  {
    bool bounded = true, quiet = true, zeroExact = true;
    double worstRatio = 0;
    for (double sampleRate : {48000.0, 768000.0}) {
      const size_t n = static_cast<size_t>(sampleRate * .15);
      for (float presence : {-12.0f, 12.0f}) {
        for (float depth : {-12.0f, 12.0f}) {
          for (const auto& dynamic : {std::array<float, 2>{-100, 0}, {-100, 100},
                                      {100, 0}, {100, 100}}) {
            for (float character : {0.0f, 100.0f}) {
              NAMRig::AmpAdvanced stage;
              LegacyAmp::AmpAdvanced legacy;
              size_t position = 0;
              const auto render = [&](int profile, bool silence) {
                std::vector<float> x(n);
                for (float& value : x) {
                  const double t = static_cast<double>(position++) / sampleRate;
                  value = silence ? 0 : static_cast<float>(
                      1.2 * std::sin(6.283185307179586 * 83 * t) +
                       .6 * std::sin(6.283185307179586 * 997 * t));
                }
                auto reference = x;
                stage.processPostAmp(x.data(), n, sampleRate, presence, depth, 100,
                                     dynamic[0], dynamic[1], 100, profile, character);
                legacy.processPostAmp(reference.data(), n, sampleRate, presence, depth,
                                      100, dynamic[0], dynamic[1], 100);
                if (character == 0) zeroExact &= x == reference;
                return x;
              };
              std::vector<float> previous;
              for (int warm = 0; warm < 4; ++warm) previous = render(NAMRig::PowerTube::k6L6, false);
              for (int profile : {NAMRig::PowerTube::kEL34, NAMRig::PowerTube::k6L6,
                                  NAMRig::PowerTube::kCaptured, NAMRig::PowerTube::kEL34}) {
                const auto x = render(profile, false);
                double before = 0, after = 0, during = 0;
                for (size_t i = 0; i < n; ++i) {
                  bounded &= std::isfinite(x[i]);
                  during = std::max(during, std::fabs(static_cast<double>(x[i])));
                  if (i >= n * 2 / 3) {
                    before = std::max(before, std::fabs(static_cast<double>(previous[i])));
                    after = std::max(after, std::fabs(static_cast<double>(x[i])));
                  }
                }
                const double endpoint = std::max(before, after);
                worstRatio = std::max(worstRatio, during / endpoint);
                bounded &= during < 1.6 * endpoint + .002;
                previous = x;
              }
              for (int warm = 0; warm < 4; ++warm) render(NAMRig::PowerTube::kEL34, true);
              for (int profile : {NAMRig::PowerTube::k6L6, NAMRig::PowerTube::kEL34,
                                  NAMRig::PowerTube::kCaptured}) {
                for (float x : render(profile, true)) quiet &= std::isfinite(x) && std::fabs(x) < 1e-6;
              }
            }
          }
        }
      }
    }
    std::printf("        DSP tube transition worst peak/endpoint %.3f (%+.2f dB)\n",
                worstRatio, 20 * std::log10(worstRatio));
    CHECK(bounded, "hot tube curve transitions retain charged Master/Sag/feedback state at base/True 8x rates");
    CHECK(quiet, "tube curve changes retain silent feedback history without DC pops");
    CHECK(zeroExact, "Character 0 curve changes retain legacy arithmetic/history exactly");
  }
  {
    NAMRig::AmpAdvanced charged;
    for (int warm = 0; warm < 12; ++warm) {
      output = input;
      charged.processPostAmp(output.data(), count, rate, 12, -12, 100, -100, 100, 100,
                             NAMRig::PowerTube::kEL34, 100);
    }
    auto captured = charged;
    charged.resetTubeCharacter();
    output = input;
    auto reference = input;
    charged.processPostAmp(output.data(), count, rate, 12, -12, 100, -100, 100, 100);
    captured.processPostAmp(reference.data(), count, rate, 12, -12, 100, -100, 100, 100);
    CHECK(!charged.hasTubeCharacter() && output == reference,
          "tube-only reset preserves charged Power filters, smoothers and envelope exactly");
  }

  {
    bool preserved = true, powerCleared = true, fullReset = true, tubeOff = true;
    double worstResetError = 0;
    for (double sampleRate : {48000.0, 768000.0}) {
      for (int profile : {NAMRig::PowerTube::k6L6, NAMRig::PowerTube::kEL34}) {
        for (float character : {0.0f, 50.0f, 100.0f}) {
          // Preserve the actual in-flight smoother, not just its target.
          for (double seconds : {.004, .3}) {
            NAMRig::AmpAdvanced charged, tubeOnly;
            std::vector<float> warm(static_cast<size_t>(sampleRate * seconds));
            auto reference = warm;
            for (size_t i = 0; i < warm.size(); ++i)
              warm[i] = static_cast<float>(2.4 * std::sin(6.283185307179586 * 997 * i / sampleRate));
            charged.processPostAmp(warm.data(), warm.size(), sampleRate,
                12, -12, 100, -100, 100, 100, profile, character);
            tubeOnly.processPostAmp(reference.data(), reference.size(), sampleRate,
                0, 0, 0, 0, 0, 0, profile, character);
            auto fullyReset = charged;
            charged.resetPostAmp(true);
            fullyReset.resetPostAmp();
            fullReset &= !fullyReset.hasTubeCharacter();
            preserved &= charged.hasTubeCharacter() == tubeOnly.hasTubeCharacter();
            std::vector<float> hot(static_cast<size_t>(sampleRate * .03) + 7);
            for (size_t i = 0; i < hot.size(); ++i)
              hot[i] = static_cast<float>(2.4 * std::sin(6.283185307179586 * 997 * i / sampleRate));
            for (const auto& controls : {std::array<float, 6>{}, {12, -12, 100, 100, 100, 100}}) {
              auto actual = hot, expected = hot;
              auto a = charged, b = tubeOnly;
              a.processPostAmp(actual.data(), actual.size(), sampleRate,
                  controls[0], controls[1], controls[2], controls[3], controls[4], controls[5], profile, character);
              b.processPostAmp(expected.data(), expected.size(), sampleRate,
                  controls[0], controls[1], controls[2], controls[3], controls[4], controls[5], profile, character);
              // The reference has mathematically unity shelf histories rather
              // than reset identity coefficients; allow their rounding noise.
              for (size_t i = 0; i < actual.size(); ++i) {
                const double error = std::fabs(actual[i] - expected[i]);
                worstResetError = std::max(worstResetError, error);
                if (controls[5] == 0) preserved &= error < 2e-6;
                else powerCleared &= error < 2e-6;
              }
            }
            charged.resetTubeCharacter();
            auto actual = hot, expected = hot;
            LegacyAmp::AmpAdvanced legacy;
            charged.processPostAmp(actual.data(), actual.size(), sampleRate, 12, -12, 100, 100, 100, 100);
            legacy.processPostAmp(expected.data(), expected.size(), sampleRate, 12, -12, 100, 100, 100, 100);
            tubeOff &= !charged.hasTubeCharacter() && actual == expected;
          }
        }
      }
    }
    std::printf("        Power-only reset max reference error %.3g\n", worstResetError);
    CHECK(preserved, "Power-only reset preserves settled and in-flight Tube smoothing at base/True 8x rates");
    CHECK(powerCleared, "Power-only reset still clears old Power filters, envelope and smoothing before re-enable");
    CHECK(fullReset, "default post-amp reset still clears Tube character");
    CHECK(tubeOff, "Tube OFF clears preserved character and restores exact legacy Power startup");
  }

  std::printf(failures ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n", failures);
  return failures ? 1 : 0;
}
