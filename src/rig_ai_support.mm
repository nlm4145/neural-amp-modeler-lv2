#import "rig_ai_support.h"
#include "rig_control_metadata.h"
#include <cstring>
#include <algorithm>

@implementation RigAICopilotResult
@end

static BOOL fail(NSError** error, NSString* message) {
  if (error) *error = [NSError errorWithDomain:@"RigAICopilot" code:-4
      userInfo:@{NSLocalizedDescriptionKey: message}];
  return NO;
}

NSString* rigAIControlReference() {
  NSMutableString* text = [NSMutableString string];
  NAMRig::forEachRigControlSymbol([&](uint32_t port, const char*) {
    const auto* c = NAMRig::rigControlContract(port);
    if (!c) return;
    [text appendFormat:@"%s: %g..%g %s; default %g%s%s\n", c->symbol,
        c->minimum, c->maximum, c->unit, c->defaultValue,
        c->choices[0] ? "; choices " : "", c->choices];
  });
  return text;
}

BOOL rigAIValidateControls(NSDictionary* controls, NSError** error) {
  if (![controls isKindOfClass:NSDictionary.class]) return fail(error, @"controls must be an object.");
  for (id key in controls) {
    if (![key isKindOfClass:NSString.class]) return fail(error, @"Control names must be strings.");
    const NAMRig::RigControlContract* contract = nullptr;
    for (const auto& c : NAMRig::kRigControlContracts)
      if (NAMRig::rigControlSymbol(c.port) && [key isEqualToString:[NSString stringWithUTF8String:c.symbol]]) {
        contract = &c;
        break;
      }
    id value = controls[key];
    if (!contract) return fail(error, [NSString stringWithFormat:@"Unknown control: %@", key]);
    if (![value isKindOfClass:NSNumber.class] ||
        (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() &&
         !(contract->integer && contract->maximum == 1)) ||
        !NAMRig::validRigControlValue(*contract, [value doubleValue]))
      return fail(error, [NSString stringWithFormat:@"Invalid %@ value. Expected %g..%g %s%@.",
          key, contract->minimum, contract->maximum, contract->unit,
          contract->integer ? @" (supported integer choice)" : @""]);
  }
  return YES;
}

BOOL rigAIValidateProviderCompletion(NSDictionary* response, NSError** error) {
  id reason = response[@"stop_reason"];
  if (![reason isKindOfClass:NSString.class]) {
    NSArray* choices = [response[@"choices"] isKindOfClass:NSArray.class] ? response[@"choices"] : @[];
    NSDictionary* choice = [choices.firstObject isKindOfClass:NSDictionary.class] ? choices.firstObject : @{};
    reason = choice[@"finish_reason"];
  }
  if (![reason isKindOfClass:NSString.class]) {
    NSArray* candidates = [response[@"candidates"] isKindOfClass:NSArray.class] ? response[@"candidates"] : @[];
    NSDictionary* candidate = [candidates.firstObject isKindOfClass:NSDictionary.class] ? candidates.firstObject : @{};
    reason = candidate[@"finishReason"];
  }
  if ([reason isKindOfClass:NSString.class] &&
      [@[@"max_tokens", @"length", @"max_output_tokens"] containsObject:[reason lowercaseString]]) {
    return fail(error, @"The provider stopped at the output-token limit before completing the tone proposal. The incomplete reply was not applied. This is a response-budget issue, not your prompt; no automatic paid retry was made.");
  }
  return YES;
}

RigAICopilotResult* rigAIParseResponse(NSString* content, NSError** error) {
  if (![content isKindOfClass:NSString.class] || !content.length || content.length > 65536) {
    fail(error, @"AI response is empty, oversized, or not text.");
    return nil;
  }
  NSString* json = [content stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

  // Strip <think>...</think> reasoning blocks from local reasoning models (e.g. DeepSeek-R1 via Ollama)
  NSString* extractedThought = nil;
  if ([json hasPrefix:@"<think>"]) {
    NSRange endTag = [json rangeOfString:@"</think>"];
    if (endTag.location != NSNotFound) {
      NSRange thoughtRange = NSMakeRange(7, endTag.location - 7);
      extractedThought = [[json substringWithRange:thoughtRange] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
      json = [[json substringFromIndex:endTag.location + endTag.length] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
  }

  if ([json hasPrefix:@"```json\n"] || [json hasPrefix:@"```\n"] ||
      [json hasPrefix:@"```json\r\n"] || [json hasPrefix:@"```\r\n"]) {
    NSRange newline = [json rangeOfString:@"\n"];
    json = [json substringFromIndex:newline.location + 1];
    if ([json hasSuffix:@"```"]) json = [json substringToIndex:json.length - 3];
    // A missing Markdown closing fence is harmless only if the entire JSON
    // object is valid. Never invent braces/values or accept partial controls.
  }
  id object = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
      options:0 error:error];
  if (![object isKindOfClass:NSDictionary.class]) {
    fail(error, @"AI response must contain exactly one JSON object."); return nil;
  }
  NSDictionary* dict = object;
  for (NSString* key in @[@"preset_name", @"preset_title", @"thought", @"explanation",
                         @"amp_model", @"amp_path", @"cab_ir", @"cab_path", @"pedal_model", @"pedal_path",
                         @"search_tone3000", @"search_tone_3000",
                         @"artist", @"album", @"song", @"genre", @"folder_path"]) {
    if (dict[key] && ![dict[key] isKindOfClass:NSString.class]) {
      fail(error, [NSString stringWithFormat:@"%@ must be a string, not null or another type.", key]); return nil;
    }
  }
  if (dict[@"slot_presets"] && (![dict[@"slot_presets"] isKindOfClass:NSDictionary.class] ||
                                [dict[@"slot_presets"] count] != 0)) {
    fail(error, @"Use explicit controls; AI slot preset selection is not supported."); return nil;
  }
  if (!rigAIValidateControls(dict[@"controls"], error)) return nil;
  RigAICopilotResult* result = [RigAICopilotResult new];
  result.presetName = dict[@"preset_name"] ?: dict[@"preset_title"];
  result.thought = (dict[@"thought"] && [dict[@"thought"] length] > 0) ? dict[@"thought"] : (extractedThought ?: @"");
  result.explanation = dict[@"explanation"] ?: @"AI tone starting point.";
  result.controls = dict[@"controls"];
  result.ampPath = dict[@"amp_model"] ?: dict[@"amp_path"];
  result.cabPath = dict[@"cab_ir"] ?: dict[@"cab_path"];
  result.pedalPath = dict[@"pedal_model"] ?: dict[@"pedal_path"];
  result.searchTone3000 = dict[@"search_tone3000"] ?: dict[@"search_tone_3000"];
  result.artist = dict[@"artist"];
  result.album = dict[@"album"];
  result.song = dict[@"song"];
  result.genre = dict[@"genre"];
  result.folderPath = dict[@"folder_path"];
  if (rigAIIsNoneModel(result.ampPath)) {
    fail(error, @"amp_model cannot be 'none'; choose a catalog amp or leave it unchanged."); return nil;
  }
  result.rawJson = dict;
  return result;
}

BOOL rigAIIsNoneModel(NSString* target) {
  if (![target isKindOfClass:NSString.class]) return NO;
  NSString* trimmed = [target.lowercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return [trimmed isEqualToString:@"none"] || [trimmed isEqualToString:@"remove"] || [trimmed isEqualToString:@"bypass"];
}

static NSDictionary* manifestForPath(NSString* path) {
  if (!path.length) return @{};
  NSString* manifestPath = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"_tone3000.json"];
  NSDictionary* attrs = [NSFileManager.defaultManager attributesOfItemAtPath:manifestPath error:nil];
  if (![attrs[NSFileType] isEqual:NSFileTypeRegular] || [attrs[NSFileSize] unsignedLongLongValue] > 1024 * 1024) return @{};
  NSData* data = [NSData dataWithContentsOfFile:manifestPath options:NSDataReadingMappedIfSafe error:nil];
  if (!data || data.length > 1024 * 1024) return @{};
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [json isKindOfClass:NSDictionary.class] ? json : @{};
}

BOOL rigAIModelIncludesCab(NSString* path) {
  if (!path.length) return NO;
  if ([[path pathComponents] containsObject:@"Full Rig"]) return YES;
  NSDictionary* manifest = manifestForPath(path);
  NSDictionary* tone = [manifest[@"tone"] isKindOfClass:NSDictionary.class] ? manifest[@"tone"] : @{};
  NSString* gear = [tone[@"gear"] isKindOfClass:NSString.class] ? [tone[@"gear"] lowercaseString] : @"";
  return [gear isEqualToString:@"amp-cab"] || [gear isEqualToString:@"full-rig"];
}

static BOOL regularFileInside(NSString* root, NSString* path) {
  NSString* canonicalRoot = root.stringByStandardizingPath.stringByResolvingSymlinksInPath;
  NSString* canonical = path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
  if (![canonical hasPrefix:[canonicalRoot stringByAppendingString:@"/"]]) return NO;
  NSDictionary* attrs = [NSFileManager.defaultManager attributesOfItemAtPath:canonical error:nil];
  return [attrs[NSFileType] isEqualToString:NSFileTypeRegular] && [attrs[NSFileSize] unsignedLongLongValue] > 0;
}

static BOOL categoryMatches(NSString* relative, NSUInteger stage) {
  NSArray* parts = relative.pathComponents;
  if (parts.count < 2) return NO;
  NSString* ext = relative.pathExtension.lowercaseString;
  if (stage == 0) return [parts[0] isEqualToString:@"Pedal"] && [ext isEqualToString:@"nam"];
  if (stage == 1) return ([parts[0] isEqualToString:@"Amp"] || [parts[0] isEqualToString:@"Full Rig"]) &&
      [ext isEqualToString:@"nam"];
  return (stage == 2 || stage == 3) &&
      ([parts[0] isEqualToString:@"Cab"] || [parts[0] isEqualToString:@"Cabinet"]) &&
      ([ext isEqualToString:@"wav"] || [ext isEqualToString:@"nam"]);
}

NSArray<NSDictionary*>* rigAILibraryCandidates(NSString* root, NSString* query, NSUInteger limit) {
  NSUInteger totals[3] = {};
  return rigAILibraryCandidatesWithTotals(root, query, limit, totals);
}

NSArray<NSDictionary*>* rigAILibraryCandidatesWithTotals(NSString* root, NSString* query, NSUInteger limit,
                                                        NSUInteger totals[3]) {
  NSUInteger dummyScores[3] = {};
  return rigAILibraryCandidatesWithTotalsAndScores(root, query, limit, totals, dummyScores);
}

NSArray<NSDictionary*>* rigAILibraryCandidatesWithTotalsAndScores(NSString* root, NSString* query, NSUInteger limit,
                                                                 NSUInteger totals[3], NSUInteger maxScores[3]) {
  NSMutableArray* items = [NSMutableArray array];
  static NSSet<NSString*>* stopWords = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    stopWords = [NSSet setWithObjects:
      @"the", @"and", @"for", @"with", @"from", @"that", @"this", @"into", @"onto",
      @"create", @"make", @"build", @"dial", @"give", @"want", @"need", @"please",
      @"new", @"preset", @"patch", @"tone", @"sound", @"rig", @"guitar", @"setting", @"settings",
      @"modeled", @"modeled", @"model", @"after", @"before", @"forget", @"like", @"style",
      @"song", @"track", @"album", @"band", @"artist", @"using", @"based", @"play", @"playing", nil];
  });
  NSArray* rawPromptTokens = [query.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet];
  NSMutableArray<NSString*>* promptTokens = [NSMutableArray array];
  for (NSString* t in rawPromptTokens) {
    if (t.length > 2 && ![stopWords containsObject:t] && ![promptTokens containsObject:t]) {
      [promptTokens addObject:t];
    }
  }
  NSMutableSet<NSString*>* gearTokenSet = [NSMutableSet set];
  for (NSString* sq in rigAISuggestGearQueries(query)) {
    for (NSString* t in [sq.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]) {
      if (t.length > 2 && ![stopWords containsObject:t] && ![promptTokens containsObject:t]) [gearTokenSet addObject:t];
    }
  }
  NSArray* gearTokens = [gearTokenSet allObjects];
  NSString* lowerQuery = query.lowercaseString ?: @"";
  const BOOL wantsChainsawOrFuzz = [lowerQuery containsString:@"chainsaw"] || [lowerQuery containsString:@"hm2"] ||
                                   [lowerQuery containsString:@"hm-2"] || [lowerQuery containsString:@"fuzz"] ||
                                   [lowerQuery containsString:@"doom"] || [lowerQuery containsString:@"sludge"];
  NSDirectoryEnumerator* en = [NSFileManager.defaultManager enumeratorAtPath:root];
  NSMutableDictionary* manifests = [NSMutableDictionary dictionary];
  for (NSUInteger s = 0; s < 3; ++s) {
    totals[s] = 0;
    if (maxScores) maxScores[s] = 0;
  }
  for (NSString* relative in en) {
    NSUInteger stage = categoryMatches(relative, 1) ? 1 : categoryMatches(relative, 2) ? 2 : categoryMatches(relative, 0) ? 0 : NSNotFound;
    if (stage == NSNotFound) continue;
    NSString* path = [root stringByAppendingPathComponent:relative];
    if (!regularFileInside(root, path)) continue;
    NSString* folder = path.stringByDeletingLastPathComponent;
    NSDictionary* manifest = manifests[folder];
    if (!manifest) manifests[folder] = manifest = manifestForPath(path);
    NSDictionary* tone = [manifest[@"tone"] isKindOfClass:NSDictionary.class] ? manifest[@"tone"] : @{};
    NSString* gear = [tone[@"gear"] isKindOfClass:NSString.class] ? [tone[@"gear"] lowercaseString] : @"";
    BOOL includesCab = [relative.pathComponents containsObject:@"Full Rig"] || [gear isEqual:@"amp-cab"] || [gear isEqual:@"full-rig"];
    ++totals[stage];
    NSMutableDictionary* item = [@{@"path": relative, @"stage": @(stage),
                                  @"includes_cab": @(stage == 1 && includesCab)} mutableCopy];
    for (NSString* key in @[@"title", @"description", @"gear", @"tags"]) {
      id value = tone[key];
      if ([value isKindOfClass:NSString.class]) {
        NSArray<NSString*>* words = [[value componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
            filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        NSString* text = [words componentsJoinedByString:@" "];
        const NSUInteger cap = [key isEqualToString:@"description"] ? 240 : 120;
        item[key] = [text substringToIndex:std::min<NSUInteger>(text.length, cap)];
      }
    }
    NSArray* downloads = [manifest[@"downloads"] isKindOfClass:NSArray.class] ? manifest[@"downloads"] : @[];
    for (id entry in downloads) {
      if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"local_filename"] isEqual:relative.lastPathComponent]) continue;
      NSDictionary* model = [entry[@"original_model"] isKindOfClass:NSDictionary.class] ? entry[@"original_model"] : @{};
      if ([model[@"name"] isKindOfClass:NSString.class]) item[@"capture_name"] = [model[@"name"] substringToIndex:std::min<NSUInteger>([model[@"name"] length], 200)];
    }
    NSString* primaryText = [NSString stringWithFormat:@"%@ %@ %@ %@",
        relative, item[@"title"] ?: @"", item[@"capture_name"] ?: @"", item[@"tags"] ?: @""].lowercaseString;
    NSString* searchable = [NSString stringWithFormat:@"%@ %@", primaryText, item[@"description"] ?: @""].lowercaseString;
    NSSet<NSString*>* wordSet = [NSSet setWithArray:[searchable componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]];
    auto matchesToken = [&](NSString* token, NSString* text) -> BOOL {
      if (token.length <= 4) return [wordSet containsObject:token];
      return [text containsString:token];
    };
    NSUInteger score = 0;
    for (NSString* token in promptTokens) {
      if (matchesToken(token, primaryText)) score += 6;
      else if (matchesToken(token, searchable)) score += 3;
    }
    for (NSString* token in gearTokens) {
      if (matchesToken(token, primaryText)) score += 4;
      else if (matchesToken(token, searchable)) score += 2;
    }
    if (score > 0 && stage == 1 && !wantsChainsawOrFuzz) {
      NSString* fileLower = relative.lastPathComponent.lowercaseString;
      if ([fileLower containsString:@"chainsaw"] || [fileLower containsString:@"jugendstil"] ||
          [fileLower containsString:@"hm300"] || [fileLower containsString:@"pickle"] ||
          [fileLower containsString:@"fuzz"]) {
        score = score > 3 ? score - 3 : 1;
      } else if ([fileLower containsString:@"noboost"] || [fileLower containsString:@"no-boost"] ||
                 [fileLower containsString:@"od808"] || [fileLower containsString:@"ts9"]) {
        score += 1;
      }
    }
    item[@"score"] = @(score);
    if (maxScores && score > maxScores[stage]) maxScores[stage] = score;
    [items addObject:item];
  }
  [items sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
    NSComparisonResult score = [b[@"score"] compare:a[@"score"]];
    return score == NSOrderedSame ? [a[@"path"] compare:b[@"path"]] : score;
  }];
  // Balanced shortlist: neither a huge amp family nor cab pack can crowd out the other stages.
  // Pedals get a small share; amps and cabs split the rest.
  NSMutableArray* selected = [NSMutableArray array];
  NSMutableDictionary* packCounts = [NSMutableDictionary dictionary];
  NSUInteger counts[3] = {};
  NSUInteger caps[3] = {0, 0, 0};
  caps[0] = totals[0] ? std::max<NSUInteger>(2, limit / 6) : 0;
  caps[0] = std::min(caps[0], limit);
  caps[1] = caps[2] = (limit - caps[0] + 1) / 2;
  for (NSMutableDictionary* item in items) {
    NSUInteger stage = [item[@"stage"] unsignedIntegerValue];
    NSString* pack = [item[@"path"] stringByDeletingLastPathComponent];
    const NSUInteger packCap = (stage == 1 && totals[1] > caps[1]) ? 2 : 3;
    if (counts[stage] >= caps[stage] || [packCounts[pack] unsignedIntegerValue] >= packCap) continue;
    ++counts[stage];
    packCounts[pack] = @([packCounts[pack] unsignedIntegerValue] + 1);
    [item removeObjectForKey:@"score"];
    [selected addObject:item];
    if (selected.count >= limit) break;
  }
  // Fill unused capacity only after giving other packs a chance.
  for (NSMutableDictionary* item in items) {
    NSUInteger stage = [item[@"stage"] unsignedIntegerValue];
    if (selected.count >= limit) break;
    if (counts[stage] >= caps[stage] || [selected containsObject:item]) continue;
    ++counts[stage];
    [item removeObjectForKey:@"score"];
    [selected addObject:item];
  }
  // Remaining room goes to any stage so a small library is always listed completely.
  for (NSMutableDictionary* item in items) {
    if (selected.count >= limit) break;
    if ([selected containsObject:item]) continue;
    [item removeObjectForKey:@"score"];
    [selected addObject:item];
  }
  return selected;
}

NSString* rigAIResolveModel(NSString* root, NSString* target, NSUInteger stage, NSError** error) {
  if (error) *error = nil;
  unichar nullCharacter = 0;
  NSString* nullString = [NSString stringWithCharacters:&nullCharacter length:1];
  if (![target isKindOfClass:NSString.class] || !target.length || stage > 3 ||
      [target rangeOfString:nullString].location != NSNotFound) {
    fail(error, @"Invalid model path or stage."); return nil;
  }
  root = root.stringByStandardizingPath.stringByResolvingSymlinksInPath;
  NSString* path = target.isAbsolutePath ? target : [root stringByAppendingPathComponent:target];
  NSString* prefix = [root stringByAppendingString:@"/"];
  NSString* lexical = path.stringByStandardizingPath;
  if ([lexical hasPrefix:prefix]) {
    NSString* relative = [lexical substringFromIndex:prefix.length];
    NSString* canonical = lexical.stringByResolvingSymlinksInPath;
    if (categoryMatches(relative, stage) && regularFileInside(root, lexical) &&
        categoryMatches([canonical substringFromIndex:prefix.length], stage)) return canonical;
  }
  // Compatibility for old filename-only clients, but never substring guessing.
  if (!target.isAbsolutePath && target.pathComponents.count == 1) {
    NSString* match = nil;
    for (NSString* relative in [NSFileManager.defaultManager enumeratorAtPath:root]) {
      NSString* candidate = [root stringByAppendingPathComponent:relative];
      if (categoryMatches(relative, stage) &&
          [relative.lastPathComponent caseInsensitiveCompare:target] == NSOrderedSame && regularFileInside(root, candidate)) {
        if (match) { fail(error, @"Ambiguous model filename. Use the exact library-relative path."); return nil; }
        match = candidate;
      }
    }
    if (match) {
      NSString* canonical = match.stringByResolvingSymlinksInPath;
      if (categoryMatches([canonical substringFromIndex:prefix.length], stage)) return canonical;
    }
  }
  fail(error, [NSString stringWithFormat:@"Model is missing, outside the library, or wrong for stage %lu: %@", (unsigned long)stage, target]);
  return nil;
}

NSArray<NSString*>* rigAISuggestGearQueries(NSString* prompt) {
  if (![prompt isKindOfClass:NSString.class] || !prompt.length) return @[];
  NSString* clean = prompt.lowercaseString;
  NSMutableArray<NSString*>* results = [NSMutableArray array];

  auto addQuery = ^(NSString* q) {
    if (q.length && ![results containsObject:q]) {
      [results addObject:q];
    }
  };

  struct GearAssociation {
    NSArray<NSString*>* triggers;
    NSArray<NSString*>* queries;
  };

  static const GearAssociation kAssociations[] = {
    // Modern / Nu Metal / Slipknot
    {
      @[@"slipknot", @"before i forget", @"duality", @"psychosocial", @"jim root", @"mick thomson", @"iowa", @"subliminal verses", @"wait and bleed"],
      @[@"rivera knucklehead", @"rivera kr7", @"bogner uberschall", @"jim root", @"rockerverb", @"diezel vh4", @"diezel herbert", @"dual rectifier", @"5150", @"v30"]
    },
    // Thrash / Metallica
    {
      @[@"metallica", @"hetfield", @"hammett", @"master of puppets", @"ride the lightning", @"enter sandman", @"black album", @"and justice for all", @"kill em all"],
      @[@"mesa mark iic+", @"mesa mark iv", @"dual rectifier", @"diesel v30", @"marshall jcm800"]
    },
    // Pantera / Dimebag Darrell
    {
      @[@"pantera", @"dimebag", @"cowboys from hell", @"vulgar display", @"walk", @"cemetery gates", @"far beyond driven"],
      @[@"randall rg100", @"warhead", @"krank revolution", @"furman pq3"]
    },
    // Tool / Adam Jones
    {
      @[@"tool", @"adam jones", @"schism", @"sober", @"lateralus", @"fear inoculum", @"aenima", @"vicarious"],
      @[@"diezel vh4", @"marshall super bass", @"dual rectifier", @"mesa 4x12"]
    },
    // Gojira / Joe Duplantier
    {
      @[@"gojira", @"duplantier", @"flying whales", @"silvera", @"stranded", @"l'enfant sauvage", @"art of dying"],
      @[@"evh 5150 iii", @"5150", @"peavey 6505", @"mesa dual rectifier"]
    },
    // Meshuggah / Djent / Progressive Metal
    {
      @[@"meshuggah", @"thordendal", @"bleed", @"periphery", @"misha mansoor", @"animals as leaders", @"tosin abasi", @"djent", @"monuments"],
      @[@"evh 5150 iii", @"friedman be100", @"precision drive", @"bogner uberschall"]
    },
    // Deftones / Stephen Carpenter
    {
      @[@"deftones", @"stephen carpenter", @"my own summer", @"change in the house of flies", @"around the fur", @"white pony", @"be quiet and drive"],
      @[@"marshall jmp-1", @"dual rectifier", @"diezel vh4"]
    },
    // Alice in Chains / Jerry Cantrell
    {
      @[@"alice in chains", @"cantrell", @"man in the box", @"rooster", @"them bones", @"dirt", @"would?"],
      @[@"bogner uberschall", @"friedman jj", @"bogner fish", @"marshall jcm800"]
    },
    // Soundgarden / Kim Thayil / Chris Cornell
    {
      @[@"soundgarden", @"kim thayil", @"chris cornell", @"black hole sun", @"spoonman", @"outshined", @"superunknown"],
      @[@"mesa dual rectifier", @"peavey vtm", @"marshall jcm800"]
    },
    // Lamb of God / Mark Morton
    {
      @[@"lamb of god", @"mark morton", @"redneck", @"laid to rest", @"ashes of the wake"],
      @[@"mesa mark iv", @"mesa mark v", @"mesa 4x12 v30"]
    },
    // Avenged Sevenfold / Synyster Gates
    {
      @[@"avenged sevenfold", @"synyster gates", @"bat country", @"hail to the king", @"nightmare", @"unholy confessions"],
      @[@"schecter hellwin", @"bogner uberschall", @"mesa dual rectifier"]
    },
    // Disturbed / Dan Donegan
    {
      @[@"disturbed", @"distrubed", @"donegan", @"dan donegan", @"the sickness", @"down with the sickness", @"stupify", @"voices", @"ten thousand fists", @"stricken", @"indestructible", @"inside the fire", @"sound of silence"],
      @[@"mesa dual rectifier", @"triple rectifier", @"dual rectifier", @"mesa boogie", @"bogner ecstasy", @"mesa 4x12", @"v30"]
    },
    // Rammstein / Richard Kruspe / Paul Landers
    {
      @[@"rammstein", @"kruspe", @"paul landers", @"du hast", @"sonne", @"feuer frei", @"deutschland", @"mutter"],
      @[@"mesa dual rectifier", @"dual rectifier", @"engl fireball", @"sansamp psa", @"mesa 4x12"]
    },
    // Korn / Munky / Head
    {
      @[@"korn", @"munky", @"brian welch", @"blind", @"freak on a leash", @"falling away from me", @"got the life"],
      @[@"mesa dual rectifier", @"triple rectifier", @"dual rectifier", @"mesa 4x12", @"ts9"]
    },
    // System of a Down / Daron Malakian
    {
      @[@"system of a down", @"soad", @"malakian", @"chop suey", @"toxicity", @"aerials", @"b.y.o.b."],
      @[@"marshall jmp-1", @"dual rectifier", @"marshall plexi 1959", @"mesa 4x12"]
    },
    // Killswitch Engage / Adam D / Joel Stroetzel
    {
      @[@"killswitch engage", @"adam d", @"holy diver", @"end of heartache", @"my curse", @"alive or just breathing"],
      @[@"peavey 5150", @"6505", @"maxon od808", @"framus cobra", @"v30"]
    },
    // Trivium / Matt Heafy / Corey Beaulieu
    {
      @[@"trivium", @"heafy", @"in waves", @"the sin and the sentence", @"pull harder", @"ascendancy"],
      @[@"evh 5150 iii", @"5150", @"peavey 6505", @"maxon od808"]
    },
    // Dream Theater / John Petrucci
    {
      @[@"dream theater", @"petrucci", @"pull me under", @"panic attack", @"the glass prison", @"metropolis", @"images and words"],
      @[@"mesa mark iic+", @"mesa mark iv", @"mesa mark v", @"mesa jp-2c", @"mesa 4x12"]
    },
    // In Flames / Björn Gelotte
    {
      @[@"in flames", @"bjorn gelotte", @"clayman", @"colony", @"the jester race", @"only for the weak"],
      @[@"peavey 5150", @"6505", @"marshall 1960", @"v30"]
    },
    // Arch Enemy / Michael Amott
    {
      @[@"arch enemy", @"amott", @"nemesis", @"war eternal", @"we will rise"],
      @[@"peavey 5150", @"evh 5150 iii", @"marshall jcm800"]
    },
    // Mastodon / Bill Kelliher / Brent Hinds
    {
      @[@"mastodon", @"blood mountain", @"crack the skye", @"leviathan", @"bill kelliher", @"brent hinds"],
      @[@"marshall jcm800", @"orange thunderverb", @"friedman butterslax"]
    },
    // Foo Fighters / Dave Grohl / Chris Shiflett
    {
      @[@"foo fighters", @"grohl", @"everlong", @"all my life", @"the pretender", @"best of you", @"monkey wrench", @"colour and the shape"],
      @[@"mesa dual rectifier", @"mesa road king", @"vox ac30", @"friedman"]
    },
    // Smashing Pumpkins / Billy Corgan
    {
      @[@"smashing pumpkins", @"billy corgan", @"siamese dream", @"cherub rock", @"today", @"bullet with butterfly wings", @"mellon collie"],
      @[@"op-amp big muff", @"big muff", @"marshall jcm800", @"fender twin reverb"]
    },
    // Weezer / Rivers Cuomo
    {
      @[@"weezer", @"rivers cuomo", @"blue album", @"pinkerton", @"say it ain't so", @"buddy holly", @"hash pipe"],
      @[@"mesa dual rectifier", @"marshall jcm900", @"marshall 4x12"]
    },
    // Steve Vai
    {
      @[@"steve vai", @"passion and warfare", @"for the love of god", @"bad horse", @"carvin legacy"],
      @[@"carvin legacy", @"bogner ecstasy", @"boss ds-1", @"ibanez ts9"]
    },
    // Joe Satriani
    {
      @[@"joe satriani", @"satriani", @"surfing with the alien", @"satch boogie", @"always with me", @"summer song"],
      @[@"marshall jvm410hjs", @"peavey jsx", @"boss ds-1"]
    },
    // Randy Rhoads
    {
      @[@"randy rhoads", @"rhoads", @"crazy train", @"mr crowley", @"blizzard of ozz", @"diary of a madman"],
      @[@"marshall 1959 super lead", @"marshall plexi", @"mxr distortion+"]
    },
    // Zakk Wylde
    {
      @[@"zakk wylde", @"black label society", @"no more tears", @"miracle man", @"stillborn"],
      @[@"marshall jcm800 2203", @"boss sd-1", @"evm-12l"]
    },
    // Van Halen / Eddie Van Halen / Brown Sound
    {
      @[@"van halen", @"eddie van halen", @"evh", @"brown sound", @"eruption", @"panama", @"hot for teacher", @"jump", @"1984"],
      @[@"marshall plexi 1959", @"evh 5150", @"variac plexi", @"greenback 4x12"]
    },
    // Guns N Roses / Slash
    {
      @[@"guns n roses", @"guns n' roses", @"slash", @"sweet child", @"welcome to the jungle", @"november rain", @"paradise city", @"appetite for destruction"],
      @[@"marshall jubilee 2555", @"marshall afd100", @"marshall jcm800", @"greenback"]
    },
    // AC/DC / Angus Young
    {
      @[@"acdc", @"ac/dc", @"angus young", @"malcolm young", @"back in black", @"highway to hell", @"thunderstruck", @"tnt", @"hells bells"],
      @[@"marshall plexi 1959", @"marshall jtm45", @"celestion g12m greenback"]
    },
    // Iron Maiden / Judas Priest
    {
      @[@"iron maiden", @"judas priest", @"trooper", @"painkiller", @"breaking the law", @"hallowed be thy name", @"run to the hills"],
      @[@"marshall jcm800", @"marshall super lead", @"ts9", @"celestion g12m"]
    },
    // Black Sabbath / Tony Iommi
    {
      @[@"black sabbath", @"tony iommi", @"iommi", @"paranoid", @"iron man", @"war pigs", @"children of the grave"],
      @[@"laney supergroup", @"laney ti100", @"dallas rangemaster", @"marshall super lead"]
    },
    // Nirvana / Kurt Cobain
    {
      @[@"nirvana", @"kurt cobain", @"cobain", @"smells like teen spirit", @"in bloom", @"come as you are", @"heart shaped box", @"nevermind", @"in utero"],
      @[@"boss ds-1", @"boss ds-2", @"fender twin reverb", @"mesa studio preamp"]
    },
    // Stevie Ray Vaughan / SRV
    {
      @[@"stevie ray vaughan", @"srv", @"texas flood", @"pride and joy", @"cold shot", @"crossfire", @"scuttle buttin"],
      @[@"fender super reverb", @"fender vibroverb", @"dumble steel string singer", @"ts808 tube screamer"]
    },
    // John Mayer
    {
      @[@"john mayer", @"mayer", @"gravity", @"slow dancing", @"continuum", @"neon", @"bold as love"],
      @[@"two rock custom classic", @"dumble steel string singer", @"fender bandmaster", @"klon centaur"]
    },
    // Jimi Hendrix
    {
      @[@"jimi hendrix", @"hendrix", @"purple haze", @"voodoo child", @"little wing", @"foxy lady"],
      @[@"marshall super lead 100", @"fuzz face", @"vox wah", @"univibe"]
    },
    // Pink Floyd / David Gilmour
    {
      @[@"pink floyd", @"david gilmour", @"gilmour", @"comfortably numb", @"shine on", @"time", @"money", @"echoes"],
      @[@"hiwatt dr103", @"electro-harmonix big muff", @"proco rat", @"fane crescendos"]
    },
    // Led Zeppelin / Jimmy Page
    {
      @[@"led zeppelin", @"jimmy page", @"whole lotta love", @"stairway to heaven", @"kashmir", @"black dog"],
      @[@"supro 1624t", @"marshall super lead", @"tone bender"]
    },
    // Radiohead / Jonny Greenwood
    {
      @[@"radiohead", @"jonny greenwood", @"greenwood", @"paranoid android", @"creep", @"karma police", @"ok computer", @"the bends"],
      @[@"vox ac30", @"fender twin reverb", @"marshall shredmaster"]
    },
    // Queen / Brian May
    {
      @[@"queen", @"brian may", @"bohemian rhapsody", @"we will rock you", @"killer queen"],
      @[@"vox ac30", @"treble booster", @"red special"]
    },
    // Rage Against the Machine / Tom Morello
    {
      @[@"rage against the machine", @"ratm", @"tom morello", @"killing in the name", @"bulls on parade"],
      @[@"marshall jcm800 2205", @"peavey cab", @"digitech whammy"]
    },
    // Polyphia / Tim Henson
    {
      @[@"polyphia", @"tim henson", @"playing god", @"goat", @"g.o.a.t.", @"ego death"],
      @[@"archetype tim henson", @"vox ac30", @"matchless dc30", @"compressor clean"]
    },
    // Blink-182 / Green Day / Pop Punk
    {
      @[@"blink-182", @"blink 182", @"tom delonge", @"all the small things", @"dammit"],
      @[@"mesa triple rectifier", @"marshall jcm900", @"invader"]
    },
    {
      @[@"green day", @"billie joe armstrong", @"dookie", @"american idiot", @"basket case"],
      @[@"marshall plexi 1959", @"marshall jcm800", @"dookie mod"]
    },
    // Generic Metal Styles
    {
      @[@"death metal", @"deathcore", @"metalcore", @"black metal", @"heavy metal", @"thrash metal"],
      @[@"5150", @"peavey 6505", @"dual rectifier", @"mesa mark iv", @"v30"]
    },
    {
      @[@"nu metal", @"drop b", @"drop c", @"drop a", @"7 string", @"8 string", @"baritone"],
      @[@"dual rectifier", @"rivera kr7", @"5150", @"rockerverb", @"v30"]
    },
    {
      @[@"doom metal", @"doom", @"sludge", @"stoner rock", @"stoner metal", @"kyuss", @"sleep"],
      @[@"orange rockerverb", @"matamp", @"sunn model t", @"fuzz face"]
    },
    {
      @[@"shoegaze", @"ambient", @"dream pop"],
      @[@"fender twin reverb", @"roland jc120", @"big muff", @"reverse reverb"]
    },
    {
      @[@"country", @"twang", @"chicken pickin"],
      @[@"fender deluxe reverb", @"fender twin reverb", @"compressor"]
    },
    {
      @[@"jazz", @"clean jazz", @"smooth jazz"],
      @[@"roland jc120", @"polytone mini brute", @"fender twin reverb"]
    }
  };

  const size_t kCount = sizeof(kAssociations) / sizeof(kAssociations[0]);
  for (size_t i = 0; i < kCount; ++i) {
    for (NSString* trigger in kAssociations[i].triggers) {
      if ([clean containsString:trigger]) {
        for (NSString* q in kAssociations[i].queries) addQuery(q);
        break;
      }
    }
  }

  // Direct gear keyword detection
  static NSArray<NSString*>* const kDirectGear = @[
    @"5150", @"6505", @"rectifier", @"dual recto", @"triple recto", @"kr7", @"rivera",
    @"diezel", @"vh4", @"herbert", @"bogner", @"uberschall", @"ecstasy", @"friedman", @"be100",
    @"soldano", @"slo100", @"slo-100", @"jcm800", @"jcm900", @"jcm2000", @"plexi", @"super lead",
    @"jubilee", @"mark iic", @"mark iv", @"mark v", @"dumble", @"steel string singer",
    @"two rock", @"twin reverb", @"deluxe reverb", @"super reverb", @"bassman", @"vibroverb",
    @"ac30", @"ac15", @"matchless dc30", @"rockerverb", @"thunderverb", @"hiwatt", @"dr103",
    @"laney", @"engl", @"powerball", @"fireball", @"invader", @"savage", @"randall", @"warhead",
    @"tube screamer", @"ts9", @"ts808", @"klon", @"centaur", @"king of tone", @"big muff",
    @"rat", @"ds-1", @"precision drive"
  ];
  for (NSString* gear in kDirectGear) {
    if ([clean containsString:gear]) addQuery(gear);
  }

  return results;
}

namespace {
struct AcousticTelemetry {
  BOOL hasBands = NO;
  float peak = -120.0f;
  float rms = -120.0f;
  float crest = 0.0f;
  size_t clipped = 0;
  float bands[5] = {-120.0f, -120.0f, -120.0f, -120.0f, -120.0f};
  BOOL isFullMix = NO;
};

static AcousticTelemetry parseTelemetry(NSString* text) {
  AcousticTelemetry t;
  if (![text isKindOfClass:NSString.class] || !text.length) return t;

  if ([text rangeOfString:@"full mix" options:NSCaseInsensitiveSearch].location != NSNotFound) {
    t.isFullMix = YES;
  }

  NSRange peakRange = [text rangeOfString:@"peak " options:NSCaseInsensitiveSearch];
  if (peakRange.location != NSNotFound) {
    NSScanner* s = [NSScanner scannerWithString:[text substringFromIndex:peakRange.location + peakRange.length]];
    float val = 0;
    if ([s scanFloat:&val]) t.peak = val;
  }

  NSRange rmsRange = [text rangeOfString:@"RMS " options:NSCaseInsensitiveSearch];
  if (rmsRange.location != NSNotFound) {
    NSScanner* s = [NSScanner scannerWithString:[text substringFromIndex:rmsRange.location + rmsRange.length]];
    float val = 0;
    if ([s scanFloat:&val]) t.rms = val;
  }

  NSRange crestRange = [text rangeOfString:@"crest " options:NSCaseInsensitiveSearch];
  if (crestRange.location != NSNotFound) {
    NSScanner* s = [NSScanner scannerWithString:[text substringFromIndex:crestRange.location + crestRange.length]];
    float val = 0;
    if ([s scanFloat:&val]) t.crest = val;
  }

  NSRange clipRange = [text rangeOfString:@"clipped samples " options:NSCaseInsensitiveSearch];
  if (clipRange.location != NSNotFound) {
    NSScanner* s = [NSScanner scannerWithString:[text substringFromIndex:clipRange.location + clipRange.length]];
    long long val = 0;
    if ([s scanLongLong:&val] && val >= 0) t.clipped = (size_t)val;
  }

  NSRange bandRange = [text rangeOfString:@"90/350/1500/5000/10500 Hz:" options:NSCaseInsensitiveSearch];
  if (bandRange.location != NSNotFound) {
    NSScanner* s = [NSScanner scannerWithString:[text substringFromIndex:bandRange.location + bandRange.length]];
    float b[5] = {};
    BOOL ok = YES;
    for (int i = 0; i < 5; ++i) {
      if (![s scanFloat:&b[i]]) { ok = NO; break; }
      if (i < 4) {
        [s scanString:@"/" intoString:nil];
      }
    }
    if (ok) {
      t.hasBands = YES;
      for (int i = 0; i < 5; ++i) t.bands[i] = b[i];
    }
  }

  return t;
}
} // namespace

NSString* rigAIAcousticDeltaGuidance(NSString* playerSummary, NSString* _Nullable referenceSummary) {
  if (![playerSummary isKindOfClass:NSString.class] || !playerSummary.length) return @"";

  NSString* playerText = playerSummary;
  NSString* refText = referenceSummary;

  // If referenceSummary is not provided, check if playerSummary contains both player and reference blocks
  if ((!refText || !refText.length) && [playerText containsString:@"TARGET REFERENCE"]) {
    NSRange r = [playerText rangeOfString:@"TARGET REFERENCE"];
    refText = [playerText substringFromIndex:r.location];
    playerText = [playerText substringToIndex:r.location];
  }

  AcousticTelemetry player = parseTelemetry(playerText);
  AcousticTelemetry ref = parseTelemetry(refText);

  if (!player.hasBands) return @"";

  NSMutableString* out = [NSMutableString string];

  if (ref.hasBands) {
    [out appendString:@"ACOUSTIC SPECTRAL & DYNAMICS DELTAS (Player Take vs Target Reference):\n"];
    if (ref.isFullMix) {
      [out appendString:@"⚠️ Target reference is a FULL MIX (drums/bass boost 90 Hz and cymbals boost 10.5 kHz). Prioritize matching 350 Hz, 1500 Hz, and 5000 Hz.\n"];
    }

    const char* bandNames[5] = {
      "Sub/Low Thump (90 Hz)",
      "Low-Mids/Mud (350 Hz)",
      "Pick Attack/Core Mids (1500 Hz)",
      "Treble/Bite (5000 Hz)",
      "Air/Fizz (10500 Hz)"
    };

    for (int i = 0; i < 5; ++i) {
      float delta = player.bands[i] - ref.bands[i];
      [out appendFormat:@"• %s: Delta %+.1f dB (Player %.1f vs Ref %.1f dBFS) — ", bandNames[i], delta, player.bands[i], ref.bands[i]];
      if (i == 0) { // 90 Hz
        if (delta > 2.5f) {
          [out appendString:@"Excess low-end flub/palm-mute rumble. Reduce 'bass' (-1 to -3 dB) or engage/raise 'input_eq' high-pass (80-120 Hz) to tighten palm mutes.\n"];
        } else if (delta < -2.5f) {
          [out appendString:@"Lean low end. Boost 'bass' or lower high-pass cutoff to restore low-end body.\n"];
        } else {
          [out appendString:@"Low-end resonance closely matches reference.\n"];
        }
      } else if (i == 1) { // 350 Hz
        if (delta > 2.5f) {
          [out appendString:@"Boxy/muddy build-up. Scoop 'mid' slightly, engage OD pedal to tighten pre-gain lows, or adjust cab capture.\n"];
        } else if (delta < -2.5f) {
          [out appendString:@"Lower mids are hollow. Gently raise 'mid' to add warmth and body.\n"];
        } else {
          [out appendString:@"Low-mid body and mud control well balanced.\n"];
        }
      } else if (i == 2) { // 1500 Hz
        if (delta > 2.5f) {
          [out appendString:@"Honky or overly forward mid attack. Soften 'mid' or select a smoother IR.\n"];
        } else if (delta < -2.5f) {
          [out appendString:@"Pick attack is deficient; tone will be buried in a mix. Boost 'mid' (+1 to +3 dB) or engage overdrive pedal (od_drive 10..25, od_tone 55..72) to sharpen pick attack.\n"];
        } else {
          [out appendString:@"Pick articulation and midrange cut well aligned.\n"];
        }
      } else if (i == 3) { // 5000 Hz
        if (delta > 2.5f) {
          [out appendString:@"Harsh treble bite/fizz. Soften 'treble' or 'presence', or tighten 'cab_high_cut' (5.5-6.5 kHz).\n"];
        } else if (delta < -2.5f) {
          [out appendString:@"Dark/muffled top end. Increase 'treble' / 'presence' or use a brighter mic IR position.\n"];
        } else {
          [out appendString:@"Treble presence and bite well aligned.\n"];
        }
      } else if (i == 4) { // 10500 Hz
        if (delta > 3.0f) {
          [out appendString:@"Digital sizzle / harsh aliasing fizz. Real guitar speakers roll off steeply above 6 kHz; apply 'cab_high_cut' (6.0-7.5 kHz).\n"];
        } else {
          [out appendString:@"Ultra-high frequencies within natural speaker boundaries.\n"];
        }
      }
    }
  } else {
    // Single take acoustic profile
    [out appendString:@"ACOUSTIC SPECTRAL & DYNAMICS PROFILE (Player Take):\n"];
    [out appendFormat:@"• Signal Dynamics: Peak %.1f dBFS, RMS %.1f dBFS, Crest factor %.1f dB, Clipped samples %zu\n",
        player.peak, player.rms, player.crest, player.clipped];
    if (player.clipped > 0) {
      [out appendFormat:@"⚠️ %zu clipped samples detected! Lower input_level or master to avoid digital distortion.\n", player.clipped];
    }
    if (player.crest < 7.0f) {
      [out appendString:@"• Dynamics: Heavily saturated / compressed take. Ease off pre-gain or gate threshold.\n"];
    } else if (player.crest > 16.0f) {
      [out appendString:@"• Dynamics: High dynamic range; overdrive saturation or light compression recommended for sustain.\n"];
    }
    if (player.bands[0] > -18.0f && (player.bands[0] - player.bands[1] > 4.0f)) {
      [out appendFormat:@"• Lows (90 Hz: %.1f dBFS): High palm-mute flub relative to 350 Hz. Recommend input high-pass or reducing bass.\n", player.bands[0]];
    }
    if (player.bands[1] > -16.0f && (player.bands[1] - player.bands[2] > 5.0f)) {
      [out appendFormat:@"• Mids (350 Hz: %.1f dBFS): Prominent boxiness. Slight mid scoop recommended.\n", player.bands[1]];
    }
    if (player.bands[2] < -25.0f) {
      [out appendFormat:@"• Attack (1500 Hz: %.1f dBFS): Muted pick attack. TS-style OD pedal recommended.\n", player.bands[2]];
    }
    if (player.bands[4] > -38.0f) {
      [out appendFormat:@"• Ultra-High (10.5 kHz: %.1f dBFS): Sizzle detected. Speaker cab high-cut filter recommended.\n", player.bands[4]];
    }
  }

  return [out copy];
}

BOOL rigAIProviderModelSupportsTemperature(NSString* provider, NSString* model) {
  NSString* p = provider ? provider.lowercaseString : @"";
  NSString* m = model ? model.lowercaseString : @"";
  if ([p isEqualToString:@"claude"]) {
    // Anthropic deprecated sampling parameters (temperature, top_p, top_k) on Claude Opus 4.7+
    // and Claude 5+ models (e.g. claude-opus-5-5, claude-sonnet-5-5, claude-haiku-5-5, claude-fable-5-1).
    // Legacy Claude 2 and Claude 3/3.5 models support temperature when thinking is disabled.
    if ([m containsString:@"claude-3"] || [m containsString:@"claude-2"] || [m containsString:@"claude-instant"]) {
      return YES;
    }
    // Modern/frontier Claude models: omit deprecated sampling parameters by default.
    return NO;
  }
  if ([p isEqualToString:@"openai"]) {
    // OpenAI reasoning models (o1, o3, o4) and GPT-5/GPT-6 families restrict custom temperature.
    // Sending temperature returns HTTP 400 (only default 1.0 supported).
    if ([m hasPrefix:@"o1"] || [m hasPrefix:@"o3"] || [m hasPrefix:@"o4"] ||
        [m containsString:@"gpt-5"] || [m containsString:@"gpt-6"]) {
      return NO;
    }
    return YES;
  }
  if ([p isEqualToString:@"gemini"]) {
    // Google Gemini 3 and Gemini 4 models optimize reasoning at default temperature (1.0).
    // The official API guidance explicitly instructs not to set temperature < 1.0 to avoid loops.
    if ([m containsString:@"gemini-3"] || [m containsString:@"gemini-4"]) {
      return NO;
    }
    return YES;
  }
  return YES;
}
