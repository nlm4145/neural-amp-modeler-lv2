#import "rig_ai_support.h"
#include "speaker_dynamics.h"
#include "rig_control_metadata.h"
#include <cstdio>
#include <limits>

static int failures = 0;
#define CHECK(x) do { if (!(x)) { ++failures; std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); } } while (0)

int main(int argc, char** argv) {
  @autoreleasepool {
    CHECK(argc == 2);
    if (argc != 2) return 1;
    NSString* root = [NSString stringWithUTF8String:argv[1]];
    NSError* error = nil;
    CHECK(rigAIValidateControls(@{@"bass": @-2, @"od_tone": @62, @"delay_mix": @25,
        @"speaker_profile": @6, @"input_eq": @45, @"bias": @-20}, &error));
    for (NSDictionary* bad in @[@{@"bass": @13}, @{@"bass": @"5"}, @{@"bass": NSNull.null},
          @{@"unknown": @1}, @{@"quality_scale": @1}, @{@"speaker_profile": @8},
          @{@"speaker_profile": @3.5}, @{@"power_tube_type": @5}, @{@"amp_oversample": @2},
          @{@"ir_normalization": @0}, @{@"bass": @YES}, @{@"delay_mix": @101},
          @{@"master": @(std::numeric_limits<double>::infinity())}]) {
      error = nil;
      CHECK(!rigAIValidateControls(bad, &error) && error);
    }
    CHECK(rigAIValidateControls(@{@"cab_enabled": @YES}, nil));
    CHECK([rigAIControlReference() containsString:@"3=Open Back"]);
    CHECK([rigAIControlReference() containsString:@"6=Modern 4x12"]);
    CHECK([rigAIControlReference() containsString:@"7=True 16x"]);
    CHECK(![rigAIControlReference() containsString:@"quality_scale:"]);
    NSString* json = @"{\"controls\":{\"bass\":-2,\"od_tone\":62},\"amp_model\":\"Amp/A/clean.nam\"}";
    CHECK(rigAIParseResponse(json, nil).controls[@"od_tone"].floatValue == 62);
    CHECK(rigAIParseResponse([NSString stringWithFormat:@"```json\n%@\n```", json], nil));
    CHECK(rigAIParseResponse([NSString stringWithFormat:@"```json\n%@", json], nil));
    CHECK(rigAIParseResponse([NSString stringWithFormat:@"```json\r\n%@\r\n```", json], nil));
    CHECK(!rigAIParseResponse(@"```json\n{\"controls\":{\"bass\":-2", nil));
    CHECK(!rigAIParseResponse([NSString stringWithFormat:@"```json\n%@\nextra text", json], nil));
    for (NSDictionary* response in @[
        @{@"stop_reason":@"max_tokens"},
        @{@"choices":@[@{@"finish_reason":@"length"}]},
        @{@"candidates":@[@{@"finishReason":@"MAX_TOKENS"}]}]) {
      error = nil;
      CHECK(!rigAIValidateProviderCompletion(response, &error));
      CHECK([error.localizedDescription containsString:@"output-token limit"]);
    }
    for (NSDictionary* response in @[@{}, @{@"stop_reason":@"end_turn"},
        @{@"choices":@[@{@"finish_reason":@"stop"}]}, @{@"candidates":@[@{@"finishReason":@"STOP"}]},
        @{@"stop_reason":NSNull.null, @"choices":@[NSNull.null]}])
      CHECK(rigAIValidateProviderCompletion(response, nil));
    NSString* searchJson = @"{\"controls\":{\"bass\":0},\"search_tone3000\":\"Mick Thomson Slipknot\"}";
    RigAICopilotResult* searchRes = rigAIParseResponse(searchJson, nil);
    CHECK(searchRes && [searchRes.searchTone3000 isEqualToString:@"Mick Thomson Slipknot"]);
    for (NSString* bad in @[@"[]", @"{}", @"{\"controls\":null}", @"{\"controls\":{},\"amp_model\":null}",
        @"{\"controls\":{},\"thought\":[]}", @"{\"controls\":{},\"slot_presets\":{\"speaker\":\"x\"}}",
        [@"logs\n" stringByAppendingString:json], [json stringByAppendingString:json]]) CHECK(!rigAIParseResponse(bad, nil));
    CHECK(rigAIResolveModel(root, @"Amp/A/clean.nam", 1, nil));
    CHECK(rigAIResolveModel(root, @"Cab/CabA/mic.wav", 2, nil));
    CHECK(rigAIResolveModel(root, @"Cabinet/Legacy/old.wav", 2, nil));
    CHECK(rigAIResolveModel(root, @"Cab/Nam/cab.nam", 3, nil));
    CHECK(rigAIResolveModel(root, @"unique.nam", 1, nil));
    for (NSString* bad in @[@"clean.nam", @"Amp", @"Amp/A", @"Amp/A/missing.nam", @"Amp/A/empty.nam",
        @"Amp/A/outside.nam", @"../outside.nam", @"clean", @"Cab/CabA/mic.wav"])
      CHECK(!rigAIResolveModel(root, bad, 1, nil));
    CHECK(rigAIModelIncludesCab([root stringByAppendingPathComponent:@"Full Rig/Combo/rig.nam"]));
    CHECK(rigAIModelIncludesCab([root stringByAppendingPathComponent:@"Amp/Full/capture.nam"]));
    CHECK(!rigAIModelIncludesCab(@""));
    NSArray* items = rigAILibraryCandidates(root, @"warm clean boutique", 8);
    CHECK(items.count <= 8);
    BOOL metadata = NO, cab = NO, full = NO;
    for (NSDictionary* item in items) {
      CHECK(![item[@"path"] containsString:@"outside"]);
      CHECK(![item[@"path"] containsString:@"empty"]);
      if ([item[@"path"] isEqual:@"Amp/A/clean.nam"]) metadata = [item[@"description"] containsString:@"warm"];
      if ([item[@"stage"] intValue] == 2) cab = YES;
      if ([item[@"includes_cab"] boolValue]) full = YES;
    }
    CHECK(metadata && cab && full);
    CHECK(rigAILibraryCandidates(root, @"", 0).count == 0);
    NSUInteger scoredTotals[3] = {};
    NSUInteger maxScores[3] = {};
    rigAILibraryCandidatesWithTotalsAndScores(root, @"warm clean boutique", 8, scoredTotals, maxScores);
    CHECK(maxScores[1] > 0);
    rigAILibraryCandidatesWithTotalsAndScores(root, @"nonexistentunknownartist", 8, scoredTotals, maxScores);
    CHECK(maxScores[1] == 0);
    // Pedals are cataloged with totals, and a small library is listed completely.
    NSUInteger totals[3] = {9, 9, 9};
    NSArray* all = rigAILibraryCandidatesWithTotals(root, @"heartland rock", 96, totals);
    CHECK(totals[0] == 1 && totals[1] == 5 && totals[2] == 3);
    CHECK(all.count == totals[0] + totals[1] + totals[2]);
    BOOL pedal = NO;
    for (NSDictionary* item in all) if ([item[@"path"] isEqual:@"Pedal/TS/ts9.nam"]) pedal = [item[@"stage"] intValue] == 0;
    CHECK(pedal);
    NSUInteger small[3] = {};
    NSArray* limited = rigAILibraryCandidatesWithTotals(root, @"", 4, small);
    CHECK(limited.count == 4 && small[1] == 5);
    CHECK(rigAIResolveModel(root, @"Pedal/TS/ts9.nam", 0, nil));
    CHECK(!rigAIResolveModel(root, @"Pedal/TS/ts9.nam", 1, nil));
    // "none" removes a pedal or cab, never the amp.
    CHECK(rigAIIsNoneModel(@"none") && rigAIIsNoneModel(@" None ") && rigAIIsNoneModel(@"bypass"));
    CHECK(!rigAIIsNoneModel(@"") && !rigAIIsNoneModel(@"Amp/A/clean.nam") && !rigAIIsNoneModel((NSString*)NSNull.null));
    RigAICopilotResult* removal = rigAIParseResponse(@"{\"controls\":{},\"pedal_model\":\"none\",\"cab_ir\":\"Cab/CabA/mic.wav\"}", nil);
    CHECK(removal && [removal.pedalPath isEqual:@"none"] && [removal.cabPath isEqual:@"Cab/CabA/mic.wav"]);
    CHECK([rigAIParseResponse(@"{\"controls\":{},\"pedal_path\":\"Pedal/TS/ts9.nam\"}", nil).pedalPath isEqual:@"Pedal/TS/ts9.nam"]);
    error = nil;
    CHECK(!rigAIParseResponse(@"{\"controls\":{},\"amp_model\":\"none\"}", &error) && error);
    CHECK(!rigAIParseResponse(@"{\"controls\":{},\"pedal_model\":3}", nil));
    // Catalog metadata whitespace is collapsed and capped.
    for (NSDictionary* item in all)
      if ([item[@"path"] isEqual:@"Amp/A/clean.nam"]) CHECK([item[@"description"] isEqual:@"warm clean boutique"]);

    // Gear research: parsing, cache persistence and matching replace the old artist tables.
    NSString* researchCache = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"axe-gear-research-%@.json", NSUUID.UUID.UUIDString]];
    rigAIGearResearchSetCachePath(researchCache);
    CHECK(rigAISuggestGearQueries(@"Fakeband - Neon Song").count == 0);
    CHECK(rigAISuggestGearQueries(@"").count == 0);

    NSDictionary* research = rigAIParseGearResearch(
        @"Sure:\n```json\n{\"kind\":\"artist\",\"artist\":\"Fakeband\",\"album\":\"Vol. 3 (The Night)\",\"song\":\"Neon Song\","
        @"\"confidence\":\"HIGH\",\"amps\":[\"Unique Amp Co. Model U\",\"  Second   Amp \"],\"cabs\":[\"2x12 Greenback\"],"
        @"\"pedals\":[],\"search_terms\":[\"Unique\",\"model u\"],\"notes\":\"well documented\"}\n```");
    CHECK(research != nil);
    CHECK([research[@"confidence"] isEqual:@"high"]);
    CHECK([research[@"amps"][1] isEqual:@"Second Amp"]);
    CHECK([research[@"search_terms"][0] isEqual:@"unique"]);
    CHECK(!rigAIParseGearResearch(@"{\"kind\":\"band\",\"amps\":[\"x\"]}"));
    CHECK(!rigAIParseGearResearch(@"{\"kind\":\"artist\",\"artist\":\"Nobody\"}"));
    CHECK(!rigAIParseGearResearch(@"not json"));
    NSDictionary* adjustment = rigAIParseGearResearch(@"{\"kind\":\"adjustment\",\"amps\":[\"Ignored\"]}");
    CHECK(adjustment && [adjustment[@"amps"] count] == 0 && [adjustment[@"confidence"] isEqual:@"low"]);
    CHECK([rigAIGearResearchSummary(research) containsString:@"Fakeband / Vol. 3 (The Night) / Neon Song"]);
    CHECK([rigAIGearResearchSummary(adjustment) containsString:@"adjustment"]);

    rigAIGearResearchStore(@"Fakeband - Neon Song tone", research);
    CHECK(rigAIGearResearchCached(@"fakeband neon song TONE") != nil);
    // Specific reuse needs the same recording; search hints only need the artist.
    CHECK(rigAIGearResearchMatching(@"play neon song by fakeband", YES) != nil);
    CHECK(rigAIGearResearchMatching(@"Fakeband other track", YES) == nil);
    CHECK(rigAIGearResearchMatching(@"Fakeband other track", NO) != nil);
    CHECK(rigAIGearResearchMatching(@"fakebandit riff", NO) == nil);
    NSArray<NSString*>* fakeQueries = rigAISuggestGearQueries(@"Fakeband other track");
    CHECK(fakeQueries.count >= 3 && [fakeQueries[0] isEqual:@"unique"]);
    CHECK(rigAITextNamesPhrase(@"the vol 3 the night era", @"Vol. 3 (The Night)"));
    CHECK(!rigAITextNamesPhrase(@"toolbox", @"Tool"));

    // Cached gear names rank captures the prompt itself never mentions.
    NSArray* fakeCandidates = rigAILibraryCandidates(root, @"Fakeband Neon Song", 8);
    CHECK(fakeCandidates.count > 0 && [fakeCandidates[0][@"path"] isEqual:@"Amp/C/unique.nam"]);

    // Survives a reload from disk.
    rigAIGearResearchSetCachePath(researchCache);
    CHECK(rigAIGearResearchCached(@"Fakeband - Neon Song tone") != nil);
    [NSFileManager.defaultManager removeItemAtPath:researchCache error:nil];
    rigAIGearResearchSetCachePath(nil);

    // Whole-library pack index: one entry per pack, correct stages, excludes empty/outside files.
    NSArray<NSDictionary*>* packIndex = rigAILibraryPackIndex(root, 100);
    NSMutableDictionary<NSString*, NSDictionary*>* packsByPath = [NSMutableDictionary dictionary];
    for (NSDictionary* p in packIndex) packsByPath[p[@"pack"]] = p;
    CHECK([packsByPath[@"Amp/A"][@"stage"] intValue] == 1 && [packsByPath[@"Amp/A"][@"captures"] intValue] == 1);
    CHECK([packsByPath[@"Amp/A"][@"title"] isEqual:@"Boutique Clean"]);
    CHECK([packsByPath[@"Full Rig/Combo"][@"includes_cab"] boolValue]);
    CHECK([packsByPath[@"Cab/CabA"][@"stage"] intValue] == 2);
    CHECK([packsByPath[@"Pedal/TS"][@"stage"] intValue] == 0);
    CHECK(packIndex.count == 9);
    CHECK(rigAILibraryPackIndex(root, 2).count == 2);
    // Pack folders resolve to a real capture for the right stage; files and escapes do not.
    CHECK([rigAIResolvePackCapture(root, @"Amp/A", 1, @"") isEqual:@"Amp/A/clean.nam"]);
    CHECK([rigAIResolvePackCapture(root, @"Cab/CabA", 2, nil) isEqual:@"Cab/CabA/mic.wav"]);
    CHECK(!rigAIResolvePackCapture(root, @"Amp/A/clean.nam", 1, @""));
    CHECK(!rigAIResolvePackCapture(root, @"Cab/CabA", 1, @""));
    CHECK(!rigAIResolvePackCapture(root, @"../library", 1, @""));

    NSString* packDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"axe-pack-%@", [NSUUID UUID].UUIDString]];
    NSString* packAmpDir = [packDir stringByAppendingPathComponent:@"Amp/Multi"];
    [NSFileManager.defaultManager createDirectoryAtPath:packAmpDir withIntermediateDirectories:YES attributes:nil error:nil];
    [@"fixture" writeToFile:[packAmpDir stringByAppendingPathComponent:@"[AMP] Clean.nam"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"fixture" writeToFile:[packAmpDir stringByAppendingPathComponent:@"[AMP] Lead.nam"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"fixture" writeToFile:[packAmpDir stringByAppendingPathComponent:@"[PRE] Rhythm.nam"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

    CHECK([rigAIResolvePackCapture(packDir, @"Amp/Multi", 1, @"Slipknot - Before I forget") isEqual:@"Amp/Multi/[AMP] Lead.nam"]);
    CHECK([rigAIResolvePackCapture(packDir, @"Amp/Multi", 1, @"clean jazz") isEqual:@"Amp/Multi/[AMP] Clean.nam"]);
    CHECK([rigAIResolvePackCapture(packDir, @"Amp/Multi", 1, @"") isEqual:@"Amp/Multi/[AMP] Lead.nam"]);
    [NSFileManager.defaultManager removeItemAtPath:packDir error:nil];

    // Profile key extraction and variant comparison (Custom > A2 > A1, capacity)
    CHECK([rigAIProfileKey(@"Amp-Dialled-xSTD.nam") isEqual:@"ampdialled"]);
    CHECK([rigAIProfileKey(@"Amp Dialled (A2).nam") isEqual:@"ampdialled"]);
    CHECK([rigAIProfileKey(@"Amp Dialled (A1).nam") isEqual:@"ampdialled"]);
    CHECK([rigAIProfileKey(@"Amp Dialled Custom.nam") isEqual:@"ampdialled"]);
    CHECK([rigAIHighestCapacityVariant(root, @"Amp/A/clean.nam", 1, nil, nil) isEqual:@"Amp/A/clean.nam"]);

    NSString* varDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"axe-var-%@", [NSUUID UUID].UUIDString]];
    NSString* ampVarDir = [varDir stringByAppendingPathComponent:@"Amp/Variants"];
    [NSFileManager.defaultManager createDirectoryAtPath:ampVarDir withIntermediateDirectories:YES attributes:nil error:nil];
    [@"{\"architecture\":\"WaveNet\",\"weights\":[1,2,3,4,5,6]}" writeToFile:[ampVarDir stringByAppendingPathComponent:@"model (A1).nam"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"{\"architecture\":\"SlimmableContainer\",\"weights\":[1,2,3,4,5]}" writeToFile:[ampVarDir stringByAppendingPathComponent:@"model (A2).nam"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"{\"architecture\":\"CustomNet\",\"weights\":[1,2]}" writeToFile:[ampVarDir stringByAppendingPathComponent:@"model Custom.nam"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

    CHECK([rigAICaptureArchitecture(varDir, @"Amp/Variants/model (A1).nam") isEqual:@"1"]);
    CHECK([rigAICaptureArchitecture(varDir, @"Amp/Variants/model (A2).nam") isEqual:@"2"]);
    CHECK([rigAICaptureArchitecture(varDir, @"Amp/Variants/model Custom.nam") isEqual:@"custom"]);
    NSInteger chosenParams = 0, origParams = 0;
    NSString* highest = rigAIHighestCapacityVariant(varDir, @"Amp/Variants/model (A1).nam", 1, &chosenParams, &origParams);
    CHECK([highest isEqual:@"Amp/Variants/model Custom.nam"]);
    CHECK(chosenParams == 2 && origParams == 6);
    [NSFileManager.defaultManager removeItemAtPath:varDir error:nil];

    // Acoustic telemetry delta guidance tests
    NSString* playerTake = @"Player take: peak -3.0 dBFS; RMS -13.0; crest 11.0 dB; clipped samples 0; broad filter estimates at 90/250/500/1000/2000/4000/8000/12000 Hz: -18.0/-15.0/-20.0/-22.0/-20.0/-26.0/-20.0/-38.0 dBFS";
    NSString* refTake = @"Reference: peak -2.0 dBFS; RMS -13.0; crest 11.0 dB; clipped samples 0; broad filter estimates at 90/250/500/1000/2000/4000/8000/12000 Hz: -22.0/-15.0/-20.0/-22.0/-20.0/-20.0/-26.0/-44.0 dBFS";
    NSString* deltaGuidance = rigAIAcousticDeltaGuidance(playerTake, refTake);
    CHECK(deltaGuidance.length > 0);
    CHECK([deltaGuidance containsString:@"+4.0 dB"]);
    CHECK([deltaGuidance containsString:@"-6.0 dB"]);
    CHECK([deltaGuidance containsString:@"+6.0 dB"]);
    CHECK([deltaGuidance containsString:@"palm-mute"]);
    CHECK([deltaGuidance.lowercaseString containsString:@"pick attack"]);
    CHECK([deltaGuidance containsString:@"sizzle"]);

    // Dynamic crest factor saturation delta check
    NSString* saturatedRef = @"Reference: peak -1.0 dBFS; RMS -8.5; crest 7.5 dB; clipped samples 0; broad filter estimates at 90/250/500/1000/2000/4000/8000/12000 Hz: -22.0/-15.0/-20.0/-22.0/-20.0/-20.0/-26.0/-44.0 dBFS";
    NSString* cleanPlayer = @"Player take: peak -2.0 dBFS; RMS -18.0; crest 16.0 dB; clipped samples 0; broad filter estimates at 90/250/500/1000/2000/4000/8000/12000 Hz: -18.0/-15.0/-20.0/-22.0/-20.0/-26.0/-20.0/-38.0 dBFS";
    NSString* satGuidance = rigAIAcousticDeltaGuidance(cleanPlayer, saturatedRef);
    CHECK([satGuidance containsString:@"heavily saturated"]);
    CHECK([satGuidance containsString:@"high-gain"]);

    // Combined audio description parsing
    NSString* combinedDesc = [NSString stringWithFormat:@"PLAYER TAKE:\n%@\n\nTARGET REFERENCE:\n%@", playerTake, refTake];
    NSString* combinedGuidance = rigAIAcousticDeltaGuidance(combinedDesc, nil);
    CHECK(combinedGuidance.length > 0 && [combinedGuidance containsString:@"+4.0 dB"]);

    // Single-take guidance
    NSString* clippedTake = @"Player take: peak 0.0 dBFS; RMS -10.0; crest 10.0 dB; clipped samples 42; broad filter estimates at 90/250/500/1000/2000/4000/8000/12000 Hz: -12.0/-18.0/-26.0/-24.0/-25.0/-28.0/-30.0/-35.0 dBFS";
    NSString* singleGuidance = rigAIAcousticDeltaGuidance(clippedTake, nil);
    CHECK(singleGuidance.length > 0);
    CHECK([singleGuidance containsString:@"42 clipped samples"]);
    CHECK([singleGuidance containsString:@"flub"]);

    // Provider model temperature support checks
    CHECK(!rigAIProviderModelSupportsTemperature(@"claude", @"claude-opus-5-5"));
    CHECK(!rigAIProviderModelSupportsTemperature(@"claude", @"claude-sonnet-5-5"));
    CHECK(!rigAIProviderModelSupportsTemperature(@"claude", @"claude-haiku-5-5"));
    CHECK(!rigAIProviderModelSupportsTemperature(@"claude", @"claude-fable-5-1"));
    CHECK(!rigAIProviderModelSupportsTemperature(@"claude", @"claude-opus-4-7"));
    CHECK(!rigAIProviderModelSupportsTemperature(@"claude", @"claude-opus-4-8"));
    CHECK(rigAIProviderModelSupportsTemperature(@"claude", @"claude-3-5-sonnet-20241022"));
    CHECK(rigAIProviderModelSupportsTemperature(@"claude", @"claude-3-haiku-20240307"));
    CHECK(rigAIProviderModelSupportsTemperature(@"claude", @"claude-2.1"));
    CHECK(!rigAIProviderModelSupportsTemperature(@"claude", @""));
    CHECK(!rigAIProviderModelSupportsTemperature(@"openai", @"o1"));
    CHECK(!rigAIProviderModelSupportsTemperature(@"openai", @"o1-mini"));
    CHECK(!rigAIProviderModelSupportsTemperature(@"openai", @"o3"));
    CHECK(!rigAIProviderModelSupportsTemperature(@"openai", @"o3-mini"));
    CHECK(!rigAIProviderModelSupportsTemperature(@"openai", @"o4-mini"));
    CHECK(!rigAIProviderModelSupportsTemperature(@"openai", @"gpt-5-mini"));
    CHECK(!rigAIProviderModelSupportsTemperature(@"openai", @"gpt-5.4-mini"));
    CHECK(!rigAIProviderModelSupportsTemperature(@"openai", @"gpt-6.1-sol"));
    CHECK(!rigAIProviderModelSupportsTemperature(@"openai", @"gpt-6-astra"));
    CHECK(rigAIProviderModelSupportsTemperature(@"openai", @"gpt-4o"));
    CHECK(rigAIProviderModelSupportsTemperature(@"openai", @"gpt-4.1-mini"));
    CHECK(!rigAIProviderModelSupportsTemperature(@"gemini", @"gemini-3.8-flash"));
    CHECK(!rigAIProviderModelSupportsTemperature(@"gemini", @"gemini-4-argon"));
    CHECK(rigAIProviderModelSupportsTemperature(@"gemini", @"gemini-2.5-pro"));
    CHECK(rigAIProviderModelSupportsTemperature(@"gemini", @"gemini-1.5-pro"));
    CHECK(rigAIProviderModelSupportsTemperature(@"ollama", @"llama3.3"));
    CHECK(rigAIProviderModelSupportsTemperature(@"ollama", @"qwen2.5-coder"));

    // DeepSeek-R1 / Ollama reasoning thinking block extraction test
    NSString* thinkJson = @"<think>\nEvaluating Lamb of God tone: needs aggressive mid punch and tight palm mutes.\n</think>\n```json\n{\"controls\":{\"bass\":-2,\"od_tone\":62}}\n```";
    RigAICopilotResult* thinkRes = rigAIParseResponse(thinkJson, nil);
    CHECK(thinkRes != nil);
    CHECK([thinkRes.thought containsString:@"aggressive mid punch"]);
    CHECK(thinkRes.controls[@"bass"].floatValue == -2);
    CHECK(thinkRes.controls[@"od_tone"].floatValue == 62);

    std::printf("AI support: %d failures\n", failures);
  }
  return failures ? 1 : 0;
}
