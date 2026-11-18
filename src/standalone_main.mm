#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>
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
#include "polyphase_worker.h"
#include "rack_controls.h"
#include "standalone_controls.h"
#include "standalone_worker.h"
#include "oversample_modes.h"
#import "rig_standalone_profiler.h"
#import "rig_local_server.h"
#import "rig_ai_copilot.h"
#import "rig_riff_recorder.h"
#import "rig_riff_renderer.h"

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
constexpr size_t kMessageCount = 512;
constexpr CGFloat kToolbarStripHeight = 28.0;
constexpr CGFloat kAudioPopupWidth = 236.0;

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
    primed_ = false;
    lastSample_ = 0.0f;
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

    // Prime only a single callback block on startup to keep round-trip latency minimal,
    // and avoid resetting primed_ on transient underruns so single-sample clock
    // jitter never silences subsequent callbacks.
    const uint64_t primeThreshold = static_cast<uint64_t>(count);
    if (!primed_) {
      if (avail < primeThreshold) {
        for (uint32_t i = 0; i < count; ++i) {
          lastSample_ *= 0.9f;
          dst[i] = lastSample_;
        }
        return;
      }
      primed_ = true;
      r = w - primeThreshold;
      avail = primeThreshold;
    }

    // Prevent latency build-up when input and output devices run on independent clocks.
    const uint64_t cap = std::max<uint64_t>(maxQueuedFrames, static_cast<uint64_t>(count) * 4);
    const uint64_t slipTarget = static_cast<uint64_t>(count) * 2;
    bool slipped = false;
    if (avail > cap) {
      r = w - slipTarget;
      avail = slipTarget;
      slipped = true;
    }

    if (avail >= count) {
      for (uint32_t i = 0; i < count; ++i) {
        dst[i] = samples_[(r + i) & kMask];
      }
      if (slipped) {
        const uint32_t fadeLen = std::min<uint32_t>(count, 32);
        for (uint32_t i = 0; i < fadeLen; ++i) {
          const float alpha = static_cast<float>(i + 1) / static_cast<float>(fadeLen + 1);
          dst[i] = lastSample_ + alpha * (dst[i] - lastSample_);
        }
      }
      lastSample_ = dst[count - 1];
      read_.store(r + count, std::memory_order_release);
    } else {
      for (uint32_t i = 0; i < static_cast<uint32_t>(avail); ++i) {
        dst[i] = samples_[(r + i) & kMask];
        lastSample_ = dst[i];
      }
      for (uint32_t i = static_cast<uint32_t>(avail); i < count; ++i) {
        lastSample_ *= 0.9f;
        dst[i] = lastSample_;
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
  bool primed_ = false;
  float lastSample_ = 0.0f;
};

struct FixedMessage {
  uint32_t size = 0;
  uint32_t format = 0;
  std::array<uint8_t, kMessageSize> bytes{};
};

// Lock-free SPSC ring buffer for streaming mono DI or stereo output audio to disk.
template <uint32_t kChannels>
class SampleRecordRing {
 public:
  SampleRecordRing() : samples_(kCapacityFrames * kChannels, 0.0f) {}

  void clear() noexcept {
    read_.store(0, std::memory_order_relaxed);
    write_.store(0, std::memory_order_relaxed);
  }

  uint32_t push(const float* ch0, const float* ch1, uint32_t frames) noexcept {
    if ((!ch0 && !ch1) || frames == 0) return 0;
    const uint64_t w = write_.load(std::memory_order_relaxed);
    const uint64_t r = read_.load(std::memory_order_acquire);
    const uint64_t used = (w >= r) ? (w - r) : 0;
    if (used >= kCapacityFrames) return 0;
    const uint32_t count = static_cast<uint32_t>(
        std::min<uint64_t>(frames, kCapacityFrames - used));
    for (uint32_t i = 0; i < count; ++i) {
      const float s0 = (ch0 && std::isfinite(ch0[i])) ? ch0[i] : 0.0f;
      const size_t idx = static_cast<size_t>((w + i) & kMask) * kChannels;
      samples_[idx] = s0;
      if constexpr (kChannels == 2) {
        const float s1 = ch1 ? (std::isfinite(ch1[i]) ? ch1[i] : 0.0f) : s0;
        samples_[idx + 1] = s1;
      }
    }
    write_.store(w + count, std::memory_order_release);
    return count;
  }

  uint32_t popChunk(float* dstInterleaved, uint32_t maxFrames) noexcept {
    if (!dstInterleaved || maxFrames == 0) return 0;
    const uint64_t r = read_.load(std::memory_order_relaxed);
    const uint64_t w = write_.load(std::memory_order_acquire);
    const uint64_t avail = (w >= r) ? (w - r) : 0;
    if (avail == 0) return 0;
    const uint32_t count = static_cast<uint32_t>(std::min<uint64_t>(avail, maxFrames));
    for (uint32_t i = 0; i < count; ++i) {
      const size_t idx = static_cast<size_t>((r + i) & kMask) * kChannels;
      for (uint32_t c = 0; c < kChannels; ++c) {
        dstInterleaved[i * kChannels + c] = samples_[idx + c];
      }
    }
    read_.store(r + count, std::memory_order_release);
    return count;
  }

 private:
  static constexpr uint64_t kCapacityFrames = 262144;
  static constexpr uint64_t kMask = kCapacityFrames - 1;
  std::vector<float> samples_;
  std::atomic<uint64_t> read_{0};
  std::atomic<uint64_t> write_{0};
};

static void writeWavHeader24(std::FILE* fp, uint64_t frames, double sampleRate, uint16_t channels) {
  if (!fp) return;
  const uint32_t sr = static_cast<uint32_t>(std::max(8000.0, std::min(192000.0, std::round(sampleRate))));
  const uint16_t bitsPerSample = 24;
  const uint16_t blockAlign = channels * (bitsPerSample / 8);
  const uint32_t byteRate = sr * blockAlign;
  const uint64_t rawBytes64 = frames * blockAlign;
  const uint32_t dataBytes = static_cast<uint32_t>(std::min<uint64_t>(rawBytes64, 0xFFFFFF00ull));
  const uint32_t riffSize = 36u + dataBytes + (dataBytes & 1u);

  uint8_t hdr[44]{};
  auto put16 = [&](size_t off, uint16_t v) {
    hdr[off] = static_cast<uint8_t>(v & 0xFFu);
    hdr[off + 1] = static_cast<uint8_t>((v >> 8) & 0xFFu);
  };
  auto put32 = [&](size_t off, uint32_t v) {
    hdr[off] = static_cast<uint8_t>(v & 0xFFu);
    hdr[off + 1] = static_cast<uint8_t>((v >> 8) & 0xFFu);
    hdr[off + 2] = static_cast<uint8_t>((v >> 16) & 0xFFu);
    hdr[off + 3] = static_cast<uint8_t>((v >> 24) & 0xFFu);
  };
  std::memcpy(hdr + 0, "RIFF", 4);
  put32(4, riffSize);
  std::memcpy(hdr + 8, "WAVEfmt ", 8);
  put32(16, 16u);
  put16(20, 1u);  // PCM
  put16(22, channels);
  put32(24, sr);
  put32(28, byteRate);
  put16(32, blockAlign);
  put16(34, bitsPerSample);
  std::memcpy(hdr + 36, "data", 4);
  put32(40, dataBytes);

  std::fseek(fp, 0, SEEK_SET);
  std::fwrite(hdr, 1, sizeof(hdr), fp);
}

static bool decodeMonoAudioFile(NSURL* url, double targetRate, std::vector<float>& outSamples, NSString** error) {
  auto failWith = [&](NSString* msg) -> bool {
    if (error) *error = msg;
    return false;
  };
  if (!url) return failWith(@"No audio file URL provided.");
  ExtAudioFileRef file = nullptr;
  if (ExtAudioFileOpenURL((__bridge CFURLRef)url, &file) != noErr || !file) {
    return failWith(@"Could not open audio file. Use WAV, AIFF, MP3, M4A, ALAC, or FLAC.");
  }
  std::unique_ptr<OpaqueExtAudioFile, OSStatus (*)(ExtAudioFileRef)> guard(file, ExtAudioFileDispose);

  AudioStreamBasicDescription fileFmt{};
  UInt32 propSize = sizeof(fileFmt);
  if (ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &propSize, &fileFmt) != noErr) {
    return failWith(@"Could not read the audio file format.");
  }
  if ((fileFmt.mChannelsPerFrame != 1 && fileFmt.mChannelsPerFrame != 2) ||
      !std::isfinite(fileFmt.mSampleRate) || fileFmt.mSampleRate < 8000.0 || fileFmt.mSampleRate > 192000.0) {
    return failWith(@"Use a mono or stereo audio file at 8–192 kHz.");
  }

  AudioStreamBasicDescription clientFmt{};
  clientFmt.mSampleRate = targetRate > 0.0 ? targetRate : fileFmt.mSampleRate;
  clientFmt.mFormatID = kAudioFormatLinearPCM;
  clientFmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  clientFmt.mBitsPerChannel = 32;
  clientFmt.mChannelsPerFrame = 1;
  clientFmt.mFramesPerPacket = 1;
  clientFmt.mBytesPerFrame = sizeof(float);
  clientFmt.mBytesPerPacket = sizeof(float);
  if (ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(clientFmt), &clientFmt) != noErr) {
    return failWith(@"Could not convert the audio file to mono float at the engine sample rate.");
  }

  constexpr size_t kMaxDISamples = 32u * 1024u * 1024u;  // ~11 min at 48 kHz
  std::vector<float> samples;
  std::vector<float> chunk(8192);
  while (samples.size() < kMaxDISamples) {
    UInt32 frames = static_cast<UInt32>(std::min<size_t>(chunk.size(), kMaxDISamples - samples.size()));
    AudioBufferList list{};
    list.mNumberBuffers = 1;
    list.mBuffers[0] = {1u, static_cast<UInt32>(frames * sizeof(float)), chunk.data()};
    if (ExtAudioFileRead(file, &frames, &list) != noErr) {
      return failWith(@"Failed decoding audio file partway through.");
    }
    if (frames == 0) break;
    for (UInt32 i = 0; i < frames; ++i) {
      if (!std::isfinite(chunk[i])) return failWith(@"Audio file contains non-finite samples.");
    }
    samples.insert(samples.end(), chunk.begin(), chunk.begin() + frames);
  }
  if (samples.size() < 64) {
    return failWith(@"The audio file is empty or too short.");
  }
  outSamples.swap(samples);
  return true;
}

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
    scheduleLV2Feature_ = {LV2_WORKER__schedule, worker_.scheduleFeature()};
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
    plugin_->ports.audio_out_r = outputR_.data();
    NAMRig::bindStandaloneControls(plugin_->ports, {
        {4, controls_}, {32, stereoControls_}, {34, advancedControls_},
        {42, speakerControls_}, {47, fxControls_},
        {NAMRig::kTransformerControlFirstPort, transformerControls_},
        {NAMRig::kRackControlFirstPort, rackControls_},
        {NAMRig::kPowerTubeTypePort, tubeControls_},
        {NAMRig::kMidPushPort, {&midPushControl_, 1}},
        {NAMRig::kPinEqFirstPort, pinEqControls_},
        {NAMRig::kOverdriveDrivePort, overdriveControls_},
        {NAMRig::kCompressorAttackPort, compressorControls_},
        {NAMRig::kOverdriveEnabledPort, {&overdriveEnabled_, 1}},
        {NAMRig::kPostCompressorFirstPort, postCompressorControls_},
        {NAMRig::kOverdriveTightPort, {&overdriveTight_, 1}},
        {NAMRig::kOverdriveVoicingPort, {&overdriveVoicing_, 1}},
        {NAMRig::kPedal2EnabledPort, pedalBoardControls_},
        {NAMRig::kOutputCeilingPort, masterOutputControls_},
        {NAMRig::kToneEqModePort, toneEqControls_},
        {NAMRig::kDropPitchPort, {&dropPitchControl_, 1}},
        {NAMRig::kModelBandLimitPort, {&modelBandLimitControl_, 1}},
        {NAMRig::kDropPitchAttackPort, dropPitchShapingControls_},
        {NAMRig::kModelBandLimitCutoffPort, modelBandLimitParamsControls_},
        {NAMRig::kSpatialCenterBlendPort, {&spatialCenterBlendControl_, 1}},
        {NAMRig::kSpeakerProfileBPort, {&speakerBProfileControl_, 1}},
        {NAMRig::kCabLowCutSlopePort, cabCutSlopeControls_},
        {NAMRig::kCabIrAutoTrimPort, {&cabIrAutoTrimControl_, 1}}});

    if (!worker_.start(plugin_.get(),
                       {NAMRig::Plugin::work, NAMRig::Plugin::workResponse, nullptr}))
      return fail(error, @"The rig worker could not be started.");
    [RigRiffRecorder sharedRecorder].renderHandler = ^NSData*(RigPreset* preset, NSData* di, double rate, NSError** renderError) {
      return rigRenderDI(preset, di, rate, renderError);
    };

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
    [[NSRunLoop mainRunLoop] addTimer:uiTimer_ forMode:NSRunLoopCommonModes];
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
    if (plugin_) plugin_->setPolyphaseWorker(nullptr);
    cabinetWorker_.stop();
    polyphaseWorker_.stop();
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
    if (isOutputRecording()) {
      stopOutputRecording();
    }
    [uiTimer_ invalidate];
    uiTimer_ = nil;
    stopObservingDisplaySleep();
    stopAudioUnits();
    if (uiDescriptor_ && uiHandle_) {
      uiDescriptor_->cleanup(uiHandle_);
      uiHandle_ = nullptr;
    }
    worker_.stop();
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

  int oversampleMode() const {
    return static_cast<int>(controls_[17] + 0.5f);
  }

  void setOversampleMode(int mode) {
    controls_[16] = static_cast<float>(mode);
    controls_[17] = static_cast<float>(mode);
    if (uiDescriptor_ && uiHandle_) {
      uiDescriptor_->port_event(uiHandle_, 20, sizeof(float), 0, &controls_[16]);
      uiDescriptor_->port_event(uiHandle_, 21, sizeof(float), 0, &controls_[17]);
    }
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

  void setRecordingViews(NSView* pill, NSButton* toggleBtn, NSTextField* timeLabel,
                         NSButton* revealBtn) {
    recPill_ = pill;
    recToggleBtn_ = toggleBtn;
    recTimeLabel_ = timeLabel;
    recRevealBtn_ = revealBtn;
    updateRecordingDisplay(true);
  }

  void setDIPlaybackViews(NSView* pill, NSButton* toggleBtn, NSButton* loadBtn) {
    diPill_ = pill;
    diToggleBtn_ = toggleBtn;
    diLoadBtn_ = loadBtn;
    updateDIPlaybackDisplay();
  }

  static NSString* recordingsDirectoryPath() {
    NSArray<NSString*>* musicDirs =
        NSSearchPathForDirectoriesInDomains(NSMusicDirectory, NSUserDomainMask, YES);
    NSString* musicBase =
        musicDirs.firstObject ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Music"];
    NSString* dir = [musicBase stringByAppendingPathComponent:@"Axe FX Recordings"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return dir;
  }

  bool isOutputRecording() const noexcept {
    return outputRecording_.load(std::memory_order_acquire);
  }

  bool isDIPlaybackActive() const noexcept {
    return diPlayActive_.load(std::memory_order_acquire);
  }

  bool hasLoadedDIPlayback() const noexcept {
    return diPlayHasSamples_;
  }

  bool hasLastSavedDIRecording() const noexcept {
    return lastSavedDIRecordingPath_.length > 0 &&
           [[NSFileManager defaultManager] fileExistsAtPath:lastSavedDIRecordingPath_];
  }

  NSString* lastSavedDIRecordingPath() const noexcept {
    return lastSavedDIRecordingPath_;
  }

  bool loadDIPlaybackFromURL(NSURL* url, bool startPlayback, NSString** error = nullptr) {
    if (!url) return fail(error, @"No Clean DI audio file selected.");
    const double targetRate = sampleRate_ > 0.0 ? sampleRate_ : 48000.0;
    std::vector<float> decoded;
    if (!decodeMonoAudioFile(url, targetRate, decoded, error)) {
      return false;
    }

    diPlayActive_.store(false, std::memory_order_release);
    const uint32_t prev = renderState_.fetch_or(kRenderSuspended, std::memory_order_acq_rel);
    while (renderState_.load(std::memory_order_acquire) & kRenderActive) {
      std::this_thread::sleep_for(std::chrono::microseconds(200));
    }
    diPlaySamples_.swap(decoded);
    diPlayCursor_.store(0, std::memory_order_relaxed);
    if ((prev & kRenderSuspended) == 0) {
      renderState_.fetch_and(~kRenderSuspended, std::memory_order_release);
    }

    diPlayHasSamples_ = !diPlaySamples_.empty();
    diPlaySampleRate_ = targetRate;
    diPlaySourceURL_ = url;
    diPlayFileName_ = url.lastPathComponent ?: @"Clean DI.wav";
    if (startPlayback && diPlayHasSamples_) {
      diPlayActive_.store(true, std::memory_order_release);
    }
    updateDIPlaybackDisplay();
    return true;
  }

  bool useLastRecordedDI(NSString** error = nullptr) {
    if (!hasLastSavedDIRecording()) {
      return fail(error, @"No Clean DI recording found yet. Record a take with ● REC first.");
    }
    return loadDIPlaybackFromURL([NSURL fileURLWithPath:lastSavedDIRecordingPath_], true, error);
  }

  void toggleDIPlayback() {
    if (!diPlayHasSamples_) return;
    if (isDIPlaybackActive()) {
      stopDIPlayback();
    } else {
      diPlayCursor_.store(0, std::memory_order_relaxed);
      diPlayActive_.store(true, std::memory_order_release);
      updateDIPlaybackDisplay();
    }
  }

  void stopDIPlayback() {
    if (!isDIPlaybackActive()) return;
    diPlayActive_.store(false, std::memory_order_release);
    updateDIPlaybackDisplay();
  }

  bool startOutputRecording(NSString** error = nullptr) {
    if (isOutputRecording()) return true;
    NSString* dir = recordingsDirectoryPath();
    NSDateFormatter* fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd HH-mm-ss";
    NSString* stamp = [fmt stringFromDate:[NSDate date]];
    NSString* baseName = [NSString stringWithFormat:@"Axe FX %@", stamp];
    NSString* filePath = [dir stringByAppendingPathComponent:
                              [baseName stringByAppendingPathExtension:@"wav"]];
    NSString* diFilePath = [dir stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"%@ - Clean DI.wav", baseName]];
    NSFileManager* fm = [NSFileManager defaultManager];
    int suffix = 2;
    while ([fm fileExistsAtPath:filePath] || [fm fileExistsAtPath:diFilePath]) {
      NSString* numberedBase = [NSString stringWithFormat:@"%@-%d", baseName, suffix++];
      filePath = [dir stringByAppendingPathComponent:[numberedBase stringByAppendingPathExtension:@"wav"]];
      diFilePath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ - Clean DI.wav", numberedBase]];
    }

    std::FILE* fp = std::fopen(filePath.fileSystemRepresentation, "wb");
    if (!fp) {
      return fail(error, @"Could not create recording file in ~/Music/Axe FX Recordings.");
    }
    std::FILE* diFp = std::fopen(diFilePath.fileSystemRepresentation, "wb");
    if (!diFp) {
      std::fclose(fp);
      [fm removeItemAtPath:filePath error:nil];
      return fail(error, @"Could not create Clean DI recording file in ~/Music/Axe FX Recordings.");
    }
    const double sr = sampleRate_ > 0.0 ? sampleRate_ : 48000.0;
    writeWavHeader24(fp, 0, sr, 2);
    writeWavHeader24(diFp, 0, sr, 1);

    outputRecordRing_.clear();
    diRecordRing_.clear();
    outputRecordedFrames_.store(0, std::memory_order_relaxed);
    outputWrittenFrames_ = 0;
    diWrittenFrames_ = 0;
    outputRecordSampleRate_ = sr;
    outputRecordFile_ = fp;
    diRecordFile_ = diFp;
    activeRecordingPath_ = filePath;
    activeDIRecordingPath_ = diFilePath;
    outputRecording_.store(true, std::memory_order_release);
    updateRecordingDisplay(true);
    return true;
  }

  NSString* stopOutputRecording() {
    if (!isOutputRecording() && !outputRecordFile_ && !diRecordFile_) return lastSavedRecordingPath_;
    outputRecording_.store(false, std::memory_order_release);
    drainOutputRecordingToDisk();
    NSString* savedPath = activeRecordingPath_;
    NSString* savedDIPath = activeDIRecordingPath_;
    auto finalizeWavFile = [&](std::FILE*& fp, uint64_t writtenFrames, uint16_t channels) {
      if (!fp) return;
      writeWavHeader24(fp, writtenFrames, outputRecordSampleRate_, channels);
      const uint64_t dataBytes = writtenFrames * channels * 3ull;
      if (dataBytes & 1ull) {
        const uint8_t pad = 0;
        std::fwrite(&pad, 1, 1, fp);
      }
      std::fflush(fp);
      std::fclose(fp);
      fp = nullptr;
    };
    finalizeWavFile(outputRecordFile_, outputWrittenFrames_, 2);
    finalizeWavFile(diRecordFile_, diWrittenFrames_, 1);
    activeRecordingPath_ = nil;
    activeDIRecordingPath_ = nil;
    if (outputWrittenFrames_ > 0 && savedPath.length > 0) {
      lastSavedRecordingPath_ = savedPath;
      lastSavedRecordingDuration_ =
          outputRecordSampleRate_ > 0.0
              ? static_cast<double>(outputWrittenFrames_) / outputRecordSampleRate_
              : 0.0;
    } else if (savedPath.length > 0) {
      [[NSFileManager defaultManager] removeItemAtPath:savedPath error:nil];
    }
    if (diWrittenFrames_ > 0 && savedDIPath.length > 0) {
      lastSavedDIRecordingPath_ = savedDIPath;
    } else if (savedDIPath.length > 0) {
      [[NSFileManager defaultManager] removeItemAtPath:savedDIPath error:nil];
    }
    updateRecordingDisplay(true);
    return lastSavedRecordingPath_;
  }

  void toggleOutputRecording(NSString** error = nullptr) {
    if (isOutputRecording()) {
      stopOutputRecording();
    } else {
      startOutputRecording(error);
    }
  }

  void revealOutputRecordingInFinder() {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* targetPath = isOutputRecording() ? activeRecordingPath_ : lastSavedRecordingPath_;
    if (targetPath.length > 0 && [fm fileExistsAtPath:targetPath]) {
      NSURL* fileURL = [NSURL fileURLWithPath:targetPath];
      [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[fileURL]];
      return;
    }
    NSString* dir = recordingsDirectoryPath();
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir isDirectory:YES]];
  }

 private:
  template <uint32_t kChannels>
  void drainRingToWav24(SampleRecordRing<kChannels>& ring, std::FILE* fp, uint64_t& writtenFrames) {
    if (!fp) return;
    constexpr uint32_t kChunkFrames = 4096;
    if (outputFloatScratch_.size() < kChunkFrames * kChannels) {
      outputFloatScratch_.resize(kChunkFrames * kChannels);
    }
    if (outputPcmScratch_.size() < kChunkFrames * kChannels * 3) {
      outputPcmScratch_.resize(kChunkFrames * kChannels * 3);
    }
    while (true) {
      const uint32_t n = ring.popChunk(outputFloatScratch_.data(), kChunkFrames);
      if (n == 0) break;
      const size_t totalSamples = static_cast<size_t>(n) * kChannels;
      for (size_t i = 0; i < totalSamples; ++i) {
        const float clamped = std::clamp(outputFloatScratch_[i], -1.0f, 1.0f);
        const int32_t v = static_cast<int32_t>(std::lrint(clamped * 8388607.0f));
        outputPcmScratch_[i * 3 + 0] = static_cast<uint8_t>(v & 0xFF);
        outputPcmScratch_[i * 3 + 1] = static_cast<uint8_t>((v >> 8) & 0xFF);
        outputPcmScratch_[i * 3 + 2] = static_cast<uint8_t>((v >> 16) & 0xFF);
      }
      std::fwrite(outputPcmScratch_.data(), 1, totalSamples * 3, fp);
      writtenFrames += n;
    }
  }

  void drainOutputRecordingToDisk() {
    drainRingToWav24(outputRecordRing_, outputRecordFile_, outputWrittenFrames_);
    drainRingToWav24(diRecordRing_, diRecordFile_, diWrittenFrames_);
  }

  static NSString* formatRecordingClock(double seconds) {
    const long totalSec = std::max<long>(0, std::lround(std::floor(seconds)));
    const long mins = totalSec / 60;
    const long secs = totalSec % 60;
    return [NSString stringWithFormat:@"%02ld:%02ld", mins, secs];
  }

  void updateRecordingDisplay(bool force = false) {
    if (!recToggleBtn_ && !recTimeLabel_) return;
    const bool rec = isOutputRecording();
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!force && rec == lastRecUiState_ && (now - lastRecUiTime_) < 0.2) return;
    lastRecUiState_ = rec;
    lastRecUiTime_ = now;

    double seconds = lastSavedRecordingDuration_;
    if (rec) {
      const uint64_t frames = outputRecordedFrames_.load(std::memory_order_relaxed);
      const double sr = outputRecordSampleRate_ > 0.0 ? outputRecordSampleRate_ : 48000.0;
      seconds = static_cast<double>(frames) / sr;
    }
    if (recTimeLabel_) {
      recTimeLabel_.stringValue = formatRecordingClock(seconds);
      recTimeLabel_.textColor = rec
          ? [NSColor colorWithSRGBRed:1.00 green:0.42 blue:0.42 alpha:1.0]
          : (lastSavedRecordingPath_.length > 0
                 ? [NSColor colorWithSRGBRed:0.86 green:0.89 blue:0.95 alpha:1.0]
                 : [NSColor colorWithSRGBRed:0.58 green:0.63 blue:0.72 alpha:1.0]);
    }
    if (recPill_ && recPill_.layer) {
      recPill_.layer.borderColor = rec
          ? [NSColor colorWithSRGBRed:0.92 green:0.24 blue:0.24 alpha:0.85].CGColor
          : [NSColor colorWithSRGBRed:0.145 green:0.165 blue:0.208 alpha:1.0].CGColor;
      recPill_.layer.backgroundColor = rec
          ? [NSColor colorWithSRGBRed:0.18 green:0.07 blue:0.08 alpha:1.0].CGColor
          : [NSColor colorWithSRGBRed:0.086 green:0.098 blue:0.129 alpha:1.0].CGColor;
    }
    if (recToggleBtn_) {
      NSString* title = rec ? @"■ STOP" : @"● REC";
      NSColor* fg = rec
          ? [NSColor colorWithSRGBRed:1.00 green:0.38 blue:0.38 alpha:1.0]
          : [NSColor colorWithSRGBRed:0.94 green:0.32 blue:0.32 alpha:1.0];
      NSDictionary* attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: fg,
      };
      recToggleBtn_.attributedTitle =
          [[NSAttributedString alloc] initWithString:title attributes:attrs];
      recToggleBtn_.toolTip = rec
          ? @"Stop recording and auto-save transformed + Clean DI WAVs to ~/Music/Axe FX Recordings (⌘R)."
          : @"Record transformed stereo output + Clean DI WAV to ~/Music/Axe FX Recordings (⌘R).";
    }
    if (recRevealBtn_) {
      if (lastSavedRecordingPath_.length > 0) {
        recRevealBtn_.toolTip = [NSString stringWithFormat:
            @"Last saved: %@ (+ Clean DI) — Click to reveal in Finder.",
            lastSavedRecordingPath_.lastPathComponent];
      } else {
        recRevealBtn_.toolTip = @"Open ~/Music/Axe FX Recordings in Finder.";
      }
    }
    updateDIPlaybackDisplay();
  }

  void updateDIPlaybackDisplay() {
    if (!diToggleBtn_ && !diPill_ && !diLoadBtn_) return;
    const bool active = isDIPlaybackActive();
    if (diPill_ && diPill_.layer) {
      diPill_.layer.borderColor = active
          ? [NSColor colorWithSRGBRed:0.20 green:0.78 blue:0.94 alpha:0.85].CGColor
          : [NSColor colorWithSRGBRed:0.145 green:0.165 blue:0.208 alpha:1.0].CGColor;
      diPill_.layer.backgroundColor = active
          ? [NSColor colorWithSRGBRed:0.06 green:0.14 blue:0.18 alpha:1.0].CGColor
          : [NSColor colorWithSRGBRed:0.086 green:0.098 blue:0.129 alpha:1.0].CGColor;
    }
    if (diToggleBtn_) {
      NSString* title = active ? @"■ DI" : @"▶ DI";
      NSColor* fg = active
          ? [NSColor colorWithSRGBRed:0.30 green:0.88 blue:1.00 alpha:1.0]
          : (diPlayHasSamples_ || hasLastSavedDIRecording()
                 ? [NSColor colorWithSRGBRed:0.76 green:0.82 blue:0.92 alpha:1.0]
                 : [NSColor colorWithSRGBRed:0.54 green:0.60 blue:0.70 alpha:1.0]);
      NSDictionary* attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: fg,
      };
      diToggleBtn_.attributedTitle =
          [[NSAttributedString alloc] initWithString:title attributes:attrs];
      if (active) {
        diToggleBtn_.toolTip = [NSString stringWithFormat:
            @"Looping Clean DI (%@) into the live rig for A/B testing. Click to stop (⇧⌘D).",
            diPlayFileName_ ?: @"WAV"];
      } else if (diPlayHasSamples_) {
        diToggleBtn_.toolTip = [NSString stringWithFormat:
            @"Play/loop loaded Clean DI (%@) through the live rig for A/B testing (⇧⌘D).",
            diPlayFileName_ ?: @"WAV"];
      } else if (hasLastSavedDIRecording()) {
        diToggleBtn_.toolTip = [NSString stringWithFormat:
            @"Loop last recorded Clean DI (%@) through the live rig for A/B testing.",
            lastSavedDIRecordingPath_.lastPathComponent];
      } else {
        diToggleBtn_.toolTip = @"Load and loop a Clean DI WAV through the live rig for A/B preset testing.";
      }
    }
    if (diLoadBtn_) {
      diLoadBtn_.toolTip = diPlayFileName_.length > 0
          ? [NSString stringWithFormat:@"Loaded Clean DI: %@ — Click to choose another WAV (⇧⌘L).", diPlayFileName_]
          : @"Choose a Clean DI WAV file to loop through the live rig (⇧⌘L).";
    }
  }
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
    if (isOutputRecording() && std::fabs(outputRecordSampleRate_ - sampleRate_) > 0.5) {
      stopOutputRecording();
    }
    stopAudioUnits();
    if (plugin_ && std::fabs(plugin_->hostSampleRate - sampleRate_) > 0.5) {
      plugin_->setSampleRateAndReload(sampleRate_);
    }
    if (diPlaySourceURL_ && std::fabs(diPlaySampleRate_ - sampleRate_) > 0.5) {
      const bool wasActive = isDIPlaybackActive();
      NSString* reloadErr = nil;
      if (!loadDIPlaybackFromURL(diPlaySourceURL_, wasActive, &reloadErr)) {
        stopDIPlayback();
      }
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
        port < NAMRig::kTransformerControlFirstPort + NAMRig::kTransformerControlCount &&
        size == sizeof(float)) {
      host->transformerControls_[port - NAMRig::kTransformerControlFirstPort] =
          *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port >= NAMRig::kRackControlFirstPort &&
        port < NAMRig::kRackControlFirstPort + NAMRig::kRackCount && size == sizeof(float)) {
      host->rackControls_[port - NAMRig::kRackControlFirstPort] =
          *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port >= NAMRig::kPowerTubeTypePort &&
        port <= NAMRig::kPowerTubeCharacterPort && size == sizeof(float)) {
      host->tubeControls_[port - NAMRig::kPowerTubeTypePort] =
          *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port == NAMRig::kMidPushPort && size == sizeof(float)) {
      host->midPushControl_ = *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port >= NAMRig::kOverdriveDrivePort &&
        port <= NAMRig::kOverdriveLevelPort && size == sizeof(float)) {
      host->overdriveControls_[port - NAMRig::kOverdriveDrivePort] =
          *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port >= NAMRig::kCompressorAttackPort &&
        port <= NAMRig::kCompressorEnabledPort && size == sizeof(float)) {
      host->compressorControls_[port - NAMRig::kCompressorAttackPort] =
          *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port == NAMRig::kOverdriveEnabledPort && size == sizeof(float)) {
      host->overdriveEnabled_ = *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port >= NAMRig::kPostCompressorFirstPort &&
        port <= NAMRig::kPostCompressorEnabledPort && size == sizeof(float)) {
      host->postCompressorControls_[port - NAMRig::kPostCompressorFirstPort] =
          *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port == NAMRig::kOverdriveTightPort && size == sizeof(float)) {
      host->overdriveTight_ = *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port == NAMRig::kOverdriveVoicingPort && size == sizeof(float)) {
      host->overdriveVoicing_ = *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port >= NAMRig::kPedal2EnabledPort && port <= NAMRig::kPedalOrderPort && size == sizeof(float)) {
      host->pedalBoardControls_[port - NAMRig::kPedal2EnabledPort] = *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && NAMRig::isPinEqPort(port) && size == sizeof(float)) {
      host->pinEqControls_[port - NAMRig::kPinEqFirstPort] = *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port >= NAMRig::kOutputCeilingPort && port <= NAMRig::kOutputBalancePort && size == sizeof(float)) {
      host->masterOutputControls_[port - NAMRig::kOutputCeilingPort] = *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port >= NAMRig::kToneEqModePort &&
        port < NAMRig::kToneEqModePort + NAMRig::kToneEqControlCount && size == sizeof(float)) {
      host->toneEqControls_[port - NAMRig::kToneEqModePort] = *static_cast<const float*>(buffer);
      return;
    }
    if (format == 0 && port == NAMRig::kDropPitchPort && size == sizeof(float)) {
      host->dropPitchControl_ = static_cast<float>(NAMRig::clampDropPitch(*static_cast<const float*>(buffer)));
      return;
    }
    if (format == 0 && port == NAMRig::kModelBandLimitPort && size == sizeof(float)) {
      host->modelBandLimitControl_ = *static_cast<const float*>(buffer) >= 0.5f ? 1.0f : 0.0f;
      return;
    }
    if (format == 0 && port >= NAMRig::kDropPitchAttackPort &&
        port <= NAMRig::kDropPitchSustainPort && size == sizeof(float)) {
      host->dropPitchShapingControls_[port - NAMRig::kDropPitchAttackPort] =
          std::clamp(*static_cast<const float*>(buffer), 0.0f, 100.0f);
      return;
    }
    if (format == 0 && port >= NAMRig::kModelBandLimitCutoffPort &&
        port <= NAMRig::kModelBandLimitRipplePort && size == sizeof(float)) {
      const float v = *static_cast<const float*>(buffer);
      if (port == NAMRig::kModelBandLimitCutoffPort) {
        host->modelBandLimitParamsControls_[0] = NAMRig::ModelBandLimit::clampCutoffHz(v);
      } else if (port == NAMRig::kModelBandLimitSlopePort) {
        host->modelBandLimitParamsControls_[1] =
            static_cast<float>(NAMRig::ModelBandLimit::clampSlope(v));
      } else {
        host->modelBandLimitParamsControls_[2] = NAMRig::ModelBandLimit::clampRippleDb(v);
      }
      return;
    }
    if (format == 0 && port == NAMRig::kSpatialCenterBlendPort && size == sizeof(float)) {
      host->spatialCenterBlendControl_ = *static_cast<const float*>(buffer) >= 0.5f ? 1.0f : 0.0f;
      return;
    }
    if (format == 0 && port == NAMRig::kSpeakerProfileBPort && size == sizeof(float)) {
      const float raw = *static_cast<const float*>(buffer);
      host->speakerBProfileControl_ = std::isfinite(raw)
          ? static_cast<float>(NAMRig::SpeakerDynamics::clampProfileB(static_cast<int>(
                std::clamp(raw, 0.0f, static_cast<float>(NAMRig::SpeakerDynamics::kProfileBCount - 1)) + 0.5f)))
          : NAMRig::kSpeakerProfileBDefault;
      return;
    }
    if (format == 0 && port >= NAMRig::kCabLowCutSlopePort &&
        port <= NAMRig::kCabHighCutSlopePort && size == sizeof(float)) {
      host->cabCutSlopeControls_[port - NAMRig::kCabLowCutSlopePort] =
          static_cast<float>(NAMRig::clampCabCutSlope(*static_cast<const float*>(buffer)));
      return;
    }
    if (format == 0 && port == NAMRig::kCabIrAutoTrimPort && size == sizeof(float)) {
      host->cabIrAutoTrimControl_ = *static_cast<const float*>(buffer) >= 0.5f ? 1.0f : 0.0f;
      return;
    }
    if (port == 0 && format == host->eventTransfer_)
      host->uiToAudio_.push(size, format, buffer);
  }

  static int resizeUI(LV2UI_Feature_Handle handle, int width, int height) {
    auto* host = static_cast<StandaloneHost*>(handle);
    if (!host->window_) return 1;
    if ((host->window_.styleMask & NSWindowStyleMaskFullScreen) != 0) {
      [host->window_.contentView setNeedsLayout:YES];
      [host->window_.contentView setNeedsDisplay:YES];
      return 0;
    }
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

    uiDescriptor_->port_event(uiHandle_, NAMRig::kOutputReductionPort, sizeof(float), 0,
                                &masterOutputControls_[2]);
    if (isOutputRecording()) {
      drainOutputRecordingToDisk();
    }
    updateRecordingDisplay();
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
        // Measure channel peaks to avoid halving mono instruments (e.g. guitar in In 1 or In 2
        // on a multi-channel interface with In 1+2 selected). If only one channel is active,
        // route it at unity gain (0 dB) rather than cutting it by -6 dB.
        float p0 = 0.0f, p1 = 0.0f;
        for (UInt32 i = 0; i < frames; ++i) {
          const float a = std::fabs(ch0[i]);
          const float b = std::fabs(ch1[i]);
          if (a > p0) p0 = a;
          if (b > p1) p1 = b;
        }
        constexpr float kActiveThreshold = 1.0e-4f; // ~ -80 dBFS
        if (p0 > kActiveThreshold && p1 <= std::max(kActiveThreshold, 0.05f * p0)) {
          std::copy_n(ch0, frames, dstMono);
          return;
        }
        if (p1 > kActiveThreshold && p0 <= std::max(kActiveThreshold, 0.05f * p1)) {
          std::copy_n(ch1, frames, dstMono);
          return;
        }
        // Both channels active (stereo instrument/pedals) or both quiet: sum at unity gain
        for (UInt32 i = 0; i < frames; ++i) {
          dstMono[i] = ch0[i] + ch1[i];
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
        inputRing_.pop(input_.data(), frames, std::max<uint32_t>(bufferSize_ * 4, frames * 4));
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

    if (diPlayActive_.load(std::memory_order_acquire) && !diPlaySamples_.empty()) {
      const size_t total = diPlaySamples_.size();
      size_t cursor = diPlayCursor_.load(std::memory_order_relaxed);
      if (cursor >= total) cursor %= total;
      for (UInt32 i = 0; i < frames; ++i) {
        input_[i] = diPlaySamples_[cursor];
        if (++cursor >= total) cursor = 0;
      }
      diPlayCursor_.store(cursor, std::memory_order_relaxed);
    }

    const bool rec = outputRecording_.load(std::memory_order_acquire);
    if (rec) {
      diRecordRing_.push(input_.data(), nullptr, frames);
    }

    worker_.applyResponses();
    buildControlSequence();
    resetSequence(notifyBuffer_, kAtomBufferSize - sizeof(LV2_Atom));
    plugin_->process(frames, cabinetDeadline);
    collectNotifications();
    rigRiffRecorderPushPair(input_.data(), output_.data(), outputR_.data(), frames, sampleRate_,
        static_cast<uint32_t>(std::max(0.0f, controls_[29 - 4])));
    if (rec) {
      const uint32_t pushed = outputRecordRing_.push(output_.data(), outputR_.data(), frames);
      if (pushed > 0) {
        outputRecordedFrames_.fetch_add(pushed, std::memory_order_relaxed);
      }
    }

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
    // Build selections apply to Finder/Dock launches; environment overrides
    // are temporary so either path can still be compared without rebuilding.
    const char* parallel = std::getenv("AXE_FX_PARALLEL_CABS");
    const char* parallelModels = std::getenv("AXE_FX_PARALLEL_MODELS");
    const bool useParallelCabs = parallel ? std::strcmp(parallel, "1") == 0
                                         : AXE_FX_PARALLEL_CABS_DEFAULT != 0;
    const bool useParallelModels = parallelModels ? std::strcmp(parallelModels, "0") != 0
                                                : AXE_FX_PARALLEL_MODELS_DEFAULT != 0;
    if (useParallelCabs || useParallelModels) {
      void* rawGroup = nullptr;
      UInt32 size = sizeof(rawGroup);
      if (AudioUnitGetProperty(audioUnit_, kAudioOutputUnitProperty_OSWorkgroup,
                               kAudioUnitScope_Global, 0, &rawGroup, &size) == noErr && rawGroup) {
        // AudioUnitGetProperty returns +1; ARC releases our reference after
        // the helper has retained it for its entire join/leave lifetime.
        os_workgroup_t group = (__bridge_transfer os_workgroup_t)rawGroup;
        const size_t maxThreads = os_workgroup_max_parallel_threads(group, nullptr);
        size_t helpers = maxThreads > 1 ? maxThreads - 1 : 0;
        if (helpers && useParallelCabs &&
            cabinetWorker_.start((__bridge void*)group, bufferSize_ / streamRate)) {
          plugin_->setCabinetWorker(&cabinetWorker_);
          --helpers;
        }
        if (helpers && useParallelModels &&
            polyphaseWorker_.start((__bridge void*)group, bufferSize_ / streamRate, helpers)) {
          plugin_->setPolyphaseWorker(&polyphaseWorker_);
          std::fprintf(stderr, "Multicore models: %zu helper threads enabled\n",
                       polyphaseWorker_.helperCount());
        } else if (useParallelModels) {
          std::fprintf(stderr, "Multicore models unavailable; using serial processing\n");
        }
      } else if (useParallelModels) {
        std::fprintf(stderr, "No audio workgroup; using serial model processing\n");
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

    // When Input is left at System Default ("") and Output is a duplex audio
    // interface (e.g. Scarlett Solo) while macOS's default input is the built-in
    // microphone, prefer the duplex output interface so input and output share
    // a single hardware clock (avoiding split-HAL clock-drift clicks/pops).
    if (inputDeviceUID_.empty() && inDev != outDev && outDev != kAudioObjectUnknown) {
      const CoreAudioDeviceInfo* inInfo = nullptr;
      const CoreAudioDeviceInfo* outInfo = nullptr;
      for (const auto& d : devices) {
        if (d.deviceID == inDev) inInfo = &d;
        if (d.deviceID == outDev) outInfo = &d;
      }
      const bool inIsBuiltInMic = !inInfo || inInfo->inputChannels == 0 ||
          inInfo->uid.find("BuiltInMicrophone") != std::string::npos;
      if (outInfo && outInfo->inputChannels > 0 && inIsBuiltInMic) {
        inDev = outDev;
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
  NAMRig::PolyphaseWorker polyphaseWorker_;
  static constexpr uint32_t kRenderActive = 1, kRenderSuspended = 2;
  std::atomic<uint32_t> renderState_{kRenderSuspended};
  double audioTicksPerFrame_ = 0.0;
  NSView* __weak parentView_ = nil;
  NSTextField* __weak cpuLabel_ = nil;
  NSView* __weak cpuBarFill_ = nil;
  NSView* __weak cpuBarSlot_ = nil;
  NSView* __weak recPill_ = nil;
  NSButton* __weak recToggleBtn_ = nil;
  NSTextField* __weak recTimeLabel_ = nil;
  NSButton* __weak recRevealBtn_ = nil;
  NSView* __weak diPill_ = nil;
  NSButton* __weak diToggleBtn_ = nil;
  NSButton* __weak diLoadBtn_ = nil;
  StandaloneAnimatedAmpView* __weak headerAmpView_ = nil;
  StandaloneAnimatedAmpView* __weak dockAmpView_ = nil;
  std::atomic<float> cpuLoadPercent_{0.0f};
  std::atomic<float> signalLevel_{0.0f};
  std::atomic<bool> ampIconsVisible_{true};
  std::atomic<bool> outputRecording_{false};
  std::atomic<uint64_t> outputRecordedFrames_{0};
  SampleRecordRing<2> outputRecordRing_;
  SampleRecordRing<1> diRecordRing_;
  std::vector<float> outputFloatScratch_;
  std::vector<uint8_t> outputPcmScratch_;
  std::FILE* outputRecordFile_ = nullptr;
  std::FILE* diRecordFile_ = nullptr;
  uint64_t outputWrittenFrames_ = 0;
  uint64_t diWrittenFrames_ = 0;
  double outputRecordSampleRate_ = 48000.0;
  NSString* __strong activeRecordingPath_ = nil;
  NSString* __strong activeDIRecordingPath_ = nil;
  NSString* __strong lastSavedRecordingPath_ = nil;
  NSString* __strong lastSavedDIRecordingPath_ = nil;
  std::atomic<bool> diPlayActive_{false};
  std::atomic<size_t> diPlayCursor_{0};
  std::vector<float> diPlaySamples_;
  bool diPlayHasSamples_ = false;
  double diPlaySampleRate_ = 48000.0;
  NSURL* __strong diPlaySourceURL_ = nil;
  NSString* __strong diPlayFileName_ = nil;
  double lastSavedRecordingDuration_ = 0.0;
  CFAbsoluteTime lastRecUiTime_ = 0.0;
  bool lastRecUiState_ = false;
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
  std::array<float, NAMRig::kRackCount> rackControls_ = NAMRig::kRackControlDefaults;
  std::array<float, 2> tubeControls_ = {0.0f, NAMRig::kPowerTubeCharacterDefault};
  float midPushControl_ = 0.0f;
  std::array<float, 3> overdriveControls_ = {0.0f, NAMRig::Overdrive::kToneDefault, 0.0f};
  float overdriveTight_ = NAMRig::kOverdriveTightDefault;
  std::array<float, 3> pedalBoardControls_{};
  std::array<float, 3> masterOutputControls_{};
  float overdriveVoicing_ = NAMRig::kOverdriveVoicingDefault;
  float overdriveEnabled_ = 1.0f;
  std::array<float, 3> compressorControls_ = {NAMRig::kCompressorAttackDefault, NAMRig::kCompressorReleaseDefault, 1.0f};
  std::array<float, 4> postCompressorControls_ = NAMRig::kPostCompressorDefaults;
  std::array<float, NAMRig::kToneEqControlCount> toneEqControls_ = NAMRig::toneEqDefaults();
  float dropPitchControl_ = NAMRig::kDropPitchDefault;
  float modelBandLimitControl_ = NAMRig::kModelBandLimitDefault;
  std::array<float, 2> dropPitchShapingControls_ = {
      NAMRig::kDropPitchAttackDefault,
      NAMRig::kDropPitchSustainDefault,
  };
  std::array<float, 3> modelBandLimitParamsControls_ = {
      NAMRig::kModelBandLimitCutoffDefault,
      NAMRig::kModelBandLimitSlopeDefault,
      NAMRig::kModelBandLimitRippleDefault,
  };
  float spatialCenterBlendControl_ = NAMRig::kSpatialCenterBlendDefault;
  float speakerBProfileControl_ = NAMRig::kSpeakerProfileBDefault;
  std::array<float, 2> cabCutSlopeControls_ = {
      NAMRig::kCabLowCutSlopeDefault,
      NAMRig::kCabHighCutSlopeDefault,
  };
  float cabIrAutoTrimControl_ = NAMRig::kCabIrAutoTrimDefault;
  std::array<float, NAMRig::kPinEqPortCount> pinEqControls_ = NAMRig::pinEqDefaults();
  std::array<uint8_t, kAtomBufferSize> controlBuffer_{};
  std::array<uint8_t, kAtomBufferSize> notifyBuffer_{};
  MessageRing uiToAudio_;
  MessageRing audioToUI_;

  std::mutex uriMutex_;
  std::deque<std::string> uris_;
  std::unordered_map<std::string, LV2_URID> urids_;
  LV2_URID atomSequence_ = 0, eventTransfer_ = 0, atomInt_ = 0, maxBlockLength_ = 0;
  LV2_URID_Map mapFeature_{};
  LV2_Log_Log logFeature_{};
  LV2UI_Resize resizeFeature_{};
  LV2_Feature mapLV2Feature_{}, scheduleLV2Feature_{}, logLV2Feature_{}, optionsLV2Feature_{};
  LV2_Feature parentLV2Feature_{}, mapUILV2Feature_{}, resizeLV2Feature_{};
  int32_t maxFramesOption_ = kMaxFrames;
  std::array<LV2_Options_Option, 2> options_{};

  NAMRig::StandaloneWorker worker_;
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

@interface StandaloneTitlebarRecContainerView : NSView
@property(nonatomic, strong) NSView* diPill;
@property(nonatomic, strong) NSView* recPill;
@end

@implementation StandaloneTitlebarRecContainerView
- (NSSize)intrinsicContentSize {
  return NSMakeSize(264.0, 28.0);
}
- (void)layout {
  [super layout];
  CGFloat recX = self.bounds.size.width - 24.0;
  if (_recPill) {
    const CGFloat pillW = _recPill.frame.size.width;
    const CGFloat pillH = _recPill.frame.size.height;
    recX = std::max<CGFloat>(0.0, self.bounds.size.width - 24.0 - pillW);
    const CGFloat y = std::floor((self.bounds.size.height - pillH) * 0.5);
    _recPill.frame = NSMakeRect(recX, y, pillW, pillH);
  }
  if (_diPill) {
    const CGFloat pillW = _diPill.frame.size.width;
    const CGFloat pillH = _diPill.frame.size.height;
    const CGFloat x = std::max<CGFloat>(0.0, recX - 8.0 - pillW);
    const CGFloat y = std::floor((self.bounds.size.height - pillH) * 0.5);
    _diPill.frame = NSMakeRect(x, y, pillW, pillH);
  }
}
@end

@interface StandaloneContentRootView : NSView
@property(nonatomic, strong) NSView* cpuPill;
@property(nonatomic, strong) NSPopUpButton* audioPopup;
@property(nonatomic, strong) StandaloneAnimatedAmpView* ampIconView;
@property(nonatomic, strong) NSView* pluginHostView;
@end

@implementation StandaloneContentRootView
- (void)layout {
  [super layout];
  if (_pluginHostView) {
    const CGFloat availW = self.bounds.size.width;
    const CGFloat availH = self.bounds.size.height - kToolbarStripHeight;
    const CGFloat baseW = 1520.0;
    const CGFloat baseH = 980.0;

    const CGFloat scale = std::max<CGFloat>(1.0, std::min<CGFloat>(availW / baseW, availH / baseH));
    const CGFloat scaledW = std::floor(baseW * scale);
    const CGFloat scaledH = std::floor(baseH * scale);
    const CGFloat hostX = std::max<CGFloat>(0.0, std::floor((availW - scaledW) / 2.0));
    const CGFloat hostY = std::max<CGFloat>(0.0, std::floor((availH - scaledH) / 2.0));
    _pluginHostView.frame = NSMakeRect(hostX, hostY, scaledW, scaledH);
    for (NSView* pluginView in _pluginHostView.subviews) {
      pluginView.frame = _pluginHostView.bounds;
      [pluginView setNeedsLayout:YES];
    }
  }
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
    // Narrow enough that the plugin's header (A/B START button) stays uncovered.
    const CGFloat audioW = kAudioPopupWidth;
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
  NSMenu* _appPerfSubmenu;
  NSMenu* _appAuditSubmenu;
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
  // Same interface both ways: don't repeat the device name (full names are in the tooltip).
  if ([inShort isEqualToString:outShort]) {
    return [NSString stringWithFormat:@"%@%@ ▸%@ · %@/%u",
                                      inShort, chTag, outChTag, khzStr, _host->bufferSize()];
  }
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

  // 7. PERFORMANCE MODE (OVERSAMPLING)
  [menu addItem:[NSMenuItem separatorItem]];
  addHeader(@"PERFORMANCE MODE (OVERSAMPLING)");
  {
    struct ModeEntry {
      int mode;
      NSString* title;
    };
    const ModeEntry kModes[] = {
      {NAMRig::kOversampleTrue8, @"True 8× (Maximum Quality — Default)"},
      {NAMRig::kOversampleTrue4, @"True 4× (Low Latency / Live)"},
      {NAMRig::kOversampleTrue2, @"True 2× (Ultra-Low CPU)"},
      {NAMRig::kOversampleLegacy, @"Legacy (Session Rate)"},
      {NAMRig::kOversampleNone, @"Off / 1× (Bypass)"},
    };
    const int curMode = _host ? _host->oversampleMode() : NAMRig::kOversampleTrue8;
    for (const auto& m : kModes) {
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:m.title
                                                    action:@selector(selectOversampleMode:)
                                             keyEquivalent:@""];
      item.target = self;
      item.tag = m.mode;
      item.state = (curMode == m.mode) ? NSControlStateValueOn : NSControlStateValueOff;
      [menu addItem:item];
    }
  }

  // 8. AMPLIFIER ENGINE (ORIGINAL / PROPOSED AUDIT A/B)
  [menu addItem:[NSMenuItem separatorItem]];
  addHeader(@"AMPLIFIER ENGINE (ORIGINAL / PROPOSED)");
  {
    const bool allProp = NAMRig::AuditMode::allProposed();
    const bool anyProp = NAMRig::AuditMode::anyProposed();

    NSMenuItem* propItem = [[NSMenuItem alloc] initWithTitle:@"Proposed (Audit Improvements)"
                                                      action:@selector(selectAuditModePreset:)
                                               keyEquivalent:@""];
    propItem.target = self;
    propItem.tag = 1;
    propItem.state = allProp ? NSControlStateValueOn
                   : anyProp ? NSControlStateValueMixed
                             : NSControlStateValueOff;
    [menu addItem:propItem];

    NSMenuItem* origItem = [[NSMenuItem alloc] initWithTitle:@"Original (Legacy Baseline)"
                                                      action:@selector(selectAuditModePreset:)
                                               keyEquivalent:@""];
    origItem.target = self;
    origItem.tag = 0;
    origItem.state = !anyProp ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:origItem];
  }

  // 9. PROFILER
  [menu addItem:[NSMenuItem separatorItem]];
  addHeader(@"DSP PERFORMANCE PROFILER");
  {
    NSMenuItem* profItem = [[NSMenuItem alloc] initWithTitle:@"Profile Active Preset…"
                                                      action:@selector(profileActivePresetAction:)
                                               keyEquivalent:@""];
    profItem.target = self;
    [menu addItem:profItem];

    NSMenuItem* profAllItem = [[NSMenuItem alloc] initWithTitle:@"Profile All Presets…"
                                                         action:@selector(profileAllPresetsAction:)
                                                  keyEquivalent:@""];
    profAllItem.target = self;
    [menu addItem:profAllItem];
  }
}

- (void)populatePerformanceMenu:(NSMenu*)menu {
  [menu removeAllItems];
  struct ModeEntry {
    int mode;
    NSString* title;
    NSString* tip;
  };
  const ModeEntry kModes[] = {
    {NAMRig::kOversampleTrue8, @"True 8× (Maximum Quality — Default)", @"Highest fidelity. 8x oversampled neural amp stage."},
    {NAMRig::kOversampleTrue4, @"True 4× (Low Latency / Live)", @"Recommended for 32/64 samples. Great balance of low latency and sound quality."},
    {NAMRig::kOversampleTrue2, @"True 2× (Ultra-Low CPU)", @"Minimal CPU impact for high sample rates or older hardware."},
    {NAMRig::kOversampleLegacy, @"Legacy (Session Rate)", @"Dilation scaling without true resampling."},
    {NAMRig::kOversampleNone, @"Off / 1× (Bypass)", @"No oversampling."},
  };
  const int curMode = _host ? _host->oversampleMode() : NAMRig::kOversampleTrue8;
  for (const auto& m : kModes) {
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:m.title
                                                  action:@selector(selectOversampleMode:)
                                           keyEquivalent:@""];
    item.target = self;
    item.tag = m.mode;
    item.toolTip = m.tip;
    item.state = (curMode == m.mode) ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:item];
  }
}

- (void)populateAuditMenu:(NSMenu*)menu {
  [menu removeAllItems];
  const bool allProp = NAMRig::AuditMode::allProposed();
  const bool anyProp = NAMRig::AuditMode::anyProposed();

  NSMenuItem* propItem = [[NSMenuItem alloc] initWithTitle:@"Proposed (All Audit Improvements)"
                                                    action:@selector(selectAuditModePreset:)
                                             keyEquivalent:@""];
  propItem.target = self;
  propItem.tag = 1;
  propItem.toolTip = @"Enables all 5 amplifier audit improvements: Power Stage biased ZDF solver + NFB linearity + C² tube curve + dual-stage sag, exact WaveNet std::tanh, Polyphase A2-max (condition_dsp) & multi-tap head, inter-stage ultrasonic band-limiting (< 0.5× model rate), and native 48 kHz True-oversampling base rate.";
  propItem.state = allProp ? NSControlStateValueOn
                 : anyProp ? NSControlStateValueMixed
                           : NSControlStateValueOff;
  [menu addItem:propItem];

  NSMenuItem* origItem = [[NSMenuItem alloc] initWithTitle:@"Original (Legacy Baseline)"
                                                    action:@selector(selectAuditModePreset:)
                                             keyEquivalent:@""];
  origItem.target = self;
  origItem.tag = 0;
  origItem.toolTip = @"Reverts all amplifier stages to the exact pre-audit baseline implementation for instant A/B comparison.";
  origItem.state = !anyProp ? NSControlStateValueOn : NSControlStateValueOff;
  [menu addItem:origItem];

  [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem* hdr = [[NSMenuItem alloc] initWithTitle:@"INDIVIDUAL AUDIT FIXES"
                                               action:NULL
                                        keyEquivalent:@""];
  hdr.enabled = NO;
  [menu addItem:hdr];

  struct FixEntry {
    uint32_t flag;
    NSString* title;
    NSString* tip;
  };
  const FixEntry kFixes[] = {
    {NAMRig::AuditMode::kInterStageBandLimit,
     @"#1 (1.4) Inter-Stage Ultrasonic Band-Limit & Nyquist Clamp",
     @"Automatically band-limits ultrasonic harmonics (> 20.5 kHz, clamped < 0.5× model rate) before oversampled NAM stages to eliminate intermodulation aliasing."},
    {NAMRig::AuditMode::kPowerStageZdfAndTube,
     @"#2 (1.1 & 2.1) Power Stage Biased ZDF, NFB Linearity, C² Tube & Dual Sag",
     @"Solves the biased ZDF loop in input coordinate u, keeps Negative Feedback linear at Master=0, upgrades the knee to a C² tube curve, and splits sag into fast screen-grid squish + slow B+ reservoir bloom."},
    {NAMRig::AuditMode::kExactWaveNetTanh,
     @"#3 (1.2) Exact WaveNet Tanh (Disable Clamping fast_tanh)",
     @"Uses exact IEEE-754 std::tanh across WaveNet & NAMCore layers instead of the clamping rational approximation."},
    {NAMRig::AuditMode::kPolyphaseCondition,
     @"1.3 Polyphase A2-max (condition_dsp) & Multi-Tap Head",
     @"Wraps condition_dsp (A2-max) and multi-tap head WaveNets in PolyphaseModel inside True oversampling domains so their internal delays stay at native 48 kHz."},
    {NAMRig::AuditMode::kNativeTrueBaseRate,
     @"1.5 Native 48 kHz True-Oversampling Base Rate",
     @"Pins True Nx oversampling to the 48 kHz native NAM rate instead of 96 kHz, cutting 48 kHz True-oversampling latency by 12–21 samples and halving CPU at True 2×/4×/8×."},
  };
  for (const auto& f : kFixes) {
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:f.title
                                                  action:@selector(toggleAuditFixFlag:)
                                           keyEquivalent:@""];
    item.target = self;
    item.tag = static_cast<NSInteger>(f.flag);
    item.toolTip = f.tip;
    item.state = NAMRig::AuditMode::has(f.flag) ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:item];
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
        @"Click to change input/output devices, input/output channels (Stereo Out), sample rate (kHz), buffer size, or oversampling mode.",
        _host ? _host->activeInputDeviceName().c_str() : "Default",
        _host ? _host->activeOutputDeviceName().c_str() : "Default",
        sr / 1000.0, buf, ms];
  }
  if (_appAudioSubmenu) {
    [self populateAudioMenu:_appAudioSubmenu includeTitleItem:NO];
  }
  if (_appPerfSubmenu) {
    [self populatePerformanceMenu:_appPerfSubmenu];
  }
  if (_appAuditSubmenu) {
    [self populateAuditMenu:_appAuditSubmenu];
  }
  if (_window) {
    const bool allProp = NAMRig::AuditMode::allProposed();
    const bool anyProp = NAMRig::AuditMode::anyProposed();
    _window.title = allProp ? @"Axe FX — Proposed Engine"
                  : anyProp ? @"Axe FX — Custom Audit Engine"
                            : @"Axe FX — Original Engine";
  }
}

- (void)menuNeedsUpdate:(NSMenu*)menu {
  if (menu == _audioPopup.menu) {
    [self populateAudioMenu:menu includeTitleItem:YES];
  } else if (menu == _appAudioSubmenu) {
    [self populateAudioMenu:menu includeTitleItem:NO];
  } else if (menu == _appPerfSubmenu) {
    [self populatePerformanceMenu:menu];
  } else if (menu == _appAuditSubmenu) {
    [self populateAuditMenu:menu];
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

- (void)selectOversampleMode:(NSMenuItem*)sender {
  if (!_host) return;
  _host->setOversampleMode(static_cast<int>(sender.tag));
  [self refreshAudioMenusAndTitle];
}

- (void)selectAuditModePreset:(NSMenuItem*)sender {
  const bool enableProposed = (sender.tag != 0);
  NAMRig::AuditMode::setProposed(enableProposed);
  [[NSUserDefaults standardUserDefaults] setInteger:static_cast<NSInteger>(NAMRig::AuditMode::flags())
                                             forKey:@"AxeFXAmpAuditFlags"];
  [self refreshAudioMenusAndTitle];
}

- (void)toggleAuditFixFlag:(NSMenuItem*)sender {
  const uint32_t flag = static_cast<uint32_t>(sender.tag);
  NAMRig::AuditMode::toggleFlag(flag);
  [[NSUserDefaults standardUserDefaults] setInteger:static_cast<NSInteger>(NAMRig::AuditMode::flags())
                                             forKey:@"AxeFXAmpAuditFlags"];
  [self refreshAudioMenusAndTitle];
}

- (void)profileActivePresetAction:(id)sender {
  (void)sender;
  [RigStandaloneProfiler profileActivePresetWithParentWindow:_window];
}

- (void)profileAllPresetsAction:(id)sender {
  (void)sender;
  [RigStandaloneProfiler profileAllPresetsWithParentWindow:_window];
}

extern void openAICopilotInActiveRig();

- (void)openAICopilotAction:(id)sender {
  (void)sender;
  openAICopilotInActiveRig();
}

- (void)toggleOutputRecordingAction:(id)sender {
  (void)sender;
  if (!_host) return;
  NSString* err = nil;
  _host->toggleOutputRecording(&err);
  if (err.length > 0) {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Could Not Start Output Recording";
    alert.informativeText = err;
    [alert runModal];
  }
}

- (void)revealOutputRecordingAction:(id)sender {
  (void)sender;
  if (!_host) return;
  _host->revealOutputRecordingInFinder();
}

- (void)loadDIWavAction:(id)sender {
  (void)sender;
  if (!_host) return;
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.allowedFileTypes = @[@"wav", @"aif", @"aiff", @"caf", @"flac", @"mp3", @"m4a"];
  panel.title = @"Load Clean DI WAV for A/B Testing";
  panel.message = @"Select a clean guitar DI audio file to loop through the live rig so you can A/B test presets with identical playing.";
  panel.prompt = @"Load & Loop DI";
  panel.canChooseDirectories = NO;
  panel.allowsMultipleSelection = NO;
  NSString* recDir = StandaloneHost::recordingsDirectoryPath();
  if (recDir.length > 0) {
    panel.directoryURL = [NSURL fileURLWithPath:recDir isDirectory:YES];
  }
  [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response) {
    if (response != NSModalResponseOK || !panel.URL || !self->_host) return;
    NSString* err = nil;
    if (!self->_host->loadDIPlaybackFromURL(panel.URL, true, &err) && err.length > 0) {
      NSAlert* alert = [[NSAlert alloc] init];
      alert.messageText = @"Could Not Load Clean DI Audio";
      alert.informativeText = err;
      [alert runModal];
    }
  }];
}

- (void)toggleDIPlaybackAction:(id)sender {
  (void)sender;
  if (!_host) return;
  if (_host->hasLoadedDIPlayback()) {
    _host->toggleDIPlayback();
  } else if (_host->hasLastSavedDIRecording()) {
    NSString* err = nil;
    if (!_host->useLastRecordedDI(&err) && err.length > 0) {
      NSAlert* alert = [[NSAlert alloc] init];
      alert.messageText = @"Could Not Play Last Clean DI";
      alert.informativeText = err;
      [alert runModal];
    }
  } else {
    [self loadDIWavAction:sender];
  }
}

- (void)useLastRecordedDIAction:(id)sender {
  (void)sender;
  if (!_host) return;
  NSString* err = nil;
  if (!_host->useLastRecordedDI(&err) && err.length > 0) {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"No Clean DI Recording Available";
    alert.informativeText = err;
    [alert runModal];
  }
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

  NSMenuItem* perfMenuItem = [[NSMenuItem alloc] initWithTitle:@"Performance Mode (Oversampling)"
                                                        action:NULL
                                                 keyEquivalent:@""];
  _appPerfSubmenu = [[NSMenu alloc] initWithTitle:@"Performance Mode (Oversampling)"];
  _appPerfSubmenu.delegate = self;
  perfMenuItem.submenu = _appPerfSubmenu;
  [appMenu addItem:perfMenuItem];

  NSMenuItem* auditMenuItem = [[NSMenuItem alloc] initWithTitle:@"Amplifier Engine (Original / Proposed)"
                                                         action:NULL
                                                  keyEquivalent:@""];
  _appAuditSubmenu = [[NSMenu alloc] initWithTitle:@"Amplifier Engine (Original / Proposed)"];
  _appAuditSubmenu.delegate = self;
  auditMenuItem.submenu = _appAuditSubmenu;
  [appMenu addItem:auditMenuItem];

  [appMenu addItem:[NSMenuItem separatorItem]];

  NSMenuItem* profActiveItem = [[NSMenuItem alloc] initWithTitle:@"Profile Active Preset…"
                                                          action:@selector(profileActivePresetAction:)
                                                   keyEquivalent:@"p"];
  profActiveItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  profActiveItem.target = self;
  [appMenu addItem:profActiveItem];

  NSMenuItem* profAllItem = [[NSMenuItem alloc] initWithTitle:@"Profile All Presets…"
                                                       action:@selector(profileAllPresetsAction:)
                                                keyEquivalent:@"P"];
  profAllItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  profAllItem.target = self;
  [appMenu addItem:profAllItem];

  NSMenuItem* copilotItem = [[NSMenuItem alloc] initWithTitle:@"AI Tone Tuning…"
                                                       action:@selector(openAICopilotAction:)
                                                keyEquivalent:@"k"];
  copilotItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  copilotItem.target = self;
  [appMenu addItem:copilotItem];

  [appMenu addItem:[NSMenuItem separatorItem]];

  NSMenuItem* recToggleItem = [[NSMenuItem alloc] initWithTitle:@"Start/Stop Output Recording"
                                                         action:@selector(toggleOutputRecordingAction:)
                                                  keyEquivalent:@"r"];
  recToggleItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  recToggleItem.target = self;
  [appMenu addItem:recToggleItem];

  NSMenuItem* recRevealItem = [[NSMenuItem alloc] initWithTitle:@"Show Recordings in Finder"
                                                         action:@selector(revealOutputRecordingAction:)
                                                  keyEquivalent:@""];
  recRevealItem.target = self;
  [appMenu addItem:recRevealItem];

  [appMenu addItem:[NSMenuItem separatorItem]];

  NSMenuItem* diLoadItem = [[NSMenuItem alloc] initWithTitle:@"Load Clean DI WAV for A/B…"
                                                      action:@selector(loadDIWavAction:)
                                               keyEquivalent:@"L"];
  diLoadItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  diLoadItem.target = self;
  [appMenu addItem:diLoadItem];

  NSMenuItem* diToggleItem = [[NSMenuItem alloc] initWithTitle:@"Play/Stop Clean DI Loop"
                                                        action:@selector(toggleDIPlaybackAction:)
                                                 keyEquivalent:@"D"];
  diToggleItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  diToggleItem.target = self;
  [appMenu addItem:diToggleItem];

  NSMenuItem* diLastItem = [[NSMenuItem alloc] initWithTitle:@"Use Last Recorded Clean DI"
                                                      action:@selector(useLastRecordedDIAction:)
                                               keyEquivalent:@""];
  diLastItem.target = self;
  [appMenu addItem:diLastItem];

  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:@"Quit Axe FX"
                     action:@selector(terminate:)
              keyEquivalent:@"q"];
  appItem.submenu = appMenu;

  NSMenuItem* editItem = [[NSMenuItem alloc] init];
  NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
  [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
  [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
  [editMenu addItem:[NSMenuItem separatorItem]];
  [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
  [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
  [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
  editItem.submenu = editMenu;
  [menu addItem:editItem];

  NSMenuItem* viewItem = [[NSMenuItem alloc] init];
  NSMenu* viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
  NSMenuItem* fullScreenItem = [[NSMenuItem alloc] initWithTitle:@"Toggle Full Screen"
                                                          action:@selector(toggleFullScreen:)
                                                   keyEquivalent:@"f"];
  fullScreenItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
  [viewMenu addItem:fullScreenItem];
  viewItem.submenu = viewMenu;
  [menu addItem:viewItem];

  NSMenuItem* windowItem = [[NSMenuItem alloc] init];
  NSMenu* windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
  [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
  [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
  [windowMenu addItem:[NSMenuItem separatorItem]];
  [windowMenu addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];
  windowItem.submenu = windowMenu;
  [menu addItem:windowItem];
  NSApp.windowsMenu = windowMenu;

  NSApp.mainMenu = menu;

  // Live animated tube-amp Dock tile icon
  _dockAmpView = [[StandaloneAnimatedAmpView alloc] initWithFrame:NSMakeRect(0, 0, 128, 128)];
  NSApp.dockTile.contentView = _dockAmpView;
  [NSApp.dockTile display];

  const NSRect initialContent = NSMakeRect(0, 0, 1520, 980 + kToolbarStripHeight);
  _window = [[NSWindow alloc]
      initWithContentRect:initialContent
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  _window.title = @"Axe FX";
  _window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  _window.delegate = self;
  _window.releasedWhenClosed = NO;
  _window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
  _window.minSize = NSMakeSize(1520, 980 + kToolbarStripHeight);

  StandaloneContentRootView* rootContent =
      [[StandaloneContentRootView alloc] initWithFrame:initialContent];
  rootContent.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _window.contentView = rootContent;

  _pluginHostView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1520, 980)];
  _pluginHostView.autoresizingMask = NSViewNotSizable;
  rootContent.pluginHostView = _pluginHostView;
  [rootContent addSubview:_pluginHostView];

  // Top-left animated tube-amp badge in the header toolbar strip.
  StandaloneAnimatedAmpView* headerAmp =
      [[StandaloneAnimatedAmpView alloc] initWithFrame:NSMakeRect(12, 980 + 2, 24, 24)];
  headerAmp.toolTip = @"Axe FX · Active Tube Amp Engine (tubes glow with your guitar signal).";
  rootContent.ampIconView = headerAmp;
  [rootContent addSubview:headerAmp positioned:NSWindowAbove relativeTo:nil];

  // Top-banner Audio I/O dropdown menu (Input Device, Input Channel, Output Device, Output Channel, kHz, Buffer Size).
  _audioPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(1520 - 24 - 136 - 8 - kAudioPopupWidth, 980 + 2, kAudioPopupWidth, 24)
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

  // Right-hand grey titlebar DI re-amp + output recorder pills (aligned above CPU pill).
  const CGFloat diPillW = 96.0;
  const CGFloat recPillW = 136.0;
  const CGFloat recPillH = 22.0;
  StandaloneTitlebarRecContainerView* recContainer =
      [[StandaloneTitlebarRecContainerView alloc] initWithFrame:NSMakeRect(0, 0, diPillW + 8.0 + recPillW + 24.0, 28.0)];

  NSView* diPill = [[NSView alloc] initWithFrame:NSMakeRect(0, 3, diPillW, recPillH)];
  diPill.wantsLayer = YES;
  diPill.layer.backgroundColor = [NSColor colorWithSRGBRed:0.086 green:0.098 blue:0.129 alpha:1.0].CGColor;
  diPill.layer.cornerRadius = 7.0;
  diPill.layer.borderWidth = 1.0;
  diPill.layer.borderColor = [NSColor colorWithSRGBRed:0.145 green:0.165 blue:0.208 alpha:1.0].CGColor;
  diPill.toolTip = @"Loop a Clean DI WAV through the live rig for A/B preset testing.";

  NSButton* diToggleBtn = [[NSButton alloc] initWithFrame:NSMakeRect(4, 1, 60, 20)];
  diToggleBtn.bordered = NO;
  diToggleBtn.bezelStyle = NSBezelStyleInline;
  diToggleBtn.target = self;
  diToggleBtn.action = @selector(toggleDIPlaybackAction:);
  [diPill addSubview:diToggleBtn];

  NSView* diDivider = [[NSView alloc] initWithFrame:NSMakeRect(66, 4, 1, 14)];
  diDivider.wantsLayer = YES;
  diDivider.layer.backgroundColor = [NSColor colorWithSRGBRed:0.18 green:0.21 blue:0.27 alpha:1.0].CGColor;
  [diPill addSubview:diDivider];

  NSButton* diLoadBtn = [[NSButton alloc] initWithFrame:NSMakeRect(68, 1, 26, 20)];
  diLoadBtn.bordered = NO;
  diLoadBtn.bezelStyle = NSBezelStyleInline;
  NSDictionary* diLoadAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.72 green:0.78 blue:0.88 alpha:1.0],
  };
  diLoadBtn.attributedTitle =
      [[NSAttributedString alloc] initWithString:@"…" attributes:diLoadAttrs];
  diLoadBtn.target = self;
  diLoadBtn.action = @selector(loadDIWavAction:);
  diLoadBtn.toolTip = @"Choose a Clean DI WAV file to loop through the live rig (⇧⌘L).";
  [diPill addSubview:diLoadBtn];

  recContainer.diPill = diPill;
  [recContainer addSubview:diPill];

  NSView* recPill = [[NSView alloc] initWithFrame:NSMakeRect(0, 3, recPillW, recPillH)];
  recPill.wantsLayer = YES;
  recPill.layer.backgroundColor = [NSColor colorWithSRGBRed:0.086 green:0.098 blue:0.129 alpha:1.0].CGColor;
  recPill.layer.cornerRadius = 7.0;
  recPill.layer.borderWidth = 1.0;
  recPill.layer.borderColor = [NSColor colorWithSRGBRed:0.145 green:0.165 blue:0.208 alpha:1.0].CGColor;
  recPill.toolTip = @"Record transformed stereo output + Clean DI WAV to ~/Music/Axe FX Recordings.";

  NSButton* recToggleBtn = [[NSButton alloc] initWithFrame:NSMakeRect(4, 1, 56, 20)];
  recToggleBtn.bordered = NO;
  recToggleBtn.bezelStyle = NSBezelStyleInline;
  recToggleBtn.target = self;
  recToggleBtn.action = @selector(toggleOutputRecordingAction:);
  [recPill addSubview:recToggleBtn];

  NSView* recDivider1 = [[NSView alloc] initWithFrame:NSMakeRect(61, 4, 1, 14)];
  recDivider1.wantsLayer = YES;
  recDivider1.layer.backgroundColor = [NSColor colorWithSRGBRed:0.18 green:0.21 blue:0.27 alpha:1.0].CGColor;
  [recPill addSubview:recDivider1];

  NSTextField* recTimeLabel = [NSTextField labelWithString:@"00:00"];
  recTimeLabel.font = [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightMedium];
  recTimeLabel.textColor = [NSColor colorWithSRGBRed:0.58 green:0.63 blue:0.72 alpha:1.0];
  recTimeLabel.alignment = NSTextAlignmentCenter;
  recTimeLabel.frame = NSMakeRect(63, 3, 46, 15);
  [recPill addSubview:recTimeLabel];

  NSView* recDivider2 = [[NSView alloc] initWithFrame:NSMakeRect(110, 4, 1, 14)];
  recDivider2.wantsLayer = YES;
  recDivider2.layer.backgroundColor = [NSColor colorWithSRGBRed:0.18 green:0.21 blue:0.27 alpha:1.0].CGColor;
  [recPill addSubview:recDivider2];

  NSButton* recRevealBtn = [[NSButton alloc] initWithFrame:NSMakeRect(112, 1, 22, 20)];
  recRevealBtn.bordered = NO;
  recRevealBtn.bezelStyle = NSBezelStyleInline;
  NSDictionary* revealAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.72 green:0.78 blue:0.88 alpha:1.0],
  };
  recRevealBtn.attributedTitle =
      [[NSAttributedString alloc] initWithString:@"↗" attributes:revealAttrs];
  recRevealBtn.target = self;
  recRevealBtn.action = @selector(revealOutputRecordingAction:);
  recRevealBtn.toolTip = @"Open ~/Music/Axe FX Recordings in Finder.";
  [recPill addSubview:recRevealBtn];

  recContainer.recPill = recPill;
  [recContainer addSubview:recPill];
  [recContainer.widthAnchor constraintEqualToConstant:diPillW + 8.0 + recPillW + 24.0].active = YES;

  NSTitlebarAccessoryViewController* titlebarRecAccessory =
      [[NSTitlebarAccessoryViewController alloc] init];
  titlebarRecAccessory.view = recContainer;
  titlebarRecAccessory.layoutAttribute = NSLayoutAttributeRight;
  [_window addTitlebarAccessoryViewController:titlebarRecAccessory];

  [_window center];

  NSUserDefaults* auditDefaults = [NSUserDefaults standardUserDefaults];
  if ([auditDefaults objectForKey:@"AxeFXAmpAuditFlags"] != nil) {
    NAMRig::AuditMode::setFlags(
        static_cast<uint32_t>([auditDefaults integerForKey:@"AxeFXAmpAuditFlags"]));
  } else {
    NAMRig::AuditMode::setProposed(true);
  }

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
  _host->setRecordingViews(recPill, recToggleBtn, recTimeLabel, recRevealBtn);
  _host->setDIPlaybackViews(diPill, diToggleBtn, diLoadBtn);
  _host->setAnimatedAmpViews(headerAmp, _dockAmpView);
  [self refreshAudioMenusAndTitle];
  [rootContent setNeedsLayout:YES];
  [_window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  // Developer Local API (for local CLI tool development / testing).
  // Disabled by default for distribution safety so no localhost ports are opened on end-user machines.
  BOOL enableDevAPI = [[NSProcessInfo processInfo].environment[@"AXE_FX_DEV_API"] boolValue] ||
                      [[NSUserDefaults standardUserDefaults] boolForKey:@"EnableLocalDevAPI"];
  if (enableDevAPI) {
    [[RigLocalServer sharedServer] startWithPort:48920];
  }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
  (void)sender;
  return YES;
}

- (void)windowDidResize:(NSNotification*)notification {
  (void)notification;
  [_window.contentView setNeedsLayout:YES];
  [_window.contentView layoutSubtreeIfNeeded];
  [_window.contentView setNeedsDisplay:YES];
}

- (void)windowDidEnterFullScreen:(NSNotification*)notification {
  (void)notification;
  [_window.contentView setNeedsLayout:YES];
  [_window.contentView layoutSubtreeIfNeeded];
  [_window.contentView setNeedsDisplay:YES];
}

- (void)windowDidExitFullScreen:(NSNotification*)notification {
  (void)notification;
  [_window.contentView setNeedsLayout:YES];
  [_window.contentView layoutSubtreeIfNeeded];
  [_window.contentView setNeedsDisplay:YES];
}

- (void)applicationWillTerminate:(NSNotification*)notification {
  (void)notification;
  if ([[RigLocalServer sharedServer] isRunning]) {
    [[RigLocalServer sharedServer] stop];
  }
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
