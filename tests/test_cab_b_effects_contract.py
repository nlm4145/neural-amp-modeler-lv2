#!/usr/bin/env python3
"""Guard the append-only second cabinet, stereo delay and plate reverb.

Cab B is a fourth stage that runs PARALLEL to Cab A from the same post-amp
tap, so it is never part of the serial chain and never joins a True-Nx domain.
The delay and reverb sit after the click-safe transition fade so a model swap
cannot cut their tails.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
ttl = (ROOT / "resources/neural_amp_modeler_rig.ttl.in").read_text()
header = (ROOT / "src/nam_rig_plugin.h").read_text()
dsp = (ROOT / "src/nam_rig_plugin.cpp").read_text()
ui = (ROOT / "src/nam_rig_ui.mm").read_text()
state = (ROOT / "src/rig_ui_state.h").read_text()
knobs = (ROOT / "src/rig_knobs.cpp").read_text()
theme = (ROOT / "src/rig_theme.mm").read_text()
standalone = (ROOT / "src/standalone_main.mm").read_text()

ports = {
    int(index): symbol
    for index, symbol in re.findall(
        r'lv2:index\s+(\d+)\s*;\s*lv2:symbol\s+"([^"]+)"', ttl
    )
}
expected = [
    "cab2_enabled", "cab2_level", "cab2_delay",
    "delay_time", "delay_feedback", "delay_damping", "delay_mix",
    "reverb_mix", "reverb_decay", "reverb_size", "reverb_damping",
    "reverb_predelay", "cab2_polarity",
]
for index, symbol in enumerate(expected, 47):
    assert ports[index] == symbol, f"port {index} must append {symbol}"
assert "offsetof(Ports, cab2_enabled) == 47 * sizeof(void*)" in header
assert "offsetof(Ports, reverb_predelay) == 58 * sizeof(void*)" in header
assert "offsetof(Ports, cab2_polarity) == 59 * sizeof(void*)" in header
assert "kPortCount = 71" in header
assert sorted(ports) == list(range(71)), "ports 0..59 must stay contiguous before transformer trims append at 60..70"


def port_default(index: int) -> float:
    match = re.search(
        rf"lv2:index\s+{index}\s*;(?:(?!lv2:index).)*?lv2:default\s+([-0-9.]+)",
        ttl,
        re.S,
    )
    assert match, f"missing default for port {index}"
    return float(match.group(1))


# Everything new must be inaudible on an existing session.
for index in (47, 48, 49, 53, 54, 59):
    assert port_default(index) == 0.0, f"port {index} must default to off/neutral"

alignment_port = re.search(r"lv2:index\s+49\s*;(?:(?!lv2:index).)*", ttl, re.S).group()
polarity_port = re.search(r"lv2:index\s+59\s*;(?:(?!lv2:index).)*", ttl, re.S).group()
assert re.search(r"lv2:minimum\s+-10\.0\s*;\s*lv2:maximum\s+10\.0", alignment_port)
assert "units:unit units:ms" in alignment_port
assert re.search(r"lv2:minimum\s+0\.0\s*;\s*lv2:maximum\s+1\.0", polarity_port)
assert "lv2:toggled" in polarity_port and "lv2:integer" in polarity_port
assert 'rdfs:label "Normal"' in polarity_port and 'rdfs:label "Inverted"' in polarity_port

# Stage 3 exists, is parallel, and carries its own path parameter.
assert "Stage : uint32_t { Pedal = 0, Amp = 1, Cab = 2, Cab2 = 3, Count = 4 }" in header
assert "kSerialStageCount = 3" in header, "only pedal/amp/cab form the serial chain"
assert "-cab2-model" in ttl and "NAM_RIG_CAB2_URI" in header
assert "<@NAM_RIG_LV2_ID@-cab2-model>\n\ta lv2:Parameter" in ttl
assert re.search(r"patch:writable(?:[^;]*?)-cab2-model>", ttl, re.S), (
    "Cab B's path must be patch:writable like the other stages"
)
assert "if (stage == stageIndex(Stage::Cab2)) return kOsLegacy2;" in header, (
    "Cab B must stay at the session rate, out of any True domain"
)
assert "for (size_t i = 0; i < kSerialStageCount; ++i)" in dsp, (
    "the oversample reload must not try to re-create Cab B for a True domain"
)

# Both cabinets take the SAME post-amp tap. A .nam Cab A leaves the amp's
# shared True group but retains its own correctly configured True domain.
assert "std::memcpy(preCab.data(), L, n * sizeof(float));" in dsp
assert "const bool deferredCab = st == 2 && (irs[2] != nullptr || parallelCabs);" in dsp, (
    "a .nam Cab A must defer out of the True chain when Cab B is active"
)
assert "processTrueCab(2, L, n, factor)" in dsp, (
    "a parallel Cab A NAM model must stay in the True domain it was loaded for"
)
assert "latencyFrames += cascadeLatencyFrames(cabFactor);" in dsp, (
    "the independent Cab A converter must be reported to the host"
)
assert "portValue(ports.cab2_delay, 0.0f)" in dsp, "signed alignment must retain a null-safe neutral default"
b_alignment = re.search(r"cab2Align\.process\(BL, BR, n,\s*(.*?)\);", dsp, re.S)
assert b_alignment, "Cab B must keep its stereo alignment delay"
assert "domainDelayMs" in b_alignment.group(1), "Cab B must retain the parallel Cab A converter compensation"
positive_delay = re.search(r"std::max\(\s*(\w+)\s*,\s*0\.0f\s*\)", b_alignment.group(1))
assert positive_delay, "only positive signed alignment may be added to Cab B compensation"
signed_control = positive_delay.group(1)
assert re.search(rf"\w+\.process\(L, R, n,\s*std::max\(-{signed_control},\s*0\.0f\)\)", dsp), (
    "the same signed alignment's negative half must delay both Cab A channels"
)
assert "portValue(ports.cab2_polarity, 0.0f)" in dsp, "unconnected polarity must default to normal"
assert "smoothedCab2Level += (cab2LevelTarget - smoothedCab2Level) * glide10;" in dsp
assert "if (haveA && haveB)" in dsp and "outL = bL;" in dsp, (
    "Cab B alone must replace the dry Cab A branch instead of mixing with it"
)

# Stereo WAV impulse responses load both channels into a second convolver.
assert "WavIR* irRight;" in header and "std::array<WavIR*, kStageCount> irsRight{};" in header
assert "WavIR* irRight = nullptr;" in header, "the pending switch must carry the right-channel IR"
assert re.search(r"const unsigned channels = WavIR::channelCount\(message->path\);", dsp)
assert re.search(r"WavIR::load\(message->path, rig->sampleRate,\s*rig->maxBufferSize, original, 1\)", dsp), (
    "channel 1 must load into the right-channel convolver"
)
assert "WavIR::linkStereoNormalization(*left, *right);" in dsp, (
    "stereo IR normalization must preserve the source channel balance"
)
assert "delete message->irRight;" in dsp, "the worker must free the right-channel IR"
assert "delete pending.irRight;" in dsp

# Effects run AFTER the transition fade, so a model swap never cuts a tail.
fade = dsp.index("transitionGain = std::sin(")
delay = dsp.index("delayFx.process(L, R, n,")
reverb = dsp.index("reverbFx.process(L, R, n,")
assert fade < delay < reverb, "delay and reverb must follow the click-safe fade"

# Wiring: knob map, value formatting, UI popover, and the standalone host.
for port in range(48, 59):
    assert re.search(rf"\b{port}\b", knobs), f"port {port} missing from the UI knob map"
    assert re.search(rf"case {port}:", theme), f"port {port} has no value formatter"
assert "kRigKnobCount = 37" in (ROOT / "src/rig_knobs.h").read_text()
assert "WIDTH / DELAY / REVERB" in ui, "the cab tile needs the effects popover button"
assert "effectsPopover" in ui and "effectsPopover" in state
assert "B ON" in ui and "onB.tag = 47;" in ui, "Cab B needs its own enable toggle"
assert "modelPickers[3]" in ui, "Cab B needs its own model picker"
assert "std::array<LV2_URID, 4> pathURIDs{}" in state
assert re.search(
    r"port >= 4 &&\s*port < NAMRig::kTransformerControlFirstPort \+ NAMRig::kTransformerControlCount",
    ui,
), "the UI must still accept every original control echo, plus transformer ports 60..70"
assert "for (uint32_t port = 47; port <= 59; ++port)" in standalone, (
    "the standalone host must connect the new ports"
)
assert "std::array<float, 13> fxControls_{};" in standalone
assert "port >= 47 && port <= 59 && size == sizeof(float)" in standalone, (
    "standalone control writes must include appended polarity"
)
fx_defaults = re.search(r"fxControls_\s*=\s*\{([^}]+)\}", standalone).group(1)
fx_defaults = [float(value.strip().removesuffix("f")) for value in fx_defaults.split(",")]
assert len(fx_defaults) == 13 and fx_defaults[-1] == 0.0
assert 'rigChip(chips, @"B POL INV", state->uiController, @selector(controlChanged:), 59)' in ui
assert "state->cab2PolarityButton = invertB;" in ui
assert "if (port == 59)" in state and "cab2PolarityButton.state = inverted ?" in state
ui_ttl = (ROOT / "resources/neural_amp_modeler_rig_ui.ttl.in").read_text()
for symbol in ("cab2_delay", "cab2_polarity"):
    assert re.search(rf'lv2:symbol "{symbol}"\s*;\s*ui:notifyType atom:Float', ui_ttl), (
        f"UI must subscribe to host automation of {symbol}"
    )
reset = re.search(r"- \(void\)resetAllKnobs:[^\n]*\{(.*?)\n\}", ui, re.S).group(1)
assert "_state->sendControl(59, 0.0f);" in reset and "_state->updateControl(59, 0.0f);" in reset
quick_preset = re.search(r"- \(void\)applyCabConsolePreset:[^\n]*\{(.*?)\n\}", ui, re.S).group(1)
assert "sendControl(59," not in quick_preset and "updateControl(59," not in quick_preset, (
    "cabinet quick presets must preserve the independent polarity selection"
)
knob_ports = re.search(r"kRigKnobPorts\s*\{([^}]+)\}", knobs).group(1)
knob_ports = [int(value) for value in re.findall(r"\d+", knob_ports)]
mins = re.search(r"kRigKnobCount> mins\s*\{([^}]+)\}", ui).group(1)
maxes = re.search(r"kRigKnobCount> maxes\s*\{([^}]+)\}", ui).group(1)
mins = [float(value.strip()) for value in mins.split(",")]
maxes = [float(value.strip()) for value in maxes.split(",")]
assert mins[knob_ports.index(49)] == -10.0 and maxes[knob_ports.index(49)] == 10.0
assert re.search(r'case 49:.*std::fabs\(value\).*@"%\+\.2f ms"', theme), (
    "negative alignment must display its sign instead of OFF"
)
assert "plugin_->ports.audio_out_r = outputR_.data();" in standalone, (
    "the standalone host must give the right channel its own buffer"
)
assert "std::copy_n(outputR_.data(), frames," in standalone, (
    "the standalone host must actually render the right DSP output"
)
print("  PASS  Cab B, stereo IRs, delay and reverb are append-only and fully wired")
