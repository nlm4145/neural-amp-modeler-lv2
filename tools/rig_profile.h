#pragma once

#include <array>
#include <chrono>

// Offline instrumentation only: copied into a temporary source snapshot by
// profile_rig.py. Nothing here is compiled into the shipping plugin or app.
namespace RigProfile {
enum Category { Total, Pedal, Amp, CabA, CabB, Converters, IR, Boost, Sculpt,
                Power, Transformer, Speaker, Pins, Compressor, Effects, Count };
inline std::array<double, Count> microseconds{};
inline bool enabled = false;
struct Scope {
  Category category;
  bool active = enabled;
  std::chrono::steady_clock::time_point begin;
  explicit Scope(Category value) : category(value) {
    if (active) begin = std::chrono::steady_clock::now();
  }
  ~Scope() {
    if (active) microseconds[category] +=
        std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - begin).count();
  }
};
}
