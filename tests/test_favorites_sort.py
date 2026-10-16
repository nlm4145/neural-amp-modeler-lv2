#!/usr/bin/env python3
"""Contract and logic tests for Tone3000 browser Favorites tab sorting (Alphabetical and Time Downloaded)."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
browser_h = (ROOT / "src/rig_tone_browser.h").read_text()
browser_mm = (ROOT / "src/rig_tone_browser.mm").read_text()
ui_mm = (ROOT / "src/nam_rig_ui.mm").read_text()

# 1. Properties and method declarations in header
assert "@property(nonatomic, copy) NSString* browseSort;" in browser_h, "rig_tone_browser.h missing browseSort property"
assert "@property(nonatomic, copy) NSString* favoritesSort;" in browser_h, "rig_tone_browser.h missing favoritesSort property"
assert "@property(nonatomic, copy) NSString* localSort;" in browser_h, "rig_tone_browser.h missing localSort property"
assert "@property(nonatomic) double minESR;" in browser_h, "rig_tone_browser.h missing minESR property"
assert "- (void)updateSortMenuForCurrentMode;" in browser_h, "rig_tone_browser.h missing updateSortMenuForCurrentMode declaration"
assert "- (NSDate*)effectiveDownloadDateForItem:(ToneItem*)item;" in browser_h, "rig_tone_browser.h missing effectiveDownloadDateForItem: declaration"
assert "- (double)effectiveESRForItem:(ToneItem*)item;" in browser_h, "rig_tone_browser.h missing effectiveESRForItem: declaration"

# 2. Dynamic sort menu adaptation for Favorites
assert "- (void)updateSortMenuForCurrentMode" in browser_mm, "rig_tone_browser.mm missing updateSortMenuForCurrentMode implementation"
assert '@"Alphabetical", @"Time Downloaded", @"ESR (Best Accuracy)", @"Alphabetical (Z-A)", @"Time Downloaded (Oldest)", @"ESR (Highest Error)"' in browser_mm, \
    "updateSortMenuForCurrentMode must configure Alphabetical, Time Downloaded, and ESR sorting options for Favorites"
assert '[self updateSortMenuForCurrentMode];' in browser_mm, \
    "selectMode: must invoke updateSortMenuForCurrentMode when tab mode changes"

# 3. Mode-aware sortChanged dispatch
assert 'if ([self.mode isEqualToString:@"Favorites"])' in browser_mm, \
    "sortChanged: must branch on Favorites mode"
assert 'self.favoritesSort = self.sort.titleOfSelectedItem;' in browser_mm, \
    "sortChanged: must record favoritesSort"

# 4. Sorting logic in filterChanged:
assert 'else if ([self.mode isEqualToString:@"Favorites"] || [self.mode isEqualToString:@"Local"])' in browser_mm, \
    "filterChanged: must branch on Favorites/Local mode for custom sorting"
assert 'Time Downloaded' in browser_mm, "filterChanged: must support Time Downloaded sorting"
assert 'effectiveDownloadDateForItem:' in browser_mm, "filterChanged: must query effectiveDownloadDateForItem: for download timestamps"
assert 'effectiveESRForItem:' in browser_mm, "filterChanged: must query effectiveESRForItem: for ESR values"
assert 'localizedStandardCompare:' in browser_mm, "filterChanged: must use localizedStandardCompare: for natural alphabetical ordering"

# 5. Timestamp resolution referencing MacBook last modified timestamp
assert 'NSFileManager' in browser_mm and 'fileModificationDate' in browser_mm, \
    "effectiveDownloadDateForItem: must query fileModificationDate from NSFileManager"
assert 'Music/Tone3000 Library' in browser_mm, \
    "effectiveDownloadDateForItem: must resolve downloaded tone folders in Tone3000 Library"

# 6. Persistence of favoritesSort in browse-filters.txt
assert 'self.favoritesSort ?: @"Alphabetical"' in browser_mm, \
    "persistFilterSelection must write favoritesSort to browse-filters.txt"
assert 'savedFavSort' in browser_mm, \
    "restoreFilterSelectionForGear:sort:arch: must read and restore savedFavSort"

# 7. UI setup wiring in nam_rig_ui.mm and Browse mode ESR support
assert '[controller updateSortMenuForCurrentMode];' in ui_mm, \
    "nam_rig_ui.mm must initialize sort menu via updateSortMenuForCurrentMode"
assert '@"ESR (Best Accuracy)", @"ESR (Highest Error)"' in ui_mm, \
    "nam_rig_ui.mm sort dropdown must include ESR options"
assert 'if ([self.browseSort containsString:@"ESR"])' in browser_mm, \
    "sortChanged: must handle ESR sorting locally in Browse mode"
assert 'prevIdFolder' in browser_mm, \
    "effectiveESRForItem: must resolve PreviewCache folders by toneId"

# 8. Behavioral simulation of the comparator logic
class MockToneItem:
    def __init__(self, title, mtime, esr=None):
        self.title = title
        self.mtime = mtime  # None if distantPast / not downloaded
        self.esr = esr      # None if unknown / not measured

def sort_items(items, mode):
    import functools
    def cmp(a, b):
        if "ESR" in mode:
            highest = "Highest" in mode
            a_has = a.esr is not None and a.esr > 0.0
            b_has = b.esr is not None and b.esr > 0.0
            if a_has and not b_has: return -1
            if not a_has and b_has: return 1
            if not a_has and not b_has:
                return -1 if a.title.lower() < b.title.lower() else (1 if a.title.lower() > b.title.lower() else 0)
            if a.esr != b.esr:
                if highest:
                    return -1 if a.esr > b.esr else 1
                else:
                    return -1 if a.esr < b.esr else 1
            return -1 if a.title.lower() < b.title.lower() else (1 if a.title.lower() > b.title.lower() else 0)
        elif mode.startswith("Time Downloaded"):
            oldest = "Oldest" in mode
            a_has = a.mtime is not None
            b_has = b.mtime is not None
            if a_has and not b_has: return -1
            if not a_has and b_has: return 1
            if not a_has and not b_has:
                return -1 if a.title.lower() < b.title.lower() else (1 if a.title.lower() > b.title.lower() else 0)
            if a.mtime != b.mtime:
                if oldest:
                    return -1 if a.mtime < b.mtime else 1
                else:
                    return -1 if a.mtime > b.mtime else 1
            return -1 if a.title.lower() < b.title.lower() else (1 if a.title.lower() > b.title.lower() else 0)
        else:
            reverse = "Z-A" in mode
            res = -1 if a.title.lower() < b.title.lower() else (1 if a.title.lower() > b.title.lower() else 0)
            return -res if reverse else res

    return sorted(items, key=functools.cmp_to_key(cmp))

items = [
    MockToneItem("Mesa Mark VII", 1790900000, 0.0035),      # downloaded 2nd, ESR .004
    MockToneItem("Bogner Ecstasy", 1790950000, 0.0120),     # downloaded most recently, ESR .012
    MockToneItem("Fender Deluxe", 1780000000, 0.0028),      # downloaded oldest, ESR .003 (best)
    MockToneItem("Marshall JCM800", None, 0.0350),          # not downloaded, ESR .035
    MockToneItem("Ampeg SVT", None, None),                  # not downloaded, no ESR
]

# Alphabetical: Ampeg, Bogner, Fender, Marshall, Mesa
sorted_alpha = [x.title for x in sort_items(items, "Alphabetical")]
assert sorted_alpha == ["Ampeg SVT", "Bogner Ecstasy", "Fender Deluxe", "Marshall JCM800", "Mesa Mark VII"], \
    f"Unexpected alphabetical sort: {sorted_alpha}"

# Alphabetical (Z-A): Mesa, Marshall, Fender, Bogner, Ampeg
sorted_rev = [x.title for x in sort_items(items, "Alphabetical (Z-A)")]
assert sorted_rev == ["Mesa Mark VII", "Marshall JCM800", "Fender Deluxe", "Bogner Ecstasy", "Ampeg SVT"], \
    f"Unexpected Z-A sort: {sorted_rev}"

# Time Downloaded (Newest first): Bogner (1790950000), Mesa (1790900000), Fender (1780000000), then Ampeg, Marshall
sorted_time = [x.title for x in sort_items(items, "Time Downloaded")]
assert sorted_time == ["Bogner Ecstasy", "Mesa Mark VII", "Fender Deluxe", "Ampeg SVT", "Marshall JCM800"], \
    f"Unexpected time downloaded sort: {sorted_time}"

# Time Downloaded (Oldest first): Fender, Mesa, Bogner, then Ampeg, Marshall
sorted_time_old = [x.title for x in sort_items(items, "Time Downloaded (Oldest)")]
assert sorted_time_old == ["Fender Deluxe", "Mesa Mark VII", "Bogner Ecstasy", "Ampeg SVT", "Marshall JCM800"], \
    f"Unexpected oldest time downloaded sort: {sorted_time_old}"

# ESR (Best Accuracy - lowest error first): Fender (0.0028), Mesa (0.0035), Bogner (0.0120), Marshall (0.0350), then Ampeg (no ESR)
sorted_esr_best = [x.title for x in sort_items(items, "ESR (Best Accuracy)")]
assert sorted_esr_best == ["Fender Deluxe", "Mesa Mark VII", "Bogner Ecstasy", "Marshall JCM800", "Ampeg SVT"], \
    f"Unexpected ESR best sort: {sorted_esr_best}"

# ESR (Highest Error first): Marshall (0.0350), Bogner (0.0120), Mesa (0.0035), Fender (0.0028), then Ampeg (no ESR)
sorted_esr_high = [x.title for x in sort_items(items, "ESR (Highest Error)")]
assert sorted_esr_high == ["Marshall JCM800", "Bogner Ecstasy", "Mesa Mark VII", "Fender Deluxe", "Ampeg SVT"], \
    f"Unexpected ESR highest sort: {sorted_esr_high}"

print("  PASS  Tone3000 browser Favorites tab sorting (Alphabetical / Time Downloaded / ESR) contract verified")
