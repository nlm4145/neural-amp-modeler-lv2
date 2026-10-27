# Axe FX (`neural-amp-modeler-lv2`) — AI Agent Guide

High-signal navigation index and operational rules for AI coding assistants (Antigravity, Claude Code, Codex).

## 1. Canonical Sources of Truth (Do Not Duplicate)
- **Architecture & DSP Signal Chain**: [`ARCHITECTURE.md`](ARCHITECTURE.md) — Complete source layout, append-only LV2 port map, URIDs, real-time audio thread invariants, and UI design tokens.
- **Control & Data Contract**: [`src/rig_control_contract.h`](src/rig_control_contract.h) — Canonical schema of all 108+ knobs, toggles, enums, and ranges.
  - **Never hand-edit `src/rig_control_contract.h`**. Edit [`src/rig_knobs.cpp`](src/rig_knobs.cpp) / [`src/nam_rig_plugin.h`](src/nam_rig_plugin.h) / [`resources/neural_amp_modeler_rig.ttl.in`](resources/neural_amp_modeler_rig.ttl.in) and regenerate via:
    ```bash
    python3 scripts/generate_rig_control_contract.py
    ```
- **Studio Pro Deck UI Rule**: [`.agents/rules/studio-deck-slot-presets.md`](.agents/rules/studio-deck-slot-presets.md) — Every rack slot in `addLowerStudioDeck` (`src/nam_rig_ui.mm`) must use `addSlotPresetDropdown(...)` with both factory and user preset CRUD actions (`Save Preset`, `Save Preset As…`, `Rename Preset…`, `Delete Preset`).

## 2. Build, Install & Verification Commands
Always use non-interactive flags when running builds or tests from an agent session:

- **Fast incremental compile (no install)**:
  ```bash
  cmake --build build -j8
  ```
- **Full build + install to `/Applications/Axe FX.app` and `~/Library/Audio/Plug-Ins/LV2/`**:
  ```bash
  ./build.sh --no-menu --no-launch
  ```
- **Full test suite (DSP, UI, AI Copilot, Presets, Pin EQ)**:
  ```bash
  ./tests/run_all.sh
  ```
- **Targeted tests (prefer during iteration)**:
  - AI Copilot & parser: `python3 tests/test_ai_tone.py`
  - Port & contract alignment: `python3 tests/test_ports.py`
  - Preset serialization: `python3 tests/test_presets.py`
  - DSP numerical regression: `python3 tests/test_dsp.py`
- **SearXNG Local Search Service** ([`tools/searxng/README.md`](tools/searxng/README.md)):
  - Start / auto-launch: `./searxng.sh start`
  - Query (CLI): `./searxng.sh search "query"`
  - Query (JSON API): `./searxng.sh json "query"` (or `curl http://localhost:8080/search?q=query&format=json`)
  - Health & status: `./searxng.sh status`
  - Reclaim port: `./searxng.sh reclaim`

## 3. Codebase Landmarks for Large Files
Avoid reading entire multi-thousand-line files into context. Read targeted line ranges instead:

### [`src/nam_rig_ui.mm`](src/nam_rig_ui.mm) (~6,300 lines)
- **Lines 1–210**: Helpers, layout constants, stage card subviews, Pin EQ interactive view.
- **Lines 211–2217**: `@implementation NAMRigUIController` — Core controller, preset bar, stage cards (Pedal/Amp/Cab), knob wiring, model/IR file browsers.
- **Lines 2218–3179**: `@implementation NAMRigUIController (AICopilot)` — AI Copilot drawer, Riff Recorder/Renderer UI, A/B auditioning, AI provider settings modal.
- **Lines 3180–3368**: `addToneBrowser(...)` — Tone3000 cloud browser tab.
- **Lines 3369–3726**: `NAMRigHeaderBar` / `NAMRigRootView` — Top window chrome, tab switcher, meter/tuner header.
- **Lines 3727–6182**: `addLowerStudioDeck(...)` — Studio Pro Deck tabs (*Post-FX Studio*, *Power Stage & Iron*, *Cab Lab & Speaker*, *Pre/Post Pin EQ*).
- **Lines 6183–end**: `extern "C"` LV2 UI descriptor (`instantiate`, `cleanup`, `port_event`, `extension_data`).

### [`src/nam_rig_plugin.cpp`](src/nam_rig_plugin.cpp) (~2,700 lines)
- **Lines 1–450**: Lifecycle, port connections, URID mapping, state save/restore.
- **Lines 451–1150**: Background LV2 worker thread (NAM model loading, WAV IR loading/resampling, polyphase oversampler rebuilds).
- **Lines 1151–2700**: `process(...)` real-time DSP loop (Input -> Gate/Comp -> Overdrive -> Pedal NAM -> Pre-EQ -> Amp NAM -> Power Stage/Transformer -> Cab IR/Speaker -> Post-EQ -> Space FX -> Output).

### [`src/rig_ai_copilot.mm`](src/rig_ai_copilot.mm) (~1,550 lines)
- **Lines 1–420**: Provider/model resolvers (`agy`, `claude`, `codex`, Gemini, OpenAI, Anthropic, Ollama), keychain & settings persistence, `jev` semantic candidate pre-ranking (`rankCandidatesWithJev:prompt:`).
- **Lines 421–980**: Prompt assembly (`buildSystemPromptWithCurrentRig:`), telemetry formatting, audio attachment encoding.
- **Lines 981–1550**: `generatePresetForPrompt:...` execution, local CLI `NSTask` runner with timeout/cancel handling, and HTTP provider requests.

## 4. Token Efficiency & Local Tools
- **Jev (`quicksilver`)**: `~/.local/bin/jev` is installed both as a runtime pre-prompt candidate filter inside `src/rig_ai_copilot.mm` and as an agent skill. When scanning large logs, triaging many files, or locating lines in large files, offload bulk filtering to `jev` (`jev locate`, `jev filter`, `jev rank`) before reading full files into context.
- **Live Rig MCP Server**: When `Axe FX.app` or the LV2 plugin is running, it exposes a local HTTP server on `127.0.0.1:49162` bridged via [`scripts/axe_fx_mcp.py`](scripts/axe_fx_mcp.py) (`axe_fx_*` MCP tools).
