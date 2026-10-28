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

static NSUInteger stageForRelative(NSString* relative) {
  return categoryMatches(relative, 1) ? 1 : categoryMatches(relative, 2) ? 2 : categoryMatches(relative, 0) ? 0 : NSNotFound;
}

// A pack is the first two path components ("Amp/<pack folder>"), or the file itself when it
// sits directly inside the category folder ("Amp/loose.nam").
static NSString* packForRelative(NSString* relative) {
  NSArray* parts = relative.pathComponents;
  return parts.count <= 2 ? relative : [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, 2)]];
}

NSArray<NSDictionary*>* rigAILibraryPackIndex(NSString* root, NSUInteger maxEntries) {
  NSMutableDictionary<NSString*, NSMutableDictionary*>* packs = [NSMutableDictionary dictionary];
  for (NSString* relative in [NSFileManager.defaultManager enumeratorAtPath:root]) {
    const NSUInteger stage = stageForRelative(relative);
    if (stage == NSNotFound) continue;
    NSString* path = [root stringByAppendingPathComponent:relative];
    if (!regularFileInside(root, path)) continue;
    NSString* pack = packForRelative(relative);
    NSMutableDictionary* entry = packs[pack];
    if (!entry) {
      entry = [@{@"pack": pack, @"stage": @(stage), @"captures": @0} mutableCopy];
      NSDictionary* manifest = manifestForPath(path);
      NSDictionary* tone = [manifest[@"tone"] isKindOfClass:NSDictionary.class] ? manifest[@"tone"] : @{};
      NSString* title = [tone[@"title"] isKindOfClass:NSString.class] ? tone[@"title"] : nil;
      if (title.length && ![pack.lastPathComponent.lowercaseString containsString:title.lowercaseString])
        entry[@"title"] = [title substringToIndex:std::min<NSUInteger>(title.length, 80)];
      if (stage == 1 && rigAIModelIncludesCab(path)) entry[@"includes_cab"] = @YES;
      packs[pack] = entry;
    }
    entry[@"captures"] = @([entry[@"captures"] unsignedIntegerValue] + 1);
  }
  NSArray* sorted = [packs.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
    NSComparisonResult s = [a[@"stage"] compare:b[@"stage"]];
    return s != NSOrderedSame ? s : [a[@"pack"] localizedCaseInsensitiveCompare:b[@"pack"]];
  }];
  return sorted.count > maxEntries ? [sorted subarrayWithRange:NSMakeRange(0, maxEntries)] : sorted;
}

NSString* rigAIResolvePackCapture(NSString* root, NSString* target, NSUInteger stage, NSString* query) {
  if (![target isKindOfClass:NSString.class] || !target.length || target.isAbsolutePath ||
      [target.pathComponents containsObject:@".."]) return nil;
  BOOL isDirectory = NO;
  NSString* full = [root stringByAppendingPathComponent:target];
  if (![NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&isDirectory] || !isDirectory) return nil;

  NSString* lowerQuery = query.lowercaseString ?: @"";
  NSMutableArray<NSString*>* tokens = [NSMutableArray array];
  for (NSString* t in [lowerQuery componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet])
    if (t.length > 2) [tokens addObject:t];

  // Gain and voicing intent from query / context
  const BOOL wantsClean = [lowerQuery containsString:@"clean"] || [lowerQuery containsString:@"acoustic"] ||
                          [lowerQuery containsString:@"jazz"] || [lowerQuery containsString:@"ambient"] ||
                          [lowerQuery containsString:@"pristine"] || [lowerQuery containsString:@"sparkle"] ||
                          [lowerQuery containsString:@"twang"] || [lowerQuery containsString:@"country"] ||
                          [lowerQuery containsString:@"funk"] || [lowerQuery containsString:@"cln"] ||
                          [lowerQuery containsString:@"warm clean"];

  const BOOL wantsHeavy = [lowerQuery containsString:@"metal"] || [lowerQuery containsString:@"heavy"] ||
                          [lowerQuery containsString:@"distort"] || [lowerQuery containsString:@"high gain"] ||
                          [lowerQuery containsString:@"highgain"] || [lowerQuery containsString:@"gain"] ||
                          [lowerQuery containsString:@"chug"] || [lowerQuery containsString:@"riff"] ||
                          [lowerQuery containsString:@"drop"] || [lowerQuery containsString:@"djent"] ||
                          [lowerQuery containsString:@"thrash"] || [lowerQuery containsString:@"death"] ||
                          [lowerQuery containsString:@"slipknot"] || [lowerQuery containsString:@"metallica"] ||
                          [lowerQuery containsString:@"pantera"] || [lowerQuery containsString:@"slayer"] ||
                          [lowerQuery containsString:@"korn"] || [lowerQuery containsString:@"deftones"] ||
                          [lowerQuery containsString:@"gojira"] || [lowerQuery containsString:@"meshuggah"] ||
                          [lowerQuery containsString:@"lamb of god"] || [lowerQuery containsString:@"hard rock"] ||
                          [lowerQuery containsString:@"grunge"] || [lowerQuery containsString:@"punk"] ||
                          [lowerQuery containsString:@"aggressive"] || [lowerQuery containsString:@"saturat"] ||
                          [lowerQuery containsString:@"breakdown"] || [lowerQuery containsString:@"core"] ||
                          [lowerQuery containsString:@"shred"] || [lowerQuery containsString:@"burn"];

  const BOOL wantsCrunch = [lowerQuery containsString:@"crunch"] || [lowerQuery containsString:@"crnch"] ||
                           [lowerQuery containsString:@"rock"] || [lowerQuery containsString:@"blues"] ||
                           [lowerQuery containsString:@"overdrive"] || [lowerQuery containsString:@"breakup"] ||
                           [lowerQuery containsString:@"plexi"] || [lowerQuery containsString:@"vintage"];

  const BOOL wantsPreamp = [lowerQuery containsString:@"preamp"] || [lowerQuery containsString:@"[pre]"];
  const BOOL wantsPoweramp = [lowerQuery containsString:@"poweramp"] || [lowerQuery containsString:@"[pow]"];
  const BOOL wantsBoost = [lowerQuery containsString:@"boost"] || [lowerQuery containsString:@"ts9"] ||
                          [lowerQuery containsString:@"od808"] || [lowerQuery containsString:@"screamer"];

  NSString* best = nil;
  NSInteger bestScore = NSIntegerMin;
  for (NSString* inner in [NSFileManager.defaultManager enumeratorAtPath:full]) {
    NSString* relative = [target stringByAppendingPathComponent:inner];
    if (!categoryMatches(relative, stage) || !regularFileInside(root, [root stringByAppendingPathComponent:relative])) continue;
    NSString* name = inner.lowercaseString;
    NSInteger score = 0;
    for (NSString* t in tokens) if ([name containsString:t]) score += 4;

    if (stage == 1) { // Amp stage
      const BOOL isClean = [name containsString:@"clean"] || [name containsString:@"cln"] ||
                           [name containsString:@"ch1"] || [name containsString:@"channel 1"] ||
                           [name containsString:@"channel1"] || [name containsString:@"acoustic"];
      const BOOL isLead = [name containsString:@"lead"] || [name containsString:@"ld"] ||
                          [name containsString:@"high gain"] || [name containsString:@"higain"] ||
                          [name containsString:@"hg"] || [name containsString:@"ch3"] ||
                          [name containsString:@"ch4"] || [name containsString:@"channel 3"] ||
                          [name containsString:@"channel 4"] || [name containsString:@"modern"] ||
                          [name containsString:@"ultra"] || [name containsString:@"red"] ||
                          [name containsString:@"fire"] || [name containsString:@"burn"];
      const BOOL isCrunch = [name containsString:@"crunch"] || [name containsString:@"crnch"] ||
                            [name containsString:@"rhythm"] || [name containsString:@"rhy"] ||
                            [name containsString:@"rhyt"] || [name containsString:@"ch2"] ||
                            [name containsString:@"channel 2"] || [name containsString:@"blue"] ||
                            [name containsString:@"vintage"] || [name containsString:@"drive"] ||
                            [name containsString:@"raw"];
      const BOOL isPre = [name containsString:@"[pre]"] || [name containsString:@"-pre-"] ||
                         [name containsString:@"_pre_"] || [name containsString:@"preamp"];
      const BOOL isPow = [name containsString:@"[pow]"] || [name containsString:@"-pow-"] ||
                         [name containsString:@"_pow_"] || [name containsString:@"poweramp"];
      const BOOL isFullAmp = [name containsString:@"[amp]"] || [name containsString:@"-amp-"] ||
                             [name containsString:@"_amp_"] || [name containsString:@"head"];
      const BOOL isBoosted = [name containsString:@"boost"] || [name containsString:@"ts9"] ||
                             [name containsString:@"od808"] || [name containsString:@"fortin"];

      // Strongly prefer full amplifier head captures over isolated preamp or poweramp slices
      if (isFullAmp) score += 2;
      if (isPre && !wantsPreamp) score -= 5;
      if (isPow && !wantsPoweramp) score -= 8;

      // Voicing alignment based on gain intent
      if (wantsClean && !wantsHeavy) {
        if (isClean) score += 6;
        if (isCrunch) score -= 3;
        if (isLead) score -= 8;
      } else if (wantsHeavy) {
        if (isLead) score += 5;
        if (isCrunch) score += 2;
        if (isClean) score -= 10; // Heavily penalize clean channel for heavy/metal tone
      } else if (wantsCrunch) {
        if (isCrunch) score += 4;
        if (isLead) score += 1;
        if (isClean) score -= 4;
      } else {
        // Neutral / general electric guitar: active amp channels rank ahead of clean
        if (isCrunch) score += 2;
        if (isLead) score += 2;
        if (isClean) score -= 2;
      }

      if ([name containsString:@"rhythm"] || [name containsString:@"rhy"]) score += 2;
      if (isBoosted && !wantsBoost) score -= 1;
    } else {
      // Pedals / Cabinets
      if ([name containsString:@"rhythm"] || [name containsString:@"rhy"]) score += 2;
      for (NSString* variant in @[@"boost", @"lead", @"solo", @"clean", @"cln", @"fuzz"])
        if ([name containsString:variant] && ![tokens containsObject:variant]) score -= 1;
    }

    if (score > bestScore || (score == bestScore && [relative localizedStandardCompare:best] == NSOrderedAscending)) {
      best = relative;
      bestScore = score;
    }
  }
  return best;
}

NSInteger rigAINamParameterCount(NSString* path) {
  if (![path.pathExtension.lowercaseString isEqualToString:@"nam"]) return 0;
  NSData* data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
  if (!data.length || data.length > 100 * 1024 * 1024) return 0;
  const char* mem = (const char*)data.bytes;
  const size_t size = data.length;
  // Count comma-separated values in every "weights" array without building a JSON object graph.
  NSInteger total = 0;
  size_t offset = 0;
  while (offset < size) {
    const char* p = (const char*)memmem(mem + offset, size - offset, "\"weights\"", 9);
    if (!p) break;
    offset = (size_t)(p - mem) + 9;
    while (offset < size && mem[offset] != '[') offset++;
    if (offset >= size) break;
    const size_t start = ++offset;
    while (offset < size && mem[offset] != ']') offset++;
    if (offset >= size) break;
    NSInteger commas = 0;
    bool hasValue = false;
    for (size_t i = start; i < offset; ++i) {
      if (mem[i] == ',') commas++;
      else if (mem[i] > ' ') hasValue = true;
    }
    if (hasValue) total += commas + 1;
    offset++;
  }
  return total;
}

NSString* rigAIProfileKey(NSString* filename) {
  // Same capture exported at different network sizes/architectures, e.g.
  // "Amp-Dialled.nam", "Amp-Dialled-xSTD.nam", "Amp Dialled (A2).nam" -> "ampdialled".
  static NSSet<NSString*>* sizeWords = [NSSet setWithArray:@[
    @"xstd", @"std", @"standard", @"lite", @"light", @"feather", @"nano", @"complex", @"xl",
    @"a1", @"a2", @"custom", @"hq", @"lq"]];
  NSArray* words = [filename.stringByDeletingPathExtension.lowercaseString
      componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet];
  NSMutableString* key = [NSMutableString string];
  for (NSString* w in words) if (w.length && ![sizeWords containsObject:w]) [key appendString:w];
  return key;
}

NSString* rigAICaptureArchitecture(NSString* root, NSString* relative) {
  NSString* full = [root stringByAppendingPathComponent:relative];
  NSDictionary* manifest = manifestForPath(full);
  NSArray* downloads = [manifest[@"downloads"] isKindOfClass:NSArray.class] ? manifest[@"downloads"] : @[];
  for (id entry in downloads) {
    if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"local_filename"] isEqual:relative.lastPathComponent]) continue;
    NSDictionary* model = [entry[@"original_model"] isKindOfClass:NSDictionary.class] ? entry[@"original_model"] : @{};
    id av = model[@"architecture_version"];
    NSString* arch = [av isKindOfClass:NSString.class] ? av : ([av respondsToSelector:@selector(stringValue)] ? [av stringValue] : nil);
    if (arch.length) return ([arch isEqualToString:@"1"] || [arch isEqualToString:@"2"]) ? arch : @"custom";
  }
  // Tone3000 export names often carry the architecture: "... (A1).nam", "... (A2).nam".
  NSArray* words = [relative.lastPathComponent.stringByDeletingPathExtension.lowercaseString
      componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet];
  if ([words containsObject:@"custom"]) return @"custom";
  if ([words containsObject:@"a2"]) return @"2";
  if ([words containsObject:@"a1"]) return @"1";

  // Check JSON header for NAM model architecture
  if ([full.pathExtension.lowercaseString isEqualToString:@"nam"]) {
    NSData* head = [NSData dataWithContentsOfFile:full options:NSDataReadingMappedIfSafe error:nil];
    if (head.length > 0) {
      const char* bytes = (const char*)head.bytes;
      const size_t scanLen = std::min<size_t>(head.length, 2048);
      if (memmem(bytes, scanLen, "SlimmableContainer", 18)) return @"2";
      if (memmem(bytes, scanLen, "WaveNet", 7) || memmem(bytes, scanLen, "LSTM", 4)) return @"1";
    }
  }
  return nil;
}

// Player preference: Custom > A2 > A1; unknown architecture ranks lowest and is compared by size.
static NSInteger architectureRank(NSString* arch) {
  if ([arch isEqualToString:@"custom"]) return 3;
  if ([arch isEqualToString:@"2"]) return 2;
  if ([arch isEqualToString:@"1"]) return 1;
  return 0;
}

NSString* rigAIHighestCapacityVariant(NSString* root, NSString* relative, NSUInteger stage,
                                      NSInteger* outParams, NSInteger* outOriginalParams) {
  if (outParams) *outParams = 0;
  if (outOriginalParams) *outOriginalParams = 0;
  if (![relative isKindOfClass:NSString.class] || !relative.length || !categoryMatches(relative, stage) ||
      ![relative.pathExtension.lowercaseString isEqualToString:@"nam"]) return relative;
  NSString* full = [root stringByAppendingPathComponent:relative];
  if (!regularFileInside(root, full)) return relative;
  NSString* key = rigAIProfileKey(relative.lastPathComponent);
  NSString* folderRelative = relative.stringByDeletingLastPathComponent;
  NSString* best = relative;
  NSInteger original = rigAINamParameterCount(full);
  NSInteger bestParams = original;
  NSInteger bestArch = architectureRank(rigAICaptureArchitecture(root, relative));
  if (key.length) {
    NSArray* siblings = [NSFileManager.defaultManager contentsOfDirectoryAtPath:full.stringByDeletingLastPathComponent error:nil];
    for (NSString* name in siblings) {
      NSString* candidate = [folderRelative stringByAppendingPathComponent:name];
      if ([candidate isEqualToString:relative] || !categoryMatches(candidate, stage) ||
          ![rigAIProfileKey(name) isEqualToString:key]) continue;
      NSString* candidateFull = [root stringByAppendingPathComponent:candidate];
      if (!regularFileInside(root, candidateFull)) continue;
      const NSInteger arch = architectureRank(rigAICaptureArchitecture(root, candidate));
      const NSInteger params = rigAINamParameterCount(candidateFull);
      if (arch > bestArch || (arch == bestArch && params > bestParams)) {
        best = candidate;
        bestParams = params;
        bestArch = arch;
      }
    }
  }
  if (outParams) *outParams = bestParams;
  if (outOriginalParams) *outOriginalParams = original;
  return best;
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
  const BOOL wantsHeavyOrMetal = [lowerQuery containsString:@"metal"] || [lowerQuery containsString:@"heavy"] ||
                                 [lowerQuery containsString:@"distort"] || [lowerQuery containsString:@"high gain"] ||
                                 [lowerQuery containsString:@"highgain"] || [lowerQuery containsString:@"gain"] ||
                                 [lowerQuery containsString:@"chug"] || [lowerQuery containsString:@"drop"] ||
                                 [lowerQuery containsString:@"slipknot"] || [lowerQuery containsString:@"metallica"] ||
                                 [lowerQuery containsString:@"pantera"] || [lowerQuery containsString:@"slayer"] ||
                                 [lowerQuery containsString:@"korn"] || [lowerQuery containsString:@"djent"] ||
                                 [lowerQuery containsString:@"thrash"] || [lowerQuery containsString:@"death"] ||
                                 [lowerQuery containsString:@"hard rock"] || [lowerQuery containsString:@"aggressive"];
  const BOOL wantsCleanTone = [lowerQuery containsString:@"clean"] || [lowerQuery containsString:@"acoustic"] ||
                              [lowerQuery containsString:@"jazz"] || [lowerQuery containsString:@"ambient"] ||
                              [lowerQuery containsString:@"pristine"] || [lowerQuery containsString:@"sparkle"] ||
                              [lowerQuery containsString:@"twang"] || [lowerQuery containsString:@"country"] ||
                              [lowerQuery containsString:@"funk"];
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
    if (score > 0 && stage == 1) {
      NSString* fileLower = relative.lastPathComponent.lowercaseString;
      if (!wantsChainsawOrFuzz) {
        if ([fileLower containsString:@"chainsaw"] || [fileLower containsString:@"jugendstil"] ||
            [fileLower containsString:@"hm300"] || [fileLower containsString:@"pickle"] ||
            [fileLower containsString:@"fuzz"]) {
          score = score > 3 ? score - 3 : 1;
        } else if ([fileLower containsString:@"noboost"] || [fileLower containsString:@"no-boost"] ||
                   [fileLower containsString:@"od808"] || [fileLower containsString:@"ts9"]) {
          score += 1;
        }
      }
      const BOOL isCleanFile = [fileLower containsString:@"clean"] || [fileLower containsString:@"cln"] ||
                               [fileLower containsString:@"ch1"] || [fileLower containsString:@"channel 1"];
      const BOOL isLeadFile = [fileLower containsString:@"lead"] || [fileLower containsString:@"high gain"] ||
                              [fileLower containsString:@"higain"] || [fileLower containsString:@"hg"] ||
                              [fileLower containsString:@"ch3"] || [fileLower containsString:@"ch4"] ||
                              [fileLower containsString:@"modern"] || [fileLower containsString:@"ultra"] ||
                              [fileLower containsString:@"red"];
      const BOOL isPreFile = [fileLower containsString:@"[pre]"] || [fileLower containsString:@"preamp"];
      if (isPreFile && ![lowerQuery containsString:@"preamp"]) {
        score = score > 3 ? score - 3 : 1;
      }
      if (wantsHeavyOrMetal) {
        if (isCleanFile) score = score > 4 ? score - 4 : 1;
        else if (isLeadFile) score += 2;
      } else if (wantsCleanTone) {
        if (isCleanFile) score += 3;
        else if (isLeadFile) score = score > 4 ? score - 4 : 1;
      }
    }
    item[@"score"] = @(score);
    if (maxScores && score > maxScores[stage]) maxScores[stage] = score;
    [items addObject:item];
  }
  [items sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
    NSComparisonResult score = [b[@"score"] compare:a[@"score"]];
    if (score != NSOrderedSame) return score;
    if (wantsHeavyOrMetal) {
      NSString* aName = [a[@"path"] lastPathComponent].lowercaseString;
      NSString* bName = [b[@"path"] lastPathComponent].lowercaseString;
      BOOL aClean = [aName containsString:@"clean"] || [aName containsString:@"cln"];
      BOOL bClean = [bName containsString:@"clean"] || [bName containsString:@"cln"];
      if (aClean != bClean) return aClean ? NSOrderedDescending : NSOrderedAscending;
    } else if (wantsCleanTone) {
      NSString* aName = [a[@"path"] lastPathComponent].lowercaseString;
      NSString* bName = [b[@"path"] lastPathComponent].lowercaseString;
      BOOL aClean = [aName containsString:@"clean"] || [aName containsString:@"cln"];
      BOOL bClean = [bName containsString:@"clean"] || [bName containsString:@"cln"];
      if (aClean != bClean) return aClean ? NSOrderedAscending : NSOrderedDescending;
    }
    return [a[@"path"] compare:b[@"path"]];
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

// ---------------------------------------------------------------------------
// Gear research: the copilot asks the configured model which gear is documented for an
// artist/album/song before searching the library. Replies are cached on disk so repeat
// requests skip the lookup and synchronous searches (library, Tone3000, Learn & Match)
// can reuse the gear names without a hand-written artist table.

static const NSUInteger kGearResearchMaxEntries = 500;
static const NSUInteger kGearResearchMaxItems = 6;

static NSString* gResearchCachePathOverride = nil;
static NSMutableDictionary<NSString*, NSDictionary*>* gResearchEntries = nil;
static NSString* gResearchLoadedPath = nil;

static NSString* normalizedResearchText(NSString* text) {
  if (![text isKindOfClass:NSString.class]) return @"";
  NSArray* raw = [text.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet];
  NSMutableArray* words = [NSMutableArray array];
  for (NSString* w in raw) if (w.length) [words addObject:w];
  return [words componentsJoinedByString:@" "];
}

// Whole-word containment on normalized text ("tool" must not match "toolbox").
static BOOL researchTextNames(NSString* normalizedText, NSString* phrase) {
  NSString* p = normalizedResearchText(phrase);
  if (!p.length || !normalizedText.length) return NO;
  return [[NSString stringWithFormat:@" %@ ", normalizedText] containsString:[NSString stringWithFormat:@" %@ ", p]];
}

BOOL rigAITextNamesPhrase(NSString* text, NSString* _Nullable phrase) {
  return researchTextNames(normalizedResearchText(text), phrase);
}

static NSString* researchString(id value, NSUInteger maxLength) {
  if (![value isKindOfClass:NSString.class]) return @"";
  NSMutableArray* words = [NSMutableArray array];
  for (NSString* w in [value componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet])
    if (w.length) [words addObject:w];
  NSString* s = [words componentsJoinedByString:@" "];
  return s.length > maxLength ? [s substringToIndex:maxLength] : s;
}

static NSArray<NSString*>* researchList(id value, BOOL lowercase) {
  NSMutableArray<NSString*>* out = [NSMutableArray array];
  if (![value isKindOfClass:NSArray.class]) return out;
  for (id item in value) {
    NSString* s = researchString(item, 80);
    if (lowercase) s = s.lowercaseString;
    if (s.length && ![out containsObject:s]) [out addObject:s];
    if (out.count >= kGearResearchMaxItems) break;
  }
  return out;
}

static NSDictionary* _Nullable researchFromObject(id object);

static NSString* researchCachePath() {
  if (gResearchCachePathOverride.length) return gResearchCachePathOverride;
  NSString* appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
  return [[appSupport stringByAppendingPathComponent:@"Axe FX"] stringByAppendingPathComponent:@"gear-research-cache.json"];
}

// Caller holds the lock.
static NSMutableDictionary<NSString*, NSDictionary*>* researchEntriesLocked() {
  NSString* path = researchCachePath();
  if (gResearchEntries && [gResearchLoadedPath isEqualToString:path]) return gResearchEntries;
  gResearchEntries = [NSMutableDictionary dictionary];
  gResearchLoadedPath = [path copy];
  NSData* data = [NSData dataWithContentsOfFile:path];
  NSDictionary* root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  NSDictionary* entries = [root isKindOfClass:NSDictionary.class] && [root[@"entries"] isKindOfClass:NSDictionary.class] ? root[@"entries"] : nil;
  for (NSString* key in entries) {
    NSDictionary* entry = researchFromObject(entries[key]);
    if ([key isKindOfClass:NSString.class] && entry) {
      NSMutableDictionary* e = [entry mutableCopy];
      if ([entries[key][@"updated"] isKindOfClass:NSNumber.class]) e[@"updated"] = entries[key][@"updated"];
      gResearchEntries[key] = e;
    }
  }
  return gResearchEntries;
}

static NSObject* researchLock() {
  static NSObject* lock = [NSObject new];
  return lock;
}

// Queries a local SearXNG instance and returns a compact snippet block for gear lookup prompts.
// Returns nil (silently) when SearXNG is unreachable or returns an error, so the caller can
// fall back to the model's training knowledge without surfacing a hard failure.
NSString* _Nullable rigAIWebSearchForGear(NSString* query, NSString* searxngURL) {
  if (!query.length || !searxngURL.length) return nil;

  // Sanitize and validate URL — only plain HTTP(S) loopback allowed (no credentials).
  NSString* base = [searxngURL stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
  NSURL* baseURL = [NSURL URLWithString:base];
  if (!baseURL || baseURL.user.length || baseURL.password.length) return nil;
  NSString* scheme = baseURL.scheme.lowercaseString;
  NSString* host = baseURL.host.lowercaseString;
  BOOL loopback = [@[@"127.0.0.1", @"localhost", @"::1"] containsObject:host];
  if (![@[@"http", @"https"] containsObject:scheme]) return nil;
  if ([scheme isEqualToString:@"http"] && !loopback) return nil; // Require HTTPS for non-loopback.

  NSURLComponents* comps = [NSURLComponents componentsWithURL:baseURL resolvingAgainstBaseURL:NO];
  comps.path = @"/search";
  comps.queryItems = @[
    [NSURLQueryItem queryItemWithName:@"q" value:query],
    [NSURLQueryItem queryItemWithName:@"format" value:@"json"],
    [NSURLQueryItem queryItemWithName:@"categories" value:@"general"],
  ];
  NSURL* url = comps.URL;
  if (!url) return nil;

  NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:url
                                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                timeoutInterval:10.0];
  [req setValue:@"AxeFX-GearResearch/1.0" forHTTPHeaderField:@"User-Agent"];
  [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

  __block NSData* responseData = nil;
  __block NSInteger statusCode = 0;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  NSURLSession* session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
  [[session dataTaskWithRequest:req completionHandler:^(NSData* data, NSURLResponse* response, NSError*) {
    statusCode = [(NSHTTPURLResponse*)response statusCode];
    responseData = data;
    dispatch_semaphore_signal(sem);
  }] resume];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)));
  [session invalidateAndCancel];

  if (statusCode != 200 || !responseData) return nil;
  NSDictionary* json = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
  NSArray* results = [json[@"results"] isKindOfClass:NSArray.class] ? json[@"results"] : @[];
  if (!results.count) return nil;

  NSMutableString* out = [NSMutableString stringWithFormat:@"WEB SEARCH RESULTS for \"%@\":\n", query];
  NSUInteger count = 0;
  for (id item in results) {
    if (count >= 5) break;
    if (![item isKindOfClass:NSDictionary.class]) continue;
    NSString* title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"";
    NSString* urlStr = [item[@"url"] isKindOfClass:NSString.class] ? item[@"url"] : @"";
    NSString* content = [item[@"content"] isKindOfClass:NSString.class] ? item[@"content"] : @"";
    if (!title.length && !content.length) continue;
    // Truncate snippets to keep the prompt compact.
    if (content.length > 300) content = [[content substringToIndex:297] stringByAppendingString:@"…"];
    [out appendFormat:@"\n[%lu] %@\n%@\n%@\n", (unsigned long)(count + 1), title, urlStr, content];
    count++;
  }
  return count > 0 ? out : nil;
}

NSString* _Nullable rigAIFindSearxngScript(void) {
  NSFileManager* fm = [NSFileManager defaultManager];
  NSMutableArray<NSString*>* candidates = [NSMutableArray array];

  NSString* cwd = fm.currentDirectoryPath;
  if (cwd) {
    [candidates addObject:[cwd stringByAppendingPathComponent:@"searxng.sh"]];
    [candidates addObject:[cwd stringByAppendingPathComponent:@"scripts/searxng.sh"]];
  }

  NSString* bundleDir = [NSBundle mainBundle].bundlePath;
  if (bundleDir) {
    [candidates addObject:[bundleDir stringByAppendingPathComponent:@"Contents/Resources/searxng.sh"]];
    NSString* cur = bundleDir;
    for (int i = 0; i < 5; ++i) {
      cur = [cur stringByDeletingLastPathComponent];
      if (!cur.length || [cur isEqualToString:@"/"]) break;
      [candidates addObject:[cur stringByAppendingPathComponent:@"searxng.sh"]];
    }
  }

  NSString* home = NSHomeDirectory();
  [candidates addObject:[home stringByAppendingPathComponent:@"Documents/Github/neural-amp-modeler-lv2/searxng.sh"]];
  [candidates addObject:[home stringByAppendingPathComponent:@".local/bin/searxng.sh"]];
  [candidates addObject:[home stringByAppendingPathComponent:@"Library/Application Support/Axe FX/searxng.sh"]];

  for (NSString* path in candidates) {
    if ([fm fileExistsAtPath:path] && [fm isExecutableFileAtPath:path]) return path;
  }
  return nil;
}

void rigAIEnsureSearxngRunning(void (^ _Nullable completion)(BOOL success, NSString* message)) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    // 1. Quick probe to see if already responding
    NSURL* probeURL = [NSURL URLWithString:@"http://localhost:8080/"];
    NSMutableURLRequest* probeReq = [NSMutableURLRequest requestWithURL:probeURL
                                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                        timeoutInterval:1.0];
    probeReq.HTTPMethod = @"HEAD";
    [probeReq setValue:@"AxeFX/1.0" forHTTPHeaderField:@"User-Agent"];

    __block BOOL responding = NO;
    dispatch_semaphore_t probeSem = dispatch_semaphore_create(0);
    NSURLSession* probeSession = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    [[probeSession dataTaskWithRequest:probeReq completionHandler:^(NSData*, NSURLResponse* response, NSError*) {
      NSInteger code = [(NSHTTPURLResponse*)response statusCode];
      if (code >= 200 && code < 400) responding = YES;
      dispatch_semaphore_signal(probeSem);
    }] resume];
    dispatch_semaphore_wait(probeSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)));
    [probeSession invalidateAndCancel];

    if (responding) {
      if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
          completion(YES, @"online at http://localhost:8080");
        });
      }
      return;
    }

    // 2. Locate searxng.sh
    NSString* scriptPath = rigAIFindSearxngScript();
    if (!scriptPath) {
      if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
          completion(NO, @"searxng.sh not found");
        });
      }
      return;
    }

    // 3. Launch searxng.sh start via NSTask
    @try {
      NSTask* task = [[NSTask alloc] init];
      task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
      task.arguments = @[scriptPath, @"start"];
      task.currentDirectoryPath = scriptPath.stringByDeletingLastPathComponent;

      NSMutableDictionary* env = [NSProcessInfo.processInfo.environment mutableCopy];
      NSString* home = NSHomeDirectory();
      NSString* curPath = env[@"PATH"] ?: @"/usr/bin:/bin";
      env[@"PATH"] = [NSString stringWithFormat:@"/opt/homebrew/bin:/usr/local/bin:%@/.local/bin:%@/.docker/bin:/Applications/Docker.app/Contents/Resources/bin:%@", home, home, curPath];
      task.environment = env;

      NSPipe* outPipe = [NSPipe pipe];
      task.standardOutput = outPipe;
      task.standardError = outPipe;

      NSError* launchError = nil;
      if (![task launchAndReturnError:&launchError]) {
        if (completion) {
          dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, launchError.localizedDescription ?: @"launch failed");
          });
        }
        return;
      }

      [task waitUntilExit];

      // 4. Verify SearXNG is now responding
      __block BOOL nowUp = NO;
      for (int attempt = 0; attempt < 6; ++attempt) {
        dispatch_semaphore_t checkSem = dispatch_semaphore_create(0);
        NSURLSession* s = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        [[s dataTaskWithRequest:probeReq completionHandler:^(NSData*, NSURLResponse* response, NSError*) {
          NSInteger code = [(NSHTTPURLResponse*)response statusCode];
          if (code >= 200 && code < 400) nowUp = YES;
          dispatch_semaphore_signal(checkSem);
        }] resume];
        dispatch_semaphore_wait(checkSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)));
        [s invalidateAndCancel];
        if (nowUp) break;
        [NSThread sleepForTimeInterval:0.8];
      }

      if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
          if (nowUp) completion(YES, @"started at http://localhost:8080");
          else completion(NO, @"started container but HTTP port 8080 did not respond");
        });
      }
    } @catch (NSException* e) {
      if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
          completion(NO, e.reason ?: @"exception launching searxng.sh");
        });
      }
    }
  });
}

NSString* rigAIGearResearchSystemPrompt() {
  return @"You identify guitar gear for an amp-modeling app. Reply with ONE JSON object only, no Markdown.\n"
         @"Schema: {\"kind\":\"artist|style|adjustment\",\"artist\":\"\",\"album\":\"\",\"song\":\"\",\"era\":\"\","
         @"\"confidence\":\"high|medium|low\",\"amps\":[],\"cabs\":[],\"pedals\":[],\"search_terms\":[],\"notes\":\"\"}\n"
         @"- kind \"artist\": the request names an artist, band, guitarist, album or song. Use canonical spellings for artist/album/song "
         @"and fill album when you know which album the song is on.\n"
         @"- kind \"style\": a genre, era or sound without a specific artist; list typical gear for it.\n"
         @"- kind \"adjustment\": a tweak to the current sound (\"tighter\", \"less fizz\", \"more delay\"); leave gear lists empty.\n"
         @"- amps/cabs/pedals: gear well documented for THAT recording or era (interviews, rig rundowns, liner notes), most important first, "
         @"full model names (e.g. \"Mesa/Boogie Mark IIC+\", \"Mesa 4x12 with Celestion Vintage 30s\", \"Ibanez TS9\"). At most 6 each.\n"
         @"- search_terms: 3-8 short lowercase phrases for searching capture filenames, primary amp first (e.g. \"mark iic+\", \"mesa mark\", \"v30\").\n"
         @"- confidence: high only when the gear is well documented; use low and say so in notes when guessing. Never invent gear.\n"
         @"- notes: at most 40 words.";
}

NSString* rigAIGearResearchUserMessage(NSString* prompt, NSString* _Nullable presetContext) {
  NSMutableString* msg = [NSMutableString stringWithFormat:@"REQUEST: %@", prompt ?: @""];
  if (presetContext.length) {
    [msg appendFormat:@"\nCURRENT PRESET NAME (may identify \"this song/album\"): %@", presetContext];
  }
  return msg;
}

NSDictionary* _Nullable rigAIParseGearResearch(NSString* _Nullable content) {
  if (![content isKindOfClass:NSString.class] || !content.length || content.length > 65536) return nil;
  NSRange open = [content rangeOfString:@"{"];
  NSRange close = [content rangeOfString:@"}" options:NSBackwardsSearch];
  if (open.location == NSNotFound || close.location == NSNotFound || close.location < open.location) return nil;
  NSString* json = [content substringWithRange:NSMakeRange(open.location, close.location - open.location + 1)];
  return researchFromObject([NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]);
}

static NSDictionary* _Nullable researchFromObject(id object) {
  if (![object isKindOfClass:NSDictionary.class]) return nil;
  NSDictionary* d = object;

  NSString* kind = researchString(d[@"kind"], 16).lowercaseString;
  if (![@[@"artist", @"style", @"adjustment"] containsObject:kind]) return nil;
  NSString* confidence = researchString(d[@"confidence"], 8).lowercaseString;
  if (![@[@"high", @"medium", @"low"] containsObject:confidence]) confidence = @"low";

  NSArray* amps = researchList(d[@"amps"], NO);
  NSArray* cabs = researchList(d[@"cabs"], NO);
  NSArray* pedals = researchList(d[@"pedals"], NO);
  NSMutableArray* terms = [researchList(d[@"search_terms"], YES) mutableCopy];
  if (!terms.count) {
    for (NSArray* list in @[amps, cabs, pedals])
      for (NSString* s in list) if (![terms containsObject:s.lowercaseString]) [terms addObject:s.lowercaseString];
  }
  if ([kind isEqualToString:@"adjustment"]) { amps = cabs = pedals = @[]; [terms removeAllObjects]; }
  if (![kind isEqualToString:@"adjustment"] && !amps.count && !terms.count) return nil;
  return @{
    @"kind": kind,
    @"artist": researchString(d[@"artist"], 80),
    @"album": researchString(d[@"album"], 120),
    @"song": researchString(d[@"song"], 120),
    @"era": researchString(d[@"era"], 60),
    @"confidence": confidence,
    @"amps": amps, @"cabs": cabs, @"pedals": pedals,
    @"search_terms": [terms subarrayWithRange:NSMakeRange(0, std::min<NSUInteger>(terms.count, 8))],
    @"notes": researchString(d[@"notes"], 300),
  };
}

void rigAIGearResearchSetCachePath(NSString* _Nullable path) {
  @synchronized(researchLock()) {
    gResearchCachePathOverride = [path copy];
    gResearchEntries = nil;
    gResearchLoadedPath = nil;
  }
}

NSDictionary* _Nullable rigAIGearResearchCached(NSString* prompt) {
  NSString* key = normalizedResearchText(prompt);
  if (!key.length) return nil;
  @synchronized(researchLock()) {
    return researchEntriesLocked()[key];
  }
}

void rigAIGearResearchStore(NSString* prompt, NSDictionary* research) {
  NSString* key = normalizedResearchText(prompt);
  if (!key.length || ![research isKindOfClass:NSDictionary.class]) return;
  @synchronized(researchLock()) {
    NSMutableDictionary* entries = researchEntriesLocked();
    NSMutableDictionary* entry = [research mutableCopy];
    entry[@"updated"] = @((long long)NSDate.date.timeIntervalSince1970);
    entries[key] = entry;
    if (entries.count > kGearResearchMaxEntries) {
      NSArray* oldest = [entries keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        return [a[@"updated"] ?: @0 compare:b[@"updated"] ?: @0];
      }];
      [entries removeObjectsForKeys:[oldest subarrayWithRange:NSMakeRange(0, entries.count - kGearResearchMaxEntries)]];
    }
    NSString* path = researchCachePath();
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSData* data = [NSJSONSerialization dataWithJSONObject:@{@"version": @1, @"entries": entries}
                                                   options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:path atomically:YES];
  }
}

NSDictionary* _Nullable rigAIGearResearchMatching(NSString* text, BOOL specificOnly) {
  NSString* norm = normalizedResearchText(text);
  if (!norm.length) return nil;
  @synchronized(researchLock()) {
    NSMutableDictionary* entries = researchEntriesLocked();
    if (entries[norm]) return entries[norm];
    NSDictionary* best = nil;
    NSInteger bestScore = 0;
    for (NSString* key in entries) {
      NSDictionary* e = entries[key];
      if (![e[@"kind"] isEqual:@"artist"] || !researchTextNames(norm, e[@"artist"])) continue;
      const BOOL songNamed = researchTextNames(norm, e[@"song"]);
      const BOOL albumNamed = researchTextNames(norm, e[@"album"]);
      // Specific reuse must identify the same recording, not just the same artist.
      if (specificOnly && !songNamed && !([e[@"song"] length] == 0 && albumNamed)) continue;
      const NSInteger score = 1 + (songNamed ? 4 : 0) + (albumNamed ? 2 : 0) + ([e[@"confidence"] isEqual:@"high"] ? 1 : 0);
      if (score > bestScore) { best = e; bestScore = score; }
    }
    return best;
  }
}

NSString* rigAIGearResearchSummary(NSDictionary* research) {
  if ([research[@"kind"] isEqual:@"adjustment"]) return @"adjustment to the current sound; no gear lookup needed.";
  NSMutableArray* parts = [NSMutableArray array];
  NSMutableArray* subject = [NSMutableArray array];
  for (NSString* key in @[@"artist", @"album", @"song"])
    if ([research[key] length]) [subject addObject:research[key]];
  if (subject.count) [parts addObject:[subject componentsJoinedByString:@" / "]];
  for (NSString* label in @[@"amps", @"cabs", @"pedals"]) {
    NSArray* list = research[label];
    if ([list isKindOfClass:NSArray.class] && list.count) {
      [parts addObject:[NSString stringWithFormat:@"%@ %@", label, [list componentsJoinedByString:@", "]]];
    }
  }
  return [parts componentsJoinedByString:@"; "];
}

NSArray<NSString*>* rigAISuggestGearQueries(NSString* prompt) {
  if (![prompt isKindOfClass:NSString.class] || !prompt.length) return @[];
  NSDictionary* research = rigAIGearResearchMatching(prompt, NO);
  if (!research) return @[];
  NSMutableArray<NSString*>* results = [NSMutableArray array];
  for (NSArray* list in @[research[@"search_terms"] ?: @[], research[@"amps"] ?: @[],
                          research[@"cabs"] ?: @[], research[@"pedals"] ?: @[]]) {
    for (NSString* s in list) {
      NSString* q = s.lowercaseString;
      if (q.length && ![results containsObject:q]) [results addObject:q];
    }
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
  float bands[8] = {-120.0f, -120.0f, -120.0f, -120.0f, -120.0f, -120.0f, -120.0f, -120.0f};
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

  NSRange bandRange = [text rangeOfString:@"90/250/500/1000/2000/4000/8000/12000 Hz:" options:NSCaseInsensitiveSearch];
  if (bandRange.location != NSNotFound) {
    NSScanner* s = [NSScanner scannerWithString:[text substringFromIndex:bandRange.location + bandRange.length]];
    float b[8] = {};
    BOOL ok = YES;
    for (int i = 0; i < 8; ++i) {
      if (![s scanFloat:&b[i]]) { ok = NO; break; }
      if (i < 7) {
        [s scanString:@"/" intoString:nil];
      }
    }
    if (ok) {
      t.hasBands = YES;
      for (int i = 0; i < 8; ++i) t.bands[i] = b[i];
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
    [out appendString:@"ACOUSTIC SPECTRAL & DYNAMICS DELTAS (Player Take vs Target Reference — level-normalized):\n"];
    if (ref.isFullMix) {
      [out appendString:@"⚠️ Target reference is a FULL MIX (bass/kick boost 90 Hz, cymbals boost 8/12 kHz). Prioritize matching 250 Hz, 500 Hz, 1 kHz, 2 kHz, and 4 kHz.\n"];
    }

    // Level normalization: compute RMS offset so spectral comparison is tonal shape, not volume.
    float rmsOffset = player.rms - ref.rms;
    rmsOffset = std::max(-12.0f, std::min(12.0f, rmsOffset));

    const char* bandNames[8] = {
      "Sub/Low Thump (90 Hz)",
      "Low-Mids/Mud (250 Hz)",
      "Body/Warmth (500 Hz)",
      "Core Midrange (1 kHz)",
      "Upper Mids/Nasal (2 kHz)",
      "Presence/Attack (4 kHz)",
      "Treble/Sizzle (8 kHz)",
      "Air/Fizz (12 kHz)"
    };

    if (player.crest > 0.0f && ref.crest > 0.0f) {
      float crestDelta = player.crest - ref.crest;
      [out appendFormat:@"• Signal Dynamics & Saturation: Delta %+.1f dB (Player %.1f vs Ref %.1f dB crest factor) — ",
          crestDelta, player.crest, ref.crest];
      if (ref.crest < 11.5f && crestDelta > 3.0f) {
        [out appendString:@"Target reference is heavily saturated/compressed (high-gain distortion or heavy overdrive). Player take has much wider dynamic range (clean/uncompressed). Select a high-gain/lead amplifier channel or engage overdrive to match reference saturation.\n"];
      } else if (ref.crest > 14.0f && crestDelta < -3.0f) {
        [out appendString:@"Target reference has wide dynamic headroom (clean or edge-of-breakup tone). Player take is more saturated/compressed. Lower pre-gain/drive or select a clean amp channel to preserve dynamic touch.\n"];
      } else {
        [out appendString:@"Saturation level and dynamic compression closely align with reference.\n"];
      }
    }

    for (int i = 0; i < 8; ++i) {
      float normalizedPlayerBand = player.bands[i] - rmsOffset;
      float delta = normalizedPlayerBand - ref.bands[i];
      [out appendFormat:@"• %s: Delta %+.1f dB (Player %.1f vs Ref %.1f dBFS) — ", bandNames[i], delta, normalizedPlayerBand, ref.bands[i]];
      if (i == 0) { // 90 Hz
        if (delta > 2.5f)  [out appendString:@"Excess low-end flub/palm-mute rumble. Reduce 'bass' or raise input high-pass (80-120 Hz).\n"];
        else if (delta < -2.5f) [out appendString:@"Lean low end. Boost 'bass' or lower high-pass cutoff.\n"];
        else [out appendString:@"Low-end resonance closely matches reference.\n"];
      } else if (i == 1) { // 250 Hz
        if (delta > 2.5f)  [out appendString:@"Boxy/muddy build-up. Scoop 'mid' slightly or engage OD pedal to tighten pre-gain lows.\n"];
        else if (delta < -2.5f) [out appendString:@"Lower mids are hollow. Gently raise 'mid' to add warmth and body.\n"];
        else [out appendString:@"Low-mid body well balanced.\n"];
      } else if (i == 2) { // 500 Hz
        if (delta > 2.5f)  [out appendString:@"Cardboard warmth build-up. Notch 'mid' around 500 Hz or choose a cab with less low-mid bloom.\n"];
        else if (delta < -2.5f) [out appendString:@"Thin/hollow body. Raise 'mid' or try a fuller-sounding cab IR.\n"];
        else [out appendString:@"Body and warmth well matched.\n"];
      } else if (i == 3) { // 1000 Hz
        if (delta > 2.5f)  [out appendString:@"Honky/nasal core. Soften 'mid' (-1 to -2 dB) or select a smoother IR.\n"];
        else if (delta < -2.5f) [out appendString:@"Hollow core midrange. Boost 'mid' (+1 to +2 dB).\n"];
        else [out appendString:@"Core midrange well aligned.\n"];
      } else if (i == 4) { // 2000 Hz
        if (delta > 2.5f)  [out appendString:@"Nasal/aggressive upper mids. Cut 'mid' or reduce 'presence'.\n"];
        else if (delta < -2.5f) [out appendString:@"Recessed upper mids. Raise 'presence' or 'mid' slightly.\n"];
        else [out appendString:@"Upper midrange matches reference.\n"];
      } else if (i == 5) { // 4000 Hz
        if (delta > 2.5f)  [out appendString:@"Harsh presence peak. Soften 'treble'/'presence' (-1 to -2 dB) or choose a darker mic IR position.\n"];
        else if (delta < -2.5f) [out appendString:@"Pick attack is deficient; tone may get buried in a mix. Boost 'presence' or engage OD pedal (od_drive 10-25, od_tone 55-72).\n"];
        else [out appendString:@"Presence and attack well aligned.\n"];
      } else if (i == 6) { // 8000 Hz
        if (delta > 2.5f)  [out appendString:@"Harsh treble sizzle. Increase 'cab_high_cut' (6.5-8 kHz) or soften 'treble'.\n"];
        else if (delta < -2.5f) [out appendString:@"Dull/muffled top end. Raise 'treble' or open up 'cab_high_cut'.\n"];
        else [out appendString:@"Treble sizzle well matched.\n"];
      } else if (i == 7) { // 12000 Hz
        if (delta > 3.0f)  [out appendString:@"Digital fizz / aliasing artefacts. Apply 'cab_high_cut' (6.0-7.5 kHz) — real speakers roll off here.\n"];
        else [out appendString:@"Ultra-high frequencies within natural speaker boundaries.\n"];
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
    if (player.bands[0] > -18.0f && (player.bands[0] - player.bands[2] > 4.0f)) {
      [out appendFormat:@"• Lows (90 Hz: %.1f dBFS): High palm-mute flub relative to 500 Hz. Recommend input high-pass or reducing bass.\n", player.bands[0]];
    }
    if (player.bands[1] > -16.0f && (player.bands[1] - player.bands[3] > 5.0f)) {
      [out appendFormat:@"• Mids (250 Hz: %.1f dBFS): Prominent boxiness. Slight mid scoop recommended.\n", player.bands[1]];
    }
    if (player.bands[5] < -25.0f) {
      [out appendFormat:@"• Attack (4 kHz: %.1f dBFS): Muted presence/attack. TS-style OD pedal recommended.\n", player.bands[5]];
    }
    if (player.bands[7] > -38.0f) {
      [out appendFormat:@"• Ultra-High (12 kHz: %.1f dBFS): Sizzle detected. Speaker cab high-cut filter recommended.\n", player.bands[7]];
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
