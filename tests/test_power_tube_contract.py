#!/usr/bin/env python3
"""Guard append-only power-tube metadata and numeric/named rig persistence."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
controls = (ROOT / "src/power_tube_controls.h").read_text()
rack = (ROOT / "src/rack_controls.h").read_text()
header = (ROOT / "src/nam_rig_plugin.h").read_text()
ttl = (ROOT / "resources/neural_amp_modeler_rig.ttl.in").read_text()
ui_ttl = (ROOT / "resources/neural_amp_modeler_rig_ui.ttl.in").read_text()
presets = (ROOT / "src/rig_presets.mm").read_text()
presets_header = (ROOT / "src/rig_presets.h").read_text()
state = (ROOT / "src/rig_ui_state.h").read_text()


def body(source: str, signature: str) -> str:
    match = re.search(
        r"^" + re.escape(signature) + r"[^{;]*\{(.*?)^\}", source, re.S | re.M,
    )
    assert match, f"missing implementation of {signature}"
    return match.group(1)


# Existing host indices and symbols are immutable; the three new controls append.
legacy_symbols = [
    "control", "notify", "input", "output", "input_level", "output_level",
    "quality_scale", "pedal_enabled", "amp_enabled", "cab_enabled", "auto_cab",
    "cab_auto_bypassed", "bass", "mid", "treble", "gate_threshold", "tuner_enable",
    "tuner_note", "tuner_cents", "oversample_mode", "pedal_oversample", "amp_oversample",
    "amp_drive", "gate_release", "ir_normalization", "cab_level", "cab_low_cut",
    "cab_high_cut", "compressor", "latency", "transformer_type", "output_r",
    "stereo_width", "room", "presence", "depth", "sag", "bias", "negative_feedback",
    "bright", "input_eq", "master", "speaker_profile", "speaker_drive",
    "speaker_compression", "speaker_thump", "speaker_resonance", "cab2_enabled",
    "cab2_level", "cab2_delay", "delay_time", "delay_feedback", "delay_damping",
    "delay_mix", "reverb_mix", "reverb_decay", "reverb_size", "reverb_damping",
    "reverb_predelay", "cab2_polarity", "transformer_low_cut", "transformer_high_cut",
    "transformer_drive", "transformer_mix", "transformer_flux", "transformer_voice_freq",
    "transformer_voice_gain", "transformer_voice_q", "transformer_leakage_freq",
    "transformer_leakage_gain", "transformer_leakage_q", "delay_enabled", "reverb_enabled",
    "spatial_enabled", "power_enabled", "sculpt_enabled", "transformer_enabled",
    "speaker_enabled", "cab_console_enabled",
]
new_symbols = ["power_tube_enabled", "power_tube_type", "power_tube_character"]
port_pairs = [(int(index), symbol) for index, symbol in re.findall(
    r'lv2:index\s+(\d+)\s*;\s*lv2:symbol\s+"([^"]+)"', ttl,
)]
assert port_pairs == list(enumerate(legacy_symbols + new_symbols)), (
    "ports 0..78 must stay unchanged; power-tube controls append at 79..81"
)
for name, value in (("kPowerTubeTypePort", 80), ("kPowerTubeCharacterPort", 81),
                    ("kRigControlPortCount", 82)):
    assert re.search(rf"\b{name}\s*=\s*{value}\s*;", controls), name
assert "kPowerTubeCharacterDefault = 50.0f;" in controls
assert "kCaptured = 0;" in controls and "kProfileCount = 3;" in controls
assert "kPortCount = kRigControlPortCount;" in header
for field, port in (("power_tube_type", "kPowerTubeTypePort"),
                    ("power_tube_character", "kPowerTubeCharacterPort")):
    assert re.search(rf"float\*\s+{field}\s*;", header), field
    assert f"offsetof(Ports, {field}) == {port} * sizeof(void*)" in header
assert "sizeof(Ports) == kPortCount * sizeof(void*)" in header

rack_names = ["Delay", "Reverb", "Spatial", "Power", "Sculpt", "Transformer",
              "Speaker", "CabConsole", "PowerTube", "Count"]
enum = re.search(r"enum class Rack\s*:\s*size_t\s*\{([^}]+)\}", rack)
assert enum and [name.strip() for name in enum.group(1).split(",")] == rack_names
assert "kRackControlFirstPort = 71;" in rack
for name, expected in (
    ("kRackControlSymbols", legacy_symbols[71:] + ["power_tube_enabled"]),
    ("kRackSlotKeys", ["delay", "reverb", "spatial", "power", "sculpt", "transformer",
                      "speaker", "cab_console", "power_tube"]),
):
    array = re.search(rf"{name}\s*=\s*\{{([^}}]+)\}}", rack)
    assert array and re.findall(r'"([^"]+)"', array.group(1)) == expected, name
defaults = re.search(r"kRackControlDefaults\s*=\s*\{([^}]+)\}", rack)
assert defaults and [float(value.strip().removesuffix("f"))
                     for value in defaults.group(1).split(",")] == [1] * 9

# Optional connections preserve old hosts; UI automation subscribes exactly once.
blocks = {}
for index, symbol, expected in (
    (79, "power_tube_enabled", (1, 0, 1)),
    (80, "power_tube_type", (0, 0, 2)),
    (81, "power_tube_character", (50, 0, 100)),
):
    block = re.search(
        rf"\[\s*a lv2:ControlPort, lv2:InputPort\s*;\s*lv2:index {index}\s*;"
        r"(.*?)(?=\]\s*,\s*\[\s*a\s|\]\s*\.)", ttl, re.S,
    )
    assert block, f"missing input control {index}"
    blocks[index] = block.group(1)
    assert f'lv2:symbol "{symbol}"' in blocks[index]
    for name, value in zip(("default", "minimum", "maximum"), expected):
        actual = re.search(rf"lv2:{name}\s+([-\d.]+)", blocks[index])
        assert actual and float(actual.group(1)) == value, f"{symbol} {name}"
    assert "lv2:connectionOptional" in blocks[index], symbol
    assert len(re.findall(
        rf'lv2:symbol "{symbol}"\s*;\s*ui:notifyType atom:Float', ui_ttl,
    )) == 1, f"UI must subscribe once to {symbol}"
assert "lv2:toggled" in blocks[79] and "lv2:integer" in blocks[79]
assert "lv2:enumeration" in blocks[80] and "lv2:integer" in blocks[80]
assert [(float(value), label) for value, label in re.findall(
    r'rdfs:value\s+([-\d.]+)\s*;\s*rdfs:label\s+"([^"]+)"', blocks[80],
)] == [(0, "Captured/No Added Character"), (1, "6L6-inspired"), (2, "EL34-inspired")]
assert "units:unit units:pc" in blocks[81]

# The shared rack mapping includes enable; type/character use only the controls map.
assert '#include "power_tube_controls.h"' in presets
mapping = body(presets, "static NSDictionary<NSNumber*, NSString*>* portToSymbolMap(")
assert "i < NAMRig::kRackCount" in mapping
assert "symbols[@(NAMRig::kRackControlFirstPort + i)]" in mapping
assert "stringWithUTF8String:NAMRig::kRackControlSymbols[i]" in mapping
assert 'symbols[@(NAMRig::kPowerTubeTypePort)] = @"power_tube_type";' in mapping
assert 'symbols[@(NAMRig::kPowerTubeCharacterPort)] = @"power_tube_character";' in mapping
inverse = body(presets, "static NSDictionary<NSString*, NSNumber*>* symbolToPortMap(")
assert "inv[portToSymbolMap()[port]] = port;" in inverse
for signature, receiver in (("+ (RigPreset*)defaultPreset", "p"),
                            ("+ (nullable RigPreset*)loadFromFile:", "preset")):
    section = body(presets, signature)
    assert "i < NAMRig::kRackCount" in section
    for assignment in (
        f"{receiver}->_controls[NAMRig::kPowerTubeTypePort] = 0.0f;",
        f"{receiver}->_controls[NAMRig::kPowerTubeCharacterPort] = NAMRig::kPowerTubeCharacterDefault;",
        f"{receiver}->_controls[NAMRig::kRackControlFirstPort + i] = NAMRig::kRackControlDefaults[i];",
    ):
        assert assignment in section, f"{signature} must initialize {assignment}"
        if receiver == "preset":
            assert section.index(assignment) < section.index('root[@"ports"]')
loading = body(presets, "+ (nullable RigPreset*)loadFromFile:")
assert loading.index('root[@"ports"]') < loading.index('root[@"params"]')
assert "preset->_controls[port] = val;" in loading
assert "symMap = symbolToPortMap();" in loading
assert "preset->_controls[[portNum unsignedIntValue]] = [paramsDict[sym] floatValue];" in loading
saving = body(presets, "- (BOOL)saveToFile:")
assert "portMap = portToSymbolMap();" in saving
assert "for (const auto& pair : _controls)" in saving
assert "portsDict[portKey] = @(pair.second);" in saving
assert "NSString* sym = portMap[@(pair.first)];" in saving
assert "paramsDict[sym] = @(pair.second);" in saving
assert 'root[@"ports"] = portsDict;' in saving and 'root[@"params"] = paramsDict;' in saving
assert not re.search(r"power_?tube", presets_header, re.I), "no duplicate stage/profile property"
assert not re.search(r'(?:root|st)\[@"power_tube[^"\]]*"\]', presets), (
    "power-tube values must persist only through numeric ports and named params"
)

capture = body(presets, "+ (RigPreset*)captureFromState:")
assert "p->_controls[NAMRig::kPowerTubeTypePort] = static_cast<float>(state->powerTubeProfile);" in capture
assert "p->_controls[NAMRig::kPowerTubeCharacterPort] = state->powerTubeCharacter;" in capture
assert "i < NAMRig::kRackCount" in capture
assert "p->_controls[NAMRig::kRackControlFirstPort + i] = state->rackControls[i];" in capture

# Applying a sparse in-memory preset must reset stale type/amount as well as enable.
apply = body(presets, "- (void)applyToState:")
for port, iterator, variable, default in (
    ("kPowerTubeTypePort", "tubeTypeIt", "tubeType", "0.0f"),
    ("kPowerTubeCharacterPort", "tubeCharacterIt", "tubeCharacter", "NAMRig::kPowerTubeCharacterDefault"),
):
    assert f"auto {iterator} = _controls.find(NAMRig::{port});" in apply
    assert re.search(
        rf"const float {variable}\s*=\s*{iterator} != _controls.end\(\)\s*"
        rf"\? {iterator}->second\s*:\s*{re.escape(default)};", apply,
    ), f"sparse presets must reset {port}"
    assert f"state->sendControl(NAMRig::{port}, {variable});" in apply
    assert f"state->updateControl(NAMRig::{port}, {variable});" in apply
assert apply.index("updateControl(NAMRig::kPowerTubeTypePort,") < apply.index(
    "updateControl(NAMRig::kPowerTubeCharacterPort,"
), "recall type before saved character"
assert "i < NAMRig::kRackCount" in apply
assert "it != _controls.end() ? it->second : NAMRig::kRackControlDefaults[i]" in apply
assert "state->sendControl(port, value);" in apply and "state->updateControl(port, value);" in apply

assert re.search(r"\bint\s+powerTubeProfile\s*=", state), "RigUIState powerTubeProfile integration is missing"
assert re.search(r"\bfloat\s+powerTubeCharacter\s*=", state), "RigUIState powerTubeCharacter integration is missing"

print("  PASS  power-tube ports 79..81, optional metadata, neutral legacy defaults and numeric/named rig persistence")
