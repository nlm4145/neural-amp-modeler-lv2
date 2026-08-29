# NAM Oversampled Rig — Architecture

This documents the DSP↔UI contract and the project's hard-won conventions so
future changes (human or agent) don't have to re-derive them. Ground truth:
`src/nam_rig_plugin.h` / `src/nam_rig_plugin.cpp` (DSP),
`resources/neural_amp_modeler_rig.ttl.in` (port map),
`src/nam_rig_ui.mm` + `src/rig_*.mm` (UI).

## Source layout (since the 2026-08 file split)

| File | Role |
|---|---|
| `src/nam_rig_lv2.cpp` | LV2 descriptor: instantiate/run/cleanup, extension data (options, state, worker) |
| `src/nam_rig_plugin.{h,cpp}` | Rig DSP: 3 serial stages (Pedal/Amp/Cab), EQ, tuner, worker model-swap chain |
| `src/wav_ir.{h,cpp}` | Cab-stage `.wav` IR: direct `vDSP_conv` convolution, load-time normalize + windowed-sinc resample |
| `src/nam_rig_ui.mm` | LV2 UI glue: `RigUIState` (via `rig_ui_state.h`), `NAMRigUIController`, layout/zoom, `instantiate`/`portEvent` |
| `src/rig_ui_state.h` | `RigUIState` struct: URIDs, LV2 write fn, stage views, UI-side persistence |
| `src/rig_theme.{h,mm}` | Dark palette (`rigBG`…`rigOrange`) + `rigKnobValueText` |
| `src/rig_knobs.{h,cpp}` | `kRigKnobPorts` / `kRigKnobDisplayOrder` (display order = signal chain, not port order) |
| `src/rig_tone_api.{h,mm}` | Tone3000 API base URL, OAuth/PKCE, keychain sessions, gear/stage mapping |
| `src/rig_tone_browser.{h,mm}` | Tone Explorer: `ToneItem`, `ToneCardItem`, `RigButton`, `ToneBrowserController` (search pagination, disk cache, downloads, favorites) |

## Port map (rig plugin) — APPEND-ONLY, never renumber

| Index | Symbol | Dir | Meaning |
|---|---|---|---|
| 0 | `control` | in | Atom sequence (patch messages) |
| 1 | `notify` | out | Atom sequence (DSP→UI patch:Set) |
| 2/3 | `input`/`output` | audio | |
| 4 | `input_level` | in | dB |
| 5 | `output_level` | in | dB |
| 6 | `quality_scale` | in | fixed 1.0 (knob removed) |
| 7/8/9 | `pedal_enabled`/`amp_enabled`/`cab_enabled` | in | toggles |
| 10 | `auto_cab` | in | toggle (always on) |
| 11 | `cab_auto_bypassed` | out | 1 when amp is a full-rig model |
| 12/13/14 | `bass`/`mid`/`treble` | in | dB |
| 15 | `gate_threshold` | in | dB, −80 = OFF |
| 16 | `tuner_enable` | in | toggle |
| 17 | `tuner_note` | out | MIDI note, −1 = none |
| 18 | `tuner_cents` | out | ±50 |

New ports go AFTER index 18. Saved Element sessions restore by index —
renumbering breaks them.

## DSP→UI messaging

- **Continuous/host-polled values** (e.g. `cab_auto_bypassed`, tuner ports):
  plain output control ports; UI reads them in `portEvent` (format 0).
- **Human-rate UI updates** (tuner note/cents): `patch:Set` objects forged into
  the `notify` port from `process()`, keyed by URIs
  `…#rig-tuner-note` / `…#rig-tuner-cents` (defined in BOTH
  `nam_rig_plugin.h` and mirrored as `#define`s in `nam_rig_ui.mm` — the UI
  target must NOT include the DSP header, it drags NeuralAudio in).
  Sends are CHANGE-GATED (only on note change / ≥2¢ drift) so the notify
  stream never floods.
- **UI→DSP**: `patch:Set` with `atom:Path` on properties
  `…#rig-{pedal,amp,cab}-model`, scheduled onto the worker thread.

## Worker model-swap chain (the only correct pattern here)

UI sends path → `work()` loads the model OFF the audio thread →
`workResponse()` (audio thread) swaps pointers and schedules a deferred
`kWorkTypeFree` for the OLD model → worker deletes it later. Never load or
free on the audio thread; never touch `rig->models[]` from `work()`.

## UI-side persistence (Element-specific)

LV2 State `save/restore` is host-driven and does NOT run on a plain app
switch that recreates the plugin instance, and the DSP worker chain never
fires for loads in Element. So the UI is the single source of truth:
`RigUIState::sendPath()` writes path + thumbnail URL + toneId to
`~/Library/Application Support/NAM Oversampled Rig/rig-model-paths.txt`, and
`restoreSelectedPaths()` re-sends at the end of `instantiate()`. Do not add
DSP-side persistence hooks — they are dead code in this host.

## "Oversampling" reality

NeuralAudio's oversampling multiplies WaveNet dilations by
`hostRate/modelRate` at LOAD time. There is no resampler. Consequences:

- Only `architecture == "WaveNet"` models are rate-adapted; **LSTM models never are**.
- Only works when `hostRate % modelRate == 0`; otherwise the model silently
  runs at the wrong rate (detuned). `modelRate` defaults to 48000 if absent.
- Changing host rate requires reloading every model
  (`loader.SetExternalSampleRate()` must precede `CreateFromFile()`).

## Tone3000 integration rules

- Search pagination is **cache-first and lazy** (disk cache,
  `~/Library/Application Support/NAM Oversampled Rig/SearchCache`,
  SHA1(request path).json, 10-min TTL; page 1 per search, more on scroll).
  Eager full pagination trips the rate limit (100 req/min) and gets the
  machine WAF-403-blocked.
- OAuth login is **manual-only**: the browser opens from exactly ONE place —
  the Connect button. Background paths (instantiate, timers, 401 handlers)
  are silent-only; on failure show an inline "Not connected" state.
- Search results keep their OWN array in server order; favorites/local items
  append AFTER — never interleaved.

## Build & install

`./build.sh` = cmake configure → build → install bundle to
`~/Library/Audio/Plug-Ins/LV2/neural_amp_modeler.lv2/` → ad-hoc codesign →
dlopen smoke check. Build intermediates live OUTSIDE the repo. A rebuilt
`.so` does nothing until the DAW re-instantiates the plugin (reload Element).
