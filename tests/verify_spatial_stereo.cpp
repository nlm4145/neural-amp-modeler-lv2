// Verifies Step 3 spatial stereo width, Dome 90-degree phase-difference
// stereoizer, low-band dual-cab coherence, auto-alignment, and end-to-end LV2
// dual-cabinet mixing / shelf compensation.
//
// Build (macOS):
//   clang++ -O2 -std=c++17 -D_DARWIN_C_SOURCE -framework Accelerate \
//     -Isrc -Ideps/pffft -Ideps/lv2/include -Ideps/NeuralAudio \
//     -Ideps/NeuralAudio/deps/RTNeural/modules/json \
//     src/dsp_accel.cpp src/wav_ir.cpp tests/verify_spatial_stereo.cpp \
//     -o /tmp/verify_spatial_stereo

#include "nam_rig_plugin.h"
#include "spatial_stereo.h"
#include "wav_ir.h"
#include "win32_control_defaults.h"

#include "NeuralAudio/NeuralModel.h"

#include "lv2/atom/atom.h"
#include "lv2/atom/forge.h"
#include "lv2/core/lv2.h"
#include "lv2/patch/patch.h"
#include "lv2/urid/urid.h"
#include "lv2/worker/worker.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <unistd.h>
#include <vector>

namespace {

using namespace NAMRig;
constexpr double kPi = 3.14159265358979323846;

int failures = 0;

void check(bool ok, const char* label) {
  std::printf("  %s  %s\n", ok ? "PASS" : "FAIL", label);
  if (!ok) ++failures;
}

void require(bool ok, const char* label) {
  if (ok) return;
  std::fprintf(stderr, "FATAL: %s\n", label);
  std::exit(1);
}

struct ToneMetrics {
  double rms = 0.0;
  double re = 0.0;
  double im = 0.0;
  double mag = 0.0;
  double phaseRad = 0.0;
};

ToneMetrics measureTone(const std::vector<float>& x, size_t start, size_t count,
                        double freqHz, double rate) {
  double sumSq = 0.0;
  double accRe = 0.0;
  double accIm = 0.0;
  const double w = 2.0 * kPi * freqHz / rate;
  for (size_t i = 0; i < count; ++i) {
    const double v = x[start + i];
    sumSq += v * v;
    const double ang = w * static_cast<double>(i);
    accRe += v * std::cos(ang);
    accIm += -v * std::sin(ang);
  }
  ToneMetrics m;
  m.rms = std::sqrt(sumSq / static_cast<double>(count));
  const double scale = 2.0 / static_cast<double>(count);
  m.re = accRe * scale;
  m.im = accIm * scale;
  m.mag = std::hypot(m.re, m.im);
  m.phaseRad = std::atan2(m.im, m.re);
  return m;
}

double wrapAngleDeg(double rad) {
  double deg = rad * (180.0 / kPi);
  while (deg > 180.0) deg -= 360.0;
  while (deg <= -180.0) deg += 360.0;
  return deg;
}

void writeFloatWav(const std::filesystem::path& path, uint32_t rate,
                   const std::vector<float>& chL,
                   const std::vector<float>* chR = nullptr) {
  const uint16_t channels = chR ? 2 : 1;
  const uint32_t frames = static_cast<uint32_t>(chL.size());
  const uint32_t dataBytes = frames * channels * 4u;
  std::ofstream file(path, std::ios::binary);
  auto little32 = [&](uint32_t v) {
    for (int i = 0; i < 4; ++i) file.put(static_cast<char>((v >> (8 * i)) & 0xff));
  };
  auto little16 = [&](uint16_t v) {
    file.put(static_cast<char>(v & 0xff));
    file.put(static_cast<char>((v >> 8) & 0xff));
  };
  file.write("RIFF", 4);
  little32(36u + dataBytes);
  file.write("WAVEfmt ", 8);
  little32(16u);
  little16(3u);  // IEEE float
  little16(channels);
  little32(rate);
  little32(rate * channels * 4u);
  little16(static_cast<uint16_t>(channels * 4u));
  little16(32u);
  file.write("data", 4);
  little32(dataBytes);
  for (uint32_t i = 0; i < frames; ++i) {
    float l = chL[i];
    file.write(reinterpret_cast<const char*>(&l), sizeof(float));
    if (chR) {
      float r = (*chR)[i];
      file.write(reinterpret_cast<const char*>(&r), sizeof(float));
    }
  }
  file.close();
  require(static_cast<bool>(file), "write IEEE float WAV fixture");
}

std::vector<float> makeDampedCabIR(double rate, double durationSec,
                                   double shiftSec, float polarity,
                                   double wLow, double wMid, double wHigh) {
  const size_t n = static_cast<size_t>(std::llround(rate * durationSec));
  std::vector<float> taps(n, 0.0f);
  const double baseOffset = 0.020 + shiftSec;
  for (size_t i = 0; i < n; ++i) {
    const double t = static_cast<double>(i) / rate - baseOffset;
    if (t < 0.0) continue;
    const double attack = 1.0 - std::exp(-t / 0.00035);
    const double low = wLow * std::exp(-38.0 * t) * std::cos(2.0 * kPi * 115.0 * t);
    const double mid = wMid * std::exp(-140.0 * t) * std::sin(2.0 * kPi * 680.0 * t);
    const double high = wHigh * std::exp(-340.0 * t) * std::cos(2.0 * kPi * 2900.0 * t);
    taps[i] = polarity * static_cast<float>(attack * (low + mid + high));
  }
  return taps;
}

// ---------- Part 1: spatial_stereo.h unit verification ----------
void testSpatialStereoUnits() {
  std::printf("-- Part 1: applySingleStereoWidthSample & DomeHilbertStereoizer --\n");

  // 1a. applySingleStereoWidthSample
  bool passthroughExact = true;
  bool monoInvariance = true;
  bool sideScaled = true;
  bool monoUnchanged = true;
  for (int i = 0; i < 64; ++i) {
    const float inL = 0.45f * std::sin(0.17f * i) - 0.12f * std::cos(0.41f * i);
    const float inR = 0.25f * std::cos(0.23f * i) + 0.19f * std::sin(0.11f * i);
    float l0 = inL, r0 = inR;
    applySingleStereoWidthSample(l0, r0, 0.0f);
    if (l0 != inL || r0 != inR) passthroughExact = false;

    for (float w : {0.5f, 1.0f}) {
      float l = inL, r = inR;
      applySingleStereoWidthSample(l, r, w);
      const float midIn = 0.5f * (inL + inR);
      const float midOut = 0.5f * (l + r);
      const float sideIn = 0.5f * (inL - inR);
      const float sideOut = 0.5f * (l - r);
      if (std::fabs(midOut - midIn) > 1.0e-6f) monoInvariance = false;
      if (std::fabs(sideOut - sideIn * (1.0f + 0.8f * w)) > 1.0e-5f) sideScaled = false;

      float ml = inL, mr = inL;
      applySingleStereoWidthSample(ml, mr, w);
      if (ml != inL || mr != inL) monoUnchanged = false;
    }
  }
  check(passthroughExact, "applySingleStereoWidthSample(w=0) is bit-exact passthrough");
  check(monoInvariance, "applySingleStereoWidthSample preserves (L+R)/2 identically across widths");
  check(sideScaled, "applySingleStereoWidthSample scales (L-R) cleanly up to 1.8x at w=1");
  check(monoUnchanged, "applySingleStereoWidthSample leaves pure mono (L==R) unchanged");

  // 1b. DomeHilbertStereoizer across 44.1 / 48 / 96 / 192 kHz
  const double rates[] = {44100.0, 48000.0, 96000.0, 192000.0};
  const double freqs[] = {80.0, 160.0, 400.0, 1000.0, 1150.0, 2500.0, 6000.0, 10000.0, 12000.0};
  constexpr double kMaxSpread = static_cast<double>(DomeHilbertStereoizer::kMaxSpread);

  for (double rate : rates) {
    DomeHilbertStereoizer stereoizer;
    stereoizer.prepare(rate);

    double worstMonoRippleDb = 0.0;
    double worstLrImbalanceDb = 0.0;
    double worstQuadErrDeg = 0.0;
    double sideAt60Hz = 0.0;
    double sideAt1kHz = 0.0;
    double sideAt12kHz = 0.0;
    bool widthZeroExact = true;

    const size_t settle = static_cast<size_t>(rate * 0.20);
    const size_t measure = static_cast<size_t>(rate * 0.10);
    const size_t total = settle + measure;

    auto runSine = [&](double hz, float width) {
      stereoizer.reset();
      std::vector<float> outM(measure), outS(measure), outL(measure), outR(measure);
      const double w = 2.0 * kPi * hz / rate;
      for (size_t i = 0; i < total; ++i) {
        const float in = static_cast<float>(std::sin(w * static_cast<double>(i)));
        float l = 0.0f, r = 0.0f;
        stereoizer.processSample(in, in, width, l, r);
        if (i >= settle) {
          const size_t k = i - settle;
          outL[k] = l;
          outR[k] = r;
          outM[k] = 0.5f * (l + r);
          outS[k] = 0.5f * (l - r);
        }
      }
      return std::array<ToneMetrics, 4>{
          measureTone(outM, 0, measure, hz, rate),
          measureTone(outS, 0, measure, hz, rate),
          measureTone(outL, 0, measure, hz, rate),
          measureTone(outR, 0, measure, hz, rate)};
    };

    // Check w = 0.0f yields identical L==R and 0 dB gain
    {
      auto m0 = runSine(1000.0, 0.0f);
      if (std::fabs(m0[1].mag) > 1.0e-6 || std::fabs(20.0 * std::log10(m0[0].mag)) > 0.01)
        widthZeroExact = false;
    }

    const double expectedNorm = 1.0 / std::sqrt(1.0 + kMaxSpread * kMaxSpread);
    for (double hz : freqs) {
      if (hz >= rate * 0.42) continue;
      auto m = runSine(hz, 1.0f);
      const double monoGainDb = 20.0 * std::log10(std::max(1.0e-12, m[0].mag) / expectedNorm);
      worstMonoRippleDb = std::max(worstMonoRippleDb, std::fabs(monoGainDb));

      const double lrDiffDb = std::fabs(20.0 * std::log10(m[2].mag / std::max(1.0e-12, m[3].mag)));
      worstLrImbalanceDb = std::max(worstLrImbalanceDb, lrDiffDb);

      const double dDeg = std::fabs(wrapAngleDeg(m[1].phaseRad - m[0].phaseRad));
      worstQuadErrDeg = std::max(worstQuadErrDeg, std::fabs(dDeg - 90.0));

      if (std::fabs(hz - 1000.0) < 1.0) sideAt1kHz = m[1].mag;
      if (std::fabs(hz - 12000.0) < 1.0) sideAt12kHz = m[1].mag;
    }
    sideAt60Hz = runSine(60.0, 1.0f)[1].mag;

    // Broadband balanced dual-cab RMS check across [200 Hz .. 7 kHz]
    double broadbandLrDiffDb = 0.0;
    double broadbandMonoDb = 0.0;
    {
      stereoizer.reset();
      std::vector<double> multiFreqs;
      for (int k = 0; k < 24; ++k) {
        const double t = static_cast<double>(k) / 23.0;
        multiFreqs.push_back(200.0 * std::pow(35.0, t));
      }
      double sumL2 = 0.0, sumR2 = 0.0, sumM2 = 0.0, sumIn2 = 0.0;
      const size_t n = static_cast<size_t>(rate * 0.5);
      for (size_t i = 0; i < n; ++i) {
        double x = 0.0;
        for (size_t k = 0; k < multiFreqs.size(); ++k) {
          const double w = 2.0 * kPi * multiFreqs[k] / rate;
          x += std::sin(w * static_cast<double>(i) + 0.7 * static_cast<double>(k));
        }
        const float xf = static_cast<float>(x / multiFreqs.size());
        float l = 0.0f, r = 0.0f;
        stereoizer.processSample(xf, xf, 1.0f, l, r);
        if (i >= n / 4) {
          sumL2 += static_cast<double>(l) * l;
          sumR2 += static_cast<double>(r) * r;
          const double m = 0.5 * (l + r);
          sumM2 += m * m;
          sumIn2 += static_cast<double>(xf) * xf;
        }
      }
      broadbandLrDiffDb = std::fabs(10.0 * std::log10(sumL2 / std::max(1.0e-18, sumR2)));
      broadbandMonoDb = std::fabs(10.0 * std::log10(sumM2 / (expectedNorm * expectedNorm * sumIn2)));
    }

    char label[256];
    std::snprintf(label, sizeof(label),
                  "DomeHilbertStereoizer @ %.0f Hz: mono %.4f dB, quad err %.2f deg, max L/R %.3f dB (broad %.3f dB)",
                  rate, worstMonoRippleDb, worstQuadErrDeg, worstLrImbalanceDb, broadbandLrDiffDb);
    check(widthZeroExact && worstMonoRippleDb < 0.01 && worstLrImbalanceDb < 0.10 &&
              worstQuadErrDeg < 1.0 && broadbandLrDiffDb < 0.05 && broadbandMonoDb < 0.01 &&
              sideAt60Hz < 0.20 * sideAt1kHz && sideAt12kHz < 0.65 * sideAt1kHz,
          label);
  }
}

// ---------- Part 2: WavIR coherence & alignment recovery ----------
void testWavIrCoherenceAndAlignment(const std::filesystem::path& tmpDir) {
  std::printf("-- Part 2: WavIR::lowBandCoherence & findBestAlignment --\n");

  for (double rate : {44100.0, 48000.0, 96000.0}) {
    const uint32_t uRate = static_cast<uint32_t>(rate);
    const auto irA = makeDampedCabIR(rate, 0.16, 0.0, 1.0f, 0.7, 0.4, 0.25);
    const auto irBLate = makeDampedCabIR(rate, 0.16, +0.0035, 1.0f, 0.7, 0.4, 0.25);
    const auto irBEarly = makeDampedCabIR(rate, 0.16, -0.00173, 1.0f, 0.7, 0.4, 0.25);
    const auto irBInv = makeDampedCabIR(rate, 0.16, +0.0022, -1.0f, 0.7, 0.4, 0.25);

    const auto pA = tmpDir / ("align-a-" + std::to_string(uRate) + ".wav");
    const auto pBLate = tmpDir / ("align-blate-" + std::to_string(uRate) + ".wav");
    const auto pBEarly = tmpDir / ("align-bearly-" + std::to_string(uRate) + ".wav");
    const auto pBInv = tmpDir / ("align-binv-" + std::to_string(uRate) + ".wav");
    writeFloatWav(pA, uRate, irA);
    writeFloatWav(pBLate, uRate, irBLate);
    writeFloatWav(pBEarly, uRate, irBEarly);
    writeFloatWav(pBInv, uRate, irBInv);

    // Sign convention: B arrives later (+3.5 ms) -> delay A (-3.5 ms alignment).
    const auto resLate = WavIR::findBestAlignment(pA.c_str(), pBLate.c_str(), rate);
    // B arrives earlier (-1.73 ms) -> delay B (+1.73 ms alignment).
    const auto resEarly = WavIR::findBestAlignment(pA.c_str(), pBEarly.c_str(), rate);
    // B inverted & delayed +2.2 ms -> delay A (-2.2 ms) & invertPolarity = true.
    const auto resInv = WavIR::findBestAlignment(pA.c_str(), pBInv.c_str(), rate);

    auto objA = WavIR::load(pA.c_str(), rate, 256, -1);
    auto objBLate = WavIR::load(pBLate.c_str(), rate, 256, -1);
    auto objBInv0 = makeDampedCabIR(rate, 0.16, 0.0, -1.0f, 0.7, 0.4, 0.25);
    const auto pBInv0 = tmpDir / ("align-binv0-" + std::to_string(uRate) + ".wav");
    writeFloatWav(pBInv0, uRate, objBInv0);
    auto objBInvZero = WavIR::load(pBInv0.c_str(), rate, 256, -1);

    const float rhoInPhase = WavIR::lowBandCoherence(objA.get(), objA.get(), 0.0f);
    const float rhoInv0 = WavIR::lowBandCoherence(objA.get(), objBInvZero.get(), 0.0f);
    const float rhoAlignedLate = WavIR::lowBandCoherence(objA.get(), objBLate.get(), resLate.delayMs);

    char label[256];
    std::snprintf(label, sizeof(label),
                  "WavIR alignment @ %u Hz: -3.5ms->%.3f, +1.73ms->%.3f, inv(-2.2ms)->%.3f (inv=%d), rho=%.3f/%.3f",
                  uRate, resLate.delayMs, resEarly.delayMs, resInv.delayMs,
                  resInv.invertPolarity ? 1 : 0, rhoInPhase, rhoInv0);
    check(resLate.valid && std::fabs(resLate.delayMs - (-3.50f)) < 0.05f && !resLate.invertPolarity &&
              resLate.correlation > 0.99f &&
              resEarly.valid && std::fabs(resEarly.delayMs - 1.73f) < 0.05f && !resEarly.invertPolarity &&
              resEarly.correlation > 0.99f &&
              resInv.valid && std::fabs(resInv.delayMs - (-2.20f)) < 0.05f && resInv.invertPolarity &&
              resInv.correlation < -0.98f &&
              rhoInPhase > 0.99f && rhoInv0 < -0.99f && rhoAlignedLate > 0.98f,
          label);
  }
}

// ---------- Part 3: End-to-end LV2 Plugin verification ----------
class IdentityAmp final : public NeuralAudio::NeuralModel {
 public:
  float GetRecommendedInputDBAdjustment() override { return 0.0f; }
  float GetRecommendedOutputDBAdjustment() override { return 0.0f; }
  void Process(float* input, float* output, size_t count) override {
    if (input != output) std::memcpy(output, input, count * sizeof(float));
  }
};

constexpr uint32_t kBlock = 128;
constexpr size_t kAtomBytes = 4096;
using Controls = std::array<float, kRigControlPortCount>;

Controls defaultControls(double /*rate*/) {
  Controls c{};
  NAMRigWin32::forEachWin32ControlDefault([&](uint32_t port, float val) {
    if (port < c.size()) c[port] = val;
  });
  const auto pins = pinEqDefaults();
  std::copy(pins.begin(), pins.end(), c.begin() + kPinEqFirstPort);
  // Neutral/clean cab testing chain: disable gate, comp, OD, sculpt, power, tube, delay, reverb
  c[15] = -80.0f;  // gate off
  c[20] = 0.0f;    // pedal base mode
  c[21] = 0.0f;    // amp base mode
  c[24] = 1.0f;    // peak normalization
  c[25] = 0.0f;    // cab level 0 dB
  c[26] = 0.0f;    // cab low cut 0 Hz
  c[27] = 20000.0f;
  c[32] = 0.0f;    // stereo width 0%
  c[33] = 0.0f;    // room 0%
  c[48] = 0.0f;    // cab2 level 0 dB
  c[49] = 0.0f;    // cab2 align 0 ms
  c[54] = 0.0f;    // reverb mix 0%
  c[59] = 0.0f;    // cab2 polarity normal
  c[kCompressorEnabledPort] = 0.0f;
  c[kOverdriveEnabledPort] = 0.0f;
  c[kPostCompressorEnabledPort] = 0.0f;
  c[kRackControlFirstPort + static_cast<size_t>(Rack::Power)] = 0.0f;
  c[kRackControlFirstPort + static_cast<size_t>(Rack::Sculpt)] = 0.0f;
  c[kRackControlFirstPort + static_cast<size_t>(Rack::Transformer)] = 0.0f;
  c[kRackControlFirstPort + static_cast<size_t>(Rack::Speaker)] = 0.0f;
  c[kRackControlFirstPort + static_cast<size_t>(Rack::Delay)] = 0.0f;
  c[kRackControlFirstPort + static_cast<size_t>(Rack::Reverb)] = 0.0f;
  c[kRackControlFirstPort + static_cast<size_t>(Rack::PowerTube)] = 0.0f;
  c[kRackControlFirstPort + static_cast<size_t>(Rack::CabConsole)] = 1.0f;
  c[kRackControlFirstPort + static_cast<size_t>(Rack::Spatial)] = 1.0f;
  c[kSpatialCenterBlendPort] = 0.0f;
  c[7] = 0.0f;   // pedal off
  c[8] = 1.0f;   // amp on (IdentityAmp)
  c[9] = 1.0f;   // cab A on
  c[47] = 0.0f;  // cab B off
  return c;
}

struct RigHost {
  const LV2_Descriptor* descriptor = nullptr;
  const LV2_Worker_Interface* worker = nullptr;
  LV2_Handle instance = nullptr;
  std::vector<std::string> uris;
  std::deque<std::vector<uint8_t>> jobs;
  LV2_URID_Map map{this, mapUri};
  LV2_Worker_Schedule schedule{this, scheduleWork};
  LV2_Atom_Forge forge{};
  LV2_URID atomSequenceUrid = 0;
  LV2_URID patchSetUrid = 0;
  LV2_URID patchPropUrid = 0;
  LV2_URID patchValUrid = 0;
  LV2_URID cabPathUrid = 0;
  LV2_URID cab2PathUrid = 0;
  Controls controls{};
  std::array<float, kBlock> input{}, left{}, right{};
  alignas(LV2_Atom_Sequence) std::array<uint8_t, kAtomBytes> control{}, notify{};
  double rate = 48000.0;
  size_t samplePos = 0;

  static LV2_URID mapUri(LV2_URID_Map_Handle handle, const char* uri) {
    auto& ids = static_cast<RigHost*>(handle)->uris;
    const auto it = std::find(ids.begin(), ids.end(), uri);
    if (it != ids.end()) return static_cast<LV2_URID>(it - ids.begin() + 1);
    ids.emplace_back(uri);
    return static_cast<LV2_URID>(ids.size());
  }
  static LV2_Worker_Status scheduleWork(LV2_Worker_Schedule_Handle handle,
                                        uint32_t size, const void* data) {
    auto* h = static_cast<RigHost*>(handle);
    const auto* b = static_cast<const uint8_t*>(data);
    h->jobs.emplace_back(b, b + size);
    return LV2_WORKER_SUCCESS;
  }
  static LV2_Worker_Status respond(LV2_Worker_Respond_Handle handle,
                                   uint32_t size, const void* data) {
    auto* h = static_cast<RigHost*>(handle);
    return h->worker->work_response(h->instance, size, data);
  }

  RigHost(const LV2_Descriptor* d, double sampleRate, Controls init)
      : descriptor(d),
        worker(static_cast<const LV2_Worker_Interface*>(
            d->extension_data(LV2_WORKER__interface))),
        controls(init),
        rate(sampleRate) {
    lv2_atom_forge_init(&forge, &map);
    atomSequenceUrid = mapUri(this, LV2_ATOM__Sequence);
    patchSetUrid = mapUri(this, LV2_PATCH__Set);
    patchPropUrid = mapUri(this, LV2_PATCH__property);
    patchValUrid = mapUri(this, LV2_PATCH__value);
    cabPathUrid = mapUri(this, NAM_RIG_CAB_URI);
    cab2PathUrid = mapUri(this, NAM_RIG_CAB2_URI);

    LV2_Feature mapF{LV2_URID__map, &map};
    LV2_Feature schedF{LV2_WORKER__schedule, &schedule};
    const LV2_Feature* features[] = {&mapF, &schedF, nullptr};
    instance = d->instantiate(d, rate, "", features);
    require(instance && worker, "instantiate rig plugin");
    d->connect_port(instance, 0, control.data());
    d->connect_port(instance, 1, notify.data());
    d->connect_port(instance, 2, input.data());
    d->connect_port(instance, 3, left.data());
    d->connect_port(instance, 31, right.data());
    for (uint32_t p = 4; p < Plugin::kPortCount; ++p)
      if (p != 31) d->connect_port(instance, p, &controls[p]);
    clearControl();
    // Latch initial rates/rack controls, then install IdentityAmp.
    runSilence(1);
    LV2SwitchModelMsg amp{kWorkTypeSwitch, Stage::Amp, 0, 0, {}, new IdentityAmp,
                          nullptr, nullptr, false, 0.0f};
    worker->work_response(instance, sizeof(amp), &amp);
    drainJobs();
    runSilence(16);
  }

  ~RigHost() {
    if (instance) descriptor->cleanup(instance);
  }

  void clearControl() {
    auto* seq = reinterpret_cast<LV2_Atom_Sequence*>(control.data());
    seq->atom.type = atomSequenceUrid;
    seq->atom.size = sizeof(LV2_Atom_Sequence_Body);
    seq->body.unit = 0;
    seq->body.pad = 0;
  }

  void loadCabWav(Stage stage, const std::filesystem::path& wavPath) {
    const std::string s = wavPath.string();
    lv2_atom_forge_set_buffer(&forge, control.data(), control.size());
    LV2_Atom_Forge_Frame seqFrame{};
    lv2_atom_forge_sequence_head(&forge, &seqFrame, 0);
    LV2_Atom_Forge_Frame objFrame{};
    lv2_atom_forge_frame_time(&forge, 0);
    lv2_atom_forge_object(&forge, &objFrame, 0, patchSetUrid);
    lv2_atom_forge_key(&forge, patchPropUrid);
    lv2_atom_forge_urid(&forge, stage == Stage::Cab2 ? cab2PathUrid : cabPathUrid);
    lv2_atom_forge_key(&forge, patchValUrid);
    lv2_atom_forge_path(&forge, s.c_str(), static_cast<uint32_t>(s.size() + 1));
    lv2_atom_forge_pop(&forge, &objFrame);
    lv2_atom_forge_pop(&forge, &seqFrame);

    runSilence(1);
    clearControl();
    drainJobs();
    runSilence(32);  // complete fade-out / commit / fade-in
  }

  void drainJobs() {
    while (!jobs.empty()) {
      auto job = std::move(jobs.front());
      jobs.pop_front();
      worker->work(instance, respond, this, static_cast<uint32_t>(job.size()), job.data());
    }
    if (worker->end_run) worker->end_run(instance);
  }

  void runSilence(int blocks) {
    input.fill(0.0f);
    for (int b = 0; b < blocks; ++b) {
      auto* seq = reinterpret_cast<LV2_Atom_Sequence*>(notify.data());
      seq->atom.type = 0;
      seq->atom.size = sizeof(LV2_Atom_Sequence_Body);
      descriptor->run(instance, kBlock);
      drainJobs();
    }
  }

  template <typename Gen>
  void runSignal(int blocks, Gen&& gen, std::vector<float>* outL = nullptr,
                 std::vector<float>* outR = nullptr) {
    for (int b = 0; b < blocks; ++b) {
      for (uint32_t i = 0; i < kBlock; ++i) {
        input[i] = gen(samplePos++);
      }
      auto* seq = reinterpret_cast<LV2_Atom_Sequence*>(notify.data());
      seq->atom.type = 0;
      seq->atom.size = sizeof(LV2_Atom_Sequence_Body);
      descriptor->run(instance, kBlock);
      drainJobs();
      if (outL) outL->insert(outL->end(), left.begin(), left.end());
      if (outR) outR->insert(outR->end(), right.begin(), right.end());
    }
  }
};

void testPluginSpatialAndShelf(const char* soPath, const std::filesystem::path& tmpDir) {
  std::printf("-- Part 3: End-to-end LV2 Plugin spatial / center blend / shelf --\n");
  void* lib = dlopen(soPath, RTLD_NOW);
  require(lib != nullptr, "dlopen neural_amp_modeler_rig.so");
  auto fn = reinterpret_cast<LV2_Descriptor_Function>(dlsym(lib, "lv2_descriptor"));
  require(fn != nullptr, "dlsym lv2_descriptor");
  const LV2_Descriptor* desc = fn(0);
  require(desc != nullptr, "descriptor(0)");

  for (double rate : {48000.0, 96000.0}) {
    const uint32_t uRate = static_cast<uint32_t>(rate);

    // Build fixtures:
    // 1) Distinct true-stereo IR (L != R)
    const auto stereoL = makeDampedCabIR(rate, 0.10, 0.0, 1.0f, 0.7, 0.4, 0.25);
    const auto stereoR = makeDampedCabIR(rate, 0.10, 0.0011, 1.0f, 0.5, 0.7, 0.35);
    const auto stereoPath = tmpDir / ("stereo-" + std::to_string(uRate) + ".wav");
    writeFloatWav(stereoPath, uRate, stereoL, &stereoR);

    // 2) Dark cab A (strong 200 Hz, weak 3 kHz) & Bright cab B (weak 200 Hz, strong 3 kHz)
    auto makeToneCab = [&](double fStrong, double gStrong, double fWeak, double gWeak) {
      const size_t n = static_cast<size_t>(std::llround(rate * 0.12));
      std::vector<float> taps(n, 0.0f);
      for (size_t i = 0; i < n; ++i) {
        const double t = static_cast<double>(i) / rate;
        taps[i] = static_cast<float>(
            gStrong * std::exp(-50.0 * t) * std::cos(2.0 * kPi * fStrong * t) +
            gWeak * std::exp(-120.0 * t) * std::cos(2.0 * kPi * fWeak * t));
      }
      return taps;
    };
    const auto darkPath = tmpDir / ("dark-" + std::to_string(uRate) + ".wav");
    const auto brightPath = tmpDir / ("bright-" + std::to_string(uRate) + ".wav");
    writeFloatWav(darkPath, uRate, makeToneCab(200.0, 1.0, 3000.0, 0.04));
    writeFloatWav(brightPath, uRate, makeToneCab(3000.0, 1.0, 200.0, 0.04));

    // 3) Coherent cab A & polarity-inverted B for dualCabShelf test
    const auto cohA = makeDampedCabIR(rate, 0.12, 0.0, 1.0f, 0.9, 0.3, 0.2);
    const auto cohBInv = makeDampedCabIR(rate, 0.12, 0.0, -1.0f, 0.9, 0.3, 0.2);
    const auto cohAPath = tmpDir / ("coh-a-" + std::to_string(uRate) + ".wav");
    const auto cohBInvPath = tmpDir / ("coh-binv-" + std::to_string(uRate) + ".wav");
    writeFloatWav(cohAPath, uRate, cohA);
    writeFloatWav(cohBInvPath, uRate, cohBInv);

    // --- 3A. Single Stereo IR M/S width (Solo Cab A and Solo Cab B) ---
    for (bool soloB : {false, true}) {
      auto runSingleStereo = [&](float spatialOn, float widthPct,
                                 std::vector<float>& L, std::vector<float>& R) {
        Controls c = defaultControls(rate);
        c[kRackControlFirstPort + static_cast<size_t>(Rack::Spatial)] = spatialOn;
        c[32] = widthPct;
        c[9] = soloB ? 0.0f : 1.0f;
        c[47] = soloB ? 1.0f : 0.0f;
        RigHost host(desc, rate, c);
        host.loadCabWav(soloB ? Stage::Cab2 : Stage::Cab, stereoPath);
        host.runSignal(96, [&](size_t n) {
          const double t = static_cast<double>(n) / rate;
          return static_cast<float>(0.35 * std::sin(2.0 * kPi * 330.0 * t) +
                                    0.25 * std::sin(2.0 * kPi * 1450.0 * t));
        }, &L, &R);
      };
      std::vector<float> offL, offR, l0, r0, l50, r50, l100, r100;
      runSingleStereo(0.0f, 100.0f, offL, offR);
      runSingleStereo(1.0f, 0.0f, l0, r0);
      runSingleStereo(1.0f, 50.0f, l50, r50);
      runSingleStereo(1.0f, 100.0f, l100, r100);

      const size_t start = offL.size() / 2;
      double maxOffVs0 = 0.0, maxMonoErr50 = 0.0, maxMonoErr100 = 0.0;
      double side0Sq = 0.0, side50Sq = 0.0, side100Sq = 0.0;
      for (size_t i = start; i < offL.size(); ++i) {
        maxOffVs0 = std::max(maxOffVs0, static_cast<double>(
            std::max(std::fabs(offL[i] - l0[i]), std::fabs(offR[i] - r0[i]))));
        const double m0 = 0.5 * (l0[i] + r0[i]);
        const double m50 = 0.5 * (l50[i] + r50[i]);
        const double m100 = 0.5 * (l100[i] + r100[i]);
        maxMonoErr50 = std::max(maxMonoErr50, std::fabs(m50 - m0));
        maxMonoErr100 = std::max(maxMonoErr100, std::fabs(m100 - m0));
        const double s0 = 0.5 * (l0[i] - r0[i]);
        const double s50 = 0.5 * (l50[i] - r50[i]);
        const double s100 = 0.5 * (l100[i] - r100[i]);
        side0Sq += s0 * s0;
        side50Sq += s50 * s50;
        side100Sq += s100 * s100;
      }
      const double ratio50 = std::sqrt(side50Sq / std::max(1.0e-18, side0Sq));
      const double ratio100 = std::sqrt(side100Sq / std::max(1.0e-18, side0Sq));
      char label[256];
      std::snprintf(label, sizeof(label),
                    "Single stereo IR %s @ %u Hz: w=0 matches OFF (err %.1e), mono err %.1e, Side x%.3f/x%.3f",
                    soloB ? "Solo B" : "Solo A", uRate, maxOffVs0, maxMonoErr100, ratio50, ratio100);
      check(maxOffVs0 < 1.0e-6 && maxMonoErr50 < 1.0e-5 && maxMonoErr100 < 1.0e-5 &&
                std::fabs(ratio50 - 1.40) < 0.02 && std::fabs(ratio100 - 1.80) < 0.02,
            label);
    }

    // --- 3B. Dual-Cab Center Blend vs Classic A/B Split ---
    {
      const int totalBlocks = static_cast<int>(std::llround(rate * 0.45 / kBlock));
      const size_t start = static_cast<size_t>(std::llround(rate * 0.25));
      const size_t len = static_cast<size_t>(std::llround(rate * 0.15));  // exact integer cycles of 200 & 3000 Hz
      auto runDual = [&](float centerBlend, float widthPct, double f1, double f2,
                         std::vector<float>& L, std::vector<float>& R) {
        Controls c = defaultControls(rate);
        c[9] = 1.0f;
        c[47] = 1.0f;
        c[32] = widthPct;
        c[kSpatialCenterBlendPort] = centerBlend;
        RigHost host(desc, rate, c);
        host.loadCabWav(Stage::Cab, darkPath);
        host.loadCabWav(Stage::Cab2, brightPath);
        host.runSignal(totalBlocks, [&](size_t n) {
          const double t = static_cast<double>(n) / rate;
          return static_cast<float>(0.3 * std::sin(2.0 * kPi * f1 * t) +
                                    0.3 * std::sin(2.0 * kPi * f2 * t));
        }, &L, &R);
      };
      std::vector<float> splitL, splitR, ctrL, ctrR, ctr0L, ctr0R;
      runDual(0.0f, 100.0f, 200.0, 3000.0, splitL, splitR);
      runDual(1.0f, 100.0f, 200.0, 3000.0, ctrL, ctrR);
      runDual(1.0f, 0.0f, 200.0, 3000.0, ctr0L, ctr0R);

      const auto spL200 = measureTone(splitL, start, len, 200.0, rate);
      const auto spR200 = measureTone(splitR, start, len, 200.0, rate);
      const auto spL3k = measureTone(splitL, start, len, 3000.0, rate);
      const auto spR3k = measureTone(splitR, start, len, 3000.0, rate);

      const auto cL200 = measureTone(ctrL, start, len, 200.0, rate);
      const auto cR200 = measureTone(ctrR, start, len, 200.0, rate);
      const auto cL3k = measureTone(ctrL, start, len, 3000.0, rate);
      const auto cR3k = measureTone(ctrR, start, len, 3000.0, rate);

      const double splitLowDiffDb = 20.0 * std::log10(spL200.mag / std::max(1.0e-12, spR200.mag));
      const double splitHighDiffDb = 20.0 * std::log10(spR3k.mag / std::max(1.0e-12, spL3k.mag));
      const double ctrLowDiffDb = std::fabs(20.0 * std::log10(cL200.mag / std::max(1.0e-12, cR200.mag)));
      const double ctrHighDiffDb = std::fabs(20.0 * std::log10(cL3k.mag / std::max(1.0e-12, cR3k.mag)));

      std::vector<float> ctrM(len), ctrS(len), ctr0M(len);
      for (size_t i = 0; i < len; ++i) {
        ctrM[i] = 0.5f * (ctrL[start + i] + ctrR[start + i]);
        ctrS[i] = 0.5f * (ctrL[start + i] - ctrR[start + i]);
        ctr0M[i] = 0.5f * (ctr0L[start + i] + ctr0R[start + i]);
      }
      const auto c0M200 = measureTone(ctr0M, 0, len, 200.0, rate);
      const auto cM200 = measureTone(ctrM, 0, len, 200.0, rate);
      const auto c0M3k = measureTone(ctr0M, 0, len, 3000.0, rate);
      const auto cM3k = measureTone(ctrM, 0, len, 3000.0, rate);
      const auto cS3k = measureTone(ctrS, 0, len, 3000.0, rate);

      // With Width=100%, Dome norm = 1/sqrt(1+kMaxSpread^2) multiplies Mono sum uniformly.
      constexpr double kMaxSpread = static_cast<double>(DomeHilbertStereoizer::kMaxSpread);
      const double expectedNorm = 1.0 / std::sqrt(1.0 + kMaxSpread * kMaxSpread);
      const double monoRatioDiffDb = std::fabs(
          20.0 * std::log10(cM200.mag / std::max(1.0e-12, c0M200.mag * expectedNorm)) -
          20.0 * std::log10(cM3k.mag / std::max(1.0e-12, c0M3k.mag * expectedNorm)));

      char label[256];
      std::snprintf(label, sizeof(label),
                    "Dual-cab Center Blend @ %u Hz: split %.1f/%.1f dB vs center %.2f/%.2f dB, comb-free %.3f dB",
                    uRate, splitLowDiffDb, splitHighDiffDb, ctrLowDiffDb, ctrHighDiffDb, monoRatioDiffDb);
      check(splitLowDiffDb > 12.0 && splitHighDiffDb > 12.0 &&
                ctrLowDiffDb < 0.20 && ctrHighDiffDb < 0.20 &&
                cS3k.mag > 0.25 * cL3k.mag && monoRatioDiffDb < 0.05,
            label);
    }

    // --- 3C. Content-/delay-/polarity-aware dualCabShelf ---
    {
      const int totalBlocks = static_cast<int>(std::llround(rate * 0.45 / kBlock));
      const size_t start = static_cast<size_t>(std::llround(rate * 0.25));
      const size_t len = static_cast<size_t>(std::llround(rate * 0.15));  // integer cycles of 100 & 2000 Hz
      auto measureLowVsHighDb = [&](bool useInvertedB, float cab2Pol, float cab2DelayMs,
                                    float widthPct, float spatialOn) {
        Controls c = defaultControls(rate);
        c[9] = 1.0f;
        c[47] = 1.0f;
        c[32] = widthPct;
        c[49] = cab2DelayMs;
        c[59] = cab2Pol;
        c[kRackControlFirstPort + static_cast<size_t>(Rack::Spatial)] = spatialOn;
        RigHost host(desc, rate, c);
        host.loadCabWav(Stage::Cab, cohAPath);
        host.loadCabWav(Stage::Cab2, useInvertedB ? cohBInvPath : cohAPath);
        std::vector<float> L, R;
        host.runSignal(totalBlocks, [&](size_t n) {
          const double t = static_cast<double>(n) / rate;
          return static_cast<float>(0.3 * std::sin(2.0 * kPi * 100.0 * t) +
                                    0.3 * std::sin(2.0 * kPi * 2000.0 * t));
        }, &L, &R);
        const auto mLow = measureTone(L, start, len, 100.0, rate);
        const auto mHigh = measureTone(L, start, len, 2000.0, rate);
        return 20.0 * std::log10(mLow.mag / std::max(1.0e-12, mHigh.mag));
      };

      // Solo A baseline (no dual-cab shelf)
      double soloBaselineDb = 0.0;
      {
        Controls c = defaultControls(rate);
        c[9] = 1.0f;
        c[47] = 0.0f;
        RigHost host(desc, rate, c);
        host.loadCabWav(Stage::Cab, cohAPath);
        std::vector<float> L, R;
        host.runSignal(totalBlocks, [&](size_t n) {
          const double t = static_cast<double>(n) / rate;
          return static_cast<float>(0.3 * std::sin(2.0 * kPi * 100.0 * t) +
                                    0.3 * std::sin(2.0 * kPi * 2000.0 * t));
        }, &L, &R);
        soloBaselineDb = 20.0 * std::log10(
            measureTone(L, start, len, 100.0, rate).mag /
            std::max(1.0e-12, measureTone(L, start, len, 2000.0, rate).mag));
      }

      const double sameDelay0 = measureLowVsHighDb(false, 0.0f, 0.0f, 0.0f, 0.0f) - soloBaselineDb;
      // Same IR with cab2_delay = +10.0 ms gives an integer cycle shift at both
      // 100 Hz (1 cycle) and 2000 Hz (20 cycles), so only lowBandCoherence changes:
      // coherence drops from +1.00 (-2.83 dB shelf at 100 Hz) to ~+0.36 (~-1.38 dB).
      const double sameDelay10ms = measureLowVsHighDb(false, 0.0f, 10.0f, 0.0f, 0.0f) - soloBaselineDb;
      // At Width=50% (u=0.924, v=0.383), baked-in inverted B has L = 0.924*A - 0.383*A (flat across freq)
      // so raw ratio without shelf == soloBaselineDb. With B POL INV=1 -> L = 0.924*A + 0.383*A and
      // rhoPos becomes +1, engaging ~ -2.2 dB shelf on 100 Hz relative to 2 kHz.
      const double bakedInvOff = measureLowVsHighDb(true, 0.0f, 0.0f, 50.0f, 1.0f) - soloBaselineDb;
      const double bakedInvPolOn = measureLowVsHighDb(true, 1.0f, 0.0f, 50.0f, 1.0f) - soloBaselineDb;
      char label[256];
      std::snprintf(label, sizeof(label),
                    "dualCabShelf @ %u Hz: 0ms=%.2f dB, 10ms=%.2f dB, baked-inv Pol=OFF %.2f dB vs Pol=ON %.2f dB",
                    uRate, sameDelay0, sameDelay10ms, bakedInvOff, bakedInvPolOn);
      check(sameDelay0 < -2.6 && sameDelay0 > -3.1 &&
                sameDelay10ms > sameDelay0 + 1.2 && sameDelay10ms < -1.1 &&
                std::fabs(bakedInvOff) < 0.15 &&
                bakedInvPolOn < -1.9 && bakedInvPolOn > -2.5,
            label);
    }

    // --- 3D. Simultaneous Spatial rack + Center Blend commit, dry FX tails, and NaN width ---
    {
      // (a) Simultaneous Rack::Spatial ON + centerBlend ON must both commit in
      //     one transition fade so dark/bright IRs are already balanced on L/R.
      Controls c = defaultControls(rate);
      c[9] = 1.0f;
      c[47] = 1.0f;
      c[32] = 100.0f;
      c[kRackControlFirstPort + static_cast<size_t>(Rack::Spatial)] = 0.0f;
      c[kSpatialCenterBlendPort] = 0.0f;
      RigHost host(desc, rate, c);
      host.loadCabWav(Stage::Cab, darkPath);
      host.loadCabWav(Stage::Cab2, brightPath);
      host.runSilence(16);

      // Flip both controls simultaneously and settle for 40 ms (> 10 ms single fade).
      host.controls[kRackControlFirstPort + static_cast<size_t>(Rack::Spatial)] = 1.0f;
      host.controls[kSpatialCenterBlendPort] = 1.0f;
      const int settleBlocks = static_cast<int>(std::llround(rate * 0.040 / kBlock));
      host.runSignal(settleBlocks, [&](size_t n) {
        const double t = static_cast<double>(n) / rate;
        return static_cast<float>(0.3 * std::sin(2.0 * kPi * 200.0 * t) +
                                  0.3 * std::sin(2.0 * kPi * 3000.0 * t));
      });
      const int measBlocks = static_cast<int>(std::llround(rate * 0.100 / kBlock));
      std::vector<float> measL, measR;
      host.runSignal(measBlocks, [&](size_t n) {
        const double t = static_cast<double>(n) / rate;
        return static_cast<float>(0.3 * std::sin(2.0 * kPi * 200.0 * t) +
                                  0.3 * std::sin(2.0 * kPi * 3000.0 * t));
      }, &measL, &measR);
      const size_t measStart = static_cast<size_t>(std::llround(rate * 0.020));
      const size_t measLen = static_cast<size_t>(std::llround(rate * 0.060));
      const double diff200 = std::fabs(20.0 * std::log10(
          measureTone(measL, measStart, measLen, 200.0, rate).mag /
          std::max(1.0e-12, measureTone(measR, measStart, measLen, 200.0, rate).mag)));
      const double diff3k = std::fabs(20.0 * std::log10(
          measureTone(measL, measStart, measLen, 3000.0, rate).mag /
          std::max(1.0e-12, measureTone(measR, measStart, measLen, 3000.0, rate).mag)));

      // (b) Toggling Center Blend must not duck an active Delay wet tail
      //     (its min block peak during the 25 ms fade must match an unchanged run).
      auto measureDelayTailMinPeak = [&](bool toggleCenterBlend) {
        Controls dlyCtrl = defaultControls(rate);
        dlyCtrl[9] = 1.0f;
        dlyCtrl[47] = 1.0f;
        dlyCtrl[32] = 100.0f;
        dlyCtrl[50] = 200.0f;  // delay_time ms
        dlyCtrl[51] = 85.0f;   // delay_feedback %
        dlyCtrl[53] = 100.0f;  // delay_mix %
        dlyCtrl[kRackControlFirstPort + static_cast<size_t>(Rack::Delay)] = 1.0f;
        dlyCtrl[kSpatialCenterBlendPort] = 0.0f;
        RigHost tailHost(desc, rate, dlyCtrl);
        tailHost.loadCabWav(Stage::Cab, cohAPath);
        tailHost.loadCabWav(Stage::Cab2, cohAPath);
        const int warmBlocks = static_cast<int>(std::llround(rate * 0.10 / kBlock));
        tailHost.runSignal(warmBlocks, [&](size_t n) {
          return static_cast<float>(0.4 * std::sin(2.0 * kPi * 440.0 * static_cast<double>(n) / rate));
        });
        // Wait 140 ms (> 120 ms cab IR tail) so post-cab dry signal is zero while the 200 ms echo rings.
        tailHost.runSilence(static_cast<int>(std::llround(rate * 0.14 / kBlock)));
        if (toggleCenterBlend) tailHost.controls[kSpatialCenterBlendPort] = 1.0f;
        const int tailBlocks = static_cast<int>(std::llround(rate * 0.025 / kBlock));
        std::vector<float> tailL, tailR;
        tailHost.runSignal(tailBlocks, [](size_t) { return 0.0f; }, &tailL, &tailR);
        double minPeak = 1.0;
        for (int b = 0; b < tailBlocks; ++b) {
          double bp = 0.0;
          for (size_t i = 0; i < kBlock; ++i) {
            bp = std::max(bp, static_cast<double>(std::max(
                std::fabs(tailL[b * kBlock + i]), std::fabs(tailR[b * kBlock + i]))));
          }
          minPeak = std::min(minPeak, bp);
        }
        return minPeak;
      };
      const double tailBase = measureDelayTailMinPeak(false);
      const double tailToggle = measureDelayTailMinPeak(true);
      const double tailRatio = tailToggle / std::max(1.0e-12, tailBase);

      // (c) NaN stereo_width must fall back safely to 0% (not 100% via std::min(1, NaN)).
      auto runStereoWidth = [&](float w) {
        Controls c = defaultControls(rate);
        c[9] = 1.0f;
        c[47] = 0.0f;
        c[32] = w;
        RigHost h(desc, rate, c);
        h.loadCabWav(Stage::Cab, stereoPath);
        std::vector<float> oL, oR;
        h.runSignal(static_cast<int>(std::llround(rate * 0.15 / kBlock)), [&](size_t n) {
          return static_cast<float>(0.4 * std::sin(2.0 * kPi * 500.0 * static_cast<double>(n) / rate));
        }, &oL, &oR);
        return std::make_pair(oL, oR);
      };
      const auto [zeroL, zeroR] = runStereoWidth(0.0f);
      const auto [nanL, nanR] = runStereoWidth(std::numeric_limits<float>::quiet_NaN());
      double maxNanErr = 0.0;
      bool allFinite = true;
      for (size_t i = nanL.size() / 2; i < nanL.size(); ++i) {
        if (!std::isfinite(nanL[i]) || !std::isfinite(nanR[i])) allFinite = false;
        maxNanErr = std::max(maxNanErr, static_cast<double>(
            std::max(std::fabs(nanL[i] - zeroL[i]), std::fabs(nanR[i] - zeroR[i]))));
      }

      char label[256];
      std::snprintf(label, sizeof(label),
                    "Transitions & guards @ %u Hz: sync=%.2f/%.2f dB, tailRatio=%.3f, NaN width finite=%d vs0=%.2e",
                    uRate, diff200, diff3k, tailRatio, allFinite ? 1 : 0, maxNanErr);
      check(diff200 < 0.25 && diff3k < 0.25 && tailRatio > 0.85 && allFinite && maxNanErr < 1.0e-6,
            label);
    }
  }

  dlclose(lib);
}

}  // namespace

int main(int argc, char** argv) {
  std::string pattern = (std::filesystem::temp_directory_path() / "spatial-stereo-XXXXXX").string();
  require(mkdtemp(pattern.data()) != nullptr, "create temp directory");
  const std::filesystem::path tmpDir(pattern);

  testSpatialStereoUnits();
  testWavIrCoherenceAndAlignment(tmpDir);
  if (argc > 1 && argv[1] && argv[1][0]) {
    testPluginSpatialAndShelf(argv[1], tmpDir);
  } else {
    std::printf("  (skipped Part 3 LV2 plugin integration: pass path to neural_amp_modeler_rig.so)\n");
  }

  std::error_code ec;
  std::filesystem::remove_all(tmpDir, ec);
  std::printf("\n%d failures\n", failures);
  return failures ? 1 : 0;
}
