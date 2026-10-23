#!/usr/bin/env python3
"""Guard the hierarchical profile categorization and library menus on stage cards and popups."""
import os, sys, re, json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ui = (ROOT / "src/nam_rig_ui.mm").read_text()
state = (ROOT / "src/rig_ui_state.h").read_text()
presets = (ROOT / "src/rig_presets.mm").read_text()
catalog_h = (ROOT / "src/rig_profile_catalog.h").read_text()
catalog_mm = (ROOT / "src/rig_profile_catalog.mm").read_text()

# 1. Verify RigProfileCatalog declarations
assert "@interface RigProfileCatalog" in catalog_h, "RigProfileCatalog header missing interface"
assert "stageCardLibraryMenuItemForStage:" in catalog_h, "RigProfileCatalog missing stageCardLibraryMenuItemForStage:"
assert "modelPickerLibraryMenuItemForStage:" in catalog_h, "RigProfileCatalog missing modelPickerLibraryMenuItemForStage:"
assert "allModelPathsForModelPath:" in catalog_h, "RigProfileCatalog missing allModelPathsForModelPath:stage: in header"
assert "allModelPathsForModelPath:(NSString*)modelPath stage:(size_t)stage" in catalog_mm, \
    "RigProfileCatalog missing allModelPathsForModelPath:stage: implementation"

# 2. Verify discoverModelsForStagePath calls RigProfileCatalog for classified model consolidation
assert "allModelPathsForModelPath:pathStr stage:stage" in presets, \
    "discoverModelsForStagePath must query RigProfileCatalog for all models of the classified model"

# 3. Verify NAMRigUIController interface and implementation
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

# 4. Verify context menu (right-click) integration in menuNeedsUpdate:
assert "stageCardLibraryMenuItemForStage:(size_t)stage" in ui, \
    "menuNeedsUpdate: must offer library menu for stage 0 and stage 1"
assert "stageCardLibraryMenuItemForStage:2" in ui, \
    "menuNeedsUpdate: must offer library menu for Cab A (stage 2)"
assert "stageCardLibraryMenuItemForStage:3" in ui, \
    "menuNeedsUpdate: must offer library menu for Cab B (stage 3)"

# 5. Verify model picker popup button integration
assert "modelPickerLibraryMenuItemForStage:" in state, \
    "setStageModels must append modelPickerLibraryMenuItemForStage: to popup menu"

# 6. Verify arrow key cycling ignores submenu items and cycles all models
assert "!it.hasSubmenu" in ui, \
    "cycleSelectedStageModel must ignore submenu items"
assert "alreadyAvailable" in ui, \
    "stageModelChanged must avoid unnecessary rebuild when cycling models already in the picker"

# 7. Verify restoreSelectedPaths discovers models on launch
assert "discoverModelsForStagePath(path, i)" in state, \
    "restoreSelectedPaths must discover classified models to populate pickers on launch"

# 8. Verify specific model rules exist (Brand > Specific Model > all .nam files)
for kw in ["Powerball II", "Powerball", "Dual Rectifier", "Triple Rectifier", "Badlander", "Mark IV", "Ecstasy 101B", "Uberschall", "5150", "VH4"]:
    assert kw in catalog_mm, f"RigProfileCatalog missing model rule for '{kw}'"

# 9. Verify no intermediate pack submenus: all captures are added directly under the model submenu
assert "[modelSubmenu addItem:item];" in catalog_mm, \
    "RigProfileCatalog must add capture items directly to modelSubmenu"

# 10. Run compiled runtime verification if clang++ is available
import subprocess
try:
    cmd = [
        "clang++", "-std=c++20", "-fobjc-arc", "-Isrc",
        "-framework", "Cocoa", "-framework", "Foundation",
        str(ROOT / "tests/verify_profile_catalog.mm"),
        str(ROOT / "src/rig_profile_catalog.mm"),
        "-o", "/tmp/verify_profile_catalog"
    ]
    subprocess.check_call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.check_call(["/tmp/verify_profile_catalog"])
except Exception as e:
    print(f"Warning: runtime verification skipped/failed: {e}", file=sys.stderr)
    raise

print("  PASS  Direct 3-tier profile categorization & full-model arrow cycling verified")
