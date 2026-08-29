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
  // Oversampler scratch: max block in, max 2x block out, decimator input.
  osUp.setMaxBlockSize(static_cast<size_t>(size));
  osDown.setMaxBlockSize(static_cast<size_t>(2 * size));
  osUp2.setMaxBlockSize(static_cast<size_t>(size));
  osDown2.setMaxBlockSize(static_cast<size_t>(2 * size));
  osUp.reset();
  osDown.reset();
  osUp2.reset();
  osDown2.reset();
  osBuffer.assign(static_cast<size_t>(2 * size) + 64, 0.0f);
  osBuffer2.assign(static_cast<size_t>(2 * size) + 64, 0.0f);
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

  LV2SwitchModelMsg response{kWorkTypeSwitch, message->stage, {}, nullptr, nullptr, false};
  const size_t length = strnlen(message->path, MAX_FILE_NAME);

  try {
    if (length > 0 && length < MAX_FILE_NAME) {
      if (message->stage == Stage::Cab && endsWithWav(message->path)) {
        response.ir = WavIR::load(message->path, rig->sampleRate, rig->maxBufferSize).release();
      } else {
        // Oversample mode decides the loader external rate, which controls
        // NeuralAudio's dilation scaling (baked in at load time):
        //   mode 0 (OFF):    48000 — equals the common model rate, so the
        //                    dilation math is a no-op; non-48k models with a
        //                    non-divisible ratio also skip dilation.
        //   mode 1 (LEGACY): session rate — the classic dilation behavior.
        //   mode 2 (TRUE 2x): 2x session rate — models are dilated to match
        //                    the oversampled domain.
        const int sessionRate = static_cast<int>(rig->sampleRate);
        const int mode = rig->oversampleMode();
        const int modelRate = mode == 2 ? sessionRate * 2
                            : mode == 1 ? sessionRate
                                        : 48000;
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
        // the heap. Size for 2x blocks in EVERY mode (not just True 2x):
        // right after a switch to True 2x the re-loaded models have not
        // landed yet, and the still-running OLD models are fed 2x-rate
        // blocks immediately — they must already be sized for them.
        if (response.model)
          response.model->SetMaxAudioBufferSize(2 * rig->maxBufferSize);
        if (mode == 0)
          lv2_log_warning(&rig->logger,
                          "Oversampling OFF (A/B mode): model '%s' runs without rate "
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
        const double domainRate = rig->oversampleMode() == 2 ? rig->sampleRate * 2.0
                             : rig->oversampleMode() == 1 ? rig->sampleRate
                                                          : 48000.0;
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
  LV2FreeModelMsg freeMessage{kWorkTypeFree, rig->models[index], rig->irs[index]};
  rig->models[index] = message->model;
  rig->irs[index] = message->ir;
  if (message->stage == Stage::Amp) rig->ampIsFullRig = message->fullRig;
  rig->modelPaths[index] = message->path;
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
      !ports.oversample_enable)
    return;

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
        LV2LoadModelMsg message{kWorkTypeLoad, static_cast<Stage>(i), {}};
        std::memcpy(message.path, path + 1, path->size);
        schedule->schedule_work(schedule->handle, sizeof(message), &message);
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

  const bool enabled[kStageCount] = {
      *ports.pedal_enabled >= 0.5f,
      *ports.amp_enabled >= 0.5f,
      *ports.cab_enabled >= 0.5f && !(*ports.auto_cab >= 0.5f && ampIsFullRig)};
  if (ports.cab_auto_bypassed)
    *ports.cab_auto_bypassed = (*ports.auto_cab >= 0.5f && ampIsFullRig) ? 1.0f : 0.0f;

  // Oversample mode change: models must be re-created for the new rate
  // domain (dilation scaling is baked in at load time). Schedule reloads;
  // until they land the stages keep running whatever they have.
  {
    const int mode = oversampleMode();
    if (mode != oversampleApplied) {
      oversampleApplied = mode;
      reloadModelsForOversample();
      osUp.reset();
      osDown.reset();
      osUp2.reset();
      osDown2.reset();
    }
  }

  // ---- Stage processing, optionally in a 2x-oversampled domain ----
  // The nonlinear stages (pedal, amp) are the only aliasing sources; when
  // oversampleApplied == 2, they run inside UP -> Process -> DOWN with the models
  // loaded at 2*rate. The cab IR and the EQ are linear and stay at base
  // rate (linear stages cannot alias). Models not yet re-loaded for the
  // 2x domain still run — the pipeline is rate-agnostic per stage.
  const bool osRun = oversampleApplied == 2;
  bool osActive = false;   // any pedal/amp stage actually ran oversampled

  if (osRun) {
    // Upsample the post-gate/trim signal ONCE; pedal and amp consume the
    // same 2x buffer in series.
    const size_t n2 = osUp.process(ports.audio_out, sampleCount, osBuffer.data());
    if (n2 > 0 && n2 + 64 <= osBuffer.size()) {
      osActive = true;
      // pedal + amp in the 2x domain
      for (size_t stage = 0; stage < 2; ++stage) {   // Pedal, Amp
        if (!enabled[stage]) continue;
        auto* model = models[stage];
        if (!model) continue;
        const float pre = dbToLinear(model->GetRecommendedInputDBAdjustment());
        if (pre != 1.0f)
          for (size_t i = 0; i < n2; ++i) osBuffer[i] *= pre;
        model->Process(osBuffer.data(), osBuffer.data(), n2);
        const float post = dbToLinear(model->GetRecommendedOutputDBAdjustment());
        if (post != 1.0f)
          for (size_t i = 0; i < n2; ++i) osBuffer[i] *= post;
      }
      // Decimate back to base rate into the output. The converters carry a
      // fixed pipeline latency, so the first block(s) after a mode switch
      // emit slightly fewer samples than the host asked for — fill the tail
      // with the last valid sample so the output is never stale garbage
      // (a ~24-sample constant-value tail once, inaudible).
      const size_t nBack = osDown.process(osBuffer.data(), n2, ports.audio_out);
      if (nBack < sampleCount) {
        const float fill = nBack > 0 ? ports.audio_out[nBack - 1] : 0.0f;
        for (size_t i = nBack; i < sampleCount; ++i) ports.audio_out[i] = fill;
      }
    }
  }

  if (!osActive) {
    // Base-rate path (oversampling off, or the upsample produced nothing).
    for (size_t stage = 0; stage < kStageCount; ++stage) {
      if (!enabled[stage]) continue;
      auto* model = models[stage];
      auto* ir = irs[stage];
      if (ir) {
        ir->process(ports.audio_out, sampleCount);
        continue;
      }
      if (!model) continue;
      const float pre = dbToLinear(model->GetRecommendedInputDBAdjustment());
      if (pre != 1.0f)
        for (uint32_t i = 0; i < sampleCount; ++i) ports.audio_out[i] *= pre;
      model->Process(ports.audio_out, ports.audio_out, sampleCount);
      const float post = dbToLinear(model->GetRecommendedOutputDBAdjustment());
      if (post != 1.0f)
        for (uint32_t i = 0; i < sampleCount; ++i) ports.audio_out[i] *= post;
    }
  } else {
    // Oversampled path ran pedal+amp; the cab (linear IR) still runs at
    // base rate on the decimated output.
    if (enabled[2]) {
      auto* ir = irs[2];
      auto* cabModel = models[2];
      if (ir) {
        ir->process(ports.audio_out, sampleCount);
      } else if (cabModel) {
        // .nam cab models are linear-ish captures but still nonlinear DSP —
        // run them oversampled too for consistency.
        const size_t n2 = osUp2.process(ports.audio_out, sampleCount, osBuffer2.data());
        if (n2 > 0) {
          const float pre = dbToLinear(cabModel->GetRecommendedInputDBAdjustment());
          if (pre != 1.0f)
            for (size_t i = 0; i < n2; ++i) osBuffer2[i] *= pre;
          cabModel->Process(osBuffer2.data(), osBuffer2.data(), n2);
          const float post = dbToLinear(cabModel->GetRecommendedOutputDBAdjustment());
          if (post != 1.0f)
            for (size_t i = 0; i < n2; ++i) osBuffer2[i] *= post;
          const size_t nBack = osDown2.process(osBuffer2.data(), n2, ports.audio_out);
          if (nBack < sampleCount) {
            const float fill = nBack > 0 ? ports.audio_out[nBack - 1] : 0.0f;
            for (size_t i = nBack; i < sampleCount; ++i) ports.audio_out[i] = fill;
          }
        }
      }
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
      LV2LoadModelMsg message{kWorkTypeLoad, static_cast<Stage>(i), {}};
      const size_t len = modelPaths[i].size();
      if (len < MAX_FILE_NAME) {
        std::memcpy(message.path, modelPaths[i].c_str(), len + 1);
        schedule->schedule_work(schedule->handle, sizeof(message), &message);
      }
    }
  }
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
      LV2LoadModelMsg message{kWorkTypeLoad, static_cast<Stage>(i), {}};
      std::memcpy(message.path, absolutePath, length + 1);
      rig->schedule->schedule_work(rig->schedule->handle, sizeof(message), &message);
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
