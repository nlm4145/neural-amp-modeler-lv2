#!/usr/bin/env python3
"""Guard editable transformer trims across LV2, DSP, UI and rig/slot presets."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
ttl = (ROOT / "resources/neural_amp_modeler_rig.ttl.in").read_text()
ui_ttl = (ROOT / "resources/neural_amp_modeler_rig_ui.ttl.in").read_text()
controls = (ROOT / "src/transformer_controls.h").read_text()
tube_controls = (ROOT / "src/power_tube_controls.h").read_text()
header = (ROOT / "src/nam_rig_plugin.h").read_text()
dsp = (ROOT / "src/nam_rig_plugin.cpp").read_text()
transformer = (ROOT / "src/output_transformer.h").read_text()
ui = (ROOT / "src/nam_rig_ui.mm").read_text()
state = (ROOT / "src/rig_ui_state.h").read_text()
standalone = (ROOT / "src/standalone_main.mm").read_text()
presets = (ROOT / "src/rig_presets.mm").read_text()


def body(source: str, signature: str, indent: str = "") -> str:
    match = re.search(
        r"^" + re.escape(indent + signature) + r"[^{;]*\{(.*?)^" + re.escape(indent) + r"\}",
        source, re.S | re.M,
    )
    assert match, f"missing implementation of {signature}"
    return match.group(1)


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
    "reverb_predelay", "cab2_polarity",
]
symbols = [
    "transformer_low_cut", "transformer_high_cut", "transformer_drive", "transformer_mix",
    "transformer_flux", "transformer_voice_freq", "transformer_voice_gain",
    "transformer_voice_q", "transformer_leakage_freq", "transformer_leakage_gain",
    "transformer_leakage_q",
]
rack_symbols = ["delay_enabled", "reverb_enabled", "spatial_enabled", "power_enabled",
                "sculpt_enabled", "transformer_enabled", "speaker_enabled", "cab_console_enabled"]
appended_symbols = ["power_tube_enabled", "power_tube_type", "power_tube_character", "mid_push"]
appended_symbols += [f"{pane}_pin{b}_{p}" for pane in ("sculpt", "transformer", "cab_console") for b in range(1, 7) for p in ("shape", "freq", "gain", "q")]
port_pairs = [(int(index), symbol) for index, symbol in re.findall(
    r'lv2:index\s+(\d+)\s*;\s*lv2:symbol\s+"([^"]+)"', ttl
)]
assert port_pairs == list(enumerate(legacy_symbols + symbols + rack_symbols + appended_symbols)), (
    "ports 0..78 must stay unchanged; Power/Tube appends at 79..81, Mid Push at 82"
)
assert "kTransformerControlFirstPort = 60;" in controls
assert "kTransformerControlCount = 11;" in controls
assert "kPortCount = kRigControlPortCount;" in header
assert "kRigControlPortCount = 155;" in tube_controls
assert "std::array<float*, kTransformerControlCount> transformer_adjustments;" in header
assert "offsetof(Ports, cab2_polarity) == 59 * sizeof(void*)" in header
assert "offsetof(Ports, transformer_adjustments) == kTransformerControlFirstPort * sizeof(void*)" in header
assert "kPowerTubeTypePort == kRackControlFirstPort + kRackCount" in header
assert "kPinEqFirstPort == kMidPushPort + 1" in header
assert "kPortCount == kPinEqFirstPort + kPinEqPortCount" in header
assert "sizeof(Ports) == kPortCount * sizeof(void*)" in header

# The metadata table is the shared host/preset order, not absolute profile values.
defaults = [1, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1]
specs = re.findall(
    r'\{"([^"]+)", "([^"]+)", "([^"]+)", ([-\d.]+)f, ([-\d.]+)f, ([-\d.]+)f, (true|false)\}',
    controls,
)
assert [spec[0] for spec in specs] == symbols, "shared metadata must expose exactly 11 ordered trims"
default_array = re.search(r"kTransformerControlDefaults\s*=\s*\{([^}]+)\}", controls)
assert default_array and [float(v) for v in default_array.group(1).split(",")] == defaults
for i, (symbol, name, unit, minimum, maximum, default, logarithmic) in enumerate(specs):
    expected_range = (0.25, 4.0) if defaults[i] == 1 else ((-100.0, 100.0) if i == 3 else (-12.0, 12.0))
    assert (float(minimum), float(maximum), float(default)) == (*expected_range, defaults[i]), symbol
    assert unit == ("x" if defaults[i] == 1 else ("%" if i == 3 else "dB")), symbol
    assert (logarithmic == "true") == (defaults[i] == 1), symbol
    port = re.search(rf"\[\s*a lv2:ControlPort, lv2:InputPort ; lv2:index {60 + i}\s*;(.*?)\]", ttl, re.S)
    assert port, f"{symbol} must be an LV2 input control"
    port = port.group(1)
    assert f'lv2:name "{name}"' in port
    for property_name, expected in (("default", defaults[i]), ("minimum", expected_range[0]), ("maximum", expected_range[1])):
        value = re.search(rf"lv2:{property_name}\s+([-\d.]+)", port)
        assert value and float(value.group(1)) == expected, f"{symbol} {property_name}"
    ttl_unit = "<@NAM_RIG_LV2_ID@-transformer-ratio>" if unit == "x" else ("units:pc" if unit == "%" else "units:db")
    assert f"units:unit {ttl_unit}" in port
    assert ("pprops:logarithmic" in port) == (logarithmic == "true")
    assert len(re.findall(rf'lv2:symbol "{symbol}"\s*;\s*ui:notifyType atom:Float', ui_ttl)) == 1, (
        f"UI must subscribe once to host automation of {symbol}"
    )

# DSP and UI must use the same absolute-value order and physical limits.
expressions = ["p.lowCutHz", "p.highCutHz", "p.drive", "p.saturationMix * 100.0",
               "p.fluxHz", "p.voiceHz", "p.voiceDb", "p.voiceQ",
               "p.leakageHz", "p.leakageDb", "p.leakageQ"]
values = body(transformer, "static std::array<float, 11> controlValues(", "  ")
assert re.findall(r"static_cast<float>\(([^)]+)\)", values) == expressions
mins = [5, 2000, 0.5, 0, 20, 100, -12, 0.2, 100, -12, 0.2]
maxes = [300, 24000, 10, 100, 400, 12000, 12, 4, 12000, 12, 4]
parameters = transformer.split("static Parameters parametersForProfile(", 1)[1].split("static std::array<float, 11> controlValues(", 1)[0]
for i, expression in enumerate(expressions):
    field = expression.split(" * ", 1)[0]
    adjustment = (f"{field} * trim({i})" if defaults[i] == 1 else
                  f"{field} + trim({i})" + (" * 0.01" if i == 3 else ""))
    assignment = re.search(rf"{re.escape(field)} = std::clamp\({re.escape(adjustment)}, ([\d.-]+), ([\d.-]+)\);", parameters)
    assert assignment, f"DSP trim {i} must adjust {field} in shared control order"
    assert tuple(map(float, assignment.groups())) == (mins[i], maxes[i] / 100 if i == 3 else maxes[i])
snapshot = dsp[dsp.index("TransformerAdjustments transformerAdjustments;"):dsp.index("if (!transformerLatched)")]
assert "portValue(ports.transformer_adjustments[i], c.defaultValue)" in snapshot
assert "std::isfinite(value)" in snapshot and "std::clamp(value, c.minimum, c.maximum) : c.defaultValue" in snapshot
assert re.search(r"outputTransformer\.process\(samples, count, domainRate, transformerApplied,\s*transformerAdjustments\);", dsp)
assert dsp.index(snapshot) < dsp.index("auto applyModel = [&]"), "trims must be captured before processing models"

# Standalone writes must address the same neutral-initialized storage connected to DSP.
assert "NAMRig::TransformerAdjustments transformerControls_ = NAMRig::kTransformerControlDefaults;" in standalone
assert re.search(r"for \(size_t i = 0; i < transformerControls_\.size\(\); \+\+i\)\s*plugin_->ports\.transformer_adjustments\[i\] = &transformerControls_\[i\];", standalone)
write = body(standalone, "static void uiWrite(", "  ")
assert re.search(r"if \(format == 0 && port >= NAMRig::kTransformerControlFirstPort &&\s*port < NAMRig::kTransformerControlFirstPort \+ NAMRig::kTransformerControlCount &&\s*size == sizeof\(float\)\) \{\s*host->transformerControls_\[port - NAMRig::kTransformerControlFirstPort\] =\s*\*static_cast<const float\*>\(buffer\);\s*return;", write)
assert "write(controller, port, sizeof(value), 0, &value);" in body(state, "void sendControl(", "  ")
event = body(ui, "void portEvent(")
assert re.search(r"if \(format == 0 && buffer && size == sizeof\(float\) && port >= 4 &&\s*port < NAMRig::kRigControlPortCount\) \{\s*state->updateControl\(port, \*static_cast<const float\*>\(buffer\)\);\s*return;", event), (
    "host float echoes must include 4..154, exclude 155+, and validate format/buffer/size"
)

assert "int transformerProfile = NAMRig::OutputTransformer::kCaptured;" in state
assert "NAMRig::TransformerAdjustments transformerAdjustments = NAMRig::kTransformerControlDefaults;" in state
popover = body(ui, "- (void)showTransformerControls:")
assert "const size_t starts[] = {0, 2, 5, 8};" in popover
assert "const size_t counts[] = {2, 3, 3, 3};" in popover
assert re.findall(r'@"([^"]+)"', re.search(r"names = @\[(.*?)\];", popover, re.S).group(1)) == [
    "Low Cut", "High Cut", "Core Drive", "Saturation Mix", "Flux Frequency",
    "Voice Frequency", "Voice Gain", "Voice Q", "Leakage Frequency", "Leakage Gain", "Leakage Q",
]
assert "slider.tag = NAMRig::kTransformerControlFirstPort + i;" in popover
assert "field.tag = slider.tag;" in popover
assert "slider.action = @selector(transformerControlChanged:);" in popover
assert "field.action = @selector(transformerControlChanged:);" in popover
assert "@selector(resetTransformerControls:)" in popover and "NSPopoverBehaviorTransient" in popover
assert "action:@selector(showTransformerControls:)" in ui and "kLbl.tag = pillIdx;" in ui
edit = body(ui, "- (void)transformerControlChanged:")
assert "_state->transformerProfile == 0" in edit
assert "index < 0 || index >= (NSInteger)NAMRig::kTransformerControlCount" in edit
assert "!std::isfinite(value)" in edit and "std::clamp(value, (double)range[0], (double)range[1])" in edit
assert "c.logarithmic ? std::exp(sender.doubleValue) : sender.doubleValue" in edit
assert "c.defaultValue == 1.0f ? value / base[index] : value - base[index]" in edit
assert edit.index("sendControl(port, trim)") < edit.index("updateControl(port, trim)") < edit.index("[self markPresetModified];")
control_range = body(state, "std::array<float, 2> transformerControlRange(", "  ")
for name, expected in (("mins", mins), ("maxes", maxes)):
    array = re.search(rf"{name}\[\] = \{{([^}}]+)\}}", control_range)
    assert array and [float(v.strip().removesuffix("f")) for v in array.group(1).split(",")] == expected
assert "parametersForProfile(transformerProfile)" in control_range
assert "ratio ? base[index] * c.minimum : base[index] + c.minimum" in control_range
assert "ratio ? base[index] * c.maximum : base[index] + c.maximum" in control_range
telemetry = body(state, "void updateTransformerTelemetry(", "  ")
assert "parametersForProfile(idx, transformerAdjustments)" in telemetry
assert "transformerVisualizer.parameters = p;" in telemetry
assert "transformerSpecLabels[i].stringValue = vals[i];" in telemetry
assert "const auto values = NAMRig::OutputTransformer::controlValues(p);" in telemetry
for expression in ("p.lowCutHz", "p.highCutHz", "p.drive", "p.saturationMix", "p.voiceDb", "p.voiceHz", "p.leakageDb", "p.leakageHz"):
    assert expression in telemetry, "spec text must be computed from current DSP parameters"
assert "slider.minValue = log ? std::log(range[0]) : range[0];" in telemetry
assert "slider.maxValue = log ? std::log(range[1]) : range[1];" in telemetry
assert "slider.doubleValue = log ? std::log(values[i]) : values[i];" in telemetry
assert "slider.enabled = idx != 0;" in telemetry and "transformerFields[i].enabled = idx != 0;" in telemetry
assert "if (!transformerFieldEditing[i])" in telemetry, "host echoes must not overwrite in-progress text edits"
update = body(state, "void updateControl(", "  ")
trim_update = update.split("if (port == 59)", 1)[0]
assert "port >= NAMRig::kTransformerControlFirstPort" in trim_update
assert "port < NAMRig::kTransformerControlFirstPort + NAMRig::kTransformerControlCount" in trim_update
assert "std::isfinite(value) ? std::clamp(value, c.minimum, c.maximum) : c.defaultValue" in trim_update
assert "transformerAdjustments[index] = trim;" in trim_update
assert "updateTransformerTelemetry(transformerProfile);" in trim_update
assert "if ([NSThread isMainThread]) updateTransformer();" in trim_update
profile_update = update.split("if (port == 30)", 1)[1].split("if (port == 42)", 1)[0]
assert "transformerProfile = idx;" in profile_update
assert "kTransformerControlDefaults" not in profile_update and "sendControl" not in profile_update, (
    "host profile echoes must preserve trims, not reset or write back automation"
)
reset = body(ui, "- (void)resetTransformerControls:")
assert "i < NAMRig::kTransformerControlCount" in reset
assert "port = NAMRig::kTransformerControlFirstPort + i;" in reset
assert "sendControl(port, NAMRig::kTransformerControlDefaults[i]);" in reset
assert "updateControl(port, NAMRig::kTransformerControlDefaults[i]);" in reset
assert "[self markPresetModified];" in reset
for signature in ("- (void)resetAllKnobs:", "- (void)transformerChanged:", "- (void)applyTransformerPreset:"):
    assert "[self resetTransformerControls:sender];" in body(ui, signature), signature

# Rig presets persist both numeric ports and named symbols, including legacy defaults.
mapping = body(presets, "static NSDictionary<NSNumber*, NSString*>* portToSymbolMap(")
assert "i < NAMRig::kTransformerControlCount" in mapping
assert "symbols[@(NAMRig::kTransformerControlFirstPort + i)]" in mapping
assert "stringWithUTF8String:NAMRig::kTransformerControls[i].symbol" in mapping
for signature, receiver in (("+ (RigPreset*)defaultPreset", "p"), ("+ (nullable RigPreset*)loadFromFile:", "preset")):
    section = body(presets, signature)
    neutral = f"{receiver}->_controls[NAMRig::kTransformerControlFirstPort + i] = NAMRig::kTransformerControlDefaults[i];"
    assert "i < NAMRig::kTransformerControlCount" in section and neutral in section
    if receiver == "preset":
        assert section.index(neutral) < section.index('root[@"ports"]') < section.index('root[@"params"]')
        assert "preset->_controls[port] = val;" in section
        assert "preset->_controls[[portNum unsignedIntValue]] = [paramsDict[sym] floatValue];" in section
saving = body(presets, "- (BOOL)saveToFile:")
assert "portsDict[portKey] = @(pair.second);" in saving and "paramsDict[sym] = @(pair.second);" in saving
capture = body(presets, "+ (RigPreset*)captureFromState:")
assert "static_cast<float>(state->transformerProfile)" in capture
assert "i < NAMRig::kTransformerControlCount" in capture
assert "p->_controls[NAMRig::kTransformerControlFirstPort + i] = state->transformerAdjustments[i];" in capture
apply = body(presets, "- (void)applyToState:")
assert "i < NAMRig::kTransformerControlCount" in apply
assert "port = NAMRig::kTransformerControlFirstPort + i;" in apply
assert "it != _controls.end() ? it->second : NAMRig::kTransformerControlDefaults[i]" in apply
assert "state->sendControl(port, value);" in apply and "state->updateControl(port, value);" in apply
trim_apply = apply[apply.index("for (size_t i = 0; i < NAMRig::kTransformerControlCount;"):]
assert "state->sendControl(port, value);" in trim_apply and "state->updateControl(port, value);" in trim_apply
assert apply.index("updateControl(30,") < apply.index(trim_apply), "restore profile before saved trims"

# Slot presets contain the model selector plus all 11 trim ports, not just port 30.
assert re.search(r"transformerPorts = \[NSMutableArray arrayWithObject:@30\];\s*for \(size_t i = 0; i < NAMRig::kTransformerControlCount; \+\+i\)\s*\[transformerPorts addObject:@\(NAMRig::kTransformerControlFirstPort \+ i\)\];", ui)
assert re.search(r'addSlotPresetDropdown\(topZone, state, @"transformer", @"Output Transformer",\s*transformerPorts,', ui)
assert '@"OUTPUT TRANSFORMER", @"CORE SATURATION & VOICING"' in ui
assert 'addLabel(topZone, @"PRESET"' in ui and 'addLabel(card, @"BASE MODEL"' in ui
slot_value = body(state, "float currentPortValueForSlot(", "  ")
assert "return (float)transformerProfile;" in slot_value
assert "port >= NAMRig::kTransformerControlFirstPort" in slot_value
assert "port < NAMRig::kTransformerControlFirstPort + NAMRig::kTransformerControlCount" in slot_value
assert "return transformerAdjustments[port - NAMRig::kTransformerControlFirstPort];" in slot_value
assert "@(currentPortValueForSlot(port))" in body(state, "NSDictionary<NSString*, NSNumber*>* captureSlotPortValues(", "  ")
slot_apply = body(ui, "- (void)slotPresetPopupChanged:")
assert 'if ([spec[@"key"] isEqualToString:@"transformer"])' in slot_apply
assert slot_apply.index("[self resetTransformerControls:sender];") < slot_apply.index("for (id portKey in values)")
assert "_state->sendControl(port, val);" in slot_apply and "_state->updateControl(port, val);" in slot_apply
assert "[self markPresetModified];" in slot_apply
print("  PASS  transformer ports 60..70, neutral trims, DSP/UI order, host wiring, resets and rig/slot persistence")
