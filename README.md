# neural-amp-modeler-lv2

LV2 plugin for neural network machine learning amp model playback using the [NeuralAudio](https://github.com/mikeoliphant/NeuralAudio) engine.

**There is no custom plugin user interface**. Setting the model to use requires that your LV2 host supports atom:Path parameters. Reaper does as of v6.82. Carla and Ardour do (although the current stable version of Carla has [another issue](https://github.com/mikeoliphant/neural-amp-modeler-lv2/issues/118)). If your favorite LV2 host does not support atom:Path, let them know you want it.
If you are looking for a GUI version, @brummer10 [has one here](https://github.com/brummer10/neural-amp-modeler-ui) that works for Linux and Windows. You may also be interested in the the version shipped with the [MOD Desktop App](https://github.com/moddevices/mod-desktop-app), or my digital pedalboard app [Stompbox](https://github.com/mikeoliphant/Stompbox).

To get the intended behavior, **you must run your audio host at the same sample rate the model was trained at** (usually 48kHz) - no resampling is done by the plugin. An exception to this is oversampling (running at an even multiple of the model sample rate). See the "[Oversampling](https://github.com/mikeoliphant/neural-amp-modeler-lv2/blob/main/README.md#oversampling)" section below.

For amp-only models (the most typical), **you will need to run an impulse reponse after this plugin** to model the cabinet.

## Usage

Your DAW should expose the following input controls:

**Input:** - Input (pre-model) gain in dB.

**Output:** - Output (post-model) volume in dB.

**Quality:** - Model quality (if applicable). For NAM A2 models, a value below 0.5 will give you a "lite" model and a value above 0.5 will give you a "full" model.

**Model:** - The model file (ie: xxx.nam) to use.

## Models Supported and Performance

The plugin supports both [Neural Amp Modeler (NAM)](https://github.com/sdatkinson/neural-amp-modeler) models (both A1 and A2) and [RTNeural keras json models](https://github.com/jatinchowdhury18/RTNeural) (like those used by [Aida-X](https://github.com/AidaDSP/AIDA-X)).

The best source of models is [Tone3000](https://www.tone3000.com/).

For more information on model type support and performance, see the [NeuralAudio](https://github.com/mikeoliphant/NeuralAudio) repository, which is where the model handling code lives.

## Input Calibration

The expected input level to the plugin is 12dBu. For models that include input level information, they will be calibrated against this level. If you know the input level of your audio interface, you should adjust the input level relative to the expected 12dBu to provide the appropriate signal level to the model.

## Oversampling

If you run at a sample rate that is an even multiple of the model sample rate, the model will be correctly oversampled to behave as expected. So, if the model sample rate is 48kHz (which they typically are), and you are running at 96kHz, the model will be 2x oversampled. This also means that if your DAW supports oversampling, you can safely use it. Running oversampled comes with a signficant performance cost, but can be useful for reducing aliasing.

## Testing

Pre-compile DSP validators (Python, numpy) — run before `./build.sh` when
touching `src/wav_ir.cpp` or the tuner in `src/nam_rig_plugin.cpp`:

```bash
./tests/run_all.sh
```

- `tests/test_wav_ir_resample.py` — mirrors `WavIR` resampling/normalization
  (DC gain, sample-rate-invariant IR transfer gain, response peak/loudness,
  equal-rate identity, round-trip RMSE, and 170 ms truncation). The length test pins the
  count/position ratio distinction that once produced a 1/4-length output.
- `tests/test_tuner_mpm.py` — mirrors the tuner's McLeod NSDF pipeline and
  asserts pitch accuracy (<5¢) on synthetic guitar tones at 48k and 96k,
  including low E (the 96 kHz case that broke v1) and palm mute.
- `tests/verify_tuner.c` loads the built rig via `RIG_SO` (defaults to the
  installed plugin), without models. At 48/96 kHz and 64/512/2048-sample
  blocks it checks early-sustain acquisition, attack/tail exclusion, jitter
  smoothing, re-pluck tuning, string changes, noise rejection, decay/silence
  clearing, notifications, and disable/re-enable reset.
  Missing plugins or harness build failures fail the suite. Live rate-change resets cannot be
  tested through the exposed LV2 interface. Run it independently with:

  ```bash
  clang -O2 -Ideps/lv2/include tests/verify_tuner.c -o /tmp/verify_tuner
  /tmp/verify_tuner build/src/neural_amp_modeler_rig.so
  ```

The C++ harnesses in `tests/verify_*.cpp` cover the DSP blocks directly and
are built ad hoc by `run_all.sh`:

- `verify_amp_advanced.cpp` — the virtual power stage: Presence/Depth deliver
  their requested dB at any Negative Feedback setting, Sag lowers headroom
  (rather than applying static gain reduction), Master compresses, and the
  loop stays bounded at 768 kHz.
- `verify_output_transformer.cpp` — per-profile bandwidth, voicing and core
  drive, plus the flux-domain signature: every profile compresses 82 Hz more
  than 1 kHz when driven, and none of them adds a low resonance.
- `verify_speaker_dynamics.cpp` — the impedance curve's low resonance AND
  rising voice-coil inductance, Negative Feedback damping flattening both,
  excursion-only Speaker Drive, and whole-token cab-name matching.
- `verify_space_fx.cpp` — `AlignDelay` sample accuracy, `StereoDelay` timing,
  damping and soft-limited feedback, and `PlateReverb` decay/size/damping/
  pre-delay with exact bypass.
- `verify_wav_ir.cpp` — partitioned-FFT convolution vs direct reference,
  the 170 ms limit, and stereo-IR channel loading.
- `verify_control_work.cpp` — gate configuration caching and Pin EQ target
  hoisting: exact bypass, automation, resets, rate changes and unchanged
  32-sample smoothing boundaries. Optional before/after comparison and
  microbenchmarks use a snapshot of the original headers:

  ```bash
  cmake --build build --target verify_control_work
  build/src/verify_control_work
  # Snapshot src/dynamics.h and src/pin_eq.h from the revision being compared.
  clang++ -O3 -std=c++17 -Isrc -DBASELINE_HEADERS=/absolute/snapshot/src \
    tests/verify_control_work.cpp -o /tmp/verify_control_work_ab
  /tmp/verify_control_work_ab --bench
  ```

Direct C++ DSP harness compiler failures fail the suite and show diagnostics rather
than silently skipping coverage. Accelerate-only harnesses run on macOS.

Shared-host regression checks are also included: `verify_standalone_worker.cpp`
covers FIFO byte copying, response contention and shutdown ownership;
`verify_standalone_controls.cpp` verifies flat/segmented port binding;
`verify_rig_control_metadata.cpp` checks TTL symbol parity, platform defaults
and Windows preset round trips. `test_win32_audio_stop.py` exercises delayed
WASAPI callback shutdown with fake platform APIs on a native C++ toolchain.

Note: `tests/test_a2_fast_ring_copy.py` currently FAILS. That is a real lost
optimization in the `NeuralAudio` submodule, not a stale assertion — see the
test's docstring.

See `ARCHITECTURE.md` for the DSP↔UI port contract, worker model-swap chain,
and the Tone3000 API/OAuth rules.

### Tuner reference

The tuner measures early sustain rather than the sharp initial attack or late
decay. After detecting a pluck, it excludes the first 300 ms from the analysis
window and requires three confident pitch estimates agreeing within 3 cents
before displaying a new result (typically around 500 ms). Updates stop one
second after the pluck or when the level stays below 25% of its attack peak
for 40 ms, whichever comes first. Low-level windows are not used during that
40 ms grace period either.
The last accepted reading is held through the tail and the next attack;
silence clears it. These are practical heuristics, not a guarantee of a
universally ideal measurement instant for every instrument.

Pluck once, let the reading settle, adjust, then pluck again to refresh it.
Very short or rapidly repeated notes may never provide an eligible sustain
window. Turning the tuner on during a quiet late tail may similarly require
a fresh pluck before it can report a pitch.

### Cabinet alignment and polarity

The rig's Dual-Cabinet Blend Console provides signed alignment and a
`B POL INV` toggle:

| Port | Symbol | Range / Default | Meaning |
|---|---|---|---|
| 49 | `cab2_delay` | -10 to +10 ms / 0 | Negative delays Cab A; positive delays Cab B; zero adds no user delay. |
| 59 | `cab2_polarity` | 0 or 1 / 0 | Cab B polarity: 0 = normal, 1 = inverted. |

Pipeline latency compensation is unchanged. Presets and A/B snapshots save
polarity; legacy presets without it restore normal polarity. Reset to Default
also restores normal polarity. Cabinet quick presets preserve your selected
polarity.

## Building

### Quick start (macOS)

To simultaneously build and install both the LV2 plugin (for hosts/DAWs like Element) and the native standalone application (`/Applications/Axe FX.app`):

```bash
./build.sh
```

In a terminal, the script opens a settings menu before building:

```text
Axe FX Build Settings
Parallel models: ON
Threaded NAM cabinets: OFF
Smart bypass (single-model LV2 only): OFF
Launch: auto
1  Toggle parallel models (macOS standalone)
2  Toggle threaded NAM cabinets (experimental, macOS standalone)
3  Toggle smart bypass (single-model LV2 only, not the rig)
4  Cycle launch: auto / standalone / element / none
Enter or b: build and install    q: quit
```

Processing choices are remembered in that build directory's CMake cache. The
threading choices become installed-app defaults, including normal Finder/Dock
launches; they do not depend on terminal environment variables. The initial
defaults are parallel models ON, threaded cabinets OFF, and smart bypass OFF.
The launch choice applies only to the current build. Audio-device settings,
oversampling, models, and presets are not changed by the menu.

This single script:
1. Configures CMake and compiles both the LV2 plugin bundle and the native macOS standalone app in parallel.
2. Installs the LV2 bundle to `~/Library/Audio/Plug-Ins/LV2/neural_amp_modeler.lv2`.
3. Signs `Axe FX.app` with a persistent local identity (preserving macOS Microphone/TCC permissions) and installs it to `/Applications/Axe FX.app`.
4. Relaunches whichever application was running (`Element` or `Axe FX`), or launches `Axe FX` if neither was running.

Options:
- `./build.sh --no-menu` builds without prompting, reusing cached processing choices.
- `./build.sh --menu` forces the menu, even with piped input.
- `./build.sh --dry-run` previews settings and the configure command without building, installing, or saving changes.
- `./build.sh --no-launch` — build and install without launching applications.
- `./build.sh --element` — specifically launch/reopen Element.
- `./build.sh --standalone` — specifically launch/reopen Axe FX standalone.

Non-interactive input/output automatically skips the menu. For scripted overrides:

```bash
BUILD_PARALLEL_MODELS=ON BUILD_PARALLEL_CABS=ON BUILD_SMART_BYPASS=OFF ./build.sh --no-menu
```

These overrides accept `ON` or `OFF` and take precedence over the cached settings.
Parallel model and cabinet processing apply to the macOS standalone only. Smart
bypass affects only the original single-model LV2 plugin, not Axe FX's rig.

### Manual build

First clone the repository:
```bash
git clone --recurse-submodules -j4 https://github.com/mikeoliphant/neural-amp-modeler-lv2
cd neural-amp-modeler-lv2/build
```

Then compile using:

**Linux/MacOS**
```bash
cmake .. -DCMAKE_BUILD_TYPE="Release"
make -j4
```

**Windows**
```bash
cmake.exe -G "Visual Studio 17 2022" -A x64 ..
cmake --build . --config=release -j4
```

Note - you'll have to change the Visual Studio version if you are using a different one.

After building, the plugin will be in **build/neural_amp_modeler.lv2** (and on macOS, the standalone app will be in **build/src/Axe FX.app**).

#### Experimental dual-NAM cabinet threading

Enable threaded NAM cabinets in the build menu to process Cab B on a prestarted
real-time helper while Cab A runs on the audio thread. For a temporary override:

```bash
AXE_FX_PARALLEL_CABS=1 "build-standalone/src/Axe FX.app/Contents/MacOS/Axe FX"
```

This applies only when both enabled cabinets are NAM models. WAV IRs, single
cabinets, LV2 hosts, and devices without a usable audio workgroup stay serial.
Model quality, oversampling, blend math, and reported latency are unchanged;
each Cab B job completes in the same buffer before mixing. Workgroup membership
helps macOS coordinate the threads, but does not pin them to performance cores
or guarantee a speedup. Wakeup overhead can outweigh savings on small models.
The initial build default is OFF. Use `AXE_FX_PARALLEL_CABS=0` for a temporary
opt-out when the installed build has threading enabled.

Build and run the worker/lifecycle and bit-equality checks independently:

```bash
cmake --build build-standalone --target verify_cabinet_worker verify_parallel_cabs
build-standalone/src/verify_cabinet_worker
build-standalone/src/verify_parallel_cabs --benchmark
```

### Oversampled model CPU

#### Multicore models (macOS standalone)

Multicore models start enabled in the build menu. Build and install normally with
`./build.sh`; the selected default also applies when launching the local build:

```bash
"build/src/Axe FX.app/Contents/MacOS/Axe FX"
```

For a serial comparison, quit the running app and launch with the explicit opt-out:

```bash
AXE_FX_PARALLEL_MODELS=0 "/Applications/Axe FX.app/Contents/MacOS/Axe FX"
```

Eligible oversampled WaveNets distribute their independent native-rate phases
across the audio thread and up to three prestarted real-time helpers in the
device's audio workgroup. The pool is shared by the pedal, amp and Cab A; those
stages still execute in signal-chain order. Cab B does not use this pool and can
use the separate `AXE_FX_PARALLEL_CABS=1` option. Total helper count respects the
workgroup's parallel-thread limit. The terminal reports the enabled helper count.

Models without separable phases, phase blocks shorter than 32 samples, LV2 hosts,
and devices without a usable workgroup retain serial processing. Every published
job finishes before the buffer returns; no extra buffering or reported latency
is introduced. Workgroup scheduling is best effort, not a dropout guarantee.
Use the serial opt-out if helper scheduling causes problems on a particular device.
`AXE_FX_PARALLEL_MODELS=1` temporarily enables processing in a build configured OFF.

Compare exact output and offline callback timings (including deadline overruns):

```bash
cmake --build build --target verify_parallel_polyphase
build/src/verify_parallel_polyphase --benchmark
```

The executor hook lives in the NeuralAudio submodule's `PolyphaseModel.h`; keep
that submodule change together with this feature when sharing the checkout.

At True Nx (and at any host rate that is a multiple of the model rate) NeuralAudio
runs a WaveNet as N native-rate copies instead of one dilation-scaled model; the
output is the same to float rounding, and each copy uses the fast static / A2
kernels (plus an ARM NEON 8-channel kernel). To verify and to A/B it:

```bash
cmake --build build --target verify_polyphase_model nam_bench
build/src/verify_polyphase_model [extra.nam ...]
build/src/nam_bench --base 96000 --factors 1,2,4,8 --polyphase 0 model.nam   # legacy
build/src/nam_bench --base 96000 --factors 1,2,4,8 --polyphase 1 model.nam   # polyphase
```

## CMake Options

```-DUSE_NATIVE_ARCH=ON```: If you have a relatively modern x64 processor, you can pass ```-DUSE_NATIVE_ARCH=ON``` on your cmake command line to enable certain processor-specific optimizations.

```-DSMART_BYPASS_ENABLED=ON```: In the original single-model LV2 plugin only, bypass model processing after sufficiently long silence (below -100 dB by default). This does not enable smart bypass in the rig/standalone app.

```-DAXE_FX_PARALLEL_MODELS_DEFAULT=ON``` / ```-DAXE_FX_PARALLEL_CABS_DEFAULT=OFF```: Set macOS standalone threading defaults; these are the options controlled by the build menu. Runtime `AXE_FX_PARALLEL_MODELS=0|1` and `AXE_FX_PARALLEL_CABS=0|1` overrides take precedence.

Also see the [NeuralAudio CMake options](https://github.com/mikeoliphant/NeuralAudio#cmake-options) - adding these to your neural-amp-modeler-lv2 cmake will pass them to the NeuralAudio build.
