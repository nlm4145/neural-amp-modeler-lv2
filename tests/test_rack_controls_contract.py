#!/usr/bin/env python3
"""Guard the append-only deck switches; audio behavior is tested via LV2."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
controls = (ROOT / "src/rack_controls.h").read_text()
header = (ROOT / "src/nam_rig_plugin.h").read_text()
ttl = (ROOT / "resources/neural_amp_modeler_rig.ttl.in").read_text()
ui_ttl = (ROOT / "resources/neural_amp_modeler_rig_ui.ttl.in").read_text()
standalone = (ROOT / "src/standalone_main.mm").read_text()

names = ["Delay", "Reverb", "Spatial", "Power", "Sculpt", "Transformer", "Speaker", "CabConsole", "PowerTube", "Count"]
symbols = ["delay_enabled", "reverb_enabled", "spatial_enabled", "power_enabled",
           "sculpt_enabled", "transformer_enabled", "speaker_enabled", "cab_console_enabled",
           "power_tube_enabled"]
enum = re.search(r"enum class Rack\s*:\s*size_t\s*\{([^}]+)\}", controls)
assert enum and [name.strip() for name in enum.group(1).split(",")] == names
assert "kRackControlFirstPort = 71;" in controls
defaults = re.search(r"kRackControlDefaults\s*=\s*\{([^}]+)\}", controls)
assert defaults and [float(value.strip().removesuffix("f")) for value in defaults.group(1).split(",")] == [1] * 9
shared_symbols = re.search(r"kRackControlSymbols\s*=\s*\{([^}]+)\}", controls)
assert shared_symbols and re.findall(r'"([^"]+)"', shared_symbols.group(1)) == symbols
assert "std::array<float*, kRackCount> rack_enabled;" in header
assert "offsetof(Ports, rack_enabled) == kRackControlFirstPort * sizeof(void*)" in header
assert "kPortCount = kRigControlPortCount;" in header
assert "kRackControlFirstPort + static_cast<size_t>(Rack::PowerTube) == 79" in header
assert "kPowerTubeTypePort == kRackControlFirstPort + kRackCount" in header
assert "kMidPushPort == kPowerTubeCharacterPort + 1" in header
assert "kPinEqFirstPort == kMidPushPort + 1" in header
assert "kOverdriveDrivePort == kPinEqFirstPort + kPinEqPortCount" in header
assert "kPortCount == kOverdriveLevelPort + 1" in header
assert "sizeof(Ports) == kPortCount * sizeof(void*)" in header

for index, symbol in enumerate(symbols, 71):
    block = re.search(rf"\[\s*a lv2:ControlPort, lv2:InputPort\s*;\s*lv2:index {index}\s*;(.*?)\]", ttl, re.S)
    assert block, f"missing rack input port {index}"
    block = block.group(1)
    assert f'lv2:symbol "{symbol}"' in block
    for name, value in (("default", 1), ("minimum", 0), ("maximum", 1)):
        actual = re.search(rf"lv2:{name}\s+([\d.]+)", block)
        assert actual and float(actual.group(1)) == value, f"{symbol} {name}"
    for property_name in ("toggled", "integer", "connectionOptional"):
        assert f"lv2:{property_name}" in block, f"{symbol} {property_name}"
    assert len(re.findall(rf'lv2:symbol "{symbol}"\s*;\s*ui:notifyType atom:Float', ui_ttl)) == 1

assert "rackControls_ = NAMRig::kRackControlDefaults;" in standalone
assert "plugin_->ports.rack_enabled[i] = &rackControls_[i];" in standalone
assert re.search(r"port >= NAMRig::kRackControlFirstPort &&\s*port < NAMRig::kRackControlFirstPort \+ NAMRig::kRackCount", standalone)
print("  PASS  old rack indices 71..78 preserved; Power/Tube appends at 79, default ON and optional")
