#import "rig_riff_renderer.h"
#include "nam_rig_plugin.h"
#include "standalone_controls.h"
#include "rig_control_metadata.h"
#include <lv2/atom/util.h>
#include <algorithm>
#include <deque>
#include <memory>
#include <stdexcept>

namespace {
struct OfflineHost {
  NAMRig::Plugin engine;
  std::deque<std::string> uris;
  std::deque<std::vector<uint8_t>> jobs;
  LV2_URID_Map map{this, mapURI};
  LV2_Worker_Schedule schedule{this, scheduleWork};
  std::array<float, NAMRig::Plugin::kPortCount> controls{};
  std::array<float, 256> input{}, left{}, right{};
  alignas(LV2_Atom_Sequence) std::array<uint8_t, 16384> control{}, notify{};

  static LV2_URID mapURI(LV2_URID_Map_Handle handle, const char* uri) {
    auto& u = static_cast<OfflineHost*>(handle)->uris;
    auto it = std::find(u.begin(), u.end(), uri);
    if (it != u.end()) return static_cast<LV2_URID>(it - u.begin() + 1);
    u.emplace_back(uri); return static_cast<LV2_URID>(u.size());
  }
  static LV2_Worker_Status scheduleWork(LV2_Worker_Schedule_Handle handle, uint32_t n, const void* data) {
    auto& jobs = static_cast<OfflineHost*>(handle)->jobs;
    auto* b = static_cast<const uint8_t*>(data); jobs.emplace_back(b, b + n); return LV2_WORKER_SUCCESS;
  }
  static LV2_Worker_Status respond(LV2_Worker_Respond_Handle handle, uint32_t n, const void* data) {
    auto& host = *static_cast<OfflineHost*>(handle);
    return NAMRig::Plugin::workResponse(&host.engine, n, data);
  }
  void drain() {
    size_t count = 0;
    while (!jobs.empty()) {
      if (++count > 64) throw std::runtime_error("Offline model loading did not settle.");
      auto job = std::move(jobs.front()); jobs.pop_front();
      if (NAMRig::Plugin::work(&engine, respond, this, static_cast<uint32_t>(job.size()), job.data()) != LV2_WORKER_SUCCESS)
        throw std::runtime_error("Offline model worker failed.");
    }
  }
  OfflineHost(RigPreset* preset, double rate) {
    for (const auto& c : NAMRig::kRigControlContracts) controls[c.port] = c.defaultValue;
    for (const auto& kv : preset.allControls) if (kv.first < controls.size()) controls[kv.first] = kv.second;
    controls[16] = 0; // Do not run tuner during offline evaluation.
    LV2_Feature mf{LV2_URID__map, &map}, sf{LV2_WORKER__schedule, &schedule};
    const LV2_Feature* features[] = {&mf, &sf, nullptr};
    if (!engine.initialize(rate, features)) throw std::runtime_error("Offline engine initialization failed.");
    engine.setMaxBufferSize(256);
    NAMRig::bindStandaloneControls(engine.ports, {{4, {controls.data() + 4, 27}},
        {32, {controls.data() + 32, controls.size() - 32}}});
    engine.ports.audio_in = input.data(); engine.ports.audio_out = left.data(); engine.ports.audio_out_r = right.data();
    engine.ports.control = reinterpret_cast<LV2_Atom_Sequence*>(control.data());
    engine.ports.notify = reinterpret_cast<LV2_Atom_Sequence*>(notify.data());
    run(256); // Latch modes and cabinet routing before creating any models.
    for (size_t stage = 0; stage < NAMRig::kStageCount; ++stage) {
      const auto* s = [preset stageAtIndex:stage];
      if (!s || s->path.empty()) continue;
      if (s->path.size() >= NAMRig::MAX_FILE_NAME) throw std::runtime_error("Model path is too long.");
      int mode = stage == 3 || (stage == 2 && controls[47] >= .5f) ? NAMRig::kOversampleLegacy :
          static_cast<int>(controls[stage == 0 ? 20 : 21]);
      NAMRig::LV2LoadModelMsg message{NAMRig::kWorkTypeLoad, static_cast<NAMRig::Stage>(stage), mode, 0, {}};
      std::memcpy(message.path, s->path.c_str(), s->path.size() + 1);
      NAMRig::Plugin::work(&engine, respond, this, sizeof(message), &message);
      drain();
    }
    // Allow fades, trim smoothing, and model swaps to complete using silence.
    for (size_t i = 0; i < static_cast<size_t>(rate / 256) + 1; ++i) run(256);
    for (size_t stage = 0; stage < NAMRig::kStageCount; ++stage) {
      const auto* s = [preset stageAtIndex:stage];
      if (s && !s->path.empty() && engine.modelPaths[stage] != s->path)
        throw std::runtime_error("A preset model could not be loaded for offline evaluation.");
    }
  }
  ~OfflineHost() { try { drain(); } catch (...) {} }
  void run(uint32_t frames) {
    auto* seq = reinterpret_cast<LV2_Atom_Sequence*>(control.data());
    seq->atom.type = mapURI(this, LV2_ATOM__Sequence); seq->atom.size = sizeof(LV2_Atom_Sequence_Body);
    reinterpret_cast<LV2_Atom_Sequence*>(notify.data())->atom.size = notify.size() - sizeof(LV2_Atom);
    engine.process(frames); drain();
  }
};
}

NSData* rigRenderDI(RigPreset* preset, NSData* di, double rate, NSError** error) {
  try {
    if (!preset || !di.length || di.length % sizeof(float) || !std::isfinite(rate) || rate < 22050 || rate > 192000 || di.length / sizeof(float) > rate * 20)
      throw std::runtime_error("Invalid DI recording.");
    OfflineHost host(preset, rate);
    size_t n = di.length / sizeof(float), latency = static_cast<size_t>(std::max(0.f, host.controls[29]));
    size_t total = n + static_cast<size_t>(rate * 2) + latency;
    const auto* samples = static_cast<const float*>(di.bytes);
    std::vector<float> output(total * 2);
    for (size_t pos = 0; pos < total;) {
      uint32_t count = static_cast<uint32_t>(std::min<size_t>(256, total - pos));
      for (uint32_t f = 0; f < count; ++f) {
        float x = pos + f < n ? samples[pos + f] : 0;
        if (!std::isfinite(x)) throw std::runtime_error("DI contains non-finite samples.");
        host.input[f] = x;
      }
      host.run(count);
      for (uint32_t f = 0; f < count; ++f) {
        if (!std::isfinite(host.left[f]) || !std::isfinite(host.right[f])) throw std::runtime_error("Candidate produced non-finite audio.");
        output[(pos + f) * 2] = host.left[f]; output[(pos + f) * 2 + 1] = host.right[f];
      }
      pos += count;
    }
    return [NSData dataWithBytes:output.data() + latency * 2 length:(total - latency) * 2 * sizeof(float)];
  } catch (const std::exception& e) {
    if (error) *error = [NSError errorWithDomain:@"RigRiffRenderer" code:-1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithUTF8String:e.what()]}];
    return nil;
  }
}
