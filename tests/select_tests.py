#!/usr/bin/env python3
"""Select tests in tests/run_all.sh impacted by changed modules and files.

Supports automatic git change detection (working tree changes first, then branch
commits ahead of upstream/main), explicit refs via --base/--working/--staged/--branch,
explicit path arguments via --files, and --all for full runs.
"""

from __future__ import annotations

import argparse
import dataclasses
import functools
import json
import os
import pathlib
import platform
import re
import subprocess
import sys
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUN_ALL_PATH = ROOT / "tests" / "run_all.sh"

IGNORED_FILENAMES = {".DS_Store"}
IGNORED_DIR_PARTS = {"__pycache__", ".git", ".pytest_cache"}
IGNORED_SUFFIXES = (".pyc", ".pyo", ".swp", ".tmp")
IGNORED_TOP_DIRS = ("build/", "build-", "Testing/")

INCLUDE_RE = re.compile(r'^\s*#(?:include|import)\s+"([^"]+)"', re.MULTILINE)
PATH_LITERAL_RE = re.compile(
    r"(?:src|resources|scripts|deps|tests)/[A-Za-z0-9_./-]+"
)
JOIN_RE = re.compile(
    r"""ROOT(?:\s*/\s*["']([^"']+)["'])+"""
)
BARE_ROOT_FILE_RE = re.compile(
    r"""ROOT\s*/\s*["'](build\.sh|CMakeLists\.txt)["']"""
)
PY_TEST_IMPORT_RE = re.compile(
    r"^\s*(?:from|import)\s+(test_[A-Za-z0-9_]+)\b", re.MULTILINE
)
RUN_ALL_SOURCE_ARG_RE = re.compile(
    r"(?<![A-Za-z0-9_./-])((?:src|tests)/[A-Za-z0-9_./-]+\.(?:c|cpp|mm|h|hpp))\b"
)


@dataclasses.dataclass(frozen=True)
class HarnessSpec:
    """Metadata for a compiled C/C++/ObjC++ harness invoked by tests/run_all.sh."""

    test_id: str
    category: str  # "unit_cpp", "darwin_accel", "rig_so", "rig_ui_so"
    darwin_only: bool = False
    requires_rig_so: bool = False
    requires_rig_ui_so: bool = False
    extra_triggers: Tuple[str, ...] = ()
    mirrors_only: bool = False


# Ordered to match execution order in tests/run_all.sh.
HARNESS_SPECS: Tuple[HarnessSpec, ...] = (
    # Cross-platform C++ unit harnesses
    HarnessSpec("tests/verify_tuner_tools.cpp", "unit_cpp"),
    HarnessSpec("tests/verify_standalone_worker.cpp", "unit_cpp"),
    HarnessSpec("tests/verify_standalone_controls.cpp", "unit_cpp"),
    HarnessSpec(
        "tests/verify_rig_control_metadata.cpp",
        "unit_cpp",
        extra_triggers=(
            "resources/neural_amp_modeler_rig.ttl.in",
            "scripts/generate_rig_control_contract.py",
        ),
    ),
    HarnessSpec("tests/verify_noise_gate.cpp", "unit_cpp"),
    HarnessSpec("tests/verify_master_output.cpp", "unit_cpp"),
    HarnessSpec("tests/verify_compressor.cpp", "unit_cpp"),
    HarnessSpec("tests/verify_output_transformer.cpp", "unit_cpp"),
    HarnessSpec("tests/verify_speaker_dynamics.cpp", "unit_cpp"),
    HarnessSpec("tests/verify_amp_advanced.cpp", "unit_cpp"),
    HarnessSpec("tests/verify_overdrive.cpp", "unit_cpp"),
    HarnessSpec("tests/verify_drop_pitch.cpp", "unit_cpp"),
    HarnessSpec("tests/verify_model_band_limit.cpp", "unit_cpp"),
    HarnessSpec("tests/verify_rate_adapter.cpp", "unit_cpp"),
    HarnessSpec("tests/verify_pin_eq.cpp", "unit_cpp"),
    HarnessSpec("tests/verify_tone_eq_link.cpp", "unit_cpp"),
    HarnessSpec("tests/verify_control_work.cpp", "unit_cpp"),
    HarnessSpec("tests/verify_rig_dsp_cache.cpp", "unit_cpp"),
    HarnessSpec("tests/verify_space_fx.cpp", "unit_cpp"),
    HarnessSpec("tests/verify_oversample_modes.cpp", "unit_cpp"),
    # Darwin Accelerate + transition fade harnesses
    HarnessSpec("tests/verify_oversample_shared.cpp", "darwin_accel", darwin_only=True),
    HarnessSpec("tests/verify_oversample_cpp.cpp", "darwin_accel", darwin_only=True),
    HarnessSpec(
        "tests/verify_transition_fade.cpp",
        "unit_cpp",
        extra_triggers=("src/nam_rig_plugin.cpp", "src/oversample.h"),
    ),
    HarnessSpec("tests/verify_oversample_batched.cpp", "darwin_accel", darwin_only=True),
    HarnessSpec("tests/verify_oversample_cascade.cpp", "darwin_accel", darwin_only=True),
    HarnessSpec("tests/verify_oversample_latency.cpp", "darwin_accel", darwin_only=True),
    HarnessSpec("tests/verify_wav_ir.cpp", "darwin_accel", darwin_only=True),
    HarnessSpec(
        "tests/verify_nsdf.cpp",
        "darwin_accel",
        darwin_only=True,
        extra_triggers=("src/nam_rig_plugin.cpp", "src/tuner_tools.h", "src/tuner_protocol.h"),
    ),
    # RIG_SO integration harnesses (explicit module coverage to avoid hub-header over-triggering)
    HarnessSpec(
        "tests/verify_host_smoke.c",
        "rig_so",
        requires_rig_so=True,
        mirrors_only=True,
        extra_triggers=(
            "CMakeLists.txt",
            "build.sh",
            "src/CMakeLists.txt",
            "resources/neural_amp_modeler_rig.ttl.in",
            "src/nam_rig_plugin.cpp",
            "src/nam_rig_plugin.h",
            "src/nam_rig_lv2.cpp",
            "src/dynamics.h",
            "src/master_output.h",
            "src/rack_controls.h",
            "src/rig_control_contract.h",
            "src/standalone_worker.cpp",
            "src/standalone_worker.h",
            "src/cabinet_worker.cpp",
            "src/cabinet_worker.h",
            "src/polyphase_worker.h",
            "src/oversample.cpp",
            "src/oversample.h",
            "src/oversample_modes.h",
            "src/wav_ir.cpp",
            "src/wav_ir.h",
            "deps/NeuralAudio/NeuralAudio/",
            "deps/NeuralAudio/deps/NeuralAmpModelerCore/",
            "deps/NeuralAudio/deps/RTNeural/",
            "deps/NeuralAudio/deps/math_approx/",
        ),
    ),
    HarnessSpec(
        "tests/verify_low_buffer_rig.cpp",
        "rig_so",
        darwin_only=True,
        requires_rig_so=True,
        mirrors_only=True,
        extra_triggers=(
            "src/CMakeLists.txt",
            "src/nam_rig_plugin.cpp",
            "src/nam_rig_plugin.h",
            "src/nam_rig_lv2.cpp",
            "src/dynamics.h",
            "src/master_output.h",
            "src/rack_controls.h",
            "src/rig_dsp_cache.h",
            "src/oversample.cpp",
            "src/oversample.h",
            "src/oversample_modes.h",
            "src/dsp_accel.cpp",
            "src/dsp_accel.h",
            "src/win32_control_defaults.h",
            "deps/NeuralAudio/NeuralAudio/NeuralModel.h",
        ),
    ),
    HarnessSpec(
        "tests/verify_rate_adapted_rig.cpp",
        "rig_so",
        darwin_only=True,
        requires_rig_so=True,
        mirrors_only=True,
        extra_triggers=(
            "src/nam_rig_plugin.cpp",
            "src/nam_rig_plugin.h",
            "src/rate_adapter.h",
            "src/standalone_worker.cpp",
            "src/standalone_worker.h",
            "src/cabinet_worker.cpp",
            "src/cabinet_worker.h",
            "src/wav_ir.cpp",
            "src/wav_ir.h",
            "src/oversample.cpp",
            "src/oversample.h",
            "src/oversample_modes.h",
            "src/model_band_limit.h",
            "src/win32_control_defaults.h",
            "deps/NeuralAudio/NeuralAudio/",
            "deps/NeuralAudio/deps/NeuralAmpModelerCore/",
            "deps/NeuralAudio/deps/RTNeural/",
        ),
    ),
    HarnessSpec(
        "tests/verify_lstm_oversampling.cpp",
        "rig_so",
        darwin_only=True,
        requires_rig_so=True,
        mirrors_only=True,
        extra_triggers=(
            "src/nam_rig_plugin.cpp",
            "src/nam_rig_plugin.h",
            "src/oversample.cpp",
            "src/oversample.h",
            "src/oversample_modes.h",
            "src/dsp_accel.cpp",
            "src/dsp_accel.h",
            "src/standalone_worker.cpp",
            "src/standalone_worker.h",
            "src/model_band_limit.h",
            "src/win32_control_defaults.h",
            "deps/NeuralAudio/NeuralAudio/",
            "deps/NeuralAudio/deps/NeuralAmpModelerCore/NAM/lstm",
            "deps/NeuralAudio/deps/RTNeural/",
        ),
    ),
    HarnessSpec(
        "tests/verify_tuner_tools_dsp.c",
        "rig_so",
        requires_rig_so=True,
        mirrors_only=True,
        extra_triggers=(
            "tests/verify_tuner.c",
            "src/nam_rig_plugin.cpp",
            "src/nam_rig_plugin.h",
            "src/tuner_protocol.h",
            "src/tuner_tools.h",
        ),
    ),
    HarnessSpec(
        "tests/verify_tuner.c",
        "rig_so",
        requires_rig_so=True,
        mirrors_only=True,
        extra_triggers=(
            "src/nam_rig_plugin.cpp",
            "src/nam_rig_plugin.h",
            "src/tuner_protocol.h",
            "src/tuner_tools.h",
        ),
    ),
    HarnessSpec(
        "tests/verify_transformer_switch.cpp",
        "rig_so",
        darwin_only=False,
        requires_rig_so=True,
        mirrors_only=True,
        extra_triggers=(
            "src/nam_rig_plugin.cpp",
            "src/nam_rig_plugin.h",
            "src/output_transformer.h",
            "src/transformer_controls.h",
            "src/power_tube_controls.h",
            "src/rack_controls.h",
            "src/oversample.cpp",
            "src/oversample.h",
            "src/oversample_modes.h",
            "src/dsp_accel.cpp",
            "src/dsp_accel.h",
            "src/standalone_worker.cpp",
            "src/standalone_worker.h",
            "deps/NeuralAudio/NeuralAudio/",
            "deps/NeuralAudio/deps/NeuralAmpModelerCore/",
            "deps/NeuralAudio/deps/RTNeural/",
        ),
    ),
    HarnessSpec(
        "tests/verify_transformer_controls.cpp",
        "rig_so",
        darwin_only=False,
        requires_rig_so=True,
        mirrors_only=True,
        extra_triggers=(
            "src/nam_rig_plugin.cpp",
            "src/nam_rig_plugin.h",
            "src/output_transformer.h",
            "src/transformer_controls.h",
            "src/power_tube_controls.h",
            "src/rack_controls.h",
            "src/rig_control_metadata.h",
        ),
    ),
    HarnessSpec(
        "tests/verify_stage_db_meters.cpp",
        "rig_so",
        darwin_only=False,
        requires_rig_so=True,
        mirrors_only=True,
        extra_triggers=(
            "src/nam_rig_plugin.cpp",
            "src/nam_rig_plugin.h",
            "src/tuner_protocol.h",
            "src/dynamics.h",
            "src/overdrive.h",
            "src/pin_eq.h",
            "src/output_transformer.h",
            "src/speaker_dynamics.h",
            "src/space_fx.h",
            "src/master_output.h",
            "src/rack_controls.h",
        ),
    ),
    HarnessSpec(
        "tests/verify_rack_bypass.cpp",
        "rig_so",
        darwin_only=False,
        requires_rig_so=True,
        mirrors_only=True,
        extra_triggers=(
            "src/nam_rig_plugin.cpp",
            "src/nam_rig_plugin.h",
            "src/rack_controls.h",
            "src/cabinet_worker.cpp",
            "src/cabinet_worker.h",
            "src/wav_ir.cpp",
            "src/wav_ir.h",
            "src/ir_normalization.h",
            "src/align_delay_table.h",
            "src/oversample.cpp",
            "src/oversample.h",
            "src/space_fx.h",
            "src/amp_advanced.h",
            "src/speaker_dynamics.h",
            "src/output_transformer.h",
            "src/dynamics.h",
            "src/overdrive.h",
            "src/pin_eq.h",
            "src/local_tone_post_eq.h",
        ),
    ),
    HarnessSpec(
        "tests/verify_spatial_stereo.cpp",
        "rig_so",
        darwin_only=True,
        requires_rig_so=True,
        mirrors_only=True,
        extra_triggers=(
            "src/nam_rig_plugin.cpp",
            "src/nam_rig_plugin.h",
            "src/spatial_stereo.h",
            "src/cabinet_worker.cpp",
            "src/cabinet_worker.h",
            "src/wav_ir.cpp",
            "src/wav_ir.h",
            "src/dsp_accel.cpp",
            "src/dsp_accel.h",
            "src/align_delay_table.h",
            "src/win32_control_defaults.h",
        ),
    ),
    # Optional RIG_UI_SO integration harness
    HarnessSpec(
        "tests/verify_transformer_ui.mm",
        "rig_ui_so",
        darwin_only=True,
        requires_rig_ui_so=True,
        mirrors_only=True,
        extra_triggers=(
            "src/nam_rig_ui.mm",
            "src/rig_ui_state.h",
            "src/rig_knobs.cpp",
            "src/rig_knobs.h",
            "src/rig_theme.mm",
            "src/rig_theme.h",
            "src/rig_profile_catalog.mm",
            "src/rig_profile_catalog.h",
            "src/overdrive.h",
            "src/output_transformer.h",
            "src/transformer_controls.h",
            "src/power_tube_controls.h",
            "src/rig_control_contract.h",
            "src/rig_presets.mm",
            "src/rig_presets.h",
        ),
    ),
)

# Extra module/mirror mappings for tests whose coverage extends beyond literal path strings.
PYTHON_EXTRA_TRIGGERS: Dict[str, Tuple[str, ...]] = {
    "tests/test_ai_tone.py": (
        "resources/neural_amp_modeler_rig.ttl.in",
        "src/rig_ai_copilot.h",
        "src/rig_ai_model_catalog.h",
        "src/rig_ai_support.h",
        "src/rig_local_server.h",
        "src/rig_local_server.mm",
        "src/rig_ui_state.h",
    ),
    "tests/test_local_tone_matcher.py": (
        "src/rig_local_tone_matcher.h",
        "src/local_tone_align.h",
        "src/local_tone_learning.h",
        "src/local_tone_post_eq.h",
        "src/rig_riff_recorder.h",
        "src/rig_riff_renderer.h",
        "src/rig_riff_renderer.mm",
        "src/wav_ir.h",
        "src/dsp_accel.h",
        "src/rig_ai_support.h",
        "src/rig_control_metadata.h",
    ),
    "tests/test_oversample_2x.py": (
        "src/oversample.cpp",
        "src/oversample.h",
        "src/dsp_accel.cpp",
        "src/dsp_accel.h",
    ),
    "tests/test_oversample_batched.py": (
        "src/oversample.cpp",
        "src/oversample.h",
        "src/dsp_accel.cpp",
        "src/dsp_accel.h",
        "tests/test_oversample_2x.py",
    ),
    "tests/test_power_tube_contract.py": (
        "scripts/generate_rig_control_contract.py",
        "src/rig_control_contract.h",
    ),
    "tests/test_presets_contract.py": (
        "CMakeLists.txt",
        "build.sh",
        "src/CMakeLists.txt",
        "resources/standalone-Info.plist.in",
        "resources/AxeFX.icns",
        "resources/AxeFX.png",
        "resources/neural_amp_modeler_rig_ui.ttl.in",
        "scripts/generate_rig_control_contract.py",
        "src/rig_control_contract.h",
        "src/rig_tone_api.h",
        "src/rig_tone_api.mm",
        "src/nam_rig_plugin.cpp",
        "src/nam_rig_plugin.h",
    ),
    "tests/test_rack_controls_contract.py": (
        "scripts/generate_rig_control_contract.py",
        "src/rig_control_contract.h",
    ),
    "tests/test_select_tests.py": (
        "tests/select_tests.py",
        "tests/run_all.sh",
    ),
    "tests/test_transformer_controls_contract.py": (
        "scripts/generate_rig_control_contract.py",
        "src/rig_control_contract.h",
    ),
    "tests/test_tuner_mpm.py": (
        "src/nam_rig_plugin.cpp",
        "src/nam_rig_plugin.h",
        "src/tuner_tools.h",
        "src/tuner_protocol.h",
    ),
    "tests/test_wav_ir_resample.py": (
        "src/wav_ir.cpp",
        "src/wav_ir.h",
        "src/dsp_accel.cpp",
        "src/dsp_accel.h",
        "tests/verify_wav_ir.cpp",
    ),
    "tests/test_win32_audio_stop.py": (
        "src/win32_audio.cpp",
        "src/win32_audio.h",
        "src/win32_asio.h",
        "src/standalone_main_win32.cpp",
    ),
    "tests/test_win32_stage_db_meters.py": (
        "src/rig_control_contract.h",
    ),
}

# Manual / CMake EXCLUDE_FROM_ALL harnesses outside run_all.sh (surfaced as advisory notes).
MANUAL_HARNESS_HINTS: Dict[str, Tuple[str, ...]] = {
    "src/cabinet_worker.cpp": ("tests/verify_cabinet_worker.cpp (manual Mach deadline test)",),
    "src/cabinet_worker.h": ("tests/verify_cabinet_worker.cpp (manual Mach deadline test)",),
    "tests/verify_cabinet_worker.cpp": ("tests/verify_cabinet_worker.cpp (manual Mach deadline test)",),
    "src/polyphase_worker.h": (
        "CMake target verify_parallel_polyphase",
        "CMake target verify_parallel_cabs",
    ),
    "tests/verify_parallel_polyphase.cpp": ("CMake target verify_parallel_polyphase",),
    "tests/verify_parallel_cabs.cpp": ("CMake target verify_parallel_cabs",),
    "tests/verify_polyphase_model.cpp": ("CMake target verify_polyphase_model",),
    "src/rig_riff_renderer.mm": ("CMake target verify_riff_renderer",),
    "src/rig_riff_renderer.h": ("CMake target verify_riff_renderer",),
    "tests/verify_riff_renderer.mm": ("CMake target verify_riff_renderer",),
    "src/rig_tone_api.mm": ("tests/verify_tone3000_fetch.mm (manual Tone3000 API test)",),
    "tests/verify_tone3000_fetch.mm": ("tests/verify_tone3000_fetch.mm (manual Tone3000 API test)",),
    "tests/verify_ai_tone_tab.mm": ("tests/verify_ai_tone_tab.mm (manual WindowServer + RIG_UI_SO test)",),
    "tests/verify_model_loads.cpp": ("tests/verify_model_loads.cpp (manual <rig.so> <pedal> <amp> <ir> test)",),
}


@dataclasses.dataclass
class SelectionResult:
    """Computed test plan and diagnostics."""

    mode: str
    detection_detail: str
    changed_files: List[str]
    selected_tests: List[str]
    reasons: Dict[str, List[str]]
    notes: List[str]
    unmapped_files: List[str]
    all_tests: List[str]


def _normalize_rel_path(path: str, root: pathlib.Path = ROOT) -> str:
    """Normalize a repo-relative or cwd-relative path to POSIX repo-relative form."""
    cleaned = path.strip().replace("\\", "/")
    if not cleaned:
        return ""
    candidate = pathlib.Path(cleaned)
    if candidate.is_absolute():
        try:
            cleaned = candidate.resolve().relative_to(root.resolve()).as_posix()
        except ValueError:
            cleaned = candidate.as_posix()
    else:
        cwd = pathlib.Path.cwd().resolve()
        root_resolved = root.resolve()
        if cwd != root_resolved and (cwd / candidate).exists():
            try:
                cleaned = (cwd / candidate).resolve().relative_to(root_resolved).as_posix()
            except ValueError:
                pass
    while cleaned.startswith("./"):
        cleaned = cleaned[2:]
    return cleaned.rstrip("/") if cleaned.endswith("/") and cleaned not in {
        "deps/NeuralAudio/NeuralAudio/",
        "deps/NeuralAudio/deps/NeuralAmpModelerCore/",
        "deps/NeuralAudio/deps/RTNeural/",
        "deps/NeuralAudio/deps/math_approx/",
    } else cleaned


def is_ignored_path(rel_path: str) -> bool:
    """Return True for build outputs, caches, and OS metadata."""
    if not rel_path:
        return True
    p = pathlib.PurePosixPath(rel_path)
    if p.name in IGNORED_FILENAMES:
        return True
    if any(part in IGNORED_DIR_PARTS for part in p.parts):
        return True
    if rel_path.endswith(IGNORED_SUFFIXES):
        return True
    return any(rel_path.startswith(prefix) or rel_path == prefix.rstrip("/") for prefix in IGNORED_TOP_DIRS)


def _run_git(cwd: pathlib.Path, args: Sequence[str], check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        capture_output=True,
        text=True,
        check=check,
    )


def _parse_submodule_paths(root: pathlib.Path) -> List[str]:
    gitmodules = root / ".gitmodules"
    if not gitmodules.is_file():
        return []
    text = gitmodules.read_text(encoding="utf-8", errors="replace")
    return [m.strip().rstrip("/") for m in re.findall(r"^\s*path\s*=\s*(.+)$", text, re.MULTILINE)]


def _expand_submodule_working_changes(
    root: pathlib.Path, submodule: str, include_staged: bool, include_unstaged: bool
) -> List[str]:
    sub_root = root / submodule
    if not (sub_root / ".git").exists():
        return [submodule]
    paths: Set[str] = set()
    if include_staged and include_unstaged:
        res = _run_git(sub_root, ["diff", "--name-only", "HEAD"])
        if res.returncode == 0:
            paths.update(line.strip() for line in res.stdout.splitlines() if line.strip())
    else:
        if include_staged:
            res = _run_git(sub_root, ["diff", "--name-only", "--cached"])
            if res.returncode == 0:
                paths.update(line.strip() for line in res.stdout.splitlines() if line.strip())
        if include_unstaged:
            res = _run_git(sub_root, ["diff", "--name-only"])
            if res.returncode == 0:
                paths.update(line.strip() for line in res.stdout.splitlines() if line.strip())
    if include_unstaged:
        untracked = _run_git(sub_root, ["ls-files", "--others", "--exclude-standard"])
        if untracked.returncode == 0:
            paths.update(line.strip() for line in untracked.stdout.splitlines() if line.strip())
    if not paths:
        # Submodule HEAD changed (detached vs superproject gitlink) without dirty files inside it.
        gitlink = _run_git(root, ["diff", "--raw", "HEAD", "--", submodule])
        if gitlink.returncode == 0:
            for line in gitlink.stdout.splitlines():
                m = re.match(r"^:\d+\s+\d+\s+([0-9a-f]+)\s+([0-9a-f]+)\s+", line)
                if m and m.group(1) != m.group(2):
                    sub_diff = _run_git(sub_root, ["diff", "--name-only", m.group(1), m.group(2)])
                    if sub_diff.returncode == 0:
                        paths.update(x.strip() for x in sub_diff.stdout.splitlines() if x.strip())
    if not paths:
        return [submodule]
    return sorted(f"{submodule}/{p}" for p in paths)


def _expand_submodule_range_changes(
    root: pathlib.Path, submodule: str, old_ref: str, new_ref: Optional[str]
) -> List[str]:
    """Expand superproject gitlink change across two commits into submodule file paths."""
    sub_root = root / submodule
    if not (sub_root / ".git").exists():
        return [submodule]
    args = ["diff", "--raw", old_ref]
    if new_ref:
        args.append(new_ref)
    args.extend(["--", submodule])
    raw = _run_git(root, args)
    paths: Set[str] = set()
    if raw.returncode == 0:
        for line in raw.stdout.splitlines():
            m = re.match(r"^:\d+\s+160000\s+([0-9a-f]+)\s+([0-9a-f]+)\s+", line)
            if m and not re.fullmatch(r"0+", m.group(1)):
                old_sha = m.group(1)
                new_sha = m.group(2)
                if re.fullmatch(r"0+", new_sha):
                    paths.update(_expand_submodule_working_changes(root, submodule, True, True))
                else:
                    sub_diff = _run_git(sub_root, ["diff", "--name-only", old_sha, new_sha])
                    if sub_diff.returncode == 0:
                        paths.update(x.strip() for x in sub_diff.stdout.splitlines() if x.strip())
    if not paths:
        return _expand_submodule_working_changes(root, submodule, True, True)
    return sorted(f"{submodule}/{p}" for p in paths)


def _resolve_branch_base(root: pathlib.Path) -> Optional[Tuple[str, str]]:
    """Return (base_sha, label) comparing HEAD against upstream or main/master."""
    upstream = _run_git(root, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
    candidates: List[Tuple[str, str]] = []
    if upstream.returncode == 0 and upstream.stdout.strip():
        up_ref = upstream.stdout.strip()
        candidates.append((up_ref, f"@{up_ref}"))
    for branch_ref in ("main", "master", "origin/main", "origin/master"):
        check = _run_git(root, ["rev-parse", "--verify", "--quiet", branch_ref])
        if check.returncode == 0:
            candidates.append((branch_ref, branch_ref))

    head_sha = _run_git(root, ["rev-parse", "--verify", "--quiet", "HEAD"])
    head = head_sha.stdout.strip() if head_sha.returncode == 0 else ""

    for ref, label in candidates:
        mb = _run_git(root, ["merge-base", "HEAD", ref])
        if mb.returncode == 0 and mb.stdout.strip():
            base_sha = mb.stdout.strip()
            if base_sha != head:
                return base_sha, f"branch commits vs {label} ({base_sha[:8]})"
    return None


def _collect_git_paths(root: pathlib.Path, args: Sequence[str], submodules: Set[str]) -> Set[str]:
    res = _run_git(root, args)
    if res.returncode != 0:
        return set()
    collected: Set[str] = set()
    for raw_line in res.stdout.splitlines():
        path = _normalize_rel_path(raw_line, root)
        if not path or is_ignored_path(path):
            continue
        collected.add(path)
    return collected


def detect_changed_files(
    root: pathlib.Path = ROOT,
    mode: str = "auto",
    base_ref: Optional[str] = None,
    explicit_files: Optional[Sequence[str]] = None,
) -> Tuple[List[str], str]:
    """Detect changed files in repo according to mode and return (files, description)."""
    if mode == "files":
        files = sorted(
            {
                _normalize_rel_path(f, root)
                for f in (explicit_files or [])
                if _normalize_rel_path(f, root) and not is_ignored_path(_normalize_rel_path(f, root))
            }
        )
        return files, "explicit --files"

    submodules = set(_parse_submodule_paths(root))

    def finish(paths: Set[str], expand_mode: str, old_ref: Optional[str] = None, new_ref: Optional[str] = None) -> Set[str]:
        expanded: Set[str] = set()
        for p in paths:
            if p in submodules:
                if expand_mode == "range" and old_ref:
                    expanded.update(_expand_submodule_range_changes(root, p, old_ref, new_ref))
                elif expand_mode == "staged":
                    expanded.update(_expand_submodule_working_changes(root, p, True, False))
                else:
                    expanded.update(_expand_submodule_working_changes(root, p, True, True))
            else:
                expanded.add(p)
        return {p for p in expanded if not is_ignored_path(p)}

    if mode == "staged":
        paths = _collect_git_paths(root, ["diff", "--name-only", "--cached"], submodules)
        return sorted(finish(paths, "staged")), "staged index changes"

    if mode == "working":
        paths = _collect_git_paths(root, ["diff", "--name-only", "HEAD"], submodules)
        paths.update(_collect_git_paths(root, ["ls-files", "--others", "--exclude-standard"], submodules))
        for sub in submodules:
            if sub not in paths and (root / sub / ".git").exists():
                sub_dirty = _run_git(root / sub, ["status", "--porcelain"])
                if sub_dirty.returncode == 0 and sub_dirty.stdout.strip():
                    paths.add(sub)
        return sorted(finish(paths, "working")), "working tree (staged + unstaged + untracked vs HEAD)"

    if mode == "branch":
        resolved = _resolve_branch_base(root)
        if not resolved:
            return [], "branch (no commits ahead of upstream/main)"
        base_sha, label = resolved
        paths = _collect_git_paths(root, ["diff", "--name-only", base_sha, "HEAD"], submodules)
        return sorted(finish(paths, "range", base_sha, "HEAD")), label

    if mode == "base":
        assert base_ref is not None
        if ".." in base_ref:
            left, right = base_ref.split("..", 1)
            if base_ref.count("...") == 1:
                left, right = base_ref.split("...", 1)
                mb = _run_git(root, ["merge-base", left or "HEAD", right or "HEAD"])
                old_ref = mb.stdout.strip() if mb.returncode == 0 else left
            else:
                old_ref = left
            new_ref = right or "HEAD"
            paths = _collect_git_paths(root, ["diff", "--name-only", old_ref, new_ref], submodules)
            return sorted(finish(paths, "range", old_ref, new_ref)), f"git range {base_ref}"
        mb = _run_git(root, ["merge-base", "HEAD", base_ref])
        compare_ref = mb.stdout.strip() if mb.returncode == 0 and mb.stdout.strip() else base_ref
        paths = _collect_git_paths(root, ["diff", "--name-only", compare_ref], submodules)
        paths.update(_collect_git_paths(root, ["ls-files", "--others", "--exclude-standard"], submodules))
        for sub in submodules:
            if sub not in paths and (root / sub / ".git").exists():
                sub_dirty = _run_git(root / sub, ["status", "--porcelain"])
                if sub_dirty.returncode == 0 and sub_dirty.stdout.strip():
                    paths.add(sub)
        return sorted(finish(paths, "range", compare_ref, None)), f"changes vs {base_ref} ({compare_ref[:8]}) + working tree"

    # mode == "auto"
    working_files, working_desc = detect_changed_files(root=root, mode="working")
    if working_files:
        return working_files, f"auto -> {working_desc}"
    branch_files, branch_desc = detect_changed_files(root=root, mode="branch")
    if branch_files:
        return branch_files, f"auto -> {branch_desc}"
    return [], "auto (clean working tree and no commits ahead of upstream/main)"


@functools.lru_cache(maxsize=None)
def _parse_run_all_extra_sources(root_str: str) -> Dict[str, Set[str]]:
    """Parse extra C/C++/ObjC++ sources compiled with each harness in tests/run_all.sh."""
    root = pathlib.Path(root_str)
    run_all = root / "tests" / "run_all.sh"
    mapping: Dict[str, Set[str]] = {}
    if not run_all.is_file():
        return mapping
    # Join backslash-continued shell commands cleanly.
    raw_lines = run_all.read_text(encoding="utf-8", errors="replace").splitlines()
    commands: List[str] = []
    buf = ""
    for line in raw_lines:
        stripped = line.rstrip()
        if stripped.endswith("\\"):
            buf += stripped[:-1] + " "
        else:
            buf += stripped
            commands.append(buf)
            buf = ""
    if buf:
        commands.append(buf)

    for cmd in commands:
        matches = RUN_ALL_SOURCE_ARG_RE.findall(cmd)
        if not matches:
            continue
        harnesses = list(dict.fromkeys(m for m in matches if m.startswith("tests/verify_")))
        if len(harnesses) != 1:
            continue
        harness = harnesses[0]
        mapping.setdefault(harness, set()).update(matches)
    return mapping


def _resolve_include(including_file: pathlib.Path, include_arg: str, root: pathlib.Path) -> Optional[str]:
    """Resolve a local #include \"...\" path to a repo-relative file path if inside repo."""
    candidates = [
        including_file.parent / include_arg,
        root / "src" / include_arg,
        root / "tests" / include_arg,
        root / include_arg,
        root / "deps" / "NeuralAudio" / include_arg,
        root / "deps" / "lv2" / "include" / include_arg,
        root / "deps" / "pffft" / include_arg,
    ]
    for cand in candidates:
        if cand.is_file():
            try:
                return cand.resolve().relative_to(root.resolve()).as_posix()
            except ValueError:
                return None
    return None


@functools.lru_cache(maxsize=None)
def _direct_local_includes(rel_path: str, root_str: str) -> Tuple[str, ...]:
    root = pathlib.Path(root_str)
    file_path = root / rel_path
    if not file_path.is_file():
        return ()
    text = file_path.read_text(encoding="utf-8", errors="replace")
    resolved: List[str] = []
    for inc in INCLUDE_RE.findall(text):
        target = _resolve_include(file_path, inc, root)
        if target and target not in resolved:
            resolved.append(target)
    return tuple(resolved)


def _transitive_include_closure(seed_paths: Iterable[str], root: pathlib.Path) -> Set[str]:
    """Collect transitive local #include/#import closure starting from seed_paths."""
    closure: Set[str] = set()
    queue = list(seed_paths)
    root_str = str(root)
    while queue:
        current = queue.pop()
        if current in closure:
            continue
        closure.add(current)
        for inc in _direct_local_includes(current, root_str):
            if inc not in closure:
                queue.append(inc)
    return closure


def discover_python_tests(root: pathlib.Path = ROOT) -> List[str]:
    """Discover all tests/test_*.py scripts sorted in run_all.sh execution order."""
    priority = [
        "tests/test_max_quality_defaults.py",
        "tests/test_stage_db_meters.py",
        "tests/test_a2_fast_ring_copy.py",
    ]
    found = [p.relative_to(root).as_posix() for p in sorted((root / "tests").glob("test_*.py"))]
    ordered = [p for p in priority if p in found]
    ordered.extend(p for p in found if p not in ordered)
    return ordered


# Meta-tests whose string literals are test fixtures rather than dependencies.
EXPLICIT_ONLY_PYTHON_TESTS: Set[str] = {"tests/test_select_tests.py"}


def _extract_python_test_refs(test_rel: str, root: pathlib.Path, seen: Optional[Set[str]] = None) -> Set[str]:
    """Extract repo files inspected or compiled by a Python test script."""
    if seen is None:
        seen = set()
    if test_rel in seen:
        return set()
    seen.add(test_rel)

    test_path = root / test_rel
    deps: Set[str] = {test_rel}
    deps.update(PYTHON_EXTRA_TRIGGERS.get(test_rel, ()))
    if test_rel in EXPLICIT_ONLY_PYTHON_TESTS or not test_path.is_file():
        return deps

    text = test_path.read_text(encoding="utf-8", errors="replace")

    for match in PATH_LITERAL_RE.findall(text):
        cleaned = match.rstrip(".,:;'\")")
        if "..." in cleaned or cleaned.endswith("/"):
            continue
        if (root / cleaned).exists() or cleaned.startswith(("src/", "resources/", "scripts/", "tests/")):
            deps.add(cleaned)

    for full_match in JOIN_RE.finditer(text):
        parts = re.findall(r"""["']([^"']+)["']""", full_match.group(0))
        joined = "/".join(parts)
        if joined and (root / joined).exists():
            deps.add(joined)

    for m in BARE_ROOT_FILE_RE.findall(text):
        if (root / m).exists():
            deps.add(m)

    # Recursively include sibling test_*.py imports (e.g., test_oversample_batched -> test_oversample_2x).
    for mod in PY_TEST_IMPORT_RE.findall(text):
        sibling = f"tests/{mod}.py"
        if (root / sibling).is_file():
            deps.update(_extract_python_test_refs(sibling, root, seen))

    # Any helper verify_* harness invoked inside a Python test pulls in its C/C++/ObjC++ closure.
    verify_seeds = {d for d in deps if d.startswith("tests/verify_") and (root / d).is_file()}
    if verify_seeds:
        deps.update(_transitive_include_closure(verify_seeds, root))

    return deps


def _harness_dependencies(spec: HarnessSpec, root: pathlib.Path) -> Set[str]:
    """Compute dependency file/prefix set for a HarnessSpec."""
    deps: Set[str] = {spec.test_id}
    deps.update(spec.extra_triggers)
    if not spec.mirrors_only:
        seeds: Set[str] = {spec.test_id}
        seeds.update(_parse_run_all_extra_sources(str(root)).get(spec.test_id, set()))
        deps.update(_transitive_include_closure(seeds, root))
    return deps


def _match_trigger(changed_file: str, dependency: str) -> bool:
    """Return True if changed_file hits exact dependency path or directory/stem prefix."""
    if changed_file == dependency:
        return True
    if dependency.endswith("/") and changed_file.startswith(dependency):
        return True
    if dependency.endswith("/lstm") and changed_file.startswith(dependency):
        return True
    return False


def _match_reasons(changed_files: Sequence[str], deps: Set[str]) -> List[str]:
    reasons: List[str] = []
    for cf in changed_files:
        for dep in deps:
            if _match_trigger(cf, dep):
                if cf == dep:
                    reasons.append(cf)
                else:
                    reasons.append(f"{cf} (via {dep})")
                break
    return reasons


def build_dependency_map(
    root: pathlib.Path = ROOT, include_rig_ui_so: bool = False, os_name: Optional[str] = None
) -> List[Tuple[str, Set[str]]]:
    """Return ordered list of (test_id, dependency_set) runnable on current platform."""
    current_os = os_name or platform.system()
    is_darwin = current_os == "Darwin"

    entries: Dict[str, Set[str]] = {}

    py_tests = discover_python_tests(root)
    for py_test in py_tests:
        entries[py_test] = _extract_python_test_refs(py_test, root)

    for spec in HARNESS_SPECS:
        if spec.darwin_only and not is_darwin:
            continue
        if spec.requires_rig_ui_so and not include_rig_ui_so:
            continue
        entries[spec.test_id] = _harness_dependencies(spec, root)

    ordered_ids: List[str] = []
    # Match tests/run_all.sh execution order: priority py -> harnesses -> remaining py.
    priority_py = [
        "tests/test_max_quality_defaults.py",
        "tests/test_stage_db_meters.py",
        "tests/test_a2_fast_ring_copy.py",
    ]
    for tid in priority_py:
        if tid in entries:
            ordered_ids.append(tid)
    for spec in HARNESS_SPECS:
        if spec.test_id in entries:
            ordered_ids.append(spec.test_id)
    for tid in py_tests:
        if tid not in ordered_ids:
            ordered_ids.append(tid)

    return [(tid, entries[tid]) for tid in ordered_ids]


def select_tests(
    root: pathlib.Path = ROOT,
    mode: str = "auto",
    base_ref: Optional[str] = None,
    explicit_files: Optional[Sequence[str]] = None,
    select_all: bool = False,
    rig_ui_so: str = "",
    rig_so: Optional[str] = None,
    os_name: Optional[str] = None,
) -> SelectionResult:
    """Compute which tests in tests/run_all.sh should run for the detected changes."""
    dep_map = build_dependency_map(root=root, include_rig_ui_so=bool(rig_ui_so), os_name=os_name)
    all_tests = [tid for tid, _ in dep_map]

    if select_all:
        return SelectionResult(
            mode="all",
            detection_detail="--all flag",
            changed_files=[],
            selected_tests=all_tests,
            reasons={tid: ["--all"] for tid in all_tests},
            notes=[],
            unmapped_files=[],
            all_tests=all_tests,
        )

    changed_files, detail = detect_changed_files(
        root=root,
        mode=mode,
        base_ref=base_ref,
        explicit_files=explicit_files,
    )

    selected: List[str] = []
    reasons: Dict[str, List[str]] = {}
    matched_changed: Set[str] = set()

    for tid, deps in dep_map:
        hits = _match_reasons(changed_files, deps)
        if hits:
            selected.append(tid)
            reasons[tid] = hits
            for h in hits:
                matched_changed.add(h.split(" (via ", 1)[0])

    unmapped = [cf for cf in changed_files if cf not in matched_changed]
    notes: List[str] = []

    # Check whether selected RIG_SO harnesses target a stale installed plugin binary.
    rig_so_ids = {s.test_id for s in HARNESS_SPECS if s.requires_rig_so}
    if any(tid in rig_so_ids for tid in selected):
        rig_path_str = rig_so or os.environ.get(
            "RIG_SO",
            str(pathlib.Path.home() / "Library/Audio/Plug-Ins/LV2/neural_amp_modeler.lv2/neural_amp_modeler_rig.so"),
        )
        rig_path = pathlib.Path(rig_path_str)
        if rig_path.is_file():
            rig_mtime = rig_path.stat().st_mtime
            newer_srcs = [
                cf
                for cf in changed_files
                if cf.startswith(("src/", "resources/", "deps/NeuralAudio/"))
                and (root / cf).is_file()
                and (root / cf).stat().st_mtime > rig_mtime
            ]
            if newer_srcs:
                notes.append(
                    f"Installed RIG_SO ({rig_path}) is older than changed source(s) "
                    f"({', '.join(newer_srcs[:3])}{'...' if len(newer_srcs) > 3 else ''}); "
                    "rebuild with './build.sh --no-menu --no-launch' to test updated binaries."
                )

    manual_hints: List[str] = []
    for cf in changed_files:
        for hint in MANUAL_HARNESS_HINTS.get(cf, ()):
            if hint not in manual_hints:
                manual_hints.append(hint)
    if manual_hints:
        notes.append(f"Optional manual/CMake targets not in run_all.sh: {', '.join(manual_hints)}")

    if (not rig_ui_so) and any(
        _match_trigger(cf, dep)
        for cf in changed_files
        for dep in next(s.extra_triggers for s in HARNESS_SPECS if s.test_id == "tests/verify_transformer_ui.mm")
    ):
        # Only mention RIG_UI_SO when nam_rig_ui / transformer UI harness itself changed or on direct UI harness edit
        if any(cf in {"tests/verify_transformer_ui.mm", "src/nam_rig_ui.mm", "src/rig_ui_state.h"} for cf in changed_files):
            notes.append(
                "RIG_UI_SO is unset; tests/verify_transformer_ui.mm skipped (set RIG_UI_SO=/path/to/neural_amp_modeler_rig_ui.so to include it)."
            )

    return SelectionResult(
        mode=mode,
        detection_detail=detail,
        changed_files=changed_files,
        selected_tests=selected,
        reasons=reasons,
        notes=notes,
        unmapped_files=unmapped,
        all_tests=all_tests,
    )


def _format_summary(res: SelectionResult) -> str:
    lines: List[str] = []
    lines.append(f"Test selection [{res.mode}]: {res.detection_detail}")
    if res.mode == "all":
        lines.append(f"Selected all {len(res.selected_tests)} runnable tests.")
        return "\n".join(lines)

    if not res.changed_files:
        lines.append("Changed files: none")
        lines.append("Selected tests (0): nothing to run.")
        return "\n".join(lines)

    preview_limit = 15
    shown = res.changed_files[:preview_limit]
    lines.append(f"Changed files ({len(res.changed_files)}): {', '.join(shown)}" + (
        f" (+{len(res.changed_files) - preview_limit} more)" if len(res.changed_files) > preview_limit else ""
    ))

    if res.selected_tests:
        lines.append(f"Selected tests ({len(res.selected_tests)}/{len(res.all_tests)}):")
        for tid in res.selected_tests:
            why = ", ".join(res.reasons.get(tid, [])[:3])
            extra = len(res.reasons.get(tid, [])) - 3
            suffix = f" (+{extra} more)" if extra > 0 else ""
            lines.append(f"  - {tid}  <- {why}{suffix}")
    else:
        lines.append(f"Selected tests (0/{len(res.all_tests)}): no mapped test targets.")

    if res.unmapped_files:
        docs_only = [
            f for f in res.unmapped_files
            if f.endswith((".md", ".txt")) or f.startswith((".agents/", ".github/", "docs/"))
        ]
        other_unmapped = [f for f in res.unmapped_files if f not in docs_only]
        if docs_only:
            d_shown = docs_only[:10]
            lines.append(
                f"Docs/meta files (no test targets): {', '.join(d_shown)}"
                + (f" (+{len(docs_only) - 10} more)" if len(docs_only) - 10 > 0 else "")
            )
        if other_unmapped:
            u_shown = other_unmapped[:10]
            lines.append(
                f"Unmapped changed files ({len(other_unmapped)}): {', '.join(u_shown)}"
                + (f" (+{len(other_unmapped) - 10} more)" if len(other_unmapped) > 10 else "")
            )
    for note in res.notes:
        lines.append(f"Note: {note}")
    return "\n".join(lines)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Select Neural Amp Modeler Rig tests for changed files.")
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument("--auto", action="store_true", help="Working changes if dirty, else branch vs upstream/main (default)")
    mode_group.add_argument("--changed", action="store_true", help="Alias for --auto")
    mode_group.add_argument("--working", action="store_true", help="Diff working tree against HEAD")
    mode_group.add_argument("--staged", action="store_true", help="Diff staged index changes against HEAD")
    mode_group.add_argument("--branch", action="store_true", help="Diff HEAD against upstream/main merge-base")
    mode_group.add_argument("--base", metavar="REF", help="Diff REF (merge-base) against working tree, or git range A..B")
    mode_group.add_argument("--files", nargs="+", metavar="PATH", help="Test impact of specific repo file paths")
    mode_group.add_argument("--all", action="store_true", help="Select all runnable tests")

    parser.add_argument("--rig-ui-so", default="", help="Path to RIG_UI_SO (enables verify_transformer_ui.mm)")
    parser.add_argument("--rig-so", default="", help="Path to RIG_SO for staleness checks")
    parser.add_argument("--ids", action="store_true", help="Print selected test IDs, one per line")
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON selection payload")
    parser.add_argument("--summary", action="store_true", help="Print human-readable summary")

    args = parser.parse_args(argv)

    mode = "auto"
    if args.working:
        mode = "working"
    elif args.staged:
        mode = "staged"
    elif args.branch:
        mode = "branch"
    elif args.base:
        mode = "base"
    elif args.files:
        mode = "files"

    res = select_tests(
        root=ROOT,
        mode=mode,
        base_ref=args.base,
        explicit_files=args.files,
        select_all=args.all,
        rig_ui_so=args.rig_ui_so,
        rig_so=args.rig_so or None,
    )

    if args.json:
        print(json.dumps(dataclasses.asdict(res), indent=2))
    elif args.ids:
        for tid in res.selected_tests:
            print(tid)
    else:
        print(_format_summary(res))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
