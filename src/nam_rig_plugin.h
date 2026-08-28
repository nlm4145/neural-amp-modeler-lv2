#pragma once

#include <array>
#include <cstdint>
#include <string>

#include <lv2/atom/atom.h>
#include <lv2/atom/forge.h>
#include <lv2/buf-size/buf-size.h>
#include <lv2/core/lv2.h>
#include <lv2/log/log.h>
#include <lv2/log/logger.h>
#include <lv2/options/options.h>
#include <lv2/patch/patch.h>
#include <lv2/state/state.h>
#include <lv2/units/units.h>
#include <lv2/urid/urid.h>
#include <lv2/worker/worker.h>

#include <NeuralAudio/NeuralModel.h>

#define NAM_RIG_URI "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig"
#define NAM_RIG_PEDAL_URI NAM_RIG_URI "-pedal-model"
#define NAM_RIG_AMP_URI NAM_RIG_URI "-amp-model"
#define NAM_RIG_CAB_URI NAM_RIG_URI "-cab-model"

namespace NAMRig {
class WavIR;
static constexpr unsigned int MAX_FILE_NAME = 1024;

enum class Stage : uint32_t { Pedal = 0, Amp = 1, Cab = 2, Count = 3 };
static constexpr size_t kStageCount = static_cast<size_t>(Stage::Count);

enum LV2WorkType : uint32_t { kWorkTypeLoad, kWorkTypeSwitch, kWorkTypeFree };

struct LV2LoadModelMsg {
  LV2WorkType type;
  Stage stage;
  char path[MAX_FILE_NAME];
};

struct LV2SwitchModelMsg {
  LV2WorkType type;
  Stage stage;
  char path[MAX_FILE_NAME];
  NeuralAudio::NeuralModel* model;
  WavIR* ir;
  bool fullRig;
};

struct LV2FreeModelMsg {
  LV2WorkType type;
  NeuralAudio::NeuralModel* model;
  WavIR* ir;
};

// Second-order biquad (transposed direct form II). At zero gain the caller
// bypasses the filter entirely, so neutral EQ stays bit-transparent.
struct Biquad {
  float b0 = 0.0f, b1 = 0.0f, b2 = 0.0f, a1 = 0.0f, a2 = 0.0f;
  float z1 = 0.0f, z2 = 0.0f;
  float process(float x) {
    const float y = b0 * x + z1;
    z1 = b1 * x - a1 * y + z2;
    z2 = b2 * x - a2 * y;
    return y;
  }
  void reset() { z1 = 0.0f; z2 = 0.0f; }
};

class Plugin {
public:
  struct Ports {
    const LV2_Atom_Sequence* control;
    LV2_Atom_Sequence* notify;
    const float* audio_in;
    float* audio_out;
    float* input_level;
    float* output_level;
    float* quality_scale;   // fixed at 1.0 (layout-compat only; DSP ignores it)
    float* pedal_enabled;
    float* amp_enabled;
    float* cab_enabled;
    float* auto_cab;
    float* cab_auto_bypassed;
    float* bass;
    float* mid;
    float* treble;
    float* gate_threshold;
  };

  Ports ports = {};
  double sampleRate = 0.0;
  LV2_URID_Map* map = nullptr;
  LV2_Log_Logger logger = {};
  LV2_Worker_Schedule* schedule = nullptr;

  std::array<NeuralAudio::NeuralModelLoader, kStageCount> loaders;
  std::array<NeuralAudio::NeuralModel*, kStageCount> models{};
  std::array<WavIR*, kStageCount> irs{};
  std::array<std::string, kStageCount> modelPaths;
  bool ampIsFullRig = false;

  Plugin();
  ~Plugin();

  bool initialize(double rate, const LV2_Feature* const* features) noexcept;
  void setMaxBufferSize(int size) noexcept;
  void process(uint32_t sampleCount) noexcept;
  void writePath(Stage stage);
  void writeAllPaths();

  static uint32_t optionsGet(LV2_Handle instance, LV2_Options_Option* options);
  static uint32_t optionsSet(LV2_Handle instance, const LV2_Options_Option* options);
  static LV2_Worker_Status work(LV2_Handle instance,
                                LV2_Worker_Respond_Function respond,
                                LV2_Worker_Respond_Handle handle,
                                uint32_t size,
                                const void* data);
  static LV2_Worker_Status workResponse(LV2_Handle instance, uint32_t size, const void* data);
  static LV2_State_Status save(LV2_Handle instance,
                               LV2_State_Store_Function store,
                               LV2_State_Handle handle,
                               uint32_t flags,
                               const LV2_Feature* const* features);
  static LV2_State_Status restore(LV2_Handle instance,
                                  LV2_State_Retrieve_Function retrieve,
                                  LV2_State_Handle handle,
                                  uint32_t flags,
                                  const LV2_Feature* const* features);

private:
  struct URIs {
    LV2_URID atomObject;
    LV2_URID atomInt;
    LV2_URID atomPath;
    LV2_URID atomURID;
    LV2_URID maxBlockLength;
    LV2_URID patchSet;
    LV2_URID patchGet;
    LV2_URID patchProperty;
    LV2_URID patchValue;
    LV2_URID unitsFrame;
    std::array<LV2_URID, kStageCount> stagePath;
  } uris{};

  LV2_Atom_Forge forge{};
  LV2_Atom_Forge_Frame sequenceFrame{};
  std::array<bool, kStageCount> notifyPending{};
  float smoothedInputLevel = 1.0f;
  float smoothedOutputLevel = 1.0f;
  Biquad bassEq, midEq, trebleEq;
  float gateDetector = 0.0f;
  float gateGain = 1.0f;
  int32_t maxBufferSize = 512;
};
} // namespace NAMRig
