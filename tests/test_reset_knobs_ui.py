#!/usr/bin/env python3
"""Guard the global reset-knobs UI contract."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ui = (ROOT / "src/nam_rig_ui.mm").read_text()
header = (ROOT / "src/rig_knobs.h").read_text()
source = (ROOT / "src/rig_knobs.cpp").read_text()

assert "kRigKnobDefaults" in header
assert "kRigKnobDefaults" in source
assert '@"RESET KNOBS"' in ui
assert "resetAllKnobs:" in ui
assert "for (size_t k = 0; k < kRigKnobCount; ++k)" in ui
assert "sendControl(kRigKnobPorts[k], kRigKnobDefaults[k])" in ui
assert "updateControl(kRigKnobPorts[k], kRigKnobDefaults[k])" in ui
print("  PASS  reset button restores every knob through the LV2 control path")
