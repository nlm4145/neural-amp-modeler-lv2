#!/usr/bin/env python3
"""Guard compressor preset/menu parity without requiring macOS AppKit."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
ui = (ROOT / "src/nam_rig_ui.mm").read_text()
apply = ui.split("- (void)applyCompressorPreset:(NSButton*)sender {", 1)[1].split(
    "- (void)sculptPageClicked:", 1)[0]
table = apply.split("const CompPreset presets[] = {", 1)[1].split("};", 1)[0]
presets = [(title.strip(), tuple(map(float, values))) for *values, title in re.findall(
    r"\{([\d.]+)f,\s*([\d.]+)f,\s*([\d.]+)f\},?\s*// ([^\n]+)", table)]
titles = re.search(r"compPresetTitles = @\[(.*?)\];", ui, re.S)
assert titles, "compressor factory menu must exist"
assert re.findall(r'@"([^"]+)"', titles.group(1)) == [name for name, _ in presets], (
    "factory menu indices must exactly match the compressor parameter table")
assert presets[:5] == [
    ("SMOOTH SUSTAIN", (40, 15, 200)),
    ("PUNCHY ATTACK", (50, 30, 80)),
    ("FAST SQUASH", (65, 2, 60)),
    ("TRANSPARENT", (25, 10, 150)),
    ("OFF / BYPASS", (0, 8, 120)),
], "existing preset values and indices must not change"
assert presets[5:] == [
    ("METAL PICK CLARITY", (22, 35, 70)),
    ("SHRED DEFINITION", (28, 25, 50)),
    ("THRASH PRECISION", (18, 20, 45)),
    ("SINGING METAL LEAD", (32, 30, 140)),
]
for title, (amount, attack, release) in presets:
    assert 0 <= amount <= 100 and 1 <= attack <= 100 and 10 <= release <= 1000, title
for title, (amount, attack, _) in presets[5:]:
    assert amount < 40 and attack >= 20, f"{title} should avoid heavy transient squash"
assert "presetCount = sizeof(presets) / sizeof(presets[0])" in apply
assert "sender.tag >= 0 && sender.tag < presetCount" in apply
assert "enabled = p.amount > 0.0f ? 1.0f : 0.0f" in apply
for operation in ("sendControl", "updateControl"):
    assert f"{operation}(NAMRig::kCompressorEnabledPort, enabled)" in apply
assert "[self markPresetModified];" in apply
assert 'addSlotPresetDropdown(chips, state, @"compressor"' in ui
assert 'spec[@"ports"] = [(ports ?: @[]) arrayByAddingObject:enabledPort];' in ui
print("  PASS  compressor presets: menu parity, legacy values, high-gain settings and bypass")
