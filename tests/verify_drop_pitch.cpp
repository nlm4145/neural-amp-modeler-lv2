#include "drop_pitch.h"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>

namespace {

double measureMagnitudeAtFreq(const std::vector<float>& buf, size_t start, size_t len,
                                double sampleRate, double freqHz) {
  constexpr double kTwoPi = 6.28318530717958647692;
  double re = 0.0;
  double im = 0.0;
  for (size_t i = 0; i < len; ++i) {
    const double w = 0.5 * (1.0 - std::cos(kTwoPi * static_cast<double>(i) / len));
    const double s = static_cast<double>(buf[start + i]) * w;
    const double angle = kTwoPi * freqHz * static_cast<double>(i) / sampleRate;
    re += s * std::cos(angle);
    im -= s * std::sin(angle);
  }
  return std::sqrt(re * re + im * im) / static_cast<double>(len);
}

void testExactBypass() {
  NAMRig::DropPitch dp;
  dp.prepare(48000.0);
  assert(dp.latencySamples(0) == 0);

  std::vector<float> buf(512);
  std::vector<float> ref(512);
  for (size_t i = 0; i < buf.size(); ++i) {
    buf[i] = ref[i] = 0.5f * std::sin(0.03f * static_cast<float>(i));
  }
  dp.process(buf.data(), static_cast<uint32_t>(buf.size()), 0);
  for (size_t i = 0; i < buf.size(); ++i) {
    assert(buf[i] == ref[i]);
  }
}

void testSingleNoteShift(double sampleRate, double inFreqHz, int semitones) {
  NAMRig::DropPitch dp;
  dp.prepare(sampleRate);
  assert(dp.latencySamples(semitones) > 0);

  constexpr double kTwoPi = 6.28318530717958647692;
  const size_t totalSamples = static_cast<size_t>(sampleRate * 0.6);
  std::vector<float> buf(totalSamples);
  for (size_t i = 0; i < totalSamples; ++i) {
    buf[i] = 0.7f * static_cast<float>(std::sin(kTwoPi * inFreqHz * static_cast<double>(i) / sampleRate));
  }

  for (size_t off = 0; off < totalSamples; off += 128) {
    const uint32_t n = static_cast<uint32_t>(std::min<size_t>(128, totalSamples - off));
    dp.process(buf.data() + off, n, semitones);
  }

  for (float s : buf) {
    assert(std::isfinite(s));
    assert(std::fabs(s) <= 1.25f);
  }

  const double expectedFreq = inFreqHz * std::pow(2.0, static_cast<double>(semitones) / 12.0);
  const size_t measureStart = totalSamples / 2;
  const size_t measureLen = totalSamples - measureStart;
  const double magTarget = measureMagnitudeAtFreq(buf, measureStart, measureLen, sampleRate, expectedFreq);
  const double magOrig = measureMagnitudeAtFreq(buf, measureStart, measureLen, sampleRate, inFreqHz);

  assert(magTarget > 0.10);
  assert(magTarget > magOrig * 8.0);
}

void testPolyphonicPowerChord() {
  // D standard power chord: D3 (146.83 Hz) + A3 (220.0 Hz), dropped -2 st to C3 + G3.
  const double sampleRate = 48000.0;
  NAMRig::DropPitch dp;
  dp.prepare(sampleRate);

  constexpr double kTwoPi = 6.28318530717958647692;
  const double f1 = 146.8324;
  const double f2 = 220.0;
  const size_t totalSamples = 28800;
  std::vector<float> buf(totalSamples);
  for (size_t i = 0; i < totalSamples; ++i) {
    buf[i] = 0.4f * static_cast<float>(std::sin(kTwoPi * f1 * static_cast<double>(i) / sampleRate)) +
             0.4f * static_cast<float>(std::sin(kTwoPi * f2 * static_cast<double>(i) / sampleRate));
  }

  dp.process(buf.data(), static_cast<uint32_t>(totalSamples), -2);

  const double ratio = std::pow(2.0, -2.0 / 12.0);
  const double mag1 = measureMagnitudeAtFreq(buf, 14400, 14400, sampleRate, f1 * ratio);
  const double mag2 = measureMagnitudeAtFreq(buf, 14400, 14400, sampleRate, f2 * ratio);
  const double magOrig1 = measureMagnitudeAtFreq(buf, 14400, 14400, sampleRate, f1);
  assert(mag1 > 0.05);
  assert(mag2 > 0.05);
  assert(mag1 > magOrig1 * 5.0);
}

void testTransitionsAndClamping() {
  assert(NAMRig::DropPitch::clampSemitones(-99) == -12);
  assert(NAMRig::DropPitch::clampSemitones(99) == 12);

  NAMRig::DropPitch dp;
  dp.prepare(48000.0);
  std::vector<float> buf(4096, 0.0f);
  for (size_t i = 0; i < buf.size(); ++i) {
    buf[i] = 0.5f * std::sin(0.02f * static_cast<float>(i));
  }
  dp.process(buf.data(), 1024, 0);
  dp.process(buf.data() + 1024, 1024, -3);
  dp.process(buf.data() + 2048, 1024, -1);
  dp.process(buf.data() + 3072, 1024, 0);
  for (float s : buf) {
    assert(std::isfinite(s));
  }
}

void testEngageHasNoDropout() {
  // Play D3 bypassed, then engage -2 st mid-note: the first 20 ms after
  // engaging must keep roughly the same level (no silence while the shifter fills).
  const double sr = 48000.0;
  constexpr double kTwoPi = 6.28318530717958647692;
  NAMRig::DropPitch dp;
  dp.prepare(sr);
  std::vector<float> buf(9600);
  for (size_t i = 0; i < buf.size(); ++i)
    buf[i] = 0.5f * static_cast<float>(std::sin(kTwoPi * 146.8324 * static_cast<double>(i) / sr));
  dp.process(buf.data(), 4800, 0);
  dp.process(buf.data() + 4800, 4800, -2);
  double rms = 0.0;
  for (size_t i = 4800; i < 4800 + 960; ++i) rms += double(buf[i]) * buf[i];
  rms = std::sqrt(rms / 960.0);
  assert(rms > 0.25);  // a full-scale 0.5 sine is 0.354 RMS
}

void testNoStaleReadsAfterSilence() {
  // After the input stops, output must decay cleanly to silence within the
  // shifter's delay, grain window, and 38 Hz compensation filter ringdown:
  // nothing old is read back.
  const double sr = 48000.0;
  NAMRig::DropPitch dp;
  dp.prepare(sr);
  std::vector<float> buf(24000, 0.0f);
  for (size_t i = 0; i < 4800; ++i) buf[i] = 0.5f * std::sin(0.02f * static_cast<float>(i));
  for (int st : {-12, -3, 12}) {
    std::vector<float> run = buf;
    dp.reset();
    dp.process(run.data(), static_cast<uint32_t>(run.size()), st);
    const size_t grainEnd = 4800 + static_cast<size_t>(dp.latencySamples(st)) + 2 * 1728 + 1024;
    for (size_t i = grainEnd; i < run.size(); ++i) assert(std::fabs(run[i]) < 5.0e-3f);
    const size_t quiet = grainEnd + 6000;
    for (size_t i = quiet; i < run.size(); ++i) assert(std::fabs(run[i]) < 1.0e-6f);
  }
}

void testTransientPunchPreserved() {
  // Simulate 4 palm-muted guitar chugs at 96 kHz, dropped -3 st: each pick attack
  // must retain strong transient peak energy and avoid double-attack flamming.
  const double sr = 96000.0;
  constexpr double kTwoPi = 6.28318530717958647692;
  NAMRig::DropPitch dp;
  dp.prepare(sr);

  const size_t period = 14400;  // 150 ms between chugs
  std::vector<float> dry(period * 4, 0.0f);
  for (size_t c = 0; c < 4; ++c) {
    const size_t base = c * period;
    for (size_t i = 0; i < period - 2400; ++i) {
      const double t = static_cast<double>(i) / sr;
      const double pickEnv = std::exp(-t / 0.0025);
      const double bodyEnv = std::exp(-t / 0.035);
      const double click = pickEnv * (0.45 * std::sin(kTwoPi * 2600.0 * t) +
                                      0.30 * std::sin(kTwoPi * 4100.0 * t));
      const double body = bodyEnv * 0.45 * (std::sin(kTwoPi * 146.8324 * t) +
                                            0.5 * std::sin(kTwoPi * 293.6648 * t));
      dry[base + i] = static_cast<float>(click + body);
    }
  }

  std::vector<float> wet = dry;
  for (size_t off = 0; off < wet.size(); off += 64) {
    const uint32_t n = static_cast<uint32_t>(std::min<size_t>(64, wet.size() - off));
    dp.process(wet.data() + off, n, -3);
  }

  for (size_t c = 0; c < 4; ++c) {
    const size_t base = c * period;
    float dryPeak = 0.0f;
    for (size_t i = 0; i < 1200; ++i) dryPeak = std::max(dryPeak, std::fabs(dry[base + i]));
    float wetPeak = 0.0f;
    size_t wetPeakIdx = 0;
    for (size_t i = 0; i < 4000; ++i) {
      const float a = std::fabs(wet[base + i]);
      if (a > wetPeak) {
        wetPeak = a;
        wetPeakIdx = base + i;
      }
    }
    assert(wetPeak >= dryPeak * 0.75f);
    // Check 14..24 ms after the attack peak for double-attack flamming:
    // damped palm mute should keep decaying cleanly (< 65% of attack peak).
    float afterPeak = 0.0f;
    for (size_t i = wetPeakIdx + 1344; i < std::min(wet.size(), wetPeakIdx + 2400); ++i) {
      afterPeak = std::max(afterPeak, std::fabs(wet[i]));
    }
    assert(afterPeak < wetPeak * 0.65f);
  }
}

}  // namespace

int main() {
  testExactBypass();
  testEngageHasNoDropout();
  testNoStaleReadsAfterSilence();
  testTransientPunchPreserved();
  testSingleNoteShift(48000.0, 146.8324, -1);  // D3 -> Db3
  testSingleNoteShift(48000.0, 146.8324, -2);  // D3 -> C3
  testSingleNoteShift(48000.0, 146.8324, -3);  // D3 -> B2
  testSingleNoteShift(48000.0, 146.8324, -12); // D3 -> D2
  testSingleNoteShift(48000.0, 146.8324, 5);   // D3 -> G3
  testSingleNoteShift(48000.0, 146.8324, 12);  // D3 -> D4
  testSingleNoteShift(44100.0, 110.0, -2);     // 44.1 kHz
  testSingleNoteShift(96000.0, 110.0, -3);     // 96 kHz
  testSingleNoteShift(96000.0, 61.7354, -2);   // Low B1 at 96 kHz (-2 st)
  testSingleNoteShift(96000.0, 61.7354, -3);   // Low B1 at 96 kHz (-3 st)
  testPolyphonicPowerChord();
  testTransitionsAndClamping();
  std::puts("verify_drop_pitch: all checks passed");
  return 0;
}
