#include "standalone_controls.h"

#include <array>
#include <cstdio>
#include <cstdlib>

using namespace NAMRig;

int main() {
  // The flat Windows array and segmented macOS arrays must bind identical port
  // indices without changing values or touching Atom/audio connections.
  std::array<float, Plugin::kPortCount> flat;
  for (size_t i = 0; i < flat.size(); ++i) flat[i] = static_cast<float>(i) + 0.25f;
  const auto original = flat;
  std::array<float, 27> base{};
  std::array<float, 2> stereo{}, tube{};
  std::array<float, 8> advanced{};
  std::array<float, 5> speaker{};
  std::array<float, 13> fx{};
  TransformerAdjustments transformer{};
  std::array<float, kRackCount> racks{};
  std::array<float, kPinEqPortCount> pins{};
  std::array<float, 3> overdrive{};
  std::array<float, 3> compressor{};
  std::array<float, 4> postCompressor{};
  float mid = 0, od_enabled = 0, od_tight = 0;
  Plugin::Ports segmented{}, indexed{};
  unsigned char sentinel = 0;
  const auto seed = [&](Plugin::Ports& ports) {
    for (size_t p : {size_t{0}, size_t{1}, size_t{2}, size_t{3}, size_t{31}}) {
      void* ptr = &sentinel;
      std::memcpy(reinterpret_cast<unsigned char*>(&ports) + p * sizeof(void*), &ptr, sizeof(ptr));
    }
  };
  seed(segmented);
  seed(indexed);
  bindStandaloneControls(segmented, {
      {4, base}, {32, stereo}, {34, advanced}, {42, speaker}, {47, fx},
      {kTransformerControlFirstPort, transformer}, {kRackControlFirstPort, racks},
      {kPowerTubeTypePort, tube}, {kMidPushPort, {&mid, 1}},
      {kPinEqFirstPort, pins}, {kOverdriveDrivePort, overdrive},
      {kCompressorAttackPort, compressor},
      {kOverdriveEnabledPort, {&od_enabled, 1}},
      {kPostCompressorFirstPort, postCompressor},
      {kOverdriveTightPort, {&od_tight, 1}}});
  const std::span<float> values(flat);
  bindStandaloneControls(indexed, {{4, values.subspan(4, 27)}, {32, values.subspan(32)}});
  for (uint32_t p = 0; p < Plugin::kPortCount; ++p) {
    void* a = nullptr;
    void* b = nullptr;
    std::memcpy(&a, reinterpret_cast<unsigned char*>(&segmented) + p * sizeof(void*), sizeof(a));
    std::memcpy(&b, reinterpret_cast<unsigned char*>(&indexed) + p * sizeof(void*), sizeof(b));
    if (p < 4 || p == 31) {
      if (a != &sentinel || b != &sentinel) std::abort();
    } else {
      if (!a || b != &flat[p] || flat[p] != original[p]) std::abort();
      *static_cast<float*>(a) = flat[p];
    }
  }
  if (base[0] != flat[4] || base.back() != flat[30] || stereo[0] != flat[32] ||
      advanced.back() != flat[41] || speaker.back() != flat[46] || fx.back() != flat[59] ||
      transformer.back() != flat[70] || racks.back() != flat[79] || tube.back() != flat[81] ||
      mid != flat[82] || pins.back() != flat[178] || overdrive.back() != flat[181] ||
      compressor.back() != flat[184] || od_enabled != flat[185] ||
      postCompressor.back() != flat[189] || od_tight != flat[190]) std::abort();
  // Exercise the Windows pin override instead of its flat-array backing.
  bindStandaloneControls(indexed, {{kPinEqFirstPort, pins}});
  for (size_t i = 0; i < pins.size(); ++i)
    if (indexed.pin_eq[i] != &pins[i]) std::abort();
  std::puts("PASS standalone port binding: flat/segmented layouts, values and non-controls preserved");
}
