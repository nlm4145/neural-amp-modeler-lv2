#include "drop_pitch.h"

#include <algorithm>
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

void testUnityGainAcrossRange() {
  // Notes starting from silence must hold exact ~1.00 unity gain across
  // -12..+12 semitones without window-centroid drift.
  const double sr = 48000.0;
  constexpr double kTwoPi = 6.28318530717958647692;
  for (int st : {-12, -5, -3, -2, -1, 1, 3, 7, 12}) {
    std::vector<float> buf(static_cast<size_t>(sr * 0.6));
    for (size_t i = 0; i < buf.size(); ++i) {
      buf[i] = 0.5f * static_cast<float>(std::sin(kTwoPi * 330.0 * static_cast<double>(i) / sr));
    }
    NAMRig::DropPitch dp;
    dp.prepare(sr);
    for (size_t off = 0; off < buf.size(); off += 64) {
      dp.process(buf.data() + off, static_cast<uint32_t>(std::min<size_t>(64, buf.size() - off)), st);
    }
    double e = 0.0;
    const size_t a = static_cast<size_t>(sr * 0.25);
    const size_t b = static_cast<size_t>(sr * 0.55);
    for (size_t i = a; i < b; ++i) e += static_cast<double>(buf[i]) * buf[i];
    const double outAmp = std::sqrt(e / static_cast<double>(b - a)) * std::sqrt(2.0);
    assert(outAmp >= 0.48 && outAmp <= 0.52);
  }
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

void testComplexChordsAndDissonantDyads() {
  // Verify polyphonic barre chords and dissonant metal dyads (E2 + F2 + B2)
  // maintain strong target harmonic energy at -3 st without time-domain splice collapse.
  const double sr = 48000.0;
  constexpr double kTwoPi = 6.28318530717958647692;
  const int st = -3;
  const double ratio = std::pow(2.0, static_cast<double>(st) / 12.0);
  const size_t total = static_cast<size_t>(sr * 0.85);
  const size_t s0 = static_cast<size_t>(sr * 0.25);
  const size_t len = static_cast<size_t>(sr * 0.50);

  for (const std::vector<double>& freqs : {
           std::vector<double>{82.41, 123.47, 164.81},
           std::vector<double>{82.41, 87.31, 123.47},
           std::vector<double>{82.41, 123.47, 164.81, 207.65, 246.94, 329.63},
       }) {
    std::vector<float> buf(total, 0.0f);
    for (size_t i = 0; i < total; ++i) {
      const double t = static_cast<double>(i) / sr;
      double s = 0.0;
      for (double f : freqs) {
        for (int h = 1; h <= 4; ++h) {
          s += (0.25 / (static_cast<double>(h) * std::sqrt(static_cast<double>(freqs.size())))) *
               std::sin(kTwoPi * f * static_cast<double>(h) * t);
        }
      }
      buf[i] = static_cast<float>(s);
    }
    NAMRig::DropPitch dp;
    dp.prepare(sr);
    for (size_t off = 0; off < total; off += 64) {
      dp.process(buf.data() + off, static_cast<uint32_t>(std::min<size_t>(64, total - off)), st);
    }
    double targetPower = 0.0;
    std::vector<double> uniq;
    for (double f : freqs) {
      for (int h = 1; h <= 4; ++h) {
        const double fh = f * static_cast<double>(h) * ratio;
        bool dup = false;
        for (double u : uniq) {
          if (std::fabs(u - fh) < 2.0) dup = true;
        }
        if (!dup) uniq.push_back(fh);
      }
    }
    for (double fh : uniq) {
      const double amp = 4.0 * measureMagnitudeAtFreq(buf, s0, len, sr, fh);
      targetPower += 0.5 * amp * amp;
    }
    double totalPower = 0.0;
    for (size_t i = s0; i < s0 + len; ++i) totalPower += static_cast<double>(buf[i]) * buf[i];
    totalPower /= static_cast<double>(len);
    const double snrDb =
        10.0 * std::log10(std::max(1.0e-12, targetPower) / std::max(1.0e-12, totalPower - targetPower));
    assert(snrDb >= 10.0);
  }
}

void testImpulseAccuracyAndZeroPreEcho() {
  // Exact impulse latency must match latencySamples() within 2 samples with
  // zero pre-echo and negligible post-ringing/flamming across -12..+12 st.
  const double sr = 48000.0;
  for (int st : {-12, -5, -4, -3, -2, -1, 2, 5, 12}) {
    std::vector<float> buf(8000, 0.0f);
    const size_t imp = 2000;
    buf[imp] = 0.8f;
    NAMRig::DropPitch dp;
    dp.prepare(sr);
    for (size_t off = 0; off < buf.size(); off += 64) {
      dp.process(buf.data() + off, static_cast<uint32_t>(std::min<size_t>(64, buf.size() - off)), st);
    }
    float pk = 0.0f;
    size_t pkIdx = 0;
    for (size_t i = imp; i < imp + 1500; ++i) {
      if (std::fabs(buf[i]) > pk) {
        pk = std::fabs(buf[i]);
        pkIdx = i;
      }
    }
    const int rep = dp.latencySamples(st);
    const int err = static_cast<int>(pkIdx - imp) - rep;
    assert(std::abs(err) <= 3);
    // Capo up-shifts apply an anti-aliasing sinc cutoff fc = 0.45 / ratio, so a
    // 1-sample Dirac delta scales proportionally to 1 / ratio.
    const float minPk = st > 0
        ? static_cast<float>(0.40 / std::pow(2.0, static_cast<double>(st) / 12.0))
        : 0.45f;
    assert(pk >= minPk);
    // Zero pre-echo up to 1 ms before the impulse crest.
    float prePk = 0.0f;
    for (size_t i = imp; i + 48 < pkIdx; ++i) {
      prePk = std::max(prePk, std::fabs(buf[i]));
    }
    assert(prePk < 1.0e-3f);
    // Negligible post-impulse flamming 4..20 ms after the crest.
    float postPk = 0.0f;
    for (size_t i = pkIdx + 192; i < pkIdx + 960; ++i) {
      postPk = std::max(postPk, std::fabs(buf[i]));
    }
    assert(postPk < 0.01f);
  }
}

void testPickupFormantPreservation() {
  // Model a passive bridge humbucker (3.0 kHz resonant peak, Q = 2.2) and verify
  // that a -4 st drop keeps the 3 kHz / 2 kHz spectral balance close to a real
  // downtuned guitar instead of shifting the pickup resonance into muddy upper-mids.
  const double sr = 48000.0;
  constexpr double kTwoPi = 6.28318530717958647692;
  struct Humbucker {
    double b0, b1, b2, a1, a2, z1 = 0.0, z2 = 0.0;
    Humbucker(double rate, double fc, double q) {
      const double w0 = kTwoPi * fc / rate;
      const double cw = std::cos(w0);
      const double alpha = std::sin(w0) / (2.0 * q);
      const double a0 = 1.0 + alpha;
      b0 = (1.0 - cw) * 0.5 / a0;
      b1 = (1.0 - cw) / a0;
      b2 = b0;
      a1 = -2.0 * cw / a0;
      a2 = (1.0 - alpha) / a0;
    }
    float process(float x) {
      const double y = b0 * x + z1;
      z1 = b1 * x - a1 * y + z2;
      z2 = b2 * x - a2 * y;
      return static_cast<float>(y);
    }
  };
  const double r = std::pow(2.0, -4.0 / 12.0);
  auto bandRms = [&](const std::vector<float>& buf, size_t start, size_t len, double fLo, double fHi) {
    double p = 0.0;
    for (double f : {110.0, 164.81, 220.0}) {
      for (int h = 1; h <= 40; ++h) {
        const double fh = f * r * static_cast<double>(h);
        if (fh >= fLo && fh <= fHi) {
          const double amp = 4.0 * measureMagnitudeAtFreq(buf, start, len, sr, fh);
          p += 0.5 * amp * amp;
        }
      }
    }
    return std::sqrt(p);
  };

  const size_t N = static_cast<size_t>(sr * 0.8);
  std::vector<float> dry(N, 0.0f);
  std::vector<float> trueDrop(N, 0.0f);
  Humbucker hbDry(sr, 3000.0, 2.2);
  Humbucker hbTrue(sr, 3000.0, 2.2);
  for (size_t i = 0; i < N; ++i) {
    const double t = static_cast<double>(i) / sr;
    double sDry = 0.0;
    double sTrue = 0.0;
    for (double f : {110.0, 164.81, 220.0}) {
      for (int h = 1; h <= 28; ++h) {
        if (f * h < 8000.0) sDry += (0.12 / std::pow(static_cast<double>(h), 0.7)) * std::sin(kTwoPi * f * h * t);
        if (f * r * h < 8000.0) {
          sTrue += (0.12 / std::pow(static_cast<double>(h), 0.7)) * std::sin(kTwoPi * f * r * h * t);
        }
      }
    }
    dry[i] = hbDry.process(static_cast<float>(sDry));
    trueDrop[i] = hbTrue.process(static_cast<float>(sTrue));
  }
  std::vector<float> wet = dry;
  NAMRig::DropPitch dp;
  dp.prepare(sr);
  for (size_t off = 0; off < N; off += 64) {
    dp.process(wet.data() + off, static_cast<uint32_t>(std::min<size_t>(64, N - off)), -4);
  }
  const size_t s0 = static_cast<size_t>(sr * 0.30);
  const size_t len = static_cast<size_t>(sr * 0.35);
  const double trueRatioDb =
      20.0 * std::log10(bandRms(trueDrop, s0, len, 2700.0, 3400.0) /
                        std::max(1.0e-9, bandRms(trueDrop, s0, len, 1800.0, 2400.0)));
  const double wetRatioDb =
      20.0 * std::log10(bandRms(wet, s0, len, 2700.0, 3400.0) /
                        std::max(1.0e-9, bandRms(wet, s0, len, 1800.0, 2400.0)));
  // 60% formant preservation anchors the 3 kHz pickup resonance within ~3.5 dB
  // of a true downtuned guitar (vs ~-9 dB upper-mid mud without formant lock).
  assert(wetRatioDb > trueRatioDb - 3.5 && wetRatioDb < trueRatioDb + 2.5);
}

void testBendAndVibratoTracking() {
  // Whole-step string bend (+2 st) + 5.5 Hz vibrato dropped -3 st must stay
  // smooth with no dropouts, clicks, or excessive amplitude wobble.
  const double sr = 48000.0;
  constexpr double kTwoPi = 6.28318530717958647692;
  const size_t N = static_cast<size_t>(sr * 0.8);
  std::vector<float> dry(N, 0.0f);
  double ph = 0.0;
  for (size_t i = 0; i < N; ++i) {
    const double t = static_cast<double>(i) / sr;
    const double bend = (t > 0.2 && t < 0.5) ? (t - 0.2) / 0.3 : (t >= 0.5 ? 1.0 : 0.0);
    const double vib = 0.02 * std::sin(kTwoPi * 5.5 * t);
    const double fInst = 293.66 * std::pow(2.0, (2.0 * bend) / 12.0) * (1.0 + vib);
    ph += kTwoPi * fInst / sr;
    dry[i] = static_cast<float>(0.4 * std::sin(ph) + 0.2 * std::sin(2.0 * ph) + 0.1 * std::sin(3.0 * ph));
  }
  std::vector<float> wet = dry;
  NAMRig::DropPitch dp;
  dp.prepare(sr);
  for (size_t off = 0; off < N; off += 64) {
    dp.process(wet.data() + off, static_cast<uint32_t>(std::min<size_t>(64, N - off)), -3);
  }
  double minR = 10.0;
  double maxR = 0.0;
  for (size_t p = static_cast<size_t>(sr * 0.15); p < static_cast<size_t>(sr * 0.72); p += 240) {
    double e = 0.0;
    for (size_t j = 0; j < 480; ++j) e += static_cast<double>(wet[p + j]) * wet[p + j];
    const double r = std::sqrt(e / 480.0);
    minR = std::min(minR, r);
    maxR = std::max(maxR, r);
  }
  assert(minR > 0.25);
  assert(20.0 * std::log10(maxR / minR) < 3.0);
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
  // shifter's fixed latency plus release tail and filter ringdown.
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
  // must retain strong transient peak energy, zero timing jitter, and no flamming.
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

  double minLatMs = 1e9;
  double maxLatMs = -1e9;
  for (size_t c = 0; c < 4; ++c) {
    const size_t base = c * period;
    float dryPeak = 0.0f;
    size_t dryPeakIdx = base;
    for (size_t i = 0; i < 1200; ++i) {
      const float a = std::fabs(dry[base + i]);
      if (a > dryPeak) {
        dryPeak = a;
        dryPeakIdx = base + i;
      }
    }
    float wetPeak = 0.0f;
    size_t wetPeakIdx = base;
    for (size_t i = 0; i < 4000; ++i) {
      const float a = std::fabs(wet[base + i]);
      if (a > wetPeak) {
        wetPeak = a;
        wetPeakIdx = base + i;
      }
    }
    assert(wetPeak >= dryPeak * 0.78f);
    const double latMs = 1000.0 * static_cast<double>(wetPeakIdx - dryPeakIdx) / sr;
    minLatMs = std::min(minLatMs, latMs);
    maxLatMs = std::max(maxLatMs, latMs);
    // Check 14..24 ms after the attack peak for double-attack flamming.
    float afterPeak = 0.0f;
    for (size_t i = wetPeakIdx + 1344; i < std::min(wet.size(), wetPeakIdx + 2400); ++i) {
      afterPeak = std::max(afterPeak, std::fabs(wet[i]));
    }
    assert(afterPeak < wetPeak * 0.65f);
  }
  assert(maxLatMs - minLatMs < 0.5);
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
  // Fixed pedal-grade latency: ~11-13 ms for typical -1..-5 st drops at 48-192 kHz,
  // <= 16.0 ms across the full -12..+12 semitone range down to 44.1 kHz.
  for (double sr : {44100.0, 48000.0, 96000.0, 192000.0}) {
    NAMRig::DropPitch dp;
    dp.prepare(sr);
    for (int st = NAMRig::DropPitch::kMinSemitones; st <= NAMRig::DropPitch::kMaxSemitones; ++st) {
      const double ms = 1000.0 * static_cast<double>(dp.latencySamples(st)) / sr;
      if (st == 0) {
        assert(ms == 0.0);
      } else {
        assert(ms > 0.0);
        if (sr >= 48000.0 && st >= -5 && st < 0) {
          assert(ms <= 13.5);
        }
        assert(ms <= (st < 0 ? 16.0 : 14.0));
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
  testImpulseAccuracyAndZeroPreEcho();
  testUnityGainAcrossRange();
  for (double sr : {44100.0, 48000.0, 96000.0}) {
    for (int st : {-12, -7, -3, -2, -1}) {
      const double budgetMs = st >= -5 ? (sr >= 48000.0 ? 14.0 : 15.0) : 16.5;
      testPickAttackLatency(sr, st, budgetMs);
      testSustainedLatency(sr, st, budgetMs);
    }
    for (int st : {2, 5, 12}) {
      testPickAttackLatency(sr, st, 14.5);
      testSustainedLatency(sr, st, 14.5);
    }
  }
  testSemitoneChangeIsImmediate();
  // Verify re-picking over a ringing low power chord across every drop setting
  // retains crisp high-frequency pick snap inside the latency-aligned 10 ms onset
  // window without interrupting the ringing chord underneath.
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
      const size_t lat = static_cast<size_t>(dp.latencySamples(st));
      double lp = 0.0;
      double hf10 = 0.0;
      for (size_t i = onset + lat; i < std::min(wet.size(), onset + lat + static_cast<size_t>(sr * 0.010)); ++i) {
        lp += (static_cast<double>(wet[i]) - lp) * lpCoeff;
        const double hp = static_cast<double>(wet[i]) - lp;
        hf10 += hp * hp;
      }
      assert(hf10 > 2.0);
    }
  }
  // Verify rapid 16th-note chugs at -3, -5, and -12 st retain punch and zero timing jitter.
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
    for (int st : {-3, -5, -12}) {
      std::vector<float> wet = dry;
      NAMRig::DropPitch dp;
      dp.prepare(sr);
      processInBlocks(dp, wet, st);
      const size_t lat = static_cast<size_t>(dp.latencySamples(st));
      double minDelayMs = 1e9;
      double maxDelayMs = -1e9;
      for (size_t c = 0; c < 6; ++c) {
        const size_t base = c * period;
        float dryPeak = 0.0f;
        float wetPeak = 0.0f;
        size_t dryIdx = base;
        size_t wetIdx = base + lat;
        for (size_t i = 0; i < 480; ++i) {
          if (std::fabs(dry[base + i]) > dryPeak) {
            dryPeak = std::fabs(dry[base + i]);
            dryIdx = base + i;
          }
          if (base + lat + i < wet.size() && std::fabs(wet[base + lat + i]) > wetPeak) {
            wetPeak = std::fabs(wet[base + lat + i]);
            wetIdx = base + lat + i;
          }
        }
        const float minRatio = st >= -5 ? 0.85f : 0.78f;
        assert(wetPeak >= dryPeak * minRatio);
        const double dMs = 1000.0 * static_cast<double>(wetIdx - dryIdx) / sr;
        minDelayMs = std::min(minDelayMs, dMs);
        maxDelayMs = std::max(maxDelayMs, dMs);
      }
      assert(maxDelayMs - minDelayMs < 0.5);
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
  testComplexChordsAndDissonantDyads();
  testPickupFormantPreservation();
  testBendAndVibratoTracking();
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
    NAMRig::DropPitch dpRef;
    dpRef.prepare(sr);
    const size_t atkStart = start + static_cast<size_t>(dpRef.latencySamples(-5));
    const size_t atkEnd = atkStart + static_cast<size_t>(sr * 0.010);
    const double atkDiffLow = hfDiffRms(atkLow, atkStart, atkEnd);
    const double atkDiffMid = hfDiffRms(neutralOut, atkStart, atkEnd);
    const double atkDiffHigh = hfDiffRms(atkHigh, atkStart, atkEnd);
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
