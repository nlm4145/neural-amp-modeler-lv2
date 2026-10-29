#!/usr/bin/env python3
"""Contract for the contextual signal-chain workspace."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
workspace = (ROOT / "src/rig_workspace.mm").read_text()
header = (ROOT / "src/rig_workspace.h").read_text()
state = (ROOT / "src/rig_ui_state.h").read_text()
ui = (ROOT / "src/nam_rig_ui.mm").read_text()
cmake = (ROOT / "src/CMakeLists.txt").read_text()

assert "rig_workspace.h rig_workspace.mm" in cmake
assert "__strong id<NAMRigWorkspaceNavigation> workspace" in state
assert "rigCreateWorkspace" in ui
assert "NSMakeRect(0, 0, 1520, 980)" in workspace

for stage in ["Input", "Pedal", "Amp", "Cab", "Output"]:
    assert stage in workspace
for key in ["compressor", "sculpt", "boost", "power", "transformer", "speaker",
            "cablab", "align", "postcomp", "delay", "reverb", "spatial", "tuner"]:
    assert f'@"{key}"' in workspace, f"Missing contextual module {key}"

assert '[self selectStage:sender.tag]' in workspace
assert '[self selectModule:sender.accessibilityIdentifier]' in workspace
assert 'self.state->selectDeckTab(0)' in workspace, "Tuner must retain its activation behavior"
assert 'self.state->selectDeckTab(1)' in workspace, "Leaving tuner must restore prior processing"
assert 'self.state->stageCards' in workspace, "Existing model cards must be reused"
assert 'self.state->modelPickers' in workspace, "Existing model dropdowns must be reused"
assert 'racksForPane' in workspace, "Existing DSP racks must be reused"

print("  PASS  contextual workspace covers every stage and modifier with live control reuse")
