#include "nam_rig_plugin.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstring>
#include <fstream>

#include <Accelerate/Accelerate.h>

#include <lv2/core/lv2_util.h>
#include "dynamics.h"
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

void deleteModelSet(NeuralAudio::NeuralModel* primary,
                    const std::array<NeuralAudio::NeuralModel*,
                                     kMaxPhaseCount - 1>& phases) {
  delete primary;
  for (auto* model : phases)
    delete model;
}

LV2FreeModelMsg freeMessage(
    NeuralAudio::NeuralModel* primary,
    const std::array<NeuralAudio::NeuralModel*, kMaxPhaseCount - 1>& phases,
    WavIR* ir) {
  return LV2FreeModelMsg{kWorkTypeFree, primary, phases, ir};
}

constexpr double kPi = 3.14159265358979323846;
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
  for (size_t stage = 0; stage < kStageCount; ++stage)
    deleteModelSet(models[stage], phaseModels[stage]);
  for (auto* ir : irs)
    delete ir;
  for (auto& pending : pendingSwitches) {
    deleteModelSet(pending.model, pending.phaseModels);
    delete pending.ir;
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
  uris.atomFloat = map->map(map->handle, LV2_ATOM__Float);
  uris.tunerNote = map->map(map->handle, NAM_RIG_TUNER_NOTE_URI);
  uris.tunerCents = map->map(map->handle, NAM_RIG_TUNER_CENTS_URI);
  uris.inputDb = map->map(map->handle, NAM_RIG_INPUT_DB_URI);

  for (auto& loader : loaders)
    loader.SetExternalSampleRate(static_cast<int>(rate));
  tunerSetRates(rate);
  trimSmoothCoeff = 1.0f - std::exp(-1.0f / static_cast<float>(rate * 0.002));
  dcBlocker.r = std::exp(static_cast<float>(-2.0 * kPi * 5.0 / rate));

  if (options)
    optionsSet(this, options);

  // Size the oversampler scratch UNCONDITIONALLY: not every host sends the
  // maxBlockLength option, and a null scratch_ would crash on first use.
  // The default (512) is generous for typical blocks; if a host later
  // reports a larger block via optionsSet, it grows.
  setMaxBufferSize(static_cast<int>(maxBufferSize));
  return true;
}

void Plugin::setMaxBufferSize(int size) noexcept {
  maxBufferSize = size;
  for (auto& loader : loaders)
    loader.SetDefaultMaxAudioBufferSize(size);
  for (size_t stage = 0; stage < kStageCount; ++stage) {
    if (models[stage])
      models[stage]->SetMaxAudioBufferSize(size + 1);
    for (auto* phaseModel : phaseModels[stage]) {
      if (phaseModel)
        phaseModel->SetMaxAudioBufferSize(size + 1);
    }
  }
  // Per-stage, per-level converter sizing. Level L of a True-2^L cascade sees
  // a block of 2^L * size samples: level 0 (2x) sees 2x, level 1 (4x) sees
  // 4x, level 2 (8x) sees 8x. Every level is sized for the worst case (8x)
  // so any mode change is safe with no host callback; the domain scratch and
  // the pedal->amp chain buffer are sized for 8x too.
  for (size_t st = 0; st < kStageCount; ++st) {
    for (size_t lvl = 0; lvl < kMaxOsLevels; ++lvl) {
      osUp[st][lvl].setMaxBlockSize(static_cast<size_t>(8 * size));
      osDown[st][lvl].setMaxBlockSize(static_cast<size_t>(8 * size));
      osUp[st][lvl].reset();
      osDown[st][lvl].reset();
    }
    osScratch[st].assign(static_cast<size_t>(8 * size) + 64, 0.0f);
    osScratch2[st].assign(static_cast<size_t>(8 * size) + 64, 0.0f);
  }
  for (size_t phase = 0; phase < kMaxPhaseCount; ++phase) {
    phaseInput[phase].assign(static_cast<size_t>(size) + 64, 0.0f);
    phaseOutput[phase].assign(static_cast<size_t>(size) + 64, 0.0f);
  }
  osChain.assign(static_cast<size_t>(8 * size) + 64, 0.0f);
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
    deleteModelSet(message->model, message->phaseModels);
    delete message->ir;
    return LV2_WORKER_SUCCESS;
  }

  if (type != kWorkTypeLoad || size < sizeof(LV2LoadModelMsg))
    return LV2_WORKER_ERR_UNKNOWN;

  const auto* message = static_cast<const LV2LoadModelMsg*>(data);
  if (!validStage(message->stage))
    return LV2_WORKER_ERR_UNKNOWN;

  LV2SwitchModelMsg response{};
  response.type = kWorkTypeSwitch;
  response.stage = message->stage;
  response.oversampleMode = message->oversampleMode;
  response.generation = message->generation;
  response.phaseCount = 1;
  const size_t length = strnlen(message->path, MAX_FILE_NAME);
  const int requestedMode = Plugin::decodeOversample(
      static_cast<float>(message->oversampleMode));

  try {
    if (length > 0 && length < MAX_FILE_NAME) {
      if (message->stage == Stage::Cab && endsWithWav(message->path)) {
        response.ir = WavIR::load(message->path, rig->sampleRate, rig->maxBufferSize).release();
      } else {
        // True-Nx uses N model clones, one for each interleaved phase of the
        // oversampled stream. Every clone advances at the session rate, so
        // NeuralAudio must prepare it for that rate rather than Nx * rate.
        // This preserves each clone's physical time scale and makes the N
        // recurrent timelines independent jobs.
        const int sessionRate = static_cast<int>(rig->sampleRate);
        const int mode = requestedMode;
        const int pipelineFactor = Plugin::truePipelineFactor(mode, rig->sampleRate);
        const int modelRate = mode == Plugin::kOsNone ? 48000
                                                     : sessionRate;
        response.phaseCount = static_cast<uint32_t>(
            std::max(1, std::min<int>(kMaxPhaseCount, pipelineFactor)));
        auto& loader = rig->loaders[stageIndex(message->stage)];
        loader.SetExternalSampleRate(modelRate);
        response.model = loader.CreateFromFile(message->path);
        for (uint32_t phase = 1;
             response.model && phase < response.phaseCount; ++phase) {
          response.phaseModels[phase - 1] = loader.CreateFromFile(message->path);
          if (!response.phaseModels[phase - 1]) {
            deleteModelSet(response.model, response.phaseModels);
            response.model = nullptr;
            response.phaseModels.fill(nullptr);
          }
        }
        loader.SetExternalSampleRate(sessionRate);
        // Each phase receives at most one base-rate block (+ one sample when
        // a block boundary is not divisible by N).
        if (response.model) {
          response.model->SetMaxAudioBufferSize(rig->maxBufferSize + 1);
          for (auto* phaseModel : response.phaseModels)
            if (phaseModel)
              phaseModel->SetMaxAudioBufferSize(rig->maxBufferSize + 1);
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
      if (response.model) {
        const int stageMode = requestedMode;
        const double domainRate = stageMode == Plugin::kOsNone
                                      ? 48000.0 : rig->sampleRate;
        const double modelRate = response.model->GetSampleRate();
        if (modelRate > 0.0 && std::fmod(domainRate, modelRate) > 1e-6)
          lv2_log_warning(&rig->logger,
                          "Model rate %.0f Hz does not evenly divide processing rate %.0f Hz — "
                          "it will run at the wrong rate (detuned). Model: '%s'\n",
                          modelRate, domainRate, message->path);
      }
    }
  } catch (...) {
    deleteModelSet(response.model, response.phaseModels);
    response.model = nullptr;
    response.phaseModels.fill(nullptr);
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
    LV2FreeModelMsg stale = freeMessage(
        message->model, message->phaseModels, message->ir);
    rig->schedule->schedule_work(rig->schedule->handle, sizeof(stale), &stale);
    return LV2_WORKER_SUCCESS;
  }
  const int desiredMode = index == 0 ? rig->osRequested[0]
                                     : rig->osRequested[1];
  if (Plugin::decodeOversample((float)message->oversampleMode) != desiredMode) {
    // The mode changed while an initial/path load was in flight, before
    // reloadModelsForOversample() had an installed model to reschedule.
    // Reuse the completed response's path and load it for the latest domain.
    const size_t length = strnlen(message->path, MAX_FILE_NAME);
    rig->scheduleModelLoad(message->stage, message->path, length, desiredMode);
    LV2FreeModelMsg stale = freeMessage(
        message->model, message->phaseModels, message->ir);
    rig->schedule->schedule_work(rig->schedule->handle, sizeof(stale), &stale);
    return LV2_WORKER_SUCCESS;
  }
  auto& pending = rig->pendingSwitches[index];
  if (pending.ready) {
    LV2FreeModelMsg superseded = freeMessage(
        pending.model, pending.phaseModels, pending.ir);
    rig->schedule->schedule_work(rig->schedule->handle,
                                 sizeof(superseded), &superseded);
  }
  pending.model = message->model;
  pending.phaseModels = message->phaseModels;
  pending.phaseCount = message->phaseCount;
  pending.ir = message->ir;
  pending.oversampleMode = Plugin::decodeOversample(
      static_cast<float>(message->oversampleMode));
  pending.fullRig = message->fullRig;
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
  tuner.lp1.reset();
  tuner.lp2.reset();
}

void Plugin::runPhaseJob(void* context) noexcept {
  auto* job = static_cast<PhaseJob*>(context);
  job->model->Process(job->input, job->output, job->count);
  job->remaining->fetch_sub(1, std::memory_order_release);
}

void Plugin::processModelPhases(size_t stage, float* samples, size_t count,
                                uint32_t factor) noexcept {
  if (factor <= 1 || factor > kMaxPhaseCount ||
      modelPhaseCounts[stage] != factor) {
    models[stage]->Process(samples, samples, count);
    return;
  }

  const size_t startingPhase = modelPhaseCursors[stage];
  const auto phaseLengths = deinterleavePhases(
      samples, count, static_cast<size_t>(factor), phaseInput, startingPhase);

  for (uint32_t phase = 0; phase < factor; ++phase) {
    phaseJobs[phase].model = phase == 0
        ? models[stage] : phaseModels[stage][phase - 1];
    phaseJobs[phase].input = phaseInput[phase].data();
    phaseJobs[phase].output = phaseOutput[phase].data();
    phaseJobs[phase].count = phaseLengths[phase];
    phaseJobs[phase].remaining = &phaseJobsRemaining;
  }

  phaseJobsRemaining.store(factor, std::memory_order_release);
  const bool dispatch = realtimeDispatcher &&
      multiCoreEnabled.load(std::memory_order_acquire);
  for (uint32_t phase = 1; phase < factor; ++phase) {
    if (!dispatch ||
        !realtimeDispatcher->tryPublish(&Plugin::runPhaseJob,
                                        &phaseJobs[phase]))
      runPhaseJob(&phaseJobs[phase]);
  }
  runPhaseJob(&phaseJobs[0]);

  while (phaseJobsRemaining.load(std::memory_order_acquire) != 0) {
#if defined(__aarch64__) || defined(__arm64__)
    __asm__ __volatile__("yield");
#elif defined(__x86_64__) || defined(_M_X64)
    __asm__ __volatile__("pause");
#endif
  }

  interleavePhases(phaseOutput, samples, count,
                   static_cast<size_t>(factor), startingPhase);
  modelPhaseCursors[stage] = static_cast<uint32_t>(
      (startingPhase + count) % factor);
}

void Plugin::process(uint32_t sampleCount) noexcept {
  if (!ports.control || !ports.notify || !ports.audio_in || !ports.audio_out ||
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
        const int mode = stageOversample(i);
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
    // Change-gate: send only on >=0.5 dB drift so the notify stream stays quiet.
    if (std::fabs(meter.lastDb - meter.sentDb) >= 0.5f) {
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
    if (!tunerOn && tuner.wasEnabled) {
      tuner.lastNote = -1.0f;
      tuner.lastCents = 0.0f;
      tuner.histLen = 0;
      tuner.histIdx = 0;
      tuner.missCount = 0;
      tuner.samplesSinceAnalysis = 0;
    }
    tuner.wasEnabled = tunerOn;
    if (tunerOn) {
      for (uint32_t i = 0; i < sampleCount; ++i) {
        const float x = tuner.lp2.process(tuner.lp1.process(ports.audio_in[i]));
        if (++tuner.decimPhase >= tuner.decimFactor) {
          tuner.decimPhase = 0;
          tuner.ring[(size_t)tuner.ringPos] = x;
          tuner.ringPos = (tuner.ringPos + 1) % Tuner::kBuf;
          if (tuner.filled < Tuner::kBuf) ++tuner.filled;
        }
      }
      // Analyze on a ~30 ms hop — rate- and block-size-independent cadence —
      // as soon as the ring holds one window+lag span (no full-ring wait).
      const int span = Tuner::kWindow + Tuner::kMaxTau;
      const int hop = (int)(sampleRate * 0.030);
      tuner.samplesSinceAnalysis += (int)sampleCount;
      if (tuner.samplesSinceAnalysis >= hop && tuner.filled >= span) {
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
          }
        } else {
          // NSDF (McLeod): nsdf[tau] = 2*acf[tau] / m[tau], in [-1, 1].
          // Vectorized: one vDSP_conv (window as signal AND filter) yields
          // acf for every lag at once, and m[tau] = E[0,W) + E[tau,tau+W)
          // comes from a prefix sum of squares — the old O(W * tauMax)
          // scalar burst on the audio thread collapses to one fast conv.
          // vDSP_conv needs signal length (kMaxTau+1) + kWindow - 1 = span.
          vDSP_conv(win, 1, win, 1, tuner.acf, 1,
                    (vDSP_Length)(Tuner::kMaxTau + 1),
                    (vDSP_Length)Tuner::kWindow);
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
          if (chosen > 0) {
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
            }
          } else {
            tuner.missCount = 0;
            // Median-of-3 display filter kills single-frame octave jumps.
            // The write slot ROLLS — a clamped index froze slots 1/2 at the
            // note's onset values, latching the display until silence.
            tuner.noteHist[tuner.histIdx] = midi;
            tuner.histIdx = (tuner.histIdx + 1) % 3;
            tuner.histLen = std::min(tuner.histLen + 1, 3);
            if (tuner.histLen >= 3) {
              const float a = tuner.noteHist[0], b = tuner.noteHist[1], c = tuner.noteHist[2];
              tuner.lastNote = std::max(std::min(a, b), std::min(std::max(a, b), c));
            }
          }
          if (tuner.lastNote >= 0.0f) {
            const int nearest = std::lround(tuner.lastNote);
            tuner.lastCents = std::max(-50.0f, std::min(50.0f, (tuner.lastNote - nearest) * 100.0f));
          } else {
            tuner.lastCents = 0.0f;
          }
        }
      }
    }
    // Publish results: output ports for host polling, plus patch:Set atom
    // events on the notify port for the UI — only when something actually
    // changed (note change or >=1-cent drift) to keep notify traffic low.
    const int noteI = (int)tuner.lastNote;
    const int centsQ = (int)std::lround(tuner.lastCents);
    if (noteI != (int)tuner.sentNote || centsQ != (int)tuner.sentCentsQ) {
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

  // Hysteretic downward expander (before input trim). The detector has a fast
  // attack and program-dependent release; a 6 dB close threshold plus 20 ms
  // hold prevents chatter. Below threshold, a 2:1 expansion curve preserves
  // tails instead of snapping to digital silence. At -80 dB it is bypassed.
  const float gateThreshold = *ports.gate_threshold;
  const bool gateActive = gateThreshold > -79.99f;
  if (!gateActive) {
    gateDetector = 0.0f;
    gateGain = 1.0f;
    gateOpen = true;
    gateHoldRemaining = 0;
  }
  const float gateOpenLin = dbToLinear(gateThreshold);
  const float gateCloseLin = dbToLinear(gateThreshold - 6.0f);
  const float releaseSeconds = std::max(0.020f, *ports.gate_release * 0.001f);
  const float detectorAttack = 1.0f - std::exp(-1.0f / (sampleRate * 0.001));
  const float detectorRelease = 1.0f - std::exp(-1.0f / (sampleRate * releaseSeconds * 0.5f));
  const float gainAttack = 1.0f - std::exp(-1.0f / (sampleRate * 0.0005));
  const float gainRelease = 1.0f - std::exp(-1.0f / (sampleRate * releaseSeconds));
  const uint32_t gateHoldSamples = static_cast<uint32_t>(sampleRate * 0.020);

  const float desiredInput = dbToLinear(*ports.input_level);
  float gain = smoothedInputLevel;
  for (uint32_t i = 0; i < sampleCount; ++i) {
    float in = ports.audio_in[i];
    if (gateActive) {
      const float level = std::fabs(in);
      const float detectorCoeff = level > gateDetector ? detectorAttack : detectorRelease;
      gateDetector += (level - gateDetector) * detectorCoeff;
      if (!gateOpen && gateDetector >= gateOpenLin) {
        gateOpen = true;
        gateHoldRemaining = gateHoldSamples;
      } else if (gateOpen) {
        if (gateDetector >= gateCloseLin) {
          gateHoldRemaining = gateHoldSamples;
        } else if (gateHoldRemaining > 0) {
          --gateHoldRemaining;
        } else {
          gateOpen = false;
        }
      }
      const float expanded = std::max(0.001f,
          gateDetector / std::max(gateCloseLin, 1.0e-9f));
      const float target = gateOpen ? 1.0f : std::min(1.0f, expanded);
      gateGain += (target - gateGain) * (target > gateGain ? gainAttack : gainRelease);
      in *= gateGain;
    }
    gain = std::fabs(desiredInput - gain) > kSmoothEpsilon
             ? gain + (desiredInput - gain) * trimSmoothCoeff
             : desiredInput;
    ports.audio_out[i] = in * gain;
  }
  smoothedInputLevel = gain;

  // One-knob, feed-forward guitar compressor before the pedal/amp chain.
  // Amount progressively lowers threshold (-12 -> -36 dB), raises ratio
  // (1:1 -> 6:1), and adds up to 6 dB makeup. Fixed 8 ms attack / 120 ms
  // release and a 6 dB soft knee retain pick definition without pumping.
  const float compAmount = std::max(0.0f, std::min(1.0f,
      *ports.compressor * 0.01f));
  if (compAmount <= 0.0001f) {
    compressorEnvelope = 0.0f;
    compressorGain = 1.0f;
  } else {
    const float thresholdDb = -12.0f - 24.0f * compAmount;
    const float ratio = 1.0f + 5.0f * compAmount;
    const float makeupDb = 6.0f * compAmount;
    const float envAttack = 1.0f - std::exp(-1.0f / (sampleRate * 0.001));
    const float envRelease = 1.0f - std::exp(-1.0f / (sampleRate * 0.080));
    const float gainAttack = 1.0f - std::exp(-1.0f / (sampleRate * 0.008));
    const float gainRelease = 1.0f - std::exp(-1.0f / (sampleRate * 0.120));
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
      *ports.cab_enabled >= 0.5f};
  if (ports.cab_auto_bypassed)
    *ports.cab_auto_bypassed = 0.0f;

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

  // ---- Oversample mode change detection (per stage) ----
  // Models carry their rate domain and phase count at load time, so any mode
  // change re-sends the loaded paths through the worker. Until a matching
  // swap lands, osApplied
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
                         | ((uint64_t)(truePipelineFactor(osApplied[st], sampleRate) + 1) << 3);
    topology |= state << (st * 8);
  }
  if (topology != osTopologySignature) {
    osTopologySignature = topology;
    modelPhaseCursors.fill(0);
    for (auto& stageUp : osUp)
      for (auto& up : stageUp) up.reset();
    for (auto& stageDown : osDown)
      for (auto& down : stageDown) down.reset();
  }

  // ---- Stage processing with per-stage oversample domains ----
  // TRUE-Nx stages run inside a genuine UP -> N base-rate phase clones ->
  // DOWN cascade (chain of 2x half-band pairs). NONE and LEGACY stages run at base rate
  // (Legacy dilation stretches the model's reach inside NeuralAudio; no
  // pipeline involved). The nonlinear stages are the aliasing sources, so
  // only they get TRUE domains; the cab WAV IR and EQ stay at base rate
  // (linear stages cannot alias). A .nam cab model follows the AMP's TRUE
  // factor, preserving the old shared-domain behavior.
  //
  // Mixed-domain chaining: stages that precede the first TRUE stage run at
  // base rate on the raw buffer; the TRUE stage(s) run inside their cascade;
  // stages after the last TRUE stage run at base rate on its decimated
  // output. Latency note: TRUE stages hold back a fixed pipeline delay
  // (factor * 24 samples per cascade), so after them, later base-rate
  // stages see delayed audio — the converters fill their short tails with
  // the last valid sample so the output never contains stale garbage.
  auto applyModel = [&](size_t stage, NeuralAudio::NeuralModel* model,
                        float* samples, size_t count, double domainRate,
                        uint32_t domainFactor) {
    if (stage == 1) {
      const float target = dbToLinear(*ports.amp_drive);
      const float coeff = 1.0f - std::exp(-1.0f /
          static_cast<float>(std::max(1.0, domainRate) * 0.010));
      for (size_t i = 0; i < count; ++i) {
        smoothedAmpDrive += (target - smoothedAmpDrive) * coeff;
        samples[i] *= smoothedAmpDrive;
      }
    }
    const float pre = dbToLinear(model->GetRecommendedInputDBAdjustment());
    if (pre != 1.0f)
      for (size_t i = 0; i < count; ++i) samples[i] *= pre;
    processModelPhases(stage, samples, count, domainFactor);
    const float post = dbToLinear(model->GetRecommendedOutputDBAdjustment());
    if (post != 1.0f)
      for (size_t i = 0; i < count; ++i) samples[i] *= post;
  };

  // Process one or more consecutive models inside ONE TRUE domain. Keeping
  // pedal -> amp -> .nam cab between the same UP/DOWN pair preserves the
  // pedal's ultrasonic products for the amp's nonlinear response and avoids
  // redundant converter filtering. `owner` supplies this group's streaming
  // converter state; stages[] remains in signal-chain order.
  auto processTrueGroup = [&](size_t owner, const size_t* stages,
                              size_t stageCount, float* samples,
                              uint32_t count, int f) -> uint32_t {
    const size_t levels = f == 8 ? 3 : (f == 4 ? 2 : 1);
    float* bufs[2] = {osScratch[owner].data(), osScratch2[owner].data()};
    size_t n = osUp[owner][0].process(samples, count, bufs[0]);
    for (size_t c = 1; c < levels && n > 0; ++c)
      n = osUp[owner][c].process(bufs[(c - 1) % 2], n, bufs[c % 2]);
    float* domain = bufs[(levels - 1) % 2];
    if (n == 0 || n + 64 > osScratch[owner].size())
      return count;
    for (size_t i = 0; i < stageCount; ++i)
      applyModel(stages[i], models[stages[i]], domain, n, sampleRate * f,
                 static_cast<uint32_t>(f));

    // Decimate back down the same chain (reversed), ping-ponging between
    // the two scratch buffers; the last level lands in the chain buffer.
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
  // Models and converter scratch are sized from maxBufferSize; a host that
  // exceeds the negotiated maxBlockLength (or never sent it, leaving the 512
  // default) would overrun NeuralAudio's fixed internal buffers — classic
  // WaveNet does not chunk in Process. So the chain runs in maxBufferSize
  // slices; the converters' streaming state carries across slices, so the
  // output is identical to one full-size pass.
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
    for (size_t st = 0; st < kStageCount;) {
      const bool isWavCab = st == 2 && irs[2] != nullptr;
      if (!enabled[st] || !models[st] || isWavCab) {
        ++st;
        continue;
      }

      const int f = truePipelineFactor(osApplied[st], sampleRate);
      if (f <= 1) {
        applyModel(st, models[st], chain, n, sampleRate, 1);
        modelProcessed = true;
        if (st == 2) cabProcessed = true;
        ++st;
        continue;
      }

      size_t group[kStageCount] = {st, 0, 0};
      size_t groupCount = 1;
      size_t next = st + 1;
      // Only merge genuinely adjacent active NAM stages. A bypassed/missing
      // stage or WAV cab ends the domain, as does a different True factor.
      while (next < kStageCount && enabled[next] && models[next] &&
             !(next == 2 && irs[2]) &&
             truePipelineFactor(osApplied[next], sampleRate) == f) {
        group[groupCount++] = next++;
      }
      n = processTrueGroup(st, group, groupCount, chain, n, f);
      modelProcessed = true;
      if (off == 0) latencyFrames += cascadeLatencyFrames(f);
      if (group[groupCount - 1] == 2) cabProcessed = true;
      st = next;
    }
    std::memcpy(io, chain, sliceLen * sizeof(float));
  }
  // Report the True cascades' fixed pipeline delay for host delay
  // compensation (0 when every active stage runs at base rate).
  if (ports.latency)
    *ports.latency = static_cast<float>(latencyFrames);

  // A WAV cab remains at base rate. A .nam cab was processed in the chain
  // above, sharing the amp's domain whenever their applied factors match.
  if (enabled[2]) {
    auto* ir = irs[2];
    if (ir) {
      const int norm = std::max(0, std::min(2,
          static_cast<int>(*ports.ir_normalization + 0.5f)));
      ir->process(ports.audio_out, sampleCount, norm);
      cabProcessed = true;
    }
  }

  // Post-cab trim and optional Butterworth cuts. These belong to the cab
  // block, so bypassing or clearing the cab leaves the signal untouched.
  if (cabProcessed) {
    const float targetCab = dbToLinear(*ports.cab_level);
    const float cabSmooth = 1.0f - std::exp(-1.0f / (sampleRate * 0.010));
    const float lowCut = std::max(0.0f, *ports.cab_low_cut);
    const float highCut = std::min(*ports.cab_high_cut,
                                   static_cast<float>(sampleRate * 0.45));
    const bool lowCutOn = lowCut >= 20.0f;
    const bool highCutOn = *ports.cab_high_cut < 19990.0f;
    if (lowCutOn) setHighPass(cabLowCutEq, lowCut, sampleRate);
    else cabLowCutEq.reset();
    if (highCutOn) setLowPass(cabHighCutEq, std::max(1000.0f, highCut), sampleRate);
    else cabHighCutEq.reset();
    for (uint32_t i = 0; i < sampleCount; ++i) {
      smoothedCabLevel += (targetCab - smoothedCabLevel) * cabSmooth;
      float x = ports.audio_out[i] * smoothedCabLevel;
      if (lowCutOn) x = cabLowCutEq.process(x);
      if (highCutOn) x = cabHighCutEq.process(x);
      ports.audio_out[i] = x;
    }
  } else {
    cabLowCutEq.reset();
    cabHighCutEq.reset();
  }

  // DC blocker (~5 Hz). NAM models routinely emit a small DC offset and the
  // True converters pass DC at exactly unity gain; unchecked, the offset
  // eats headroom and gets amplified by a bass-shelf boost. Runs only when a
  // model actually processed this block, so a model-free chain stays
  // bit-transparent.
  if (modelProcessed) {
    for (uint32_t i = 0; i < sampleCount; ++i)
      ports.audio_out[i] = dcBlocker.process(ports.audio_out[i]);
  } else {
    dcBlocker.reset();
  }

  // 3-band EQ (post: after the stages, before the output trim). Each band is
  // only processed when its gain is non-zero and the whole section is skipped
  // at neutral, so a flat EQ is bit-transparent.
  const bool bassOn = *ports.bass != 0.0f;
  const bool midOn = *ports.mid != 0.0f;
  const bool trebleOn = *ports.treble != 0.0f;
  if (bassOn) setLowShelf(bassEq, *ports.bass, 150.0f, sampleRate);
  if (midOn) setPeaking(midEq, *ports.mid, 700.0f, sampleRate);
  if (trebleOn) setHighShelf(trebleEq, *ports.treble, 3000.0f, sampleRate);
  if (!bassOn) bassEq.reset();
  if (!midOn) midEq.reset();
  if (!trebleOn) trebleEq.reset();
  if (bassOn || midOn || trebleOn) {
    for (uint32_t i = 0; i < sampleCount; ++i) {
      float x = ports.audio_out[i];
      if (bassOn) x = bassEq.process(x);
      if (midOn) x = midEq.process(x);
      if (trebleOn) x = trebleEq.process(x);
      ports.audio_out[i] = x;
    }
  }

  const float desiredOutput = dbToLinear(*ports.output_level);
  gain = smoothedOutputLevel;
  for (uint32_t i = 0; i < sampleCount; ++i) {
    gain = std::fabs(desiredOutput - gain) > kSmoothEpsilon
             ? gain + (desiredOutput - gain) * trimSmoothCoeff
             : desiredOutput;
    ports.audio_out[i] *= gain;
  }
  smoothedOutputLevel = gain;

  // Click-safe model/domain transition. A 5 ms equal-power fade on each side
  // is short enough to feel immediate but long enough to suppress a waveform
  // discontinuity and hide converter warm-up after the zero crossing.
  if (transitionPhase != TransitionPhase::Steady) {
    const uint32_t fadeSamples = std::max<uint32_t>(1,
        static_cast<uint32_t>(std::lround(sampleRate * 0.005)));
    bool commitAfterBlock = false;
    for (uint32_t i = 0; i < sampleCount; ++i) {
      if (transitionPhase == TransitionPhase::FadeOut) {
        const float t = std::min(1.0f,
            static_cast<float>(transitionPosition) / fadeSamples);
        transitionGain = std::cos(0.5f * static_cast<float>(kPi) * t);
        if (transitionPosition < fadeSamples) ++transitionPosition;
        else commitAfterBlock = true;
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
      ports.audio_out[i] *= transitionGain;
      if (commitAfterBlock) {
        transitionGain = 0.0f;
        for (uint32_t j = i + 1; j < sampleCount; ++j)
          ports.audio_out[j] = 0.0f;
        break;
      }
    }
    if (commitAfterBlock) {
      commitPendingSwitches();
      for (size_t st = 0; st < kStageCount; ++st)
        appliedEnabled[st] = desiredEnabled[st];
      transitionPhase = TransitionPhase::FadeIn;
      transitionPosition = 0;
      transitionGain = 0.0f;
    }
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
    LV2FreeModelMsg old = freeMessage(models[index], phaseModels[index],
                                      irs[index]);
    models[index] = pending.model;
    phaseModels[index] = pending.phaseModels;
    modelPhaseCounts[index] = pending.phaseCount;
    modelPhaseCursors[index] = 0;
    irs[index] = pending.ir;
    pending.model = nullptr;
    pending.phaseModels.fill(nullptr);
    pending.phaseCount = 1;
    pending.ir = nullptr;
    if (index == stageIndex(Stage::Amp)) ampIsFullRig = pending.fullRig;
    modelPaths[index] = pending.path;
    osApplied[index] = pending.oversampleMode;
    assert(modelPaths[index].capacity() >= MAX_FILE_NAME + 1);
    notifyPending[index] = true;
    pending.ready = false;
    for (auto& up : osUp[index]) up.reset();
    for (auto& down : osDown[index]) down.reset();
    schedule->schedule_work(schedule->handle, sizeof(old), &old);
  }
  osTopologySignature = ~uint64_t{0};
}

void Plugin::reloadModelsForOversample() {
  // Re-send every loaded model path through the worker so its external rate
  // and number of persistent phase clones match the requested mode.
  for (size_t i = 0; i < kStageCount; ++i) {
    if (models[i] && !modelPaths[i].empty()) {
      const size_t len = modelPaths[i].size();
      const int mode = i == 0 ? osRequested[0] : osRequested[1];
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
    LV2FreeModelMsg superseded = freeMessage(
        pending.model, pending.phaseModels, pending.ir);
    schedule->schedule_work(schedule->handle, sizeof(superseded), &superseded);
    pending.model = nullptr;
    pending.phaseModels.fill(nullptr);
    pending.phaseCount = 1;
    pending.ir = nullptr;
    pending.ready = false;
  }
  LV2LoadModelMsg message{kWorkTypeLoad, stage, decodeOversample((float)mode),
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
                             rig->stageOversample(i));
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
