#!/usr/bin/env python3
"""Execute the real WASAPI stop boundary with fake Win32 APIs and a live callback.

Run: python3 tests/test_win32_audio_stop.py
No Windows audio runtime is required. Failure cases run in child processes so
the real terminate path can verify that handles/state survive until fail-fast.
"""
from pathlib import Path
import os
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "src/win32_audio.cpp").read_text()


def method(signature, next_signature):
    return signature + source.split(signature, 1)[1].split(next_signature, 1)[0]


methods = (
    method("WindowsAudioEngine::~WindowsAudioEngine()", "bool WindowsAudioEngine::start(")
    + method("void WindowsAudioEngine::stop()", "bool WindowsAudioEngine::startWasapi(")
    + method("void WindowsAudioEngine::stopWasapi()", "void WindowsAudioEngine::wasapiThreadFunc()")
)

fixture = r"""
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>

using DWORD = uint32_t;
constexpr DWORD WAIT_OBJECT_0 = 0;
constexpr DWORD WAIT_TIMEOUT = 258;
constexpr DWORD WAIT_FAILED = 0xffffffffu;
constexpr DWORD INFINITE = 0xffffffffu;
struct Handle { bool closed = false; };
using HANDLE = Handle*;
Handle threadHandle, stopEvent, outEvent, inEvent;
DWORD forcedWait = WAIT_OBJECT_0;
int closes = 0, releases = 0, clientStops = 0, drains = 0, uninitializes = 0;
std::mutex mutex;
std::condition_variable cv;
bool callbackActive = false, callbackFinished = false, stopSignaled = false;
std::thread audioThread;

int SetEvent(HANDLE handle) {
  assert(handle == &stopEvent && !handle->closed);
  std::lock_guard<std::mutex> lock(mutex);
  stopSignaled = true;
  cv.notify_all();
  return 1;
}
DWORD WaitForSingleObject(HANDLE handle, DWORD timeout) {
  assert(handle == &threadHandle && !handle->closed && stopSignaled);
  if (forcedWait != WAIT_OBJECT_0) return forcedWait;
  std::unique_lock<std::mutex> lock(mutex);
  if (timeout == INFINITE) {
    cv.wait(lock, [] { return callbackFinished; });
  } else if (!cv.wait_for(lock, std::chrono::milliseconds(timeout),
                         [] { return callbackFinished; })) {
    return WAIT_TIMEOUT;
  }
  lock.unlock();
  audioThread.join();
  return WAIT_OBJECT_0;
}
DWORD GetLastError() { return 6; } // ERROR_INVALID_HANDLE
int CloseHandle(HANDLE handle) {
  assert(callbackFinished && !callbackActive && !handle->closed);
  if (handle == &threadHandle) assert(!audioThread.joinable());
  handle->closed = true;
  ++closes;
  return 1;
}
struct Client {
  bool released = false;
  void Stop() { assert(callbackFinished && !callbackActive); ++clientStops; }
  void Release() {
    assert(callbackFinished && !callbackActive && !released);
    released = true;
    ++releases;
  }
};
using IAudioClient = Client;
using IAudioRenderClient = Client;
using IAudioCaptureClient = Client;
Client outClient, inClient, renderClient, captureClient;
void CoUninitialize() { assert(!callbackActive); ++uninitializes; }

// Only the stop boundary is extracted; initialization and device APIs are not faked.
enum class AudioDriverType { WASAPI_Shared, ASIO };
class WindowsAudioEngine {
 public:
  ~WindowsAudioEngine();
  void stop();
  void stopWasapi();
  void stopAsio() { std::abort(); } // This harness exercises WASAPI only.
  struct { AudioDriverType driverType = AudioDriverType::WASAPI_Shared; } config_;
  bool isRunning_ = true;
  HANDLE wasapiThread_ = &threadHandle;
  HANDLE wasapiStopEvent_ = &stopEvent;
  HANDLE wasapiOutEvent_ = &outEvent;
  HANDLE wasapiInEvent_ = &inEvent;
  void* wasapiOutClient_ = &outClient;
  void* wasapiInClient_ = &inClient;
  void* wasapiOutRender_ = &renderClient;
  void* wasapiInCapture_ = &captureClient;
};
#define _WIN32
""" + methods + r"""

WindowsAudioEngine* engine = nullptr;
void verifyFailure() {
  assert(engine && engine->isRunning_ && callbackActive && !callbackFinished);
  assert(engine->wasapiThread_ == &threadHandle && !threadHandle.closed);
  assert(engine->wasapiStopEvent_ == &stopEvent && !stopEvent.closed);
  assert(engine->wasapiOutEvent_ == &outEvent && !outEvent.closed);
  assert(engine->wasapiInEvent_ == &inEvent && !inEvent.closed);
  assert(engine->wasapiOutClient_ == &outClient);
  assert(engine->wasapiInClient_ == &inClient);
  assert(engine->wasapiOutRender_ == &renderClient);
  assert(engine->wasapiInCapture_ == &captureClient);
  assert(closes == 0 && releases == 0 && clientStops == 0);
  assert(drains == 0 && uninitializes == 0 && stopSignaled);
  std::_Exit(86);
}

int main(int argc, char** argv) {
  assert(argc == 2);
  const std::string mode = argv[1];
  engine = new WindowsAudioEngine;
  if (mode != "join") {
    forcedWait = mode == "unexpected_wait" ? WAIT_TIMEOUT : WAIT_FAILED;
    callbackActive = true;
    std::set_terminate(verifyFailure);
    if (mode == "destructor_failure") delete engine;
    else engine->stop();
    ++drains; // A failed stop must not reach the worker's response drain.
    return 1;
  }

  audioThread = std::thread([] {
    std::unique_lock<std::mutex> lock(mutex);
    callbackActive = true;
    cv.notify_all();
    cv.wait(lock, [] { return stopSignaled; });
    lock.unlock();
    // Keep the callback alive beyond the old three-second stop timeout.
    std::this_thread::sleep_for(std::chrono::milliseconds(3200));
    lock.lock();
    assert(closes == 0 && releases == 0 && clientStops == 0 && drains == 0);
    callbackActive = false;
    callbackFinished = true;
    cv.notify_all();
  });
  {
    std::unique_lock<std::mutex> lock(mutex);
    cv.wait(lock, [] { return callbackActive; });
  }
  engine->stop();
  assert(callbackFinished && !callbackActive && !audioThread.joinable());
  ++drains;
  assert(!engine->isRunning_ && !engine->wasapiThread_);
  assert(!engine->wasapiStopEvent_ && !engine->wasapiOutEvent_ && !engine->wasapiInEvent_);
  assert(!engine->wasapiOutClient_ && !engine->wasapiInClient_);
  assert(!engine->wasapiOutRender_ && !engine->wasapiInCapture_);
  assert(closes == 4 && releases == 4 && clientStops == 2);
  engine->stop();
  delete engine;
  assert(closes == 4 && releases == 4 && clientStops == 2 && uninitializes == 1);
}
"""

compiler = shlex.split(os.environ.get("CXX", "c++"))
assert compiler and shutil.which(compiler[0]), "a native C++ compiler is required"
with tempfile.TemporaryDirectory(prefix="win32-audio-stop-") as directory:
    executable = str(Path(directory) / "audio_stop")
    subprocess.run(
        compiler + ["-std=c++17", "-pthread"]
        + shlex.split(os.environ.get("CXXFLAGS", ""))
        + ["-x", "c++", "-", "-o", executable],
        input=fixture, text=True, check=True,
    )
    subprocess.run([executable, "join"], check=True, timeout=15)
    for mode in ("wait_failed", "unexpected_wait", "destructor_failure"):
        result = subprocess.run([executable, mode], capture_output=True, text=True, timeout=5)
        assert result.returncode == 86, (mode, result.returncode, result.stderr)
        assert "WASAPI thread join failed" in result.stderr, "join failure must be observable"

print("  PASS  WASAPI joins delayed callbacks; failed joins reject cleanup and response drain")
