// Small production-renderer smoke test. Minimal in-memory preset avoids AppKit/UI setup.
#import "rig_riff_renderer.h"
#include "rig_control_metadata.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <unordered_map>

@implementation RigPreset {
  std::unordered_map<uint32_t, float> _controls;
  std::array<RigStagePreset, 4> _stages;
}
- (void)setControl:(uint32_t)p value:(float)v { _controls[p] = v; }
- (const std::unordered_map<uint32_t, float>&)allControls { return _controls; }
- (RigStagePreset*)stageAtIndex:(size_t)i { return &_stages[i]; }
@end

int main(int argc, char** argv) {
  @autoreleasepool {
    RigPreset* preset = [RigPreset new];
    for (const auto& c : NAMRig::kRigControlContracts) [preset setControl:c.port value:c.defaultValue];
    for (uint32_t p : {7u, 8u, 9u, 47u, 184u, 185u, 189u}) [preset setControl:p value:0];
    [preset setControl:15 value:-120];
    std::vector<float> di(2400);
    for (size_t i = 0; i < di.size(); ++i) di[i] = .05f * std::sin(2 * M_PI * 440 * i / 48000);
    NSData* input = [NSData dataWithBytes:di.data() length:di.size() * sizeof(float)];
    NSError* error = nil;
    NSData* a = rigRenderDI(preset, input, 48000, &error);
    assert(a && !error && a.length == (2400 + 96000) * 2 * sizeof(float));
    NSData* b = rigRenderDI(preset, input, 48000, &error);
    assert([a isEqual:b]); // Same DI + preset yields deterministic output.
    float peak = 0; const auto* x = static_cast<const float*>(a.bytes);
    for (size_t i = 0; i < a.length / sizeof(float); ++i) { assert(std::isfinite(x[i])); peak = std::max(peak, std::fabs(x[i])); }
    assert(peak > .01f);
    [preset stageAtIndex:1]->path = "/missing/amp.nam";
    assert(!rigRenderDI(preset, input, 48000, &error) && error);
    if (argc > 1) {
      [preset stageAtIndex:1]->path = argv[1]; [preset setControl:8 value:1];
      error = nil; NSData* nam = rigRenderDI(preset, input, 48000, &error);
      if (!nam) std::fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
      assert(nam && !error);
    }
    std::puts("PASS production DI renderer: deterministic finite output, tail and failed-load handling");
  }
}
