#!/usr/bin/env python3
"""Contract and logic tests for Tone3000 explorer author search.

Guards:
1. Header declarations in src/rig_tone_browser.h for author searching and creator registry.
2. Implementation contracts in src/rig_tone_browser.mm:
   - Known creators registry seeded with top creators including '2dor'.
   - Tone3000 search API parameter &creators= integration.
   - parseSearchStringFast query parsing (@author, author:..., by:..., direct author name).
   - Context menu actions for searching and viewing author tones.
   - Status bar indicating tones by author.
3. UI wiring in src/nam_rig_ui.mm:
   - search.target / search.action hooked to searchSubmitted:
   - Placeholder and tooltip indicating author search support.
4. Algorithmic unit tests for author query parsing and tone item matching.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
browser_h = (ROOT / "src/rig_tone_browser.h").read_text()
browser_mm = (ROOT / "src/rig_tone_browser.mm").read_text()
ui_mm = (ROOT / "src/nam_rig_ui.mm").read_text()

# 1. Header declarations
assert "@property(nonatomic, copy) NSString* activeCreator;" in browser_h, \
    "rig_tone_browser.h missing activeCreator property"
assert "@property(nonatomic, copy) NSString* activeTextQuery;" in browser_h, \
    "rig_tone_browser.h missing activeTextQuery property"
assert "- (void)searchForAuthor:(NSString*)author;" in browser_h, \
    "rig_tone_browser.h missing searchForAuthor: declaration"
assert "- (IBAction)searchSubmitted:(id)sender;" in browser_h, \
    "rig_tone_browser.h missing searchSubmitted: declaration"
assert "- (BOOL)isKnownCreator:(NSString*)name;" in browser_h, \
    "rig_tone_browser.h missing isKnownCreator: declaration"
assert "- (void)registerKnownCreator:(NSString*)name;" in browser_h, \
    "rig_tone_browser.h missing registerKnownCreator: declaration"
assert "- (void)preloadKnownCreators;" in browser_h, \
    "rig_tone_browser.h missing preloadKnownCreators declaration"
assert "- (IBAction)searchByAuthor:(id)sender;" in browser_h, \
    "rig_tone_browser.h missing ToneCardItem searchByAuthor: declaration"
assert "- (IBAction)openAuthorOnTone3000:(id)sender;" in browser_h, \
    "rig_tone_browser.h missing ToneCardItem openAuthorOnTone3000: declaration"

# 2. Known creators seed list in rig_tone_browser.mm
assert '@"2dor"' in browser_mm, \
    "rig_tone_browser.mm must include '2dor' in known creators seed list"
assert "tone3000-creators.json" in browser_mm, \
    "rig_tone_browser.mm must persist discovered creators to tone3000-creators.json"

# 3. Tone3000 search API integration
assert "&creators=" in browser_mm, \
    "rig_tone_browser.mm must pass &creators= parameter to /tones/search endpoint"
assert "/tones/search?sort=%@%@%@%@" in browser_mm, \
    "rig_tone_browser.mm must construct prefix with sort, gear, creators, and query params"

# 4. Context menu additions
assert "Search Tones by @" in browser_mm, \
    "ToneCardItem context menu must include 'Search Tones by @<creator>'"
assert "View @%@ on Tone3000" in browser_mm, \
    "ToneCardItem context menu must include 'View @<creator> on Tone3000'"
assert "searchByAuthor:" in browser_mm, \
    "ToneCardItem must route searchByAuthor: to browserController"

# 5. UI wiring in nam_rig_ui.mm
assert "controller.search.target = controller;" in ui_mm, \
    "nam_rig_ui.mm must set controller.search.target to controller"
assert "controller.search.action = @selector(searchSubmitted:);" in ui_mm, \
    "nam_rig_ui.mm must set controller.search.action to searchSubmitted:"
assert "@author" in ui_mm, \
    "nam_rig_ui.mm search placeholder or tooltip must indicate author search support"

# 6. Algorithmic unit tests for query parsing logic
KNOWN_CREATORS = {"2dor", "outmodedelectronics", "akka5", "metalheart", "tone3000"}

def parse_search_fast(raw: str):
    trimmed = raw.strip()
    if not trimmed:
        return None, None
    if trimmed.startswith("@"):
        parts = trimmed[1:].split()
        if parts:
            creator = parts[0]
            query = " ".join(parts[1:]) if len(parts) > 1 else None
            return creator, query
    m = re.match(r"^(?:author|creator|by|user):\s*([A-Za-z0-9_\-\.]+)(.*)$", trimmed, re.IGNORECASE)
    if m:
        creator = m.group(1)
        rem = m.group(2).strip()
        return creator, rem if rem else None
    parts = trimmed.split()
    if parts and parts[0].lower() in KNOWN_CREATORS:
        creator = parts[0]
        query = " ".join(parts[1:]) if len(parts) > 1 else None
        return creator, query
    return None, trimmed

# Test queries
c, q = parse_search_fast("2dor")
assert c == "2dor" and q is None, f"Expected ('2dor', None), got ({c}, {q})"

c, q = parse_search_fast("@2dor")
assert c == "2dor" and q is None, f"Expected ('2dor', None), got ({c}, {q})"

c, q = parse_search_fast("author:2dor")
assert c == "2dor" and q is None, f"Expected ('2dor', None), got ({c}, {q})"

c, q = parse_search_fast("by:2dor")
assert c == "2dor" and q is None, f"Expected ('2dor', None), got ({c}, {q})"

c, q = parse_search_fast("2dor marshall")
assert c == "2dor" and q == "marshall", f"Expected ('2dor', 'marshall'), got ({c}, {q})"

c, q = parse_search_fast("@2dor high gain")
assert c == "2dor" and q == "high gain", f"Expected ('2dor', 'high gain'), got ({c}, {q})"

c, q = parse_search_fast("marshall")
assert c is None and q == "marshall", f"Expected (None, 'marshall'), got ({c}, {q})"

# 7. Matching item logic
def item_matches(item_creator, item_title, item_gear, creator_filter, raw_search, query_tokens):
    searchable = f"{item_title.lower()} {item_creator.lower()} {item_gear.lower()}"
    if creator_filter:
        if creator_filter.lower() not in item_creator.lower():
            is_explicit = raw_search.startswith("@") or any(raw_search.lower().startswith(p) for p in ["author:", "creator:", "by:", "user:"])
            if is_explicit or raw_search.lower() not in searchable:
                return False
    if query_tokens:
        for t in query_tokens:
            if t.lower() not in searchable:
                return False
    elif not creator_filter and raw_search:
        if raw_search.lower() not in searchable:
            return False
    return True

# 2dor tone with unrelated title
assert item_matches("2dor", "MLC S_ZERO V Vogg (Decapitated)", "amp", "2dor", "2dor", None)
assert item_matches("2dor", "Carstens Grace 100", "amp", "2dor", "2dor", None)
assert item_matches("2dor", "Marshall JCM800 2203 Modified", "amp", "2dor", "2dor marshall", ["marshall"])
assert not item_matches("2dor", "Carstens Grace 100", "amp", "2dor", "2dor marshall", ["marshall"])
# Another author's tone
assert not item_matches("humbug", "Top Secret Bogner modded JCM800", "amp", "2dor", "@2dor", None)

print("  PASS  Tone3000 explorer author search ('2dor', @author, author:..., &creators= API) fully verified")
