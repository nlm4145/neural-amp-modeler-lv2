// RigRiffRecorder — Real-time audio riff capture and spectral analysis for Axe FX.
// Thread-safe lock-free audio capture from the standalone audio callback,
// with WAV export, native playback, and acoustic telemetry for AI Tone Tuning.
#pragma once

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <atomic>
#include <cstdint>
#include <vector>

#ifdef __cplusplus
extern "C" {
#endif

// Realtime audio callback entry point. Called directly on the CoreAudio thread.
// Must be 100% lock-free, zero allocation, non-blocking.
void rigRiffRecorderPushSamples(const float* _Nullable left,
                                const float* _Nullable right,
                                uint32_t frames,
                                double sampleRate);
// Capture the exact input delivered to the engine, plus its stereo output.
void rigRiffRecorderPushPair(const float* _Nullable di,
                            const float* _Nullable left,
                            const float* _Nullable right,
                            uint32_t frames, double sampleRate, uint32_t latencyFrames);

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__

NS_ASSUME_NONNULL_BEGIN
@class RigPreset;

// Installed by the standalone host. Returns interleaved float stereo, latency
// compensated, including a short effect tail. Runs off the audio/UI threads.
typedef NSData* _Nullable (^RigRiffRenderHandler)(RigPreset* preset, NSData* di,
                                                double rate, NSError** error);

NSData* _Nullable rigDecodeReference(NSURL* url, double& rate, NSUInteger& channels, BOOL& truncated, NSError** error);
NSData* _Nullable rigWavDataFromFloatSamples(const float* samples, size_t frames, uint16_t channels, double rate);

@interface RigRiffRecorder : NSObject

+ (instancetype)sharedRecorder;

// Realtime status
@property (nonatomic, readonly) BOOL isRecording;
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) NSTimeInterval recordedDuration;
@property (nonatomic, readonly) double recordedSampleRate;
@property (nonatomic, readonly, nullable) NSData* recordedWavData;
@property (nonatomic, readonly, nullable) NSData* recordedDIWavData;
@property (nonatomic, readonly, nullable) NSData* recordedDIFrames; // Unnormalized float mono
@property (nonatomic, strong, nullable) RigPreset* recordingPreset;
@property (nonatomic, copy) NSDictionary* recordingMetadata;
@property (nonatomic, readonly) NSUInteger latencyFrames;
@property (nonatomic, readonly, copy) NSString* guidance;
// Guided-take segments: @{@"start", @"end" (seconds), @"label", @"instruction"} in playing order.
+ (NSArray<NSDictionary*>*)guidedPlan;
// Zero-based index of the guided segment that contains the current recording time, or -1.
@property (nonatomic, readonly) NSInteger guidedSegmentIndex;
@property (nonatomic, readonly) BOOL isGuided;
@property (nonatomic, readonly, nullable) NSData* referenceWavData;
@property (nonatomic, readonly, nullable) NSData* referenceBackingWavData;
// Selected 5–20 s section of the reference as original interleaved float samples
// (not clamped WAV). referenceWavData and referenceAnalysis follow the selection.
@property (nonatomic, readonly, nullable) NSData* referenceFrames;
// Optional sum of non-guitar stems (for Demucs references), sliced to the same selection.
@property (nonatomic, readonly, nullable) NSData* referenceBackingFrames;
@property (nonatomic, readonly) double referenceSampleRate;
@property (nonatomic, readonly) NSUInteger referenceChannels;
@property (nonatomic, readonly) BOOL referenceIsFullMix;
// @"demucs" (extracted stem), @"stem" (user-supplied guitar track) or @"mix".
@property (nonatomic, readonly, copy) NSString* referenceSource;
@property (nonatomic, readonly) NSTimeInterval referenceTotalDuration; // Whole decoded file (bounded).
@property (nonatomic, readonly) BOOL referenceTruncated; // File was longer than the in-memory bound.
@property (nonatomic, readonly) NSTimeInterval referenceSelectionStart;
@property (nonatomic, readonly) NSTimeInterval referenceSelectionLength;
@property (nonatomic, readonly) BOOL referenceSelectionAuto;
@property (nonatomic, readonly, copy) NSString* referenceAnalysis;
@property (nonatomic, copy, nullable) RigRiffRenderHandler renderHandler;
@property (nonatomic, readonly) BOOL isRendering;
@property (nonatomic, readonly, nullable) NSData* baselineWavData;
@property (nonatomic, readonly, nullable) NSData* candidateWavData;
@property (nonatomic, readonly, copy) NSString* candidateAnalysis;
@property (nonatomic, readonly) float currentPeakLevel; // Linear 0.0 .. 1.0 for UI VU meter

// Acoustic & spectral analysis of the recorded audio
@property (nonatomic, readonly) float peakDbfs;
@property (nonatomic, readonly) float rmsDbfs;
@property (nonatomic, readonly) float crestFactorDb; // Dynamic punch (peak - rms)
@property (nonatomic, readonly) float lowBandDbfs;   // < 150 Hz (chug, rumble, bass)
@property (nonatomic, readonly) float lowMidDbfs;   // 150 - 600 Hz (boxiness, warmth)
@property (nonatomic, readonly) float highMidDbfs;  // 600 - 3000 Hz (cut, punch, voice)
@property (nonatomic, readonly) float trebleDbfs;   // 3000 - 8000 Hz (fizz, bite, edge)
@property (nonatomic, readonly) float airDbfs;      // > 8000 Hz (sheen, hiss)
@property (nonatomic, readonly, copy) NSString* audioAnalysisSummary;

// Controls
- (void)startRecording;
// guided: 0-2s muted strings, 2-6s chugs, 6-10s chords,
// 10-15s soft/hard single notes, 15-20s sustained note and decay.
- (void)startRecordingGuided:(BOOL)guided;
// Play along: plays target sound in monitors/headphones while recording guitar DI
- (void)startPlayAlong;
- (void)stopPlayAlong;
@property (nonatomic, readonly) BOOL isPlayingAlong;
- (void)stopRecording;
- (void)clearRecording;
- (void)playRecording;
- (void)playTrack:(NSString*)track; // processed, di, baseline, candidate, reference, backing
- (void)stopPlayback;
@property (nonatomic, readonly, copy, nullable) NSString* currentPlayingTrack;
@property (nonatomic, copy, nullable) void (^onPlaybackFinished)(void);

// Load an external processed-riff WAV (the raw DI cannot be reconstructed).
- (BOOL)loadAudioFromURL:(NSURL*)fileURL error:(NSError* _Nullable * _Nullable)error;
// References decode any CoreAudio format (WAV/AIFF/MP3/M4A/ALAC/FLAC/CAF) and keep
// the whole song (bounded) so a section can be selected; auto-selects the
// densest 20 s.
- (BOOL)loadReferenceFromURL:(NSURL*)fileURL fullMix:(BOOL)fullMix error:(NSError**)error;
- (BOOL)loadReferenceFromURL:(NSURL*)fileURL fullMix:(BOOL)fullMix source:(NSString*)source error:(NSError**)error;
- (BOOL)loadReferenceFromURL:(NSURL*)fileURL fullMix:(BOOL)fullMix source:(NSString*)source backingAudioURL:(nullable NSURL*)backingURL error:(NSError**)error;
// Length is clamped to 5–20 s (or the whole file if shorter). Automatic picks the
// most energetic window of that length and ignores start.
- (void)selectReferenceStart:(NSTimeInterval)start length:(NSTimeInterval)length automatic:(BOOL)automatic;
- (void)clearReference;
- (void)invalidatePreview;
- (void)renderBaseline:(RigPreset*)baseline candidate:(RigPreset*)candidate
           completion:(void (^)(NSError* _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

#endif // __OBJC__
