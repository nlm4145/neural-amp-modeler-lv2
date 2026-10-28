#!/usr/bin/env python3
"""UI vocabulary/privacy regressions for target loading versus cloud transport."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WorkflowTests(unittest.TestCase):
    def test_separate_player_target_and_upload(self):
        ui = (ROOT / "src/nam_rig_ui.mm").read_text()
        for label in ["Your guitar — record your playing",
                      "2. Load target sound…", "not uploaded",
                      "Send recordings to cloud AI", "Claude uses audio measurements only",
                      "To enable: "]:
            self.assertIn(label, ui)
        self.assertNotIn("Your riff WAV…", ui)
        self.assertNotIn("Extract guitar stem…", ui)
        self.assertNotIn("copilotLocalCLIButton", ui)
        self.assertNotIn("copilotLocalCLIToggled", ui)
        self.assertIn("config.allowLocalCLI = YES", ui)

    def test_cli_default_does_not_enable_audio_upload(self):
        code = (ROOT / "src/rig_ai_copilot.mm").read_text()
        defaults = code.split("+ (instancetype)defaultConfig", 1)[1].split("return c;", 1)[0]
        self.assertIn("c.allowLocalCLI = YES", defaults)
        self.assertIn("c.sendAudio = NO", defaults)

    def test_local_match_research_is_opt_in_text_only(self):
        ui = (ROOT / "src/nam_rig_ui.mm").read_text()
        code = (ROOT / "src/rig_ai_copilot.mm").read_text()
        match = ui.split("- (void)matchCopilotLocally:(id)sender {", 1)[1].split("\n- (void)", 1)[0]
        # The only provider call from Learn & Match is gated on the opt-in checkbox.
        self.assertEqual(match.count("researchGearForPrompt:"), 1)
        self.assertIn("if (research && query.length && !rigAIGearResearchMatching(query, YES))", match)
        self.assertIn("const BOOL research = self.copilotMatchResearchButton.state == NSControlStateValueOn;", match)
        self.assertIn("Research gear with AI (text only)", ui)
        # Off unless saved on; never attaches audio.
        self.assertIn('c.researchGearForLocalMatch = [dict[@"local_match_research"] isKindOfClass:NSNumber.class] && '
                      '[dict[@"local_match_research"] boolValue];', code)
        research = code.split("- (void)researchGearForPrompt:(NSString*)prompt\n                   completion:", 1)[1].split("\n}\n", 1)[0]
        for audio in ["audio", "Audio", "clips", "sendAudio"]:
            self.assertNotIn(audio, research)
        # Cancel stops research as well as the matcher.
        cancel = ui.split("- (void)cancelCopilotRequest:(id)sender {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("[[RigAICopilot sharedCopilot] cancelProcessing]; // Opt-in gear research", cancel)

    def test_local_match_mix_eq_toggle(self):
        ui = (ROOT / "src/nam_rig_ui.mm").read_text()
        select = ui.split("- (void)selectCopilotLocalMatch:(id)sender {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("match.presetWithoutMixEQ && !mixEQ ? match.presetWithoutMixEQ : match.preset", select)
        self.assertIn("result.proposedPreset = chosen;", select)
        self.assertIn("Mix EQ (Console pins)", ui)

    def test_local_match_demucs_rescore_is_opt_in(self):
        ui = (ROOT / "src/nam_rig_ui.mm").read_text()
        drawer = ui.split("- (void)openAICopilot:(id)sender {", 1)[1].split("\n- (void)", 1)[0]
        self.assertIn("Accurate Demucs re-score (slow)", drawer)
        self.assertIn("self.copilotAccurateRescoreButton.state = NSControlStateValueOff;", drawer)
        update = ui.split("- (void)updateCopilotRiffUI {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn('self.copilotAccurateRescoreButton.enabled = !busy && [r.referenceSource isEqualToString:@"demucs"];', update)
        match = ui.split("- (void)matchCopilotLocally:(id)sender {", 1)[1].split("\n- (void)", 1)[0]
        self.assertIn("const BOOL accurateRescore = self.copilotAccurateRescoreButton.state == NSControlStateValueOn &&", match)
        self.assertIn("plan.accurateRescore = accurateRescore;", match)

    def test_play_along_and_dtw_alignment_ui(self):
        ui = (ROOT / "src/nam_rig_ui.mm").read_text()
        rec = (ROOT / "src/rig_riff_recorder.h").read_text()
        self.assertIn("● Play Along", ui)
        self.assertIn("copilotPlayAlongBtn", ui)
        self.assertIn("- (void)toggleCopilotPlayAlong:(id)sender;", ui)
        self.assertIn("startPlayAlong", rec)
        self.assertIn("stopPlayAlong", rec)
        self.assertIn("isPlayingAlong", rec)
        update = ui.split("- (void)updateCopilotRiffUI {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("self.copilotPlayAlongBtn.title =", update)
        self.assertIn("self.copilotPlayAlongBtn.enabled =", update)
        match = ui.split("- (void)matchCopilotLocally:(id)sender {", 1)[1].split("\n- (void)", 1)[0]
        self.assertIn("plan.playAlong = playAlong;", match)
        self.assertIn("(aligned)", match)
        select = ui.split("- (void)selectCopilotLocalMatch:(id)sender {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("DTW alignment:", select)

    def test_embedding_rerank_ui(self):
        ui = (ROOT / "src/nam_rig_ui.mm").read_text()
        drawer = ui.split("- (void)openAICopilot:(id)sender {", 1)[1].split("\n- (void)", 1)[0]
        self.assertIn("Embedding re-rank (CLAP)", drawer)
        self.assertIn("self.copilotEmbeddingRerankButton.state = NSControlStateValueOff;", drawer)
        update = ui.split("- (void)updateCopilotRiffUI {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("self.copilotEmbeddingRerankButton.enabled = !busy;", update)
        match = ui.split("- (void)matchCopilotLocally:(id)sender {", 1)[1].split("\n- (void)", 1)[0]
        self.assertIn("plan.embeddingRerank = embeddingRerank;", match)
        self.assertIn("(emb: %.2f)", match)
        select = ui.split("- (void)selectCopilotLocalMatch:(id)sender {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("CLAP embedding distance:", select)


if __name__ == "__main__":
    unittest.main()
