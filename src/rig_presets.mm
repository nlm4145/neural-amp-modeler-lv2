// RigPreset & RigPresetManager — implementation for Axe FX.
#import "rig_presets.h"

#include <sys/stat.h>
#include <algorithm>

#include "rig_knobs.h"
#include "oversample_modes.h"
#include "output_transformer.h"
#include "speaker_dynamics.h"
#include "rig_ui_state.h"

static NSDictionary<NSNumber*, NSString*>* portToSymbolMap() {
  static NSDictionary<NSNumber*, NSString*>* map = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    map = @{
      @4: @"input_level",
      @5: @"output_level",
      @7: @"pedal_enabled",
      @8: @"amp_enabled",
      @9: @"cab_enabled",
      @12: @"bass",
      @13: @"mid",
      @14: @"treble",
      @15: @"gate_threshold",
      @20: @"pedal_oversample",
      @21: @"amp_oversample",
      @22: @"amp_drive",
      @23: @"gate_release",
      @24: @"ir_normalization",
      @25: @"cab_level",
      @26: @"cab_low_cut",
      @27: @"cab_high_cut",
      @28: @"compressor",
      @30: @"transformer_type",
      @32: @"stereo_width",
      @33: @"room",
      @34: @"presence",
      @35: @"depth",
      @36: @"sag",
      @37: @"bias",
      @38: @"negative_feedback",
      @39: @"bright",
      @40: @"input_eq",
      @41: @"master",
      @42: @"speaker_profile",
      @43: @"speaker_drive",
      @44: @"speaker_compression",
      @45: @"speaker_thump",
      @46: @"speaker_resonance",
      @47: @"cab2_enabled",
      @48: @"cab2_level",
      @49: @"cab2_delay",
      @50: @"delay_time",
      @51: @"delay_feedback",
      @52: @"delay_damping",
      @53: @"delay_mix",
      @54: @"reverb_mix",
      @55: @"reverb_decay",
      @56: @"reverb_size",
      @57: @"reverb_damping",
      @58: @"reverb_predelay"
    };
  });
  return map;
}

static NSDictionary<NSString*, NSNumber*>* symbolToPortMap() {
  static NSDictionary<NSString*, NSNumber*>* map = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableDictionary<NSString*, NSNumber*>* inv = [NSMutableDictionary dictionary];
    for (NSNumber* port in portToSymbolMap()) {
      inv[portToSymbolMap()[port]] = port;
    }
    map = [inv copy];
  });
  return map;
}

std::vector<std::string> discoverModelsForStagePath(const std::string& modelPath, size_t stage) {
  if (modelPath.empty()) return {};

  NSString* pathStr = [NSString stringWithUTF8String:modelPath.c_str()];
  NSFileManager* fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:pathStr]) {
    return {modelPath};
  }

  NSString* folder = [pathStr stringByDeletingLastPathComponent];
  NSString* manifestPath = [folder stringByAppendingPathComponent:@"_tone3000.json"];
  NSMutableArray<NSString*>* discovered = [NSMutableArray array];

  // 1. If _tone3000.json exists, follow Tone3000 pack downloads
  if ([fm fileExistsAtPath:manifestPath]) {
    NSData* data = [NSData dataWithContentsOfFile:manifestPath];
    if (data) {
      id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      if ([json isKindOfClass:[NSDictionary class]]) {
        NSArray* downloads = json[@"downloads"];
        if ([downloads isKindOfClass:[NSArray class]]) {
          for (NSDictionary* d in downloads) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            NSString* local = d[@"local_filename"];
            if ([local isKindOfClass:[NSString class]] && local.length) {
              NSString* full = [folder stringByAppendingPathComponent:local];
              if ([fm fileExistsAtPath:full] && ![discovered containsObject:full]) {
                [discovered addObject:full];
              }
            }
          }
        }
      }
    }
  }

  // 2. If no _tone3000.json or downloads empty, scan directory for sibling models
  if (discovered.count == 0) {
    NSArray<NSString*>* files = [fm contentsOfDirectoryAtPath:folder error:nil];
    NSSet* allowedExts = (stage >= 2)
        ? [NSSet setWithObjects:@"wav", @"nam", @"nammodel", @"aidax", @"aidadspmodel", nil]
        : [NSSet setWithObjects:@"nam", @"nammodel", @"aidax", @"aidadspmodel", nil];

    NSMutableArray<NSString*>* candidates = [NSMutableArray array];
    for (NSString* f in files) {
      if ([f hasPrefix:@"."] || [f hasPrefix:@"_"]) continue;
      NSString* ext = [[f pathExtension] lowercaseString];
      if ([allowedExts containsObject:ext]) {
        [candidates addObject:[folder stringByAppendingPathComponent:f]];
      }
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
      return [a.lastPathComponent localizedCaseInsensitiveCompare:b.lastPathComponent];
    }];
    [discovered addObjectsFromArray:candidates];
  }

  // 3. Ensure the current modelPath itself is included
  if (![discovered containsObject:pathStr]) {
    [discovered addObject:pathStr];
  }

  std::vector<std::string> result;
  result.reserve(discovered.count);
  for (NSString* p in discovered) {
    if (p.length) result.push_back(p.UTF8String);
  }
  return result;
}

@implementation RigPreset {
  std::array<RigStagePreset, 4> _stages;
  std::unordered_map<uint32_t, float> _controls;
}

- (RigStagePreset*)stageAtIndex:(size_t)index {
  if (index >= _stages.size()) return &_stages[0];
  return &_stages[index];
}

- (void)setControl:(uint32_t)port value:(float)value {
  _controls[port] = value;
}

- (float)controlForPort:(uint32_t)port {
  auto it = _controls.find(port);
  return (it != _controls.end()) ? it->second : 0.0f;
}

- (const std::unordered_map<uint32_t, float>&)allControls {
  return _controls;
}

+ (RigPreset*)defaultPreset {
  RigPreset* p = [[RigPreset alloc] init];
  p.name = @"Default Rig";
  p.speakerProfile = 0.0f;

  const char* roles[] = {"pedal", "amp", "cab", "cab2"};
  for (size_t s = 0; s < 4; ++s) {
    p->_stages[s].role = roles[s];
    p->_stages[s].enabled = (s < 3);
    p->_stages[s].path.clear();
    p->_stages[s].imageURL.clear();
    p->_stages[s].toneId = 0;
    p->_stages[s].oversample = static_cast<float>(NAMRig::kOversampleTrue8);
    p->_stages[s].transformer = 0.0f;
    p->_stages[s].irNormalization = 2.0f;
    p->_stages[s].models.clear();
  }

  for (size_t k = 0; k < kRigKnobCount; ++k) {
    p->_controls[kRigKnobPorts[k]] = kRigKnobDefaults[k];
  }

  // Toggles & modes:
  p->_controls[7] = 1.0f;   // pedal_enabled
  p->_controls[8] = 1.0f;   // amp_enabled
  p->_controls[9] = 1.0f;   // cab_enabled
  p->_controls[47] = 0.0f;  // cab2_enabled
  p->_controls[20] = static_cast<float>(NAMRig::kOversampleTrue8);
  p->_controls[21] = static_cast<float>(NAMRig::kOversampleTrue8);
  p->_controls[24] = 2.0f;  // Loudness
  p->_controls[30] = 0.0f;  // Captured / Off
  p->_controls[42] = 0.0f;  // Captured / Off

  return p;
}

+ (nullable RigPreset*)loadFromFile:(NSString*)filePath {
  if (!filePath.length || ![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
    return nil;
  }

  NSData* data = [NSData dataWithContentsOfFile:filePath];
  if (!data) return nil;

  NSError* err = nil;
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
  if (err || ![json isKindOfClass:[NSDictionary class]]) return nil;

  NSDictionary* root = (NSDictionary*)json;
  RigPreset* preset = [[RigPreset alloc] init];
  preset.filePath = filePath;
  preset.name = root[@"name"] ?: [filePath.lastPathComponent stringByDeletingPathExtension];
  preset.speakerProfile = [root[@"speaker_profile"] floatValue];

  const char* roles[] = {"pedal", "amp", "cab", "cab2"};
  for (size_t s = 0; s < 4; ++s) {
    preset->_stages[s].role = roles[s];
    preset->_stages[s].enabled = (s < 3);
    preset->_stages[s].path.clear();
    preset->_stages[s].imageURL.clear();
    preset->_stages[s].toneId = 0;
    preset->_stages[s].oversample = static_cast<float>(NAMRig::kOversampleTrue8);
    preset->_stages[s].transformer = 0.0f;
    preset->_stages[s].irNormalization = 2.0f;
    preset->_stages[s].models.clear();
  }

  NSArray* stagesArray = root[@"stages"];
  if ([stagesArray isKindOfClass:[NSArray class]]) {
    for (size_t s = 0; s < std::min((size_t)stagesArray.count, (size_t)4); ++s) {
      NSDictionary* st = stagesArray[s];
      if (![st isKindOfClass:[NSDictionary class]]) continue;
      preset->_stages[s].enabled = st[@"enabled"] ? [st[@"enabled"] boolValue] : (s < 3);
      if (st[@"path"]) preset->_stages[s].path = [st[@"path"] UTF8String];
      if (st[@"imageURL"]) preset->_stages[s].imageURL = [st[@"imageURL"] UTF8String];
      if (st[@"toneId"]) preset->_stages[s].toneId = [st[@"toneId"] longValue];
      if (st[@"oversample"]) preset->_stages[s].oversample = [st[@"oversample"] floatValue];
      if (st[@"transformer"]) preset->_stages[s].transformer = [st[@"transformer"] floatValue];
      if (st[@"ir_normalization"]) preset->_stages[s].irNormalization = [st[@"ir_normalization"] floatValue];
      preset->_stages[s].models.clear();
      NSArray* modelsArr = st[@"models"];
      if ([modelsArr isKindOfClass:[NSArray class]]) {
        for (id m in modelsArr) {
          if ([m isKindOfClass:[NSString class]] && [m length]) {
            preset->_stages[s].models.push_back([m UTF8String]);
          }
        }
      }
      if (preset->_stages[s].models.empty() && !preset->_stages[s].path.empty()) {
        preset->_stages[s].models = discoverModelsForStagePath(preset->_stages[s].path, s);
      }
    }
  }

  // Load controls: first from numeric "ports" if present
  NSDictionary* portsDict = root[@"ports"];
  if ([portsDict isKindOfClass:[NSDictionary class]]) {
    for (NSString* key in portsDict) {
      uint32_t port = (uint32_t)[key longLongValue];
      float val = [portsDict[key] floatValue];
      preset->_controls[port] = val;
    }
  }

  // Then from named "params" if present (allows override or alternate format)
  NSDictionary* paramsDict = root[@"params"];
  if ([paramsDict isKindOfClass:[NSDictionary class]]) {
    NSDictionary<NSString*, NSNumber*>* symMap = symbolToPortMap();
    for (NSString* sym in paramsDict) {
      NSNumber* portNum = symMap[sym];
      if (portNum) {
        preset->_controls[[portNum unsignedIntValue]] = [paramsDict[sym] floatValue];
      }
    }
  }

  return preset;
}

- (BOOL)saveToFile:(NSString*)filePath error:(NSError**)error {
  NSMutableDictionary* root = [NSMutableDictionary dictionary];
  root[@"name"] = self.name ?: @"Untitled";
  root[@"version"] = @1;

  NSDateFormatter* df = [[NSDateFormatter alloc] init];
  df.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
  root[@"created"] = [df stringFromDate:[NSDate date]];
  root[@"speaker_profile"] = @(self.speakerProfile);

  NSMutableArray* stagesList = [NSMutableArray arrayWithCapacity:4];
  for (size_t s = 0; s < 4; ++s) {
    NSMutableDictionary* st = [NSMutableDictionary dictionary];
    st[@"role"] = [NSString stringWithUTF8String:_stages[s].role.c_str()];
    st[@"enabled"] = @(_stages[s].enabled);
    st[@"path"] = [NSString stringWithUTF8String:_stages[s].path.c_str()];
    st[@"imageURL"] = [NSString stringWithUTF8String:_stages[s].imageURL.c_str()];
    st[@"toneId"] = @(_stages[s].toneId);
    if (s == 0 || s == 1) st[@"oversample"] = @(_stages[s].oversample);
    if (s == 1) st[@"transformer"] = @(_stages[s].transformer);
    if (s == 2) st[@"ir_normalization"] = @(_stages[s].irNormalization);
    NSMutableArray* modelsList = [NSMutableArray arrayWithCapacity:_stages[s].models.size()];
    for (const auto& m : _stages[s].models) {
      if (!m.empty()) [modelsList addObject:[NSString stringWithUTF8String:m.c_str()]];
    }
    st[@"models"] = modelsList;
    [stagesList addObject:st];
  }
  root[@"stages"] = stagesList;

  NSMutableDictionary* portsDict = [NSMutableDictionary dictionary];
  NSMutableDictionary* paramsDict = [NSMutableDictionary dictionary];
  NSDictionary<NSNumber*, NSString*>* portMap = portToSymbolMap();

  for (const auto& pair : _controls) {
    NSString* portKey = [NSString stringWithFormat:@"%u", pair.first];
    portsDict[portKey] = @(pair.second);
    NSString* sym = portMap[@(pair.first)];
    if (sym) {
      paramsDict[sym] = @(pair.second);
    }
  }
  root[@"ports"] = portsDict;
  root[@"params"] = paramsDict;

  NSData* data = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:error];
  if (!data) return NO;

  BOOL ok = [data writeToFile:filePath options:NSDataWritingAtomic error:error];
  if (ok) self.filePath = filePath;
  return ok;
}

+ (RigPreset*)captureFromState:(RigUIState*)state name:(NSString*)name {
  RigPreset* p = [[RigPreset alloc] init];
  p.name = name ?: @"Untitled";

  const char* roles[] = {"pedal", "amp", "cab", "cab2"};
  for (size_t s = 0; s < 4; ++s) {
    p->_stages[s].role = roles[s];
    p->_stages[s].path = state->selectedPaths[s];
    p->_stages[s].imageURL = state->selectedImageURLs[s];
    p->_stages[s].toneId = state->selectedToneIds[s];
    p->_stages[s].models = state->availableModelPaths[s];
    if (p->_stages[s].models.empty() && !p->_stages[s].path.empty()) {
      p->_stages[s].models = discoverModelsForStagePath(p->_stages[s].path, s);
    }
    if (!p->_stages[s].path.empty()) {
      if (std::find(p->_stages[s].models.begin(), p->_stages[s].models.end(), p->_stages[s].path) == p->_stages[s].models.end()) {
        p->_stages[s].models.push_back(p->_stages[s].path);
      }
    }
    if (state->powerButtons[s]) {
      p->_stages[s].enabled = (state->powerButtons[s].state == NSControlStateValueOn);
    } else {
      p->_stages[s].enabled = (s < 3);
    }
  }

  // Oversampling modes
  if (state->stageOsPopup[0]) {
    const int idx = (int)state->stageOsPopup[0].indexOfSelectedItem;
    p->_stages[0].oversample = static_cast<float>(NAMRig::oversampleModeFromMenuIndex(idx));
  } else {
    p->_stages[0].oversample = static_cast<float>(NAMRig::kOversampleTrue8);
  }

  if (state->stageOsPopup[1]) {
    const int idx = (int)state->stageOsPopup[1].indexOfSelectedItem;
    p->_stages[1].oversample = static_cast<float>(NAMRig::oversampleModeFromMenuIndex(idx));
  } else {
    p->_stages[1].oversample = static_cast<float>(NAMRig::kOversampleTrue8);
  }

  // Transformer
  if (state->transformerPopup) {
    p->_stages[1].transformer = static_cast<float>(state->transformerPopup.indexOfSelectedItem);
  } else {
    p->_stages[1].transformer = 0.0f;
  }

  // IR Normalization
  if (state->irNormPopup) {
    p->_stages[2].irNormalization = static_cast<float>(state->irNormPopup.indexOfSelectedItem);
  } else {
    p->_stages[2].irNormalization = 2.0f;
  }

  // Speaker Profile
  if (state->speakerProfilePopup) {
    p.speakerProfile = static_cast<float>(state->speakerProfilePopup.indexOfSelectedItem);
  } else {
    p.speakerProfile = 0.0f;
  }

  // Knobs
  for (size_t k = 0; k < kRigKnobCount; ++k) {
    const uint32_t port = kRigKnobPorts[k];
    const float val = state->knobs[k] ? state->knobs[k].floatValue : kRigKnobDefaults[k];
    p->_controls[port] = val;
  }

  // Toggles and modes into controls map:
  p->_controls[7] = p->_stages[0].enabled ? 1.0f : 0.0f;
  p->_controls[8] = p->_stages[1].enabled ? 1.0f : 0.0f;
  p->_controls[9] = p->_stages[2].enabled ? 1.0f : 0.0f;
  p->_controls[47] = p->_stages[3].enabled ? 1.0f : 0.0f;
  p->_controls[20] = p->_stages[0].oversample;
  p->_controls[21] = p->_stages[1].oversample;
  p->_controls[24] = p->_stages[2].irNormalization;
  p->_controls[30] = p->_stages[1].transformer;
  p->_controls[42] = p.speakerProfile;

  return p;
}

- (void)applyToState:(RigUIState*)state {
  if (!state) return;

  // 1. Stage powers (ports 7, 8, 9, 47)
  state->sendControl(7, _stages[0].enabled ? 1.0f : 0.0f);
  state->updateControl(7, _stages[0].enabled ? 1.0f : 0.0f);
  state->sendControl(8, _stages[1].enabled ? 1.0f : 0.0f);
  state->updateControl(8, _stages[1].enabled ? 1.0f : 0.0f);
  state->sendControl(9, _stages[2].enabled ? 1.0f : 0.0f);
  state->updateControl(9, _stages[2].enabled ? 1.0f : 0.0f);
  state->sendControl(47, _stages[3].enabled ? 1.0f : 0.0f);
  state->updateControl(47, _stages[3].enabled ? 1.0f : 0.0f);

  // 2. Modes and Profiles
  state->sendControl(20, _stages[0].oversample);
  state->updateControl(20, _stages[0].oversample);
  state->sendControl(21, _stages[1].oversample);
  state->updateControl(21, _stages[1].oversample);
  state->sendControl(24, _stages[2].irNormalization);
  state->updateControl(24, _stages[2].irNormalization);
  state->sendControl(30, _stages[1].transformer);
  state->updateControl(30, _stages[1].transformer);
  state->sendControl(42, self.speakerProfile);
  state->updateControl(42, self.speakerProfile);

  // 3. Knobs
  for (size_t k = 0; k < kRigKnobCount; ++k) {
    const uint32_t port = kRigKnobPorts[k];
    auto it = _controls.find(port);
    const float val = (it != _controls.end()) ? it->second : kRigKnobDefaults[k];
    state->sendControl(port, val);
    state->updateControl(port, val);
  }

  // 4. Models: populate available stage selections and load selected models
  for (size_t s = 0; s < 4; ++s) {
    const std::string& path = _stages[s].path;
    const std::string& img = _stages[s].imageURL;
    const long toneId = _stages[s].toneId;
    std::vector<std::string> stageModels = _stages[s].models;
    if (stageModels.empty() && !path.empty()) {
      stageModels = discoverModelsForStagePath(path, s);
    }
    if (!path.empty()) {
      // Ensure the active path is present in stageModels
      if (std::find(stageModels.begin(), stageModels.end(), path) == stageModels.end()) {
        stageModels.push_back(path);
      }
      state->selectedPaths[s] = path;
      NSMutableArray<NSString*>* modelPaths = [NSMutableArray arrayWithCapacity:stageModels.size()];
      for (const auto& m : stageModels) {
        if (!m.empty()) [modelPaths addObject:[NSString stringWithUTF8String:m.c_str()]];
      }
      state->setStageModels(s, modelPaths);
      state->sendPath(s, path.c_str());
      if (img.length() || toneId > 0) {
        state->setStageThumb(s, nil, toneId, [NSString stringWithUTF8String:img.c_str()]);
      }
    } else {
      state->setStageModels(s, @[]);
      state->sendPath(s, "");
      state->setStageThumb(s, nil, 0, nil);
    }
  }
}

@end

@interface RigPresetManager () {
  NSMutableArray<NSString*>* _presetNames;
}
@end

@implementation RigPresetManager

+ (instancetype)sharedManager {
  static RigPresetManager* shared = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    shared = [[RigPresetManager alloc] init];
  });
  return shared;
}

- (instancetype)init {
  if (self = [super init]) {
    _presetNames = [NSMutableArray array];
    _isModified = NO;
    _currentPresetName = @"Default Rig";
    [self ensureDefaultPresetExists];
    [self rescanPresets];
    [self restoreCurrentPresetName];
  }
  return self;
}

- (NSString*)presetsDirectory {
  NSString* home = NSHomeDirectory();
  NSString* dir = [home stringByAppendingPathComponent:@"Library/Application Support/Axe FX/Presets"];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  return dir;
}

- (NSString*)currentPresetFilePath {
  NSString* home = NSHomeDirectory();
  return [home stringByAppendingPathComponent:@"Library/Application Support/Axe FX/current-preset.txt"];
}

- (void)ensureDefaultPresetExists {
  NSString* defaultPath = [self.presetsDirectory stringByAppendingPathComponent:@"Default Rig.json"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:defaultPath]) {
    RigPreset* def = [RigPreset defaultPreset];
    [def saveToFile:defaultPath error:nil];
  }
}

- (void)rescanPresets {
  [_presetNames removeAllObjects];
  NSFileManager* fm = [NSFileManager defaultManager];
  NSArray<NSString*>* files = [fm contentsOfDirectoryAtPath:self.presetsDirectory error:nil];
  for (NSString* f in files) {
    if ([f hasPrefix:@"."]) continue;
    if ([[f pathExtension] isEqualToString:@"json"]) {
      [_presetNames addObject:[f stringByDeletingPathExtension]];
    }
  }
  [_presetNames sortUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
    // "Default Rig" always stays first
    if ([a isEqualToString:@"Default Rig"]) return NSOrderedAscending;
    if ([b isEqualToString:@"Default Rig"]) return NSOrderedDescending;
    return [a localizedCaseInsensitiveCompare:b];
  }];

  if (_presetNames.count == 0) {
    [_presetNames addObject:@"Default Rig"];
  }

  if (![_presetNames containsObject:_currentPresetName]) {
    _currentPresetName = _presetNames.firstObject;
    _isModified = NO;
  }
}

- (nullable RigPreset*)loadPresetNamed:(NSString*)name {
  if (!name.length) return nil;
  NSString* path = [self.presetsDirectory stringByAppendingPathComponent:
                    [name.lastPathComponent stringByAppendingPathExtension:@"json"]];
  RigPreset* p = [RigPreset loadFromFile:path];
  if (p) {
    _currentPresetName = [name copy];
    _isModified = NO;
    [self persistCurrentPresetName];
  }
  return p;
}

- (BOOL)savePreset:(RigPreset*)preset error:(NSError**)error {
  if (!preset || !preset.name.length) return NO;
  NSString* safeName = [preset.name stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
  safeName = [safeName stringByReplacingOccurrencesOfString:@":" withString:@"-"];
  NSString* path = [self.presetsDirectory stringByAppendingPathComponent:
                    [safeName stringByAppendingPathExtension:@"json"]];
  BOOL ok = [preset saveToFile:path error:error];
  if (ok) {
    _currentPresetName = [preset.name copy];
    _isModified = NO;
    [self rescanPresets];
    [self persistCurrentPresetName];
  }
  return ok;
}

- (BOOL)saveCurrentPresetFromState:(RigUIState*)state error:(NSError**)error {
  if (!_currentPresetName.length) _currentPresetName = @"Default Rig";
  return [self savePresetNamed:_currentPresetName fromState:state error:error];
}

- (BOOL)savePresetNamed:(NSString*)name fromState:(RigUIState*)state error:(NSError**)error {
  if (!name.length || !state) return NO;
  RigPreset* p = [RigPreset captureFromState:state name:name];
  return [self savePreset:p error:error];
}

- (BOOL)deletePresetNamed:(NSString*)name error:(NSError**)error {
  if (!name.length || [name isEqualToString:@"Default Rig"]) return NO;
  NSString* path = [self.presetsDirectory stringByAppendingPathComponent:
                    [name.lastPathComponent stringByAppendingPathExtension:@"json"]];
  BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:path error:error];
  if (ok) {
    [self rescanPresets];
    _currentPresetName = _presetNames.firstObject;
    _isModified = NO;
    [self persistCurrentPresetName];
  }
  return ok;
}

- (nullable NSString*)nextPresetName {
  if (_presetNames.count <= 1) return nil;
  NSUInteger idx = [_presetNames indexOfObject:_currentPresetName];
  if (idx == NSNotFound) return _presetNames.firstObject;
  NSUInteger nextIdx = (idx + 1) % _presetNames.count;
  return _presetNames[nextIdx];
}

- (nullable NSString*)previousPresetName {
  if (_presetNames.count <= 1) return nil;
  NSUInteger idx = [_presetNames indexOfObject:_currentPresetName];
  if (idx == NSNotFound) return _presetNames.firstObject;
  NSUInteger prevIdx = (idx == 0) ? (_presetNames.count - 1) : (idx - 1);
  return _presetNames[prevIdx];
}

- (void)revealPresetsInFinder {
  NSString* dir = self.presetsDirectory;
  NSString* cur = [dir stringByAppendingPathComponent:
                   [_currentPresetName.lastPathComponent stringByAppendingPathExtension:@"json"]];
  if ([[NSFileManager defaultManager] fileExistsAtPath:cur]) {
    [[NSWorkspace sharedWorkspace] selectFile:cur inFileViewerRootedAtPath:dir];
  } else {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir]];
  }
}

- (NSString*)displayTitle {
  NSString* name = _currentPresetName.length ? _currentPresetName : @"Default Rig";
  return _isModified ? [name stringByAppendingString:@" *"] : name;
}

- (void)persistCurrentPresetName {
  if (!_currentPresetName.length) return;
  [_currentPresetName writeToFile:[self currentPresetFilePath]
                       atomically:YES
                         encoding:NSUTF8StringEncoding
                            error:nil];
}

- (void)restoreCurrentPresetName {
  NSString* file = [self currentPresetFilePath];
  if ([[NSFileManager defaultManager] fileExistsAtPath:file]) {
    NSString* saved = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
    saved = [saved stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (saved.length && [_presetNames containsObject:saved]) {
      _currentPresetName = saved;
      _isModified = NO;
    }
  }
}

@end
