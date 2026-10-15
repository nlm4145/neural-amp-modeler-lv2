#!/usr/bin/env python3
"""Exercise build.sh's menu and side-effect-free dry runs.

Run: python3 tests/test_build_menu.py
"""

import errno
import os
from pathlib import Path
import platform
import pty
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SETTING_ENV = (
    "BUILD_PARALLEL_MODELS",
    "BUILD_PARALLEL_CABS",
    "BUILD_SMART_BYPASS",
)
LABELS = (
    "Parallel models",
    "Threaded NAM cabinets",
    "Smart bypass (single-model LV2 only)",
    "Launch",
)


class BuildMenuTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(
            prefix="build-menu tests ", dir=os.environ.get("TMPDIR")
        )
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.build_dir = self.directory / "build directory"
        self.lv2_dir = self.directory / "lv2 install"
        self.install_dir = self.directory / "standalone install"
        tmp_dir = self.directory / "tmp"
        tmp_dir.mkdir()
        bin_dir = self.directory / "bin"
        bin_dir.mkdir()

        # Accidental tool execution must fail without building or launching.
        guard = (
            "#!/bin/sh\n"
            "printf '%s\\n' \"$0 $*\" >> \"$BUILD_MENU_SIDE_EFFECT_LOG\"\n"
            "exit 99\n"
        )
        for name in ("cmake", "make", "ninja", "install", "open", "element"):
            executable = bin_dir / name
            executable.write_text(guard)
            executable.chmod(0o755)

        self.env = os.environ.copy()
        for name in SETTING_ENV:
            self.env.pop(name, None)
        self.env.update(
            TMPDIR=str(tmp_dir),
            BUILD_DIR=str(self.build_dir),
            LV2_DIR=str(self.lv2_dir),
            INSTALL_DIR=str(self.install_dir),
            PATH=str(bin_dir) + os.pathsep + self.env.get("PATH", ""),
            BUILD_MENU_SIDE_EFFECT_LOG=str(self.directory / "side-effects.log"),
        )

    def snapshot(self):
        return {
            str(path.relative_to(self.directory)): (
                path.stat().st_mtime_ns,
                path.read_bytes() if path.is_file() else None,
            )
            for path in self.directory.rglob("*")
        }

    def run_build(self, *args, input_text="", overrides=None,
                  stdin_tty=False, stdout_tty=False):
        env = self.env.copy()
        env.update(overrides or {})
        before = self.snapshot()
        build_existed = self.build_dir.exists()
        command = ["bash", str(ROOT / "build.sh"), "--dry-run", *args]
        masters = []
        slaves = []
        stdin = None
        stdout = subprocess.PIPE
        try:
            if stdin_tty:
                input_master, stdin = pty.openpty()
                masters.append(input_master)
                slaves.append(stdin)
                os.write(input_master, input_text.encode())
            if stdout_tty:
                output_master, stdout = pty.openpty()
                masters.append(output_master)
                slaves.append(stdout)
            result = subprocess.run(
                command,
                cwd=ROOT,
                env=env,
                stdin=stdin,
                input=None if stdin_tty else input_text,
                stdout=stdout,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=15,
            )
            if stdout_tty:
                # Darwin can discard buffered output when the last slave closes.
                # Keep it open and stop at EAGAIN rather than waiting for EOF.
                os.set_blocking(output_master, False)
                chunks = []
                while True:
                    try:
                        chunk = os.read(output_master, 65536)
                    except BlockingIOError:
                        break
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        break
                    if not chunk:
                        break
                    chunks.append(chunk)
                result.stdout = b"".join(chunks).decode()
            result.stderr = ""
        finally:
            for fd in slaves + masters:
                os.close(fd)

        output = result.stdout + result.stderr
        self.assertEqual(before, self.snapshot(), output)
        self.assertFalse(self.lv2_dir.exists(), output)
        self.assertFalse(self.install_dir.exists(), output)
        if not build_existed:
            self.assertFalse(self.build_dir.exists(), output)
        return result

    def assert_settings(self, result, models="ON", cabs="OFF",
                        smart="OFF", launch="auto"):
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        for label, value in zip(LABELS, (models, cabs, smart, launch)):
            values = re.findall(re.escape(label) + r":\s*([^\r\n]+)", output)
            self.assertTrue(values, f"Missing {label!r} in:\n{output}")
            self.assertEqual(values[-1].strip(), value, output)

        commands = re.findall(r"\bcmake [^\r\n]+", result.stdout)
        self.assertEqual(len(commands), 1, output)
        args = shlex.split(commands[0])
        self.assertEqual(args[0], "cmake", output)
        self.assertIn(f"-DSMART_BYPASS_ENABLED={smart}", args, output)
        if platform.system() == "Darwin":
            self.assertIn(f"-DAXE_FX_PARALLEL_MODELS_DEFAULT={models}", args, output)
            self.assertIn(f"-DAXE_FX_PARALLEL_CABS_DEFAULT={cabs}", args, output)
        self.assertNotIn("--build", args, output)
        self.assertNotIn("--install", args, output)
        return args

    def assert_quit(self, result):
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertNotIn("cmake ", output.lower())

    def write_cache(self, models="OFF", cabs="ON", smart="ON", extra=""):
        self.build_dir.mkdir()
        (self.build_dir / "CMakeCache.txt").write_text(
            "# Previous processing settings, not shell input.\n"
            f"AXE_FX_PARALLEL_MODELS_DEFAULT:BOOL={models}\n"
            f"AXE_FX_PARALLEL_CABS_DEFAULT:BOOL={cabs}\n"
            f"SMART_BYPASS_ENABLED:BOOL={smart}\n"
            + extra
        )

    def test_defaults_and_no_menu_ignores_piped_selections(self):
        result = self.run_build("--no-menu", input_text="1\n2\n3\n4\nb\n")
        self.assert_settings(result)

    def test_auto_menu_requires_both_standard_streams_to_be_ttys(self):
        for stdin_tty, stdout_tty in ((False, False), (True, False), (False, True)):
            with self.subTest(stdin_tty=stdin_tty, stdout_tty=stdout_tty):
                result = self.run_build(
                    input_text="q\n", stdin_tty=stdin_tty, stdout_tty=stdout_tty
                )
                self.assert_settings(result)
        self.assert_quit(self.run_build(input_text="q\n", stdin_tty=True, stdout_tty=True))

    def test_no_menu_overrides_automatic_tty_menu(self):
        self.assert_settings(self.run_build(
            "--no-menu", input_text="q\n", stdin_tty=True, stdout_tty=True
        ))

    def test_forced_menu_accepts_enter_and_build_with_piped_input(self):
        for selection in ("\n", "b\n"):
            with self.subTest(selection=repr(selection)):
                self.assert_settings(self.run_build("--menu", input_text=selection))

    def test_each_processing_toggle(self):
        for selection, expected in (
            ("1", {"models": "OFF"}),
            ("2", {"cabs": "ON"}),
            ("3", {"smart": "ON"}),
        ):
            with self.subTest(selection=selection):
                self.assert_settings(
                    self.run_build("--menu", input_text=f"{selection}\nb\n"),
                    **expected,
                )

    def test_all_processing_toggles(self):
        self.assert_settings(
            self.run_build("--menu", input_text="1\n2\n3\nb\n"),
            models="OFF", cabs="ON", smart="ON",
        )

    def test_repeated_toggles_restore_defaults(self):
        self.assert_settings(self.run_build(
            "--menu", input_text="1\n1\n2\n2\n3\n3\nb\n"
        ))

    def test_launch_cycle(self):
        for count, launch in enumerate(("auto", "standalone", "element", "none", "auto")):
            with self.subTest(count=count):
                self.assert_settings(
                    self.run_build("--menu", input_text="4\n" * count + "b\n"),
                    launch=launch,
                )

    def test_existing_launch_flags_noninteractive(self):
        for flag, launch in (
            ("--no-launch", "none"),
            ("--standalone", "standalone"),
            ("--element", "element"),
        ):
            with self.subTest(flag=flag):
                self.assert_settings(self.run_build("--no-menu", flag), launch=launch)
                self.assert_settings(self.run_build(flag), launch=launch)

    def test_menu_uses_launch_flag_as_initial_selection(self):
        for flag, launch in (
            ("--standalone", "element"),
            ("--element", "none"),
            ("--no-launch", "auto"),
        ):
            with self.subTest(flag=flag):
                self.assert_settings(
                    self.run_build("--menu", flag, input_text="4\nb\n"),
                    launch=launch,
                )

    def test_quit_and_eof_never_choose_a_build(self):
        for input_text in ("q\n", "", "1\n2\n3\n4\nq\n", "1\n2\n3\n4\n"):
            with self.subTest(input_text=repr(input_text)):
                self.assert_quit(self.run_build("--menu", input_text=input_text))

    def test_invalid_menu_selection_reports_error_and_redisplays(self):
        result = self.run_build("--menu", input_text="not-a-selection\nq\n")
        self.assert_quit(result)
        output = result.stdout + result.stderr
        invalid = re.search(r"invalid", output, re.IGNORECASE)
        self.assertIsNotNone(invalid, output)
        self.assertIn("parallel models", output[:invalid.start()].lower())
        self.assertIn("parallel models", output[invalid.end():].lower())

    def test_invalid_menu_selection_does_not_change_settings(self):
        self.assert_settings(self.run_build(
            "--menu", input_text="0\n5\nnot-a-selection\nb\n"
        ))

    def test_unknown_flags_fail_without_a_build(self):
        for flag in ("--not-a-build-option", "--menu=ON"):
            with self.subTest(flag=flag):
                result = self.run_build("--no-menu", flag)
                output = result.stdout + result.stderr
                self.assertNotEqual(result.returncode, 0, output)
                self.assertRegex(output.lower(), r"unknown|invalid|unrecognized")
                self.assertNotIn("cmake ", output.lower())

    def test_environment_overrides_defaults(self):
        self.assert_settings(
            self.run_build("--no-menu", overrides=dict(zip(SETTING_ENV, ("OFF", "ON", "ON")))),
            models="OFF", cabs="ON", smart="ON",
        )

    def test_environment_values_must_be_uppercase_on_or_off(self):
        for name in SETTING_ENV:
            for value in ("on", "off", "1", "0", "yes", "invalid"):
                with self.subTest(name=name, value=value):
                    result = self.run_build("--no-menu", overrides={name: value})
                    output = result.stdout + result.stderr
                    self.assertNotEqual(result.returncode, 0, output)
                    self.assertIn(name, output)
                    self.assertNotIn("cmake ", output.lower())

    def test_previous_cache_settings_are_used(self):
        self.write_cache()
        self.assert_settings(self.run_build("--no-menu"), models="OFF", cabs="ON", smart="ON")

    def test_cmake_boolean_cache_values_are_normalized(self):
        self.write_cache(models="0", cabs="TRUE", smart="1")
        self.assert_settings(self.run_build("--no-menu"), models="OFF", cabs="ON", smart="ON")

    def test_cmake_false_cache_values_are_preserved(self):
        self.write_cache(models="FALSE", cabs="NO", smart="OFF")
        self.assert_settings(self.run_build("--no-menu"), models="OFF", cabs="OFF", smart="OFF")

    def test_missing_cache_settings_use_defaults(self):
        self.build_dir.mkdir()
        (self.build_dir / "CMakeCache.txt").write_text(
            "SMART_BYPASS_ENABLED:BOOL=ON\n"
        )
        self.assert_settings(self.run_build("--no-menu"), smart="ON")

    def test_menu_toggles_start_from_previous_cache_settings(self):
        self.write_cache()
        self.assert_settings(self.run_build("--menu", input_text="1\n2\n3\nb\n"))

    def test_environment_overrides_previous_cache_settings(self):
        self.write_cache()
        for name in SETTING_ENV:
            with self.subTest(name=name):
                values = {"models": "OFF", "cabs": "ON", "smart": "ON"}
                key = dict(zip(SETTING_ENV, ("models", "cabs", "smart")))[name]
                values[key] = "ON" if key == "models" else "OFF"
                self.assert_settings(
                    self.run_build("--no-menu", overrides={name: values[key]}), **values
                )

    def test_menu_toggles_start_from_environment_overrides(self):
        self.assert_settings(self.run_build(
            "--menu", input_text="1\n2\n3\nb\n",
            overrides=dict(zip(SETTING_ENV, ("OFF", "ON", "ON"))),
        ))

    def test_cache_is_parsed_not_sourced_or_rewritten(self):
        marker = self.directory / "cache was sourced"
        self.write_cache(extra=f"touch {shlex.quote(str(marker))}\n")
        self.assert_settings(self.run_build("--no-menu"), models="OFF", cabs="ON", smart="ON")
        self.assertFalse(marker.exists())

    def test_cmake_command_shell_quotes_paths(self):
        # Decoding shell quoting must recover the complete path, not split it.
        self.build_dir = self.directory / "build space 'quote' $HOME;literal"
        self.env["BUILD_DIR"] = str(self.build_dir)
        args = self.assert_settings(self.run_build("--no-menu"))
        self.assertTrue(
            any(arg in (str(self.build_dir), "-B" + str(self.build_dir))
                or arg.endswith("=" + str(self.build_dir))
                for arg in args),
            f"CMake command did not preserve BUILD_DIR as one argument: {args!r}",
        )


if __name__ == "__main__":
    unittest.main()
