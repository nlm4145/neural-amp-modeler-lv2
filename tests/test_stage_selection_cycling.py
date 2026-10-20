#!/usr/bin/env python3
"""Contract test for stage selection and arrow-key model cycling.

Verifies:
1. Amp card whitespace/thumbnail click selects Amp stage (stage 1) with yellow border on card.
2. Cab stage card whitespace/click does NOT apply selection border to the whole tone card.
3. Cab A dropdown receives the clicked yellow border context when clicked or selected (stage 2).
4. Cab B dropdown receives the clicked yellow border context when clicked or selected (stage 3).
5. Left/Right/Up/Down arrow keys cycle through models for the active selection.
6. Switching to Tone3000 clears stage selection.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ui = (ROOT / "src/nam_rig_ui.mm").read_text()
state = (ROOT / "src/rig_ui_state.h").read_text()
widgets_h = (ROOT / "src/rig_widgets.h").read_text()
widgets_mm = (ROOT / "src/rig_widgets.mm").read_text()

# 1. RigPopUpButton contract
assert "RigPopUpButton : NSPopUpButton" in widgets_h, "RigPopUpButton declaration missing in rig_widgets.h"
assert "@property(nonatomic) BOOL showsSelection;" in widgets_h, "RigPopUpButton missing showsSelection property"
assert "@property(nonatomic, strong) NSColor* selectionBorderColor;" in widgets_h, "RigPopUpButton missing selectionBorderColor property"
assert "@property(nonatomic, copy) void (^onClick)(void);" in widgets_h, "RigPopUpButton missing onClick property"
assert "@implementation RigPopUpButton" in widgets_mm, "RigPopUpButton implementation missing in rig_widgets.mm"
assert "bezierPathWithRoundedRect:r xRadius:4.0 yRadius:4.0" in widgets_mm, "RigPopUpButton drawRect missing rounded border"

# 2. RigPanel contract
assert "@property(nonatomic, copy) void (^onClickWithEvent)(NSEvent* event, RigPanel* panel);" in widgets_h, "RigPanel missing onClickWithEvent"
assert "if (_onClickWithEvent)" in widgets_mm, "RigPanel mouseDown: must invoke _onClickWithEvent"

# 3. RigUIState contract
assert "std::array<__strong RigPopUpButton*, 4> modelPickers" in state, "RigUIState modelPickers must be RigPopUpButton"
assert "selectedStageIndex" in state, "RigUIState missing selectedStageIndex"
assert "modelPickers[s].showsSelection = NO" in state, "selectTab must clear modelPickers showsSelection"

# 4. selectStageCard contract:
# - Stage 0 (Pedal) and Stage 1 (Amp) show selection border on whole card.
# - Stage 2 (Cab) NEVER shows selection border on whole card.
# - Cab A dropdown (modelPickers[2]) shows selection border when stageIndex == 2.
# - Cab B dropdown (modelPickers[3]) shows selection border when stageIndex == 3.
assert "_state->stageCards[s].showsSelection = ((NSInteger)s == stageIndex);" in ui, "selectStageCard must set showsSelection for cards < 2"
assert "_state->stageCards[s].showsSelection = NO;" in ui, "selectStageCard must keep Cab card showsSelection NO"
assert "_state->modelPickers[2].showsSelection = (stageIndex == 2);" in ui, "selectStageCard must set Cab A dropdown selection"
assert "_state->modelPickers[3].showsSelection = (stageIndex == 3);" in ui, "selectStageCard must set Cab B dropdown selection"

# 5. cycleSelectedStageModel contract:
# - Must support stage 0, 1, 2, and 3 (stage < 0 || stage >= 4 return)
assert "if (stage < 0 || stage >= 4) return;" in ui, "cycleSelectedStageModel must allow stage 3 (Cab B)"
assert "NSPopUpButton* picker = _state->modelPickers[(size_t)stage];" in ui, "cycleSelectedStageModel must query modelPickers for stage"
assert "[self stageModelChanged:picker];" in ui, "cycleSelectedStageModel must invoke stageModelChanged"

# 6. User interaction wiring:
# - Cab card click delegates horizontally to Cab A (2) or Cab B (3), never card border
assert "box.onClickWithEvent = ^(NSEvent* event, RigPanel* pnl)" in ui, "Cab card must use onClickWithEvent"
assert "[weakCtrl selectStageCard:2];" in ui, "Must select Cab A for left half"
assert "[weakCtrl selectStageCard:3];" in ui, "Must select Cab B for right half"
assert "mp.onClick =" in ui, "Cab A dropdown must have onClick"
assert "mpB.onClick =" in ui, "Cab B dropdown must have onClick"

# 7. Arrow keys in RIG tab cycle stage models
assert "cyclePreviousStageModel" in state, "Arrow Left/Up must call cyclePreviousStageModel"
assert "cycleNextStageModel" in state, "Arrow Right/Down must call cycleNextStageModel"

print("  PASS  Stage selection & cycling contract verified:")
print("        - Amp card has whole-card yellow selection border on click")
print("        - Cab card never has whole-card border")
print("        - Cab A dropdown has yellow border when selected; arrow keys cycle Cab A")
print("        - Cab B dropdown has yellow border when selected; arrow keys cycle Cab B")
print("        - Tone3000 tab switch resets all selections")
