// Linked integration test: compile with nam_rig_plugin.cpp, wav_ir.cpp,
// oversample.cpp and cabinet_worker.cpp; link NeuralAudio and Accelerate.
// Usage: verify_parallel_cabs [wavenet.nam [lstm.nam]] [--benchmark]
#include "nam_rig_plugin.h"
#include "cabinet_worker.h"
#include "polyphase_worker.h"
#include "wav_ir.h"
#include "rack_controls.h"

#include <algorithm>
#include <array>
#include <cfenv>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <exception>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <mach/mach_time.h>

#pragma STDC FENV_ACCESS ON

namespace {
using NAMRig::CabinetWorker;
using NAMRig::Plugin;
using NAMRig::Stage;
constexpr uint32_t kMaximum = 513;
constexpr int32_t kBlockLength = 128;
constexpr size_t kAtomBytes = 16384;
constexpr std::array<uint32_t, 7> kCounts{1, 17, 64, 127, 128, 256, 513};
constexpr std::array<int, 4> kModes{0, 4, 5, 6};
constexpr std::array<const char*, 4> kStageUris{
    NAM_RIG_PEDAL_URI, NAM_RIG_AMP_URI, NAM_RIG_CAB_URI, NAM_RIG_CAB2_URI};
std::string testSection = "startup";
uint64_t checkedFrames = 0;
uint64_t workerCalls = 0;

void check(bool condition, const char* message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL [%s]: %s\n", testSection.c_str(), message);
    std::exit(1);
  }
}

struct TempWavs {
  std::filesystem::path directory;
  std::string mono, stereo, identity, greenback, v30;

  TempWavs() {
    const std::string pattern =
        (std::filesystem::temp_directory_path() / "verify_parallel_cabs-XXXXXX").string();
    std::vector<char> name(pattern.begin(), pattern.end());
    name.push_back('\0');
    const char* created = mkdtemp(name.data());
    if (!created) throw std::runtime_error("cannot create temporary WAV fixture directory");
    directory = created;
    mono = (directory / "mono.wav").string();
    stereo = (directory / "stereo.wav").string();
    identity = (directory / "identity.nam").string();
    greenback = (directory / "Marshall Greenback G12M.wav").string();
    v30 = (directory / "Mesa Oversized V30.wav").string();
  }
  ~TempWavs() {
    std::error_code error;
    std::filesystem::remove_all(directory, error);
  }
  TempWavs(const TempWavs&) = delete;
  TempWavs& operator=(const TempWavs&) = delete;

  void write(unsigned channels) const {
    const std::string& path = channels == 1 ? mono : stereo;
    std::ofstream file(path, std::ios::binary);
    auto little = [&](uint32_t value, unsigned bytes) {
      for (unsigned i = 0; i < bytes; ++i)
        file.put(static_cast<char>((value >> (8 * i)) & 0xff));
    };
    constexpr uint32_t frames = 64, rate = 48000;
    const uint32_t dataBytes = frames * channels * 2;
    file.write("RIFF", 4); little(36 + dataBytes, 4); file.write("WAVE", 4);
    file.write("fmt ", 4); little(16, 4); little(1, 2); little(channels, 2);
    little(rate, 4); little(rate * channels * 2, 4);
    little(channels * 2, 2); little(16, 2);
    file.write("data", 4); little(dataBytes, 4);
    for (uint32_t frame = 0; frame < frames; ++frame) {
      for (unsigned channel = 0; channel < channels; ++channel) {
        const int16_t tap = channel == 0
            ? (frame == 0 ? 16384 : frame == 5 ? -4096 : frame == 23 ? 2048 : 0)
            : (frame == 17 ? 8192 : frame == 31 ? -2048 : 0);
        little(static_cast<uint16_t>(tap), 2);
      }
    }
    file.close();
    if (!file) throw std::runtime_error("cannot write temporary PCM16 WAV: " + path);
    check(NAMRig::WavIR::channelCount(path.c_str()) == channels,
          "PCM16 fixture reports expected channel count");
  }
  void writeSpeakerFixtures() const {
    for (const std::string& path : {greenback, v30}) {
      std::ofstream file(path, std::ios::binary);
      auto little = [&](uint32_t value, unsigned bytes) {
        for (unsigned i = 0; i < bytes; ++i)
          file.put(static_cast<char>((value >> (8 * i)) & 0xff));
      };
      constexpr uint32_t frames = 64, rate = 48000;
      const uint32_t dataBytes = frames * 2;
      file.write("RIFF", 4); little(36 + dataBytes, 4); file.write("WAVE", 4);
      file.write("fmt ", 4); little(16, 4); little(1, 2); little(1, 2);
      little(rate, 4); little(rate * 2, 4);
      little(2, 2); little(16, 2);
      file.write("data", 4); little(dataBytes, 4);
      for (uint32_t frame = 0; frame < frames; ++frame) {
        const int16_t tap = frame == 0 ? 16384 : 0;
        little(static_cast<uint16_t>(tap), 2);
      }
      file.close();
      if (!file) throw std::runtime_error("cannot write temporary speaker WAV: " + path);
    }
  }
  void writeIdentity() const {
    std::ofstream file(identity);
    // A one-tap WaveNet is identity in Hardtanh's linear range. Use the
    // production WaveNet loader; Linear isn't linked by every NeuralAudio build.
    file << R"({"version":"0.5.4","architecture":"WaveNet","config":{"layers":[{"input_size":1,"condition_size":1,"head_size":1,"channels":1,"kernel_size":1,"dilations":[1],"activation":"Hardtanh","gated":false,"head_bias":false}],"head":null,"head_scale":1.0},"weights":[1,1,0,0,0,0,1,1],"sample_rate":48000})";
    file.close();
    if (!file) throw std::runtime_error("cannot write identity NAM fixture");
  }
};

// The rig's RBJ low shelf (nam_rig_plugin.cpp setLowShelf) as the dual-cab
// blend applies it: 200 Hz, -20*log10(cos(pi/4) + sin(pi/4)) dB at Width 0
// with both cabinets at equal level.
void dualCabShelf(NAMRig::Biquad& f, double sampleRate) {
  const float theta = 3.14159265358979323846f * 0.25f;
  const float coherent = std::max(1.0f, std::cos(theta) + std::sin(theta));
  const float gainDb = -20.0f * std::log10(coherent);
  const float kEqQ = 0.7071067811865476f;
  const double A = std::pow(10.0, gainDb / 40.0);
  const double w0 = 2.0 * 3.14159265358979323846 * 200.0f / sampleRate;
  const double c = std::cos(w0), s = std::sin(w0);
  const double alpha = s / (2.0 * kEqQ);
  const double sqA = 2.0 * std::sqrt(A) * alpha;
  const double b0 = A * ((A + 1) - (A - 1) * c + sqA);
  const double b1 = 2.0 * A * ((A - 1) - (A + 1) * c);
  const double b2 = A * ((A + 1) - (A - 1) * c - sqA);
  const double a0 = (A + 1) + (A - 1) * c + sqA;
  const double a1 = -2.0 * ((A - 1) + (A + 1) * c);
  const double a2 = (A + 1) + (A - 1) * c - sqA;
  f.b0 = b0 / a0;
  f.b1 = b1 / a0;
  f.b2 = b2 / a0;
  f.a1 = a1 / a0;
  f.a2 = a2 / a0;
}

bool sameEnvironment(const std::fenv_t& a, const std::fenv_t& b,
                     bool includeFlags = true) {
#if defined(__arm64__)
  return a.__fpcr == b.__fpcr && (!includeFlags || a.__fpsr == b.__fpsr);
#elif defined(__x86_64__)
  return a.__control == b.__control &&
         (includeFlags ? a.__mxcsr == b.__mxcsr && a.__status == b.__status
                       : (a.__mxcsr & ~0x3fu) == (b.__mxcsr & ~0x3fu));
#else
#error Unsupported macOS floating-point environment
#endif
}

struct EnvironmentResult {
  std::fenv_t entry{};
  std::array<float, 4> values{};
  std::thread::id thread;
};

void environmentJob(void* context) noexcept {
  auto& result = *static_cast<EnvironmentResult*>(context);
  check(std::fegetenv(&result.entry) == 0, "capture job fenv");
  result.thread = std::this_thread::get_id();
  volatile float one = 1.0f, small = 0x1p-24f, normal = 0x1p-126f;
  volatile float denormal = std::numeric_limits<float>::denorm_min();
  result.values = {one + small, -one - small, normal * 0.5f, denormal * 2.0f};
  // Contaminate the thread so the next job must restore its own snapshot.
  check(std::fesetenv(FE_DFL_ENV) == 0, "reset job fenv");
}

void setEnvironment(int rounding, bool flushDenormals) {
  const std::fenv_t* base = FE_DFL_ENV;
  if (flushDenormals) {
#if defined(__arm64__)
    base = FE_DFL_DISABLE_DENORMS_ENV;
#elif defined(__x86_64__)
    base = FE_DFL_DISABLE_SSE_DENORMS_ENV;
#endif
  }
  check(std::fesetenv(base) == 0 && std::fesetround(rounding) == 0,
        "set rounding/denormal environment");
  check(std::feraiseexcept(FE_DIVBYZERO) == 0, "seed sticky exception flag");
}

void verifyEnvironment() {
  testSection = "complete per-job floating-point environment";
  CabinetWorker worker;
  check(worker.start(nullptr, kBlockLength / 48000.0), "start offline worker");
  for (bool flush : {false, true}) {
    for (int rounding : {FE_TONEAREST, FE_UPWARD, FE_DOWNWARD, FE_TOWARDZERO}) {
      setEnvironment(rounding, flush);
      std::fenv_t submitted{};
      check(std::fegetenv(&submitted) == 0, "capture submitted fenv");
      EnvironmentResult serial, parallel;
      environmentJob(&serial);
      check(std::fesetenv(&submitted) == 0, "restore submission fenv");
      check(worker.submit(environmentJob, &parallel), "submit fenv probe");
      check(std::fesetenv(FE_DFL_ENV) == 0, "change caller fenv after submit");
      std::fenv_t caller{}, after{};
      check(std::fegetenv(&caller) == 0, "capture caller fenv");
      worker.wait();
      check(std::fegetenv(&after) == 0 && sameEnvironment(caller, after),
            "wait preserves caller fenv");
      check(parallel.thread != serial.thread, "probe executes on worker thread");
      check(sameEnvironment(serial.entry, parallel.entry),
            "full fenv matches, including sticky flags and denormal controls");
      check(std::memcmp(serial.values.data(), parallel.values.data(),
                        sizeof(serial.values)) == 0,
            "rounding and subnormal arithmetic is bit-identical");
    }
  }
  worker.stop();
  check(std::fesetenv(FE_DFL_ENV) == 0, "restore default fenv");
  std::printf("PASS: full worker fenv equality in all four rounding modes, denormals on/off\n");
}

struct Calls {
  uint64_t caller = 0, worker = 0, frames = 0;
  size_t largest = 0;
  bool environmentMatches = true;
};

// Every graph is still created by Plugin::work's real loader. This decorator
// owns and forwards that graph, adding observation without replacing its DSP.
class ObservedModel final : public NeuralAudio::NeuralModel {
 public:
  ObservedModel(NeuralAudio::NeuralModel* model, Calls& calls,
                const std::fenv_t& expected, std::thread::id caller)
      : model_(model), calls_(calls), expected_(expected), caller_(caller) {}
  NeuralAudio::EModelLoadMode GetLoadMode() override { return model_->GetLoadMode(); }
  bool HasQualityScaling() override { return model_->HasQualityScaling(); }
  float GetQualityScaleFactor() override { return model_->GetQualityScaleFactor(); }
  bool IsQualityChangeRealtimeSafe(float v) override {
    return model_->IsQualityChangeRealtimeSafe(v);
  }
  void SetQualityScaleFactor(float v) override { model_->SetQualityScaleFactor(v); }
  bool IsStatic() override { return model_->IsStatic(); }
  void SetMaxAudioBufferSize(int v) override { model_->SetMaxAudioBufferSize(v); }
  void SetAudioInputLevelDBu(float v) override { model_->SetAudioInputLevelDBu(v); }
  float GetAudioInputLevelDBu() override { return model_->GetAudioInputLevelDBu(); }
  float GetRecommendedInputDBAdjustment() override {
    return model_->GetRecommendedInputDBAdjustment();
  }
  float GetRecommendedOutputDBAdjustment() override {
    return model_->GetRecommendedOutputDBAdjustment();
  }
  float GetSampleRate() override { return model_->GetSampleRate(); }
  int GetReceptiveFieldSize() override { return model_->GetReceptiveFieldSize(); }
  std::string GetModelVersion() override { return model_->GetModelVersion(); }
  std::string GetMetadata(const std::string& field) override {
    return model_->GetMetadata(field);
  }
  void Prewarm() override { model_->Prewarm(); }
  void Process(float* input, float* output, size_t count) override {
    if (std::this_thread::get_id() == caller_) ++calls_.caller;
    else ++calls_.worker;
    calls_.frames += count;
    calls_.largest = std::max(calls_.largest, count);
    std::fenv_t entry{};
    // A and B need identical control modes. Sticky flags can differ because A
    // runs before B serially, but after B's submission in the parallel path.
    calls_.environmentMatches &= std::fegetenv(&entry) == 0 &&
                                 sameEnvironment(entry, expected_, false);
    model_->Process(input, output, count);
  }

 private:
  std::unique_ptr<NeuralAudio::NeuralModel> model_;
  Calls& calls_;
  const std::fenv_t& expected_;
  std::thread::id caller_;
};

struct Host {
  struct Work {
    NAMRig::LV2WorkType type{};
    NAMRig::LV2LoadModelMsg load{};
    NAMRig::LV2FreeModelMsg free{};
  };
  std::vector<std::string> uris;
  std::deque<Work> jobs;
  std::deque<NAMRig::LV2SwitchModelMsg> replies;
  std::array<uint64_t, NAMRig::kStageCount> loads{}, responses{};
  uint64_t scheduledFrees = 0, completedFrees = 0;
  std::array<Calls, NAMRig::kStageCount> calls{};
  std::fenv_t expectedEnvironment{};
  bool inProcess = false, observe = true;
  int32_t maxBlock = kBlockLength;
  LV2_URID_Map map{this, mapUri};
  LV2_Worker_Schedule schedule{this, scheduleWork};
  alignas(8) std::array<uint8_t, kAtomBytes> control{}, notify{};
  std::array<float, kMaximum + 1> input{}, left{}, right{};
  std::array<float, Plugin::kPortCount> controls{};
  // Destroy the plugin before the queues and observation state it references.
  Plugin plugin;

  static LV2_URID mapUri(LV2_URID_Map_Handle handle, const char* uri) {
    auto& host = *static_cast<Host*>(handle);
    const auto found = std::find(host.uris.begin(), host.uris.end(), uri);
    if (found != host.uris.end())
      return static_cast<LV2_URID>(found - host.uris.begin() + 1);
    host.uris.emplace_back(uri);
    return static_cast<LV2_URID>(host.uris.size());
  }

  static LV2_Worker_Status scheduleWork(LV2_Worker_Schedule_Handle handle,
                                       uint32_t size, const void* data) {
    auto& host = *static_cast<Host*>(handle);
    check(data && size >= sizeof(NAMRig::LV2WorkType), "valid scheduled message");
    Work work;
    std::memcpy(&work.type, data, sizeof(work.type));
    if (work.type == NAMRig::kWorkTypeLoad) {
      check(size == sizeof(work.load), "load message size");
      std::memcpy(&work.load, data, size);
      const size_t stage = static_cast<size_t>(work.load.stage);
      check(stage < NAMRig::kStageCount, "load stage in range");
      // Pedal, Amp, Cab A, and Cab B all schedule requested oversample modes (none/True).
      check(std::find(kModes.begin(), kModes.end(),
                      work.load.oversampleMode) != kModes.end(),
            "all stages schedule requested none/True oversample modes");
      ++host.loads[stage];
    } else {
      check(work.type == NAMRig::kWorkTypeFree && size == sizeof(work.free),
            "free message type/size");
      std::memcpy(&work.free, data, size);
      ++host.scheduledFrees;
    }
    host.jobs.push_back(work); // Capture only: never load/free inside process().
    return LV2_WORKER_SUCCESS;
  }

  static LV2_Worker_Status respond(LV2_Worker_Respond_Handle handle,
                                  uint32_t size, const void* data) {
    auto& host = *static_cast<Host*>(handle);
    check(!host.inProcess && size == sizeof(NAMRig::LV2SwitchModelMsg),
          "real loader responds outside process");
    NAMRig::LV2SwitchModelMsg response;
    std::memcpy(&response, data, size);
    const size_t stage = static_cast<size_t>(response.stage);
    check(stage < NAMRig::kStageCount, "response stage in range");
    check(response.type == NAMRig::kWorkTypeSwitch, "switch response type");
    if (!response.path[0]) {
      check(!response.model && !response.ir && !response.irRight,
            "unload response owns no model or IR");
    } else if (std::filesystem::path(response.path).extension() == ".wav") {
      const unsigned channels = NAMRig::WavIR::channelCount(response.path);
      check(stage >= 2 && !response.model && response.ir &&
                (response.irRight != nullptr) == (channels == 2),
            "WAV response owns left IR and stereo right IR, not a NAM graph");
      check(!response.irRight || response.irRight != response.ir,
            "stereo WAV response owns independent channel convolvers");
    } else {
      check(response.model && !response.ir && !response.irRight,
            "NAM response owns a real graph, not an IR");
    }
    // A failed nonempty load must not silently turn this into a dry comparison.
    if (response.model && host.observe)
      response.model = new ObservedModel(response.model, host.calls[stage],
                                        host.expectedEnvironment,
                                        std::this_thread::get_id());
    ++host.responses[stage];
    host.replies.push_back(response);
    return LV2_WORKER_SUCCESS;
  }

  explicit Host(double rate, bool observed = true, bool connectPolarity = true) : observe(observed) {
    controls[6] = 1.0f;
    controls[7] = controls[8] = controls[9] = controls[47] = 1.0f;
    controls[15] = -80.0f;
    controls[17] = -1.0f;
    controls[20] = controls[21] = 6.0f;
    controls[23] = 150.0f;
    controls[27] = 20000.0f;
    controls[43] = controls[44] = 25.0f;
    controls[45] = controls[46] = 50.0f;
    controls[50] = 80.0f;
    controls[51] = 45.0f;
    controls[52] = 40.0f;
    controls[55] = controls[56] = controls[57] = 50.0f;
    controls[58] = 10.0f;
    std::copy(NAMRig::kTransformerControlDefaults.begin(), NAMRig::kTransformerControlDefaults.end(),
              controls.begin() + NAMRig::kTransformerControlFirstPort);
    std::copy(NAMRig::kRackControlDefaults.begin(), NAMRig::kRackControlDefaults.end(),
              controls.begin() + NAMRig::kRackControlFirstPort);
    controls[NAMRig::kPowerTubeCharacterPort] = NAMRig::kPowerTubeCharacterDefault;
    controls[NAMRig::kCompressorAttackPort] = NAMRig::kCompressorAttackDefault;
    controls[NAMRig::kCompressorReleasePort] = NAMRig::kCompressorReleaseDefault;
    controls[NAMRig::kCompressorEnabledPort] = 1.0f;
    controls[NAMRig::kOverdriveEnabledPort] = 1.0f;
    controls[NAMRig::kSpeakerProfileBPort] = NAMRig::kSpeakerProfileBDefault;
    controls[NAMRig::kCabLowCutSlopePort] = NAMRig::kCabLowCutSlopeDefault;
    controls[NAMRig::kCabHighCutSlopePort] = NAMRig::kCabHighCutSlopeDefault;
    // Connect the original fields explicitly; append arrays and tube controls below.
    plugin.ports = {
        sequence(control), sequence(notify), input.data(), left.data(),
        &controls[4], &controls[5], &controls[6], &controls[7], &controls[8],
        &controls[9], &controls[10], &controls[11], &controls[12], &controls[13],
        &controls[14], &controls[15], &controls[16], &controls[17], &controls[18],
        &controls[19], &controls[20], &controls[21], &controls[22], &controls[23],
        &controls[24], &controls[25], &controls[26], &controls[27], &controls[28],
        &controls[29], &controls[30], right.data(), &controls[32], &controls[33],
        &controls[34], &controls[35], &controls[36], &controls[37], &controls[38],
        &controls[39], &controls[40], &controls[41], &controls[42], &controls[43],
        &controls[44], &controls[45], &controls[46], &controls[47], &controls[48],
        &controls[49], &controls[50], &controls[51], &controls[52], &controls[53],
        &controls[54], &controls[55], &controls[56], &controls[57], &controls[58],
        &controls[59]};
    for (size_t i = 0; i < NAMRig::kTransformerControlCount; ++i)
      plugin.ports.transformer_adjustments[i] = &controls[NAMRig::kTransformerControlFirstPort + i];
    for (size_t i = 0; i < NAMRig::kRackCount; ++i)
      plugin.ports.rack_enabled[i] = &controls[NAMRig::kRackControlFirstPort + i];
    plugin.ports.power_tube_type = &controls[NAMRig::kPowerTubeTypePort];
    plugin.ports.power_tube_character = &controls[NAMRig::kPowerTubeCharacterPort];
    plugin.ports.mid_push = &controls[NAMRig::kMidPushPort];
    for (size_t i = 0; i < NAMRig::kPinEqPortCount; ++i)
      plugin.ports.pin_eq[i] = &controls[NAMRig::kPinEqFirstPort + i];
    plugin.ports.od_drive = &controls[NAMRig::kOverdriveDrivePort];
    plugin.ports.od_tone = &controls[NAMRig::kOverdriveTonePort];
    plugin.ports.od_level = &controls[NAMRig::kOverdriveLevelPort];
    plugin.ports.compressor_attack = &controls[NAMRig::kCompressorAttackPort];
    plugin.ports.compressor_release = &controls[NAMRig::kCompressorReleasePort];
    plugin.ports.compressor_enabled = &controls[NAMRig::kCompressorEnabledPort];
    plugin.ports.od_enabled = &controls[NAMRig::kOverdriveEnabledPort];
    plugin.ports.post_compressor = &controls[NAMRig::kPostCompressorAmountPort];
    plugin.ports.post_compressor_attack = &controls[NAMRig::kPostCompressorAttackPort];
    plugin.ports.post_compressor_release = &controls[NAMRig::kPostCompressorReleasePort];
    plugin.ports.post_compressor_enabled = &controls[NAMRig::kPostCompressorEnabledPort];
    plugin.ports.od_tight = &controls[NAMRig::kOverdriveTightPort];
    plugin.ports.od_voicing = &controls[NAMRig::kOverdriveVoicingPort];
    plugin.ports.output_ceiling = &controls[NAMRig::kOutputCeilingPort];
    plugin.ports.output_balance = &controls[NAMRig::kOutputBalancePort];
    plugin.ports.output_reduction = &controls[NAMRig::kOutputReductionPort];
    plugin.ports.pedal2_enabled = &controls[NAMRig::kPedal2EnabledPort];
    plugin.ports.pedal3_enabled = &controls[NAMRig::kPedal3EnabledPort];
    plugin.ports.pedal_order = &controls[NAMRig::kPedalOrderPort];
    for (size_t i = 0; i < NAMRig::kToneEqControlCount; ++i)
      plugin.ports.tone_eq[i] = &controls[NAMRig::kToneEqModePort + i];
    plugin.ports.drop_pitch = &controls[NAMRig::kDropPitchPort];
    plugin.ports.model_band_limit = &controls[NAMRig::kModelBandLimitPort];
    plugin.ports.drop_pitch_attack = &controls[NAMRig::kDropPitchAttackPort];
    plugin.ports.drop_pitch_sustain = &controls[NAMRig::kDropPitchSustainPort];
    plugin.ports.model_band_limit_cutoff = &controls[NAMRig::kModelBandLimitCutoffPort];
    plugin.ports.model_band_limit_slope = &controls[NAMRig::kModelBandLimitSlopePort];
    plugin.ports.model_band_limit_ripple = &controls[NAMRig::kModelBandLimitRipplePort];
    plugin.ports.spatial_center_blend = &controls[NAMRig::kSpatialCenterBlendPort];
    plugin.ports.speaker_profile_b = &controls[NAMRig::kSpeakerProfileBPort];
    plugin.ports.cab_low_cut_slope = &controls[NAMRig::kCabLowCutSlopePort];
    plugin.ports.cab_high_cut_slope = &controls[NAMRig::kCabHighCutSlopePort];
    static_assert(Plugin::kPortCount == 238, "update connections if ports change");
    if (!connectPolarity) plugin.ports.cab2_polarity = nullptr;
    LV2_Options_Option options[] = {
        {LV2_OPTIONS_INSTANCE, 0, mapUri(this, LV2_BUF_SIZE__maxBlockLength),
         sizeof(maxBlock), mapUri(this, LV2_ATOM__Int), &maxBlock}, {}};
    LV2_Feature mapFeature{LV2_URID__map, &map};
    LV2_Feature scheduleFeature{LV2_WORKER__schedule, &schedule};
    LV2_Feature optionsFeature{LV2_OPTIONS__options, options};
    const LV2_Feature* features[]{&mapFeature, &scheduleFeature, &optionsFeature, nullptr};
    check(plugin.initialize(rate, features), "initialize real Plugin with LV2 features");
    for (auto& loader : plugin.loaders)
      check(loader.GetDefaultMaxAudioBufferSize() == kBlockLength,
            "maxBlockLength=128 option reaches every loader");
    clearControl();
  }

  static LV2_Atom_Sequence* sequence(std::array<uint8_t, kAtomBytes>& bytes) {
    return reinterpret_cast<LV2_Atom_Sequence*>(bytes.data());
  }

  void clearControl() {
    control.fill(0);
    sequence(control)->atom.type = mapUri(this, LV2_ATOM__Sequence);
    sequence(control)->atom.size = sizeof(LV2_Atom_Sequence_Body);
  }

  void paths(const std::vector<std::pair<Stage, std::string>>& requests) {
    clearControl();
    LV2_Atom_Forge forge{};
    lv2_atom_forge_init(&forge, &map);
    lv2_atom_forge_set_buffer(&forge, control.data(), control.size());
    LV2_Atom_Forge_Frame frame{};
    check(lv2_atom_forge_sequence_head(&forge, &frame, 0) != 0, "forge control sequence");
    for (const auto& request : requests) {
      check(request.second.size() + 1 < NAMRig::MAX_FILE_NAME, "fixture path fits atom");
      LV2_Atom_Forge_Frame object{};
      lv2_atom_forge_frame_time(&forge, 0);
      lv2_atom_forge_object(&forge, &object, 0, mapUri(this, LV2_PATCH__Set));
      lv2_atom_forge_key(&forge, mapUri(this, LV2_PATCH__property));
      lv2_atom_forge_urid(&forge, mapUri(this, kStageUris[static_cast<size_t>(request.first)]));
      lv2_atom_forge_key(&forge, mapUri(this, LV2_PATCH__value));
      check(lv2_atom_forge_path(&forge, request.second.c_str(),
                               static_cast<uint32_t>(request.second.size() + 1)) != 0,
            "forge model path");
      lv2_atom_forge_pop(&forge, &object);
    }
    lv2_atom_forge_pop(&forge, &frame);
  }

  void drain() {
    check(!inProcess, "queue drains outside process only");
    unsigned operations = 0;
    while (!jobs.empty() || !replies.empty()) {
      while (!jobs.empty()) {
        check(++operations <= 64, "bounded work drain (possible Cab2 reschedule loop)");
        Work work = jobs.front();
        jobs.pop_front();
        const bool load = work.type == NAMRig::kWorkTypeLoad;
        check(Plugin::work(&plugin, respond, this,
                          load ? sizeof(work.load) : sizeof(work.free),
                          load ? static_cast<const void*>(&work.load)
                               : static_cast<const void*>(&work.free)) == LV2_WORKER_SUCCESS,
              "Plugin::work succeeds");
        if (load) {
          check(!replies.empty() &&
                    std::strcmp(replies.back().path, work.load.path) == 0,
                "real loader returns the requested path (not a silent load failure)");
        } else ++completedFrees;
      }
      while (!replies.empty()) {
        check(++operations <= 64, "bounded response drain (possible Cab2 reschedule loop)");
        const auto response = replies.front();
        replies.pop_front();
        check(Plugin::workResponse(&plugin, sizeof(response), &response) ==
                  LV2_WORKER_SUCCESS, "Plugin::workResponse succeeds");
      }
    }
    check(scheduledFrees == completedFrees, "all scheduled frees executed");
  }

  double run(uint32_t count, const std::fenv_t& environment,
             uint64_t cabinetDeadlineTicks = 0) {
    notify.fill(0);
    sequence(notify)->atom.size = notify.size() - sizeof(LV2_Atom);
    left.fill(std::numeric_limits<float>::quiet_NaN());
    right.fill(std::numeric_limits<float>::quiet_NaN());
    expectedEnvironment = environment;
    check(std::fesetenv(&environment) == 0, "restore identical process-entry fenv");
    inProcess = true;
    const auto begin = std::chrono::steady_clock::now();
    plugin.process(count, cabinetDeadlineTicks);
    const auto end = std::chrono::steady_clock::now();
    inProcess = false;
    check(std::isnan(left[count]) && std::isnan(right[count]), "output buffer guards intact");
    check(sequence(notify)->atom.size <= notify.size() - sizeof(LV2_Atom),
          "notify atom fits buffer");
    clearControl();
    return std::chrono::duration<double>(end - begin).count();
  }
};

struct Pair {
  Host serial, parallel;
  CabinetWorker worker;
  double time = 0.0, serialSeconds = 0.0, parallelSeconds = 0.0;
  uint32_t noise = 0x715acafeu;
  uint64_t blocks = 0;

  explicit Pair(double rate, bool observe = true, bool connectPolarity = true)
      : serial(rate, observe, connectPolarity), parallel(rate, observe, connectPolarity) {
    check(worker.start(nullptr, kBlockLength / rate), "start null-group offline worker");
    parallel.plugin.setCabinetWorker(&worker);
  }
  ~Pair() {
    parallel.plugin.setCabinetWorker(nullptr);
    worker.stop();
    serial.drain();
    parallel.drain();
  }
  void set(size_t port, float value) {
    serial.controls.at(port) = parallel.controls.at(port) = value;
  }
  void paths(const std::vector<std::pair<Stage, std::string>>& requests) {
    serial.paths(requests);
    parallel.paths(requests);
  }
  void drain() {
    check(serial.jobs.size() == parallel.jobs.size(), "same scheduled queue length");
    for (size_t i = 0; i < serial.jobs.size(); ++i) {
      const auto& a = serial.jobs[i];
      const auto& b = parallel.jobs[i];
      check(a.type == b.type, "same scheduled message type");
      if (a.type == NAMRig::kWorkTypeLoad)
        check(a.load.stage == b.load.stage && a.load.generation == b.load.generation &&
                  a.load.oversampleMode == b.load.oversampleMode &&
                  std::strcmp(a.load.path, b.load.path) == 0,
              "identical scheduled stage/path/mode/generation");
    }
    serial.drain();
    parallel.drain();
    check(serial.loads == parallel.loads && serial.responses == parallel.responses &&
              serial.completedFrees == parallel.completedFrees,
          "deterministic load/response/free accounting");
  }
  double run(uint32_t count, bool silence = false, bool drainWork = true,
             uint64_t cabinetDeadlineTicks = 0) {
    check(count > 0 && count <= kMaximum, "block count in harness range");
    for (uint32_t i = 0; i < count; ++i) {
      noise = noise * 1664525u + 1013904227u;
      const double random = static_cast<double>(noise >> 8) / 16777216.0 - 0.5;
      const float sample = silence ? 0.0f : static_cast<float>(
          0.17 * std::sin(6.283185307179586 * 173.0 * time) +
          0.09 * std::sin(6.283185307179586 * 997.0 * time) + 0.03 * random);
      serial.input[i] = parallel.input[i] = sample;
      time += 1.0 / serial.plugin.sampleRate;
    }
    return runControl(count, drainWork, cabinetDeadlineTicks);
  }
  double runControl(uint32_t count, bool drainWork = true,
                    uint64_t cabinetDeadlineTicks = 0) {
    check(count > 0 && count <= kMaximum, "block count in harness range");
    std::fenv_t entry{};
    check(std::fegetenv(&entry) == 0, "capture common block-entry fenv");
    // Alternate order to avoid consistently favoring one path in optional timing.
    if (blocks % 2 == 0) {
      serialSeconds += serial.run(count, entry, cabinetDeadlineTicks);
      parallelSeconds += parallel.run(count, entry, cabinetDeadlineTicks);
    } else {
      parallelSeconds += parallel.run(count, entry, cabinetDeadlineTicks);
      serialSeconds += serial.run(count, entry, cabinetDeadlineTicks);
    }
    double energy = 0.0;
    for (uint32_t i = 0; i < count; ++i) {
      for (bool right : {false, true}) {
        const float a = right ? serial.right[i] : serial.left[i];
        const float b = right ? parallel.right[i] : parallel.left[i];
        if (!std::isfinite(a) || !std::isfinite(b) || std::memcmp(&a, &b, sizeof(a))) {
          std::fprintf(stderr, "FAIL [%s]: block=%llu count=%u sample=%u %s serial=%a worker=%a\n",
                       testSection.c_str(), static_cast<unsigned long long>(blocks), count, i,
                       right ? "R" : "L", static_cast<double>(a), static_cast<double>(b));
          std::exit(1);
        }
        energy += static_cast<double>(a) * a;
      }
    }
    for (size_t port : {11u, 17u, 18u, 29u})
      check(std::memcmp(&serial.controls[port], &parallel.controls[port], sizeof(float)) == 0,
            "bit-identical output control ports, including latency");
    const size_t notifySize = Host::sequence(serial.notify)->atom.size + sizeof(LV2_Atom);
    check(notifySize == Host::sequence(parallel.notify)->atom.size + sizeof(LV2_Atom) &&
              std::memcmp(serial.notify.data(), parallel.notify.data(), notifySize) == 0,
          "bit-identical notify atoms");
    for (size_t stage = 0; stage < NAMRig::kStageCount; ++stage) {
      check(serial.calls[stage].environmentMatches && parallel.calls[stage].environmentMatches,
            "real model entry rounding/denormal controls match caller");
      check(serial.calls[stage].worker == 0, "sequential models never execute off caller");
      check(serial.calls[stage].frames == parallel.calls[stage].frames &&
                serial.calls[stage].caller == parallel.calls[stage].caller +
                                                  parallel.calls[stage].worker,
            "each real graph processes identical frames and call counts");
      check(serial.calls[stage].largest <= static_cast<size_t>(16 * kBlockLength) &&
                parallel.calls[stage].largest <= static_cast<size_t>(16 * kBlockLength),
            "model calls stay within allocated worst-case True-domain buffers");
      if (stage != 3)
        check(parallel.calls[stage].worker == 0, "only Cab B may execute off caller");
    }
    ++blocks;
    checkedFrames += count;
    if (drainWork) drain();
    return energy;
  }
  double sweep(unsigned cycles = 1, bool silence = false) {
    double energy = 0.0;
    for (unsigned cycle = 0; cycle < cycles; ++cycle)
      for (uint32_t count : kCounts) energy += run(count, silence);
    return energy;
  }
  void installed(Stage stage, const std::string& path, unsigned irChannels = 0) {
    const size_t index = static_cast<size_t>(stage);
    for (Host* host : {&serial, &parallel}) {
      check(host->plugin.modelPaths[index] == path, "committed model path matches request");
      check((host->plugin.models[index] != nullptr) == (!path.empty() && !irChannels),
            "real NAM graph installed or cleared for WAV/unload");
      check((host->plugin.irs[index] != nullptr) == (irChannels != 0) &&
                (host->plugin.irsRight[index] != nullptr) == (irChannels == 2),
            "committed mono/stereo IR pointers match requested fixture");
    }
    if (irChannels) {
      check(serial.plugin.irs[index] != parallel.plugin.irs[index],
            "instances own separate left IR convolvers");
      if (irChannels == 2)
        check(serial.plugin.irsRight[index] != parallel.plugin.irsRight[index],
              "instances own separate right IR convolvers");
    } else if (!path.empty())
      check(serial.plugin.models[index] != parallel.plugin.models[index],
            "instances own separate real model graphs");
  }
  // nativeA/nativeB describe the cabinet models: 0 = rate-adaptable WaveNet,
  // 1 = non-adaptable model at the session rate, 2/4/8 = non-adaptable model
  // decimated into its native-rate domain.
  void steady(bool cabA, bool cabB, bool dispatch, int factor, int nativeA = 0, int nativeB = 0) {
    sweep(2); // Both 5 ms transition phases finish, including at 96 kHz.
    const auto a = parallel.calls[2], b = parallel.calls[3];
    const uint64_t framesBefore = checkedFrames;
    const double energy = sweep();
    const uint64_t frames = checkedFrames - framesBefore;
    const bool namA = cabA && parallel.plugin.models[2];
    const bool namB = cabB && parallel.plugin.models[3];
    // A decimated domain emits floor-divided counts; a block boundary may move
    // one sample between measurement windows.
    const auto nativeFrames = [&](uint64_t processed, int native) {
      const uint64_t expected = frames / static_cast<uint64_t>(native);
      return processed + 1 >= expected && processed <= expected + 1;
    };
    const uint64_t framesA = parallel.calls[2].frames - a.frames;
    if (!namA) check(framesA == 0, "a bypassed or WAV Cab A runs no graph");
    else if (nativeA >= 2) check(nativeFrames(framesA, nativeA), "a native-rate Cab A processes its decimated frames");
    else if (nativeA == 1) check(framesA == frames, "a non-adaptable 1x Cab A processes exactly session-rate frames");
    else check(framesA == frames * factor, "an active rate-adaptable Cab A processes exactly its amp-following True domain");
    const uint64_t framesB = parallel.calls[3].frames - b.frames;
    if (!namB) check(framesB == 0, "a bypassed or WAV Cab B runs no graph");
    else if (nativeB >= 2) check(nativeFrames(framesB, nativeB), "a native-rate Cab B processes its decimated frames");
    else if (nativeB == 1) check(framesB == frames, "a non-adaptable 1x Cab B processes exactly session-rate frames");
    else check(framesB == frames * factor, "an active rate-adaptable Cab B processes exactly its amp-following True domain");
    const uint64_t dispatched = parallel.calls[3].worker - b.worker;
    const uint64_t callerB = parallel.calls[3].caller - b.caller;
    uint64_t slices = 0, singles = 0;
    for (uint32_t count : kCounts) {
      slices += (count + parallel.maxBlock - 1) / parallel.maxBlock;
      if (count % parallel.maxBlock == 1) ++singles;
    }
    // A one-frame slice may emit no decimated sample, so a native-rate Cab B
    // graph is not entered on every slice; every slice still dispatches.
    const auto perSlice = [&](uint64_t calls) {
      return nativeB >= 2 ? calls <= slices && calls + singles >= slices : calls == slices;
    };
    check(dispatch ? perSlice(dispatched) && callerB == 0 : dispatched == 0,
          "one worker call per dual-NAM slice; bypass/fallback remains serial");
    if (namB && !dispatch)
      check(perSlice(callerB), "serial Cab B fallback processes once per session-rate slice");
    workerCalls += dispatched;
    check(energy > 0.0, "comparison exercises nonzero output");
  }
  void reconfigure(double rate) {
    // No process or job is in flight while changing the executor/device period.
    worker.stop();
    serial.plugin.setSampleRateAndReload(rate);
    parallel.plugin.setSampleRateAndReload(rate);
    drain();
    check(worker.start(nullptr, kBlockLength / rate), "restart worker at new device period");
    sweep(3);
  }
};

int pipelineFactor(int mode, double rate) {
  if (mode == 0) return 1;
  // True modes target 96 kHz * N, not host-rate * N; the cascade caps at 16.
  const double wanted = 96000.0 * (1 << (mode - 3)) / rate;
  return wanted < 1.5 ? 1 : wanted < 3.0 ? 2 : wanted < 6.0 ? 4 : wanted < 12.0 ? 8 : 16;
}

// Keep legacy helper signatures unused without triggering -Wunused-function.
[[maybe_unused]] int nativeDecimation(double rate) { return rate == 96000.0 ? 2 : 1; }
[[maybe_unused]] float nativeHold(double rate) { return rate == 96000.0 ? 47.0f : 0.0f; }

void verifyMulticoreModels(const std::string& standard, const std::string& a2,
                           const std::string& lstm) {
  testSection = "96 kHz raw multicore model integration";
  Pair pair(96000.0, false); // Decorators would hide PolyphaseModel from the pool.
  struct ScopedPool {
    Plugin& plugin;
    NAMRig::PolyphaseWorker pool;
    ~ScopedPool() {
      plugin.setPolyphaseWorker(nullptr);
      pool.stop();
    }
  } executor{pair.parallel.plugin}; // Destroy before Pair, including on exceptions.
  check(executor.pool.start(nullptr, kBlockLength / 96000.0, 3) &&
            executor.pool.helperCount() == 3,
        "start three null-workgroup offline phase helpers alongside cabinet worker");
  pair.parallel.plugin.setPolyphaseWorker(&executor.pool);

  auto verifyGraph = [&](Stage stage, const std::string& path, size_t phases) {
    pair.installed(stage, path);
    for (Host* host : {&pair.serial, &pair.parallel}) {
      auto* model = host->plugin.models[static_cast<size_t>(stage)];
      if (path == a2)
        check(dynamic_cast<NeuralAudio::CompositeModel*>(model) &&
                  model->HasQualityScaling() && model->GetQualityScaleFactor() == 1.0f,
              "packed A2 installs its full-quality raw composite graph");
      while (auto* composite = dynamic_cast<NeuralAudio::CompositeModel*>(model))
        model = composite->GetCurrentModel();
      check(model != nullptr, "raw graph has an active model");
      auto* poly = dynamic_cast<NeuralAudio::PolyphaseModel*>(model);
      check(phases > 1 ? poly && poly->GetNumPhases() == phases : !poly,
            "raw graph has expected native-rate phases or non-polyphase fallback");
    }
  };
  auto latency = [](int mode) {
    const int factor = pipelineFactor(mode, 96000.0);
    return factor == 2 ? 23.0f : factor == 4 ? 35.0f : factor == 8 ? 41.0f
         : factor == 16 ? 44.0f : 0.0f;
  };
  pair.set(47, 0);
  pair.paths({{Stage::Pedal, standard}, {Stage::Amp, a2},
              {Stage::Cab, standard}, {Stage::Cab2, a2}});
  for (int mode : kModes) {
    testSection = "96 kHz multicore grouped/dual NAM mode " + std::to_string(mode);
    pair.set(20, static_cast<float>(mode));
    pair.set(21, static_cast<float>(mode));
    const size_t phases = mode == 0 ? 1 : 2 * pipelineFactor(mode, 96000.0);
    // True8 is a 768 kHz domain here: sixteen phases for these 48 kHz models.
    check(mode != 6 || phases == 16, "96 kHz True8 loads sixteen native-rate phases");
    const auto cabBLoads = pair.serial.loads[3];
    for (bool dual : {false, true}) {
      pair.set(47, dual ? 1 : 0);
      check(pair.sweep(3) > 0.0, "raw multicore comparison exercises nonzero output");
      verifyGraph(Stage::Pedal, standard, phases);
      verifyGraph(Stage::Amp, a2, phases);
      verifyGraph(Stage::Cab, standard, phases);
      verifyGraph(Stage::Cab2, a2, phases);
      check(pair.serial.controls[29] == (dual ? 2.0f : 1.0f) * latency(mode),
            "grouped serial or parallel True-cab latency is exact");
    }
    check(pair.serial.loads[3] == cabBLoads + 1,
          "Cab B graph loads at initialization and reloads on each True oversample change");
  }

  for (auto modes : {std::array<int, 2>{0, 6}, {4, 5}, {6, 4}}) {
    testSection = "96 kHz multicore differing pedal/amp modes " +
                  std::to_string(modes[0]) + "/" + std::to_string(modes[1]);
    pair.set(20, static_cast<float>(modes[0]));
    pair.set(21, static_cast<float>(modes[1]));
    for (bool dual : {false, true}) {
      pair.set(47, dual ? 1 : 0);
      pair.sweep(3);
      verifyGraph(Stage::Pedal, standard,
                  modes[0] == 0 ? 1 : 2 * pipelineFactor(modes[0], 96000.0));
      verifyGraph(Stage::Amp, a2, 2 * pipelineFactor(modes[1], 96000.0));
      verifyGraph(Stage::Cab, standard, 2 * pipelineFactor(modes[1], 96000.0));
      verifyGraph(Stage::Cab2, a2, 2 * pipelineFactor(modes[1], 96000.0));
      check(pair.serial.controls[29] == latency(modes[0]) + (dual ? 2.0f : 1.0f) * latency(modes[1]),
            "differing True domains retain exact summed converter latency");
    }
  }

  testSection = "96 kHz multicore bypass topology and model swaps";
  pair.set(20, 6); pair.set(21, 6);
  // Exercise the newly eligible 16-native-sample phase blocks in real rig
  // converters/graphs, including a negotiated 32-frame maximum and expiry.
  for (int block : {32, 64}) {
    for (Host* host : {&pair.serial, &pair.parallel}) {
      host->plugin.setMaxBufferSize(block);
      host->maxBlock = block;
    }
    for (unsigned i = 0; i < 48; ++i)
      pair.run(static_cast<uint32_t>(block), false, true,
               i % 3 == 0 ? mach_absolute_time() : 0);
    check(pair.serial.controls[29] == 82.0f, "32/64-frame phase dispatch preserves dual True8 latency");
  }
  for (Host* host : {&pair.serial, &pair.parallel}) {
    host->plugin.setMaxBufferSize(kBlockLength);
    host->maxBlock = kBlockLength;
  }
  for (size_t port : {7u, 8u, 9u, 47u}) {
    pair.set(port, 0);
    pair.sweep(3);
    check(pair.serial.controls[29] == (port == 47u ? 41.0f : 82.0f),
          "pedal/amp/cab bypass switches preserve exact True8 topology latency");
    pair.set(port, 1);
    pair.sweep(3);
    check(pair.serial.controls[29] == 82.0f, "dual NAM topology restored after bypass");
  }
  for (const auto& path : {a2, standard, lstm, standard}) {
    pair.paths({{Stage::Pedal, path}, {Stage::Amp, path},
                {Stage::Cab, path}, {Stage::Cab2, path}});
    check(pair.sweep(3) > 0.0, "swapped raw models produce nonzero exact output");
    for (Stage stage : {Stage::Pedal, Stage::Amp, Stage::Cab, Stage::Cab2})
      verifyGraph(stage, path, path == lstm ? 1 : 16);
  }
  executor.pool.stop();
  pair.sweep(); // Attached but stopped pool falls back without resetting graphs.
  check(executor.pool.start(nullptr, kBlockLength / 96000.0, 3), "restart phase pool");
  pair.sweep();
  pair.parallel.plugin.setPolyphaseWorker(nullptr);
  pair.sweep(); // Existing cabinet executor remains attached throughout.
  std::printf("PASS: 96 kHz raw multicore standard/A2/LSTM graphs; grouped/dual NAM, True8 sixteen phases, mixed modes, bypass/swaps, irregular/oversized blocks, exact audio/atoms/latency, phase pool stop/restart/detach\n");
}

void verifyPlugins(double rate, const std::string& wave, const std::string& lstm) {
  testSection = "initial real loads at " + std::to_string(static_cast<int>(rate)) + " Hz";
  Pair pair(rate);
  pair.paths({{Stage::Pedal, wave}, {Stage::Amp, lstm}, {Stage::Cab, wave}, {Stage::Cab2, lstm}});
  pair.run(17);
  check(pair.serial.loads[3] == 1 && pair.serial.responses[3] == 1,
        "Cab2 initial response accepted without a rescheduled load");
  pair.sweep(3);
  for (Stage stage : {Stage::Pedal, Stage::Amp, Stage::Cab, Stage::Cab2})
    pair.installed(stage, stage == Stage::Pedal || stage == Stage::Cab ? wave : lstm);
  check(pair.serial.loads[3] == 1, "stage 3 installs instead of endlessly rescheduling");
  std::printf("PASS: %.0f Hz real stage 0/1/2/3 loads, independent graphs, Cab2 installs once\n", rate);

  mach_timebase_info_data_t timebase{};
  check(mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.numer && timebase.denom,
        "query deadline Mach timebase");
  const uint64_t futureWindow = UINT64_C(60000000000) * timebase.denom / timebase.numer;

  // The LSTM amp and Cab B join the phase-split True domain in True modes
  // (native = 0, frames * factor) and run at the session rate at mode 0.
  const int native = 0;
  for (int mode : kModes) {
    const int factor = pipelineFactor(mode, rate);
    testSection = std::to_string(static_cast<int>(rate)) + " Hz mode " + std::to_string(mode);
    const uint64_t cabBLoads = pair.serial.loads[3];
    pair.set(20, static_cast<float>(mode));
    pair.set(21, static_cast<float>(mode));
    pair.set(9, 1); pair.set(47, 1);
    pair.set(25, 0); pair.set(48, 0); pair.set(32, 0); pair.set(49, 0);
    pair.set(53, 0); pair.set(54, 0); pair.set(33, 0); pair.set(59, 0);
    pair.steady(true, true, true, factor, 0, native);
    check(pair.serial.loads[3] == cabBLoads + 1, "amp_oversample changes reload Cab B to follow cabinet oversampling");
    const int latency = factor == 2 ? 23 : factor == 4 ? 35 : factor == 8 ? 41
                      : factor == 16 ? 44 : 0;
    // Pedal + phase-split LSTM amp merge into one True cascade + parallel Cab A/B cascade.
    const float expectedLatency = static_cast<float>(latency) * 2.0f;
    check(pair.serial.controls[29] == expectedLatency,
          "latency sums the merged Pedal+Amp cascade and parallel Cab A/B cascade");

    for (bool future : {false, true}) {
      for (uint32_t count : kCounts) {
        const Calls before = pair.parallel.calls[3];
        const uint64_t now = mach_absolute_time();
        check(now > 1, "expired deadline remains nonzero");
        pair.run(count, false, true, future ? now + futureWindow : now - 1);
        const auto& after = pair.parallel.calls[3];
        const uint64_t slices = (count + kBlockLength - 1) / kBlockLength;
        const uint64_t singles = count % kBlockLength == 1 ? 1 : 0;
        const uint64_t framesB = after.frames - before.frames;
        const uint64_t expectedB = native >= 2
            ? count / static_cast<uint64_t>(native)
            : count * static_cast<uint64_t>(factor);
        check(native < 2 ? framesB == count * static_cast<uint64_t>(factor)
                         : framesB + 1 >= expectedB && framesB <= expectedB + 1,
              "deadline branch processes Cab B's domain frames exactly once");
        const uint64_t worker = after.worker - before.worker;
        const uint64_t caller = after.caller - before.caller;
        const auto perSlice = [&](uint64_t calls) {
          return native >= 2 ? calls <= slices && calls + singles >= slices : calls == slices;
        };
        check(future ? perSlice(worker) && caller == 0 : worker == 0 && perSlice(caller),
              "expired deadline forces caller fallback; future deadline dispatches every slice");
        workerCalls += worker;
      }
    }

    pair.set(32, 100); pair.set(49, 7.25f);
    pair.set(25, -6); pair.set(48, -3);
    pair.steady(true, true, true, factor, 0, native);
    check(std::memcmp(pair.serial.left.data(), pair.serial.right.data(),
                      kCounts.back() * sizeof(float)) != 0,
          "width/alignment exercise distinct stereo output");
    for (float alignment : {-10.0f, -7.25f, 0.0f, 10.0f}) {
      for (float polarity : {1.0f, 0.0f}) {
        pair.set(49, alignment); pair.set(59, polarity);
        pair.steady(true, true, true, factor, 0, native);
        check(pair.serial.controls[29] == expectedLatency,
              "signed user alignment/polarity do not change reported pipeline latency");
      }
    }
    for (auto trims : {std::array<float, 2>{-24, -3}, {-6, -24}, {-24, -24}}) {
      pair.set(25, trims[0]); pair.set(48, trims[1]);
      pair.steady(true, true, true, factor, 0, native);
    }
    pair.set(25, 0); pair.set(48, 0);
    pair.set(9, 0);
    pair.steady(false, true, false, factor, 0, native);
    pair.set(9, 1); pair.set(47, 0);
    pair.steady(true, false, false, factor, 0, native);
    pair.set(47, 1);
    pair.steady(true, true, true, factor, 0, native);
    std::printf("PASS: %.0f Hz Cab A mode %d (effective %dx alone, session rate beside Cab B), native-rate LSTM Cab B; counts 1/17/64/127/128/256/513; expired/future deadlines, dual/A-only/B-only, width, align, mute trims\n",
                rate, mode, factor);
  }

  testSection = "Plugin output under all rounding/denormal environments";
  for (bool flush : {false, true})
    for (int rounding : {FE_TONEAREST, FE_UPWARD, FE_DOWNWARD, FE_TOWARDZERO}) {
      setEnvironment(rounding, flush);
      pair.sweep();
    }
  check(std::fesetenv(FE_DFL_ENV) == 0, "reset fenv after Plugin matrix");
  std::printf("PASS: %.0f Hz real Plugin bit equality in eight floating-point environments\n", rate);

  testSection = "stopped executor fallback and buffer reconfiguration";
  pair.worker.stop();
  pair.steady(true, true, false, pipelineFactor(6, rate), 0, native);
  check(pair.worker.start(nullptr, kBlockLength / rate), "restart stopped executor");
  for (int block : {64, 128}) {
    pair.serial.plugin.setMaxBufferSize(block);
    pair.parallel.plugin.setMaxBufferSize(block);
    pair.serial.maxBlock = pair.parallel.maxBlock = block;
    pair.steady(true, true, true, pipelineFactor(6, rate), 0, native);
  }

  testSection = "in-flight Cab B swaps and stale-generation disposal";
  const uint64_t beforeSwap = pair.serial.loads[3];
  pair.paths({{Stage::Cab2, wave}});
  pair.run(64, false, false);
  pair.paths({{Stage::Cab2, lstm}});
  pair.run(127, false, false);
  pair.drain();
  pair.sweep(3);
  pair.installed(Stage::Cab2, lstm);
  check(pair.serial.loads[3] == beforeSwap + 2, "stale Cab2 response frees, never reschedules");
  pair.paths({{Stage::Cab, lstm}, {Stage::Cab2, wave}});
  pair.run(256);
  pair.steady(true, true, true, pipelineFactor(6, rate), native, 0);
  pair.installed(Stage::Cab, lstm);
  pair.installed(Stage::Cab2, wave);

  testSection = "Cab unload/reload and mode change with initial load in flight";
  pair.paths({{Stage::Cab2, ""}});
  pair.run(513);
  pair.steady(true, false, false, pipelineFactor(6, rate), native, 0);
  pair.installed(Stage::Cab2, "");
  pair.paths({{Stage::Cab2, wave}, {Stage::Cab, ""}});
  pair.run(128);
  pair.steady(false, true, false, pipelineFactor(6, rate), native, 0);
  pair.installed(Stage::Cab, "");
  const uint64_t beforeLoad = pair.serial.loads[2];
  pair.paths({{Stage::Cab, lstm}});
  pair.run(17, false, false);
  pair.set(20, 4); pair.set(21, 4);
  pair.run(64, false, false);
  pair.drain();
  pair.steady(true, true, true, pipelineFactor(4, rate), native, 0);
  pair.installed(Stage::Cab, lstm);
  // Under 6C, changing oversample modes while an in-flight load used the old mode schedules one reload.
  check(pair.serial.loads[2] == beforeLoad + 2,
        "in-flight Cab A load at old oversample mode reloads once for new True mode");

  testSection = "sample-rate reload and worker restart";
  for (double newRate : {rate == 48000.0 ? 96000.0 : 48000.0, rate}) {
    const auto before = pair.serial.loads;
    pair.reconfigure(newRate);
    for (size_t stage = 0; stage < NAMRig::kStageCount; ++stage)
      check(pair.serial.loads[stage] == before[stage] + (stage < 4 ? 1 : 0),
            "sample-rate reconfiguration reloads installed paths and leaves empty pedal slots alone");
    pair.installed(Stage::Cab, lstm);
    pair.installed(Stage::Cab2, wave);
    pair.steady(true, true, true, pipelineFactor(4, newRate), 0, 0);
  }
  std::printf("PASS: %.0f Hz worker fallback/restart, 64/128 buffer sizing, swaps, stale responses, unloads, in-flight True change, rate reloads\n", rate);

  testSection = "delay/reverb tails through model unload and silence";
  pair.set(53, 48); pair.set(54, 42); pair.set(33, 25);
  pair.set(50, 55); pair.set(51, 65); pair.set(55, 72);
  pair.sweep(5);
  // Remove every graph so sustained silent-input energy can only be FX/DC
  // history, not a recurrent model's DC output. No executor job survives unload.
  pair.paths({{Stage::Pedal, ""}, {Stage::Amp, ""}, {Stage::Cab, ""}, {Stage::Cab2, ""}});
  pair.run(513, true);
  pair.sweep(3, true);
  for (Stage stage : {Stage::Pedal, Stage::Amp, Stage::Cab, Stage::Cab2})
    pair.installed(stage, "");
  const auto offThread = pair.parallel.calls[3].worker;
  double lateEnergy = 0.0;
  const uint64_t tailFrames = static_cast<uint64_t>(rate * 0.35);
  for (uint64_t frames = 0; frames < tailFrames; frames += kMaximum) {
    const double energy = pair.run(kMaximum, true);
    if (frames > tailFrames / 2) lateEnergy += energy;
  }
  check(lateEnergy > 1.0e-12, "delay/reverb retain measurable late silent-input tails");
  check(pair.parallel.calls[3].worker == offThread, "no stale worker jobs after unloading");
  pair.set(53, 0); pair.set(54, 0); pair.set(33, 0);
  pair.sweep(3, true);
  std::printf("PASS: %.0f Hz bit-identical delay/reverb tails and FX bypass after unloading all models\n", rate);
}

void verifyWavFallback(double rate, const std::string& wave, const std::string& lstm,
                       const TempWavs& fixtures) {
  for (unsigned channels : {1u, 2u}) {
    const std::string& path = channels == 1 ? fixtures.mono : fixtures.stereo;
    for (bool irAtA : {true, false}) {
      testSection = std::to_string(static_cast<int>(rate)) + " Hz " +
                (irAtA ? "A WAV + B NAM" : "A NAM + B WAV") +
                " (" + std::to_string(channels) + " WAV channels)";
      Pair pair(rate);
      pair.set(7, 0); pair.set(8, 0);
      const Stage irStage = irAtA ? Stage::Cab : Stage::Cab2;
      const Stage namStage = irAtA ? Stage::Cab2 : Stage::Cab;
      const std::string& namPath = irAtA ? lstm : wave;
      // Both WaveNet and phase-split LSTM cabs follow the True domain.
      const int nativeB = 0;
      pair.paths({{irStage, path}, {namStage, namPath}});
      pair.run(17);
      pair.steady(true, true, false, pipelineFactor(6, rate), 0, nativeB);
      pair.installed(irStage, path, channels);
      pair.installed(namStage, namPath);
      check((std::memcmp(pair.serial.left.data(), pair.serial.right.data(),
                         kCounts.back() * sizeof(float)) == 0) == (channels == 1),
            "zero width keeps each cabinet's image: mono fixtures stay dual mono, a stereo IR stays stereo");

      pair.set(32, 100);
      pair.set(irAtA ? 47 : 9, 0); // Isolate the IR's own channel behavior.
      pair.steady(irAtA, !irAtA, false, pipelineFactor(6, rate), 0, nativeB);
      check((std::memcmp(pair.serial.left.data(), pair.serial.right.data(),
                         kCounts.back() * sizeof(float)) != 0) == (channels == 2),
            "isolated mono IR stays dual mono; stereo IR preserves distinct channels");
      for (Host* host : {&pair.serial, &pair.parallel}) {
        double leftEnergy = 0.0, rightEnergy = 0.0;
        for (uint32_t i = 0; i < kCounts.back(); ++i) {
          leftEnergy += static_cast<double>(host->left[i]) * host->left[i];
          rightEnergy += static_cast<double>(host->right[i]) * host->right[i];
        }
        check(leftEnergy > 0.0 && rightEnergy > 0.0, "both IR output channels are audible");
      }
      pair.set(irAtA ? 47 : 9, 1);
      pair.steady(true, true, false, pipelineFactor(6, rate), 0, nativeB);
      for (float alignment : {-10.0f, -3.5f, 0.0f, 7.25f, 10.0f}) {
        for (float polarity : {1.0f, 0.0f}) {
          pair.set(49, alignment); pair.set(59, polarity);
          pair.steady(true, true, false, pipelineFactor(6, rate), 0, nativeB);
        }
      }

      const size_t index = static_cast<size_t>(irStage);
      const uint64_t loads = pair.serial.loads[index];
      pair.paths({{irStage, ""}});
      pair.run(256);
      pair.steady(!irAtA, irAtA, false, pipelineFactor(6, rate), 0, nativeB);
      pair.installed(irStage, "");
      pair.installed(namStage, namPath);
      pair.paths({{irStage, path}});
      pair.run(513);
      pair.steady(true, true, false, pipelineFactor(6, rate), 0, nativeB);
      pair.installed(irStage, path, channels);
      check(pair.serial.loads[index] == loads + 2,
            "WAV unload/reload each schedule exactly once, including Cab2");
      check(pair.parallel.calls[3].worker == 0,
            "WAV/NAM combinations never dispatch a cabinet worker job");
      pair.paths({{irStage, ""}, {namStage, ""}});
      pair.run(128);
      pair.sweep(3);
      pair.installed(irStage, "");
      pair.installed(namStage, "");
      std::printf("PASS: %.0f Hz %s, %s PCM16 IR; all block counts bit-identical, no worker calls, channel behavior and unload/reload\n",
                  rate, irAtA ? "A WAV + B NAM" : "A NAM + B WAV",
                  channels == 1 ? "mono" : "stereo");
    }
  }
}

void verifyAlignment(double rate, const TempWavs& fixtures) {
  testSection = "matching WAV cancellation, amplification and optional polarity at " +
                std::to_string(static_cast<int>(rate)) + " Hz";
  for (unsigned channels : {1u, 2u}) {
    const auto& path = channels == 1 ? fixtures.mono : fixtures.stereo;
    Pair reference(rate), normal(rate), inverted(rate), optional(rate, true, false);
    for (Pair* pair : {&reference, &normal, &inverted, &optional}) {
      pair->set(7, 0); pair->set(8, 0); pair->set(32, 0);
      pair->paths({{Stage::Cab, path}, {Stage::Cab2, path}});
      pair->run(128, true);
      pair->sweep(3, true);
      pair->installed(Stage::Cab, path, channels);
      pair->installed(Stage::Cab2, path, channels);
    }
    reference.set(47, 0);
    inverted.set(59, 1);
    const unsigned settle = static_cast<unsigned>(std::ceil(rate * 0.25 / 128));
    for (unsigned block = 0; block < settle; ++block)
      for (Pair* pair : {&reference, &normal, &inverted, &optional}) pair->run(128, true);
    double referenceEnergy = 0.0, normalEnergy = 0.0, cancelledEnergy = 0.0;
    double amplificationError = 0.0;
    // Two matching cabinets are fully coherent, so the equal-power blend is
    // sqrt(2) times one cabinet through the rig's 200 Hz low shelf of
    // -20*log10(cos(pi/4) + sin(pi/4)) dB, which the silent settle has
    // already glided to its target with a clean filter history.
    NAMRig::Biquad shelfL, shelfR;
    dualCabShelf(shelfL, rate);
    dualCabShelf(shelfR, rate);
    for (uint32_t count : kCounts) {
      referenceEnergy += reference.run(count);
      normalEnergy += normal.run(count);
      cancelledEnergy += inverted.run(count);
      optional.run(count);
      check(std::memcmp(normal.serial.left.data(), optional.serial.left.data(), count * sizeof(float)) == 0 &&
                std::memcmp(normal.serial.right.data(), optional.serial.right.data(), count * sizeof(float)) == 0,
            "unconnected optional polarity is bit-identical to default normal polarity");
      for (uint32_t i = 0; i < count; ++i) {
        for (bool right : {false, true}) {
          const float a = right ? reference.serial.right[i] : reference.serial.left[i];
          const float b = right ? normal.serial.right[i] : normal.serial.left[i];
          const float expected = (right ? shelfR : shelfL).process(std::sqrt(2.0f) * a);
          const double error = b - expected;
          amplificationError += error * error;
        }
      }
    }
    check(referenceEnergy > 1.0e-4 && normalEnergy > referenceEnergy * 1.1,
          "matching normal WAVs produce audible amplified output, not empty buffers");
    check(amplificationError < referenceEnergy * 1.0e-8,
          "normal width-zero dual cabs equal the shelved sqrt(2) times the isolated Cab A reference");
    check(cancelledEnergy < referenceEnergy * 1.0e-10,
          "matching WAVs at width zero cancel after Cab B polarity settles");
  }

  testSection = "stereo Cab B polarity and click-free switching";
  Pair normal(rate), inverted(rate);
  for (Pair* pair : {&normal, &inverted}) {
    pair->set(7, 0); pair->set(8, 0); pair->set(9, 0); pair->set(32, 100);
    pair->paths({{Stage::Cab2, fixtures.stereo}});
    pair->run(128, true);
    pair->sweep(3, true);
    pair->installed(Stage::Cab2, fixtures.stereo, 2);
  }
  for (uint64_t frames = 0; frames < static_cast<uint64_t>(rate * 0.25); frames += 128) {
    for (Pair* pair : {&normal, &inverted}) {
      pair->serial.input.fill(0.2f); pair->parallel.input.fill(0.2f);
      pair->runControl(128);
    }
  }
  const std::array<float, 2> baseline{normal.serial.left[127], normal.serial.right[127]};
  check(std::fabs(baseline[0]) > 0.01f && std::fabs(baseline[1]) > 0.01f &&
            std::fabs(baseline[0] - baseline[1]) > 0.01f,
        "stereo polarity probe has audible, distinct left and right channels");
  inverted.set(59, 1);
  std::array<float, 2> previous = baseline;
  double largestStep = 0.0;
  for (uint64_t frames = 0; frames < static_cast<uint64_t>(rate * 0.25); frames += 128) {
    normal.runControl(128); inverted.runControl(128);
    if (frames == 0)
      check(inverted.serial.left[0] / baseline[0] > 0.9f &&
                inverted.serial.right[0] / baseline[1] > 0.9f,
            "polarity toggle begins near +1 rather than hard-switching to -1");
    for (uint32_t i = 0; i < 128; ++i) {
      const std::array<float, 2> current{inverted.serial.left[i], inverted.serial.right[i]};
      for (size_t channel = 0; channel < 2; ++channel) {
        largestStep = std::max(largestStep,
            static_cast<double>(std::fabs((current[channel] - previous[channel]) / baseline[channel])));
        previous[channel] = current[channel];
      }
    }
  }
  check(largestStep < 0.01, "polarity gain moves by less than 1% per sample on both channels");
  check(std::fabs(previous[0] + baseline[0]) < std::fabs(baseline[0]) * 1.0e-5f &&
            std::fabs(previous[1] + baseline[1]) < std::fabs(baseline[1]) * 1.0e-5f,
        "settled polarity negates both stereo Cab B channels");
  // Return through zero as well; a second switch must not reset to a hard +1.
  inverted.set(59, 0);
  inverted.runControl(1);
  check(inverted.serial.left[0] / baseline[0] < -0.9f &&
            inverted.serial.right[0] / baseline[1] < -0.9f,
        "return to normal polarity also starts from the previous smoothed gain");
  for (uint64_t frames = 0; frames < static_cast<uint64_t>(rate * 0.25); frames += 128)
    inverted.runControl(128);
  check(std::memcmp(normal.serial.left.data(), inverted.serial.left.data(), 128 * sizeof(float)) == 0 &&
            std::memcmp(normal.serial.right.data(), inverted.serial.right.data(), 128 * sizeof(float)) == 0,
        "return to normal polarity settles to the exact unchanged stereo reference");

  auto impulsePeaks = [&](Pair& pair) {
    for (uint64_t frames = 0; frames < static_cast<uint64_t>(rate * 0.3); frames += 128)
      pair.run(128, true);
    std::array<size_t, 2> peaks{};
    std::array<float, 2> amplitudes{};
    constexpr uint32_t impulseFrames = 4096;
    for (uint32_t offset = 0; offset < impulseFrames; offset += 128) {
      pair.serial.input.fill(0.0f); pair.parallel.input.fill(0.0f);
      if (offset == 0) pair.serial.input[0] = pair.parallel.input[0] = 0.2f;
      pair.runControl(128);
      for (uint32_t i = 0; i < 128; ++i) {
        const std::array<float, 2> samples{pair.serial.left[i], pair.serial.right[i]};
        for (size_t channel = 0; channel < 2; ++channel) {
          if (std::fabs(samples[channel]) > std::fabs(amplitudes[channel])) {
            amplitudes[channel] = samples[channel];
            peaks[channel] = offset + i;
          }
        }
      }
    }
    check(std::fabs(amplitudes[0]) > 0.01f && std::fabs(amplitudes[1]) > 0.01f,
          "timing probe measures real audible impulses on both channels");
    return peaks;
  };
  for (bool trueCab : {false, true}) {
    Pair pair(rate);
    pair.set(7, 0); pair.set(8, 0); pair.set(32, 100);
    if (trueCab)
      for (Host* host : {&pair.serial, &pair.parallel})
        check(host->plugin.loaders[2].SetWaveNetLoadMode(NeuralAudio::EModelLoadMode::NAMCore),
              "identity fixture uses the real NAMCore loader");
    const auto& cabA = trueCab ? fixtures.identity : fixtures.mono;
    pair.paths({{Stage::Cab, cabA}, {Stage::Cab2, fixtures.mono}});
    pair.run(128, true);
    pair.sweep(3, true);
    pair.installed(Stage::Cab, cabA, trueCab ? 0 : 1);
    pair.installed(Stage::Cab2, fixtures.mono, 1);
    // Mixed WaveNet Cab A (True Nx) alongside mono WAV Cab B (session rate)
    // must keep both branches aligned by True-cab cascade latency.
    for (int mode : kModes) {
      if (!trueCab && mode != 0) continue;
      pair.set(21, static_cast<float>(mode));
      const int factor = mode == 0 ? 1 : pipelineFactor(mode, rate);
      const size_t cabLat = !trueCab ? 0u
          : (factor == 2 ? 23u : factor == 4 ? 35u : factor == 8 ? 41u : factor == 16 ? 44u : 0u);
      for (float alignment : {-10.0f, -3.5f, 0.0f, 3.5f, 10.0f}) {
        testSection = "real impulse alignment " + std::to_string(alignment) +
                      " ms, mode " + std::to_string(mode) + " at " + std::to_string(rate);
        pair.set(49, alignment);
        const auto peaks = impulsePeaks(pair);
        const size_t extra = static_cast<size_t>(std::llround(rate * std::fabs(alignment) * 0.001));
        check(peaks[0] == cabLat + (alignment < 0 ? extra : 0),
              "negative alignment delays Cab A by -d on top of balanced cab latency");
        check(peaks[1] == cabLat + (alignment > 0 ? extra : 0),
              "Cab B balances Cab A True-cab latency plus positive user alignment");
        check(pair.serial.controls[29] == static_cast<float>(cabLat),
              "host latency reports balanced True-cab delay for mixed WaveNet+WAV cabinets");
      }
    }
  }

  testSection = "single cabinet and dry signed alignment";
  for (int active : {0, 1, 2}) {
    Pair pair(rate);
    pair.set(7, 0); pair.set(8, 0); pair.set(32, 100);
    pair.set(9, active == 1 ? 1 : 0); pair.set(47, active == 2 ? 1 : 0);
    pair.paths({{Stage::Cab, fixtures.mono}, {Stage::Cab2, fixtures.mono}});
    pair.run(128, true);
    for (float alignment : {-10.0f, 0.0f, 10.0f}) {
      pair.set(49, alignment);
      const auto peaks = impulsePeaks(pair);
      const size_t expected = active == 2 && alignment > 0
          ? static_cast<size_t>(std::llround(rate * alignment * 0.001)) : 0;
      check(peaks[0] == expected && peaks[1] == expected,
            "A-only/dry never acquire A alignment; B-only keeps its existing positive delay");
    }
  }
  {
    Pair pair(rate);
    pair.set(7, 0); pair.set(8, 0); pair.set(32, 100); pair.set(49, -10);
    pair.paths({{Stage::Cab, fixtures.mono}, {Stage::Cab2, fixtures.mono}});
    pair.run(128, true);
    const auto dual = impulsePeaks(pair);
    check(dual[0] == static_cast<size_t>(std::llround(rate * 0.010)) && dual[1] == 0,
          "dual-cab probe primes a nonzero extra Cab A delay before bypass");
    pair.set(47, 0);
    const auto aOnly = impulsePeaks(pair);
    check(aOnly[0] == 0 && aOnly[1] == 0,
          "disabling Cab B clears the previously active extra Cab A delay");
    pair.set(47, 1);
    const auto back = impulsePeaks(pair);
    check(back == dual, "re-enabling both cabinets restores signed alignment without stale history");
  }
  std::printf("PASS: %.0f Hz WAV cancellation/shelved amplification, optional polarity, stereo smooth switching, signed impulse timing with a session-rate .nam Cab A, A/B-only and dry behavior\n", rate);
}

void benchmark(const std::string& wave, const std::string& lstm) {
  testSection = "optional focused timing (not a speedup assertion)";
  for (int mode : {0, 6}) {
    Pair pair(96000.0, false); // Time real graphs without observation decorators.
    pair.set(7, 0); pair.set(8, 0);
    pair.set(20, static_cast<float>(mode)); pair.set(21, static_cast<float>(mode));
    pair.paths({{Stage::Cab, wave}, {Stage::Cab2, lstm}});
    pair.run(128);
    pair.sweep(3);
    pair.installed(Stage::Cab, wave);
    pair.installed(Stage::Cab2, lstm);
    for (unsigned block = 0; block < 64; ++block) pair.run(128);
    pair.serialSeconds = pair.parallelSeconds = 0.0;
    constexpr unsigned measured = 1024;
    for (unsigned block = 0; block < measured; ++block) pair.run(128);
    std::printf("TIMING: both NAM cabs loaded, 96 kHz, Cab A %dx / Cab B 1x, 128 frames, %u blocks: serial %.2f us/block, worker %.2f us/block, serial/worker %.3f (offline, no guaranteed speedup)\n",
                mode == 0 ? 1 : 8, measured,
                pair.serialSeconds * 1.0e6 / measured,
                pair.parallelSeconds * 1.0e6 / measured,
                pair.serialSeconds / pair.parallelSeconds);
  }
}

void verifyDualCabSpeakerDynamics(double rate, const TempWavs& fixtures) {
  testSection = std::to_string(static_cast<int>(rate)) + " Hz dual-cab SpeakerDynamics";
  Pair pair(rate);
  pair.set(7, 0);
  pair.set(8, 1);
  pair.set(9, 1);
  pair.set(47, 1);
  pair.set(32, 100.0f);
  pair.set(NAMRig::kSpatialCenterBlendPort, 0.0f);
  pair.set(43, 0.0f);
  pair.set(44, 0.0f);
  pair.set(45, 0.0f);
  pair.set(46, 100.0f);

  auto measure118HzRatioDb = [&]() {
    const uint32_t warmupFrames = static_cast<uint32_t>(rate * 0.4);
    const uint32_t measureFrames = static_cast<uint32_t>(rate * 0.4);
    double phase = 0.0;
    const double step = 2.0 * 3.14159265358979323846 * 118.0 / rate;
    double sumL = 0.0, sumR = 0.0;
    uint32_t total = 0;
    while (total < warmupFrames + measureFrames) {
      const uint32_t n = std::min<uint32_t>(128, warmupFrames + measureFrames - total);
      for (uint32_t i = 0; i < n; ++i) {
        const float s = static_cast<float>(0.25 * std::sin(phase));
        pair.serial.input[i] = pair.parallel.input[i] = s;
        phase += step;
      }
      pair.runControl(n);
      if (total >= warmupFrames) {
        for (uint32_t i = 0; i < n; ++i) {
          const double l = pair.serial.left[i];
          const double r = pair.serial.right[i];
          sumL += l * l;
          sumR += r * r;
        }
      }
      total += n;
    }
    check(sumL > 1.0e-8 && sumR > 1.0e-8,
          "dual-cab speaker sine measurement produces audible stereo output");
    return 10.0 * std::log10(sumL / sumR);
  };

  // 1. Auto + Match Cab A resolves independent profiles from WAV Cab A & Cab B names.
  pair.set(42, static_cast<float>(NAMRig::SpeakerDynamics::kAuto));
  pair.set(NAMRig::kSpeakerProfileBPort, static_cast<float>(NAMRig::SpeakerDynamics::kMatchCabA));
  pair.paths({{Stage::Amp, fixtures.identity},
              {Stage::Cab, fixtures.greenback},
              {Stage::Cab2, fixtures.v30}});
  pair.run(17);
  pair.sweep(3);
  for (Host* host : {&pair.serial, &pair.parallel}) {
    check(host->plugin.appliedSpeakerProfile() == NAMRig::SpeakerDynamics::kUK412 &&
              host->plugin.appliedSpeakerBProfile() == NAMRig::SpeakerDynamics::kModern412,
          "Auto + Match Cab A resolves Cab A to UK 4x12 and Cab B to Modern 4x12");
  }
  const double autoRatioDb = measure118HzRatioDb();
  check(autoRatioDb > 1.0 && autoRatioDb < 3.5,
        "Auto split applies stronger 118 Hz UK 4x12 resonance on Cab A than Modern 4x12 on Cab B");

  // 2. Explicit UK 4x12 (Cab A) + Captured (Cab B) with .nam Cab B dispatched to CabinetWorker.
  const uint64_t workerBefore = pair.parallel.calls[3].worker;
  pair.set(42, static_cast<float>(NAMRig::SpeakerDynamics::kUK412));
  pair.set(NAMRig::kSpeakerProfileBPort, static_cast<float>(NAMRig::SpeakerDynamics::kCaptured));
  pair.paths({{Stage::Cab, fixtures.identity}, {Stage::Cab2, fixtures.identity}});
  pair.run(17);
  pair.sweep(3);
  for (Host* host : {&pair.serial, &pair.parallel}) {
    check(host->plugin.appliedSpeakerProfile() == NAMRig::SpeakerDynamics::kUK412 &&
              host->plugin.appliedSpeakerBProfile() == NAMRig::SpeakerDynamics::kCaptured,
          "explicit Cab B profile overrides Match Cab A independently of Cab A");
  }
  const double explicitRatioDb = measure118HzRatioDb();
  check(explicitRatioDb > 2.0 && explicitRatioDb < 4.5,
        "explicit UK 4x12 vs Captured applies speaker load strictly to Cab A");
  check(pair.parallel.calls[3].worker > workerBefore,
        "dual-cab SpeakerDynamics keeps .nam Cab B execution on CabinetWorker");

  // 3. Shared mode: UK 4x12 + Match Cab A collapses to common pre-split SpeakerDynamics.
  pair.set(42, static_cast<float>(NAMRig::SpeakerDynamics::kUK412));
  pair.set(NAMRig::kSpeakerProfileBPort, static_cast<float>(NAMRig::SpeakerDynamics::kMatchCabA));
  pair.sweep(3);
  for (Host* host : {&pair.serial, &pair.parallel}) {
    check(host->plugin.appliedSpeakerProfile() == NAMRig::SpeakerDynamics::kUK412 &&
              host->plugin.appliedSpeakerBProfile() == NAMRig::SpeakerDynamics::kUK412,
          "explicit Cab A + Match Cab A shares one profile across both cabs");
  }
  const double sharedRatioDb = measure118HzRatioDb();
  check(std::fabs(sharedRatioDb) < 0.05,
        "matching dual-cab SpeakerDynamics produces matched stereo L/R level");

  std::printf("PASS: %.0f Hz dual-cab SpeakerDynamics (Auto %.2f dB, UK/Cap %.2f dB, shared %.2f dB)\n",
              rate, autoRatioDb, explicitRatioDb, sharedRatioDb);
}

std::string defaultModel(const std::filesystem::path& relative) {
  const auto sourceRoot = std::filesystem::path(__FILE__).parent_path().parent_path();
  if (std::filesystem::is_regular_file(sourceRoot / relative))
    return std::filesystem::absolute(sourceRoot / relative).string();
  for (auto root = std::filesystem::current_path(); !root.empty();) {
    if (std::filesystem::is_regular_file(root / relative))
      return (root / relative).string();
    const auto parent = root.parent_path();
    if (parent == root) break;
    root = parent;
  }
  return relative.string(); // main reports a useful missing-fixture error.
}
} // namespace

int main(int argc, char** argv) {
  std::fenv_t original{};
  check(std::fegetenv(&original) == 0, "capture original fenv");
  try {
    bool timing = false;
    bool speakerOnly = false;
    bool pluginsOnly = false;
    std::vector<std::string> arguments;
    for (int i = 1; i < argc; ++i) {
      if (std::strcmp(argv[i], "--benchmark") == 0) timing = true;
      else if (std::strcmp(argv[i], "--speaker") == 0) speakerOnly = true;
      else if (std::strcmp(argv[i], "--plugins") == 0) pluginsOnly = true;
      else if (std::strcmp(argv[i], "--help") == 0) {
        std::printf("Usage: %s [wavenet.nam [lstm.nam]] [--benchmark|--speaker|--plugins]\n", argv[0]);
        return 0;
      } else arguments.emplace_back(argv[i]);
    }
    check(arguments.size() <= 2, "usage: verify_parallel_cabs [wavenet.nam [lstm.nam]] [--benchmark|--speaker|--plugins]");
    if (speakerOnly) {
      TempWavs fixtures;
      fixtures.writeIdentity();
      fixtures.writeSpeakerFixtures();
      verifyEnvironment();
      for (double rate : {48000.0, 96000.0})
        verifyDualCabSpeakerDynamics(rate, fixtures);
      check(std::fesetenv(&original) == 0, "restore original fenv");
      std::printf("PASS: dual-cab SpeakerDynamics checks; %llu stereo frames compared bit-for-bit, %llu observed steady-state Cab B worker calls\n",
                  static_cast<unsigned long long>(checkedFrames),
                  static_cast<unsigned long long>(workerCalls));
      return 0;
    }
    const std::string wave = arguments.empty()
        ? defaultModel("deps/NeuralAudio/deps/NeuralAmpModelerCore/example_models/wavenet.nam")
        : std::filesystem::absolute(arguments[0]).string();
    const std::string lstm = arguments.size() < 2
        ? defaultModel("deps/NeuralAudio/Utils/Models/BossLSTM-1x16.nam")
        : std::filesystem::absolute(arguments[1]).string();
    const std::string standard = defaultModel("deps/NeuralAudio/Utils/Models/BossWN-standard.nam");
    const std::string a2 = defaultModel("deps/NeuralAudio/Utils/Models/BossWN-a2.nam");
    for (const auto& path : {wave, lstm, standard, a2}) {
      if (!std::filesystem::is_regular_file(path)) {
        std::fprintf(stderr, "FAIL: model fixture not found: %s\n", path.c_str());
        return 1;
      }
    }
    std::printf("Models: Cab A default %s\n        Cab B default %s\n", wave.c_str(), lstm.c_str());
    TempWavs fixtures;
    fixtures.write(1);
    fixtures.write(2);
    fixtures.writeIdentity();
    fixtures.writeSpeakerFixtures();
    verifyEnvironment();
    if (!pluginsOnly) verifyMulticoreModels(standard, a2, lstm);
    for (double rate : {48000.0, 96000.0}) {
      verifyAlignment(rate, fixtures);
      verifyPlugins(rate, wave, lstm);
      verifyWavFallback(rate, wave, lstm, fixtures);
      verifyDualCabSpeakerDynamics(rate, fixtures);
    }
    if (timing) benchmark(wave, lstm);
    check(std::fesetenv(&original) == 0, "restore original fenv");
    std::printf("PASS: all parallel cabinet integration checks; %llu stereo frames compared bit-for-bit, %llu observed steady-state Cab B worker calls\n",
                static_cast<unsigned long long>(checkedFrames),
                static_cast<unsigned long long>(workerCalls));
    return 0;
  } catch (const std::exception& error) {
    std::fesetenv(&original);
    std::fprintf(stderr, "FAIL [%s]: %s\n", testSection.c_str(), error.what());
    return 1;
  }
}
