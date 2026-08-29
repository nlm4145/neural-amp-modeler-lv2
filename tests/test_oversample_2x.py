#!/usr/bin/env python3
"""Unit tests for the true 2x oversampler (half-band polyphase, streaming).

Reference implementation of what src/oversample.cpp implements:

Prototype (half-band, exact): h[m] = 0.5 * sinc(0.5*m) * kaiserWindow(m),
  m = -23 .. +23 (n = 47, beta = 9.0). Even-offset taps are sinc zeros;
  the center tap is exactly 0.5; the odd-offset taps are rescaled so the
  prototype sums to EXACTLY 1 (DC gain 1).

UP (2x):   u[2i]   = x[i]                                    (identity phase)
           u[2i+1] = dot(P, x[i-11 .. i+12])                 (P = 2*h[odd
                                                                offsets], 24
                                                                symmetric taps,
                                                                DC gain exact 1)
DOWN (1x): y[k]    = (h * u)[2k]   -- full 47-tap prototype FIR at the 2x
           rate, centered alignment, decimated to even absolute positions.

Streaming (exactly the C++ design):
  Up2x   keeps 11 left-context + all pending base samples; emits only
         positions whose full 24-tap window is covered by REAL data;
         right context (12) rolls over between calls.
  Down2x keeps 23 u-samples of history and an absolute consumed count for
         parity; emits even absolute positions whose 47-tap window is
         fully covered.
  => streaming == one-shot prefix (fixed pipeline delay), any block size.

Run:  python3 tests/test_oversample_2x.py
"""
import math

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

HB_N = 47          # prototype length, 4k-1 form (k=12)
Kaiser_beta = 9.0  # ~100 dB stopband attenuation
HALF = (HB_N - 1) // 2  # 23


def bessel_i0(x):
    x = np.asarray(x, dtype=np.float64)
    out = np.ones_like(x)
    term = np.ones_like(x)
    for k in range(1, 80):
        term = term * (x / (2.0 * k)) ** 2
        out += term
    return out


def halfband_prototype(n=HB_N, beta=Kaiser_beta):
    m = np.arange(n) - (n - 1) / 2.0
    x = beta * np.sqrt(np.maximum(0.0, 1.0 - (m / ((n - 1) / 2.0)) ** 2))
    w = bessel_i0(x) / bessel_i0(np.array(beta))
    h = 0.5 * np.sinc(0.5 * m) * w
    h[HALF] = 0.5  # exact center
    # Rescale ONLY the odd-offset taps so the prototype sums to exactly 1:
    # even-offset taps are sinc zeros and the center is pinned at 0.5, so the
    # odd taps must carry precisely the other 0.5. DC gain exact.
    offsets = np.arange(n) - HALF
    odd_idx = np.where(offsets % 2 != 0)[0]
    h[odd_idx] *= 0.5 / h[odd_idx].sum()
    return h


PROTO = halfband_prototype()
PROTO_REV = PROTO[::-1]
# Interpolation branch: odd OFFSETS sit at even INDICES -> PROTO[0::2],
# 24 symmetric taps (offsets -23..+23 odd). Sum = 2 * 0.5 = 1 exactly.
P = 2.0 * PROTO[0::2]


def up_2x(x):
    """One-shot: even outputs = input; odd = centered 24-tap FIR."""
    x = np.asarray(x, dtype=np.float64)
    n = x.size
    xp = np.pad(x, (11, 12))
    win = sliding_window_view(xp, 24)
    odd = win @ P  # P symmetric
    u = np.empty(2 * n)
    u[0::2] = x
    u[1::2] = odd
    return u


def down_2x(u):
    """One-shot: 47-tap centered FIR at 2x, take even absolute positions."""
    u = np.asarray(u, dtype=np.float64)
    xp = np.pad(u, (HALF, HALF))
    win = sliding_window_view(xp, HB_N)
    filtered = win @ PROTO_REV
    return filtered[0::2].copy()


def saturation(x):
    """Nonlinear stage stand-in: hard clip (strong harmonic generation)."""
    return np.clip(x, -0.5, 0.5)


class Up2x:
    """Streaming 2x upsampler (the C++ design).

    buf = [11 left-context samples] + [un-emitted real samples].
    Per call: a base position p (buf index) is emittable when its window
    buf[p-11 .. p+12] is fully inside buf. Emits (u[2j], u[2j+1]) pairs;
    retains the 12-sample right context plus everything un-emitted.
    """

    LEFT = 11   # taps before the output position
    RIGHT = 12  # taps after the output position

    def __init__(self):
        self.buf = np.zeros(self.LEFT)  # stream-start left context (zeros)

    def process(self, x):
        self.buf = np.concatenate([self.buf, np.asarray(x, dtype=np.float64)])
        # real positions start at index LEFT; emittable: p + RIGHT <= len-1
        n_real = len(self.buf) - self.LEFT
        n_emit = n_real - self.RIGHT
        if n_emit <= 0:
            return np.zeros(0)
        win = sliding_window_view(self.buf, 24)  # win[k] = buf[k .. k+23]
        # position p = LEFT + j  ->  window = buf[p-11 .. p+12] = win[p-11] = win[j]
        odd = win[:n_emit] @ P
        even = self.buf[self.LEFT:self.LEFT + n_emit]
        u = np.empty(2 * n_emit)
        u[0::2] = even
        u[1::2] = odd
        # retain: keep last 11 samples before the un-emitted tail + the tail
        self.buf = self.buf[n_emit:]
        return u


class Down2x:
    """Streaming 2x decimator (the C++ design), absolute-position indexing.

    buf holds u-samples covering absolute positions [buf_start, buf_start+len).
    next_out is the next absolute position to EMIT (even parity); it advances
    past emitted positions and can point anywhere, including inside hist.
    A position a is emittable when its 47-tap window [a-23, a+23] lies fully
    inside the buffer. After the call, the buffer's left edge is trimmed to
    next_out - 23 (the oldest context still needed). This never drops or
    double-emits a position, at any block size.
    """

    def __init__(self):
        self.buf = np.zeros(HB_N - 1)   # stream-start left context
        self.buf_start = -(HB_N - 1)    # absolute position of buf[0]
        self.next_out = 0               # next absolute position to emit

    def process(self, u):
        u = np.asarray(u, dtype=np.float64)
        self.buf = np.concatenate([self.buf, u])
        end = self.buf_start + len(self.buf) - 1   # last covered abs position
        # emittable: next_out - 23 >= buf_start  AND  next_out + 23 <= end
        out = []
        win = sliding_window_view(self.buf, HB_N)
        while self.next_out - HB_N // 2 >= self.buf_start and \
                self.next_out + HB_N // 2 <= end and self.next_out % 2 == 0 or \
                (self.next_out % 2 != 0):
            if self.next_out % 2 != 0:
                self.next_out += 1  # only even positions are outputs
                continue
            if not (self.next_out - HB_N // 2 >= self.buf_start and
                    self.next_out + HB_N // 2 <= end):
                break
            # window start in buf: next_out - 23 - buf_start
            w = self.next_out - HB_N // 2 - self.buf_start
            out.append(float(win[w] @ PROTO_REV))
            self.next_out += 2
        # trim: keep from next_out - 23 onward
        keep_from = self.next_out - HB_N // 2
        if keep_from > self.buf_start:
            self.buf = self.buf[keep_from - self.buf_start:]
            self.buf_start = keep_from
        return np.array(out)


def roundtrip_stream(x, block=128):
    up = Up2x()
    down = Down2x()
    out = []
    for i in range(0, len(x), block):
        out.append(down.process(up.process(x[i:i + block])))
    return np.concatenate(out)


# ---- tests ----

def test_prototype_halfband_property():
    """Even-offset taps (except center) must be ~0; center exactly 0.5."""
    for k in range(HB_N):
        m = k - HALF
        if m != 0 and m % 2 == 0:
            assert abs(PROTO[k]) < 1e-12, f"tap offset {m} not 0: {PROTO[k]}"
    assert PROTO[HALF] == 0.5
    assert abs(PROTO.sum() - 1.0) < 1e-12


def test_interp_branch_dc_gain():
    """Interpolation branch must sum to exactly 1 (DC passthrough)."""
    assert abs(P.sum() - 1.0) < 1e-12


def test_up_identity_phase():
    """Even output positions must be EXACTLY the input samples."""
    rng = np.random.default_rng(2)
    x = rng.standard_normal(256) * 0.3
    u = up_2x(x)
    assert u.size == 512
    assert np.array_equal(u[0::2], x)


def test_up_dc():
    """DC in -> DC out at 1.0 on both phases (interior; edges see padding)."""
    u = up_2x(np.ones(512))
    assert np.allclose(u[24:-24], 1.0, atol=1e-9)


def test_up_imaging_rejection():
    """Upsampling an in-band tone must not create images above 24k."""
    rate = 48000
    n = 16384
    t = np.arange(n) / rate
    x = 0.5 * np.sin(2 * math.pi * 5000.0 * t)
    u = up_2x(x)
    seg = u[256:-256] * np.hanning(len(u) - 512)
    spec = np.abs(np.fft.rfft(seg))
    freqs = np.fft.rfftfreq(len(seg), 1.0 / 96000)
    image = spec[freqs > 25000].max()
    fundamental = spec.max()
    assert image / fundamental < 10 ** (-90 / 20), \
        f"image energy only {20 * math.log10(image / fundamental):.1f} dB down"


def test_down_alias_rejection():
    """A 30 kHz tone at the 2x rate must be >= 90 dB below its INPUT level
    after decimation (would alias to 18 kHz with poor filtering)."""
    rate = 96000
    n = 16384
    t = np.arange(n) / rate
    u = 0.5 * np.sin(2 * math.pi * 30e3 * t)
    y = down_2x(u)
    seg = y[512:-512] * np.hanning(len(y) - 1024)
    spec = np.abs(np.fft.rfft(seg))
    freqs = np.fft.rfftfreq(len(seg), 1.0 / 48000)
    residual = spec[(freqs > 17e3) & (freqs < 19e3)].max()
    input_level = 0.5 * (len(seg) / 2)
    assert residual / input_level < 10 ** (-90 / 20), \
        f"30k alias only {20 * math.log10(residual / input_level):.1f} dB below input"


def test_passband_ripple():
    """UP+DOWN round trip flat to < 0.1 dB up to 19.2 kHz (0.4 x base)."""
    rate = 48000
    n = 8192
    t = np.arange(n) / rate
    for f in [100.0, 1000.0, 5000.0, 12000.0, 18000.0, 19200.0]:
        x = 0.5 * np.sin(2 * math.pi * f * t)
        y = down_2x(up_2x(x))
        skip = 128
        seg = y[skip:skip + 4096]
        ref = x[skip:skip + 4096]
        ratio = np.sqrt((seg ** 2).mean()) / np.sqrt((ref ** 2).mean())
        db = 20 * math.log10(ratio)
        assert abs(db) < 0.1, f"{f} Hz: round-trip gain {db:+.3f} dB"


def test_streaming_equivalence():
    """Streaming in any block size == one-shot (fixed pipeline delay,
    sub-1e-9 error). The killer regression test for the C++ ring buffers."""
    rng = np.random.default_rng(4)
    x = rng.standard_normal(4096) * 0.3
    one = down_2x(up_2x(x))
    for b in (64, 128, 512, 1000):
        streamed = roundtrip_stream(x, block=b)
        m = min(len(one), len(streamed))
        best = None
        for lag in range(0, 64):
            a = streamed[lag:lag + m - 64]
            e = a - one[:m - 64]
            r = float(np.abs(e).max())
            if best is None or r < best[1]:
                best = (lag, r)
        lag, err = best
        assert err < 1e-9, f"block {b}: best lag {lag}, max err {err}"


def test_saturation_alias_reduction():
    """THE reason this exists: clipping at 2x then decimating must leave far
    less inter-harmonic alias clutter than clipping at the base rate.
    Non-integer fundamental so folded products land BETWEEN harmonics."""
    rate = 48000
    n = 65536
    t = np.arange(n) / rate
    f0 = 3173.0  # prime-ish: harmonics + folded products interleave
    x = 1.5 * np.sin(2 * math.pi * f0 * t)   # hard clip -> rich harmonics
    base = saturation(x)
    over = down_2x(saturation(up_2x(x)))
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

    c_base = clutter(base)
    c_over = clutter(over)
    improvement_db = 20 * math.log10(c_base / c_over)
    assert improvement_db > 10.0, \
        f"alias clutter only {improvement_db:.1f} dB better oversampled " \
        f"(base {c_base:.2e}, over {c_over:.2e})"


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"  PASS  {t.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"  FAIL  {t.__name__}: {e}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    raise SystemExit(1 if failed else 0)
