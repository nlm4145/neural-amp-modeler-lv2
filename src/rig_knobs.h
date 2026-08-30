// Knob configuration constants — extracted verbatim from nam_rig_ui.mm.
#pragma once
#include <array>
#include <cstddef>
#include <cstdint>

// Knob configuration — index order matches the LV2 port list in nam_rig_plugin.ttl.
// strip. Atom ports (0/1) and the stage toggles (7-10) are handled separately.
constexpr size_t kRigKnobCount = 12;
extern const std::array<uint32_t, kRigKnobCount> kRigKnobPorts;
// Footer display order follows the SIGNAL CHAIN, not the port list:
// GATE -> INPUT -> [pedal/amp/cab stages] -> BASS -> MID -> TREBLE -> OUTPUT.
// Maps display slot -> index into kRigKnobPorts (port tags / state arrays unchanged).
extern const std::array<size_t, kRigKnobCount> kRigKnobDisplayOrder;
