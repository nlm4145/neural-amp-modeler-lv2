#pragma once

#include <cassert>
#include <cstring>
#include <initializer_list>
#include <span>

#include "nam_rig_plugin.h"

namespace NAMRig {

struct ControlPortRange {
  uint32_t first;
  std::span<float> values;
};

// Initialization only. Hosts retain their storage and defaults; audio and Atom
// ports are connected separately. Ports' positional layout is asserted by Plugin.
inline void bindStandaloneControls(Plugin::Ports& ports,
                                   std::initializer_list<ControlPortRange> ranges) {
  for (const auto& range : ranges) {
    assert(range.first >= 4 && range.first <= Plugin::kPortCount);
    assert(range.values.size() <= Plugin::kPortCount - range.first);
    assert(range.first > 31 || range.first + range.values.size() <= 31);
    for (size_t i = 0; i < range.values.size(); ++i) {
      float* value = &range.values[i];
      std::memcpy(reinterpret_cast<unsigned char*>(&ports) +
                      (range.first + i) * sizeof(void*), &value, sizeof(value));
    }
  }
}

} // namespace NAMRig
