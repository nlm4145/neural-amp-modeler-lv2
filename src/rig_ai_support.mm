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

RigAICopilotResult* rigAIParseResponse(NSString* content, NSError** error) {
  if (![content isKindOfClass:NSString.class] || !content.length || content.length > 65536) {
    fail(error, @"AI response is empty, oversized, or not text.");
    return nil;
  }
  NSString* json = [content stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if ([json hasPrefix:@"```json\n"] || [json hasPrefix:@"```\n"]) {
    NSRange newline = [json rangeOfString:@"\n"];
    if (![json hasSuffix:@"```"] || json.length < newline.location + 4) {
      fail(error, @"Unclosed JSON code fence."); return nil;
    }
    json = [json substringWithRange:NSMakeRange(newline.location + 1, json.length - newline.location - 4)];
  }
  id object = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
      options:0 error:error];
  if (![object isKindOfClass:NSDictionary.class]) {
    fail(error, @"AI response must contain exactly one JSON object."); return nil;
  }
  NSDictionary* dict = object;
  for (NSString* key in @[@"preset_name", @"preset_title", @"thought", @"explanation",
                         @"amp_model", @"amp_path", @"cab_ir", @"cab_path", @"pedal_model", @"pedal_path"]) {
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
  result.thought = dict[@"thought"] ?: @"";
  result.explanation = dict[@"explanation"] ?: @"AI tone starting point.";
  result.controls = dict[@"controls"];
  result.ampPath = dict[@"amp_model"] ?: dict[@"amp_path"];
  result.cabPath = dict[@"cab_ir"] ?: dict[@"cab_path"];
  result.pedalPath = dict[@"pedal_model"] ?: dict[@"pedal_path"];
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
  NSMutableArray* items = [NSMutableArray array];
  NSArray* tokens = [query.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet];
  NSDirectoryEnumerator* en = [NSFileManager.defaultManager enumeratorAtPath:root];
  NSMutableDictionary* manifests = [NSMutableDictionary dictionary];
  for (NSUInteger s = 0; s < 3; ++s) totals[s] = 0;
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
    NSString* searchable = item.description.lowercaseString;
    NSUInteger score = 0;
    for (NSString* token in tokens) if (token.length > 2 && [searchable containsString:token]) ++score;
    item[@"score"] = @(score);
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
    if (counts[stage] >= caps[stage] || [packCounts[pack] unsignedIntegerValue] >= 3) continue;
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
