#!/usr/bin/env python3
"""Guard A2Fast against copying its full maximum buffer every audio block.

The model is deliberately sized for the worst reachable True-8x block, but
normal callbacks are often much smaller. Ring maintenance must scale with the
current block/read extent, not the maximum allocation.
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
