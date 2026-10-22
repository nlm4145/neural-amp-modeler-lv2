#pragma once
#import <Foundation/Foundation.h>
#import "rig_ai_copilot.h"

// Foundation-only validation/catalog helpers, shared by the copilot and local API.
NSString* rigAIControlReference();
BOOL rigAIValidateControls(NSDictionary* controls, NSError** error);
RigAICopilotResult* rigAIParseResponse(NSString* content, NSError** error);
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

// Semantic gear expansion: translates artist/song/style prompts into associated gear families and acoustic search terms.
NSArray<NSString*>* rigAISuggestGearQueries(NSString* prompt);

// Acoustic profile analyzer: extracts frequency band energies from telemetry strings and calculates delta guidance.
NSString* rigAIAcousticDeltaGuidance(NSString* playerSummary, NSString* _Nullable referenceSummary);
