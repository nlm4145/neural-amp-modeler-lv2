#pragma once

#include <array>
#include <cstddef>
#include <vector>

namespace NAMRig {

template <size_t MaxPhases>
std::array<size_t, MaxPhases> deinterleavePhases(
    const float* input, size_t count, size_t factor,
    std::array<std::vector<float>, MaxPhases>& lanes,
    size_t startingPhase = 0) noexcept {
  std::array<size_t, MaxPhases> lengths{};
  for (size_t i = 0; i < count; ++i) {
    const size_t phase = (startingPhase + i) % factor;
    lanes[phase][lengths[phase]++] = input[i];
  }
  return lengths;
}

template <size_t MaxPhases>
void interleavePhases(
    const std::array<std::vector<float>, MaxPhases>& lanes, float* output,
    size_t count, size_t factor, size_t startingPhase = 0) noexcept {
  std::array<size_t, MaxPhases> positions{};
  for (size_t i = 0; i < count; ++i) {
    const size_t phase = (startingPhase + i) % factor;
    output[i] = lanes[phase][positions[phase]++];
  }
}

}  // namespace NAMRig
