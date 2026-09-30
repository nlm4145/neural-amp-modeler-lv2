---
trigger: always_on
description: Studio Pro Deck slots must use a preset dropdown menu (with factory + user-saved presets) instead of preset chip buttons.
---

# Studio Pro Deck — Slot Preset Dropdown Rule

Whenever creating or modifying a pane or rack slot in the Studio Pro Deck (`addLowerStudioDeck` in `src/nam_rig_ui.mm` and `RigUIState` in `src/rig_ui_state.h`):

1. **Always use `addSlotPresetDropdown(...)`** for the slot's preset selector instead of a horizontal row of `rigChip` preset buttons.
2. **Support both factory and user-created presets**:
   - Populate the dropdown with the slot's factory presets.
   - Include user-saved presets for that slot key (persisted in `~/Library/Application Support/Axe FX/slot-presets.json`).
   - Provide `Save Preset`, `Save Preset As…`, and `Delete Preset` menu actions so the user can create, update, and delete custom presets for every slot.
