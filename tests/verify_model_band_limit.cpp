// Validates src/model_band_limit.h: the switchable low-pass in front of a NAM
// model that runs above its training rate.
#include "model_band_limit.h"

#include <cmath>
#include <cstdio>
#include <vector>

using NAMRig::ModelBandLimit;

int main() {
  int failures = 0;
  auto check = [&](bool ok, const char* message) {
    std::printf("  %s  %s\n", ok ? "PASS" : "FAIL", message);
    if (!ok) ++failures;
  };

  bool flat = true, steep = true;
  for (double domain : {96000.0, 192000.0, 768000.0, 1536000.0}) {
    for (double hz = 20.0; hz <= 20000.0; hz *= 1.05)
      flat &= std::fabs(ModelBandLimit::responseDb(hz, domain, 48000.0)) < 0.06;
    steep &= ModelBandLimit::responseDb(28000.0, domain, 48000.0) < -30.0 &&
             ModelBandLimit::responseDb(36000.0, domain, 48000.0) < -50.0;
  }
  check(flat, "passband within 0.06 dB from 20 Hz to 20 kHz for a 48 kHz model");
  check(steep, "at least 30 dB down at 28 kHz and 50 dB down at 36 kHz");

  std::vector<float> x(4096), ref;
  for (size_t i = 0; i < x.size(); ++i) x[i] = std::sin(0.01f * static_cast<float>(i));
  ref = x;
  ModelBandLimit off, native;
  off.process(x.data(), x.size(), 768000.0, 48000.0, false);
  check(x == ref, "off leaves the samples bit-identical");
  native.process(x.data(), x.size(), 48000.0, 48000.0, true);
  check(x == ref, "a model at its own rate is not filtered");

  // 100 kHz at a 768 kHz domain is far in the stopband once the fade ends.
  std::vector<float> tone(40000);
  for (size_t i = 0; i < tone.size(); ++i)
    tone[i] = static_cast<float>(std::sin(6.28318530717958647692 * 100000.0 * static_cast<double>(i) / 768000.0));
  ModelBandLimit on;
  on.process(tone.data(), tone.size(), 768000.0, 48000.0, true);
  float peak = 0.0f;
  for (size_t i = 20000; i < tone.size(); ++i) peak = std::max(peak, std::fabs(tone[i]));
  check(peak < 1.0e-4f, "on removes ultrasonic content after the 5 ms fade");

  // Configurable cutoff, slope, and ripple behave as expected and bypass cleanly.
  ModelBandLimit::Params lowCut{8000.0f, 3, 0.05f};
  check(ModelBandLimit::responseDb(14000.0, 384000.0, 48000.0, lowCut) < -35.0,
        "custom 8 kHz cutoff attenuates 14 kHz");
  ModelBandLimit::Params slope12{12000.0f, 0, 0.05f};
  ModelBandLimit::Params slope48{12000.0f, 3, 0.05f};
  check(ModelBandLimit::responseDb(24000.0, 384000.0, 48000.0, slope48) <
            ModelBandLimit::responseDb(24000.0, 384000.0, 48000.0, slope12) - 30.0,
        "48 dB/oct slope attenuates stopband much more steeply than 12 dB/oct");
  ModelBandLimit::Params highRipple{12000.0f, 2, 0.80f};
  ModelBandLimit::Params lowRipple{12000.0f, 2, 0.02f};
  check(ModelBandLimit::responseDb(18000.0, 384000.0, 48000.0, highRipple) <
            ModelBandLimit::responseDb(18000.0, 384000.0, 48000.0, lowRipple) - 5.0,
        "higher ripple produces steeper transition roll-off");

  // Aggressive settings are still bit-identical when bypassed.
  std::vector<float> bypassTest = ref;
  ModelBandLimit customBypass;
  customBypass.process(bypassTest.data(), bypassTest.size(), 768000.0, 48000.0, false,
                       ModelBandLimit::Params{4000.0f, 3, 1.00f});
  check(bypassTest == ref, "custom filter settings are bit-identical when bypassed");

  // Engaging then bypassing fades cleanly back to bit-identical dry samples.
  std::vector<float> toggleBuf(16384);
  for (size_t i = 0; i < toggleBuf.size(); ++i)
    toggleBuf[i] = std::sin(0.03f * static_cast<float>(i));
  std::vector<float> toggleDry = toggleBuf;
  ModelBandLimit toggleFilter;
  toggleFilter.process(toggleBuf.data(), 8192, 768000.0, 48000.0, true,
                       ModelBandLimit::Params{6000.0f, 2, 0.25f});
  toggleFilter.process(toggleBuf.data() + 8192, 8192, 768000.0, 48000.0, false,
                       ModelBandLimit::Params{6000.0f, 2, 0.25f});
  // After the 5 ms fade (3840 samples at 768 kHz), remaining samples must be bit-identical.
  bool tailIdentical = true;
  for (size_t i = 8192 + 4096; i < toggleBuf.size(); ++i)
    tailIdentical &= (toggleBuf[i] == toggleDry[i]);
  check(tailIdentical, "disabling HF filter returns to bit-identical bypass after 5 ms fade");

  // Sweeping cutoff/ripple and switching slope while playing must not inject step clicks.
  {
    const double rate = 384000.0;
    const size_t blk = 64;
    std::vector<float> buf(blk);
    ModelBandLimit sweepFilter;
    double phase = 0.0;
    auto fillSignal = [&]() {
      for (size_t i = 0; i < blk; ++i) {
        buf[i] = static_cast<float>(
            0.5 * std::sin(2.0 * 3.14159265358979323846 * 1200.0 * phase / rate) +
            0.4 * std::sin(2.0 * 3.14159265358979323846 * 4500.0 * phase / rate));
        phase += 1.0;
      }
    };
    ModelBandLimit::Params p{20500.0f, 3, 0.05f};
    for (int b = 0; b < 300; ++b) {
      fillSignal();
      sweepFilter.process(buf.data(), blk, rate, 48000.0, true, p);
    }
    float prev = buf.back();
    float maxCutoffJump = 0.0f;
    for (int b = 0; b < 80; ++b) {
      p.cutoffHz = static_cast<float>(20500.0 - 16500.0 * b / 79.0);
      fillSignal();
      sweepFilter.process(buf.data(), blk, rate, 48000.0, true, p);
      for (float s : buf) {
        maxCutoffJump = std::max(maxCutoffJump, std::fabs(s - prev));
        prev = s;
      }
    }
    check(maxCutoffJump < 0.06f, "cutoff sweep stays continuous without step clicks");

    float maxRippleJump = 0.0f;
    for (int b = 0; b < 60; ++b) {
      p.rippleDb = (b % 2 == 0) ? 1.00f : 0.01f;
      fillSignal();
      sweepFilter.process(buf.data(), blk, rate, 48000.0, true, p);
      for (float s : buf) {
        maxRippleJump = std::max(maxRippleJump, std::fabs(s - prev));
        prev = s;
      }
    }
    check(maxRippleJump < 0.06f, "ripple changes stay continuous without step clicks");

    p = {5000.0f, 3, 0.50f};
    for (int b = 0; b < 300; ++b) {
      fillSignal();
      sweepFilter.process(buf.data(), blk, rate, 48000.0, true, p);
    }
    prev = buf.back();
    float maxSlopeJump = 0.0f;
    for (int b = 0; b < 150; ++b) {
      if (b == 0) p.slope = 0;
      if (b == 80) p.slope = 3;
      fillSignal();
      sweepFilter.process(buf.data(), blk, rate, 48000.0, true, p);
      for (float s : buf) {
        maxSlopeJump = std::max(maxSlopeJump, std::fabs(s - prev));
        prev = s;
      }
    }
    check(maxSlopeJump < 0.06f, "slope switches fade without single-sample pops");
  }

  std::printf("%s\n", failures ? "FAILED" : "verify_model_band_limit: all checks passed");
  return failures ? 1 : 0;
}
