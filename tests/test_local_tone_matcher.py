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


if __name__ == "__main__":
    unittest.main()
