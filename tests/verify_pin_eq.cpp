// Graph pin EQ (src/pin_eq.h): port layout, exact bypass, steady-state
// response matching the drawn curve, click-free shape changes, and stability
// at the 16x True-domain rate. Also checks the Speaker graph's drawn load
// response against the speaker DSP.
#include <cmath>
#include <cstdio>
#include <vector>

#include "pin_eq.h"
#include "speaker_dynamics.h"

using namespace NAMRig;

static int failures = 0;
#define CHECK(cond, ...)                                  \
  do {                                                    \
    if (!(cond)) {                                        \
      ++failures;                                         \
      std::printf("  FAIL %s:%d: ", __FILE__, __LINE__);  \
      std::printf(__VA_ARGS__);                           \
      std::printf("\n");                                  \
    }                                                     \
  } while (0)

static constexpr double kPi = 3.14159265358979323846;

// Steady-state gain (dB) of a sine through the EQ, after a long settle.
static double measureDb(PinEq& eq, const PinBands& bands, double rate, double hz) {
  const size_t settle = static_cast<size_t>(rate * 0.25);
  const size_t span = static_cast<size_t>(rate * 0.1);
  std::vector<float> buf(settle + span);
  for (size_t i = 0; i < buf.size(); ++i)
    buf[i] = static_cast<float>(0.25 * std::sin(2.0 * kPi * hz * i / rate));
  float* ch[1] = {buf.data()};
  for (size_t start = 0; start < buf.size(); start += 512) {
    float* block[1] = {ch[0] + start};
    eq.process(block, 1, std::min<size_t>(512, buf.size() - start), rate, bands);
  }
  double in = 0.0, out = 0.0;
  for (size_t i = settle; i < buf.size(); ++i) {
    const double x = 0.25 * std::sin(2.0 * kPi * hz * i / rate);
    in += x * x;
    out += static_cast<double>(buf[i]) * buf[i];
  }
  return 10.0 * std::log10(out / in);
}

int main() {
  std::printf("== pin EQ ==\n");

  // Port layout: 4 panes x 6 bands x 4 params, appended after Mid Push.
  CHECK(kPinEqFirstPort == kMidPushPort + 1, "pins append after mid_push");
  CHECK(pinEqPort(PinEqPane::CabConsole, 5, kPinQ) == 154, "console pins keep ports 131..154");
  CHECK(pinEqPort(PinEqPane::Speaker, 0, kPinShape) == 155, "speaker pins append at 155");
  CHECK(pinEqPort(PinEqPane::Speaker, 5, kPinQ) == kPinEqFirstPort + kPinEqPortCount - 1 &&
        kPinEqFirstPort + kPinEqPortCount - 1 == 178, "last pin port");
  CHECK(kOverdriveDrivePort == 179 && kRigControlPortCount == 182, "overdrive appends after the pins");
  CHECK(pinEqSymbol(pinEqPort(PinEqPane::Sculpt, 0, kPinShape)) == "sculpt_pin1_shape", "symbol");
  CHECK(pinEqSymbol(pinEqPort(PinEqPane::Transformer, 2, kPinFreq)) == "transformer_pin3_freq", "symbol");
  CHECK(pinEqSymbol(pinEqPort(PinEqPane::CabConsole, 5, kPinQ)) == "cab_console_pin6_q", "symbol");
  CHECK(pinEqSymbol(pinEqPort(PinEqPane::Speaker, 3, kPinGain)) == "speaker_pin4_gain", "symbol");
  for (uint32_t port = kPinEqFirstPort; port < kRigControlPortCount; ++port) {
    CHECK(pinEqPort(static_cast<PinEqPane>(pinEqPaneOf(port)), pinEqBandOf(port), pinEqParamOf(port)) == port,
          "round trip %u", port);
  }
  CHECK(clampPinEqValue(pinEqPort(PinEqPane::Sculpt, 0, kPinFreq), 0.0f) == kPinFreqMin, "freq clamp");
  CHECK(clampPinEqValue(pinEqPort(PinEqPane::Sculpt, 0, kPinQ), NAN) == kPinQDefault, "non-finite Q");
  CHECK(clampPinEqValue(pinEqPort(PinEqPane::Sculpt, 0, kPinShape), 2.6f) == 3.0f, "shape rounds");

  // Default bands (no pins) and a 0 dB pin are exact bypass.
  {
    PinEq eq;
    PinBands bands;
    std::vector<float> a(4096), b(4096);
    for (size_t i = 0; i < a.size(); ++i) a[i] = b[i] = static_cast<float>(std::sin(0.01 * i) * 0.7);
    float* ch[1] = {a.data()};
    eq.process(ch, 1, a.size(), 48000.0, bands);
    bands[2].shape = kPinBell;  // pin placed at 0 dB
    eq.process(ch, 1, a.size(), 48000.0, bands);
    bool exact = true;
    for (size_t i = 0; i < a.size(); ++i) exact &= a[i] == b[i];
    CHECK(exact, "no pins / 0 dB pin must be bit-transparent");
  }

  // Steady state matches the drawn magnitude (what the graph shows is what you hear).
  for (double rate : {48000.0, 96000.0, 1536000.0}) {
    PinBands bands;
    bands[0] = {kPinBell, 1000.0, 9.0, 1.5};
    bands[1] = {kPinLowShelf, 120.0, -6.0, 0.7071};
    bands[2] = {kPinHighShelf, 6000.0, 4.0, 0.7071};
    for (double hz : {60.0, 400.0, 1000.0, 3000.0, 9000.0}) {
      PinEq eq;
      const double got = measureDb(eq, bands, rate, hz);
      const double want = pinBandsMagnitudeDb(bands, hz, rate);
      CHECK(std::fabs(got - want) < 0.05, "rate %.0f, %.0f Hz: measured %.3f dB, drawn %.3f dB",
            rate, hz, got, want);
    }
  }

  // Adding, reshaping and removing a pin under a steady tone never steps:
  // the largest sample-to-sample change stays near the tone's own slope.
  {
    const double rate = 48000.0, hz = 200.0;
    PinEq eq;
    PinBands bands;
    const size_t n = static_cast<size_t>(rate * 0.6);
    std::vector<float> buf(n);
    for (size_t i = 0; i < n; ++i) buf[i] = static_cast<float>(0.5 * std::sin(2.0 * kPi * hz * i / rate));
    for (size_t start = 0; start < n; start += 128) {
      if (start == 4800) bands[0] = {kPinBell, 200.0, 12.0, 1.0};     // add
      if (start == 14400) bands[0].shape = kPinLowShelf;              // reshape
      if (start == 24000) bands[0] = PinBand{};                        // remove
      float* ch[1] = {buf.data() + start};
      eq.process(ch, 1, std::min<size_t>(128, n - start), rate, bands);
    }
    double maxStep = 0.0;
    for (size_t i = 1; i < n; ++i) maxStep = std::max(maxStep, std::fabs((double)buf[i] - buf[i - 1]));
    // A +12 dB tone (x4) at 200 Hz moves at most 4 * 0.5 * 2*pi*200/48000 ~ 0.052 per sample.
    CHECK(maxStep < 0.06, "max step %.4f indicates a click", maxStep);
    double tail = 0.0;
    for (size_t i = n - 4800; i < n; ++i) {
      const double x = 0.5 * std::sin(2.0 * kPi * hz * i / rate);
      tail = std::max(tail, std::fabs(buf[i] - x));
    }
    CHECK(tail < 1.0e-6, "removed pin must return to exact dry (err %.2e)", tail);
  }

  // Stability: extreme low/high settings at the 16x True rate stay finite.
  {
    PinEq eq;
    PinBands bands;
    bands[0] = {kPinLowShelf, 20.0, 18.0, 0.1};
    bands[1] = {kPinBell, 20.0, -18.0, 10.0};
    bands[2] = {kPinHighShelf, 20000.0, 18.0, 10.0};
    std::vector<float> buf(1 << 16);
    for (size_t i = 0; i < buf.size(); ++i) buf[i] = (i % 977) < 3 ? 1.0f : 0.0f;
    float* ch[1] = {buf.data()};
    eq.process(ch, 1, buf.size(), 1536000.0, bands);
    bool finite = true;
    for (float v : buf) finite &= std::isfinite(v) && std::fabs(v) < 1.0e3f;
    CHECK(finite, "extreme pins at 1.536 MHz must stay finite and bounded");
  }

  // The Speaker graph draws SpeakerDynamics::responseDb; with compression and
  // drive at zero the DSP is linear and must measure exactly that.
  for (int profile = SpeakerDynamics::kResistive; profile < SpeakerDynamics::kProfileCount; ++profile) {
    for (double rate : {48000.0, 384000.0}) {
      const float thump = 70.0f, resonance = 80.0f, damping = 0.4f;
      for (double hz : {50.0, 100.0, 400.0, 3000.0, 9000.0}) {
        SpeakerDynamics spk;
        spk.reset();
        const size_t settle = static_cast<size_t>(rate * 0.3), span = static_cast<size_t>(rate * 0.1);
        std::vector<float> buf(settle + span);
        for (size_t i = 0; i < buf.size(); ++i)
          buf[i] = static_cast<float>(0.1 * std::sin(2.0 * kPi * hz * i / rate));
        for (size_t start = 0; start < buf.size(); start += 512)
          spk.process(buf.data() + start, std::min<size_t>(512, buf.size() - start), rate, profile,
                      0.0f, 0.0f, thump, resonance, damping);
        double in = 0.0, out = 0.0;
        for (size_t i = settle; i < buf.size(); ++i) {
          const double x = 0.1 * std::sin(2.0 * kPi * hz * i / rate);
          in += x * x;
          out += static_cast<double>(buf[i]) * buf[i];
        }
        const double got = 10.0 * std::log10(out / in);
        const double want = SpeakerDynamics::responseDb(profile, hz, rate, thump, resonance, damping);
        CHECK(std::fabs(got - want) < 0.05, "speaker profile %d rate %.0f, %.0f Hz: measured %.3f dB, drawn %.3f dB",
              profile, rate, hz, got, want);
      }
    }
  }
  CHECK(SpeakerDynamics::responseDb(SpeakerDynamics::kCaptured, 100.0, 48000.0, 100, 100, 0) == 0.0,
        "captured speaker draws flat");

  if (failures == 0) std::printf("  ALL PASSED\n");
  return failures == 0 ? 0 : 1;
}
