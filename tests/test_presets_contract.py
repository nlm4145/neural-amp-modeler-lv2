#!/usr/bin/env python3
"""Guard the Axe FX / NAM Rig preset serialization and management contracts."""
import json
import re
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
presets_h = (ROOT / "src/rig_presets.h").read_text()
presets_mm = (ROOT / "src/rig_presets.mm").read_text()
ui_state_h = (ROOT / "src/rig_ui_state.h").read_text()
ui_mm = (ROOT / "src/nam_rig_ui.mm").read_text()
knobs_h = (ROOT / "src/rig_knobs.h").read_text()
knobs_cpp = (ROOT / "src/rig_knobs.cpp").read_text()

# 1. Verify RigPreset & RigPresetManager definitions
assert "@interface RigPreset" in presets_h, "RigPreset must be declared in rig_presets.h"
assert "@interface RigPresetManager" in presets_h, "RigPresetManager must be declared in rig_presets.h"
assert "stageAtIndex:" in presets_h, "stageAtIndex: must be declared in rig_presets.h"
assert "std::vector<std::string> models;" in presets_h, "RigStagePreset must have models vector"
assert "discoverModelsForStagePath" in presets_h, "discoverModelsForStagePath must be declared in rig_presets.h"
assert "@implementation RigPreset" in presets_mm, "RigPreset must be implemented in rig_presets.mm"
assert "@implementation RigPresetManager" in presets_mm, "RigPresetManager must be implemented in rig_presets.mm"
assert "discoverModelsForStagePath" in presets_mm, "discoverModelsForStagePath must be implemented in rig_presets.mm"
assert "setStageModels" in presets_mm, "applyToState must update available stage models"

# 2. Verify all knob ports are registered in the preset map
assert "kRigKnobCount = 38" in knobs_h
expected_ports = [
    15, 23, 4, 28, 22, 12, 13, 14, 25, 26, 27, 5, 32, 33,
    34, 35, 36, 37, 38, 39, 40, 41, 43, 44, 45, 46,
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58
]
for p in expected_ports:
    assert f"@{p}:" in presets_mm, f"Port {p} must be mapped in portToSymbolMap()"
assert 'symbols[@(NAMRig::kPowerTubeCharacterPort)] = @"power_tube_character";' in presets_mm
expected_ports.append(81)

# 3. Verify stage powers, modes, and profiles are mapped
for p in [7, 8, 9, 20, 21, 24, 30, 42, 47, 59]:
    assert f"@{p}:" in presets_mm, f"Mode/power/profile port {p} must be mapped in portToSymbolMap()"

# Signed alignment remains the existing knob; polarity is an appended toggle.
assert '@49: @"cab2_delay"' in presets_mm
assert '@59: @"cab2_polarity"' in presets_mm
defaults = presets_mm.split("+ (RigPreset*)defaultPreset", 1)[1].split("+ (nullable RigPreset*)loadFromFile:", 1)[0]
loading = presets_mm.split("+ (nullable RigPreset*)loadFromFile:", 1)[1].split("- (BOOL)saveToFile:", 1)[0]
saving = presets_mm.split("- (BOOL)saveToFile:", 1)[1].split("+ (RigPreset*)captureFromState:", 1)[0]
capture = presets_mm.split("+ (RigPreset*)captureFromState:", 1)[1].split("- (void)applyToState:", 1)[0]
apply = presets_mm.split("- (void)applyToState:", 1)[1].split("@end", 1)[0]
assert "p->_controls[59] = 0.0f;" in defaults
assert "preset->_controls[59] = 0.0f;" in loading
assert loading.index("preset->_controls[59] = 0.0f;") < loading.index('root[@"ports"]'), (
    "legacy normal polarity must be initialized before numeric/named saved values override it"
)
assert "preset->_controls[port] = val;" in loading
assert "preset->_controls[[portNum unsignedIntValue]] = [paramsDict[sym] floatValue];" in loading
assert loading.index('root[@"ports"]') < loading.index('root[@"params"]'), (
    "named signed alignment/polarity must retain precedence over numeric port values"
)
assert "portsDict[portKey] = @(pair.second);" in saving
assert "paramsDict[sym] = @(pair.second);" in saving
assert "p->_controls[59] = state->cab2PolarityInverted ? 1.0f : 0.0f;" in capture
assert "state->sendControl(59, polarity);" in apply
assert "state->updateControl(59, polarity);" in apply
assert "[self controlForPort:59] >= 0.5f ? 1.0f : 0.0f" in apply
assert "state->sendControl(port, val);" in apply and "state->updateControl(port, val);" in apply
knob_defaults = re.search(r"kRigKnobDefaults\s*\{([^}]+)\}", knobs_cpp).group(1)
knob_defaults = [float(value.strip().removesuffix("f")) for value in knob_defaults.split(",")]
assert knob_defaults[expected_ports.index(49)] == 0.0, "legacy/default signed alignment must be neutral"

# 4. Verify UI state bindings
assert "presetPopup" in ui_state_h
assert "prevPresetBtn" in ui_state_h
assert "nextPresetBtn" in ui_state_h
assert "savePresetBtn" in ui_state_h
assert "presetManager" in ui_state_h
assert "rebuildPresetMenu" in ui_state_h
assert "updatePresetDisplayTitle" in ui_state_h

# 5. Verify NAMRigUIController preset methods and dirty tracking
assert "presetPopupChanged:" in ui_mm
assert "prevPresetClicked:" in ui_mm
assert "nextPresetClicked:" in ui_mm
assert "saveCurrentPreset:" in ui_mm
assert "savePresetAs:" in ui_mm
assert "duplicateCurrentPreset:" in ui_mm
assert "deleteCurrentPreset:" in ui_mm
assert "revealPresetsInFinder:" in ui_mm
assert "markPresetModified" in ui_mm

# 5b. Verify Duplicate Preset wiring: manager API + menu entry + dialog flow
assert "uniquePresetNameForBase:" in presets_h
assert "duplicateCurrentPresetFromState:" in presets_h
assert "duplicateCurrentPresetFromState:" in presets_mm
assert "uniquePresetNameForBase" in presets_mm
assert '"Duplicate Preset"' in ui_state_h, "Preset popup menu must offer Duplicate Preset"
assert "@selector(duplicateCurrentPreset:)" in ui_state_h
assert "Duplicate Preset" in ui_mm, "UI must show a Duplicate Preset dialog"
assert "uniquePresetNameForBase:" in ui_mm, "Duplicate dialog must suggest a unique name"

# 5c. Verify the popup never sticks on a command row: command rows carry no
# representedObject-based name, and every Cancel/failure path re-syncs the
# button back to the current preset.
assert "resyncPresetPopupSelection" in ui_state_h
assert "representedObject isKindOfClass:[NSString class]" in ui_mm, \
    "presetPopupChanged must only treat representedObject-backed rows as presets"
assert ui_mm.count("resyncPresetPopupSelection") >= 8, \
    "every preset Cancel/failure path must snap the popup back to the current preset"

# 6. Verify dirty tracking is called on adjustments and defaults A/B slot B to "<preset> *"
assert "[self markPresetModified];" in ui_mm
assert "abModifiedPreset" in ui_state_h, "RigUIState must maintain abModifiedPreset snapshot for modified B slot"
assert "abModifiedToken()" in ui_state_h, "RigUIState must define abModifiedToken() for modified B slot"
assert "abUserChoseB" in ui_state_h, "RigUIState must track whether user manually overrode B slot"
assert 'NSString* modTitle = [cur stringByAppendingString:@" *"];' in ui_state_h, \
    "refreshABMenus must add '<cur> *' to Menu B when preset is modified"
assert '([name isEqualToString:cur] && presetManager.isModified)' not in ui_state_h, \
    "Main preset popup (Menu A) must keep the base preset name without '*' so Menu B holds '<cur> *'"
assert "applyABDropdownHighlight(presetPopup, abCycling && abShowingA);" in ui_state_h, \
    "updateABStatus must highlight presetPopup yellow when A is active during A/B testing"
assert "applyABDropdownHighlight(abPresetB, abCycling && !abShowingA);" in ui_state_h, \
    "updateABStatus must highlight abPresetB yellow when B is active during A/B testing"
assert 'filterWithName:@"CIColorMatrix"' in ui_state_h, \
    "applyABDropdownHighlight must use CIColorMatrix to tint the active white dropdown yellow"
assert "installKeyEventMonitor" in ui_state_h and "state->installKeyEventMonitor();" in ui_mm, \
    "UI must install a local key event monitor for Cmd+S and arrow keys"
assert "stopKeyEventMonitor" in ui_state_h and "state->stopKeyEventMonitor();" in ui_mm, \
    "UI must remove the local key event monitor on teardown"
assert "[(id)selfState->uiController saveCurrentPreset:nil];" in ui_state_h, \
    "Cmd+S must save the current preset"
assert "[(id)selfState->uiController prevPresetClicked:nil];" in ui_state_h, \
    "Left arrow key must select the previous (up) preset"
assert "[(id)selfState->uiController nextPresetClicked:nil];" in ui_state_h, \
    "Right arrow key must select the next (down) preset"
assert "headerBar.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];" in ui_mm, \
    "headerBar must use NSAppearanceNameAqua so preset dropdowns render white with black text"
cmake_txt = (ROOT / "src" / "CMakeLists.txt").read_text()
plist_in = (ROOT / "resources" / "standalone-Info.plist.in").read_text()
assert "-Wl,-platform_version,macos,11.0,14.5" in cmake_txt, \
    "axe_fx_standalone must link with macOS SDK 14.5 platform_version to match Element's classic opaque white Aqua NSPopUpButton bezel"
assert "<key>UIDesignRequiresCompatibility</key><true/>" in plist_in, \
    "standalone-Info.plist.in must enable UIDesignRequiresCompatibility"
tone_api_mm = (ROOT / "src" / "rig_tone_api.mm").read_text()
assert "tone3000-session.json" in tone_api_mm, \
    "Tone3000 session must persist to tone3000-session.json in Application Support so ad-hoc rebuilds do not trigger Keychain password prompts"
assert "kSecUseAuthenticationUISkip" in tone_api_mm, \
    "Fallback Keychain queries must set kSecUseAuthenticationUISkip so macOS never shows a modal Keychain password prompt"
build_sh = (ROOT / "build.sh").read_text()
assert 'CODESIGN_ID="Axe FX Local Signer"' in build_sh and '--sign "$CODESIGN_ID"' in build_sh, \
    "build.sh must sign Axe FX.app with a persistent local code-signing identity so macOS TCC remembers Microphone permission across rebuilds"
assert "kMeterUiIntervalSec = 0.5" in ui_state_h, \
    "Input and output dB meter UI updates must be throttled to a 500ms cadence"
standalone_mm = (ROOT / "src" / "standalone_main.mm").read_text()
assert "now - lastCpuUiTime_ < 0.5" in standalone_mm, \
    "Standalone CPU meter UI updates must be throttled to a 500ms cadence"
assert "<key>CFBundleIconFile</key><string>AxeFX</string>" in plist_in, \
    "standalone-Info.plist.in must specify AxeFX as CFBundleIconFile"
assert (ROOT / "resources" / "AxeFX.icns").exists() and (ROOT / "resources" / "AxeFX.png").exists(), \
    "AxeFX.icns and AxeFX.png must exist in resources/"
assert "StandaloneAnimatedAmpView" in standalone_mm and "NSApp.dockTile.contentView = _dockAmpView;" in standalone_mm, \
    "standalone_main.mm must render an animated amp view in the Dock and top toolbar"
for required_audio_sym in (
    "rootContent.audioPopup = _audioPopup;",
    "@selector(selectInputDevice:)",
    "@selector(selectInputChannel:)",
    "@selector(selectOutputDevice:)",
    "@selector(selectOutputChannel:)",
    "OUTPUT SOURCE / CHANNEL",
    "Output 1 + 2 (Stereo Out)",
    "Output 1 + 2 (Dual Mono)",
    "@selector(selectSampleRate:)",
    "@selector(selectBufferSize:)",
    "configureSplitHAL",
    "setSampleRateAndReload",
):
    assert required_audio_sym in standalone_mm, f"standalone_main.mm missing {required_audio_sym}"

assert '@"CAB A LVL"' in ui_mm, "knobNames[8] must be labeled CAB A LVL"
assert "const size_t groupCounts[3] = {4, 6, 1};" in ui_mm, \
    "Cab card must display only 1 knob (OUTPUT) directly underneath, with advanced cab knobs in Dual-Cabinet Blend Console"
plugin_cpp = (ROOT / "src" / "nam_rig_plugin.cpp").read_text()
assert "if (haveA && consoleOn) {\n      for (uint32_t i = 0; i < n; ++i) {\n        smoothedCabLevel += (targetCab - smoothedCabLevel) * glide10;" in plugin_cpp, \
    "cab_level (CAB A LVL) must scale Cab A independently before blending with Cab B"
theme_mm = (ROOT / "src" / "rig_theme.mm").read_text()
assert 'case 22: return [NSString stringWithFormat:@"%+.1f dB", value];' in theme_mm, \
    "Port 22 (Amp Drive) must display dB at -24 dB, not OFF"
assert 'case 25: return value <= -23.95f ? @"OFF"' in theme_mm, \
    "Port 25 (Cab A Level) must display OFF at -24 dB"
assert 'case 48: return value <= -23.95f ? @"OFF"' in theme_mm, \
    "Port 48 (Cab B Level) must display OFF at -24 dB"
rig_ttl = (ROOT / "resources" / "neural_amp_modeler_rig.ttl.in").read_text()
assert rig_ttl.count('lv2:scalePoint [ rdfs:value -24.0 ; rdfs:label "Off" ]') == 2, \
    "Both cab_level (25) and cab2_level (48) must declare Off scalePoint at -24.0 dB in TTL"
assert "if (version < 2)" in presets_mm and 'root[@"version"] = @2;' in presets_mm, \
    "Presets must migrate v1 cab2_level on load and save as version 2"

# 7. Test preset JSON serialization / deserialization round-trip
sample_preset = {
    "name": "Mesa Modern Lead",
    "version": 1,
    "created": "2026-09-12T04:50:00Z",
    "speaker_profile": 2.0,
    "stages": [
        {
            "role": "pedal",
            "enabled": True,
            "path": "/path/to/overdrive.nam",
            "imageURL": "https://example.com/pedal.png",
            "toneId": 12345,
            "oversample": 6.0,
            "models": ["/path/to/overdrive.nam", "/path/to/overdrive_boost.nam"]
        },
        {
            "role": "amp",
            "enabled": True,
            "path": "/path/to/mesa_lead.nam",
            "imageURL": "https://example.com/amp.png",
            "toneId": 67890,
            "oversample": 6.0,
            "transformer": 1.0,
            "models": ["/path/to/mesa_clean.nam", "/path/to/mesa_lead.nam"]
        },
        {
            "role": "cab",
            "enabled": True,
            "path": "/path/to/v30_cab.wav",
            "imageURL": "https://example.com/cab.png",
            "toneId": 11111,
            "ir_normalization": 2.0,
            "models": ["/path/to/v30_cab.wav", "/path/to/v30_room.wav"]
        },
        {
            "role": "cab2",
            "enabled": False,
            "path": "",
            "imageURL": "",
            "toneId": 0,
            "models": []
        }
    ],
    "ports": {str(p): 0.0 for p in expected_ports},
    "params": {
        "gate_threshold": -27.0,
        "input_level": 1.5,
        "amp_drive": 3.0,
        "bass": 1.0,
        "mid": -0.5,
        "treble": 2.0,
        "reverb_mix": 15.0,
        "delay_mix": 20.0,
        "cab2_delay": -7.25,
        "cab2_polarity": 1.0
    }
}
sample_preset["ports"]["49"] = -7.25
sample_preset["ports"]["59"] = 1.0

with tempfile.NamedTemporaryFile(mode="w+", suffix=".json") as f:
    json.dump(sample_preset, f, indent=2)
    f.flush()
    f.seek(0)
    loaded = json.load(f)

assert loaded["name"] == "Mesa Modern Lead"
assert len(loaded["stages"]) == 4
assert loaded["stages"][1]["transformer"] == 1.0
assert loaded["stages"][0]["models"] == ["/path/to/overdrive.nam", "/path/to/overdrive_boost.nam"]
assert loaded["stages"][1]["models"] == ["/path/to/mesa_clean.nam", "/path/to/mesa_lead.nam"]
assert loaded["stages"][2]["models"] == ["/path/to/v30_cab.wav", "/path/to/v30_room.wav"]
assert loaded["params"]["reverb_mix"] == 15.0
assert len(loaded["ports"]) == len(expected_ports) + 1
assert loaded["ports"]["49"] == loaded["params"]["cab2_delay"] == -7.25
assert loaded["ports"]["59"] == loaded["params"]["cab2_polarity"] == 1.0

print("  PASS  Axe FX / NAM Rig preset contract and JSON serialization fully verified")
