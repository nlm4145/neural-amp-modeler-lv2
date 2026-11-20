// Comprehensive verification harness for Tier 1 & Tier 2 Amplifier Engine
// enhancements and bit-exact baseline preservation when EngineMode::kNone.
#include "amp_engine_mode.h"
#include "amp_advanced.h"
#include "dynamics.h"
#include "model_band_limit.h"
#include "nam_rig_plugin.h"
#include "output_transformer.h"
#include "overdrive.h"
#include "rack_controls.h"
#include "speaker_dynamics.h"

#include <lv2/atom/forge.h>
#include <lv2/atom/util.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <string>
#include <unistd.h>
#include <unordered_map>
#include <vector>

namespace {

using namespace NAMRig;
constexpr double kPi = 3.14159265358979323846;
int failures = 0;

void check(bool cond, const char* label, double observed = 0.0, bool showObs = false) {
  if (showObs) {
    std::printf("  %s  %s (observed %.5f)\n", cond ? "PASS" : "FAIL", label, observed);
  } else {
    std::printf("  %s  %s\n", cond ? "PASS" : "FAIL", label);
  }
  if (!cond) ++failures;
}

double dftMag(const std::vector<float>& x, size_t start, size_t len, double freq, double rate) {
  double re = 0.0, im = 0.0;
  for (size_t i = 0; i < len; ++i) {
    const double w = 0.5 * (1.0 - std::cos(2.0 * kPi * static_cast<double>(i) / static_cast<double>(len)));
    const double ph = 2.0 * kPi * freq * static_cast<double>(i) / rate;
    const double s = static_cast<double>(x[start + i]) * w;
    re += s * std::cos(ph);
    im -= s * std::sin(ph);
  }
  return 4.0 * std::hypot(re, im) / static_cast<double>(len);
}

double rmsSlice(const std::vector<float>& x, size_t start, size_t len) {
  double acc = 0.0;
  for (size_t i = 0; i < len; ++i) acc += static_cast<double>(x[start + i]) * x[start + i];
  return std::sqrt(acc / static_cast<double>(std::max<size_t>(1, len)));
}

double meanSlice(const std::vector<float>& x, size_t start, size_t len) {
  double acc = 0.0;
  for (size_t i = 0; i < len; ++i) acc += static_cast<double>(x[start + i]);
  return acc / static_cast<double>(std::max<size_t>(1, len));
}

double toDb(double v) {
  return 20.0 * std::log10(std::max(1.0e-12, v));
}

// ---- Minimal synchronous LV2 harness for Plugin end-to-end tests ----
struct MiniHost {
  Plugin plugin;
  double rate = 48000.0;
  std::array<float, Plugin::kPortCount> ctrl{};
  std::vector<float> inBuf, outL, outR;
  std::array<uint8_t, 16384> ctrlAtom{}, notifyAtom{};
  std::unordered_map<std::string, LV2_URID> urids;
  LV2_URID nextUrid = 1;
  LV2_URID_Map mapFeature{};
  LV2_Worker_Schedule schedFeature{};
  LV2_Log_Log logFeature{};
  std::deque<std::vector<uint8_t>> workResponses;
  LV2_Atom_Forge forge{};

  static LV2_URID mapFn(LV2_URID_Map_Handle h, const char* uri) {
    auto* self = static_cast<MiniHost*>(h);
    auto it = self->urids.find(uri);
    if (it != self->urids.end()) return it->second;
    LV2_URID id = self->nextUrid++;
    self->urids.emplace(uri, id);
    return id;
  }

  static LV2_Worker_Status respondFn(LV2_Worker_Respond_Handle h, uint32_t size, const void* data) {
    auto* self = static_cast<MiniHost*>(h);
    const auto* b = static_cast<const uint8_t*>(data);
    self->workResponses.emplace_back(b, b + size);
    return LV2_WORKER_SUCCESS;
  }

  static LV2_Worker_Status scheduleFn(LV2_Worker_Schedule_Handle h, uint32_t size, const void* data) {
    auto* self = static_cast<MiniHost*>(h);
    return Plugin::work(&self->plugin, respondFn, self, size, data);
  }

  static int logPrintf(LV2_Log_Handle, LV2_URID, const char*, ...) { return 0; }
  static int logVprintf(LV2_Log_Handle, LV2_URID, const char*, va_list) { return 0; }

  void init(double sampleRate, uint32_t maxBlock = 256) {
    rate = sampleRate;
    ctrl.fill(0.0f);
    ctrl[6] = 1.0f;  // quality_scale
    ctrl[7] = 1.0f;  // pedal_enabled
    ctrl[8] = 1.0f;  // amp_enabled
    ctrl[9] = 1.0f;  // cab_enabled
    ctrl[15] = -80.0f; // gate off
    ctrl[20] = 6.0f; // pedal oversample True 8x
    ctrl[21] = 6.0f; // amp oversample True 8x
    ctrl[23] = 150.0f;
    ctrl[24] = 2.0f;
    ctrl[27] = 20000.0f;
    ctrl[43] = ctrl[44] = 25.0f;
    ctrl[45] = ctrl[46] = 50.0f;
    std::copy(kTransformerControlDefaults.begin(), kTransformerControlDefaults.end(),
              ctrl.begin() + kTransformerControlFirstPort);
    std::copy(kRackControlDefaults.begin(), kRackControlDefaults.end(),
              ctrl.begin() + kRackControlFirstPort);
    ctrl[kPowerTubeCharacterPort] = kPowerTubeCharacterDefault;
    const auto pins = pinEqDefaults();
    std::copy(pins.begin(), pins.end(), ctrl.begin() + kPinEqFirstPort);
    ctrl[kOverdriveTonePort] = Overdrive::kToneDefault;
    ctrl[kOverdriveTightPort] = kOverdriveTightDefault;
    ctrl[kCompressorAttackPort] = kCompressorAttackDefault;
    ctrl[kCompressorReleasePort] = kCompressorReleaseDefault;
    ctrl[kCompressorEnabledPort] = 1.0f;
    ctrl[kOverdriveEnabledPort] = 0.0f;
    std::copy(kPostCompressorDefaults.begin(), kPostCompressorDefaults.end(),
              ctrl.begin() + kPostCompressorFirstPort);
    const auto tones = toneEqDefaults();
    std::copy(tones.begin(), tones.end(), ctrl.begin() + kToneEqModePort);
    ctrl[kModelBandLimitCutoffPort] = kModelBandLimitCutoffDefault;
    ctrl[kModelBandLimitSlopePort] = kModelBandLimitSlopeDefault;
    ctrl[kModelBandLimitRipplePort] = kModelBandLimitRippleDefault;
    ctrl[kSpeakerProfileBPort] = kSpeakerProfileBDefault;

    mapFeature = {this, mapFn};
    schedFeature = {this, scheduleFn};
    logFeature = {this, logPrintf, logVprintf};
    LV2_Feature fMap{LV2_URID__map, &mapFeature};
    LV2_Feature fSched{LV2_WORKER__schedule, &schedFeature};
    LV2_Feature fLog{LV2_LOG__log, &logFeature};
    const LV2_Feature* feats[] = {&fMap, &fSched, &fLog, nullptr};
    check(plugin.initialize(rate, feats), "MiniHost plugin.initialize");
    plugin.setMaxBufferSize(static_cast<int>(maxBlock));
    lv2_atom_forge_init(&forge, &mapFeature);

    inBuf.assign(maxBlock, 0.0f);
    outL.assign(maxBlock, 0.0f);
    outR.assign(maxBlock, 0.0f);
    auto** ptrs = reinterpret_cast<void**>(&plugin.ports);
    for (uint32_t i = 0; i < Plugin::kPortCount; ++i) ptrs[i] = &ctrl[i];
    plugin.ports.control = reinterpret_cast<const LV2_Atom_Sequence*>(ctrlAtom.data());
    plugin.ports.notify = reinterpret_cast<LV2_Atom_Sequence*>(notifyAtom.data());
    plugin.ports.audio_in = inBuf.data();
    plugin.ports.audio_out = outL.data();
    plugin.ports.audio_out_r = outR.data();
    clearControlAtom();
  }

  void clearControlAtom() {
    auto* seq = reinterpret_cast<LV2_Atom_Sequence*>(ctrlAtom.data());
    seq->atom.type = mapFn(this, LV2_ATOM__Sequence);
    seq->atom.size = sizeof(LV2_Atom_Sequence_Body);
    seq->body.unit = 0;
    seq->body.pad = 0;
  }

  void prepNotifyAtom() {
    auto* seq = reinterpret_cast<LV2_Atom_Sequence*>(notifyAtom.data());
    seq->atom.type = mapFn(this, LV2_ATOM__Sequence);
    seq->atom.size = static_cast<uint32_t>(notifyAtom.size() - sizeof(LV2_Atom));
  }

  void sendPath(const char* propUri, const std::string& path) {
    lv2_atom_forge_set_buffer(&forge, ctrlAtom.data(), ctrlAtom.size());
    LV2_Atom_Forge_Frame seqFrame{}, objFrame{};
    lv2_atom_forge_sequence_head(&forge, &seqFrame, 0);
    lv2_atom_forge_frame_time(&forge, 0);
    lv2_atom_forge_object(&forge, &objFrame, 0, mapFn(this, LV2_PATCH__Set));
    lv2_atom_forge_key(&forge, mapFn(this, LV2_PATCH__property));
    lv2_atom_forge_urid(&forge, mapFn(this, propUri));
    lv2_atom_forge_key(&forge, mapFn(this, LV2_PATCH__value));
    lv2_atom_forge_path(&forge, path.c_str(), static_cast<uint32_t>(path.size() + 1));
    lv2_atom_forge_pop(&forge, &objFrame);
    lv2_atom_forge_pop(&forge, &seqFrame);
    runBlock(nullptr, 128);
    clearControlAtom();
    drainWorkAndSettle();
  }

  void drainWorkAndSettle() {
    for (int iter = 0; iter < 40; ++iter) {
      while (!workResponses.empty()) {
        auto msg = std::move(workResponses.front());
        workResponses.pop_front();
        Plugin::workResponse(&plugin, static_cast<uint32_t>(msg.size()), msg.data());
      }
      runBlock(nullptr, 128);
      if (workResponses.empty() && plugin.currentTransitionPhase() == Plugin::TransitionPhase::Steady)
        break;
    }
  }

  void runBlock(const float* in, uint32_t count) {
    if (in) std::memcpy(inBuf.data(), in, count * sizeof(float));
    else std::fill(inBuf.begin(), inBuf.begin() + count, 0.0f);
    prepNotifyAtom();
    plugin.process(count);
    while (!workResponses.empty()) {
      auto msg = std::move(workResponses.front());
      workResponses.pop_front();
      Plugin::workResponse(&plugin, static_cast<uint32_t>(msg.size()), msg.data());
    }
  }
};

struct TempDir {
  std::filesystem::path dir;
  TempDir() {
    std::string tmpl = (std::filesystem::temp_directory_path() / "verify_amp_eval-XXXXXX").string();
    std::vector<char> buf(tmpl.begin(), tmpl.end());
    buf.push_back('\0');
    const char* created = mkdtemp(buf.data());
    if (!created) std::abort();
    dir = created;
  }
  ~TempDir() {
    std::error_code ec;
    std::filesystem::remove_all(dir, ec);
  }
  std::string writeFile(const std::string& name, const std::string& contents) const {
    std::string p = (dir / name).string();
    std::ofstream f(p);
    f << contents;
    f.close();
    return p;
  }
};

// ---- Test 1: Bit-exact baseline preservation when EngineMode::kNone ----
void testBitExactBaseline() {
  std::printf("== 1. Bit-Exact Baseline Preservation (kNone) ==\n");
  EngineMode::setFlags(EngineMode::kNone);
  std::vector<float> sig(4096);
  for (size_t i = 0; i < sig.size(); ++i)
    sig[i] = 0.25f * std::sin(2.0f * static_cast<float>(kPi) * 220.0f * i / 48000.0f) +
             0.12f * std::sin(2.0f * static_cast<float>(kPi) * 1450.0f * i / 48000.0f);

  auto runAllDsp = [&](std::vector<float> buf) {
    NoiseGate g; g.configure(48000.0, -45.0f, 100.0f);
    for (float& s : buf) s = g.process(s);
    CompressorCore c; c.prepare(48000.0);
    for (float& s : buf) s *= c.processSigned(s, -24.0f, 3.5f, 3.0f, 0.002f, 0.0002f);
    Overdrive od; od.process(buf.data(), buf.size(), 48000.0, 60.0f, 55.0f, 3.0f, 720.0f, 1.0f, true);
    AmpAdvanced amp;
    amp.processPreAmp(buf.data(), buf.size(), 48000.0, 50.0f, 40.0f, 30.0f, 6.0f);
    amp.processPostAmp(buf.data(), buf.size(), 48000.0, 2.0f, 1.0f, 50.0f, 20.0f, 50.0f, 40.0f,
                       PowerTube::kEL34, 60.0f);
    OutputTransformer ot;
    ot.process(buf.data(), buf.size(), 48000.0, OutputTransformer::kTweedBloom);
    SpeakerDynamics spk;
    spk.process(buf.data(), buf.size(), 48000.0, SpeakerDynamics::kModern412,
                40.0f, 50.0f, 60.0f, 70.0f, 0.4f);
    return buf;
  };

  auto base1 = runAllDsp(sig);
  EngineMode::setFlags(EngineMode::kAllTier1And2);
  auto enhanced = runAllDsp(sig);
  EngineMode::setFlags(EngineMode::kNone);
  auto base2 = runAllDsp(sig);

  double maxDiffBase = 0.0, maxDiffEnh = 0.0;
  for (size_t i = 0; i < sig.size(); ++i) {
    maxDiffBase = std::max<double>(maxDiffBase, std::fabs(base1[i] - base2[i]));
    maxDiffEnh = std::max<double>(maxDiffEnh, std::fabs(base1[i] - enhanced[i]));
  }
  check(maxDiffBase == 0.0, "kNone -> kAllTier1And2 -> kNone returns bit-exact baseline", maxDiffBase, true);
  check(maxDiffEnh > 0.01, "kAllTier1And2 produces measurably different audio from baseline", maxDiffEnh, true);
}

// ---- Test 2: T1.1 44.1 kHz WaveNet Rational Resampling ----
void testT11ModelRateResampling(const TempDir& tmp) {
  std::printf("== 2. T1.1: 44.1 kHz Rational Model Resampling ==\n");
  // WaveNet layer: input_size=1, channels=1, kernel_size=2, dilations=[44], Hardtanh.
  // Weights layout in NeuralAudio WaveNet:
  //   input_mixin(1), conv(kernel=2 -> [w_t-44, w_t] + bias), 1x1(1+bias), head_rechannel(1), head_scale.
  // Let's craft a clean 2-tap FIR comb filter y[n] = 0.5*x[n] + 0.5*x[n - 44] at 44100 Hz:
  //   Notch at f = 44100 / (2 * 44) = 501.14 Hz, pass peak at f = 44100 / 44 = 1002.27 Hz!
  // Layer weights order in NAM WaveNet (no gated, head_bias=false):
  //   rechannel (1x1 no bias): 1.0
  //   conv (out=1, in=1, k=2, bias=true): [w_oldest=0.5, w_newest=0.5, bias=0.0]
  //   input_mixin (out=1, cond=1, bias=false): 0.0
  //   1x1 (out=1, in=1, bias=true): [0.0, 0.0]
  //   head_rechannel (out=1, in=1, bias=false): 1.0
  //   head_scale: 1.0
  const std::string comb44k = tmp.writeFile("comb_44100.nam",
      R"({"version":"0.5.4","architecture":"WaveNet","config":{"layers":[{"input_size":1,"condition_size":1,"head_size":1,"channels":1,"kernel_size":2,"dilations":[44],"activation":"Hardtanh","gated":false,"head_bias":false}],"head":null,"head_scale":1.0},"weights":[1.0,0.5,0.5,0.0,0.0,0.0,0.0,1.0,1.0],"sample_rate":44100,"metadata":{"loudness":-18.0,"input_level_dbu":12.0}})");

  auto measureNotchDb = [&](uint32_t flags, float& outLatency) {
    EngineMode::setFlags(flags);
    MiniHost host;
    host.init(48000.0, 256);
    host.ctrl[7] = 0.0f; // pedal off
    host.ctrl[9] = 0.0f; // cab off
    host.ctrl[21] = 6.0f; // True 8x (768 kHz domain!)
    host.sendPath(NAM_RIG_AMP_URI, comb44k);

    auto measureTone = [&](double freq) {
      constexpr size_t total = 8192;
      std::vector<float> out(total, 0.0f);
      std::vector<float> in(256, 0.0f);
      for (size_t off = 0; off < total; off += 256) {
        for (size_t i = 0; i < 256; ++i)
          in[i] = 0.25f * std::sin(2.0f * static_cast<float>(kPi) * static_cast<float>(freq * (off + i) / 48000.0));
        host.runBlock(in.data(), 256);
        std::memcpy(out.data() + off, host.outL.data(), 256 * sizeof(float));
      }
      outLatency = host.ctrl[29];
      return dftMag(out, 4096, 4096, freq, 48000.0);
    };
    const double magNotch = measureTone(501.136);
    const double magPeak = measureTone(1002.273);
    return toDb(magNotch / std::max(1.0e-9, magPeak));
  };

  float latBase = 0.0f, latEnh = 0.0f;
  const double notchBaseDb = measureNotchDb(EngineMode::kNone, latBase);
  const double notchEnhDb = measureNotchDb(EngineMode::kModelRateResampling, latEnh);
  check(notchBaseDb > -3.0, "Baseline 44.1k WaveNet @ True 8x misses 501 Hz comb notch (detuned 17.4x)", notchBaseDb, true);
  check(notchEnhDb < -25.0, "T1.1 resampled 44.1k WaveNet @ True 8x restores exact 501 Hz notch", notchEnhDb, true);
  check(std::fabs(latEnh - 124.0f) <= 1.0f, "T1.1 reports exact rational + True 8x latency (~124 frames)", latEnh, true);
}

// ---- Test 3: T1.2 Inter-Stage DC Blocking ----
void testT12DcBlocking() {
  std::printf("== 3. T1.2: Inter-Stage DC Blocking ==\n");
  constexpr double rate = 48000.0;
  constexpr size_t N = 24000;
  std::vector<float> sine(N);
  for (size_t i = 0; i < N; ++i)
    sine[i] = 0.25f * std::sin(2.0f * static_cast<float>(kPi) * 200.0f * i / static_cast<float>(rate));

  // Overdrive SD-1 asymmetric DC
  EngineMode::setFlags(EngineMode::kNone);
  auto odBase = sine;
  { Overdrive od; od.process(odBase.data(), N, rate, 70.0f, 50.0f, 0.0f, 720.0f, 1.0f, true); }
  EngineMode::setFlags(EngineMode::kInterStageDcBlocking);
  auto odEnh = sine;
  { Overdrive od; od.process(odEnh.data(), N, rate, 70.0f, 50.0f, 0.0f, 720.0f, 1.0f, true); }
  const double odDcBase = std::fabs(meanSlice(odBase, 12000, 12000));
  const double odDcEnh = std::fabs(meanSlice(odEnh, 12000, 12000));
  check(odDcBase > 0.04, "Baseline SD-1 OD leaks asymmetric DC", odDcBase, true);
  check(odDcEnh < 1.0e-4, "T1.2 blocks SD-1 OD asymmetric DC (< -80 dBFS)", odDcEnh, true);

  // OutputTransformer Tweed Bloom asymmetric core DC (100 Hz near flux corner)
  std::vector<float> sine100(N);
  for (size_t i = 0; i < N; ++i)
    sine100[i] = 0.25f * std::sin(2.0f * static_cast<float>(kPi) * 100.0f * i / static_cast<float>(rate));
  EngineMode::setFlags(EngineMode::kNone);
  auto otBase = sine100;
  { OutputTransformer ot; ot.process(otBase.data(), N, rate, OutputTransformer::kTweedBloom); }
  EngineMode::setFlags(EngineMode::kInterStageDcBlocking);
  auto otEnh = sine100;
  { OutputTransformer ot; ot.process(otEnh.data(), N, rate, OutputTransformer::kTweedBloom); }
  const double otDcBase = std::fabs(meanSlice(otBase, 12000, 12000));
  const double otDcEnh = std::fabs(meanSlice(otEnh, 12000, 12000));
  check(otDcBase > 0.002, "Baseline Tweed Bloom transformer leaks rectified DC", otDcBase, true);
  check(otDcEnh < 1.0e-4, "T1.2 restores physical 0 DC gain in OutputTransformer", otDcEnh, true);

  // AmpAdvanced extreme bias DC (measure steady state after 5 Hz DC blocker settles)
  EngineMode::setFlags(EngineMode::kInterStageDcBlocking);
  std::vector<float> ampEnh(48000);
  for (size_t i = 0; i < ampEnh.size(); ++i)
    ampEnh[i] = 0.25f * std::sin(2.0f * static_cast<float>(kPi) * 200.0f * i / static_cast<float>(rate));
  { AmpAdvanced a; a.processPostAmp(ampEnh.data(), ampEnh.size(), rate, 0, 0, 50, 100, 50, 50); }
  const double ampDcEnh = std::fabs(meanSlice(ampEnh, 36000, 12000));
  check(ampDcEnh < 1.0e-4, "T1.2 eliminates DC from biased AmpAdvanced power stage", ampDcEnh, true);
}

// ---- Test 4: T1.3 Tighter Inter-Stage Band-Limit & Clean OD Bypass ----
void testT13BandLimit() {
  std::printf("== 4. T1.3: Tighter 14.5 kHz Band-Limit & Clean OD ==\n");
  constexpr double domainRate = 768000.0;
  constexpr double modelRate = 48000.0;
  auto measureGainDb = [&](bool tighter, double freq) {
    ModelBandLimit mbl;
    constexpr size_t N = 16384;
    std::vector<float> buf(N);
    for (size_t i = 0; i < N; ++i)
      buf[i] = std::sin(2.0f * static_cast<float>(kPi) * static_cast<float>(freq * i / domainRate));
    mbl.process(buf.data(), N, domainRate, modelRate, true,
                ModelBandLimit::autoInterStageParams(modelRate, tighter));
    return toDb(dftMag(buf, 8192, 8192, freq, domainRate));
  };
  const double pb5k = measureGainDb(true, 5000.0);
  const double sb36kBase = measureGainDb(false, 36000.0);
  const double sb36kEnh = measureGainDb(true, 36000.0);
  const double sb48kEnh = measureGainDb(true, 48000.0);
  check(pb5k > -0.5, "T1.3 14.5 kHz Bessel6 preserves 5 kHz guitar top-end (> -0.5 dB)", pb5k, true);
  check(sb36kEnh < sb36kBase - 12.0 && sb36kEnh < -22.0,
        "T1.3 improves 36 kHz image rejection by > 12 dB", sb36kEnh, true);
  check(sb48kEnh < -35.5, "T1.3 suppresses 48 kHz ultrasonic content by > 35.5 dB", sb48kEnh, true);

  // Verify Clean OD is flagged pure clean while TS at Drive 50% is nonlinear
  EngineMode::setFlags(EngineMode::kParallelCabAndOdBandLimit);
  Overdrive odClean, odTs;
  std::vector<float> x(256, 0.1f);
  odClean.process(x.data(), x.size(), 48000.0, 50.0f, 50.0f, 3.0f, 720.0f, 4.0f, true);
  odTs.process(x.data(), x.size(), 48000.0, 50.0f, 50.0f, 3.0f, 720.0f, 0.0f, true);
  check(odClean.isPureClean(), "Overdrive Clean voicing reports isPureClean() == true");
  check(!odTs.isPureClean(), "Overdrive TS voicing @ Drive 50% reports isPureClean() == false");
}

// ---- Test 5: T1.4 Overdrive 2x ADAA & Matched EQ ----
void testT14AdaaAndMatchedEq() {
  std::printf("== 5. T1.4: Overdrive 2x ADAA & Nyquist-Matched Filters ==\n");
  constexpr double rate = 48000.0;
  constexpr size_t N = 16384;
  // Choose an exact bin frequency f0 = 3515.625 Hz (bin 600 of 8192 FFT @ 48 kHz)
  // so harmonics 3*f0=10546.875, 5*f0=17578.125 are in-band while 7*f0=24609.375 aliases to 23390.625 Hz
  // and 9*f0=31640.625 aliases to 16359.375 Hz, 11*f0=38671.875 aliases to 9328.125 Hz!
  const double f0 = 600.0 * rate / 8192.0; // 3515.625 Hz
  std::vector<float> in(N);
  for (size_t i = 0; i < N; ++i)
    in[i] = 0.4f * std::sin(2.0f * static_cast<float>(kPi) * static_cast<float>(f0 * i / rate));

  auto measureAliasRatioDb = [&](uint32_t flags) {
    EngineMode::setFlags(flags);
    auto buf = in;
    Overdrive od;
    od.process(buf.data(), N, rate, 90.0f, 100.0f, 0.0f, 720.0f, 0.0f, true);
    const double fund = dftMag(buf, 8192, 8192, f0, rate);
    // Measure folded odd aliases (9*f0 -> 48000 - 9*f0, 11*f0 -> 48000 - 11*f0, 13*f0 -> 48000 - 13*f0)
    const double a9 = dftMag(buf, 8192, 8192, rate - 9.0 * f0, rate);
    const double a11 = dftMag(buf, 8192, 8192, rate - 11.0 * f0, rate);
    const double a13 = dftMag(buf, 8192, 8192, 13.0 * f0 - rate, rate);
    return toDb(std::sqrt(a9 * a9 + a11 * a11 + a13 * a13) / std::max(1.0e-9, fund));
  };
  const double aliasBase = measureAliasRatioDb(EngineMode::kNone);
  const double aliasEnh = measureAliasRatioDb(EngineMode::kOverdriveAdaaAndMatchedEq);
  check(aliasEnh < aliasBase - 12.0,
        "T1.4 Overdrive 2x ADAA suppresses 48 kHz aliasing by > 12 dB", aliasBase - aliasEnh, true);

  // OutputTransformer 48 kHz vs 768 kHz Nyquist-matched check at 10 kHz (Studio Linear / Modern)
  auto measureOtAtRate = [&](uint32_t flags, double r) {
    EngineMode::setFlags(flags);
    const size_t n = static_cast<size_t>(r * 0.25);
    std::vector<float> buf(n);
    for (size_t i = 0; i < n; ++i)
      buf[i] = 0.05f * std::sin(2.0f * static_cast<float>(kPi) * static_cast<float>(10000.0 * i / r));
    OutputTransformer ot;
    ot.process(buf.data(), n, r, OutputTransformer::kModern);
    return toDb(dftMag(buf, n / 2, n / 2, 10000.0, r) / 0.05);
  };
  const double otRef768 = measureOtAtRate(EngineMode::kNone, 768000.0);
  const double ot48Base = measureOtAtRate(EngineMode::kNone, 48000.0);
  const double ot48Enh = measureOtAtRate(EngineMode::kOverdriveAdaaAndMatchedEq, 48000.0);
  check(std::fabs(ot48Enh - otRef768) < std::fabs(ot48Base - otRef768) &&
        std::fabs(ot48Enh - otRef768) < 0.6,
        "T1.4 OutputTransformer 48 kHz matches 768 kHz at 10 kHz (< 0.6 dB err)",
        std::fabs(ot48Enh - otRef768), true);

  // SpeakerDynamics 48 kHz vs 768 kHz inductive rise match at 12 kHz
  EngineMode::setFlags(EngineMode::kNone);
  const double spkRef = SpeakerDynamics::responseDb(SpeakerDynamics::kModern412, 12000.0, 768000.0, 0, 100, 0);
  const double spkBase = SpeakerDynamics::responseDb(SpeakerDynamics::kModern412, 12000.0, 48000.0, 0, 100, 0);
  EngineMode::setFlags(EngineMode::kOverdriveAdaaAndMatchedEq);
  const double spkEnh = SpeakerDynamics::responseDb(SpeakerDynamics::kModern412, 12000.0, 48000.0, 0, 100, 0);
  check(std::fabs(spkEnh - spkRef) < std::fabs(spkBase - spkRef) && std::fabs(spkEnh - spkRef) < 0.2,
        "T1.4 SpeakerDynamics 48 kHz matches 768 kHz at 12 kHz (< 0.2 dB err)",
        std::fabs(spkEnh - spkRef), true);
}

// ---- Test 6: T2.1 Interface dBu Calibration & Pedal -> Amp Gain Staging ----
void testT21CalibrationAndPedalStaging(const TempDir& tmp) {
  std::printf("== 6. T2.1: Interface dBu Calibration & Pedal->Amp Staging ==\n");
  // Unity-gain WaveNet pedal: input_level_dbu=12, output_level_dbu=18, loudness=-6
  // (Baseline normalizes output by -18 - (-6) = -12 dB; T2.1 preserves raw output + passes +18 dBu bus!)
  const std::string pedalPath = tmp.writeFile("boost_pedal.nam",
      R"({"version":"0.5.4","architecture":"WaveNet","config":{"layers":[{"input_size":1,"condition_size":1,"head_size":1,"channels":1,"kernel_size":1,"dilations":[1],"activation":"Hardtanh","gated":false,"head_bias":false}],"head":null,"head_scale":1.0},"weights":[1,1,0,0,0,0,1,1],"sample_rate":48000,"metadata":{"loudness":-6.0,"input_level_dbu":12.0,"output_level_dbu":18.0}})");
  // Unity-gain WaveNet amp: input_level_dbu=12, loudness=-18
  const std::string ampPath = tmp.writeFile("clean_amp.nam",
      R"({"version":"0.5.4","architecture":"WaveNet","config":{"layers":[{"input_size":1,"condition_size":1,"head_size":1,"channels":1,"kernel_size":1,"dilations":[1],"activation":"Hardtanh","gated":false,"head_bias":false}],"head":null,"head_scale":1.0},"weights":[1,1,0,0,0,0,1,1],"sample_rate":48000,"metadata":{"loudness":-18.0,"input_level_dbu":12.0}})");

  auto runRigDb = [&](uint32_t flags, float calDbu, bool withPedal) {
    EngineMode::setFlags(flags);
    EngineMode::setInputCalibrationDbu(calDbu);
    MiniHost host;
    host.init(48000.0, 256);
    host.ctrl[7] = withPedal ? 1.0f : 0.0f;
    host.ctrl[8] = 1.0f;
    host.ctrl[9] = 0.0f;
    host.ctrl[20] = 0.0f;
    host.ctrl[21] = 0.0f;
    if (withPedal) host.sendPath(NAM_RIG_PEDAL_URI, pedalPath);
    host.sendPath(NAM_RIG_AMP_URI, ampPath);

    std::vector<float> out(4096, 0.0f), in(256, 0.0f);
    for (size_t off = 0; off < 4096; off += 256) {
      for (size_t i = 0; i < 256; ++i)
        in[i] = 0.05f * std::sin(2.0f * static_cast<float>(kPi) * 440.0f * (off + i) / 48000.0f);
      host.runBlock(in.data(), 256);
      std::memcpy(out.data() + off, host.outL.data(), 256 * sizeof(float));
    }
    return toDb(dftMag(out, 2048, 2048, 440.0, 48000.0) / 0.05);
  };

  const double ampCal12 = runRigDb(EngineMode::kCalibrationAndPedalStaging, 12.0f, false);
  const double ampCal18 = runRigDb(EngineMode::kCalibrationAndPedalStaging, 18.0f, false);
  check(std::fabs((ampCal18 - ampCal12) - 6.0) < 0.2,
        "T2.1 +18 dBu interface calibration boosts +12 dBu model by +6.0 dB", ampCal18 - ampCal12, true);

  const double chainBase = runRigDb(EngineMode::kNone, 12.0f, true);
  const double chainEnh = runRigDb(EngineMode::kCalibrationAndPedalStaging, 12.0f, true);
  check(std::fabs(chainBase - (-12.0)) < 0.3,
        "Baseline pedal->amp loudness normalization attenuates +12 dB hot pedal to -12 dB", chainBase, true);
  check(std::fabs(chainEnh - 6.0) < 0.3,
        "T2.1 pedal->amp preserves true output_level_dbu transfer (+6.0 dB into amp)", chainEnh, true);
  EngineMode::setInputCalibrationDbu(EngineMode::kDefaultInputCalibrationDbu);
}

// ---- Test 7: T2.2 Power Stage Headroom, Master Noise, Charged-Cap Sag, Class AB & Damping ----
void testT22PowerStageTubeDynamics() {
  std::printf("== 7. T2.2: Tube Power Stage Dynamics ==\n");
  constexpr double rate = 48000.0;
  constexpr size_t N = 16384;

  // 7a. Calibrated headroom engages on -12 dBFS (0.25) peak even at Master 0% + Sag 100%
  auto measureThd = [&](uint32_t flags) {
    EngineMode::setFlags(flags);
    std::vector<float> buf(N);
    for (size_t i = 0; i < N; ++i)
      buf[i] = 0.25f * std::sin(2.0f * static_cast<float>(kPi) * 200.0f * i / static_cast<float>(rate));
    AmpAdvanced amp;
    amp.processPostAmp(buf.data(), N, rate, 0, 0, 100, 0, 50, 0);
    const double f1 = dftMag(buf, 8192, 8192, 200.0, rate);
    const double f2 = dftMag(buf, 8192, 8192, 400.0, rate);
    const double f3 = dftMag(buf, 8192, 8192, 600.0, rate);
    return std::hypot(f2, f3) / std::max(1.0e-9, f1);
  };
  const double thdBase = measureThd(EngineMode::kNone);
  const double thdEnh = measureThd(EngineMode::kPowerStageTubeDynamics);
  check(thdBase < 1.0e-4, "Baseline @ Master 0%, Sag 100% stays dead linear on -12 dBFS peak", thdBase, true);
  check(thdEnh > 0.002, "T2.2 @ Master 0%, Sag 100% actively engages tube knee on -12 dBFS peak", thdEnh, true);

  // 7b. Master 100% quiet noise-floor boost <= +5.0 dB (vs +18 dB in baseline)
  auto measureQuietGainDb = [&](uint32_t flags) {
    EngineMode::setFlags(flags);
    std::vector<float> buf(N);
    for (size_t i = 0; i < N; ++i)
      buf[i] = 0.002f * std::sin(2.0f * static_cast<float>(kPi) * 1000.0f * i / static_cast<float>(rate));
    AmpAdvanced amp;
    amp.processPostAmp(buf.data(), N, rate, 0, 0, 0, 0, 50, 100);
    return toDb(dftMag(buf, 8192, 8192, 1000.0, rate) / 0.002);
  };
  const double quietBaseDb = measureQuietGainDb(EngineMode::kNone);
  const double quietEnhDb = measureQuietGainDb(EngineMode::kPowerStageTubeDynamics);
  check(quietBaseDb > 17.0, "Baseline Master 100% inflates quiet noise floor by ~+18 dB", quietBaseDb, true);
  check(quietEnhDb < 5.0, "T2.2 Master 100% caps quiet noise-floor boost <= +5.0 dB", quietEnhDb, true);

  // 7c. Charged-cap pick snap preserved before sag droops on sustained low-end chug
  EngineMode::setFlags(EngineMode::kPowerStageTubeDynamics);
  {
    AmpAdvanced amp;
    // Prime smoothers with silence first so only sag dynamics vary across the burst.
    std::vector<float> prime(4096, 0.0f);
    amp.processPostAmp(prime.data(), prime.size(), rate, 0, 0, 100, 0, 50, 50);
    std::vector<float> burst(8192);
    for (size_t i = 0; i < burst.size(); ++i)
      burst[i] = 0.35f * std::sin(2.0f * static_cast<float>(kPi) * 100.0f * i / static_cast<float>(rate));
    amp.processPostAmp(burst.data(), burst.size(), rate, 0, 0, 100, 0, 50, 50);
    const double initialRms = rmsSlice(burst, 0, 480);      // 0..10 ms (charged caps!)
    const double sustainRms = rmsSlice(burst, 4800, 2400);  // 100..150 ms (sagged!)
    check(initialRms > sustainRms * 1.03,
          "T2.2 Sag preserves initial 0-10 ms charged-cap pick snap before drooping",
          toDb(initialRms / std::max(1.0e-9, sustainRms)), true);
  }

  // 7d. Dynamic NFB damping drops under drive & differs between EL34 and 6L6
  {
    AmpAdvanced ampEl34, amp6l6;
    std::vector<float> quiet(4096), loud(4096);
    for (size_t i = 0; i < 4096; ++i) {
      quiet[i] = 0.02f * std::sin(2.0f * static_cast<float>(kPi) * 200.0f * i / static_cast<float>(rate));
      loud[i] = 0.45f * std::sin(2.0f * static_cast<float>(kPi) * 200.0f * i / static_cast<float>(rate));
    }
    ampEl34.processPostAmp(quiet.data(), quiet.size(), rate, 0, 0, 50, 0, 50, 0, PowerTube::kEL34, 100);
    amp6l6.processPostAmp(quiet.data(), quiet.size(), rate, 0, 0, 50, 0, 50, 0, PowerTube::k6L6, 100);
    const double el34QuietDamp = ampEl34.lastDynamicDamping();
    const double l6QuietDamp = amp6l6.lastDynamicDamping();
    ampEl34.processPostAmp(loud.data(), loud.size(), rate, 0, 0, 50, 0, 50, 80, PowerTube::kEL34, 100);
    const double el34DrivenDamp = ampEl34.lastDynamicDamping();
    check(el34QuietDamp < l6QuietDamp - 0.1,
          "T2.2 EL34 pentode has lower natural speaker damping than 6L6 tetrode",
          l6QuietDamp - el34QuietDamp, true);
    check(el34DrivenDamp < el34QuietDamp - 0.15,
          "T2.2 NFB dynamic damping collapses under heavy power-tube saturation",
          el34DrivenDamp, true);
  }
}

// ---- Test 8: T2.3 Speaker Palm-Mute Thump, Low-Band Excursion & NFB Coupling ----
void testT23SpeakerPalmMuteDynamics() {
  std::printf("== 8. T2.3: Speaker Palm-Mute Dynamics ==\n");
  constexpr double rate = 48000.0;
  constexpr size_t N = 16384;

  // 8a. Low-band-only excursion leaves 3 kHz pick clarity un-ducked during heavy 82 Hz palm mute
  auto measurePickDuckDb = [&](uint32_t flags) {
    EngineMode::setFlags(flags);
    std::vector<float> hiOnly(N), chugPlusHi(N);
    for (size_t i = 0; i < N; ++i) {
      const float hi = 0.06f * std::sin(2.0f * static_cast<float>(kPi) * 3000.0f * i / static_cast<float>(rate));
      const float lo = 0.65f * std::sin(2.0f * static_cast<float>(kPi) * 82.0f * i / static_cast<float>(rate));
      hiOnly[i] = hi;
      chugPlusHi[i] = lo + hi;
    }
    SpeakerDynamics s1, s2;
    s1.process(hiOnly.data(), N, rate, SpeakerDynamics::kModern412, 0, 100, 0, 50, 0.3f);
    s2.process(chugPlusHi.data(), N, rate, SpeakerDynamics::kModern412, 0, 100, 0, 50, 0.3f);
    const double m1 = dftMag(hiOnly, 8192, 8192, 3000.0, rate);
    const double m2 = dftMag(chugPlusHi, 8192, 8192, 3000.0, rate);
    return toDb(m2 / std::max(1.0e-9, m1));
  };
  const double duckBaseDb = measurePickDuckDb(EngineMode::kNone);
  const double duckEnhDb = measurePickDuckDb(EngineMode::kSpeakerPalmMuteDynamics);
  check(duckBaseDb < -2.0, "Baseline broadband excursion ducks 3 kHz pick by > 2 dB during 82 Hz chug", duckBaseDb, true);
  check(duckEnhDb > -0.9, "T2.3 low-band-only excursion preserves 3 kHz pick clarity (< 0.9 dB duck)", duckEnhDb, true);

  // 8b. Dynamic Thump kicks harder on onset (5-25 ms) than steady sustain (160-240 ms)
  auto measureThumpOnsetAdvantageDb = [&](uint32_t flags) {
    EngineMode::setFlags(flags);
    SpeakerDynamics spk;
    std::vector<float> prime(4096, 0.0f);
    spk.process(prime.data(), prime.size(), rate, SpeakerDynamics::kModern412, 0, 0, 100, 50, 0.3f);
    std::vector<float> burst(14400);
    for (size_t i = 0; i < burst.size(); ++i)
      burst[i] = 0.25f * std::sin(2.0f * static_cast<float>(kPi) * 68.0f * i / static_cast<float>(rate));
    spk.process(burst.data(), burst.size(), rate, SpeakerDynamics::kModern412, 0, 0, 100, 50, 0.3f);
    const double onsetRms = rmsSlice(burst, 240, 1200);
    const double steadyRms = rmsSlice(burst, 8000, 4000);
    return toDb(onsetRms / std::max(1.0e-9, steadyRms));
  };
  const double thumpBase = measureThumpOnsetAdvantageDb(EngineMode::kNone);
  const double thumpEnh = measureThumpOnsetAdvantageDb(EngineMode::kSpeakerPalmMuteDynamics);
  check(thumpEnh > thumpBase + 0.5,
        "T2.3 dynamic Thump delivers stronger onset punch relative to sustain",
        thumpEnh - thumpBase, true);

  // 8c. Dynamic NFB damping coupling blooms resonance when power tubes saturate
  EngineMode::setFlags(EngineMode::kSpeakerPalmMuteDynamics);
  auto measureResWithDynDamp = [&](float dynScale) {
    std::vector<float> buf(N);
    for (size_t i = 0; i < N; ++i)
      buf[i] = 0.1f * std::sin(2.0f * static_cast<float>(kPi) * 82.0f * i / static_cast<float>(rate));
    SpeakerDynamics spk;
    spk.setDynamicDampingScale(dynScale);
    spk.process(buf.data(), N, rate, SpeakerDynamics::kModern412, 0, 0, 0, 100, 0.8f);
    return toDb(dftMag(buf, 8192, 8192, 82.0, rate) / 0.1);
  };
  const double resHighDamp = measureResWithDynDamp(1.0f);
  const double resLowDamp = measureResWithDynDamp(0.4f);
  check(resLowDamp > resHighDamp + 0.35,
        "T2.3 dynamic NFB collapse blooms 82 Hz speaker resonance",
        resLowDamp - resHighDamp, true);
}

// ---- Test 9: T2.4 Lookahead Gate & Sidechain-HPF Compressor ----
void testT24GateAndCompDynamics() {
  std::printf("== 9. T2.4: 0.75 ms Lookahead Gate & Sidechain-HPF Compressor ==\n");
  constexpr double rate = 48000.0;

  // 9a. Gate lookahead preserves the first pick sample after closed silence
  auto testGateLeadingEdge = [&](uint32_t flags, uint32_t& outLatency) {
    EngineMode::setFlags(flags);
    NoiseGate g;
    g.configure(rate, -36.0f, 80.0f);
    outLatency = g.latencySamples();
    // Feed 300 ms silence to close the gate completely
    for (int i = 0; i < 14400; ++i) g.process(0.0f);
    // Feed sudden 1 kHz burst of amplitude 0.25 (first non-zero peak at sample 12)
    std::vector<float> out(256, 0.0f);
    for (size_t i = 0; i < out.size(); ++i) {
      const float s = 0.25f * std::sin(2.0f * static_cast<float>(kPi) * 1000.0f * (i + 12) / static_cast<float>(rate));
      out[i] = g.process(s);
    }
    return std::fabs(out[outLatency]); // Exact first delayed sample (which has input amplitude 0.25!)
  };
  uint32_t gateLatBase = 0, gateLatEnh = 0;
  const double firstBase = testGateLeadingEdge(EngineMode::kNone, gateLatBase);
  const double firstEnh = testGateLeadingEdge(EngineMode::kGateAndCompDynamics, gateLatEnh);
  check(gateLatBase == 0 && gateLatEnh == 36, "T2.4 NoiseGate reports 36-sample (0.75 ms) lookahead @ 48 kHz", gateLatEnh, true);
  check(firstBase < 0.02, "Baseline zero-lookahead gate clips first pick sample", firstBase, true);
  check(firstEnh > 0.23, "T2.4 0.75 ms lookahead preserves > 92% of very first pick sample", firstEnh / 0.25, true);

  // 9b. Gate sidechain rejects 60 Hz hum compared to 1 kHz guitar tone at equal amplitude
  EngineMode::setFlags(EngineMode::kGateAndCompDynamics);
  auto measureGateOpenLevel = [&](double freq) {
    NoiseGate g;
    g.configure(rate, -30.0f, 80.0f);
    for (int i = 0; i < 14400; ++i) g.process(0.0f);
    std::vector<float> out(4800);
    // -27 dBFS amplitude (0.0447): 1 kHz clears -30 dBFS easily; 60 Hz is attenuated -8.6 dB by 95 Hz HPF -> stays closed!
    for (size_t i = 0; i < out.size(); ++i) {
      const float s = 0.045f * std::sin(2.0f * static_cast<float>(kPi) * static_cast<float>(freq * i / rate));
      out[i] = g.process(s);
    }
    return rmsSlice(out, 2400, 2400);
  };
  const double rmsHum = measureGateOpenLevel(60.0);
  const double rmsGuitar = measureGateOpenLevel(1000.0);
  check(rmsGuitar > 0.025 && rmsHum < rmsGuitar * 0.35,
        "T2.4 NoiseGate 110 Hz LR4 sidechain suppresses 60 Hz hum (> 9 dB) while opening on 1 kHz guitar",
        toDb(rmsHum / std::max(1.0e-9, rmsGuitar)), true);

  // 9c. Compressor 110 Hz sidechain HPF reduces gain reduction on 82 Hz palm mute vs 1 kHz
  EngineMode::setFlags(EngineMode::kGateAndCompDynamics);
  const float attCoeff = static_cast<float>(-std::expm1(-1.0 / (rate * 0.005)));
  const float relCoeff = static_cast<float>(-std::expm1(-1.0 / (rate * 0.020)));
  auto measureCompGain = [&](double freq) {
    CompressorCore c;
    c.prepare(rate);
    float lastG = 1.0f;
    for (int i = 0; i < 9600; ++i) {
      const float s = 0.25f * std::sin(2.0f * static_cast<float>(kPi) * static_cast<float>(freq * i / rate));
      lastG = c.processSigned(s, -24.0f, 4.0f, 0.0f, attCoeff, relCoeff);
    }
    return toDb(lastG);
  };
  const double gr82 = measureCompGain(82.0);
  const double gr1k = measureCompGain(1000.0);
  check(gr82 > gr1k + 2.0,
        "T2.4 Compressor 110 Hz sidechain HPF ducks 82 Hz palm mute less than 1 kHz",
        gr82 - gr1k, true);

  // 9d. Compressor noise-floor-safe makeup does not boost -70 dBFS idle noise
  {
    CompressorCore c;
    c.prepare(rate);
    float quietG = 1.0f, activeG = 1.0f;
    for (int i = 0; i < 12000; ++i)
      quietG = c.processSigned(0.0003f * std::sin(2.0f * static_cast<float>(kPi) * 1000.0f * i / static_cast<float>(rate)),
                               -24.0f, 3.0f, 6.0f, attCoeff, relCoeff);
    for (int i = 0; i < 12000; ++i)
      activeG = c.processSigned(0.03f * std::sin(2.0f * static_cast<float>(kPi) * 1000.0f * i / static_cast<float>(rate)),
                                -24.0f, 3.0f, 6.0f, attCoeff, relCoeff);
    check(toDb(quietG) < 0.5 && toDb(activeG) > 5.0,
          "T2.4 Compressor fades makeup to ~0 dB on -70 dBFS idle noise while giving +6 dB on active guitar",
          toDb(activeG) - toDb(quietG), true);
  }
}

// ---- Test 10: T2.5 OD Tight at Drive 0% + Dynamic 6 dB/oct Tight + Gain-Coupled Bright Cap ----
void testT25PreAmpTightAndBrightCap() {
  std::printf("== 10. T2.5: OD Tight @ Drive 0%%, Dynamic 6 dB/oct HPF & Bright Cap ==\n");
  constexpr double rate = 48000.0;
  constexpr size_t N = 16384;

  // 10a. Overdrive Drive 0% retains Tight HPF mid-focus cleanly
  auto measureOdContour = [&](uint32_t flags, double freq) {
    EngineMode::setFlags(flags);
    std::vector<float> buf(N);
    for (size_t i = 0; i < N; ++i)
      buf[i] = 0.2f * std::sin(2.0f * static_cast<float>(kPi) * static_cast<float>(freq * i / rate));
    Overdrive od;
    od.process(buf.data(), N, rate, 0.0f, 50.0f, 0.0f, 720.0f, 0.0f, true);
    return toDb(dftMag(buf, 8192, 8192, freq, rate) / 0.2);
  };
  const double odBaseDiff = measureOdContour(EngineMode::kNone, 720.0) - measureOdContour(EngineMode::kNone, 80.0);
  const double odEnhDiff = measureOdContour(EngineMode::kPreAmpTightAndBrightCap, 720.0) -
                           measureOdContour(EngineMode::kPreAmpTightAndBrightCap, 80.0);
  check(std::fabs(odBaseDiff) < 0.5, "Baseline OD Drive 0% ignores Tight HPF", odBaseDiff, true);
  check(odEnhDiff > 5.0, "T2.5 OD Drive 0% retains clean Tight mid-focus contour (> 5 dB)", odEnhDiff, true);

  // 10b. Dynamic palm-mute tightening cuts 82 Hz deeper on heavy chug (0.5) than quiet pick (0.02)
  EngineMode::setFlags(EngineMode::kPreAmpTightAndBrightCap);
  auto measurePreTight = [&](float ampLevel) {
    std::vector<float> buf(N);
    for (size_t i = 0; i < N; ++i)
      buf[i] = ampLevel * std::sin(2.0f * static_cast<float>(kPi) * 82.0f * i / static_cast<float>(rate));
    AmpAdvanced amp;
    amp.processPreAmp(buf.data(), N, rate, 0.0f, 60.0f, 0.0f, 0.0f);
    return toDb(dftMag(buf, 8192, 8192, 82.0, rate) / ampLevel);
  };
  const double quiet82 = measurePreTight(0.02f);
  const double chug82 = measurePreTight(0.50f);
  check(chug82 < quiet82 - 1.2,
        "T2.5 dynamic Pre-Amp Tight cuts 82 Hz deeper during heavy palm-mute chug",
        quiet82 - chug82, true);

  // 10c. Gain-coupled Bright Cap tapers as ampDriveDb rises from 0 dB -> +24 dB
  auto measureBright4k = [&](float ampDriveDb) {
    std::vector<float> buf(N);
    for (size_t i = 0; i < N; ++i)
      buf[i] = 0.1f * std::sin(2.0f * static_cast<float>(kPi) * 4000.0f * i / static_cast<float>(rate));
    AmpAdvanced amp;
    amp.processPreAmp(buf.data(), N, rate, 100.0f, 0.0f, 0.0f, ampDriveDb);
    return toDb(dftMag(buf, 8192, 8192, 4000.0, rate) / 0.1);
  };
  const double brightLowGain = measureBright4k(0.0f);
  const double brightHighGain = measureBright4k(24.0f);
  check(brightLowGain > brightHighGain + 2.5,
        "T2.5 Bright Cap tapers down by > 2.5 dB as Amp Drive increases 0 -> +24 dB",
        brightLowGain - brightHighGain, true);
}

// ---- Test 11: Click-Free requestFlags Transition on Live Plugin ----
void testClickFreeRuntimeToggle() {
  std::printf("== 11. Click-Free Runtime Toggle (requestFlags) ==\n");
  EngineMode::setFlags(EngineMode::kNone);
  MiniHost host;
  host.init(48000.0, 128);
  host.ctrl[7] = 0.0f;
  host.ctrl[8] = 0.0f;
  host.ctrl[9] = 0.0f;
  host.ctrl[15] = -36.0f; // Enable gate so lookahead flips during silent commit!

  std::vector<float> in(128);
  for (int b = 0; b < 5; ++b) {
    for (size_t i = 0; i < 128; ++i)
      in[i] = 0.25f * std::sin(2.0f * static_cast<float>(kPi) * 440.0f * (b * 128 + i) / 48000.0f);
    host.runBlock(in.data(), 128);
  }
  EngineMode::requestFlags(EngineMode::kAllTier1And2);
  bool sawFade = false, allFinite = true;
  for (int b = 0; b < 15; ++b) {
    for (size_t i = 0; i < 128; ++i)
      in[i] = 0.25f * std::sin(2.0f * static_cast<float>(kPi) * 440.0f * ((b + 5) * 128 + i) / 48000.0f);
    host.runBlock(in.data(), 128);
    if (host.plugin.currentTransitionPhase() != Plugin::TransitionPhase::Steady) sawFade = true;
    for (float s : host.outL) if (!std::isfinite(s)) allFinite = false;
  }
  check(sawFade, "EngineMode::requestFlags triggers click-safe cosine transition fade");
  check(EngineMode::flags() == EngineMode::kAllTier1And2, "Transition commits kAllTier1And2 cleanly at silence");
  check(host.plugin.currentTransitionPhase() == Plugin::TransitionPhase::Steady, "Transition settles back to Steady");
  check(allFinite, "All samples remain finite across runtime engine switch");
  EngineMode::setFlags(EngineMode::kNone);
}

}  // namespace

int main() {
  TempDir tmp;
  testBitExactBaseline();
  testT11ModelRateResampling(tmp);
  testT12DcBlocking();
  testT13BandLimit();
  testT14AdaaAndMatchedEq();
  testT21CalibrationAndPedalStaging(tmp);
  testT22PowerStageTubeDynamics();
  testT23SpeakerPalmMuteDynamics();
  testT24GateAndCompDynamics();
  testT25PreAmpTightAndBrightCap();
  testClickFreeRuntimeToggle();

  std::printf("\n%s (%d failures)\n", failures == 0 ? "ALL PASSED" : "FAILED", failures);
  return failures == 0 ? 0 : 1;
}
