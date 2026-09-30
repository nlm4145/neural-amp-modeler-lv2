#import <Cocoa/Cocoa.h>
#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/CoreAudio.h>
#include <os/workgroup.h>
#include <mach/mach_time.h>

#include <lv2/atom/atom.h>
#include <lv2/atom/util.h>
#include <lv2/buf-size/buf-size.h>
#include <lv2/core/lv2.h>
#include <lv2/log/log.h>
#include <lv2/options/options.h>
#include <lv2/ui/ui.h>
#include <lv2/urid/urid.h>
#include <lv2/worker/worker.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "nam_rig_plugin.h"
#include "cabinet_worker.h"

extern "C" const LV2UI_Descriptor* lv2ui_descriptor(uint32_t index);

@interface StandaloneAnimatedAmpView : NSView
@property(nonatomic, assign) double phase;
@property(nonatomic, assign) float signalLevel;
@end

@implementation StandaloneAnimatedAmpView {
  NSImage* _baseImage;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    NSString* path = [[NSBundle mainBundle] pathForResource:@"AxeFX" ofType:@"png"];
    if (path) {
      _baseImage = [[NSImage alloc] initWithContentsOfFile:path];
    }
    if (!_baseImage) {
      _baseImage = [NSImage imageNamed:@"AxeFX"];
    }
  }
  return self;
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  const NSRect b = self.bounds;
  if (b.size.width <= 0.0 || b.size.height <= 0.0) return;

  if (_baseImage) {
    [_baseImage drawInRect:b
                  fromRect:NSZeroRect
                 operation:NSCompositingOperationSourceOver
                  fraction:1.0];
  }

  [NSGraphicsContext saveGraphicsState];
  [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositingOperationPlusLighter];

  const CGFloat w = b.size.width;
  const CGFloat h = b.size.height;
  const double p = _phase;
  const CGFloat sig = std::max(0.0f, std::min(1.0f, _signalLevel));

  // 1. Four animated glowing vacuum tubes inside the upper grille cage.
  const CGFloat tubeUs[4] = {0.362, 0.453, 0.545, 0.637};
  for (int i = 0; i < 4; ++i) {
    const double wave = 0.5 + 0.5 * std::sin(p * 3.2 + i * 1.15);
    const double flicker = 0.5 + 0.5 * std::sin(p * 7.8 + i * 2.3);
    const CGFloat intensity = std::min<CGFloat>(1.0, 0.28 + 0.34 * wave + 0.12 * flicker + 0.55 * sig);

    const CGFloat cx = b.origin.x + w * tubeUs[i];
    const CGFloat cy = b.origin.y + h * 0.655;
    const CGFloat tw = w * 0.068;
    const CGFloat th = h * 0.145;

    // Outer warm amber tube envelope aura
    NSRect outerRect = NSMakeRect(cx - tw * 0.65, cy - th * 0.55, tw * 1.3, th * 1.1);
    NSBezierPath* outerGlow = [NSBezierPath bezierPathWithOvalInRect:outerRect];
    [[NSColor colorWithSRGBRed:1.00 green:0.42 blue:0.06 alpha:(0.22 * intensity)] setFill];
    [outerGlow fill];

    // Inner bright orange-gold filament core
    NSRect coreRect = NSMakeRect(cx - tw * 0.36, cy - th * 0.42, tw * 0.72, th * 0.84);
    NSBezierPath* coreGlow = [NSBezierPath bezierPathWithOvalInRect:coreRect];
    [[NSColor colorWithSRGBRed:1.00 green:0.68 blue:0.20 alpha:(0.32 * intensity)] setFill];
    [coreGlow fill];

    // Top & bottom cathode heater hotspots
    const CGFloat hotR = w * 0.018 * (0.85 + 0.35 * intensity);
    NSRect botHot = NSMakeRect(cx - hotR, b.origin.y + h * 0.602 - hotR * 0.7, hotR * 2.0, hotR * 1.4);
    NSRect topHot = NSMakeRect(cx - hotR * 0.85, b.origin.y + h * 0.698 - hotR * 0.6, hotR * 1.7, hotR * 1.2);
    [[NSColor colorWithSRGBRed:1.00 green:0.88 blue:0.52 alpha:(0.55 * intensity)] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:botHot] fill];
    [[NSBezierPath bezierPathWithOvalInRect:topHot] fill];
  }

  // 2. Pulsing electric cyan power jewel light on the left of the faceplate.
  {
    const double jewelWave = 0.5 + 0.5 * std::sin(p * 2.4);
    const CGFloat jAlpha = std::min<CGFloat>(1.0, 0.24 + 0.28 * jewelWave + 0.35 * sig);
    const CGFloat jx = b.origin.x + w * 0.256;
    const CGFloat jy = b.origin.y + h * 0.463;
    const CGFloat jr = w * (0.042 + 0.012 * jewelWave + 0.015 * sig);
    NSRect haloRect = NSMakeRect(jx - jr, jy - jr, jr * 2.0, jr * 2.0);
    [[NSColor colorWithSRGBRed:0.10 green:0.86 blue:1.00 alpha:jAlpha] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:haloRect] fill];
  }

  // 3. Subtle speaker cone acoustic energy rings in the lower 2x12 cabinet.
  {
    const double conePulse = 0.5 + 0.5 * std::sin(p * 4.5);
    const CGFloat coneAlpha = 0.06 + 0.08 * conePulse + 0.28 * sig;
    const CGFloat coneXs[2] = {0.34, 0.66};
    for (int c = 0; c < 2; ++c) {
      const CGFloat sx = b.origin.x + w * coneXs[c];
      const CGFloat sy = b.origin.y + h * 0.245;
      const CGFloat sr = w * (0.075 + 0.025 * conePulse + 0.035 * sig);
      NSRect ringRect = NSMakeRect(sx - sr, sy - sr, sr * 2.0, sr * 2.0);
      NSBezierPath* ring = [NSBezierPath bezierPathWithOvalInRect:ringRect];
      ring.lineWidth = std::max<CGFloat>(1.0, w * 0.012);
      [[NSColor colorWithSRGBRed:1.00 green:0.55 blue:0.18 alpha:coneAlpha] setStroke];
      [ring stroke];
    }
  }

  [NSGraphicsContext restoreGraphicsState];
}
@end

namespace {

constexpr uint32_t kMaxFrames = 4096;
constexpr uint32_t kMaxInputChannels = 16;
constexpr size_t kAtomBufferSize = 16384;
constexpr size_t kMessageSize = 2048;
constexpr size_t kMessageCount = 64;
constexpr CGFloat kToolbarStripHeight = 28.0;

struct CoreAudioDeviceInfo {
  AudioDeviceID deviceID = kAudioObjectUnknown;
  std::string uid;
  std::string name;
  uint32_t inputChannels = 0;
  uint32_t outputChannels = 0;
  std::vector<std::string> inputChannelNames;
  std::vector<std::string> outputChannelNames;
  std::vector<double> supportedRates;
  uint32_t minBufferSize = 32;
  uint32_t maxBufferSize = 4096;
};

static std::string cfStringToStd(CFStringRef cf) {
  if (!cf) return {};
  NSString* ns = (__bridge NSString*)cf;
  const char* utf8 = [ns UTF8String];
  return utf8 ? std::string(utf8) : std::string();
}

static AudioDeviceID defaultAudioDeviceID(bool isInput) {
  AudioDeviceID device = kAudioObjectUnknown;
  UInt32 size = sizeof(device);
  AudioObjectPropertyAddress address{
      isInput ? kAudioHardwarePropertyDefaultInputDevice
              : kAudioHardwarePropertyDefaultOutputDevice,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr,
                                 &size, &device) != noErr) {
    return kAudioObjectUnknown;
  }
  return device;
}

static uint32_t countDeviceChannels(AudioDeviceID device, AudioObjectPropertyScope scope) {
  if (device == kAudioObjectUnknown) return 0;
  AudioObjectPropertyAddress address{kAudioDevicePropertyStreamConfiguration,
                                     scope,
                                     kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) != noErr ||
      size < sizeof(UInt32)) {
    return 0;
  }
  std::vector<uint8_t> storage(size, 0);
  auto* bufferList = reinterpret_cast<AudioBufferList*>(storage.data());
  if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, bufferList) != noErr) {
    return 0;
  }
  uint32_t total = 0;
  for (UInt32 i = 0; i < bufferList->mNumberBuffers; ++i) {
    total += bufferList->mBuffers[i].mNumberChannels;
  }
  return total;
}

static std::string queryDeviceStringProperty(AudioDeviceID device,
                                             AudioObjectPropertySelector selector,
                                             AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
                                             AudioObjectPropertyElement element = kAudioObjectPropertyElementMain) {
  if (device == kAudioObjectUnknown) return {};
  AudioObjectPropertyAddress address{selector, scope, element};
  CFStringRef strRef = nullptr;
  UInt32 size = sizeof(strRef);
  if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &strRef) != noErr || !strRef) {
    return {};
  }
  std::string out = cfStringToStd(strRef);
  CFRelease(strRef);
  return out;
}

static double queryDeviceNominalSampleRate(AudioDeviceID device) {
  if (device == kAudioObjectUnknown) return 0.0;
  Float64 rate = 0.0;
  UInt32 size = sizeof(rate);
  AudioObjectPropertyAddress address{kAudioDevicePropertyNominalSampleRate,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &rate) != noErr) {
    return 0.0;
  }
  return static_cast<double>(rate);
}

static uint32_t queryDeviceBufferFrameSize(AudioDeviceID device, AudioObjectPropertyScope scope) {
  if (device == kAudioObjectUnknown) return 0;
  UInt32 frames = 0;
  UInt32 size = sizeof(frames);
  AudioObjectPropertyAddress address{kAudioDevicePropertyBufferFrameSize,
                                     scope,
                                     kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &frames) == noErr && frames > 0) {
    return frames;
  }
  address.mScope = kAudioObjectPropertyScopeGlobal;
  if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &frames) == noErr && frames > 0) {
    return frames;
  }
  return 0;
}

static void applyDeviceSampleRateAndBufferSize(AudioDeviceID device,
                                               AudioObjectPropertyScope scope,
                                               double targetRate,
                                               uint32_t targetBufferFrames) {
  if (device == kAudioObjectUnknown) return;

  if (targetRate > 0.0) {
    Float64 currentRate = queryDeviceNominalSampleRate(device);
    if (std::fabs(currentRate - targetRate) > 1.0) {
      AudioObjectPropertyAddress rangeAddr{kAudioDevicePropertyAvailableNominalSampleRates,
                                           kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain};
      UInt32 rangeSize = 0;
      bool supported = true;
      if (AudioObjectGetPropertyDataSize(device, &rangeAddr, 0, nullptr, &rangeSize) == noErr &&
          rangeSize >= sizeof(AudioValueRange)) {
        std::vector<AudioValueRange> ranges(rangeSize / sizeof(AudioValueRange));
        if (AudioObjectGetPropertyData(device, &rangeAddr, 0, nullptr, &rangeSize, ranges.data()) == noErr) {
          supported = false;
          for (const auto& r : ranges) {
            if (targetRate >= r.mMinimum - 1.0 && targetRate <= r.mMaximum + 1.0) {
              supported = true;
              break;
            }
          }
        }
      }
      if (supported) {
        Float64 desired = static_cast<Float64>(targetRate);
        AudioObjectPropertyAddress rateAddr{kAudioDevicePropertyNominalSampleRate,
                                            kAudioObjectPropertyScopeGlobal,
                                            kAudioObjectPropertyElementMain};
        AudioObjectSetPropertyData(device, &rateAddr, 0, nullptr, sizeof(desired), &desired);
      }
    }
  }

  if (targetBufferFrames > 0) {
    UInt32 desiredFrames = targetBufferFrames;
    AudioObjectPropertyAddress rangeAddr{kAudioDevicePropertyBufferFrameSizeRange,
                                         scope,
                                         kAudioObjectPropertyElementMain};
    AudioValueRange range{};
    UInt32 rangeSize = sizeof(range);
    if (AudioObjectGetPropertyData(device, &rangeAddr, 0, nullptr, &rangeSize, &range) != noErr) {
      rangeAddr.mScope = kAudioObjectPropertyScopeGlobal;
      AudioObjectGetPropertyData(device, &rangeAddr, 0, nullptr, &rangeSize, &range);
    }
    if (range.mMaximum >= range.mMinimum && range.mMaximum > 0) {
      const uint32_t minF = static_cast<uint32_t>( std::max(16.0, range.mMinimum));
      const uint32_t maxF = static_cast<uint32_t>( std::min<double>(kMaxFrames, range.mMaximum));
      desiredFrames = std::max(minF, std::min(maxF, desiredFrames));
    }
    AudioObjectPropertyAddress bufAddr{kAudioDevicePropertyBufferFrameSize,
                                       scope,
                                       kAudioObjectPropertyElementMain};
    if (AudioObjectSetPropertyData(device, &bufAddr, 0, nullptr,
                                   sizeof(desiredFrames), &desiredFrames) != noErr) {
      bufAddr.mScope = kAudioObjectPropertyScopeGlobal;
      AudioObjectSetPropertyData(device, &bufAddr, 0, nullptr,
                                 sizeof(desiredFrames), &desiredFrames);
    }
  }
}

static std::vector<CoreAudioDeviceInfo> enumerateAudioDevices() {
  std::vector<CoreAudioDeviceInfo> result;
  AudioObjectPropertyAddress address{kAudioHardwarePropertyDevices,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, nullptr, &size) != noErr ||
      size < sizeof(AudioDeviceID)) {
    return result;
  }
  std::vector<AudioDeviceID> ids(size / sizeof(AudioDeviceID));
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, ids.data()) != noErr) {
    return result;
  }

  const double kStandardRates[] = {44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0};

  for (AudioDeviceID id : ids) {
    CoreAudioDeviceInfo info;
    info.deviceID = id;
    info.uid = queryDeviceStringProperty(id, kAudioDevicePropertyDeviceUID);
    info.name = queryDeviceStringProperty(id, kAudioObjectPropertyName);
    if (info.uid.empty() || info.name.empty()) continue;

    info.inputChannels = countDeviceChannels(id, kAudioObjectPropertyScopeInput);
    info.outputChannels = countDeviceChannels(id, kAudioObjectPropertyScopeOutput);
    if (info.inputChannels == 0 && info.outputChannels == 0) continue;

    const uint32_t chLimit = std::min<uint32_t>(info.inputChannels, kMaxInputChannels);
    for (uint32_t ch = 1; ch <= chLimit; ++ch) {
      std::string chName = queryDeviceStringProperty(
          id, kAudioObjectPropertyElementName, kAudioObjectPropertyScopeInput, ch);
      if (!chName.empty()) {
        info.inputChannelNames.push_back("Input " + std::to_string(ch) + " (" + chName + ")");
      } else {
        info.inputChannelNames.push_back("Input " + std::to_string(ch));
      }
    }

    const uint32_t outChLimit = std::min<uint32_t>(info.outputChannels, kMaxInputChannels);
    for (uint32_t ch = 1; ch <= outChLimit; ++ch) {
      std::string chName = queryDeviceStringProperty(
          id, kAudioObjectPropertyElementName, kAudioObjectPropertyScopeOutput, ch);
      if (!chName.empty()) {
        info.outputChannelNames.push_back("Output " + std::to_string(ch) + " (" + chName + ")");
      } else {
        info.outputChannelNames.push_back("Output " + std::to_string(ch));
      }
    }

    AudioObjectPropertyAddress rateAddr{kAudioDevicePropertyAvailableNominalSampleRates,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
    UInt32 rateSize = 0;
    if (AudioObjectGetPropertyDataSize(id, &rateAddr, 0, nullptr, &rateSize) == noErr &&
        rateSize >= sizeof(AudioValueRange)) {
      std::vector<AudioValueRange> ranges(rateSize / sizeof(AudioValueRange));
      if (AudioObjectGetPropertyData(id, &rateAddr, 0, nullptr, &rateSize, ranges.data()) == noErr) {
        for (double stdRate : kStandardRates) {
          for (const auto& r : ranges) {
            if (stdRate >= r.mMinimum - 1.0 && stdRate <= r.mMaximum + 1.0) {
              info.supportedRates.push_back(stdRate);
              break;
            }
          }
        }
      }
    }
    if (info.supportedRates.empty()) {
      info.supportedRates = {44100.0, 48000.0, 88200.0, 96000.0};
    }

    AudioObjectPropertyAddress rangeAddr{kAudioDevicePropertyBufferFrameSizeRange,
                                         kAudioObjectPropertyScopeGlobal,
                                         kAudioObjectPropertyElementMain};
    AudioValueRange bufRange{};
    UInt32 bufRangeSize = sizeof(bufRange);
    if (AudioObjectGetPropertyData(id, &rangeAddr, 0, nullptr, &bufRangeSize, &bufRange) == noErr &&
        bufRange.mMaximum > 0) {
      info.minBufferSize = static_cast<uint32_t>(std::max(16.0, bufRange.mMinimum));
      info.maxBufferSize = static_cast<uint32_t>(std::min<double>(kMaxFrames, bufRange.mMaximum));
    }

    result.push_back(std::move(info));
  }
  return result;
}

// Lock-free single-producer/single-consumer ring buffer for bridging separate
// CoreAudio input and output hardware devices (e.g. Focusrite input -> MacBook Pro Speakers output).
class AudioSampleRing {
 public:
  void clear() noexcept {
    read_.store(0, std::memory_order_relaxed);
    write_.store(0, std::memory_order_relaxed);
    samples_.fill(0.0f);
  }

  void push(const float* src, uint32_t count) noexcept {
    if (!src || count == 0) return;
    uint64_t w = write_.load(std::memory_order_relaxed);
    const uint64_t r = read_.load(std::memory_order_acquire);
    if (w - r + count > kCapacity) {
      // Drop oldest unread samples if the ring is full.
      read_.store(w + count - kCapacity, std::memory_order_release);
    }
    for (uint32_t i = 0; i < count; ++i) {
      samples_[(w + i) & kMask] = src[i];
    }
    write_.store(w + count, std::memory_order_release);
  }

  void pop(float* dst, uint32_t count, uint32_t maxQueuedFrames) noexcept {
    if (!dst || count == 0) return;
    uint64_t r = read_.load(std::memory_order_relaxed);
    const uint64_t w = write_.load(std::memory_order_acquire);
    uint64_t avail = (w >= r) ? (w - r) : 0;

    // Prevent latency build-up when input and output devices run on independent clocks.
    const uint64_t cap = std::max<uint64_t>(maxQueuedFrames, count * 2);
    if (avail > cap) {
      r = w - count * 2;
      avail = count * 2;
    }

    if (avail >= count) {
      for (uint32_t i = 0; i < count; ++i) {
        dst[i] = samples_[(r + i) & kMask];
      }
      read_.store(r + count, std::memory_order_release);
    } else {
      const uint32_t pad = count - static_cast<uint32_t>(avail);
      for (uint32_t i = 0; i < pad; ++i) {
        dst[i] = 0.0f;
      }
      for (uint32_t i = 0; i < static_cast<uint32_t>(avail); ++i) {
        dst[pad + i] = samples_[(r + i) & kMask];
      }
      read_.store(r + avail, std::memory_order_release);
    }
  }

 private:
  static constexpr uint64_t kCapacity = 32768;
  static constexpr uint64_t kMask = kCapacity - 1;
  std::array<float, kCapacity> samples_{};
  std::atomic<uint64_t> read_{0};
  std::atomic<uint64_t> write_{0};
};

struct FixedMessage {
  uint32_t size = 0;
  uint32_t format = 0;
  std::array<uint8_t, kMessageSize> bytes{};
};

// Single-producer/single-consumer queue. UI->audio and audio->UI each have
// their own instance, so the Core Audio callback never takes a mutex.
class MessageRing {
 public:
  bool push(uint32_t size, uint32_t format, const void* data) noexcept {
    if (!data || size > kMessageSize) return false;
    const size_t write = write_.load(std::memory_order_relaxed);
    const size_t next = (write + 1) % kMessageCount;
    if (next == read_.load(std::memory_order_acquire)) return false;
    slots_[write].size = size;
    slots_[write].format = format;
    std::memcpy(slots_[write].bytes.data(), data, size);
    write_.store(next, std::memory_order_release);
    return true;
  }

  bool pop(FixedMessage& message) noexcept {
    const size_t read = read_.load(std::memory_order_relaxed);
    if (read == write_.load(std::memory_order_acquire)) return false;
    message = slots_[read];
    read_.store((read + 1) % kMessageCount, std::memory_order_release);
    return true;
  }

 private:
  std::array<FixedMessage, kMessageCount> slots_{};
  std::atomic<size_t> read_{0};
  std::atomic<size_t> write_{0};
};

class StandaloneHost {
 public:
  StandaloneHost() {
    mapFeature_.handle = this;
    mapFeature_.map = mapURI;
    scheduleFeature_.handle = this;
    scheduleFeature_.schedule_work = scheduleWork;
    logFeature_.handle = this;
    logFeature_.printf = logPrintf;
    logFeature_.vprintf = logVPrintf;
    resizeFeature_.handle = this;
    resizeFeature_.ui_resize = resizeUI;

    // LV2 control defaults, in port order (ports 4..33, excluding audio port 31).
    controls_ = {0.0f, 0.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 0.0f,
                 0.0f, 0.0f, 0.0f, -80.0f, 0.0f, -1.0f, 0.0f, 1.0f,
                 1.0f, 1.0f, 0.0f, 150.0f, 2.0f, 0.0f, 0.0f,
                 20000.0f, 0.0f, 0.0f, 0.0f};
    stereoControls_ = {0.0f, 0.0f};
    advancedControls_.fill(0.0f);
    speakerControls_ = {0.0f, 25.0f, 25.0f, 50.0f, 50.0f};
    fxControls_ = {0.0f, 0.0f, 0.0f, 400.0f, 35.0f, 40.0f, 0.0f, 0.0f, 50.0f, 50.0f, 50.0f, 10.0f, 0.0f};
  }

  ~StandaloneHost() { stop(); }

  bool start(NSWindow* window, NSView* parent, NSString** error) {
    window_ = window;
    parentView_ = parent;
    loadPersistedAudioSettings();
    if (sampleRate_ <= 0.0) {
      sampleRate_ = defaultOutputSampleRate();
      if (sampleRate_ <= 0.0) sampleRate_ = 48000.0;
    }

    atomSequence_ = map(LV2_ATOM__Sequence);
    eventTransfer_ = map(LV2_ATOM__eventTransfer);
    atomInt_ = map(LV2_ATOM__Int);
    maxBlockLength_ = map(LV2_BUF_SIZE__maxBlockLength);

    maxFramesOption_ = static_cast<int32_t>(kMaxFrames);
    options_[0] = {LV2_OPTIONS_INSTANCE, 0, maxBlockLength_, sizeof(maxFramesOption_),
                   atomInt_, &maxFramesOption_};
    options_[1] = {};

    mapLV2Feature_ = {LV2_URID__map, &mapFeature_};
    scheduleLV2Feature_ = {LV2_WORKER__schedule, &scheduleFeature_};
    logLV2Feature_ = {LV2_LOG__log, &logFeature_};
    optionsLV2Feature_ = {LV2_OPTIONS__options, options_.data()};
    const LV2_Feature* dspFeatures[] = {&mapLV2Feature_, &scheduleLV2Feature_,
                                        &logLV2Feature_, &optionsLV2Feature_, nullptr};

    plugin_ = std::make_unique<NAMRig::Plugin>();
    if (!plugin_->initialize(sampleRate_, dspFeatures)) {
      return fail(error, @"The rig DSP could not be initialized.");
    }

    resetSequence(controlBuffer_, sizeof(LV2_Atom_Sequence_Body), true);
    resetSequence(notifyBuffer_, kAtomBufferSize - sizeof(LV2_Atom), true);
    plugin_->ports.control = reinterpret_cast<LV2_Atom_Sequence*>(controlBuffer_.data());
    plugin_->ports.notify = reinterpret_cast<LV2_Atom_Sequence*>(notifyBuffer_.data());
    plugin_->ports.audio_in = input_.data();
    plugin_->ports.audio_out = output_.data();
    for (uint32_t port = 4; port <= 30; ++port) {
      *reinterpret_cast<float**>(reinterpret_cast<uint8_t*>(&plugin_->ports) +
                                 port * sizeof(void*)) = &controls_[port - 4];
    }
    plugin_->ports.audio_out_r = outputR_.data();
    plugin_->ports.stereo_width = &stereoControls_[0];
    plugin_->ports.room = &stereoControls_[1];
    for (uint32_t port = 34; port <= 41; ++port) {
      *reinterpret_cast<float**>(reinterpret_cast<uint8_t*>(&plugin_->ports) +
                                 port * sizeof(void*)) = &advancedControls_[port - 34];
    }
    for (uint32_t port = 42; port <= 46; ++port) {
      *reinterpret_cast<float**>(reinterpret_cast<uint8_t*>(&plugin_->ports) +
                                 port * sizeof(void*)) = &speakerControls_[port - 42];
    }
    static_assert(offsetof(NAMRig::Plugin::Ports, cab2_polarity) == 59 * sizeof(void*));
    for (uint32_t port = 47; port <= 59; ++port) {
      *reinterpret_cast<float**>(reinterpret_cast<uint8_t*>(&plugin_->ports) +
                                 port * sizeof(void*)) = &fxControls_[port - 47];
    }
    for (size_t i = 0; i < transformerControls_.size(); ++i)
      plugin_->ports.transformer_adjustments[i] = &transformerControls_[i];

    worker_ = std::thread([this] { workerLoop(); });

    parentLV2Feature_ = {LV2_UI__parent, (__bridge void*)parent};
    mapUILV2Feature_ = {LV2_URID__map, &mapFeature_};
    resizeLV2Feature_ = {LV2_UI__resize, &resizeFeature_};
    const LV2_Feature* uiFeatures[] = {&mapUILV2Feature_, &parentLV2Feature_,
                                       &resizeLV2Feature_, nullptr};
    uiDescriptor_ = lv2ui_descriptor(0);
    if (!uiDescriptor_) return fail(error, @"The native rig UI is unavailable.");
    LV2UI_Widget widget = nullptr;
    uiHandle_ = uiDescriptor_->instantiate(uiDescriptor_, NAM_RIG_URI, nullptr, uiWrite,
                                           this, &widget, uiFeatures);
    if (!uiHandle_) return fail(error, @"The native rig UI could not be created.");

    if (!startAudio(error)) return false;
    observeDisplaySleep();
    uiTimer_ = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
                                                target:[NSBlockOperation blockOperationWithBlock:^{
                                                  this->drainUIEvents();
                                                }]
                                              selector:@selector(main)
                                              userInfo:nil
                                               repeats:YES];
    return true;
  }

  void stopAudioUnits() {
    // CoreAudio must finish its callback (and that callback's cab job) before
    // the helper leaves the old workgroup or its AudioUnit is disposed.
    // Close the callback gate even if CoreAudio reports a stop error. New
    // callbacks render silence; only the existing callback owns the cab wait.
    renderState_.fetch_or(kRenderSuspended, std::memory_order_acq_rel);
    if (audioUnit_) AudioOutputUnitStop(audioUnit_);
    while (renderState_.load(std::memory_order_acquire) & kRenderActive)
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    if (plugin_) plugin_->setCabinetWorker(nullptr);
    cabinetWorker_.stop();
    if (inputUnit_) {
      AudioOutputUnitStop(inputUnit_);
      AudioUnitUninitialize(inputUnit_);
      AudioComponentInstanceDispose(inputUnit_);
      inputUnit_ = nullptr;
    }
    if (audioUnit_) {
      AudioOutputUnitStop(audioUnit_);
      AudioUnitUninitialize(audioUnit_);
      AudioComponentInstanceDispose(audioUnit_);
      audioUnit_ = nullptr;
    }
  }

  void stop() {
    [uiTimer_ invalidate];
    uiTimer_ = nil;
    stopObservingDisplaySleep();
    stopAudioUnits();
    if (uiDescriptor_ && uiHandle_) {
      uiDescriptor_->cleanup(uiHandle_);
      uiHandle_ = nullptr;
    }
    {
      std::lock_guard<std::mutex> lock(workerMutex_);
      workerStopping_ = true;
    }
    workerCV_.notify_one();
    if (worker_.joinable()) worker_.join();
    plugin_.reset();
  }

  double sampleRate() const { return sampleRate_; }
  uint32_t bufferSize() const { return bufferSize_; }
  const std::string& inputDeviceUID() const { return inputDeviceUID_; }
  const std::string& outputDeviceUID() const { return outputDeviceUID_; }
  const std::string& activeInputDeviceName() const { return activeInputDeviceName_; }
  const std::string& activeOutputDeviceName() const { return activeOutputDeviceName_; }
  int inputChannel() const { return inputChannel_.load(std::memory_order_relaxed); }
  uint32_t activeInputChannelCount() const { return activeInputChannelCount_; }
  const std::vector<std::string>& activeInputChannelNames() const { return activeInputChannelNames_; }
  int outputChannel() const { return outputChannel_.load(std::memory_order_relaxed); }
  uint32_t activeOutputChannelCount() const { return activeOutputChannelCount_; }
  const std::vector<std::string>& activeOutputChannelNames() const { return activeOutputChannelNames_; }

  bool setInputDeviceUID(const std::string& uid, NSString** error = nullptr) {
    if (inputDeviceUID_ == uid) return true;
    const std::string prev = inputDeviceUID_;
    inputDeviceUID_ = uid;
    inputChannel_.store(0, std::memory_order_relaxed);
    if (!restartAudioEngine(error)) {
      inputDeviceUID_ = prev;
      restartAudioEngine(nullptr);
      return false;
    }
    savePersistedAudioSettings();
    return true;
  }

  bool setOutputDeviceUID(const std::string& uid, NSString** error = nullptr) {
    if (outputDeviceUID_ == uid) return true;
    const std::string prev = outputDeviceUID_;
    outputDeviceUID_ = uid;
    outputChannel_.store(-1, std::memory_order_relaxed);
    if (!restartAudioEngine(error)) {
      outputDeviceUID_ = prev;
      restartAudioEngine(nullptr);
      return false;
    }
    savePersistedAudioSettings();
    return true;
  }

  void setInputChannel(int channel) {
    inputChannel_.store(channel, std::memory_order_relaxed);
    savePersistedAudioSettings();
    lastCpuUiTime_ = 0.0;
    updateCpuDisplay();
  }

  void setOutputChannel(int channel) {
    outputChannel_.store(channel, std::memory_order_relaxed);
    savePersistedAudioSettings();
    lastCpuUiTime_ = 0.0;
    updateCpuDisplay();
  }

  bool setSampleRate(double rate, NSString** error = nullptr) {
    if (rate <= 0.0 || std::fabs(sampleRate_ - rate) < 0.5) return true;
    const double prev = sampleRate_;
    sampleRate_ = rate;
    if (!restartAudioEngine(error)) {
      sampleRate_ = prev;
      restartAudioEngine(nullptr);
      return false;
    }
    savePersistedAudioSettings();
    return true;
  }

  bool setBufferSize(uint32_t frames, NSString** error = nullptr) {
    frames = std::max<uint32_t>(32u, std::min<uint32_t>(kMaxFrames, frames));
    if (bufferSize_ == frames) return true;
    const uint32_t prev = bufferSize_;
    bufferSize_ = frames;
    if (!restartAudioEngine(error)) {
      bufferSize_ = prev;
      restartAudioEngine(nullptr);
      return false;
    }
    savePersistedAudioSettings();
    return true;
  }

  void setCpuMeterViews(NSTextField* label, NSView* barFill, NSView* barSlot) {
    cpuLabel_ = label;
    cpuBarFill_ = barFill;
    cpuBarSlot_ = barSlot;
    lastCpuUiTime_ = 0.0;
    updateCpuDisplay();
  }

  void setAnimatedAmpViews(StandaloneAnimatedAmpView* headerAmp,
                           StandaloneAnimatedAmpView* dockAmp) {
    headerAmpView_ = headerAmp;
    dockAmpView_ = dockAmp;
  }

 private:
  struct WorkItem { std::vector<uint8_t> data; };
  struct WorkResponse { std::vector<uint8_t> data; };

  static NSString* audioSettingsFilePath() {
    NSArray<NSString*>* paths = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString* base = paths.firstObject ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    NSString* dir = [base stringByAppendingPathComponent:@"Axe FX"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [dir stringByAppendingPathComponent:@"standalone-audio.json"];
  }

  void loadPersistedAudioSettings() {
    NSData* data = [NSData dataWithContentsOfFile:audioSettingsFilePath()];
    if (!data) return;
    NSDictionary* dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![dict isKindOfClass:[NSDictionary class]]) return;
    if ([dict[@"inputDeviceUID"] isKindOfClass:[NSString class]]) {
      inputDeviceUID_ = [dict[@"inputDeviceUID"] UTF8String] ?: "";
    }
    if ([dict[@"outputDeviceUID"] isKindOfClass:[NSString class]]) {
      outputDeviceUID_ = [dict[@"outputDeviceUID"] UTF8String] ?: "";
    }
    if ([dict[@"inputChannel"] respondsToSelector:@selector(intValue)]) {
      inputChannel_.store([dict[@"inputChannel"] intValue], std::memory_order_relaxed);
    }
    if ([dict[@"outputChannel"] respondsToSelector:@selector(intValue)]) {
      outputChannel_.store([dict[@"outputChannel"] intValue], std::memory_order_relaxed);
    }
    if ([dict[@"sampleRate"] respondsToSelector:@selector(doubleValue)]) {
      const double sr = [dict[@"sampleRate"] doubleValue];
      if (sr >= 44100.0 && sr <= 192000.0) sampleRate_ = sr;
    }
    if ([dict[@"bufferSize"] respondsToSelector:@selector(unsignedIntValue)]) {
      const uint32_t bs = [dict[@"bufferSize"] unsignedIntValue];
      if (bs >= 32 && bs <= kMaxFrames) bufferSize_ = bs;
    }
  }

  void savePersistedAudioSettings() const {
    NSDictionary* dict = @{
      @"inputDeviceUID": [NSString stringWithUTF8String:inputDeviceUID_.c_str()] ?: @"",
      @"outputDeviceUID": [NSString stringWithUTF8String:outputDeviceUID_.c_str()] ?: @"",
      @"inputChannel": @(inputChannel_.load(std::memory_order_relaxed)),
      @"outputChannel": @(outputChannel_.load(std::memory_order_relaxed)),
      @"sampleRate": @(sampleRate_),
      @"bufferSize": @(bufferSize_),
    };
    NSData* data = [NSJSONSerialization dataWithJSONObject:dict
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (data) {
      [data writeToFile:audioSettingsFilePath() atomically:YES];
    }
  }

  bool restartAudioEngine(NSString** error) {
    stopAudioUnits();
    if (plugin_ && std::fabs(plugin_->sampleRate - sampleRate_) > 0.5) {
      plugin_->setSampleRateAndReload(sampleRate_);
    }
    const bool ok = startAudio(error);
    lastCpuUiTime_ = 0.0;
    updateCpuDisplay();
    return ok;
  }

  static bool fail(NSString** error, NSString* message) {
    if (error) *error = message;
    return false;
  }

  LV2_URID map(const char* uri) {
    std::lock_guard<std::mutex> lock(uriMutex_);
    const auto found = urids_.find(uri);
    if (found != urids_.end()) return found->second;
    const LV2_URID id = static_cast<LV2_URID>(uris_.size() + 1);
    uris_.emplace_back(uri);
    urids_.emplace(uris_.back(), id);
    return id;
  }

  static LV2_URID mapURI(LV2_URID_Map_Handle handle, const char* uri) {
    return static_cast<StandaloneHost*>(handle)->map(uri);
  }

  static int logVPrintf(LV2_Log_Handle, LV2_URID, const char* format, va_list args) {
    return std::vfprintf(stderr, format, args);
  }

  static int logPrintf(LV2_Log_Handle handle, LV2_URID type, const char* format, ...) {
    va_list args;
    va_start(args, format);
    const int result = logVPrintf(handle, type, format, args);
    va_end(args);
    return result;
  }

  static LV2_Worker_Status scheduleWork(LV2_Worker_Schedule_Handle handle,
                                        uint32_t size, const void* data) {
    auto* host = static_cast<StandaloneHost*>(handle);
    if (!data || !size) return LV2_WORKER_ERR_UNKNOWN;
    WorkItem item;
    item.data.resize(size);
    std::memcpy(item.data.data(), data, size);
    {
      std::lock_guard<std::mutex> lock(host->workerMutex_);
      host->work_.push_back(std::move(item));
    }
    host->workerCV_.notify_one();
    return LV2_WORKER_SUCCESS;
  }

  static LV2_Worker_Status respondWork(LV2_Worker_Respond_Handle handle,
                                       uint32_t size, const void* data) {
    auto* host = static_cast<StandaloneHost*>(handle);
    WorkResponse response;
    response.data.resize(size);
    std::memcpy(response.data.data(), data, size);
    std::lock_guard<std::mutex> lock(host->responseMutex_);
    host->responses_.push_back(std::move(response));
    return LV2_WORKER_SUCCESS;
  }

  void workerLoop() {
    for (;;) {
      WorkItem item;
      {
        std::unique_lock<std::mutex> lock(workerMutex_);
        workerCV_.wait(lock, [this] { return workerStopping_ || !work_.empty(); });
        if (workerStopping_ && work_.empty()) return;
        item = std::move(work_.front());
        work_.pop_front();
      }
      NAMRig::Plugin::work(plugin_.get(), respondWork, this,
                           static_cast<uint32_t>(item.data.size()), item.data.data());
    }
  }

  void applyWorkerResponses() noexcept {
    if (!responseMutex_.try_lock()) return;
    std::deque<WorkResponse> local;
    local.swap(responses_);
    responseMutex_.unlock();
    for (const auto& response : local)
      NAMRig::Plugin::workResponse(plugin_.get(),
                                   static_cast<uint32_t>(response.data.size()),
                                   response.data.data());
  }

  static void uiWrite(LV2UI_Controller controller, uint32_t port, uint32_t size,
                      uint32_t format, const void* buffer) {
    auto* host = static_cast<StandaloneHost*>(controller);
    if (format == 0 && port >= 4 && port <= 30 && size == sizeof(float)) {
      host->controls_[port - 4] = *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port >= 32 && port <= 33 && size == sizeof(float)) {
      host->stereoControls_[port - 32] = *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port >= 34 && port <= 41 && size == sizeof(float)) {
      host->advancedControls_[port - 34] = *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port >= 42 && port <= 46 && size == sizeof(float)) {
      host->speakerControls_[port - 42] = *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port >= 47 && port <= 59 && size == sizeof(float)) {
      host->fxControls_[port - 47] = *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port >= NAMRig::kTransformerControlFirstPort &&
        port < NAMRig::Plugin::kPortCount && size == sizeof(float)) {
      host->transformerControls_[port - NAMRig::kTransformerControlFirstPort] =
          *static_cast<const float*>(buffer);
      return;
    }
    if (port == 0 && format == host->eventTransfer_)
      host->uiToAudio_.push(size, format, buffer);
  }

  static int resizeUI(LV2UI_Feature_Handle handle, int width, int height) {
    auto* host = static_cast<StandaloneHost*>(handle);
    if (!host->window_) return 1;
    if (host->parentView_) {
      host->parentView_.frame = NSMakeRect(0, 0, width, height);
    }
    NSRect content = NSMakeRect(0, 0, width, height + kToolbarStripHeight);
    NSRect frame = [host->window_ frameRectForContentRect:content];
    NSRect old = host->window_.frame;
    frame.origin.x = old.origin.x;
    frame.origin.y = NSMaxY(old) - frame.size.height;
    [host->window_ setFrame:frame display:YES animate:NO];
    [host->window_.contentView setNeedsLayout:YES];
    [host->window_.contentView setNeedsDisplay:YES];
    return 0;
  }

  // Only the sequence header needs clearing: readers stop at atom.size, the
  // forge overwrites whatever it appends, and buildControlSequence() zeroes
  // its own event padding. Pass fullClear only at setup, never per block
  // (clearing both 16 KB buffers every callback was pure audio-thread churn).
  void resetSequence(std::array<uint8_t, kAtomBufferSize>& buffer, uint32_t size,
                     bool fullClear = false) {
    if (fullClear) std::memset(buffer.data(), 0, buffer.size());
    else std::memset(buffer.data(), 0, sizeof(LV2_Atom_Sequence));
    auto* sequence = reinterpret_cast<LV2_Atom_Sequence*>(buffer.data());
    sequence->atom.type = atomSequence_;
    sequence->atom.size = size;
  }

  void buildControlSequence() noexcept {
    resetSequence(controlBuffer_, sizeof(LV2_Atom_Sequence_Body));
    auto* sequence = reinterpret_cast<LV2_Atom_Sequence*>(controlBuffer_.data());
    size_t used = sizeof(LV2_Atom_Sequence);
    FixedMessage message;
    while (uiToAudio_.pop(message)) {
      const size_t eventSize = sizeof(int64_t) + message.size;
      const size_t padded = lv2_atom_pad_size(static_cast<uint32_t>(eventSize));
      if (used + padded > controlBuffer_.size()) break;
      auto* event = reinterpret_cast<LV2_Atom_Event*>(controlBuffer_.data() + used);
      event->time.frames = 0;
      std::memcpy(&event->body, message.bytes.data(), message.size);
      if (padded > eventSize)
        std::memset(reinterpret_cast<uint8_t*>(event) + eventSize, 0, padded - eventSize);
      used += padded;
      sequence->atom.size += static_cast<uint32_t>(padded);
    }
  }

  void collectNotifications() noexcept {
    auto* sequence = reinterpret_cast<LV2_Atom_Sequence*>(notifyBuffer_.data());
    LV2_ATOM_SEQUENCE_FOREACH(sequence, event) {
      const uint32_t size = lv2_atom_total_size(&event->body);
      audioToUI_.push(size, eventTransfer_, &event->body);
    }
  }

  void drainUIEvents() {
    if (!uiDescriptor_ || !uiHandle_) return;
    FixedMessage message;
    while (audioToUI_.pop(message))
      uiDescriptor_->port_event(uiHandle_, 1, message.size, message.format,
                                message.bytes.data());

    // Output controls are cheap to poll at UI rate (tuner and auto-cab state).
    for (uint32_t port : {11u, 17u, 18u, 29u})
      uiDescriptor_->port_event(uiHandle_, port, sizeof(float), 0, &controls_[port - 4]);

    updateCpuDisplay();
    updateAnimatedAmpIcons();
  }

  // Animation is purely cosmetic, so it only runs while someone can see it:
  // the header icon while the window is actually on screen (not minimized,
  // hidden, or fully covered), the Dock icon while the display is awake and
  // this login session is in front. When nothing is visible the audio thread
  // also stops computing the peak that drives them (ampIconsVisible_).
  void updateAnimatedAmpIcons() {
    const bool headerVisible = headerAmpView_ && window_ && !NSApp.isHidden &&
        (window_.occlusionState & NSWindowOcclusionStateVisible) != 0;
    const bool dockVisible = dockAmpView_ && !displayAsleep_;
    ampIconsVisible_.store(headerVisible || dockVisible, std::memory_order_relaxed);
    if (!headerVisible && !dockVisible) return;

    ampPhase_ += 0.085;
    const float sig = signalLevel_.load(std::memory_order_relaxed);
    if (headerVisible) {
      headerAmpView_.phase = ampPhase_;
      headerAmpView_.signalLevel = sig;
      [headerAmpView_ setNeedsDisplay:YES];
    }
    if (dockVisible && (++dockFrameTick_ % 3 == 0)) {
      dockAmpView_.phase = ampPhase_;
      dockAmpView_.signalLevel = sig;
      [dockAmpView_ setNeedsDisplay:YES];
      [[NSApp dockTile] display];
    }
  }

  void observeDisplaySleep() {
    NSNotificationCenter* center = [[NSWorkspace sharedWorkspace] notificationCenter];
    auto setAsleep = [this, center](NSNotificationName name, bool asleep) {
      id token = [center addObserverForName:name
                                     object:nil
                                      queue:[NSOperationQueue mainQueue]
                                 usingBlock:^(NSNotification*) { this->displayAsleep_ = asleep; }];
      if (token) displayObservers_.push_back(token);
    };
    setAsleep(NSWorkspaceScreensDidSleepNotification, true);
    setAsleep(NSWorkspaceScreensDidWakeNotification, false);
    setAsleep(NSWorkspaceSessionDidResignActiveNotification, true);
    setAsleep(NSWorkspaceSessionDidBecomeActiveNotification, false);
  }

  void stopObservingDisplaySleep() {
    NSNotificationCenter* center = [[NSWorkspace sharedWorkspace] notificationCenter];
    for (id token : displayObservers_) [center removeObserver:token];
    displayObservers_.clear();
  }

  void updateCpuDisplay() {
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastCpuUiTime_ < 0.5) return;
    lastCpuUiTime_ = now;
    const float pct = cpuLoadPercent_.load(std::memory_order_relaxed);
    const float clamped = std::max(0.0f, std::min(100.0f, pct));
    if (cpuLabel_) {
      cpuLabel_.stringValue = [NSString stringWithFormat:@"CPU %4.1f%%", clamped];
    }
    if (cpuBarFill_ && cpuBarSlot_) {
      const CGFloat slotW = cpuBarSlot_.bounds.size.width;
      const CGFloat fillW = std::max<CGFloat>(0.0, std::min<CGFloat>(slotW, slotW * (clamped / 100.0f)));
      cpuBarFill_.frame = NSMakeRect(0, 0, fillW, cpuBarSlot_.bounds.size.height);
      NSColor* fillColor =
          clamped > 80.0f ? [NSColor colorWithSRGBRed:0.95 green:0.22 blue:0.20 alpha:1.0]
        : clamped > 50.0f ? [NSColor colorWithSRGBRed:1.00 green:0.60 blue:0.20 alpha:1.0]
                          : [NSColor colorWithSRGBRed:0.20 green:0.82 blue:0.96 alpha:1.0];
      cpuBarFill_.layer.backgroundColor = fillColor.CGColor;
    }
    if (window_) {
      NSString* inName = [NSString stringWithUTF8String:activeInputDeviceName_.c_str()] ?: @"Default Input";
      NSString* outName = [NSString stringWithUTF8String:activeOutputDeviceName_.c_str()] ?: @"Default Output";
      const int ch = inputChannel_.load(std::memory_order_relaxed);
      NSString* chSuffix = (activeInputChannelCount_ > 1)
          ? (ch < 0 ? @" (In 1+2)" : [NSString stringWithFormat:@" (In %d)", ch + 1])
          : @"";
      window_.subtitle = [NSString stringWithFormat:@"%@%@ → %@ · %.1f kHz · %u smp · CPU %.1f%%",
                                                    inName, chSuffix, outName,
                                                    sampleRate_ / 1000.0, bufferSize_, clamped];
    }
  }

  void extractSelectedChannel(const AudioBufferList* captureList,
                              UInt32 frames,
                              float* dstMono) noexcept {
    if (!captureList || captureList->mNumberBuffers == 0) {
      std::fill_n(dstMono, frames, 0.0f);
      return;
    }
    const int sel = inputChannel_.load(std::memory_order_relaxed);
    if (sel < 0 && captureList->mNumberBuffers >= 2) {
      const float* ch0 = static_cast<const float*>(captureList->mBuffers[0].mData);
      const float* ch1 = static_cast<const float*>(captureList->mBuffers[1].mData);
      if (ch0 && ch1) {
        for (UInt32 i = 0; i < frames; ++i) {
          dstMono[i] = 0.5f * (ch0[i] + ch1[i]);
        }
        return;
      }
    }
    const UInt32 bufIdx = (sel >= 0 && static_cast<UInt32>(sel) < captureList->mNumberBuffers)
                              ? static_cast<UInt32>(sel)
                              : 0u;
    const float* src = static_cast<const float*>(captureList->mBuffers[bufIdx].mData);
    if (src) {
      std::copy_n(src, frames, dstMono);
    } else {
      std::fill_n(dstMono, frames, 0.0f);
    }
  }

  AudioBufferList* prepareCaptureBufferList(UInt32 frames) noexcept {
    auto* list = reinterpret_cast<AudioBufferList*>(captureListStorage_.data());
    const UInt32 nBufs = std::max<UInt32>(1u, std::min<UInt32>(captureChannels_, kMaxInputChannels));
    list->mNumberBuffers = nBufs;
    for (UInt32 ch = 0; ch < nBufs; ++ch) {
      list->mBuffers[ch].mNumberChannels = 1;
      list->mBuffers[ch].mDataByteSize = frames * sizeof(float);
      list->mBuffers[ch].mData = captureChannelData_[ch].data();
    }
    return list;
  }

  static OSStatus inputRender(void* context, AudioUnitRenderActionFlags* flags,
                              const AudioTimeStamp* timestamp, UInt32 busNumber,
                              UInt32 frames, AudioBufferList*) {
    return static_cast<StandaloneHost*>(context)->captureInputAudio(
        flags, timestamp, busNumber, frames);
  }

  OSStatus captureInputAudio(AudioUnitRenderActionFlags* flags,
                             const AudioTimeStamp* timestamp,
                             UInt32 busNumber,
                             UInt32 frames) noexcept {
    if (!inputUnit_ || frames == 0 || frames > kMaxFrames) return noErr;
    AudioBufferList* captureList = prepareCaptureBufferList(frames);
    const OSStatus status = AudioUnitRender(inputUnit_, flags, timestamp,
                                            busNumber, frames, captureList);
    if (status == noErr) {
      extractSelectedChannel(captureList, frames, captureMonoScratch_.data());
      inputRing_.push(captureMonoScratch_.data(), frames);
    } else {
      std::fill_n(captureMonoScratch_.data(), frames, 0.0f);
      inputRing_.push(captureMonoScratch_.data(), frames);
    }
    return noErr;
  }

  static OSStatus render(void* context, AudioUnitRenderActionFlags* flags,
                         const AudioTimeStamp* timestamp, UInt32, UInt32 frames,
                         AudioBufferList* ioData) {
    return static_cast<StandaloneHost*>(context)->renderAudio(flags, timestamp, frames, ioData);
  }

  OSStatus renderAudio(AudioUnitRenderActionFlags* flags, const AudioTimeStamp* timestamp,
                       UInt32 frames, AudioBufferList* ioData) noexcept {
    uint32_t expected = 0;
    if (frames > kMaxFrames || !ioData || ioData->mNumberBuffers == 0 ||
        !renderState_.compare_exchange_strong(expected, kRenderActive,
                                              std::memory_order_acquire)) {
      if (ioData)
        for (UInt32 i = 0; i < ioData->mNumberBuffers; ++i)
          if (ioData->mBuffers[i].mData)
            std::memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
      return noErr;
    }
    struct RenderGuard {
      std::atomic<uint32_t>& state;
      ~RenderGuard() { state.fetch_and(~kRenderActive, std::memory_order_release); }
    } guard{renderState_};

    const auto t0 = std::chrono::steady_clock::now();
    // The helper arrives after capture and amp processing. Use the remaining
    // callback budget, reserving 10% for blending/EQ/FX, not a fresh full period.
    const uint64_t cabinetDeadline = mach_absolute_time() +
        static_cast<uint64_t>(frames * audioTicksPerFrame_ * 0.9);

    if (useSplitInputUnit_) {
      if (inputUnit_) {
        inputRing_.pop(input_.data(), frames, std::max<uint32_t>(bufferSize_ * 3, frames * 3));
      } else {
        std::fill_n(input_.data(), frames, 0.0f);
      }
    } else {
      AudioBufferList* captureList = prepareCaptureBufferList(frames);
      const OSStatus status = AudioUnitRender(audioUnit_, flags, timestamp, 1, frames, captureList);
      if (status == noErr) {
        extractSelectedChannel(captureList, frames, input_.data());
      } else {
        std::fill_n(input_.data(), frames, 0.0f);
      }
    }

    applyWorkerResponses();
    buildControlSequence();
    resetSequence(notifyBuffer_, kAtomBufferSize - sizeof(LV2_Atom));
    plugin_->process(frames, cabinetDeadline);
    collectNotifications();

    // The block peak only drives the animated amp icons; skip the scan while
    // neither icon is on screen (the main thread publishes that flag).
    if (ampIconsVisible_.load(std::memory_order_relaxed)) {
      float blockPeak = 0.0f;
      for (UInt32 i = 0; i < frames; ++i) {
        const float a = std::fabs(output_[i]);
        const float b = std::fabs(outputR_[i]);
        if (a > blockPeak) blockPeak = a;
        if (b > blockPeak) blockPeak = b;
      }
      const float prevSig = signalLevel_.load(std::memory_order_relaxed);
      const float normPeak = std::min(1.0f, blockPeak * 1.8f);
      const float nextSig = normPeak > prevSig ? (0.4f * prevSig + 0.6f * normPeak)
                                               : (0.92f * prevSig + 0.08f * normPeak);
      signalLevel_.store(nextSig, std::memory_order_relaxed);
    }

    const int outCh = outputChannel_.load(std::memory_order_relaxed);
    auto writeChannelSample = [&](UInt32 chIdx, UInt32 frameIdx, float* chPtr, UInt32 stride) {
      float sample = 0.0f;
      if (outCh == -1) {
        if (chIdx == 0) sample = output_[frameIdx];
        else if (chIdx == 1) sample = outputR_[frameIdx];
      } else if (outCh == -2) {
        if (chIdx == 0 || chIdx == 1) sample = 0.5f * (output_[frameIdx] + outputR_[frameIdx]);
      } else if (outCh <= -100) {
        const UInt32 pairIdx = static_cast<UInt32>(-(outCh + 100));
        const UInt32 leftCh = pairIdx * 2u;
        const UInt32 rightCh = leftCh + 1u;
        if (chIdx == leftCh) sample = output_[frameIdx];
        else if (chIdx == rightCh) sample = outputR_[frameIdx];
      } else if (outCh >= 0 && chIdx == static_cast<UInt32>(outCh)) {
        sample = 0.5f * (output_[frameIdx] + outputR_[frameIdx]);
      }
      chPtr[frameIdx * stride] = sample;
    };

    if (ioData->mNumberBuffers >= 2 &&
        ioData->mBuffers[0].mNumberChannels == 1) {
      const UInt32 numBufs = ioData->mNumberBuffers;
      for (UInt32 b = 0; b < numBufs; ++b) {
        float* buf = static_cast<float*>(ioData->mBuffers[b].mData);
        if (!buf) continue;
        if (outCh == -1) {
          if (b == 0) std::copy_n(output_.data(), frames, buf);
          else if (b == 1) std::copy_n(outputR_.data(), frames, buf);
          else std::fill_n(buf, frames, 0.0f);
        } else if (outCh == -2) {
          if (b == 0 || b == 1) {
            for (UInt32 f = 0; f < frames; ++f) buf[f] = 0.5f * (output_[f] + outputR_[f]);
          } else {
            std::fill_n(buf, frames, 0.0f);
          }
        } else {
          for (UInt32 f = 0; f < frames; ++f) writeChannelSample(b, f, buf, 1);
        }
      }
    } else if (ioData->mNumberBuffers > 0) {
      float* destination = static_cast<float*>(ioData->mBuffers[0].mData);
      const UInt32 channels = ioData->mBuffers[0].mNumberChannels;
      if (destination && channels >= 2) {
        for (UInt32 frame = 0; frame < frames; ++frame) {
          for (UInt32 ch = 0; ch < channels; ++ch) {
            writeChannelSample(ch, frame, destination + ch, channels);
          }
        }
      } else if (destination) {
        for (UInt32 frame = 0; frame < frames; ++frame)
          destination[frame] = 0.5f * (output_[frame] + outputR_[frame]);
      }
    }

    const auto t1 = std::chrono::steady_clock::now();
    if (sampleRate_ > 0.0 && frames > 0) {
      const double elapsedSec = std::chrono::duration<double>(t1 - t0).count();
      const double budgetSec = static_cast<double>(frames) / sampleRate_;
      if (budgetSec > 0.0) {
        float pct = static_cast<float>((elapsedSec / budgetSec) * 100.0);
        if (pct < 0.0f) pct = 0.0f;
        if (pct > 100.0f) pct = 100.0f;
        const float prev = cpuLoadPercent_.load(std::memory_order_relaxed);
        const float smoothed = prev <= 0.001f ? pct : (0.95f * prev + 0.05f * pct);
        cpuLoadPercent_.store(smoothed, std::memory_order_relaxed);
      }
    }
    return noErr;
  }

  static double defaultOutputSampleRate() {
    AudioDeviceID device = defaultAudioDeviceID(false);
    return queryDeviceNominalSampleRate(device);
  }

  bool configureSingleDuplexHAL(AudioDeviceID device, uint32_t inChannels, double streamRate) {
    stopAudioUnits();
    useSplitInputUnit_ = false;
    captureChannels_ = std::max<uint32_t>(1u, std::min<uint32_t>(inChannels, kMaxInputChannels));
    outputChannels_ = std::max<uint32_t>(2u, std::min<uint32_t>(activeOutputChannelCount_, kMaxInputChannels));

    AudioComponentDescription description{};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_HALOutput;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent component = AudioComponentFindNext(nullptr, &description);
    if (!component || AudioComponentInstanceNew(component, &audioUnit_) != noErr)
      return false;

    UInt32 enableIn = 1;
    UInt32 enableOut = 1;
    if (AudioUnitSetProperty(audioUnit_, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, &enableIn, sizeof(enableIn)) != noErr ||
        AudioUnitSetProperty(audioUnit_, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output, 0, &enableOut, sizeof(enableOut)) != noErr) {
      stopAudioUnits();
      return false;
    }

    if (device != kAudioObjectUnknown) {
      if (AudioUnitSetProperty(audioUnit_, kAudioOutputUnitProperty_CurrentDevice,
                               kAudioUnitScope_Global, 0, &device, sizeof(device)) != noErr) {
        stopAudioUnits();
        return false;
      }
    }

    AudioStreamBasicDescription inputFormat{};
    inputFormat.mSampleRate = streamRate;
    inputFormat.mFormatID = kAudioFormatLinearPCM;
    inputFormat.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) |
                               static_cast<AudioFormatFlags>(kAudioFormatFlagIsNonInterleaved);
    inputFormat.mFramesPerPacket = 1;
    inputFormat.mChannelsPerFrame = captureChannels_;
    inputFormat.mBitsPerChannel = 32;
    inputFormat.mBytesPerFrame = sizeof(float);
    inputFormat.mBytesPerPacket = sizeof(float);

    AudioStreamBasicDescription outputFormat = inputFormat;
    outputFormat.mChannelsPerFrame = outputChannels_;

    if (AudioUnitSetProperty(audioUnit_, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, 1, &inputFormat,
                             sizeof(inputFormat)) != noErr) {
      stopAudioUnits();
      return false;
    }
    if (AudioUnitSetProperty(audioUnit_, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0, &outputFormat,
                             sizeof(outputFormat)) != noErr) {
      outputFormat.mChannelsPerFrame = 2;
      outputChannels_ = 2;
      if (AudioUnitSetProperty(audioUnit_, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &outputFormat,
                               sizeof(outputFormat)) != noErr) {
        stopAudioUnits();
        return false;
      }
    }

    UInt32 maxFrames = kMaxFrames;
    AudioUnitSetProperty(audioUnit_, kAudioUnitProperty_MaximumFramesPerSlice,
                         kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames));
    AURenderCallbackStruct callback{render, this};
    if (AudioUnitSetProperty(audioUnit_, kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input, 0, &callback, sizeof(callback)) != noErr ||
        AudioUnitInitialize(audioUnit_) != noErr ||
        !startOutputAudio(streamRate)) {
      stopAudioUnits();
      return false;
    }
    return true;
  }

  bool configureSplitHAL(AudioDeviceID inDevice,
                         uint32_t inChannels,
                         AudioDeviceID outDevice,
                         double streamRate) {
    stopAudioUnits();
    useSplitInputUnit_ = true;
    inputRing_.clear();
    captureChannels_ = std::max<uint32_t>(1u, std::min<uint32_t>(inChannels, kMaxInputChannels));
    outputChannels_ = std::max<uint32_t>(2u, std::min<uint32_t>(activeOutputChannelCount_, kMaxInputChannels));

    AudioComponentDescription description{};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_HALOutput;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent component = AudioComponentFindNext(nullptr, &description);
    if (!component) return false;

    // 1. Configure dedicated Input HAL unit if an input device with input channels is available.
    if (inDevice != kAudioObjectUnknown && inChannels > 0) {
      if (AudioComponentInstanceNew(component, &inputUnit_) == noErr) {
        UInt32 enableIn = 1;
        UInt32 disableOut = 0;
        bool inputOk =
            AudioUnitSetProperty(inputUnit_, kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input, 1, &enableIn, sizeof(enableIn)) == noErr &&
            AudioUnitSetProperty(inputUnit_, kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Output, 0, &disableOut, sizeof(disableOut)) == noErr &&
            AudioUnitSetProperty(inputUnit_, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &inDevice, sizeof(inDevice)) == noErr;

        if (inputOk) {
          AudioStreamBasicDescription inputFormat{};
          inputFormat.mSampleRate = streamRate;
          inputFormat.mFormatID = kAudioFormatLinearPCM;
          inputFormat.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) |
                               static_cast<AudioFormatFlags>(kAudioFormatFlagIsNonInterleaved);
          inputFormat.mFramesPerPacket = 1;
          inputFormat.mChannelsPerFrame = captureChannels_;
          inputFormat.mBitsPerChannel = 32;
          inputFormat.mBytesPerFrame = sizeof(float);
          inputFormat.mBytesPerPacket = sizeof(float);

          UInt32 maxFrames = kMaxFrames;
          AudioUnitSetProperty(inputUnit_, kAudioUnitProperty_MaximumFramesPerSlice,
                               kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames));
          AURenderCallbackStruct inCallback{inputRender, this};
          inputOk =
              AudioUnitSetProperty(inputUnit_, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output, 1, &inputFormat,
                                   sizeof(inputFormat)) == noErr &&
              AudioUnitSetProperty(inputUnit_, kAudioOutputUnitProperty_SetInputCallback,
                                   kAudioUnitScope_Global, 0, &inCallback,
                                   sizeof(inCallback)) == noErr &&
              AudioUnitInitialize(inputUnit_) == noErr &&
              AudioOutputUnitStart(inputUnit_) == noErr;
        }
        if (!inputOk) {
          AudioUnitUninitialize(inputUnit_);
          AudioComponentInstanceDispose(inputUnit_);
          inputUnit_ = nullptr;
        }
      }
    }

    // 2. Configure dedicated Output HAL unit.
    if (outDevice == kAudioObjectUnknown ||
        AudioComponentInstanceNew(component, &audioUnit_) != noErr) {
      stopAudioUnits();
      return false;
    }

    UInt32 enableOut = 1;
    UInt32 disableIn = 0;
    if (AudioUnitSetProperty(audioUnit_, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output, 0, &enableOut, sizeof(enableOut)) != noErr ||
        AudioUnitSetProperty(audioUnit_, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, &disableIn, sizeof(disableIn)) != noErr ||
        AudioUnitSetProperty(audioUnit_, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &outDevice, sizeof(outDevice)) != noErr) {
      stopAudioUnits();
      return false;
    }

    AudioStreamBasicDescription outputFormat{};
    outputFormat.mSampleRate = streamRate;
    outputFormat.mFormatID = kAudioFormatLinearPCM;
    outputFormat.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) |
                               static_cast<AudioFormatFlags>(kAudioFormatFlagIsNonInterleaved);
    outputFormat.mFramesPerPacket = 1;
    outputFormat.mChannelsPerFrame = outputChannels_;
    outputFormat.mBitsPerChannel = 32;
    outputFormat.mBytesPerFrame = sizeof(float);
    outputFormat.mBytesPerPacket = sizeof(float);

    UInt32 maxFrames = kMaxFrames;
    AudioUnitSetProperty(audioUnit_, kAudioUnitProperty_MaximumFramesPerSlice,
                         kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames));
    AURenderCallbackStruct outCallback{render, this};
    if (AudioUnitSetProperty(audioUnit_, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0, &outputFormat,
                             sizeof(outputFormat)) != noErr) {
      outputFormat.mChannelsPerFrame = 2;
      outputChannels_ = 2;
      if (AudioUnitSetProperty(audioUnit_, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &outputFormat,
                               sizeof(outputFormat)) != noErr) {
        stopAudioUnits();
        return false;
      }
    }
    if (AudioUnitSetProperty(audioUnit_, kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input, 0, &outCallback,
                             sizeof(outCallback)) != noErr ||
        AudioUnitInitialize(audioUnit_) != noErr ||
        !startOutputAudio(streamRate)) {
      stopAudioUnits();
      return false;
    }
    return true;
  }

  bool configureVoiceProcessingFallback(double streamRate) {
    stopAudioUnits();
    useSplitInputUnit_ = false;
    captureChannels_ = 1;

    AudioComponentDescription description{};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_VoiceProcessingIO;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent component = AudioComponentFindNext(nullptr, &description);
    if (!component || AudioComponentInstanceNew(component, &audioUnit_) != noErr)
      return false;

    UInt32 enabled = 1;
    if (AudioUnitSetProperty(audioUnit_, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, &enabled, sizeof(enabled)) != noErr) {
      stopAudioUnits();
      return false;
    }

    UInt32 bypass = 1;
    AudioUnitSetProperty(audioUnit_, kAUVoiceIOProperty_BypassVoiceProcessing,
                         kAudioUnitScope_Global, 0, &bypass, sizeof(bypass));
    UInt32 agc = 0;
    AudioUnitSetProperty(audioUnit_, kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                         kAudioUnitScope_Global, 0, &agc, sizeof(agc));

    AudioStreamBasicDescription inputFormat{};
    inputFormat.mSampleRate = streamRate;
    inputFormat.mFormatID = kAudioFormatLinearPCM;
    inputFormat.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) |
                               static_cast<AudioFormatFlags>(kAudioFormatFlagIsNonInterleaved);
    inputFormat.mFramesPerPacket = 1;
    inputFormat.mChannelsPerFrame = 1;
    inputFormat.mBitsPerChannel = 32;
    inputFormat.mBytesPerFrame = sizeof(float);
    inputFormat.mBytesPerPacket = sizeof(float);
    AudioStreamBasicDescription outputFormat = inputFormat;
    outputFormat.mChannelsPerFrame = 2;

    if (AudioUnitSetProperty(audioUnit_, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, 1, &inputFormat,
                             sizeof(inputFormat)) != noErr ||
        AudioUnitSetProperty(audioUnit_, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0, &outputFormat,
                             sizeof(outputFormat)) != noErr) {
      stopAudioUnits();
      return false;
    }

    UInt32 maxFrames = kMaxFrames;
    AudioUnitSetProperty(audioUnit_, kAudioUnitProperty_MaximumFramesPerSlice,
                         kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames));
    AURenderCallbackStruct callback{render, this};
    if (AudioUnitSetProperty(audioUnit_, kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input, 0, &callback, sizeof(callback)) != noErr ||
        AudioUnitInitialize(audioUnit_) != noErr || !startOutputAudio(streamRate)) {
      stopAudioUnits();
      return false;
    }
    return true;
  }

  bool startOutputAudio(double streamRate) {
    mach_timebase_info_data_t timebase{};
    mach_timebase_info(&timebase);
    audioTicksPerFrame_ = timebase.numer > 0
        ? 1.0e9 * timebase.denom / (timebase.numer * streamRate) : 0.0;
    // Experimental opt-in until real-device deadline benchmarks are available.
    const char* parallel = std::getenv("AXE_FX_PARALLEL_CABS");
    if (parallel && std::strcmp(parallel, "1") == 0) {
      void* rawGroup = nullptr;
      UInt32 size = sizeof(rawGroup);
      if (AudioUnitGetProperty(audioUnit_, kAudioOutputUnitProperty_OSWorkgroup,
                               kAudioUnitScope_Global, 0, &rawGroup, &size) == noErr && rawGroup) {
        // AudioUnitGetProperty returns +1; ARC releases our reference after
        // the helper has retained it for its entire join/leave lifetime.
        os_workgroup_t group = (__bridge_transfer os_workgroup_t)rawGroup;
        if (os_workgroup_max_parallel_threads(group, nullptr) > 1 &&
            cabinetWorker_.start((__bridge void*)group, bufferSize_ / streamRate))
          plugin_->setCabinetWorker(&cabinetWorker_);
      }
    }
    renderState_.store(0, std::memory_order_release);
    return AudioOutputUnitStart(audioUnit_) == noErr;
  }

  bool startAudio(NSString** error) {
    const auto devices = enumerateAudioDevices();
    AudioDeviceID inDev = defaultAudioDeviceID(true);
    AudioDeviceID outDev = defaultAudioDeviceID(false);

    if (!inputDeviceUID_.empty()) {
      for (const auto& d : devices) {
        if (d.uid == inputDeviceUID_ && d.inputChannels > 0) {
          inDev = d.deviceID;
          break;
        }
      }
    }
    if (!outputDeviceUID_.empty()) {
      for (const auto& d : devices) {
        if (d.uid == outputDeviceUID_ && d.outputChannels > 0) {
          outDev = d.deviceID;
          break;
        }
      }
    }

    activeInputDeviceName_ = "Default Input";
    activeOutputDeviceName_ = "Default Output";
    activeInputChannelCount_ = 1;
    activeInputChannelNames_ = {"Input 1"};
    activeOutputChannelCount_ = 2;
    activeOutputChannelNames_ = {"Output 1", "Output 2"};

    for (const auto& d : devices) {
      if (d.deviceID == inDev && d.inputChannels > 0) {
        activeInputDeviceName_ = d.name;
        activeInputChannelCount_ = d.inputChannels;
        activeInputChannelNames_ = d.inputChannelNames;
      }
      if (d.deviceID == outDev && d.outputChannels > 0) {
        activeOutputDeviceName_ = d.name;
        activeOutputChannelCount_ = d.outputChannels;
        activeOutputChannelNames_ = d.outputChannelNames;
      }
    }

    const int curCh = inputChannel_.load(std::memory_order_relaxed);
    if (curCh >= static_cast<int>(activeInputChannelCount_)) {
      inputChannel_.store(0, std::memory_order_relaxed);
    } else if (curCh < 0 && activeInputChannelCount_ < 2) {
      inputChannel_.store(0, std::memory_order_relaxed);
    }

    const int curOutCh = outputChannel_.load(std::memory_order_relaxed);
    if (curOutCh >= static_cast<int>(activeOutputChannelCount_)) {
      outputChannel_.store(-1, std::memory_order_relaxed);
    } else if (curOutCh <= -100) {
      const int pairIdx = -(curOutCh + 100);
      if (pairIdx * 2 + 1 >= static_cast<int>(activeOutputChannelCount_)) {
        outputChannel_.store(-1, std::memory_order_relaxed);
      }
    }

    applyDeviceSampleRateAndBufferSize(inDev, kAudioObjectPropertyScopeInput, sampleRate_, bufferSize_);
    applyDeviceSampleRateAndBufferSize(outDev, kAudioObjectPropertyScopeOutput, sampleRate_, bufferSize_);

    const uint32_t actualBuf = queryDeviceBufferFrameSize(outDev, kAudioObjectPropertyScopeOutput);
    if (actualBuf >= 16 && actualBuf <= kMaxFrames) {
      bufferSize_ = actualBuf;
    }

    if (inDev != kAudioObjectUnknown && inDev == outDev && activeInputChannelCount_ > 0) {
      if (configureSingleDuplexHAL(outDev, activeInputChannelCount_, sampleRate_)) return true;
    }
    if (configureSplitHAL(inDev, activeInputChannelCount_, outDev, sampleRate_)) return true;
    if (configureVoiceProcessingFallback(sampleRate_)) return true;
    if (sampleRate_ > 48000.0 && configureVoiceProcessingFallback(48000.0)) return true;
    return fail(error, @"Core Audio could not start. Check microphone permission and the selected input/output devices.");
  }

  NSWindow* __weak window_ = nil;
  NAMRig::CabinetWorker cabinetWorker_;
  static constexpr uint32_t kRenderActive = 1, kRenderSuspended = 2;
  std::atomic<uint32_t> renderState_{kRenderSuspended};
  double audioTicksPerFrame_ = 0.0;
  NSView* __weak parentView_ = nil;
  NSTextField* __weak cpuLabel_ = nil;
  NSView* __weak cpuBarFill_ = nil;
  NSView* __weak cpuBarSlot_ = nil;
  StandaloneAnimatedAmpView* __weak headerAmpView_ = nil;
  StandaloneAnimatedAmpView* __weak dockAmpView_ = nil;
  std::atomic<float> cpuLoadPercent_{0.0f};
  std::atomic<float> signalLevel_{0.0f};
  std::atomic<bool> ampIconsVisible_{true};
  bool displayAsleep_ = false;
  std::vector<id> displayObservers_;
  double ampPhase_ = 0.0;
  uint32_t dockFrameTick_ = 0;
  CFAbsoluteTime lastCpuUiTime_ = 0.0;
  NSTimer* __strong uiTimer_ = nil;

  AudioUnit inputUnit_ = nullptr;
  AudioUnit audioUnit_ = nullptr;
  bool useSplitInputUnit_ = false;
  uint32_t captureChannels_ = 1;
  uint32_t outputChannels_ = 2;
  std::string inputDeviceUID_;
  std::string outputDeviceUID_;
  std::string activeInputDeviceName_ = "Default Input";
  std::string activeOutputDeviceName_ = "Default Output";
  uint32_t activeInputChannelCount_ = 1;
  std::vector<std::string> activeInputChannelNames_{"Input 1"};
  std::atomic<int> inputChannel_{0};
  uint32_t activeOutputChannelCount_ = 2;
  std::vector<std::string> activeOutputChannelNames_{"Output 1", "Output 2"};
  std::atomic<int> outputChannel_{-1};
  double sampleRate_ = 0.0;
  uint32_t bufferSize_ = 128;

  AudioSampleRing inputRing_;
  alignas(AudioBufferList) std::array<
      uint8_t, sizeof(AudioBufferList) + (kMaxInputChannels - 1) * sizeof(AudioBuffer)>
      captureListStorage_{};
  std::array<std::array<float, kMaxFrames>, kMaxInputChannels> captureChannelData_{};
  std::array<float, kMaxFrames> captureMonoScratch_{};

  std::unique_ptr<NAMRig::Plugin> plugin_;
  const LV2UI_Descriptor* uiDescriptor_ = nullptr;
  LV2UI_Handle uiHandle_ = nullptr;

  std::array<float, kMaxFrames> input_{};
  std::array<float, kMaxFrames> output_{};
  std::array<float, kMaxFrames> outputR_{};
  std::array<float, 27> controls_{};
  std::array<float, 2> stereoControls_{};
  std::array<float, 8> advancedControls_{};
  std::array<float, 5> speakerControls_{};
  std::array<float, 13> fxControls_{};
  NAMRig::TransformerAdjustments transformerControls_ = NAMRig::kTransformerControlDefaults;
  std::array<uint8_t, kAtomBufferSize> controlBuffer_{};
  std::array<uint8_t, kAtomBufferSize> notifyBuffer_{};
  MessageRing uiToAudio_;
  MessageRing audioToUI_;

  std::mutex uriMutex_;
  std::deque<std::string> uris_;
  std::unordered_map<std::string, LV2_URID> urids_;
  LV2_URID atomSequence_ = 0, eventTransfer_ = 0, atomInt_ = 0, maxBlockLength_ = 0;
  LV2_URID_Map mapFeature_{};
  LV2_Worker_Schedule scheduleFeature_{};
  LV2_Log_Log logFeature_{};
  LV2UI_Resize resizeFeature_{};
  LV2_Feature mapLV2Feature_{}, scheduleLV2Feature_{}, logLV2Feature_{}, optionsLV2Feature_{};
  LV2_Feature parentLV2Feature_{}, mapUILV2Feature_{}, resizeLV2Feature_{};
  int32_t maxFramesOption_ = kMaxFrames;
  std::array<LV2_Options_Option, 2> options_{};

  std::thread worker_;
  std::mutex workerMutex_;
  std::condition_variable workerCV_;
  std::deque<WorkItem> work_;
  bool workerStopping_ = false;
  std::mutex responseMutex_;
  std::deque<WorkResponse> responses_;
};

static NSString* compactDeviceTitle(const std::string& rawName) {
  NSString* s = [NSString stringWithUTF8String:rawName.c_str()] ?: @"Audio";
  s = [s stringByReplacingOccurrencesOfString:@"Scarlett Solo 4th Gen" withString:@"Scarlett Solo"];
  s = [s stringByReplacingOccurrencesOfString:@"Scarlett 2i2 4th Gen" withString:@"Scarlett 2i2"];
  s = [s stringByReplacingOccurrencesOfString:@"MacBook Pro Microphone" withString:@"MacBook Mic"];
  s = [s stringByReplacingOccurrencesOfString:@"MacBook Air Microphone" withString:@"MacBook Mic"];
  s = [s stringByReplacingOccurrencesOfString:@"MacBook Pro Speakers" withString:@"MacBook Spkr"];
  s = [s stringByReplacingOccurrencesOfString:@"MacBook Air Speakers" withString:@"MacBook Spkr"];
  s = [s stringByReplacingOccurrencesOfString:@"External Headphones" withString:@"Headphones"];
  s = [s stringByReplacingOccurrencesOfString:@"External Microphone" withString:@"Ext Mic"];
  if (s.length > 14) {
    s = [[s substringToIndex:13] stringByAppendingString:@"…"];
  }
  return s;
}

}  // namespace

@interface StandaloneContentRootView : NSView
@property(nonatomic, strong) NSView* cpuPill;
@property(nonatomic, strong) NSPopUpButton* audioPopup;
@property(nonatomic, strong) StandaloneAnimatedAmpView* ampIconView;
@end

@implementation StandaloneContentRootView
- (void)layout {
  [super layout];
  for (NSView* sub in self.subviews) {
    for (NSView* child in sub.subviews) {
      [child setNeedsLayout:YES];
    }
    [sub setNeedsLayout:YES];
  }
  if (_ampIconView) {
    const CGFloat iconS = 24.0;
    const CGFloat iconX = 12.0;
    const CGFloat iconY = self.bounds.size.height - kToolbarStripHeight + (kToolbarStripHeight - iconS) / 2.0;
    _ampIconView.frame = NSMakeRect(iconX, iconY, iconS, iconS);
  }
  const CGFloat pillW = 136.0;
  const CGFloat pillH = 24.0;
  const CGFloat pillX = self.bounds.size.width - 24.0 - pillW;
  const CGFloat pillY = self.bounds.size.height - kToolbarStripHeight + (kToolbarStripHeight - pillH) / 2.0;
  if (_audioPopup) {
    const CGFloat audioW = 328.0;
    const CGFloat audioH = 24.0;
    const CGFloat audioX = pillX - 8.0 - audioW;
    const CGFloat audioY = self.bounds.size.height - kToolbarStripHeight + (kToolbarStripHeight - audioH) / 2.0;
    _audioPopup.frame = NSMakeRect(audioX, audioY, audioW, audioH);
    [_audioPopup removeFromSuperview];
    [self addSubview:_audioPopup positioned:NSWindowAbove relativeTo:nil];
  }
  if (_cpuPill) {
    _cpuPill.frame = NSMakeRect(pillX, pillY, pillW, pillH);
    if (self.subviews.lastObject != _cpuPill) {
      [_cpuPill removeFromSuperview];
      [self addSubview:_cpuPill positioned:NSWindowAbove relativeTo:nil];
    }
  }
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  [[NSColor colorWithSRGBRed:0.047 green:0.055 blue:0.075 alpha:1.0] setFill];
  NSRectFill(self.bounds);
  NSRect stripRect = NSMakeRect(0, self.bounds.size.height - kToolbarStripHeight,
                                self.bounds.size.width, kToolbarStripHeight);
  [[NSColor colorWithSRGBRed:0.067 green:0.078 blue:0.106 alpha:1.0] setFill];
  NSRectFill(stripRect);
  NSRect sepRect = NSMakeRect(0, self.bounds.size.height - kToolbarStripHeight,
                              self.bounds.size.width, 1.0);
  [[NSColor colorWithSRGBRed:0.145 green:0.165 blue:0.208 alpha:1.0] setFill];
  NSRectFill(sepRect);
}
@end

@interface StandaloneAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate>
@end

@implementation StandaloneAppDelegate {
  NSWindow* _window;
  NSView* _pluginHostView;
  NSPopUpButton* _audioPopup;
  NSMenu* _appAudioSubmenu;
  StandaloneAnimatedAmpView* _dockAmpView;
  std::unique_ptr<StandaloneHost> _host;
}

- (NSString*)audioSummaryTitle {
  if (!_host) return @"Audio I/O · 48k / 128";
  NSString* inShort = compactDeviceTitle(_host->activeInputDeviceName());
  NSString* outShort = compactDeviceTitle(_host->activeOutputDeviceName());
  const int ch = _host->inputChannel();
  NSString* chTag = (_host->activeInputChannelCount() > 1)
      ? (ch < 0 ? @" 1+2" : [NSString stringWithFormat:@" %d", ch + 1])
      : @"";
  const int outCh = _host->outputChannel();
  NSString* outChTag = @" 1+2";
  if (outCh >= 0) {
    outChTag = [NSString stringWithFormat:@" %d", outCh + 1];
  } else if (outCh <= -100) {
    const int p = -(outCh + 100);
    outChTag = [NSString stringWithFormat:@" %d+%d", p * 2 + 1, p * 2 + 2];
  }
  const double khz = _host->sampleRate() / 1000.0;
  NSString* khzStr = (std::fabs(khz - std::round(khz)) < 0.05)
      ? [NSString stringWithFormat:@"%.0fk", khz]
      : [NSString stringWithFormat:@"%.1fk", khz];
  return [NSString stringWithFormat:@"%@%@ ▸ %@%@ · %@/%u",
                                    inShort, chTag, outShort, outChTag, khzStr, _host->bufferSize()];
}

- (void)populateAudioMenu:(NSMenu*)menu includeTitleItem:(BOOL)includeTitleItem {
  if (!menu || !_host) return;
  [menu removeAllItems];
  menu.autoenablesItems = NO;

  if (includeTitleItem) {
    NSMenuItem* titleItem = [[NSMenuItem alloc] initWithTitle:[self audioSummaryTitle]
                                                       action:NULL
                                                keyEquivalent:@""];
    [menu addItem:titleItem];
  }

  const auto devices = enumerateAudioDevices();
  const AudioDeviceID defInID = defaultAudioDeviceID(true);
  const AudioDeviceID defOutID = defaultAudioDeviceID(false);
  std::string defInName = "System Default";
  std::string defOutName = "System Default";
  for (const auto& d : devices) {
    if (d.deviceID == defInID && d.inputChannels > 0) defInName = d.name;
    if (d.deviceID == defOutID && d.outputChannels > 0) defOutName = d.name;
  }

  auto addHeader = ^(NSString* text) {
    NSMenuItem* hdr = [[NSMenuItem alloc] initWithTitle:text action:NULL keyEquivalent:@""];
    hdr.enabled = NO;
    NSDictionary* attrs = @{
      NSFontAttributeName: [NSFont systemFontOfSize:10.0 weight:NSFontWeightBold],
      NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
    };
    hdr.attributedTitle = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    [menu addItem:hdr];
  };

  // 1. INPUT DEVICE
  addHeader(@"INPUT DEVICE");
  {
    NSString* defTitle = [NSString stringWithFormat:@"System Default (%s)", defInName.c_str()];
    NSMenuItem* defItem = [[NSMenuItem alloc] initWithTitle:defTitle
                                                     action:@selector(selectInputDevice:)
                                              keyEquivalent:@""];
    defItem.target = self;
    defItem.representedObject = @"";
    defItem.state = _host->inputDeviceUID().empty() ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:defItem];

    for (const auto& d : devices) {
      if (d.inputChannels == 0) continue;
      NSString* title = [NSString stringWithFormat:@"%s (%u in)", d.name.c_str(), d.inputChannels];
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                    action:@selector(selectInputDevice:)
                                             keyEquivalent:@""];
      item.target = self;
      item.representedObject = [NSString stringWithUTF8String:d.uid.c_str()];
      item.state = (_host->inputDeviceUID() == d.uid) ? NSControlStateValueOn : NSControlStateValueOff;
      [menu addItem:item];
    }
  }

  // 2. INPUT SOURCE / CHANNEL
  [menu addItem:[NSMenuItem separatorItem]];
  addHeader(@"INPUT SOURCE / CHANNEL");
  {
    const auto& chNames = _host->activeInputChannelNames();
    const uint32_t chCount = std::max<uint32_t>(1u, _host->activeInputChannelCount());
    const int activeCh = _host->inputChannel();
    const uint32_t limit = std::min<uint32_t>(chCount, kMaxInputChannels);
    for (uint32_t ch = 0; ch < limit; ++ch) {
      NSString* title = (ch < chNames.size())
          ? [NSString stringWithUTF8String:chNames[ch].c_str()]
          : [NSString stringWithFormat:@"Input %u", ch + 1];
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                    action:@selector(selectInputChannel:)
                                             keyEquivalent:@""];
      item.target = self;
      item.tag = static_cast<NSInteger>(ch);
      item.state = (activeCh == static_cast<int>(ch)) ? NSControlStateValueOn : NSControlStateValueOff;
      [menu addItem:item];
    }
    if (chCount >= 2) {
      NSMenuItem* stereoItem = [[NSMenuItem alloc] initWithTitle:@"Input 1 + 2 (Stereo Sum)"
                                                          action:@selector(selectInputChannel:)
                                                   keyEquivalent:@""];
      stereoItem.target = self;
      stereoItem.tag = -1;
      stereoItem.state = (activeCh < 0) ? NSControlStateValueOn : NSControlStateValueOff;
      [menu addItem:stereoItem];
    }
  }

  // 3. OUTPUT DEVICE
  [menu addItem:[NSMenuItem separatorItem]];
  addHeader(@"OUTPUT DEVICE");
  {
    NSString* defTitle = [NSString stringWithFormat:@"System Default (%s)", defOutName.c_str()];
    NSMenuItem* defItem = [[NSMenuItem alloc] initWithTitle:defTitle
                                                     action:@selector(selectOutputDevice:)
                                              keyEquivalent:@""];
    defItem.target = self;
    defItem.representedObject = @"";
    defItem.state = _host->outputDeviceUID().empty() ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:defItem];

    for (const auto& d : devices) {
      if (d.outputChannels == 0) continue;
      NSString* title = [NSString stringWithFormat:@"%s (%u out)", d.name.c_str(), d.outputChannels];
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                    action:@selector(selectOutputDevice:)
                                             keyEquivalent:@""];
      item.target = self;
      item.representedObject = [NSString stringWithUTF8String:d.uid.c_str()];
      item.state = (_host->outputDeviceUID() == d.uid) ? NSControlStateValueOn : NSControlStateValueOff;
      [menu addItem:item];
    }
  }

  // 4. OUTPUT SOURCE / CHANNEL
  [menu addItem:[NSMenuItem separatorItem]];
  addHeader(@"OUTPUT SOURCE / CHANNEL");
  {
    const auto& outNames = _host->activeOutputChannelNames();
    const uint32_t outCount = std::max<uint32_t>(2u, _host->activeOutputChannelCount());
    const int activeOutCh = _host->outputChannel();
    const uint32_t limit = std::min<uint32_t>(outCount, kMaxInputChannels);
    for (uint32_t ch = 0; ch < limit; ++ch) {
      NSString* title = (ch < outNames.size())
          ? [NSString stringWithUTF8String:outNames[ch].c_str()]
          : [NSString stringWithFormat:@"Output %u", ch + 1];
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                    action:@selector(selectOutputChannel:)
                                             keyEquivalent:@""];
      item.target = self;
      item.tag = static_cast<NSInteger>(ch);
      item.state = (activeOutCh == static_cast<int>(ch)) ? NSControlStateValueOn : NSControlStateValueOff;
      [menu addItem:item];
    }
    NSMenuItem* stereoOutItem = [[NSMenuItem alloc] initWithTitle:@"Output 1 + 2 (Stereo Out)"
                                                           action:@selector(selectOutputChannel:)
                                                    keyEquivalent:@""];
    stereoOutItem.target = self;
    stereoOutItem.tag = -1;
    stereoOutItem.state = (activeOutCh == -1) ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:stereoOutItem];

    NSMenuItem* dualMonoOutItem = [[NSMenuItem alloc] initWithTitle:@"Output 1 + 2 (Dual Mono)"
                                                             action:@selector(selectOutputChannel:)
                                                      keyEquivalent:@""];
    dualMonoOutItem.target = self;
    dualMonoOutItem.tag = -2;
    dualMonoOutItem.state = (activeOutCh == -2) ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:dualMonoOutItem];

    for (uint32_t pair = 1; pair * 2 + 1 < limit; ++pair) {
      NSString* pairTitle = [NSString stringWithFormat:@"Output %u + %u (Stereo Out)",
                                                       pair * 2 + 1, pair * 2 + 2];
      NSMenuItem* pairItem = [[NSMenuItem alloc] initWithTitle:pairTitle
                                                        action:@selector(selectOutputChannel:)
                                                 keyEquivalent:@""];
      pairItem.target = self;
      const int pairTag = -100 - static_cast<int>(pair);
      pairItem.tag = pairTag;
      pairItem.state = (activeOutCh == pairTag) ? NSControlStateValueOn : NSControlStateValueOff;
      [menu addItem:pairItem];
    }
  }

  // 5. SAMPLE RATE (kHz)
  [menu addItem:[NSMenuItem separatorItem]];
  addHeader(@"SAMPLE RATE");
  {
    const double kRates[] = {44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0};
    for (double r : kRates) {
      NSString* title = [NSString stringWithFormat:@"%.1f kHz (%.0f Hz)", r / 1000.0, r];
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                    action:@selector(selectSampleRate:)
                                             keyEquivalent:@""];
      item.target = self;
      item.representedObject = @(r);
      item.state = (std::fabs(_host->sampleRate() - r) < 1.0)
                       ? NSControlStateValueOn
                       : NSControlStateValueOff;
      [menu addItem:item];
    }
  }

  // 6. BUFFER SIZE
  [menu addItem:[NSMenuItem separatorItem]];
  addHeader(@"BUFFER SIZE");
  {
    const uint32_t kBuffers[] = {32, 64, 128, 256, 512, 1024, 2048};
    const double sr = _host->sampleRate() > 0.0 ? _host->sampleRate() : 48000.0;
    for (uint32_t buf : kBuffers) {
      const double latencyMs = (static_cast<double>(buf) / sr) * 1000.0;
      NSString* title = [NSString stringWithFormat:@"%u samples (%.1f ms)", buf, latencyMs];
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                    action:@selector(selectBufferSize:)
                                             keyEquivalent:@""];
      item.target = self;
      item.tag = static_cast<NSInteger>(buf);
      item.state = (_host->bufferSize() == buf) ? NSControlStateValueOn : NSControlStateValueOff;
      [menu addItem:item];
    }
  }
}

- (void)refreshAudioMenusAndTitle {
  if (_audioPopup) {
    [self populateAudioMenu:_audioPopup.menu includeTitleItem:YES];
    [_audioPopup setTitle:[self audioSummaryTitle]];
    const double sr = _host ? _host->sampleRate() : 48000.0;
    const uint32_t buf = _host ? _host->bufferSize() : 128u;
    const double ms = (sr > 0.0) ? (static_cast<double>(buf) / sr) * 1000.0 : 0.0;
    _audioPopup.toolTip = [NSString stringWithFormat:
        @"Audio I/O & Engine Settings — Input: %s → Output: %s · %.1f kHz · %u samples (%.1f ms). "
        @"Click to change input/output devices, input/output channels (Stereo Out), sample rate (kHz), or buffer size.",
        _host ? _host->activeInputDeviceName().c_str() : "Default",
        _host ? _host->activeOutputDeviceName().c_str() : "Default",
        sr / 1000.0, buf, ms];
  }
  if (_appAudioSubmenu) {
    [self populateAudioMenu:_appAudioSubmenu includeTitleItem:NO];
  }
}

- (void)menuNeedsUpdate:(NSMenu*)menu {
  if (menu == _audioPopup.menu) {
    [self populateAudioMenu:menu includeTitleItem:YES];
  } else if (menu == _appAudioSubmenu) {
    [self populateAudioMenu:menu includeTitleItem:NO];
  }
}

- (void)selectInputDevice:(NSMenuItem*)sender {
  if (!_host) return;
  NSString* uidObj = [sender.representedObject isKindOfClass:[NSString class]]
                         ? sender.representedObject
                         : @"";
  NSString* err = nil;
  if (!_host->setInputDeviceUID([uidObj UTF8String] ?: "", &err) && err) {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Could Not Switch Input Device";
    alert.informativeText = err;
    [alert runModal];
  }
  [self refreshAudioMenusAndTitle];
}

- (void)selectInputChannel:(NSMenuItem*)sender {
  if (!_host) return;
  _host->setInputChannel(static_cast<int>(sender.tag));
  [self refreshAudioMenusAndTitle];
}

- (void)selectOutputDevice:(NSMenuItem*)sender {
  if (!_host) return;
  NSString* uidObj = [sender.representedObject isKindOfClass:[NSString class]]
                         ? sender.representedObject
                         : @"";
  NSString* err = nil;
  if (!_host->setOutputDeviceUID([uidObj UTF8String] ?: "", &err) && err) {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Could Not Switch Output Device";
    alert.informativeText = err;
    [alert runModal];
  }
  [self refreshAudioMenusAndTitle];
}

- (void)selectOutputChannel:(NSMenuItem*)sender {
  if (!_host) return;
  _host->setOutputChannel(static_cast<int>(sender.tag));
  [self refreshAudioMenusAndTitle];
}

- (void)selectSampleRate:(NSMenuItem*)sender {
  if (!_host || ![sender.representedObject respondsToSelector:@selector(doubleValue)]) return;
  const double rate = [sender.representedObject doubleValue];
  NSString* err = nil;
  if (!_host->setSampleRate(rate, &err) && err) {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Could Not Change Sample Rate";
    alert.informativeText = err;
    [alert runModal];
  }
  [self refreshAudioMenusAndTitle];
}

- (void)selectBufferSize:(NSMenuItem*)sender {
  if (!_host) return;
  const uint32_t buf = static_cast<uint32_t>(sender.tag);
  NSString* err = nil;
  if (!_host->setBufferSize(buf, &err) && err) {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Could Not Change Buffer Size";
    alert.informativeText = err;
    [alert runModal];
  }
  [self refreshAudioMenusAndTitle];
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
  (void)notification;
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  NSMenu* menu = [[NSMenu alloc] init];
  NSMenuItem* appItem = [[NSMenuItem alloc] init];
  [menu addItem:appItem];
  NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"Axe FX"];

  NSMenuItem* audioMenuItem = [[NSMenuItem alloc] initWithTitle:@"Audio I/O & Device Setup"
                                                         action:NULL
                                                  keyEquivalent:@""];
  _appAudioSubmenu = [[NSMenu alloc] initWithTitle:@"Audio I/O & Device Setup"];
  _appAudioSubmenu.delegate = self;
  audioMenuItem.submenu = _appAudioSubmenu;
  [appMenu addItem:audioMenuItem];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:@"Quit Axe FX"
                     action:@selector(terminate:)
              keyEquivalent:@"q"];
  appItem.submenu = appMenu;
  NSApp.mainMenu = menu;

  // Live animated tube-amp Dock tile icon
  _dockAmpView = [[StandaloneAnimatedAmpView alloc] initWithFrame:NSMakeRect(0, 0, 128, 128)];
  NSApp.dockTile.contentView = _dockAmpView;
  [NSApp.dockTile display];

  const NSRect initialContent = NSMakeRect(0, 0, 1520, 980 + kToolbarStripHeight);
  _window = [[NSWindow alloc]
      initWithContentRect:initialContent
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskMiniaturizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  _window.title = @"Axe FX";
  _window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  _window.delegate = self;
  _window.releasedWhenClosed = NO;

  StandaloneContentRootView* rootContent =
      [[StandaloneContentRootView alloc] initWithFrame:initialContent];
  rootContent.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _window.contentView = rootContent;

  _pluginHostView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1520, 980)];
  _pluginHostView.autoresizingMask = NSViewNotSizable;
  [rootContent addSubview:_pluginHostView];

  // Top-left animated tube-amp badge in the header toolbar strip.
  StandaloneAnimatedAmpView* headerAmp =
      [[StandaloneAnimatedAmpView alloc] initWithFrame:NSMakeRect(12, 980 + 2, 24, 24)];
  headerAmp.toolTip = @"Axe FX · Active Tube Amp Engine (tubes glow with your guitar signal).";
  rootContent.ampIconView = headerAmp;
  [rootContent addSubview:headerAmp positioned:NSWindowAbove relativeTo:nil];

  // Top-banner Audio I/O dropdown menu (Input Device, Input Channel, Output Device, Output Channel, kHz, Buffer Size).
  _audioPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(1520 - 24 - 136 - 8 - 328, 980 + 2, 328, 24)
                                           pullsDown:YES];
  _audioPopup.controlSize = NSControlSizeSmall;
  _audioPopup.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
  _audioPopup.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
  _audioPopup.menu.delegate = self;
  rootContent.audioPopup = _audioPopup;
  [rootContent addSubview:_audioPopup positioned:NSWindowAbove relativeTo:nil];

  // Top-right CPU meter pill in the header toolbar strip (matches input/output dB pills).
  NSView* cpuPill = [[NSView alloc] initWithFrame:NSMakeRect(1520 - 24 - 136, 980 + 2, 136, 24)];
  cpuPill.wantsLayer = YES;
  cpuPill.layer.backgroundColor = [NSColor colorWithSRGBRed:0.086 green:0.098 blue:0.129 alpha:1.0].CGColor;
  cpuPill.layer.cornerRadius = 8.0;
  cpuPill.layer.borderWidth = 1.0;
  cpuPill.layer.borderColor = [NSColor colorWithSRGBRed:0.145 green:0.165 blue:0.208 alpha:1.0].CGColor;
  cpuPill.toolTip = @"Real-time audio DSP CPU load (% of audio callback buffer budget).";

  NSTextField* cpuLabel = [NSTextField labelWithString:@"CPU  0.0%"];
  cpuLabel.font = [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightMedium];
  cpuLabel.textColor = [NSColor colorWithSRGBRed:0.86 green:0.89 blue:0.95 alpha:1.0];
  cpuLabel.alignment = NSTextAlignmentLeft;
  cpuLabel.frame = NSMakeRect(8, 4, 68, 16);
  [cpuPill addSubview:cpuLabel];

  NSView* cpuSlot = [[NSView alloc] initWithFrame:NSMakeRect(78, 8, 50, 8)];
  cpuSlot.wantsLayer = YES;
  cpuSlot.layer.backgroundColor = [NSColor colorWithSRGBRed:0.125 green:0.145 blue:0.188 alpha:1.0].CGColor;
  cpuSlot.layer.cornerRadius = 2.0;
  [cpuPill addSubview:cpuSlot];

  NSView* cpuFill = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 0, 8)];
  cpuFill.wantsLayer = YES;
  cpuFill.layer.backgroundColor = [NSColor colorWithSRGBRed:0.20 green:0.82 blue:0.96 alpha:1.0].CGColor;
  cpuFill.layer.cornerRadius = 2.0;
  [cpuSlot addSubview:cpuFill];

  rootContent.cpuPill = cpuPill;
  [rootContent addSubview:cpuPill positioned:NSWindowAbove relativeTo:nil];

  [_window center];

  _host = std::make_unique<StandaloneHost>();
  NSString* error = nil;
  if (!_host->start(_window, _pluginHostView, &error)) {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Axe FX could not start";
    alert.informativeText = error ?: @"Unknown error";
    [alert runModal];
    [NSApp terminate:nil];
    return;
  }
  _host->setCpuMeterViews(cpuLabel, cpuFill, cpuSlot);
  _host->setAnimatedAmpViews(headerAmp, _dockAmpView);
  [self refreshAudioMenusAndTitle];
  [rootContent setNeedsLayout:YES];
  [_window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
  (void)sender;
  return YES;
}

- (void)applicationWillTerminate:(NSNotification*)notification {
  (void)notification;
  _host.reset();
}

@end

int main(int argc, const char* argv[]) {
  (void)argc;
  (void)argv;
  @autoreleasepool {
    NSApplication* app = [NSApplication sharedApplication];
    StandaloneAppDelegate* delegate = [[StandaloneAppDelegate alloc] init];
    app.delegate = delegate;
    [app run];
  }
  return 0;
}
