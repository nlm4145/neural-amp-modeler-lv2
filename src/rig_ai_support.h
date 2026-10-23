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

// Semantic gear expansion: translates artist/song/style prompts into associated gear families and acoustic search terms.
NSArray<NSString*>* rigAISuggestGearQueries(NSString* prompt);

// Acoustic profile analyzer: extracts frequency band energies from telemetry strings and calculates delta guidance.
NSString* rigAIAcousticDeltaGuidance(NSString* playerSummary, NSString* _Nullable referenceSummary);

// Returns whether the specified provider and model support the sampling temperature parameter.
// Anthropic deprecated temperature on Claude Opus 4.7+ and Claude 5+ models, and OpenAI reasoning models (o1/o3/o4) reject it.
BOOL rigAIProviderModelSupportsTemperature(NSString* _Nullable provider, NSString* _Nullable model);

#pragma clang diagnostic pop
