#!/usr/bin/env python3
"""Guard the hierarchical profile categorization and library menus on stage cards and popups."""
import os, sys, re, json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ui = (ROOT / "src/nam_rig_ui.mm").read_text()
state = (ROOT / "src/rig_ui_state.h").read_text()
catalog_h = (ROOT / "src/rig_profile_catalog.h").read_text()
catalog_mm = (ROOT / "src/rig_profile_catalog.mm").read_text()

# 1. Verify RigProfileCatalog declarations
assert "@interface RigProfileCatalog" in catalog_h, "RigProfileCatalog header missing interface"
assert "stageCardLibraryMenuItemForStage:" in catalog_h, "RigProfileCatalog missing stageCardLibraryMenuItemForStage:"
assert "modelPickerLibraryMenuItemForStage:" in catalog_h, "RigProfileCatalog missing modelPickerLibraryMenuItemForStage:"

# 2. Verify NAMRigUIController interface and implementation
assert "- (void)selectLibraryModelItem:(NSMenuItem*)sender;" in ui, \
    "NAMRigUIController missing selectLibraryModelItem: declaration"
assert "discoverModelsForStagePath(path.fileSystemRepresentation, stage)" in ui, \
    "selectLibraryModelItem: must discover sibling models for chosen profile"
assert "_state->setStageModels(stage, paths);" in ui, \
    "selectLibraryModelItem: must populate stage models"
assert "_state->sendPath(stage, path.fileSystemRepresentation);" in ui, \
    "selectLibraryModelItem: must send path to DSP"
assert "_state->updateThumbnailForStagePath(stage, path);" in ui, \
    "selectLibraryModelItem: must update stage thumbnail"

# 3. Verify context menu (right-click) integration in menuNeedsUpdate:
assert "stageCardLibraryMenuItemForStage:(size_t)stage" in ui, \
    "menuNeedsUpdate: must offer library menu for stage 0 and stage 1"
assert "stageCardLibraryMenuItemForStage:2" in ui, \
    "menuNeedsUpdate: must offer library menu for Cab A (stage 2)"
assert "stageCardLibraryMenuItemForStage:3" in ui, \
    "menuNeedsUpdate: must offer library menu for Cab B (stage 3)"

# 4. Verify model picker popup button integration
assert "modelPickerLibraryMenuItemForStage:" in state, \
    "setStageModels must append modelPickerLibraryMenuItemForStage: to popup menu"

# 5. Verify arrow key cycling ignores submenu items
assert "!it.hasSubmenu" in ui, \
    "cycleSelectedStageModel must ignore submenu items"

# 6. Verify specific model rules exist (Brand > Specific Model > all .nam files)
for kw in ["Powerball II", "Powerball", "Dual Rectifier", "Triple Rectifier", "Badlander", "Mark IV", "Ecstasy 101B", "Uberschall", "5150", "VH4"]:
    assert kw in catalog_mm, f"RigProfileCatalog missing model rule for '{kw}'"

# 7. Verify no intermediate pack submenus: all captures are added directly under the model submenu
assert "[modelSubmenu addItem:item];" in catalog_mm, \
    "RigProfileCatalog must add capture items directly to modelSubmenu"

print("  PASS  Direct 3-tier profile categorization (Brand > Model > .nam) verified")
