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

  for (auto& loader : loaders)
    loader.SetExternalSampleRate(static_cast<int>(rate));

  if (options)
    optionsSet(this, options);
  return true;
}

void Plugin::setMaxBufferSize(int size) noexcept {
  maxBufferSize = size;
  for (auto& loader : loaders)
    loader.SetDefaultMaxAudioBufferSize(size);
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
      if (message->stage == Stage::Cab && endsWithWav(message->path))
        response.ir = WavIR::load(message->path, rig->sampleRate, rig->maxBufferSize).release();
      else
        response.model = rig->loaders[stageIndex(message->stage)].CreateFromFile(message->path);
      if (message->stage == Stage::Amp)
        response.fullRig = isFullRigModel(message->path);
      if (response.model || response.ir)
        std::memcpy(response.path, message->path, length + 1);
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

void Plugin::process(uint32_t sampleCount) noexcept {
  if (!ports.control || !ports.notify || !ports.audio_in || !ports.audio_out ||
      !ports.input_level || !ports.output_level ||
      !ports.pedal_enabled || !ports.amp_enabled || !ports.cab_enabled || !ports.auto_cab)
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

  for (size_t stage = 0; stage < kStageCount; ++stage) {
    if (!enabled[stage]) continue;
    auto* model = models[stage];
    auto* ir = irs[stage];
    if (ir) {
      ir->process(ports.audio_out, sampleCount);
      continue;
    }
    if (!model)
      continue;

    const float pre = dbToLinear(model->GetRecommendedInputDBAdjustment());
    if (pre != 1.0f)
      for (uint32_t i = 0; i < sampleCount; ++i) ports.audio_out[i] *= pre;

    model->Process(ports.audio_out, ports.audio_out, sampleCount);

    const float post = dbToLinear(model->GetRecommendedOutputDBAdjustment());
    if (post != 1.0f)
      for (uint32_t i = 0; i < sampleCount; ++i) ports.audio_out[i] *= post;
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
