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

@interface RigAICopilot () {
  RigPreset* _lastUndoSnapshot;
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
  }
  return self;
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

  if (!isOllama && apiKey.length == 0) {
    if (completionHandler) {
      NSString* msg = [NSString stringWithFormat:@"API key not set for provider '%@'. Set it in AI Settings or via %@_API_KEY environment variable.",
                       cfg.provider, cfg.provider.uppercaseString];
      completionHandler(nil, [NSError errorWithDomain:@"RigAICopilot" code:-2 userInfo:@{NSLocalizedDescriptionKey: msg}]);
    }
    return;
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

          if (!content.length) {
            if (completionHandler) {
              completionHandler(nil, [NSError errorWithDomain:@"RigAICopilot" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Empty content from AI response."}]);
            }
            return;
          }

          // Strip ```json ... ``` wrapper if present
          NSString* cleanJson = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
          if ([cleanJson hasPrefix:@"```"]) {
            NSScanner* scanner = [NSScanner scannerWithString:cleanJson];
            [scanner scanString:@"```json" intoString:NULL] || [scanner scanString:@"```" intoString:NULL];
            NSString* inside = nil;
            [scanner scanUpToString:@"```" intoString:&inside];
            if (inside.length) cleanJson = [inside stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
          }

          NSData* cleanData = [cleanJson dataUsingEncoding:NSUTF8StringEncoding];
          NSDictionary* resultJson = [NSJSONSerialization JSONObjectWithData:cleanData options:0 error:nil];
          if (![resultJson isKindOfClass:[NSDictionary class]]) {
            if (completionHandler) {
              completionHandler(nil, [NSError errorWithDomain:@"RigAICopilot" code:-4 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to parse JSON result: %@", cleanJson]}]);
            }
            return;
          }

          RigAICopilotResult* res = [[RigAICopilotResult alloc] init];
          res.thought = resultJson[@"thought"] ?: @"";
          res.explanation = resultJson[@"explanation"] ?: @"Tone adjusted by AI Tone Tuning.";
          res.controls = [resultJson[@"controls"] isKindOfClass:[NSDictionary class]] ? resultJson[@"controls"] : @{};
          res.ampPath = resultJson[@"amp_model"] ?: resultJson[@"amp_path"];
          res.cabPath = resultJson[@"cab_ir"] ?: resultJson[@"cab_path"];
          res.slotPresets = resultJson[@"slot_presets"];
          res.rawJson = resultJson;

          if (completionHandler) completionHandler(res, nil);
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
