#!/usr/bin/env python3
"""Unit tests for the rig tuner's McLeod Pitch Method (NSDF) detector.

Mirrors the EXACT algorithm in src/nam_rig_plugin.cpp (process() tuner
block): cascaded RBJ lowpass (Q=0.707, fc=0.45*decimated Nyquist) ->
decimation to ~12 kHz -> NSDF over lag range [kMinTau, kMaxTau] -> first
peak >= 90% of best after the first positive zero-crossing -> parabolic
vertex -> 55-1400 Hz band -> median-of-3.

The 96 kHz session rate is the case that killed v1 (a fixed 1000-sample lag
range put the low E out of range) — both rates are asserted.

Run:  python3 tests/test_tuner_mpm.py   (needs numpy)
"""
import math

import numpy as np

# Tuner constants — must match Tuner struct in src/nam_rig_plugin.h
K_WINDOW = 1024   # analysis window (decimated samples)
K_MAX_TAU = 400   # max lag at ~12 kHz -> floor ~30 Hz
K_MIN_TAU = 8     # min lag -> ceiling ~1500 Hz


def biquad_lowpass_coeffs(fc, fs, q=0.7071067811865476):
    """RBJ Audio EQ Cookbook lowpass — mirrors the coeffs baked in
    tunerSetRates() (alpha = sin(w0)/(2Q), Q hardcoded 0.7071 there)."""
    w0 = 2 * math.pi * fc / fs
    alpha = math.sin(w0) / (2 * q)
    a0 = 1 + alpha
    return {
        "b0": (1 - math.cos(w0)) / 2 / a0,
        "b1": (1 - math.cos(w0)) / a0,
        "b2": (1 - math.cos(w0)) / 2 / a0,
        "a1": -2 * math.cos(w0) / a0,
        "a2": (1 - alpha) / a0,
    }


class Biquad:
    def __init__(self, coeffs):
        self.c = coeffs
        self.reset()

    def reset(self):
        self.x1 = self.x2 = self.y1 = self.y2 = 0.0

    def process(self, x):
        c = self.c
        y = c["b0"] * x + c["b1"] * self.x1 + c["b2"] * self.x2 - c["a1"] * self.y1 - c["a2"] * self.y2
        self.x2, self.x1, self.y2, self.y1 = self.x1, x, self.y1, y
        return y


def tuner_detect(x, host_rate, verbose=False):
    """Full pipeline: LP x2 -> decimate -> NSDF -> pick -> cents. Returns
    (midi, cents) or (None, None) for silence/out-of-band."""
    decim = max(1, round(host_rate / 12000.0))
    dr = host_rate / decim
    fc = 0.45 * dr / 2.0
    lp1 = Biquad(biquad_lowpass_coeffs(fc, dr, 0.7071))
    lp2 = Biquad(biquad_lowpass_coeffs(fc, dr, 0.7071))
    # decimate
    ring = []
    phase = 0
    for s in x:
        y = lp2.process(lp1.process(s))
        phase += 1
        if phase >= decim:
            phase = 0
            ring.append(y)
    win = np.asarray(ring[-(K_WINDOW + K_MAX_TAU):], dtype=np.float64)
    if win.size < K_WINDOW + K_MAX_TAU:
        return None, None
    w = win[:K_WINDOW]
    energy = float(np.sum(w * w))
    rms = math.sqrt(energy / K_WINDOW)
    if rms < 0.003:
        return None, None
    nsdf = np.zeros(K_MAX_TAU + 2)
    for tau in range(K_MIN_TAU, K_MAX_TAU + 1):
        a = w
        b = win[tau:tau + K_WINDOW]
        acf = float(np.dot(a, b))
        m = float(np.dot(a, a) + np.dot(b, b))
        nsdf[tau] = 2 * acf / m if m > 0 else 0.0
    # peaks after first positive zero-crossing
    peaks = []
    crossed = False
    for tau in range(K_MIN_TAU + 1, K_MAX_TAU):
        if not crossed:
            if nsdf[tau - 1] < 0 <= nsdf[tau]:
                crossed = True
            continue
        if nsdf[tau] > nsdf[tau - 1] and nsdf[tau] >= nsdf[tau + 1] and nsdf[tau] > 0:
            peaks.append(tau)
    chosen = -1
    if peaks:
        best = max(nsdf[p] for p in peaks)
        for p in peaks:
            if nsdf[p] >= 0.90 * best:
                chosen = p
                break
    if chosen <= 0:
        return None, None
    s0, s1, s2 = nsdf[chosen - 1], nsdf[chosen], nsdf[chosen + 1]
    tau_f = float(chosen)
    denom = s0 - 2 * s1 + s2
    if denom < -1e-9:
        delta = (s0 - s2) / (2 * denom)
        delta = max(-1.0, min(1.0, delta))
        tau_f += delta
    freq = dr / tau_f
    if not (55.0 <= freq <= 1400.0):
        return None, None
    midi = 69.0 + 12 * math.log2(freq / 440.0)
    nearest = round(midi)
    cents = max(-50.0, min(50.0, (midi - nearest) * 100.0))
    return midi, cents


def synth_guitar(freq, seconds=1.0, rate=96000, harmonics=6, decay=2.0, noise=0.002, seed=0):
    """Synthetic guitar tone: harmonics with exponential decay + pick noise."""
    rng = np.random.default_rng(seed)
    n = int(seconds * rate)
    t = np.arange(n) / rate
    x = np.zeros(n)
    for h in range(1, harmonics + 1):
        amp = 1.0 / h
        x += amp * np.sin(2 * math.pi * freq * h * t) * np.exp(-decay * h * 0.7 * t)
    x += noise * rng.standard_normal(n)
    x /= np.max(np.abs(x)) * 1.1
    return x.astype(np.float32)


def _assert_pitch(name, freq, rate, expected_midi, tol_cents=5.0):
    x = synth_guitar(freq, rate=rate)
    midi, cents = tuner_detect(x, rate)
    assert midi is not None, f"{name}: no pitch detected at {rate} Hz"
    err_cents = abs(midi - expected_midi) * 100
    assert err_cents <= tol_cents, f"{name}: {midi:.2f} vs {expected_midi} ({err_cents:.1f} cents off)"


def test_low_e_48k():
    _assert_pitch("low E 48k", 82.41, 48000, 40.0)  # E2 = MIDI 40


def test_low_e_96k():
    # THE v1 killer: fixed lag range at 96 kHz put low E out of range.
    _assert_pitch("low E 96k", 82.41, 96000, 40.0)


def test_a4_48k():
    _assert_pitch("A4 48k", 440.0, 48000, 69.0)


def test_a4_96k():
    _assert_pitch("A4 96k", 440.0, 96000, 69.0)


def test_high_e_96k():
    _assert_pitch("high E 96k", 329.63, 96000, 64.0)  # E4 = MIDI 64


def test_palm_mute_96k():
    # Palm mute: heavy damping (fast decay), still must track low E.
    x = synth_guitar(82.41, seconds=0.8, rate=96000, harmonics=4, decay=6.0, noise=0.01, seed=3)
    midi, cents = tuner_detect(x, 96000)
    assert midi is not None, "palm mute: no pitch detected"
    assert abs(midi - 40.0) * 100 <= 8.0, f"palm mute: {midi:.2f} vs 40 ({abs(midi-40)*100:.1f} cents)"


def test_silence_reports_none():
    rng = np.random.default_rng(1)
    x = (0.001 * rng.standard_normal(int(0.5 * 96000))).astype(np.float32)  # below RMS gate
    midi, cents = tuner_detect(x, 96000)
    assert midi is None, f"silence must report None, got {midi}"


def test_out_of_band_reports_none():
    # 30 Hz is below the 55 Hz floor -> must report None, not a garbage octave.
    x = synth_guitar(30.0, rate=96000)
    midi, _ = tuner_detect(x, 96000)
    assert midi is None, f"30 Hz must be out of band, got {midi}"


def test_octave_stability():
    # Strong even harmonics can tempt sub-octave picks; the first-peak->=90%
    # rule must keep the fundamental.
    x = synth_guitar(220.0, rate=96000, harmonics=8)
    midi, _ = tuner_detect(x, 96000)
    assert midi is not None
    assert abs(midi - 57.0) * 100 <= 5.0, f"A3 220 Hz: {midi:.2f} vs 57"


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
