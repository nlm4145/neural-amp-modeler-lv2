#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>

#include "fx_controls.h"

namespace NAMRig {

// Control sources for the four modifier slots: LFO shapes, the input envelope,
// two fixed step sequencers and the expression pedals. Sources advance once per
// processing sub-block; the plugin applies them as offsets to the targeted
// control before the DSP reads it.
//
// Unit interval conventions (see fx_controls.h "Modifier N Depth"):
//   LFO shapes return a value in [-0.5, 0.5], so full depth sweeps the whole
//   range centred on the knob. Envelope, sequencer and expression return
//   [0, 1], so full depth moves the knob up to the top of its range.
class ModifierEngine {
 public:
  enum Source {
    kOff = 0, kLfoSine, kLfoTriangle, kLfoSquare, kLfoSawUp, kLfoSawDown,
    kLfoRandom, kEnvelope, kSequencer4, kSequencer8, kExpression1, kExpression2,
    kSourceCount
  };
  static_assert(kSourceCount == kModSourceCount);

  void initialize(double rate) {
    rate_ = rate > 0.0 ? rate : 48000.0;
    envAttack_ = 1.0f - std::exp(-1.0f / static_cast<float>(rate_ * 0.005));
    envRelease_ = 1.0f - std::exp(-1.0f / static_cast<float>(rate_ * 0.150));
    reset();
  }

  void reset() {
    for (auto& slot : slots_) slot = SlotState{};
    envelope_ = 0.0f;
    expr_ = {0.0f, 0.0f};
  }

  // One call per sub-block, before the targets are refreshed.
  void advance(size_t count, float inputPeak, float expr1, float expr2,
               const std::array<float, kModifierCount>& ratesHz,
               const std::array<int, kModifierCount>& sources) {
    const float peak = std::isfinite(inputPeak) ? std::fabs(inputPeak) : 0.0f;
    // Block-rate envelope: attack/release coefficients are per sample, so
    // raise them to the block length.
    const float attack = 1.0f - std::pow(1.0f - envAttack_, static_cast<float>(count));
    const float release = 1.0f - std::pow(1.0f - envRelease_, static_cast<float>(count));
    envelope_ += (peak - envelope_) * (peak > envelope_ ? attack : release);
    expr_[0] = clamp01(expr1);
    expr_[1] = clamp01(expr2);
    for (size_t s = 0; s < kModifierCount; ++s) {
      auto& slot = slots_[s];
      const int source = sources[s];
      const float rate = std::isfinite(ratesHz[s])
          ? std::clamp(ratesHz[s], 0.01f, 40.0f) : 1.0f;
      if (source == kOff) {
        slot.phase = 0.0;
        slot.random = 0.0f;
        continue;
      }
      const double step = static_cast<double>(rate) * count / rate_;
      slot.phase += step;
      if (slot.phase >= 1.0) {
        slot.phase -= std::floor(slot.phase);
        slot.random = nextRandom(slot.seed);
        slot.sequenceStep = (slot.sequenceStep + 1) % 8;
      }
    }
  }

  float value(size_t slot, int source) const {
    if (slot >= kModifierCount) return 0.0f;
    const auto& st = slots_[slot];
    const float phase = static_cast<float>(st.phase);
    switch (source) {
      case kLfoSine: return 0.5f * std::sin(2.0f * kPi * phase);
      case kLfoTriangle: return phase < 0.5f ? 2.0f * phase - 0.5f : 1.5f - 2.0f * phase;
      case kLfoSquare: return phase < 0.5f ? 0.5f : -0.5f;
      case kLfoSawUp: return phase - 0.5f;
      case kLfoSawDown: return 0.5f - phase;
      case kLfoRandom: return st.random - 0.5f;
      case kEnvelope: {
        const float db = envelope_ > 1.0e-6f ? 20.0f * std::log10(envelope_) : -120.0f;
        return clamp01((db + 40.0f) / 40.0f);
      }
      case kSequencer4: return kSequence4[st.sequenceStep % 4];
      case kSequencer8: return kSequence8[st.sequenceStep % 8];
      case kExpression1: return expr_[0];
      case kExpression2: return expr_[1];
      default: return 0.0f;
    }
  }

  float envelope() const { return envelope_; }

 private:
  static constexpr float kPi = 3.14159265358979323846f;
  static constexpr float kSequence4[4] = {0.0f, 0.333333f, 0.666667f, 1.0f};
  static constexpr float kSequence8[8] = {0.0f, 1.0f, 0.5f, 0.75f, 0.25f, 1.0f, 0.5f, 0.0f};

  struct SlotState {
    double phase = 0.0;
    float random = 0.5f;
    uint32_t seed = 0x2545F491u;
    int sequenceStep = 0;
  };

  static float clamp01(float x) {
    return std::isfinite(x) ? std::max(0.0f, std::min(1.0f, x)) : 0.0f;
  }
  static float nextRandom(uint32_t& seed) {
    seed ^= seed << 13;
    seed ^= seed >> 17;
    seed ^= seed << 5;
    return static_cast<float>(seed & 0xFFFFFFu) / static_cast<float>(0x1000000u);
  }

  double rate_ = 48000.0;
  float envAttack_ = 0.01f, envRelease_ = 0.001f;
  float envelope_ = 0.0f;
  std::array<float, 2> expr_{};
  std::array<SlotState, kModifierCount> slots_{};
};

} // namespace NAMRig
