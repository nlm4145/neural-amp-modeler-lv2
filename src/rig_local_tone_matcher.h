#pragma once
#import "rig_riff_recorder.h"
#import "rig_presets.h"
#include <atomic>
#include <memory>

NS_ASSUME_NONNULL_BEGIN
// Dry candidate plan. `base` has effects, compressors, power/transformer/speaker
// coloration, Cab B, the tone stack, cab cuts and Console pins neutralized; input
// calibration, oversampling and any pedal/OD are kept. `amps` (current amp first,
// at most 24; more than 4 get a quick screen) are rendered with the cab off; every WAV in `cabs` is screened offline
// by FFT convolution. Does not load models or touch the live rig.
@interface RigLocalTonePlan : NSObject
@property(nonatomic, strong) RigPreset* base;
@property(nonatomic, copy) NSArray<NSString*>* amps;
@property(nonatomic, copy) NSArray<NSString*>* cabs;
@property(nonatomic, copy, nullable) NSString* currentCab; // The live rig's cab IR (starting-point score), if any.
@property(nonatomic, copy, nullable) NSArray<NSString*>* pedals; // Pedal captures tried once on the leading amp (at most 2).
@property(nonatomic) BOOL preferOverdrive; // Gear research documents an OD/boost: always search OD drive.
@property(nonatomic, copy, nullable) NSString* referenceSource; // @"demucs", @"stem", or @"mix"
@property(nonatomic) BOOL accurateRescore; // Re-extract finalists through Demucs with backing stems to match separation artifacts.
@property(nonatomic, copy, nullable) NSData* referenceBackingFrames; // Non-guitar Demucs stem audio for symmetric re-scoring.
@property(nonatomic) BOOL embeddingRerank; // Score finalists with CLAP / local embedding cosine distance.
@property(nonatomic) BOOL playAlong; // Recorded in play-along mode; enables DTW onset alignment.
@end
// Cabs: the current cab, catalog cabs, then every WAV under <libraryRoot>/Cab (max 400).
RigLocalTonePlan* rigLocalTonePlan(RigPreset* base, NSArray<NSDictionary*>* catalog, NSString* libraryRoot);
@interface RigLocalToneMatch : NSObject
@property(nonatomic, strong) RigPreset* preset;
@property(nonatomic) double score; // Relative feature distance in dB from a real engine render; not a perceptual confidence percentage.
@property(nonatomic) double offlineScore; // The same distance predicted offline (amp render ⊛ IR + post EQ).
// When Console-pin "mix EQ" was kept (it lowered the real score), the same gear
// without it; nil otherwise.
@property(nonatomic, strong, nullable) RigPreset* presetWithoutMixEQ;
@property(nonatomic) double scoreWithoutMixEQ;
@property(nonatomic) double alignedDistance;
@property(nonatomic) double alignmentConfidence;
@property(nonatomic) BOOL alignmentConfident;
@property(nonatomic) double embeddingDistance;
@end

@interface RigLocalToneMatcher : NSObject {
  std::shared_ptr<std::atomic<bool>> _cancelled;
}
+ (instancetype)sharedMatcher;
+ (NSString*)trainingDirectory;
+ (NSString*)renderCacheDirectory;
@property(nonatomic, readonly) BOOL isRunning;
// All inputs are frozen on the main thread; work runs locally off audio/UI threads.
// Returns up to three REAL-rendered finalists, never offline-only predictions.
- (void)matchDI:(NSData*)di rate:(double)rate target:(NSData*)target
    targetRate:(double)targetRate targetChannels:(NSUInteger)channels
          plan:(RigLocalTonePlan*)plan renderer:(RigRiffRenderHandler)renderer
cacheDirectory:(NSString*)cacheDirectory progress:(void (^ _Nullable)(NSString*))progress
    completion:(void (^)(NSArray<RigLocalToneMatch*>* _Nullable, NSDictionary* _Nullable, NSError* _Nullable))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
