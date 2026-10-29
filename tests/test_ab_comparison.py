#!/usr/bin/env python3
"""Contract and regression tests for Hands-Free Tone Comparison Switcher (A/B compare)."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ui_state_h = (ROOT / "src/rig_ui_state.h").read_text()
ui_mm = (ROOT / "src/nam_rig_ui.mm").read_text()

def test_ab_apply_cycle_path_resolution():
    """Verify abApplyCycle uses pathForPresetNamed so subfolder presets are loaded correctly."""
    assert "abApplyCycle(NSString* name)" in ui_state_h, "abApplyCycle must be defined in rig_ui_state.h"
    # Ensure it uses pathForPresetNamed rather than stripping subfolders with lastPathComponent
    match = re.search(r"void abApplyCycle\(NSString\* name\)\s*\{(.*?)\n  \}", ui_state_h, re.DOTALL)
    assert match, "abApplyCycle body must be found"
    body = match.group(1)
    assert "pathForPresetNamed:name" in body, "abApplyCycle must use [presetManager pathForPresetNamed:name]"
    assert "presetsDirectory] stringByAppendingPathComponent:[[name lastPathComponent]" not in body, \
        "abApplyCycle must NOT strip directory hierarchy with [name lastPathComponent]"

def test_ab_preset_changed_preserves_cycling_and_preset_a():
    """Verify changing B mid-cycle does not overwrite Preset A and continues cycling."""
    match = re.search(r"- \(void\)abPresetChanged:\(id\)sender\s*\{(.*?)\n\}", ui_mm, re.DOTALL)
    assert match, "abPresetChanged: must be found in nam_rig_ui.mm"
    body = match.group(1)
    assert "applyPresetByName" not in body, \
        "abPresetChanged: must NOT call applyPresetByName, which mutates currentPresetName (Preset A)"
    assert "resyncABPresetBSelection" in body, \
        "abPresetChanged: must sync the B dropdown title and checkmarks"
    assert "abApplyCycle(name)" in body, \
        "abPresetChanged: must audition the new B preset via abApplyCycle"
    assert "restartABTimer" in body, \
        "abPresetChanged: must restart cadence timer so player hears full interval"

def test_ab_resync_and_menu_refresh():
    """Verify resyncABPresetBSelection handles submenus and refreshABMenus retains user choice."""
    assert "void resyncABPresetBSelection()" in ui_state_h, \
        "resyncABPresetBSelection must be defined in rig_ui_state.h"
    assert "updateCheckmarks" in ui_state_h, \
        "resyncABPresetBSelection must update checkmarks recursively across submenus"
    # In refreshABMenus, keep must start from abNameB, not stale abPresetB.selectedItem
    match = re.search(r"void refreshABMenus\(\)\s*\{(.*?)\n  \}", ui_state_h, re.DOTALL)
    assert match, "refreshABMenus body must be found"
    body = match.group(1)
    assert "keep = abNameB;" in body, \
        "refreshABMenus must preserve abNameB as source of truth for slot B"
    assert "resyncABPresetBSelection();" in body, \
        "refreshABMenus must call resyncABPresetBSelection()"

def test_start_ab_same_preset_fallback():
    """Verify startAB falls back to a different preset if A and B are the same."""
    match = re.search(r"void startAB\(\)\s*\{(.*?)\n  \}", ui_state_h, re.DOTALL)
    assert match, "startAB body must be found"
    body = match.group(1)
    assert "sameName" in body, "startAB must detect when A and B represent the same preset"
    assert "fallback" in body, "startAB must select a fallback when A and B match instead of failing"

def test_modified_preset_comparison_behavior():
    """Verify modified preset snapshot handling during A/B switching and stopping."""
    match = re.search(r"void abTick\(\)\s*\{(.*?)\n  \}", ui_state_h, re.DOTALL)
    assert match, "abTick body must be found"
    body = match.group(1)
    assert "abModifiedToken()" in body, "abTick must support modified token state"

    stop_match = re.search(r"void stopAB\(\)\s*\{(.*?)\n  \}", ui_state_h, re.DOTALL)
    assert stop_match, "stopAB body must be found"
    stop_body = stop_match.group(1)
    assert "abModifiedPreset" in stop_body, "stopAB must restore abModifiedPreset when modified"

if __name__ == "__main__":
    test_ab_apply_cycle_path_resolution()
    test_ab_preset_changed_preserves_cycling_and_preset_a()
    test_ab_resync_and_menu_refresh()
    test_start_ab_same_preset_fallback()
    test_modified_preset_comparison_behavior()
    print("  PASS  Tone comparison switcher contracts and regression tests verified")
