#include "nam_rig_plugin.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstring>
#include <fstream>

#include <lv2/core/lv2_util.h>
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
    delete message->model;
    delete message->ir;
    return LV2_WORKER_SUCCESS;
  }

  if (type != kWorkTypeLoad || size < sizeof(LV2LoadModelMsg))
    return LV2_WORKER_ERR_UNKNOWN;

  const auto* message = static_cast<const LV2LoadModelMsg*>(data);
  if (!validStage(message->stage))
    return LV2_WORKER_ERR_UNKNOWN;

  LV2SwitchModelMsg response{kWorkTypeSwitch, message->stage,
                             message->oversampleMode, message->generation,
                             {}, nullptr, nullptr, false};
  const size_t length = strnlen(message->path, MAX_FILE_NAME);
  const int requestedMode = Plugin::decodeOversample(
      static_cast<float>(message->oversampleMode));

  try {
    if (length > 0 && length < MAX_FILE_NAME) {
      if (message->stage == Stage::Cab && endsWithWav(message->path)) {
        response.ir = WavIR::load(message->path, rig->sampleRate, rig->maxBufferSize).release();
      } else {
        // The stage's oversample mode decides the loader external rate.
        // NONE (0): 48000 — dilation is a no-op for common-rate models.
        // LEGACY Nx (1..3): session rate — dilation = hostRate/modelRate
        //                    (NeuralAudio stretches the model's dilations;
        //                    a "4x" Legacy model runs the SAME math per
        //                    sample, just reaches further back in time).
        // TRUE Nx (4..6): Nx * session rate — the model is created for the
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
        // the pipeline now feeds. Size for the worst case (8x = 4096 samples
        // at a 512 max block) in EVERY mode — a few MB per model, no CPU.
        // Do NOT make this mode-conditional; that re-opens the 2026-08-29
        // click-crash (verified via unified-log forensics).
        if (response.model)
          response.model->SetMaxAudioBufferSize(8 * rig->maxBufferSize);
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
    response.model = nullptr;
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
    LV2FreeModelMsg stale{kWorkTypeFree, message->model, message->ir};
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
    LV2FreeModelMsg stale{kWorkTypeFree, message->model, message->ir};
    rig->schedule->schedule_work(rig->schedule->handle, sizeof(stale), &stale);
    return LV2_WORKER_SUCCESS;
  }
  LV2FreeModelMsg freeMessage{kWorkTypeFree, rig->models[index], rig->irs[index]};
  rig->models[index] = message->model;
  rig->irs[index] = message->ir;
  if (message->stage == Stage::Amp) rig->ampIsFullRig = message->fullRig;
  rig->modelPaths[index] = message->path;
  rig->osApplied[index] = Plugin::decodeOversample(
      static_cast<float>(message->oversampleMode));
  for (auto& up : rig->osUp[index]) up.reset();
  for (auto& down : rig->osDown[index]) down.reset();
  assert(rig->modelPaths[index].capacity() >= MAX_FILE_NAME + 1);
  rig->notifyPending[index] = true;
  rig->schedule->schedule_work(rig->schedule->handle, sizeof(freeMessage), &freeMessage);
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

void Plugin::process(uint32_t sampleCount) noexcept {
  if (!ports.control || !ports.notify || !ports.audio_in || !ports.audio_out ||
      !ports.input_level || !ports.output_level ||
      !ports.pedal_enabled || !ports.amp_enabled || !ports.cab_enabled || !ports.auto_cab ||
      !ports.tuner_enable || !ports.tuner_note || !ports.tuner_cents ||
      !ports.pedal_oversample || !ports.amp_oversample)
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
      if (tuner.cooldown > 0) {
        --tuner.cooldown;
      } else if (tuner.filled >= Tuner::kBuf) {
        tuner.cooldown = 3;   // re-analyze every few blocks; UI stays smooth
        // Unwrap the most recent window (+ max lag) into linear scratch.
        float* win = tuner.scratch;
        const int span = Tuner::kWindow + Tuner::kMaxTau;
        const int start = (tuner.ringPos - span + 2 * Tuner::kBuf) % Tuner::kBuf;
        for (int i = 0; i < span; ++i)
          win[i] = tuner.ring[(size_t)((start + i) % Tuner::kBuf)];

        float energy = 0.0f;
        for (int i = 0; i < Tuner::kWindow; ++i) energy += win[i] * win[i];
        const float rms = std::sqrt(energy / Tuner::kWindow);
        if (rms < 0.003f) {           // silence — show "no signal"
          tuner.lastNote = -1.0f;
          tuner.histLen = 0;
        } else {
          // NSDF (McLeod): nsdf[tau] = 2*acf[tau] / m[tau], in [-1, 1].
          for (int tau = Tuner::kMinTau; tau <= Tuner::kMaxTau; ++tau) {
            float acf = 0.0f, m = 0.0f;
            for (int i = 0; i < Tuner::kWindow; ++i) {
              const float a = win[i];
              const float b = win[i + tau];
              acf += a * b;
              m += a * a + b * b;
            }
            tuner.nsdf[tau] = (m > 0.0f) ? (2.0f * acf / m) : 0.0f;
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
            tuner.lastNote = -1.0f;
            tuner.histLen = 0;
          } else {
            // Median-of-3 display filter kills single-frame octave jumps.
            tuner.noteHist[tuner.histLen % 3] = midi;
            tuner.histLen = std::min(tuner.histLen + 1, 3);
            if (tuner.histLen >= 3) {
              const float a = tuner.noteHist[0], b = tuner.noteHist[1], c = tuner.noteHist[2];
              tuner.lastNote = std::max(std::min(a, b), std::min(std::max(a, b), c));
            } else if (tuner.lastNote < 0.0f) {
              tuner.lastNote = -1.0f;   // need 3 consistent frames before showing
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
    // changed (note change or >=2-cent drift) to keep notify traffic low.
    const int noteI = (int)tuner.lastNote;
    const int centsQ = (int)std::lround(tuner.lastCents / 2.0f);
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

  // Noise gate (before the input trim). Fully bypassed at the -80 dB minimum
  // threshold so the default signal path is bit-identical to before.
  const float gateThreshold = *ports.gate_threshold;
  const bool gateActive = gateThreshold > -79.99f;
  if (!gateActive) { gateDetector = 0.0f; gateGain = 1.0f; }
  const float gateThresholdLin = dbToLinear(gateThreshold);
  const float gateRelease = 1.0f - std::exp(-1.0f / (sampleRate * 0.060));

  const float desiredInput = dbToLinear(*ports.input_level);
  float gain = smoothedInputLevel;
  for (uint32_t i = 0; i < sampleCount; ++i) {
    float in = ports.audio_in[i];
    if (gateActive) {
      const float level = std::fabs(in);
      if (level > gateDetector) gateDetector = level;
      else gateDetector += (level - gateDetector) * gateRelease;
      const float target = gateDetector > gateThresholdLin ? 1.0f : 0.0f;
      if (target > gateGain) gateGain = target;
      else gateGain += (target - gateGain) * gateRelease;
      in *= gateGain;
    }
    gain = std::fabs(desiredInput - gain) > kSmoothEpsilon
             ? 0.99f * gain + 0.01f * desiredInput
             : desiredInput;
    ports.audio_out[i] = in * gain;
  }
  smoothedInputLevel = gain;

  // Auto-cab bypass DISABLED (user decision, 2026-08-29): the user manages
  // cab on/off themselves with the ON button, so the cab now always follows
  // cab_enabled — full-rig amp captures no longer silently disconnect the
  // cab stage. The auto_cab port and the cab_auto_bypassed output keep their
  // meanings (cab_auto_bypassed now stays 0) for session/UI compatibility.
  const bool enabled[kStageCount] = {
      *ports.pedal_enabled >= 0.5f,
      *ports.amp_enabled >= 0.5f,
      *ports.cab_enabled >= 0.5f};
  if (ports.cab_auto_bypassed)
    *ports.cab_auto_bypassed = 0.0f;

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

  // ---- Stage processing with per-stage oversample domains ----
  // TRUE-Nx stages run inside a genuine UP -> model@Nx -> DOWN cascade
  // (chain of 2x half-band pairs). NONE and LEGACY stages run at base rate
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
  const int cabFactor = truePipelineFactor(osApplied[2], sampleRate);

  // Process ONE model stage either at base rate or inside a TRUE cascade.
  // Returns the number of base-rate samples written to `dst` (may be < count
  // on the first block(s) after a reset; caller fills the tail).
  auto processStage = [&](size_t st, const float* src, float* dst,
                          uint32_t count, bool inPlace) -> uint32_t {
    auto* model = models[st];
    if (!model) {
      if (dst != src) std::memcpy(dst, src, count * sizeof(float));
      return count;
    }
    const int f = truePipelineFactor(osApplied[st], sampleRate);
    if (f <= 1) {
      // Base-rate stage (NONE or LEGACY), or a TRUE stage COASTING (f == 1:
      // the Element wrapper already supplies the target rate). Both process
      // the model directly at the incoming rate, no converters — running a
      // cascade here would DOUBLE the rate on top of the wrapper (the bug
      // behind "True 2x and True 4x cost the same"). The models are created
      // for exactly this effective processing rate by the worker.
      (void)inPlace;
      const float pre = dbToLinear(model->GetRecommendedInputDBAdjustment());
      if (dst != src || pre != 1.0f) {
        if (dst != src) std::memcpy(dst, src, count * sizeof(float));
        if (pre != 1.0f)
          for (uint32_t i = 0; i < count; ++i) dst[i] *= pre;
      }
      model->Process(dst, dst, count);
      const float post = dbToLinear(model->GetRecommendedOutputDBAdjustment());
      if (post != 1.0f)
        for (uint32_t i = 0; i < count; ++i) dst[i] *= post;
      return count;
    }
    // TRUE-Nx cascade: 2x = 1 level, 4x = 2, 8x = 3. Each level is its OWN
    // converter instance (own streaming history); sharing one across levels
    // corrupts the stream — that was the 2026-08-29 True-4x/8x bug. Levels
    // PING-PONG between two scratch buffers: neither Up2x nor Down2x is
    // in-place safe (each writes outputs into indices that later outputs'
    // windows still read). The model processes ~count * f samples at Nx,
    // which is exactly why the CPU meter must climb with the factor.
    const size_t levels = f == 8 ? 3 : (f == 4 ? 2 : 1);
    float* bufs[2] = {osScratch[st].data(), osScratch2[st].data()};
    size_t n = osUp[st][0].process(src, count, bufs[0]);
    for (size_t c = 1; c < levels && n > 0; ++c)
      n = osUp[st][c].process(bufs[(c - 1) % 2], n, bufs[c % 2]);
    float* domain = bufs[(levels - 1) % 2];
    if (n == 0 || n + 64 > osScratch[st].size()) {
      if (dst != src) std::memcpy(dst, src, count * sizeof(float));
      return count;
    }
    const float pre = dbToLinear(model->GetRecommendedInputDBAdjustment());
    if (pre != 1.0f)
      for (size_t i = 0; i < n; ++i) domain[i] *= pre;
    model->Process(domain, domain, n);
    const float post = dbToLinear(model->GetRecommendedOutputDBAdjustment());
    if (post != 1.0f)
      for (size_t i = 0; i < n; ++i) domain[i] *= post;
    // Decimate back down the same chain (reversed), ping-ponging between
    // the two scratch buffers; the last level lands in dst.
    size_t back = n;
    const float* dnIn = domain;
    for (size_t c = levels; c-- > 0;) {
      float* dnOut = (c == 0) ? dst : bufs[(c - 1) % 2];
      back = osDown[st][c].process(dnIn, back, dnOut);
      dnIn = dnOut;
    }
    if (back < count) {
      const float fill = back > 0 ? dst[back - 1]
                                  : (src ? src[0] : 0.0f);
      for (size_t i = back; i < count; ++i) dst[i] = fill;
    }
    return static_cast<uint32_t>(back);
  };

  // ---- Chain pedal -> amp through their (possibly different) domains ----
  float* chain = osChain.data();
  if (osChain.size() < (size_t)sampleCount + 64) {
    // Should not happen (sized for 8x); guard anyway.
    for (uint32_t i = 0; i < sampleCount; ++i) ports.audio_out[i] = 0.0f;
  } else {
    std::memcpy(chain, ports.audio_out, sampleCount * sizeof(float));
    uint32_t n = sampleCount;
    for (size_t st = 0; st < 2; ++st) {
      if (!enabled[st]) continue;
      n = processStage(st, chain, chain, n, true);
      // NOTE: a TRUE stage's pipeline delay means `n` can trail `sampleCount`
      // on the first blocks; later stages then process fewer samples for a
      // few blocks until the delay buffer fills. The cab IR below still gets
      // the full sampleCount (tail-filled by processStage).
    }
    std::memcpy(ports.audio_out, chain, sampleCount * sizeof(float));
  }

  // ---- Cab: WAV IR at base rate; .nam cab rides the amp's TRUE factor ----
  if (enabled[2]) {
    auto* ir = irs[2];
    auto* cabModel = models[2];
    if (ir) {
      ir->process(ports.audio_out, sampleCount);
    } else if (cabModel && cabFactor > 1) {
      // (cabFactor == 1 means the amp coasted — the cab rides at base rate
      // via the plain branch below.)
      // Same cascade shape as the amp (per-level converters, ping-pong
      // scratch), on the post-amp signal.
      const size_t cabLevels = cabFactor == 8 ? 3 : (cabFactor == 4 ? 2 : 1);
      float* cabBufs[2] = {osScratch[2].data(), osScratch2[2].data()};
      size_t n2 = osUp[2][0].process(ports.audio_out, sampleCount, cabBufs[0]);
      for (size_t c = 1; c < cabLevels && n2 > 0; ++c)
        n2 = osUp[2][c].process(cabBufs[(c - 1) % 2], n2, cabBufs[c % 2]);
      float* domain = cabBufs[(cabLevels - 1) % 2];
      if (n2 > 0 && n2 + 64 <= osScratch[2].size()) {
        const float pre = dbToLinear(cabModel->GetRecommendedInputDBAdjustment());
        if (pre != 1.0f)
          for (size_t i = 0; i < n2; ++i) domain[i] *= pre;
        cabModel->Process(domain, domain, n2);
        const float post = dbToLinear(cabModel->GetRecommendedOutputDBAdjustment());
        if (post != 1.0f)
          for (size_t i = 0; i < n2; ++i) domain[i] *= post;
        size_t nBack = n2;
        const float* dnIn = domain;
        for (size_t c = cabLevels; c-- > 0;) {
          float* dnOut = (c == 0) ? ports.audio_out : cabBufs[(c - 1) % 2];
          nBack = osDown[2][c].process(dnIn, nBack, dnOut);
          dnIn = dnOut;
        }
        if (nBack < sampleCount) {
          const float fill = nBack > 0 ? ports.audio_out[nBack - 1] : 0.0f;
          for (size_t i = nBack; i < sampleCount; ++i) ports.audio_out[i] = fill;
        }
      }
    } else if (cabModel) {
      cabModel->Process(ports.audio_out, ports.audio_out, sampleCount);
    }
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
             ? 0.99f * gain + 0.01f * desiredOutput
             : desiredOutput;
    ports.audio_out[i] *= gain;
  }
  smoothedOutputLevel = gain;
}

void Plugin::reloadModelsForOversample() {
  // Re-send every loaded model path through the worker so the models are
  // re-created with the loader external rate matching the new domain.
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
