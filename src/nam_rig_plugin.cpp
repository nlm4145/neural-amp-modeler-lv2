#include "nam_rig_plugin.h"
#include "cabinet_worker.h"
#include "polyphase_worker.h"

#include <algorithm>
#include <cassert>
#include <cfenv>
#include <cmath>
#include <cstring>
#include <fstream>

#include "dsp_accel.h"

#include <lv2/core/lv2_util.h>
#include "dynamics.h"
#include "ir_normalization.h"
#include "wav_ir.h"

namespace NAMRig {
namespace {
constexpr float kSmoothEpsilon = 0.0001f;

size_t stageIndex(Stage stage) {
  return static_cast<size_t>(stage);
}

bool validStage(Stage stage) {
  return stageIndex(stage) < kStageCount;
}

float dbToLinear(float db) {
  return std::pow(10.0f, db * 0.05f);
}

float portValue(const float* port, float fallback) {
  return port ? *port : fallback;
}

void glideValue(float& value, float target, float coeff, float snap) {
  value += (target - value) * coeff;
  if (std::fabs(target - value) < snap) value = target;
}

void copyCoefficients(Biquad& dst, const Biquad& src) {
  dst.b0 = src.b0; dst.b1 = src.b1; dst.b2 = src.b2;
  dst.a1 = src.a1; dst.a2 = src.a2;
}

constexpr uint32_t kEqChunk = 32;

bool endsWithWav(const char* path) {
  const std::string value(path ? path : "");
  if (value.size() < 4) return false;
  std::string suffix = value.substr(value.size() - 4);
  std::transform(suffix.begin(), suffix.end(), suffix.begin(), ::tolower);
  return suffix == ".wav";
}

bool isFullRigModel(const char* path) {
  std::ifstream file(path, std::ios::binary);
  if (!file) return false;
  std::string header(65536, '\0');
  file.read(header.data(), static_cast<std::streamsize>(header.size()));
  header.resize(static_cast<size_t>(file.gcount()));
  return header.find("\"gear_type\":\"amp_cab\"") != std::string::npos ||
         header.find("\"gear_type\": \"amp_cab\"") != std::string::npos ||
         header.find("\"gear_type\":\"full_rig\"") != std::string::npos;
}

// The top-level "architecture" string of a .nam file, or empty when absent.
std::string modelArchitecture(const char* path) {
  std::ifstream file(path, std::ios::binary);
  if (!file) return {};
  std::string header(65536, '\0');
  file.read(header.data(), static_cast<std::streamsize>(header.size()));
  header.resize(static_cast<size_t>(file.gcount()));
  const size_t key = header.find("\"architecture\"");
  if (key == std::string::npos) return {};
  const size_t colon = header.find(':', key);
  if (colon == std::string::npos) return {};
  const size_t open = header.find('"', colon + 1);
  if (open == std::string::npos) return {};
  const size_t close = header.find('"', open + 1);
  if (close == std::string::npos) return {};
  return header.substr(open + 1, close - open - 1);
}

// NeuralAudio rate-adapts WaveNets (dilation scaling / polyphase) and the
// WaveNet submodels inside an A2 container. Everything else runs at its own
// rate regardless of the loader's external rate.
bool rateAdaptable(const std::string& architecture) {
  return architecture.empty() || architecture == "WaveNet" ||
         architecture == "SlimmableContainer";
}

constexpr double kPi = 3.14159265358979323846;
constexpr float kDualCabShelfHz = 200.0f;
constexpr float kEqQ = 0.7071067811865476f;  // Q = 1/sqrt(2)

// RBJ Audio EQ Cookbook — normalized (by a0) biquad coefficient setters.
static void setLowShelf(Biquad& f, float gainDb, float freq, double sampleRate) {
  const double A = std::pow(10.0, gainDb / 40.0);
  const double w0 = 2.0 * kPi * freq / sampleRate;
  const double c = std::cos(w0), s = std::sin(w0);
  const double alpha = s / (2.0 * kEqQ);
  const double sqA = 2.0 * std::sqrt(A) * alpha;
  const double b0 = A * ((A + 1) - (A - 1) * c + sqA);
  const double b1 = 2.0 * A * ((A - 1) - (A + 1) * c);
  const double b2 = A * ((A + 1) - (A - 1) * c - sqA);
  const double a0 = (A + 1) + (A - 1) * c + sqA;
  const double a1 = -2.0 * ((A - 1) + (A + 1) * c);
  const double a2 = (A + 1) + (A - 1) * c - sqA;
  f.b0 = static_cast<float>(b0 / a0);
  f.b1 = static_cast<float>(b1 / a0);
  f.b2 = static_cast<float>(b2 / a0);
  f.a1 = static_cast<float>(a1 / a0);
  f.a2 = static_cast<float>(a2 / a0);
}

static void setHighShelf(Biquad& f, float gainDb, float freq, double sampleRate) {
  const double A = std::pow(10.0, gainDb / 40.0);
  const double w0 = 2.0 * kPi * freq / sampleRate;
  const double c = std::cos(w0), s = std::sin(w0);
  const double alpha = s / (2.0 * kEqQ);
  const double sqA = 2.0 * std::sqrt(A) * alpha;
  const double b0 = A * ((A + 1) + (A - 1) * c + sqA);
  const double b1 = -2.0 * A * ((A - 1) + (A + 1) * c);
  const double b2 = A * ((A + 1) + (A - 1) * c - sqA);
  const double a0 = (A + 1) - (A - 1) * c + sqA;
  const double a1 = 2.0 * ((A - 1) - (A + 1) * c);
  const double a2 = (A + 1) - (A - 1) * c - sqA;
  f.b0 = static_cast<float>(b0 / a0);
  f.b1 = static_cast<float>(b1 / a0);
  f.b2 = static_cast<float>(b2 / a0);
  f.a1 = static_cast<float>(a1 / a0);
  f.a2 = static_cast<float>(a2 / a0);
}

static void setPeaking(Biquad& f, float gainDb, float freq, double sampleRate) {
  const double A = std::pow(10.0, gainDb / 40.0);
  const double w0 = 2.0 * kPi * freq / sampleRate;
  const double c = std::cos(w0), s = std::sin(w0);
  const double alpha = s / (2.0 * kEqQ);
  const double b0 = 1.0 + alpha * A;
  const double b1 = -2.0 * c;
  const double b2 = 1.0 - alpha * A;
  const double a0 = 1.0 + alpha / A;
  const double a1 = -2.0 * c;
  const double a2 = 1.0 - alpha / A;
  f.b0 = static_cast<float>(b0 / a0);
  f.b1 = static_cast<float>(b1 / a0);
  f.b2 = static_cast<float>(b2 / a0);
  f.a1 = static_cast<float>(a1 / a0);
  f.a2 = static_cast<float>(a2 / a0);
}

static void setHighPass(Biquad& f, float freq, double sampleRate) {
  const double w0 = 2.0 * kPi * freq / sampleRate;
  const double c = std::cos(w0), s = std::sin(w0);
  const double alpha = s / (2.0 * kEqQ);
  const double a0 = 1.0 + alpha;
  f.b0 = static_cast<float>((1.0 + c) * 0.5 / a0);
  f.b1 = static_cast<float>(-(1.0 + c) / a0);
  f.b2 = f.b0;
  f.a1 = static_cast<float>(-2.0 * c / a0);
  f.a2 = static_cast<float>((1.0 - alpha) / a0);
}

static void setLowPass(Biquad& f, float freq, double sampleRate) {
  const double w0 = 2.0 * kPi * freq / sampleRate;
  const double c = std::cos(w0), s = std::sin(w0);
  const double alpha = s / (2.0 * kEqQ);
  const double a0 = 1.0 + alpha;
  f.b0 = static_cast<float>((1.0 - c) * 0.5 / a0);
  f.b1 = static_cast<float>((1.0 - c) / a0);
  f.b2 = f.b0;
  f.a1 = static_cast<float>(-2.0 * c / a0);
  f.a2 = static_cast<float>((1.0 - alpha) / a0);
}
} // namespace

Plugin::Plugin() {
  for (auto& path : modelPaths)
    path.reserve(MAX_FILE_NAME + 1);
}

Plugin::~Plugin() {
  for (auto* model : models)
    delete model;
  for (auto* ir : irs)
    delete ir;
  for (auto* ir : irsRight)
    delete ir;
  for (auto& pending : pendingSwitches) {
    delete pending.model;
    delete pending.ir;
    delete pending.irRight;
  }
}

bool Plugin::initialize(double rate, const LV2_Feature* const* features) noexcept {
  sampleRate = rate;
  LV2_Options_Option* options = nullptr;

  for (size_t i = 0; features && features[i]; ++i) {
    if (!std::strcmp(features[i]->URI, LV2_URID__map))
      map = static_cast<LV2_URID_Map*>(features[i]->data);
    else if (!std::strcmp(features[i]->URI, LV2_WORKER__schedule))
      schedule = static_cast<LV2_Worker_Schedule*>(features[i]->data);
    else if (!std::strcmp(features[i]->URI, LV2_LOG__log))
      logger.log = static_cast<LV2_Log_Log*>(features[i]->data);
    else if (!std::strcmp(features[i]->URI, LV2_OPTIONS__options))
      options = static_cast<LV2_Options_Option*>(features[i]->data);
  }

  if (!map || !schedule)
    return false;

  lv2_log_logger_set_map(&logger, map);
  lv2_atom_forge_init(&forge, map);

  uris.atomObject = map->map(map->handle, LV2_ATOM__Object);
  uris.atomInt = map->map(map->handle, LV2_ATOM__Int);
  uris.atomPath = map->map(map->handle, LV2_ATOM__Path);
  uris.atomURID = map->map(map->handle, LV2_ATOM__URID);
  uris.maxBlockLength = map->map(map->handle, LV2_BUF_SIZE__maxBlockLength);
  uris.patchSet = map->map(map->handle, LV2_PATCH__Set);
  uris.patchGet = map->map(map->handle, LV2_PATCH__Get);
  uris.patchProperty = map->map(map->handle, LV2_PATCH__property);
  uris.patchValue = map->map(map->handle, LV2_PATCH__value);
  uris.unitsFrame = map->map(map->handle, LV2_UNITS__frame);
  uris.stagePath[0] = map->map(map->handle, NAM_RIG_PEDAL_URI);
  uris.stagePath[1] = map->map(map->handle, NAM_RIG_AMP_URI);
  uris.stagePath[2] = map->map(map->handle, NAM_RIG_CAB_URI);
  uris.stagePath[3] = map->map(map->handle, NAM_RIG_CAB2_URI);
  uris.atomFloat = map->map(map->handle, LV2_ATOM__Float);
  uris.tunerNote = map->map(map->handle, NAM_RIG_TUNER_NOTE_URI);
  uris.tunerCents = map->map(map->handle, NAM_RIG_TUNER_CENTS_URI);
  uris.inputDb = map->map(map->handle, NAM_RIG_INPUT_DB_URI);
  uris.preAmpDb = map->map(map->handle, NAM_RIG_PRE_AMP_DB_URI);
  uris.postAmpDb = map->map(map->handle, NAM_RIG_POST_AMP_DB_URI);
  uris.outputDb = map->map(map->handle, NAM_RIG_OUTPUT_DB_URI);

  for (auto& loader : loaders) {
    loader.SetExternalSampleRate(static_cast<int>(rate));
    // Slimmable/A2 files contain multiple fidelity tiers. Keep the loader on
    // the full model explicitly rather than depending on a library default.
    loader.SetDefaultQualityScaleFactor(1.0f);
  }
  tunerSetRates(rate);
  trimSmoothCoeff = 1.0f - std::exp(-1.0f / static_cast<float>(rate * 0.002));
  dcBlocker.setRate(rate);
  dcBlockerR.setRate(rate);
  for (size_t st = 0; st < kStageCount; ++st) {
    stageDc[st].setRate(rate);
    stageDcRate[st] = rate;
  }
  // Includes the user's 10 ms alignment range plus the short True-Nx
  // converter delay used by a parallel Cab A NAM model.
  cab2Align.initialize(rate, 20.0);
  cabAlign.initialize(rate, 20.0);
  delayFx.initialize(rate);
  reverbFx.initialize(rate);
  postCompressor.initialize(rate);

  if (options)
    optionsSet(this, options);

  // Size the oversampler scratch UNCONDITIONALLY: not every host sends the
  // maxBlockLength option, and a null scratch_ would crash on first use.
  // The default (512) is generous for typical blocks; if a host later
  // reports a larger block via optionsSet, it grows.
  setMaxBufferSize(static_cast<int>(maxBufferSize));
  return true;
}

void Plugin::setSampleRateAndReload(double rate) noexcept {
  if (rate <= 0.0 || std::fabs(rate - sampleRate) < 0.5) return;
  sampleRate = rate;
  for (auto& loader : loaders) {
    loader.SetExternalSampleRate(static_cast<int>(rate));
    loader.SetDefaultQualityScaleFactor(1.0f);
  }
  tunerSetRates(rate);
  trimSmoothCoeff = 1.0f - std::exp(-1.0f / static_cast<float>(rate * 0.002));
  dcBlocker.setRate(rate);
  dcBlockerR.setRate(rate);
  for (size_t st = 0; st < kStageCount; ++st) {
    stageDc[st].setRate(rate);
    stageDcRate[st] = rate;
  }
  cab2Align.initialize(rate, 20.0);
  cabAlign.initialize(rate, 20.0);
  delayFx.initialize(rate);
  reverbFx.initialize(rate);
  postCompressor.initialize(rate);
  appliedBass = -999.0f;
  appliedMid = -999.0f;
  appliedTreble = -999.0f;
  appliedLowCut = -1.0f;
  appliedHighCut = -1.0f;
  osTopologySignature = ~uint64_t{0};
  setMaxBufferSize(static_cast<int>(maxBufferSize));
  for (size_t i = 0; i < kStageCount; ++i) {
    if (!modelPaths[i].empty() && modelPaths[i].size() < MAX_FILE_NAME) {
      scheduleModelLoad(static_cast<Stage>(i), modelPaths[i].c_str(),
                        modelPaths[i].size(), desiredStageMode(i));
    }
  }
}

void Plugin::setMaxBufferSize(int size) noexcept {
  maxBufferSize = size;
  for (auto& loader : loaders)
    loader.SetDefaultMaxAudioBufferSize(size);
  // Per-stage, per-level converter sizing. Level L of a True-2^L cascade sees
  // a block of 2^L * size samples: level 0 (2x) sees 2x ... level 3 (16x)
  // sees 16x. Every level is sized for the worst case (kMaxOsFactor) so any
  // mode change is safe with no host callback; the domain scratch and the
  // pedal->amp chain buffer are sized for it too.
  for (size_t st = 0; st < kStageCount; ++st) {
    for (size_t lvl = 0; lvl < kMaxOsLevels; ++lvl) {
      osUp[st][lvl].setMaxBlockSize(static_cast<size_t>(kMaxOsFactor * size));
      osDown[st][lvl].setMaxBlockSize(static_cast<size_t>(kMaxOsFactor * size));
      osUp[st][lvl].reset();
      osDown[st][lvl].reset();
    }
    osScratch[st].assign(static_cast<size_t>(kMaxOsFactor * size) + 64, 0.0f);
    osScratch2[st].assign(static_cast<size_t>(kMaxOsFactor * size) + 64, 0.0f);
    resetNativeStream(st);
  }
  osChain.assign(static_cast<size_t>(kMaxOsFactor * size) + 64, 0.0f);
  const size_t post = static_cast<size_t>(std::max(1, size));
  postL.assign(post, 0.0f);
  postR.assign(post, 0.0f);
  preCab.assign(post, 0.0f);
  cabBL.assign(post, 0.0f);
  cabBR.assign(post, 0.0f);
}

LV2_Worker_Status Plugin::work(LV2_Handle instance,
                               LV2_Worker_Respond_Function respond,
                               LV2_Worker_Respond_Handle handle,
                               uint32_t size,
                               const void* data) {
  if (!instance || !data || size < sizeof(LV2WorkType))
    return LV2_WORKER_ERR_UNKNOWN;

  auto* rig = static_cast<Plugin*>(instance);
  const auto type = *static_cast<const LV2WorkType*>(data);

  if (type == kWorkTypeFree) {
    if (size < sizeof(LV2FreeModelMsg)) return LV2_WORKER_ERR_UNKNOWN;
    const auto* message = static_cast<const LV2FreeModelMsg*>(data);
    delete message->model;
    delete message->ir;
    delete message->irRight;
    return LV2_WORKER_SUCCESS;
  }

  if (type != kWorkTypeLoad || size < sizeof(LV2LoadModelMsg))
    return LV2_WORKER_ERR_UNKNOWN;

  const auto* message = static_cast<const LV2LoadModelMsg*>(data);
  if (!validStage(message->stage))
    return LV2_WORKER_ERR_UNKNOWN;

  LV2SwitchModelMsg response{kWorkTypeSwitch, message->stage,
                             message->oversampleMode, message->generation,
                             {}, nullptr, nullptr, nullptr, false, 0.0f};
  const size_t length = strnlen(message->path, MAX_FILE_NAME);
  const int requestedMode = Plugin::normalizeLoadMode(message->stage,
                                                      message->oversampleMode);

  try {
    if (length > 0 && length < MAX_FILE_NAME) {
      if ((message->stage == Stage::Cab || message->stage == Stage::Cab2) &&
          endsWithWav(message->path)) {
        const unsigned channels = WavIR::channelCount(message->path);
        if (channels >= 2) {
          auto left = WavIR::load(message->path, rig->sampleRate,
                                  rig->maxBufferSize, 0);
          auto right = WavIR::load(message->path, rig->sampleRate,
                                   rig->maxBufferSize, 1);
          WavIR::linkStereoNormalization(*left, *right);
          response.ir = left.release();
          response.irRight = right.release();
        } else {
          response.ir = WavIR::load(message->path, rig->sampleRate,
                                    rig->maxBufferSize).release();
        }
      } else {
        // The stage's oversample mode decides the loader external rate.
        // NONE (0): 48000 — dilation is a no-op for common-rate models.
        // LEGACY Nx (1..3): session rate — dilation = hostRate/modelRate
        //                    (NeuralAudio stretches the model's dilations;
        //                    a "4x" Legacy model runs the SAME math per
        //                    sample, just reaches further back in time).
        // TRUE Nx (4..7): Nx * session rate — the model is created for the
        //                    genuine pipeline domain it will process in.
        const int sessionRate = static_cast<int>(rig->sampleRate);
        const int mode = requestedMode;
        // TRUE: absolute target = kTrueBaseRate * N (96k session pinned),
        // immune to the Element wrapper — the model is created for the
        // domain the pipeline will actually run, which is what the incoming
        // rate still lacks (see truePipelineFactor). LEGACY: dilation from
        // the incoming rate — the Element menu keeps affecting it (user
        // decision, 2026-08-29). NONE: pinned 48k.
        const int pipelineFactor = Plugin::truePipelineFactor(mode, rig->sampleRate);
        const int modelRate = mode == Plugin::kOsNone ? 48000
                              : pipelineFactor > 0 ? static_cast<int>(
                                    std::lround(rig->sampleRate * pipelineFactor))
                                                   : sessionRate;
        auto& loader = rig->loaders[stageIndex(message->stage)];
        loader.SetExternalSampleRate(modelRate);
        response.model = loader.CreateFromFile(message->path);
        loader.SetExternalSampleRate(sessionRate);
        // The model must be sized for the largest block it will ever be fed.
        // NeuralAudio sizes internal buffers (WaveNet Eigen matrices, ring
        // buffers) from the loader's DefaultMaxAudioBufferSize at load time;
        // classic WaveNet does NOT chunk in Process (its
        // num_frames <= maxBufferSize assert is compiled out in Release), so
        // a block larger than the sizing overruns those buffers and corrupts
        // the heap. The transient window after ANY mode click is the danger:
        // the audio thread flips its pipeline immediately while the OLD
        // (just replaced) or NEW models keep processing whatever block shape
        // the pipeline now feeds. Size for the worst case (16x = 8192 samples
        // at a 512 max block) in EVERY mode — a few MB per model, no CPU.
        // Do NOT make this mode-conditional; that re-opens the 2026-08-29
        // click-crash (verified via unified-log forensics).
        if (response.model) {
          response.model->SetMaxAudioBufferSize(kMaxOsFactor * rig->maxBufferSize);
          // Maximum-sound policy: always select the full A2/Slimmable tier.
          response.model->SetQualityScaleFactor(1.0f);
          // A model NeuralAudio cannot rate-adapt would otherwise run at the
          // domain rate with weights trained for its own rate. NONE keeps the
          // unadapted reference behaviour on purpose.
          const std::string architecture = modelArchitecture(message->path);
          if (mode != Plugin::kOsNone && !rateAdaptable(architecture)) {
            response.nativeRate = response.model->GetSampleRate();
            lv2_log_note(&rig->logger,
                         "Model '%s' (%s) is not rate-adaptable; it runs at its "
                         "native %.0f Hz inside a resampled domain.\n",
                         message->path, architecture.c_str(), response.nativeRate);
          }
        }
        if (mode == Plugin::kOsNone)
          lv2_log_warning(&rig->logger,
                          "Oversampling NONE: model '%s' runs without rate "
                          "adaptation — a non-48k model at this session rate will "
                          "sound detuned.\n",
                          message->path);
      }
      if (message->stage == Stage::Amp)
        response.fullRig = isFullRigModel(message->path);
      if (response.model || response.ir)
        std::memcpy(response.path, message->path, length + 1);
      // NeuralAudio "oversampling" is dilation scaling: it only adapts the
      // model to the host rate when hostRate % modelRate == 0. Otherwise the
      // model runs at the wrong rate (detuned/wrong tone) — silently. Warn.
      if (response.model && response.nativeRate <= 0.0f) {
        const int stageMode = requestedMode;
        const int pipelineFactor2 = Plugin::truePipelineFactor(stageMode,
                                                                rig->sampleRate);
        const double domainRate = stageMode == Plugin::kOsNone ? 48000.0
                                 : pipelineFactor2 > 0
                                       ? rig->sampleRate * pipelineFactor2
                                       : rig->sampleRate;
        const double modelRate = response.model->GetSampleRate();
        if (modelRate > 0.0 && std::fmod(domainRate, modelRate) > 1e-6)
          lv2_log_warning(&rig->logger,
                          "Model rate %.0f Hz does not evenly divide processing rate %.0f Hz — "
                          "it will run at the wrong rate (detuned). Model: '%s'\n",
                          modelRate, domainRate, message->path);
      }
    }
  } catch (...) {
    delete response.ir;
    delete response.irRight;
    response.model = nullptr;
    response.ir = nullptr;
    response.irRight = nullptr;
  }

  if (!response.model && !response.ir && length > 0)
    lv2_log_error(&rig->logger, "Unable to load rig model: '%s'\n", message->path);

  respond(handle, sizeof(response), &response);
  return LV2_WORKER_SUCCESS;
}

LV2_Worker_Status Plugin::workResponse(LV2_Handle instance, uint32_t size, const void* data) {
  if (!instance || !data || size < sizeof(LV2SwitchModelMsg))
    return LV2_WORKER_ERR_UNKNOWN;

  const auto* message = static_cast<const LV2SwitchModelMsg*>(data);
  if (message->type != kWorkTypeSwitch || !validStage(message->stage))
    return LV2_WORKER_ERR_UNKNOWN;

  auto* rig = static_cast<Plugin*>(instance);
  const size_t index = stageIndex(message->stage);
  if (message->generation != rig->loadGeneration[index]) {
    // A newer path or oversampling request superseded this load while it was
    // running. Dispose of the stale result on the worker thread.
    LV2FreeModelMsg stale{kWorkTypeFree, message->model, message->ir, message->irRight};
    rig->schedule->schedule_work(rig->schedule->handle, sizeof(stale), &stale);
    return LV2_WORKER_SUCCESS;
  }
  rig->respondedGeneration[index] = message->generation;
  const int desiredMode = rig->desiredStageMode(index);
  const int responseMode = Plugin::normalizeLoadMode(message->stage,
                                                     message->oversampleMode);
  if (responseMode != desiredMode) {
    // The mode changed while an initial/path load was in flight, before
    // reloadModelsForOversample() had an installed model to reschedule.
    // Reuse the completed response's path and load it for the latest domain.
    const size_t length = strnlen(message->path, MAX_FILE_NAME);
    rig->scheduleModelLoad(message->stage, message->path, length, desiredMode);
    LV2FreeModelMsg stale{kWorkTypeFree, message->model, message->ir, message->irRight};
    rig->schedule->schedule_work(rig->schedule->handle, sizeof(stale), &stale);
    return LV2_WORKER_SUCCESS;
  }
  auto& pending = rig->pendingSwitches[index];
  if (pending.ready) {
    LV2FreeModelMsg superseded{kWorkTypeFree, pending.model, pending.ir, pending.irRight};
    rig->schedule->schedule_work(rig->schedule->handle,
                                 sizeof(superseded), &superseded);
  }
  pending.model = message->model;
  pending.ir = message->ir;
  pending.irRight = message->irRight;
  pending.oversampleMode = responseMode;
  pending.fullRig = message->fullRig;
  pending.nativeRate = message->nativeRate;
  std::memcpy(pending.path, message->path, MAX_FILE_NAME);
  pending.ready = true;

  // Fade the current chain to zero before changing model pointers or rate
  // domains, then fade the new chain in. This avoids discontinuities without
  // running two heavyweight recurrent model graphs in parallel.
  rig->startTransitionFadeOut();
  return LV2_WORKER_SUCCESS;
}

void Plugin::tunerSetRates(double rate) {
  tuner.decimFactor = std::max(1, (int)std::lround(rate / 12000.0));
  const double dr = rate / tuner.decimFactor;
  tuner.decimRate = (float)dr;
  // Two cascaded RBJ lowpass sections (Q=0.707), cutoff at 0.45 x the
  // decimated Nyquist — clean anti-alias for the decimator.
  const double fc = 0.45 * dr / 2.0;
  const double w0 = 2.0 * 3.14159265358979323846 * fc / dr;
  const double cosw = std::cos(w0);
  const double alpha = std::sin(w0) / (2.0 * 0.7071);
  const double a0 = 1.0 + alpha;
  tuner.lp1.b0 = (float)((1.0 - cosw) / 2.0 / a0);
  tuner.lp1.b1 = (float)((1.0 - cosw) / a0);
  tuner.lp1.b2 = (float)((1.0 - cosw) / 2.0 / a0);
  tuner.lp1.a1 = (float)(-2.0 * cosw / a0);
  tuner.lp1.a2 = (float)((1.0 - alpha) / a0);
  tuner.lp2 = tuner.lp1;
  tuner.resetTracking();
}

void Plugin::process(uint32_t sampleCount, uint64_t deadlineTicks) noexcept {
  cabinetDeadlineTicks = deadlineTicks;
  if (!ports.control || !ports.notify || !ports.audio_in || !ports.audio_out ||
      !ports.audio_out_r || !ports.stereo_width || !ports.room ||
      !ports.presence || !ports.depth || !ports.sag || !ports.bias ||
      !ports.negative_feedback || !ports.bright || !ports.input_eq || !ports.master ||
      !ports.speaker_profile || !ports.speaker_drive || !ports.speaker_compression ||
      !ports.speaker_thump || !ports.speaker_resonance ||
      !ports.input_level || !ports.output_level ||
      !ports.pedal_enabled || !ports.amp_enabled || !ports.cab_enabled || !ports.auto_cab ||
      !ports.tuner_enable || !ports.tuner_note || !ports.tuner_cents ||
      !ports.pedal_oversample || !ports.amp_oversample || !ports.amp_drive ||
      !ports.gate_release || !ports.ir_normalization || !ports.cab_level ||
      !ports.cab_low_cut || !ports.cab_high_cut || !ports.compressor)
    return;
  // NOTE: ports.oversample_mode_legacy (port 19) is intentionally unused —
  // the per-stage ports 20/21 supersede it. It exists only for positional
  // alignment (see the header comment) and session-compat in the TTL.

  blockRounding = std::fegetround();
  rateCache.configure(sampleRate, blockRounding);

  lv2_atom_forge_set_buffer(&forge, reinterpret_cast<uint8_t*>(ports.notify), ports.notify->atom.size);
  lv2_atom_forge_sequence_head(&forge, &sequenceFrame, uris.unitsFrame);

  for (size_t i = 0; i < kStageCount; ++i) {
    if (notifyPending[i]) {
      writePath(static_cast<Stage>(i));
      notifyPending[i] = false;
    }
    // quality_scale port is fixed at 1.0 — never touch the loaders' quality
    // (NeuralAudio's DEFAULT_QUALITY_SCALE of 1.0 = full quality at all times).
  }

  LV2_ATOM_SEQUENCE_FOREACH(ports.control, event) {
    if (event->body.type != uris.atomObject)
      continue;
    const auto* object = reinterpret_cast<const LV2_Atom_Object*>(&event->body);
    if (object->body.otype == uris.patchGet) {
      writeAllPaths();
      continue;
    }
    if (object->body.otype != uris.patchSet)
      continue;

    const LV2_Atom* property = nullptr;
    const LV2_Atom* path = nullptr;
    lv2_atom_object_get(object,
                        uris.patchProperty, &property,
                        uris.patchValue, &path,
                        0);
    if (!property || property->type != uris.atomURID || !path ||
        path->type != uris.atomPath || path->size == 0 || path->size >= MAX_FILE_NAME)
      continue;

    const LV2_URID propertyId = reinterpret_cast<const LV2_Atom_URID*>(property)->body;
    for (size_t i = 0; i < kStageCount; ++i) {
      if (propertyId == uris.stagePath[i]) {
        const Stage stage = static_cast<Stage>(i);
        const int mode = desiredStageMode(i);
        scheduleModelLoad(stage, reinterpret_cast<const char*>(path + 1),
                          path->size - 1, mode);
        break;
      }
    }
  }

  // ---- Input level meter (raw input, before any processing) ----
  // Peak over the block, converted to dBFS, smoothed with a fast-attack /
  // slow-decay ballistics so the meter reads like hardware. Published as a
  // change-gated patch:Set atom (same channel as the tuner) — the UI can
  // show it without the host polling anything.
  {
    float blockPeak = 0.0f;
    for (uint32_t i = 0; i < sampleCount; ++i) {
      const float a = std::fabs(ports.audio_in[i]);
      if (a > blockPeak) blockPeak = a;
    }
    const float blockDb = blockPeak > 1e-9f ? 20.0f * std::log10(blockPeak) : -120.0f;
    // Attack: jump up immediately. Release: fall ~20 dB/s (per-block decay
    // scaled by block duration).
    const float releasePerBlock = 20.0f * (float)sampleCount / (float)sampleRate;
    if (blockDb > meter.lastDb)
      meter.lastDb = blockDb;
    else
      meter.lastDb = std::max(blockDb, meter.lastDb - releasePerBlock);
    // Change-gate: on attack, publish quickly (>=0.25 dB rise, or >=0.1 dB if hot/near clipping > -3 dB)
    // so transient peaks are immediately received by the UI; on decay, publish on >=0.5 dB drift.
    const bool isAttack = meter.lastDb > meter.sentDb;
    const float threshold = (isAttack && meter.lastDb > -3.0f) ? 0.1f
                          : isAttack ? 0.25f : 0.5f;
    if (std::fabs(meter.lastDb - meter.sentDb) >= threshold) {
      meter.sentDb = meter.lastDb;
      LV2_Atom_Forge_Frame frame;
      lv2_atom_forge_frame_time(&forge, 0);
      lv2_atom_forge_object(&forge, &frame, 0, uris.patchSet);
      lv2_atom_forge_key(&forge, uris.patchProperty);
      lv2_atom_forge_urid(&forge, uris.inputDb);
      lv2_atom_forge_key(&forge, uris.patchValue);
      lv2_atom_forge_float(&forge, meter.lastDb);
      lv2_atom_forge_pop(&forge, &frame);
    }
  }

  // ---- Tuner (raw input tap — runs BEFORE gate/trim/stages/EQ) ----
  // Only active while tuner_enable is on. Low-pass + decimate the dry input
  // into a ring buffer, then run McLeod Pitch Method (NSDF) for a robust f0.
  // Results publish on the tuner_note/tuner_cents output ports and as
  // change-gated patch:Set atoms for the UI.
  {
    const bool tunerOn = *ports.tuner_enable >= 0.5f;
    if (!tunerOn && tuner.wasEnabled) tuner.resetTracking();
    tuner.wasEnabled = tunerOn;
    if (tunerOn) {
      const int onsetWindow = std::max(1, (int)std::lround(tuner.decimRate * 0.010f));
      const int attackEnd = (int)std::lround(tuner.decimRate * 0.300f);
      const int sustainStart = attackEnd + Tuner::kWindow + Tuner::kMaxTau;
      const int sustainEnd = (int)std::lround(tuner.decimRate * 1.000f);
      const int tailHold = (int)std::lround(tuner.decimRate * 0.040f);
      for (uint32_t i = 0; i < sampleCount; ++i) {
        const float x = tuner.lp2.process(tuner.lp1.process(ports.audio_in[i]));
        if (++tuner.decimPhase >= tuner.decimFactor) {
          tuner.decimPhase = 0;
          tuner.ring[(size_t)tuner.ringPos] = x;
          tuner.ringPos = (tuner.ringPos + 1) % Tuner::kBuf;
          if (tuner.filled < Tuner::kBuf) ++tuner.filled;
          if (tuner.pluckSamples >= 0 && tuner.pluckSamples < sustainEnd) ++tuner.pluckSamples;
          tuner.onsetEnergy += x * x;
          if (++tuner.onsetSamples >= onsetWindow) {
            const float onsetRms = std::sqrt(tuner.onsetEnergy / tuner.onsetSamples);
            // Measure each pluck's early sustain, not its sharp attack or
            // fading tail. Keep the previous accepted result between plucks.
            if ((onsetRms > 0.006f && onsetRms > 2.0f * tuner.previousRms) ||
                (tuner.pluckSamples < 0 && onsetRms >= 0.003f)) {
              tuner.pluckSamples = 0;
              tuner.pluckPeakRms = onsetRms;
              tuner.measurementClosed = false;
              tuner.hasMeasurement = false;
              tuner.tailSamples = 0;
              tuner.histLen = tuner.histIdx = 0;
              tuner.missCount = 0;
            }
            if (tuner.pluckSamples >= 0) {
              if (tuner.pluckSamples < attackEnd / 3)
                tuner.pluckPeakRms = std::max(tuner.pluckPeakRms, onsetRms);
              else {
                tuner.tailSamples = onsetRms < 0.25f * tuner.pluckPeakRms
                    ? std::min(tuner.tailSamples + onsetWindow, tailHold) : 0;
                if (tuner.pluckSamples >= sustainEnd || tuner.tailSamples >= tailHold)
                  tuner.measurementClosed = true;
              }
            }
            tuner.previousRms = onsetRms;
            tuner.onsetEnergy = 0.0f;
            tuner.onsetSamples = 0;
          }
        }
      }
      // Analyze on a ~30 ms hop (rounded up to the next block boundary)
      // as soon as the ring holds one window+lag span (no full-ring wait).
      const int span = Tuner::kWindow + Tuner::kMaxTau;
      const int hop = (int)(sampleRate * 0.030);
      tuner.samplesSinceAnalysis += (int)sampleCount;
      // Suppress a pending rise even before its 10 ms envelope window ends.
      const bool onsetPending = tuner.onsetSamples > 0 &&
          tuner.onsetEnergy > tuner.onsetSamples *
              std::max(0.006f * 0.006f, 4.0f * tuner.previousRms * tuner.previousRms);
      if (onsetPending || (tuner.pluckSamples >= 0 && tuner.pluckSamples < sustainStart))
        tuner.samplesSinceAnalysis = 0;
      if (tuner.samplesSinceAnalysis >= hop && tuner.filled >= span) {
        const float elapsed = (float)(tuner.samplesSinceAnalysis / sampleRate);
        tuner.samplesSinceAnalysis = 0;
        // Unwrap the most recent window (+ max lag) into linear scratch.
        float* win = tuner.scratch;
        const int start = (tuner.ringPos - span + 2 * Tuner::kBuf) % Tuner::kBuf;
        for (int i = 0; i < span; ++i)
          win[i] = tuner.ring[(size_t)((start + i) % Tuner::kBuf)];

        float energy = 0.0f;
        for (int i = 0; i < Tuner::kWindow; ++i) energy += win[i] * win[i];
        const float rms = std::sqrt(energy / Tuner::kWindow);
        if (rms < 0.003f) {
          // Silence: hold the last reading through short dropouts (pluck
          // transients, damped re-plucks) so the display doesn't blank and
          // re-latch; clear only after kMissLimit consecutive misses.
          if (++tuner.missCount >= Tuner::kMissLimit) {
            tuner.lastNote = -1.0f;
            tuner.histLen = 0;
            tuner.histIdx = 0;
            tuner.hasMeasurement = false;
            tuner.pluckSamples = -1;
            tuner.measurementClosed = true;
          }
        } else {
          // NSDF (McLeod): nsdf[tau] = 2*acf[tau] / m[tau], in [-1, 1].
          // Vectorized: one vDSP_conv (window as signal AND filter) yields
          // acf for every lag at once, and m[tau] = E[0,W) + E[tau,tau+W)
          // comes from a prefix sum of squares — the old O(W * tauMax)
          // scalar burst on the audio thread collapses to one fast conv.
          // vDSP_conv needs signal length (kMaxTau+1) + kWindow - 1 = span.
          DSP::conv(win, win, tuner.acf,
                    Tuner::kMaxTau + 1,
                    Tuner::kWindow);
          {
            double c = 0.0;
            tuner.sqPrefix[0] = 0.0;
            for (int i = 0; i < span; ++i) {
              c += (double)win[i] * win[i];
              tuner.sqPrefix[i + 1] = c;
            }
          }
          const double e0 = tuner.sqPrefix[Tuner::kWindow];
          for (int tau = Tuner::kMinTau; tau <= Tuner::kMaxTau; ++tau) {
            const double m = e0 + tuner.sqPrefix[tau + Tuner::kWindow] -
                             tuner.sqPrefix[tau];
            tuner.nsdf[tau] = m > 0.0 ? (float)(2.0 * tuner.acf[tau] / m) : 0.0f;
          }
          // Local maxima after the first positive zero-crossing; take the
          // FIRST peak within 90% of the best (avoids sub-octave picks).
          int peaks[64];
          int nPeaks = 0;
          bool crossed = false;
          for (int tau = Tuner::kMinTau + 1; tau < Tuner::kMaxTau; ++tau) {
            if (!crossed) {
              if (tuner.nsdf[tau - 1] < 0.0f && tuner.nsdf[tau] >= 0.0f) crossed = true;
              continue;
            }
            if (tuner.nsdf[tau] > tuner.nsdf[tau - 1] &&
                tuner.nsdf[tau] >= tuner.nsdf[tau + 1] && tuner.nsdf[tau] > 0.0f) {
              if (nPeaks < 64) peaks[nPeaks++] = tau;
            }
          }
          int chosen = -1;
          if (nPeaks > 0) {
            float best = 0.0f;
            for (int p = 0; p < nPeaks; ++p)
              if (tuner.nsdf[peaks[p]] > best) best = tuner.nsdf[peaks[p]];
            for (int p = 0; p < nPeaks; ++p)
              if (tuner.nsdf[peaks[p]] >= 0.90f * best) { chosen = peaks[p]; break; }
          }
          float midi = -1.0f;
          // The relative peak rule selects a period, not confidence. Reject
          // weak periodicity rather than chasing noise as a string decays.
          if (chosen > 0 && tuner.nsdf[chosen] >= 0.80f) {
            // Parabolic vertex refinement around the NSDF peak.
            const float s0 = tuner.nsdf[chosen - 1];
            const float s1 = tuner.nsdf[chosen];
            const float s2 = tuner.nsdf[chosen + 1];
            float tauF = (float)chosen;
            const float denom = s0 - 2.0f * s1 + s2;
            if (denom < -1e-9f) {
              float delta = (s0 - s2) / (2.0f * denom);
              delta = std::max(-1.0f, std::min(1.0f, delta));
              tauF += delta;
            }
            const float freq = tuner.decimRate / tauF;
            if (freq >= 55.0f && freq <= 1400.0f)
              midi = 69.0f + 12.0f * std::log2(freq / 440.0f);
          }
          if (midi < 0.0f) {
            // No confident pitch this frame: same short hold as silence.
            if (++tuner.missCount >= Tuner::kMissLimit) {
              tuner.lastNote = -1.0f;
              tuner.histLen = 0;
              tuner.histIdx = 0;
              tuner.hasMeasurement = false;
            }
          } else {
            tuner.missCount = 0;
            if (!tuner.measurementClosed && tuner.pluckSamples >= sustainStart &&
                tuner.pluckSamples < sustainEnd &&
                tuner.previousRms >= 0.25f * tuner.pluckPeakRms) {
              // Median rejects isolated errors; a 250 ms low-pass calms small
              // movements without averaging across genuinely different notes.
              tuner.noteHist[tuner.histIdx] = midi;
              tuner.histIdx = (tuner.histIdx + 1) % 3;
              tuner.histLen = std::min(tuner.histLen + 1, 3);
              if (tuner.histLen >= 3) {
                const float a = tuner.noteHist[0], b = tuner.noteHist[1], c = tuner.noteHist[2];
                const float median = std::max(std::min(a, b), std::min(std::max(a, b), c));
                const float difference = median - tuner.lastNote;
                const float spread = std::max({a, b, c}) - std::min({a, b, c});
                if (!tuner.hasMeasurement) {
                  // Require three agreeing estimates, then snap to this pluck's
                  // reference rather than blending it with the previous pluck.
                  if (spread <= 0.03f) {
                    tuner.lastNote = median;
                    tuner.hasMeasurement = true;
                  }
                } else if (tuner.lastNote < 0.0f ||
                    (std::fabs(difference) >= 0.5f && spread < 0.1f)) {
                  // Relatch a coherent new string immediately, but smooth
                  // mixed-note windows instead of locking onto their pitch.
                  tuner.lastNote = median;
                } else if (std::fabs(difference) > 0.005f) { // half-cent deadband, not an in-tune snap
                  // Faster catch-up for coarse tuning, steady near the target.
                  const float seconds = std::fabs(difference) > 0.25f ? 0.100f : 0.250f;
                  tuner.lastNote += (1.0f - std::exp(-elapsed / seconds)) * difference;
                }
              }
            }
          }
        }
      }
    }
    if (tuner.lastNote >= 0.0f) {
      const int nearest = std::lround(tuner.lastNote);
      tuner.lastCents = std::max(-50.0f, std::min(50.0f, (tuner.lastNote - nearest) * 100.0f));
    } else {
      tuner.lastCents = 0.0f;
    }
    // Publish results: output ports for host polling, plus patch:Set atom
    // events on the notify port for the UI — only when something actually
    // changed (note change or >=1-cent drift) to keep notify traffic low.
    const int noteI = (int)std::lround(tuner.lastNote);
    const int centsQ = (int)std::lround(tuner.lastCents);
    if (noteI != (int)std::lround(tuner.sentNote) || centsQ != (int)tuner.sentCentsQ) {
      tuner.sentNote = tuner.lastNote;
      tuner.sentCentsQ = (float)centsQ;
      LV2_Atom_Forge_Frame frame;
      lv2_atom_forge_frame_time(&forge, 0);
      lv2_atom_forge_object(&forge, &frame, 0, uris.patchSet);
      lv2_atom_forge_key(&forge, uris.patchProperty);
      lv2_atom_forge_urid(&forge, uris.tunerNote);
      lv2_atom_forge_key(&forge, uris.patchValue);
      lv2_atom_forge_float(&forge, tuner.lastNote);
      lv2_atom_forge_pop(&forge, &frame);
      lv2_atom_forge_frame_time(&forge, 0);
      lv2_atom_forge_object(&forge, &frame, 0, uris.patchSet);
      lv2_atom_forge_key(&forge, uris.patchProperty);
      lv2_atom_forge_urid(&forge, uris.tunerCents);
      lv2_atom_forge_key(&forge, uris.patchValue);
      lv2_atom_forge_float(&forge, tuner.lastCents);
      lv2_atom_forge_pop(&forge, &frame);
    }
    *ports.tuner_note = tuner.lastNote;
    *ports.tuner_cents = tuner.lastCents;
  }

  // Before input trim: fast qualified onset, independent tail tracking and
  // mute-aware release. The existing threshold/release controls stay unchanged.
  noiseGate.configure(sampleRate, *ports.gate_threshold, *ports.gate_release);

  const float desiredInput = inputGainCache.get(*ports.input_level, blockRounding);
  float gain = smoothedInputLevel;
  for (uint32_t i = 0; i < sampleCount; ++i) {
    const float in = noiseGate.process(ports.audio_in[i]);
    gain = std::fabs(desiredInput - gain) > kSmoothEpsilon
             ? gain + (desiredInput - gain) * trimSmoothCoeff
             : desiredInput;
    ports.audio_out[i] = in * gain;
  }
  smoothedInputLevel = gain;

  // Feed-forward guitar compressor before the pedal/amp chain.
  // Amount progressively lowers threshold (-12 -> -36 dB), raises ratio
  // (1:1 -> 6:1), and adds up to 6 dB makeup. Attack (1..100 ms, default 8 ms)
  // and release (10..1000 ms, default 120 ms) smooth gain reduction with a 6 dB
  // soft knee to retain pick definition without pumping.
  // Port 184 (compressor_enabled) bypasses the compressor when toggled off.
  const bool compEnabled = !ports.compressor_enabled || *ports.compressor_enabled >= 0.5f;
  const float compAmount = compEnabled
      ? std::max(0.0f, std::min(1.0f, *ports.compressor * 0.01f))
      : 0.0f;
  if (compAmount <= 0.0001f) {
    compressorEnvelope = 0.0f;
    compressorGain = 1.0f;
  } else {
    const float thresholdDb = -12.0f - 24.0f * compAmount;
    const float ratio = 1.0f + 5.0f * compAmount;
    const float makeupDb = 6.0f * compAmount;
    const float attackMs = std::max(0.1f, portValue(ports.compressor_attack, kCompressorAttackDefault));
    const float releaseMs = std::max(1.0f, portValue(ports.compressor_release, kCompressorReleaseDefault));
    compressorTimingCache.configure(sampleRate, attackMs, releaseMs, blockRounding);
    const float envAttack = rateCache.envAttack;
    const float envRelease = rateCache.envRelease;
    const float gainAttack = compressorTimingCache.gainAttack;
    const float gainRelease = compressorTimingCache.gainRelease;
    for (uint32_t i = 0; i < sampleCount; ++i) {
      const float level = std::fabs(ports.audio_out[i]);
      compressorEnvelope += (level - compressorEnvelope) *
          (level > compressorEnvelope ? envAttack : envRelease);
      const float levelDb = compressorEnvelope > 1.0e-9f
          ? 20.0f * std::log10(compressorEnvelope) : -180.0f;
      const float reductionDb = compressorReductionDb(levelDb, thresholdDb,
                                                       ratio, 6.0f);
      const float targetGain = dbToLinear(makeupDb - reductionDb);
      compressorGain += (targetGain - compressorGain) *
          (targetGain < compressorGain ? gainAttack : gainRelease);
      ports.audio_out[i] *= compressorGain;
    }
  }

  // Auto-cab bypass DISABLED (user decision, 2026-08-29): the user manages
  // cab on/off themselves with the ON button, so the cab now always follows
  // cab_enabled — full-rig amp captures no longer silently disconnect the
  // cab stage. The auto_cab port and the cab_auto_bypassed output keep their
  // meanings (cab_auto_bypassed now stays 0) for session/UI compatibility.
  const bool desiredEnabled[kStageCount] = {
      *ports.pedal_enabled >= 0.5f,
      *ports.amp_enabled >= 0.5f,
      *ports.cab_enabled >= 0.5f,
      portValue(ports.cab2_enabled, 0.0f) >= 0.5f};
  if (ports.cab_auto_bypassed)
    *ports.cab_auto_bypassed = 0.0f;

  // A .nam Cab A shares the amp's True domain alone, but runs at the session
  // rate next to Cab B. Engaging or dropping Cab B therefore reloads Cab A for
  // the other domain; the swap lands through the usual fade.
  {
    const size_t cab = stageIndex(Stage::Cab);
    const size_t cab2 = stageIndex(Stage::Cab2);
    const bool parallelDesired = desiredEnabled[cab2] &&
        (models[cab2] || irs[cab2] || pendingSwitches[cab2].ready);
    if (!cabParallelLatched) {
      cabParallelDesired = parallelDesired;
      cabParallelLatched = true;
    } else if (parallelDesired != cabParallelDesired) {
      cabParallelDesired = parallelDesired;
      const int mode = desiredStageMode(cab);
      const auto& pending = pendingSwitches[cab];
      if (pending.ready) {
        // The pending switch is the newest request: re-domain a pending model,
        // never revive a model that a pending unload or IR is replacing.
        const size_t length = strnlen(pending.path, MAX_FILE_NAME);
        if (pending.model && length > 0 && pending.oversampleMode != mode)
          scheduleModelLoad(Stage::Cab, pending.path, length, mode);
      } else if (loadGeneration[cab] == respondedGeneration[cab] && models[cab] &&
                 !irs[cab] && osApplied[cab] != mode && !modelPaths[cab].empty() &&
                 modelPaths[cab].size() < MAX_FILE_NAME) {
        // No load is in flight (one in flight re-domains itself in
        // workResponse), so re-create the installed model for the new domain.
        scheduleModelLoad(Stage::Cab, modelPaths[cab].c_str(), modelPaths[cab].size(), mode);
      }
    }
  }

  // An enable toggle switches a (possibly high-gain) stage in or out mid
  // waveform — a click. Latch the toggles through the same equal-power fade
  // as a model swap: fade out, apply at the zero crossing, fade back in.
  if (!enabledLatched) {
    for (size_t st = 0; st < kStageCount; ++st)
      appliedEnabled[st] = desiredEnabled[st];
    enabledLatched = true;
  } else {
    for (size_t st = 0; st < kStageCount; ++st) {
      if (desiredEnabled[st] != appliedEnabled[st]) {
        startTransitionFadeOut();
        break;
      }
    }
  }
  const auto& enabled = appliedEnabled;

  for (size_t i = 0; i < kRackCount; ++i) {
    const float value = portValue(ports.rack_enabled[i], 1.0f);
    requestedRacks[i] = !std::isfinite(value) || value >= 0.5f;
  }
  if (!racksLatched) {
    appliedRacks = requestedRacks;
    racksLatched = true;
  }
  const auto rackOn = [&](Rack rack) { return appliedRacks[static_cast<size_t>(rack)]; };

  const float tubeSelection = portValue(ports.power_tube_type, 0.0f);
  const int desiredTube = std::isfinite(tubeSelection)
      ? PowerTube::clampProfile(static_cast<int>(std::clamp(tubeSelection, 0.0f,
            static_cast<float>(PowerTube::kProfileCount - 1)) + 0.5f))
      : PowerTube::kCaptured;
  const float tubeCharacter = PowerTube::clampCharacter(
      portValue(ports.power_tube_character, kPowerTubeCharacterDefault));
  if (!tubeLatched) {
    tubeRequested = tubeApplied = desiredTube;
    tubeLatched = true;
  } else if (desiredTube != tubeRequested) {
    tubeRequested = desiredTube;
    const bool audibleTube = rackOn(Rack::PowerTube) &&
        models[stageIndex(Stage::Amp)] && appliedEnabled[stageIndex(Stage::Amp)] &&
        (ampAdvanced.hasTubeCharacter() || (tubeCharacter > 0.0f &&
            (tubeApplied != PowerTube::kCaptured || tubeRequested != PowerTube::kCaptured)));
    if (audibleTube) {
      startTransitionFadeOut();
    } else {
      // Offline/neutral edits must not disturb the shared legacy Power envelope.
      tubeApplied = tubeRequested;
    }
  }
  // Both OFF skips post-amp processing, so clear only the inactive tube's
  // character here. The shared Power filters, smoothers and envelope stay intact.
  if (!rackOn(Rack::PowerTube) || tubeApplied == PowerTube::kCaptured)
    ampAdvanced.resetTubeCharacter();

  // Output-transformer profiles are part of the amp block.  Changes use the
  // same click-safe zero crossing as model and bypass changes; the existing
  // capture remains bit-identical by default (profile 0).
  const float transformerSelection = portValue(ports.transformer_type, 0.0f);
  const int desiredTransformer = std::isfinite(transformerSelection)
      ? static_cast<int>(std::clamp(transformerSelection, 0.0f,
            static_cast<float>(OutputTransformer::kBassIron)) + 0.5f)
      : OutputTransformer::kCaptured;
  TransformerAdjustments transformerAdjustments;
  for (size_t i = 0; i < transformerAdjustments.size(); ++i) {
    const auto& c = kTransformerControls[i];
    const float value = portValue(ports.transformer_adjustments[i], c.defaultValue);
    transformerAdjustments[i] = std::isfinite(value)
        ? std::clamp(value, c.minimum, c.maximum) : c.defaultValue;
  }
  if (!transformerLatched) {
    transformerRequested = transformerApplied = desiredTransformer;
    transformerLatched = true;
  } else if (desiredTransformer != transformerRequested) {
    transformerRequested = desiredTransformer;
    if (models[stageIndex(Stage::Amp)] && appliedEnabled[stageIndex(Stage::Amp)] &&
        rackOn(Rack::Transformer)) {
      startTransitionFadeOut();
    } else {
      // With no active amp there is no transformer signal/state to protect,
      // so avoid needlessly dipping an otherwise dry/bypassed chain.
      transformerApplied = transformerRequested;
      outputTransformer.reset();
    }
  }

  // Generic speaker-load interaction is opt-in. Auto resolves from the
  // committed cab path without changing the host-visible profile selection.
  int desiredSpeaker = SpeakerDynamics::clampProfile(
      static_cast<int>(*ports.speaker_profile + 0.5f));
  if (desiredSpeaker == SpeakerDynamics::kAuto) {
    // Cab A names the profile; Cab B takes over when Cab A is absent or when
    // Cab A's file name matches no profile family.
    const bool cabAActive = appliedEnabled[2] && (models[2] || irs[2]);
    const bool cabBActive = appliedEnabled[3] && (models[3] || irs[3]) &&
                            !modelPaths[3].empty();
    desiredSpeaker = SpeakerDynamics::profileFromCabPath(modelPaths[2].c_str());
    if (cabBActive && (!cabAActive || desiredSpeaker == SpeakerDynamics::kResistive))
      desiredSpeaker = SpeakerDynamics::profileFromCabPath(modelPaths[3].c_str());
  }
  if (!speakerLatched) {
    speakerRequested = speakerApplied = desiredSpeaker;
    speakerLatched = true;
  } else if (desiredSpeaker != speakerRequested) {
    speakerRequested = desiredSpeaker;
    if (models[stageIndex(Stage::Amp)] && appliedEnabled[stageIndex(Stage::Amp)] &&
        rackOn(Rack::Speaker)) {
      startTransitionFadeOut();
    } else {
      speakerApplied = speakerRequested;
      speakerDynamics.reset();
    }
  }

  // Do not change wet-tail routing halfway through an existing model fade.
  if (requestedRacks != appliedRacks && transitionPhase == TransitionPhase::Steady) {
    rackTransitionActive = true;
    startTransitionFadeOut();
  }

  // ---- Oversample mode change detection (per stage) ----
  // Models carry their rate domain baked in at load time (dilation factor
  // and/or created at Nx * sessionRate), so any mode change re-sends the
  // loaded paths through the worker. Until a matching swap lands, osApplied
  // keeps the stage and its old model in their existing processing domain.
  // The cab (index 2) rides the amp's domain, so only pedal/amp are watched.
  bool oversampleChanged = false;
  for (size_t st = 0; st < 2; ++st) {
    const int mode = stageOversample(st);
    if (mode != osRequested[st]) {
      osRequested[st] = mode;
      oversampleChanged = true;
    }
  }
  if (oversampleChanged)
    reloadModelsForOversample();

  // Converter histories belong to a particular grouping of active stages.
  // If bypass, model presence, cab type, or an applied factor changes, a
  // group may acquire a different owner bank; reset all histories instead of
  // reusing stale samples from the last time that bank happened to run.
  uint64_t topology = 0;
  for (size_t st = 0; st < kStageCount; ++st) {
    const uint64_t state = (enabled[st] ? 1u : 0u)
                         | (models[st] ? 2u : 0u)
                         | (irs[st] ? 4u : 0u)
                         | ((uint64_t)(truePipelineFactor(osApplied[st], sampleRate) + 1) << 3)
                         | ((uint64_t)nativeDecimation(st) << 8);
    topology |= state << (st * 16);
  }
  if (topology != osTopologySignature) {
    osTopologySignature = topology;
    for (auto& stageUp : osUp)
      for (auto& up : stageUp) up.reset();
    for (auto& stageDown : osDown)
      for (auto& down : stageDown) down.reset();
    for (size_t st = 0; st < kStageCount; ++st) resetNativeStream(st);
  }

  // ---- Stage processing with per-stage oversample domains ----
  // TRUE-Nx stages run inside a genuine UP -> model@Nx -> DOWN cascade
  // (chain of 2x half-band pairs). NONE and LEGACY stages run at base rate.
  // The nonlinear stages are the aliasing sources, so only they get TRUE
  // domains; the cab WAV IR and EQ stay at base rate. A .nam cab follows the
  // AMP's TRUE factor. With a second cabinet engaged, Cab A uses an independent
  // True domain from the shared post-amp tap and Cab B is delayed to match it.
  const bool parallelCabs = enabled[3] && (models[3] || irs[3]);
  const PinBands sculptPinBands = pinBands(PinEqPane::Sculpt);
  const PinBands transformerPinBands = pinBands(PinEqPane::Transformer);
  const PinBands speakerPinBands = pinBands(PinEqPane::Speaker);
  float blockPreAmpPeak = 0.0f;
  float blockPostAmpPeak = 0.0f;
  bool ampMetersCapturedThisSlice = false;
  auto applyModel = [&](size_t stage, NeuralAudio::NeuralModel* model,
                        float* samples, size_t count, double domainRate) {
    if (stage == 1) {
      // The overdrive is a pedal in front of the amp, so it precedes Amp Drive.
      const bool odOn = portValue(ports.od_enabled, 0.0f) >= 0.5f;
      overdrive.process(samples, count, domainRate, portValue(ports.od_drive, 0.0f),
                        portValue(ports.od_tone, Overdrive::kToneDefault),
                        portValue(ports.od_level, 0.0f), odOn);
      const float target = ampGainCache.get(*ports.amp_drive, blockRounding);
      const float coeff = ampDriveRateCache.get(domainRate, blockRounding);
      for (size_t i = 0; i < count; ++i) {
        smoothedAmpDrive += (target - smoothedAmpDrive) * coeff;
        samples[i] *= smoothedAmpDrive;
      }
      if (rackOn(Rack::Sculpt)) {
        ampAdvanced.processPreAmp(samples, count, domainRate,
                                  *ports.bright, *ports.input_eq,
                                  portValue(ports.mid_push, 0.0f));
        float* channels[1] = {samples};
        sculptPins.process(channels, 1, count, domainRate, sculptPinBands);
      }
      for (size_t i = 0; i < count; ++i) {
        const float a = std::fabs(samples[i]);
        if (a > blockPreAmpPeak) blockPreAmpPeak = a;
      }
    }
    runModel(stage, model, samples, count, domainRate);
    if (stage == stageIndex(Stage::Amp)) {
      const bool powerOn = rackOn(Rack::Power);
      const int tubeProfile = rackOn(Rack::PowerTube) ? tubeApplied : PowerTube::kCaptured;
      const bool activeTube = tubeProfile != PowerTube::kCaptured &&
          (tubeCharacter > 0.0f || ampAdvanced.hasTubeCharacter());
      if (powerOn || activeTube)
        ampAdvanced.processPostAmp(samples, count, domainRate,
                                  powerOn ? *ports.presence : 0.0f,
                                  powerOn ? *ports.depth : 0.0f,
                                  powerOn ? *ports.sag : 0.0f,
                                  powerOn ? *ports.bias : 0.0f,
                                  powerOn ? *ports.negative_feedback : 0.0f,
                                  powerOn ? *ports.master : 0.0f,
                                  tubeProfile, tubeCharacter);
      if (rackOn(Rack::Transformer)) {
        outputTransformer.process(samples, count, domainRate, transformerApplied,
                                transformerAdjustments);
        float* channels[1] = {samples};
        transformerPins.process(channels, 1, count, domainRate, transformerPinBands);
      }
      if (rackOn(Rack::Speaker)) {
        speakerDynamics.process(samples, count, domainRate, speakerApplied,
                              *ports.speaker_drive, *ports.speaker_compression,
                              *ports.speaker_thump, *ports.speaker_resonance,
                                rackOn(Rack::Power) ? *ports.negative_feedback * 0.01f : 0.0f);
        float* channels[1] = {samples};
        speakerPins.process(channels, 1, count, domainRate, speakerPinBands);
      }
      // Capture in the amp's domain, before a grouped NAM cabinet or decimation.
      for (size_t i = 0; i < count; ++i)
        blockPostAmpPeak = std::max(blockPostAmpPeak, std::fabs(samples[i]));
      ampMetersCapturedThisSlice = true;
    }
  };

  // Process one or more consecutive models inside ONE TRUE domain. `owner`
  // supplies this group's streaming converter state; stages[] remains in
  // signal-chain order.
  auto processTrueGroup = [&](size_t owner, const size_t* stages,
                              size_t stageCount, float* samples,
                              uint32_t count, int f) -> uint32_t {
    const size_t levels = cascadeLevels(f);
    float* bufs[2] = {osScratch[owner].data(), osScratch2[owner].data()};
    size_t n = osUp[owner][0].process(samples, count, bufs[0]);
    for (size_t c = 1; c < levels && n > 0; ++c)
      n = osUp[owner][c].process(bufs[(c - 1) % 2], n, bufs[c % 2]);
    float* domain = bufs[(levels - 1) % 2];
    if (n == 0 || n + 64 > osScratch[owner].size())
      return count;
    for (size_t i = 0; i < stageCount; ++i)
      applyModel(stages[i], models[stages[i]], domain, n, sampleRate * f);

    size_t back = n;
    const float* dnIn = domain;
    for (size_t c = levels; c-- > 0;) {
      float* dnOut = (c == 0) ? samples : bufs[(c - 1) % 2];
      back = osDown[owner][c].process(dnIn, back, dnOut);
      dnIn = dnOut;
    }
    if (back < count) {
      const float fill = back > 0 ? samples[back - 1] : samples[0];
      for (size_t i = back; i < count; ++i) samples[i] = fill;
    }
    return static_cast<uint32_t>(back);
  };

  // ---- Chain NAM stages, merging adjacent compatible TRUE domains ----
  // The chain runs in maxBufferSize slices so a host that exceeds the
  // negotiated maxBlockLength cannot overrun NeuralAudio's fixed buffers.
  float* chain = osChain.data();
  bool cabProcessed = false;
  bool modelProcessed = false;
  uint32_t latencyFrames = 0;
  const uint32_t sliceMax = static_cast<uint32_t>(std::max(1, maxBufferSize));
  for (uint32_t off = 0; off < sampleCount; off += sliceMax) {
    const uint32_t sliceLen = std::min(sliceMax, sampleCount - off);
    float* io = ports.audio_out + off;
    std::memcpy(chain, io, sliceLen * sizeof(float));
    uint32_t n = sliceLen;
    ampMetersCapturedThisSlice = false;
    for (size_t st = 0; st < kSerialStageCount;) {
      if (st == 2 && !ampMetersCapturedThisSlice) {
        // With no active amp, both boundaries carry the post-pedal signal.
        for (uint32_t i = 0; i < sliceLen; ++i) {
          const float a = std::fabs(chain[i]);
          if (a > blockPreAmpPeak) blockPreAmpPeak = a;
          if (a > blockPostAmpPeak) blockPostAmpPeak = a;
        }
        ampMetersCapturedThisSlice = true;
      }

      const bool deferredCab = st == 2 && (irs[2] != nullptr || parallelCabs);
      if (!enabled[st] || !models[st] || deferredCab) {
        ++st;
        continue;
      }

      // Non-adaptable models (LSTM, ...) run at their own rate: decimate the
      // session stream, process, interpolate back. Same rate = plain base path.
      const int decimation = nativeDecimation(st);
      if (decimation > 0) {
        if (decimation > 1) {
          n = runNativeDomain(st, chain, n, decimation,
                              [&](float* domain, uint32_t m, double rate) {
                                applyModel(st, models[st], domain, m, rate);
                              });
          if (off == 0) latencyFrames += nativeLatencyFrames(decimation);
        } else {
          applyModel(st, models[st], chain, n, sampleRate);
        }
        modelProcessed = true;
        if (st == 2) cabProcessed = true;
        ++st;
        continue;
      }

      const int f = truePipelineFactor(osApplied[st], sampleRate);
      if (f <= 1) {
        applyModel(st, models[st], chain, n, sampleRate);
        modelProcessed = true;
        if (st == 2) cabProcessed = true;
        ++st;
        continue;
      }

      size_t group[kSerialStageCount] = {st, 0, 0};
      size_t groupCount = 1;
      size_t next = st + 1;
      while (next < kSerialStageCount && enabled[next] && models[next] &&
             !(next == 2 && (irs[2] || parallelCabs)) &&
             nativeDecimation(next) == 0 &&
             truePipelineFactor(osApplied[next], sampleRate) == f) {
        group[groupCount++] = next++;
      }
      n = processTrueGroup(st, group, groupCount, chain, n, f);
      modelProcessed = true;
      if (off == 0) latencyFrames += cascadeLatencyFrames(f);
      if (group[groupCount - 1] == 2) cabProcessed = true;
      st = next;
    }
    if (!ampMetersCapturedThisSlice) {
      for (uint32_t i = 0; i < sliceLen; ++i) {
        const float a = std::fabs(chain[i]);
        if (a > blockPreAmpPeak) blockPreAmpPeak = a;
        if (a > blockPostAmpPeak) blockPostAmpPeak = a;
      }
    }
    std::memcpy(io, chain, sliceLen * sizeof(float));
  }
  // Parallel cabinets normally share the session-rate domain and add nothing.
  // While a Cab A reload for that domain is still in flight it keeps its own
  // True cascade, and a native-rate cabinet model keeps its resampling
  // domain; the longer branch is reported and the other branch is delayed to
  // match it in processPostChain.
  if (parallelCabs) {
    uint32_t extraA = 0, extraB = 0;
    parallelCabExtras(extraA, extraB);
    latencyFrames += std::max(extraA, extraB);
  }
  if (ports.latency)
    *ports.latency = static_cast<float>(latencyFrames);

  processPostChain(ports.audio_out, sampleCount, cabProcessed, modelProcessed,
                   desiredEnabled);

  // ---- Pre-amp level meter (after pedal + pre-amp sculpt, before amp model) ----
  {
    const float blockDb = blockPreAmpPeak > 1e-9f ? 20.0f * std::log10(blockPreAmpPeak) : -120.0f;
    const float releasePerBlock = 20.0f * (float)sampleCount / (float)sampleRate;
    if (blockDb >= preAmpMeter.lastDb)
      preAmpMeter.lastDb = blockDb;
    else
      preAmpMeter.lastDb = std::max(blockDb, preAmpMeter.lastDb - releasePerBlock);
    if (std::fabs(preAmpMeter.lastDb - preAmpMeter.sentDb) >= 0.5f) {
      preAmpMeter.sentDb = preAmpMeter.lastDb;
      LV2_Atom_Forge_Frame frame;
      lv2_atom_forge_frame_time(&forge, 0);
      lv2_atom_forge_object(&forge, &frame, 0, uris.patchSet);
      lv2_atom_forge_key(&forge, uris.patchProperty);
      lv2_atom_forge_urid(&forge, uris.preAmpDb);
      lv2_atom_forge_key(&forge, uris.patchValue);
      lv2_atom_forge_float(&forge, preAmpMeter.lastDb);
      lv2_atom_forge_pop(&forge, &frame);
    }
  }

  // ---- Post-amp level meter (after amp + post-amp effects, before cabinet) ----
  {
    const float blockDb = blockPostAmpPeak > 1e-9f ? 20.0f * std::log10(blockPostAmpPeak) : -120.0f;
    const float releasePerBlock = 20.0f * (float)sampleCount / (float)sampleRate;
    if (blockDb >= postAmpMeter.lastDb)
      postAmpMeter.lastDb = blockDb;
    else
      postAmpMeter.lastDb = std::max(blockDb, postAmpMeter.lastDb - releasePerBlock);
    if (std::fabs(postAmpMeter.lastDb - postAmpMeter.sentDb) >= 0.5f) {
      postAmpMeter.sentDb = postAmpMeter.lastDb;
      LV2_Atom_Forge_Frame frame;
      lv2_atom_forge_frame_time(&forge, 0);
      lv2_atom_forge_object(&forge, &frame, 0, uris.patchSet);
      lv2_atom_forge_key(&forge, uris.patchProperty);
      lv2_atom_forge_urid(&forge, uris.postAmpDb);
      lv2_atom_forge_key(&forge, uris.patchValue);
      lv2_atom_forge_float(&forge, postAmpMeter.lastDb);
      lv2_atom_forge_pop(&forge, &frame);
    }
  }
}

void Plugin::runModel(size_t stage, NeuralAudio::NeuralModel* model,
                      float* samples, size_t count, double domainRate) noexcept {
  const float pre = modelInputGainCache[stage].get(
      model->GetRecommendedInputDBAdjustment(), blockRounding);
  if (pre != 1.0f)
    for (size_t i = 0; i < count; ++i) samples[i] *= pre;
  // Cab B may already be running on a different executor. Only the callback's
  // serial stages own the phase pool, including independently oversampled Cab A.
  if (polyphaseWorker && stage != stageIndex(Stage::Cab2)) {
    polyphaseWorker->setDeadline(cabinetDeadlineTicks);
    polyphaseWorker->process(model, samples, samples, count);
  } else {
    model->Process(samples, samples, count);
  }
  const float post = modelOutputGainCache[stage].get(
      model->GetRecommendedOutputDBAdjustment(), blockRounding);
  if (post != 1.0f)
    for (size_t i = 0; i < count; ++i) samples[i] *= post;
  if (std::fabs(stageDcRate[stage] - domainRate) > 0.5) {
    stageDc[stage].setRate(domainRate);
    stageDc[stage].reset();
    stageDcRate[stage] = domainRate;
  }
  for (size_t i = 0; i < count; ++i)
    samples[i] = stageDc[stage].process(samples[i]);
}

uint32_t Plugin::processTrueCab(size_t stage, float* samples, uint32_t count,
                               int factor) noexcept {
  const size_t levels = cascadeLevels(factor);
  float* bufs[2] = {osScratch[stage].data(), osScratch2[stage].data()};
  size_t n = osUp[stage][0].process(samples, count, bufs[0]);
  for (size_t level = 1; level < levels && n > 0; ++level)
    n = osUp[stage][level].process(bufs[(level - 1) % 2], n,
                                   bufs[level % 2]);
  float* domain = bufs[(levels - 1) % 2];
  if (n == 0 || n + 64 > osScratch[stage].size()) return count;
  runModel(stage, models[stage], domain, n, sampleRate * factor);

  size_t back = n;
  const float* downInput = domain;
  for (size_t level = levels; level-- > 0;) {
    float* downOutput = level == 0 ? samples : bufs[(level - 1) % 2];
    back = osDown[stage][level].process(downInput, back, downOutput);
    downInput = downOutput;
  }
  if (back < count) {
    const float fill = back > 0 ? samples[back - 1] : samples[0];
    for (size_t i = back; i < count; ++i) samples[i] = fill;
  }
  return static_cast<uint32_t>(back);
}

void Plugin::processCabB(float* samples, uint32_t count) noexcept {
  constexpr size_t kCabB = stageIndex(Stage::Cab2);
  const int decimation = nativeDecimation(kCabB);
  if (decimation > 1)
    runNativeDomain(kCabB, samples, count, decimation,
                    [this](float* domain, uint32_t m, double rate) noexcept {
                      runModel(kCabB, models[kCabB], domain, m, rate);
                    });
  else
    runModel(kCabB, models[kCabB], samples, count, sampleRate);
}

void Plugin::parallelCabExtras(uint32_t& extraA, uint32_t& extraB) const noexcept {
  extraA = extraB = 0;
  if (appliedEnabled[2] && models[2] && !irs[2]) {
    const int decimation = nativeDecimation(2);
    if (decimation > 1) {
      extraA = nativeLatencyFrames(decimation);
    } else {
      const int factor = truePipelineFactor(osApplied[2], sampleRate);
      if (factor > 1) extraA = cascadeLatencyFrames(factor);
    }
  }
  if (models[3] && !irs[3]) {
    const int decimation = nativeDecimation(3);
    if (decimation > 1) extraB = nativeLatencyFrames(decimation);
  }
}

// Everything after the serial NAM chain: the parallel cabinet pair, the cab
// trim and cuts, DC removal, post EQ, output trim, the click-safe transition
// fade, and the stereo effects. Runs in maxBufferSize slices on internal
// stereo buffers, so the two output ports may alias.
PinBands Plugin::pinBands(PinEqPane pane) const noexcept {
  return readPinBands(pane, [&](uint32_t port) {
    return portValue(ports.pin_eq[port - kPinEqFirstPort], pinEqDefault(port));
  });
}

void Plugin::processPostChain(float* mono, uint32_t count, bool cabInChain,
                              bool modelProcessed, const bool* desiredEnabled) noexcept {
  const auto& enabled = appliedEnabled;
  const auto rackOn = [&](Rack rack) { return appliedRacks[static_cast<size_t>(rack)]; };
  const bool consoleOn = rackOn(Rack::CabConsole);
  const bool spatialOn = rackOn(Rack::Spatial);
  const bool reverbOn = rackOn(Rack::Reverb);
  const bool parallelCabs = enabled[3] && (models[3] || irs[3]);
  const PinBands consolePinBands = pinBands(PinEqPane::CabConsole);
  const int norm = decodeIrNormalization(*ports.ir_normalization);
  const uint32_t sliceMax = static_cast<uint32_t>(std::max(1, maxBufferSize));
  const float widthTarget = std::max(0.0f, std::min(1.0f, *ports.stereo_width * 0.01f));
  const float rawCab2Db = portValue(ports.cab2_level, 0.0f);
  const float cab2LevelTarget = rawCab2Db <= -23.95f ? 0.0f : cab2GainCache.get(rawCab2Db, blockRounding);
  const float glide10 = rateCache.glide10;
  const float chunkGlide = rateCache.chunkGlide;
  const float desiredOutput = outputGainCache.get(*ports.output_level, blockRounding);
  const float rawCabDb = *ports.cab_level;
  const float targetCab = rawCabDb <= -23.95f ? 0.0f : cabGainCache.get(rawCabDb, blockRounding);
  const float alignmentMs = consoleOn ? std::max(-10.0f, std::min(10.0f,
      portValue(ports.cab2_delay, 0.0f))) : 0.0f;
  const float polarityTarget = portValue(ports.cab2_polarity, 0.0f) >= 0.5f
      ? -1.0f : 1.0f;
  const uint32_t fadeSamples = std::max<uint32_t>(1,
      static_cast<uint32_t>(std::lround(sampleRate * 0.005)));
  bool commitRequested = false;
  bool cabProcessedAny = cabInChain;

  if (!parallelCabs && cab2AlignActive) {
    cab2Align.reset();
    cab2AlignActive = false;
  }
  if (!parallelCabs) smoothedCab2Polarity = polarityTarget;

  for (uint32_t off = 0; off < count; off += sliceMax) {
    const uint32_t n = std::min(sliceMax, count - off);
    float* L = postL.data();
    float* R = postR.data();
    std::memcpy(L, mono + off, n * sizeof(float));
    bool cabProcessed = cabInChain;
    bool haveA = cabInChain;
    bool stereoA = false;
    if (parallelCabs) std::memcpy(preCab.data(), L, n * sizeof(float));

    struct CabJob {
      Plugin* plugin;
      float* samples;
      uint32_t count;
    } job{this, cabBL.data(), n};
    bool cabBDispatched = false;
    if (cabinetWorker && parallelCabs && enabled[2] && models[2] && !irs[2] &&
        models[3] && !irs[3]) {
      std::memcpy(job.samples, preCab.data(), n * sizeof(float));
      cabBDispatched = cabinetWorker->submit([](void* context) noexcept {
        auto& j = *static_cast<CabJob*>(context);
        j.plugin->processCabB(j.samples, j.count);
      }, &job, cabinetDeadlineTicks);
    }

    uint32_t extraA = 0, extraB = 0;
    parallelCabExtras(extraA, extraB);

    if (enabled[2]) {
      if (irs[2]) {
        if (irsRight[2]) {
          std::memcpy(R, L, n * sizeof(float));
          irsRight[2]->process(R, n, norm);
          stereoA = true;
        }
        irs[2]->process(L, n, norm);
        cabProcessed = true;
      } else if (models[2] && parallelCabs) {
        // Steady state is the session rate. A True domain only persists while
        // the session-rate reload is in flight; native-rate models resample.
        const int decimation = nativeDecimation(2);
        const int factor = truePipelineFactor(osApplied[2], sampleRate);
        if (decimation > 1)
          runNativeDomain(2, L, n, decimation,
                          [this](float* domain, uint32_t m, double rate) noexcept {
                            runModel(2, models[2], domain, m, rate);
                          });
        else if (factor > 1) processTrueCab(2, L, n, factor);
        else runModel(2, models[2], L, n, sampleRate);
        cabProcessed = true;
      }
      haveA = cabProcessed;
    }
    if (!stereoA) std::memcpy(R, L, n * sizeof(float));
    if (haveA && consoleOn) {
      for (uint32_t i = 0; i < n; ++i) {
        smoothedCabLevel += (targetCab - smoothedCabLevel) * glide10;
        L[i] *= smoothedCabLevel;
        R[i] *= smoothedCabLevel;
      }
    }
    if (haveA && parallelCabs) {
      // Delay either capture without subtracting its own converter latency
      // from the other branch's compensation. Zero-delay calls maintain
      // history for sign flips.
      const float cabADomainDelayMs = extraB > extraA
          ? static_cast<float>(1000.0 * (extraB - extraA) / sampleRate) : 0.0f;
      cabAlign.process(L, R, n, std::max(-alignmentMs, 0.0f) + cabADomainDelayMs);
      cabAlignActive = true;
    } else if (cabAlignActive) {
      cabAlign.reset();
      cabAlignActive = false;
    }

    bool haveB = false;
    if (parallelCabs) {
      float* BL = cabBL.data();
      float* BR = cabBR.data();
      if (!cabBDispatched) std::memcpy(BL, preCab.data(), n * sizeof(float));
      if (irs[3]) {
        if (irsRight[3]) {
          std::memcpy(BR, BL, n * sizeof(float));
          irsRight[3]->process(BR, n, norm);
        }
        irs[3]->process(BL, n, norm);
        if (!irsRight[3]) std::memcpy(BR, BL, n * sizeof(float));
      } else {
        // Always finish the published job before touching B, switching models,
        // or leaving this slice. A timeout cannot safely retry recurrent DSP.
        if (cabBDispatched) cabinetWorker->wait();
        else processCabB(BL, n);
        std::memcpy(BR, BL, n * sizeof(float));
      }
      const float domainDelayMs = haveA && extraA > extraB
          ? static_cast<float>(1000.0 * (extraA - extraB) / sampleRate) : 0.0f;
      cab2Align.process(BL, BR, n,
                        std::max(alignmentMs, 0.0f) + domainDelayMs);
      cab2AlignActive = true;
      if (consoleOn) for (uint32_t i = 0; i < n; ++i) {
        smoothedCab2Level += (cab2LevelTarget - smoothedCab2Level) * glide10;
        // Snap above float-rounding stalls so equal captures can fully cancel
        // and returning to normal restores an exact +1 gain.
        glideValue(smoothedCab2Polarity, polarityTarget, glide10, 1.0e-3f);
        const float cabBGain = smoothedCab2Level * smoothedCab2Polarity;
        BL[i] *= cabBGain;
        BR[i] *= cabBGain;
      }
      haveB = true;
      cabProcessed = true;
    }

    // Width: the equal-power spread between cabinet A (left) and cabinet B
    // (right). Each cabinet keeps its own stereo image at every setting; zero
    // sums both cabinets to the same dual-mono blend Spatial OFF uses.
    if (!spatialOn) {
      // Cabinet routing remains active, without mono collapse or width panning.
      if (haveA && haveB) {
        const float gain = std::sqrt(0.5f);
        for (uint32_t i = 0; i < n; ++i) {
          L[i] = (L[i] + cabBL[i]) * gain;
          R[i] = (R[i] + cabBR[i]) * gain;
        }
      } else if (haveB) {
        std::memcpy(L, cabBL.data(), n * sizeof(float));
        std::memcpy(R, cabBR.data(), n * sizeof(float));
      }
    } else if (haveA && haveB && smoothedWidth == widthTarget) {
      // Once settled, the original smoother is a no-op. Use one exact gain
      // pair for the slice rather than rechecking Width for every sample.
      widthGainCache.configure(smoothedWidth, blockRounding);
      const float gainNear = widthGainCache.near;
      const float gainFar = widthGainCache.far;
      for (uint32_t i = 0; i < n; ++i) {
        const float outL = L[i] * gainNear + cabBL[i] * gainFar;
        const float outR = R[i] * gainFar + cabBR[i] * gainNear;
        L[i] = outL;
        R[i] = outR;
      }
    } else {
      const float* BL = cabBL.data();
      const float* BR = cabBR.data();
      for (uint32_t i = 0; i < n; ++i) {
        smoothedWidth += (widthTarget - smoothedWidth) * glide10;
        if (std::fabs(widthTarget - smoothedWidth) < 1.0e-4f) smoothedWidth = widthTarget;
        if (haveA && haveB) {
          widthGainCache.configure(smoothedWidth, blockRounding);
          const float gainNear = widthGainCache.near;
          const float gainFar = widthGainCache.far;
          const float outL = L[i] * gainNear + BL[i] * gainFar;
          const float outR = R[i] * gainFar + BR[i] * gainNear;
          L[i] = outL;
          R[i] = outR;
        } else if (haveB) {
          L[i] = BL[i];
          R[i] = BR[i];
        }
      }
    }

    // Two cabinets are coherent in the lows, so the equal-power blend adds
    // 20*log10(cos + sin) dB there (+3 dB at zero Width, 0 dB hard-panned).
    // Take it back with a low shelf scaled by the level balance; a muted or
    // polarity-inverted Cab B has no coherent sum to compensate.
    if (haveA && haveB) {
      widthGainCache.configure(spatialOn ? smoothedWidth : 0.0f, blockRounding);
      const float coherent = widthGainCache.coherent;
      const float gainA = consoleOn ? smoothedCabLevel : 1.0f;
      const float gainB = consoleOn
          ? smoothedCab2Level * std::max(0.0f, smoothedCab2Polarity) : 1.0f;
      const float balance = gainA + gainB > 1.0e-6f
          ? 2.0f * std::min(gainA, gainB) / (gainA + gainB) : 0.0f;
      const float shelfTarget = -20.0f * std::log10(coherent) * balance;
      for (uint32_t start = 0; start < n; start += kEqChunk) {
        const uint32_t m = std::min<uint32_t>(kEqChunk, n - start);
        glideValue(smoothedDualCabShelfDb, shelfTarget, chunkGlide, 0.005f);
        if (smoothedDualCabShelfDb != appliedDualCabShelfDb) {
          if (smoothedDualCabShelfDb != 0.0f) {
            setLowShelf(dualCabShelf, smoothedDualCabShelfDb, kDualCabShelfHz, sampleRate);
            copyCoefficients(dualCabShelfR, dualCabShelf);
          } else {
            dualCabShelf.reset();
            dualCabShelfR.reset();
          }
          appliedDualCabShelfDb = smoothedDualCabShelfDb;
        }
        if (smoothedDualCabShelfDb == 0.0f) continue;
        for (uint32_t i = start; i < start + m; ++i) {
          L[i] = dualCabShelf.process(L[i]);
          R[i] = dualCabShelfR.process(R[i]);
        }
      }
    } else {
      dualCabShelf.reset();
      dualCabShelfR.reset();
      smoothedDualCabShelfDb = appliedDualCabShelfDb = 0.0f;
    }

    if (cabProcessed && consoleOn) {
      cabProcessedAny = true;
      const float lowCutTarget = std::max(0.0f, *ports.cab_low_cut);
      const float highCutTarget = std::min(*ports.cab_high_cut,
                                           static_cast<float>(sampleRate * 0.45));
      for (uint32_t start = 0; start < n; start += kEqChunk) {
        const uint32_t m = std::min<uint32_t>(kEqChunk, n - start);
        glideValue(smoothedLowCut, lowCutTarget, chunkGlide, 0.05f);
        glideValue(smoothedHighCut, highCutTarget, chunkGlide, 0.5f);
        const bool lowCutOn = smoothedLowCut >= 20.0f;
        const bool highCutOn = smoothedHighCut < 19990.0f;
        if (smoothedLowCut != appliedLowCut) {
          if (lowCutOn) {
            setHighPass(cabLowCutEq, smoothedLowCut, sampleRate);
            copyCoefficients(cabLowCutEqR, cabLowCutEq);
          } else {
            cabLowCutEq.reset();
            cabLowCutEqR.reset();
          }
          appliedLowCut = smoothedLowCut;
        }
        if (smoothedHighCut != appliedHighCut) {
          if (highCutOn) {
            setLowPass(cabHighCutEq, std::max(1000.0f, smoothedHighCut), sampleRate);
            copyCoefficients(cabHighCutEqR, cabHighCutEq);
          } else {
            cabHighCutEq.reset();
            cabHighCutEqR.reset();
          }
          appliedHighCut = smoothedHighCut;
        }
        if (!lowCutOn && !highCutOn) continue;
        for (uint32_t i = start; i < start + m; ++i) {
          float l = L[i];
          float r = R[i];
          if (lowCutOn) { l = cabLowCutEq.process(l); r = cabLowCutEqR.process(r); }
          if (highCutOn) { l = cabHighCutEq.process(l); r = cabHighCutEqR.process(r); }
          L[i] = l;
          R[i] = r;
        }
      }
      float* channels[2] = {L, R};
      consolePins.process(channels, 2, n, sampleRate, consolePinBands);
    } else {
      consolePins.reset();
      cabLowCutEq.reset();
      cabHighCutEq.reset();
      cabLowCutEqR.reset();
      cabHighCutEqR.reset();
      appliedLowCut = appliedHighCut = -1.0f;
    }

    if (modelProcessed) {
      for (uint32_t i = 0; i < n; ++i) {
        L[i] = dcBlocker.process(L[i]);
        R[i] = dcBlockerR.process(R[i]);
      }
    } else {
      dcBlocker.reset();
      dcBlockerR.reset();
    }

    for (uint32_t start = 0; start < n; start += kEqChunk) {
      const uint32_t m = std::min<uint32_t>(kEqChunk, n - start);
      glideValue(smoothedBass, *ports.bass, chunkGlide, 0.005f);
      glideValue(smoothedMid, *ports.mid, chunkGlide, 0.005f);
      glideValue(smoothedTreble, *ports.treble, chunkGlide, 0.005f);
      const bool bassOn = smoothedBass != 0.0f;
      const bool midOn = smoothedMid != 0.0f;
      const bool trebleOn = smoothedTreble != 0.0f;
      if (smoothedBass != appliedBass) {
        if (bassOn) { setLowShelf(bassEq, smoothedBass, 150.0f, sampleRate); copyCoefficients(bassEqR, bassEq); }
        else { bassEq.reset(); bassEqR.reset(); }
        appliedBass = smoothedBass;
      }
      if (smoothedMid != appliedMid) {
        if (midOn) { setPeaking(midEq, smoothedMid, 700.0f, sampleRate); copyCoefficients(midEqR, midEq); }
        else { midEq.reset(); midEqR.reset(); }
        appliedMid = smoothedMid;
      }
      if (smoothedTreble != appliedTreble) {
        if (trebleOn) { setHighShelf(trebleEq, smoothedTreble, 3000.0f, sampleRate); copyCoefficients(trebleEqR, trebleEq); }
        else { trebleEq.reset(); trebleEqR.reset(); }
        appliedTreble = smoothedTreble;
      }
      if (!bassOn && !midOn && !trebleOn) continue;
      for (uint32_t i = start; i < start + m; ++i) {
        float l = L[i], r = R[i];
        if (bassOn) { l = bassEq.process(l); r = bassEqR.process(r); }
        if (midOn) { l = midEq.process(l); r = midEqR.process(r); }
        if (trebleOn) { l = trebleEq.process(l); r = trebleEqR.process(r); }
        L[i] = l;
        R[i] = r;
      }
    }

    float gain = smoothedOutputLevel;
    for (uint32_t i = 0; i < n; ++i) {
      gain = std::fabs(desiredOutput - gain) > kSmoothEpsilon
               ? gain + (desiredOutput - gain) * trimSmoothCoeff
               : desiredOutput;
      L[i] *= gain;
      R[i] *= gain;
    }
    smoothedOutputLevel = gain;

    const auto processEffects = [&] {
      postCompressor.process(L, R, n, portValue(ports.post_compressor, 0.0f),
                             portValue(ports.post_compressor_attack, 8.0f),
                             portValue(ports.post_compressor_release, 120.0f),
                             portValue(ports.post_compressor_enabled, 1.0f) >= 0.5f);
      if (rackOn(Rack::Delay))
        delayFx.process(L, R, n, portValue(ports.delay_time, 400.0f),
                        portValue(ports.delay_feedback, 35.0f),
                        portValue(ports.delay_damping, 40.0f),
                        portValue(ports.delay_mix, 0.0f));
      reverbFx.process(L, R, n, *ports.room, portValue(ports.reverb_mix, 0.0f),
                       portValue(ports.reverb_decay, 50.0f),
                       portValue(ports.reverb_size, 50.0f),
                       portValue(ports.reverb_damping, 50.0f),
                       portValue(ports.reverb_predelay, 10.0f),
                       spatialOn, reverbOn);
    };
    // Rack switches fade the wet output too; model switches retain FX tails.
    if (rackTransitionActive) processEffects();

    // Click-safe model/domain transition: a 5 ms equal-power fade on each
    // side. The pointer swap itself happens once, after the whole call.
    if (commitRequested) {
      std::memset(L, 0, n * sizeof(float));
      std::memset(R, 0, n * sizeof(float));
    } else if (transitionPhase != TransitionPhase::Steady) {
      for (uint32_t i = 0; i < n; ++i) {
        if (transitionPhase == TransitionPhase::FadeOut) {
          const float t = std::min(1.0f,
              static_cast<float>(transitionPosition) / fadeSamples);
          transitionGain = std::cos(0.5f * static_cast<float>(kPi) * t);
          if (transitionPosition < fadeSamples) ++transitionPosition;
          else commitRequested = true;
        } else {
          const float t = std::min(1.0f,
              static_cast<float>(transitionPosition) / fadeSamples);
          transitionGain = std::sin(0.5f * static_cast<float>(kPi) * t);
          if (transitionPosition < fadeSamples) {
            ++transitionPosition;
          } else {
            transitionGain = 1.0f;
            transitionPhase = TransitionPhase::Steady;
          }
        }
        L[i] *= transitionGain;
        R[i] *= transitionGain;
        if (commitRequested) {
          transitionGain = 0.0f;
          for (uint32_t j = i + 1; j < n; ++j) L[j] = R[j] = 0.0f;
          break;
        }
      }
    }

    if (!rackTransitionActive) processEffects();

    std::memcpy(ports.audio_out + off, L, n * sizeof(float));
    std::memcpy(ports.audio_out_r + off, R, n * sizeof(float));
  }
  (void)cabProcessedAny;

  // ---- Master output level meter (post-effects, final output) ----
  {
    float peak = 0.0f;
    for (uint32_t i = 0; i < count; ++i) {
      const float a = std::fabs(ports.audio_out[i]);
      const float b = std::fabs(ports.audio_out_r[i]);
      if (a > peak) peak = a;
      if (b > peak) peak = b;
    }
    const float blockDb = peak > 1e-9f ? 20.0f * std::log10(peak) : -120.0f;
    const float releasePerBlock = 20.0f * (float)count / (float)sampleRate;
    if (blockDb >= outMeter.lastDb)
      outMeter.lastDb = blockDb;
    else
      outMeter.lastDb = std::max(blockDb, outMeter.lastDb - releasePerBlock);
    const bool isOutAttack = outMeter.lastDb > outMeter.sentDb;
    const float outThreshold = (isOutAttack && outMeter.lastDb > -3.0f) ? 0.1f
                             : isOutAttack ? 0.25f : 0.5f;
    if (std::fabs(outMeter.lastDb - outMeter.sentDb) >= outThreshold) {
      outMeter.sentDb = outMeter.lastDb;
      LV2_Atom_Forge_Frame frame;
      lv2_atom_forge_frame_time(&forge, 0);
      lv2_atom_forge_object(&forge, &frame, 0, uris.patchSet);
      lv2_atom_forge_key(&forge, uris.patchProperty);
      lv2_atom_forge_urid(&forge, uris.outputDb);
      lv2_atom_forge_key(&forge, uris.patchValue);
      lv2_atom_forge_float(&forge, outMeter.lastDb);
      lv2_atom_forge_pop(&forge, &frame);
    }
  }

  if (commitRequested) {
    commitPendingSwitches();
    // The output is silent at the commit, so the blend shelf restarts from a
    // clean history regardless of what each branch carried into the fade.
    dualCabShelf.reset();
    dualCabShelfR.reset();
    for (size_t st = 0; st < kStageCount; ++st)
      appliedEnabled[st] = desiredEnabled[st];
    if (rackTransitionActive && appliedRacks != requestedRacks) {
      const auto changed = [&](Rack rack) {
        const size_t i = static_cast<size_t>(rack);
        return appliedRacks[i] != requestedRacks[i];
      };
      if (changed(Rack::Sculpt)) { ampAdvanced.resetPreAmp(); sculptPins.reset(); overdrive.reset(); }
      if (changed(Rack::Power)) {
        // Power owns the loop reset, not the unchanged Tube amount smoother.
        ampAdvanced.resetPostAmp(true);
        if (!requestedRacks[static_cast<size_t>(Rack::Power)]) speakerDynamics.bypassDamping();
      }
      if (changed(Rack::Transformer)) { outputTransformer.reset(); transformerPins.reset(); }
      if (changed(Rack::Speaker)) { speakerDynamics.reset(); speakerPins.reset(); }
      if (changed(Rack::Delay)) delayFx.reset();
      if (changed(Rack::Reverb)) reverbFx.resetPlate();
      if (changed(Rack::Spatial)) reverbFx.resetRoom();
      if (changed(Rack::Spatial)) smoothedWidth = widthTarget;
      if (changed(Rack::CabConsole)) {
        // Alignment lines keep receiving audio while bypassed. Switch the
        // read delay at silence without discarding the already-filled history.
        cabAlign.primeNextDelay();
        cab2Align.primeNextDelay();
        smoothedCabLevel = targetCab;
        smoothedCab2Level = cab2LevelTarget;
        smoothedCab2Polarity = polarityTarget;
        cabLowCutEq.reset(); cabLowCutEqR.reset();
        cabHighCutEq.reset(); cabHighCutEqR.reset();
        smoothedLowCut = std::max(0.0f, *ports.cab_low_cut);
        smoothedHighCut = std::min(*ports.cab_high_cut, static_cast<float>(sampleRate * 0.45));
        appliedLowCut = appliedHighCut = -1.0f;
      }
      appliedRacks = requestedRacks;
    }
    if (transformerApplied != transformerRequested) {
      transformerApplied = transformerRequested;
      outputTransformer.reset();
    }
    if (speakerApplied != speakerRequested) {
      speakerApplied = speakerRequested;
      speakerDynamics.reset();
    }
    // Tube type/bypass changes the curve at silence, not the shared Power state.
    // Its normalized supply envelope remains meaningful across tube curves.
    tubeApplied = tubeRequested;
    transitionPhase = TransitionPhase::FadeIn;
    transitionPosition = 0;
    transitionGain = 0.0f;
  } else if (transitionPhase == TransitionPhase::Steady) {
    rackTransitionActive = false;
  }
}

void Plugin::startTransitionFadeOut() {
  if (transitionPhase == TransitionPhase::FadeOut)
    return;
  if (transitionPhase == TransitionPhase::Steady) {
    transitionPhase = TransitionPhase::FadeOut;
    transitionPosition = 0;
    return;
  }
  // Mid-FadeIn: pick the fade-out position whose cosine gain equals the
  // current fade-in gain, so the gain curve stays continuous.
  const float g = std::max(0.0f, std::min(1.0f, transitionGain));
  transitionPhase = TransitionPhase::FadeOut;
  transitionPosition = static_cast<uint32_t>(
      std::acos(g) * 2.0 / kPi * std::max(1.0, sampleRate * 0.005));
}

void Plugin::commitPendingSwitches() {
  for (size_t index = 0; index < kStageCount; ++index) {
    auto& pending = pendingSwitches[index];
    if (!pending.ready) continue;
    LV2FreeModelMsg old{kWorkTypeFree, models[index], irs[index], irsRight[index]};
    models[index] = pending.model;
    irs[index] = pending.ir;
    irsRight[index] = pending.irRight;
    pending.model = nullptr;
    pending.ir = nullptr;
    pending.irRight = nullptr;
    if (index == stageIndex(Stage::Amp)) ampIsFullRig = pending.fullRig;
    modelPaths[index] = pending.path;
    osApplied[index] = pending.oversampleMode;
    stageNativeRate[index] = models[index] ? pending.nativeRate : 0.0f;
    assert(modelPaths[index].capacity() >= MAX_FILE_NAME + 1);
    notifyPending[index] = true;
    pending.ready = false;
    for (auto& up : osUp[index]) up.reset();
    for (auto& down : osDown[index]) down.reset();
    resetNativeStream(index);
    schedule->schedule_work(schedule->handle, sizeof(old), &old);
  }
  osTopologySignature = ~uint64_t{0};
}

void Plugin::reloadModelsForOversample() {
  // Re-send every loaded model path through the worker so the models are
  // re-created with the loader external rate matching the new domain.
  for (size_t i = 0; i < kSerialStageCount; ++i) {
    if (models[i] && !modelPaths[i].empty()) {
      const size_t len = modelPaths[i].size();
      const int mode = desiredStageMode(i);
      if (len < MAX_FILE_NAME)
        scheduleModelLoad(static_cast<Stage>(i), modelPaths[i].c_str(), len, mode);
    }
  }
}

void Plugin::scheduleModelLoad(Stage stage, const char* path, size_t length,
                               int mode) {
  if (!validStage(stage) || !path || length >= MAX_FILE_NAME)
    return;
  const size_t index = stageIndex(stage);
  auto& pending = pendingSwitches[index];
  if (pending.ready) {
    LV2FreeModelMsg superseded{kWorkTypeFree, pending.model, pending.ir, pending.irRight};
    schedule->schedule_work(schedule->handle, sizeof(superseded), &superseded);
    pending.model = nullptr;
    pending.ir = nullptr;
    pending.irRight = nullptr;
    pending.ready = false;
  }
  LV2LoadModelMsg message{kWorkTypeLoad, stage,
                          normalizeLoadMode(stage, mode),
                          ++loadGeneration[index], {}};
  std::memcpy(message.path, path, length);
  message.path[length] = '\0';
  schedule->schedule_work(schedule->handle, sizeof(message), &message);
}

void Plugin::writePath(Stage stage) {
  const size_t index = stageIndex(stage);
  LV2_Atom_Forge_Frame frame;
  lv2_atom_forge_frame_time(&forge, 0);
  lv2_atom_forge_object(&forge, &frame, 0, uris.patchSet);
  lv2_atom_forge_key(&forge, uris.patchProperty);
  lv2_atom_forge_urid(&forge, uris.stagePath[index]);
  lv2_atom_forge_key(&forge, uris.patchValue);
  lv2_atom_forge_path(&forge,
                      modelPaths[index].c_str(),
                      static_cast<uint32_t>(modelPaths[index].size() + 1));
  lv2_atom_forge_pop(&forge, &frame);
}

void Plugin::writeAllPaths() {
  for (size_t i = 0; i < kStageCount; ++i)
    writePath(static_cast<Stage>(i));
}

uint32_t Plugin::optionsGet(LV2_Handle, LV2_Options_Option*) {
  return LV2_OPTIONS_ERR_UNKNOWN;
}

uint32_t Plugin::optionsSet(LV2_Handle instance, const LV2_Options_Option* options) {
  auto* rig = static_cast<Plugin*>(instance);
  for (int i = 0; options && options[i].key && options[i].type; ++i) {
    if (options[i].key == rig->uris.maxBlockLength && options[i].type == rig->uris.atomInt) {
      rig->setMaxBufferSize(*static_cast<const int32_t*>(options[i].value));
      break;
    }
  }
  return LV2_OPTIONS_SUCCESS;
}

LV2_State_Status Plugin::save(LV2_Handle instance,
                              LV2_State_Store_Function store,
                              LV2_State_Handle handle,
                              uint32_t,
                              const LV2_Feature* const* features) {
  auto* rig = static_cast<Plugin*>(instance);
  auto* mapPath = static_cast<LV2_State_Map_Path*>(lv2_features_data(features, LV2_STATE__mapPath));
  if (!mapPath)
    return LV2_STATE_ERR_NO_FEATURE;
  auto* freePath = static_cast<LV2_State_Free_Path*>(lv2_features_data(features, LV2_STATE__freePath));

  for (size_t i = 0; i < kStageCount; ++i) {
    if ((!rig->models[i] && !rig->irs[i]) || rig->modelPaths[i].empty())
      continue;
    char* abstractPath = mapPath->abstract_path(mapPath->handle, rig->modelPaths[i].c_str());
    store(handle,
          rig->uris.stagePath[i],
          abstractPath,
          std::strlen(abstractPath) + 1,
          rig->uris.atomPath,
          LV2_STATE_IS_POD | LV2_STATE_IS_PORTABLE);
    if (freePath) freePath->free_path(freePath->handle, abstractPath);
#ifndef _WIN32
    else std::free(abstractPath);
#endif
  }
  return LV2_STATE_SUCCESS;
}

LV2_State_Status Plugin::restore(LV2_Handle instance,
                                 LV2_State_Retrieve_Function retrieve,
                                 LV2_State_Handle handle,
                                 uint32_t,
                                 const LV2_Feature* const* features) {
  auto* rig = static_cast<Plugin*>(instance);
  auto* mapPath = static_cast<LV2_State_Map_Path*>(lv2_features_data(features, LV2_STATE__mapPath));
  if (!mapPath)
    return LV2_STATE_ERR_NO_FEATURE;
  auto* freePath = static_cast<LV2_State_Free_Path*>(lv2_features_data(features, LV2_STATE__freePath));

  for (size_t i = 0; i < kStageCount; ++i) {
    size_t size = 0;
    uint32_t type = 0;
    uint32_t flags = 0;
    const void* value = retrieve(handle, rig->uris.stagePath[i], &size, &type, &flags);
    if (!value || type != rig->uris.atomPath)
      continue;
    char* absolutePath = mapPath->absolute_path(mapPath->handle, static_cast<const char*>(value));
    const size_t length = std::strlen(absolutePath);
    if (length < MAX_FILE_NAME) {
      const Stage stage = static_cast<Stage>(i);
      rig->scheduleModelLoad(stage, absolutePath, length,
                             rig->desiredStageMode(i));
      rig->modelPaths[i] = absolutePath;
    }
    if (freePath) freePath->free_path(freePath->handle, absolutePath);
#ifndef _WIN32
    else std::free(absolutePath);
#endif
  }
  return LV2_STATE_SUCCESS;
}
} // namespace NAMRig
