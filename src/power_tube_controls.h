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
inline constexpr uint32_t kRigControlPortCount = 83;

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
