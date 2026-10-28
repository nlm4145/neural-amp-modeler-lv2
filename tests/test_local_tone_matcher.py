#!/usr/bin/env python3
"""Local training/measurement regressions. No providers, downloads or user rig changes."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LocalToneTests(unittest.TestCase):
    def test_feature_learning(self):
        with tempfile.TemporaryDirectory(prefix="axe-local-learning-", dir=os.environ.get("TMPDIR")) as temp:
            binary = str(Path(temp) / "learning")
            subprocess.run(["clang++", "-O2", "-std=c++17", "-Isrc", "tests/verify_local_tone_learning.cpp", "-o", binary], cwd=ROOT, check=True)
            subprocess.run([binary], check=True)

    @unittest.skipUnless(sys.platform == "darwin", "Foundation runtime requires macOS")
    def test_local_matcher(self):
        with tempfile.TemporaryDirectory(prefix="axe-local-match-", dir=os.environ.get("TMPDIR")) as temp:
            binary = str(Path(temp) / "matcher")
            subprocess.run(["clang++", "-O2", "-std=c++20", "-fobjc-arc", "-Wno-incomplete-implementation", "-Isrc",
                            "tests/verify_local_tone_matcher.mm", "src/rig_local_tone_matcher.mm", "src/rig_ai_support.mm",
                            "-framework", "Cocoa", "-o", binary], cwd=ROOT, check=True)
            subprocess.run([binary, str(Path(temp) / "training")], check=True, timeout=30)

    @unittest.skipUnless(sys.platform == "darwin", "CoreAudio decoding requires macOS")
    def test_reference_selection(self):
        """Recorder: whole-song references, Auto/manual section selection, compressed formats."""
        with tempfile.TemporaryDirectory(prefix="axe-riff-recorder-", dir=os.environ.get("TMPDIR")) as temp:
            binary = str(Path(temp) / "recorder")
            subprocess.run(["clang++", "-O2", "-std=c++20", "-fobjc-arc", "-UNDEBUG", "-Isrc",
                            "tests/verify_riff_recorder.mm", "src/rig_riff_recorder.mm",
                            "-framework", "Cocoa", "-framework", "AudioToolbox", "-o", binary], cwd=ROOT, check=True)
            subprocess.run([binary], check=True, timeout=60, env={**os.environ, "TMPDIR": temp})


if __name__ == "__main__":
    unittest.main()
