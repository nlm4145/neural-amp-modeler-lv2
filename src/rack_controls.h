#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace NAMRig {

enum class Rack : size_t {
  Delay, Reverb, Spatial, Power, Sculpt, Transformer, Speaker, CabConsole, PowerTube, Count
};
inline constexpr size_t kRackCount = static_cast<size_t>(Rack::Count);
inline constexpr uint32_t kRackControlFirstPort = 71;
inline constexpr std::array<const char*, kRackCount> kRackControlSymbols = {
    "delay_enabled", "reverb_enabled", "spatial_enabled", "power_enabled",
    "sculpt_enabled", "transformer_enabled", "speaker_enabled", "cab_console_enabled",
    "power_tube_enabled"};
inline constexpr std::array<const char*, kRackCount> kRackSlotKeys = {
    "delay", "reverb", "spatial", "power", "sculpt", "transformer", "speaker", "cab_console",
    "power_tube"};
inline constexpr std::array<float, kRackCount> kRackControlDefaults = {
    1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f};

} // namespace NAMRig
