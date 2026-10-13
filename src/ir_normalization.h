#pragma once

namespace NAMRig {
// Keep shipped port/preset IDs: 1 = Peak, 2 = Loudness. Removed modes
// (0 = Preserve, 3 = Original) and invalid values recall as Loudness.
inline int decodeIrNormalization(float value) noexcept {
  return value >= 0.5f && value < 1.5f ? 1 : 2;
}
}
