#!/usr/bin/env python3
"""Generate precomputed causal LS-FIR + Kaiser-32 fractional-delay lookup tables."""
from __future__ import annotations

import argparse
from pathlib import Path
from typing import Optional
import numpy as np

ROOT = Path(__file__).resolve().parents[1]

TAPS = 32
CAUSAL_MAX_DELAY = 15
CAUSAL_STEPS = 64
CAUSAL_ROWS = CAUSAL_MAX_DELAY * CAUSAL_STEPS + 1
SINC_FIRST_TAP = -15
SINC_STEPS = 256
SINC_ROWS = SINC_STEPS + 1
KAISER_BETA = 7.0
CAUSAL_PEAK_CAP = 1.022


def _quantize_row(row: np.ndarray, integer_tap: Optional[int] = None) -> np.ndarray:
    """Round coefficients to float32 while preserving exact unit impulses and unity DC sum."""
    if integer_tap is not None:
        out = np.zeros(TAPS, dtype=np.float32)
        out[integer_tap] = np.float32(1.0)
        return out
    q = row.astype(np.float32)
    dominant = int(np.argmax(np.abs(q)))
    other_sum = np.sum(q.astype(np.float64)) - float(q[dominant])
    q[dominant] = np.float32(1.0 - other_sum)
    return q


def _causal_weights() -> np.ndarray:
    """Design peak-capped, group-delay-accurate causal LS-FIR32 kernels for [0, 15]."""
    ws = np.linspace(0.0, np.pi, 320)
    u = ws / np.pi
    u_pb = 0.52
    u_sb = 0.86
    sb_weight = 0.012
    # Emphasize low frequencies smoothly so phase delay at guitar fundamentals
    # stays close to target without starving upper presence / cab air bands.
    base_weight = np.where(
        u <= u_pb,
        2.0 * (1.0 + 0.08 / (u * u + 0.025 * 0.025)),
        np.where(
            u <= u_sb,
            sb_weight
            + (2.0 - sb_weight) * 0.5 * (1.0 + np.cos(np.pi * (u - u_pb) / (u_sb - u_pb))),
            sb_weight,
        ),
    )
    basis = np.exp(-1j * np.arange(TAPS)[None, :] * ws[:, None])
    b_re = np.real(basis)
    b_im = np.imag(basis)
    b_sym = b_re.T @ b_re + b_im.T @ b_im
    # Constrain both unity DC gain (sum h = 1) and exact DC group delay (sum k*h = d)
    # so zero-lookahead fractional delays < 1 sample cannot go negative at bass frequencies.
    constraints = np.column_stack([np.ones(TAPS), np.arange(TAPS, dtype=np.float64)])
    zero_block = np.zeros((2, 2))
    rows = np.zeros((CAUSAL_ROWS, TAPS), dtype=np.float32)
    rho = 10.0

    for step in range(CAUSAL_ROWS):
        if step % CAUSAL_STEPS == 0:
            rows[step] = _quantize_row(rows[step], step // CAUSAL_STEPS)
            continue

        delay = step / CAUSAL_STEPS
        d_re = np.cos(delay * ws)
        d_im = -np.sin(delay * ws)
        dist = np.abs(np.arange(TAPS) - delay) / 16.0
        edge_extra = np.maximum(0.0, dist - 0.85)
        reg = np.diag(1.0e-7 + 0.004 * (dist ** 4) + 0.4 * (edge_extra ** 2))
        rhs_c = np.array([1.0, delay], dtype=np.float64)

        a_wls = (b_re.T * base_weight[None, :]) @ b_re + (b_im.T * base_weight[None, :]) @ b_im + reg
        b_wls = b_re.T @ (base_weight * d_re) + b_im.T @ (base_weight * d_im)
        h = np.linalg.solve(
            np.block([[a_wls, constraints], [constraints.T, zero_block]]),
            np.concatenate([b_wls, rhs_c]),
        )[:TAPS]

        bh_re = b_re @ h
        bh_im = b_im @ h
        if np.max(np.hypot(bh_re, bh_im)) > CAUSAL_PEAK_CAP:
            # Solve the convex peak-magnitude-constrained problem via over-relaxed ADMM
            # on z = B*h with per-bin Euclidean ball projection |z_k| <= CAUSAL_PEAK_CAP.
            a_admm = rho * b_sym + reg
            kkt_inv = np.linalg.inv(
                np.block([[a_admm, constraints], [constraints.T, zero_block]])
            )
            z_re = bh_re.copy()
            z_im = bh_im.copy()
            mag0 = np.hypot(z_re, z_im)
            scale0 = np.where(mag0 > CAUSAL_PEAK_CAP, CAUSAL_PEAK_CAP / np.maximum(mag0, 1.0e-12), 1.0)
            z_re *= scale0
            z_im *= scale0
            y_re = np.zeros_like(ws)
            y_im = np.zeros_like(ws)
            for it in range(150):
                b_rhs = rho * (b_re.T @ (z_re - y_re) + b_im.T @ (z_im - y_im))
                h = (kkt_inv @ np.concatenate([b_rhs, rhs_c]))[:TAPS]
                bh_re = b_re @ h
                bh_im = b_im @ h
                if it >= 30 and (it % 10 == 0):
                    if (
                        np.max(np.hypot(bh_re, bh_im) - CAUSAL_PEAK_CAP) < 5.0e-5
                        and np.max(np.hypot(bh_re - z_re, bh_im - z_im)) < 1.0e-4
                    ):
                        break
                bh_re_hat = 1.6 * bh_re - 0.6 * z_re
                bh_im_hat = 1.6 * bh_im - 0.6 * z_im
                t_re = (base_weight * d_re + rho * (bh_re_hat + y_re)) / (base_weight + rho)
                t_im = (base_weight * d_im + rho * (bh_im_hat + y_im)) / (base_weight + rho)
                t_mag = np.hypot(t_re, t_im)
                scale = np.where(t_mag > CAUSAL_PEAK_CAP, CAUSAL_PEAK_CAP / np.maximum(t_mag, 1.0e-12), 1.0)
                z_re = t_re * scale
                z_im = t_im * scale
                y_re += bh_re_hat - z_re
                y_im += bh_im_hat - z_im

        rows[step] = _quantize_row(h)
    return rows


def _kaiser_sinc_weights() -> np.ndarray:
    """Build 32-tap Kaiser-windowed sinc kernels for fractional delays in [0, 1]."""
    rows = np.zeros((SINC_ROWS, TAPS), dtype=np.float32)
    i0_beta = float(np.i0(KAISER_BETA))
    half = 0.5 * TAPS
    taps = np.arange(SINC_FIRST_TAP, SINC_FIRST_TAP + TAPS, dtype=np.float64)

    for step in range(SINC_ROWS):
        if step == 0:
            rows[step] = _quantize_row(rows[step], -SINC_FIRST_TAP)
            continue
        if step == SINC_STEPS:
            rows[step] = _quantize_row(rows[step], -SINC_FIRST_TAP + 1)
            continue

        frac = step / SINC_STEPS
        x = taps - frac
        sinc = np.where(np.abs(x) < 1.0e-9, 1.0, np.sin(np.pi * x) / (np.pi * x))
        r = x / half
        window = np.where(
            np.abs(r) <= 1.0,
            np.i0(KAISER_BETA * np.sqrt(np.maximum(0.0, 1.0 - r * r))) / i0_beta,
            0.0,
        )
        kernel = sinc * window
        kernel /= np.sum(kernel)
        rows[step] = _quantize_row(kernel)
    return rows


def _fmt(v: float) -> str:
    if v == 0.0:
        return "0.0f"
    s = f"{float(v):.9g}"
    if "." not in s and "e" not in s and "E" not in s:
        s += ".0"
    return s + "f"


def _format_table(rows: np.ndarray) -> str:
    lines = []
    for row in rows:
        vals = ", ".join(_fmt(float(v)) for v in row)
        lines.append(f"    {{{vals}}},")
    return "\n".join(lines)


def generate() -> str:
    causal = _causal_weights()
    sinc = _kaiser_sinc_weights()
    return (
        "// Generated by scripts/generate_align_delay_table.py; do not edit.\n"
        "#pragma once\n\n"
        "namespace NAMRig {\n\n"
        "struct AlignDelayTables {\n"
        f"  static constexpr int kTaps = {TAPS};\n"
        f"  static constexpr int kCausalMaxDelay = {CAUSAL_MAX_DELAY};\n"
        f"  static constexpr int kCausalSteps = {CAUSAL_STEPS};\n"
        f"  static constexpr int kCausalRows = {CAUSAL_ROWS};\n"
        f"  static constexpr int kSincFirstTap = {SINC_FIRST_TAP};\n"
        f"  static constexpr int kSincSteps = {SINC_STEPS};\n"
        f"  static constexpr int kSincRows = {SINC_ROWS};\n"
        "};\n\n"
        "inline constexpr float kAlignCausalWeights"
        "[AlignDelayTables::kCausalRows][AlignDelayTables::kTaps] = {\n"
        + _format_table(causal)
        + "\n};\n\n"
        "inline constexpr float kAlignSincWeights"
        "[AlignDelayTables::kSincRows][AlignDelayTables::kTaps] = {\n"
        + _format_table(sinc)
        + "\n};\n\n"
        "}  // namespace NAMRig\n"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    out_path = ROOT / "src/align_delay_table.h"
    content = generate()
    if args.check:
        if not out_path.exists() or out_path.read_text() != content:
            raise SystemExit(
                "Alignment delay table is stale; run scripts/generate_align_delay_table.py"
            )
    else:
        out_path.write_text(content)
