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
assert "aiPane" in state, "RigUIState missing aiPane"
assert "rigTabBtn" in state, "RigUIState missing rigTabBtn"
assert "toneTabBtn" in state, "RigUIState missing toneTabBtn"
assert "aiTabBtn" in state, "RigUIState missing aiTabBtn"
assert "selectTab(NSInteger tab)" in state, "RigUIState missing selectTab method"
assert "rigPane.hidden = (tab != 0)" in state, "selectTab must toggle rigPane.hidden"
assert "tonePane.hidden = (tab != 1)" in state, "selectTab must toggle tonePane.hidden"
assert "aiPane.hidden = (tab != 2)" in state, "selectTab must toggle aiPane.hidden"

# Verify 1280x980 base size in UI state and standalone app
assert "baseH = 980.0" in state, "Base height must be 980.0"
assert "NSMakeRect(0, 0, 1520, 980)" in standalone, "Standalone window must be 1520x980"

# Verify UI elements and wiring
assert '@"RIG"' in ui, "UI missing RIG tab button title"
assert '@"TONE3000"' in ui, "UI missing TONE3000 tab button title"
assert '@"AI STUDIO"' in ui, "UI missing AI STUDIO tab button title"
assert "switchTab:" in ui, "NAMRigUIController missing switchTab: action"
assert "addToneBrowser(state, tonePane)" in ui, "ToneBrowser must be mounted to tonePane"
assert "addAIToneMatcherPage(state, aiPane)" in ui, "AIToneMatcherPage must be mounted to aiPane"
assert "[rigPane addSubview:boxRow]" in ui, "Legacy stage controls must still be constructed for workspace reuse"
assert "rigCreateWorkspace" in ui, "Contextual workspace must be mounted on rigPane"
assert "state->selectTab(0)" in ui, "Initial tab selection must default to Rig (0)"

# Verify compact Tone3000 cards
assert "minimumItemSize = NSMakeSize(270, 214)" in ui, "Card grid must use compact vertical cards"
assert "NSMakeRect(12, 86, 296, 104)" in browser, "ToneCardItem must use compact top artwork"
assert "_tagField" in browser, "ToneCardItem must include tag field"

# Verify header relocation to host toolbar space and upward boxRow shift
assert "headerBar" in state, "RigUIState missing headerBar"
assert "rigHeaderGroup" in state, "RigUIState missing rigHeaderGroup"
assert "NAMRigRootView" in ui, "UI missing NAMRigRootView host toolbar container"
assert "layoutHeaderInHostWindow" in ui, "UI missing layoutHeaderInHostWindow"
assert "rigPane.topAnchor constant:12" in ui, "boxRow topAnchor must be pinned to rigPane.topAnchor constant: 12"

# Verify tone type (gear) filter positioned next to sort dropdown inside browser search row
assert "controller.gear = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(24 + searchW + 12" in ui, \
    "controller.gear must be positioned inside browser search row next to search field"
assert "[browser addSubview:controller.gear]" in ui, "controller.gear must be added to browser"
assert "[browser addSubview:controller.sort]" in ui, "controller.sort must be added to browser"

# Verify rich tone card hover details
assert "formatToneCardTooltip" in browser, "browser missing formatToneCardTooltip"
assert 'Makes and Models' in browser, "formatToneCardTooltip must format Makes and Models"
assert 'Description' in browser, "formatToneCardTooltip must format Description"
assert 'Tags' in browser, "formatToneCardTooltip must format Tags"

print("  PASS  tabbed UI contract verified (contextual workspace, AI Studio, compact Tone3000 grid)")
