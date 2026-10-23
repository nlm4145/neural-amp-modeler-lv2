#pragma once
#import "rig_riff_recorder.h"
#import "rig_presets.h"
#include <atomic>
#include <memory>

NS_ASSUME_NONNULL_BEGIN
// Dry, conservative gear seeds: base rig plus at most 3 amps x 2 cabs from
// the metadata shortlist. Does not load models or touch the live rig.
NSArray<RigPreset*>* rigLocalToneSeeds(RigPreset* base, NSArray<NSDictionary*>* catalog, NSString* libraryRoot);
@interface RigLocalToneMatch : NSObject
@property(nonatomic, strong) RigPreset* preset;
@property(nonatomic) double score; // Relative feature distance in dB; not a perceptual confidence percentage.
@end

@interface RigLocalToneMatcher : NSObject {
  std::shared_ptr<std::atomic<bool>> _cancelled;
}
+ (instancetype)sharedMatcher;
+ (NSString*)trainingDirectory;
@property(nonatomic, readonly) BOOL isRunning;
// All inputs are frozen on the main thread; work runs locally off audio/UI threads.
// Returns up to three REAL-rendered finalists, never surrogate-only predictions.
- (void)matchDI:(NSData*)di rate:(double)rate target:(NSData*)target
    targetRate:(double)targetRate targetChannels:(NSUInteger)channels
         seeds:(NSArray<RigPreset*>*)seeds renderer:(RigRiffRenderHandler)renderer
cacheDirectory:(NSString*)cacheDirectory progress:(void (^ _Nullable)(NSString*))progress
    completion:(void (^)(NSArray<RigLocalToneMatch*>* _Nullable, NSDictionary* _Nullable, NSError* _Nullable))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
