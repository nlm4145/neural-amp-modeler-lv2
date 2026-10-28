#!/usr/bin/env python3
"""Audio embedding distance scorer for Axe FX Local Tone Matcher.

Computes cosine distance between learned audio embeddings of a target audio file
and candidate finalist audio files. Supports LAION-CLAP when installed, and
a deterministic mock mode for testing without GPU/PyTorch dependencies.
"""

import argparse
import json
import math
import os
from pathlib import Path
import struct
import sys
import wave


def read_wav_samples(path, max_seconds=10.0):
    """Read mono float samples from a WAV file."""
    try:
        with wave.open(str(path), "rb") as wf:
            channels = wf.getnchannels()
            sampwidth = wf.getsampwidth()
            framerate = wf.getframerate()
            max_frames = int(framerate * max_seconds)
            n_frames = min(wf.getnframes(), max_frames)
            raw = wf.readframes(n_frames)

            if sampwidth == 2:
                fmt = f"<{n_frames * channels}h"
                ints = struct.unpack(fmt, raw)
                scale = 32768.0
            elif sampwidth == 4:
                fmt = f"<{n_frames * channels}i"
                ints = struct.unpack(fmt, raw)
                scale = 2147483648.0
            else:
                return [], framerate

            # Downmix to mono
            samples = []
            for i in range(0, len(ints), channels):
                val = sum(ints[i:i + channels]) / (channels * scale)
                samples.append(val)
            return samples, framerate
    except Exception as e:
        return [], 48000


def mock_embedding(samples, framerate, dim=128):
    """Deterministic, content-aware mock embedding vector for tests."""
    if not samples:
        return [0.0] * dim

    # Compute band energies and zero crossing rate as deterministic embedding
    n = len(samples)
    energy = sum(s * s for s in samples) / max(1, n)
    zcr = sum(1 for i in range(1, n) if (samples[i] >= 0) != (samples[i - 1] >= 0)) / max(1, n)

    vec = [0.0] * dim
    for k in range(dim):
        freq = 80.0 * (2.0 ** (k * 7.0 / dim))
        omega = 2.0 * math.pi * freq / framerate
        cos_sum = sum(samples[i] * math.cos(omega * i) for i in range(0, min(n, 2048)))
        sin_sum = sum(samples[i] * math.sin(omega * i) for i in range(0, min(n, 2048)))
        val = math.sqrt(cos_sum * cos_sum + sin_sum * sin_sum) + (k % 3) * energy + zcr
        vec[k] = val

    # L2 normalize
    norm = math.sqrt(sum(v * v for v in vec))
    if norm > 1e-9:
        vec = [v / norm for v in vec]
    return vec


def cosine_distance(vec_a, vec_b):
    """Cosine distance in [0, 2]. 0 = identical."""
    if not vec_a or not vec_b or len(vec_a) != len(vec_b):
        return 1.0
    dot = sum(a * b for a, b in zip(vec_a, vec_b))
    norm_a = math.sqrt(sum(a * a for a in vec_a))
    norm_b = math.sqrt(sum(b * b for b in vec_b))
    if norm_a < 1e-9 or norm_b < 1e-9:
        return 1.0
    cos_sim = dot / (norm_a * norm_b)
    return max(0.0, min(2.0, 1.0 - cos_sim))


def run_mock(target_path, candidate_paths):
    target_samples, rate = read_wav_samples(target_path)
    target_emb = mock_embedding(target_samples, rate)

    distances = []
    for p in candidate_paths:
        cand_samples, cand_rate = read_wav_samples(p)
        cand_emb = mock_embedding(cand_samples, cand_rate)
        distances.append(round(cosine_distance(target_emb, cand_emb), 4))

    return {
        "status": "ok",
        "model": "mock-spectral",
        "target": str(target_path),
        "distances": distances,
    }


def run_clap(target_path, candidate_paths):
    try:
        import laion_clap
        import torch
    except ImportError:
        return {"status": "error", "message": "laion_clap or torch not installed"}

    try:
        model = laion_clap.CLAP_Module(enable_fusion=False)
        model.load_ckpt()
        with torch.no_grad():
            target_emb = model.get_audio_embedding_from_filelist(x=[str(target_path)])
            cand_embs = model.get_audio_embedding_from_filelist(x=[str(p) for p in candidate_paths])

            # Cosine similarity matrix
            t_norm = target_emb / (torch.norm(target_emb, dim=-1, keepdim=True) + 1e-9)
            c_norm = cand_embs / (torch.norm(cand_embs, dim=-1, keepdim=True) + 1e-9)
            sim = torch.mm(c_norm, t_norm.t()).squeeze(-1)
            distances = [max(0.0, min(2.0, round(float(1.0 - s), 4))) for s in sim]

        return {
            "status": "ok",
            "model": "laion-clap-630k",
            "target": str(target_path),
            "distances": distances,
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}


def main():
    parser = argparse.ArgumentParser(description="Score audio embedding distances.")
    parser.add_argument("--target", required=True, help="Target reference WAV path")
    parser.add_argument("--candidates", nargs="+", required=True, help="Candidate WAV paths")
    parser.add_argument("--mock", action="store_true", help="Force mock embedding mode")
    parser.add_argument("--output", help="Optional output JSON file path")
    args = parser.parse_args()

    target = Path(args.target)
    if not target.exists():
        res = {"status": "error", "message": f"Target file not found: {target}"}
        print(json.dumps(res))
        sys.exit(1)

    candidates = [Path(c) for c in args.candidates]
    for c in candidates:
        if not c.exists():
            res = {"status": "error", "message": f"Candidate file not found: {c}"}
            print(json.dumps(res))
            sys.exit(1)

    if args.mock:
        result = run_mock(target, candidates)
    else:
        # Try real CLAP first, fallback to mock if CLAP is missing
        result = run_clap(target, candidates)
        if result.get("status") == "error" and "not installed" in result.get("message", ""):
            result = run_mock(target, candidates)

    out_json = json.dumps(result, indent=2)
    if args.output:
        Path(args.output).write_text(out_json)
    print(out_json)


if __name__ == "__main__":
    main()
