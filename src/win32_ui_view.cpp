#include "win32_ui_view.h"

#ifdef _WIN32
#include <windows.h>
#include <wtypes.h>
#include <commctrl.h>
#include <commdlg.h>
#include <shellapi.h>
#include <gdiplus.h>
#endif

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <sstream>
#include <iomanip>

#include "oversample_modes.h"
#include "output_transformer.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace NAMRigWin32 {

namespace {

const wchar_t* kWin32ViewClassName = L"NAMRigWin32ViewClass";
constexpr UINT_PTR kMeterTimerId = 1;
const RECT kMetersRect = {774, 8, 1160, 60};

// Axe FX dark theme colors
const Gdiplus::Color kBgColor(255, 17, 18, 21);            // #111215
const Gdiplus::Color kCardBgColor(255, 24, 27, 32);        // #181b20
const Gdiplus::Color kCardBorderColor(255, 42, 47, 56);    // #2a2f38
const Gdiplus::Color kHeaderBgColor(255, 14, 15, 18);      // #0e0f12
const Gdiplus::Color kAccentOrange(255, 255, 119, 0);      // #ff7700
const Gdiplus::Color kAccentCyan(255, 79, 163, 227);       // #4fa3e3
const Gdiplus::Color kActiveLed(255, 40, 200, 64);         // #28c840
const Gdiplus::Color kInactiveLed(255, 60, 64, 75);        // #3c404b
const Gdiplus::Color kTextBright(255, 226, 229, 235);      // #e2e5eb
const Gdiplus::Color kTextMuted(255, 140, 146, 160);       // #8c92a0
const Gdiplus::Color kKnobBody(255, 31, 35, 43);           // #1f232b
const Gdiplus::Color kKnobRim(255, 56, 62, 74);            // #383e4a
const Gdiplus::Color kTrackBg(255, 42, 46, 56);            // #2a2e38
const Gdiplus::Color kClipColor(255, 242, 51, 46);

std::string formatDb(float v) {
  char buf[32];
  if (v <= -80.0f) return "-inf dB";
  std::snprintf(buf, sizeof(buf), "%+.1f dB", v);
  return buf;
}

std::string formatPercent(float v) {
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%.0f %%", v);
  return buf;
}

std::string formatMs(float v) {
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%.1f ms", v);
  return buf;
}

std::string formatHz(float v) {
  char buf[32];
  if (v <= 0.0f || v >= 20000.0f) return "Off";
  if (v >= 1000.0f) {
    std::snprintf(buf, sizeof(buf), "%.1f kHz", v / 1000.0f);
  } else {
    std::snprintf(buf, sizeof(buf), "%.0f Hz", v);
  }
  return buf;
}

std::string formatOversample(float v) {
  int mode = static_cast<int>(v);
  switch (mode) {
    case 0: return "1x (Off)";
    case 1: return "Eco 2x";
    case 2: return "Eco 4x";
    case 3: return "Eco 8x";
    case 4: return "True 2x";
    case 5: return "True 4x";
    case 6: return "True 8x";
    default: return "True 8x";
  }
}

std::string formatTransformer(float v) {
  int t = static_cast<int>(v);
  switch (t) {
    case 0: return "Captured/Off";
    case 1: return "Modern";
    case 2: return "US Vintage";
    case 3: return "UK Vintage";
    case 4: return "Small Iron";
    case 5: return "Tight Metal";
    case 6: return "Extended";
    case 7: return "Thrash Bite";
    case 8: return "Doom Iron";
    case 9: return "Studio Linear";
    case 10: return "Tweed Bloom";
    case 11: return "Class-A";
    case 12: return "Bass Iron";
    default: return "Modern";
  }
}

std::string formatTubeType(float v) {
  int t = static_cast<int>(v);
  switch (t) {
    case 0: return "Captured";
    case 1: return "6L6-Style";
    case 2: return "EL34-Style";
    default: return "Captured";
  }
}

std::string formatNormalization(float v) {
  int n = static_cast<int>(v);
  switch (n) {
    case 0: return "Preserve";
    case 1: return "Peak";
    case 2: return "Loudness";
    default: return "Loudness";
  }
}

std::string getFileNameOnly(const std::string& path) {
  if (path.empty()) return "None (Empty)";
  size_t lastSlash = path.find_last_of("\\/");
  if (lastSlash != std::string::npos) {
    return path.substr(lastSlash + 1);
  }
  return path;
}

} // namespace

Win32UIView::Win32UIView() {
#ifdef _WIN32
  Gdiplus::GdiplusStartupInput input;
  Gdiplus::GdiplusStartup(&gdiplusToken_, &input, NULL);
#endif
  PresetManager::instance().initialize();
  initLayout();
}

Win32UIView::~Win32UIView() {
  destroy();
#ifdef _WIN32
  if (gdiplusToken_) {
    Gdiplus::GdiplusShutdown(gdiplusToken_);
    gdiplusToken_ = 0;
  }
#endif
}

void Win32UIView::initLayout() {
  controls_.clear();
  controlOrder_.clear();

  auto addControl = [this](uint32_t port, ControlType type, int x, int y, int w, int h,
                           const std::string& label, float minV, float maxV, float defV,
                           const std::string& unit, std::function<std::string(float)> fmt) {
    UIControl c;
    c.port = port;
    c.type = type;
    c.rect = {x, y, x + w, y + h};
    c.label = label;
    c.minValue = minV;
    c.maxValue = maxV;
    c.defaultValue = defV;
    c.currentValue = defV;
    c.unit = unit;
    c.formatValue = fmt;
    controls_[port] = c;
    controlOrder_.push_back(port);
  };

  // Header Bar controls (y = 15..55)
  addControl(16, ControlType::Toggle, 20, 18, 90, 32, "TUNER", 0.0f, 1.0f, 0.0f, "", nullptr);
  addControl(4, ControlType::Knob, 470, 12, 60, 52, "INPUT", -20.0f, 20.0f, 0.0f, "dB", formatDb);
  addControl(15, ControlType::Knob, 545, 12, 60, 52, "GATE", -80.0f, 0.0f, -80.0f, "dB", formatDb);
  addControl(5, ControlType::Knob, 620, 12, 60, 52, "OUTPUT", -20.0f, 20.0f, 0.0f, "dB", formatDb);
  addControl(32, ControlType::Knob, 695, 12, 60, 52, "WIDTH", 0.0f, 100.0f, 0.0f, "%", formatPercent);

  // Stage 1: PEDAL (x = 20, y = 80, w = 265, h = 320)
  addControl(7, ControlType::Toggle, 220, 92, 50, 24, "ON", 0.0f, 1.0f, 1.0f, "", nullptr);
  addControl(179, ControlType::Knob, 40, 175, 65, 60, "DRIVE", 0.0f, 100.0f, 0.0f, "%", formatPercent);
  addControl(180, ControlType::Knob, 120, 175, 65, 60, "TONE", 0.0f, 100.0f, 50.0f, "%", formatPercent);
  addControl(181, ControlType::Knob, 200, 175, 65, 60, "LEVEL", -12.0f, 12.0f, 0.0f, "dB", formatDb);
  addControl(20, ControlType::Dropdown, 140, 275, 120, 26, "OVERSAMPLE", 0.0f, 6.0f, 6.0f, "", formatOversample);

  // Stage 2: AMP (x = 300, y = 80, w = 575, h = 320)
  addControl(8, ControlType::Toggle, 810, 92, 50, 24, "ON", 0.0f, 1.0f, 1.0f, "", nullptr);
  addControl(22, ControlType::Knob, 320, 175, 65, 60, "DRIVE", -20.0f, 20.0f, 0.0f, "dB", formatDb);
  addControl(12, ControlType::Knob, 390, 175, 65, 60, "BASS", -12.0f, 12.0f, 0.0f, "dB", formatDb);
  addControl(13, ControlType::Knob, 460, 175, 65, 60, "MID", -12.0f, 12.0f, 0.0f, "dB", formatDb);
  addControl(14, ControlType::Knob, 530, 175, 65, 60, "TREBLE", -12.0f, 12.0f, 0.0f, "dB", formatDb);
  addControl(34, ControlType::Knob, 600, 175, 65, 60, "PRESENCE", -12.0f, 12.0f, 0.0f, "dB", formatDb);
  addControl(35, ControlType::Knob, 670, 175, 65, 60, "DEPTH", -12.0f, 12.0f, 0.0f, "dB", formatDb);
  addControl(41, ControlType::Knob, 740, 175, 65, 60, "MASTER", 0.0f, 100.0f, 0.0f, "%", formatPercent);
  addControl(36, ControlType::Knob, 810, 175, 65, 60, "SAG", 0.0f, 100.0f, 0.0f, "%", formatPercent);

  addControl(37, ControlType::Knob, 350, 255, 60, 55, "BIAS", -100.0f, 100.0f, 0.0f, "%", formatPercent);
  addControl(38, ControlType::Knob, 430, 255, 60, 55, "NFB", 0.0f, 100.0f, 0.0f, "%", formatPercent);
  addControl(39, ControlType::Knob, 510, 255, 60, 55, "BRIGHT", 0.0f, 100.0f, 0.0f, "%", formatPercent);
  addControl(40, ControlType::Knob, 590, 255, 60, 55, "IN CUT", 0.0f, 100.0f, 0.0f, "%", formatPercent);
  addControl(21, ControlType::Dropdown, 720, 265, 120, 26, "OVERSAMPLE", 0.0f, 6.0f, 6.0f, "", formatOversample);

  // Stage 3: TRANSFORMER & TUBE (x = 890, y = 80, w = 270, h = 320)
  addControl(30, ControlType::Dropdown, 990, 135, 150, 26, "PROFILE", 0.0f, 12.0f, 0.0f, "", formatTransformer);
  addControl(80, ControlType::Dropdown, 990, 185, 150, 26, "TUBE", 0.0f, 2.0f, 0.0f, "", formatTubeType);
  addControl(81, ControlType::Knob, 920, 245, 65, 60, "TUBE CHAR", 0.0f, 100.0f, 0.0f, "%", formatPercent);
  addControl(82, ControlType::Knob, 995, 245, 65, 60, "MID PUSH", 0.0f, 100.0f, 0.0f, "%", formatPercent);
  addControl(60, ControlType::Knob, 1070, 245, 65, 60, "DRIVE TRIM", -12.0f, 12.0f, 0.0f, "dB", formatDb);

  // Stage 4: DUAL CABINET (x = 20, y = 415, w = 550, h = 345)
  // Cab A
  addControl(9, ControlType::Toggle, 220, 427, 45, 22, "A ON", 0.0f, 1.0f, 1.0f, "", nullptr);
  addControl(25, ControlType::Knob, 40, 495, 60, 55, "A LEVEL", -20.0f, 20.0f, 0.0f, "dB", formatDb);
  addControl(26, ControlType::Knob, 110, 495, 60, 55, "LOW CUT", 0.0f, 500.0f, 0.0f, "Hz", formatHz);
  addControl(27, ControlType::Knob, 180, 495, 60, 55, "HIGH CUT", 2000.0f, 20000.0f, 20000.0f, "Hz", formatHz);
  addControl(24, ControlType::Dropdown, 140, 565, 110, 24, "NORM", 0.0f, 2.0f, 2.0f, "", formatNormalization);

  // Cab B
  addControl(47, ControlType::Toggle, 500, 427, 45, 22, "B ON", 0.0f, 1.0f, 0.0f, "", nullptr);
  addControl(48, ControlType::Knob, 310, 495, 60, 55, "B LEVEL", -20.0f, 20.0f, 0.0f, "dB", formatDb);
  addControl(49, ControlType::Knob, 385, 495, 60, 55, "DELAY", -10.0f, 10.0f, 0.0f, "ms", formatMs);
  addControl(59, ControlType::Toggle, 465, 510, 75, 24, "INVERT", 0.0f, 1.0f, 0.0f, "", nullptr);

  // Stage 5: SPACE & FX (x = 585, y = 415, w = 575, h = 345)
  addControl(28, ControlType::Knob, 610, 445, 60, 55, "COMP", 0.0f, 100.0f, 0.0f, "%", formatPercent);
  addControl(33, ControlType::Knob, 680, 445, 60, 55, "ROOM", 0.0f, 100.0f, 0.0f, "%", formatPercent);

  // Delay
  addControl(71, ControlType::Toggle, 810, 432, 45, 20, "DLY", 0.0f, 1.0f, 1.0f, "", nullptr);
  addControl(50, ControlType::Knob, 755, 475, 55, 52, "TIME", 10.0f, 2000.0f, 400.0f, "ms", formatMs);
  addControl(51, ControlType::Knob, 815, 475, 55, 52, "FDBK", 0.0f, 100.0f, 35.0f, "%", formatPercent);
  addControl(52, ControlType::Knob, 875, 475, 55, 52, "DAMP", 0.0f, 100.0f, 40.0f, "%", formatPercent);
  addControl(53, ControlType::Knob, 935, 475, 55, 52, "MIX", 0.0f, 100.0f, 0.0f, "%", formatPercent);

  // Reverb
  addControl(72, ControlType::Toggle, 1100, 432, 45, 20, "REV", 0.0f, 1.0f, 1.0f, "", nullptr);
  addControl(55, ControlType::Knob, 620, 565, 55, 52, "DECAY", 0.0f, 100.0f, 50.0f, "%", formatPercent);
  addControl(56, ControlType::Knob, 685, 565, 55, 52, "SIZE", 0.0f, 100.0f, 50.0f, "%", formatPercent);
  addControl(57, ControlType::Knob, 750, 565, 55, 52, "DAMP", 0.0f, 100.0f, 50.0f, "%", formatPercent);
  addControl(58, ControlType::Knob, 815, 565, 55, 52, "PREDLY", 0.0f, 100.0f, 10.0f, "ms", formatMs);
  addControl(54, ControlType::Knob, 880, 565, 55, 52, "REV MIX", 0.0f, 100.0f, 0.0f, "%", formatPercent);
}

HWND Win32UIView::create(HWND parent, int x, int y, int width, int height) {
#ifdef _WIN32
  HINSTANCE hInstance = GetModuleHandle(NULL);

  WNDCLASSEXW wc = {sizeof(WNDCLASSEXW)};
  wc.style = CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS;
  wc.lpfnWndProc = WndProc;
  wc.hInstance = hInstance;
  wc.hCursor = LoadCursor(NULL, IDC_ARROW);
  wc.hbrBackground = NULL; // double-buffered painting
  wc.lpszClassName = kWin32ViewClassName;
  RegisterClassExW(&wc);

  DWORD style = parent ? (WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN)
                       : (WS_OVERLAPPEDWINDOW | WS_VISIBLE | WS_CLIPCHILDREN);

  hwnd_ = CreateWindowExW(0, kWin32ViewClassName, L"Axe FX",
                          style, x, y, width, height, parent, NULL, hInstance, this);
  if (hwnd_) SetTimer(hwnd_, kMeterTimerId, 33, NULL);
  return hwnd_;
#else
  (void)parent; (void)x; (void)y; (void)width; (void)height;
  return NULL;
#endif
}

void Win32UIView::destroy() {
#ifdef _WIN32
  if (hwnd_) {
    DestroyWindow(hwnd_);
    hwnd_ = NULL;
  }
#endif
}

LRESULT CALLBACK Win32UIView::WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
#ifdef _WIN32
  Win32UIView* self = nullptr;
  if (msg == WM_NCCREATE) {
    CREATESTRUCT* cs = reinterpret_cast<CREATESTRUCT*>(lParam);
    self = reinterpret_cast<Win32UIView*>(cs->lpCreateParams);
    self->hwnd_ = hwnd;
    SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  } else {
    self = reinterpret_cast<Win32UIView*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  }

  if (self) {
    return self->handleMessage(msg, wParam, lParam);
  }
  return DefWindowProcW(hwnd, msg, wParam, lParam);
#else
  (void)hwnd; (void)msg; (void)wParam; (void)lParam;
  return 0;
#endif
}

LRESULT Win32UIView::handleMessage(UINT msg, WPARAM wParam, LPARAM lParam) {
#ifdef _WIN32
  switch (msg) {
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC hdc = BeginPaint(hwnd_, &ps);
      paint(hdc);
      EndPaint(hwnd_, &ps);
      return 0;
    }
    case WM_ERASEBKGND:
      return 1; // flicker-free

    case WM_TIMER:
      if (wParam == kMeterTimerId) {
        advanceMeterPeaks(std::chrono::steady_clock::now());
        InvalidateRect(hwnd_, &kMetersRect, FALSE);
        return 0;
      }
      break;

    case WM_DESTROY:
      KillTimer(hwnd_, kMeterTimerId);
      break;

    case WM_LBUTTONDOWN:
      onMouseDown(LOWORD(lParam), HIWORD(lParam), false);
      return 0;

    case WM_RBUTTONDOWN:
      onMouseDown(LOWORD(lParam), HIWORD(lParam), true);
      return 0;

    case WM_MOUSEMOVE:
      onMouseMove(LOWORD(lParam), HIWORD(lParam), wParam);
      return 0;

    case WM_LBUTTONUP:
      onMouseUp(LOWORD(lParam), HIWORD(lParam));
      return 0;

    case WM_MOUSEWHEEL:
      onMouseWheel(GET_WHEEL_DELTA_WPARAM(wParam));
      return 0;

    case WM_LBUTTONDBLCLK:
      onDoubleClick(LOWORD(lParam), HIWORD(lParam));
      return 0;

    case WM_DROPFILES: {
      HDROP hDrop = reinterpret_cast<HDROP>(wParam);
      wchar_t filePath[MAX_PATH];
      if (DragQueryFileW(hDrop, 0, filePath, MAX_PATH)) {
        int len = WideCharToMultiByte(CP_UTF8, 0, filePath, -1, NULL, 0, NULL, NULL);
        if (len > 0) {
          std::string path(len - 1, '\0');
          WideCharToMultiByte(CP_UTF8, 0, filePath, -1, &path[0], len, NULL, NULL);
          std::string ext = path.substr(path.find_last_of(".") + 1);
          std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
          if (ext == "nam") {
            setStagePath(1, path); // Amp
          } else if (ext == "wav") {
            setStagePath(2, path); // Cab A
          }
        }
      }
      DragFinish(hDrop);
      return 0;
    }
  }
  return DefWindowProcW(hwnd_, msg, wParam, lParam);
#else
  (void)msg; (void)wParam; (void)lParam;
  return 0;
#endif
}

void Win32UIView::setControlValue(uint32_t port, float value, bool notify) {
  auto it = controls_.find(port);
  if (it != controls_.end()) {
    it->second.currentValue = std::max(it->second.minValue, std::min(it->second.maxValue, value));
#ifdef _WIN32
    if (hwnd_) {
      InvalidateRect(hwnd_, &it->second.rect, FALSE);
    }
#endif
    if (notify && onControlChanged_) {
      onControlChanged_(port, it->second.currentValue);
    }
  }
}

float Win32UIView::getControlValue(uint32_t port) const {
  auto it = controls_.find(port);
  if (it != controls_.end()) {
    return it->second.currentValue;
  }
  return 0.0f;
}

void Win32UIView::setTuner(float note, float cents) {
  tunerNote_ = note;
  tunerCents_ = cents;
#ifdef _WIN32
  if (hwnd_) {
    RECT r = {120, 10, 320, 60};
    InvalidateRect(hwnd_, &r, FALSE);
  }
#endif
}

void Win32UIView::setAudioLevels(float inDb, float outDb) {
  setMeterLevel(MeterStage::Input, inDb);
  setMeterLevel(MeterStage::Output, outDb);
}

void Win32UIView::advanceMeterPeaks(std::chrono::steady_clock::time_point now) {
  for (auto& meter : meters_) {
    const auto releaseStart = std::max(meter.lastPeakUpdate, meter.peakHoldUntil);
    if (now > releaseStart) {
      const float elapsed = std::chrono::duration<float>(now - releaseStart).count();
      meter.peakDb = std::max(meter.levelDb, meter.peakDb - 20.0f * elapsed);
    }
    meter.lastPeakUpdate = now;
  }
}

void Win32UIView::setMeterLevel(MeterStage stage, float db) {
  const size_t index = static_cast<size_t>(stage);
  if (index >= meters_.size()) return;
  const auto now = std::chrono::steady_clock::now();
  advanceMeterPeaks(now);
  auto& meter = meters_[index];
  meter.levelDb = std::isfinite(db) ? std::max(-120.0f, db) : -120.0f;
  if (meter.levelDb >= meter.peakDb) {
    meter.peakDb = meter.levelDb;
    meter.peakHoldUntil = now + std::chrono::milliseconds(1200);
  }
  if (meter.levelDb >= -0.5f) {
    meter.clipUntil = now + std::chrono::milliseconds(1200);
  }
#ifdef _WIN32
  if (hwnd_) {
    InvalidateRect(hwnd_, &kMetersRect, FALSE);
  }
#endif
}

void Win32UIView::setStagePath(uint32_t stage, const std::string& path) {
  if (stage < 4) {
    stagePaths_[stage] = path;
#ifdef _WIN32
    if (hwnd_) {
      InvalidateRect(hwnd_, NULL, FALSE);
    }
#endif
    if (onStageFileChanged_) {
      onStageFileChanged_(stage, path);
    }
  }
}

void Win32UIView::paint(HDC hdc) {
#ifdef _WIN32
  RECT clientRect;
  GetClientRect(hwnd_, &clientRect);
  int width = clientRect.right;
  int height = clientRect.bottom;
  if (width <= 0 || height <= 0) return;

  HDC memDC = CreateCompatibleDC(hdc);
  HBITMAP memBmp = CreateCompatibleBitmap(hdc, width, height);
  HGDIOBJ oldBmp = SelectObject(memDC, memBmp);

  {
    Gdiplus::Graphics g(memDC);
    g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    g.SetTextRenderingHint(Gdiplus::TextRenderingHintClearTypeGridFit);

    // 1. Overall Dark Background
    Gdiplus::SolidBrush bgBrush(kBgColor);
    g.FillRectangle(&bgBrush, 0, 0, width, height);

    // 2. Header Bar (y = 0..68)
    Gdiplus::SolidBrush headerBrush(kHeaderBgColor);
    g.FillRectangle(&headerBrush, 0, 0, width, 68);
    Gdiplus::Pen headerBorder(kCardBorderColor, 1.0f);
    g.DrawLine(&headerBorder, 0, 68, width, 68);

    // Header Title
    Gdiplus::FontFamily ff(L"Segoe UI");
    Gdiplus::Font titleFont(&ff, 14, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
    Gdiplus::Font smallFont(&ff, 10, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::Font valueFont(&ff, 10, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
    Gdiplus::Font labelFont(&ff, 9, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::Font noteFont(&ff, 20, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);

    Gdiplus::SolidBrush orangeBrush(kAccentOrange);
    Gdiplus::SolidBrush brightBrush(kTextBright);
    Gdiplus::SolidBrush mutedBrush(kTextMuted);

    // Branding
    g.DrawString(L"AXE FX", -1, &titleFont, Gdiplus::PointF(20.0f, 14.0f), &orangeBrush);
    g.DrawString(L"STUDIO PRO", -1, &smallFont, Gdiplus::PointF(20.0f, 35.0f), &mutedBrush);

    // Preset selector button / box (x = 120, y = 16, w = 180, h = 34)
    Gdiplus::Rect presetRect(120, 16, 180, 34);
    Gdiplus::SolidBrush btnBg(kCardBgColor);
    g.FillRectangle(&btnBg, presetRect);
    g.DrawRectangle(&headerBorder, presetRect);

    std::string presetTitle = "Preset: " + PresetManager::instance().currentPresetName();
    int wlen = MultiByteToWideChar(CP_UTF8, 0, presetTitle.c_str(), -1, NULL, 0);
    if (wlen > 0) {
      std::wstring wtitle(wlen, L'\0');
      MultiByteToWideChar(CP_UTF8, 0, presetTitle.c_str(), -1, &wtitle[0], wlen);
      Gdiplus::RectF prF(125.0f, 24.0f, 150.0f, 20.0f);
      g.DrawString(wtitle.c_str(), -1, &smallFont, prF, NULL, &brightBrush);
    }
    // Down arrow triangle
    Gdiplus::Point arrowPts[3] = {Gdiplus::Point(285, 30), Gdiplus::Point(293, 30), Gdiplus::Point(289, 36)};
    g.FillPolygon(&mutedBrush, arrowPts, 3);

    // Tuner Display (x = 315, y = 14, w = 140, h = 38)
    Gdiplus::Rect tunerBox(315, 14, 140, 38);
    Gdiplus::SolidBrush tunerBg(Gdiplus::Color(255, 12, 13, 16));
    g.FillRectangle(&tunerBg, tunerBox);
    g.DrawRectangle(&headerBorder, tunerBox);

    bool tunerOn = (getControlValue(16) >= 0.5f);
    if (tunerOn) {
      if (tunerNote_ < 0.0f) {
        g.DrawString(L"---", -1, &titleFont, Gdiplus::PointF(325.0f, 22.0f), &mutedBrush);
      } else {
        const wchar_t* noteNames[12] = {L"C", L"C#", L"D", L"D#", L"E", L"F", L"F#", L"G", L"G#", L"A", L"A#", L"B"};
        int midi = static_cast<int>(std::round(tunerNote_));
        int nIdx = midi % 12;
        if (nIdx < 0) nIdx += 12;
        int oct = (midi / 12) - 1;
        wchar_t nBuf[16];
        swprintf(nBuf, sizeof(nBuf)/sizeof(wchar_t), L"%s%d", noteNames[nIdx], oct);

        bool inTune = (std::abs(tunerCents_) < 3.0f);
        const Gdiplus::Color& tuneColor = inTune ? kActiveLed : kAccentOrange;
        Gdiplus::SolidBrush tuneBrush(tuneColor);
        g.DrawString(nBuf, -1, &noteFont, Gdiplus::PointF(322.0f, 18.0f), &tuneBrush);

        // Cents line
        float cx = 395.0f + (tunerCents_ / 50.0f) * 45.0f;
        cx = std::max(355.0f, std::min(440.0f, cx));
        Gdiplus::Pen tunePen(tuneColor, 2.0f);
        g.DrawLine(&tunePen, cx, 18.0f, cx, 46.0f);
      }
    } else {
      g.DrawString(L"Tuner Mute", -1, &smallFont, Gdiplus::PointF(345.0f, 25.0f), &mutedBrush);
    }

    // Compact dBFS meters occupy the unused right side of the header.
    const auto meterNow = std::chrono::steady_clock::now();
    advanceMeterPeaks(meterNow);
    const wchar_t* meterTitles[] = {L"IN", L"PRE", L"POST", L"OUT"};
    for (size_t i = 0; i < meters_.size(); ++i) {
      const auto& meter = meters_[i];
      const float x = 774.0f + static_cast<float>(i) * 98.0f;
      const float y = 8.0f;
      const Gdiplus::Color& accent = (i == 1 || i == 2) ? kAccentCyan : kAccentOrange;
      const Gdiplus::Color& levelColor = meter.levelDb >= -0.5f ? kClipColor
          : meter.levelDb >= -6.0f ? kAccentOrange : accent;
      Gdiplus::SolidBrush accentBrush(accent);
      Gdiplus::SolidBrush levelBrush(levelColor);
      Gdiplus::SolidBrush trackBrush(kTrackBg);
      g.FillRectangle(&btnBg, x, y, 92.0f, 52.0f);
      g.DrawRectangle(&headerBorder, x, y, 92.0f, 52.0f);
      g.DrawString(meterTitles[i], -1, &valueFont, Gdiplus::PointF(x + 5.0f, y + 4.0f), &accentBrush);

      wchar_t dbText[32];
      if (meter.levelDb <= -119.0f) {
        swprintf(dbText, 32, L"-inf");
      } else {
        swprintf(dbText, 32, L"%+.1f", meter.levelDb);
      }
      Gdiplus::StringFormat rightAlign;
      rightAlign.SetAlignment(Gdiplus::StringAlignmentFar);
      g.DrawString(dbText, -1, &valueFont, Gdiplus::RectF(x + 31.0f, y + 4.0f, 47.0f, 14.0f),
                   &rightAlign, &levelBrush);
      Gdiplus::SolidBrush clipBrush(meter.levelDb >= -0.5f || meterNow < meter.clipUntil
          ? kClipColor : kInactiveLed);
      g.FillEllipse(&clipBrush, x + 82.0f, y + 8.0f, 4.0f, 4.0f);

      const float trackX = x + 6.0f;
      const float trackY = y + 24.0f;
      const float fraction = (std::clamp(meter.levelDb, -60.0f, 0.0f) + 60.0f) / 60.0f;
      g.FillRectangle(&trackBrush, trackX, trackY, 80.0f, 7.0f);
      if (fraction > 0.0f) {
        g.FillRectangle(&levelBrush, trackX, trackY, 80.0f * fraction, 7.0f);
      }
      if (meter.peakDb > -60.0f) {
        const float peakX = trackX + 79.0f * (std::clamp(meter.peakDb, -60.0f, 0.0f) + 60.0f) / 60.0f;
        Gdiplus::Pen peakPen(kTextBright, 1.0f);
        g.DrawLine(&peakPen, peakX, trackY - 1.0f, peakX, trackY + 8.0f);
      }
      for (float tick : {-60.0f, -24.0f, -12.0f, -6.0f, 0.0f}) {
        const float tickX = trackX + 80.0f * (tick + 60.0f) / 60.0f;
        g.DrawLine(&headerBorder, tickX, trackY + 8.0f, tickX, trackY + 10.0f);
      }
      g.DrawString(L"-60", -1, &labelFont, Gdiplus::PointF(trackX - 2.0f, y + 37.0f), &mutedBrush);
      g.DrawString(L"dBFS", -1, &labelFont, Gdiplus::PointF(x + 32.0f, y + 37.0f), &mutedBrush);
      g.DrawString(L"0", -1, &labelFont, Gdiplus::PointF(x + 79.0f, y + 37.0f), &mutedBrush);
    }

    // Draw Stage Cards
    auto drawCard = [&](int x, int y, int w, int h, const wchar_t* cardTitle,
                        uint32_t stageIdx, const wchar_t* fileFilterHint) {
      Gdiplus::Rect cr(x, y, w, h);
      g.FillRectangle(&btnBg, cr);
      g.DrawRectangle(&headerBorder, cr);

      // Card Header
      g.DrawString(cardTitle, -1, &titleFont, Gdiplus::PointF(x + 12.0f, y + 10.0f), &orangeBrush);

      // File Row (if stage has models)
      if (stageIdx < 4) {
        Gdiplus::Rect fileBox(x + 12, y + 36, w - 100, 24);
        g.FillRectangle(&tunerBg, fileBox);
        g.DrawRectangle(&headerBorder, fileBox);

        std::string fname = getFileNameOnly(stagePaths_[stageIdx]);
        int flen = MultiByteToWideChar(CP_UTF8, 0, fname.c_str(), -1, NULL, 0);
        if (flen > 0) {
          std::wstring wfn(flen, L'\0');
          MultiByteToWideChar(CP_UTF8, 0, fname.c_str(), -1, &wfn[0], flen);
          Gdiplus::RectF fnF(x + 16.0f, y + 41.0f, w - 110.0f, 18.0f);
          g.DrawString(wfn.c_str(), -1, &labelFont, fnF, NULL, &mutedBrush);
        }

        // Load & Clear buttons
        Gdiplus::Rect loadBtn(x + w - 82, y + 36, 42, 24);
        g.FillRectangle(&btnBg, loadBtn);
        g.DrawRectangle(&headerBorder, loadBtn);
        g.DrawString(L"Load", -1, &labelFont, Gdiplus::PointF(x + w - 74.0f, y + 41.0f), &brightBrush);

        Gdiplus::Rect clearBtn(x + w - 36, y + 36, 26, 24);
        g.FillRectangle(&btnBg, clearBtn);
        g.DrawRectangle(&headerBorder, clearBtn);
        g.DrawString(L"X", -1, &labelFont, Gdiplus::PointF(x + w - 28.0f, y + 41.0f), &mutedBrush);
      }
    };

    drawCard(20, 78, 265, 325, L"PEDAL / SCULPT", 0, L"*.nam");
    drawCard(295, 78, 580, 325, L"AMP MODEL & TONE STACK", 1, L"*.nam");
    drawCard(885, 78, 275, 325, L"TRANSFORMER & TUBES", 99, L"");
    drawCard(20, 412, 550, 350, L"DUAL CABINET IMPULSE RESPONSE", 2, L"*.wav");
    drawCard(580, 412, 580, 350, L"SPACE & MASTER STUDIO FX", 99, L"");

    // Cab B file row inside Dual Cabinet card (y + 195)
    {
      int x = 20, y = 412, w = 550;
      g.DrawString(L"CAB B (PARALLEL)", -1, &smallFont, Gdiplus::PointF(x + 12.0f, y + 200.0f), &orangeBrush);
      Gdiplus::Rect fileBoxB(x + 12, y + 220, w - 100, 24);
      g.FillRectangle(&tunerBg, fileBoxB);
      g.DrawRectangle(&headerBorder, fileBoxB);

      std::string fnameB = getFileNameOnly(stagePaths_[3]);
      int flen = MultiByteToWideChar(CP_UTF8, 0, fnameB.c_str(), -1, NULL, 0);
      if (flen > 0) {
        std::wstring wfn(flen, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, fnameB.c_str(), -1, &wfn[0], flen);
        Gdiplus::RectF fnF(x + 16.0f, y + 225.0f, w - 110.0f, 18.0f);
        g.DrawString(wfn.c_str(), -1, &labelFont, fnF, NULL, &mutedBrush);
      }
      Gdiplus::Rect loadBtnB(x + w - 82, y + 220, 42, 24);
      g.FillRectangle(&btnBg, loadBtnB);
      g.DrawRectangle(&headerBorder, loadBtnB);
      g.DrawString(L"Load", -1, &labelFont, Gdiplus::PointF(x + w - 74.0f, y + 225.0f), &brightBrush);

      Gdiplus::Rect clearBtnB(x + w - 36, y + 220, 26, 24);
      g.FillRectangle(&btnBg, clearBtnB);
      g.DrawRectangle(&headerBorder, clearBtnB);
      g.DrawString(L"X", -1, &labelFont, Gdiplus::PointF(x + w - 28.0f, y + 225.0f), &mutedBrush);
    }

    // 3. Render all UI Controls
    for (uint32_t port : controlOrder_) {
      const auto& c = controls_[port];
      const RECT& r = c.rect;

      if (c.type == ControlType::Knob) {
        float cx = (r.left + r.right) * 0.5f;
        float cy = r.top + (r.bottom - r.top) * 0.42f;
        float radius = std::min(r.right - r.left, r.bottom - r.top) * 0.32f;

        // Label above
        int llen = MultiByteToWideChar(CP_UTF8, 0, c.label.c_str(), -1, NULL, 0);
        if (llen > 0) {
          std::wstring wlbl(llen, L'\0');
          MultiByteToWideChar(CP_UTF8, 0, c.label.c_str(), -1, &wlbl[0], llen);
          Gdiplus::RectF lRect(r.left - 10.0f, r.top - 2.0f, (r.right - r.left) + 20.0f, 14.0f);
          Gdiplus::StringFormat sf;
          sf.SetAlignment(Gdiplus::StringAlignmentCenter);
          g.DrawString(wlbl.c_str(), -1, &labelFont, lRect, &sf, &mutedBrush);
        }

        // Knob Background Track Arc (135 to 405 deg)
        Gdiplus::Pen trackPen(kTrackBg, 3.5f);
        trackPen.SetStartCap(Gdiplus::LineCapRound);
        trackPen.SetEndCap(Gdiplus::LineCapRound);
        g.DrawArc(&trackPen, cx - radius, cy - radius, radius * 2.0f, radius * 2.0f, 135.0f, 270.0f);

        // Value Arc
        float norm = (c.currentValue - c.minValue) / (c.maxValue - c.minValue);
        norm = std::max(0.0f, std::min(1.0f, norm));
        float sweep = norm * 270.0f;
        if (sweep > 1.0f) {
          Gdiplus::Pen valPen(kAccentOrange, 3.5f);
          valPen.SetStartCap(Gdiplus::LineCapRound);
          valPen.SetEndCap(Gdiplus::LineCapRound);
          g.DrawArc(&valPen, cx - radius, cy - radius, radius * 2.0f, radius * 2.0f, 135.0f, sweep);
        }

        // Center Knob Disc
        float discR = radius * 0.78f;
        Gdiplus::SolidBrush knobBrush(kKnobBody);
        g.FillEllipse(&knobBrush, cx - discR, cy - discR, discR * 2.0f, discR * 2.0f);
        Gdiplus::Pen knobRimPen(kKnobRim, 1.2f);
        g.DrawEllipse(&knobRimPen, cx - discR, cy - discR, discR * 2.0f, discR * 2.0f);

        // Pointer Tick
        float angleRad = static_cast<float>((135.0f + sweep) * M_PI / 180.0);
        float px = cx + std::cos(angleRad) * (discR * 0.85f);
        float py = cy + std::sin(angleRad) * (discR * 0.85f);
        float ix = cx + std::cos(angleRad) * (discR * 0.35f);
        float iy = cy + std::sin(angleRad) * (discR * 0.35f);
        Gdiplus::Pen needlePen(kTextBright, 2.0f);
        needlePen.SetStartCap(Gdiplus::LineCapRound);
        g.DrawLine(&needlePen, ix, iy, px, py);

        // Value text below
        std::string valStr = c.formatValue ? c.formatValue(c.currentValue) : std::to_string(c.currentValue);
        int vlen = MultiByteToWideChar(CP_UTF8, 0, valStr.c_str(), -1, NULL, 0);
        if (vlen > 0) {
          std::wstring wval(vlen, L'\0');
          MultiByteToWideChar(CP_UTF8, 0, valStr.c_str(), -1, &wval[0], vlen);
          Gdiplus::RectF vRect(r.left - 10.0f, r.bottom - 13.0f, (r.right - r.left) + 20.0f, 14.0f);
          Gdiplus::StringFormat sf;
          sf.SetAlignment(Gdiplus::StringAlignmentCenter);
          g.DrawString(wval.c_str(), -1, &valueFont, vRect, &sf, &brightBrush);
        }
      } else if (c.type == ControlType::Toggle) {
        bool on = (c.currentValue >= 0.5f);
        Gdiplus::Rect tr(r.left, r.top, r.right - r.left, r.bottom - r.top);
        g.FillRectangle(&btnBg, tr);
        g.DrawRectangle(&headerBorder, tr);

        // LED circle
        Gdiplus::SolidBrush ledBrush(on ? kActiveLed : kInactiveLed);
        g.FillEllipse(&ledBrush, r.left + 6, r.top + (r.bottom - r.top - 8) / 2, 8, 8);

        // Label
        int tlen = MultiByteToWideChar(CP_UTF8, 0, c.label.c_str(), -1, NULL, 0);
        if (tlen > 0) {
          std::wstring wlbl(tlen, L'\0');
          MultiByteToWideChar(CP_UTF8, 0, c.label.c_str(), -1, &wlbl[0], tlen);
          g.DrawString(wlbl.c_str(), -1, &labelFont,
                       Gdiplus::PointF(r.left + 18.0f, r.top + (r.bottom - r.top - 12) / 2.0f),
                       on ? &brightBrush : &mutedBrush);
        }
      } else if (c.type == ControlType::Dropdown) {
        Gdiplus::Rect dr(r.left, r.top, r.right - r.left, r.bottom - r.top);
        g.FillRectangle(&btnBg, dr);
        g.DrawRectangle(&headerBorder, dr);

        std::string dval = c.formatValue ? c.formatValue(c.currentValue) : std::to_string(c.currentValue);
        std::string dstr = c.label + ": " + dval;
        int dlen = MultiByteToWideChar(CP_UTF8, 0, dstr.c_str(), -1, NULL, 0);
        if (dlen > 0) {
          std::wstring wd(dlen, L'\0');
          MultiByteToWideChar(CP_UTF8, 0, dstr.c_str(), -1, &wd[0], dlen);
          Gdiplus::RectF dRect(r.left + 5.0f, r.top + 5.0f, (r.right - r.left) - 18.0f, 16.0f);
          g.DrawString(wd.c_str(), -1, &labelFont, dRect, NULL, &brightBrush);
        }
        Gdiplus::Point arrow[3] = {
            Gdiplus::Point(r.right - 12, r.top + 9),
            Gdiplus::Point(r.right - 6, r.top + 9),
            Gdiplus::Point(r.right - 9, r.top + 14)};
        g.FillPolygon(&mutedBrush, arrow, 3);
      }
    }
  }

  BitBlt(hdc, 0, 0, width, height, memDC, 0, 0, SRCCOPY);
  SelectObject(memDC, oldBmp);
  DeleteObject(memBmp);
  DeleteDC(memDC);
#else
  (void)hdc;
#endif
}

void Win32UIView::onMouseDown(int x, int y, bool isRight) {
#ifdef _WIN32
  // Check preset button (120, 16, 180, 34)
  if (x >= 120 && x <= 300 && y >= 16 && y <= 50) {
    POINT pt = {120, 50};
    ClientToScreen(hwnd_, &pt);
    showPresetMenu(pt.x, pt.y);
    return;
  }

  // Check Load / Clear buttons
  // Pedal: Load (203, 114, 42, 24), Clear (249, 114, 26, 24)
  if (x >= 203 && x <= 245 && y >= 114 && y <= 138) { browseForFile(0, false); return; }
  if (x >= 249 && x <= 275 && y >= 114 && y <= 138) { setStagePath(0, ""); return; }

  // Amp: Load (793, 114, 42, 24), Clear (839, 114, 26, 24)
  if (x >= 793 && x <= 835 && y >= 114 && y <= 138) { browseForFile(1, false); return; }
  if (x >= 839 && x <= 865 && y >= 114 && y <= 138) { setStagePath(1, ""); return; }

  // Cab A: Load (488, 448, 42, 24), Clear (534, 448, 26, 24)
  if (x >= 488 && x <= 530 && y >= 448 && y <= 472) { browseForFile(2, true); return; }
  if (x >= 534 && x <= 560 && y >= 448 && y <= 472) { setStagePath(2, ""); return; }

  // Cab B: Load (488, 632, 42, 24), Clear (534, 632, 26, 24)
  if (x >= 488 && x <= 530 && y >= 632 && y <= 656) { browseForFile(3, true); return; }
  if (x >= 534 && x <= 560 && y >= 632 && y <= 656) { setStagePath(3, ""); return; }

  for (auto& pair : controls_) {
    auto& c = pair.second;
    if (x >= c.rect.left && x <= c.rect.right && y >= c.rect.top && y <= c.rect.bottom) {
      if (c.type == ControlType::Knob) {
        activeDragControl_ = &c;
        c.isDragging = true;
        c.dragStartY = y;
        c.dragStartValue = c.currentValue;
        SetCapture(hwnd_);
        return;
      } else if (c.type == ControlType::Toggle) {
        float newVal = (c.currentValue >= 0.5f) ? 0.0f : 1.0f;
        setControlValue(c.port, newVal, true);
        return;
      } else if (c.type == ControlType::Dropdown) {
        if (c.port == 20 || c.port == 21) {
          float next = c.currentValue + 1.0f;
          if (next > 6.0f) next = 0.0f;
          setControlValue(c.port, next, true);
        } else if (c.port == 30) {
          float next = c.currentValue + 1.0f;
          if (next > 12.0f) next = 0.0f;
          setControlValue(c.port, next, true);
        } else if (c.port == 80) {
          float next = c.currentValue + 1.0f;
          if (next > 2.0f) next = 0.0f;
          setControlValue(c.port, next, true);
        } else if (c.port == 24) {
          float next = c.currentValue + 1.0f;
          if (next > 2.0f) next = 0.0f;
          setControlValue(c.port, next, true);
        }
        return;
      }
    }
  }
#else
  (void)x; (void)y; (void)isRight;
#endif
}

void Win32UIView::onMouseMove(int x, int y, WPARAM flags) {
#ifdef _WIN32
  if (activeDragControl_ && activeDragControl_->isDragging) {
    int deltaY = activeDragControl_->dragStartY - y;
    float range = activeDragControl_->maxValue - activeDragControl_->minValue;
    float sensitivity = 0.005f * range;
    if (flags & MK_SHIFT) sensitivity *= 0.25f; // fine control

    float newVal = activeDragControl_->dragStartValue + deltaY * sensitivity;
    newVal = std::max(activeDragControl_->minValue, std::min(activeDragControl_->maxValue, newVal));
    setControlValue(activeDragControl_->port, newVal, true);
  }
#else
  (void)x; (void)y; (void)flags;
#endif
}

void Win32UIView::onMouseUp(int x, int y) {
#ifdef _WIN32
  if (activeDragControl_) {
    activeDragControl_->isDragging = false;
    activeDragControl_ = nullptr;
    ReleaseCapture();
  }
#else
  (void)x; (void)y;
#endif
}

void Win32UIView::onMouseWheel(short delta) {
  // Adjust control under cursor
  POINT pt;
  GetCursorPos(&pt);
  ScreenToClient(hwnd_, &pt);

  for (auto& pair : controls_) {
    auto& c = pair.second;
    if (pt.x >= c.rect.left && pt.x <= c.rect.right && pt.y >= c.rect.top && pt.y <= c.rect.bottom) {
      if (c.type == ControlType::Knob) {
        float step = (c.maxValue - c.minValue) * 0.02f;
        float newVal = c.currentValue + (delta > 0 ? step : -step);
        setControlValue(c.port, newVal, true);
        return;
      }
    }
  }
}

void Win32UIView::onDoubleClick(int x, int y) {
  for (auto& pair : controls_) {
    auto& c = pair.second;
    if (x >= c.rect.left && x <= c.rect.right && y >= c.rect.top && y <= c.rect.bottom) {
      if (c.type == ControlType::Knob) {
        setControlValue(c.port, c.defaultValue, true);
        return;
      }
    }
  }
}

void Win32UIView::showPresetMenu(int screenX, int screenY) {
#ifdef _WIN32
  HMENU hMenu = CreatePopupMenu();
  auto& pm = PresetManager::instance();
  pm.rescanPresets();

  const auto& factory = pm.factoryPresets();
  const auto& userNames = pm.userPresetNames();

  UINT id = 1000;
  // Factory presets
  AppendMenuW(hMenu, MF_STRING | MF_GRAYED, 0, L"--- FACTORY PRESETS ---");
  for (const auto& fp : factory) {
    int wlen = MultiByteToWideChar(CP_UTF8, 0, fp.name.c_str(), -1, NULL, 0);
    if (wlen > 0) {
      std::wstring wname(wlen, L'\0');
      MultiByteToWideChar(CP_UTF8, 0, fp.name.c_str(), -1, &wname[0], wlen);
      UINT flags = MF_STRING;
      if (fp.name == pm.currentPresetName()) flags |= MF_CHECKED;
      AppendMenuW(hMenu, flags, id++, wname.c_str());
    }
  }

  // User presets
  AppendMenuW(hMenu, MF_SEPARATOR, 0, NULL);
  AppendMenuW(hMenu, MF_STRING | MF_GRAYED, 0, L"--- USER PRESETS ---");
  if (userNames.empty()) {
    AppendMenuW(hMenu, MF_STRING | MF_GRAYED, 0, L"(No User Presets)");
  } else {
    for (const auto& un : userNames) {
      int wlen = MultiByteToWideChar(CP_UTF8, 0, un.c_str(), -1, NULL, 0);
      if (wlen > 0) {
        std::wstring wname(wlen, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, un.c_str(), -1, &wname[0], wlen);
        UINT flags = MF_STRING;
        if (un == pm.currentPresetName()) flags |= MF_CHECKED;
        AppendMenuW(hMenu, flags, id++, wname.c_str());
      }
    }
  }

  // Actions adhering to studio-deck-slot-presets rule
  AppendMenuW(hMenu, MF_SEPARATOR, 0, NULL);
  AppendMenuW(hMenu, MF_STRING, 5001, L"Save Preset");
  AppendMenuW(hMenu, MF_STRING, 5002, L"Save Preset As...");
  AppendMenuW(hMenu, MF_STRING, 5003, L"Rename Preset...");
  AppendMenuW(hMenu, MF_STRING, 5004, L"Delete Preset");

  int selected = TrackPopupMenuEx(hMenu, TPM_RETURNCMD | TPM_LEFTALIGN | TPM_TOPALIGN,
                                  screenX, screenY, hwnd_, NULL);
  DestroyMenu(hMenu);

  if (selected >= 1000 && selected < static_cast<int>(1000 + factory.size())) {
    size_t idx = selected - 1000;
    RigPreset p = factory[idx];
    applyPreset(p);
  } else if (selected >= static_cast<int>(1000 + factory.size()) &&
             selected < static_cast<int>(1000 + factory.size() + userNames.size())) {
    size_t idx = selected - (1000 + factory.size());
    RigPreset p;
    if (pm.loadPresetNamed(userNames[idx], p)) {
      applyPreset(p);
    }
  } else if (selected == 5001) {
    // Save Preset
    RigPreset p = capturePreset(pm.currentPresetName());
    pm.savePresetNamed(pm.currentPresetName(), p);
  } else if (selected == 5002) {
    // Save Preset As...
    // Prompt or save with default incremented name
    std::string newName = "User Rig " + std::to_string(userNames.size() + 1);
    RigPreset p = capturePreset(newName);
    pm.savePresetNamed(newName, p);
  } else if (selected == 5003) {
    // Rename Preset...
    std::string oldName = pm.currentPresetName();
    std::string newName = oldName + " (Edited)";
    pm.renamePresetNamed(oldName, newName);
  } else if (selected == 5004) {
    // Delete Preset
    pm.deletePresetNamed(pm.currentPresetName());
    if (!factory.empty()) applyPreset(factory[0]);
  }
#else
  (void)screenX; (void)screenY;
#endif
}

void Win32UIView::browseForFile(uint32_t stage, bool isWav) {
#ifdef _WIN32
  wchar_t fileName[MAX_PATH] = L"";
  OPENFILENAMEW ofn = {sizeof(OPENFILENAMEW)};
  ofn.hwndOwner = hwnd_;
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
      setStagePath(stage, path);
    }
  }
#else
  (void)stage; (void)isWav;
#endif
}

void Win32UIView::applyPreset(const RigPreset& preset) {
  PresetManager::instance().setCurrentPresetName(preset.name);
  for (const auto& pair : preset.controls) {
    setControlValue(pair.first, pair.second, true);
  }
  for (size_t s = 0; s < 4; ++s) {
    if (!preset.stages[s].path.empty()) {
      setStagePath(static_cast<uint32_t>(s), preset.stages[s].path);
    }
  }
#ifdef _WIN32
  if (hwnd_) InvalidateRect(hwnd_, NULL, FALSE);
#endif
}

RigPreset Win32UIView::capturePreset(const std::string& name) const {
  RigPreset p;
  p.name = name.empty() ? PresetManager::instance().currentPresetName() : name;
  for (const auto& pair : controls_) {
    p.controls[pair.first] = pair.second.currentValue;
  }
  for (size_t s = 0; s < 4; ++s) {
    p.stages[s].path = stagePaths_[s];
    p.stages[s].enabled = (s < 3);
  }
  return p;
}

} // namespace NAMRigWin32
