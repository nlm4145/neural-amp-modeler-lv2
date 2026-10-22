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

// Returns whether the specified provider and model support the sampling temperature parameter.
// Anthropic deprecated temperature on Claude Opus 4.7+ and Claude 5+ models, and OpenAI reasoning models (o1/o3/o4) reject it.
BOOL rigAIProviderModelSupportsTemperature(NSString* _Nullable provider, NSString* _Nullable model);

#pragma clang diagnostic pop
