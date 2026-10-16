#pragma once

#include <array>
#include <cstdint>
#include <string>

#include "pin_eq.h"
#include "rack_controls.h"
#include "transformer_controls.h"

namespace NAMRig {

struct RigControlSymbol {
  uint32_t port;
  const char* symbol;
};

// Preset names, not every LV2 control: legacy global modes and meters stay excluded.
inline constexpr RigControlSymbol kRigStaticControlSymbols[] = {
    {4, "input_level"},
    {5, "output_level"},
    {7, "pedal_enabled"},
    {8, "amp_enabled"},
    {9, "cab_enabled"},
    {12, "bass"},
    {13, "mid"},
    {14, "treble"},
    {15, "gate_threshold"},
    {20, "pedal_oversample"},
    {21, "amp_oversample"},
    {22, "amp_drive"},
    {23, "gate_release"},
    {24, "ir_normalization"},
    {25, "cab_level"},
    {26, "cab_low_cut"},
    {27, "cab_high_cut"},
    {28, "compressor"},
    {30, "transformer_type"},
    {32, "stereo_width"},
    {33, "room"},
    {34, "presence"},
    {35, "depth"},
    {36, "sag"},
    {37, "bias"},
    {38, "negative_feedback"},
    {39, "bright"},
    {40, "input_eq"},
    {41, "master"},
    {42, "speaker_profile"},
    {43, "speaker_drive"},
    {44, "speaker_compression"},
    {45, "speaker_thump"},
    {46, "speaker_resonance"},
    {47, "cab2_enabled"},
    {48, "cab2_level"},
    {49, "cab2_delay"},
    {50, "delay_time"},
    {51, "delay_feedback"},
    {52, "delay_damping"},
    {53, "delay_mix"},
    {54, "reverb_mix"},
    {55, "reverb_decay"},
    {56, "reverb_size"},
    {57, "reverb_damping"},
    {58, "reverb_predelay"},
    {59, "cab2_polarity"},
    {kPowerTubeTypePort, "power_tube_type"},
    {kPowerTubeCharacterPort, "power_tube_character"},
    {kMidPushPort, "mid_push"},
    {kOverdriveDrivePort, "od_drive"},
    {kOverdriveTonePort, "od_tone"},
    {kOverdriveLevelPort, "od_level"},
    {kCompressorAttackPort, "compressor_attack"},
    {kCompressorReleasePort, "compressor_release"},
    {kCompressorEnabledPort, "compressor_enabled"},
    {kOverdriveEnabledPort, "od_enabled"},
};

// Non-null results have static lifetime, including generated pin names.
inline const char* rigControlSymbol(uint32_t port) {
  for (const auto& entry : kRigStaticControlSymbols)
    if (entry.port == port) return entry.symbol;
  if (port >= kTransformerControlFirstPort &&
      port < kTransformerControlFirstPort + kTransformerControlCount)
    return kTransformerControls[port - kTransformerControlFirstPort].symbol;
  if (port >= kRackControlFirstPort && port < kRackControlFirstPort + kRackCount)
    return kRackControlSymbols[port - kRackControlFirstPort];
  if (isPinEqPort(port)) {
    static const auto symbols = [] {
      std::array<std::string, kPinEqPortCount> result;
      for (uint32_t i = 0; i < kPinEqPortCount; ++i)
        result[i] = pinEqSymbol(kPinEqFirstPort + i);
      return result;
    }();
    return symbols[port - kPinEqFirstPort].c_str();
  }
  return nullptr;
}

template <typename Visit>
inline void forEachRigControlSymbol(Visit&& visit) {
  for (const auto& entry : kRigStaticControlSymbols)
    visit(entry.port, entry.symbol);
  for (uint32_t i = 0; i < kTransformerControlCount; ++i)
    visit(kTransformerControlFirstPort + i, kTransformerControls[i].symbol);
  for (uint32_t i = 0; i < kRackCount; ++i)
    visit(kRackControlFirstPort + i, kRackControlSymbols[i]);
  for (uint32_t i = 0; i < kPinEqPortCount; ++i)
    visit(kPinEqFirstPort + i, rigControlSymbol(kPinEqFirstPort + i));
}

} // namespace NAMRig
