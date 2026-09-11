#!/usr/bin/env python3
"""Guard the in-UI signal-flow diagram and its EQ distinctions."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ui = (ROOT / "src/nam_rig_ui.mm").read_text()
state = (ROOT / "src/rig_ui_state.h").read_text()

assert "signalFlowPopover" in state
assert '@"SIGNAL FLOW"' in ui
assert "showSignalFlow:" in ui
for label in (
    "Bright + Input EQ",
    "Amp NAM",
    "Presence / Depth / Sag / Bias / Feedback / Master",
    "Cab NAM / WAV IR",
    "Bass / Mid / Treble",
):
    assert label in ui, f"diagram missing {label}"
assert "Bass / Mid / Treble stay the original post-cab EQ" in ui
print("  PASS  UI exposes the EQ signal-flow diagram")
