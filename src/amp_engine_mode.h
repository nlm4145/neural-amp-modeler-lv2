#pragma once

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>

namespace NAMRig {
namespace EngineMode {

// Runtime A/B evaluation switches for Tier 1 (clarity, anti-aliasing & bug fixes)
// and Tier 2 (palm-muting dynamics, calibration & tube-amp physics).
//
// Default is kNone so unit tests and LV2 hosts preserve bit-exact baseline DSP
// unless explicitly enabled (e.g. from the standalone Axe FX menu bar dropdown).
enum FeatureFlags : uint32_t {
  kNone                       = 0u,

  // ---- Tier 1: Quality, Clarity & Bug Fixes ----
  kModelRateResampling        = 1u << 0,
  kInterStageDcBlocking       = 1u << 1,
  kParallelCabAndOdBandLimit  = 1u << 2,
  kOverdriveAdaaAndMatchedEq  = 1u << 3,

  // ---- Tier 2: Palm-Muting Dynamics, Calibration & Tube Realism ----
  kCalibrationAndPedalStaging = 1u << 4,
  kPowerStageTubeDynamics     = 1u << 5,
  kSpeakerPalmMuteDynamics    = 1u << 6,
  kGateAndCompDynamics        = 1u << 7,
  kPreAmpTightAndBrightCap    = 1u << 8,

  kTier1 = kModelRateResampling |
           kInterStageDcBlocking |
           kParallelCabAndOdBandLimit |
           kOverdriveAdaaAndMatchedEq,

  kTier2 = kCalibrationAndPedalStaging |
           kPowerStageTubeDynamics |
           kSpeakerPalmMuteDynamics |
           kGateAndCompDynamics |
           kPreAmpTightAndBrightCap,

  kAllTier1And2 = kTier1 | kTier2,
};

inline constexpr float kDefaultInputCalibrationDbu = 12.0f;
inline constexpr float kMinInputCalibrationDbu = 0.0f;
inline constexpr float kMaxInputCalibrationDbu = 24.0f;

inline std::atomic<uint32_t>& flagsStorage() noexcept {
  static std::atomic<uint32_t> flags{kNone};
  return flags;
}

inline std::atomic<uint32_t>& requestedFlagsStorage() noexcept {
  static std::atomic<uint32_t> requested{kNone};
  return requested;
}

inline std::atomic<float>& inputCalibrationDbuStorage() noexcept {
  static std::atomic<float> dbu{kDefaultInputCalibrationDbu};
  return dbu;
}

inline std::atomic<float>& requestedCalibrationDbuStorage() noexcept {
  static std::atomic<float> requestedDbu{kDefaultInputCalibrationDbu};
  return requestedDbu;
}

inline uint32_t flags() noexcept {
  return flagsStorage().load(std::memory_order_relaxed);
}

inline uint32_t requestedFlags() noexcept {
  return requestedFlagsStorage().load(std::memory_order_relaxed);
}

inline bool has(uint32_t mask) noexcept {
  return (flags() & mask) == mask;
}

inline bool requestedHas(uint32_t mask) noexcept {
  return (requestedFlags() & mask) == mask;
}

inline bool anyEnabled() noexcept {
  return (flags() & kAllTier1And2) != 0u;
}

inline bool allEnabled() noexcept {
  return (flags() & kAllTier1And2) == kAllTier1And2;
}

inline bool isTier1Only() noexcept {
  return (flags() & kAllTier1And2) == kTier1;
}

// Immediate setter (for unit tests and startup before audio runs).
inline void setFlags(uint32_t newFlags) noexcept {
  const uint32_t masked = newFlags & kAllTier1And2;
  requestedFlagsStorage().store(masked, std::memory_order_relaxed);
  flagsStorage().store(masked, std::memory_order_relaxed);
}

// Click-safe runtime request from UI: audio thread fades out, commits at
// silence via commitRequested(), resets DSP state, and fades back in.
inline void requestFlags(uint32_t newFlags) noexcept {
  requestedFlagsStorage().store(newFlags & kAllTier1And2, std::memory_order_relaxed);
}

inline void setEnhanced(bool enabled) noexcept {
  setFlags(enabled ? kAllTier1And2 : kNone);
}

inline void toggleFlag(uint32_t flag) noexcept {
  setFlags(flags() ^ (flag & kAllTier1And2));
}

inline void requestToggleFlag(uint32_t flag) noexcept {
  requestFlags(requestedFlags() ^ (flag & kAllTier1And2));
}

inline float inputCalibrationDbu() noexcept {
  return inputCalibrationDbuStorage().load(std::memory_order_relaxed);
}

inline float requestedInputCalibrationDbu() noexcept {
  return requestedCalibrationDbuStorage().load(std::memory_order_relaxed);
}

inline void setInputCalibrationDbu(float dbu) noexcept {
  const float clamped = std::isfinite(dbu)
      ? std::clamp(dbu, kMinInputCalibrationDbu, kMaxInputCalibrationDbu)
      : kDefaultInputCalibrationDbu;
  requestedCalibrationDbuStorage().store(clamped, std::memory_order_relaxed);
  inputCalibrationDbuStorage().store(clamped, std::memory_order_relaxed);
}

inline void requestInputCalibrationDbu(float dbu) noexcept {
  const float clamped = std::isfinite(dbu)
      ? std::clamp(dbu, kMinInputCalibrationDbu, kMaxInputCalibrationDbu)
      : kDefaultInputCalibrationDbu;
  requestedCalibrationDbuStorage().store(clamped, std::memory_order_relaxed);
}

inline void commitRequested() noexcept {
  flagsStorage().store(requestedFlagsStorage().load(std::memory_order_relaxed),
                       std::memory_order_relaxed);
  inputCalibrationDbuStorage().store(
      requestedCalibrationDbuStorage().load(std::memory_order_relaxed),
      std::memory_order_relaxed);
}

}  // namespace EngineMode
}  // namespace NAMRig
