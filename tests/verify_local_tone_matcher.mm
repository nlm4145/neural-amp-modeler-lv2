#import "rig_local_tone_matcher.h"
#include "rig_control_metadata.h"
#include "local_tone_learning.h"
#ifdef NAMRIG_REAL_RENDER
#import "rig_riff_renderer.h"
#endif
#include <cassert>
#include <cmath>
#include <cstdio>

// Minimal in-memory preset; does not load user preferences or touch AppKit rigs.
@implementation RigPreset {
  std::unordered_map<uint32_t, float> _controls;
  std::array<RigStagePreset, 4> _stages;
}
+ (RigPreset*)defaultPreset {
  RigPreset* p = [RigPreset new]; p.name = @"Fixture"; p.slotPresets = [NSMutableDictionary dictionary];
  for (const auto& c : NAMRig::kRigControlContracts) [p setControl:c.port value:c.defaultValue];
  for (size_t s = 0; s < 4; ++s) [p stageAtIndex:s]->role = s == 1 ? "amp" : "cab";
  return p;
}
- (void)setControl:(uint32_t)p value:(float)v { _controls[p] = v; }
- (float)controlForPort:(uint32_t)p { return _controls[p]; }
- (const std::unordered_map<uint32_t, float>&)allControls { return _controls; }
- (RigStagePreset*)stageAtIndex:(size_t)i { return &_stages[i]; }
@end

int main(int argc, char** argv) {
  @autoreleasepool {
    assert(argc >= 2);
    NSString* cache = @(argv[1]);
    const double rate = 48000;
    std::vector<float> raw(24000);
    for (size_t i = 0; i < raw.size(); ++i) raw[i] = .1f * std::sin(2 * M_PI * 220 * i / rate);
    NSData* di = [NSData dataWithBytes:raw.data() length:raw.size() * sizeof(float)];
    RigPreset* base = [RigPreset defaultPreset];
    for (uint32_t p : {7u, 8u, 9u, 47u, 184u, 185u, 189u}) [base setControl:p value:0];
    [base setControl:15 value:-80]; [base setControl:27 value:10000];
    RigRiffRenderHandler render;
#ifdef NAMRIG_REAL_RENDER
    if (argc > 2) { [base stageAtIndex:1]->path = argv[2]; [base setControl:8 value:1]; }
    render = ^NSData*(RigPreset* p, NSData* x, double sampleRate, NSError** error) {
      return rigRenderDI(p, x, sampleRate, error);
    };
#else
    render = ^NSData*(RigPreset* p, NSData* x, double sampleRate, NSError** error) {
      size_t frames = x.length / sizeof(float); std::vector<float> output(frames * 2);
      double low = std::pow(10., [p controlForPort:12] / 20.), high = std::pow(10., [p controlForPort:14] / 20.);
      double level = .1 * std::pow(10., [p controlForPort:5] / 20.);
      for (size_t i = 0; i < frames; ++i) output[i * 2] = output[i * 2 + 1] = level *
          (low * std::sin(2 * M_PI * 220 * i / sampleRate) + high * std::sin(2 * M_PI * 4000 * i / sampleRate));
      return [NSData dataWithBytes:output.data() length:output.size() * sizeof(float)];
    };
#endif
    RigPreset* goal = [RigPreset defaultPreset];
    for (const auto& kv : base.allControls) [goal setControl:kv.first value:kv.second];
    for (size_t s = 0; s < 4; ++s) *[goal stageAtIndex:s] = *[base stageAtIndex:s];
    [goal setControl:12 value:2]; [goal setControl:14 value:-2];
    NSError* renderError = nil; NSData* target = render(goal, di, rate, &renderError);
    assert(target && !renderError);
    target = [target subdataWithRange:NSMakeRange(0, di.length * 2)];
    const auto before = base.allControls;
    RigLocalToneMatcher* matcher = [RigLocalToneMatcher sharedMatcher];
    __block BOOL done = NO;
    __block NSArray<RigLocalToneMatch*>* winners;
    __block NSDictionary* record;
    [matcher matchDI:di rate:rate target:target targetRate:rate targetChannels:2 seeds:@[base] renderer:render
        cacheDirectory:cache progress:^(NSString* line) { assert(NSThread.isMainThread); }
        completion:^(NSArray* matches, NSDictionary* metadata, NSError* error) {
      if (error) std::fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
      assert(NSThread.isMainThread && !error); winners = matches; record = metadata; done = YES;
    }];
    assert(matcher.isRunning);
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:90];
    while (!done && deadline.timeIntervalSinceNow > 0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    assert(done && !matcher.isRunning && winners.count > 0 && winners.count <= 3);
    assert(base.allControls == before);
    assert([record[@"training_examples"] count] == 13 && [record[@"coefficients"] count] == 7);
    assert([record[@"render_count"] unsignedIntegerValue] >= 20);
    assert([NSFileManager.defaultManager fileExistsAtPath:record[@"training_file"]]);
    assert(![record[@"audio_stored"] boolValue]);
    for (RigLocalToneMatch* winner in winners) {
      for (const auto& c : NAMRig::kRigControlContracts) assert(NAMRig::validRigControlValue(c, [winner.preset controlForPort:c.port]));
      NSError* error = nil; NSData* audio = render(winner.preset, di, rate, &error); assert(audio && !error);
      auto measured = NAMRig::LocalTone::measure(static_cast<const float*>(audio.bytes), raw.size(), 2, rate);
      auto reference = NAMRig::LocalTone::measure(static_cast<const float*>(target.bytes), raw.size(), 2, rate);
      assert(std::fabs(winner.score - NAMRig::LocalTone::distance(measured.features, reference.features)) < 1e-5);
      assert(measured.peak < 1);
    }
    assert(winners.firstObject.score <= [record[@"initial_score"] doubleValue] + 1e-4);
    assert(winners.firstObject.score < [record[@"initial_score"] doubleValue] * .9);
    std::printf("PASS local matcher improved real measured distance %.3f -> %.3f dB\n", [record[@"initial_score"] doubleValue], winners.firstObject.score);
    // Longer takes are measured over up to three non-overlapping loud excerpts.
    {
      std::vector<float> longRaw(size_t(rate * 6));
      for (size_t i = 0; i < longRaw.size(); ++i) {
        double gain = (i / size_t(rate)) % 2 ? .02 : .1; // Alternating loud/quiet seconds.
        longRaw[i] = float(gain * std::sin(2 * M_PI * 220 * i / rate));
      }
      NSData* longDI = [NSData dataWithBytes:longRaw.data() length:longRaw.size() * sizeof(float)];
      NSError* error = nil; NSData* longTarget = render(goal, longDI, rate, &error);
      assert(longTarget && !error);
      longTarget = [longTarget subdataWithRange:NSMakeRange(0, longDI.length * 2)];
      done = NO; __block NSDictionary* longRecord;
      [matcher matchDI:longDI rate:rate target:longTarget targetRate:rate targetChannels:2 seeds:@[base] renderer:render
          cacheDirectory:cache progress:nil completion:^(NSArray* matches, NSDictionary* metadata, NSError* matchError) {
        if (matchError) std::fprintf(stderr, "%s\n", matchError.localizedDescription.UTF8String);
        assert(matches.count && !matchError); longRecord = metadata; done = YES;
      }];
      deadline = [NSDate dateWithTimeIntervalSinceNow:90];
      while (!done && deadline.timeIntervalSinceNow > 0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
      assert(done && [longRecord[@"di_excerpts"] integerValue] == 3 && [longRecord[@"target_excerpts"] integerValue] == 3);
      assert([longRecord[@"version"] integerValue] == 2 && [longRecord[@"feature_version"] integerValue] == NAMRig::LocalTone::kFeatureVersion);
    }
    // Cancellation completes once, without publishing a candidate or mutating the base.
    done = NO;
    [matcher matchDI:di rate:rate target:target targetRate:rate targetChannels:2 seeds:@[base] renderer:render cacheDirectory:cache
        progress:nil completion:^(NSArray* matches, NSDictionary* metadata, NSError* error) {
      assert(!matches && error); done = YES;
    }];
    [matcher cancel];
    deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!done && deadline.timeIntervalSinceNow > 0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    assert(done && !matcher.isRunning && base.allControls == before);
    // Clip safety is checked before any engine render.
    raw[0] = 1;
    NSData* clipped = [NSData dataWithBytes:raw.data() length:raw.size() * sizeof(float)]; done = NO;
    [matcher matchDI:clipped rate:rate target:target targetRate:rate targetChannels:2 seeds:@[base] renderer:render cacheDirectory:cache
        progress:nil completion:^(NSArray* matches, NSDictionary* metadata, NSError* error) {
      assert(!matches && [error.localizedDescription containsString:@"full scale"]); done = YES;
    }];
    deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!done && deadline.timeIntervalSinceNow > 0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    assert(done);
    // Dry seeds bypass effects and cabs on full-rig captures; source untouched.
    [base stageAtIndex:1]->path = "/somewhere/Full Rig/Test/amp.nam";
    [base stageAtIndex:2]->path = "/somewhere/Cab/cab.wav";
    NSArray* seeds = rigLocalToneSeeds(base, @[], @"/not-a-library");
    assert(seeds.count == 1);
    RigPreset* seed = seeds.firstObject;
    assert([seed stageAtIndex:2]->path.empty() && [seed controlForPort:9] == 0 && [seed controlForPort:72] == 0);
    assert([seed controlForPort:4] == [base controlForPort:4]);
    assert(![base stageAtIndex:2]->path.empty());
    std::puts("PASS local matching: verified finalists, training record, cancellation, clipping, full-rig seeds");
  }
}
