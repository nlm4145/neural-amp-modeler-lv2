// RigAICopilot — Universal AI Tone Copilot for Axe FX.
#import "rig_ai_copilot.h"

#include <vector>
#include <string>
#include <algorithm>

#import "rig_control_metadata.h"
#import "rig_presets.h"
#import "rig_ui_state.h"

// Forward-declare helpers from rig_presets.mm
extern NSDictionary<NSString*, NSNumber*>* rigSymbolToPortMap();
extern NSDictionary<NSNumber*, NSString*>* rigPortToSymbolMap();

@implementation RigAIConfig

+ (NSString*)configFilePath {
  NSString* appSupport = [NSSearchPathForDirectoriesInDomains(
      NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
  NSString* dir = [appSupport stringByAppendingPathComponent:@"Axe FX"];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  return [dir stringByAppendingPathComponent:@"ai-config.json"];
}

+ (instancetype)defaultConfig {
  RigAIConfig* c = [[RigAIConfig alloc] init];
  c.provider = @"gemini";
  c.apiKey = @"";
  c.model = @"gemini-3.8-flash";
  c.baseURL = @"https://generativelanguage.googleapis.com/v1beta/openai";
  c.temperature = 0.2f;
  return c;
}

+ (instancetype)loadFromDisk {
  NSString* path = [self configFilePath];
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    RigAIConfig* def = [self defaultConfig];
    [def saveToDisk:nil];
    return def;
  }
  NSData* data = [NSData dataWithContentsOfFile:path];
  if (!data) return [self defaultConfig];

  NSError* err = nil;
  NSDictionary* dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
  if (![dict isKindOfClass:[NSDictionary class]]) return [self defaultConfig];

  RigAIConfig* c = [[RigAIConfig alloc] init];
  c.provider = dict[@"provider"] ?: @"gemini";
  c.apiKey = dict[@"api_key"] ?: @"";
  c.model = dict[@"model"] ?: @"gemini-3.8-flash";
  if ([c.model isEqualToString:@"gemini-2.5-flash"]) {
    c.model = @"gemini-3.8-flash";
  }
  c.baseURL = dict[@"base_url"] ?: @"https://generativelanguage.googleapis.com/v1beta/openai";
  NSNumber* temp = dict[@"temperature"];
  c.temperature = temp ? temp.floatValue : 0.2f;
  return c;
}

- (BOOL)saveToDisk:(NSError**)error {
  NSDictionary* dict = @{
    @"provider": self.provider ?: @"gemini",
    @"api_key": self.apiKey ?: @"",
    @"model": self.model ?: @"gemini-3.8-flash",
    @"base_url": self.baseURL ?: @"",
    @"temperature": @(self.temperature)
  };
  NSData* data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:error];
  if (!data) return NO;
  return [data writeToFile:[[self class] configFilePath] options:NSDataWritingAtomic error:error];
}

- (NSString*)effectiveApiKey {
  if (self.apiKey.length > 0) return self.apiKey;
  NSDictionary<NSString*, NSString*>* env = [NSProcessInfo processInfo].environment;
  NSString* prov = self.provider.lowercaseString;
  if ([prov isEqualToString:@"gemini"]) {
    return env[@"GEMINI_API_KEY"] ?: @"";
  } else if ([prov isEqualToString:@"openai"]) {
    return env[@"OPENAI_API_KEY"] ?: @"";
  } else if ([prov isEqualToString:@"claude"]) {
    return env[@"ANTHROPIC_API_KEY"] ?: @"";
  }
  return @"";
}

- (NSString*)effectiveEndpointURL {
  NSString* prov = self.provider.lowercaseString;
  if ([prov isEqualToString:@"claude"]) {
    return self.baseURL.length ? self.baseURL : @"https://api.anthropic.com/v1/messages";
  }
  NSString* base = self.baseURL.length ? self.baseURL : @"https://generativelanguage.googleapis.com/v1beta/openai";
  if ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
  if ([base hasSuffix:@"/chat/completions"]) return base;
  return [base stringByAppendingString:@"/chat/completions"];
}

@end

@implementation RigAICopilotResult
@end

@implementation RigAIPresetTask

- (NSString*)displayText {
  NSMutableString* s = [NSMutableString string];
  if (self.status == RigAITaskStatusInProgress) {
    [s appendFormat:@"⚡ %@ (in progress ⏳)\n", self.summary ?: @"Custom Preset"];
    [s appendFormat:@"  • Mode: %@ (%@)\n", self.executionMode ?: @"AI", self.model ?: @"default"];
    [s appendString:@"  • Status: Analyzing tone request, scanning Tone3000 library, dialing DSP parameters...\n"];
    [s appendString:@"  • Preset will automatically save to Axe FX Presets upon completion."];
  } else if (self.status == RigAITaskStatusComplete) {
    [s appendFormat:@"⚡ %@ (complete ✅)\n", self.summary ?: @"Custom Preset"];
    if (self.savedPresetName.length > 0) {
      [s appendFormat:@"  • Saved to Axe FX Presets: \"%@\"\n", self.savedPresetName];
    }
    if (self.ampModel.length > 0) {
      [s appendFormat:@"  • Loaded Amp: %@\n", self.ampModel];
    }
    if (self.cabIR.length > 0) {
      [s appendFormat:@"  • Loaded Cab: %@\n", self.cabIR];
    }
    if (self.keyDials.length > 0) {
      [s appendFormat:@"  • Key Dials: %@\n", self.keyDials];
    }
    if (self.explanation.length > 0) {
      [s appendFormat:@"  • Summary: %@\n", self.explanation];
    }
  } else {
    [s appendFormat:@"❌ %@ (failed)\n", self.summary ?: @"Custom Preset"];
    [s appendFormat:@"  • Error: %@", self.errorMessage ?: @"Dial-in failed."];
  }
  return s;
}

@end

static NSString* stripTrailingFluff(NSString* s) {
  if (!s.length) return @"";
  NSString* cur = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  cur = [cur stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@".,!?:;\"'()[]{}"]];

  NSArray<NSString*>* fluffPhrases = @[
    @"with tight attack and no feedback",
    @"with punchy low end",
    @"with aggressive attack",
    @"with no feedback",
    @"with subtle chorus",
    @"with subtle delay",
    @"with heavy reverb",
    @"and scoop mids",
    @"and scooped mids",
    @"and eliminate feedback",
    @"and no feedback",
    @"and tight low end",
    @"for rhythm",
    @"for lead",
    @"for solos",
    @"rhythm tone",
    @"lead tone",
    @"guitar tone",
    @"album tone",
    @"studio tone",
    @"live tone",
    @"second solo",
    @"first solo",
    @"brown sound",
    @"sound",
    @"tone",
    @"preset",
    @"vibe",
    @"style",
    @"settings",
    @"setting",
    @"album"
  ];

  BOOL changed = YES;
  while (changed) {
    changed = NO;
    NSString* lower = cur.lowercaseString;
    for (NSString* fluff in fluffPhrases) {
      if ([lower hasSuffix:fluff]) {
        NSUInteger newLen = cur.length - fluff.length;
        cur = [[cur substringToIndex:newLen] stringByTrimmingCharactersInSet:
               [NSCharacterSet characterSetWithCharactersInString:@" \t\r\n.,!?:;\"'()-/"]];
        changed = YES;
        break;
      }
    }
  }
  return cur;
}

static NSString* titleCasedString(NSString* s) {
  if (!s.length) return @"";
  NSArray<NSString*>* words = [s componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  NSMutableArray<NSString*>* titleWords = [NSMutableArray arrayWithCapacity:words.count];
  NSSet<NSString*>* lowerWords = [NSSet setWithObjects:@"a", @"an", @"the", @"and", @"but", @"or", @"for", @"nor", @"on", @"at", @"to", @"from", @"by", @"of", @"in", nil];
  
  for (NSUInteger i = 0; i < words.count; ++i) {
    NSString* w = words[i];
    if (!w.length) continue;
    NSString* lw = w.lowercaseString;
    if ([w isEqualToString:w.uppercaseString] && w.length > 1 && ![lowerWords containsObject:lw]) {
      [titleWords addObject:w];
    } else if (i > 0 && [lowerWords containsObject:lw]) {
      [titleWords addObject:lw];
    } else {
      [titleWords addObject:[lw capitalizedString]];
    }
  }
  return [titleWords componentsJoinedByString:@" "];
}

@interface RigAICopilot () {
  RigPreset* _lastUndoSnapshot;
  NSMutableArray<RigAIPresetTask*>* _sessionTasks;
  RigAIPresetTask* _currentTask;
}
@property(nonatomic, assign) BOOL isProcessing;
@end

@implementation RigAICopilot

+ (instancetype)sharedCopilot {
  static RigAICopilot* sInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sInstance = [[RigAICopilot alloc] init];
  });
  return sInstance;
}

- (instancetype)init {
  if ((self = [super init])) {
    _config = [RigAIConfig loadFromDisk];
    _sessionTasks = [NSMutableArray array];
  }
  return self;
}

- (NSArray<RigAIPresetTask*>*)sessionTasks {
  @synchronized(self) {
    return [_sessionTasks copy];
  }
}

- (RigAIPresetTask*)currentTask {
  @synchronized(self) {
    return _currentTask;
  }
}

- (RigAIPresetTask*)beginPresetTaskForPrompt:(NSString*)prompt {
  RigAIConfig* cfg = self.config;
  NSString* provider = cfg.provider.lowercaseString;
  NSString* apiKey = [cfg effectiveApiKey];
  NSString* localCLI = [RigAICopilot detectLocalCLIForProvider:provider];

  RigAIPresetTask* task = [[RigAIPresetTask alloc] init];
  task.taskId = [[NSUUID UUID] UUIDString];
  task.prompt = prompt;
  task.summary = [RigAICopilot summarizePromptToPresetName:prompt];
  task.status = RigAITaskStatusInProgress;
  task.provider = cfg.provider;
  task.model = cfg.model ?: @"";
  if (apiKey.length == 0 && localCLI) {
    task.executionMode = [NSString stringWithFormat:@"Local %@", localCLI.lastPathComponent];
  } else {
    task.executionMode = [NSString stringWithFormat:@"Cloud %@", cfg.provider.capitalizedString];
  }
  task.timestamp = [NSDate date];

  @synchronized(self) {
    if (!_sessionTasks) _sessionTasks = [NSMutableArray array];
    [_sessionTasks insertObject:task atIndex:0];
    _currentTask = task;
  }
  return task;
}

- (void)completeCurrentTaskWithResult:(RigAICopilotResult*)result savedPresetName:(nullable NSString*)savedPresetName {
  @synchronized(self) {
    if (_currentTask) {
      if (result.presetName.length > 0) {
        _currentTask.summary = result.presetName;
      }
      _currentTask.savedPresetName = savedPresetName ?: _currentTask.summary;
      _currentTask.ampModel = result.ampPath.lastPathComponent;
      _currentTask.cabIR = result.cabPath.lastPathComponent;
      _currentTask.explanation = result.explanation;

      // Extract key dials summary
      NSMutableArray<NSString*>* parts = [NSMutableArray array];
      NSDictionary<NSString*, NSNumber*>* c = result.controls;
      if (c[@"bass"]) [parts addObject:[NSString stringWithFormat:@"Bass %.1f", c[@"bass"].floatValue]];
      if (c[@"mid"]) [parts addObject:[NSString stringWithFormat:@"Mid %.1f", c[@"mid"].floatValue]];
      if (c[@"treble"]) [parts addObject:[NSString stringWithFormat:@"Treble %.1f", c[@"treble"].floatValue]];
      if (c[@"presence"]) [parts addObject:[NSString stringWithFormat:@"Pres %.1f", c[@"presence"].floatValue]];
      if (c[@"gate_threshold"]) [parts addObject:[NSString stringWithFormat:@"Gate %.0fdB", c[@"gate_threshold"].floatValue]];
      if (c[@"od_enabled"].boolValue) [parts addObject:@"OD Boost on"];
      if (c[@"compressor_enabled"].boolValue) [parts addObject:@"Comp on"];
      if (c[@"delay_mix"].floatValue > 0.05f) [parts addObject:[NSString stringWithFormat:@"Delay %.0f%%", c[@"delay_mix"].floatValue * 100]];
      if (c[@"reverb_mix"].floatValue > 0.05f) [parts addObject:[NSString stringWithFormat:@"Reverb %.0f%%", c[@"reverb_mix"].floatValue * 100]];
      _currentTask.keyDials = [parts componentsJoinedByString:@", "];

      _currentTask.status = RigAITaskStatusComplete;
      _currentTask = nil;
    }
  }
}

- (void)failCurrentTaskWithError:(NSError*)error {
  @synchronized(self) {
    if (_currentTask) {
      _currentTask.status = RigAITaskStatusFailed;
      _currentTask.errorMessage = error.localizedDescription ?: @"Unknown error occurred.";
      _currentTask = nil;
    }
  }
}

- (NSString*)sessionTasksDisplayText {
  @synchronized(self) {
    if (_sessionTasks.count == 0) {
      return
        @"Ready to dial presets.\n\n"
        @"• Type any artist, song, or tone above (e.g. \"Metallica - Master of Puppets\", \"Lamb of God - Redneck\", \"Van Halen - 1984\") and click 'Dial In Tone'.\n"
        @"• The AI will analyze your rig, match Tone3000 amp & cab captures, calculate authentic DSP dials, and automatically save the preset to your Axe FX Presets library.";
    }

    NSMutableString* text = [NSMutableString string];
    for (NSUInteger i = 0; i < _sessionTasks.count; ++i) {
      RigAIPresetTask* t = _sessionTasks[i];
      if (i > 0) {
        [text appendString:@"\n────────────────────────────────────────────────────────────\n\n"];
      }
      [text appendString:[t displayText]];
    }
    return text;
  }
}

- (void)clearSessionTasks {
  @synchronized(self) {
    [_sessionTasks removeAllObjects];
    _currentTask = nil;
  }
}

+ (NSString*)summarizePromptToPresetName:(NSString*)rawPrompt {
  if (!rawPrompt.length) return @"AI Custom Tone";

  NSString* trimmed = [rawPrompt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  trimmed = [trimmed stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\"'"]];

  NSArray<NSString*>* prefixes = @[
    @"please dial in a tone like",
    @"please dial in a tone of",
    @"please dial in a",
    @"please dial in",
    @"can you dial in a tone like",
    @"can you dial in",
    @"can you give me that tone from",
    @"can you give me that",
    @"can you give me a",
    @"can you give me",
    @"give me that tone from",
    @"give me that",
    @"give me a tone like",
    @"give me a",
    @"give me",
    @"gimme that",
    @"gimme a",
    @"gimme",
    @"i want a tone like",
    @"i want that",
    @"i want a",
    @"i want",
    @"dial in a tone like",
    @"dial in that",
    @"dial in a",
    @"dial in",
    @"make it sound like",
    @"sound like",
    @"tone like",
    @"tone of",
    @"tone for",
    @"preset for",
    @"guitar tone for",
    @"guitar sound like",
    @"how about"
  ];
  
  NSString* clean = trimmed;
  for (NSString* pfx in prefixes) {
    if ([clean.lowercaseString hasPrefix:pfx]) {
      clean = [[clean substringFromIndex:pfx.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
      break;
    }
  }

  // 1. Explicit separator " - ", " : ", " / "
  NSArray<NSString*>* seps = @[@" - ", @" : ", @": ", @" / "];
  for (NSString* sep in seps) {
    NSRange r = [clean rangeOfString:sep];
    if (r.location != NSNotFound) {
      NSString* p1 = [[clean substringToIndex:r.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
      NSString* p2 = [[clean substringFromIndex:r.location + r.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
      p2 = stripTrailingFluff(p2);
      if (p1.length > 0 && p2.length > 0) {
        return [NSString stringWithFormat:@"%@ - %@", titleCasedString(p1), titleCasedString(p2)];
      }
    }
  }

  // 2. " by "
  NSRange byRange = [clean rangeOfString:@" by " options:NSCaseInsensitiveSearch];
  if (byRange.location != NSNotFound) {
    NSString* song = [[clean substringToIndex:byRange.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString* artist = [[clean substringFromIndex:byRange.location + byRange.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    song = stripTrailingFluff(song);
    artist = stripTrailingFluff(artist);
    if (song.length > 0 && artist.length > 0) {
      return [NSString stringWithFormat:@"%@ - %@", titleCasedString(artist), titleCasedString(song)];
    }
  }

  // 3. Known artist match
  static NSArray<NSString*>* sKnownArtists = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sKnownArtists = @[
      @"Metallica", @"Megadeth", @"Slayer", @"Anthrax", @"Pantera", @"Lamb of God",
      @"Iron Maiden", @"Judas Priest", @"Black Sabbath", @"Led Zeppelin", @"Pink Floyd",
      @"Van Halen", @"AC/DC", @"Guns N' Roses", @"Deftones", @"Slipknot", @"Jim Root",
      @"Mick Thomson", @"Avenged Sevenfold", @"Alice in Chains", @"Soundgarden", @"Nirvana",
      @"Tool", @"Rammstein", @"Meshuggah", @"Periphery", @"Polyphia", @"Animals as Leaders",
      @"Gojira", @"Dream Theater", @"Opeth", @"Stevie Ray Vaughan", @"SRV", @"Jimi Hendrix",
      @"Eric Clapton", @"B.B. King", @"Gary Moore", @"John Mayer", @"Joe Bonamassa",
      @"Slash", @"Ozzy Osbourne", @"Dio", @"Motörhead", @"System of a Down", @"Korn",
      @"Disturbed", @"Killswitch Engage", @"Trivium", @"Arch Enemy", @"In Flames",
      @"Children of Bodom", @"Mastodon", @"Sepultura", @"Kreator", @"Testament",
      @"Cannibal Corpse", @"Death", @"Ghost", @"Dire Straits", @"The Police", @"Queen",
      @"The Beatles", @"The Rolling Stones", @"The Who", @"Rush", @"Yes", @"Foo Fighters",
      @"Red Hot Chili Peppers", @"Green Day", @"Blink-182", @"Paramore", @"Radiohead",
      @"Muse", @"Smashing Pumpkins", @"Weezer", @"Rage Against the Machine", @"Audioslave",
      @"Queens of the Stone Age", @"Arctic Monkeys", @"The White Stripes", @"Steve Vai",
      @"Joe Satriani", @"Yngwie Malmsteen", @"Randy Rhoads", @"Zakk Wylde", @"Dimebag Darrell",
      @"Buckethead", @"Paul Gilbert", @"Andy Timmons", @"Mateus Asato", @"Tim Henson",
      @"Tesseract", @"Monuments", @"Intervals", @"Plini", @"Chon"
    ];
  });

  NSString* lowerClean = clean.lowercaseString;
  for (NSString* artist in sKnownArtists) {
    NSString* lArtist = artist.lowercaseString;
    NSRange artistRange = [lowerClean rangeOfString:lArtist];
    if (artistRange.location != NSNotFound) {
      NSString* before = [[clean substringToIndex:artistRange.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
      NSString* after = [[clean substringFromIndex:artistRange.location + artistRange.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
      NSString* remainder = (after.length > 0) ? after : before;
      remainder = stripTrailingFluff(remainder);
      if (remainder.length > 0) {
        return [NSString stringWithFormat:@"%@ - %@", artist, titleCasedString(remainder)];
      } else {
        return [NSString stringWithFormat:@"%@ Tone", artist];
      }
    }
  }

  // 4. Fallback: Clean up prompt
  NSString* stripped = stripTrailingFluff(clean);
  if (stripped.length > 36) {
    stripped = [stripped substringToIndex:36];
  }
  return titleCasedString(stripped);
}

- (BOOL)canUndo {
  return _lastUndoSnapshot != nil;
}

+ (NSString*)generateLibrarySummary {
  static NSString* sCachedSummary = nil;
  static NSTimeInterval sLastScan = 0;
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  if (sCachedSummary && (now - sLastScan < 30.0)) {
    return sCachedSummary;
  }

  NSString* libRoot = [@"~/Music/Tone3000 Library" stringByExpandingTildeInPath];
  NSFileManager* fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:libRoot]) {
    return @"(No local Tone3000 Library folder found at ~/Music/Tone3000 Library)";
  }

  NSMutableDictionary<NSString*, NSMutableArray<NSString*>*>* ampFamilies = [NSMutableDictionary dictionary];
  NSMutableArray<NSString*>* cabs = [NSMutableArray array];

  NSDirectoryEnumerator* enumerator = [fm enumeratorAtPath:libRoot];
  NSString* relPath = nil;
  while ((relPath = [enumerator nextObject])) {
    NSString* ext = relPath.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"nam"]) {
      NSArray<NSString*>* components = [relPath pathComponents];
      if (components.count >= 2 && [components[0] isEqualToString:@"Amp"]) {
        NSString* family = components.count >= 3 ? components[1] : @"General";
        if (!ampFamilies[family]) ampFamilies[family] = [NSMutableArray array];
        [ampFamilies[family] addObject:[relPath lastPathComponent]];
      }
    } else if ([ext isEqualToString:@"wav"]) {
      NSArray<NSString*>* components = [relPath pathComponents];
      if (components.count >= 2 && [components[0] isEqualToString:@"Cabinet"]) {
        [cabs addObject:[relPath lastPathComponent]];
      }
    }
  }

  NSMutableString* outStr = [NSMutableString string];
  [outStr appendString:@"Installed Amp Models in ~/Music/Tone3000 Library/Amp:\n"];
  for (NSString* fam in [[ampFamilies allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
    NSArray<NSString*>* models = ampFamilies[fam];
    [outStr appendFormat:@"- %@: %lu model(s) (e.g. %@)\n", fam, (unsigned long)models.count, [models firstObject]];
  }

  [outStr appendString:@"\nInstalled Cabinets in ~/Music/Tone3000 Library/Cabinet:\n"];
  NSUInteger maxCabs = std::min<NSUInteger>(cabs.count, 25);
  for (NSUInteger i = 0; i < maxCabs; ++i) {
    [outStr appendFormat:@"- %@\n", cabs[i]];
  }
  if (cabs.count > maxCabs) {
    [outStr appendFormat:@"- ...and %lu more cabinet IRs\n", (unsigned long)(cabs.count - maxCabs)];
  }

  sCachedSummary = [outStr copy];
  sLastScan = now;
  return sCachedSummary;
}

- (NSString*)buildSystemPromptWithState:(nullable RigUIState*)state {
  NSMutableString* sys = [NSMutableString string];
  [sys appendString:
    @"You are the Axe FX AI Tone Tuning assistant, an elite guitar technician, audio engineer, and DSP expert for the Axe FX standalone guitar rig software.\n\n"
    @"YOUR OBJECTIVE:\n"
    @"Analyze the player's natural language request (artist, song, album, musical genre, or acoustic problem like feedback/muddiness) and dial in an authentic, studio-ready guitar tone.\n\n"
    @"ENGINE ARCHITECTURE & DSP SIGNAL PATH:\n"
    @"1. INPUT STAGE: `input_level` (dB trim).\n"
    @"2. NOISE GATE: `gate_threshold` (-80 to 0 dB, default -55 dB), `gate_release` (5 to 500 ms).\n"
    @"   *CRITICAL DSP RULE*: The noise gate sits BEFORE the Pre-Amp Compressor. If the pre-amp compressor is enabled with high gain, its makeup gain lifts silence/decay by up to +6 dB, which causes runaway acoustic/microphonic feedback. For high gain metal/rock, set `compressor_enabled: 0` and keep gate threshold around -45 to -38 dB.\n"
    @"3. PRE-AMP TONE CARDS:\n"
    @"   - Pre-Amp Overdrive: `od_enabled` (0 or 1), `od_drive` (0.0 to 1.0), `od_tone` (0.0 to 1.0), `od_level` (-12 to +12 dB). Low drive (0.10-0.20), tone 0.55-0.70, level +2-4dB acts as a clean boost to tighten low end for modern metal.\n"
    @"   - Pre-Amp Compressor: `compressor_enabled` (0 or 1), `compressor` (amount 0..1), `compressor_attack` (ms), `compressor_release` (ms).\n"
    @"   - Input EQ: `input_eq` (0.0 to 1.0, 0.50 neutral). Rolling below 0.50 cuts rumble; rolling around 0.45 cuts microphonic high whistle.\n"
    @"4. STAGE 1 (NAM AMPLIFIER):\n"
    @"   - `amp_enabled` (1 or 0), `amp_oversample` (default 6 or 7 for True 8x).\n"
    @"   - Tone stack: `bass` (0 to 10), `mid` (0 to 10), `treble` (0 to 10), `presence` (0 to 10), `depth` (0 to 10).\n"
    @"   - Power section: `master` (0 to 10), `sag` (0 to 10), `bias` (0 to 10), `negative_feedback` (0 to 10), `bright` (0 or 1).\n"
    @"   - Power tubes: `power_tube_type` (0=Bypass, 1=6L6, 2=EL34, 3=KT88, 4=6V6, 5=EL84), `power_tube_character` (0 to 10).\n"
    @"   - Transformer: `transformer_type` (0=Clean/Bypass, 1=Vintage Iron, 2=Modern High Headroom).\n"
    @"5. STAGE 2 (CABINET IR):\n"
    @"   - `cab_enabled` (1 or 0), `cab_level` (dB), `cab_low_cut` (Hz, e.g. 70-90 Hz), `cab_high_cut` (Hz, e.g. 7000-11000 Hz), `ir_normalization` (2.0 = Loudness Match).\n"
    @"6. POST-AMP FX & STUDIO PRO DECK:\n"
    @"   - `delay_mix` (0..1), `delay_time` (ms), `delay_feedback` (0..1).\n"
    @"   - `reverb_mix` (0..1), `reverb_decay` (0..1), `reverb_size` (0..1).\n"
    @"   - `stereo_width` (0..1), `room` (0..1).\n"
    @"   - `output_level` (dB trim, usually -6 to 0 dB).\n\n"
  ];

  [sys appendString:@"USER'S LOCAL TONE3000 LIBRARY:\n"];
  [sys appendString:[[self class] generateLibrarySummary]];
  [sys appendString:
    @"\n\nOUTPUT FORMAT REQUIREMENTS:\n"
    @"You MUST respond with a valid JSON object only (no outer markdown conversational fluff, or wrap only in ```json ... ```). "
    @"The JSON schema must match:\n"
    @"{\n"
    @"  \"preset_name\": \"Concise preset title formatted as '<Artist> - <Song>' or '<Artist> - <Album>' (e.g. 'Metallica - Master of Puppets', 'Lamb of God - Redneck', 'Van Halen - 1984', or 'Modern High-Gain Metal Rhythm')\",\n"
    @"  \"thought\": \"Detailed audio engineering reasoning on frequency curves, gear choices, feedback prevention, and gain staging\",\n"
    @"  \"explanation\": \"Friendly 1-3 sentence summary explaining to the player what was tuned and why it achieves their requested tone\",\n"
    @"  \"amp_model\": \"Filename of the chosen amp capture from the library (or empty if unchanged)\",\n"
    @"  \"cab_ir\": \"Filename of the chosen cabinet IR from the library (or empty if unchanged)\",\n"
    @"  \"controls\": {\n"
    @"    \"control_name\": float_value,\n"
    @"    ... (e.g. \"bass\": 5.2, \"mid\": 6.0, \"treble\": 5.8, \"gate_threshold\": -42.0, \"compressor_enabled\": 0, \"od_enabled\": 1, \"od_drive\": 0.15, \"od_tone\": 0.62, \"input_eq\": 0.46)\n"
    @"  }\n"
    @"}\n"
  ];

  return sys;
}

+ (nullable NSString*)detectLocalCLIForProvider:(NSString*)provider {
  NSString* p = provider.lowercaseString;
  NSString* toolName = nil;
  if ([p isEqualToString:@"gemini"]) {
    toolName = @"agy";
  } else if ([p isEqualToString:@"claude"]) {
    toolName = @"claude";
  } else if ([p isEqualToString:@"openai"]) {
    toolName = @"codex";
  }
  if (!toolName) return nil;

  NSFileManager* fm = [NSFileManager defaultManager];
  NSString* home = NSHomeDirectory();
  NSArray<NSString*>* searchPaths = @[
    [NSString stringWithFormat:@"%@/.local/bin/%@", home, toolName],
    [NSString stringWithFormat:@"/opt/homebrew/bin/%@", toolName],
    [NSString stringWithFormat:@"/usr/local/bin/%@", toolName],
    [NSString stringWithFormat:@"/usr/bin/%@", toolName]
  ];
  for (NSString* sp in searchPaths) {
    if ([fm fileExistsAtPath:sp]) return sp;
  }
  return nil;
}

- (nullable RigAICopilotResult*)parseCopilotResponseContent:(NSString*)content error:(NSError**)error {
  if (!content.length) {
    if (error) *error = [NSError errorWithDomain:@"RigAICopilot" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Empty content from AI response."}];
    return nil;
  }

  // Strip ```json ... ``` wrapper if present
  NSString* cleanJson = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSRange jsonStart = [cleanJson rangeOfString:@"```json"];
  if (jsonStart.location == NSNotFound) {
    jsonStart = [cleanJson rangeOfString:@"```"];
  }
  if (jsonStart.location != NSNotFound) {
    NSUInteger afterCode = jsonStart.location + jsonStart.length;
    NSRange nlRange = [cleanJson rangeOfString:@"\n" options:0 range:NSMakeRange(afterCode, cleanJson.length - afterCode)];
    NSUInteger contentStart = (nlRange.location != NSNotFound) ? nlRange.location + 1 : afterCode;
    NSRange endFence = [cleanJson rangeOfString:@"```" options:0 range:NSMakeRange(contentStart, cleanJson.length - contentStart)];
    if (endFence.location != NSNotFound) {
      cleanJson = [cleanJson substringWithRange:NSMakeRange(contentStart, endFence.location - contentStart)];
    }
  }

  // Find opening '{' and closing '}' to ignore incidental terminal logs or chat wrapping
  NSRange openBrace = [cleanJson rangeOfString:@"{"];
  NSRange closeBrace = [cleanJson rangeOfString:@"}" options:NSBackwardsSearch];
  if (openBrace.location != NSNotFound && closeBrace.location != NSNotFound && closeBrace.location > openBrace.location) {
    cleanJson = [cleanJson substringWithRange:NSMakeRange(openBrace.location, closeBrace.location - openBrace.location + 1)];
  }

  cleanJson = [cleanJson stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSData* cleanData = [cleanJson dataUsingEncoding:NSUTF8StringEncoding];
  NSError* jsonErr = nil;
  NSDictionary* resultJson = cleanData ? [NSJSONSerialization JSONObjectWithData:cleanData options:0 error:&jsonErr] : nil;
  if (![resultJson isKindOfClass:[NSDictionary class]]) {
    if (error) {
      NSString* preview = cleanJson.length > 200 ? [cleanJson substringToIndex:200] : cleanJson;
      NSString* msg = [NSString stringWithFormat:@"Failed to parse JSON result: %@", preview];
      *error = [NSError errorWithDomain:@"RigAICopilot" code:-4 userInfo:@{NSLocalizedDescriptionKey: msg}];
    }
    return nil;
  }

  RigAICopilotResult* res = [[RigAICopilotResult alloc] init];
  NSString* pName = resultJson[@"preset_name"] ?: resultJson[@"preset_title"];
  if ([pName isKindOfClass:[NSString class]] && pName.length > 0) {
    res.presetName = [pName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  }
  res.thought = resultJson[@"thought"] ?: @"";
  res.explanation = resultJson[@"explanation"] ?: @"Tone dialed in by AI Tone Tuning.";
  res.controls = [resultJson[@"controls"] isKindOfClass:[NSDictionary class]] ? resultJson[@"controls"] : @{};
  res.ampPath = resultJson[@"amp_model"] ?: resultJson[@"amp_path"];
  res.cabPath = resultJson[@"cab_ir"] ?: resultJson[@"cab_path"];
  res.slotPresets = resultJson[@"slot_presets"];
  res.rawJson = resultJson;
  return res;
}

- (void)executeLocalCLI:(NSString*)cliPath
               provider:(NSString*)provider
            fullPrompt:(NSString*)fullPrompt
                 model:(NSString*)model
     completionHandler:(void (^)(RigAICopilotResult* _Nullable result, NSError* _Nullable error))completionHandler {
  __weak RigAICopilot* weakSelf = self;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:cliPath];

    NSMutableArray<NSString*>* args = [NSMutableArray array];
    NSString* toolName = cliPath.lastPathComponent.lowercaseString;

    if ([toolName isEqualToString:@"agy"]) {
      [args addObject:@"-p"];
      [args addObject:fullPrompt];
      [args addObject:@"--disable-slash-commands"];
      [args addObject:@"--dangerously-skip-permissions"];
      [args addObject:@"--output-format"];
      [args addObject:@"text"];
    } else if ([toolName isEqualToString:@"claude"]) {
      [args addObject:@"-p"];
      [args addObject:fullPrompt];
    } else if ([toolName isEqualToString:@"codex"]) {
      [args addObject:@"exec"];
      if (model.length > 0 && ![model containsString:@"gpt-6"]) {
        [args addObject:@"-m"];
        [args addObject:model];
      }
    }

    task.arguments = args;

    NSMutableDictionary* env = [[NSProcessInfo processInfo].environment mutableCopy];
    NSString* existingPath = env[@"PATH"] ?: @"/usr/bin:/bin:/usr/sbin:/sbin";
    NSString* extraPaths = [NSString stringWithFormat:@"%@/.local/bin:/opt/homebrew/bin:/usr/local/bin", NSHomeDirectory()];
    env[@"PATH"] = [NSString stringWithFormat:@"%@:%@", extraPaths, existingPath];
    task.environment = env;

    NSPipe* outPipe = [NSPipe pipe];
    NSPipe* inPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = outPipe;
    if ([toolName isEqualToString:@"codex"]) {
      task.standardInput = inPipe;
    }

    NSError* launchErr = nil;
    if (![task launchAndReturnError:&launchErr]) {
      dispatch_async(dispatch_get_main_queue(), ^{
        weakSelf.isProcessing = NO;
        if (completionHandler) completionHandler(nil, launchErr);
      });
      return;
    }

    if ([toolName isEqualToString:@"codex"]) {
      NSData* inputData = [fullPrompt dataUsingEncoding:NSUTF8StringEncoding];
      [inPipe.fileHandleForWriting writeData:inputData];
      [inPipe.fileHandleForWriting closeFile];
    }

    NSData* outputData = [outPipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];

    NSString* outputStr = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] ?: @"";
    NSError* parseErr = nil;
    RigAICopilotResult* res = [weakSelf parseCopilotResponseContent:outputStr error:&parseErr];

    dispatch_async(dispatch_get_main_queue(), ^{
      weakSelf.isProcessing = NO;
      if (res) {
        if (completionHandler) completionHandler(res, nil);
      } else {
        if (completionHandler) {
          NSString* errDetail = (outputStr.length > 0) ? outputStr : (parseErr.localizedDescription ?: [NSString stringWithFormat:@"%@ returned no output", toolName]);
          NSError* err = [NSError errorWithDomain:@"RigAICopilot" code:-6 userInfo:@{NSLocalizedDescriptionKey: errDetail}];
          completionHandler(nil, err);
        }
      }
    });
  });
}

- (void)processUserPrompt:(NSString*)userPrompt
                withState:(nullable RigUIState*)state
        completionHandler:(void (^)(RigAICopilotResult* _Nullable result, NSError* _Nullable error))completionHandler {
  if (self.isProcessing) {
    if (completionHandler) {
      completionHandler(nil, [NSError errorWithDomain:@"RigAICopilot"
                                                 code:-1
                                             userInfo:@{NSLocalizedDescriptionKey: @"A request is already in progress."}]);
    }
    return;
  }

  RigAIConfig* cfg = self.config;
  NSString* apiKey = [cfg effectiveApiKey];
  NSString* provider = cfg.provider.lowercaseString;
  BOOL isOllama = [provider isEqualToString:@"ollama"];
  NSString* localCLI = [RigAICopilot detectLocalCLIForProvider:provider];

  if (!isOllama && apiKey.length == 0 && !localCLI) {
    NSString* msg = [NSString stringWithFormat:@"API key not set for '%@', and no local %@ tool was detected (e.g. Antigravity 'agy', Claude CLI, or Codex). Enter an API key in AI Settings or install Antigravity/Claude/Codex.",
                     cfg.provider, cfg.provider.capitalizedString];
    NSError* keyErr = [NSError errorWithDomain:@"RigAICopilot" code:-2 userInfo:@{NSLocalizedDescriptionKey: msg}];
    [self failCurrentTaskWithError:keyErr];
    if (completionHandler) {
      completionHandler(nil, keyErr);
    }
    return;
  }

  if (!_currentTask || ![_currentTask.prompt isEqualToString:userPrompt]) {
    [self beginPresetTaskForPrompt:userPrompt];
  }

  self.isProcessing = YES;

  // Capture current rig state as JSON context
  NSMutableDictionary* stateContext = [NSMutableDictionary dictionary];
  if (state) {
    RigPreset* current = [RigPreset captureFromState:state name:@"Current Rig"];
    stateContext[@"current_preset"] = state->presetManager.currentPresetName ?: @"Custom";
    NSMutableDictionary* ctrlMap = [NSMutableDictionary dictionary];
    for (const auto& kv : current.allControls) {
      const char* sym = NAMRig::rigControlSymbol(kv.first);
      if (sym && sym[0]) {
        ctrlMap[[NSString stringWithUTF8String:sym]] = @(kv.second);
      }
    }
    stateContext[@"current_controls"] = ctrlMap;
    const auto* ampStage = [current stageAtIndex:1];
    const auto* cabStage = [current stageAtIndex:2];
    stateContext[@"current_amp"] = ampStage ? [NSString stringWithUTF8String:ampStage->path.c_str()].lastPathComponent : @"";
    stateContext[@"current_cab"] = cabStage ? [NSString stringWithUTF8String:cabStage->path.c_str()].lastPathComponent : @"";
  }

  NSData* contextData = [NSJSONSerialization dataWithJSONObject:stateContext options:0 error:nil];
  NSString* contextStr = contextData ? [[NSString alloc] initWithData:contextData encoding:NSUTF8StringEncoding] : @"{}";

  NSString* systemPrompt = [self buildSystemPromptWithState:state];
  NSString* userMessage = [NSString stringWithFormat:
    @"USER REQUEST: %@\n\nCURRENT RIG STATE CONTEXT:\n%@",
    userPrompt, contextStr];

  // If no API key is set, but local CLI is available -> dispatch directly to local CLI!
  if (!isOllama && apiKey.length == 0 && localCLI) {
    NSString* fullPrompt = [NSString stringWithFormat:@"%@\n\n%@", systemPrompt, userMessage];
    [self executeLocalCLI:localCLI
                 provider:provider
               fullPrompt:fullPrompt
                    model:cfg.model
        completionHandler:completionHandler];
    return;
  }

  NSString* endpoint = [cfg effectiveEndpointURL];
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
  request.HTTPMethod = @"POST";
  request.timeoutInterval = 45.0;
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

  NSDictionary* reqBody = nil;
  if ([provider isEqualToString:@"claude"]) {
    [request setValue:apiKey forHTTPHeaderField:@"x-api-key"];
    [request setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
    reqBody = @{
      @"model": cfg.model ?: @"claude-sonnet-5-5",
      @"system": systemPrompt,
      @"messages": @[
        @{@"role": @"user", @"content": userMessage}
      ],
      @"max_tokens": @4096,
      @"temperature": @(cfg.temperature)
    };
  } else {
    // OpenAI, Gemini, Ollama, Groq, DeepSeek
    if (apiKey.length > 0) {
      [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    }
    reqBody = @{
      @"model": cfg.model ?: @"gemini-3.8-flash",
      @"messages": @[
        @{@"role": @"system", @"content": systemPrompt},
        @{@"role": @"user", @"content": userMessage}
      ],
      @"response_format": @{@"type": @"json_object"},
      @"temperature": @(cfg.temperature)
    };
  }

  NSError* jsonErr = nil;
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:reqBody options:0 error:&jsonErr];
  if (jsonErr) {
    self.isProcessing = NO;
    if (completionHandler) completionHandler(nil, jsonErr);
    return;
  }

  __weak RigAICopilot* weakSelf = self;
  NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:request
      completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        dispatch_async(dispatch_get_main_queue(), ^{
          weakSelf.isProcessing = NO;
          if (error) {
            if (completionHandler) completionHandler(nil, error);
            return;
          }

          NSHTTPURLResponse* httpResp = (NSHTTPURLResponse*)response;
          if (httpResp.statusCode < 200 || httpResp.statusCode >= 300) {
            NSString* errBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSString* msg = [NSString stringWithFormat:@"HTTP Error %ld: %@", (long)httpResp.statusCode, errBody ?: @""];
            if (completionHandler) {
              completionHandler(nil, [NSError errorWithDomain:@"RigAICopilot" code:(NSInteger)httpResp.statusCode userInfo:@{NSLocalizedDescriptionKey: msg}]);
            }
            return;
          }

          NSError* parseErr = nil;
          NSDictionary* respDict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
          if (![respDict isKindOfClass:[NSDictionary class]]) {
            if (completionHandler) completionHandler(nil, parseErr);
            return;
          }

          NSString* content = nil;
          if ([provider isEqualToString:@"claude"]) {
            NSArray* contentBlocks = respDict[@"content"];
            if ([contentBlocks isKindOfClass:[NSArray class]] && contentBlocks.count > 0) {
              content = contentBlocks[0][@"text"];
            }
          } else {
            NSArray* choices = respDict[@"choices"];
            if ([choices isKindOfClass:[NSArray class]] && choices.count > 0) {
              content = choices[0][@"message"][@"content"];
            }
          }

          NSError* finalErr = nil;
          RigAICopilotResult* res = [weakSelf parseCopilotResponseContent:content error:&finalErr];
          if (completionHandler) completionHandler(res, finalErr);
        });
      }];

  [task resume];
}

static NSString* findModelInDirectory(NSString* dir, NSString* target) {
  if (!dir.length || !target.length) return nil;
  NSFileManager* fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:target]) return target;

  NSString* direct = [dir stringByAppendingPathComponent:target];
  if ([fm fileExistsAtPath:direct]) return direct;

  NSString* baseName = [target lastPathComponent].lowercaseString;
  NSDirectoryEnumerator* enumerator = [fm enumeratorAtPath:dir];
  NSString* rel = nil;
  while ((rel = [enumerator nextObject])) {
    if ([rel.lastPathComponent.lowercaseString isEqualToString:baseName]) {
      return [dir stringByAppendingPathComponent:rel];
    }
  }
  return nil;
}

- (BOOL)applyResult:(RigAICopilotResult*)result
            toState:(RigUIState*)state
      saveUndoState:(BOOL)saveUndo
              error:(NSError**)error {
  if (!result || !state) return NO;

  if (saveUndo) {
    _lastUndoSnapshot = [RigPreset captureFromState:state name:@"Before AI Tone Tuning"];
  }

  // 1. Controls
  NSDictionary<NSString*, NSNumber*>* symMap = rigSymbolToPortMap();
  for (NSString* sym in result.controls) {
    NSNumber* portNum = symMap[sym];
    if (portNum) {
      uint32_t port = portNum.unsignedIntValue;
      float val = result.controls[sym].floatValue;
      state->sendControl(port, val);
      state->updateControl(port, val);
    }
  }

  // 2. Amp Model
  if (result.ampPath.length) {
    NSString* ampLib = [@"~/Music/Tone3000 Library/Amp" stringByExpandingTildeInPath];
    NSString* fullPath = findModelInDirectory(ampLib, result.ampPath);
    if (!fullPath) {
      fullPath = findModelInDirectory([@"~/Music/Tone3000 Library" stringByExpandingTildeInPath], result.ampPath);
    }
    if (fullPath) {
      std::string cppPath = fullPath.fileSystemRepresentation;
      std::vector<std::string> models = discoverModelsForStagePath(cppPath, 1);
      if (std::find(models.begin(), models.end(), cppPath) == models.end()) {
        models.push_back(cppPath);
      }
      NSMutableArray<NSString*>* modelPaths = [NSMutableArray arrayWithCapacity:models.size()];
      for (const auto& m : models) {
        if (!m.empty()) [modelPaths addObject:[NSString stringWithUTF8String:m.c_str()]];
      }
      state->setStageModels(1, modelPaths);
      state->sendPath(1, cppPath.c_str());
      state->updateThumbnailForStagePath(1, fullPath);
    }
  }

  // 3. Cabinet IR
  if (result.cabPath.length) {
    NSString* cabLib = [@"~/Music/Tone3000 Library/Cabinet" stringByExpandingTildeInPath];
    NSString* fullPath = findModelInDirectory(cabLib, result.cabPath);
    if (!fullPath) {
      fullPath = findModelInDirectory([@"~/Music/Tone3000 Library" stringByExpandingTildeInPath], result.cabPath);
    }
    if (fullPath) {
      std::string cppPath = fullPath.fileSystemRepresentation;
      state->sendPath(2, cppPath.c_str());
      state->updateThumbnailForStagePath(2, fullPath);
    }
  }

  state->markModified();
  return YES;
}

- (BOOL)undoLastAIApplicationToState:(RigUIState*)state error:(NSError**)error {
  if (!_lastUndoSnapshot || !state) {
    if (error) {
      *error = [NSError errorWithDomain:@"RigAICopilot" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"No previous AI state to undo."}];
    }
    return NO;
  }
  [_lastUndoSnapshot applyToState:state];
  _lastUndoSnapshot = nil;
  state->markModified();
  return YES;
}

+ (NSArray<NSString*>*)defaultModelsForProvider:(NSString*)provider {
  NSString* p = provider.lowercaseString;
  if ([p isEqualToString:@"gemini"]) {
    return @[
      @"gemini-3.8-flash",
      @"gemini-3.8-pro",
      @"gemini-3.5-flash",
      @"gemini-3.5-pro",
      @"gemini-3.1-pro",
      @"gemini-3.0-flash",
      @"gemini-2.5-flash",
      @"gemini-2.5-pro",
      @"gemini-2.0-flash"
    ];
  } else if ([p isEqualToString:@"openai"]) {
    return @[
      @"gpt-6.1-sol",
      @"gpt-6-astra",
      @"gpt-6-luna",
      @"sol-6.1",
      @"astra",
      @"gpt-4o",
      @"gpt-4o-mini",
      @"o3-mini",
      @"o1",
      @"gpt-4-turbo"
    ];
  } else if ([p isEqualToString:@"claude"]) {
    return @[
      @"claude-sonnet-5-5",
      @"claude-opus-5-5",
      @"claude-fable-5-1",
      @"claude-fable-5",
      @"claude-3-7-sonnet-20250219",
      @"claude-3-5-sonnet-20241022",
      @"claude-3-5-haiku-20241022",
      @"claude-3-opus-20240229"
    ];
  } else if ([p isEqualToString:@"ollama"]) {
    return @[
      @"llama3.3",
      @"qwen2.5-coder",
      @"deepseek-r1",
      @"mistral"
    ];
  }
  return @[@"default"];
}

- (void)fetchModelsForProvider:(NSString*)provider
             completionHandler:(void (^)(NSArray<NSString*>* _Nullable models, NSError* _Nullable error))completionHandler {
  [self fetchModelsForProvider:provider apiKey:nil completionHandler:completionHandler];
}

- (void)fetchModelsForProvider:(NSString*)provider
                        apiKey:(nullable NSString*)explicitKey
             completionHandler:(void (^)(NSArray<NSString*>* _Nullable models, NSError* _Nullable error))completionHandler {
  NSString* p = provider.lowercaseString;
  NSArray<NSString*>* fallbackList = [RigAICopilot defaultModelsForProvider:p];

  RigAIConfig* cfg = self.config;
  NSString* apiKey = (explicitKey.length > 0) ? explicitKey : [cfg effectiveApiKey];

  NSString* endpoint = nil;
  NSMutableURLRequest* req = nil;

  if ([p isEqualToString:@"claude"]) {
    if (!apiKey.length) {
      if (completionHandler) completionHandler(fallbackList, nil);
      return;
    }
    endpoint = @"https://api.anthropic.com/v1/models?limit=100";
    req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 8.0;
    [req setValue:apiKey forHTTPHeaderField:@"x-api-key"];
    [req setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
  } else if ([p isEqualToString:@"gemini"]) {
    if (!apiKey.length) {
      if (completionHandler) completionHandler(fallbackList, nil);
      return;
    }
    // Google Gemini API models endpoint with key parameter & pageSize=100
    NSString* encKey = [apiKey stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString* urlStr = [NSString stringWithFormat:@"https://generativelanguage.googleapis.com/v1beta/models?key=%@&pageSize=100", encKey];
    req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 8.0;
  } else if ([p isEqualToString:@"openai"]) {
    if (!apiKey.length) {
      if (completionHandler) completionHandler(fallbackList, nil);
      return;
    }
    endpoint = @"https://api.openai.com/v1/models";
    req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 8.0;
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
  } else if ([p isEqualToString:@"ollama"]) {
    NSString* base = cfg.baseURL.length ? cfg.baseURL : @"http://localhost:11434/v1";
    if ([base hasSuffix:@"/chat/completions"]) base = [base stringByDeletingLastPathComponent];
    if ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    endpoint = [base stringByAppendingString:@"/models"];
    req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 4.0;
  } else {
    if (completionHandler) completionHandler(fallbackList, nil);
    return;
  }

  NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:req
      completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        if (error || !data) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (completionHandler) completionHandler(fallbackList, error);
          });
          return;
        }

        NSError* jsonErr = nil;
        NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        if (![json isKindOfClass:[NSDictionary class]]) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (completionHandler) completionHandler(fallbackList, jsonErr);
          });
          return;
        }

        // Parse either "data" array (OpenAI / Anthropic / Ollama) or "models" array (Google native Gemini)
        NSArray* items = json[@"data"];
        if (![items isKindOfClass:[NSArray class]]) {
          items = json[@"models"];
        }

        NSMutableArray<NSDictionary*>* discoveredItems = [NSMutableArray array];

        if ([items isKindOfClass:[NSArray class]]) {
          for (NSDictionary* item in items) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString* mid = item[@"id"] ?: item[@"name"];
            if (!mid || ![mid isKindOfClass:[NSString class]]) continue;

            // Strip "models/" prefix if returned by Google
            if ([mid hasPrefix:@"models/"]) {
              mid = [mid substringFromIndex:7];
            }

            NSString* lower = mid.lowercaseString;
            if ([p isEqualToString:@"gemini"]) {
              if ([lower containsString:@"embedding"] || [lower containsString:@"aqa"] ||
                  [lower containsString:@"imagen"] || [lower containsString:@"learnlm"]) {
                continue;
              }
              if ([lower containsString:@"gemini"]) {
                [discoveredItems addObject:@{@"id": mid, @"created": @0}];
              }
            } else if ([p isEqualToString:@"openai"]) {
              if ([lower containsString:@"whisper"] || [lower containsString:@"tts"] ||
                  [lower containsString:@"dall-e"] || [lower containsString:@"embedding"] ||
                  [lower containsString:@"moderation"] || [lower containsString:@"babbage"] ||
                  [lower containsString:@"davinci"] || [lower containsString:@"canary"]) {
                continue;
              }
              NSNumber* created = item[@"created"];
              [discoveredItems addObject:@{@"id": mid, @"created": created ?: @0}];
            } else if ([p isEqualToString:@"claude"]) {
              if ([lower containsString:@"claude"]) {
                [discoveredItems addObject:@{@"id": mid, @"created": @0}];
              }
            } else {
              [discoveredItems addObject:@{@"id": mid, @"created": @0}];
            }
          }
        }

        // Sort discovered items:
        // If created timestamp is present (OpenAI), sort by timestamp descending (newest releases first).
        // Otherwise sort descending using natural numeric version comparison (e.g. 5.5 > 5.1 > 3.7; 3.8 > 3.5 > 2.5).
        [discoveredItems sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
          NSNumber* tA = a[@"created"];
          NSNumber* tB = b[@"created"];
          if (tA && tB && tA.doubleValue > 0 && tB.doubleValue > 0 && ![tA isEqualToNumber:tB]) {
            return [tB compare:tA];
          }
          NSString* sA = a[@"id"];
          NSString* sB = b[@"id"];
          return [sB compare:sA options:NSNumericSearch | NSCaseInsensitiveSearch];
        }];

        // Live priority merge:
        // Place live discovered models at the top (newest first).
        // Then append any curated flagship models not returned in the account's query.
        NSMutableArray<NSString*>* merged = [NSMutableArray array];
        for (NSDictionary* dict in discoveredItems) {
          NSString* mid = dict[@"id"];
          if (![merged containsObject:mid]) {
            [merged addObject:mid];
          }
        }
        for (NSString* f in fallbackList) {
          if (![merged containsObject:f]) {
            [merged addObject:f];
          }
        }

        if (merged.count == 0) {
          merged = [NSMutableArray arrayWithArray:fallbackList];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
          if (completionHandler) completionHandler(merged, nil);
        });
      }];
  [task resume];
}

@end
