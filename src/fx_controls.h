#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "power_tube_controls.h"

namespace NAMRig {

// Appended control ports for performance control, the effect racks, capture
// morphing, the extra cabinets and the mic models. APPEND-ONLY after 181.
inline constexpr uint32_t kFxControlFirstPort = 182;

enum FxPort : uint32_t {
  kScenePort = kFxControlFirstPort,
  kMidiChannelPort,
  kExpr1CcPort,
  kExpr2CcPort,
  kExpr1ValuePort,
  kExpr2ValuePort,
  kMod1TargetPort,
  kMod1SourcePort,
  kMod1RatePort,
  kMod1DepthPort,
  kMod2TargetPort,
  kMod2SourcePort,
  kMod2RatePort,
  kMod2DepthPort,
  kMod3TargetPort,
  kMod3SourcePort,
  kMod3RatePort,
  kMod3DepthPort,
  kMod4TargetPort,
  kMod4SourcePort,
  kMod4RatePort,
  kMod4DepthPort,
  kFxRackFirstPort,
  kWahEnabledPort = kFxRackFirstPort,
  kModFxEnabledPort,
  kPitchEnabledPort,
  kMbcEnabledPort,
  kSynthEnabledPort,
  kLooperEnabledPort,
  kMicEnabledPort,
  kWahModePort,
  kWahPositionPort,
  kWahResonancePort,
  kWahSensitivityPort,
  kOdTypePort,
  kReverbTypePort,
  kMbcLowXoverPort,
  kMbcHighXoverPort,
  kMbcLowPort,
  kMbcMidPort,
  kMbcHighPort,
  kModFxTypePort,
  kModFxRatePort,
  kModFxDepthPort,
  kModFxFeedbackPort,
  kModFxMixPort,
  kPitchModePort,
  kPitchShiftPort,
  kPitchShift2Port,
  kPitchDetunePort,
  kPitchMixPort,
  kPitchPostPort,
  kPitchWhammyPort,
  kLooperStatePort,
  kLooperLevelPort,
  kSynthWavePort,
  kSynthMixPort,
  kSynthFilterPort,
  kAmpMorphPort,
  kCab3EnabledPort,
  kCab3LevelPort,
  kCab3PanPort,
  kCab4EnabledPort,
  kCab4LevelPort,
  kCab4PanPort,
  kCabMicDistancePort,
  kCabMicPositionPort,
  kCab2MicDistancePort,
  kCab2MicPositionPort,
  kCab3MicDistancePort,
  kCab3MicPositionPort,
  kCab4MicDistancePort,
  kCab4MicPositionPort,
  kLooperCcPort,
  kFxControlEndPort
};

inline constexpr uint32_t kFxControlCount = kFxControlEndPort - kFxControlFirstPort;
static_assert(kFxControlEndPort == kRigControlPortCount);
static_assert(kMod1TargetPort == 188 && kFxRackFirstPort == 204 && kWahModePort == 211);
static_assert(kAmpMorphPort == 239 && kCab3EnabledPort == 240 && kCabMicDistancePort == 246);
static_assert(kLooperCcPort == 254 && kFxControlCount == 73);

// Model/IR stages shared by the DSP, the hosts and the preset files.
inline constexpr size_t kRigStageCount = 7;
inline constexpr std::array<const char*, kRigStageCount> kRigStageRoles = {
    "pedal", "amp", "cab", "cab2", "amp2", "cab3", "cab4"};
inline constexpr std::array<bool, kRigStageCount> kRigStageEnabledDefaults = {
    true, true, true, false, true, false, false};

inline constexpr size_t kModifierCount = 4;
inline constexpr uint32_t kModifierPortStride = 4;
inline constexpr uint32_t modifierPort(size_t slot, uint32_t field) {
  return kMod1TargetPort + static_cast<uint32_t>(slot) * kModifierPortStride + field;
}

enum class FxRack : size_t { Wah, ModFx, Pitch, Multiband, Synth, Looper, Mic, Count };
inline constexpr size_t kFxRackCount = static_cast<size_t>(FxRack::Count);
static_assert(kFxRackFirstPort + kFxRackCount == kWahModePort);
inline constexpr std::array<const char*, kFxRackCount> kFxRackSlotKeys = {
    "wah", "mod_fx", "pitch", "mbc", "synth", "looper", "mic"};
inline constexpr std::array<float, kFxRackCount> kFxRackDefaults = {
    0.0f, 1.0f, 1.0f, 1.0f, 0.0f, 1.0f, 1.0f};

enum class FxControlKind : uint8_t { Continuous, Toggle, Enum };

struct FxControl {
  const char* symbol;
  const char* name;
  const char* unit;
  float minimum;
  float maximum;
  float defaultValue;
  FxControlKind kind;
  bool logarithmic;
  const char* const* labels;
  uint8_t labelCount;
  const char* comment;
};

inline constexpr const char* kModSourceLabels[] = {
    "Off", "LFO Sine", "LFO Triangle", "LFO Square", "LFO Saw Up", "LFO Saw Down",
    "LFO Random", "Envelope", "Sequencer 4", "Sequencer 8", "Expression 1", "Expression 2"};
inline constexpr uint8_t kModSourceCount = 12;
inline constexpr const char* kWahModeLabels[] = {
    "Wah", "Auto Wah", "Low Pass", "Band Pass", "High Pass"};
inline constexpr const char* kOdTypeLabels[] = {
    "Screamer", "Blues", "Distortion", "Fuzz", "Treble Boost", "Clean Boost"};
inline constexpr const char* kReverbTypeLabels[] = {"Plate", "Spring", "Hall"};
inline constexpr const char* kModFxTypeLabels[] = {
    "Chorus", "Flanger", "Phaser", "Tremolo", "Vibrato", "Rotary"};
inline constexpr const char* kPitchModeLabels[] = {"Shift", "Detune", "Harmony", "Whammy"};
inline constexpr const char* kPitchPostLabels[] = {"Pre-Amp", "Post-Cab"};
inline constexpr const char* kLooperStateLabels[] = {"Stop", "Record", "Play", "Overdub"};
inline constexpr const char* kSynthWaveLabels[] = {"Off", "Sine", "Square", "Saw", "Sub Octave"};
inline constexpr const char* kSceneLabels[] = {
    "Scene 1", "Scene 2", "Scene 3", "Scene 4", "Scene 5", "Scene 6", "Scene 7", "Scene 8"};
inline constexpr uint8_t kSceneCount = 8;

// Parameters a modifier can drive. Index 0 is Off. Ranges are the knob ranges
// the UI uses; the DSP clamps the modulated value to them.
struct ModTarget {
  uint32_t port;
  float minimum;
  float maximum;
  const char* label;
};
inline constexpr ModTarget kModTargets[] = {
    {0, 0.0f, 0.0f, "Off"},
    {4, -20.0f, 20.0f, "Input Level"},
    {5, -20.0f, 20.0f, "Output Level"},
    {22, -24.0f, 24.0f, "Amp Drive"},
    {41, 0.0f, 100.0f, "Master"},
    {34, -12.0f, 12.0f, "Presence"},
    {35, -12.0f, 12.0f, "Depth"},
    {36, 0.0f, 100.0f, "Sag"},
    {12, -12.0f, 12.0f, "Bass"},
    {13, -12.0f, 12.0f, "Mid"},
    {14, -12.0f, 12.0f, "Treble"},
    {15, -80.0f, 0.0f, "Gate Threshold"},
    {28, 0.0f, 100.0f, "Compressor"},
    {25, -24.0f, 24.0f, "Cab A Level"},
    {48, -24.0f, 24.0f, "Cab B Level"},
    {32, 0.0f, 100.0f, "Width"},
    {33, 0.0f, 100.0f, "Room"},
    {50, 20.0f, 2000.0f, "Delay Time"},
    {51, 0.0f, 100.0f, "Delay Feedback"},
    {53, 0.0f, 100.0f, "Delay Mix"},
    {54, 0.0f, 100.0f, "Reverb Mix"},
    {55, 0.0f, 100.0f, "Reverb Decay"},
    {kOverdriveDrivePort, 0.0f, 100.0f, "OD Drive"},
    {kOverdriveLevelPort, -12.0f, 12.0f, "OD Level"},
    {kMidPushPort, 0.0f, 100.0f, "Mid Push"},
    {kWahPositionPort, 0.0f, 100.0f, "Wah Position"},
    {kModFxRatePort, 0.05f, 10.0f, "Mod Rate"},
    {kModFxDepthPort, 0.0f, 100.0f, "Mod Depth"},
    {kModFxMixPort, 0.0f, 100.0f, "Mod Mix"},
    {kPitchWhammyPort, 0.0f, 100.0f, "Whammy"},
    {kPitchMixPort, 0.0f, 100.0f, "Pitch Mix"},
    {kPitchShiftPort, -24.0f, 24.0f, "Pitch Shift"},
    {kAmpMorphPort, 0.0f, 100.0f, "Amp Morph"},
    {kSynthMixPort, 0.0f, 100.0f, "Synth Mix"},
    {kSynthFilterPort, 0.0f, 100.0f, "Synth Filter"},
    {kLooperLevelPort, -24.0f, 6.0f, "Looper Level"},
    {kMbcLowPort, 0.0f, 100.0f, "Multiband Low"},
    {kMbcHighPort, 0.0f, 100.0f, "Multiband High"},
    {kCabMicDistancePort, 0.0f, 100.0f, "Mic A Distance"},
    {kCab2MicDistancePort, 0.0f, 100.0f, "Mic B Distance"},
};
inline constexpr uint8_t kModTargetCount = sizeof(kModTargets) / sizeof(kModTargets[0]);
inline constexpr const char* kModTargetLabels[] = {
    "Off", "Input Level", "Output Level", "Amp Drive", "Master", "Presence", "Depth", "Sag",
    "Bass", "Mid", "Treble", "Gate Threshold", "Compressor", "Cab A Level", "Cab B Level",
    "Width", "Room", "Delay Time", "Delay Feedback", "Delay Mix", "Reverb Mix", "Reverb Decay",
    "OD Drive", "OD Level", "Mid Push", "Wah Position", "Mod Rate", "Mod Depth", "Mod Mix",
    "Whammy", "Pitch Mix", "Pitch Shift", "Amp Morph", "Synth Mix", "Synth Filter",
    "Looper Level", "Multiband Low", "Multiband High", "Mic A Distance", "Mic B Distance"};
static_assert(sizeof(kModTargetLabels) / sizeof(kModTargetLabels[0]) == kModTargetCount);

#define NAMRIG_FX_MODIFIER(N)                                                                  \
  {"mod" #N "_target", "Modifier " #N " Target", "", 0.0f, static_cast<float>(kModTargetCount - 1), \
   0.0f, FxControlKind::Enum, false, kModTargetLabels, kModTargetCount,                        \
   "Parameter driven by modifier " #N ". Off disconnects the modifier."},                      \
  {"mod" #N "_source", "Modifier " #N " Source", "", 0.0f, static_cast<float>(kModSourceCount - 1), \
   0.0f, FxControlKind::Enum, false, kModSourceLabels, kModSourceCount,                        \
   "Control source: an LFO shape, the input envelope, a step sequencer or an expression pedal."}, \
  {"mod" #N "_rate", "Modifier " #N " Rate", "Hz", 0.05f, 20.0f, 1.0f, FxControlKind::Continuous, \
   true, nullptr, 0, "LFO or sequencer rate in Hz."},                                           \
  {"mod" #N "_depth", "Modifier " #N " Depth", "%", -100.0f, 100.0f, 0.0f,                     \
   FxControlKind::Continuous, false, nullptr, 0,                                               \
   "How far the source moves the target across its range. Negative inverts the motion."}

inline constexpr std::array<FxControl, kFxControlCount> kFxControls = {{
    {"scene", "Scene", "", 0.0f, 7.0f, 0.0f, FxControlKind::Enum, false, kSceneLabels, kSceneCount,
     "Active scene (1-8). Each scene is a complete snapshot of every control; the UI recalls it. MIDI Program Change 0-7 selects a scene."},
    {"midi_channel", "MIDI Channel", "", 0.0f, 16.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "MIDI channel the rig listens on. 0 = omni."},
    {"expr1_cc", "Expression 1 CC", "", 0.0f, 127.0f, 11.0f, FxControlKind::Continuous, false, nullptr, 0,
     "MIDI continuous controller number for expression pedal 1."},
    {"expr2_cc", "Expression 2 CC", "", 0.0f, 127.0f, 1.0f, FxControlKind::Continuous, false, nullptr, 0,
     "MIDI continuous controller number for expression pedal 2."},
    {"expr1_value", "Expression 1", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Expression pedal 1 position. Host automation sets it; incoming MIDI on the assigned CC overrides it."},
    {"expr2_value", "Expression 2", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Expression pedal 2 position. Host automation sets it; incoming MIDI on the assigned CC overrides it."},
    NAMRIG_FX_MODIFIER(1),
    NAMRIG_FX_MODIFIER(2),
    NAMRIG_FX_MODIFIER(3),
    NAMRIG_FX_MODIFIER(4),
    {"wah_enabled", "Wah / Filter On", "", 0.0f, 1.0f, 0.0f, FxControlKind::Toggle, false, nullptr, 0,
     "Wah / filter rack before the pedal and amp captures."},
    {"mod_fx_enabled", "Modulation On", "", 0.0f, 1.0f, 1.0f, FxControlKind::Toggle, false, nullptr, 0,
     "Stereo modulation rack after the cabinets."},
    {"pitch_enabled", "Pitch On", "", 0.0f, 1.0f, 1.0f, FxControlKind::Toggle, false, nullptr, 0,
     "Pitch shifter / harmonizer rack."},
    {"mbc_enabled", "Multiband Comp On", "", 0.0f, 1.0f, 1.0f, FxControlKind::Toggle, false, nullptr, 0,
     "Three-band compressor after the cabinets."},
    {"synth_enabled", "Synth On", "", 0.0f, 1.0f, 0.0f, FxControlKind::Toggle, false, nullptr, 0,
     "Monophonic guitar synth mixed in before the amp."},
    {"looper_enabled", "Looper On", "", 0.0f, 1.0f, 1.0f, FxControlKind::Toggle, false, nullptr, 0,
     "Stereo looper at the end of the chain."},
    {"mic_enabled", "Mic Models On", "", 0.0f, 1.0f, 1.0f, FxControlKind::Toggle, false, nullptr, 0,
     "Per-cabinet microphone distance and position models."},
    {"wah_mode", "Wah Mode", "", 0.0f, 4.0f, 0.0f, FxControlKind::Enum, false, kWahModeLabels, 5,
     "Wah: classic resonant sweep. Auto Wah: the input envelope moves the sweep. Low/Band/High Pass: a resonant state-variable filter."},
    {"wah_position", "Wah Position", "%", 0.0f, 100.0f, 50.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Sweep position (heel to toe). Assign an expression pedal through a modifier for a real wah."},
    {"wah_resonance", "Wah Resonance", "%", 0.0f, 100.0f, 50.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Peak sharpness of the wah or filter."},
    {"wah_sensitivity", "Auto Wah Sensitivity", "%", 0.0f, 100.0f, 50.0f, FxControlKind::Continuous, false, nullptr, 0,
     "How far picking dynamics open the auto wah."},
    {"od_type", "Overdrive Type", "", 0.0f, 5.0f, 0.0f, FxControlKind::Enum, false, kOdTypeLabels, 6,
     "Drive pedal circuit in front of the amp: Screamer (TS), Blues, Distortion (RAT), Fuzz, Treble Boost or Clean Boost. Drive, Tone and Level apply to every type."},
    {"reverb_type", "Reverb Type", "", 0.0f, 2.0f, 0.0f, FxControlKind::Enum, false, kReverbTypeLabels, 3,
     "Reverb algorithm: EMT plate, dispersive spring tank or a larger hall."},
    {"mbc_low_xover", "Multiband Low Crossover", "Hz", 60.0f, 500.0f, 150.0f, FxControlKind::Continuous, true, nullptr, 0,
     "Crossover between the low and mid bands."},
    {"mbc_high_xover", "Multiband High Crossover", "Hz", 1000.0f, 8000.0f, 2500.0f, FxControlKind::Continuous, true, nullptr, 0,
     "Crossover between the mid and high bands."},
    {"mbc_low", "Multiband Low", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "One-knob compression of the low band. 0 = off."},
    {"mbc_mid", "Multiband Mid", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "One-knob compression of the mid band. 0 = off."},
    {"mbc_high", "Multiband High", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "One-knob compression of the high band. 0 = off."},
    {"mod_fx_type", "Modulation Type", "", 0.0f, 5.0f, 0.0f, FxControlKind::Enum, false, kModFxTypeLabels, 6,
     "Chorus, Flanger, Phaser, Tremolo, Vibrato or Rotary speaker."},
    {"mod_fx_rate", "Modulation Rate", "Hz", 0.05f, 10.0f, 0.8f, FxControlKind::Continuous, true, nullptr, 0,
     "LFO speed. Rotary: horn speed, the drum follows slower."},
    {"mod_fx_depth", "Modulation Depth", "%", 0.0f, 100.0f, 50.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Sweep or intensity."},
    {"mod_fx_feedback", "Modulation Feedback", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Flanger/Phaser regeneration. Tremolo: stereo phase offset. Rotary: horn/drum balance."},
    {"mod_fx_mix", "Modulation Mix", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Wet/dry blend. 0 = exact bypass."},
    {"pitch_mode", "Pitch Mode", "", 0.0f, 3.0f, 0.0f, FxControlKind::Enum, false, kPitchModeLabels, 4,
     "Shift: crossfade to the shifted voice. Detune: adds +/- cents voices. Harmony: adds two interval voices. Whammy: the shift follows the Whammy control."},
    {"pitch_shift", "Pitch Shift", "st", -24.0f, 24.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Voice 1 interval in semitones (Whammy: the interval at full pedal)."},
    {"pitch_shift2", "Pitch Shift 2", "st", -24.0f, 24.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Voice 2 interval in semitones (Harmony mode)."},
    {"pitch_detune", "Pitch Detune", "ct", -50.0f, 50.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Fine detune in cents added to the voices."},
    {"pitch_mix", "Pitch Mix", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Shifted voice level. 0 = exact bypass."},
    {"pitch_post", "Pitch Position", "", 0.0f, 1.0f, 0.0f, FxControlKind::Enum, false, kPitchPostLabels, 2,
     "Pre-Amp runs the shifter in mono into the pedal and amp; Post-Cab runs it in stereo after the cabinets."},
    {"pitch_whammy", "Whammy", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Whammy pedal position. Assign an expression pedal through a modifier."},
    {"looper_state", "Looper State", "", 0.0f, 3.0f, 0.0f, FxControlKind::Enum, false, kLooperStateLabels, 4,
     "Stop, Record, Play or Overdub. The looper CC cycles Record, Play and Overdub."},
    {"looper_level", "Looper Level", "dB", -24.0f, 6.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Loop playback level."},
    {"synth_wave", "Synth Wave", "", 0.0f, 4.0f, 0.0f, FxControlKind::Enum, false, kSynthWaveLabels, 5,
     "Oscillator shape tracking the input pitch. Off = exact bypass."},
    {"synth_mix", "Synth Mix", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Synth level added to the guitar before the amp."},
    {"synth_filter", "Synth Filter", "%", 0.0f, 100.0f, 60.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Resonant low-pass cutoff on the synth voice."},
    {"amp_morph", "Amp Morph", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Blend between the Amp capture (0) and the Amp B capture (100). Both run inside the same oversampled domain. 0 is exact Amp A."},
    {"cab3_enabled", "Cab C On", "", 0.0f, 1.0f, 0.0f, FxControlKind::Toggle, false, nullptr, 0,
     "Third cabinet IR, parallel to Cab A and B (WAV impulse responses only)."},
    {"cab3_level", "Cab C Level", "dB", -24.0f, 24.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Cab C trim. -24 dB mutes it."},
    {"cab3_pan", "Cab C Pan", "%", -100.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Cab C stereo position."},
    {"cab4_enabled", "Cab D On", "", 0.0f, 1.0f, 0.0f, FxControlKind::Toggle, false, nullptr, 0,
     "Fourth cabinet IR, parallel to the others (WAV impulse responses only)."},
    {"cab4_level", "Cab D Level", "dB", -24.0f, 24.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Cab D trim. -24 dB mutes it."},
    {"cab4_pan", "Cab D Pan", "%", -100.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Cab D stereo position."},
    {"cab_mic_distance", "Cab A Mic Distance", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Virtual mic distance after the Cab A IR: 0 on the grille (exact bypass with Position 0), 100 about one metre back."},
    {"cab_mic_position", "Cab A Mic Position", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Virtual mic position: 0 dust cap (bright), 100 cone edge (dark)."},
    {"cab2_mic_distance", "Cab B Mic Distance", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Virtual mic distance after the Cab B IR."},
    {"cab2_mic_position", "Cab B Mic Position", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Virtual mic position after the Cab B IR."},
    {"cab3_mic_distance", "Cab C Mic Distance", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Virtual mic distance after the Cab C IR."},
    {"cab3_mic_position", "Cab C Mic Position", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Virtual mic position after the Cab C IR."},
    {"cab4_mic_distance", "Cab D Mic Distance", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Virtual mic distance after the Cab D IR."},
    {"cab4_mic_position", "Cab D Mic Position", "%", 0.0f, 100.0f, 0.0f, FxControlKind::Continuous, false, nullptr, 0,
     "Virtual mic position after the Cab D IR."},
    {"looper_cc", "Looper CC", "", 0.0f, 127.0f, 80.0f, FxControlKind::Continuous, false, nullptr, 0,
     "MIDI CC that steps the looper: Stop/Play -> Record -> Play -> Overdub -> Play. A value of 0 stops."},
}};
#undef NAMRIG_FX_MODIFIER

inline constexpr const FxControl& fxControl(uint32_t port) {
  return kFxControls[port - kFxControlFirstPort];
}
inline constexpr bool isFxControlPort(uint32_t port) {
  return port >= kFxControlFirstPort && port < kFxControlEndPort;
}
inline constexpr float fxControlDefault(uint32_t port) {
  return fxControl(port).defaultValue;
}
inline constexpr std::array<float, kFxControlCount> fxControlDefaults() {
  std::array<float, kFxControlCount> values{};
  for (size_t i = 0; i < kFxControlCount; ++i) values[i] = kFxControls[i].defaultValue;
  return values;
}
inline constexpr bool isFxRackPort(uint32_t port) {
  return port >= kFxRackFirstPort && port < kFxRackFirstPort + kFxRackCount;
}
inline constexpr uint32_t fxRackPort(FxRack rack) {
  return kFxRackFirstPort + static_cast<uint32_t>(rack);
}

static_assert(kFxControls[kScenePort - kFxControlFirstPort].symbol[0] == 's');
static_assert(kFxControls[kWahEnabledPort - kFxControlFirstPort].kind == FxControlKind::Toggle);
static_assert(kFxControls[kLooperCcPort - kFxControlFirstPort].defaultValue == 80.0f);
static_assert(kFxControls[kAmpMorphPort - kFxControlFirstPort].symbol[4] == 'm');
static_assert(kFxRackDefaults[static_cast<size_t>(FxRack::Wah)] ==
              kFxControls[kWahEnabledPort - kFxControlFirstPort].defaultValue);
static_assert(kFxRackDefaults[static_cast<size_t>(FxRack::Synth)] ==
              kFxControls[kSynthEnabledPort - kFxControlFirstPort].defaultValue);

} // namespace NAMRig
