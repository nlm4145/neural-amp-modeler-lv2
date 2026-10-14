#!/usr/bin/env python3
"""Check Windows routing, meter state, and standalone atomic peak transfer."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
header = (ROOT / "src/win32_ui_view.h").read_text()
view = (ROOT / "src/win32_ui_view.cpp").read_text()
ui = (ROOT / "src/nam_rig_win32_ui.cpp").read_text()
standalone = (ROOT / "src/standalone_main_win32.cpp").read_text()

for urid, stage in (
    ("inputDbURID", "Input"),
    ("preAmpDbURID", "PreAmp"),
    ("postAmpDbURID", "PostAmp"),
    ("outputDbURID", "Output"),
):
    assert f"propID == ui->{urid}" in ui
    assert f"setMeterLevel(NAMRigWin32::MeterStage::{stage}, val);" in ui
assert "ui->view->setAudioLevels(" not in ui, "one notification must not reset another meter"
assert 'meterTitles[] = {L"IN", L"PRE", L"POST", L"OUT"}' in view
assert "std::clamp(meter.levelDb, -60.0f, 0.0f)" in view
assert 'L"dBFS"' in view and "meter.peakDb" in view and "meter.clipUntil" in view
assert "SetTimer(hwnd_, kMeterTimerId, 33, NULL)" in view
assert "KillTimer(hwnd_, kMeterTimerId)" in view

# Preserve the standalone's raw input and combined stereo output measurements.
for field, stage in (
    ("inPeakMeter_", "Input"),
    ("preAmpDbMeter_", "PreAmp"),
    ("postAmpDbMeter_", "PostAmp"),
    ("outPeakMeter_", "Output"),
):
    assert f"{field}.applyTo(*uiView_, NAMRigWin32::MeterStage::{stage})" in standalone
assert "inPeakMeter_.store(maxIn > 1e-4f ? 20.0f * std::log10(maxIn) : -80.0f)" in standalone
assert "outPeakMeter_.store(maxOut > 1e-4f ? 20.0f * std::log10(maxOut) : -80.0f)" in standalone
assert "float absV = std::abs(inL[i]);" in standalone
assert "float absV = std::max(std::abs(outL[i]), std::abs(outR[i]));" in standalone
assert "LV2_ATOM_SEQUENCE_FOREACH(notify, event)" in standalone
assert "resetSequence(notifyBuffer_, kAtomBufferSize - sizeof(LV2_Atom), true);\n    plugin_->process(count);" in standalone
for stage, uri, field in (
    ("PreAmp", "PRE_AMP", "preAmp"),
    ("PostAmp", "POST_AMP", "postAmp"),
):
    assert f"uridMap_.map(NAM_RIG_{uri}_DB_URI)" in standalone
    assert f"{field}DbMeter_.store(db)" in standalone
assert "value->size != sizeof(float)" in standalone

# Compile the unchanged state methods without Win32 rendering dependencies so
# timing/independence regressions are executable on non-Windows development hosts.
compiler = shutil.which("c++")
assert compiler, "a C++ compiler is required for the meter-state checks"
state = header.split("  struct MeterState {", 1)[1].split("  // Active dragging control", 1)[0]
methods = view.split("void Win32UIView::setAudioLevels(", 1)[1].split("void Win32UIView::setStagePath(", 1)[0]
transfer = "struct StandaloneMeter {" + standalone.split("struct StandaloneMeter {", 1)[1].split("class StandaloneApp {", 1)[0]
fixture = """
#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <limits>
#include <thread>
enum class MeterStage { Input, PreAmp, PostAmp, Output };
struct Win32UIView {
  void setAudioLevels(float, float);
  void setMeterLevel(MeterStage, float);
  void advanceMeterPeaks(std::chrono::steady_clock::time_point);
  struct MeterState {
""" + state + "};\nvoid Win32UIView::setAudioLevels(" + methods + """
namespace NAMRigWin32 {
  using ::Win32UIView;
  using ::MeterStage;
}
""" + transfer + """
int main() {
  using namespace std::chrono;
  Win32UIView v;
  for (const auto& m : v.meters_) assert(m.levelDb == -120.0f);
  v.setMeterLevel(MeterStage::Input, -18.0f);
  v.setMeterLevel(MeterStage::Output, -9.0f);
  v.setMeterLevel(MeterStage::PreAmp, -3.0f);
  v.setMeterLevel(MeterStage::PostAmp, 1.0f);
  v.setMeterLevel(MeterStage::Input, -22.0f);
  assert(v.meters_[1].levelDb == -3.0f);
  assert(v.meters_[2].levelDb == 1.0f);
  assert(v.meters_[3].levelDb == -9.0f);
  v.setAudioLevels(-30.0f, -12.0f);
  assert(v.meters_[0].levelDb == -30.0f && v.meters_[3].levelDb == -12.0f);
  assert(v.meters_[1].levelDb == -3.0f && v.meters_[2].levelDb == 1.0f);
  v.setMeterLevel(MeterStage::PreAmp, std::numeric_limits<float>::quiet_NaN());
  assert(v.meters_[1].levelDb == -120.0f);
  v.setMeterLevel(MeterStage::PreAmp, -200.0f);
  assert(v.meters_[1].levelDb == -120.0f);

  // A peak remains held for 1.2 s, then falls at 20 dB/s even without messages.
  v.setMeterLevel(MeterStage::PostAmp, -40.0f);
  auto& m = v.meters_[2];
  const auto start = m.peakHoldUntil - milliseconds(1200);
  assert(m.clipUntil >= start + milliseconds(1199));
  v.advanceMeterPeaks(start + milliseconds(1000));
  assert(m.peakDb == 1.0f);
  v.advanceMeterPeaks(start + milliseconds(1700));
  assert(std::abs(m.peakDb - (-9.0f)) < 0.001f);
  assert(m.clipUntil < start + milliseconds(1700));
  auto once = v;
  auto many = v;
  once.advanceMeterPeaks(start + milliseconds(2200));
  for (int ms = 1750; ms <= 2200; ms += 50)
    many.advanceMeterPeaks(start + milliseconds(ms));
  assert(std::abs(once.meters_[2].peakDb - many.meters_[2].peakDb) < 0.001f);
  v.advanceMeterPeaks(start + seconds(10));
  assert(m.peakDb == m.levelDb);

  Win32UIView polled;
  StandaloneMeter meters[] = {
      StandaloneMeter(-80.0f), StandaloneMeter(-120.0f),
      StandaloneMeter(-120.0f), StandaloneMeter(-80.0f)};
  for (size_t i = 0; i < 4; ++i) {
    // Each stage clips briefly, then falls below the threshold before a UI poll.
    meters[i].store(1.0f + static_cast<float>(i));
    meters[i].store(-30.0f - static_cast<float>(i));
    meters[i].applyTo(polled, static_cast<MeterStage>(i));
    assert(meters[i].pendingPeakDb.load() == -120.0f);
    assert(meters[i].latestDb.load() == -30.0f - static_cast<float>(i));
    assert(polled.meters_[i].levelDb == meters[i].latestDb.load());
    assert(polled.meters_[i].peakDb == 1.0f + static_cast<float>(i));
    assert(polled.meters_[i].clipUntil > steady_clock::now());
  }
  // Draining one stage must not touch another pending maximum.
  meters[0].store(-50.0f);
  meters[1].store(5.0f);
  meters[0].applyTo(polled, MeterStage::Input);
  assert(meters[1].pendingPeakDb.load() == 5.0f);
  assert(polled.meters_[1].levelDb == -31.0f);
  meters[1].store(-31.0f);
  meters[1].applyTo(polled, MeterStage::PreAmp);
  assert(polled.meters_[1].levelDb == -31.0f && polled.meters_[1].peakDb == 5.0f);

  // An empty second drain cannot replay an expired clip or old maximum.
  polled.advanceMeterPeaks(steady_clock::now() + seconds(10));
  const auto oldClipUntil = polled.meters_[1].clipUntil;
  meters[1].applyTo(polled, MeterStage::PreAmp);
  assert(polled.meters_[1].levelDb == -31.0f && polled.meters_[1].peakDb == -31.0f);
  assert(polled.meters_[1].clipUntil == oldClipUntil);

  // Exercise concurrent CAS accumulation and exchange drains with real atomics.
  StandaloneMeter concurrent(-80.0f);
  Win32UIView raced;
  std::atomic<bool> finished{false};
  std::thread producer([&] {
    for (int i = 0; i < 20000; ++i) {
      concurrent.store(i % 23 == 0 ? 6.0f : -20.0f);
      concurrent.store(-50.0f);
    }
    finished.store(true);
  });
  float observedPeak = -120.0f;
  do {
    concurrent.applyTo(raced, MeterStage::Input);
    observedPeak = std::max(observedPeak, raced.meters_[0].peakDb);
    std::this_thread::yield();
  } while (!finished.load());
  producer.join();
  concurrent.applyTo(raced, MeterStage::Input);
  observedPeak = std::max(observedPeak, raced.meters_[0].peakDb);
  assert(observedPeak == 6.0f);
  assert(raced.meters_[0].levelDb == -50.0f);
  assert(concurrent.latestDb.load() == -50.0f && concurrent.pendingPeakDb.load() == -120.0f);
}
"""
with tempfile.TemporaryDirectory(prefix="win32-meter-test-") as directory:
    executable = str(Path(directory) / "meter_state")
    subprocess.run([compiler, "-std=c++20", "-pthread", "-x", "c++", "-", "-o", executable],
                   input=fixture, text=True, check=True)
    subprocess.run([executable], check=True)

print("  PASS  Windows routing, atomic peak transfer, and elapsed-time peak/clip holds")
