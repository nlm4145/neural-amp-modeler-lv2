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
#define NAM_RIG_TUNER_NOTE_URI NAM_RIG_URI "-tuner-note"
#define NAM_RIG_TUNER_CENTS_URI NAM_RIG_URI "-tuner-cents"
#define NAM_RIG_INPUT_DB_URI NAM_RIG_URI "-input-db"

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
    float* tuner_enable;    // in:  UI toggle (0/1)
    float* tuner_note;      // out: MIDI note number, -1 = no pitch
    float* tuner_cents;     // out: detune in cents [-50, +50]
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
    LV2_URID atomFloat;
    LV2_URID tunerNote;
    LV2_URID tunerCents;
    LV2_URID inputDb;
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

  // Tuner: analyzes the RAW input signal (before gate/trim/stages/EQ).
  // Front end: 2-pole×2 lowpass then decimate to ~12 kHz (kills harmonics →
  // fewer octave errors, and makes low E comfortably inside the lag range),
  // then McLeod Pitch Method (NSDF) over a 3072-sample decimated ring.
  // Results land on output ports 17/18 + patch:Set atoms for the UI. Only
  // runs while tuner_enable is on.
  struct Tuner {
    static constexpr int kBuf = 3072;        // decimated-domain ring length
    static constexpr int kWindow = 2048;     // NSDF correlation window
    static constexpr int kMinTau = 8;        // ~1500 Hz top
    static constexpr int kMaxTau = 300;      // 12k/300 = 40 Hz floor
    std::array<float, kBuf> ring{};
    int ringPos = 0;
    int filled = 0;
    bool wasEnabled = false;
    int cooldown = 0;               // blocks to skip between analyses
    int decimPhase = 0;             // raw-sample counter for decimation
    float lastNote = -1.0f, lastCents = 0.0f;
    float sentNote = -99.0f;        // last values pushed over notify (change gate)
    float sentCentsQ = -99.0f;
    float noteHist[3] = {-1.f, -1.f, -1.f};   // median-3 display filter
    int histLen = 0;
    float nsdf[kMaxTau + 2] = {};
    float scratch[kWindow + kMaxTau] = {};   // unwrapped NSDF window
    Biquad lp1, lp2;                // anti-alias front end
    int decimFactor = 1;
    float decimRate = 12000.0f;
  } tuner;

  // Input level meter: raw input peak (dBFS) with fast-attack / ~20 dB/s
  // release ballistics; published to the UI change-gated (>=0.5 dB drift).
  struct Meter {
    float lastDb = -120.0f;
    float sentDb = -999.0f;
  } meter;
  void tunerSetRates(double rate);
};
} // namespace NAMRig
