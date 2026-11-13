#!/usr/bin/env python3
"""Guard the rig's append-only stereo output and cabinet width contract.

Width is no longer a right-channel Haas delay (that comb-filtered in mono and
pulled the image right). It is the equal-power pan spread between Cab A and
Cab B. Each cabinet keeps its own stereo image at every setting; 0% sums both
cabinets to the same dual-mono blend Spatial OFF uses and 100% stays mono-safe.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
ttl = (ROOT / "resources/neural_amp_modeler_rig.ttl.in").read_text()
header = (ROOT / "src/nam_rig_plugin.h").read_text()
dsp = (ROOT / "src/nam_rig_plugin.cpp").read_text()
cache = (ROOT / "src/rig_dsp_cache.h").read_text()
spatial_stereo = (ROOT / "src/spatial_stereo.h").read_text()

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
assert ports[234] == "spatial_center_blend", "centered blend toggle must append at port 234"
assert "float* audio_out_r;" in header
assert "offsetof(Ports, audio_out_r) == 31 * sizeof(void*)" in header
assert "offsetof(Ports, spatial_center_blend) == kSpatialCenterBlendPort * sizeof(void*)" in header

# Both channels are written from internal buffers, so a host may alias the two
# output ports (Element's dual-mono default does exactly that).
assert "std::memcpy(ports.audio_out + off, L, n * sizeof(float));" in dsp
assert "std::memcpy(ports.audio_out_r + off, R, n * sizeof(float));" in dsp
assert "std::vector<float> postL, postR" in header, "post chain needs its own stereo scratch"

# Width:
# 1) Single stereo IR: 0% is native passthrough, >0% applies mono-sum invariant M/S width.
# 2) Dual cabs: default A/B Split uses equal-power pan; optional Center Blend uses
#    90-degree phase-quadrature Dome all-pass stereoization preserving A+B tonal balance.
assert "applySingleStereoWidthSample(L[i], R[i], smoothedWidth)" in dsp
assert "applySingleStereoWidthSample" in spatial_stereo and "const float m = 0.5f * (l + r);" in spatial_stereo
assert "* 0.25f * (1.0f - value);" in cache and (
    "near = std::cos(theta);" in cache and "far = std::sin(theta);" in cache
) and "widthGainCache.configure(smoothedWidth, blockRounding);" in dsp, (
    "Cab A/Cab B spread must be an equal-power pan"
)
assert "const float outL = L[i] * gainNear + BL[i] * gainFar;" in dsp and (
    "const float outR = R[i] * gainFar + BR[i] * gainNear;" in dsp
), "the pan must feed each cabinet's own left/right channels into the spread"
assert "centerStereoizer.processSample(mixL, mixR, smoothedWidth, L[i], R[i]);" in dsp
assert "class DomeHilbertStereoizer" in spatial_stereo
assert "smoothedWidth += (widthTarget - smoothedWidth) * glide10;" in dsp, (
    "Width must glide, not step per block"
)
assert not re.search(r"stereoSpace|StereoSpace", dsp + header), (
    "the Haas-delay StereoSpace block is replaced by space_fx.h"
)
assert not (ROOT / "src/stereo_space.h").exists(), "stereo_space.h must be gone"

# Room is now the plate reverb's diffused, damped early-reflection cluster.
space = (ROOT / "src/space_fx.h").read_text()
assert re.search(r"reverbFx\.process\(L, R, n,\s*\*ports\.room,[^;]*spatialOn, reverbOn\);", dsp, re.S)
assert "const bool spatialOn = rackOn(Rack::Spatial);" in dsp
assert "roomEnabled ? clamp01(roomPercent * 0.01f) : 0.0f" in space, (
    "Room must drive early reflections only while the Spatial rack is enabled"
)
print("  PASS  rig exposes append-only stereo output with mono-safe cabinet width")
