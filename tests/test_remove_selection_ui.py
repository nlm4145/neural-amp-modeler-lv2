#!/usr/bin/env python3
"""Guard the remove selection capability via right-click on pedal, amp, and cab cards."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ui = (ROOT / "src/nam_rig_ui.mm").read_text()
state = (ROOT / "src/rig_ui_state.h").read_text()

# 1. Verify stageCards tracking in RigUIState
assert "std::array<__strong RigPanel*, 3> stageCards{};" in state, \
    "RigUIState missing stageCards array"

# 2. Verify NAMRigUIController interface declarations
assert "<NSComboBoxDelegate, NSTextFieldDelegate, NSMenuDelegate>" in ui, \
    "NAMRigUIController must conform to NSMenuDelegate"
assert "- (void)removeStageSelection:(id)sender;" in ui, \
    "NAMRigUIController missing removeStageSelection: declaration"
assert "- (void)removeBothCabsSelection:(id)sender;" in ui, \
    "NAMRigUIController missing removeBothCabsSelection: declaration"
assert "- (void)menuNeedsUpdate:(NSMenu*)menu;" in ui, \
    "NAMRigUIController missing menuNeedsUpdate: declaration"

# 3. Verify context menu setup on stage cards (pedal, amp, cab)
assert 'cardMenu.identifier = [NSString stringWithFormat:@"stage_card_menu_%ld", (long)i];' in ui, \
    "Stage cards must assign stage_card_menu_<stage> identifier"
assert "box.menu = cardMenu;" in ui, "box.menu must be assigned cardMenu"
assert "thumb.menu = cardMenu;" in ui, "thumb.menu must be assigned cardMenu"
assert "header.menu = cardMenu;" in ui, "header.menu must be assigned cardMenu"
assert "state->stageCards[(size_t)i] = box;" in ui, "state->stageCards must track stage boxes"

# 4. Verify context menu dynamic update implementation
assert 'stage_card_menu_0' in ui, "menuNeedsUpdate must handle stage 0 (pedal)"
assert 'stage_card_menu_1' in ui, "menuNeedsUpdate must handle stage 1 (amp)"
assert 'stage_card_menu_2' in ui, "menuNeedsUpdate must handle stage 2 (cab)"
assert '@"Remove Selection"' in ui, "menuNeedsUpdate must offer Remove Selection item"
assert '@selector(removeStageSelection:)' in ui, "menuNeedsUpdate item must target removeStageSelection:"
assert '@"Remove Cab B Selection"' in ui, "menuNeedsUpdate must offer Remove Cab B Selection when Cab B loaded"
assert '@"Remove Both Selections"' in ui, "menuNeedsUpdate must offer Remove Both Selections when Cab B loaded"
assert '@selector(removeBothCabsSelection:)' in ui, "Remove Both Selections must target removeBothCabsSelection:"

# 5. Verify removal logic in clearModel / removeStageSelection
assert "_state->setStageModels(stage, @[]);" in ui, \
    "removeStageSelection must clear stage models"
assert '_state->sendPath(stage, "");' in ui, \
    "removeStageSelection must send empty path to unload DSP model"
assert "_state->setStageThumb(stage, nil, 0, nil);" in ui, \
    "removeStageSelection must reset stage thumbnail to placeholder"
assert "_state->powerButtons[3].state = NSControlStateValueOff;" in ui, \
    "Removing Cab B must toggle off Cab B power button"

# 6. Verify right-click discoverability tooltips
assert "Right-click card to remove selection." in ui, \
    "Stage tips and thumb tooltips must mention right-clicking card to remove selection"

print("  PASS  remove selection on pedal, amp, and cab cards verified")
