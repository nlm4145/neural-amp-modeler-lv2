// Allocation-free control caches must match the original expressions exactly.
#include "rig_dsp_cache.h"

#include <array>
#include <cfenv>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {
void same(float actual, float expected, const char* label) {
  if (std::memcmp(&actual, &expected, sizeof(float))) {
    std::fprintf(stderr, "FAIL: %s (%a != %a)\n", label, actual, expected);
    std::exit(1);
  }
}
}

int main() {
  NAMRig::DbGainCache gain;
  NAMRig::RigRateCache rates;
  NAMRig::CompressorTimingCache compressor;
  NAMRig::AmpDriveRateCache amp;
  NAMRig::WidthGainCache width;
  std::fenv_t entry;
  std::fegetenv(&entry);
  for (int mode : {FE_TONEAREST, FE_UPWARD, FE_DOWNWARD, FE_TOWARDZERO, FE_TONEAREST}) {
    std::fesetround(mode);
    for (double rate : {48000.0, 96000.0, 768000.0, 48000.0}) {
      for (int repeat = 0; repeat < 4; ++repeat) {
        rates.configure(rate, mode);
        same(rates.glide10, 1.0f - std::exp(-1.0f / static_cast<float>(rate * 0.010)), "10ms glide");
        same(rates.chunkGlide, 1.0f - std::exp(-32.0f / static_cast<float>(rate * 0.020)), "EQ glide");
        same(rates.envAttack, 1.0f - std::exp(-1.0f / (rate * 0.001)), "envelope attack");
        same(rates.envRelease, 1.0f - std::exp(-1.0f / (rate * 0.080)), "envelope release");
        same(amp.get(rate, mode), 1.0f - std::exp(-1.0f /
             static_cast<float>(std::max(1.0, rate) * 0.010)), "amp domain glide");
        for (float attack : {1.0f, 8.0f, 35.0f, 100.0f})
          for (float release : {10.0f, 120.0f, 1000.0f}) {
            compressor.configure(rate, attack, release, mode);
            same(compressor.gainAttack, 1.0f - std::exp(-1.0f / (rate * (attack * 0.001f))), "gain attack");
            same(compressor.gainRelease, 1.0f - std::exp(-1.0f / (rate * (release * 0.001f))), "gain release");
          }
      }
    }
    for (float db : {0.0f, -0.0f, -24.0f, -3.0f, 12.0f, 0.0f})
      for (int repeat = 0; repeat < 4; ++repeat)
        same(gain.get(db, mode), std::pow(10.0f, db * 0.05f), "dB gain");
    for (float value : {0.0f, 0.35f, 1.0f, 0.35f, 0.0f})
      for (int repeat = 0; repeat < 4; ++repeat) {
        width.configure(value, mode);
        const float theta = static_cast<float>(3.14159265358979323846) * 0.25f * (1.0f - value);
        same(width.near, std::cos(theta), "near cabinet gain");
        same(width.far, std::sin(theta), "far cabinet gain");
        same(width.coherent, std::max(1.0f, std::cos(theta) + std::sin(theta)), "coherent sum");
      }
  }
  std::fesetenv(&entry);
  std::puts("PASS: cached gains, timing and width equal original math; repeated controls, automation, rates and rounding changes");
}
