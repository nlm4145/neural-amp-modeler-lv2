#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace NAMRig {

inline constexpr uint32_t kTransformerControlFirstPort = 60;
inline constexpr size_t kTransformerControlCount = 11;

struct TransformerControl {
  const char* symbol;
  const char* name;
  const char* unit;
  float minimum;
  float maximum;
  float defaultValue;
  bool logarithmic;
};

// Host values are neutral trims, not absolute profile parameters. Mix is an
// additive offset in percentage points; the two gains are additive dB offsets.
inline constexpr std::array<TransformerControl, 11> kTransformerControls = {{
    {"transformer_low_cut", "Transformer Low Cut Ratio", "x", 0.25f, 4.0f, 1.0f, true},
    {"transformer_high_cut", "Transformer High Cut Ratio", "x", 0.25f, 4.0f, 1.0f, true},
    {"transformer_drive", "Transformer Drive Ratio", "x", 0.25f, 4.0f, 1.0f, true},
    {"transformer_mix", "Transformer Saturation Mix Trim", "%", -100.0f, 100.0f, 0.0f, false},
    {"transformer_flux", "Transformer Flux Ratio", "x", 0.25f, 4.0f, 1.0f, true},
    {"transformer_voice_freq", "Transformer Voice Frequency Ratio", "x", 0.25f, 4.0f, 1.0f, true},
    {"transformer_voice_gain", "Transformer Voice Gain Trim", "dB", -12.0f, 12.0f, 0.0f, false},
    {"transformer_voice_q", "Transformer Voice Q Ratio", "x", 0.25f, 4.0f, 1.0f, true},
    {"transformer_leakage_freq", "Transformer Leakage Frequency Ratio", "x", 0.25f, 4.0f, 1.0f, true},
    {"transformer_leakage_gain", "Transformer Leakage Gain Trim", "dB", -12.0f, 12.0f, 0.0f, false},
    {"transformer_leakage_q", "Transformer Leakage Q Ratio", "x", 0.25f, 4.0f, 1.0f, true},
}};

inline constexpr std::array<float, 11> kTransformerControlDefaults = {
    1, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1};
using TransformerAdjustments = std::array<float, kTransformerControlCount>;

} // namespace NAMRig
