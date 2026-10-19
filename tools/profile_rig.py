#!/usr/bin/env python3
"""Build an instrumented offline rig snapshot without modifying production DSP.

Usage: python3 tools/profile_rig.py --scratch /approved/temp/path [--build build]
       [--blocks 300] preset.json [preset.json ...]
Uses the already-built Release NeuralAudio objects from --build on macOS.
"""
import argparse
import pathlib
import shlex
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]


def instrument_calls(text, symbol, category):
    start = 0
    while True:
        pos = text.find(symbol + "(", start)
        if pos < 0:
            return text
        end = text.index(";", pos) + 1
        original = text[pos:end]
        replacement = "{ RigProfile::Scope profile(RigProfile::" + category + "); " + original + " }"
        text = text[:pos] + replacement + text[end:]
        start = pos + len(replacement)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch", required=True, type=pathlib.Path)
    parser.add_argument("--build", default=ROOT / "build", type=pathlib.Path)
    parser.add_argument("--blocks", default=300, type=int)
    parser.add_argument("presets", nargs="+")
    args = parser.parse_args()
    scratch = args.scratch.resolve()
    scratch.mkdir(parents=True, exist_ok=True)
    sources = scratch / "src"
    sources.mkdir(exist_ok=True)
    for file in (ROOT / "src").iterdir():
        if file.is_file() and file.suffix in (".h", ".cpp"):
            shutil.copy2(file, sources / file.name)
    shutil.copy2(ROOT / "tools/rig_profile.h", sources / "rig_profile.h")
    plugin = (sources / "nam_rig_plugin.cpp").read_text()
    plugin = '#include "rig_profile.h"\n' + plugin
    marker = "void Plugin::process(uint32_t sampleCount, uint64_t deadlineTicks) noexcept {"
    assert marker in plugin
    plugin = plugin.replace(marker, marker + "\n  RigProfile::Scope profile(RigProfile::Total);")
    marker = "float* samples, size_t count, double domainRate) noexcept {"
    assert marker in plugin
    plugin = plugin.replace(marker, marker + "\n  RigProfile::Scope profile(static_cast<RigProfile::Category>(RigProfile::Pedal + stage));")
    marker = "const auto processEffects = [&] {"
    assert marker in plugin
    plugin = plugin.replace(marker, marker + "\n      RigProfile::Scope profile(RigProfile::Effects);")
    marker = "const float thresholdDb = -12.0f - 24.0f * compAmount;"
    assert marker in plugin
    plugin = plugin.replace(marker, "RigProfile::Scope profile(RigProfile::Compressor);\n    " + marker)
    for symbol, category in [("overdrive.process", "Boost"), ("ampAdvanced.processPreAmp", "Sculpt"),
                             ("ampAdvanced.processPostAmp", "Power"), ("outputTransformer.process", "Transformer"),
                             ("speakerDynamics.process", "Speaker")]:
        plugin = instrument_calls(plugin, symbol, category)
    for symbol in ["sculptPins.process", "transformerPins.process", "speakerPins.process", "consolePins.process"]:
        plugin = instrument_calls(plugin, symbol, "Pins")
    (sources / "nam_rig_plugin.cpp").write_text(plugin)
    for filename, markers, category in [
        ("oversample.cpp", ["size_t Up2x::process(", "size_t Down2x::process("], "Converters"),
        ("wav_ir.cpp", ["void WavIR::process("], "IR")]:
        text = '#include "rig_profile.h"\n' + (sources / filename).read_text()
        for marker in markers:
            pos = text.index("{", text.index(marker)) + 1
            text = text[:pos] + "\n  RigProfile::Scope profile(RigProfile::" + category + ");" + text[pos:]
        (sources / filename).write_text(text)
    # Reuse the current build's exact engine objects (including existing local
    # dependency edits), but compile DSP without LTO so scopes stay observable.
    build = args.build.resolve()
    link = shlex.split((build / "src/CMakeFiles/neural_amp_modeler_rig.dir/link.txt").read_text())
    objects = [str(build / "src" / p) for p in link if p.endswith(".o") and "NeuralAudio/" in p]
    archives = [str(build / "src" / p) for p in link if p.endswith(".a")]
    assert objects, "build the Release rig target first"
    includes = [sources, ROOT / "deps/NeuralAudio", ROOT / "deps/lv2/include", ROOT / "deps/denormal",
                ROOT / "deps/NeuralAudio/deps/RTNeural/modules/json",
                ROOT / "deps/NeuralAudio/deps/RTNeural/modules/Eigen"]
    binary = scratch / "profile_rig"
    command = ["clang++", "-O3", "-std=c++20", "-mcpu=native", "-ffp-contract=fast", "-DNDEBUG",
               "-DEIGEN_NO_DEBUG", "-DRTNEURAL_DEFAULT_ALIGNMENT=16", "-DRTNEURAL_NAMESPACE=RTNeural",
               "-DRTNEURAL_USE_EIGEN=1", "-DDISABLE_DENORMALS", "-pthread"]
    command += ["-I" + str(p) for p in includes]
    command += [str(ROOT / "tools/profile_rig.cpp")]
    command += [str(sources / p) for p in ["nam_rig_plugin.cpp", "cabinet_worker.cpp", "oversample.cpp", "wav_ir.cpp", "dsp_accel.cpp", "rig_knobs.cpp"]]
    command += objects + archives + ["-framework", "Accelerate", "-o", str(binary)]
    subprocess.run(command, cwd=build / "src", check=True)
    subprocess.run([str(binary), "--blocks", str(args.blocks), *args.presets], check=True)


if __name__ == "__main__":
    main()
