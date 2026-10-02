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
                       float levelDb) {
  Overdrive od;
  od.process(x.data(), x.size(), rate, drive, tone, levelDb);
  return x;
}

int failures = 0;
void check(bool ok, const char* label) {
  std::printf("  %s  %s\n", ok ? "PASS" : "FAIL", label);
  if (!ok) ++failures;
}
}  // namespace

int main() {
  // ---- Drive 0 is an exact bypass, whatever Tone and Level say. ----
  for (double rate : {48000.0, 384000.0}) {
    const auto x = sine(440.0, 0.3, rate, 4096);
    check(run(x, rate, 0.0f, 0.0f, 12.0f) == x, "Drive 0 is bit-exact (Tone/Level ignored)");
    check(run(x, rate, NAN, 50.0f, 0.0f) == x, "non-finite Drive falls back to bypass");
  }

  // ---- Turning Drive back to 0 fades out and returns to exact bypass. ----
  {
    const double rate = 96000.0;
    Overdrive od;
    auto a = sine(440.0, 0.3, rate, 9600);
    od.process(a.data(), a.size(), rate, 60.0f, 50.0f, 0.0f);
    check(od.active(), "engaged after Drive > 0");
    auto b = sine(440.0, 0.3, rate, 96000);
    od.process(b.data(), b.size(), rate, 0.0f, 50.0f, 0.0f);
    check(!od.active(), "fades out and resets after Drive returns to 0");
    const auto c = sine(440.0, 0.3, rate, 4096);
    auto d = c;
    od.process(d.data(), d.size(), rate, 0.0f, 50.0f, 0.0f);
    check(d == c, "bit-exact again after the fade-out");
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
    od.process(x.data(), x.size(), 48000.0, 100.0f, NAN, NAN);
    bool finite = true;
    for (float v : x) finite = finite && std::isfinite(v);
    check(finite, "finite output with huge input and non-finite Tone/Level");
  }

  std::printf(failures ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n", failures);
  return failures ? 1 : 0;
}
