#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "win32_asio.h"

namespace NAMRigWin32 {

enum class AudioDriverType {
  WASAPI_Shared,
  WASAPI_Exclusive,
  ASIO
};

struct AudioDevice {
  std::string id;
  std::string name;
  bool isInput = false;
};

struct AudioEngineConfig {
  AudioDriverType driverType = AudioDriverType::WASAPI_Shared;
  std::string inputDeviceId;
  std::string outputDeviceId;
  std::string asioDriverName;
  double sampleRate = 48000.0;
  uint32_t bufferSize = 256;
};

using AudioProcessCallback = std::function<void(const float* inL, const float* inR,
                                                float* outL, float* outR,
                                                uint32_t numFrames)>;

class WindowsAudioEngine {
 public:
  WindowsAudioEngine();
  ~WindowsAudioEngine();

  static std::vector<AudioDevice> enumerateWasapiDevices(bool isInput);
  static std::vector<AsioDriverDesc> enumerateAsioDrivers();

  bool start(const AudioEngineConfig& config, AudioProcessCallback cb);
  void stop();

  bool isRunning() const { return isRunning_; }
  double sampleRate() const { return sampleRate_; }
  uint32_t bufferSize() const { return bufferSize_; }
  AudioDriverType driverType() const { return config_.driverType; }

 private:
  bool startWasapi(const AudioEngineConfig& config);
  void stopWasapi();
  void wasapiThreadFunc();

  bool startAsio(const AudioEngineConfig& config);
  void stopAsio();

  static void asioBufferSwitch(long doubleBufferIndex, ASIOBool directProcess);
  static void asioSampleRateDidChange(ASIOSampleRate sRate);
  static long asioMessageCallback(long selector, long value, void* message, double* opt);
  static ASIOTime* asioBufferSwitchTimeInfo(ASIOTime* params, long doubleBufferIndex, ASIOBool directProcess);

  AudioEngineConfig config_;
  AudioProcessCallback processCallback_;
  bool isRunning_ = false;
  double sampleRate_ = 48000.0;
  uint32_t bufferSize_ = 256;

  // WASAPI internals
  void* wasapiInClient_ = nullptr;
  void* wasapiOutClient_ = nullptr;
  void* wasapiInCapture_ = nullptr;
  void* wasapiOutRender_ = nullptr;
  HANDLE wasapiInEvent_ = NULL;
  HANDLE wasapiOutEvent_ = NULL;
  HANDLE wasapiStopEvent_ = NULL;
  HANDLE wasapiThread_ = NULL;

  // ASIO internals
  IASIO* asioDriver_ = nullptr;
  std::vector<ASIOBufferInfo> asioBufferInfos_;
  ASIOCallbacks asioCallbacks_{};
  long asioInputChannels_ = 0;
  long asioOutputChannels_ = 0;
};

} // namespace NAMRigWin32
