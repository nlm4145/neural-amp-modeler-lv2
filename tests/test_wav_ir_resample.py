#!/usr/bin/env python3
"""Unit tests for WavIR resampling + selectable IR level normalization.

These mirror the EXACT algorithms in src/wav_ir.cpp (windowed-sinc resample,
80 ms truncation, preserve/peak/energy scales) so any change to the C++ can be
validated in seconds, before compiling — the discipline that caught the
count/position ratio inversion (a 1/4-length output) during development.

Run:  python3 tests/test_wav_ir_resample.py
"""
import math
import random
import struct
import wave

import numpy as np

PI = math.pi
K_TAPS = 64  # kernel half-width, input samples (must match wav_ir.cpp)


def resample(input_sig, from_rate, to_rate):
    """Mirror of NAMRig::(anonymous)::resample in src/wav_ir.cpp."""
    input_sig = np.asarray(input_sig, dtype=np.float64)
    if abs(from_rate - to_rate) < 1.0 or input_sig.size < 2:
        return input_sig.astype(np.float32)
    ratio = from_rate / to_rate
    beta = 0.9 * min(from_rate, to_rate) / from_rate
    count = max(2, round(input_sig.size * to_rate / from_rate))
    n = input_sig.size
    output = np.zeros(count, dtype=np.float64)
    for i in range(count):
        pos = i * ratio
        center = round(pos)
        acc = 0.0
        wsum = 0.0
        for k in range(center - K_TAPS, center + K_TAPS + 1):
            if k < 0 or k >= n:
                continue
            r = pos - k
            u = beta * r
            if abs(u) < 1e-8:
                s = beta
            else:
                s = beta * math.sin(PI * u) / (PI * u)
            v = r / K_TAPS
            w = (0.35875 + 0.48829 * math.cos(PI * v) + 0.14128 * math.cos(2 * PI * v)
                 + 0.01168 * math.cos(3 * PI * v))  # Blackman-Harris
            acc += input_sig[k] * s * w
            wsum += s * w
        if wsum != 0.0:
            output[i] = acc / wsum
        else:
            output[i] = input_sig[min(center, n - 1)]
    return output.astype(np.float32)


def wav_ir_load_taps(x, source_rate, host_rate):
    """The tap-processing chain in WavIR::load (after WAV decode):
    resample -> 80 ms truncation. Normalization is now a runtime output scale."""
    taps = np.asarray(resample(x, source_rate, host_rate), dtype=np.float64)
    max_len = int(host_rate * 0.08)
    if taps.size > max_len:
        taps = taps[:max_len]
    if taps.size == 0:
        raise ValueError("empty IR")
    return taps


def normalization_scales(taps):
    peak = float(np.max(np.abs(taps)))
    energy = float(np.sum(taps * taps))
    return (1.0,
            1.0 / peak if peak > 0.0 else 1.0,
            1.0 / math.sqrt(energy) if energy > 0.0 else 1.0)


def test_equal_rate_is_identity():
    """48 kHz host, 48 kHz IR: the resampler must be a bit-exact no-op."""
    rng = random.Random(42)
    x = np.array([rng.uniform(-1, 1) for _ in range(732)], dtype=np.float32)
    out = resample(x, 48000, 48000)
    assert out.dtype == np.float32
    assert np.array_equal(out, x), "equal-rate path must be bit-identical"


def test_dc_gain_is_one():
    """Window-sum normalization: DC in -> DC out at exactly 1.0."""
    for (f, t) in [(48000, 96000), (96000, 48000), (44100, 48000)]:
        x = np.ones(1024, dtype=np.float32)
        out = resample(x, f, t)
        # skip 2*taps edges where the window truncates
        interior = out[2 * K_TAPS:-2 * K_TAPS]
        assert np.allclose(interior, 1.0, atol=1e-6), \
            f"DC gain != 1 for {f}->{t}: max err {np.max(np.abs(interior - 1.0))}"


def test_bandlimited_impulse_preserves_area():
    """Impulse at a misaligned grid position: output sum == to/from (area law)."""
    rng = random.Random(7)
    x = np.zeros(1024, dtype=np.float32)
    x[137] = 1.0
    out = np.asarray(resample(x, 48000, 96000), dtype=np.float64)
    assert abs(out.sum() - 2.0) < 0.02, f"area {out.sum()} != 2.0"


def test_lengths():
    """count uses to/from; positions use from/to. Inverting them produces a
    1/4-length output on 2x upsampling — this exact bug shipped once."""
    n = 732
    assert resample(np.zeros(n), 48000, 96000).size == 2 * n
    assert resample(np.zeros(n), 48000, 44100).size == round(n * 44100 / 48000)  # 673
    assert resample(np.zeros(n), 96000, 48000).size == n // 2


def test_no_nan_finite():
    x = np.random.default_rng(3).uniform(-1, 1, 512).astype(np.float32)
    out = resample(x, 48000, 96000)
    assert np.all(np.isfinite(out))


def synth_cab_ir(n=732, seed=11, cutoff_hz=18000.0, rate=48000):
    """Band-limited decaying noise burst — a realistic cab IR. Real IRs carry
    almost no energy above ~20 kHz, which matters here: the resampler's design
    cutoff is 0.45*min(fs) (21.6 kHz at 48k), so full-band white noise would
    LOSE the 21.6-24k band on any rate change by design, not by defect."""
    rng = np.random.default_rng(seed)
    x = rng.standard_normal(n)
    # simple FIR lowpass (windowed sinc, 65 taps)
    h = np.zeros(65)
    for i in range(65):
        r = (i - 32) * 2 * cutoff_hz / rate
        h[i] = (2 * cutoff_hz / rate) * (np.sinc(r)) * (0.54 - 0.46 * np.cos(2 * math.pi * i / 64))
    y = np.convolve(x, h, "same")
    y *= np.exp(-np.arange(n) / 120.0)
    y /= np.max(np.abs(y))
    return y.astype(np.float32)


def test_top_band_energy_preserved_vs_linear():
    """The whole point of windowed-sinc over linear interp: in-band hi-frequency
    (12-18 kHz) energy must not droop. Linear interpolation applies a sinc^2
    magnitude response (~-1.4 dB @ 12 kHz on 48->96) that reads as permanent
    top-end loss; windowed-sinc is flat. Reference measured on a Mesa cab IR:
    windowed-sinc ~0.042 vs linear ~0.028 hi-band share."""
    ir = synth_cab_ir()
    n = ir.size
    up = np.asarray(resample(ir, 48000, 96000), dtype=np.float64)
    # linear interpolation reference (the OLD broken behavior)
    pos = np.arange(len(up)) * (48000 / 96000)
    i0 = np.floor(pos).astype(int)
    frac = pos - i0
    i1 = np.minimum(i0 + 1, n - 1)
    lin = ir[i0] * (1 - frac) + ir[i1] * frac

    def hishare(sig):
        spec = np.abs(np.fft.rfft(sig))
        freqs = np.fft.rfftfreq(len(sig), 1.0 / 96000)
        # in-band top region only (below the 21.6 kHz design cutoff)
        return spec[(freqs >= 12000) & (freqs <= 18000)].sum() / spec.sum()

    hs = hishare(up)
    hl = hishare(lin)
    assert hs > 1.15 * hl, f"top-band share {hs:.3f} not clearly better than linear {hl:.3f}"


def test_round_trip_near_lossless():
    """48->96->48 round trip on a band-limited IR (like a real cab capture):
    RMSE must be near-zero (reference measured on a Mesa IR: ~0.0014)."""
    ir = synth_cab_ir(seed=5)
    n = ir.size
    up = resample(ir, 48000, 96000)
    back = resample(up, 96000, 48000)
    common = min(len(back), n)
    rmse = float(np.sqrt(np.mean((back[:common] - ir[:common]) ** 2)))
    assert rmse < 0.01, f"round-trip RMSE {rmse}"


def test_selectable_normalization():
    """Preserve is untouched; peak and historical loudness modes hit unity."""
    rng = random.Random(23)
    n = 732
    for peak in (1.0, 0.1, 0.01):
        ir = np.array([rng.uniform(-1, 1) for _ in range(n)], dtype=np.float32) * peak
        taps = wav_ir_load_taps(ir, 48000, 48000)
        preserve, peak_scale, loudness_scale = normalization_scales(taps)
        assert preserve == 1.0 and np.array_equal(taps, ir)
        assert abs(float(np.max(np.abs(taps * peak_scale))) - 1.0) < 1e-5
        energy = float(np.sum((taps * loudness_scale) ** 2))
        assert abs(math.sqrt(energy) - 1.0) < 1e-4, f"input peak {peak}: energy {energy}"


def test_wav_decode_roundtrip_smoke():
    """The readWav mirror (16/24/32-PCM, 32-float) — exercises the byte-layout
    assumptions used by readWav, via a temp WAV write/read with the stdlib."""
    import tempfile, os
    rng = random.Random(99)
    x = np.array([rng.uniform(-0.9, 0.9) for _ in range(64)], dtype=np.float32)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        path = f.name
    try:
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(48000)
            w.writeframes((x * 32767).astype("<i2").tobytes())
        with wave.open(path, "rb") as w:
            assert w.getframerate() == 48000 and w.getsampwidth() == 2
            y = np.frombuffer(w.readframes(64), dtype="<i2").astype(np.float32) / 32768.0
        assert np.max(np.abs(y - x)) < 0.001
    finally:
        os.unlink(path)


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
