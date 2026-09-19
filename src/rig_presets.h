// RigPreset & RigPresetManager — preset serialization and management for Axe FX.
#pragma once

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>

#include <array>
#include <string>
#include <unordered_map>
#include <vector>

struct RigUIState;

struct RigStagePreset {
  std::string role;      // "pedal", "amp", "cab", "cab2"
  bool enabled = true;
  std::string path;
  std::string imageURL;
  long toneId = 0;
  float oversample = 6.0f;     // port 20 or 21
  float transformer = 0.0f;    // port 30 (amp only)
  float irNormalization = 2.0f;// port 24 (cab only)
  std::vector<std::string> models; // available model selections for this stage
};

std::vector<std::string> discoverModelsForStagePath(const std::string& modelPath, size_t stage);

NS_ASSUME_NONNULL_BEGIN

@interface RigPreset : NSObject
@property(nonatomic, copy) NSString* name;
@property(nonatomic, copy, nullable) NSString* filePath;
@property(nonatomic) float speakerProfile;   // port 42

- (RigStagePreset*)stageAtIndex:(size_t)index;
- (void)setControl:(uint32_t)port value:(float)value;
- (float)controlForPort:(uint32_t)port;
- (const std::unordered_map<uint32_t, float>&)allControls;

+ (nullable RigPreset*)loadFromFile:(NSString*)filePath;
- (BOOL)saveToFile:(NSString*)filePath error:(NSError**)error;

+ (RigPreset*)captureFromState:(RigUIState*)state name:(NSString*)name;
- (void)applyToState:(RigUIState*)state;

// Factory default preset (factory neutral settings, uncompromised True 8x).
+ (RigPreset*)defaultPreset;
@end

@interface RigPresetManager : NSObject
@property(nonatomic, readonly, copy) NSString* presetsDirectory;
@property(nonatomic, readonly, strong) NSMutableArray<NSString*>* presetNames;
@property(nonatomic, copy) NSString* currentPresetName;
@property(nonatomic) BOOL isModified;

+ (instancetype)sharedManager;
- (void)rescanPresets;
- (nullable RigPreset*)loadPresetNamed:(NSString*)name;
- (BOOL)savePreset:(RigPreset*)preset error:(NSError**)error;
- (BOOL)saveCurrentPresetFromState:(RigUIState*)state error:(NSError**)error;
- (BOOL)savePresetNamed:(NSString*)name fromState:(RigUIState*)state error:(NSError**)error;
- (BOOL)deletePresetNamed:(NSString*)name error:(NSError**)error;
- (NSString*)uniquePresetNameForBase:(NSString*)base;
- (BOOL)duplicateCurrentPresetFromState:(RigUIState*)state error:(NSError**)error;
- (BOOL)duplicateCurrentPresetFromState:(RigUIState*)state
                               withName:(NSString*)name
                                  error:(NSError**)error;

- (nullable NSString*)nextPresetName;
- (nullable NSString*)previousPresetName;
- (void)revealPresetsInFinder;
- (void)ensureDefaultPresetExists;

- (NSString*)displayTitle;
- (void)persistCurrentPresetName;
- (void)restoreCurrentPresetName;
@end

NS_ASSUME_NONNULL_END
#endif
