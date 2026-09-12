#!/usr/bin/env python3
"""Guard the rig's append-only stereo output and cabinet width contract.

Width is no longer a right-channel Haas delay (that comb-filtered in mono and
pulled the image right). It is now the side gain of each stereo cabinet pair
plus an equal-power pan spread between Cab A and Cab B, so 0% still collapses
to exact dual mono and 100% stays mono-safe.
"""
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
assert ports[32] == "stereo_width", "width control must be append-only at port 32"
assert ports[33] == "room", "room control must be append-only at port 33"
assert "float* audio_out_r;" in header
assert "offsetof(Ports, audio_out_r) == 31 * sizeof(void*)" in header

# Both channels are written from internal buffers, so a host may alias the two
# output ports (Element's dual-mono default does exactly that).
assert "std::memcpy(ports.audio_out + off, L, n * sizeof(float));" in dsp
assert "std::memcpy(ports.audio_out_r + off, R, n * sizeof(float));" in dsp
assert "std::vector<float> postL, postR" in header, "post chain needs its own stereo scratch"

# Width: mid/side on each cab pair, then an equal-power spread between cabs.
assert "const float sideA = 0.5f * (L[i] - R[i]) * w;" in dsp, (
    "Width must scale the side component, not delay a channel"
)
assert "const float theta = static_cast<float>(kPi) * 0.25f * (1.0f - w);" in dsp, (
    "Cab A/Cab B spread must be an equal-power pan"
)
assert "smoothedWidth += (widthTarget - smoothedWidth) * glide10;" in dsp, (
    "Width must glide, not step per block"
)
assert not re.search(r"stereoSpace|StereoSpace", dsp + header), (
    "the Haas-delay StereoSpace block is replaced by space_fx.h"
)
assert not (ROOT / "src/stereo_space.h").exists(), "stereo_space.h must be gone"

# Room is now the plate reverb's diffused, damped early-reflection cluster.
assert re.search(r"reverbFx\.process\(L, R, n, \*ports\.room,", dsp), (
    "Room must drive the reverb's early reflections"
)
print("  PASS  rig exposes append-only stereo output with mono-safe cabinet width")
