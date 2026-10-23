#!/usr/bin/env python3
"""UI vocabulary/privacy regressions for target loading versus cloud transport."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WorkflowTests(unittest.TestCase):
    def test_separate_player_target_and_upload(self):
        ui = (ROOT / "src/nam_rig_ui.mm").read_text()
        for label in ["Your guitar — record your playing", "Your riff WAV…",
                      "2. Load target sound…", "Reference WAV · loaded locally",
                      "Send recordings to cloud AI", "Claude uses audio measurements only",
                      "To enable: ", "use a guitar-only target, not a full song mix"]:
            self.assertIn(label, ui)
        self.assertNotIn("copilotLocalCLIButton", ui)
        self.assertNotIn("copilotLocalCLIToggled", ui)
        self.assertIn("config.allowLocalCLI = YES", ui)

    def test_cli_default_does_not_enable_audio_upload(self):
        code = (ROOT / "src/rig_ai_copilot.mm").read_text()
        defaults = code.split("+ (instancetype)defaultConfig", 1)[1].split("return c;", 1)[0]
        self.assertIn("c.allowLocalCLI = YES", defaults)
        self.assertIn("c.sendAudio = NO", defaults)


if __name__ == "__main__":
    unittest.main()
