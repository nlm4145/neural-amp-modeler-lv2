#pragma once

#include <atomic>
#include <cstdint>

#ifndef NEURALAUDIO_AUDIT_FLAGS_DEFINED
#define NEURALAUDIO_AUDIT_FLAGS_DEFINED
namespace NeuralAudio {
inline std::atomic<bool>& UseExactTanhFlag() noexcept {
  static std::atomic<bool> flag{false};
  return flag;
}
inline std::atomic<bool>& UsePolyphaseConditionDspFlag() noexcept {
  static std::atomic<bool> flag{false};
  return flag;
}
}  // namespace NeuralAudio
#endif

namespace NAMRig {
namespace AuditMode {

enum FixFlags : uint32_t {
  kNone                 = 0u,
  // 1.1 & 2.1: Biased ZDF solver in u, NFB linearity, C^2 soft-knee tube curve, dual-stage sag
  kPowerStageZdfAndTube = 1u << 0,
  // 1.2: Exact IEEE-754 std::tanh in WaveNet & NAMCore instead of global fast_tanh
  kExactWaveNetTanh     = 1u << 1,
  // 1.3: Allow PolyphaseModel for condition_dsp (A2-max) & multi-tap head in True OS
  kPolyphaseCondition   = 1u << 2,
  // 1.4: Auto inter-stage ultrasonic band-limiting before oversampled NAM models + Nyquist clamp
  kInterStageBandLimit  = 1u << 3,
  // 1.5 & 3.1: Native 48 kHz True-oversampling base rate (eliminates 2x double-OS at 48 kHz)
  kNativeTrueBaseRate   = 1u << 4,

  kAllProposed          = kPowerStageZdfAndTube |
                          kExactWaveNetTanh |
                          kPolyphaseCondition |
                          kInterStageBandLimit |
                          kNativeTrueBaseRate
};

inline std::atomic<uint32_t>& flagsStorage() noexcept {
  static std::atomic<uint32_t> flags{kNone};
  return flags;
}

inline uint32_t flags() noexcept {
  return flagsStorage().load(std::memory_order_relaxed);
}

inline bool has(uint32_t mask) noexcept {
  return (flags() & mask) == mask;
}

inline bool anyProposed() noexcept {
  return (flags() & kAllProposed) != 0u;
}

inline bool allProposed() noexcept {
  return (flags() & kAllProposed) == kAllProposed;
}

inline void syncBackends(uint32_t currentFlags) noexcept {
  const bool exactTanh = (currentFlags & kExactWaveNetTanh) != 0u;
  const bool polyCondition = (currentFlags & kPolyphaseCondition) != 0u;
  NeuralAudio::UseExactTanhFlag().store(exactTanh, std::memory_order_relaxed);
  NeuralAudio::UsePolyphaseConditionDspFlag().store(polyCondition,
                                                    std::memory_order_relaxed);
}

inline void setFlags(uint32_t newFlags) noexcept {
  const uint32_t sanitized = newFlags & kAllProposed;
  flagsStorage().store(sanitized, std::memory_order_relaxed);
  syncBackends(sanitized);
}

inline void setProposed(bool enabled) noexcept {
  setFlags(enabled ? kAllProposed : kNone);
}

inline void toggleFlag(uint32_t flag) noexcept {
  setFlags(flags() ^ (flag & kAllProposed));
}

}  // namespace AuditMode
}  // namespace NAMRig
