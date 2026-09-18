#!/usr/bin/env python3
"""Guard the rig's fresh-instance maximum-quality policy.

Best-sound builds must start both nonlinear stages in genuine True 8x,
keep A2/Slimmable models on their full tier, and expose the same selection
in both master and per-stage UI controls.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
ttl = (ROOT / "resources/neural_amp_modeler_rig.ttl.in").read_text()
header = (ROOT / "src/nam_rig_plugin.h").read_text()
ui = (ROOT / "src/nam_rig_ui.mm").read_text()
dsp = (ROOT / "src/nam_rig_plugin.cpp").read_text()


def port_default(index: int) -> float:
    match = re.search(
        rf"lv2:index\s+{index}\s*;(?:(?!lv2:index).)*?lv2:default\s+([-0-9.]+)",
        ttl,
        re.S,
    )
    assert match, f"missing default for port {index}"
    return float(match.group(1))


assert port_default(20) == 6.0, "fresh pedal stage must default to True 8x"
assert port_default(21) == 6.0, "fresh amp stage must default to True 8x"
assert "osApplied = {kOsTrue8, kOsTrue8, kOsTrue8, kOsLegacy2}" in header, (
    "pedal/amp/cab must start in True 8x; Cab B is parallel and base-rate"
)
assert "osRequested = {kOsTrue8, kOsTrue8}" in header
assert 'addItemsWithTitles:@[@"None", @"True 2x", @"True 4x", @"True 8x"]' in ui
assert "osPopup" not in ui
assert "[so selectItemAtIndex:3]" in ui
assert "loader.SetDefaultQualityScaleFactor(1.0f)" in dsp
assert "response.model->SetQualityScaleFactor(1.0f)" in dsp
print("  PASS  fresh rig defaults to full-tier True 8x on every nonlinear stage")
