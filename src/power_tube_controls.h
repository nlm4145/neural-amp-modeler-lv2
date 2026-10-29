#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace NAMRig {

inline constexpr uint32_t kPowerTubeTypePort = 80;
inline constexpr uint32_t kPowerTubeCharacterPort = 81;
inline constexpr float kPowerTubeCharacterDefault = 50.0f;
// Pre-Amp Tonal Sculpt mid push (0..100%), appended after the tube controls.
inline constexpr uint32_t kMidPushPort = 82;
// Pin EQ bands for the Sculpt/Transformer/Cab Console graphs (see pin_eq.h).
inline constexpr uint32_t kPinEqFirstPort = 83;
inline constexpr uint32_t kPinEqPortCount = 96;
// Pre-Amp Tonal Sculpt overdrive (see overdrive.h), appended after the pins.
inline constexpr uint32_t kOverdriveDrivePort = 179;
inline constexpr uint32_t kOverdriveTonePort = 180;
inline constexpr uint32_t kOverdriveLevelPort = 181;
// Pre-Amp Compressor attack, release, and bypass controls.
inline constexpr uint32_t kCompressorAttackPort = 182;
inline constexpr uint32_t kCompressorReleasePort = 183;
inline constexpr uint32_t kCompressorEnabledPort = 184;
inline constexpr float kCompressorAttackDefault = 8.0f;     // ms
inline constexpr float kCompressorReleaseDefault = 120.0f;  // ms
// Pre-Amp Boost (Overdrive) bypass control.
inline constexpr uint32_t kOverdriveEnabledPort = 185;
// Independent Post-FX Studio stereo compressor (append-only).
inline constexpr uint32_t kPostCompressorAmountPort = 186;
inline constexpr uint32_t kPostCompressorAttackPort = 187;
inline constexpr uint32_t kPostCompressorReleasePort = 188;
inline constexpr uint32_t kPostCompressorEnabledPort = 189;
inline constexpr uint32_t kPostCompressorFirstPort = kPostCompressorAmountPort;
inline constexpr std::array<float, 4> kPostCompressorDefaults = {0.0f, 8.0f, 120.0f, 1.0f};
// Pre-Amp Overdrive tight high-pass cutoff frequency (100..1500 Hz, default 720 Hz).
inline constexpr uint32_t kOverdriveTightPort = 190;
inline constexpr float kOverdriveTightDefault = 720.0f;  // Hz
inline constexpr float kOverdriveTightMin = 100.0f;     // Hz
inline constexpr float kOverdriveTightMax = 1500.0f;    // Hz
// Pre-Amp Overdrive voicing / diode selector:
// 0 = Classic TS (symmetric silicon), 1 = SD-1 (asymmetric silicon),
// 2 = LED Turbo (high headroom red LEDs), 3 = Germanium (vintage soft compression),
// 4 = Clean / No Diodes (linear boost with tone shaping).
inline constexpr uint32_t kOverdriveVoicingPort = 191;
inline constexpr float kOverdriveVoicingDefault = 0.0f;
inline constexpr float kOverdriveVoicingMin = 0.0f;
inline constexpr float kOverdriveVoicingMax = 4.0f;
inline constexpr uint32_t kPedal2EnabledPort = 192;
inline constexpr uint32_t kPedal3EnabledPort = 193;
inline constexpr uint32_t kPedalOrderPort = 194;
inline constexpr uint32_t kRigControlPortCount = 195;

namespace PowerTube {
inline constexpr int kCaptured = 0;
inline constexpr int k6L6 = 1;
inline constexpr int kEL34 = 2;
inline constexpr int kProfileCount = 3;

inline constexpr int clampProfile(int profile) noexcept {
  return std::clamp(profile, kCaptured, kProfileCount - 1);
}

inline float clampCharacter(float character) noexcept {
  return std::isfinite(character) ? std::clamp(character, 0.0f, 100.0f)
                                 : kPowerTubeCharacterDefault;
}

struct Profile {
  const char* name;
  double knee, headroom, asymmetry, biasSensitivity;
};

// Design voicings, not measured tube models. Supply behavior belongs to Power.
inline constexpr std::array<Profile, kProfileCount> kProfiles = {{
    {"Captured/No Added Character", 0.7, 1.0, 0.0, 1.0},
    {"6L6-inspired", 0.65, 0.85, 0.015, 1.0},
    {"EL34-inspired", 0.5, 0.58, 0.035, 1.15},
}};
} // namespace PowerTube

} // namespace NAMRig
