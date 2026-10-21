// verify_riff_recorder.mm — unit test for RigRiffRecorder
#import <Foundation/Foundation.h>
#import "rig_riff_recorder.h"
#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>

int main() {
  @autoreleasepool {
    RigRiffRecorder* recorder = [RigRiffRecorder sharedRecorder];
    assert(recorder != nil);
    assert(!recorder.isRecording);
    assert(recorder.recordedWavData == nil);

    std::cout << "Testing startRecording..." << std::endl;
    [recorder startRecording];
    assert(recorder.isRecording);

    // Simulate 2 seconds of 48kHz audio (96,000 stereo frames)
    // Left: 440 Hz sine wave, Right: 880 Hz sine wave
    const double srate = 48000.0;
    const uint32_t totalFrames = 96000;
    const uint32_t blockSize = 256;
    std::vector<float> left(blockSize);
    std::vector<float> right(blockSize);

    uint32_t framesRendered = 0;
    while (framesRendered < totalFrames) {
      uint32_t chunk = std::min(blockSize, totalFrames - framesRendered);
      for (uint32_t i = 0; i < chunk; ++i) {
        double t = static_cast<double>(framesRendered + i) / srate;
        left[i] = static_cast<float>(0.5 * std::sin(2.0 * M_PI * 440.0 * t));
        right[i] = static_cast<float>(0.4 * std::sin(2.0 * M_PI * 880.0 * t));
      }
      rigRiffRecorderPushSamples(left.data(), right.data(), chunk, srate);
      framesRendered += chunk;
    }

    assert(recorder.currentPeakLevel > 0.3f);
    std::cout << "Peak level during audio: " << recorder.currentPeakLevel << std::endl;

    std::cout << "Testing stopRecording..." << std::endl;
    [recorder stopRecording];
    assert(!recorder.isRecording);

    NSData* wav = recorder.recordedWavData;
    assert(wav != nil);
    assert(wav.length > 44);
    std::cout << "WAV size: " << wav.length << " bytes, duration: " << recorder.recordedDuration << "s" << std::endl;
    assert(std::fabs(recorder.recordedDuration - 2.0) < 0.05);

    // Check WAV header
    const char* bytes = (const char*)wav.bytes;
    assert(std::memcmp(bytes, "RIFF", 4) == 0);
    assert(std::memcmp(bytes + 8, "WAVE", 4) == 0);
    assert(std::memcmp(bytes + 12, "fmt ", 4) == 0);
    (void)bytes;

    // Check telemetry metrics
    std::cout << "Peak dBFS: " << recorder.peakDbfs << std::endl;
    std::cout << "RMS dBFS: " << recorder.rmsDbfs << std::endl;
    std::cout << "Crest Factor: " << recorder.crestFactorDb << std::endl;
    std::cout << "Summary:\n" << [recorder.audioAnalysisSummary UTF8String] << std::endl;

    assert(recorder.peakDbfs > -10.0f && recorder.peakDbfs < 0.0f);
    assert(recorder.rmsDbfs > -15.0f && recorder.rmsDbfs < -5.0f);
    assert(recorder.audioAnalysisSummary.length > 0);

    std::cout << "Testing clearRecording..." << std::endl;
    [recorder clearRecording];
    assert(recorder.recordedWavData == nil);
    assert(recorder.recordedDuration == 0.0);

    // Pair identity, live duration, clipping before PCM clamping, and auto-finalization.
    [recorder startRecordingGuided:YES];
    std::fill(left.begin(), left.end(), 1.25f);
    std::fill(right.begin(), right.end(), .1f);
    rigRiffRecorderPushPair(left.data(), right.data(), right.data(), blockSize, srate, 35);
    assert(recorder.recordedDuration > 0);
    [recorder stopRecording];
    assert(recorder.latencyFrames == 35);
    assert(recorder.recordedDIFrames.length == blockSize * sizeof(float));
    assert(static_cast<const float*>(recorder.recordedDIFrames.bytes)[0] == 1.25f);
    assert(recorder.recordedDIWavData.length > 44);
    assert([recorder.audioAnalysisSummary containsString:@"clipped samples 256"]);
    assert([recorder.audioAnalysisSummary containsString:@"Guided Muted strings"]);

    [recorder startRecording];
    std::fill(left.begin(), left.end(), 0);
    for (uint32_t i = 0; i < uint32_t(srate * 20); i += blockSize)
      rigRiffRecorderPushPair(left.data(), right.data(), right.data(), blockSize, srate, 0);
    assert(!recorder.isRecording);
    [recorder stopRecording];
    assert(recorder.recordedWavData.length > 44);
    assert(std::fabs(recorder.recordedDuration - 20) < .001);
    [recorder stopRecording]; // Idempotent finalization.

    // Exercise local audition processing without loading heavyweight NAMs or AI.
    recorder.renderHandler = ^NSData*(RigPreset* preset, NSData* di, double rate, NSError** error) {
      std::vector<float> output(2048, .1f);
      return [NSData dataWithBytes:output.data() length:output.size() * sizeof(float)];
    };
    __block BOOL completed = NO;
    [recorder renderBaseline:(RigPreset*)[NSObject new] candidate:(RigPreset*)[NSObject new] completion:^(NSError* error) {
      assert(!error); completed = YES;
    }];
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!completed && deadline.timeIntervalSinceNow > 0)
      [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    assert(completed && recorder.baselineWavData.length && recorder.candidateWavData.length);
    assert([recorder.candidateAnalysis containsString:@"Before audition level matching"]);
    recorder.renderHandler = nil;

    // Import decoder round-trip and independent reference storage.
    NSString* dir = NSProcessInfo.processInfo.environment[@"TMPDIR"] ?: NSTemporaryDirectory();
    NSURL* file = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"wav"]]];
    [recorder.recordedDIWavData writeToURL:file atomically:YES];
    NSError* importError = nil;
    assert([recorder loadReferenceFromURL:file fullMix:YES error:&importError]);
    assert(recorder.recordedDIFrames.length > 0);
    assert([recorder.referenceAnalysis containsString:@"do NOT match"]);
    [recorder clearRecording];
    assert(recorder.referenceWavData.length > 0);
    assert([recorder loadAudioFromURL:file error:&importError]);
    assert(recorder.recordedDIFrames == nil);
    assert(recorder.recordedWavData.length > 44);
    [@"bad wave" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSData* previous = recorder.recordedWavData;
    assert(![recorder loadAudioFromURL:file error:&importError]);
    assert(recorder.recordedWavData == previous);
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    [recorder clearRecording]; [recorder clearReference];

    std::cout << "PASS verify_riff_recorder" << std::endl;
  }
  return 0;
}
