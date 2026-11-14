#!/usr/bin/env python3
"""Verify src/align_delay_table.h stays synced with its generator and obeys DSP bounds."""
from __future__ import annotations

import ast
from pathlib import Path
import re
import subprocess
import sys

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
HEADER = ROOT / "src/align_delay_table.h"
GENERATOR = ROOT / "scripts/generate_align_delay_table.py"


def _parse_c_table(text: str, symbol: str, rows: int, cols: int) -> np.ndarray:
    pattern = rf"{re.escape(symbol)}\[[^\]]+\]\[[^\]]+\]\s*=\s*\{{(.*?)\}};"
    match = re.search(pattern, text, re.S)
    assert match, f"missing array {symbol} in {HEADER.name}"
    py_literal = "[" + re.sub(r"([0-9eE.+\-]+)f\b", r"\1", match.group(1)).replace("{", "[").replace("}", "]") + "]"
    arr = np.array(ast.literal_eval(py_literal), dtype=np.float64)
    assert arr.shape == (rows, cols), f"{symbol} expected {(rows, cols)}, got {arr.shape}"
    return arr


# 1. Generated header matches generator output and compiles without Python 3.10+ pitfalls.
gen_src = GENERATOR.read_text()
assert "from __future__ import annotations" in gen_src, "generator must remain Python 3.9+ safe"
subprocess.run([sys.executable, str(GENERATOR), "--check"], check=True)
assert "align_delay_table.h" in (ROOT / "src/CMakeLists.txt").read_text()

header_text = HEADER.read_text()
causal = _parse_c_table(header_text, "kAlignCausalWeights", 15 * 64 + 1, 32)
sinc = _parse_c_table(header_text, "kAlignSincWeights", 257, 32)

# 2. Check DC unity, integer unit-impulse exactness, DC group delay, peak cap, passband & slew.
ws = np.linspace(0.0, np.pi, 2048)
u = ws / np.pi
basis = np.exp(-1j * np.arange(32)[None, :] * ws[:, None])

causal_ds = np.arange(causal.shape[0]) / 64.0
for tap in range(16):
    expected = np.zeros(32, dtype=np.float64)
    expected[tap] = 1.0
    assert np.array_equal(causal[tap * 64], expected), f"integer delay {tap} must be unit impulse"

assert np.max(np.abs(np.sum(causal, axis=1) - 1.0)) < 1.0e-5, "causal DC sum must equal 1"
causal_gd0_err = np.abs(causal @ np.arange(32) - causal_ds)
assert np.max(causal_gd0_err) < 1.0e-4, f"causal DC group-delay error too large: {np.max(causal_gd0_err)}"

causal_resp = basis @ causal.T
causal_mag = np.abs(causal_resp)
max_causal_mag = float(np.max(causal_mag))
assert max_causal_mag <= 1.025, f"causal peak magnitude exceeded +0.22 dB cap: {max_causal_mag:.6f}"

causal_err = np.abs(causal_resp - np.exp(-1j * ws[:, None] * causal_ds[None, :]))
worst_pb45_db = float(20.0 * np.log10(np.max(causal_err[u <= 0.45])))
assert worst_pb45_db < -23.5, f"causal passband u<=0.45 error degraded: {worst_pb45_db:.2f} dB"

# Low-frequency phase delay (80 Hz @ 48 kHz) must stay strictly positive for d > 0 and accurate.
w80 = 2.0 * np.pi * 80.0 / 48000.0
r80 = np.exp(-1j * np.arange(32) * w80) @ causal[1:].T
pd80 = -np.angle(r80) / w80
assert np.all(pd80 > 0.0) and np.max(np.abs(pd80 - causal_ds[1:])) < 0.02, (
    f"causal 80 Hz phase delay inaccurate: max err {np.max(np.abs(pd80 - causal_ds[1:])):.5f}"
)

# Sweep slew smoothness at 1 kHz and 4 kHz @ 48 kHz across all 961 causal delays.
for hz in (1000.0, 4000.0):
    w0 = 2.0 * np.pi * hz / 48000.0
    r_hz = np.exp(-1j * np.arange(32) * w0) @ causal.T
    slew_ratio = float(np.max(np.abs(np.diff(r_hz)) * 64.0) / w0)
    assert slew_ratio < 1.45, f"causal {hz:.0f} Hz sweep slew too uneven: {slew_ratio:.2f}x"

# 3. Verify Kaiser-32 symmetric sinc table invariants as well.
exp0 = np.zeros(32, dtype=np.float64)
exp0[15] = 1.0
exp1 = np.zeros(32, dtype=np.float64)
exp1[16] = 1.0
assert np.array_equal(sinc[0], exp0) and np.array_equal(sinc[-1], exp1), "sinc endpoints must be exact"
assert np.max(np.abs(np.sum(sinc, axis=1) - 1.0)) < 1.0e-5, "sinc DC sum must equal 1"

sinc_fracs = np.arange(sinc.shape[0]) / 256.0
sinc_taps = np.arange(-15, 17, dtype=np.float64)
assert np.max(np.abs(sinc @ sinc_taps - sinc_fracs)) < 1.0e-3, "sinc DC group-delay error too large"

sinc_basis = np.exp(-1j * sinc_taps[None, :] * ws[:, None])
sinc_resp = sinc_basis @ sinc.T
assert float(np.max(np.abs(sinc_resp))) <= 1.001, "sinc peak magnitude exceeded +0.01 dB"
sinc_err = np.abs(sinc_resp - np.exp(-1j * ws[:, None] * sinc_fracs[None, :]))
sinc_pb50_db = float(20.0 * np.log10(np.max(sinc_err[u <= 0.50])))
assert sinc_pb50_db < -70.0, f"sinc passband u<=0.50 error degraded: {sinc_pb50_db:.2f} dB"

print(
    f"  PASS  align_delay_table synced; causal maxMag={20.0 * np.log10(max_causal_mag):+.3f} dB, "
    f"pb45={worst_pb45_db:.1f} dB, max gd0 err={np.max(causal_gd0_err):.2e}, "
    f"sinc pb50={sinc_pb50_db:.1f} dB"
)
