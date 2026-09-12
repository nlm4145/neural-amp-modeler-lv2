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
assert sorted(ports) == list(range(59)), "ports must remain contiguous through 58"
expected = ["speaker_profile", "speaker_drive", "speaker_compression",
            "speaker_thump", "speaker_resonance"]
for index, symbol in enumerate(expected, 42):
    assert ports[index] == symbol, f"port {index} must append {symbol}"
assert re.search(r'lv2:index 42.*?lv2:symbol "speaker_profile".*?lv2:default 0\.0', ttl, re.S)
assert "offsetof(Ports, speaker_resonance) == 46 * sizeof(void*)" in header
assert "SpeakerDynamics speakerDynamics;" in header

# The load sits after the power stage and the iron, and before any cabinet.
post = dsp.index("ampAdvanced.processPostAmp")
iron = dsp.index("outputTransformer.process(samples, count, domainRate")
speaker = dsp.index("speakerDynamics.process")
cab = dsp.index("void Plugin::processPostChain")
assert post < iron < speaker < cab, "speaker load must follow the power stage and iron, before the cab"

# A tube output stage follows the impedance curve in proportion to its output
# impedance, so Negative Feedback (damping) must scale the curve.
assert re.search(r"speakerDynamics\.process\((?:[^;]*?)\*ports\.negative_feedback \* 0\.01f\)", dsp, re.S), (
    "Negative Feedback must drive the speaker block's damping input"
)
speaker_src = (ROOT / "src/speaker_dynamics.h").read_text()
assert "smoothedDamping_" in speaker_src
assert "1.0 - 0.6 * smoothedDamping_" in speaker_src, "damping must flatten the impedance curve"
assert "inductance_" in speaker_src, "the curve needs the rising voice-coil inductance, not just the low resonance"
# Cone/suspension nonlinearity acts on excursion, so Drive is low-band only.
assert "driveLow_" in speaker_src and "sigmoid(driveLow_ * gain)" in speaker_src, (
    "Speaker Drive must saturate the excursion (low) band, not the full band"
)
assert "SPEAKER LOAD" in ui
assert "Speaker Dynamics / Impedance" in ui
print("  PASS  speaker load ports, bypass default, damping coupling, DSP placement, and UI are wired")
