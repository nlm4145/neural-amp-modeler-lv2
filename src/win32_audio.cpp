#include "win32_audio.h"

#ifdef _WIN32
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <avrt.h>
#include <functiondiscoverykeys_devpkey.h>
#endif

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <exception>
#include <iostream>
#include <thread>
#include <vector>

namespace NAMRigWin32 {

namespace {

static WindowsAudioEngine* s_currentAsioEngine = nullptr;

#ifdef _WIN32
// KSDATAFORMAT_SUBTYPE_IEEE_FLOAT: {00000003-0000-0010-8000-00AA00389B71}
static const GUID kGuidSubtypeIeeeFloat = {
    0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}
};
#endif

std::string wideToUtf8(const wchar_t* wstr) {
  if (!wstr) return {};
  int len = WideCharToMultiByte(CP_UTF8, 0, wstr, -1, NULL, 0, NULL, NULL);
  if (len <= 0) return {};
  std::string out(len - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wstr, -1, &out[0], len, NULL, NULL);
  return out;
}

std::wstring utf8ToWide(const std::string& str) {
  if (str.empty()) return {};
  int len = MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, NULL, 0);
  if (len <= 0) return {};
  std::wstring out(len - 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, &out[0], len);
  return out;
}

} // namespace

std::vector<AsioDriverDesc> enumerateAsioDrivers() {
  std::vector<AsioDriverDesc> list;
#ifdef _WIN32
  HKEY hKey = NULL;
  if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\ASIO", 0, KEY_READ, &hKey) == ERROR_SUCCESS) {
    DWORD index = 0;
    wchar_t subkeyName[256];
    DWORD nameLen = sizeof(subkeyName) / sizeof(wchar_t);

    while (RegEnumKeyExW(hKey, index++, subkeyName, &nameLen, NULL, NULL, NULL, NULL) == ERROR_SUCCESS) {
      nameLen = sizeof(subkeyName) / sizeof(wchar_t);
      HKEY hDriverKey = NULL;
      if (RegOpenKeyExW(hKey, subkeyName, 0, KEY_READ, &hDriverKey) == ERROR_SUCCESS) {
        wchar_t clsidStr[128];
        DWORD clsidLen = sizeof(clsidStr);
        if (RegQueryValueExW(hDriverKey, L"CLSID", NULL, NULL, (LPBYTE)clsidStr, &clsidLen) == ERROR_SUCCESS) {
          CLSID clsid;
          if (SUCCEEDED(CLSIDFromString(clsidStr, &clsid))) {
            AsioDriverDesc desc;
            desc.name = wideToUtf8(subkeyName);
            desc.clsidString = wideToUtf8(clsidStr);
            desc.clsid = clsid;
            list.push_back(desc);
          }
        }
        RegCloseKey(hDriverKey);
      }
    }
    RegCloseKey(hKey);
  }
#endif
  return list;
}

std::vector<AudioDevice> WindowsAudioEngine::enumerateWasapiDevices(bool isInput) {
  std::vector<AudioDevice> list;
#ifdef _WIN32
  CoInitialize(NULL);
  IMMDeviceEnumerator* enumerator = nullptr;
  if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), NULL, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator), (void**)&enumerator)) && enumerator) {
    IMMDeviceCollection* collection = nullptr;
    EDataFlow flow = isInput ? eCapture : eRender;
    if (SUCCEEDED(enumerator->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE, &collection)) && collection) {
      UINT count = 0;
      collection->GetCount(&count);
      for (UINT i = 0; i < count; ++i) {
        IMMDevice* device = nullptr;
        if (SUCCEEDED(collection->Item(i, &device)) && device) {
          LPWSTR strId = nullptr;
          device->GetId(&strId);

          std::string devName = "Audio Device";
          IPropertyStore* props = nullptr;
          if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &props)) && props) {
            PROPVARIANT var;
            PropVariantInit(&var);
            if (SUCCEEDED(props->GetValue(PKEY_Device_FriendlyName, &var)) && var.pwszVal) {
              devName = wideToUtf8(var.pwszVal);
            }
            PropVariantClear(&var);
            props->Release();
          }

          AudioDevice ad;
          ad.id = wideToUtf8(strId);
          ad.name = devName;
          ad.isInput = isInput;
          list.push_back(ad);

          if (strId) CoTaskMemFree(strId);
          device->Release();
        }
      }
      collection->Release();
    }
    enumerator->Release();
  }
#endif
  return list;
}

std::vector<AsioDriverDesc> WindowsAudioEngine::enumerateAsioDrivers() {
  return NAMRigWin32::enumerateAsioDrivers();
}

WindowsAudioEngine::WindowsAudioEngine() {
#ifdef _WIN32
  CoInitialize(NULL);
#endif
}

WindowsAudioEngine::~WindowsAudioEngine() {
  stop();
#ifdef _WIN32
  CoUninitialize();
#endif
}

bool WindowsAudioEngine::start(const AudioEngineConfig& config, AudioProcessCallback cb) {
  stop();
  config_ = config;
  processCallback_ = cb;
  sampleRate_ = config.sampleRate;
  bufferSize_ = config.bufferSize;

  if (config.driverType == AudioDriverType::ASIO) {
    return startAsio(config);
  } else {
    return startWasapi(config);
  }
}

void WindowsAudioEngine::stop() {
  if (!isRunning_) return;
  if (config_.driverType == AudioDriverType::ASIO) {
    stopAsio();
  } else {
    stopWasapi();
  }
  isRunning_ = false;
}

bool WindowsAudioEngine::startWasapi(const AudioEngineConfig& config) {
#ifdef _WIN32
  IMMDeviceEnumerator* enumerator = nullptr;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), NULL, CLSCTX_ALL,
                              __uuidof(IMMDeviceEnumerator), (void**)&enumerator)) || !enumerator) {
    return false;
  }

  IMMDevice* inDevice = nullptr;
  IMMDevice* outDevice = nullptr;

  if (!config.inputDeviceId.empty()) {
    std::wstring wid = utf8ToWide(config.inputDeviceId);
    enumerator->GetDevice(wid.c_str(), &inDevice);
  }
  if (!inDevice) {
    enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &inDevice);
  }

  if (!config.outputDeviceId.empty()) {
    std::wstring wid = utf8ToWide(config.outputDeviceId);
    enumerator->GetDevice(wid.c_str(), &outDevice);
  }
  if (!outDevice) {
    enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &outDevice);
  }

  enumerator->Release();
  if (!outDevice) {
    if (inDevice) inDevice->Release();
    return false;
  }

  IAudioClient* outClient = nullptr;
  outDevice->Activate(__uuidof(IAudioClient), CLSCTX_ALL, NULL, (void**)&outClient);
  outDevice->Release();
  if (!outClient) {
    if (inDevice) inDevice->Release();
    return false;
  }

  IAudioClient* inClient = nullptr;
  if (inDevice) {
    inDevice->Activate(__uuidof(IAudioClient), CLSCTX_ALL, NULL, (void**)&inClient);
    inDevice->Release();
  }

  // Format: IEEE float 32-bit, 2 channels, requested sample rate
  WAVEFORMATEXTENSIBLE wfe{};
  wfe.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
  wfe.Format.nChannels = 2;
  wfe.Format.nSamplesPerSec = static_cast<DWORD>(config.sampleRate);
  wfe.Format.wBitsPerSample = 32;
  wfe.Format.nBlockAlign = (wfe.Format.nChannels * wfe.Format.wBitsPerSample) / 8;
  wfe.Format.nAvgBytesPerSec = wfe.Format.nSamplesPerSec * wfe.Format.nBlockAlign;
  wfe.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
  wfe.Samples.wValidBitsPerSample = 32;
  wfe.dwChannelMask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
  wfe.SubFormat = kGuidSubtypeIeeeFloat;

  REFERENCE_TIME bufferDuration = static_cast<REFERENCE_TIME>(
      (10000000.0 * config.bufferSize) / config.sampleRate);

  DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
  AUDCLNT_SHAREMODE shareMode = (config.driverType == AudioDriverType::WASAPI_Exclusive)
                                    ? AUDCLNT_SHAREMODE_EXCLUSIVE
                                    : AUDCLNT_SHAREMODE_SHARED;

  if (shareMode == AUDCLNT_SHAREMODE_SHARED) {
    // In shared mode, query mix format to honor engine rate
    WAVEFORMATEX* mixFormat = nullptr;
    if (SUCCEEDED(outClient->GetMixFormat(&mixFormat)) && mixFormat) {
      sampleRate_ = mixFormat->nSamplesPerSec;
      CoTaskMemFree(mixFormat);
    }
  }

  HRESULT hr = outClient->Initialize(shareMode, flags, bufferDuration,
                                     (shareMode == AUDCLNT_SHAREMODE_EXCLUSIVE) ? bufferDuration : 0,
                                     (WAVEFORMATEX*)&wfe, NULL);
  if (FAILED(hr)) {
    outClient->Release();
    if (inClient) inClient->Release();
    return false;
  }

  wasapiOutEvent_ = CreateEvent(NULL, FALSE, FALSE, NULL);
  outClient->SetEventHandle(wasapiOutEvent_);

  IAudioRenderClient* renderClient = nullptr;
  outClient->GetService(__uuidof(IAudioRenderClient), (void**)&renderClient);

  IAudioCaptureClient* captureClient = nullptr;
  if (inClient) {
    inClient->Initialize(shareMode, flags, bufferDuration,
                         (shareMode == AUDCLNT_SHAREMODE_EXCLUSIVE) ? bufferDuration : 0,
                         (WAVEFORMATEX*)&wfe, NULL);
    wasapiInEvent_ = CreateEvent(NULL, FALSE, FALSE, NULL);
    inClient->SetEventHandle(wasapiInEvent_);
    inClient->GetService(__uuidof(IAudioCaptureClient), (void**)&captureClient);
  }

  wasapiInClient_ = inClient;
  wasapiOutClient_ = outClient;
  wasapiInCapture_ = captureClient;
  wasapiOutRender_ = renderClient;
  wasapiStopEvent_ = CreateEvent(NULL, TRUE, FALSE, NULL);

  isRunning_ = true;
  wasapiThread_ = CreateThread(NULL, 0, [](LPVOID param) -> DWORD {
    auto* self = static_cast<WindowsAudioEngine*>(param);
    self->wasapiThreadFunc();
    return 0;
  }, this, 0, NULL);

  return true;
#else
  (void)config;
  return false;
#endif
}

void WindowsAudioEngine::stopWasapi() {
#ifdef _WIN32
  if (wasapiStopEvent_) {
    SetEvent(wasapiStopEvent_);
  }
  if (wasapiThread_) {
    // Management-thread join: callbacks must finish before cleanup or worker drain.
    const DWORD waitResult = WaitForSingleObject(wasapiThread_, INFINITE);
    if (waitResult != WAIT_OBJECT_0) {
      const DWORD error = waitResult == WAIT_FAILED ? GetLastError() : 0;
      std::cerr << "WASAPI thread join failed: wait=" << waitResult
                << ", error=" << error << std::endl;
      // stop() is also called by destructors; returning or unwinding is unsafe.
      std::terminate();
    }
    CloseHandle(wasapiThread_);
    wasapiThread_ = NULL;
  }

  if (wasapiOutClient_) {
    auto* oc = static_cast<IAudioClient*>(wasapiOutClient_);
    oc->Stop();
    oc->Release();
    wasapiOutClient_ = nullptr;
  }
  if (wasapiInClient_) {
    auto* ic = static_cast<IAudioClient*>(wasapiInClient_);
    ic->Stop();
    ic->Release();
    wasapiInClient_ = nullptr;
  }
  if (wasapiOutRender_) {
    static_cast<IAudioRenderClient*>(wasapiOutRender_)->Release();
    wasapiOutRender_ = nullptr;
  }
  if (wasapiInCapture_) {
    static_cast<IAudioCaptureClient*>(wasapiInCapture_)->Release();
    wasapiInCapture_ = nullptr;
  }

  if (wasapiOutEvent_) { CloseHandle(wasapiOutEvent_); wasapiOutEvent_ = NULL; }
  if (wasapiInEvent_) { CloseHandle(wasapiInEvent_); wasapiInEvent_ = NULL; }
  if (wasapiStopEvent_) { CloseHandle(wasapiStopEvent_); wasapiStopEvent_ = NULL; }
#endif
}

void WindowsAudioEngine::wasapiThreadFunc() {
#ifdef _WIN32
  DWORD taskIndex = 0;
  HANDLE hTask = AvSetMmThreadCharacteristicsW(L"Pro Audio", &taskIndex);
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);

  auto* outClient = static_cast<IAudioClient*>(wasapiOutClient_);
  auto* inClient = static_cast<IAudioClient*>(wasapiInClient_);
  auto* renderClient = static_cast<IAudioRenderClient*>(wasapiOutRender_);
  auto* captureClient = static_cast<IAudioCaptureClient*>(wasapiInCapture_);

  if (outClient) outClient->Start();
  if (inClient) inClient->Start();

  UINT32 bufferFrameCount = 0;
  if (outClient) outClient->GetBufferSize(&bufferFrameCount);
  if (bufferFrameCount == 0) bufferFrameCount = bufferSize_;

  std::vector<float> inL(bufferFrameCount, 0.0f);
  std::vector<float> inR(bufferFrameCount, 0.0f);
  std::vector<float> outL(bufferFrameCount, 0.0f);
  std::vector<float> outR(bufferFrameCount, 0.0f);

  HANDLE waitHandles[2] = {wasapiStopEvent_, wasapiOutEvent_};

  while (isRunning_) {
    DWORD waitResult = WaitForMultipleObjects(2, waitHandles, FALSE, 2000);
    if (waitResult == WAIT_OBJECT_0) {
      break; // stop event signaled
    }
    if (waitResult != WAIT_OBJECT_0 + 1) {
      continue;
    }

    // Read available input frames
    UINT32 inFramesRead = 0;
    if (captureClient) {
      BYTE* pData = nullptr;
      UINT32 numFramesAvailable = 0;
      DWORD flags = 0;
      while (SUCCEEDED(captureClient->GetBuffer(&pData, &numFramesAvailable, &flags, NULL, NULL)) && numFramesAvailable > 0) {
        float* fData = reinterpret_cast<float*>(pData);
        for (UINT32 i = 0; i < numFramesAvailable && inFramesRead < bufferFrameCount; ++i) {
          if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
            inL[inFramesRead] = 0.0f;
            inR[inFramesRead] = 0.0f;
          } else {
            inL[inFramesRead] = fData[i * 2 + 0];
            inR[inFramesRead] = fData[i * 2 + 1];
          }
          inFramesRead++;
        }
        captureClient->ReleaseBuffer(numFramesAvailable);
      }
    }
    for (UINT32 i = inFramesRead; i < bufferFrameCount; ++i) {
      inL[i] = 0.0f;
      inR[i] = 0.0f;
    }

    // Process block through audio callback
    if (processCallback_) {
      processCallback_(inL.data(), inR.data(), outL.data(), outR.data(), bufferFrameCount);
    } else {
      std::fill(outL.begin(), outL.end(), 0.0f);
      std::fill(outR.begin(), outR.end(), 0.0f);
    }

    // Write rendered output frames
    if (renderClient) {
      BYTE* pOutData = nullptr;
      if (SUCCEEDED(renderClient->GetBuffer(bufferFrameCount, &pOutData)) && pOutData) {
        float* fOut = reinterpret_cast<float*>(pOutData);
        for (UINT32 i = 0; i < bufferFrameCount; ++i) {
          fOut[i * 2 + 0] = outL[i];
          fOut[i * 2 + 1] = outR[i];
        }
        renderClient->ReleaseBuffer(bufferFrameCount, 0);
      }
    }
  }

  if (hTask) {
    AvRevertMmThreadCharacteristics(hTask);
  }
#endif
}

bool WindowsAudioEngine::startAsio(const AudioEngineConfig& config) {
#ifdef _WIN32
  auto drivers = enumerateAsioDrivers();
  AsioDriverDesc targetDriver;
  bool found = false;

  for (const auto& d : drivers) {
    if (d.name == config.asioDriverName || config.asioDriverName.empty()) {
      targetDriver = d;
      found = true;
      break;
    }
  }
  if (!found) return false;

  s_currentAsioEngine = this;
  if (FAILED(CoCreateInstance(targetDriver.clsid, NULL, CLSCTX_INPROC_SERVER,
                              IID_IASIO, (void**)&asioDriver_)) || !asioDriver_) {
    return false;
  }

  if (!asioDriver_->init(GetDesktopWindow())) {
    asioDriver_->Release();
    asioDriver_ = nullptr;
    return false;
  }

  asioDriver_->setSampleRate(config.sampleRate);
  long numIn = 0, numOut = 0;
  asioDriver_->getChannels(&numIn, &numOut);
  asioInputChannels_ = std::min(numIn, 2L);
  asioOutputChannels_ = std::min(numOut, 2L);

  asioBufferInfos_.clear();
  for (long i = 0; i < asioInputChannels_; ++i) {
    ASIOBufferInfo info{};
    info.isInput = 1;
    info.channelNum = i;
    asioBufferInfos_.push_back(info);
  }
  for (long i = 0; i < asioOutputChannels_; ++i) {
    ASIOBufferInfo info{};
    info.isInput = 0;
    info.channelNum = i;
    asioBufferInfos_.push_back(info);
  }

  asioCallbacks_.bufferSwitch = asioBufferSwitch;
  asioCallbacks_.sampleRateDidChange = asioSampleRateDidChange;
  asioCallbacks_.asioMessage = asioMessageCallback;
  asioCallbacks_.bufferSwitchTimeInfo = asioBufferSwitchTimeInfo;

  long minSize = 0, maxSize = 0, prefSize = 0, gran = 0;
  asioDriver_->getBufferSize(&minSize, &maxSize, &prefSize, &gran);
  long bufferSize = (config.bufferSize > 0) ? config.bufferSize : prefSize;
  bufferSize_ = bufferSize;

  if (asioDriver_->createBuffers(asioBufferInfos_.data(),
                                static_cast<long>(asioBufferInfos_.size()),
                                bufferSize, &asioCallbacks_) != ASE_OK) {
    asioDriver_->Release();
    asioDriver_ = nullptr;
    return false;
  }

  if (asioDriver_->start() != ASE_OK) {
    asioDriver_->disposeBuffers();
    asioDriver_->Release();
    asioDriver_ = nullptr;
    return false;
  }

  isRunning_ = true;
  return true;
#else
  (void)config;
  return false;
#endif
}

void WindowsAudioEngine::stopAsio() {
#ifdef _WIN32
  if (asioDriver_) {
    asioDriver_->stop();
    asioDriver_->disposeBuffers();
    asioDriver_->Release();
    asioDriver_ = nullptr;
  }
  s_currentAsioEngine = nullptr;
#endif
}

void WindowsAudioEngine::asioBufferSwitch(long doubleBufferIndex, ASIOBool directProcess) {
  (void)directProcess;
  if (!s_currentAsioEngine) return;

  uint32_t frames = s_currentAsioEngine->bufferSize_;
  std::vector<float> inL(frames, 0.0f);
  std::vector<float> inR(frames, 0.0f);
  std::vector<float> outL(frames, 0.0f);
  std::vector<float> outR(frames, 0.0f);

  // Convert inputs to float
  if (s_currentAsioEngine->asioInputChannels_ > 0) {
    float* srcL = static_cast<float*>(s_currentAsioEngine->asioBufferInfos_[0].buffers[doubleBufferIndex]);
    if (srcL) std::copy(srcL, srcL + frames, inL.begin());
  }
  if (s_currentAsioEngine->asioInputChannels_ > 1) {
    float* srcR = static_cast<float*>(s_currentAsioEngine->asioBufferInfos_[1].buffers[doubleBufferIndex]);
    if (srcR) std::copy(srcR, srcR + frames, inR.begin());
  }

  // Audio callback
  if (s_currentAsioEngine->processCallback_) {
    s_currentAsioEngine->processCallback_(inL.data(), inR.data(), outL.data(), outR.data(), frames);
  }

  // Write outputs
  size_t outOffset = s_currentAsioEngine->asioInputChannels_;
  if (s_currentAsioEngine->asioOutputChannels_ > 0) {
    float* dstL = static_cast<float*>(s_currentAsioEngine->asioBufferInfos_[outOffset + 0].buffers[doubleBufferIndex]);
    if (dstL) std::copy(outL.begin(), outL.end(), dstL);
  }
  if (s_currentAsioEngine->asioOutputChannels_ > 1) {
    float* dstR = static_cast<float*>(s_currentAsioEngine->asioBufferInfos_[outOffset + 1].buffers[doubleBufferIndex]);
    if (dstR) std::copy(outR.begin(), outR.end(), dstR);
  }

  s_currentAsioEngine->asioDriver_->outputReady();
}

void WindowsAudioEngine::asioSampleRateDidChange(ASIOSampleRate sRate) {
  if (s_currentAsioEngine) {
    s_currentAsioEngine->sampleRate_ = sRate;
  }
}

long WindowsAudioEngine::asioMessageCallback(long selector, long value, void* message, double* opt) {
  (void)selector; (void)value; (void)message; (void)opt;
  return 0;
}

ASIOTime* WindowsAudioEngine::asioBufferSwitchTimeInfo(ASIOTime* params, long doubleBufferIndex, ASIOBool directProcess) {
  asioBufferSwitch(doubleBufferIndex, directProcess);
  return params;
}

} // namespace NAMRigWin32
