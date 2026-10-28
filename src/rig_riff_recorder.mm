// Paired DI/output capture. Only fixed-buffer copies and atomics run in CoreAudio.
#import "rig_riff_recorder.h"
#import <AudioToolbox/AudioToolbox.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <memory>
#include <thread>

namespace {
constexpr uint32_t kMaxRate = 192000, kSeconds = 20;
constexpr uint32_t kMaxFrames = kMaxRate * kSeconds;
std::vector<float> g_di(kMaxFrames), g_wet(kMaxFrames * 2);
std::atomic_flag g_busy = ATOMIC_FLAG_INIT;
std::atomic<bool> g_recording{false};
std::atomic<uint32_t> g_frames{0};
std::atomic<double> g_rate{48000};
std::atomic<float> g_peak{0};
bool g_hasDI = false;
uint32_t g_latency = 0;

// Main-thread operations may wait for an in-flight copy. The audio thread never waits.
struct CaptureGuard {
  CaptureGuard() { while (g_busy.test_and_set(std::memory_order_acquire)) std::this_thread::yield(); }
  ~CaptureGuard() { g_busy.clear(std::memory_order_release); }
};
float db(double x) { return x > 1e-6 ? static_cast<float>(20 * std::log10(x)) : -120; }
float finite(float x) { return std::isfinite(x) ? x : 0; }

NSData* wav(const float* samples, size_t frames, uint16_t channels, double rate) {
  // PCM24 preserves DI detail for providers/playback. Float originals stay untouched.
  NSMutableData* data = [NSMutableData data];
  auto u16 = [&](uint16_t v) { uint8_t b[] = {uint8_t(v), uint8_t(v >> 8)}; [data appendBytes:b length:2]; };
  auto u32 = [&](uint32_t v) { uint8_t b[] = {uint8_t(v), uint8_t(v >> 8), uint8_t(v >> 16), uint8_t(v >> 24)}; [data appendBytes:b length:4]; };
  uint32_t bytes = static_cast<uint32_t>(frames * channels * 3);
  [data appendBytes:"RIFF" length:4]; u32(36 + bytes + (bytes & 1));
  [data appendBytes:"WAVEfmt " length:8]; u32(16); u16(1); u16(channels);
  u32(static_cast<uint32_t>(rate)); u32(static_cast<uint32_t>(rate) * channels * 3);
  u16(channels * 3); u16(24); [data appendBytes:"data" length:4]; u32(bytes);
  std::vector<uint8_t> pcm(bytes + (bytes & 1));
  for (size_t i = 0; i < frames * channels; ++i) {
    int32_t v = static_cast<int32_t>(std::clamp(finite(samples[i]), -1.0f, 1.0f) * 8388607);
    pcm[i * 3] = v; pcm[i * 3 + 1] = v >> 8; pcm[i * 3 + 2] = v >> 16;
  }
  [data appendBytes:pcm.data() length:pcm.size()];
  return data;
}

struct Stats {
  float peak = -120, rms = -120;
  size_t clipped = 0;
  std::array<float, 8> bands{};
};
Stats analyze(const float* x, size_t frames, size_t channels, double rate) {
  Stats s;
  double sum = 0, peak = 0;
  for (size_t i = 0; i < frames * channels; ++i) {
    double v = finite(x[i]); sum += v * v; peak = std::max(peak, std::fabs(v));
    if (std::fabs(v) >= 1) ++s.clipped;
  }
  s.peak = db(peak); s.rms = db(std::sqrt(sum / std::max<size_t>(1, frames * channels)));
  // Broad center-frequency estimates, not exact disjoint frequency bands.
  const double centers[] = {90, 250, 500, 1000, 2000, 4000, 8000, 12000};
  for (size_t band = 0; band < 8; ++band) {
    if (centers[band] >= rate * .45) { s.bands[band] = -120; continue; }
    double w = 2 * M_PI * centers[band] / rate, alpha = std::sin(w) / 1.4;
    double b = alpha / (1 + alpha), a1 = -2 * std::cos(w) / (1 + alpha), a2 = (1 - alpha) / (1 + alpha);
    double energy = 0;
    for (size_t ch = 0; ch < channels; ++ch) {
      double z1 = 0, z2 = 0;
      for (size_t f = 0; f < frames; ++f) {
        double v = finite(x[f * channels + ch]), y = b * v + z1;
        z1 = -a1 * y + z2; z2 = -b * v - a2 * y; energy += y * y;
      }
    }
    s.bands[band] = db(std::sqrt(energy / std::max<size_t>(1, frames * channels)));
  }
  return s;
}
NSString* summary(NSString* label, const Stats& s) {
  return [NSString stringWithFormat:@"%@: peak %.1f dBFS; RMS %.1f; crest %.1f dB; clipped samples %zu; broad filter estimates at 90/250/500/1000/2000/4000/8000/12000 Hz: %.1f/%.1f/%.1f/%.1f/%.1f/%.1f/%.1f/%.1f dBFS",
      label, s.peak, s.rms, std::max(0.f, s.peak - s.rms), s.clipped,
      s.bands[0], s.bands[1], s.bands[2], s.bands[3], s.bands[4], s.bands[5], s.bands[6], s.bands[7]];
}
NSError* failure(NSString* text) {
  return [NSError errorWithDomain:@"RigRiffRecorder" code:-1 userInfo:@{NSLocalizedDescriptionKey:text}];
}

// Bounded RIFF decoder; supports mono/stereo PCM16/24/32 and float32, arbitrary chunks.
NSData* decode(NSURL* url, double& rate, NSUInteger& channels, NSError** error) {
  NSNumber* size = nil;
  if (![url getResourceValue:&size forKey:NSURLFileSizeKey error:error]) return nil;
  if (size.unsignedLongLongValue > 40 * 1024 * 1024) { if (error) *error = failure(@"WAV must be at most 40 MB; choose a short excerpt."); return nil; }
  NSData* file = [NSData dataWithContentsOfURL:url options:0 error:error];
  if (!file) return nil;
  const auto* b = static_cast<const uint8_t*>(file.bytes);
  auto u16 = [&](size_t i) { return uint16_t(b[i] | uint16_t(b[i + 1]) << 8); };
  auto u32 = [&](size_t i) { return uint32_t(b[i]) | uint32_t(b[i+1]) << 8 | uint32_t(b[i+2]) << 16 | uint32_t(b[i+3]) << 24; };
  size_t payload = 0, bytes = 0; uint16_t format = 0, bits = 0, align = 0;
  if (file.length >= 12 && !memcmp(b, "RIFF", 4) && !memcmp(b+8, "WAVE", 4)) {
    size_t end = std::min<size_t>(file.length, size_t(u32(4)) + 8);
    for (size_t pos = 12; pos + 8 <= end;) {
      size_t n = u32(pos + 4), start = pos + 8;
      if (n > end - start) break;
      if (!memcmp(b + pos, "fmt ", 4) && n >= 16) {
        format = u16(start); channels = u16(start+2); rate = u32(start+4);
        align = u16(start+12); bits = u16(start+14);
      } else if (!memcmp(b + pos, "data", 4)) { payload = start; bytes = n; }
      pos = start + n + (n & 1);
    }
  }
  if (!payload || !bytes || (channels != 1 && channels != 2) || rate < 22050 || rate > kMaxRate ||
      !((format == 1 && (bits == 16 || bits == 24 || bits == 32)) || (format == 3 && bits == 32)) ||
      align != channels * (bits / 8) || bytes % align) {
    if (error) *error = failure(@"Use mono/stereo PCM16/24/32 or float32 WAV at 22.05–192 kHz."); return nil;
  }
  size_t frames = std::min<size_t>(bytes / align, static_cast<size_t>(rate * kSeconds));
  std::vector<float> out(frames * channels);
  for (size_t i = 0; i < out.size(); ++i) {
    size_t p = payload + i * bits / 8;
    if (format == 3) { uint32_t v = u32(p); memcpy(&out[i], &v, 4); }
    else if (bits == 16) out[i] = int16_t(u16(p)) / 32768.f;
    else if (bits == 24) {
      int32_t v = b[p] | int32_t(b[p+1]) << 8 | int32_t(b[p+2]) << 16;
      if (v & 0x800000) v |= ~0xffffff;
      out[i] = v / 8388608.f;
    } else out[i] = int32_t(u32(p)) / 2147483648.f;
    if (!std::isfinite(out[i])) { if (error) *error = failure(@"WAV contains non-finite samples."); return nil; }
  }
  return [NSData dataWithBytes:out.data() length:out.size() * sizeof(float)];
}

// Any CoreAudio-readable mono/stereo file as interleaved float. Songs are kept
// whole (up to 128 MB of samples) so the user can pick the section to match.
constexpr size_t kMaxReferenceSamples = size_t(32) * 1024 * 1024;
NSData* decodeReference(NSURL* url, double& rate, NSUInteger& channels, BOOL& truncated, NSError** error) {
  auto fail = [&](NSString* text) -> NSData* { if (error) *error = failure(text); return nil; };
  ExtAudioFileRef file = nullptr;
  if (ExtAudioFileOpenURL((__bridge CFURLRef)url, &file) != noErr || !file)
    return fail(@"Could not read this audio file. Use WAV, AIFF, MP3, M4A/AAC, ALAC or FLAC.");
  std::unique_ptr<OpaqueExtAudioFile, OSStatus (*)(ExtAudioFileRef)> guard(file, ExtAudioFileDispose);
  AudioStreamBasicDescription format{}; UInt32 size = sizeof(format);
  if (ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format) != noErr)
    return fail(@"Could not read the audio file format.");
  rate = format.mSampleRate; channels = format.mChannelsPerFrame;
  if ((channels != 1 && channels != 2) || !std::isfinite(rate) || rate < 22050 || rate > kMaxRate)
    return fail(@"Use a mono or stereo file at 22.05–192 kHz.");
  AudioStreamBasicDescription client{};
  client.mSampleRate = rate; client.mFormatID = kAudioFormatLinearPCM;
  client.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  client.mBitsPerChannel = 32; client.mChannelsPerFrame = UInt32(channels); client.mFramesPerPacket = 1;
  client.mBytesPerFrame = client.mBytesPerPacket = UInt32(sizeof(float) * channels);
  if (ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client) != noErr)
    return fail(@"Could not decode this audio file to float samples.");
  SInt64 fileFrames = 0; size = sizeof(fileFrames);
  ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &fileFrames);
  const size_t maxFrames = kMaxReferenceSamples / channels;
  std::vector<float> out, chunk(8192 * channels);
  out.reserve(std::min<size_t>(size_t(std::max<SInt64>(0, fileFrames)), maxFrames) * channels);
  truncated = NO;
  while (true) {
    const size_t have = out.size() / channels;
    if (have >= maxFrames) { truncated = fileFrames > SInt64(maxFrames); break; }
    UInt32 frames = UInt32(std::min<size_t>(8192, maxFrames - have));
    AudioBufferList list{};
    list.mNumberBuffers = 1;
    list.mBuffers[0] = {UInt32(channels), UInt32(frames * sizeof(float) * channels), chunk.data()};
    if (ExtAudioFileRead(file, &frames, &list) != noErr) return fail(@"Decoding failed partway through the file.");
    if (!frames) break;
    out.insert(out.end(), chunk.begin(), chunk.begin() + frames * channels);
  }
  if (out.size() < size_t(rate * .25) * channels) return fail(@"The audio file is empty or too short.");
  for (float x : out) if (!std::isfinite(x)) return fail(@"Audio contains non-finite samples.");
  return [NSData dataWithBytes:out.data() length:out.size() * sizeof(float)];
}

// Start frame of the most energetic window of `count` frames (250 ms resolution).
size_t densestWindow(const float* x, size_t frames, size_t channels, size_t count, double rate) {
  if (frames <= count) return 0;
  const size_t chunk = std::max<size_t>(1, size_t(rate * .25)), chunks = frames / chunk;
  std::vector<double> prefix(chunks + 1, 0);
  for (size_t c = 0; c < chunks; ++c) {
    double sum = 0;
    for (size_t i = c * chunk * channels; i < (c + 1) * chunk * channels; ++i) sum += double(x[i]) * x[i];
    prefix[c + 1] = prefix[c] + sum;
  }
  const size_t span = std::max<size_t>(1, count / chunk);
  size_t best = 0; double bestEnergy = -1;
  for (size_t c = 0; c + span <= chunks; ++c) {
    if (prefix[c + span] - prefix[c] > bestEnergy) { bestEnergy = prefix[c + span] - prefix[c]; best = c; }
  }
  return std::min(best * chunk, frames - count);
}
NSString* clock(double seconds) {
  const long s = std::lround(std::max(0.0, seconds));
  return [NSString stringWithFormat:@"%ld:%02ld", s / 60, s % 60];
}
} // namespace

NSData* rigDecodeReference(NSURL* url, double& rate, NSUInteger& channels, BOOL& truncated, NSError** error) {
  return decodeReference(url, rate, channels, truncated, error);
}

NSData* rigWavDataFromFloatSamples(const float* samples, size_t frames, uint16_t channels, double rate) {
  return wav(samples, frames, channels, rate);
}

void rigRiffRecorderPushPair(const float* di, const float* left, const float* right,
                            uint32_t frames, double rate, uint32_t latency) {
  if (!g_recording.load(std::memory_order_acquire) || !frames) return;
  if (g_busy.test_and_set(std::memory_order_acquire)) return;
  if (g_recording.load(std::memory_order_relaxed)) {
    uint32_t pos = g_frames.load(std::memory_order_relaxed);
    if (!std::isfinite(rate) || rate < 22050 || rate > kMaxRate || (pos && rate != g_rate.load())) {
      g_recording.store(false, std::memory_order_release);
    } else {
      g_rate.store(rate); g_latency = latency;
      uint32_t limit = static_cast<uint32_t>(rate * kSeconds);
      uint32_t count = std::min(frames, limit - pos);
      float peak = 0;
      if (!pos) g_hasDI = di != nullptr;
      g_hasDI = g_hasDI && di != nullptr;
      for (uint32_t f = 0; f < count; ++f) {
        float d = di ? finite(di[f]) : 0, l = left ? finite(left[f]) : 0, r = right ? finite(right[f]) : l;
        g_di[pos + f] = d; g_wet[(pos + f) * 2] = l; g_wet[(pos + f) * 2 + 1] = r;
        peak = std::max(peak, std::fabs(di ? d : l));
      }
      g_peak.store(peak); g_frames.store(pos + count, std::memory_order_release);
      if (pos + count == limit) g_recording.store(false, std::memory_order_release);
    }
  }
  g_busy.clear(std::memory_order_release);
}
void rigRiffRecorderPushSamples(const float* l, const float* r, uint32_t n, double rate) {
  rigRiffRecorderPushPair(nullptr, l, r, n, rate, 0);
}

@interface RigRiffRecorder () <NSSoundDelegate> {
  NSSound* _player;
  NSSound* _playAlongPlayer;
  BOOL _pending, _guided, _playingAlong;
  NSData* _wetFrames;
  NSUInteger _previewGeneration;
}
@property(nonatomic, readwrite) BOOL isPlayingAlong;
@property(nonatomic, readwrite) NSTimeInterval recordedDuration;
@property(nonatomic, readwrite) double recordedSampleRate;
@property(nonatomic, readwrite, nullable) NSData* recordedWavData;
@property(nonatomic, readwrite, nullable) NSData* recordedDIWavData;
@property(nonatomic, readwrite, nullable) NSData* recordedDIFrames;
@property(nonatomic, readwrite) NSUInteger latencyFrames;
@property(nonatomic, readwrite) BOOL isPlaying;
@property(nonatomic, readwrite) BOOL isRendering;
@property(nonatomic, readwrite) float peakDbfs, rmsDbfs, crestFactorDb, lowBandDbfs, lowMidDbfs, highMidDbfs, trebleDbfs, airDbfs;
@property(nonatomic, readwrite) float diPeakDbfs;
@property(nonatomic, readwrite) BOOL isDIClipped;
@property(nonatomic, readwrite, copy) NSString* audioAnalysisSummary;
@property(nonatomic, readwrite, nullable) NSData* referenceWavData;
@property(nonatomic, readwrite, nullable) NSData* referenceBackingWavData;
@property(nonatomic, readwrite, nullable) NSData* referenceFrames;
@property(nonatomic, readwrite, nullable) NSData* referenceBackingFrames;
@property(nonatomic, strong, nullable) NSData* referenceBackingFullFrames;
@property(nonatomic, readwrite, copy, nullable) NSString* currentPlayingTrack;
@property(nonatomic, readwrite) double referenceSampleRate;
@property(nonatomic, readwrite) NSUInteger referenceChannels;
@property(nonatomic, readwrite) BOOL referenceIsFullMix;
@property(nonatomic, readwrite, copy) NSString* referenceSource;
@property(nonatomic, readwrite) NSTimeInterval referenceTotalDuration;
@property(nonatomic, readwrite) BOOL referenceTruncated;
@property(nonatomic, readwrite) NSTimeInterval referenceSelectionStart;
@property(nonatomic, readwrite) NSTimeInterval referenceSelectionLength;
@property(nonatomic, readwrite) BOOL referenceSelectionAuto;
@property(nonatomic, strong, nullable) NSData* referenceFullFrames;
@property(nonatomic, readwrite, copy) NSString* referenceAnalysis;
@property(nonatomic, readwrite, nullable) NSData* baselineWavData;
@property(nonatomic, readwrite, nullable) NSData* candidateWavData;
@property(nonatomic, readwrite, copy) NSString* candidateAnalysis;
@end

@implementation RigRiffRecorder
+ (instancetype)sharedRecorder {
  static RigRiffRecorder* instance; static dispatch_once_t once;
  dispatch_once(&once, ^{ instance = [RigRiffRecorder new]; }); return instance;
}
- (instancetype)init {
  if ((self = [super init])) { [self clearRecording]; _referenceAnalysis = @""; _referenceSource = @""; _recordingMetadata = @{}; }
  return self;
}
- (BOOL)isRecording { return g_recording.load(std::memory_order_acquire); }
- (float)currentPeakLevel { return g_peak.load(); }
- (NSTimeInterval)recordedDuration { return _pending ? g_frames.load() / g_rate.load() : _recordedDuration; }
+ (NSArray<NSDictionary*>*)guidedPlan {
  return @[
    @{@"start": @0, @"end": @2, @"label": @"Muted strings", @"instruction": @"Mute the strings with your fretting hand. Keep the guitar volume up. This captures the noise floor."},
    @{@"start": @2, @"end": @6, @"label": @"Chugs", @"instruction": @"Palm-muted low-string chugs with short gaps between them."},
    @{@"start": @6, @"end": @10, @"label": @"Power chords", @"instruction": @"Unmuted power chords. Let each chord ring."},
    @{@"start": @10, @"end": @15, @"label": @"Single notes", @"instruction": @"Low then high single notes. Pick softly first, then firmly."},
    @{@"start": @15, @"end": @20, @"label": @"Sustain", @"instruction": @"Hold one note or bend and let it fade out naturally."},
  ];
}
- (BOOL)isGuided { return _guided; }
- (NSInteger)guidedSegmentIndex {
  if (!_guided) return -1;
  const double t = self.recordedDuration;
  NSArray* plan = [RigRiffRecorder guidedPlan];
  for (NSUInteger i = 0; i < plan.count; ++i)
    if (t < [plan[i][@"end"] doubleValue]) return (NSInteger)i;
  return (NSInteger)plan.count - 1;
}
- (NSString*)guidance {
  if (!_guided) return @"Play a representative riff; include soft/hard picking and a note that fades.";
  NSArray* plan = [RigRiffRecorder guidedPlan];
  NSDictionary* segment = plan[(NSUInteger)std::max<NSInteger>(0, self.guidedSegmentIndex)];
  return [NSString stringWithFormat:@"%@–%@s: %@", segment[@"start"], segment[@"end"], segment[@"instruction"]];
}
- (void)startRecording { [self startRecordingGuided:NO]; }
- (void)startRecordingGuided:(BOOL)guided {
  [self clearRecording]; _guided = guided;
  CaptureGuard guard; g_frames.store(0); g_hasDI = false; _pending = YES;
  g_recording.store(true, std::memory_order_release);
}
- (void)startPlayAlong {
  [self clearRecording]; _guided = NO; _playingAlong = YES;
  if (_referenceWavData.length) {
    _playAlongPlayer = [[NSSound alloc] initWithData:_referenceWavData];
    _playAlongPlayer.delegate = self;
    [_playAlongPlayer play];
  }
  CaptureGuard guard; g_frames.store(0); g_hasDI = false; _pending = YES;
  g_recording.store(true, std::memory_order_release);
}
- (void)stopPlayAlong {
  if (_playAlongPlayer) { [_playAlongPlayer stop]; _playAlongPlayer = nil; }
  _playingAlong = NO;
  [self stopRecording];
}
- (BOOL)isPlayingAlong { return _playingAlong; }
- (void)setStats:(const Stats&)s {
  _peakDbfs = s.peak; _rmsDbfs = s.rms; _crestFactorDb = std::max(0.f, s.peak - s.rms);
  _lowBandDbfs = s.bands[0]; _lowMidDbfs = s.bands[1]; _highMidDbfs = s.bands[2]; _trebleDbfs = s.bands[3]; _airDbfs = s.bands[4];
}
- (void)stopRecording {
  if (_playAlongPlayer) { [_playAlongPlayer stop]; _playAlongPlayer = nil; }
  _playingAlong = NO;
  if (!_pending) return;
  {
    CaptureGuard guard; g_recording.store(false, std::memory_order_release); _pending = NO;
    uint32_t n = g_frames.load(); _recordedSampleRate = g_rate.load(); _recordedDuration = n / _recordedSampleRate;
    _latencyFrames = g_latency;
    _wetFrames = [NSData dataWithBytes:g_wet.data() length:n * 2 * sizeof(float)];
    _recordedDIFrames = g_hasDI ? [NSData dataWithBytes:g_di.data() length:n * sizeof(float)] : nil;
  }
  g_peak.store(0);
  size_t n = _wetFrames.length / (2 * sizeof(float));
  if (n < 64) { _audioAnalysisSummary = @"Recording too short."; return; }
  const auto* wet = static_cast<const float*>(_wetFrames.bytes);
  _recordedWavData = wav(wet, n, 2, _recordedSampleRate);
  Stats s = analyze(wet, n, 2, _recordedSampleRate); [self setStats:s];
  NSMutableString* text = [NSMutableString stringWithFormat:@"Take %.1fs, %.0f Hz; engine latency %lu frames. DI precedes all app processing; external hardware may still color it. Do not infer pickup type or hardware gain from these measurements.\n%@",
      _recordedDuration, _recordedSampleRate, (unsigned long)_latencyFrames, summary(@"Processed output", s)];
  _isDIClipped = NO;
  _diPeakDbfs = -120.0f;
  if (_recordedDIFrames.length) {
    const auto* di = static_cast<const float*>(_recordedDIFrames.bytes);
    _recordedDIWavData = wav(di, n, 1, _recordedSampleRate);
    Stats diStats = analyze(di, n, 1, _recordedSampleRate);
    _diPeakDbfs = diStats.peak;
    _isDIClipped = (diStats.clipped > 0 || diStats.peak >= -0.01f);
    [text appendFormat:@"\n%@", summary(@"Raw DI (not normalized)", diStats)];
    if (_isDIClipped) {
      [text appendString:@"\n⚠️ WARNING: Raw guitar DI clipped at full scale (0 dBFS). Lower your audio interface input gain and re-record an unclipped take before tone matching."];
    }
    if (_guided) {
      const double boundaries[] = {0, 2, 6, 10, 15, 20};
      NSArray* labels = @[@"Muted strings / noise", @"Chugs", @"Power chords", @"Soft/hard single notes", @"Sustain/decay"];
      for (size_t i = 0; i < 5; ++i) {
        size_t start = boundaries[i] * _recordedSampleRate, end = std::min(n, size_t(boundaries[i+1] * _recordedSampleRate));
        if (end <= start) break;
        Stats dry = analyze(di + start, end - start, 1, _recordedSampleRate);
        size_t ws = std::min(n, start + _latencyFrames), we = std::min(n, end + _latencyFrames);
        if (we <= ws) continue;
        Stats processed = analyze(wet + ws * 2, we - ws, 2, _recordedSampleRate);
        [text appendFormat:@"\nGuided %@ (expected, not detected), %.0f–%.1fs: DI peak/RMS %.1f/%.1f; %@",
            labels[i], boundaries[i], end / _recordedSampleRate, dry.peak, dry.rms, summary(@"processed", processed)];
      }
    }
  }
  _audioAnalysisSummary = text;
}
- (void)invalidatePreview {
  ++_previewGeneration; _isRendering = NO; _baselineWavData = nil; _candidateWavData = nil; _candidateAnalysis = @"";
}
- (void)clearRecording {
  if (_playAlongPlayer) { [_playAlongPlayer stop]; _playAlongPlayer = nil; }
  _playingAlong = NO;
  [self stopPlayback]; [self invalidatePreview];
  { CaptureGuard guard; g_recording.store(false); g_frames.store(0); g_peak.store(0); g_latency = 0; _pending = NO; }
  _wetFrames = nil; _recordedWavData = nil; _recordedDIWavData = nil; _recordedDIFrames = nil;
  _recordingPreset = nil; _recordingMetadata = @{}; _recordedDuration = 0; _latencyFrames = 0;
  _isDIClipped = NO; _diPeakDbfs = -120.0f;
  Stats s; s.bands.fill(-120); [self setStats:s]; _audioAnalysisSummary = @"No riff recorded.";
}
- (void)playRecording { [self playTrack:@"processed"]; }
- (void)playTrack:(NSString*)track {
  [self stopPlayback];
  _currentPlayingTrack = [track copy];
  NSDictionary* dict = @{
    @"processed": _recordedWavData ?: NSData.data,
    @"di": _recordedDIWavData ?: NSData.data,
    @"baseline": _baselineWavData ?: NSData.data,
    @"candidate": _candidateWavData ?: NSData.data,
    @"reference": _referenceWavData ?: NSData.data,
    @"target": _referenceWavData ?: NSData.data,
    @"backing": _referenceBackingWavData ?: NSData.data,
  };
  NSData* data = dict[track];
  if (!data.length) {
    _currentPlayingTrack = nil;
    return;
  }
  _player = [[NSSound alloc] initWithData:data];
  _player.delegate = self;
  _isPlaying = [_player play];
  if (!_isPlaying) {
    _currentPlayingTrack = nil;
  }
}
- (void)stopPlayback {
  [_player stop];
  _player = nil;
  _isPlaying = NO;
  _currentPlayingTrack = nil;
}
- (void)sound:(NSSound*)sound didFinishPlaying:(BOOL)flag {
  if (sound == _player) {
    _isPlaying = NO;
    _currentPlayingTrack = nil;
    _player = nil;
    if (self.onPlaybackFinished) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onPlaybackFinished) self.onPlaybackFinished();
      });
    }
  }
  if (sound == _playAlongPlayer) {
    _playAlongPlayer = nil;
    _playingAlong = NO;
    if (self.isRecording) [self stopRecording];
  }
}
- (BOOL)loadAudioFromURL:(NSURL*)url error:(NSError**)error {
  double rate = 0; NSUInteger channels = 0; NSData* audio = decode(url, rate, channels, error);
  if (!audio) return NO; // Keep the old take when import fails.
  [self clearRecording]; _recordedSampleRate = rate;
  size_t n = audio.length / (channels * sizeof(float)); _recordedDuration = n / rate;
  auto* x = static_cast<const float*>(audio.bytes); _recordedWavData = wav(x, n, channels, rate);
  Stats s = analyze(x, n, channels, rate); [self setStats:s];
  _audioAnalysisSummary = [@"Imported player's processed riff (first 20s maximum); no paired DI or recording-time preset.\n" stringByAppendingString:summary(@"Imported riff", s)];
  return YES;
}
- (BOOL)loadReferenceFromURL:(NSURL*)url fullMix:(BOOL)fullMix error:(NSError**)error {
  return [self loadReferenceFromURL:url fullMix:fullMix source:fullMix ? @"mix" : @"stem" error:error];
}
- (BOOL)loadReferenceFromURL:(NSURL*)url fullMix:(BOOL)fullMix source:(NSString*)source error:(NSError**)error {
  return [self loadReferenceFromURL:url fullMix:fullMix source:source backingAudioURL:nil error:error];
}
- (BOOL)loadReferenceFromURL:(NSURL*)url fullMix:(BOOL)fullMix source:(NSString*)source backingAudioURL:(nullable NSURL*)backingURL error:(NSError**)error {
  double rate = 0; NSUInteger channels = 0; BOOL truncated = NO;
  NSData* audio = decodeReference(url, rate, channels, truncated, error);
  if (!audio) return NO; // Keep the old reference when import fails.
  NSData* backingAudio = nil;
  if (backingURL) {
    double bRate = 0; NSUInteger bChannels = 0; BOOL bTruncated = NO;
    backingAudio = decodeReference(backingURL, bRate, bChannels, bTruncated, nil);
    if (backingAudio && (bRate != rate || bChannels != channels)) backingAudio = nil;
  }
  _referenceFullFrames = audio; _referenceBackingFullFrames = backingAudio; _referenceSampleRate = rate; _referenceChannels = channels;
  _referenceIsFullMix = fullMix; _referenceSource = [source copy] ?: @"stem"; _referenceTruncated = truncated;
  _referenceTotalDuration = audio.length / (channels * sizeof(float)) / rate;
  [self selectReferenceStart:0 length:20 automatic:YES];
  return YES;
}
- (void)selectReferenceStart:(NSTimeInterval)start length:(NSTimeInterval)length automatic:(BOOL)automatic {
  if (!_referenceFullFrames.length || !_referenceChannels || _referenceSampleRate <= 0) return;
  const size_t channels = _referenceChannels; const double rate = _referenceSampleRate;
  const size_t total = _referenceFullFrames.length / (channels * sizeof(float));
  const auto* x = static_cast<const float*>(_referenceFullFrames.bytes);
  const double seconds = std::clamp(std::isfinite(length) ? length : 20.0, 5.0, 20.0);
  const size_t count = std::min(total, size_t(seconds * rate));
  const size_t first = automatic ? densestWindow(x, total, channels, count, rate) :
      std::min(size_t(std::max(0.0, std::isfinite(start) ? start : 0.0) * rate), total - count);
  _referenceSelectionAuto = automatic; _referenceSelectionStart = first / rate; _referenceSelectionLength = count / rate;
  _referenceFrames = [_referenceFullFrames subdataWithRange:NSMakeRange(first * channels * sizeof(float), count * channels * sizeof(float))];
  if (_referenceBackingFullFrames.length >= (first + count) * channels * sizeof(float)) {
    _referenceBackingFrames = [_referenceBackingFullFrames subdataWithRange:NSMakeRange(first * channels * sizeof(float), count * channels * sizeof(float))];
  } else {
    _referenceBackingFrames = nil;
  }
  const float* section = x + first * channels;
  _referenceWavData = wav(section, count, uint16_t(channels), rate);
  if (_referenceBackingFrames.length) {
    const float* bSection = static_cast<const float*>(_referenceBackingFrames.bytes);
    _referenceBackingWavData = wav(bSection, count, uint16_t(channels), rate);
  } else {
    _referenceBackingWavData = nil;
  }
  NSString* kind = _referenceIsFullMix ? @"full mix" : [_referenceSource isEqualToString:@"demucs"] ? @"isolated guitar · Demucs stem" : @"isolated guitar";
  _referenceAnalysis = [NSString stringWithFormat:@"TARGET REFERENCE (%@, %.1fs section %@–%@ of %@%@, %@). %@\n%@",
      kind, count / rate, clock(first / rate), clock((first + count) / rate), clock(_referenceTotalDuration),
      _referenceTruncated ? @" (file truncated)" : @"", automatic ? @"auto-selected densest passage" : @"user-selected",
      _referenceIsFullMix ? @"Contains other instruments/mastering: do NOT match its raw spectrum or loudness as guitar EQ." : @"Different performance/tuning may affect spectral comparisons.",
      summary(@"Reference", analyze(section, count, channels, rate))];
}
- (void)clearReference {
  _referenceWavData = nil; _referenceBackingWavData = nil; _referenceFrames = nil; _referenceFullFrames = nil;
  _referenceBackingFrames = nil; _referenceBackingFullFrames = nil; _referenceAnalysis = @"";
  _referenceSampleRate = 0; _referenceChannels = 0; _referenceIsFullMix = NO; _referenceSource = @"";
  _referenceTotalDuration = 0; _referenceTruncated = NO; _referenceSelectionStart = 0; _referenceSelectionLength = 0;
  _referenceSelectionAuto = NO;
}
- (void)renderBaseline:(RigPreset*)baseline candidate:(RigPreset*)candidate completion:(void (^)(NSError*))completion {
  if (_isRendering) { completion(failure(@"A DI render is already running.")); return; }
  if (!self.renderHandler || !_recordedDIFrames.length) { completion(failure(@"Record paired DI in the standalone app before rendering.")); return; }
  [self stopPlayback]; [self invalidatePreview]; _isRendering = YES;
  NSUInteger generation = _previewGeneration; double rate = _recordedSampleRate;
  BOOL guided = _guided;
  NSData* di = _recordedDIFrames; RigRiffRenderHandler renderer = self.renderHandler;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      NSError* error = nil; NSData* a = renderer(baseline, di, rate, &error);
      NSData* b = a && !error ? renderer(candidate, di, rate, &error) : nil;
      NSData* aw = nil; NSData* bw = nil; NSString* analysis = @"";
      if (a.length && b.length && !error) {
        size_t an = a.length / (2 * sizeof(float)), bn = b.length / (2 * sizeof(float));
        auto* ax = static_cast<const float*>(a.bytes); auto* bx = static_cast<const float*>(b.bytes);
        Stats as = analyze(ax, an, 2, rate), bs = analyze(bx, bn, 2, rate);
        analysis = [NSString stringWithFormat:@"Same unnormalized DI rendered through both presets (engine latency compensated; 2s effect tail, possibly truncated). Before audition level matching:\n%@\n%@",
            summary(@"Baseline", as), summary(@"Candidate", bs)];
        if (guided) {
          NSMutableString* segments = [analysis mutableCopy];
          const double bounds[] = {0, 2, 6, 10, 15, 20};
          NSArray* labels = @[@"Muted strings", @"Chugs", @"Chords", @"Soft/hard notes", @"Sustain/decay"];
          size_t takeFrames = di.length / sizeof(float);
          for (size_t i = 0; i < 5; ++i) {
            size_t start = bounds[i] * rate, end = std::min({an, bn, takeFrames, size_t(bounds[i+1] * rate)});
            if (end <= start) break;
            Stats sa = analyze(ax + start * 2, end - start, 2, rate), sb = analyze(bx + start * 2, end - start, 2, rate);
            [segments appendFormat:@"\nExpected %@: baseline/candidate RMS %.1f/%.1f, crest %.1f/%.1f dB; candidate-minus-baseline broad-filter dB (90/250/500/1000/2000/4000/8000/12000 Hz): %.1f/%.1f/%.1f/%.1f/%.1f/%.1f/%.1f/%.1f",
                labels[i], sa.rms, sb.rms, sa.peak-sa.rms, sb.peak-sb.rms,
                sb.bands[0]-sa.bands[0], sb.bands[1]-sa.bands[1], sb.bands[2]-sa.bands[2], sb.bands[3]-sa.bands[3],
                sb.bands[4]-sa.bands[4], sb.bands[5]-sa.bands[5], sb.bands[6]-sa.bands[6], sb.bands[7]-sa.bands[7]];
          }
          analysis = segments;
        }
        // Attenuate only: common RMS target plus peak headroom. Never boost clipping.
        double target = std::min(as.rms, bs.rms), ga = std::pow(10, (target - as.rms) / 20), gb = std::pow(10, (target - bs.rms) / 20);
        double peak = std::max(std::pow(10, as.peak / 20) * ga, std::pow(10, bs.peak / 20) * gb);
        double headroom = peak > .95 ? .95 / peak : 1;
        std::vector<float> av(an * 2), bv(bn * 2);
        for (size_t i = 0; i < av.size(); ++i) av[i] = ax[i] * ga * headroom;
        for (size_t i = 0; i < bv.size(); ++i) bv[i] = bx[i] * gb * headroom;
        aw = wav(av.data(), an, 2, rate); bw = wav(bv.data(), bn, 2, rate);
      } else if (!error) error = failure(@"The offline renderer returned no audio.");
      dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_previewGeneration) { completion(failure(@"Take or proposal changed; preview discarded.")); return; }
        self.isRendering = NO; self.baselineWavData = aw; self.candidateWavData = bw; self.candidateAnalysis = analysis;
        completion(error);
      });
    }
  });
}
@end
