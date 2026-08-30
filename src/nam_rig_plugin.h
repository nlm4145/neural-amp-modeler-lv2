#pragma once

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <string>
#include <type_traits>

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

#include "oversample.h"
#include "oversample_modes.h"
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
  int32_t oversampleMode;
  uint64_t generation;
  char path[MAX_FILE_NAME];
};

struct LV2SwitchModelMsg {
  LV2WorkType type;
  Stage stage;
  int32_t oversampleMode;
  uint64_t generation;
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
    float* oversample_mode_legacy;  // in: port 19, old global mode — IGNORED by
                                    //     the DSP (kept so the TTL's port list
                                    //     matches this struct POSITIONALLY:
                                    //     connectPort writes field N from port
                                    //     N, so this placeholder MUST stay at
                                    //     index 19 or every port after it
                                    //     shifts — that bug silently ate the
                                    //     amp mode and corrupted sampleRate)
    float* pedal_oversample;   // in: port 20, pedal mode (0..6, decodeOversample)
    float* amp_oversample;     // in: port 21, amp mode (0..6); cab follows amp
    float* amp_drive;          // in: port 22, gain between pedal and amp (dB)
    float* gate_release;       // in: port 23, expander release time (ms)
    float* ir_normalization;   // in: port 24, 0 preserve / 1 peak / 2 loudness
    float* cab_level;          // in: port 25, post-cab trim (dB)
    float* cab_low_cut;        // in: port 26, Hz (0 = off)
    float* cab_high_cut;       // in: port 27, Hz (20 kHz = off)
    float* compressor;         // in: port 28, one-knob amount (0..100%)
  };
  static_assert(std::is_standard_layout_v<Ports>);
  static_assert(offsetof(Ports, amp_drive) == 22 * sizeof(void*));
  static_assert(offsetof(Ports, compressor) == 28 * sizeof(void*));

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
  float smoothedAmpDrive = 1.0f;
  float smoothedCabLevel = 1.0f;
  Biquad bassEq, midEq, trebleEq;
  Biquad cabLowCutEq, cabHighCutEq;
  float gateDetector = 0.0f;
  float gateGain = 1.0f;
  bool gateOpen = true;
  uint32_t gateHoldRemaining = 0;
  float compressorEnvelope = 0.0f;
  float compressorGain = 1.0f;
  int32_t maxBufferSize = 512;

  // Tuner: analyzes the RAW input signal (before gate/trim/stages/EQ).
  // Front end: 2-pole×2 lowpass then decimate to ~12 kHz (kills harmonics →
  // fewer octave errors, and makes low E comfortably inside the lag range),
  // then McLeod Pitch Method (NSDF) over a 3072-sample decimated ring.
  // Results land on output ports 17/18 + patch:Set atoms for the UI. Only
  // runs while tuner_enable is on.
  struct Tuner {
    static constexpr int kBuf = 3072;        // decimated-domain ring length
    static constexpr int kWindow = 1024;     // NSDF correlation window (matches tests/test_tuner_mpm.py)
    static constexpr int kMinTau = 8;        // ~1500 Hz top
    static constexpr int kMaxTau = 300;      // 12k/300 = 40 Hz floor
    static constexpr int kMissLimit = 8;     // failed analyses before the display clears (~240 ms)
    std::array<float, kBuf> ring{};
    int ringPos = 0;
    int filled = 0;
    bool wasEnabled = false;
    int samplesSinceAnalysis = 0;   // raw-sample hop counter (rate-independent cadence)
    int decimPhase = 0;             // raw-sample counter for decimation
    float lastNote = -1.0f, lastCents = 0.0f;
    float sentNote = -99.0f;        // last values pushed over notify (change gate)
    float sentCentsQ = -99.0f;
    float noteHist[3] = {-1.f, -1.f, -1.f};   // median-3 display filter (rolling)
    int histIdx = 0;                // next write slot — MUST roll, not clamp
    int histLen = 0;
    int missCount = 0;              // consecutive analyses with no pitch
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

  // TRUE oversampling cascades. Each factor is a CHAIN of 2x half-band
  // pairs: 2x = 1 pair, 4x = 2, 8x = 3. Every level needs its OWN converter
  // instance — a level's streaming history belongs to that level's rate
  // (sharing one instance across levels corrupts the stream state; that was
  // the 2026-08-29 True-4x/8x bug). osUp[stage][level] / osDown[stage][level];
  // stage 2 (cab .nam) rides the amp's factor. osScratch[st] is the stage's
  // Nx-rate domain buffer; osChain is the base-rate pedal->amp work buffer.
  // Cab WAV IR + EQ stay at the base rate (linear stages cannot alias).
  static constexpr size_t kMaxOsLevels = 3;    // 2x, 4x, 8x
  std::array<std::array<Up2x, kMaxOsLevels>, kStageCount> osUp;
  std::array<std::array<Down2x, kMaxOsLevels>, kStageCount> osDown;
  std::array<std::vector<float>, kStageCount> osScratch;   // domain buffer A
  std::array<std::vector<float>, kStageCount> osScratch2;  // domain buffer B (ping-pong)
  std::vector<float> osChain;
  uint64_t osTopologySignature = ~uint64_t{0};

  // Last-applied mode per stage (models were loaded for this domain). Index 2
  // (cab) tracks the amp's mode — the cab .nam pipeline rides the amp domain.
  std::array<int, kStageCount> osApplied = {kOsLegacy2, kOsLegacy2, kOsLegacy2};
  // Latest port modes requested by the host. osApplied changes only when the
  // corresponding worker response lands, so an old model is never pushed
  // through a newly-selected rate domain during an asynchronous reload.
  std::array<int, 2> osRequested = {kOsLegacy2, kOsLegacy2};
  std::array<uint64_t, kStageCount> loadGeneration{};

  struct PendingSwitch {
    NeuralAudio::NeuralModel* model = nullptr;
    WavIR* ir = nullptr;
    int oversampleMode = kOsLegacy2;
    bool fullRig = false;
    bool ready = false;
    char path[MAX_FILE_NAME] = {};
  };
  std::array<PendingSwitch, kStageCount> pendingSwitches{};
  enum class TransitionPhase { Steady, FadeOut, FadeIn };
  TransitionPhase transitionPhase = TransitionPhase::Steady;
  uint32_t transitionPosition = 0;
  float transitionGain = 1.0f;
  // Per-stage oversample mode (pedal port 20, amp port 21; cab follows amp).
  // 0 = NONE   (no rate adaptation — loader external rate pinned to 48000 so
  //             dilation is a no-op for common rates; a non-48k model at a
  //             non-multiple session rate runs wrong, warning is logged),
  // 1/2/3 = LEGACY 2x/4x/8x (NeuralAudio dilation scaling: hostRate/modelRate
  //             baked in at load time — cheap, stretches the model's memory),
  // 4/5/6 = TRUE 2x/4x/8x (genuine UP -> model@Nx -> DOWN pipeline in this
  //             plugin; the aliasing fix).
  // The stage ports supersede the old global port 19 (kept in the TTL for
  // session-compat; process() ignores it).
  static constexpr int kOsNone = 0, kOsLegacy2 = 1, kOsLegacy4 = 2,
                       kOsLegacy8 = 3, kOsTrue2 = 4, kOsTrue4 = 5, kOsTrue8 = 6;

  static int decodeOversample(float v) {
    const int i = static_cast<int>(v + 0.5f);
    if (i < 0) return kOsNone;
    if (i > kOsTrue8) return kOsTrue8;
    // Legacy 4x/8x (values 2/3) are aliases of Legacy (1): dilation's factor
    // is set by the incoming rate, not the tile — the collapsed UI options
    // keep old session values mapping onto the one real Legacy behavior.
    if (i == kOsLegacy4 || i == kOsLegacy8) return kOsLegacy2;
    return i;
  }

  int stageOversample(size_t stage) const {
    // stage 0 = pedal, 1 = amp (2 = cab: follows amp in process()).
    const float* port = stage == 0 ? ports.pedal_oversample
                                    : ports.amp_oversample;
    if (!port) return kOsLegacy2;   // port not connected: keep 2x defaults
    return decodeOversample(*port);
  }

  // TRUE modes target an ABSOLUTE domain rate pinned to the user's session
  // rate, NOT the incoming rate: the Element host wrapper (Options >
  // Oversampling) feeds the plugin a multiplied stream, and True must not
  // stack on top of it. True Nx means "N x 96 kHz". The pipeline factor is
  // what's still MISSING: factor = base*N / incoming, clamped to >= 1 —
  // if the wrapper already supplied part (or all) of it, the plugin coasts.
  // Legacy tiles are deliberately the exception: dilation is defined by the
  // incoming rate, so the Element menu keeps affecting them (user decision).
  static constexpr double kTrueBaseRate = 96000.0;   // Element session rate

  // 0 = not a TRUE mode (base-rate path). Otherwise the pipeline factor for
  // this mode at this incoming rate (1 = coast: wrapper already covers it).
  static int truePipelineFactor(int mode, double incomingRate) {
    if (mode < kOsTrue2) return 0;
    const int n = 1 << (mode - kOsTrue2 + 1);          // 2 / 4 / 8
    if (incomingRate <= 0.0) return n;
    const double want = kTrueBaseRate * n / incomingRate;
    // The implementation is a cascade of 2x stages, so never return an
    // unsupported factor such as 3 or 16. The latter would otherwise be
    // misinterpreted as a single 2x level by process().
    if (want < 1.5) return 1;
    if (want < 3.0) return 2;
    if (want < 6.0) return 4;
    return 8;
  }

  // Re-load all currently-loaded model paths at the new rate domain. Called
  // on the AUDIO thread when the toggle flips (schedules worker loads; the
  // old models keep processing until each swap lands).
  void reloadModelsForOversample();
  void scheduleModelLoad(Stage stage, const char* path, size_t length, int mode);
  void commitPendingSwitches();
  void tunerSetRates(double rate);
};
} // namespace NAMRig
