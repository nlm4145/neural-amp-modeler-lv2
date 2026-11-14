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
// Final output utilities, append-only. Ceiling 0 is exact bypass.
inline constexpr uint32_t kOutputCeilingPort = 195;
inline constexpr uint32_t kOutputBalancePort = 196;
inline constexpr uint32_t kOutputReductionPort = 197;
inline constexpr uint32_t kToneEqModePort = 198;
inline constexpr uint32_t kToneEqFirstPort = 199;
inline constexpr uint32_t kToneEqControlCount = 29;
// Pre-amp polyphonic Drop Pitch / Virtual Capo (-12..+12 semitones, 0 = bypass).
inline constexpr uint32_t kDropPitchPort = 227;
inline constexpr float kDropPitchMin = -12.0f;
inline constexpr float kDropPitchMax = 12.0f;
inline constexpr float kDropPitchDefault = 0.0f;
// Low-pass in front of each NAM model that runs above its training rate
// (0 = off, 1 = on). See model_band_limit.h.
inline constexpr uint32_t kModelBandLimitPort = 228;
inline constexpr float kModelBandLimitDefault = 0.0f;
// Drop Pitch / Virtual Capo shaping controls (0..100%), append-only.
// Neutrals (Attack 50%, Sustain 50%) preserve default behavior.
inline constexpr uint32_t kDropPitchAttackPort = 229;
inline constexpr uint32_t kDropPitchSustainPort = 230;
inline constexpr float kDropPitchAttackDefault = 50.0f;
inline constexpr float kDropPitchSustainDefault = 50.0f;
// Configurable HF Filter (Model Band-Limit) parameters, append-only.
// Bypassed bit-identically when model_band_limit (port 228) is 0.
inline constexpr uint32_t kModelBandLimitCutoffPort = 231;
inline constexpr uint32_t kModelBandLimitSlopePort = 232;
inline constexpr uint32_t kModelBandLimitRipplePort = 233;
inline constexpr float kModelBandLimitCutoffDefault = 20500.0f;
inline constexpr float kModelBandLimitSlopeDefault = 3.0f;
inline constexpr float kModelBandLimitRippleDefault = 0.05f;
// Dual-cabinet Spatial Acoustics stereo mode (append-only):
// 0 = A/B Split pan (default), 1 = Centered Blend (balanced A+B tone on L & R).
inline constexpr uint32_t kSpatialCenterBlendPort = 234;
inline constexpr float kSpatialCenterBlendDefault = 0.0f;
// Dual-cabinet Cab B Speaker Load Profile (append-only):
// 0..7 match speaker_profile (0=Captured, 1=Auto, 2=Resistive..7=Bass); 8=Match Cab A.
inline constexpr uint32_t kSpeakerProfileBPort = 235;
inline constexpr float kSpeakerProfileBDefault = 8.0f;
// Dual-cabinet blend console cut filter slopes (append-only):
// 0 = 12 dB/oct (2nd-order Butterworth, default), 1 = 18 dB/oct (3rd), 2 = 24 dB/oct (4th).
inline constexpr uint32_t kCabLowCutSlopePort = 236;
inline constexpr float kCabLowCutSlopeDefault = 0.0f;
inline constexpr uint32_t kCabHighCutSlopePort = 237;
inline constexpr float kCabHighCutSlopeDefault = 0.0f;
// Optional auto-trim of leading silence on WAV cab IRs (append-only):
// 0 = Off (preserve raw IR offset, default), 1 = On (trim leading digital silence uniformly).
inline constexpr uint32_t kCabIrAutoTrimPort = 238;
inline constexpr float kCabIrAutoTrimDefault = 0.0f;
inline constexpr uint32_t kRigControlPortCount = 239;

inline int clampDropPitch(float value) noexcept {
  if (!std::isfinite(value)) return 0;
  return std::clamp(static_cast<int>(std::lround(value)), -12, 12);
}

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
