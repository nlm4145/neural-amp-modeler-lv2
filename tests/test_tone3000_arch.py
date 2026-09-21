#!/usr/bin/env python3
"""Guard Tone3000 architecture badges, segmented download control, and context menu contract."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ui = (ROOT / "src/nam_rig_ui.mm").read_text()
browser_h = (ROOT / "src/rig_tone_browser.h").read_text()
browser_mm = (ROOT / "src/rig_tone_browser.mm").read_text()

# 1. Verify ToneItem architecture properties
assert "@property(nonatomic) NSInteger a2Count;" in browser_h, "ToneItem missing a2Count property"
assert "@property(nonatomic) NSInteger a1Count;" in browser_h, "ToneItem missing a1Count property"
assert "@property(nonatomic) NSInteger customCount;" in browser_h, "ToneItem missing customCount property"
assert "@property(nonatomic) NSInteger irsCount;" in browser_h, "ToneItem missing irsCount property"

# 2. Verify ToneBrowserController segmented control and download methods
assert "@property(nonatomic, strong) NSSegmentedControl* archControl;" in browser_h, "ToneBrowserController missing archControl"
assert "@property(nonatomic, copy) NSString* selectedArch;" in browser_h, "ToneBrowserController missing selectedArch"
assert "- (void)archChanged:(id)sender;" in browser_h, "ToneBrowserController missing archChanged: declaration"
assert "- (void)downloadTone:(ToneItem*)item withArch:(NSString*)arch;" in browser_h, "ToneBrowserController missing downloadTone:withArch: declaration"

# 3. Verify ToneCardItem context menu callback
assert "@property(nonatomic, copy) void (^onDownloadArch)(ToneItem*, NSString*);" in browser_h, "ToneCardItem missing onDownloadArch callback"

# 4. Verify archControl mounted in UI search row with 4 pill segments
assert 'controller.archControl = [NSSegmentedControl segmentedControlWithLabels:@[@"A2 Default", @"A1 Legacy", @"Custom", @"All"]' in ui, \
    "UI missing segmented control with A2 Default, A1 Legacy, Custom, All labels"
assert "[browser addSubview:controller.archControl];" in ui, "archControl must be mounted to browser"
assert "controller.archControl.segmentDistribution = NSSegmentDistributionFillEqually;" in ui, \
    "archControl segments must be equally distributed"

# 5. Verify format parsing in toneItem()
assert "item.a2Count = [tone[@\"a2_models_count\"]" in browser_mm, "toneItem() must parse a2_models_count"
assert "item.a1Count = [tone[@\"a1_models_count\"]" in browser_mm, "toneItem() must parse a1_models_count"
assert "item.customCount = [tone[@\"custom_models_count\"]" in browser_mm, "toneItem() must parse custom_models_count"
assert "item.irsCount = [tone[@\"irs_count\"]" in browser_mm, "toneItem() must parse irs_count"

# 6. Verify card badge formatting in setRepresentedObject:
assert 'if (item.a2Count > 0) [badges addObject:[NSString stringWithFormat:@"A2 (%ld)", (long)item.a2Count]];' in browser_mm, \
    "ToneCardItem must format A2 badge with count"
assert 'if (item.a1Count > 0) [badges addObject:[NSString stringWithFormat:@"A1 (%ld)", (long)item.a1Count]];' in browser_mm, \
    "ToneCardItem must format A1 badge with count"
assert 'if (item.customCount > 0) [badges addObject:[NSString stringWithFormat:@"Custom (%ld)", (long)item.customCount]];' in browser_mm, \
    "ToneCardItem must format Custom badge with count"
assert 'if (item.irsCount > 0) [badges addObject:[NSString stringWithFormat:@"IR (%ld)", (long)item.irsCount]];' in browser_mm, \
    "ToneCardItem must format IR badge with count"

# 7. Verify dynamic right-click context menu options
assert 'Download A2 Models' in browser_mm, "Context menu must include Download A2 Models option"
assert 'Download A1 Legacy Models' in browser_mm, "Context menu must include Download A1 Legacy Models option"
assert 'Download Custom Models' in browser_mm, "Context menu must include Download Custom Models option"
assert 'Download All Formats' in browser_mm, "Context menu must include Download All Formats option"

# 8. Verify paginated model fetching in downloadTone:withArch:
assert "fetchModelsForToneId:(NSInteger)toneId arch:(NSString*)arch page:(NSInteger)page" in browser_mm, \
    "downloadTone:withArch: must paginate /models endpoint"

# 9. Verify model filename collision disambiguation
assert 'archSuffix = model[@"architecture_version"]' in browser_mm, \
    "downloadModelStep must disambiguate colliding model filenames across architectures"

# 10. Verify preview vs favorite-only library download contract
assert "- (void)previewTone:(ToneItem*)item withArch:(NSString*)arch;" in browser_h, \
    "ToneBrowserController missing previewTone:withArch: declaration"
assert "previewCacheDir()" in browser_mm, \
    "rig_tone_browser.mm missing previewCacheDir helper"
assert "if (item.favorite) {" in browser_mm, \
    "collectionView:didSelectItemsAtIndexPaths must branch on item.favorite"
assert "[self previewTone:item withArch:self.selectedArch];" in browser_mm, \
    "collectionView:didSelectItemsAtIndexPaths must preview non-favorited tones"
assert "[strongSelf downloadTone:item withArch:strongSelf.selectedArch];" in browser_mm, \
    "toggleFavoriteFromCard must download newly favorited tones to library"
assert "cachedSearchPageForPath(p, 3600.0)" in browser_mm, \
    "fetchModelsForToneId must cache model lists to avoid repeat network requests"

print("  PASS  Tone3000 architecture badges, segmented control, and download contract verified")
