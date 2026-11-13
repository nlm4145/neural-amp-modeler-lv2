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
  // shifter's delay, its longest splice search span plus crossfade (40 ms),
  // and the compensation filter ringdown: nothing old is read back.
  const double sr = 48000.0;
  NAMRig::DropPitch dp;
  dp.prepare(sr);
  std::vector<float> buf(24000, 0.0f);
  for (size_t i = 0; i < 4800; ++i) buf[i] = 0.5f * std::sin(0.02f * static_cast<float>(i));
  for (int st : {-12, -3, 12}) {
    std::vector<float> run = buf;
    dp.reset();
    dp.process(run.data(), static_cast<uint32_t>(run.size()), st);
    const size_t tailEnd = 4800 + static_cast<size_t>(dp.latencySamples(st)) + static_cast<size_t>(sr * 0.040);
    for (size_t i = tailEnd; i < run.size(); ++i) assert(std::fabs(run[i]) < 5.0e-3f);
    const size_t quiet = tailEnd + 6000;
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

size_t firstIndexAbove(const std::vector<float>& buf, size_t from, float level) {
  for (size_t i = from; i < buf.size(); ++i) {
    if (std::fabs(buf[i]) > level) return i;
  }
  return buf.size();
}

void processInBlocks(NAMRig::DropPitch& dp, std::vector<float>& buf, int semitones) {
  for (size_t off = 0; off < buf.size(); off += 64) {
    const uint32_t n = static_cast<uint32_t>(std::min<size_t>(64, buf.size() - off));
    dp.process(buf.data() + off, n, semitones);
  }
}

void testReportedLatencyIsLow() {
  // Drop settings report at most 6 ms and capo settings at most 12 ms.
  for (double sr : {44100.0, 48000.0, 96000.0, 192000.0}) {
    NAMRig::DropPitch dp;
    dp.prepare(sr);
    for (int st = NAMRig::DropPitch::kMinSemitones; st <= NAMRig::DropPitch::kMaxSemitones; ++st) {
      const double ms = 1000.0 * static_cast<double>(dp.latencySamples(st)) / sr;
      if (st == 0) {
        assert(ms == 0.0);
      } else {
        assert(ms > 0.0);
        assert(ms <= (st < 0 ? 6.0 : 12.0));
      }
    }
  }
}

void testPickAttackLatency(double sr, int semitones, double maxMs) {
  // A picked note after silence must reach half of its dry attack peak within maxMs.
  constexpr double kTwoPi = 6.28318530717958647692;
  NAMRig::DropPitch dp;
  dp.prepare(sr);
  const size_t start = static_cast<size_t>(sr * 0.2);
  std::vector<float> dry(static_cast<size_t>(sr * 0.5), 0.0f);
  for (size_t i = start; i < dry.size(); ++i) {
    const double t = static_cast<double>(i - start) / sr;
    const double click = std::exp(-t / 0.0025) *
                         (0.45 * std::sin(kTwoPi * 2600.0 * t) + 0.30 * std::sin(kTwoPi * 4100.0 * t));
    const double body = std::exp(-t / 0.2) * 0.45 * std::sin(kTwoPi * 110.0 * t);
    dry[i] = static_cast<float>(click + body);
  }
  std::vector<float> wet = dry;
  processInBlocks(dp, wet, semitones);

  float dryPeak = 0.0f;
  for (size_t i = start; i < start + static_cast<size_t>(sr * 0.010); ++i) {
    dryPeak = std::max(dryPeak, std::fabs(dry[i]));
  }
  const size_t dryIdx = firstIndexAbove(dry, 0, 0.5f * dryPeak);
  const size_t wetIdx = firstIndexAbove(wet, 0, 0.5f * dryPeak);
  assert(wetIdx < wet.size());
  assert(wetIdx >= dryIdx);
  assert(1000.0 * static_cast<double>(wetIdx - dryIdx) / sr <= maxMs);
}

void testSustainedLatency(double sr, int semitones, double maxMs) {
  // A level step inside a sustained D3 must reach the output within maxMs.
  constexpr double kTwoPi = 6.28318530717958647692;
  NAMRig::DropPitch dp;
  dp.prepare(sr);
  const size_t step = static_cast<size_t>(sr * 0.4);
  std::vector<float> dry(static_cast<size_t>(sr * 0.7));
  for (size_t i = 0; i < dry.size(); ++i) {
    const double amp = i < step ? 0.2 : 0.6;
    dry[i] = static_cast<float>(amp * std::sin(kTwoPi * 146.8324 * static_cast<double>(i) / sr));
  }
  std::vector<float> wet = dry;
  processInBlocks(dp, wet, semitones);

  const size_t dryIdx = firstIndexAbove(dry, 0, 0.42f);
  const size_t wetIdx = firstIndexAbove(wet, static_cast<size_t>(sr * 0.1), 0.42f);
  assert(wetIdx < wet.size());
  assert(wetIdx >= dryIdx);
  assert(1000.0 * static_cast<double>(wetIdx - dryIdx) / sr <= maxMs);
}

void testSemitoneChangeIsImmediate() {
  // A change from -2 st to -5 st mid-note must sound at the new pitch 5 ms later.
  const double sr = 48000.0;
  constexpr double kTwoPi = 6.28318530717958647692;
  NAMRig::DropPitch dp;
  dp.prepare(sr);
  const double inFreq = 146.8324;
  std::vector<float> buf(static_cast<size_t>(sr * 0.6));
  for (size_t i = 0; i < buf.size(); ++i) {
    buf[i] = 0.7f * static_cast<float>(std::sin(kTwoPi * inFreq * static_cast<double>(i) / sr));
  }
  const size_t change = static_cast<size_t>(sr * 0.3);
  for (size_t off = 0; off < buf.size(); off += 64) {
    const uint32_t n = static_cast<uint32_t>(std::min<size_t>(64, buf.size() - off));
    dp.process(buf.data() + off, n, off < change ? -2 : -5);
  }
  for (float s : buf) assert(std::isfinite(s));

  const size_t measureStart = change + static_cast<size_t>(sr * 0.005);
  const size_t measureLen = static_cast<size_t>(sr * 0.1);
  const double magNew = measureMagnitudeAtFreq(buf, measureStart, measureLen, sr, inFreq * std::pow(2.0, -5.0 / 12.0));
  const double magOld = measureMagnitudeAtFreq(buf, measureStart, measureLen, sr, inFreq * std::pow(2.0, -2.0 / 12.0));
  assert(magNew > 0.15);
  assert(magNew > magOld * 8.0);
}

}  // namespace

int main() {
  testExactBypass();
  testEngageHasNoDropout();
  testNoStaleReadsAfterSilence();
  testTransientPunchPreserved();
  testReportedLatencyIsLow();
  for (double sr : {44100.0, 48000.0, 96000.0}) {
    for (int st : {-12, -7, -3, -2, -1}) {
      testPickAttackLatency(sr, st, 4.0);
      testSustainedLatency(sr, st, 8.0);
    }
    for (int st : {2, 5, 12}) {
      testPickAttackLatency(sr, st, 10.0);
      testSustainedLatency(sr, st, 12.0);
    }
  }
  testSemitoneChangeIsImmediate();
  // Verify re-picking over a ringing low power chord across every drop setting
  // retains crisp high-frequency pick snap inside the first 10 ms (not delayed
  // 15-20 ms or skipped by periodic veto / slowEnv masking).
  {
    const double sr = 48000.0;
    constexpr double kTwoPi = 6.28318530717958647692;
    const size_t total = static_cast<size_t>(sr * 0.50);
    const size_t onset = static_cast<size_t>(sr * 0.25);
    std::vector<float> dry(total, 0.0f);
    for (size_t i = 0; i < total; ++i) {
      const double t = static_cast<double>(i) / sr;
      double s = 0.32 * (std::sin(kTwoPi * 82.41 * t) + 0.7 * std::sin(kTwoPi * 123.47 * t));
      if (i >= onset) {
        const double tp = static_cast<double>(i - onset) / sr;
        s += std::exp(-tp / 0.0022) *
             (0.40 * std::sin(kTwoPi * 2600.0 * tp) + 0.28 * std::sin(kTwoPi * 4100.0 * tp));
        s += std::exp(-tp / 0.060) * 0.35 * std::sin(kTwoPi * 164.81 * tp);
      }
      dry[i] = static_cast<float>(s);
    }
    const double lpCoeff = 1.0 - std::exp(-kTwoPi * 1600.0 / sr);
    for (int st = -1; st >= -12; --st) {
      std::vector<float> wet = dry;
      NAMRig::DropPitch dp;
      dp.prepare(sr);
      processInBlocks(dp, wet, st);
      double lp = 0.0;
      double hf10 = 0.0;
      for (size_t i = onset; i < onset + static_cast<size_t>(sr * 0.010); ++i) {
        lp += (static_cast<double>(wet[i]) - lp) * lpCoeff;
        const double hp = static_cast<double>(wet[i]) - lp;
        hf10 += hp * hp;
      }
      assert(hf10 > 2.0);
    }
  }
  // Verify rapid 16th-note chugs at -5 st and -12 st retain punch and low latency.
  {
    const double sr = 48000.0;
    constexpr double kTwoPi = 6.28318530717958647692;
    const size_t period = static_cast<size_t>(sr * 0.070);
    std::vector<float> dry(period * 6, 0.0f);
    for (size_t c = 0; c < 6; ++c) {
      for (size_t i = 0; i < period; ++i) {
        const double t = static_cast<double>(i) / sr;
        const double click = std::exp(-t / 0.0020) *
                             (0.42 * std::sin(kTwoPi * 2700.0 * t) + 0.28 * std::sin(kTwoPi * 4200.0 * t));
        const double body = std::exp(-t / 0.030) * 0.50 * std::sin(kTwoPi * 98.0 * t);
        dry[c * period + i] += static_cast<float>(click + body);
      }
    }
    for (int st : {-5, -12}) {
      std::vector<float> wet = dry;
      NAMRig::DropPitch dp;
      dp.prepare(sr);
      processInBlocks(dp, wet, st);
      for (size_t c = 0; c < 6; ++c) {
        const size_t base = c * period;
        float dryPeak = 0.0f, wetPeak = 0.0f;
        for (size_t i = 0; i < 480; ++i) {
          dryPeak = std::max(dryPeak, std::fabs(dry[base + i]));
          wetPeak = std::max(wetPeak, std::fabs(wet[base + i]));
        }
        assert(wetPeak >= dryPeak * 0.85f);
      }
    }
  }
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
  auto rmsRange = [](const std::vector<float>& buf, size_t a, size_t b) {
    double e = 0.0;
    for (size_t i = a; i < b; ++i) e += static_cast<double>(buf[i]) * static_cast<double>(buf[i]);
    return std::sqrt(e / static_cast<double>(b - a));
  };
  // Verify decaying low-string palm mutes preserve sub-fundamental body and quiet tail sustain.
  {
    const double sr = 48000.0;
    constexpr double kTwoPi = 6.28318530717958647692;
    const size_t start = static_cast<size_t>(sr * 0.04);
    const size_t noteEnd = start + static_cast<size_t>(sr * 0.36);
    const size_t total = noteEnd + static_cast<size_t>(sr * 0.12);
    std::vector<float> dry(total, 0.0f);
    double phase = 0.0;
    for (size_t i = start; i < noteEnd; ++i) {
      const double t = static_cast<double>(i - start) / sr;
      const double fInst = 61.7354 * (1.0 + 0.012 * std::exp(-t / 0.025));
      phase += kTwoPi * fInst / sr;
      const double click = std::exp(-t / 0.0020) * (0.35 * std::sin(kTwoPi * 2400.0 * t) +
                                                    0.22 * std::sin(kTwoPi * 3800.0 * t));
      const double h = std::exp(-t / 0.070) *
                       (1.00 * std::sin(phase) + 0.50 * std::exp(-t / 0.030) * std::sin(2.0 * phase) +
                        0.22 * std::exp(-t / 0.016) * std::sin(3.0 * phase));
      dry[i] = static_cast<float>(0.12 * (click + h));
    }
    for (int st : {-3, -5, -7, -12}) {
      std::vector<float> wet = dry;
      NAMRig::DropPitch dp;
      dp.prepare(sr);
      processInBlocks(dp, wet, st);
      const size_t w0 = start + static_cast<size_t>(sr * 0.030);
      const size_t w1 = start + static_cast<size_t>(sr * 0.180);
      const size_t w2 = start + static_cast<size_t>(sr * 0.320);
      assert(rmsRange(wet, w0, w1) >= 0.72 * rmsRange(dry, w0, w1));
      assert(rmsRange(wet, w1, w2) >= 0.72 * rmsRange(dry, w1, w2));
      const size_t win = static_cast<size_t>(sr * 0.036);
      for (size_t pos = w0; pos + win <= w2; pos += win) {
        assert(rmsRange(wet, pos, pos + win) >= 0.65 * rmsRange(dry, pos, pos + win));
      }
      assert(rmsRange(wet, noteEnd + static_cast<size_t>(sr * 0.060), total) < 1.0e-4);
    }
  }
  // Verify dropped palm-muted power chords below E2 track periodic cycles without dropouts.
  {
    const double sr = 48000.0;
    constexpr double kTwoPi = 6.28318530717958647692;
    const size_t start = static_cast<size_t>(sr * 0.04);
    const size_t noteEnd = start + static_cast<size_t>(sr * 0.34);
    const size_t total = noteEnd + static_cast<size_t>(sr * 0.12);
    for (double f1 : {73.416, 65.406, 61.7354}) {
      std::vector<float> dry(total, 0.0f);
      double p1 = 0.0, p2 = 0.0;
      for (size_t i = start; i < noteEnd; ++i) {
        const double t = static_cast<double>(i - start) / sr;
        const double pitchEnv = 1.0 + 0.012 * std::exp(-t / 0.025);
        p1 += kTwoPi * f1 * pitchEnv / sr;
        p2 += kTwoPi * (f1 * 1.4983) * pitchEnv / sr;
        const double click = std::exp(-t / 0.0020) * (0.35 * std::sin(kTwoPi * 2400.0 * t) +
                                                      0.22 * std::sin(kTwoPi * 3800.0 * t));
        const double body = std::exp(-t / 0.085) *
                            (0.75 * std::sin(p1) + 0.55 * std::sin(p2) +
                             0.25 * std::exp(-t / 0.035) * std::sin(2.0 * p1));
        dry[i] = static_cast<float>(0.30 * (click + body));
      }
      for (int st : {-2, -5}) {
        std::vector<float> wet = dry;
        NAMRig::DropPitch dp;
        dp.prepare(sr);
        processInBlocks(dp, wet, st);
        const size_t a = start + static_cast<size_t>(sr * 0.040);
        const size_t b = start + static_cast<size_t>(sr * 0.280);
        assert(rmsRange(wet, a, b) >= 0.75 * rmsRange(dry, a, b));
        const size_t win = static_cast<size_t>(sr * 0.045);
        for (size_t pos = a; pos + win <= b; pos += win) {
          assert(rmsRange(wet, pos, pos + win) >= 0.65 * rmsRange(dry, pos, pos + win));
        }
        assert(rmsRange(wet, noteEnd + static_cast<size_t>(sr * 0.060), total) < 1.0e-4);
      }
    }
  }
  // Verify the 2 shaper controls: neutral parity, attack, sustain (+ mute silence), and live smoothing.
  {
    const double sr = 48000.0;
    constexpr double kTwoPi = 6.28318530717958647692;
    const size_t start = static_cast<size_t>(sr * 0.04);
    const size_t noteEnd = start + static_cast<size_t>(sr * 0.36);
    const size_t total = noteEnd + static_cast<size_t>(sr * 0.12);
    std::vector<float> palmMute(total, 0.0f);
    double phase = 0.0;
    for (size_t i = start; i < noteEnd; ++i) {
      const double t = static_cast<double>(i - start) / sr;
      phase += kTwoPi * 82.41 / sr;
      const double click = std::exp(-t / 0.0020) * (0.40 * std::sin(kTwoPi * 2600.0 * t) +
                                                    0.24 * std::sin(kTwoPi * 4000.0 * t));
      const double body = std::exp(-t / 0.070) * (std::sin(phase) + 0.45 * std::sin(2.0 * phase));
      palmMute[i] = static_cast<float>(0.22 * (click + body));
    }

    auto runWithParams = [&](std::vector<float> buf, int st, const NAMRig::DropPitch::Params& p) {
      NAMRig::DropPitch dp;
      dp.prepare(sr);
      for (size_t off = 0; off < buf.size(); off += 128) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(128, buf.size() - off));
        dp.process(buf.data() + off, n, st, p);
      }
      return buf;
    };

    // 1. Neutral defaults {50, 50} must be bit-identical to 3-arg process().
    std::vector<float> legacyOut = palmMute;
    {
      NAMRig::DropPitch dp;
      dp.prepare(sr);
      processInBlocks(dp, legacyOut, -5);
    }
    const std::vector<float> neutralOut =
        runWithParams(palmMute, -5, NAMRig::DropPitch::Params{50.0f, 50.0f});
    for (size_t i = 0; i < total; ++i) {
      assert(neutralOut[i] == legacyOut[i]);
    }

    // 2. Attack scales high-frequency pick transient articulation monotonically (0 < 50 < 100).
    const auto atkLow = runWithParams(palmMute, -5, {0.0f, 50.0f});
    const auto atkHigh = runWithParams(palmMute, -5, {100.0f, 50.0f});
    auto hfDiffRms = [&](const std::vector<float>& buf, size_t a, size_t b) {
      double acc = 0.0;
      for (size_t i = a + 1; i < b; ++i) {
        const double d = static_cast<double>(buf[i]) - static_cast<double>(buf[i - 1]);
        acc += d * d;
      }
      return std::sqrt(acc / static_cast<double>(b - a - 1));
    };
    const size_t atkEnd = start + static_cast<size_t>(sr * 0.010);
    const double atkDiffLow = hfDiffRms(atkLow, start, atkEnd);
    const double atkDiffMid = hfDiffRms(neutralOut, start, atkEnd);
    const double atkDiffHigh = hfDiffRms(atkHigh, start, atkEnd);
    assert(atkDiffHigh > atkDiffMid * 1.12);
    assert(atkDiffMid > atkDiffLow * 1.04);

    // 3. Sustain lifts decaying palm-mute tail without pumping silence.
    const auto susLow = runWithParams(palmMute, -5, {50.0f, 0.0f});
    const auto susHigh = runWithParams(palmMute, -5, {50.0f, 100.0f});
    const size_t tailA = start + static_cast<size_t>(sr * 0.14);
    const size_t tailB = start + static_cast<size_t>(sr * 0.30);
    assert(rmsRange(susHigh, tailA, tailB) > rmsRange(neutralOut, tailA, tailB) * 1.15);
    assert(rmsRange(susLow, tailA, tailB) < rmsRange(neutralOut, tailA, tailB) * 0.90);
    assert(rmsRange(susHigh, noteEnd + static_cast<size_t>(sr * 0.06), total) < 1.0e-4);

    // 4. Live parameter automation stays finite and click-free across sudden jumps.
    std::vector<float> sweep(static_cast<size_t>(sr * 0.5), 0.0f);
    for (size_t i = 0; i < sweep.size(); ++i) {
      sweep[i] = static_cast<float>(0.25 * std::sin(kTwoPi * 110.0 * static_cast<double>(i) / sr));
    }
    NAMRig::DropPitch dpLive;
    dpLive.prepare(sr);
    for (size_t off = 0; off < sweep.size(); off += 128) {
      const uint32_t n = static_cast<uint32_t>(std::min<size_t>(128, sweep.size() - off));
      const NAMRig::DropPitch::Params p =
          off < sweep.size() / 2 ? NAMRig::DropPitch::Params{0.0f, 0.0f}
                                 : NAMRig::DropPitch::Params{100.0f, 100.0f};
      dpLive.process(sweep.data() + off, n, -5, p);
    }
    double maxStep = 0.0;
    for (size_t i = 1; i < sweep.size(); ++i) {
      assert(std::isfinite(sweep[i]));
      maxStep = std::max(maxStep, static_cast<double>(std::fabs(sweep[i] - sweep[i - 1])));
    }
    assert(maxStep < 0.15);
  }
  std::puts("verify_drop_pitch: all checks passed");
  return 0;
}
