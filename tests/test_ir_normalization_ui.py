#!/usr/bin/env python3
"""Guard the two cabinet modes and their existing port IDs."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ui = (ROOT / "src/nam_rig_ui.mm").read_text()
state = (ROOT / "src/rig_ui_state.h").read_text()
presets = (ROOT / "src/rig_presets.mm").read_text()
win_ui = (ROOT / "src/win32_ui_view.cpp").read_text()
wav = (ROOT / "src/wav_ir.cpp").read_text()

assert '[@"Peak", @"Loudness"]' in ui
assert "[norm selectItemAtIndex:1]" in ui
action = ui.split("- (void)irNormalizationChanged:(NSPopUpButton*)sender {", 1)[1].split("\n}", 1)[0]
assert "sendControl(24, sender.indexOfSelectedItem == 0 ? 1.0f : 2.0f)" in action
assert "sendPath" not in action
assert "NAMRig::decodeIrNormalization(value) - 1" in state
assert "state->irNormPopup.indexOfSelectedItem == 0 ? 1.0f : 2.0f" in presets
assert "NAMRig::decodeIrNormalization(c.currentValue) == 1 ? 2.0f : 1.0f" in win_ui
assert "if (port == 24) value = NAMRig::decodeIrNormalization(value)" in win_ui
assert "normalizationMode == 1 ? peakScale : loudnessScale" in wav
print("  PASS  Peak/Loudness retain IDs 1/2; retired modes use Loudness")
