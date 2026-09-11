#!/usr/bin/env python3
"""Guard the rig's append-only stereo-output foundation."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
ttl = (ROOT / "resources/neural_amp_modeler_rig.ttl.in").read_text()
header = (ROOT / "src/nam_rig_plugin.h").read_text()
dsp = (ROOT / "src/nam_rig_plugin.cpp").read_text()

ports = {
    int(index): symbol
    for index, symbol in re.findall(
        r"lv2:index\s+(\d+)\s*;\s*lv2:symbol\s+\"([^\"]+)\"", ttl
    )
}

assert ports[2] == "input", "existing mono guitar input must stay at port 2"
assert ports[3] == "output", "existing left output must stay at port 3"
assert ports[31] == "output_r", "right output must be appended at port 31"
assert "float* audio_out_r;" in header
assert "offsetof(Ports, audio_out_r) == 31 * sizeof(void*)" in header
assert "ports.audio_out_r[i] = ports.audio_out[i];" in dsp
print("  PASS  rig exposes append-only stereo outputs with a dual-mono foundation")
