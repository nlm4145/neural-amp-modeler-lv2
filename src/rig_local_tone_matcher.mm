#import "rig_local_tone_matcher.h"
#include "local_tone_post_eq.h"
#include "rig_control_metadata.h"
#include "dsp_accel.h"
#include "wav_ir.h"
#import "rig_ai_support.h"
#include <map>

@implementation RigLocalTonePlan
@end
@implementation RigLocalToneMatch
@end
@interface RigLocalToneMatcher ()
@property(nonatomic, readwrite) BOOL isRunning;
@end

namespace {
using namespace NAMRig;
using namespace NAMRig::LocalTone;
constexpr uint32_t kDrivePort = 22, kOdDrivePort = 179, kOdEnabledPort = 185, kPowerPort = 74;
// Up to kMaxAmps amps get a quick screen (short excerpt, reduced oversampling);
// the current amp plus the best kFullAmps - 1 continue at full quality.
constexpr size_t kMaxAmps = 24, kFullAmps = 4, kMaxCabs = 400, kShortlist = 3, kMaxPedals = 2;
// Engine renders spent searching nonlinear controls (amp-only renders); the
// initial amp renders and finalist verification are extra.
constexpr size_t kSearchBudget = 20;

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
BOOL isWav(NSString* path) { return [path.pathExtension.lowercaseString isEqualToString:@"wav"]; }
double clampToContract(uint32_t port, double value) {
  const auto* c = rigControlContract(port);
  return c ? std::clamp(value, double(c->minimum), double(c->maximum)) : value;
}
NSString* symbol(uint32_t port) { return @(rigControlSymbol(port)); }

// Keep the raw amplitude; take up to three non-overlapping 1.5-second windows,
// loudest first, so one riff section (or the guided recording's muted-string
// pre-roll) cannot dominate. Returned in chronological order.
struct Span { size_t start, count; };
std::vector<Span> excerpts(NSData* data, double rate, size_t channels) {
  const auto* samples = static_cast<const float*>(data.bytes);
  const size_t frames = data.length / (channels * sizeof(float));
  const size_t count = std::min(frames, size_t(rate * 1.5));
  if (frames <= count) return {{0, frames}};
  std::vector<double> prefix(frames + 1, 0);
  for (size_t f = 0; f < frames; ++f) {
    double e = 0;
    for (size_t c = 0; c < channels; ++c) e += double(samples[f * channels + c]) * samples[f * channels + c];
    prefix[f + 1] = prefix[f] + e;
  }
  std::vector<std::pair<double, size_t>> windows;
  const size_t hop = std::max<size_t>(1, size_t(rate * .05));
  for (size_t start = 0; start + count <= frames; start += hop) windows.emplace_back(prefix[start + count] - prefix[start], start);
  windows.emplace_back(prefix[frames] - prefix[frames - count], frames - count);
  std::sort(windows.begin(), windows.end(), [](const auto& x, const auto& y) { return x.first > y.first; });
  std::vector<Span> chosen;
  for (const auto& [energy, start] : windows) {
    if (chosen.size() == 3 || energy < windows.front().first * .25) break;
    bool overlaps = false;
    for (const auto& span : chosen) overlaps |= start < span.start + span.count && span.start < start + count;
    if (!overlaps) chosen.push_back({start, count});
  }
  std::sort(chosen.begin(), chosen.end(), [](const Span& x, const Span& y) { return x.start < y.start; });
  return chosen;
}
Measurement measureSpans(const float* audio, size_t channels, const std::vector<Span>& spans, double rate) {
  std::vector<Measurement> parts;
  for (const Span& span : spans) parts.push_back(measure(audio + span.start * channels, span.count, channels, rate));
  return average(parts);
}

// FFT overlap-add convolution (Accelerate via DSP::RealFFT); output has x's length.
std::vector<float> convolve(const std::vector<float>& x, const std::vector<float>& h) {
  size_t block = 256;
  while (block < h.size()) block <<= 1;
  const size_t n = 2 * block, bins = block;
  DSP::RealFFT fft(n);
  std::vector<float> time(n, 0), hRe(bins), hIm(bins), xRe(bins), xIm(bins), yRe(bins), yIm(bins), out(x.size(), 0);
  std::copy(h.begin(), h.end(), time.begin());
  fft.forward(time.data(), hRe.data(), hIm.data());
  const float hNyquist = hIm[0]; hIm[0] = 0; // Packed format: im[0] holds the real Nyquist bin.
  // Scale is irrelevant to the level-invariant features; tests pin it anyway.
  const float scale = fft.roundTripScale() * 2;
  for (size_t start = 0; start < x.size(); start += block) {
    const size_t m = std::min(block, x.size() - start);
    std::fill(time.begin(), time.end(), 0.f);
    std::copy(x.begin() + start, x.begin() + start + m, time.begin());
    fft.forward(time.data(), xRe.data(), xIm.data());
    const float xNyquist = xIm[0]; xIm[0] = 0;
    std::fill(yRe.begin(), yRe.end(), 0.f); std::fill(yIm.begin(), yIm.end(), 0.f);
    DSP::zvma(xRe.data(), xIm.data(), hRe.data(), hIm.data(), yRe.data(), yIm.data(), bins);
    yIm[0] = xNyquist * hNyquist;
    fft.inverse(yRe.data(), yIm.data(), time.data());
    for (size_t i = 0; i < n && start + i < out.size(); ++i) out[start + i] += time[i] * scale;
  }
  return out;
}

struct Cab { NSString* path; std::vector<float> left, right; };
using Controls = std::map<uint32_t, double>;

// The span regions plus a pre-roll (longer than the cab IR and IIR settling),
// packed back to back so convolution and EQ only touch what is measured.
struct Compact { std::vector<float> audio; std::vector<Span> spans; };
Compact compactMono(const float* stereo, size_t frames, const std::vector<Span>& spans, size_t preroll) {
  Compact c;
  for (const Span& span : spans) {
    const size_t from = span.start >= preroll ? span.start - preroll : 0;
    c.spans.push_back({c.audio.size() + (span.start - from), span.count});
    for (size_t f = from; f < span.start + span.count && f < frames; ++f) c.audio.push_back(stereo[f * 2]);
  }
  return c;
}

// One amp-side configuration rendered with the cab off and a neutral post EQ.
struct Evaluation {
  size_t amp = 0;
  size_t pedal = SIZE_MAX; // Index into plan.pedals, or the base pedal (unchanged)
  Controls controls;
  Compact pre;          // Mono pre-cab signal
  double score = 1e300; // Best verified offline score over the cab shortlist (mix EQ allowed)
  size_t cab = SIZE_MAX;
};
// Verified offline fits for one evaluation + cab: tone stack/cuts only, and the
// joint fit with Console-pin mix EQ (equal to `tone` when pins do not help).
struct Fits { LinearFit tone, mixed; };
struct Candidate { size_t evaluation, cab; Fits fits; };
bool sameControls(const Controls& a, const Controls& b) {
  if (a.size() != b.size()) return false;
  for (const auto& [port, value] : a) if (!b.count(port) || std::fabs(b.at(port) - value) > 1e-3) return false;
  return true;
}
} // namespace

RigLocalTonePlan* rigLocalTonePlan(RigPreset* base, NSArray<NSDictionary*>* catalog, NSString* root) {
  RigPreset* dry = clone(base);
  // Match the core guitar sound, not reverb/delay/mastering. Retain calibrated
  // input, oversampling and any selected pedal/OD; do not normalize the DI.
  for (uint32_t port : {33u, 53u, 54u, 71u, 72u, 73u, 74u, 76u, 77u, 79u, 184u, 189u}) [dry setControl:port value:0];
  [dry setControl:15 value:-80]; [dry setControl:30 value:0]; [dry setControl:42 value:0]; [dry setControl:80 value:0];
  // The linear post section is solved offline, so renders keep it neutral.
  [dry setControl:kBassPort value:0]; [dry setControl:kMidPort value:0]; [dry setControl:kTreblePort value:0];
  [dry setControl:kLowCutPort value:0]; [dry setControl:kHighCutPort value:20000];
  [dry setControl:kConsolePort value:1]; // Cab cuts need the console rack.
  for (size_t band = 0; band < kPinEqBandCount; ++band) [dry setControl:pinEqPort(PinEqPane::CabConsole, band, kPinGain) value:0];
  [dry setControl:47 value:0]; [dry stageAtIndex:3]->path.clear(); [dry stageAtIndex:3]->models.clear();
  NSString* currentAmp = @([dry stageAtIndex:1]->path.c_str());
  NSString* currentCab = @([dry stageAtIndex:2]->path.c_str());
  [dry stageAtIndex:2]->path.clear(); [dry stageAtIndex:2]->models.clear(); [dry setControl:9 value:0];
  dry.slotPresets = [NSMutableDictionary dictionary]; dry.speakerProfile = 0;

  NSMutableArray<NSString*>* amps = [NSMutableArray array];
  NSMutableArray<NSString*>* cabs = [NSMutableArray array];
  // One capture per profile (same folder + name without size/architecture words).
  NSMutableSet<NSString*>* profiles = [NSMutableSet set];
  auto profile = [](NSString* path) {
    return [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:rigAIProfileKey(path.lastPathComponent)];
  };
  if (currentAmp.length) { [amps addObject:currentAmp]; [profiles addObject:profile(currentAmp)]; }
  if (isWav(currentCab) && [NSFileManager.defaultManager fileExistsAtPath:currentCab]) [cabs addObject:currentCab];
  for (NSDictionary* item in catalog) {
    NSUInteger stage = [item[@"stage"] unsignedIntegerValue];
    if (stage != 1 && stage != 2) continue;
    NSString* relative = item[@"path"];
    if (stage == 1) relative = rigAIHighestCapacityVariant(root, relative, 1, nullptr, nullptr) ?: relative;
    NSString* path = rigAIResolveModel(root, relative, stage, nil);
    if (!path.length) continue;
    if (stage == 1 && amps.count < kMaxAmps && ![profiles containsObject:profile(path)]) {
      [amps addObject:path]; [profiles addObject:profile(path)];
    }
    if (stage == 2 && isWav(path) && cabs.count < kMaxCabs && ![cabs containsObject:path]) [cabs addObject:path];
  }
  NSString* cabRoot = [root stringByAppendingPathComponent:@"Cab"];
  NSDirectoryEnumerator* walk = [NSFileManager.defaultManager enumeratorAtPath:cabRoot];
  for (NSString* relative; cabs.count < kMaxCabs && (relative = [walk nextObject]);) {
    NSString* path = [cabRoot stringByAppendingPathComponent:relative];
    if (isWav(path) && ![cabs containsObject:path]) [cabs addObject:path];
  }
  RigLocalTonePlan* plan = [RigLocalTonePlan new];
  plan.base = dry; plan.amps = amps; plan.cabs = cabs;
  plan.currentCab = isWav(currentCab) ? currentCab : @"";
  return plan;
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
          plan:(RigLocalTonePlan*)plan renderer:(RigRiffRenderHandler)renderer
cacheDirectory:(NSString*)cacheDirectory progress:(void (^)(NSString*))progress
    completion:(void (^)(NSArray<RigLocalToneMatch*>*, NSDictionary*, NSError*))completion {
  NSAssert(NSThread.isMainThread, @"Freeze local matcher inputs on main thread");
  if (self.isRunning || !renderer || !plan.base || !plan.amps.count || plan.amps.count > kMaxAmps ||
      !std::isfinite(rate) || rate < 22050 || rate > 192000 ||
      !std::isfinite(targetRate) || targetRate < 22050 || targetRate > 192000 ||
      (channels != 1 && channels != 2) || di.length % sizeof(float) ||
      target.length % (channels * sizeof(float)) || di.length < rate * .25 * sizeof(float) ||
      target.length < targetRate * .25 * channels * sizeof(float) ||
      di.length > rate * 20 * sizeof(float) || target.length > targetRate * 20 * channels * sizeof(float)) {
    completion(nil, nil, failure(@"Local matching needs a paired DI take, an isolated target, and 1–8 candidate amps. A match must not already be running.")); return;
  }
  RigPreset* base = clone(plan.base);
  NSArray<NSString*>* amps = [plan.amps copy];
  NSArray<NSString*>* pedals = [plan.pedals subarrayWithRange:NSMakeRange(0, std::min<NSUInteger>(plan.pedals.count, kMaxPedals))] ?: @[];
  const BOOL preferOverdrive = plan.preferOverdrive;
  NSArray<NSString*>* cabPaths = [plan.cabs copy] ?: @[];
  NSString* currentCab = [plan.currentCab copy] ?: @"";
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
      size_t renders = 0;
      try {
        auto checkCancel = [&] { if (cancelled->load()) throw std::runtime_error("Local matching cancelled; live rig unchanged."); };
        checkCancel();
        // Validate all raw samples before choosing excerpts, including input clipping.
        Measurement input = measure(static_cast<const float*>(di.bytes), di.length / sizeof(float), 1, rate);
        if (input.peak >= 1) throw std::runtime_error("Raw DI reaches full scale. Lower interface input gain and record an unclipped take before local training.");
        measure(static_cast<const float*>(target.bytes), target.length / (channels * sizeof(float)), channels, targetRate);
        // DI excerpts are joined with 250 ms of silence (longer than the cab IR
        // tail) so each candidate needs a single render; each is measured alone.
        std::vector<Span> renderSpans;
        NSMutableData* joined = [NSMutableData data];
        const size_t gap = size_t(rate * .25), preroll = size_t(rate * .2);
        for (const Span& span : excerpts(di, rate, 1)) {
          if (joined.length) [joined increaseLengthBy:gap * sizeof(float)];
          renderSpans.push_back({joined.length / sizeof(float), span.count});
          [joined appendBytes:static_cast<const float*>(di.bytes) + span.start length:span.count * sizeof(float)];
        }
        NSData* dry = joined;
        const size_t renderFrames = dry.length / sizeof(float);
        std::vector<Measurement> goals;
        const auto* targetSamples = static_cast<const float*>(target.bytes);
        const std::vector<Span> targetSpans = excerpts(target, targetRate, channels);
        for (const Span& span : targetSpans)
          goals.push_back(measure(targetSamples + span.start * channels, span.count, channels, targetRate));
        const Measurement goal = average(goals);

        auto renderInput = [&](RigPreset* p, NSData* input) -> NSData* {
          checkCancel(); ++renders;
          NSError* renderError = nil; NSData* audio = renderer(p, input, rate, &renderError);
          checkCancel();
          if (renderError || audio.length < input.length * 2 || audio.length % (2 * sizeof(float)))
            throw std::runtime_error((renderError.localizedDescription ?: @"Renderer returned an incomplete candidate.").UTF8String);
          return audio;
        };
        auto render = [&](RigPreset* p) { return renderInput(p, dry); };
        std::vector<bool> fullRig;
        for (NSString* amp in amps) fullRig.push_back(rigAIModelIncludesCab(amp));
        // Amp-only preset: the cab stage off, so the render is the exact pre-cab signal.
        auto ampPreset = [&](size_t amp, const Controls& controls, size_t pedal) {
          RigPreset* p = clone(base);
          if (pedal != SIZE_MAX) {
            [p stageAtIndex:0]->path = pedals[pedal].fileSystemRepresentation;
            [p stageAtIndex:0]->models.clear(); [p stageAtIndex:0]->imageURL.clear(); [p stageAtIndex:0]->toneId = 0;
            [p setControl:7 value:1];
          }
          [p stageAtIndex:1]->path = amps[amp].fileSystemRepresentation;
          [p stageAtIndex:1]->models.clear(); [p stageAtIndex:1]->imageURL.clear(); [p stageAtIndex:1]->toneId = 0;
          [p stageAtIndex:2]->path.clear(); [p stageAtIndex:2]->models.clear();
          [p setControl:8 value:1]; [p setControl:9 value:0];
          for (const auto& [port, value] : controls) [p setControl:port value:clampToContract(port, value)];
          const uint32_t enables[] = {7, 8, 9, 47};
          for (size_t s = 0; s < 4; ++s) {
            if ([p stageAtIndex:s]->path.empty()) [p setControl:enables[s] value:0];
            [p stageAtIndex:s]->enabled = [p controlForPort:enables[s]] >= .5;
          }
          return p;
        };

        // ── Cab IRs at the render rate (the engine's exact taps) ──────────
        std::vector<Cab> cabs;
        for (NSString* path in cabPaths) {
          checkCancel();
          try {
            const char* file = path.fileSystemRepresentation;
            const bool stereo = WavIR::channelCount(file) >= 2;
            Cab cab{path, WavIR::loadTaps(file, rate, stereo ? 0 : -1), {}};
            if (stereo) cab.right = WavIR::loadTaps(file, rate, 1);
            cabs.push_back(std::move(cab));
          } catch (const std::exception& e) {
            report([NSString stringWithFormat:@"Skipping cab %@: %s", path.lastPathComponent, e.what()]);
          }
        }
        if (cabs.empty() && std::find(fullRig.begin(), fullRig.end(), true) == fullRig.end())
          throw std::runtime_error("No usable cab IRs (WAV) found. Install a cab IR or choose an amp capture that includes its cab.");

        // Cab-processed span audio for an evaluation (mono, or stereo interleaved
        // for stereo IRs); the pre-cab signal itself for full-rig captures.
        auto cabbed = [&](const Evaluation& e, size_t cab, size_t& outChannels) {
          outChannels = 1;
          if (cab == SIZE_MAX) return e.pre.audio;
          const Cab& c = cabs[cab];
          std::vector<float> left = convolve(e.pre.audio, c.left);
          if (c.right.empty()) return left;
          std::vector<float> right = convolve(e.pre.audio, c.right), stereo(left.size() * 2);
          for (size_t i = 0; i < left.size(); ++i) { stereo[i * 2] = left[i]; stereo[i * 2 + 1] = right[i]; }
          outChannels = 2; return stereo;
        };
        // Cuts and Console pins only run when a cab IR was processed.
        auto fixedEq = [&](size_t cab) { PostEq eq; eq.console = cab != SIZE_MAX; return eq; };
        // Verified offline fits of the linear post section for one evaluation + cab.
        // Mix EQ is part of the search objective so gear and drive are not bent to
        // imitate the target mix's EQ (pins only exist when a cab is processed).
        auto verifiedFit = [&](const Evaluation& e, size_t cab) {
          size_t ch = 1; const std::vector<float> audio = cabbed(e, cab, ch);
          const Measurement neutral = measureSpans(audio.data(), ch, e.pre.spans, rate);
          auto measureWith = [&](const PostEq& eq) {
            std::vector<float> y = audio; applyPostEq(eq, y.data(), y.size() / ch, ch, rate);
            return measureSpans(y.data(), ch, e.pre.spans, rate).features;
          };
          Fits fits;
          fits.tone = fitLinear(neutral.features, goal.features, rate, fixedEq(cab), measureWith);
          fits.mixed = fitMixEq(fits.tone, goal.features, rate, measureWith, 2);
          return fits;
        };
        // Predicted (one-shot) score of every cab, in parallel; best first.
        auto screen = [&](const Evaluation& evaluation) {
          std::vector<std::pair<double, size_t>> scores(cabs.size(), {1e300, 0});
          auto* out = scores.data();
          const Evaluation* e = &evaluation; // Blocks capture the pointer, not a C++ reference.
          dispatch_apply(cabs.size(), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t i) {
            out[i] = {1e300, i};
            if (cancelled->load()) return;
            try {
              size_t ch = 1; const std::vector<float> audio = cabbed(*e, i, ch);
              const Measurement m = measureSpans(audio.data(), ch, e->pre.spans, rate);
              out[i].first = solveLinear(m.features, goal.features, rate, fixedEq(i)).score;
            } catch (...) {}
          });
          checkCancel();
          std::sort(scores.begin(), scores.end());
          return scores;
        };

        std::vector<Evaluation> evaluations;
        std::map<size_t, std::vector<size_t>> shortlist; // amp -> cabs
        std::vector<Candidate> candidates;
        // Score an evaluation over its amp's cab shortlist (verified fits, in parallel).
        auto scoreEvaluation = [&](size_t index) {
          const Evaluation* e = &evaluations[index];
          const std::vector<size_t> cabsToFit = fullRig[e->amp] ? std::vector<size_t>{SIZE_MAX} : shortlist[e->amp];
          std::vector<Fits> fits(cabsToFit.size());
          auto* out = fits.data(); const auto* which = cabsToFit.data();
          dispatch_apply(cabsToFit.size(), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t i) {
            out[i].tone.score = out[i].mixed.score = 1e300;
            if (cancelled->load()) return;
            try { out[i] = verifiedFit(*e, which[i]); } catch (...) {}
          });
          checkCancel();
          Evaluation& stored = evaluations[index];
          for (size_t i = 0; i < cabsToFit.size(); ++i) {
            candidates.push_back({index, cabsToFit[i], fits[i]});
            if (fits[i].mixed.score < stored.score) { stored.score = fits[i].mixed.score; stored.cab = cabsToFit[i]; }
          }
        };
        auto renderEvaluation = [&](size_t amp, const Controls& controls, size_t pedal) {
          Evaluation e; e.amp = amp; e.pedal = pedal;
          for (const auto& [port, value] : controls) e.controls[port] = clampToContract(port, value);
          NSData* audio = render(ampPreset(amp, e.controls, pedal));
          e.pre = compactMono(static_cast<const float*>(audio.bytes), audio.length / (2 * sizeof(float)), renderSpans, preroll);
          evaluations.push_back(std::move(e));
          return evaluations.size() - 1;
        };
        // Cached: identical settings are never rendered twice.
        auto evaluateWith = [&](size_t amp, const Controls& controls, size_t pedal) -> double {
          Controls clamped;
          for (const auto& [port, value] : controls) clamped[port] = clampToContract(port, value);
          for (const auto& e : evaluations) if (e.amp == amp && e.pedal == pedal && sameControls(e.controls, clamped)) return e.score;
          const size_t index = renderEvaluation(amp, clamped, pedal);
          scoreEvaluation(index);
          return evaluations[index].score;
        };
        auto evaluate = [&](size_t amp, const Controls& controls) { return evaluateWith(amp, controls, SIZE_MAX); };

        report([NSString stringWithFormat:@"LOCAL MATCH — %lu amp(s) × %lu cab IR(s). Each amp is rendered with the cab off; every cab and the tone stack are fitted offline. Live rig unchanged; no audio uploaded.",
            (unsigned long)amps.count, (unsigned long)cabs.size()]);
        const Controls baseControls = {{kDrivePort, [base controlForPort:kDrivePort]}};
        double initialScore = -1;
        NSMutableArray* screening = [NSMutableArray array];
        NSMutableArray* quickScreening = [NSMutableArray array];
        // ── 0. Quick amp screen: one 0.75 s excerpt (plus pre-roll) at ≤ True 2x,
        // every cab scored one-shot. Keeps the current amp plus the best others.
        std::vector<size_t> fullAmps;
        size_t quickRenders = 0;
        if (amps.count <= kFullAmps) {
          for (size_t a = 0; a < amps.count; ++a) fullAmps.push_back(a);
        } else {
          const Span& loudest = renderSpans[renderSpans.size() / 2];
          const size_t count = std::min(loudest.count, size_t(rate * .75));
          const size_t start = loudest.start + (loudest.count - count) / 2, from = start >= preroll ? start - preroll : 0;
          NSData* quick = [dry subdataWithRange:NSMakeRange(from * sizeof(float), (start - from + count) * sizeof(float))];
          const std::vector<Span> quickSpans{{start - from, count}};
          report([NSString stringWithFormat:@"Quick screen: %lu amps on a short excerpt at reduced oversampling…", (unsigned long)amps.count]);
          std::vector<std::pair<double, size_t>> quickScores;
          for (size_t a = 0; a < amps.count; ++a) {
            checkCancel();
            try {
              RigPreset* p = ampPreset(a, baseControls, SIZE_MAX);
              for (uint32_t port : {20u, 21u}) if ([p controlForPort:port] > 4) [p setControl:port value:4]; // True 2x
              const size_t before = renders;
              NSData* audio = renderInput(p, quick);
              quickRenders += renders - before;
              Evaluation probe; probe.amp = a;
              probe.pre = compactMono(static_cast<const float*>(audio.bytes), audio.length / (2 * sizeof(float)), quickSpans, 0);
              double score = 1e300;
              if (fullRig[a]) score = solveLinear(measureSpans(probe.pre.audio.data(), 1, probe.pre.spans, rate).features,
                                                  goal.features, rate, fixedEq(SIZE_MAX)).score;
              else if (!cabs.empty()) score = screen(probe).front().first;
              quickScores.push_back({score, a});
              [quickScreening addObject:@{@"amp":amps[a], @"score":@(score < 1e299 ? score : -1)}];
            } catch (const std::exception& ex) {
              checkCancel(); report([NSString stringWithFormat:@"Skipping amp %@: %s", amps[a].lastPathComponent, ex.what()]);
            }
          }
          std::sort(quickScores.begin(), quickScores.end());
          fullAmps.push_back(0); // The current amp is always the starting point.
          for (const auto& [score, a] : quickScores) {
            if (fullAmps.size() >= kFullAmps || score > 1e299) break;
            if (a != 0) fullAmps.push_back(a);
          }
          NSMutableArray* names = [NSMutableArray array];
          for (size_t i = 1; i < fullAmps.size(); ++i) [names addObject:amps[fullAmps[i]].lastPathComponent];
          report([NSString stringWithFormat:@"Quick screen kept: %@", [names componentsJoinedByString:@", "]]);
        }
        // ── 1. Full-quality amp renders + full offline cab screen ──────────
        for (size_t a : fullAmps) {
          checkCancel();
          report([NSString stringWithFormat:@"Rendering amp %@…", amps[a].lastPathComponent]);
          try {
            const size_t index = renderEvaluation(a, baseControls, SIZE_MAX);
            if (!fullRig[a]) {
              const auto ranked = screen(evaluations[index]);
              for (size_t i = 0; i < std::min(kShortlist, ranked.size()); ++i)
                if (ranked[i].first < 1e299) shortlist[a].push_back(ranked[i].second);
              if (shortlist[a].empty()) { report([NSString stringWithFormat:@"Skipping amp %@: no cab could be scored.", amps[a].lastPathComponent]); continue; }
            }
            if (a == 0) {
              // Starting point: current gear (current cab when it is an IR) with a neutral tone stack.
              size_t cab = fullRig[a] ? SIZE_MAX : shortlist[a].front();
              if (!fullRig[a] && currentCab.length)
                for (size_t i = 0; i < cabs.size(); ++i) if ([cabs[i].path isEqualToString:currentCab]) cab = i;
              size_t ch = 1; const std::vector<float> neutral = cabbed(evaluations[index], cab, ch);
              initialScore = distance(measureSpans(neutral.data(), ch, evaluations[index].pre.spans, rate).features, goal.features);
            }
            scoreEvaluation(index);
            const Evaluation& e = evaluations[index];
            [screening addObject:@{@"amp":amps[a], @"best_cab":e.cab == SIZE_MAX ? @"" : cabs[e.cab].path, @"score":@(e.score)}];
            report([NSString stringWithFormat:@"  %@ → %@: %.2f dB after tone-stack fit", amps[a].lastPathComponent,
                e.cab == SIZE_MAX ? @"captured cab" : cabs[e.cab].path.lastPathComponent, e.score]);
          } catch (const std::exception& ex) {
            checkCancel(); report([NSString stringWithFormat:@"Skipping amp %@: %s", amps[a].lastPathComponent, ex.what()]);
          }
        }
        std::vector<size_t> ampOrder;
        for (const auto& e : evaluations) if (e.score < 1e299) ampOrder.push_back(e.amp);
        if (ampOrder.empty()) throw std::runtime_error("No candidate amp rendered successfully. Check the installed models.");
        auto bestScore = [&](size_t amp) {
          double best = 1e300;
          for (const auto& e : evaluations) if (e.amp == amp) best = std::min(best, e.score);
          return best;
        };
        std::sort(ampOrder.begin(), ampOrder.end(), [&](size_t x, size_t y) { return bestScore(x) < bestScore(y); });
        if (initialScore < 0) initialScore = bestScore(0) < 1e299 ? bestScore(0) : bestScore(ampOrder.front());

        // ── 2. Nonlinear search with real amp renders ───────────────────────
        const size_t searchStart = renders;
        auto budgetLeft = [&] { return renders - searchStart < kSearchBudget; };
        struct Dim { uint32_t port; double step; };
        // Best evaluation of `amp` whose control set matches `like` outside `dims`.
        auto comparable = [&](const Evaluation& e, size_t amp, const Controls& like, const std::vector<Dim>& dims) {
          if (e.amp != amp || e.pedal != SIZE_MAX || e.score > 1e299 || e.controls.size() != like.size()) return false;
          for (const auto& [port, value] : like) {
            if (!e.controls.count(port)) return false;
            bool searched = false;
            for (const Dim& d : dims) searched |= d.port == port;
            if (!searched && std::fabs(e.controls.at(port) - value) > 1e-3) return false;
          }
          return true;
        };
        // Trust-region rounds: probe ±r per dimension, fit a quadratic (in step
        // units) to every comparable evaluation, render its predicted minimum,
        // re-center on the best real evaluation, shrink r.
        auto search = [&](size_t amp, Controls center, const std::vector<Dim>& dims, const std::vector<double>& radii) {
          const size_t d = dims.size(), terms = 1 + 2 * d + (d == 2 ? 1 : 0);
          for (double r : radii) {
            std::vector<Controls> probes;
            for (const Dim& dim : dims) for (double sign : {-1.0, 1.0}) {
              Controls c = center; c[dim.port] += sign * r * dim.step; probes.push_back(c);
            }
            if (d == 2) { Controls c = center; for (const Dim& dim : dims) c[dim.port] += .7 * r * dim.step; probes.push_back(c); }
            for (const Controls& c : probes) { if (!budgetLeft()) return; evaluate(amp, c); }
            auto basis = [&](const Controls& c) {
              std::vector<double> phi{1};
              for (const Dim& dim : dims) { const double x = (c.at(dim.port) - center.at(dim.port)) / dim.step; phi.push_back(x); phi.push_back(x * x); }
              if (d == 2) phi.push_back((c.at(dims[0].port) - center.at(dims[0].port)) / dims[0].step *
                                        (c.at(dims[1].port) - center.at(dims[1].port)) / dims[1].step);
              return phi;
            };
            std::vector<std::vector<double>> system(terms, std::vector<double>(terms + 1, 0));
            size_t points = 0;
            for (const auto& e : evaluations) {
              if (!comparable(e, amp, center, dims)) continue;
              const auto phi = basis(e.controls); ++points;
              for (size_t i = 0; i < terms; ++i) {
                for (size_t j = 0; j < terms; ++j) system[i][j] += phi[i] * phi[j];
                system[i][terms] += phi[i] * e.score;
              }
            }
            bool solved = points >= terms;
            for (size_t i = 1; i < terms && solved; ++i) system[i][i] += 1e-3;
            for (size_t col = 0; col < terms && solved; ++col) {
              size_t pivot = col;
              for (size_t row = col + 1; row < terms; ++row) if (std::fabs(system[row][col]) > std::fabs(system[pivot][col])) pivot = row;
              std::swap(system[col], system[pivot]);
              if (std::fabs(system[col][col]) < 1e-12) { solved = false; break; }
              const double div = system[col][col];
              for (double& v : system[col]) v /= div;
              for (size_t row = 0; row < terms; ++row) if (row != col) {
                const double factor = system[row][col];
                for (size_t j = 0; j <= terms; ++j) system[row][j] -= factor * system[col][j];
              }
            }
            if (solved && budgetLeft()) {
              Controls bestPoint = center; double bestValue = 1e300;
              const int steps = d == 1 ? 40 : 20;
              for (int i = 0; i <= steps; ++i) for (int j = 0; j <= (d == 2 ? steps : 0); ++j) {
                Controls c = center;
                c[dims[0].port] = clampToContract(dims[0].port, center[dims[0].port] + (2.0 * i / steps - 1) * r * dims[0].step);
                if (d == 2) c[dims[1].port] = clampToContract(dims[1].port, center[dims[1].port] + (2.0 * j / steps - 1) * r * dims[1].step);
                const auto phi = basis(c); double value = 0;
                for (size_t t = 0; t < terms; ++t) value += phi[t] * system[t][terms];
                if (value < bestValue) { bestValue = value; bestPoint = c; }
              }
              evaluate(amp, bestPoint);
            }
            double centerScore = 1e300;
            for (const auto& e : evaluations)
              if (comparable(e, amp, center, dims) && e.score < centerScore) { centerScore = e.score; center = e.controls; }
            report([NSString stringWithFormat:@"  search ±%.0f dB: %@ drive %+.1f dB → %.2f dB", r * dims[0].step,
                amps[amp].lastPathComponent, center[kDrivePort], centerScore]);
          }
        };
        auto bestControls = [&](size_t amp, const Controls& like) {
          const Evaluation* best = nullptr;
          for (const auto& e : evaluations)
            if (e.amp == amp && e.pedal == SIZE_MAX && e.score < 1e299 && e.controls.size() == like.size() &&
                (!best || e.score < best->score)) best = &e;
          return best ? best->controls : like;
        };
        report(@"Searching gain staging with real amp renders (offline cab + tone-stack fit per render)…");
        for (size_t rank = 0; rank < std::min<size_t>(2, ampOrder.size()); ++rank) {
          const size_t amp = ampOrder[rank];
          search(amp, bestControls(amp, baseControls), {{kDrivePort, 6}}, rank == 0 ? std::vector<double>{1, .5, .25} : std::vector<double>{1});
        }
        // Discrete options on the leading amp: an overdrive push, and the power stage.
        if (budgetLeft()) {
          const size_t amp = ampOrder.front();
          const Controls best = bestControls(amp, baseControls);
          const double before = evaluate(amp, best);
          const BOOL odActive = [base controlForPort:kOdEnabledPort] >= .5 && [base controlForPort:kOdDrivePort] > 0;
          Controls od = best; od[kOdEnabledPort] = 1; od[kOdDrivePort] = odActive ? [base controlForPort:kOdDrivePort] : 40;
          const double withOd = evaluate(amp, od);
          report([NSString stringWithFormat:@"  overdrive %@: %.2f → %.2f dB", odActive ? @"(kept)" : @"push", before, withOd]);
          // Research that documents an overdrive/boost earns the OD search even if the plain push lost.
          if ((withOd < before || odActive || preferOverdrive) && budgetLeft()) search(amp, od, {{kDrivePort, 6}, {kOdDrivePort, 20}}, {.5});
          if (budgetLeft()) {
            Controls power = best; power[kPowerPort] = 1;
            report([NSString stringWithFormat:@"  power stage (defaults): %.2f → %.2f dB", before, evaluate(amp, power)]);
          }
          for (size_t pedal = 0; pedal < pedals.count && budgetLeft(); ++pedal) {
            try {
              report([NSString stringWithFormat:@"  pedal %@: %.2f → %.2f dB", pedals[pedal].lastPathComponent, before, evaluateWith(amp, best, pedal)]);
            } catch (const std::exception& ex) {
              checkCancel(); report([NSString stringWithFormat:@"  Skipping pedal %@: %s", pedals[pedal].lastPathComponent, ex.what()]);
            }
          }
        }

        // ── 3. Re-screen every cab on the two best renders ─────────────────
        std::vector<size_t> order;
        for (size_t i = 0; i < evaluations.size(); ++i) if (evaluations[i].score < 1e299) order.push_back(i);
        std::sort(order.begin(), order.end(), [&](size_t x, size_t y) { return evaluations[x].score < evaluations[y].score; });
        for (size_t k = 0; k < std::min<size_t>(2, order.size()); ++k) {
          const size_t index = order[k];
          if (fullRig[evaluations[index].amp]) continue;
          const auto ranked = screen(evaluations[index]);
          for (size_t i = 0; i < std::min(kShortlist, ranked.size()); ++i) {
            const size_t cab = ranked[i].second;
            bool known = false;
            for (const auto& c : candidates) known |= c.evaluation == index && c.cab == cab;
            if (!known && ranked[i].first < 1e299) candidates.push_back({index, cab, verifiedFit(evaluations[index], cab)});
          }
        }
        checkCancel();

        // ── 4. Finalists: distinct gear, verified by full engine renders ───
        std::sort(candidates.begin(), candidates.end(), [](const Candidate& x, const Candidate& y) { return x.fits.mixed.score < y.fits.mixed.score; });
        std::vector<Candidate> finalists;
        for (const Candidate& c : candidates) {
          if (c.fits.mixed.score > 1e299) break;
          bool duplicate = false;
          for (const Candidate& f : finalists)
            duplicate |= evaluations[f.evaluation].amp == evaluations[c.evaluation].amp && f.cab == c.cab;
          if (!duplicate) finalists.push_back(c);
          if (finalists.size() == 3) break;
        }
        const size_t searchRenders = renders - searchStart;
        report([NSString stringWithFormat:@"Verifying %lu finalist(s) with full engine renders…", (unsigned long)finalists.size()]);
        auto measureReal = [&](RigPreset* preset) {
          NSData* audio = render(preset);
          const auto* rendered = static_cast<const float*>(audio.bytes);
          Measurement m = measureSpans(rendered, 2, renderSpans, rate);
          for (size_t i = 0; i < renderFrames * 2; ++i) m.peak = std::max(m.peak, double(std::fabs(rendered[i])));
          return m;
        };
        // Real render plus measured output-headroom correction (which cannot
        // improve the loudness-invariant score).
        auto verify = [&](RigPreset* preset) {
          Measurement m = measureReal(preset);
          if (m.peak > .85) {
            const double output = [preset controlForPort:5] + 20 * std::log10(.85 / m.peak);
            [preset setControl:5 value:std::max(-20.0, output)];
            m = measureReal(preset);
            if (m.peak >= 1) throw std::runtime_error("Candidate cannot reach safe output headroom within the control range.");
          }
          return m;
        };
        size_t mixKept = 0;
        NSMutableArray* finalistJSON = [NSMutableArray array];
        for (const Candidate& c : finalists) {
          const Evaluation& e = evaluations[c.evaluation];
          const BOOL hasCab = c.cab != SIZE_MAX;
          auto build = [&](const PostEq& eq) {
            RigPreset* p = ampPreset(e.amp, e.controls, e.pedal);
            if (hasCab) {
              [p stageAtIndex:2]->path = cabs[c.cab].path.fileSystemRepresentation;
              [p setControl:9 value:1]; [p stageAtIndex:2]->enabled = true;
            }
            [p setControl:kBassPort value:clampToContract(kBassPort, eq.bass)];
            [p setControl:kMidPort value:clampToContract(kMidPort, eq.mid)];
            [p setControl:kTreblePort value:clampToContract(kTreblePort, eq.treble)];
            [p setControl:kLowCutPort value:clampToContract(kLowCutPort, eq.lowCut)];
            [p setControl:kHighCutPort value:clampToContract(kHighCutPort, eq.highCut)];
            for (size_t band = 0; band < kPinEqBandCount; ++band) {
              const auto& pin = eq.pins[band];
              if (pin.shape == kPinOff) continue;
              [p setControl:pinEqPort(PinEqPane::CabConsole, band, kPinShape) value:pin.shape];
              [p setControl:pinEqPort(PinEqPane::CabConsole, band, kPinFreq) value:pin.freq];
              [p setControl:pinEqPort(PinEqPane::CabConsole, band, kPinGain) value:pin.gainDb];
              [p setControl:pinEqPort(PinEqPane::CabConsole, band, kPinQ) value:pin.q];
            }
            p.name = [NSString stringWithFormat:@"%@%@ + %@", e.pedal == SIZE_MAX ? @"" : [pedals[e.pedal].lastPathComponent stringByAppendingString:@" → "],
                amps[e.amp].lastPathComponent, hasCab ? cabs[c.cab].path.lastPathComponent : @"captured cab"];
            return p;
          };
          // Polish (finalists only, offline): pins and the tone stack overlap, so the
          // search's fit may sit in a far corner of a valley of near-equal fits. Re-fit
          // from a neutral tone stack too and, within 0.02 dB, keep the smaller adjustment.
          Fits fits = c.fits;
          if (hasCab) {
            size_t ch = 1; const std::vector<float> audio = cabbed(e, c.cab, ch);
            auto measureWith = [&](const PostEq& eq) {
              std::vector<float> y = audio; applyPostEq(eq, y.data(), y.size() / ch, ch, rate);
              return measureSpans(y.data(), ch, e.pre.spans, rate).features;
            };
            auto size = [](const PostEq& eq) {
              double sum = eq.bass * eq.bass + eq.mid * eq.mid + eq.treble * eq.treble;
              for (const auto& pin : eq.pins) sum += pin.gainDb * pin.gainDb;
              return sum;
            };
            LinearFit neutral = fits.tone;
            neutral.eq.bass = neutral.eq.mid = neutral.eq.treble = 0;
            neutral.predicted = measureWith(neutral.eq);
            neutral.score = distance(neutral.predicted, goal.features);
            const LinearFit polished = fitMixEq(neutral, goal.features, rate, measureWith, 4);
            const LinearFit& current = fits.mixed;
            if (polished.score < current.score - .02 ||
                (polished.score < current.score + .02 && size(polished.eq) < size(current.eq))) fits.mixed = polished;
          }
          RigPreset* p = build(fits.tone.eq);
          RigLocalToneMatch* match = [RigLocalToneMatch new];
          match.preset = p; match.score = distance(verify(p).features, goal.features); match.offlineScore = fits.tone.score;
          [matches addObject:match];
          // Mix EQ (Console pins, jointly re-fitted with the tone stack): kept only
          // when the real engine render agrees it helps.
          const LinearFit& mix = fits.mixed;
          if (mix.score < fits.tone.score - .02) {
            RigPreset* q = build(mix.eq);
            const double mixed = distance(verify(q).features, goal.features);
            report([NSString stringWithFormat:@"  mix EQ (Console pins %+.1f/%+.1f/%+.1f/%+.1f/%+.1f/%+.1f dB): engine %.2f → %.2f dB%@",
                mix.eq.pins[0].gainDb, mix.eq.pins[1].gainDb, mix.eq.pins[2].gainDb, mix.eq.pins[3].gainDb,
                mix.eq.pins[4].gainDb, mix.eq.pins[5].gainDb, match.score, mixed, mixed < match.score - .01 ? @"" : @" — not kept"]);
            if (mixed < match.score - .01) {
              match.presetWithoutMixEQ = p; match.scoreWithoutMixEQ = match.score;
              match.preset = q; match.score = mixed; match.offlineScore = mix.score; ++mixKept;
            }
          }
          const LinearFit& kept = match.presetWithoutMixEQ ? mix : fits.tone;
          NSMutableDictionary* controls = [NSMutableDictionary dictionary];
          for (const auto& [port, value] : e.controls) controls[symbol(port)] = @(value);
          NSMutableArray* pins = [NSMutableArray array];
          if (match.presetWithoutMixEQ) for (const auto& pin : mix.eq.pins) [pins addObject:@(pin.gainDb)];
          const PostEq& eqKept = kept.eq;
          [finalistJSON addObject:@{@"amp":amps[e.amp], @"cab":hasCab ? cabs[c.cab].path : @"", @"controls":controls,
              @"pedal":e.pedal == SIZE_MAX ? @"" : pedals[e.pedal],
              @"eq":@{@"bass":@(eqKept.bass), @"mid":@(eqKept.mid), @"treble":@(eqKept.treble),
                      @"low_cut":@(eqKept.lowCut), @"high_cut":@(eqKept.highCut)},
              @"mix_eq_pins":pins, @"offline_score":@(match.offlineScore), @"real_score":@(match.score),
              @"score_without_mix_eq":@(match.presetWithoutMixEQ ? match.scoreWithoutMixEQ : match.score)}];
          report([NSString stringWithFormat:@"  %@: offline %.2f dB, engine %.2f dB", match.preset.name, match.offlineScore, match.score]);
        }
        if (!matches.count) throw std::runtime_error("No finalist could be verified.");
        [matches sortUsingComparator:^NSComparisonResult(RigLocalToneMatch* a, RigLocalToneMatch* b) {
          return a.score < b.score ? NSOrderedAscending : a.score > b.score ? NSOrderedDescending : NSOrderedSame;
        }];
        checkCancel();
        NSMutableArray* evaluationsJSON = [NSMutableArray array];
        for (const auto& e : evaluations) {
          NSMutableDictionary* controls = [NSMutableDictionary dictionary];
          for (const auto& [port, value] : e.controls) controls[symbol(port)] = @(value);
          [evaluationsJSON addObject:@{@"amp":amps[e.amp], @"controls":controls, @"pedal":e.pedal == SIZE_MAX ? @"" : pedals[e.pedal],
              @"cab":e.cab == SIZE_MAX ? @"" : cabs[e.cab].path, @"score":@(e.score < 1e299 ? e.score : -1)}];
        }
        NSMutableArray* targetFeatures = [NSMutableArray array];
        for (double v : goal.features) [targetFeatures addObject:@(v)];
        NSString* runID = NSUUID.UUID.UUIDString;
        NSMutableDictionary* record = [@{@"version":@3, @"run_id":runID, @"method":@"local-screen-v1",
            @"feature_version":@(kFeatureVersion), @"di_excerpts":@(renderSpans.size()), @"target_excerpts":@(targetSpans.size()),
            @"created_at":NSDate.date.description, @"render_count":@(renders), @"search_renders":@(searchRenders),
            @"amps_screened":@(amps.count), @"amps_full":@(fullAmps.size()), @"quick_renders":@(quickRenders),
            @"quick_screening":quickScreening, @"mix_eq_kept":@(mixKept), @"pedals_tried":@(pedals.count),
            @"cabs_screened":@(cabs.size()), @"screening":screening,
            @"evaluations":evaluationsJSON, @"finalists":finalistJSON, @"target_features":targetFeatures,
            @"initial_score":@(initialScore), @"best_score":@(matches.firstObject.score),
            @"score_description":@"Relative spectral/texture distance in dB; lower is better, not perceptual confidence",
            @"audio_stored":@NO, @"input_rate":@(rate), @"target_rate":@(targetRate)} mutableCopy];
        NSError* cacheError = nil;
        NSString* cachePath = [cacheDirectory stringByAppendingPathComponent:[runID stringByAppendingPathExtension:@"json"]];
        BOOL directoryOK = [NSFileManager.defaultManager createDirectoryAtPath:cacheDirectory withIntermediateDirectories:YES attributes:nil error:&cacheError];
        NSData* json = [NSJSONSerialization dataWithJSONObject:record options:0 error:&cacheError];
        if (directoryOK && json && [json writeToFile:cachePath options:NSDataWritingAtomic error:&cacheError]) record[@"training_file"] = cachePath;
        else report([NSString stringWithFormat:@"Match ready, but the run record was not saved: %@", cacheError.localizedDescription ?: @"unknown error"]);
        metadata = record;
        report([NSString stringWithFormat:@"Local match complete: %lu engine renders, %lu cab IRs screened offline; feature distance %.2f → %.2f dB. Audition before applying; this is not a guaranteed tone match.",
            (unsigned long)renders, (unsigned long)cabs.size(), initialScore, matches.firstObject.score]);
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
