#!/usr/bin/env python3
"""Guard append-only advanced amp controls and the established post EQ."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
ttl = (ROOT / "resources/neural_amp_modeler_rig.ttl.in").read_text()
header = (ROOT / "src/nam_rig_plugin.h").read_text()
dsp = (ROOT / "src/nam_rig_plugin.cpp").read_text()
knobs = (ROOT / "src/rig_knobs.cpp").read_text()

ports = {
    int(index): symbol
    for index, symbol in re.findall(
        r'lv2:index\s+(\d+)\s*;\s*lv2:symbol\s+"([^"]+)"', ttl
    )
}
expected = [
    "presence", "depth", "sag", "bias", "negative_feedback",
    "bright", "input_eq", "master",
]
for index, symbol in enumerate(expected, 34):
    assert ports[index] == symbol, f"port {index} must append {symbol}"
assert "offsetof(Ports, master) == 41 * sizeof(void*)" in header
assert "ampAdvanced.processPreAmp" in dsp
assert "ampAdvanced.processPostAmp" in dsp

# These are the established post-chain controls. Their ports, frequencies,
# ordering, and dedicated state must remain untouched by the advanced block.
assert "Biquad bassEq, midEq, trebleEq;" in header
assert "setLowShelf(bassEq, *ports.bass, 150.0f, sampleRate);" in dsp
assert "setPeaking(midEq, *ports.mid, 700.0f, sampleRate);" in dsp
assert "setHighShelf(trebleEq, *ports.treble, 3000.0f, sampleRate);" in dsp
assert re.search(r"if \(bassOn\) x = bassEq\.process\(x\);\s*if \(midOn\) x = midEq\.process\(x\);\s*if \(trebleOn\) x = trebleEq\.process\(x\);", dsp)
for port in range(34, 42):
    assert re.search(rf"\b{port}\b", knobs), f"advanced control port {port} missing from UI knob map"
print("  PASS  advanced amp controls are append-only and legacy B/M/T stay intact")
