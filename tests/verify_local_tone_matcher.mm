#import "rig_local_tone_matcher.h"
#include "rig_control_metadata.h"
#include "local_tone_post_eq.h"
#include "wav_ir.h"
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

namespace {
using namespace NAMRig::LocalTone;
// Synthetic cabinet: a few narrow resonances (decaying sinusoids) a tone stack
// cannot imitate, written as a mono float32 WAV.
NSString* writeCab(NSString* dir, NSString* name, std::initializer_list<double> peaks, double rate) {
  std::vector<float> h(1024, 0);
  h[0] = .3f;
  for (double f : peaks)
    for (size_t n = 0; n < h.size(); ++n) h[n] += float(.25 * std::exp(-double(n) / 180) * std::sin(2 * M_PI * f * n / rate));
  NSMutableData* wav = [NSMutableData data];
  auto u32 = [&](uint32_t v) { [wav appendBytes:&v length:4]; };
  auto u16 = [&](uint16_t v) { [wav appendBytes:&v length:2]; };
  [wav appendBytes:"RIFF" length:4]; u32(uint32_t(36 + h.size() * 4)); [wav appendBytes:"WAVEfmt " length:8];
  u32(16); u16(3); u16(1); u32(uint32_t(rate)); u32(uint32_t(rate * 4)); u16(4); u16(32);
  [wav appendBytes:"data" length:4]; u32(uint32_t(h.size() * 4)); [wav appendBytes:h.data() length:h.size() * 4];
  NSString* path = [dir stringByAppendingPathComponent:name];
  assert([wav writeToFile:path atomically:YES]);
  return path;
}
void wait(const BOOL* done, double seconds) {
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (!*done && deadline.timeIntervalSinceNow > 0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
}
}

int main(int argc, char** argv) {
  @autoreleasepool {
    assert(argc >= 2);
    NSString* cache = @(argv[1]);
    [NSFileManager.defaultManager createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
    [NSFileManager.defaultManager removeItemAtPath:[RigLocalToneMatcher renderCacheDirectory] error:nil];
    const double rate = 48000;
    // Plucked two-note figure: decays and onsets give the texture features something to see.
    std::vector<float> raw(size_t(rate * 1.2));
    for (size_t i = 0; i < raw.size(); ++i) {
      const double t = i / rate, local = std::fmod(t, .6), env = std::exp(-3 * local);
      // Pick harmonics up the spectrum, like a real DI, so amp voicing matters.
      double x = 0;
      for (int h = 1; h <= 12; ++h) x += (std::sin(2 * M_PI * 110 * h * t) + .6 * std::sin(2 * M_PI * 165 * h * t)) / h;
      raw[i] = float(.07 * env * x);
    }
    NSData* di = [NSData dataWithBytes:raw.data() length:raw.size() * sizeof(float)];
    NSString* cabA = writeCab(cache, @"cab-a.wav", {1100, 5200}, rate);
    NSString* cabB = writeCab(cache, @"cab-b.wav", {2400, 380}, rate);
    NSString* cabC = writeCab(cache, @"cab-c.wav", {700, 3900}, rate);
    RigPreset* live = [RigPreset defaultPreset];
    for (uint32_t p : {7u, 47u, 184u, 185u, 189u}) [live setControl:p value:0];
    RigRiffRenderHandler render;
    NSArray<NSString*>* amps;
#ifdef NAMRIG_REAL_RENDER
    // <training> <truth-amp.nam> [cab-folder] [other amps...]: other amps come first
    // (the first plays the "current" amp), so more than 3 exercise the quick screen.
    assert(argc > 2);
    NSMutableArray* realAmps = [NSMutableArray array];
    for (int i = 4; i < argc; ++i) [realAmps addObject:@(argv[i])];
    [realAmps addObject:@(argv[2])];
    amps = realAmps;
    render = ^NSData*(RigPreset* p, NSData* x, double sampleRate, NSError** error) {
      return rigRenderDI(p, x, sampleRate, error);
    };
#else
    // Six amps (> 4) exercise the quick screen; decoys first, the hidden truth last.
    amps = @[@"/stub/amp-a.nam", @"/stub/amp-c-bright.nam", @"/stub/amp-d-soft.nam", @"/stub/amp-e-hard.nam",
             @"/stub/amp-f-bright-soft.nam", @"/stub/amp-b-dark.nam"];
    // Stub engine with the real chain's structure: drive → (OD push) → amp
    // nonlinearity → cab IR (if processed) → cuts/console (only with a cab) →
    // tone stack → output level.
    render = ^NSData*(RigPreset* p, NSData* x, double sampleRate, NSError** error) {
      const size_t frames = x.length / sizeof(float);
      const auto* in = static_cast<const float*>(x.bytes);
      const std::string amp = [p stageAtIndex:1]->path, cab = [p stageAtIndex:2]->path;
      double gain = std::pow(10., [p controlForPort:22] / 20.);
      if ([p controlForPort:185] >= .5 && [p controlForPort:179] > 0) gain *= 1 + [p controlForPort:179] / 25.;
      const bool pedal = [p controlForPort:7] >= .5 && ![p stageAtIndex:0]->path.empty();
      if (pedal) gain *= 2.5; // A boost pedal capture.
      auto has = [&](const char* word) { return amp.find(word) != std::string::npos; };
      const bool dark = has("dark"), bright = has("bright"), hard = has("hard");
      const double drive = has("soft") ? 1.5 : 4;
      std::vector<float> y(frames);
      double lp = 0, previous = 0;
      for (size_t i = 0; i < frames; ++i) {
        lp += (in[i] - lp) * (dark ? .15 : 1.0);
        double x = bright ? lp - .85 * previous : lp; previous = lp;
        x *= drive * gain;
        y[i] = float(.3 * (hard ? std::clamp(x, -1.0, 1.0) : std::tanh(x)));
      }
      const bool cabProcessed = [p controlForPort:9] >= .5 && !cab.empty();
      if (cabProcessed) {
        const auto h = NAMRig::WavIR::loadTaps(cab.c_str(), sampleRate);
        std::vector<float> z(frames, 0);
        for (size_t i = 0; i < frames; ++i)
          for (size_t k = 0; k < h.size() && k <= i; ++k) z[i] += h[k] * y[i - k];
        y = z;
      }
      PostEq eq;
      eq.bass = [p controlForPort:12]; eq.mid = [p controlForPort:13]; eq.treble = [p controlForPort:14];
      eq.lowCut = [p controlForPort:26]; eq.highCut = [p controlForPort:27];
      eq.console = cabProcessed && [p controlForPort:78] >= .5;
      eq.pins = NAMRig::readPinBands(NAMRig::PinEqPane::CabConsole, [&](uint32_t port) { return [p controlForPort:port]; });
      applyPostEq(eq, y.data(), frames, 1, sampleRate);
      const float level = float(std::pow(10., [p controlForPort:5] / 20.));
      std::vector<float> output(frames * 2);
      for (size_t i = 0; i < frames; ++i) output[i * 2] = output[i * 2 + 1] = y[i] * level;
      return [NSData dataWithBytes:output.data() length:output.size() * sizeof(float)];
    };
#endif
    RigLocalTonePlan* plan = rigLocalTonePlan(live, @[], @"/not-a-library");
    plan.amps = amps; plan.cabs = @[cabA, cabB, cabC]; plan.currentCab = cabA;
#ifndef NAMRIG_REAL_RENDER
    plan.pedals = @[@"/stub/pedal-boost.nam"];
#endif
#ifdef NAMRIG_REAL_RENDER
    // Optional real library cab folder: the hidden cab must still win against it.
    if (argc > 3) {
      NSMutableArray* cabs = [plan.cabs mutableCopy];
      NSDirectoryEnumerator* walk = [NSFileManager.defaultManager enumeratorAtPath:@(argv[3])];
      for (NSString* relative; (relative = [walk nextObject]);)
        if ([relative.pathExtension.lowercaseString isEqualToString:@"wav"]) [cabs addObject:[@(argv[3]) stringByAppendingPathComponent:relative]];
      plan.cabs = cabs;
    }
#endif
    // Hidden truth: the last amp, cab B, +6 dB drive and a voiced tone stack.
    RigPreset* goal = [RigPreset defaultPreset];
    for (const auto& kv : plan.base.allControls) [goal setControl:kv.first value:kv.second];
    [goal stageAtIndex:1]->path = amps.lastObject.fileSystemRepresentation; [goal setControl:8 value:1];
    [goal stageAtIndex:2]->path = cabB.fileSystemRepresentation; [goal setControl:9 value:1];
    [goal stageAtIndex:1]->enabled = [goal stageAtIndex:2]->enabled = true;
    [goal setControl:22 value:6]; [goal setControl:12 value:3]; [goal setControl:14 value:-4]; [goal setControl:26 value:80];
    // ...plus a "mix" EQ only the Console pins can reproduce.
    using NAMRig::pinEqPort; using NAMRig::PinEqPane;
    // 250 Hz boost and 3.5 kHz cut: the 150 Hz / 3 kHz shelves cannot imitate them.
    for (auto [band, gain] : {std::pair<size_t, double>{1, 5}, {4, -5}}) {
      [goal setControl:pinEqPort(PinEqPane::CabConsole, band, NAMRig::kPinShape) value:NAMRig::kPinBell];
      [goal setControl:pinEqPort(PinEqPane::CabConsole, band, NAMRig::kPinFreq) value:NAMRig::kPinFreqDefaults[band]];
      [goal setControl:pinEqPort(PinEqPane::CabConsole, band, NAMRig::kPinGain) value:gain];
      [goal setControl:pinEqPort(PinEqPane::CabConsole, band, NAMRig::kPinQ) value:.9];
    }
    NSError* renderError = nil; NSData* target = render(goal, di, rate, &renderError);
    assert(target && !renderError);
    target = [target subdataWithRange:NSMakeRange(0, di.length * 2)];
    const auto before = live.allControls;
    RigLocalToneMatcher* matcher = [RigLocalToneMatcher sharedMatcher];
    __block BOOL done = NO;
    __block NSArray<RigLocalToneMatch*>* winners;
    __block NSDictionary* record;
    [matcher matchDI:di rate:rate target:target targetRate:rate targetChannels:2 plan:plan renderer:render
        cacheDirectory:cache progress:^(NSString* line) { assert(NSThread.isMainThread); std::printf("  | %s\n", line.UTF8String); }
        completion:^(NSArray* matches, NSDictionary* metadata, NSError* error) {
      if (error) std::fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
      assert(NSThread.isMainThread && !error); winners = matches; record = metadata; done = YES;
    }];
    assert(matcher.isRunning);
    wait(&done, 600);
    assert(done && !matcher.isRunning && winners.count > 0 && winners.count <= 3);
    assert(live.allControls == before);
    assert([record[@"version"] integerValue] == 3 && [record[@"cabs_screened"] integerValue] == (NSInteger)plan.cabs.count);
    assert([record[@"amps_screened"] integerValue] == (NSInteger)amps.count);
    assert([record[@"search_renders"] integerValue] <= 20);
    // Quick screen (one short render per amp when > 4) + ≤ 4 full amps + search + ≤ 4 per finalist.
    const NSInteger quick = amps.count > 4 ? (NSInteger)amps.count : 0;
    assert([record[@"quick_renders"] integerValue] == quick);
    assert([record[@"amps_full"] integerValue] == (NSInteger)std::min<NSUInteger>(amps.count, 4));
    assert([record[@"render_count"] integerValue] <= quick + 4 + 20 + 12);
    assert([NSFileManager.defaultManager fileExistsAtPath:record[@"training_file"]]);
    assert(![record[@"audio_stored"] boolValue]);
    RigLocalToneMatch* best = winners.firstObject;
    for (RigLocalToneMatch* winner in winners) {
      for (const auto& c : NAMRig::kRigControlContracts) assert(NAMRig::validRigControlValue(c, [winner.preset controlForPort:c.port]));
      NSError* error = nil; NSData* audio = render(winner.preset, di, rate, &error); assert(audio && !error);
      auto measured = measure(static_cast<const float*>(audio.bytes), raw.size(), 2, rate);
      auto reference = measure(static_cast<const float*>(target.bytes), raw.size(), 2, rate);
      assert(std::fabs(winner.score - distance(measured.features, reference.features)) < 1e-5);
      assert(measured.peak < 1);
      // Offline prediction (amp render ⊛ IR + post EQ) agrees with the full render.
      std::printf("  finalist %s: offline %.3f, engine %.3f dB\n", winner.preset.name.UTF8String, winner.offlineScore, winner.score);
      assert(std::fabs(winner.score - winner.offlineScore) < .2);
    }
    const double initial = [record[@"initial_score"] doubleValue];
    std::printf("PASS local matcher: %.3f -> %.3f dB, %ld renders; best %s drive %+.1f bass %+.1f mid %+.1f treble %+.1f lowcut %.0f\n",
        initial, best.score, (long)[record[@"render_count"] integerValue], best.preset.name.UTF8String,
        [best.preset controlForPort:22], [best.preset controlForPort:12], [best.preset controlForPort:13],
        [best.preset controlForPort:14], [best.preset controlForPort:26]);
    assert(best.score < initial * .5);
    // The Console-pin mix EQ in the target is recognized and kept (and can be switched off).
    assert(best.presetWithoutMixEQ && best.score < best.scoreWithoutMixEQ);
    assert([best.presetWithoutMixEQ controlForPort:pinEqPort(PinEqPane::CabConsole, 4, NAMRig::kPinGain)] == 0);
    assert([best.preset controlForPort:pinEqPort(PinEqPane::CabConsole, 1, NAMRig::kPinGain)] > 1);
    assert([best.preset controlForPort:pinEqPort(PinEqPane::CabConsole, 4, NAMRig::kPinGain)] < -1);
    std::printf("  mix EQ: %.3f -> %.3f dB\n", best.scoreWithoutMixEQ, best.score);
    assert([@([best.preset stageAtIndex:2]->path.c_str()) isEqualToString:cabB]);
    assert([@([best.preset stageAtIndex:1]->path.c_str()) isEqualToString:amps.lastObject]);
#ifndef NAMRIG_REAL_RENDER
    assert([@([best.preset stageAtIndex:1]->path.c_str()) isEqualToString:amps.lastObject]);
    assert(std::fabs([best.preset controlForPort:22] - 6) <= 3 && best.score < .5);
    assert([record[@"pedals_tried"] integerValue] == 1 && [best.preset stageAtIndex:0]->path.empty());

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
      [matcher matchDI:longDI rate:rate target:longTarget targetRate:rate targetChannels:2 plan:plan renderer:render
          cacheDirectory:cache progress:nil completion:^(NSArray* matches, NSDictionary* metadata, NSError* matchError) {
        if (matchError) std::fprintf(stderr, "%s\n", matchError.localizedDescription.UTF8String);
        assert(matches.count && !matchError); longRecord = metadata; done = YES;
      }];
      wait(&done, 300);
      assert(done && [longRecord[@"di_excerpts"] integerValue] == 3 && [longRecord[@"target_excerpts"] integerValue] == 3);
      assert([longRecord[@"feature_version"] integerValue] == kFeatureVersion);
    }
#endif

    // Phase D: Demucs-aware weights, render cache reuse, and training prior reuse.
    {
      NSString* firstTrainingFile = record[@"training_file"];
      assert(firstTrainingFile && [NSFileManager.defaultManager fileExistsAtPath:firstTrainingFile]);
      NSString* copyTrainingFile = [cache stringByAppendingPathComponent:@"prior-synthetic-run.json"];
      [NSFileManager.defaultManager removeItemAtPath:copyTrainingFile error:nil];
      assert([NSFileManager.defaultManager copyItemAtPath:firstTrainingFile toPath:copyTrainingFile error:nil]);

      RigLocalTonePlan* demucsPlan = rigLocalTonePlan(live, @[], @"/not-a-library");
      demucsPlan.amps = @[amps.lastObject];
      demucsPlan.cabs = @[cabB];
      demucsPlan.currentCab = cabB;
      demucsPlan.referenceSource = @"demucs";

      done = NO; __block NSDictionary* demucsRecord = nil;
      [matcher matchDI:di rate:rate target:target targetRate:rate targetChannels:2 plan:demucsPlan renderer:render
          cacheDirectory:cache progress:nil completion:^(NSArray* matches, NSDictionary* metadata, NSError* error) {
        assert(!error && matches.count);
        demucsRecord = metadata;
        done = YES;
      }];
      wait(&done, 120);
      assert(done);
      assert([demucsRecord[@"demucs_weighted"] boolValue]);
      assert([demucsRecord[@"cached_renders"] integerValue] > 0);
      assert([demucsRecord[@"prior_runs_found"] integerValue] >= 2);
      std::printf("PASS Phase D: demucs_weighted=YES, cached_renders=%ld, prior_runs_found=%ld\n",
          (long)[demucsRecord[@"cached_renders"] integerValue],
          (long)[demucsRecord[@"prior_runs_found"] integerValue]);
    }

    // Cancellation completes once, without publishing a candidate or mutating the base.
    done = NO;
    [matcher matchDI:di rate:rate target:target targetRate:rate targetChannels:2 plan:plan renderer:render cacheDirectory:cache
        progress:nil completion:^(NSArray* matches, NSDictionary* metadata, NSError* error) {
      assert(!matches && error); done = YES;
    }];
    [matcher cancel];
    wait(&done, 60);
    assert(done && !matcher.isRunning && live.allControls == before);
    // Clip safety is checked before any engine render.
    raw[0] = 1;
    NSData* clipped = [NSData dataWithBytes:raw.data() length:raw.size() * sizeof(float)]; done = NO;
    [matcher matchDI:clipped rate:rate target:target targetRate:rate targetChannels:2 plan:plan renderer:render cacheDirectory:cache
        progress:nil completion:^(NSArray* matches, NSDictionary* metadata, NSError* error) {
      assert(!matches && [error.localizedDescription containsString:@"full scale"]); done = YES;
    }];
    wait(&done, 5);
    assert(done);
    // No cab IRs and no full-rig capture: fails clearly instead of guessing.
    RigLocalTonePlan* empty = rigLocalTonePlan(live, @[], @"/not-a-library");
    empty.amps = @[@"/stub/amp-a.nam"]; raw[0] = 0; done = NO;
    [matcher matchDI:[NSData dataWithBytes:raw.data() length:raw.size() * sizeof(float)] rate:rate target:target targetRate:rate
        targetChannels:2 plan:empty renderer:render cacheDirectory:cache progress:nil
        completion:^(NSArray* matches, NSDictionary* metadata, NSError* error) {
      assert(!matches && [error.localizedDescription containsString:@"cab IR"]); done = YES;
    }];
    wait(&done, 5);
    assert(done);
    // Plan: dry base bypasses effects, neutralizes the linear post section, keeps input calibration.
    [live stageAtIndex:1]->path = "/somewhere/Full Rig/Test/amp.nam";
    [live stageAtIndex:2]->path = "/somewhere/Cab/cab.wav";
    [live setControl:12 value:5]; [live setControl:26 value:120];
    RigLocalTonePlan* dryPlan = rigLocalTonePlan(live, @[], @"/not-a-library");
    assert(dryPlan.amps.count == 1 && [dryPlan.amps[0] isEqualToString:@"/somewhere/Full Rig/Test/amp.nam"]);
    assert(dryPlan.cabs.count == 0); // Missing file is not offered.
    RigPreset* dryBase = dryPlan.base;
    assert([dryBase stageAtIndex:2]->path.empty() && [dryBase controlForPort:9] == 0 && [dryBase controlForPort:72] == 0);
    assert([dryBase controlForPort:12] == 0 && [dryBase controlForPort:26] == 0 && [dryBase controlForPort:78] == 1);
    assert([dryBase controlForPort:4] == [live controlForPort:4]);
    assert(![live stageAtIndex:2]->path.empty() && [live controlForPort:12] == 5);
    std::puts("PASS local matching: offline cab screen, tone-stack fit, verified finalists, cancellation, clipping, plan");
  }
}
