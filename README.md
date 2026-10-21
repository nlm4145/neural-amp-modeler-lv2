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

## High-gain compressor presets

In the macOS rig UI (LV2 and standalone), open **PREAMP → Pre-Amp Compressor**
and use its preset dropdown. For clearer solo picking, start with **METAL PICK
CLARITY**. The new presets use modest compression and slower attacks to preserve
the pick transient before leveling the note body.

| Preset | Amount | Attack | Release | Starting point for |
| --- | ---: | ---: | ---: | --- |
| METAL PICK CLARITY | 22% | 35 ms | 70 ms | Defined high-gain solo attacks |
| SHRED DEFINITION | 28% | 25 ms | 50 ms | Fast alternate-picked runs |
| THRASH PRECISION | 18% | 20 ms | 45 ms | Light leveling for aggressive, fast picking |
| SINGING METAL LEAD | 32% | 30 ms | 140 ms | More sustained leads with an audible pick attack |

Selecting an active preset turns the compressor on; **OFF / BYPASS** turns it
off. Use **Save Preset As…** to keep your adjustments. Amount also adds makeup
gain before the amp, so increasing it can add saturation rather than clarity.
If notes still blur, try less Amount or amp gain and compare with bypass; a
heavily saturated amp capture already compresses the signal.

## Testing

Focused local audio checks (no provider requests):

```bash
cmake --build build --target verify_riff_recorder verify_riff_renderer
build/src/verify_riff_recorder
build/src/verify_riff_renderer # optionally pass a .nam path for a short model smoke test
```

### AI Tone Tuning (macOS rig UI and standalone)

Open **AI Tone Tuning** with **⌘K**. Choose a provider, model and API URL,
describe your tone, then click **Preview Tone**. Preview does not change the rig.
**Apply & Save** validates the proposal, waits for engine model-load acknowledgements,
and saves a uniquely named preset without overwriting an existing one. **A/B Toggle**
exchanges it with the prior rig; it does not alter the saved preset file.

Choose **Modify current preset** (load your saved preset first), **Build from scratch**,
or **Refine last proposal**. The base is frozen for each request; applying a proposal
refuses to overwrite live edits made since that request.

In the macOS **standalone app**, **Record Riff** captures the raw mono DI before all
app processing and the full stereo rig output simultaneously, for up to 20 seconds.
It retains the recording-time preset and optional tuning/pickup/interface metadata.
DI float samples remain unnormalized for replay; PCM24 WAVs are used for audition/upload.
External pedals and interface gain are still part of the input, not inferred by the AI.

**Guided 20s take** prompts: 0–2s muted strings (volume unchanged), 2–6s chugs,
6–10s ringing power chords, 10–15s soft/hard low/high single notes, and 15–20s
sustain/decay. These are expected segments, not automatically detected techniques.
For clean/lead tones, substitute representative arpeggios/notes or disable guidance.
Analysis reports DI/output dynamics, clipping, and broad frequency-filter estimates;
it is not a precise spectrum match. Avoid changing rig settings during a take.

After **Preview Tone**, click **Render DI A/B** to render that same DI through the
baseline and candidate with separate production-engine instances, locally and without
changing the live rig. Choose **Baseline (matched)** / **Candidate (matched)** and
**Play** to audition RMS-matched, peak-safe clips. Engine latency is compensated;
two seconds of effect tail are included (long tails can be truncated). Refine with
your listening feedback and another explicit **Preview Tone** request. No automatic
AI loop or retry spends tokens. Takes and auditions are session-local, not preset files.

**Load WAV…** imports a player's processed riff; **Target WAV…** separately imports
an isolated-guitar or full-mix reference. Imports accept mono/stereo PCM16/24/32 or
float32 WAV at 22.05–192 kHz, max 40 MB, using the first 20 seconds. A full mix must
not be treated as isolated guitar EQ. The LV2 UI supports import/text tuning; live
paired capture and DI rendering require the standalone app.

The assistant receives compact rig settings and at most 24 installed-model
candidates from `~/Music/Tone3000 Library`, using `_tone3000.json` metadata where
available. **Telemetry-only is the default** to reduce cost. **Upload audio** is an
explicit opt-in for Gemini models or OpenAI GPT audio-input models (ordinary GPT-4o
is not assumed audio-capable); Claude, Ollama/custom and local CLI receive text only.
Uploads label DI, processed output, and target separately. Candidate feedback stays
local telemetry. Requests cap output at 2048 tokens and audio at four clips / 40 MB;
provider/model availability may still vary. Artist tones are starting points, not
verified reproductions. Full-rig captures require cabinet stages to be bypassed.

API keys are stored per provider in macOS Keychain; legacy plaintext keys are
migrated only after Keychain accepts them. Local CLI fallback is **off by default**
and requires explicit opt-in. It retains CLI permissions; Claude tools are disabled
and Codex runs read-only. Provider requests have a 60-second deadline and can be
cancelled. Use HTTPS endpoints, or HTTP on loopback for Ollama/local servers.

The standalone local API binds to `127.0.0.1:48920`, rejects browser origins, and
requires a bearer token stored with mode `0600` in
`~/Library/Application Support/Axe FX/local-api-token`. `scripts/axe_fx_mcp.py`
reads this token automatically, or uses `AXE_FX_API_TOKEN`. External clients must
send `Authorization: Bearer <token>`. Read `/api/v1/controls/schema` before writing
controls: percentages use **0–100**, EQ trims use **dB with 0 neutral**, and enum IDs
must match the schema. MCP AI requests default to preview (`apply: false`).

The control reference is generated from the shipped LV2 definitions. After changing
`resources/neural_amp_modeler_rig.ttl.in`, run:

```bash
python3 scripts/generate_rig_control_contract.py
python3 tests/test_ai_tone.py
RIG_UI_SO=build-test/src/neural_amp_modeler_rig_ui.so python3 tests/test_ai_tone.py
```

The Foundation validation/catalog tests run without provider access. The optional
built-UI checks cover application, immediate preset capture, repeatable A/B,
cancellation, and authenticated socket routes. AI UI/network integration is currently
macOS-only; the control contract remains portable C++.

### DSP tests

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

### Small-buffer performance checks (macOS)

The standalone phase executor now admits short blocks based on grouped work:
below 32 native samples per phase, it requires at least 16 samples per phase
and 64 samples per thread range. This lets 96 kHz / True 8x / 32-frame buffers
use helpers without threading tiny low-phase-count jobs. No buffering, extra
latency, oversampling reduction, or model quality change is involved.

Stable gain conversions, compressor timing and stereo-width gains are cached;
automation retains the original smoothing, and rate/rounding changes invalidate
the relevant cached values. To verify and benchmark:

```bash
cmake --build build --target verify_parallel_polyphase verify_rig_dsp_cache verify_low_buffer_rig
build/src/verify_parallel_polyphase --benchmark
build/src/verify_rig_dsp_cache
build/src/verify_low_buffer_rig build/src/neural_amp_modeler_rig.so /path/to/baseline/rig.so --bench
```

The before/after rig check compares audio, notifications and latency bit-for-bit
at 48/96/192 kHz with 32/64 and irregular/oversized blocks, automated controls,
model swaps and buffer resizes. Its optional timing uses lightweight model
fixtures to isolate control overhead; it is not a whole-app CPU measurement.
`RIG_BASELINE_SO=/path/to/baseline/rig.so` also enables this comparison in
`tests/run_all.sh`; without it, that test compares two fresh current instances.

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

In a terminal, the script asks for a processing mode before building:

```text
1  Parallel
2  Serial (threaded cabs enabled)
Choice:
```

- `1  Parallel`: multicore models ON, threaded NAM cabinets OFF. This is the
  initial default and the recommended choice.
- `2  Serial (threaded cabs enabled)`: multicore models OFF, threaded NAM
  cabinets ON. Use it to compare the serial model path; the experimental Cab B
  helper thread is enabled in this mode.
- `q`: quit without building.

The script then prints the settings it will use (processing mode, parallel
models, threaded NAM cabinets, smart bypass, launch) and builds. Processing
choices are remembered in that build directory's CMake cache. The threading
choices become installed-app defaults, including normal Finder/Dock launches;
they do not depend on terminal environment variables. Smart bypass and the
launch choice are not part of the menu: set smart bypass with the
`BUILD_SMART_BYPASS` variable and the launch with the command-line options
below. Audio-device settings, oversampling, models, and presets are not changed
by the menu.

This single script:
1. Configures CMake and compiles both the LV2 plugin bundle and the native macOS standalone app in parallel.
2. Installs the LV2 bundle to `~/Library/Audio/Plug-Ins/LV2/neural_amp_modeler.lv2`.
3. Signs `Axe FX.app` with a persistent local identity (preserving macOS Microphone/TCC permissions) and installs it to `/Applications/Axe FX.app`.
4. Relaunches whichever application was running (`Element` or `Axe FX`), or launches `Axe FX` if neither was running.

Options:
- `./build.sh --no-menu` builds without prompting, reusing cached processing choices.
- `./build.sh --menu` forces the menu, even with piped input.
- `./build.sh --parallel` / `./build.sh --serial` select the processing mode without the menu.
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
