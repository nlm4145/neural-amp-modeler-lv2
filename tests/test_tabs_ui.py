#!/usr/bin/env python3
"""Guard the tabbed UI contract between Rig and Tone3000 panes."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ui = (ROOT / "src/nam_rig_ui.mm").read_text()
state = (ROOT / "src/rig_ui_state.h").read_text()
standalone = (ROOT / "src/standalone_main.mm").read_text()
browser = (ROOT / "src/rig_tone_browser.mm").read_text()

# Verify pane and tab state declarations
assert "rigPane" in state, "RigUIState missing rigPane"
assert "tonePane" in state, "RigUIState missing tonePane"
assert "rigTabBtn" in state, "RigUIState missing rigTabBtn"
assert "toneTabBtn" in state, "RigUIState missing toneTabBtn"
assert "selectTab(NSInteger tab)" in state, "RigUIState missing selectTab method"
assert "rigPane.hidden = (tab != 0)" in state, "selectTab must toggle rigPane.hidden"
assert "tonePane.hidden = (tab != 1)" in state, "selectTab must toggle tonePane.hidden"

# Verify 1280x980 base size in UI state and standalone app
assert "baseH = 980.0" in state, "Base height must be 980.0"
assert "NSMakeRect(0, 0, 1280, 980)" in standalone, "Standalone window must be 1280x980"

# Verify UI elements and wiring
assert '@"RIG"' in ui, "UI missing RIG tab button title"
assert '@"TONE3000"' in ui, "UI missing TONE3000 tab button title"
assert "switchTab:" in ui, "NAMRigUIController missing switchTab: action"
assert "addToneBrowser(state, tonePane)" in ui, "ToneBrowser must be mounted to tonePane"
assert "[rigPane addSubview:boxRow]" in ui, "Stage boxes must be mounted to rigPane"
assert "expansionSlot" in ui, "Empty expansion space must be present on rigPane"
assert "state->selectTab(0)" in ui, "Initial tab selection must default to Rig (0)"

# Verify enlarged Tone3000 cards
assert "minimumItemSize = NSMakeSize(270, 108)" in ui, "Card grid must use enlarged minimum card size"
assert "NSMakeRect(8, 8, 92, 92)" in browser, "ToneCardItem must use enlarged 92x92 artwork"
assert "_tagField" in browser, "ToneCardItem must include tag field"

print("  PASS  tabbed UI contract verified (1280x980, Rig empty expansion space, and enlarged Tone cards)")
