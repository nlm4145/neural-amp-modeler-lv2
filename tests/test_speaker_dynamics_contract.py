#!/usr/bin/env python3
"""Guard the append-only speaker-load port and signal-flow contract."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
ttl = (ROOT / "resources/neural_amp_modeler_rig.ttl.in").read_text()
header = (ROOT / "src/nam_rig_plugin.h").read_text()
dsp = (ROOT / "src/nam_rig_plugin.cpp").read_text()
ui = (ROOT / "src/nam_rig_ui.mm").read_text()

ports = {
    int(index): symbol
    for index, symbol in re.findall(
        r'lv2:index\s+(\d+)\s*;\s*lv2:symbol\s+"([^"]+)"', ttl
    )
}
assert sorted(ports) == list(range(47)), "ports must remain contiguous through 46"
expected = ["speaker_profile", "speaker_drive", "speaker_compression",
            "speaker_thump", "speaker_resonance"]
for index, symbol in enumerate(expected, 42):
    assert ports[index] == symbol, f"port {index} must append {symbol}"
assert re.search(r'lv2:index 42.*?lv2:symbol "speaker_profile".*?lv2:default 0\.0', ttl, re.S)
assert "offsetof(Ports, speaker_resonance) == 46 * sizeof(void*)" in header
assert "SpeakerDynamics speakerDynamics;" in header
post = dsp.index("ampAdvanced.processPostAmp")
speaker = dsp.index("speakerDynamics.process")
cab = dsp.index("// A WAV cab remains at base rate")
assert post < speaker < cab
assert "SPEAKER LOAD" in ui
assert "Speaker Dynamics / Impedance" in ui
print("  PASS  speaker dynamics ports, bypass default, DSP placement, and UI are wired")
