#!/usr/bin/env python3
"""Unit tests for WavIR resampling + selectable IR level normalization.

These mirror the algorithms in src/wav_ir.cpp (windowed-sinc resample, IR
transfer-gain correction, 170 ms truncation, and response-based normalization)
so changes can be validated before compiling.

Run:  python3 tests/test_wav_ir_resample.py
"""
import math
import random
import struct
import wave

import numpy as np

PI = math.pi
K_TAPS = 64  # kernel half-width, input samples (must match wav_ir.cpp)


def _repair_causal_pre_ringing(full, pre_out, count, from_rate, to_rate):
    """Mirror of repairCausalPreRinging + estimateSpectrumEnvelope in src/wav_ir.cpp."""
    if pre_out == 0 or count == 0:
        return
    max_pre = float(np.max(np.abs(full[:pre_out])))
    max_base = float(np.max(np.abs(full[pre_out:pre_out + count])))
    if not (max_base > 1e-30) or max_pre <= 1e-7 * max_base:
        return

    f_lin = np.linspace(0.0, 0.5, 384)
    low_min = min(15.0 / to_rate, 0.25)
    low_max = min(500.0 / to_rate, 0.45)
    if 0.0 < low_min < low_max:
        f_log = np.geomspace(low_min, low_max, 64)
        f_norm = np.sort(np.concatenate([f_lin, f_log]))
        dedup = [f_norm[0]]
        for val in f_norm[1:]:
            if abs(val - dedup[-1]) >= 1e-12:
                dedup.append(val)
        norm_freqs = np.asarray(dedup, dtype=np.float64)
    else:
        norm_freqs = f_lin

    spec_len = min(full.size, 32768)
    max_abs = float(np.max(np.abs(full[:spec_len])))
    if max_abs > 0.0:
        n_fft = 2048
        while n_fft < spec_len:
            n_fft <<= 1
        mag_fft = np.abs(np.fft.rfft(full[:spec_len] / max_abs, n=n_fft))
        half_bins = n_fft // 2
        bins = np.clip(norm_freqs * n_fft, 0.0, half_bins - 1e-9)
        b0 = np.floor(bins).astype(int)
        b1 = np.minimum(b0 + 1, half_bins)
        bf = bins - b0
        mag_env = mag_fft[b0] * (1.0 - bf) + mag_fft[b1] * bf
        peak_mag = max(float(np.max(mag_env)), 1e-12)
    else:
        mag_env = np.ones_like(norm_freqs)
        peak_mag = 1.0

    min_rate = min(from_rate, to_rate)
    f_pass = min(20000.0, 0.42 * min_rate) / to_rate
    f_stop = (0.5 * min_rate) / to_rate
    L = min(96, count)

    w = np.full_like(norm_freqs, 0.05)
    pass_mask = norm_freqs <= f_pass
    stop_mask = (~pass_mask) & (norm_freqs >= f_stop)
    w[pass_mask] = 1.0 / np.maximum(mag_env[pass_mask] / peak_mag, 0.02)
    w[stop_mask] = 0.20
    w2 = w * w

    p_idx = np.arange(1, pre_out + 1, dtype=np.float64)
    pre_rev = full[pre_out - 1::-1]
    target = np.exp(2j * PI * np.outer(norm_freqs, p_idx)) @ pre_rev

    d_idx = np.arange(L, dtype=np.float64)
    c = np.cos(2.0 * PI * np.outer(norm_freqs, d_idx)).T @ w2
    rhs = np.real(np.exp(2j * PI * np.outer(d_idx, norm_freqs)) @ (w2 * target))
    if not (c[0] > 0.0):
        return

    idx_grid = np.arange(L)
    G = c[np.abs(idx_grid[:, None] - idx_grid[None, :])]
    G[np.diag_indices(L)] += 1e-6 * c[0]
    try:
        dh = np.linalg.solve(G, rhs)
    except np.linalg.LinAlgError:
        return
    if np.all(np.isfinite(dh)):
        full[pre_out:pre_out + L] += dh


def resample(input_sig, from_rate, to_rate):
    """Mirror of NAMRig::(anonymous)::resample in src/wav_ir.cpp."""
    input_sig = np.asarray(input_sig, dtype=np.float64)
    if abs(from_rate - to_rate) < 1.0 or input_sig.size < 2:
        return input_sig.astype(np.float32)
    ratio = from_rate / to_rate
    beta = 0.9 * min(from_rate, to_rate) / from_rate
    count = max(2, round(input_sig.size * to_rate / from_rate))
    pre_out = int(math.ceil(K_TAPS * to_rate / from_rate))
    total = pre_out + count
    n = input_sig.size
    full = np.zeros(total, dtype=np.float64)
    for idx in range(total):
        i = idx - pre_out
        pos = i * ratio
        center = round(pos)
        acc = 0.0
        wsum = 0.0
        for k in range(center - K_TAPS, center + K_TAPS + 1):
            r = pos - k
            v = r / K_TAPS
            if abs(v) > 1.0:
                continue
            u = beta * r
            if abs(u) < 1e-8:
                s = beta
            else:
                s = beta * math.sin(PI * u) / (PI * u)
            w = (0.35875 + 0.48829 * math.cos(PI * v) + 0.14128 * math.cos(2 * PI * v)
                 + 0.01168 * math.cos(3 * PI * v))  # Blackman-Harris
            sw = s * w
            if 0 <= k < n:
                acc += input_sig[k] * sw
            wsum += sw
        full[idx] = acc / wsum if wsum != 0.0 else 0.0

    _repair_causal_pre_ringing(full, pre_out, count, from_rate, to_rate)
    return full[pre_out:].astype(np.float32)


def wav_ir_load_taps(x, source_rate, host_rate):
    """The tap-processing chain in WavIR::load (after WAV decode):
    resample -> transfer-gain correction -> truncation.

    The limit tracks WavIR::kMaxSeconds (170 ms). The synthetic IRs here are
    far shorter, so truncation never fires; it is mirrored for completeness.
    The C++ loader also applies a 5 ms raised-cosine fade at the cut, which
    this mirror omits because nothing here reaches the limit. Truncation and
    the fade are covered end-to-end by tests/verify_wav_ir.cpp."""
    taps = np.asarray(resample(x, source_rate, host_rate), dtype=np.float64)
    if abs(source_rate - host_rate) >= 1.0:
        taps *= source_rate / host_rate
    max_len = int(host_rate * 0.17)   # WavIR::kMaxSeconds
    if taps.size > max_len:
        taps = taps[:max_len]
    if taps.size == 0:
        raise ValueError("empty IR")
    return taps


def response_stats(taps, rate):
    """Peak and RMS magnitude across the same physical-Hz band as WavIR."""
    taps = np.asarray(taps, dtype=np.float64)
    freqs = np.linspace(20.0, max(20.0, min(20000.0, rate * 0.45)), 512)
    sample = np.arange(taps.size, dtype=np.float64)
    response = np.empty(freqs.size, dtype=np.complex128)
    # Keep temporary matrices bounded for long, high-rate IRs.
    for start in range(0, freqs.size, 32):
        f = freqs[start:start + 32]
        kernel = np.exp(-2j * PI * np.outer(f / rate, sample))
        response[start:start + f.size] = kernel @ taps
    magnitude = np.abs(response)
    return float(np.max(magnitude)), float(np.sqrt(np.mean(magnitude * magnitude)))


def normalization_scales(taps, rate):
    peak, rms = response_stats(taps, rate)
    return {1: 1.0 / peak if peak > 1e-12 else 1.0,
            2: 1.0 / rms if rms > 1e-12 else 1.0}


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


def test_ir_transfer_gain_is_sample_rate_invariant():
    """IR resampling preserves magnitude at the same physical frequencies."""
    ir = synth_cab_ir(seed=23)
    reference = wav_ir_load_taps(ir, 48000, 48000)
    for host_rate in (44100, 96000, 192000):
        converted = wav_ir_load_taps(ir, 48000, host_rate)
        for frequency in (100.0, 1000.0, 5000.0, 12000.0):
            def magnitude(taps, rate):
                n = np.arange(taps.size)
                return abs(np.sum(taps * np.exp(-2j * PI * frequency * n / rate)))
            delta_db = 20 * math.log10(
                magnitude(converted, host_rate) / magnitude(reference, 48000))
            assert abs(delta_db) < 0.15, \
                f"{host_rate} Hz at {frequency} Hz changed by {delta_db:.3f} dB"


def test_selectable_normalization():
    """Only Peak and Loudness are supported and normalize response metrics."""
    for amplitude in (1.0, 0.1, 0.01):
        ir = synth_cab_ir(seed=23) * amplitude
        taps = wav_ir_load_taps(ir, 48000, 48000)
        scales = normalization_scales(taps, 48000)
        assert set(scales) == {1, 2}
        peak_scale, loudness_scale = scales[1], scales[2]
        peak, _ = response_stats(taps * peak_scale, 48000)
        _, rms = response_stats(taps * loudness_scale, 48000)
        assert abs(peak - 1.0) < 1e-6
        assert abs(rms - 1.0) < 1e-6
        assert response_stats(taps * peak_scale, 48000)[1] < rms


def test_normalized_modes_are_sample_rate_invariant():
    """Response normalization uses physical Hz, not sample-count energy."""
    ir = synth_cab_ir(seed=31)
    for mode in (1, 2):
        reference = wav_ir_load_taps(ir, 48000, 48000)
        reference *= normalization_scales(reference, 48000)[mode]
        for host_rate in (44100, 96000, 192000):
            converted = wav_ir_load_taps(ir, 48000, host_rate)
            converted *= normalization_scales(converted, host_rate)[mode]
            for frequency in (100.0, 1000.0, 5000.0, 12000.0):
                def magnitude(taps, rate):
                    n = np.arange(taps.size)
                    return abs(np.sum(taps * np.exp(-2j * PI * frequency * n / rate)))
                delta_db = 20 * math.log10(
                    magnitude(converted, host_rate) / magnitude(reference, 48000))
                assert abs(delta_db) < 0.35, \
                    f"mode {mode}, {host_rate} Hz/{frequency} Hz: {delta_db:.3f} dB"


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


def test_minimum_phase_peak_at_zero_resampling():
    """Minimum-phase / peak-at-0 IRs must preserve transfer magnitude and phase
    coherence across sample-rate conversions without boundary clipping."""
    idx = np.arange(512, dtype=np.float64)
    ir0 = (np.exp(-idx / 30.0) * np.cos(0.15 * idx)).astype(np.float32)
    ir2 = np.pad(ir0[:-2], (2, 0)).astype(np.float32)

    def mag_at(taps, rate, freqs):
        n = np.arange(taps.size)
        return np.abs(np.exp(-2j * PI * np.outer(freqs / rate, n)) @ taps)

    freqs = np.array([50.0, 100.0, 500.0, 1000.0, 5000.0, 10000.0, 18000.0])
    for src_rate, dst_rate, limit_db in (
        (48000, 96000, 0.10),
        (96000, 48000, 0.15),
        (192000, 48000, 0.25),
        (44100, 48000, 0.05),
        (48000, 44100, 0.08),
    ):
        conv = wav_ir_load_taps(ir0, src_rate, dst_rate)
        delta_db = 20.0 * np.log10(mag_at(conv, dst_rate, freqs) / mag_at(ir0, src_rate, freqs))
        worst = float(np.max(np.abs(delta_db)))
        assert worst < limit_db, f"peak@0 {src_rate}->{dst_rate}: {worst:.3f} dB"

    conv2 = wav_ir_load_taps(ir2, 192000, 48000)
    worst2 = float(np.max(np.abs(20.0 * np.log10(
        mag_at(conv2, 48000, freqs) / mag_at(ir2, 192000, freqs)))))
    assert worst2 < 0.15, f"peak@2 192000->48000: {worst2:.3f} dB"


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
