#!/usr/bin/env python3
"""Equivalence spec for the BATCHED (vDSP_conv) formulation of the 2x
oversampler, before src/oversample.cpp is changed to use it.

Current C++ computes each output with one vDSP_dotpr inside a per-sample
while loop. The batched formulation computes the SAME outputs from the SAME
scratch buffer with ONE strided FIR pass per call:

  Up2x   odd outputs: windows starting at consecutive scr indices
         j0 .. j0+m-1 (24 taps each)  ->  one correlation
         even outputs: scr[j0+11 ..] verbatim
  Down2x outputs:     windows starting at scr indices j0, j0+2, j0+4, ...
         (47 taps each)               ->  one stride-2 correlation
         (this is exactly vDSP_conv with input stride 2, as in WavIR)

Both share the identical streaming state machine (hist_, next_/provided_,
consumed_/emitted_), so only the output computation differs. This test
proves:

  1. per-sample vs batched in float64: equal to ~1e-12 (same linear filter,
     only summation order differs),
  2. batched float32 vs float64 reference: within float32 rounding
     (<= ~1e-6 on unit-scale signals) — the real C++ comparison standard,
  3. streaming output == one-shot prefix (delay/parity semantics unchanged),
     for adversarial block-size sequences,
  4. edge cases: 1-sample blocks, blocks shorter than the context windows,
     first block after reset, DC gain, band-limited impulse area.

Run:  python3 tests/test_oversample_batched.py
"""
import math
import sys

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

sys.path.insert(0, "tests")
from test_oversample_2x import (  # noqa: E402
    HB_N,
    HALF,
    P,
    PROTO,
    PROTO_REV,
    Up2x as Up2xRef,
    Down2x as Down2xRef,
    up_2x,
    down_2x,
    saturation,
)

UP_HIST = 23   # C++ Up2x::kHist
DN_HIST = 46   # C++ Down2x::kHist
UP_LEFT = 11
UP_RIGHT = 12

PASS = 0
FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok    {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}  {detail}")


# ---------------------------------------------------------------------------
# Streaming state machine mirroring the C++ EXACTLY, computing both the
# per-sample formulation (what the current C++ does) and the batched one
# (what vDSP_conv will do) from the same scratch buffer per call.
# ---------------------------------------------------------------------------
class Up2xDual:
    def __init__(self):
        self.hist = np.zeros(UP_HIST)
        self.next = 0        # next base position to emit (absolute)
        self.provided = 0    # base samples provided (absolute)

    def process(self, x):
        x = np.asarray(x, dtype=np.float64)
        n = x.size
        scr = np.concatenate([self.hist, x])
        total = scr.size
        base = self.provided - UP_HIST  # absolute pos of scr[0]

        # -- determine the emitted range exactly like the C++ loop --
        p = self.next
        outs_sample, outs_batch = [], []
        js = []
        while True:
            j = (p - UP_LEFT) - base
            if j < 0:
                p += 1
                continue
            if j + 24 > total:
                break
            js.append(j)
            p += 1
        m = len(js)
        if m:
            j0 = js[0]
            assert js == list(range(j0, j0 + m))  # contiguity is the design
            # per-sample formulation (current C++): dot(scr[j:j+24], P)
            for j in js:
                outs_sample.append(float(np.dot(scr[j:j + 24], P)))
            # batched formulation: ONE window matrix, one matmul
            win = sliding_window_view(scr, 24)[j0:j0 + m]
            outs_batch_f64 = win @ P
            outs_batch_f32 = (win.astype(np.float32) @ P.astype(np.float32)
                              ).astype(np.float64)
            evens = scr[j0 + UP_LEFT: j0 + UP_LEFT + m]
            out_sample = np.empty(2 * m)
            out_sample[0::2] = evens
            out_sample[1::2] = outs_sample
            out_batch_f64 = np.empty(2 * m)
            out_batch_f64[0::2] = evens
            out_batch_f64[1::2] = outs_batch_f64
            out_batch_f32 = np.empty(2 * m)
            out_batch_f32[0::2] = evens
            out_batch_f32[1::2] = outs_batch_f32
        else:
            out_sample = out_batch_f64 = out_batch_f32 = np.zeros(0)

        # -- update state exactly like the C++ --
        self.next = p
        self.provided += n
        if total >= UP_HIST:
            self.hist = scr[total - UP_HIST:].copy()
        else:
            self.hist = scr.copy()
        return out_sample, out_batch_f64, out_batch_f32, m


class Down2xDual:
    def __init__(self):
        self.hist = np.zeros(DN_HIST)
        self.consumed = 0
        self.emitted = 0

    def process(self, u):
        u = np.asarray(u, dtype=np.float64)
        n = u.size
        scr = np.concatenate([self.hist, u])
        total = scr.size
        base = self.consumed - DN_HIST

        a = 2 * self.emitted
        js = []
        while True:
            j = (a - HALF) - base
            if j < 0:
                a += 2
                continue
            if j + HB_N > total:
                break
            js.append(j)
            a += 2
        m = len(js)
        if m:
            j0 = js[0]
            assert js == list(range(j0, j0 + 2 * m, 2))  # stride-2 contiguity
            # per-sample (current C++)
            outs_sample = [float(np.dot(scr[j:j + HB_N], PROTO_REV))
                           for j in js]
            # batched: stride-2 windows, ONE matmul (== vDSP_conv, IS stride 2)
            win = sliding_window_view(scr, HB_N)[j0: j0 + 2 * m: 2]
            outs_batch_f64 = win @ PROTO_REV
            outs_batch_f32 = (win.astype(np.float32)
                              @ PROTO_REV.astype(np.float32)).astype(np.float64)
        else:
            outs_sample = []
            outs_batch_f64 = outs_batch_f32 = np.zeros(0)

        self.emitted += m
        self.consumed += n
        if total >= DN_HIST:
            self.hist = scr[total - DN_HIST:].copy()
        else:
            self.hist = scr.copy()
        return (np.asarray(outs_sample), np.asarray(outs_batch_f64),
                np.asarray(outs_batch_f32), m)


def random_block_sizes(total, rng, max_block=1024):
    sizes, left = [], total
    while left:
        n = int(rng.integers(1, min(max_block, left) + 1))
        sizes.append(min(n, left))
        left -= sizes[-1]
    return sizes


def main():
    rng = np.random.default_rng(20260829)

    print("== 1. per-sample vs batched, float64 (same filter, order only) ==")
    worst64 = 0.0
    for trial in range(200):
        n_total = int(rng.integers(24, 4000))
        x = rng.uniform(-1, 1, n_total)
        up = Up2xDual()
        for n in random_block_sizes(n_total, rng):
            o_s, o_b, _, _ = up.process(x[:0])  # placeholder, replaced below
            break
        # re-run cleanly (state machine consumed above) — fresh instance
        up = Up2xDual()
        fed = 0
        for n in random_block_sizes(n_total, rng):
            o_s, o_b, _, _ = up.process(x[fed:fed + n])
            if o_s.size:
                worst64 = max(worst64, float(np.max(np.abs(o_s - o_b))))
            fed += n
    check("Up2x per-sample == batched (f64)", worst64 < 1e-12,
          f"worst={worst64:.3e}")

    worst64d = 0.0
    for trial in range(200):
        n_total = int(rng.integers(48, 4000))
        u = rng.uniform(-1, 1, n_total)
        dn = Down2xDual()
        fed = 0
        for n in random_block_sizes(n_total, rng, max_block=2048):
            o_s, o_b, _, _ = dn.process(u[fed:fed + n])
            if o_s.size:
                worst64d = max(worst64d, float(np.max(np.abs(o_s - o_b))))
            fed += n
    check("Down2x per-sample == batched (f64)", worst64d < 1e-12,
          f"worst={worst64d:.3e}")

    print("== 2. batched float32 vs float64 reference (realistic precision) ==")
    # Per-call outputs are absolute positions [emitted_before,
    # emitted_before+m) — compare CUMULATIVELY against the one-shot prefix.
    worst32 = 0.0
    for trial in range(100):
        n_total = int(rng.integers(64, 4000))
        x = rng.uniform(-1, 1, n_total)
        up = Up2xDual()
        got = []
        fed = 0
        for n in random_block_sizes(n_total, rng):
            _, _, o32, _ = up.process(x[fed:fed + n])
            if o32.size:
                got.append(o32)
            fed += n
        if got:
            got = np.concatenate(got)
            ref = up_2x(x)[: got.size]
            worst32 = max(worst32, float(np.max(np.abs(got - ref))))
    check("Up2x f32 batched within float rounding of reference",
          worst32 < 2e-6, f"worst={worst32:.3e}")

    worst32d = 0.0
    for trial in range(100):
        n_total = int(rng.integers(64, 4000))
        u = rng.uniform(-1, 1, n_total)
        dn = Down2xDual()
        got = []
        fed = 0
        for n in random_block_sizes(n_total, rng, max_block=2048):
            _, _, o32, _ = dn.process(u[fed:fed + n])
            if o32.size:
                got.append(o32)
            fed += n
        if got:
            got = np.concatenate(got)
            ref = down_2x(u)[: got.size]
            worst32d = max(worst32d, float(np.max(np.abs(got - ref))))
    check("Down2x f32 batched within float rounding of reference",
          worst32d < 2e-6, f"worst={worst32d:.3e}")

    print("== 3. streaming == one-shot prefix, adversarial block sizes ==")
    ok_stream_up = True
    for trial in range(100):
        n_total = int(rng.integers(24, 2000))
        x = rng.uniform(-1, 1, n_total)
        up = Up2xDual()
        got = []
        fed = 0
        for n in random_block_sizes(n_total, rng):
            _, o_b, _, _ = up.process(x[fed:fed + n])
            got.append(o_b)
            fed += n
        got = np.concatenate(got) if got else np.zeros(0)
        ref = up_2x(x)
        # emitted count can trail the one-shot by the right-context delay
        if got.size > ref.size or not np.allclose(got, ref[: got.size],
                                                  atol=1e-12):
            ok_stream_up = False
            break
    check("Up2x streaming == one-shot prefix (any block sizes)",
          ok_stream_up)

    ok_stream_dn = True
    for trial in range(100):
        n_total = int(rng.integers(48, 2000))
        u = rng.uniform(-1, 1, n_total)
        dn = Down2xDual()
        got = []
        fed = 0
        for n in random_block_sizes(n_total, rng, max_block=2048):
            _, o_b, _, _ = dn.process(u[fed:fed + n])
            got.append(o_b)
            fed += n
        got = np.concatenate(got) if got else np.zeros(0)
        ref = down_2x(u)
        if got.size > ref.size or not np.allclose(got, ref[: got.size],
                                                  atol=1e-12):
            ok_stream_dn = False
            break
    check("Down2x streaming == one-shot prefix (any block sizes)",
          ok_stream_dn)

    print("== 4. edge cases ==")
    # 1-sample blocks
    up = Up2xDual()
    outs = []
    for i in range(200):
        _, o_b, _, _ = up.process(np.array([np.sin(0.1 * i)]))
        outs.append(o_b)
    got = np.concatenate(outs)
    ref = up_2x(np.sin(0.1 * np.arange(200)))
    check("Up2x 1-sample blocks == one-shot",
          np.allclose(got, ref[: got.size], atol=1e-12))

    dn = Down2xDual()
    outs = []
    u = np.cos(0.07 * np.arange(400))
    for i in range(400):
        _, o_b, _, _ = dn.process(np.array([u[i]]))
        outs.append(o_b)
    got = np.concatenate(outs) if outs else np.zeros(0)
    ref = down_2x(u)
    check("Down2x 1-sample blocks == one-shot",
          np.allclose(got, ref[: got.size], atol=1e-12))

    # blocks SHORTER than the context windows
    up = Up2xDual()
    o, _, _, m = up.process(np.array([0.5]))
    check("Up2x first 1-sample block emits nothing (window incomplete)",
          m == 0 and o.size == 0)
    dn = Down2xDual()
    o, _, _, m = dn.process(np.zeros(10))
    check("Down2x short first block emits nothing", m == 0 and o.size == 0)

    # exact-boundary block: n == context so windows just complete
    up = Up2xDual()
    x = rng.uniform(-1, 1, 12)
    _, o_b, _, m = up.process(x)
    check("Up2x n=12 first block emits 0 (needs 11 left + 12 right)",
          m == 0, f"m={m}")
    _, o_b, _, m = up.process(rng.uniform(-1, 1, 1))
    check("Up2x 13th sample releases first output", m == 1, f"m={m}")

    # DC gain through the full batched pipeline
    up = Up2xDual()
    dn = Down2xDual()
    x = np.ones(4000)
    got_up = []
    fed = 0
    for n in random_block_sizes(4000, rng):
        _, o_b, _, _ = up.process(x[fed:fed + n])
        got_up.append(o_b)
        fed += n
    u2 = np.concatenate(got_up)
    got_dn = []
    fed = 0
    for n in random_block_sizes(u2.size, rng, max_block=2048):
        _, o_b, _, _ = dn.process(u2[fed:fed + n])
        got_dn.append(o_b)
        fed += n
    y = np.concatenate(got_dn)
    check("DC gain of batched UP->DOWN ~= 1 (streaming, f64)",
          y.size > 100 and abs(np.mean(y[-100:]) - 1.0) < 1e-9,
          f"mean_tail={np.mean(y[-100:]):.12f}")

    # band-limited impulse area preserved (upsampled then decimated)
    up = Up2xDual()
    dn = Down2xDual()
    x = np.zeros(2000)
    x[137] = 1.0
    u2 = np.concatenate([up.process(x[i:i + 256])[1]
                         for i in range(0, 2000, 256)])
    y = np.concatenate([dn.process(u2[i:i + 512])[1]
                        for i in range(0, u2.size, 512)])
    check("impulse round-trip area ~= 1",
          abs(np.sum(y) - 1.0) < 1e-9, f"area={np.sum(y):.12f}")

    # hard-clipper alias sanity, EXACTLY the spec test's construction and
    # clutter metric (test_saturation_alias_reduction): non-integer f0 so
    # folded products land BETWEEN harmonics; mask +/-150 Hz around each
    # harmonic, measure the max of the rest, ratio to spectrum peak.
    rate = 48000
    n = 65536
    t = np.arange(n) / rate
    f0 = 3173.0
    x = 1.5 * np.sin(2 * math.pi * f0 * t)   # hard clip -> rich harmonics
    skip = 512

    def clutter(sig):
        seg = sig[skip:-skip] * np.hanning(len(sig) - 2 * skip)
        spec = np.abs(np.fft.rfft(seg))
        freqs = np.fft.rfftfreq(len(seg), 1.0 / rate)
        mask = np.zeros(len(spec), dtype=bool)
        for k in range(1, 16):
            fh = f0 * k
            if fh < 24000:
                mask |= np.abs(freqs - fh) < 150
        region = ~mask & (freqs > 3600) & (freqs < 23000)
        return spec[region].max() / spec.max()

    base = clutter(saturation(x))  # hard clip at base rate
    up = Up2xDual()
    dn = Down2xDual()
    u2 = np.concatenate([up.process(x[i:i + 512])[1]
                         for i in range(0, x.size, 512)])
    u2s = saturation(u2)
    y = np.concatenate([dn.process(u2s[i:i + 1024])[1]
                        for i in range(0, u2s.size, 1024)])
    over = clutter(y)
    # Spec standard: improvement > 10 dB == amplitude ratio > 10^(10/20).
    check("hard-clipper: batched oversampled clutter >= 10 dB below base",
          over < base / (10 ** (10 / 20)), f"base={base:.3e} over={over:.3e} "
          f"({20 * np.log10(base / max(over, 1e-30)):.1f} dB better)")

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
