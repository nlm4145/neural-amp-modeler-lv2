#!/usr/bin/env python3
"""Guard A2Fast against copying its full maximum buffer every audio block.

The model is deliberately sized for the worst reachable True-8x block, but
normal callbacks are often much smaller. Ring maintenance must scale with the
current block/read extent, not the maximum allocation.

KNOWN FAILING since the `Update NeuralAudio` submodule bump (ea6ed50): upstream
replaced the local patch with an unconditional tail mirror of `mbs` columns per
layer per block (`_ring_write`, NAM_A2_RING_MODE == 1). Reads never span more
than `num_frames` columns past the wrap, so the mirror only needs `num_frames`
columns -- at the rig's 8x sizing that is an 8x redundant copy per layer per
block. This assertion is NOT stale; it is detecting a real lost optimization in
the submodule. Fix it in `deps/NeuralAudio/.../wavenet/a2_fast.cpp`, not here.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
src = (ROOT / "deps/NeuralAudio/deps/NeuralAmpModelerCore/NAM/wavenet/a2_fast.cpp").read_text()

assert "int mirror_needed =" in src, "layer rings must calculate the current block's required mirror extent"
assert "static_cast<size_t>(mirror_needed) * Channels * sizeof(float)" in src
assert "static_cast<size_t>(mbs) * Channels * sizeof(float)" not in src, (
    "A2Fast still copies maxBufferSize for every layer/head on every callback"
)
print("  PASS  A2Fast ring-copy work scales with the current block")
