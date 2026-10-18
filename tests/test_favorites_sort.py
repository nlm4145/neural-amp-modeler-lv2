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
assert "@property(nonatomic) NSInteger parameterCount;" in browser_h, "rig_tone_browser.h missing parameterCount property"
assert "- (void)updateSortMenuForCurrentMode;" in browser_h, "rig_tone_browser.h missing updateSortMenuForCurrentMode declaration"
assert "- (NSDate*)effectiveDownloadDateForItem:(ToneItem*)item;" in browser_h, "rig_tone_browser.h missing effectiveDownloadDateForItem: declaration"
assert "- (NSInteger)effectiveParameterCountForItem:(ToneItem*)item;" in browser_h, "rig_tone_browser.h missing effectiveParameterCountForItem: declaration"

# 2. Dynamic sort menu adaptation for Favorites
assert "- (void)updateSortMenuForCurrentMode" in browser_mm, "rig_tone_browser.mm missing updateSortMenuForCurrentMode implementation"
assert '@"Alphabetical", @"Time Downloaded", @"Parameters (Lowest)", @"Parameters (Highest)", @"Alphabetical (Z-A)", @"Time Downloaded (Oldest)"' in browser_mm, \
    "updateSortMenuForCurrentMode must configure Alphabetical, Time Downloaded, and Parameters sorting options for Favorites"
assert '[self updateSortMenuForCurrentMode];' in browser_mm, \
    "selectMode: must invoke updateSortMenuForCurrentMode when tab mode changes"

# 3. Mode-aware sortChanged dispatch
assert 'if ([self.mode isEqualToString:@"Favorites"])' in browser_mm, \
    "sortChanged: must branch on Favorites mode"
assert 'self.favoritesSort = self.sort.titleOfSelectedItem;' in browser_mm, \
    "sortChanged: must record favoritesSort"

# 4. Sorting logic in filterChanged:
assert 'else if ([sortChoice containsString:@"Parameters"])' in browser_mm, \
    "filterChanged: must branch on Parameters for custom unrounded sorting"
assert 'Time Downloaded' in browser_mm, "filterChanged: must support Time Downloaded sorting"
assert 'effectiveDownloadDateForItem:' in browser_mm, "filterChanged: must query effectiveDownloadDateForItem: for download timestamps"
assert 'effectiveParameterCountForItem:' in browser_mm, "filterChanged: must query effectiveParameterCountForItem: for exact parameter counts"
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

# 7. UI setup wiring in nam_rig_ui.mm and Browse mode Parameters support
assert '[controller updateSortMenuForCurrentMode];' in ui_mm, \
    "nam_rig_ui.mm must initialize sort menu via updateSortMenuForCurrentMode"
assert '@"Parameters (Lowest)", @"Parameters (Highest)"' in ui_mm, \
    "nam_rig_ui.mm sort dropdown must include Parameters sorting options"
assert 'if ([self.browseSort containsString:@"Parameters"])' in browser_mm, \
    "sortChanged: must handle Parameters sorting locally in Browse mode"

# 8. Behavioral simulation of the comparator logic
class MockToneItem:
    def __init__(self, title, mtime, params=None):
        self.title = title
        self.mtime = mtime  # None if distantPast / not downloaded
        self.params = params  # None if unknown / 0

def sort_items(items, mode):
    import functools
    def cmp(a, b):
        if "Parameters" in mode:
            highest = "Highest" in mode
            a_has = a.params is not None and a.params > 0
            b_has = b.params is not None and b.params > 0
            if a_has and not b_has: return -1
            if not a_has and b_has: return 1
            if not a_has and not b_has:
                return -1 if a.title.lower() < b.title.lower() else (1 if a.title.lower() > b.title.lower() else 0)
            if a.params != b.params:
                if highest:
                    return -1 if a.params > b.params else 1
                else:
                    return -1 if a.params < b.params else 1
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
    MockToneItem("Mesa Mark VII", 1790900000, 14017),    # downloaded 2nd, 14,017 params
    MockToneItem("Bogner Ecstasy", 1790950000, 12410),   # downloaded most recently, 12,410 params
    MockToneItem("Fender Deluxe", 1780000000, 842),      # downloaded oldest, 842 params (fewest)
    MockToneItem("Rivera M100", 1785000000, 89994),      # downloaded 3rd, 89,994 params (most)
    MockToneItem("Marshall JCM800", None, 13802),        # not downloaded, 13,802 params
    MockToneItem("Ampeg SVT", None, None),               # not downloaded, unknown params
]

# Alphabetical: Ampeg, Bogner, Fender, Marshall, Mesa, Rivera
sorted_alpha = [x.title for x in sort_items(items, "Alphabetical")]
assert sorted_alpha == ["Ampeg SVT", "Bogner Ecstasy", "Fender Deluxe", "Marshall JCM800", "Mesa Mark VII", "Rivera M100"], \
    f"Unexpected alphabetical sort: {sorted_alpha}"

# Alphabetical (Z-A): Rivera, Mesa, Marshall, Fender, Bogner, Ampeg
sorted_rev = [x.title for x in sort_items(items, "Alphabetical (Z-A)")]
assert sorted_rev == ["Rivera M100", "Mesa Mark VII", "Marshall JCM800", "Fender Deluxe", "Bogner Ecstasy", "Ampeg SVT"], \
    f"Unexpected Z-A sort: {sorted_rev}"

# Time Downloaded (Newest first): Bogner (1790950000), Mesa (1790900000), Rivera (1785000000), Fender (1780000000), then Ampeg, Marshall
sorted_time = [x.title for x in sort_items(items, "Time Downloaded")]
assert sorted_time == ["Bogner Ecstasy", "Mesa Mark VII", "Rivera M100", "Fender Deluxe", "Ampeg SVT", "Marshall JCM800"], \
    f"Unexpected time downloaded sort: {sorted_time}"

# Time Downloaded (Oldest first): Fender, Rivera, Mesa, Bogner, then Ampeg, Marshall
sorted_time_old = [x.title for x in sort_items(items, "Time Downloaded (Oldest)")]
assert sorted_time_old == ["Fender Deluxe", "Rivera M100", "Mesa Mark VII", "Bogner Ecstasy", "Ampeg SVT", "Marshall JCM800"], \
    f"Unexpected oldest time downloaded sort: {sorted_time_old}"

# Parameters (Lowest - unrounded exact count): Fender (842), Bogner (12,410), Marshall (13,802), Mesa (14,017), Rivera (89,994), Ampeg (no params)
sorted_params_lowest = [x.title for x in sort_items(items, "Parameters (Lowest)")]
assert sorted_params_lowest == ["Fender Deluxe", "Bogner Ecstasy", "Marshall JCM800", "Mesa Mark VII", "Rivera M100", "Ampeg SVT"], \
    f"Unexpected parameters lowest sort: {sorted_params_lowest}"

# Parameters (Highest - unrounded exact count): Rivera (89,994), Mesa (14,017), Marshall (13,802), Bogner (12,410), Fender (842), Ampeg (no params)
sorted_params_highest = [x.title for x in sort_items(items, "Parameters (Highest)")]
assert sorted_params_highest == ["Rivera M100", "Mesa Mark VII", "Marshall JCM800", "Bogner Ecstasy", "Fender Deluxe", "Ampeg SVT"], \
    f"Unexpected parameters highest sort: {sorted_params_highest}"

print("  PASS  Tone3000 browser Favorites tab sorting (Alphabetical / Time Downloaded / Parameters) contract verified")
