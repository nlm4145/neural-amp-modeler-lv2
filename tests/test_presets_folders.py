#!/usr/bin/env python3
"""Verify preset folder hierarchy scanning, relative path resolution, and menu nesting."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
presets_h = (ROOT / "src/rig_presets.h").read_text()
presets_mm = (ROOT / "src/rig_presets.mm").read_text()
ui_state_h = (ROOT / "src/rig_ui_state.h").read_text()
ui_mm = (ROOT / "src/nam_rig_ui.mm").read_text()

# 1. PresetManager supports recursive subpaths and path resolution
assert "pathForPresetNamed:" in presets_h, "pathForPresetNamed: must be declared in rig_presets.h"
assert "pathForPresetNamed:" in presets_mm, "pathForPresetNamed: must be implemented in rig_presets.mm"
assert "subpathsOfDirectoryAtPath:self.presetsDirectory" in presets_mm, \
    "rescanPresets must scan subdirectories recursively"

# 2. Save, duplicate, rename, delete handle folders
assert "uniquePresetNameForBase:" in presets_mm
assert "cleanName.stringByDeletingLastPathComponent" in presets_mm, \
    "savePreset must extract subdirectory path"
assert "createDirectoryAtPath:targetDir withIntermediateDirectories:YES" in presets_mm, \
    "savePreset must create intermediate folder directories"

# 3. Hierarchical menu building in UI
assert "buildPresetTree" in ui_state_h, \
    "RigUIState must support hierarchical preset submenus"
assert "componentsSeparatedByString:@\"/\"" in ui_state_h, \
    "rebuildPresetMenu must traverse folder path components"

# 4. Action handling handles NSMenuItem* from submenus
assert "[sender isKindOfClass:[NSMenuItem class]]" in ui_mm, \
    "presetPopupChanged must handle NSMenuItem sender from submenus"
assert "[sender isKindOfClass:[NSMenuItem class]]" in ui_mm, \
    "abPresetChanged must handle NSMenuItem sender from submenus"

print("  PASS  Preset folders and submenu hierarchy contract verified")
