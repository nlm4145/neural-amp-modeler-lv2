#pragma once

#include "oversample_modes.h"
#include "rig_control_metadata.h"

namespace NAMRigWin32 {

// Windows preset coverage includes explicit zeros, but excludes pins and host-only modes.
template <typename Set>
inline void forEachWin32ControlDefault(Set&& set) {
  // Avoid the full symbol enumerator: generating unused pin names can allocate.
  for (const auto& entry : NAMRig::kRigStaticControlSymbols) {
    float value = 0.0f;
    switch (entry.port) {
      case 7: case 8: case 9: value = 1.0f; break;
      case 15: value = -80.0f; break;
      case 20: case 21: value = static_cast<float>(NAMRig::kOversampleTrue8); break;
      case 23: value = 150.0f; break;
      case 24: value = 2.0f; break;
      case 27: value = 20000.0f; break;
      case 43: case 44: value = 25.0f; break;
      case 45: case 46: case 55: case 56: case 57:
      case NAMRig::kOverdriveTonePort: value = 50.0f; break;
      case 50: value = 400.0f; break;
      case 51: value = 35.0f; break;
      case 52: value = 40.0f; break;
      case 58: value = 10.0f; break;
      case NAMRig::kCompressorAttackPort: value = NAMRig::kCompressorAttackDefault; break;
      case NAMRig::kCompressorReleasePort: value = NAMRig::kCompressorReleaseDefault; break;
      case NAMRig::kCompressorEnabledPort:
      case NAMRig::kOverdriveEnabledPort: value = 1.0f; break;
      case NAMRig::kPostCompressorAmountPort:
      case NAMRig::kPostCompressorAttackPort:
      case NAMRig::kPostCompressorReleasePort:
      case NAMRig::kPostCompressorEnabledPort:
        value = NAMRig::kPostCompressorDefaults[entry.port - NAMRig::kPostCompressorFirstPort]; break;
      case NAMRig::kOverdriveTightPort:
        value = NAMRig::kOverdriveTightDefault; break;
      case NAMRig::kOverdriveVoicingPort:
        value = NAMRig::kOverdriveVoicingDefault; break;
      default: break;
    }
    set(entry.port, value);
  }
  for (uint32_t i = 0; i < NAMRig::kTransformerControlCount; ++i)
    set(NAMRig::kTransformerControlFirstPort + i, NAMRig::kTransformerControls[i].defaultValue);
  for (uint32_t i = 0; i < NAMRig::kRackCount; ++i)
    set(NAMRig::kRackControlFirstPort + i, NAMRig::kRackControlDefaults[i]);
}

} // namespace NAMRigWin32
