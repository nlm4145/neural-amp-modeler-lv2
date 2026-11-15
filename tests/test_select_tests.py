#!/usr/bin/env python3
"""Unit tests for changed-module test selection (tests/select_tests.py and tests/run_all.sh)."""

from __future__ import annotations

import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

import select_tests

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUN_ALL = ROOT / "tests" / "run_all.sh"


def _git(cwd: pathlib.Path, *args: str) -> str:
    res = subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        capture_output=True,
        text=True,
        check=True,
    )
    return res.stdout.strip()


class TestSelectTests(unittest.TestCase):
    def test_run_all_parity_with_harness_specs(self) -> None:
        run_all_text = RUN_ALL.read_text(encoding="utf-8")
        # Ignore comment lines, then find every tests/verify_* referenced in run_all.sh.
        active_lines = "\n".join(
            line for line in run_all_text.splitlines() if not line.lstrip().startswith("#")
        )
        run_all_verifies = set(
            re.findall(r"tests/verify_[A-Za-z0-9_]+\.(?:cpp|mm|c)\b", active_lines)
        )
        spec_ids = {s.test_id for s in select_tests.HARNESS_SPECS}
        self.assertEqual(
            run_all_verifies,
            spec_ids,
            "HARNESS_SPECS in tests/select_tests.py must stay 1:1 with tests/run_all.sh",
        )

    def test_all_runnable_tests_have_non_empty_deps_and_self_trigger(self) -> None:
        dep_map = select_tests.build_dependency_map(
            root=ROOT, include_rig_ui_so=True, os_name="Darwin"
        )
        self.assertGreaterEqual(len(dep_map), 70)
        for tid, deps in dep_map:
            self.assertIn(tid, deps, f"{tid} must trigger itself")
            res = select_tests.select_tests(
                root=ROOT,
                mode="files",
                explicit_files=[tid],
                rig_ui_so="/tmp/fake_ui.so",
                os_name="Darwin",
            )
            self.assertIn(tid, res.selected_tests, f"Editing {tid} did not select itself")

    def test_extra_compiled_cpp_sources_detected_from_run_all(self) -> None:
        cases = {
            "src/wav_ir.cpp": {"tests/verify_wav_ir.cpp", "tests/test_wav_ir_resample.py"},
            "src/oversample.cpp": {
                "tests/verify_oversample_shared.cpp",
                "tests/verify_oversample_cpp.cpp",
                "tests/verify_oversample_batched.cpp",
                "tests/verify_oversample_cascade.cpp",
                "tests/verify_oversample_latency.cpp",
                "tests/test_oversample_2x.py",
                "tests/test_oversample_batched.py",
            },
            "src/win32_presets.cpp": {"tests/verify_rig_control_metadata.cpp"},
            "src/standalone_worker.cpp": {"tests/verify_standalone_worker.cpp"},
        }
        for src_file, expected in cases.items():
            res = select_tests.select_tests(
                root=ROOT, mode="files", explicit_files=[src_file], os_name="Darwin"
            )
            missing = expected - set(res.selected_tests)
            self.assertFalse(missing, f"{src_file} missed expected tests: {missing}")

    def test_header_isolation_does_not_overtrigger_unrelated_tests(self) -> None:
        res = select_tests.select_tests(
            root=ROOT, mode="files", explicit_files=["src/drop_pitch.h"], os_name="Darwin"
        )
        selected = set(res.selected_tests)
        self.assertIn("tests/verify_drop_pitch.cpp", selected)
        self.assertIn("tests/verify_standalone_controls.cpp", selected)
        for unrelated in (
            "tests/verify_overdrive.cpp",
            "tests/verify_tuner.c",
            "tests/verify_lstm_oversampling.cpp",
            "tests/verify_host_smoke.c",
            "tests/test_ai_tone.py",
            "tests/test_tone3000_arch.py",
        ):
            self.assertNotIn(unrelated, selected)

    def test_targeted_module_mappings(self) -> None:
        res_browser = select_tests.select_tests(
            root=ROOT, mode="files", explicit_files=["src/rig_tone_browser.mm"], os_name="Darwin"
        )
        self.assertEqual(
            set(res_browser.selected_tests),
            {
                "tests/test_author_search.py",
                "tests/test_favorites_sort.py",
                "tests/test_tabs_ui.py",
                "tests/test_tone3000_arch.py",
            },
        )

        res_ttl = select_tests.select_tests(
            root=ROOT,
            mode="files",
            explicit_files=["resources/neural_amp_modeler_rig.ttl.in"],
            os_name="Darwin",
        )
        for expected in (
            "tests/test_max_quality_defaults.py",
            "tests/verify_rig_control_metadata.cpp",
            "tests/verify_host_smoke.c",
            "tests/test_ai_tone.py",
            "tests/test_presets_contract.py",
        ):
            self.assertIn(expected, res_ttl.selected_tests)

        res_win32 = select_tests.select_tests(
            root=ROOT, mode="files", explicit_files=["src/win32_audio.cpp"], os_name="Darwin"
        )
        self.assertEqual(res_win32.selected_tests, ["tests/test_win32_audio_stop.py"])

        res_meta = select_tests.select_tests(
            root=ROOT,
            mode="files",
            explicit_files=["tests/select_tests.py"],
            os_name="Darwin",
        )
        self.assertEqual(res_meta.selected_tests, ["tests/test_select_tests.py"])

    def test_neuralaudio_submodule_granularity(self) -> None:
        res_model = select_tests.select_tests(
            root=ROOT,
            mode="files",
            explicit_files=["deps/NeuralAudio/NeuralAudio/NeuralModel.cpp"],
            os_name="Darwin",
        )
        self.assertNotIn("tests/test_a2_fast_ring_copy.py", res_model.selected_tests)
        self.assertIn("tests/verify_host_smoke.c", res_model.selected_tests)
        self.assertIn("tests/verify_rate_adapted_rig.cpp", res_model.selected_tests)

        res_a2 = select_tests.select_tests(
            root=ROOT,
            mode="files",
            explicit_files=["deps/NeuralAudio/deps/NeuralAmpModelerCore/NAM/wavenet/a2_fast.cpp"],
            os_name="Darwin",
        )
        self.assertIn("tests/test_a2_fast_ring_copy.py", res_a2.selected_tests)

    def test_rig_ui_so_gating_and_darwin_filtering(self) -> None:
        res_no_ui = select_tests.select_tests(
            root=ROOT,
            mode="files",
            explicit_files=["src/nam_rig_ui.mm"],
            rig_ui_so="",
            os_name="Darwin",
        )
        self.assertNotIn("tests/verify_transformer_ui.mm", res_no_ui.selected_tests)
        self.assertTrue(any("RIG_UI_SO is unset" in n for n in res_no_ui.notes))

        res_with_ui = select_tests.select_tests(
            root=ROOT,
            mode="files",
            explicit_files=["src/nam_rig_ui.mm"],
            rig_ui_so="/tmp/mock_ui.so",
            os_name="Darwin",
        )
        self.assertIn("tests/verify_transformer_ui.mm", res_with_ui.selected_tests)

        res_linux = select_tests.select_tests(
            root=ROOT,
            mode="files",
            explicit_files=["src/wav_ir.cpp"],
            os_name="Linux",
        )
        self.assertNotIn("tests/verify_wav_ir.cpp", res_linux.selected_tests)
        self.assertIn("tests/test_wav_ir_resample.py", res_linux.selected_tests)

    def test_docs_only_selects_zero_tests(self) -> None:
        res = select_tests.select_tests(
            root=ROOT, mode="files", explicit_files=["README.md", "AGENTS.md"], os_name="Darwin"
        )
        self.assertEqual(res.selected_tests, [])
        self.assertEqual(set(res.unmapped_files), {"README.md", "AGENTS.md"})

    def test_git_auto_branch_and_submodule_detection(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = pathlib.Path(tmp)
            sub_repo = tmp_path / "sub"
            repo = tmp_path / "repo"
            sub_repo.mkdir()
            repo.mkdir()

            # Initialize child submodule repo
            _git(sub_repo, "init")
            _git(sub_repo, "config", "user.name", "Test")
            _git(sub_repo, "config", "user.email", "test@example.com")
            (sub_repo / "Model.h").write_text("// v1\n", encoding="utf-8")
            (sub_repo / "Other.cpp").write_text("// v1\n", encoding="utf-8")
            _git(sub_repo, "add", ".")
            _git(sub_repo, "commit", "-m", "init sub")

            # Initialize superproject on branch 'main'
            _git(repo, "init", "-b", "main")
            _git(repo, "config", "user.name", "Test")
            _git(repo, "config", "user.email", "test@example.com")
            _git(repo, "config", "protocol.file.allow", "always")
            (repo / "src").mkdir()
            (repo / "src" / "a.h").write_text("// a1\n", encoding="utf-8")
            (repo / "src" / "b.h").write_text("// b1\n", encoding="utf-8")
            _git(repo, "add", ".")
            _git(repo, "commit", "-m", "init main")
            _git(repo, "-c", "protocol.file.allow=always", "submodule", "add", str(sub_repo), "deps/sub")
            _git(repo, "commit", "-m", "add sub")

            # Clean on main -> no changes detected
            files, _ = select_tests.detect_changed_files(root=repo, mode="auto")
            self.assertEqual(files, [])

            # Branch commit on feature branch -> auto falls back to branch diff vs main
            _git(repo, "checkout", "-b", "feat/x")
            (repo / "src" / "a.h").write_text("// a2\n", encoding="utf-8")
            _git(repo, "add", "src/a.h")
            _git(repo, "commit", "-m", "edit a.h")
            files, desc = select_tests.detect_changed_files(root=repo, mode="auto")
            self.assertEqual(files, ["src/a.h"])
            self.assertIn("branch", desc)

            # Working tree edit takes priority in --auto; staged vs working work distinctly
            (repo / "src" / "b.h").write_text("// b2\n", encoding="utf-8")
            files_auto, _ = select_tests.detect_changed_files(root=repo, mode="auto")
            self.assertEqual(files_auto, ["src/b.h"])

            files_base, _ = select_tests.detect_changed_files(root=repo, mode="base", base_ref="main")
            self.assertEqual(files_base, ["src/a.h", "src/b.h"])

            _git(repo, "add", "src/b.h")
            (repo / "src" / "untracked.h").write_text("// new\n", encoding="utf-8")
            files_staged, _ = select_tests.detect_changed_files(root=repo, mode="staged")
            self.assertEqual(files_staged, ["src/b.h"])
            files_working, _ = select_tests.detect_changed_files(root=repo, mode="working")
            self.assertEqual(files_working, ["src/b.h", "src/untracked.h"])

            # Dirty submodule file expands to exact inner path
            (repo / "deps" / "sub" / "Model.h").write_text("// dirty\n", encoding="utf-8")
            files_with_sub, _ = select_tests.detect_changed_files(root=repo, mode="working")
            self.assertEqual(
                files_with_sub,
                ["deps/sub/Model.h", "src/b.h", "src/untracked.h"],
            )

            # Cleanup avoids PermissionError on git objects on some systems
            shutil.rmtree(repo / "deps", ignore_errors=True)

    def test_run_all_cli_dry_run_and_zero_test_exit_zero(self) -> None:
        help_res = subprocess.run(
            ["bash", str(RUN_ALL), "--help"],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertIn("--all", help_res.stdout)
        self.assertIn("--files", help_res.stdout)

        docs_res = subprocess.run(
            ["bash", str(RUN_ALL), "--files", "README.md"],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertIn("Selected tests (0/", docs_res.stdout)


if __name__ == "__main__":
    unittest.main()
