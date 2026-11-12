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

}  // namespace

int main() {
  testExactBypass();
  testSingleNoteShift(48000.0, 146.8324, -1);  // D3 -> Db3
  testSingleNoteShift(48000.0, 146.8324, -2);  // D3 -> C3
  testSingleNoteShift(48000.0, 146.8324, -3);  // D3 -> B2
  testSingleNoteShift(48000.0, 146.8324, -12); // D3 -> D2
  testSingleNoteShift(48000.0, 146.8324, 5);   // D3 -> G3
  testSingleNoteShift(48000.0, 146.8324, 12);  // D3 -> D4
  testSingleNoteShift(44100.0, 110.0, -2);     // 44.1 kHz
  testSingleNoteShift(96000.0, 110.0, -3);     // 96 kHz
  testPolyphonicPowerChord();
  testTransitionsAndClamping();
  std::puts("verify_drop_pitch: all checks passed");
  return 0;
}
