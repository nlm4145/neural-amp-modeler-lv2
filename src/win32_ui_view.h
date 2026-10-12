#pragma once

#ifdef _WIN32
#include <windows.h>
#include <wtypes.h>
#include <shellapi.h>
#include <gdiplus.h>
#endif

#include <cstdint>
#include <functional>
#include <string>
#include <unordered_map>
#include <vector>

#include "win32_presets.h"

namespace NAMRigWin32 {

enum class ControlType {
  Knob,
  Toggle,
  Button,
  Dropdown,
  Meter,
  Tuner
};

struct UIControl {
  uint32_t port = 0;
  ControlType type = ControlType::Knob;
  RECT rect = {0, 0, 0, 0};
  std::string label;
  float minValue = 0.0f;
  float maxValue = 1.0f;
  float defaultValue = 0.0f;
  float currentValue = 0.0f;
  std::string unit;
  std::function<std::string(float)> formatValue;
  bool isDragging = false;
  int dragStartY = 0;
  float dragStartValue = 0.0f;
};

class Win32UIView {
 public:
  Win32UIView();
  ~Win32UIView();

  HWND create(HWND parent, int x = 0, int y = 0, int width = 1180, int height = 780);
  void destroy();

  HWND hwnd() const { return hwnd_; }

  void setControlValue(uint32_t port, float value, bool notify = false);
  float getControlValue(uint32_t port) const;

  void setTuner(float note, float cents);
  void setAudioLevels(float inPeak, float outPeak);
  void setStagePath(uint32_t stage, const std::string& path);

  void setOnControlChanged(std::function<void(uint32_t port, float value)> cb) {
    onControlChanged_ = std::move(cb);
  }

  void setOnStageFileChanged(std::function<void(uint32_t stage, const std::string& path)> cb) {
    onStageFileChanged_ = std::move(cb);
  }

  void applyPreset(const RigPreset& preset);
  RigPreset capturePreset(const std::string& name = "") const;

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
  LRESULT handleMessage(UINT msg, WPARAM wParam, LPARAM lParam);

  void initLayout();
  void paint(HDC hdc);
  void onMouseDown(int x, int y, bool isRight);
  void onMouseMove(int x, int y, WPARAM flags);
  void onMouseUp(int x, int y);
  void onMouseWheel(short delta);
  void onDoubleClick(int x, int y);

  void showPresetMenu(int screenX, int screenY);
  void showSlotPresetMenu(const std::string& slotKey, int screenX, int screenY);
  void browseForFile(uint32_t stage, bool isWav);

  HWND hwnd_ = NULL;
  ULONG_PTR gdiplusToken_ = 0;
  std::unordered_map<uint32_t, UIControl> controls_;
  std::vector<uint32_t> controlOrder_;

  // File paths for stages: 0=Pedal, 1=Amp, 2=Cab A, 3=Cab B
  std::array<std::string, 4> stagePaths_;

  // Tuner & meter state
  float tunerNote_ = -1.0f;
  float tunerCents_ = 0.0f;
  float inPeak_ = 0.0f;
  float outPeak_ = 0.0f;

  // Active dragging control
  UIControl* activeDragControl_ = nullptr;

  // Callbacks
  std::function<void(uint32_t port, float value)> onControlChanged_;
  std::function<void(uint32_t stage, const std::string& path)> onStageFileChanged_;
};

} // namespace NAMRigWin32
