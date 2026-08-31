#import <Cocoa/Cocoa.h>
#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/CoreAudio.h>

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
#include <condition_variable>
#include <cstdarg>
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

extern "C" const LV2UI_Descriptor* lv2ui_descriptor(uint32_t index);

namespace {

constexpr uint32_t kMaxFrames = 4096;
constexpr size_t kAtomBufferSize = 16384;
constexpr size_t kMessageSize = 2048;
constexpr size_t kMessageCount = 64;

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

    // LV2 control defaults, in port order (ports 4..29).
    controls_ = {0.0f, 0.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 0.0f,
                 0.0f, 0.0f, 0.0f, -80.0f, 0.0f, -1.0f, 0.0f, 1.0f,
                 1.0f, 1.0f, 0.0f, 150.0f, 2.0f, 0.0f, 0.0f,
                 20000.0f, 0.0f, 0.0f};
  }

  ~StandaloneHost() { stop(); }

  bool start(NSWindow* window, NSView* parent, NSString** error) {
    window_ = window;
    sampleRate_ = defaultOutputSampleRate();
    if (sampleRate_ <= 0.0) sampleRate_ = 48000.0;

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

    resetSequence(controlBuffer_, sizeof(LV2_Atom_Sequence_Body));
    resetSequence(notifyBuffer_, kAtomBufferSize - sizeof(LV2_Atom));
    plugin_->ports.control = reinterpret_cast<LV2_Atom_Sequence*>(controlBuffer_.data());
    plugin_->ports.notify = reinterpret_cast<LV2_Atom_Sequence*>(notifyBuffer_.data());
    plugin_->ports.audio_in = input_.data();
    plugin_->ports.audio_out = output_.data();
    for (uint32_t port = 4; port < 30; ++port) {
      *reinterpret_cast<float**>(reinterpret_cast<uint8_t*>(&plugin_->ports) +
                                 port * sizeof(void*)) = &controls_[port - 4];
    }

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
    uiTimer_ = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
                                                target:[NSBlockOperation blockOperationWithBlock:^{
                                                  this->drainUIEvents();
                                                }]
                                              selector:@selector(main)
                                              userInfo:nil
                                               repeats:YES];
    return true;
  }

  void stop() {
    [uiTimer_ invalidate];
    uiTimer_ = nil;
    if (audioUnit_) {
      AudioOutputUnitStop(audioUnit_);
      AudioUnitUninitialize(audioUnit_);
      AudioComponentInstanceDispose(audioUnit_);
      audioUnit_ = nullptr;
    }
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

 private:
  struct WorkItem { std::vector<uint8_t> data; };
  struct WorkResponse { std::vector<uint8_t> data; };

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
    if (format == 0 && port >= 4 && port < 30 && size == sizeof(float)) {
      host->controls_[port - 4] = *static_cast<const float*>(buffer);
      return;
    }
    if (port == 0 && format == host->eventTransfer_)
      host->uiToAudio_.push(size, format, buffer);
  }

  static int resizeUI(LV2UI_Feature_Handle handle, int width, int height) {
    auto* host = static_cast<StandaloneHost*>(handle);
    if (!host->window_) return 1;
    NSRect content = NSMakeRect(0, 0, width, height);
    NSRect frame = [host->window_ frameRectForContentRect:content];
    NSRect old = host->window_.frame;
    frame.origin.x = old.origin.x;
    frame.origin.y = NSMaxY(old) - frame.size.height;
    [host->window_ setFrame:frame display:YES animate:NO];
    return 0;
  }

  void resetSequence(std::array<uint8_t, kAtomBufferSize>& buffer, uint32_t size) {
    std::memset(buffer.data(), 0, buffer.size());
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
  }

  static OSStatus render(void* context, AudioUnitRenderActionFlags* flags,
                         const AudioTimeStamp* timestamp, UInt32, UInt32 frames,
                         AudioBufferList* ioData) {
    return static_cast<StandaloneHost*>(context)->renderAudio(flags, timestamp, frames, ioData);
  }

  OSStatus renderAudio(AudioUnitRenderActionFlags* flags, const AudioTimeStamp* timestamp,
                       UInt32 frames, AudioBufferList* ioData) noexcept {
    if (frames > kMaxFrames || !ioData || ioData->mNumberBuffers == 0) {
      if (ioData)
        for (UInt32 i = 0; i < ioData->mNumberBuffers; ++i)
          if (ioData->mBuffers[i].mData)
            std::memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
      return noErr;
    }

    AudioBufferList inputList{};
    inputList.mNumberBuffers = 1;
    inputList.mBuffers[0].mNumberChannels = 1;
    inputList.mBuffers[0].mDataByteSize = frames * sizeof(float);
    inputList.mBuffers[0].mData = input_.data();
    const OSStatus status = AudioUnitRender(audioUnit_, flags, timestamp, 1, frames, &inputList);
    if (status != noErr) {
      std::fill_n(output_.data(), frames, 0.0f);
    } else {
      applyWorkerResponses();
      buildControlSequence();
      resetSequence(notifyBuffer_, kAtomBufferSize - sizeof(LV2_Atom));
      plugin_->process(frames);
      collectNotifications();
    }

    for (UInt32 buffer = 0; buffer < ioData->mNumberBuffers; ++buffer) {
      float* destination = static_cast<float*>(ioData->mBuffers[buffer].mData);
      if (destination) std::copy_n(output_.data(), frames, destination);
    }
    return noErr;
  }

  static double defaultOutputSampleRate() {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address{kAudioHardwarePropertyDefaultOutputDevice,
                                       kAudioObjectPropertyScopeGlobal,
                                       kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr,
                                   &size, &device) != noErr)
      return 0.0;
    Float64 rate = 0.0;
    size = sizeof(rate);
    address = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
               kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &rate) == noErr
               ? rate : 0.0;
  }

  bool startAudio(NSString** error) {
    AudioComponentDescription description{};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_VoiceProcessingIO;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent component = AudioComponentFindNext(nullptr, &description);
    if (!component || AudioComponentInstanceNew(component, &audioUnit_) != noErr)
      return fail(error, @"Core Audio could not create an input/output device.");

    UInt32 enabled = 1;
    if (AudioUnitSetProperty(audioUnit_, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, &enabled, sizeof(enabled)) != noErr)
      return fail(error, @"Core Audio could not enable microphone input.");
    // Keep VoiceProcessingIO solely as a convenient full-duplex default-device
    // bridge; guitar processing must not receive echo cancellation or AGC.
    UInt32 bypass = 1;
    AudioUnitSetProperty(audioUnit_, kAUVoiceIOProperty_BypassVoiceProcessing,
                         kAudioUnitScope_Global, 0, &bypass, sizeof(bypass));
    UInt32 agc = 0;
    AudioUnitSetProperty(audioUnit_, kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                         kAudioUnitScope_Global, 0, &agc, sizeof(agc));

    AudioStreamBasicDescription format{};
    format.mSampleRate = sampleRate_;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    format.mFramesPerPacket = 1;
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 32;
    format.mBytesPerFrame = sizeof(float);
    format.mBytesPerPacket = sizeof(float);
    if (AudioUnitSetProperty(audioUnit_, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, 1, &format, sizeof(format)) != noErr ||
        AudioUnitSetProperty(audioUnit_, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0, &format, sizeof(format)) != noErr)
      return fail(error, @"Core Audio could not configure a mono floating-point stream.");

    UInt32 maxFrames = kMaxFrames;
    AudioUnitSetProperty(audioUnit_, kAudioUnitProperty_MaximumFramesPerSlice,
                         kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames));
    AURenderCallbackStruct callback{render, this};
    if (AudioUnitSetProperty(audioUnit_, kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input, 0, &callback, sizeof(callback)) != noErr ||
        AudioUnitInitialize(audioUnit_) != noErr || AudioOutputUnitStart(audioUnit_) != noErr)
      return fail(error, @"Core Audio could not start. Check microphone permission and the selected system input/output devices.");
    return true;
  }

  NSWindow* __weak window_ = nil;
  NSTimer* __strong uiTimer_ = nil;
  AudioUnit audioUnit_ = nullptr;
  double sampleRate_ = 48000.0;
  std::unique_ptr<NAMRig::Plugin> plugin_;
  const LV2UI_Descriptor* uiDescriptor_ = nullptr;
  LV2UI_Handle uiHandle_ = nullptr;

  std::array<float, kMaxFrames> input_{};
  std::array<float, kMaxFrames> output_{};
  std::array<float, 26> controls_{};
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

}  // namespace

@interface StandaloneAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@implementation StandaloneAppDelegate {
  NSWindow* _window;
  std::unique_ptr<StandaloneHost> _host;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
  (void)notification;
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  NSMenu* menu = [[NSMenu alloc] init];
  NSMenuItem* appItem = [[NSMenuItem alloc] init];
  [menu addItem:appItem];
  NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"NAM Oversampled Rig"];
  [appMenu addItemWithTitle:@"Quit NAM Oversampled Rig"
                     action:@selector(terminate:)
              keyEquivalent:@"q"];
  appItem.submenu = appMenu;
  NSApp.mainMenu = menu;

  _window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 1280, 830)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskMiniaturizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  _window.title = @"NAM Oversampled Rig";
  _window.delegate = self;
  _window.releasedWhenClosed = NO;
  [_window center];

  _host = std::make_unique<StandaloneHost>();
  NSString* error = nil;
  if (!_host->start(_window, _window.contentView, &error)) {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"NAM Oversampled Rig could not start";
    alert.informativeText = error ?: @"Unknown error";
    [alert runModal];
    [NSApp terminate:nil];
    return;
  }
  _window.subtitle = [NSString stringWithFormat:@"Live input · %.0f Hz", _host->sampleRate()];
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
