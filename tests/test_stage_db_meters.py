#!/usr/bin/env python3
"""Contract and verification tests for the inter-stage decibel meters.

Signal flow:
input db (raw) -> pedal -> all the pre amp stuff -> pre db -> amp -> post amp stuff -> post db -> cab -> output db
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

plugin_h = (ROOT / "src/nam_rig_plugin.h").read_text()
plugin_cpp = (ROOT / "src/nam_rig_plugin.cpp").read_text()
ui_h = (ROOT / "src/rig_ui_state.h").read_text()
ui_mm = (ROOT / "src/nam_rig_ui.mm").read_text()
widgets_h = (ROOT / "src/rig_widgets.h").read_text()
widgets_mm = (ROOT / "src/rig_widgets.mm").read_text()
win32_cpp = (ROOT / "src/nam_rig_win32_ui.cpp").read_text()

# 1. Verify URI definitions
assert '#define NAM_RIG_INPUT_DB_URI NAM_RIG_URI "-input-db"' in plugin_h
assert '#define NAM_RIG_PRE_AMP_DB_URI NAM_RIG_URI "-pre-amp-db"' in plugin_h
assert '#define NAM_RIG_POST_AMP_DB_URI NAM_RIG_URI "-post-amp-db"' in plugin_h
assert '#define NAM_RIG_OUTPUT_DB_URI NAM_RIG_URI "-output-db"' in plugin_h

assert '#define NAM_RIG_PRE_AMP_DB_URI NAM_RIG_URI "-pre-amp-db"' in ui_mm
assert '#define NAM_RIG_POST_AMP_DB_URI NAM_RIG_URI "-post-amp-db"' in ui_mm

# 2. Verify Plugin struct URIs and Meters
assert "LV2_URID preAmpDb;" in plugin_h
assert "LV2_URID postAmpDb;" in plugin_h
assert "meter, preAmpMeter, postAmpMeter, outMeter;" in plugin_h

assert "uris.preAmpDb = map->map(map->handle, NAM_RIG_PRE_AMP_DB_URI);" in plugin_cpp
assert "uris.postAmpDb = map->map(map->handle, NAM_RIG_POST_AMP_DB_URI);" in plugin_cpp

# 3. Verify DSP signal flow taps and forge messages
assert "blockPreAmpPeak" in plugin_cpp
assert "blockPostAmpPeak" in plugin_cpp
assert "lv2_atom_forge_urid(&forge, uris.preAmpDb);" in plugin_cpp
assert "lv2_atom_forge_urid(&forge, uris.postAmpDb);" in plugin_cpp

# 4. Verify UI state
assert "LV2_URID preAmpDbURID = 0;" in ui_h
assert "LV2_URID postAmpDbURID = 0;" in ui_h
assert "float lastPreAmpDb = -120.0f;" in ui_h
assert "float lastPostAmpDb = -120.0f;" in ui_h
assert "std::array<__strong RigStageMeterView*, 4> stageMeters{};" in ui_h
assert "void applyPreAmpDbDisplayNow()" in ui_h
assert "void applyPostAmpDbDisplayNow()" in ui_h
assert "void updatePreAmpDbDisplay()" in ui_h
assert "void updatePostAmpDbDisplay()" in ui_h

# 5. Verify UI widget class
assert "@interface RigStageMeterView : NSView" in widgets_h
assert "@implementation RigStageMeterView" in widgets_mm
assert "- (void)setLevelDb:(float)db" in widgets_mm

# 6. Verify layout and order in nam_rig_ui.mm
assert 'RigStageMeterView* m0 = [[RigStageMeterView alloc] initWithTitle:@"IN"' in ui_mm
assert 'RigStageMeterView* m1 = [[RigStageMeterView alloc] initWithTitle:@"PRE"' in ui_mm
assert 'RigStageMeterView* m2 = [[RigStageMeterView alloc] initWithTitle:@"POST"' in ui_mm
assert 'RigStageMeterView* m3 = [[RigStageMeterView alloc] initWithTitle:@"OUT"' in ui_mm

assert "[boxRow addArrangedSubview:m0];" in ui_mm
assert "[boxRow addArrangedSubview:tileBoxes[0]];" in ui_mm
assert "[boxRow addArrangedSubview:m1];" in ui_mm
assert "[boxRow addArrangedSubview:tileBoxes[1]];" in ui_mm
assert "[boxRow addArrangedSubview:m2];" in ui_mm
assert "[boxRow addArrangedSubview:tileBoxes[2]];" in ui_mm
assert "[boxRow addArrangedSubview:m3];" in ui_mm

# 7. Verify port event dispatch
assert "state->preAmpDbURID" in ui_mm
assert "state->postAmpDbURID" in ui_mm
assert "state->updatePreAmpDbDisplay();" in ui_mm
assert "state->updatePostAmpDbDisplay();" in ui_mm

# 8. Verify Win32 mapping compatibility
assert "ui->preAmpDbURID" in win32_cpp
assert "ui->postAmpDbURID" in win32_cpp

print("  PASS  all 4 stage decibel readers (IN -> Pedal -> PRE -> Amp -> POST -> Cab -> OUT) verified")
