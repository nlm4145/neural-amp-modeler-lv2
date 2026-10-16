#include <windows.h>
#include <commctrl.h>
#include <commdlg.h>
#include <shellapi.h>
#include <shlobj.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include <lv2/atom/atom.h>
#include <lv2/atom/forge.h>
#include <lv2/atom/util.h>
#include <lv2/buf-size/buf-size.h>
#include <lv2/core/lv2.h>
#include <lv2/log/log.h>
#include <lv2/options/options.h>
#include <lv2/patch/patch.h>
#include <lv2/urid/urid.h>
#include <lv2/worker/worker.h>

#include "cabinet_worker.h"
#include "nam_rig_plugin.h"
#include "rack_controls.h"
#include "standalone_controls.h"
#include "standalone_worker.h"
#include "win32_audio.h"
#include "win32_presets.h"
#include "win32_ui_view.h"

using json = nlohmann::json;

namespace {

constexpr uint32_t kMaxFrames = 4096;
constexpr size_t kAtomBufferSize = 16384;
constexpr size_t kMessageSize = 2048;
constexpr size_t kMessageCount = 64;
constexpr UINT_PTR kTimerId = 1;

static const wchar_t* kMainWindowClass = L"AxeFXMainWindowClass";

struct URIDEntry {
  std::string uri;
  LV2_URID urid;
};

class StandaloneURIDMap {
 public:
  LV2_URID map(const char* uri) {
    if (!uri) return 0;
    for (size_t i = 0; i < entries_.size(); ++i) {
      if (entries_[i].uri == uri) return entries_[i].urid;
    }
    LV2_URID id = static_cast<LV2_URID>(entries_.size() + 1);
    entries_.push_back({uri, id});
    return id;
  }

  static LV2_URID mapCallback(LV2_URID_Map_Handle handle, const char* uri) {
    return static_cast<StandaloneURIDMap*>(handle)->map(uri);
  }

 private:
  std::vector<URIDEntry> entries_;
};

struct FixedMessage {
  uint32_t size = 0;
  uint32_t format = 0;
  std::array<uint8_t, kMessageSize> bytes{};
};

class MessageQueue {
 public:
  bool push(uint32_t size, uint32_t format, const void* data) noexcept {
    if (size > kMessageSize || !data) return false;
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

struct StandaloneMeter {
  explicit StandaloneMeter(float initialDb) : latestDb(initialDb) {}

  std::atomic<float> latestDb;
  std::atomic<float> pendingPeakDb{-120.0f};

  void store(float db) noexcept {
    latestDb.store(db);
    float peak = pendingPeakDb.load();
    while (db > peak && !pendingPeakDb.compare_exchange_weak(peak, db)) {}
  }

  void applyTo(NAMRigWin32::Win32UIView& view, NAMRigWin32::MeterStage stage) {
    // Preserve transients between UI polls without replacing the current reading.
    const float peak = pendingPeakDb.exchange(-120.0f);
    if (peak > -120.0f) view.setMeterLevel(stage, peak);
    view.setMeterLevel(stage, latestDb.load());
  }
};

class StandaloneApp {
 public:
  StandaloneApp() {
    mapFeature_.handle = &uridMap_;
    mapFeature_.map = StandaloneURIDMap::mapCallback;

    logFeature_.handle = this;
    logFeature_.printf = logPrintf;
    logFeature_.vprintf = logVPrintf;

    // Default control values
    controls_.fill(0.0f);
    NAMRigWin32::forEachWin32ControlDefault(
        [&](uint32_t port, float value) { controls_[port] = value; });
    controls_[6] = 1.0f;        // quality_scale
    controls_[10] = 1.0f;       // auto_cab
    controls_[17] = -1.0f;      // tuner_note
    controls_[19] = 1.0f;       // legacy
  }

  ~StandaloneApp() {
    stop();
  }

  bool initialize(HINSTANCE hInstance) {
    loadSettings();

    atomSequence_ = uridMap_.map(LV2_ATOM__Sequence);
    eventTransfer_ = uridMap_.map(LV2_ATOM__eventTransfer);
    atomInt_ = uridMap_.map(LV2_ATOM__Int);
    atomFloat_ = uridMap_.map(LV2_ATOM__Float);
    atomObject_ = uridMap_.map(LV2_ATOM__Object);
    atomPath_ = uridMap_.map(LV2_ATOM__Path);
    atomURID_ = uridMap_.map(LV2_ATOM__URID);
    patchSet_ = uridMap_.map(LV2_PATCH__Set);
    patchProperty_ = uridMap_.map(LV2_PATCH__property);
    patchValue_ = uridMap_.map(LV2_PATCH__value);
    maxBlockLength_ = uridMap_.map(LV2_BUF_SIZE__maxBlockLength);
    preAmpDbURID_ = uridMap_.map(NAM_RIG_PRE_AMP_DB_URI);
    postAmpDbURID_ = uridMap_.map(NAM_RIG_POST_AMP_DB_URI);

    pathURIDs_[0] = uridMap_.map(NAM_RIG_PEDAL_URI);
    pathURIDs_[1] = uridMap_.map(NAM_RIG_AMP_URI);
    pathURIDs_[2] = uridMap_.map(NAM_RIG_CAB_URI);
    pathURIDs_[3] = uridMap_.map(NAM_RIG_CAB2_URI);

    maxFramesOption_ = static_cast<int32_t>(kMaxFrames);
    options_[0] = {LV2_OPTIONS_INSTANCE, 0, maxBlockLength_, sizeof(maxFramesOption_),
                   atomInt_, &maxFramesOption_};
    options_[1] = {};

    mapFeatureStruct_ = {LV2_URID__map, &mapFeature_};
    scheduleFeatureStruct_ = {LV2_WORKER__schedule, worker_.scheduleFeature()};
    logFeatureStruct_ = {LV2_LOG__log, &logFeature_};
    optionsFeatureStruct_ = {LV2_OPTIONS__options, options_.data()};

    const LV2_Feature* dspFeatures[] = {
        &mapFeatureStruct_, &scheduleFeatureStruct_,
        &logFeatureStruct_, &optionsFeatureStruct_, nullptr};

    plugin_ = std::make_unique<NAMRig::Plugin>();
    if (!plugin_->initialize(audioConfig_.sampleRate, dspFeatures)) {
      MessageBoxW(NULL, L"Failed to initialize NAM Rig DSP core.", L"Error", MB_ICONERROR);
      return false;
    }

    inputAudio_.assign(kMaxFrames, 0.0f);
    outputAudioL_.assign(kMaxFrames, 0.0f);
    outputAudioR_.assign(kMaxFrames, 0.0f);

    controlBuffer_.assign(kAtomBufferSize, 0);
    notifyBuffer_.assign(kAtomBufferSize, 0);

    resetSequence(controlBuffer_, sizeof(LV2_Atom_Sequence_Body), true);
    resetSequence(notifyBuffer_, kAtomBufferSize - sizeof(LV2_Atom), true);

    plugin_->ports.control = reinterpret_cast<LV2_Atom_Sequence*>(controlBuffer_.data());
    plugin_->ports.notify = reinterpret_cast<LV2_Atom_Sequence*>(notifyBuffer_.data());
    plugin_->ports.audio_in = inputAudio_.data();
    plugin_->ports.audio_out = outputAudioL_.data();
    plugin_->ports.audio_out_r = outputAudioR_.data();

    pinEqControls_.fill(0.0f);
    const std::span<float> controls(controls_);
    NAMRig::bindStandaloneControls(plugin_->ports, {
        {4, controls.subspan(4, 27)}, {32, controls.subspan(32, 51)},
        {NAMRig::kPinEqFirstPort, pinEqControls_},
        {NAMRig::kOverdriveDrivePort, controls.subspan(NAMRig::kOverdriveDrivePort, 3)},
        {NAMRig::kCompressorAttackPort, controls.subspan(NAMRig::kCompressorAttackPort, 3)},
        {NAMRig::kOverdriveEnabledPort, controls.subspan(NAMRig::kOverdriveEnabledPort, 1)}});

    if (!worker_.start(plugin_.get(),
                       {NAMRig::Plugin::work, NAMRig::Plugin::workResponse, nullptr}))
      return false;

    // Create Main Window
    WNDCLASSEXW wc = {sizeof(WNDCLASSEXW)};
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = MainWndProc;
    wc.hInstance = hInstance;
    wc.hIcon = LoadIcon(NULL, IDI_APPLICATION);
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    wc.lpszClassName = kMainWindowClass;
    RegisterClassExW(&wc);

    HMENU hMenuBar = CreateMenu();
    HMENU hFileMenu = CreatePopupMenu();
    AppendMenuW(hFileMenu, MF_STRING, 101, L"Load Amp Model (*.nam)...");
    AppendMenuW(hFileMenu, MF_STRING, 102, L"Load Pedal Model (*.nam)...");
    AppendMenuW(hFileMenu, MF_STRING, 103, L"Load Cab A IR (*.wav)...");
    AppendMenuW(hFileMenu, MF_STRING, 104, L"Load Cab B IR (*.wav)...");
    AppendMenuW(hFileMenu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(hFileMenu, MF_STRING, 105, L"Exit");
    AppendMenuW(hMenuBar, MF_POPUP, (UINT_PTR)hFileMenu, L"File");

    HMENU hAudioMenu = CreatePopupMenu();
    AppendMenuW(hAudioMenu, MF_STRING, 201, L"Audio Device Settings...");
    AppendMenuW(hMenuBar, MF_POPUP, (UINT_PTR)hAudioMenu, L"Audio");

    HMENU hPresetMenu = CreatePopupMenu();
    AppendMenuW(hPresetMenu, MF_STRING, 301, L"Open Presets Folder...");
    AppendMenuW(hMenuBar, MF_POPUP, (UINT_PTR)hPresetMenu, L"Presets");

    RECT wr = {0, 0, 1180, 780};
    AdjustWindowRect(&wr, WS_OVERLAPPEDWINDOW, TRUE);

    mainWindow_ = CreateWindowExW(
        WS_EX_ACCEPTFILES, kMainWindowClass, L"Axe FX — Studio Pro Standalone",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_VISIBLE,
        CW_USEDEFAULT, CW_USEDEFAULT, wr.right - wr.left, wr.bottom - wr.top,
        NULL, hMenuBar, hInstance, this);

    if (!mainWindow_) return false;

    uiView_ = std::make_unique<NAMRigWin32::Win32UIView>();
    uiView_->create(mainWindow_, 0, 0, 1180, 780);

    uiView_->setOnControlChanged([this](uint32_t port, float value) {
      if (port < controls_.size()) {
        controls_[port] = value;
      }
    });

    uiView_->setOnStageFileChanged([this](uint32_t stage, const std::string& path) {
      sendPath(stage, path);
    });

    startAudio();
    SetTimer(mainWindow_, kTimerId, 33, NULL);
    return true;
  }

  void run() {
    MSG msg;
    while (GetMessage(&msg, NULL, 0, 0)) {
      TranslateMessage(&msg);
      DispatchMessage(&msg);
    }
  }

  void stop() {
    audioEngine_.stop();
    worker_.stop();
    saveSettings();
  }

  void sendPath(size_t stage, const std::string& path) {
    if (stage >= pathURIDs_.size()) return;
    const size_t length = path.length() + 1;
    std::vector<uint8_t> buffer(length + 256);
    LV2_Atom_Forge forge;
    LV2_URID_Map forgeMap{};
    forgeMap.handle = &uridMap_;
    forgeMap.map = StandaloneURIDMap::mapCallback;
    lv2_atom_forge_init(&forge, &forgeMap);
    lv2_atom_forge_set_buffer(&forge, buffer.data(), buffer.size());
    LV2_Atom_Forge_Frame frame{};
    auto* message = reinterpret_cast<LV2_Atom*>(lv2_atom_forge_object(&forge, &frame, 0, patchSet_));
    if (!message) return;
    lv2_atom_forge_key(&forge, patchProperty_);
    lv2_atom_forge_urid(&forge, pathURIDs_[stage]);
    lv2_atom_forge_key(&forge, patchValue_);
    lv2_atom_forge_path(&forge, path.c_str(), static_cast<uint32_t>(length));
    lv2_atom_forge_pop(&forge, &frame);

    uiToAudio_.push(lv2_atom_total_size(message), eventTransfer_, message);
  }

 private:
  static LRESULT CALLBACK MainWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    StandaloneApp* self = nullptr;
    if (msg == WM_NCCREATE) {
      CREATESTRUCT* cs = reinterpret_cast<CREATESTRUCT*>(lParam);
      self = reinterpret_cast<StandaloneApp*>(cs->lpCreateParams);
      SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    } else {
      self = reinterpret_cast<StandaloneApp*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
    }

    if (self) {
      return self->handleWindowMessage(hwnd, msg, wParam, lParam);
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
  }

  LRESULT handleWindowMessage(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
      case WM_COMMAND: {
        int id = LOWORD(wParam);
        if (id == 101) browseAndLoad(1, false);
        else if (id == 102) browseAndLoad(0, false);
        else if (id == 103) browseAndLoad(2, true);
        else if (id == 104) browseAndLoad(3, true);
        else if (id == 105) PostQuitMessage(0);
        else if (id == 201) showAudioSettingsDialog();
        else if (id == 301) {
          std::string pdir = NAMRigWin32::PresetManager::instance().presetsDirectory();
          ShellExecuteA(NULL, "open", pdir.c_str(), NULL, NULL, SW_SHOW);
        }
        return 0;
      }
      case WM_TIMER: {
        if (wParam == kTimerId) {
          updateTimerTick();
        }
        return 0;
      }
      case WM_DESTROY: {
        KillTimer(hwnd, kTimerId);
        PostQuitMessage(0);
        return 0;
      }
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
  }

  void updateTimerTick() {
    if (!uiView_) return;
    float note = controls_[17];
    float cents = controls_[18];
    uiView_->setTuner(note, cents);
    inPeakMeter_.applyTo(*uiView_, NAMRigWin32::MeterStage::Input);
    preAmpDbMeter_.applyTo(*uiView_, NAMRigWin32::MeterStage::PreAmp);
    postAmpDbMeter_.applyTo(*uiView_, NAMRigWin32::MeterStage::PostAmp);
    outPeakMeter_.applyTo(*uiView_, NAMRigWin32::MeterStage::Output);
  }

  void startAudio() {
    audioEngine_.start(audioConfig_, [this](const float* inL, const float* inR,
                                            float* outL, float* outR, uint32_t frames) {
      processAudioBlock(inL, inR, outL, outR, frames);
    });
  }

  void processAudioBlock(const float* inL, const float* inR, float* outL, float* outR, uint32_t frames) {
    (void)inR;
    uint32_t count = std::min(frames, kMaxFrames);

    worker_.applyResponses();

    // Prepare control sequence from UI messages
    auto* sequence = reinterpret_cast<LV2_Atom_Sequence*>(controlBuffer_.data());
    resetSequence(controlBuffer_, sizeof(LV2_Atom_Sequence_Body), true);
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

    // Measure peak in
    float maxIn = 0.0f;
    for (uint32_t i = 0; i < count; ++i) {
      inputAudio_[i] = inL[i];
      float absV = std::abs(inL[i]);
      if (absV > maxIn) maxIn = absV;
    }
    inPeakMeter_.store(maxIn > 1e-4f ? 20.0f * std::log10(maxIn) : -80.0f);

    // The DSP replaces atom.size with the used size, so restore capacity each block.
    resetSequence(notifyBuffer_, kAtomBufferSize - sizeof(LV2_Atom), true);
    plugin_->process(count);

    const auto* notify = reinterpret_cast<const LV2_Atom_Sequence*>(notifyBuffer_.data());
    LV2_ATOM_SEQUENCE_FOREACH(notify, event) {
      if (event->body.type != atomObject_ || event->body.size < sizeof(LV2_Atom_Object_Body))
        continue;
      const auto* object = reinterpret_cast<const LV2_Atom_Object*>(&event->body);
      if (object->body.otype != patchSet_) continue;
      const LV2_Atom* property = nullptr;
      const LV2_Atom* value = nullptr;
      lv2_atom_object_get(object, patchProperty_, &property, patchValue_, &value, 0);
      if (!property || property->type != atomURID_ || property->size != sizeof(LV2_URID) ||
          !value || value->type != atomFloat_ || value->size != sizeof(float))
        continue;
      const auto propID = reinterpret_cast<const LV2_Atom_URID*>(property)->body;
      const float db = reinterpret_cast<const LV2_Atom_Float*>(value)->body;
      if (propID == preAmpDbURID_) preAmpDbMeter_.store(db);
      else if (propID == postAmpDbURID_) postAmpDbMeter_.store(db);
    }

    // Measure peak out & write outputs
    float maxOut = 0.0f;
    for (uint32_t i = 0; i < count; ++i) {
      outL[i] = outputAudioL_[i];
      outR[i] = outputAudioR_[i];
      float absV = std::max(std::abs(outL[i]), std::abs(outR[i]));
      if (absV > maxOut) maxOut = absV;
    }
    outPeakMeter_.store(maxOut > 1e-4f ? 20.0f * std::log10(maxOut) : -80.0f);
  }

  void browseAndLoad(size_t stage, bool isWav) {
    wchar_t fileName[MAX_PATH] = L"";
    OPENFILENAMEW ofn = {sizeof(OPENFILENAMEW)};
    ofn.hwndOwner = mainWindow_;
    ofn.lpstrFilter = isWav ? L"WAV IR Files (*.wav)\0*.wav\0All Files (*.*)\0*.*\0"
                            : L"NAM Models (*.nam)\0*.nam\0All Files (*.*)\0*.*\0";
    ofn.lpstrFile = fileName;
    ofn.nMaxFile = MAX_PATH;
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST;

    if (GetOpenFileNameW(&ofn)) {
      int len = WideCharToMultiByte(CP_UTF8, 0, fileName, -1, NULL, 0, NULL, NULL);
      if (len > 0) {
        std::string path(len - 1, '\0');
        WideCharToMultiByte(CP_UTF8, 0, fileName, -1, &path[0], len, NULL, NULL);
        sendPath(stage, path);
        if (uiView_) {
          uiView_->setStagePath(static_cast<uint32_t>(stage), path);
        }
      }
    }
  }

  static int logPrintf(LV2_Log_Handle, LV2_URID, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int ret = vprintf(fmt, ap);
    va_end(ap);
    return ret;
  }

  static int logVPrintf(LV2_Log_Handle, LV2_URID, const char* fmt, va_list ap) {
    return vprintf(fmt, ap);
  }

  static void resetSequence(std::vector<uint8_t>& buf, size_t cap, bool reset) {
    auto* seq = reinterpret_cast<LV2_Atom_Sequence*>(buf.data());
    seq->atom.type = 1; // Sequence
    seq->atom.size = static_cast<uint32_t>(cap);
    if (reset) seq->body.unit = 0;
  }

  void showAudioSettingsDialog() {
    auto asioDrivers = NAMRigWin32::WindowsAudioEngine::enumerateAsioDrivers();

    std::wstring info = L"Current Audio Configuration:\n\n";
    info += L"Backend: " + std::wstring(audioConfig_.driverType == NAMRigWin32::AudioDriverType::ASIO ? L"ASIO" : L"WASAPI") + L"\n";
    info += L"Sample Rate: " + std::to_wstring(static_cast<int>(audioConfig_.sampleRate)) + L" Hz\n";
    info += L"Buffer Size: " + std::to_wstring(audioConfig_.bufferSize) + L" frames\n\n";

    if (!asioDrivers.empty()) {
      info += L"Installed ASIO Drivers:\n";
      for (const auto& d : asioDrivers) {
        int wlen = MultiByteToWideChar(CP_UTF8, 0, d.name.c_str(), -1, NULL, 0);
        if (wlen > 0) {
          std::wstring wd(wlen, L'\0');
          MultiByteToWideChar(CP_UTF8, 0, d.name.c_str(), -1, &wd[0], wlen);
          info += L" \x2022 " + wd + L"\n";
        }
      }
    } else {
      info += L"No external ASIO drivers detected (WASAPI engine active).\n";
    }

    MessageBoxW(mainWindow_, info.c_str(), L"Audio Settings", MB_OK | MB_ICONINFORMATION);
  }

  void loadSettings() {
    std::string appDir = NAMRigWin32::PresetManager::instance().presetsDirectory();
    size_t lastSlash = appDir.find_last_of("\\/");
    if (lastSlash != std::string::npos) appDir = appDir.substr(0, lastSlash);
    std::string setPath = appDir + "\\audio_settings.json";

    std::ifstream f(setPath);
    if (f.is_open()) {
      try {
        json j;
        f >> j;
        if (j.contains("sample_rate")) audioConfig_.sampleRate = j["sample_rate"].get<double>();
        if (j.contains("buffer_size")) audioConfig_.bufferSize = j["buffer_size"].get<uint32_t>();
        if (j.contains("driver_type")) {
          std::string dt = j["driver_type"].get<std::string>();
          if (dt == "ASIO") audioConfig_.driverType = NAMRigWin32::AudioDriverType::ASIO;
          else if (dt == "WASAPI_Exclusive") audioConfig_.driverType = NAMRigWin32::AudioDriverType::WASAPI_Exclusive;
          else audioConfig_.driverType = NAMRigWin32::AudioDriverType::WASAPI_Shared;
        }
        if (j.contains("asio_driver")) audioConfig_.asioDriverName = j["asio_driver"].get<std::string>();
      } catch (...) {}
    }
  }

  void saveSettings() {
    std::string appDir = NAMRigWin32::PresetManager::instance().presetsDirectory();
    size_t lastSlash = appDir.find_last_of("\\/");
    if (lastSlash != std::string::npos) appDir = appDir.substr(0, lastSlash);
    std::string setPath = appDir + "\\audio_settings.json";

    json j;
    j["sample_rate"] = audioConfig_.sampleRate;
    j["buffer_size"] = audioConfig_.bufferSize;
    j["driver_type"] = (audioConfig_.driverType == NAMRigWin32::AudioDriverType::ASIO) ? "ASIO" : "WASAPI_Shared";
    j["asio_driver"] = audioConfig_.asioDriverName;

    std::ofstream f(setPath);
    if (f.is_open()) {
      f << std::setw(2) << j << std::endl;
    }
  }

  HWND mainWindow_ = NULL;
  std::unique_ptr<NAMRigWin32::Win32UIView> uiView_;
  std::unique_ptr<NAMRig::Plugin> plugin_;
  NAMRigWin32::WindowsAudioEngine audioEngine_;
  NAMRigWin32::AudioEngineConfig audioConfig_;

  StandaloneURIDMap uridMap_;
  LV2_URID_Map mapFeature_{};
  LV2_Log_Log logFeature_{};
  LV2_Feature mapFeatureStruct_{};
  LV2_Feature scheduleFeatureStruct_{};
  LV2_Feature logFeatureStruct_{};
  LV2_Feature optionsFeatureStruct_{};
  std::array<LV2_Options_Option, 2> options_{};

  LV2_URID atomSequence_ = 0;
  LV2_URID eventTransfer_ = 0;
  LV2_URID atomInt_ = 0;
  LV2_URID atomFloat_ = 0;
  LV2_URID atomObject_ = 0;
  LV2_URID atomPath_ = 0;
  LV2_URID atomURID_ = 0;
  LV2_URID patchSet_ = 0;
  LV2_URID patchProperty_ = 0;
  LV2_URID patchValue_ = 0;
  LV2_URID maxBlockLength_ = 0;
  LV2_URID preAmpDbURID_ = 0;
  LV2_URID postAmpDbURID_ = 0;
  std::array<LV2_URID, 4> pathURIDs_{};
  int32_t maxFramesOption_ = kMaxFrames;

  std::array<float, 186> controls_{};
  std::array<float, NAMRig::kPinEqPortCount> pinEqControls_{};

  std::vector<float> inputAudio_;
  std::vector<float> outputAudioL_;
  std::vector<float> outputAudioR_;
  std::vector<uint8_t> controlBuffer_;
  std::vector<uint8_t> notifyBuffer_;

  MessageQueue uiToAudio_;
  StandaloneMeter inPeakMeter_{-80.0f};
  StandaloneMeter outPeakMeter_{-80.0f};
  StandaloneMeter preAmpDbMeter_{-120.0f};
  StandaloneMeter postAmpDbMeter_{-120.0f};

  NAMRig::StandaloneWorker worker_;
};

} // namespace

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE, LPSTR, int nCmdShow) {
  (void)nCmdShow;
  CoInitialize(NULL);
  InitCommonControls();

  StandaloneApp app;
  if (app.initialize(hInstance)) {
    app.run();
  }

  CoUninitialize();
  return 0;
}

int main(int argc, char** argv) {
  (void)argc; (void)argv;
  return WinMain(GetModuleHandle(NULL), NULL, NULL, SW_SHOW);
}
