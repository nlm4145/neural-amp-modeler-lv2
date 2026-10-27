#pragma once
#import <Foundation/Foundation.h>
#import "rig_ai_copilot.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Wnullability-completeness-on-arrays"

// Foundation-only validation/catalog helpers, shared by the copilot and local API.
NSString* rigAIControlReference();
BOOL rigAIValidateControls(NSDictionary* controls, NSError** error);
RigAICopilotResult* rigAIParseResponse(NSString* content, NSError** error);
// Reject provider-declared output truncation before parsing incomplete JSON.
BOOL rigAIValidateProviderCompletion(NSDictionary* response, NSError** error);
NSArray<NSDictionary*>* rigAILibraryCandidates(NSString* root, NSString* query, NSUInteger limit);
// Same shortlist plus the installed per-stage totals (index 0 pedal, 1 amp, 2 cab) so the
// prompt can state whether the catalog is complete or a ranked excerpt.
NSArray<NSDictionary*>* rigAILibraryCandidatesWithTotals(NSString* root, NSString* query, NSUInteger limit,
                                                        NSUInteger totals[3]);
NSArray<NSDictionary*>* rigAILibraryCandidatesWithTotalsAndScores(NSString* root, NSString* query, NSUInteger limit,
                                                                 NSUInteger totals[3], NSUInteger maxScores[3]);
// "none" removes a pedal or cabinet capture instead of selecting one.
BOOL rigAIIsNoneModel(NSString* target);
NSString* rigAIResolveModel(NSString* root, NSString* target, NSUInteger stage, NSError** error);
BOOL rigAIModelIncludesCab(NSString* path);
// Compact index of every installed pack (one entry per "Amp/<folder>", "Cab/<folder>", ... or loose
// file) so the AI can match an artist's documented gear against the whole library, not only the
// keyword-ranked excerpt. Entries: pack, stage, captures, optional title/includes_cab.
NSArray<NSDictionary*>* rigAILibraryPackIndex(NSString* root, NSUInteger maxEntries);
// When the AI names a pack folder instead of a capture file, pick the best capture inside it for
// the stage (query words in filenames first, then plain rhythm captures). Returns a library-relative
// path, or nil when target is not a pack folder.
NSString* _Nullable rigAIResolvePackCapture(NSString* root, NSString* target, NSUInteger stage, NSString* _Nullable query);
// Exact neural-network weight count of a .nam file (0 when unreadable or not a .nam).
NSInteger rigAINamParameterCount(NSString* path);
// Filename with size/architecture words (xSTD, lite, feather, nano, A1, A2, ...) removed, so the
// same capture exported at different network sizes shares one key.
NSString* rigAIProfileKey(NSString* filename);
// Architecture of an installed capture: @"custom", @"2" (A2) or @"1" (A1), from the Tone3000
// manifest or "(A1)/(A2)" in the filename; nil when unknown.
NSString* _Nullable rigAICaptureArchitecture(NSString* root, NSString* relative);
// Once a capture is chosen, return the best sibling in the same folder with the same profile key:
// architecture first (Custom > A2 > A1 > unknown), then highest parameter count. Returns the
// original path when it is already the best. Optional outputs report chosen/original parameter counts.
NSString* rigAIHighestCapacityVariant(NSString* root, NSString* relative, NSUInteger stage,
                                      NSInteger* _Nullable outParams, NSInteger* _Nullable outOriginalParams);

// Platform-agnostic web search via a local SearXNG instance. Returns a compact snippet block
// ready to embed in a gear-research prompt, or nil when SearXNG is unreachable or misconfigured.
// Only loopback HTTP and any HTTPS URLs are permitted; credentials in the URL are rejected.
NSString* _Nullable rigAIWebSearchForGear(NSString* query, NSString* searxngURL);

// Locate searxng.sh in repo, bundle, or standard Axe FX locations.
NSString* _Nullable rigAIFindSearxngScript(void);

// Checks if SearXNG is running on localhost:8080, and spins up searxng.sh start in the background if needed.
void rigAIEnsureSearxngRunning(void (^ _Nullable completion)(BOOL success, NSString* message));

// Gear research: a preliminary AI lookup of the gear documented for an artist/album/song/style
// request. Replies are normalized and cached on disk (Application Support/Axe FX).
NSString* rigAIGearResearchSystemPrompt();
NSString* rigAIGearResearchUserMessage(NSString* prompt, NSString* _Nullable presetContext);
// Validates/normalizes a lookup reply (kind, artist/album/song, amps/cabs/pedals, search_terms); nil if unusable.
NSDictionary* _Nullable rigAIParseGearResearch(NSString* _Nullable content);
// Tests point the cache at a temporary file; nil restores the default location.
void rigAIGearResearchSetCachePath(NSString* _Nullable path);
NSDictionary* _Nullable rigAIGearResearchCached(NSString* prompt);
void rigAIGearResearchStore(NSString* prompt, NSDictionary* research);
// Cached research for free text: the exact prompt, else an artist entry named in the text.
// specificOnly additionally requires the same song (or album, for album-level entries).
NSDictionary* _Nullable rigAIGearResearchMatching(NSString* text, BOOL specificOnly);
// Whole-word, case- and punctuation-insensitive phrase match ("Vol. 3" matches "vol 3").
BOOL rigAITextNamesPhrase(NSString* text, NSString* _Nullable phrase);
// One-line description for the progress log ("Artist / Album / Song; amps …; cabs …; pedals …").
NSString* rigAIGearResearchSummary(NSDictionary* research);
// Gear search terms (primary amp first) from cached research; empty when nothing is cached.
NSArray<NSString*>* rigAISuggestGearQueries(NSString* prompt);

// Acoustic profile analyzer: extracts frequency band energies from telemetry strings and calculates delta guidance.
NSString* rigAIAcousticDeltaGuidance(NSString* playerSummary, NSString* _Nullable referenceSummary);

// Returns whether the specified provider and model support the sampling temperature parameter.
// Anthropic deprecated temperature on Claude Opus 4.7+ and Claude 5+ models, and OpenAI reasoning models (o1/o3/o4) reject it.
BOOL rigAIProviderModelSupportsTemperature(NSString* _Nullable provider, NSString* _Nullable model);

#pragma clang diagnostic pop
