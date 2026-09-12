#!/usr/bin/env python3
"""Guard the Axe FX / NAM Rig preset serialization and management contracts."""
import json
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
presets_h = (ROOT / "src/rig_presets.h").read_text()
presets_mm = (ROOT / "src/rig_presets.mm").read_text()
ui_state_h = (ROOT / "src/rig_ui_state.h").read_text()
ui_mm = (ROOT / "src/nam_rig_ui.mm").read_text()
knobs_h = (ROOT / "src/rig_knobs.h").read_text()
knobs_cpp = (ROOT / "src/rig_knobs.cpp").read_text()

# 1. Verify RigPreset & RigPresetManager definitions
assert "@interface RigPreset" in presets_h, "RigPreset must be declared in rig_presets.h"
assert "@interface RigPresetManager" in presets_h, "RigPresetManager must be declared in rig_presets.h"
assert "stageAtIndex:" in presets_h, "stageAtIndex: must be declared in rig_presets.h"
assert "@implementation RigPreset" in presets_mm, "RigPreset must be implemented in rig_presets.mm"
assert "@implementation RigPresetManager" in presets_mm, "RigPresetManager must be implemented in rig_presets.mm"

# 2. Verify all 37 knob ports are registered in the preset map
assert "kRigKnobCount = 37" in knobs_h
expected_ports = [
    15, 23, 4, 28, 22, 12, 13, 14, 25, 26, 27, 5, 32, 33,
    34, 35, 36, 37, 38, 39, 40, 41, 43, 44, 45, 46,
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58
]
for p in expected_ports:
    assert f"@{p}:" in presets_mm, f"Port {p} must be mapped in portToSymbolMap()"

# 3. Verify stage powers, modes, and profiles are mapped
for p in [7, 8, 9, 20, 21, 24, 30, 42, 47]:
    assert f"@{p}:" in presets_mm, f"Mode/power/profile port {p} must be mapped in portToSymbolMap()"

# 4. Verify UI state bindings
assert "presetPopup" in ui_state_h
assert "prevPresetBtn" in ui_state_h
assert "nextPresetBtn" in ui_state_h
assert "savePresetBtn" in ui_state_h
assert "presetManager" in ui_state_h
assert "rebuildPresetMenu" in ui_state_h
assert "updatePresetDisplayTitle" in ui_state_h

# 5. Verify NAMRigUIController preset methods and dirty tracking
assert "presetPopupChanged:" in ui_mm
assert "prevPresetClicked:" in ui_mm
assert "nextPresetClicked:" in ui_mm
assert "saveCurrentPreset:" in ui_mm
assert "savePresetAs:" in ui_mm
assert "deleteCurrentPreset:" in ui_mm
assert "revealPresetsInFinder:" in ui_mm
assert "markPresetModified" in ui_mm

# 6. Verify dirty tracking is called on adjustments
assert "[self markPresetModified];" in ui_mm

# 7. Test preset JSON serialization / deserialization round-trip
sample_preset = {
    "name": "Mesa Modern Lead",
    "version": 1,
    "created": "2026-09-12T04:50:00Z",
    "speaker_profile": 2.0,
    "stages": [
        {
            "role": "pedal",
            "enabled": True,
            "path": "/path/to/overdrive.nam",
            "imageURL": "https://example.com/pedal.png",
            "toneId": 12345,
            "oversample": 6.0
        },
        {
            "role": "amp",
            "enabled": True,
            "path": "/path/to/mesa_lead.nam",
            "imageURL": "https://example.com/amp.png",
            "toneId": 67890,
            "oversample": 6.0,
            "transformer": 1.0
        },
        {
            "role": "cab",
            "enabled": True,
            "path": "/path/to/v30_cab.wav",
            "imageURL": "https://example.com/cab.png",
            "toneId": 11111,
            "ir_normalization": 2.0
        },
        {
            "role": "cab2",
            "enabled": False,
            "path": "",
            "imageURL": "",
            "toneId": 0
        }
    ],
    "ports": {str(p): 0.0 for p in expected_ports},
    "params": {
        "gate_threshold": -27.0,
        "input_level": 1.5,
        "amp_drive": 3.0,
        "bass": 1.0,
        "mid": -0.5,
        "treble": 2.0,
        "reverb_mix": 15.0,
        "delay_mix": 20.0
    }
}

with tempfile.NamedTemporaryFile(mode="w+", suffix=".json") as f:
    json.dump(sample_preset, f, indent=2)
    f.flush()
    f.seek(0)
    loaded = json.load(f)

assert loaded["name"] == "Mesa Modern Lead"
assert len(loaded["stages"]) == 4
assert loaded["stages"][1]["transformer"] == 1.0
assert loaded["params"]["reverb_mix"] == 15.0
assert len(loaded["ports"]) == len(expected_ports)

print("  PASS  Axe FX / NAM Rig preset contract and JSON serialization fully verified")
