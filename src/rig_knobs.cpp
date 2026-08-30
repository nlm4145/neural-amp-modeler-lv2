#include "rig_knobs.h"

// Indices 12/13/14 are the new per-stage A/B blend knobs (ports 30/31/32),
// appended at the end so the original 0..11 layout never renumbers.
const std::array<uint32_t, kRigKnobCount> kRigKnobPorts{
    15, 23, 4, 28, 22, 12, 13, 14, 25, 26, 27, 5, 30, 31, 32};
// Grouped contiguously per tile: slots 0-4 = pedal (gate/release/input/comp/
// blend), 5-9 = amp (drive/bass/mid/treble/blend), 10-14 = cab (level/low
// cut/high cut/output/blend) — each tile's blend knob lands as its 5th knob.
const std::array<size_t, kRigKnobCount> kRigKnobDisplayOrder{
    0, 1, 2, 3, 12, 4, 5, 6, 7, 13, 8, 9, 10, 11, 14};
