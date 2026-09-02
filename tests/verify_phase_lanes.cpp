#include "phase_lanes.h"

#include <array>
#include <cmath>
#include <cstdio>
#include <vector>

int main() {
  constexpr size_t kMaxPhases = 8;
  for (size_t factor : {2u, 4u, 8u}) {
    for (size_t count : {1u, 7u, 64u, 511u, 4096u}) {
      std::vector<float> input(count), output(count, 0.0f);
      std::array<std::vector<float>, kMaxPhases> lanes;
      for (auto& lane : lanes) lane.resize(count + 1);
      for (size_t i = 0; i < count; ++i)
        input[i] = std::sin(static_cast<float>(i) * 0.071f) +
                   static_cast<float>(i) * 0.0001f;

      for (size_t startingPhase = 0; startingPhase < factor;
           ++startingPhase) {
        const auto lengths = NAMRig::deinterleavePhases(
            input.data(), count, factor, lanes, startingPhase);
        size_t total = 0;
        for (size_t phase = 0; phase < factor; ++phase) total += lengths[phase];
        if (total != count) return 1;
        NAMRig::interleavePhases(lanes, output.data(), count, factor,
                                 startingPhase);
        if (output != input) return 1;
      }
    }
  }
  std::puts("  PASS  2x/4x/8x phase lanes round-trip exactly");
  return 0;
}
