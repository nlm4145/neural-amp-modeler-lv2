// RigPreset & RigPresetManager — implementation for Axe FX.
#import "rig_presets.h"
#import "rig_ai_copilot.h"
#import "rig_profile_catalog.h"

#include <sys/stat.h>
#include <algorithm>

#include "rig_knobs.h"
#include "oversample_modes.h"
#include "ir_normalization.h"
#include "output_transformer.h"
#include "pin_eq.h"
#include "power_tube_controls.h"
#include "rack_controls.h"
#include "rig_control_metadata.h"
#include "speaker_dynamics.h"
#include "rig_ui_state.h"

static NSDictionary<NSNumber*, NSString*>* portToSymbolMap() {
  static NSDictionary<NSNumber*, NSString*>* map = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableDictionary* symbols = [NSMutableDictionary dictionary];
    NAMRig::forEachRigControlSymbol([&](uint32_t port, const char* symbol) {
      symbols[@(port)] = [NSString stringWithUTF8String:symbol];
    });
    map = [symbols copy];
  });
  return map;
}

NSDictionary<NSNumber*, NSString*>* rigPortToSymbolMap() {
  return portToSymbolMap();
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

NSDictionary<NSString*, NSNumber*>* rigSymbolToPortMap() {
  return symbolToPortMap();
}

std::vector<std::string> discoverModelsForStagePath(const std::string& modelPath, size_t stage) {
  if (modelPath.empty()) return {};

  NSString* pathStr = [NSString stringWithUTF8String:modelPath.c_str()];
  NSFileManager* fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:pathStr]) {
    return {modelPath};
  }

  // 1. If RigProfileCatalog classifies this model, return all captures for this model across local packs
  NSArray<NSString*>* classified = [[RigProfileCatalog sharedCatalog] allModelPathsForModelPath:pathStr stage:stage];
  if (classified.count > 0) {
    std::vector<std::string> result;
    result.reserve(classified.count);
    for (NSString* p in classified) {
      if (p.length) result.push_back(p.fileSystemRepresentation);
    }
    return result;
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
    NSSet* allowedExts = (stage == 2 || stage == 3)
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
  std::array<RigStagePreset, 6> _stages;
  std::unordered_map<uint32_t, float> _controls;
}

- (instancetype)init {
  if (self = [super init]) {
    _slotPresets = [NSMutableDictionary dictionary];
  }
  return self;
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

  const char* roles[] = {"pedal", "amp", "cab", "cab2", "pedal2", "pedal3"};
  for (size_t s = 0; s < 6; ++s) {
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
  p->_controls[59] = 0.0f;  // cab2_polarity: normal
  p->_controls[NAMRig::kPostCompressorEnabledPort] = 1.0f;
  p->_controls[20] = static_cast<float>(NAMRig::kOversampleTrue8);
  p->_controls[21] = static_cast<float>(NAMRig::kOversampleTrue8);
  p->_controls[24] = 2.0f;  // Loudness
  p->_controls[30] = 0.0f;  // Captured / Off
  for (size_t i = 0; i < NAMRig::kTransformerControlCount; ++i)
    p->_controls[NAMRig::kTransformerControlFirstPort + i] = NAMRig::kTransformerControlDefaults[i];
  for (size_t i = 0; i < NAMRig::kRackCount; ++i)
    p->_controls[NAMRig::kRackControlFirstPort + i] = NAMRig::kRackControlDefaults[i];
  p->_controls[NAMRig::kPowerTubeTypePort] = 0.0f;
  p->_controls[NAMRig::kPowerTubeCharacterPort] = NAMRig::kPowerTubeCharacterDefault;
  p->_controls[NAMRig::kOverdriveVoicingPort] = 0.0f;
  p->_controls[42] = 0.0f;  // Captured / Off
  for (uint32_t i = 0; i < NAMRig::kPinEqPortCount; ++i)
    p->_controls[NAMRig::kPinEqFirstPort + i] = NAMRig::pinEqDefault(NAMRig::kPinEqFirstPort + i);

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
  NSDictionary* spDict = root[@"slot_presets"];
  if ([spDict isKindOfClass:[NSDictionary class]]) {
    preset.slotPresets = [spDict mutableCopy];
  } else {
    preset.slotPresets = [NSMutableDictionary dictionary];
  }

  const char* roles[] = {"pedal", "amp", "cab", "cab2", "pedal2", "pedal3"};
  for (size_t s = 0; s < 6; ++s) {
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
    for (size_t s = 0; s < std::min((size_t)stagesArray.count, (size_t)6); ++s) {
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
      if (!preset->_stages[s].path.empty()) {
        std::vector<std::string> discovered = discoverModelsForStagePath(preset->_stages[s].path, s);
        if (!discovered.empty()) {
          preset->_stages[s].models = std::move(discovered);
        }
      }
    }
  }

  // Load controls: first from numeric "ports" if present
  preset->_controls[59] = 0.0f;  // Legacy presets default to normal polarity.
  for (uint32_t i = 0; i < NAMRig::kPostCompressorDefaults.size(); ++i)
    preset->_controls[NAMRig::kPostCompressorFirstPort + i] = NAMRig::kPostCompressorDefaults[i];
  for (size_t i = 0; i < NAMRig::kTransformerControlCount; ++i)
    preset->_controls[NAMRig::kTransformerControlFirstPort + i] = NAMRig::kTransformerControlDefaults[i];
  for (size_t i = 0; i < NAMRig::kRackCount; ++i)
    preset->_controls[NAMRig::kRackControlFirstPort + i] = NAMRig::kRackControlDefaults[i];
  preset->_controls[NAMRig::kPowerTubeTypePort] = 0.0f;
  preset->_controls[NAMRig::kPowerTubeCharacterPort] = NAMRig::kPowerTubeCharacterDefault;
  preset->_controls[NAMRig::kOverdriveVoicingPort] = 0.0f;
  // Presets saved before graph pins existed recall with no pins placed.
  for (uint32_t i = 0; i < NAMRig::kPinEqPortCount; ++i)
    preset->_controls[NAMRig::kPinEqFirstPort + i] = NAMRig::pinEqDefault(NAMRig::kPinEqFirstPort + i);
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

  // Controls win over the stale stage field in older Windows captures.
  const float savedNorm = preset->_controls.count(24) ? preset->_controls[24]
      : preset->_stages[2].irNormalization;
  preset->_stages[2].irNormalization = NAMRig::decodeIrNormalization(savedNorm);
  preset->_controls[24] = preset->_stages[2].irNormalization;

  // Migrate v1 presets where cab_level (port 25) scaled the combined Cab A + Cab B
  // sum rather than Cab A alone. Adding cab_level to cab2_level (port 48) when Cab B
  // is active preserves the exact effective level of Cab B from v1 sessions.
  const NSInteger version = root[@"version"] ? [root[@"version"] integerValue] : 1;
  if (version < 2) {
    auto itA = preset->_controls.find(25);
    const float cabADb = (itA != preset->_controls.end()) ? itA->second : 0.0f;
    const float oldCabBDb = preset->_controls.count(48) ? preset->_controls[48] : 0.0f;
    const bool cabBActive = preset->_stages[3].enabled ||
                            (preset->_controls.count(47) && preset->_controls[47] >= 0.5f) ||
                            std::fabs(oldCabBDb) > 1e-4f;
    if (cabBActive && std::fabs(cabADb) > 1e-4f) {
      if (cabADb <= -23.95f || oldCabBDb <= -23.95f) {
        preset->_controls[48] = -24.0f;
      } else {
        preset->_controls[48] = std::max(-24.0f, std::min(24.0f, oldCabBDb + cabADb));
      }
    }
  }

  if ([root[@"ai_metadata"] isKindOfClass:[NSDictionary class]]) {
    preset.aiMetadata = [root[@"ai_metadata"] mutableCopy];
  }

  return preset;
}

- (BOOL)saveToFile:(NSString*)filePath error:(NSError**)error {
  NSMutableDictionary* root = [NSMutableDictionary dictionary];
  root[@"name"] = self.name ?: @"Untitled";
  root[@"version"] = @2;

  NSDateFormatter* df = [[NSDateFormatter alloc] init];
  df.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
  root[@"created"] = [df stringFromDate:[NSDate date]];
  root[@"speaker_profile"] = @(self.speakerProfile);

  if (self.aiMetadata.count > 0) {
    root[@"ai_metadata"] = [self.aiMetadata copy];
  }

  NSMutableArray* stagesList = [NSMutableArray arrayWithCapacity:6];
  for (size_t s = 0; s < 6; ++s) {
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
  if (self.slotPresets.count > 0) {
    root[@"slot_presets"] = [self.slotPresets copy];
  }

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

  const char* roles[] = {"pedal", "amp", "cab", "cab2", "pedal2", "pedal3"};
  for (size_t s = 0; s < 6; ++s) {
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
  p->_stages[1].transformer = static_cast<float>(state->transformerProfile);
  for (size_t i = 0; i < NAMRig::kTransformerControlCount; ++i)
    p->_controls[NAMRig::kTransformerControlFirstPort + i] = state->transformerAdjustments[i];
  for (size_t i = 0; i < NAMRig::kRackCount; ++i)
    p->_controls[NAMRig::kRackControlFirstPort + i] = state->rackControls[i];
  p->_controls[NAMRig::kPowerTubeTypePort] = static_cast<float>(state->powerTubeProfile);
  p->_controls[NAMRig::kPowerTubeCharacterPort] = state->powerTubeCharacter;
  p->_controls[NAMRig::kOverdriveVoicingPort] = static_cast<float>(state->boostVoicing);
  for (uint32_t i = 0; i < NAMRig::kPinEqPortCount; ++i)
    p->_controls[NAMRig::kPinEqFirstPort + i] = state->pinEqControls[i];

  // IR Normalization
  if (state->irNormPopup) {
    p->_stages[2].irNormalization = state->irNormPopup.indexOfSelectedItem == 0 ? 1.0f : 2.0f;
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
    if (port == NAMRig::kPowerTubeCharacterPort) continue;
    if (port == 4) {
      p->_controls[4] = state->knobs[k] ? state->knobs[k].floatValue : 0.0f;
      continue;
    }
    const float val = state->knobs[k] ? state->knobs[k].floatValue : kRigKnobDefaults[k];
    p->_controls[port] = val;
  }

  // Toggles and modes into controls map:
  p->_controls[NAMRig::kPedal2EnabledPort] = state->extraPedalEnabled[0];
  p->_controls[NAMRig::kPedal3EnabledPort] = state->extraPedalEnabled[1];
  p->_controls[NAMRig::kPedalOrderPort] = state->pedalOrder;
  p->_controls[7] = p->_stages[0].enabled ? 1.0f : 0.0f;
  p->_controls[8] = p->_stages[1].enabled ? 1.0f : 0.0f;
  p->_controls[9] = p->_stages[2].enabled ? 1.0f : 0.0f;
  p->_controls[47] = p->_stages[3].enabled ? 1.0f : 0.0f;
  p->_controls[59] = state->cab2PolarityInverted ? 1.0f : 0.0f;
  p->_controls[NAMRig::kCompressorEnabledPort] = state->compressorEnabled;
  p->_controls[NAMRig::kOverdriveEnabledPort] = state->boostEnabled;
  p->_controls[NAMRig::kPostCompressorEnabledPort] = state->postCompressorEnabled;
  p->_controls[20] = p->_stages[0].oversample;
  p->_controls[21] = p->_stages[1].oversample;
  p->_controls[24] = p->_stages[2].irNormalization;
  p->_controls[30] = p->_stages[1].transformer;
  p->_controls[42] = p.speakerProfile;

  if (state && state->deckSlotSpecs) {
    for (NSDictionary* spec in state->deckSlotSpecs) {
      if (![spec isKindOfClass:[NSDictionary class]]) continue;
      NSString* key = spec[@"key"];
      NSString* title = spec[@"selectedTitle"];
      if (key.length && title.length) {
        p.slotPresets[key] = title;
      }
    }
  }

  return p;
}

- (void)applyToState:(RigUIState*)state {
  if (!state) return;
  state->cancelTransformerEditing();

  // 1. Models: discover sibling models and send stage path changes before
  // touching oversample/cab-enable controls so the audio thread never reloads
  // the previous preset's models while disk/menu work is still running.
  for (size_t s = 0; s < 6; ++s) {
    const std::string& path = _stages[s].path;
    std::vector<std::string> stageModels = _stages[s].models;
    if (!path.empty()) {
      std::vector<std::string> discovered = discoverModelsForStagePath(path, s);
      if (!discovered.empty()) {
        stageModels = std::move(discovered);
      }
    }
    if (!path.empty()) {
      if (std::find(stageModels.begin(), stageModels.end(), path) == stageModels.end()) {
        stageModels.push_back(path);
      }
      state->selectedPaths[s] = path;
      NSMutableArray<NSString*>* modelPaths = [NSMutableArray arrayWithCapacity:stageModels.size()];
      for (const auto& m : stageModels) {
        if (!m.empty()) [modelPaths addObject:[NSString stringWithUTF8String:m.c_str()]];
      }
      state->setStageModels(s, modelPaths);
    } else {
      state->setStageModels(s, @[]);
    }
  }
  for (size_t s = 0; s < 6; ++s) {
    const std::string& path = _stages[s].path;
    state->sendPath(s, path.empty() ? "" : path.c_str());
  }

  for (uint32_t port : {NAMRig::kPedal2EnabledPort, NAMRig::kPedal3EnabledPort, NAMRig::kPedalOrderPort}) {
    const float value = port == NAMRig::kPedalOrderPort ? [self controlForPort:port] : (_stages[port == NAMRig::kPedal2EnabledPort ? 4 : 5].enabled ? 1.0f : 0.0f);
    state->sendControl(port, value);
    state->updateControl(port, value);
  }
  // 2. Stage powers (ports 7, 8, 9, 47)
  state->sendControl(7, _stages[0].enabled ? 1.0f : 0.0f);
  state->updateControl(7, _stages[0].enabled ? 1.0f : 0.0f);
  state->sendControl(8, _stages[1].enabled ? 1.0f : 0.0f);
  state->updateControl(8, _stages[1].enabled ? 1.0f : 0.0f);
  state->sendControl(9, _stages[2].enabled ? 1.0f : 0.0f);
  state->updateControl(9, _stages[2].enabled ? 1.0f : 0.0f);
  state->sendControl(47, _stages[3].enabled ? 1.0f : 0.0f);
  state->updateControl(47, _stages[3].enabled ? 1.0f : 0.0f);
  // Always recall every rack toggle so legacy presets cannot leave stale bypasses.
  for (size_t i = 0; i < NAMRig::kRackCount; ++i) {
    const uint32_t port = NAMRig::kRackControlFirstPort + i;
    auto it = _controls.find(port);
    const float value = it != _controls.end() ? it->second : NAMRig::kRackControlDefaults[i];
    state->sendControl(port, value);
    state->updateControl(port, value);
  }

  // 3. Modes and Profiles
  const auto postEnabledIt = _controls.find(NAMRig::kPostCompressorEnabledPort);
  const float postEnabled = postEnabledIt != _controls.end() ? postEnabledIt->second : 1.0f;
  state->sendControl(NAMRig::kPostCompressorEnabledPort, postEnabled);
  state->updateControl(NAMRig::kPostCompressorEnabledPort, postEnabled);
  for (const uint32_t port : {NAMRig::kCompressorEnabledPort, NAMRig::kOverdriveEnabledPort}) {
    auto it = _controls.find(port);
    const float enabled = it != _controls.end() ? it->second : 1.0f;
    state->sendControl(port, enabled);
    state->updateControl(port, enabled);
  }
  state->sendControl(20, _stages[0].oversample);
  state->updateControl(20, _stages[0].oversample);
  state->sendControl(21, _stages[1].oversample);
  state->updateControl(21, _stages[1].oversample);
  state->sendControl(24, _stages[2].irNormalization);
  state->updateControl(24, _stages[2].irNormalization);
  state->sendControl(30, _stages[1].transformer);
  state->updateControl(30, _stages[1].transformer);
  for (size_t i = 0; i < NAMRig::kTransformerControlCount; ++i) {
    const uint32_t port = NAMRig::kTransformerControlFirstPort + i;
    auto it = _controls.find(port);
    const float value = it != _controls.end() ? it->second : NAMRig::kTransformerControlDefaults[i];
    state->sendControl(port, value);
    state->updateControl(port, value);
  }
  state->sendControl(42, self.speakerProfile);
  state->updateControl(42, self.speakerProfile);
  // Sparse presets must clear previously selected tube character.
  auto tubeTypeIt = _controls.find(NAMRig::kPowerTubeTypePort);
  const float tubeType = tubeTypeIt != _controls.end() ? tubeTypeIt->second : 0.0f;
  state->sendControl(NAMRig::kPowerTubeTypePort, tubeType);
  state->updateControl(NAMRig::kPowerTubeTypePort, tubeType);
  auto tubeCharacterIt = _controls.find(NAMRig::kPowerTubeCharacterPort);
  const float tubeCharacter = tubeCharacterIt != _controls.end()
      ? tubeCharacterIt->second : NAMRig::kPowerTubeCharacterDefault;
  state->sendControl(NAMRig::kPowerTubeCharacterPort, tubeCharacter);
  state->updateControl(NAMRig::kPowerTubeCharacterPort, tubeCharacter);
  auto odVoicingIt = _controls.find(NAMRig::kOverdriveVoicingPort);
  const float odVoicing = odVoicingIt != _controls.end() ? odVoicingIt->second : 0.0f;
  state->sendControl(NAMRig::kOverdriveVoicingPort, odVoicing);
  state->updateControl(NAMRig::kOverdriveVoicingPort, odVoicing);
  for (uint32_t i = 0; i < NAMRig::kPinEqPortCount; ++i) {
    const uint32_t port = NAMRig::kPinEqFirstPort + i;
    auto it = _controls.find(port);
    const float value = it != _controls.end() ? it->second : NAMRig::pinEqDefault(port);
    state->sendControl(port, value);
    state->updateControl(port, value);
  }
  const float polarity = [self controlForPort:59] >= 0.5f ? 1.0f : 0.0f;
  state->sendControl(59, polarity);
  state->updateControl(59, polarity);

  // 4. Knobs
  for (size_t k = 0; k < kRigKnobCount; ++k) {
    const uint32_t port = kRigKnobPorts[k];
    if (port == NAMRig::kPowerTubeCharacterPort) continue;
    if (port == 4) {
      auto it = _controls.find(port);
      const float val = it != _controls.end() ? it->second : 0.0f;
      state->sendControl(4, val);
      state->updateControl(4, val);
      continue;
    }
    auto it = _controls.find(port);
    const float val = (it != _controls.end()) ? it->second : kRigKnobDefaults[k];
    state->sendControl(port, val);
    state->updateControl(port, val);
  }

  // 5. Stage thumbnails
  for (size_t s = 0; s < 6; ++s) {
    const std::string& path = _stages[s].path;
    const std::string& img = _stages[s].imageURL;
    const long toneId = _stages[s].toneId;
    if (!path.empty()) {
      NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
      state->updateThumbnailForStagePath(s, nsPath);
      // Stored artwork metadata is trusted only when the model folder itself proves the tone
      // identity; otherwise stale metadata captured from an unrelated rig would follow this preset.
      NSString* folder = nsPath.stringByDeletingLastPathComponent;
      const BOOL previewOfSameTone = toneId > 0 && [folder containsString:@"/PreviewCache/"] &&
          folder.lastPathComponent.integerValue == toneId;
      if (state->selectedToneIds[s] <= 0 && state->selectedImageURLs[s].empty() && previewOfSameTone) {
        state->setStageThumb(s, nil, toneId, img.length() ? [NSString stringWithUTF8String:img.c_str()] : nil);
      }
    } else {
      state->setStageThumb(s, nil, 0, nil);
    }
  }

  // 5. Studio Pro Deck slot presets recall
  if (state && state->deckSlotSpecs) {
    state->ensureSlotPresetStorage();
    for (NSInteger slotIdx = 0; slotIdx < (NSInteger)state->deckSlotSpecs.count; ++slotIdx) {
      NSMutableDictionary* spec = state->deckSlotSpecs[(NSUInteger)slotIdx];
      NSString* slotKey = spec[@"key"] ?: @"";
      NSString* savedTitle = self.slotPresets[slotKey];
      if (savedTitle.length) {
        NSDictionary* userMap = state->userSlotPresets[slotKey];
        const BOOL isUser = (userMap && userMap[savedTitle] != nil);
        spec[@"selectedTitle"] = savedTitle;
        spec[@"selectedIsUser"] = @(isUser);
        state->rebuildSlotPresetMenu(slotIdx);
      }
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
  NSArray<NSString*>* subpaths = [fm subpathsOfDirectoryAtPath:self.presetsDirectory error:nil];
  for (NSString* rel in subpaths) {
    if ([rel.lastPathComponent hasPrefix:@"."]) continue;
    if ([[rel pathExtension].lowercaseString isEqualToString:@"json"]) {
      [_presetNames addObject:[rel stringByDeletingPathExtension]];
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
    NSString* match = nil;
    for (NSString* p in _presetNames) {
      if ([p.lastPathComponent isEqualToString:_currentPresetName]) {
        match = p;
        break;
      }
    }
    if (match) {
      _currentPresetName = match;
    } else {
      _currentPresetName = _presetNames.firstObject;
      _isModified = NO;
    }
  }
}

- (NSString*)pathForPresetNamed:(NSString*)name {
  if (!name.length) return nil;
  NSString* trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

  // 1. Direct check in presetsDirectory with .json
  NSString* direct = [self.presetsDirectory stringByAppendingPathComponent:
                      [trimmed stringByAppendingPathExtension:@"json"]];
  if ([[NSFileManager defaultManager] fileExistsAtPath:direct]) return direct;

  // 2. Exact match in _presetNames
  for (NSString* p in _presetNames) {
    if ([p isEqualToString:trimmed]) {
      return [self.presetsDirectory stringByAppendingPathComponent:[p stringByAppendingPathExtension:@"json"]];
    }
  }

  // 3. Match by lastPathComponent
  for (NSString* p in _presetNames) {
    if ([p.lastPathComponent localizedCaseInsensitiveCompare:trimmed] == NSOrderedSame) {
      return [self.presetsDirectory stringByAppendingPathComponent:[p stringByAppendingPathExtension:@"json"]];
    }
  }
  return direct;
}

- (nullable RigPreset*)loadPresetNamed:(NSString*)name {
  if (!name.length) return nil;
  NSString* path = [self pathForPresetNamed:name];
  RigPreset* p = [RigPreset loadFromFile:path];
  if (p) {
    NSString* canonical = nil;
    for (NSString* existing in _presetNames) {
      if ([existing isEqualToString:name] || [existing.lastPathComponent localizedCaseInsensitiveCompare:name] == NSOrderedSame) {
        canonical = existing;
        break;
      }
    }
    _currentPresetName = canonical ? [canonical copy] : [name copy];
    _isModified = NO;
    [self persistCurrentPresetName];
  }
  return p;
}

- (BOOL)savePreset:(RigPreset*)preset error:(NSError**)error {
  if (!preset || !preset.name.length) return NO;
  NSString* cleanName = [preset.name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSString* relDir = cleanName.stringByDeletingLastPathComponent;
  NSString* fileBase = cleanName.lastPathComponent;
  fileBase = [fileBase stringByReplacingOccurrencesOfString:@":" withString:@"-"];

  NSString* targetDir = self.presetsDirectory;
  if (relDir.length && ![relDir isEqualToString:@"."]) {
    targetDir = [targetDir stringByAppendingPathComponent:relDir];
  }
  [[NSFileManager defaultManager] createDirectoryAtPath:targetDir withIntermediateDirectories:YES attributes:nil error:nil];
  NSString* path = [targetDir stringByAppendingPathComponent:[fileBase stringByAppendingPathExtension:@"json"]];
  BOOL ok = [preset saveToFile:path error:error];
  if (ok) {
    _currentPresetName = [cleanName copy];
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

- (BOOL)renamePresetNamed:(NSString*)oldName to:(NSString*)newName error:(NSError**)error {
  return [self renamePresetNamed:oldName to:newName fromState:nil error:error];
}

- (BOOL)renamePresetNamed:(NSString*)oldName
                       to:(NSString*)newName
                fromState:(nullable RigUIState*)state
                    error:(NSError**)error {
  NSString* trimmedOld = [oldName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (!trimmedOld.length || [trimmedOld isEqualToString:@"Default Rig"] || [trimmedOld.lastPathComponent isEqualToString:@"Default Rig"]) {
    if (error) *error = [NSError errorWithDomain:@"RigPresetManager"
                                            code:-1
                                        userInfo:@{NSLocalizedDescriptionKey: @"The Default Rig preset cannot be renamed."}];
    return NO;
  }
  NSString* trimmedNew = [newName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (!trimmedNew.length) {
    if (error) *error = [NSError errorWithDomain:@"RigPresetManager"
                                            code:-2
                                        userInfo:@{NSLocalizedDescriptionKey: @"Please enter a valid preset name."}];
    return NO;
  }
  if ([trimmedNew isEqualToString:@"Default Rig"] || [trimmedNew.lastPathComponent isEqualToString:@"Default Rig"]) {
    if (error) *error = [NSError errorWithDomain:@"RigPresetManager"
                                            code:-3
                                        userInfo:@{NSLocalizedDescriptionKey: @"A preset cannot be named 'Default Rig'."}];
    return NO;
  }

  NSString* targetRelNew = trimmedNew;
  if (![targetRelNew containsString:@"/"] && [trimmedOld containsString:@"/"]) {
    NSString* oldDir = [trimmedOld stringByDeletingLastPathComponent];
    targetRelNew = [oldDir stringByAppendingPathComponent:trimmedNew];
  }

  if ([trimmedOld isEqualToString:targetRelNew]) {
    return YES;
  }

  if ([_presetNames containsObject:targetRelNew] &&
      [trimmedOld localizedCaseInsensitiveCompare:targetRelNew] != NSOrderedSame) {
    if (error) *error = [NSError errorWithDomain:@"RigPresetManager"
                                            code:-4
                                        userInfo:@{NSLocalizedDescriptionKey:
                                                   [NSString stringWithFormat:@"A preset named '%@' already exists.", targetRelNew]}];
    return NO;
  }

  NSString* oldPath = [self pathForPresetNamed:trimmedOld];

  NSString* newRelDir = targetRelNew.stringByDeletingLastPathComponent;
  NSString* newFileBase = targetRelNew.lastPathComponent;
  newFileBase = [newFileBase stringByReplacingOccurrencesOfString:@":" withString:@"-"];
  NSString* newTargetDir = self.presetsDirectory;
  if (newRelDir.length && ![newRelDir isEqualToString:@"."]) {
    newTargetDir = [newTargetDir stringByAppendingPathComponent:newRelDir];
  }
  [[NSFileManager defaultManager] createDirectoryAtPath:newTargetDir withIntermediateDirectories:YES attributes:nil error:nil];
  NSString* newPath = [newTargetDir stringByAppendingPathComponent:[newFileBase stringByAppendingPathExtension:@"json"]];

  NSFileManager* fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:oldPath]) {
    if (error) *error = [NSError errorWithDomain:@"RigPresetManager"
                                            code:-5
                                        userInfo:@{NSLocalizedDescriptionKey:
                                                   [NSString stringWithFormat:@"Preset file for '%@' not found.", trimmedOld]}];
    return NO;
  }

  RigPreset* preset = nil;
  if (state && ([trimmedOld isEqualToString:_currentPresetName] || [trimmedOld.lastPathComponent isEqualToString:_currentPresetName.lastPathComponent]) && _isModified) {
    preset = [RigPreset captureFromState:state name:targetRelNew];
  } else {
    preset = [RigPreset loadFromFile:oldPath];
    if (!preset) {
      if (error) *error = [NSError errorWithDomain:@"RigPresetManager"
                                              code:-6
                                          userInfo:@{NSLocalizedDescriptionKey: @"Could not load the existing preset."}];
      return NO;
    }
    preset.name = targetRelNew;
  }

  const BOOL caseOnly = [oldPath caseInsensitiveCompare:newPath] == NSOrderedSame &&
                        ![oldPath isEqualToString:newPath];
  NSString* tempPath = nil;
  if (caseOnly) {
    tempPath = [oldPath stringByAppendingString:@".tmp_rename"];
    if (![fm moveItemAtPath:oldPath toPath:tempPath error:error]) {
      return NO;
    }
  }

  BOOL ok = [preset saveToFile:newPath error:error];
  if (!ok) {
    if (caseOnly && tempPath) {
      [fm moveItemAtPath:tempPath toPath:oldPath error:nil];
    }
    return NO;
  }

  if (caseOnly && tempPath) {
    [fm removeItemAtPath:tempPath error:nil];
  } else if (![oldPath isEqualToString:newPath]) {
    [fm removeItemAtPath:oldPath error:nil];
  }

  if ([_currentPresetName isEqualToString:trimmedOld] || [_currentPresetName.lastPathComponent isEqualToString:trimmedOld.lastPathComponent]) {
    _currentPresetName = [targetRelNew copy];
    _isModified = NO;
    [self persistCurrentPresetName];
  }
  [self rescanPresets];
  return YES;
}

- (BOOL)deletePresetNamed:(NSString*)name error:(NSError**)error {
  if (!name.length || [name isEqualToString:@"Default Rig"] || [name.lastPathComponent isEqualToString:@"Default Rig"]) return NO;
  NSString* path = [self pathForPresetNamed:name];
  BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:path error:error];
  if (ok) {
    [self rescanPresets];
    _currentPresetName = _presetNames.firstObject;
    _isModified = NO;
    [self persistCurrentPresetName];
  }
  return ok;
}

- (NSString*)uniquePresetNameForBase:(NSString*)base {
  NSString* raw = base.length ? base : @"Untitled";
  NSString* trimmed = [raw stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (!trimmed.length) trimmed = @"Untitled";

  NSString* dir = [trimmed containsString:@"/"] ? [trimmed stringByDeletingLastPathComponent] : nil;
  NSString* stem = [trimmed containsString:@"/"] ? trimmed.lastPathComponent : trimmed;

  NSSet<NSString*>* existing = [NSSet setWithArray:_presetNames];
  if (![existing containsObject:trimmed]) return trimmed;
  // "Foo" -> "Foo Copy", then "Foo Copy 2", "Foo Copy 3", ...
  // A base that already ends in " Copy" / " Copy N" reuses its stem so
  // duplicating a duplicate yields "Foo Copy 2", not "Foo Copy Copy".
  static NSRegularExpression* copySuffix = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    copySuffix = [NSRegularExpression regularExpressionWithPattern:@"^(.*) Copy(?: (\\d+))?$"
                                                           options:0
                                                             error:nil];
  });
  NSString* baseStem = stem;
  NSTextCheckingResult* m = [copySuffix firstMatchInString:stem
                                                  options:0
                                                    range:NSMakeRange(0, stem.length)];
  if (m && m.numberOfRanges >= 2 && [m rangeAtIndex:1].location != NSNotFound) {
    baseStem = [stem substringWithRange:[m rangeAtIndex:1]];
  }
  NSString* candidateLeaf = [baseStem stringByAppendingString:@" Copy"];
  NSString* candidate = dir ? [dir stringByAppendingPathComponent:candidateLeaf] : candidateLeaf;
  if (![existing containsObject:candidate]) return candidate;
  NSUInteger n = 2;
  while (YES) {
    NSString* numberedLeaf = [candidateLeaf stringByAppendingFormat:@" %lu", (unsigned long)n];
    NSString* numbered = dir ? [dir stringByAppendingPathComponent:numberedLeaf] : numberedLeaf;
    if (![existing containsObject:numbered]) return numbered;
    ++n;
  }
}

- (BOOL)duplicateCurrentPresetFromState:(RigUIState*)state error:(NSError**)error {
  NSString* base = _currentPresetName.length ? _currentPresetName : @"Default Rig";
  return [self duplicateCurrentPresetFromState:state
                                      withName:[self uniquePresetNameForBase:base]
                                         error:error];
}

- (BOOL)duplicateCurrentPresetFromState:(RigUIState*)state
                               withName:(NSString*)name
                                  error:(NSError**)error {
  if (!state) {
    if (error) *error = [NSError errorWithDomain:@"RigPresetManager"
                                            code:-1
                                        userInfo:@{NSLocalizedDescriptionKey: @"No rig state to duplicate from."}];
    return NO;
  }
  NSString* raw = name.length ? name : @"";
  NSString* trimmed = [raw stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (!trimmed.length) {
    if (error) *error = [NSError errorWithDomain:@"RigPresetManager"
                                            code:-2
                                        userInfo:@{NSLocalizedDescriptionKey: @"Enter a name for the duplicated preset."}];
    return NO;
  }
  // An explicit name that already exists fails loudly instead of silently
  // picking another name (the auto-name path above guarantees uniqueness).
  if ([_presetNames containsObject:trimmed]) {
    if (error) *error = [NSError errorWithDomain:@"RigPresetManager"
                                            code:-4
                                        userInfo:@{NSLocalizedDescriptionKey:
                                                   [NSString stringWithFormat:
                                                    @"A preset named '%@' already exists.", trimmed]}];
    return NO;
  }
  // The duplicate keeps the source preset's uncommitted on-screen edits: if
  // the user tweaked the rig after loading (isModified), capture the live UI
  // state rather than re-saving the stale file on disk. Load from disk
  // directly (not via loadPresetNamed:) to avoid mutating current selection.
  RigPreset* source = nil;
  if (_isModified) {
    source = [RigPreset captureFromState:state name:trimmed];
  } else {
    NSString* path = [self pathForPresetNamed:_currentPresetName];
    source = [RigPreset loadFromFile:path];
    if (!source) source = [RigPreset captureFromState:state name:trimmed];
    else source.name = trimmed;
  }
  if (!source) {
    if (error) *error = [NSError errorWithDomain:@"RigPresetManager"
                                            code:-3
                                        userInfo:@{NSLocalizedDescriptionKey: @"Could not load the current preset."}];
    return NO;
  }
  source.name = trimmed;
  // savePreset: selects the new copy and clears the dirty flag.
  return [self savePreset:source error:error];
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
  NSString* cur = [self pathForPresetNamed:_currentPresetName];
  if (cur.length && [[NSFileManager defaultManager] fileExistsAtPath:cur]) {
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
    if (saved.length) {
      if ([_presetNames containsObject:saved]) {
        _currentPresetName = saved;
        _isModified = NO;
      } else {
        for (NSString* p in _presetNames) {
          if ([p.lastPathComponent isEqualToString:saved]) {
            _currentPresetName = p;
            _isModified = NO;
            break;
          }
        }
      }
    }
  }
}

- (NSUInteger)autoOrganizeUnsortedPresets:(NSError**)error {
  NSFileManager* fm = [NSFileManager defaultManager];
  NSString* dir = self.presetsDirectory;
  NSArray<NSString*>* entries = [fm contentsOfDirectoryAtPath:dir error:error];
  if (!entries) return 0;

  NSUInteger movedCount = 0;
  for (NSString* file in entries) {
    if ([file hasPrefix:@"."] || ![[file pathExtension].lowercaseString isEqualToString:@"json"]) continue;
    NSString* stem = [file stringByDeletingPathExtension];
    if ([stem isEqualToString:@"Default Rig"]) continue;

    NSString* fullPath = [dir stringByAppendingPathComponent:file];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:fullPath isDirectory:&isDir] || isDir) continue;

    NSData* data = [NSData dataWithContentsOfFile:fullPath];
    if (!data) continue;
    NSDictionary* root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:[NSDictionary class]]) continue;

    NSDictionary* aiMeta = [root[@"ai_metadata"] isKindOfClass:[NSDictionary class]] ? root[@"ai_metadata"] : nil;
    NSString* prompt = aiMeta[@"prompt"];
    NSString* artist = aiMeta[@"artist"];
    NSString* album = aiMeta[@"album"];
    NSString* song = aiMeta[@"song"];
    NSString* genre = aiMeta[@"genre"];
    NSString* folderPath = aiMeta[@"folder_path"];

    NSString* targetRel = [RigAICopilot hierarchicalPresetPathForTitle:stem
                                                                prompt:prompt
                                                                artist:artist
                                                                 album:album
                                                                  song:song
                                                                 genre:genre
                                                            folderPath:folderPath];
    if (!targetRel.length || [targetRel isEqualToString:stem]) continue;

    NSString* targetFullPath = [dir stringByAppendingPathComponent:[targetRel stringByAppendingPathExtension:@"json"]];
    NSString* targetDir = [targetFullPath stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:targetDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSError* moveErr = nil;
    if ([fm moveItemAtPath:fullPath toPath:targetFullPath error:&moveErr]) {
      movedCount++;
      if ([_currentPresetName isEqualToString:stem] || [_currentPresetName.lastPathComponent isEqualToString:stem]) {
        _currentPresetName = [targetRel copy];
        [self persistCurrentPresetName];
      }
    }
  }

  if (movedCount > 0) {
    [self rescanPresets];
  }
  return movedCount;
}

- (NSUInteger)propagateSlotValues:(NSDictionary<NSString*, NSNumber*>*)values
                          slotKey:(NSString*)slotKey
                   slotPresetName:(nullable NSString*)presetName
                            error:(NSError**)error {
  if (!values.count) return 0;
  NSFileManager* fm = [NSFileManager defaultManager];
  NSString* dir = self.presetsDirectory;
  NSArray<NSString*>* files = [fm subpathsOfDirectoryAtPath:dir error:error];
  if (!files) return 0;

  NSDictionary<NSNumber*, NSString*>* portMap = portToSymbolMap();
  NSUInteger updatedCount = 0;

  for (NSString* f in files) {
    if (![[f pathExtension].lowercaseString isEqualToString:@"json"]) continue;
    if ([[f.lastPathComponent stringByDeletingPathExtension] isEqualToString:@"Default Rig"]) continue;
    NSString* fullPath = [dir stringByAppendingPathComponent:f];
    NSData* data = [NSData dataWithContentsOfFile:fullPath];
    if (!data) continue;
    NSError* parseErr = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&parseErr];
    if (![obj isKindOfClass:[NSMutableDictionary class]]) continue;
    NSMutableDictionary* root = (NSMutableDictionary*)obj;

    if (presetName.length && slotKey.length) {
      NSDictionary* sp = root[@"slot_presets"];
      if (![sp isKindOfClass:[NSDictionary class]] || ![sp[slotKey] isEqualToString:presetName])
        continue;
    }

    NSMutableDictionary* portsDict = [root[@"ports"] isKindOfClass:[NSDictionary class]]
        ? [root[@"ports"] mutableCopy] : [NSMutableDictionary dictionary];
    NSMutableDictionary* paramsDict = [root[@"params"] isKindOfClass:[NSDictionary class]]
        ? [root[@"params"] mutableCopy] : [NSMutableDictionary dictionary];

    for (NSString* portStr in values) {
      NSNumber* val = values[portStr];
      portsDict[portStr] = val;
      uint32_t portNum = (uint32_t)portStr.longLongValue;
      NSString* sym = portMap[@(portNum)];
      if (sym.length) {
        paramsDict[sym] = val;
      }
    }
    root[@"ports"] = portsDict;
    root[@"params"] = paramsDict;

    if (slotKey.length && presetName.length) {
      NSMutableDictionary* sp = [root[@"slot_presets"] isKindOfClass:[NSDictionary class]]
          ? [root[@"slot_presets"] mutableCopy] : [NSMutableDictionary dictionary];
      sp[slotKey] = presetName;
      root[@"slot_presets"] = sp;
    }

    NSData* outData = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:nil];
    if (outData && [outData writeToFile:fullPath atomically:YES]) {
      updatedCount++;
    }
  }

  return updatedCount;
}

- (void)renameSlotPresetInAllPresetsFrom:(NSString*)oldName
                                      to:(NSString*)newName
                                 slotKey:(NSString*)slotKey {
  if (!oldName.length || !newName.length || !slotKey.length) return;
  NSFileManager* fm = [NSFileManager defaultManager];
  NSString* dir = self.presetsDirectory;
  NSArray<NSString*>* files = [fm subpathsOfDirectoryAtPath:dir error:nil];
  for (NSString* f in files) {
    if (![[f pathExtension].lowercaseString isEqualToString:@"json"]) continue;
    if ([[f.lastPathComponent stringByDeletingPathExtension] isEqualToString:@"Default Rig"]) continue;
    NSString* fullPath = [dir stringByAppendingPathComponent:f];
    NSData* data = [NSData dataWithContentsOfFile:fullPath];
    if (!data) continue;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (![obj isKindOfClass:[NSMutableDictionary class]]) continue;
    NSMutableDictionary* root = (NSMutableDictionary*)obj;
    NSMutableDictionary* sp = [root[@"slot_presets"] isKindOfClass:[NSDictionary class]]
        ? [root[@"slot_presets"] mutableCopy] : nil;
    if (sp && [sp[slotKey] isEqualToString:oldName]) {
      sp[slotKey] = newName;
      root[@"slot_presets"] = sp;
      NSData* outData = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:nil];
      if (outData) [outData writeToFile:fullPath atomically:YES];
    }
  }
}

- (void)deleteSlotPresetInAllPresetsNamed:(NSString*)deletedName
                                  slotKey:(NSString*)slotKey {
  if (!deletedName.length || !slotKey.length) return;
  NSFileManager* fm = [NSFileManager defaultManager];
  NSString* dir = self.presetsDirectory;
  NSArray<NSString*>* files = [fm subpathsOfDirectoryAtPath:dir error:nil];
  for (NSString* f in files) {
    if (![[f pathExtension].lowercaseString isEqualToString:@"json"]) continue;
    if ([[f.lastPathComponent stringByDeletingPathExtension] isEqualToString:@"Default Rig"]) continue;
    NSString* fullPath = [dir stringByAppendingPathComponent:f];
    NSData* data = [NSData dataWithContentsOfFile:fullPath];
    if (!data) continue;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (![obj isKindOfClass:[NSMutableDictionary class]]) continue;
    NSMutableDictionary* root = (NSMutableDictionary*)obj;
    NSMutableDictionary* sp = [root[@"slot_presets"] isKindOfClass:[NSDictionary class]]
        ? [root[@"slot_presets"] mutableCopy] : nil;
    if (sp && [sp[slotKey] isEqualToString:deletedName]) {
      [sp removeObjectForKey:slotKey];
      root[@"slot_presets"] = sp;
      NSData* outData = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:nil];
      if (outData) [outData writeToFile:fullPath atomically:YES];
    }
  }
}

@end
