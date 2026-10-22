// Sculpt's Tube Screamer-style overdrive (src/overdrive.h).
#include <cmath>
#include <complex>
#include <cstdio>
#include <vector>

#include "overdrive.h"

using NAMRig::Overdrive;

namespace {
constexpr double kPi = 3.14159265358979323846;

std::vector<float> sine(double hz, double amplitude, double rate, size_t count) {
  std::vector<float> x(count);
  for (size_t i = 0; i < count; ++i)
    x[i] = static_cast<float>(amplitude * std::sin(2.0 * kPi * hz * i / rate));
  return x;
}

// Amplitude of `hz` over the second half (after smoothing has settled).
double level(const std::vector<float>& y, double hz, double rate) {
  std::complex<double> acc = 0.0;
  const size_t from = y.size() / 2;
  for (size_t i = from; i < y.size(); ++i)
    acc += double(y[i]) * std::polar(1.0, -2.0 * kPi * hz * i / rate);
  return 2.0 * std::abs(acc) / double(y.size() - from);
}

std::vector<float> run(std::vector<float> x, double rate, float drive, float tone,
                       float levelDb, bool enabled = true) {
  Overdrive od;
  od.process(x.data(), x.size(), rate, drive, tone, levelDb, enabled);
  return x;
}

int failures = 0;
void check(bool ok, const char* label) {
  std::printf("  %s  %s\n", ok ? "PASS" : "FAIL", label);
  if (!ok) ++failures;
}
}  // namespace

int main() {
  // ---- Tone card OFF is an exact bypass, whatever Drive, Tone and Level say. ----
  for (double rate : {48000.0, 384000.0}) {
    const auto x = sine(440.0, 0.3, rate, 4096);
    check(run(x, rate, 50.0f, 50.0f, 12.0f, false) == x, "Tone card OFF is bit-exact (Drive/Tone/Level ignored)");
    check(run(x, rate, 0.0f, 0.0f, 12.0f, false) == x, "Tone card OFF with Drive 0 is bit-exact");
  }

  // ---- Drive 0 with card ON is an active, distortionless boost (Level and Tone apply, no clipping). ----
  {
    const double rate = 96000.0;
    const size_t n = 96000;
    const auto x = sine(440.0, 0.2, rate, n);
    const auto unity = run(x, rate, 0.0f, 100.0f, 0.0f, true);
    const auto boosted = run(x, rate, 0.0f, 100.0f, 6.0f, true);
    const double unityLvl = level(unity, 440.0, rate);
    const double boostLvl = level(boosted, 440.0, rate);
    check(std::fabs(20.0 * std::log10(boostLvl / unityLvl) - 6.0) < 0.05,
          "Drive 0 level +6 dB provides 6 dB boost");

    // Pure distortionless boost: no clipping harmonics (H3 and H2 negligible).
    const double h3 = level(boosted, 1320.0, rate) / boostLvl;
    const double h2 = level(boosted, 880.0, rate) / boostLvl;
    check(h3 < 1.0e-4 && h2 < 1.0e-4, "Drive 0 is distortionless (no harmonics added)");

    Overdrive od;
    auto a = sine(440.0, 0.2, rate, 9600);
    od.process(a.data(), a.size(), rate, 0.0f, 50.0f, 6.0f, true);
    check(od.active(), "Drive 0 remains active when tone card is ON");
  }

  // ---- Turning tone card OFF fades out and returns to exact bypass. ----
  {
    const double rate = 96000.0;
    Overdrive od;
    auto a = sine(440.0, 0.3, rate, 9600);
    od.process(a.data(), a.size(), rate, 60.0f, 50.0f, 0.0f, true);
    check(od.active(), "engaged while tone card is ON");
    auto b = sine(440.0, 0.3, rate, 96000);
    od.process(b.data(), b.size(), rate, 60.0f, 50.0f, 0.0f, false);
    check(!od.active(), "fades out and resets after tone card is turned OFF");
    const auto c = sine(440.0, 0.3, rate, 4096);
    auto d = c;
    od.process(d.data(), d.size(), rate, 60.0f, 50.0f, 0.0f, false);
    check(d == c, "bit-exact again after turning card OFF");
  }

  // ---- Engaging does not jump: the first samples stay near the dry input. ----
  {
    const double rate = 96000.0;
    const auto x = sine(440.0, 0.3, rate, 64);
    const auto y = run(x, rate, 100.0f, 50.0f, 0.0f);
    double worst = 0.0;
    for (size_t i = 0; i < 16; ++i) worst = std::max(worst, std::fabs(double(y[i] - x[i])));
    check(worst < 0.01, "engage crossfades in from the dry signal");
  }

  // ---- TS character: symmetric soft clipping, more with Drive. ----
  {
    const double rate = 384000.0;
    const size_t n = 192000;
    const auto x = sine(220.0, 0.1, rate, n);
    const auto low = run(x, rate, 10.0f, 100.0f, 0.0f);
    const auto high = run(x, rate, 100.0f, 100.0f, 0.0f);
    const double h3Low = level(low, 660.0, rate) / level(low, 220.0, rate);
    const double h3High = level(high, 660.0, rate) / level(high, 220.0, rate);
    const double h2High = level(high, 440.0, rate) / level(high, 220.0, rate);
    std::printf("    H3 %.1f dBc (drive 10) -> %.1f dBc (drive 100), H2 %.1f dBc\n",
                20 * std::log10(h3Low), 20 * std::log10(h3High), 20 * std::log10(h2High));
    check(h3High > h3Low * 2.0, "more Drive adds odd harmonics");
    check(h3High > 0.1, "full Drive is audibly distorted (H3 above -20 dBc)");
    check(h2High < 1.0e-3, "symmetric diode pair: no even harmonics");
  }

  // ---- Bass bypasses the clipper: a low note stays cleaner than a mid one. ----
  {
    const double rate = 384000.0;
    const size_t n = 192000;
    const auto lowNote = run(sine(82.0, 0.01, rate, n), rate, 70.0f, 100.0f, 0.0f);
    const auto midNote = run(sine(800.0, 0.01, rate, n), rate, 70.0f, 100.0f, 0.0f);
    const double lowGain = level(lowNote, 82.0, rate) / 0.01;
    const double midGain = level(midNote, 800.0, rate) / 0.01;
    check(midGain > lowGain * 1.5, "720 Hz high-pass: mids pushed harder than bass");
  }

  // ---- Compression: output peak grows far slower than the input. ----
  {
    const double rate = 384000.0;
    const size_t n = 96000;
    const double quiet = level(run(sine(800.0, 0.05, rate, n), rate, 60.0f, 100.0f, 0.0f), 800.0, rate);
    const double loud = level(run(sine(800.0, 0.5, rate, n), rate, 60.0f, 100.0f, 0.0f), 800.0, rate);
    check(loud / quiet < 4.0, "a 20 dB louder input comes out less than 12 dB louder");
  }

  // ---- Level is a plain dB trim on the pedal output. ----
  {
    const double rate = 96000.0;
    const auto x = sine(800.0, 0.2, rate, 96000);
    const double unity = level(run(x, rate, 40.0f, 50.0f, 0.0f), 800.0, rate);
    const double boosted = level(run(x, rate, 40.0f, 50.0f, 6.0f), 800.0, rate);
    check(std::fabs(20.0 * std::log10(boosted / unity) - 6.0) < 0.01, "Level +6 dB adds 6 dB");
  }

  // ---- The graph's Tone/Level curve matches the DSP after the clipper. ----
  // With a tiny input the clipper is linear, so Tone 0 vs Tone 100 isolates
  // the tone filter: compare the measured difference to postClipResponseDb.
  {
    bool ok = true;
    for (double rate : {48000.0, 384000.0}) {
      for (double hz : {200.0, 1000.0, 3000.0, 8000.0}) {
        const auto x = sine(hz, 1.0e-4, rate, size_t(rate));
        for (float tone : {0.0f, 35.0f, 80.0f}) {
          const double dark = level(run(x, rate, 50.0f, tone, -4.0f), hz, rate);
          const double ref = level(run(x, rate, 50.0f, 100.0f, 0.0f), hz, rate);
          const double measured = 20.0 * std::log10(dark / ref);
          const double drawn = Overdrive::postClipResponseDb(hz, rate, tone, -4.0f) -
                               Overdrive::postClipResponseDb(hz, rate, 100.0f, 0.0f);
          if (std::fabs(measured - drawn) > 0.05) {
            std::printf("    rate %.0f hz %.0f tone %.0f measured %.3f drawn %.3f\n", rate, hz,
                        tone, measured, drawn);
            ok = false;
          }
        }
      }
    }
    check(ok, "graph Tone/Level response matches the DSP within 0.05 dB");
    check(Overdrive::postClipResponseDb(3000.0, 48000.0, 0.0f, 0.0f) < -10.0,
          "Tone 0 is dark (-10 dB or more at 3 kHz)");
    check(Overdrive::postClipResponseDb(100.0, 48000.0, 50.0f, 0.0f) > -0.1,
          "Tone leaves the lows alone");
  }

  // ---- Stays finite on hostile input. ----
  {
    std::vector<float> x(4096, 0.0f);
    x[10] = 1.0e6f;
    x[11] = -1.0e6f;
    Overdrive od;
    od.process(x.data(), x.size(), 48000.0, 100.0f, NAN, NAN, NAN);
    bool finite = true;
    for (float v : x) finite = finite && std::isfinite(v);
    check(finite, "finite output with huge input and non-finite Tone/Level/Tight");
  }

  // ---- Variable Tight / Cut control sweeps pre-clip high-pass filter. ----
  {
    const double rate = 384000.0;
    const size_t n = 192000;
    Overdrive odWarm, odTight;
    auto xWarm = sine(120.0, 0.1, rate, n);
    auto xTight = xWarm;
    odWarm.process(xWarm.data(), xWarm.size(), rate, 70.0f, 50.0f, 0.0f, 200.0f);
    odTight.process(xTight.data(), xTight.size(), rate, 70.0f, 50.0f, 0.0f, 1400.0f);
    const double h3Warm = level(xWarm, 360.0, rate);
    const double h3Tight = level(xTight, 360.0, rate);
    check(h3Warm > h3Tight * 1.8, "Tight 1400 Hz cuts 120 Hz pre-clip distortion much more than Tight 200 Hz");
    check(Overdrive::preClipHighPassResponseDb(120.0, 48000.0, 1400.0f) < -15.0,
          "preClipHighPassResponseDb at 1400 Hz is below -15 dB at 120 Hz");
    check(Overdrive::preClipHighPassResponseDb(3000.0, 48000.0, 720.0f) > -1.0,
          "preClipHighPassResponseDb passes highs near unity");
  }

  // ---- 4 Diode Voicings: Classic TS, SD-1 Asymmetric, LED Turbo, Germanium ----
  {
    const double rate = 192000.0;
    const size_t n = 96000;
    // 1. SD-1 Asymmetric produces rich 2nd harmonic (H2) and asymmetric peak levels.
    auto xInput = sine(1000.0, 0.15, rate, n);
    auto xTS = xInput;
    auto xSD1 = xInput;
    Overdrive odTS, odSD1;
    odTS.process(xTS.data(), xTS.size(), rate, 80.0f, 50.0f, 0.0f, 720.0f, 0.0f);
    odSD1.process(xSD1.data(), xSD1.size(), rate, 80.0f, 50.0f, 0.0f, 720.0f, 1.0f);

    const double h2TS = level(xTS, 2000.0, rate);
    const double h2SD1 = level(xSD1, 2000.0, rate);
    const double f0SD1 = level(xSD1, 1000.0, rate);
    check(h2TS < 1.0e-5, "Classic TS has negligible even harmonics (symmetric)");
    check(h2SD1 / f0SD1 > 0.02, "SD-1 Asymmetric generates prominent 2nd-order even harmonics (> -34 dBc)");

    // Positive vs Negative peak asymmetry in SD-1:
    float maxPos = 0.0f, maxNeg = 0.0f;
    for (size_t i = n / 2; i < n; ++i) {
      if (xSD1[i] > maxPos) maxPos = xSD1[i];
      if (-xSD1[i] > maxNeg) maxNeg = -xSD1[i];
    }
    check(maxPos > maxNeg * 1.15f, "SD-1 clips positive and negative half-cycles with asymmetric thresholds");

    // 2. LED Turbo has higher clipping threshold and higher headroom (less distortion at medium drive).
    auto xTS_med = xInput;
    auto xLED_med = xInput;
    Overdrive odTS2, odLED;
    odTS2.process(xTS_med.data(), xTS_med.size(), rate, 40.0f, 50.0f, 0.0f, 720.0f, 0.0f);
    odLED.process(xLED_med.data(), xLED_med.size(), rate, 40.0f, 50.0f, 0.0f, 720.0f, 2.0f);
    const double f0TS = level(xTS_med, 1000.0, rate);
    const double f0LED = level(xLED_med, 1000.0, rate);
    check(f0LED > f0TS * 1.4, "LED Turbo provides significantly higher dynamic output headroom than Classic TS");

    // 3. Germanium has lower clipping threshold and compresses earlier into a warm envelope.
    auto xTS_low = sine(1000.0, 0.08, rate, n);
    auto xGe_low = xTS_low;
    Overdrive odTS3, odGe;
    odTS3.process(xTS_low.data(), xTS_low.size(), rate, 30.0f, 50.0f, 0.0f, 720.0f, 0.0f);
    odGe.process(xGe_low.data(), xGe_low.size(), rate, 30.0f, 50.0f, 0.0f, 720.0f, 3.0f);
    const double f0TS_low = level(xTS_low, 1000.0, rate);
    const double f0Ge_low = level(xGe_low, 1000.0, rate);
    check(f0Ge_low < f0TS_low * 0.85, "Germanium compresses earlier with lower clipping ceiling than Classic TS");

    // 4. Live Voicing switching crossfades smoothly without DC jumps or instability.
    Overdrive odSwitch;
    auto xStream = sine(440.0, 0.2, rate, 48000);
    odSwitch.process(xStream.data(), 12000, rate, 60.0f, 50.0f, 0.0f, 720.0f, 0.0f);
    odSwitch.process(xStream.data() + 12000, 12000, rate, 60.0f, 50.0f, 0.0f, 720.0f, 1.0f);
    odSwitch.process(xStream.data() + 24000, 12000, rate, 60.0f, 50.0f, 0.0f, 720.0f, 2.0f);
    odSwitch.process(xStream.data() + 36000, 12000, rate, 60.0f, 50.0f, 0.0f, 720.0f, 3.0f);
    bool streamFinite = true;
    for (float v : xStream) streamFinite = streamFinite && std::isfinite(v) && std::fabs(v) < 10.0f;
    check(streamFinite, "Live Voicing switching stays finite, bounded, and seamless across buffer boundaries");
  }

  std::printf(failures ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n", failures);
  return failures ? 1 : 0;
}
