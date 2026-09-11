#!/usr/bin/env python3
"""Regression guard: the UI must retain all four IR modes."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ui = (ROOT / "src/nam_rig_ui.mm").read_text()
state = (ROOT / "src/rig_ui_state.h").read_text()

assert '[@"Preserve", @"Peak", @"Loudness", @"Original"]' in ui
assert "std::min(3, (int)(value + 0.5f))" in state, (
    "host updates must allow index 3 (Original) instead of clamping it to Loudness"
)
print("  PASS  UI retains Original IR mode on host echo")
