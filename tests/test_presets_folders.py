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

# 5. Continued automation & Auto-organize contract
ai_copilot_h = (ROOT / "src/rig_ai_copilot.h").read_text()
ai_copilot_mm = (ROOT / "src/rig_ai_copilot.mm").read_text()
assert "hierarchicalPresetPathForTitle:" in ai_copilot_h, \
    "hierarchicalPresetPathForTitle: must be declared in rig_ai_copilot.h"
assert "hierarchicalPresetPathForTitle:" in ai_copilot_mm, \
    "hierarchicalPresetPathForTitle: must be implemented in rig_ai_copilot.mm"
assert "autoOrganizeUnsortedPresets:" in presets_h, \
    "autoOrganizeUnsortedPresets: must be declared in rig_presets.h"
assert "autoOrganizeUnsortedPresets:" in presets_mm, \
    "autoOrganizeUnsortedPresets: must be implemented in rig_presets.mm"
assert "autoOrganizePresetsAction:" in ui_mm, \
    "autoOrganizePresetsAction: must be implemented in nam_rig_ui.mm"
assert "autoOrganizePresetsAction:" in ui_state_h, \
    "autoOrganizePresetsAction: must be hooked in rig_ui_state.h"

# 6. Verify python organizer with temporary fixture
import sys
import tempfile
import json
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from scripts.organize_presets import organize_directory, resolve_preset_destination

with tempfile.TemporaryDirectory() as tmp_dir:
    p_dir = Path(tmp_dir) / "Presets"
    p_dir.mkdir()
    # Create test preset files
    (p_dir / "Default Rig.json").write_text(json.dumps({"name": "Default Rig"}))
    (p_dir / "Bullet For My Valentine - Room 409.json").write_text(json.dumps({"name": "Bullet For My Valentine - Room 409"}))
    (p_dir / "Korn - Freak on a Leash.json").write_text(json.dumps({"name": "Korn - Freak on a Leash"}))
    (p_dir / "Sludge Metal Tone.json").write_text(json.dumps({"name": "Sludge Metal Tone"}))

    moves = organize_directory(p_dir, dry_run=False)
    assert len(moves) == 3, f"Expected 3 moves, got {len(moves)}"
    assert (p_dir / "Default Rig.json").exists(), "Default Rig must remain at root"
    assert (p_dir / "Artists/Bullet For My Valentine/The Poison/Room 409.json").exists()
    assert (p_dir / "Artists/Korn/Follow the Leader/Freak on a Leash.json").exists()
    assert (p_dir / "Genre/Sludge Metal/Sludge Metal Tone.json").exists()

print("  PASS  Preset folders and submenu hierarchy contract verified")
