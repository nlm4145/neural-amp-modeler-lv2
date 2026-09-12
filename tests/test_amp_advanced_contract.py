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

# Physical amp order inside the oversampled domain: model, then its own DC
# blocker, then the power stage, then the output transformer, then the speaker
# load. Presence/Depth are power-stage feedback, so they must precede the iron.
# Scope the search to the stage lambda -- runModel is a separate function, so
# whole-file offsets are not execution order.
apply_model = dsp[dsp.index("auto applyModel = [&]"):
                  dsp.index("// Process one or more consecutive models inside ONE TRUE domain")]
assert (apply_model.index("runModel(")
        < apply_model.index("ampAdvanced.processPostAmp")
        < apply_model.index("outputTransformer.process")
        < apply_model.index("speakerDynamics.process")), (
    "amp stage must run model -> power stage -> iron -> speaker load"
)
# Every model stage removes its own DC before any envelope, bias point, flux
# integrator or excursion detector downstream can be pushed off zero by it.
run_model = dsp[dsp.index("void Plugin::runModel("):
                dsp.index("// Everything after the serial NAM chain")]
assert run_model.index("model->Process(") < run_model.index("stageDc[stage].process"), (
    "each model stage must DC-block its own output in-domain"
)

# The power stage is a negative-feedback loop, not a series of shelves: the
# feedback filters must be driven from the stage OUTPUT each sample.
amp = (ROOT / "src/amp_advanced.h").read_text()
assert "presence_.advance(depth_.advance(y));" in amp, "Presence/Depth must filter the loop output"
assert "feedbackShelfDb" in amp, "closed-loop shelf gain must be derived from the loop gain"

# These are the established post-chain controls. Their ports, frequencies and
# ordering must remain untouched by the advanced block. Gains are now glided
# per chunk (smoothedBass/Mid/Treble) instead of read raw, and the right
# channel mirrors the left channel's coefficients.
assert "Biquad bassEq, midEq, trebleEq;" in header
assert "Biquad bassEqR, midEqR, trebleEqR;" in header
assert "setLowShelf(bassEq, smoothedBass, 150.0f, sampleRate);" in dsp
assert "setPeaking(midEq, smoothedMid, 700.0f, sampleRate);" in dsp
assert "setHighShelf(trebleEq, smoothedTreble, 3000.0f, sampleRate);" in dsp
for name in ("smoothedBass", "smoothedMid", "smoothedTreble"):
    assert re.search(rf"glideValue\({name}, \*ports\.", dsp), f"{name} must glide from its port"
assert re.search(
    r"if \(bassOn\) \{ l = bassEq\.process\(l\); r = bassEqR\.process\(r\); \}\s*"
    r"if \(midOn\) \{ l = midEq\.process\(l\); r = midEqR\.process\(r\); \}\s*"
    r"if \(trebleOn\) \{ l = trebleEq\.process\(l\); r = trebleEqR\.process\(r\); \}", dsp
), "post EQ must stay in bass -> mid -> treble order on both channels"
for port in range(34, 42):
    assert re.search(rf"\b{port}\b", knobs), f"advanced control port {port} missing from UI knob map"
print("  PASS  advanced amp controls are append-only, feedback-coupled, and legacy B/M/T stay intact")
