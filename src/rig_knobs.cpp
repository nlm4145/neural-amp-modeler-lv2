#include "rig_knobs.h"

const std::array<uint32_t, kRigKnobCount> kRigKnobPorts{
    15, 23, 4, 28, 22, 12, 13, 14, 25, 26, 27, 5, 32, 33,
    34, 35, 36, 37, 38, 39, 40, 41, 43, 44, 45, 46};
const std::array<float, kRigKnobCount> kRigKnobDefaults{
    -80.0f, 150.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
    0.0f, 0.0f, 20000.0f, 0.0f, 0.0f, 0.0f,
    0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
    25.0f, 25.0f, 50.0f, 50.0f};
const std::array<size_t, kRigKnobCount> kRigKnobDisplayOrder{
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
    14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25};
