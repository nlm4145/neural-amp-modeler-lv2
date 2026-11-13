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

  std::printf("%s\n", failures ? "FAILED" : "verify_model_band_limit: all checks passed");
  return failures ? 1 : 0;
}
