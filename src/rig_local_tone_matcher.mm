#import "rig_local_tone_matcher.h"
#include "local_tone_learning.h"
#include "rig_control_metadata.h"
#import "rig_ai_support.h"
#include <random>

@implementation RigLocalToneMatch
@end
@interface RigLocalToneMatcher ()
@property(nonatomic, readwrite) BOOL isRunning;
@end

namespace {
using namespace NAMRig::LocalTone;
NSError* failure(NSString* text) {
  return [NSError errorWithDomain:@"RigLocalToneMatcher" code:-1 userInfo:@{NSLocalizedDescriptionKey:text}];
}
RigPreset* clone(RigPreset* source) {
  RigPreset* p = [RigPreset defaultPreset];
  for (const auto& kv : source.allControls) [p setControl:kv.first value:kv.second];
  for (size_t s = 0; s < 4; ++s) *[p stageAtIndex:s] = *[source stageAtIndex:s];
  p.name = source.name; p.speakerProfile = source.speakerProfile;
  p.slotPresets = [source.slotPresets mutableCopy];
  return p;
}
inline constexpr uint32_t ports[kParameters] = {22, 12, 13, 14, 26, 27};
inline constexpr double steps[kParameters] = {3, 3, 3, 3, 30, 3000};
RigPreset* variant(RigPreset* base, const Parameters& x) {
  RigPreset* p = clone(base);
  for (size_t i = 0; i < kParameters; ++i) {
    const auto* contract = NAMRig::rigControlContract(ports[i]);
    double value = [base controlForPort:ports[i]] + x[i] * steps[i];
    [p setControl:ports[i] value:std::clamp(value, double(contract->minimum), double(contract->maximum))];
  }
  return p;
}
Parameters actualParameters(RigPreset* base, RigPreset* p) {
  Parameters x{};
  for (size_t i = 0; i < kParameters; ++i) x[i] = ([p controlForPort:ports[i]] - [base controlForPort:ports[i]]) / steps[i];
  return x;
}
NSArray* numbers(const Features& values) {
  NSMutableArray* out = [NSMutableArray array];
  for (double v : values) [out addObject:@(v)];
  return out;
}
// Keep the raw amplitude; take the most energetic contiguous 1.5 seconds.
// This avoids training on the guided recording's muted-string pre-roll.
NSData* excerpt(NSData* data, double rate, size_t channels) {
  const auto* samples = static_cast<const float*>(data.bytes);
  size_t frames = data.length / (channels * sizeof(float));
  size_t count = std::min(frames, size_t(rate * 1.5)), best = 0;
  double energy = 0;
  for (size_t i = 0; i < count * channels; ++i) energy += double(samples[i]) * samples[i];
  double maxEnergy = energy;
  for (size_t f = count; f < frames; ++f) {
    for (size_t c = 0; c < channels; ++c) {
      double a = samples[f * channels + c], b = samples[(f - count) * channels + c];
      energy += a * a - b * b;
    }
    if (energy > maxEnergy) { maxEnergy = energy; best = f - count + 1; }
  }
  return [data subdataWithRange:NSMakeRange(best * channels * sizeof(float), count * channels * sizeof(float))];
}
}

NSArray<RigPreset*>* rigLocalToneSeeds(RigPreset* base, NSArray<NSDictionary*>* catalog, NSString* root) {
  RigPreset* dry = clone(base);
  // Match the core guitar sound, not reverb/delay/mastering. Retain calibrated
  // input, oversampling and any selected pedal/OD; do not normalize the DI.
  for (uint32_t port : {33u, 53u, 54u, 71u, 72u, 73u, 74u, 76u, 77u, 79u, 184u, 189u}) [dry setControl:port value:0];
  [dry setControl:15 value:-80]; [dry setControl:30 value:0]; [dry setControl:42 value:0]; [dry setControl:80 value:0];
  [dry setControl:78 value:1]; // The optimized cab cuts must actually be active.
  [dry setControl:47 value:0]; [dry stageAtIndex:3]->path.clear(); [dry stageAtIndex:3]->models.clear();
  dry.slotPresets = [NSMutableDictionary dictionary]; dry.speakerProfile = 0;
  NSMutableArray<NSString*>* amps = [NSMutableArray array];
  NSMutableArray<NSString*>* cabs = [NSMutableArray array];
  for (NSDictionary* item in catalog) {
    NSUInteger stage = [item[@"stage"] unsignedIntegerValue];
    if (stage != 1 && stage != 2) continue;
    NSMutableArray* paths = stage == 1 ? amps : cabs;
    if (paths.count >= (stage == 1 ? 3u : 2u)) continue;
    NSString* path = rigAIResolveModel(root, item[@"path"], stage, nil);
    if (path.length && ![paths containsObject:path]) [paths addObject:path];
  }
  NSString* currentAmp = @([dry stageAtIndex:1]->path.c_str());
  NSString* currentCab = @([dry stageAtIndex:2]->path.c_str());
  if (!amps.count && currentAmp.length) [amps addObject:currentAmp];
  if (!cabs.count && currentCab.length) [cabs addObject:currentCab];
  NSMutableArray* seeds = [NSMutableArray array];
  auto add = [&](NSString* amp, NSString* cab) {
    if (!amp.length || seeds.count >= 8) return;
    RigPreset* p = clone(dry);
    [p stageAtIndex:1]->path = amp.fileSystemRepresentation;
    [p stageAtIndex:1]->models.clear(); [p stageAtIndex:1]->imageURL.clear(); [p stageAtIndex:1]->toneId = 0;
    BOOL includesCab = rigAIModelIncludesCab(amp);
    if (!includesCab && !cab.length) return;
    [p stageAtIndex:2]->path = includesCab ? "" : cab.fileSystemRepresentation;
    [p stageAtIndex:2]->models.clear(); [p stageAtIndex:2]->imageURL.clear(); [p stageAtIndex:2]->toneId = 0;
    [p setControl:8 value:1]; [p setControl:9 value:includesCab ? 0 : 1];
    const uint32_t enables[] = {7, 8, 9, 47};
    for (size_t s = 0; s < 4; ++s) {
      if ([p stageAtIndex:s]->path.empty()) [p setControl:enables[s] value:0];
      [p stageAtIndex:s]->enabled = [p controlForPort:enables[s]] >= .5;
    }
    p.name = [NSString stringWithFormat:@"%@ + %@", amp.lastPathComponent, includesCab ? @"captured cab" : cab.lastPathComponent];
    for (RigPreset* previous in seeds) {
      if ([previous stageAtIndex:1]->path == [p stageAtIndex:1]->path &&
          [previous stageAtIndex:2]->path == [p stageAtIndex:2]->path) return;
    }
    [seeds addObject:p];
  };
  add(currentAmp, currentCab);
  for (NSString* amp in amps) {
    if (rigAIModelIncludesCab(amp)) add(amp, @"");
    else for (NSString* cab in cabs) add(amp, cab);
  }
  return seeds;
}

@implementation RigLocalToneMatcher
+ (instancetype)sharedMatcher {
  static RigLocalToneMatcher* instance; static dispatch_once_t once;
  dispatch_once(&once, ^{ instance = [RigLocalToneMatcher new]; }); return instance;
}
+ (NSString*)trainingDirectory {
  return [@"~/Library/Application Support/Axe FX/Local Tone Training" stringByExpandingTildeInPath];
}
- (void)cancel { if (_cancelled) _cancelled->store(true); }
- (void)matchDI:(NSData*)di rate:(double)rate target:(NSData*)target
    targetRate:(double)targetRate targetChannels:(NSUInteger)channels
         seeds:(NSArray<RigPreset*>*)seeds renderer:(RigRiffRenderHandler)renderer
cacheDirectory:(NSString*)cacheDirectory progress:(void (^)(NSString*))progress
    completion:(void (^)(NSArray<RigLocalToneMatch*>*, NSDictionary*, NSError*))completion {
  NSAssert(NSThread.isMainThread, @"Freeze local matcher inputs on main thread");
  if (self.isRunning || !renderer || !seeds.count || seeds.count > 8 ||
      !std::isfinite(rate) || rate < 22050 || rate > 192000 ||
      !std::isfinite(targetRate) || targetRate < 22050 || targetRate > 192000 ||
      (channels != 1 && channels != 2) || di.length % sizeof(float) ||
      target.length % (channels * sizeof(float)) || di.length < rate * .25 * sizeof(float) ||
      target.length < targetRate * .25 * channels * sizeof(float) ||
      di.length > rate * 20 * sizeof(float) || target.length > targetRate * 20 * channels * sizeof(float)) {
    completion(nil, nil, failure(@"Local matching needs a paired DI take, an isolated target WAV, and 1–8 candidate rigs. A match must not already be running.")); return;
  }
  NSMutableArray* frozenSeeds = [NSMutableArray array];
  for (RigPreset* seed in seeds) [frozenSeeds addObject:clone(seed)];
  di = [di copy]; target = [target copy]; cacheDirectory = [cacheDirectory copy];
  _cancelled = std::make_shared<std::atomic<bool>>(false); auto cancelled = _cancelled;
  self.isRunning = YES;
  void (^report)(NSString*) = ^(NSString* line) {
    dispatch_async(dispatch_get_main_queue(), ^{ if (!cancelled->load() && progress) progress(line); });
  };
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      NSError* error = nil; NSDictionary* metadata = nil;
      NSMutableArray<RigLocalToneMatch*>* matches = [NSMutableArray array];
      NSMutableArray* examplesJSON = [NSMutableArray array];
      size_t renders = 0;
      try {
        auto checkCancel = [&] { if (cancelled->load()) throw std::runtime_error("Local matching cancelled; live rig unchanged."); };
        checkCancel();
        // Validate all raw samples before choosing excerpts, including input clipping.
        Measurement input = measure(static_cast<const float*>(di.bytes), di.length / sizeof(float), 1, rate);
        if (input.peak >= 1) throw std::runtime_error("Raw DI reaches full scale. Lower interface input gain and record an unclipped take before local training.");
        measure(static_cast<const float*>(target.bytes), target.length / (channels * sizeof(float)), channels, targetRate);
        NSData* dry = excerpt(di, rate, 1);
        NSData* reference = excerpt(target, targetRate, channels);
        Measurement goal = measure(static_cast<const float*>(reference.bytes), reference.length / (channels * sizeof(float)), channels, targetRate);
        const size_t renderFrames = dry.length / sizeof(float);
        auto evaluate = [&](RigPreset* p, BOOL retain) -> Measurement {
          checkCancel(); ++renders;
          NSError* renderError = nil; NSData* audio = renderer(p, dry, rate, &renderError);
          checkCancel();
          if (renderError || audio.length < renderFrames * 2 * sizeof(float) || audio.length % (2 * sizeof(float)))
            throw std::runtime_error((renderError.localizedDescription ?: @"Renderer returned an incomplete candidate.").UTF8String);
          Measurement m = measure(static_cast<const float*>(audio.bytes), renderFrames, 2, rate);
          if (retain) {
            RigLocalToneMatch* match = [RigLocalToneMatch new]; match.preset = p;
            match.score = distance(m.features, goal.features); [matches addObject:match];
          }
          return m;
        };
        report(@"LOCAL MATCH — analyzing short active excerpts. Comparing relative spectrum and dynamics, not exact artist-tone identity. Live rig unchanged; no audio uploaded.");
        for (NSUInteger i = 0; i < frozenSeeds.count; ++i) {
          checkCancel();
          RigPreset* p = frozenSeeds[i];
          report([NSString stringWithFormat:@"Testing gear %lu/%lu: %@…", (unsigned long)i + 1, (unsigned long)frozenSeeds.count, p.name]);
          try { evaluate(p, YES); }
          catch (const std::exception& e) {
            checkCancel(); report([NSString stringWithFormat:@"Skipping candidate %@: %s", p.name, e.what()]);
          }
        }
        if (!matches.count) throw std::runtime_error("No candidate rig rendered successfully. Check the installed models.");
        [matches sortUsingComparator:^NSComparisonResult(RigLocalToneMatch* a, RigLocalToneMatch* b) {
          return a.score < b.score ? NSOrderedAscending : a.score > b.score ? NSOrderedDescending : NSOrderedSame;
        }];
        RigPreset* anchor = clone(matches.firstObject.preset);
        const double initialScore = matches.firstObject.score;
        std::vector<Example> training;
        auto trainExample = [&](const Parameters& requested) {
          RigPreset* p = variant(anchor, requested); Measurement m = evaluate(p, YES);
          Parameters x = actualParameters(anchor, p); training.push_back({x, m.features});
          NSMutableDictionary* controls = [NSMutableDictionary dictionary];
          NSMutableArray* parameters = [NSMutableArray array];
          for (size_t i = 0; i < kParameters; ++i) {
            controls[@(NAMRig::rigControlSymbol(ports[i]))] = @([p controlForPort:ports[i]]);
            [parameters addObject:@(x[i])];
          }
          [examplesJSON addObject:@{@"parameters":parameters, @"controls":controls, @"features":numbers(m.features)}];
        };
        report(@"Training a local ridge-regression surrogate from 13 real control-perturbation renders…");
        trainExample({});
        for (size_t i = 0; i < kParameters; ++i) for (double direction : {-1.0, 1.0}) {
          Parameters x{}; x[i] = direction;
          report([NSString stringWithFormat:@"Training render %lu/13…", (unsigned long)training.size() + 1]);
          trainExample(x);
        }
        checkCancel();
        Surrogate model; model.train(training);
        std::mt19937 rng(42); std::uniform_real_distribution<double> distribution(-1, 1);
        std::vector<std::pair<double, Parameters>> predictions;
        for (size_t i = 0; i < 256; ++i) {
          Parameters x{}; for (double& value : x) value = distribution(rng);
          RigPreset* p = variant(anchor, x); x = actualParameters(anchor, p);
          predictions.emplace_back(distance(model.predict(x), goal.features), x);
        }
        std::sort(predictions.begin(), predictions.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
        report(@"Surrogate searched 256 settings locally. Verifying its best 3 suggestions with real engine renders…");
        for (size_t i = 0; i < 3; ++i) evaluate(variant(anchor, predictions[i].second), YES);
        [matches sortUsingComparator:^NSComparisonResult(RigLocalToneMatch* a, RigLocalToneMatch* b) {
          return a.score < b.score ? NSOrderedAscending : a.score > b.score ? NSOrderedDescending : NSOrderedSame;
        }];
        // Distinct settings only. Never replace a measured winner with an unverified prediction.
        NSMutableArray* finalists = [NSMutableArray array];
        for (RigLocalToneMatch* match in matches) {
          BOOL duplicate = NO;
          for (RigLocalToneMatch* previous in finalists) {
            if (previous.preset.allControls != match.preset.allControls) continue;
            BOOL same = YES;
            for (size_t s = 0; s < 4; ++s) same &= [previous.preset stageAtIndex:s]->path == [match.preset stageAtIndex:s]->path;
            if (same) { duplicate = YES; break; }
          }
          if (duplicate) continue;
          [finalists addObject:match]; if (finalists.count == 3) break;
        }
        matches = finalists;
        // Headroom correction is verified too. It cannot improve the loudness-invariant score.
        for (RigLocalToneMatch* match in matches) {
          Measurement m = evaluate(match.preset, NO);
          if (m.peak > .85) {
            double output = [match.preset controlForPort:5] + 20 * std::log10(.85 / m.peak);
            [match.preset setControl:5 value:std::max(-20.0, output)];
            m = evaluate(match.preset, NO);
            if (m.peak >= 1) throw std::runtime_error("Candidate cannot reach safe output headroom within the control range.");
          }
          match.score = distance(m.features, goal.features);
        }
        [matches sortUsingComparator:^NSComparisonResult(RigLocalToneMatch* a, RigLocalToneMatch* b) {
          return a.score < b.score ? NSOrderedAscending : a.score > b.score ? NSOrderedDescending : NSOrderedSame;
        }];
        checkCancel();
        NSMutableArray* coefficients = [NSMutableArray array];
        for (const auto& row : model.coefficients) [coefficients addObject:numbers(row)];
        NSMutableArray* gear = [NSMutableArray array];
        for (size_t s = 0; s < 4; ++s) [gear addObject:@([anchor stageAtIndex:s]->path.c_str())];
        NSString* runID = NSUUID.UUID.UUIDString;
        NSMutableDictionary* record = [@{@"version":@1, @"run_id":runID, @"method":@"local-ridge-surrogate-v1",
            @"created_at":NSDate.date.description, @"render_count":@(renders), @"training_examples":examplesJSON,
            @"coefficients":coefficients, @"anchor_gear":gear, @"target_features":numbers(goal.features),
            @"initial_score":@(initialScore), @"best_score":@(matches.firstObject.score),
            @"score_description":@"Relative spectral/dynamics distance in dB; lower is better, not perceptual confidence",
            @"audio_stored":@NO, @"input_rate":@(rate), @"target_rate":@(targetRate)} mutableCopy];
        NSError* cacheError = nil;
        NSString* cachePath = [cacheDirectory stringByAppendingPathComponent:[runID stringByAppendingPathExtension:@"json"]];
        BOOL directoryOK = [NSFileManager.defaultManager createDirectoryAtPath:cacheDirectory withIntermediateDirectories:YES attributes:nil error:&cacheError];
        NSData* json = [NSJSONSerialization dataWithJSONObject:record options:0 error:&cacheError];
        if (directoryOK && json && [json writeToFile:cachePath options:NSDataWritingAtomic error:&cacheError]) record[@"training_file"] = cachePath;
        else report([NSString stringWithFormat:@"Match ready, but training record was not saved: %@", cacheError.localizedDescription ?: @"unknown error"]);
        metadata = record;
        report([NSString stringWithFormat:@"Local training complete: %lu real renders; best feature distance %.2f → %.2f dB. Audition before applying; this is not a guaranteed tone match.",
            (unsigned long)renders, initialScore, matches.firstObject.score]);
      } catch (const std::exception& e) { error = failure(@(e.what())); }
      dispatch_async(dispatch_get_main_queue(), ^{
        self.isRunning = NO;
        if (cancelled->load()) completion(nil, nil, failure(@"Local matching cancelled; live rig unchanged."));
        else completion(error ? nil : matches, metadata, error);
      });
    }
  });
}
@end
