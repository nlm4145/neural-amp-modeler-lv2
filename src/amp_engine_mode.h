#pragma once

#include <algorithm>
#include <atomic>
#include <cmath>

namespace NAMRig {
namespace EngineMode {

// Audio interface instrument-input headroom calibration (0 dBFS -> dBu).
// Matched against each NAM capture's input_level_dbu metadata so guitars hit
// pedals and amp captures at true hardware voltage regardless of interface gain.
inline constexpr float kDefaultInputCalibrationDbu = 12.0f;
inline constexpr float kMinInputCalibrationDbu = 0.0f;
inline constexpr float kMaxInputCalibrationDbu = 24.0f;

inline std::atomic<float>& inputCalibrationDbuStorage() noexcept {
  static std::atomic<float> dbu{kDefaultInputCalibrationDbu};
  return dbu;
}

inline std::atomic<float>& requestedCalibrationDbuStorage() noexcept {
  static std::atomic<float> requestedDbu{kDefaultInputCalibrationDbu};
  return requestedDbu;
}

inline float inputCalibrationDbu() noexcept {
  return inputCalibrationDbuStorage().load(std::memory_order_relaxed);
}

inline float requestedInputCalibrationDbu() noexcept {
  return requestedCalibrationDbuStorage().load(std::memory_order_relaxed);
}

// Immediate setter (for unit tests and startup before audio runs).
inline void setInputCalibrationDbu(float dbu) noexcept {
  const float clamped = std::isfinite(dbu)
      ? std::clamp(dbu, kMinInputCalibrationDbu, kMaxInputCalibrationDbu)
      : kDefaultInputCalibrationDbu;
  requestedCalibrationDbuStorage().store(clamped, std::memory_order_relaxed);
  inputCalibrationDbuStorage().store(clamped, std::memory_order_relaxed);
}

// Click-safe runtime request from UI: audio thread fades out, commits at
// silence via commitRequested(), and fades back in.
inline void requestInputCalibrationDbu(float dbu) noexcept {
  const float clamped = std::isfinite(dbu)
      ? std::clamp(dbu, kMinInputCalibrationDbu, kMaxInputCalibrationDbu)
      : kDefaultInputCalibrationDbu;
  requestedCalibrationDbuStorage().store(clamped, std::memory_order_relaxed);
}

inline void commitRequested() noexcept {
  inputCalibrationDbuStorage().store(
      requestedCalibrationDbuStorage().load(std::memory_order_relaxed),
      std::memory_order_relaxed);
}

}  // namespace EngineMode
}  // namespace NAMRig
