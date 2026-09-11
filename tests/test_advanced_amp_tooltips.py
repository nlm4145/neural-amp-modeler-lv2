#!/usr/bin/env python3
"""Guard clear advanced-amp help text and shorter tooltip delay."""
from pathlib import Path

ui = (Path(__file__).resolve().parents[1] / "src/nam_rig_ui.mm").read_text()
for text in (
    "Removes deep bass before the NAM amp model",
    "Adds a simulated power-stage drive after the NAM amp model",
    "Works independently of Input EQ and Master",
    "NSInitialToolTipDelay",
):
    assert text in ui, f"missing advanced help text: {text}"
assert '@150' in ui, "tooltip delay should be about 150 ms"
print("  PASS  advanced controls have clear help and fast tooltips")
