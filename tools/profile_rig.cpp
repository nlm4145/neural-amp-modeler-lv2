// Offline preset profiler. Built only via profile_rig.py's temporary DSP copy.
#include "nam_rig_plugin.h"
#include "polyphase_worker.h"
#include "rig_control_metadata.h"
#include "rig_knobs.h"
#include "win32_control_defaults.h"
#include "rig_profile.h"
#include "architecture.hpp"

#include <NeuralAudio/CompositeModel.h>
#include <NeuralAudio/PolyphaseModel.h>
#include <json.hpp>
#include <lv2/atom/util.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <algorithm>
#include <array>
#include <cfenv>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using namespace NAMRig;
using json = nlohmann::json;
constexpr double kRate = 96000;
constexpr size_t kFrames = 128, kAtoms = 16384;
void require(bool ok, const char* text) { if (!ok) throw std::runtime_error(text); }
json load(const std::string& path) {
  std::ifstream file(path);
  require(file.good(), "preset/model file unavailable");
  json result; file >> result; return result;
}
double cpuSeconds() {
  rusage value{}; getrusage(RUSAGE_SELF, &value);
  return value.ru_utime.tv_sec + value.ru_stime.tv_sec +
      1.0e-6 * (value.ru_utime.tv_usec + value.ru_stime.tv_usec);
}

struct Host {
  std::vector<std::string> ids;
  std::deque<std::vector<uint8_t>> jobs;
  std::deque<LV2SwitchModelMsg> replies;
  LV2_URID_Map map{this, mapUri};
  LV2_Worker_Schedule schedule{this, scheduleWork};
  alignas(8) std::array<uint8_t, kAtoms> control{}, notify{};
  std::array<float, kFrames> input{}, left{}, right{};
  std::array<float, Plugin::kPortCount> controls{};
  PolyphaseWorker pool;
  Plugin plugin;
  uint32_t block;
  size_t position = 0;
  double ticksPerFrame;
  static LV2_URID mapUri(LV2_URID_Map_Handle handle, const char* uri) {
    auto& ids = static_cast<Host*>(handle)->ids;
    const auto found = std::find(ids.begin(), ids.end(), uri);
    if (found != ids.end()) return static_cast<LV2_URID>(found - ids.begin() + 1);
    ids.emplace_back(uri); return static_cast<LV2_URID>(ids.size());
  }
  static LV2_Worker_Status scheduleWork(LV2_Worker_Schedule_Handle handle, uint32_t size, const void* data) {
    const auto* bytes = static_cast<const uint8_t*>(data);
    static_cast<Host*>(handle)->jobs.emplace_back(bytes, bytes + size);
    return LV2_WORKER_SUCCESS;
  }
  static LV2_Worker_Status respond(LV2_Worker_Respond_Handle handle, uint32_t size, const void* data) {
    require(size == sizeof(LV2SwitchModelMsg), "switch response size");
    static_cast<Host*>(handle)->replies.push_back(*static_cast<const LV2SwitchModelMsg*>(data));
    return LV2_WORKER_SUCCESS;
  }
  void drain() {
    unsigned attempts = 0;
    while (!jobs.empty() || !replies.empty()) {
      require(++attempts < 100, "worker reload loop");
      while (!jobs.empty()) {
        auto bytes = std::move(jobs.front()); jobs.pop_front();
        require(Plugin::work(&plugin, respond, this, static_cast<uint32_t>(bytes.size()), bytes.data()) ==
                    LV2_WORKER_SUCCESS, "load/free failed");
      }
      while (!replies.empty()) {
        const auto reply = replies.front(); replies.pop_front();
        require(Plugin::workResponse(&plugin, sizeof(reply), &reply) == LV2_WORKER_SUCCESS, "model response failed");
      }
    }
  }
  Host(const json& preset, uint32_t frames, size_t helpers, const std::string& variant) : block(frames) {
    NAMRigWin32::forEachWin32ControlDefault([&](uint32_t port, float value) { controls[port] = value; });
    for (size_t i = 0; i < kRigKnobCount; ++i) controls[kRigKnobPorts[i]] = kRigKnobDefaults[i];
    auto pins = pinEqDefaults(); std::copy(pins.begin(), pins.end(), controls.begin() + kPinEqFirstPort);
    if (preset.contains("ports"))
      for (const auto& item : preset["ports"].items()) {
        const auto port = std::stoul(item.key());
        if (port < controls.size()) controls[port] = item.value().get<float>();
      }
    std::map<std::string, uint32_t> symbols;
    forEachRigControlSymbol([&](uint32_t port, const char* name) { symbols[name] = port; });
    if (preset.contains("params"))
      for (const auto& item : preset["params"].items())
        if (symbols.count(item.key())) controls[symbols[item.key()]] = item.value().get<float>();
    const auto& stages = preset["stages"];
    for (size_t i = 0; i < kStageCount; ++i)
      controls[i < 3 ? 7 + i : 47] = stages[i].value("enabled", i < 3) ? 1 : 0;
    controls[20] = stages[0].value("oversample", 6.0f);
    controls[21] = stages[1].value("oversample", 6.0f);
    controls[30] = stages[1].value("transformer", 0.0f);
    controls[4] = 0; // Native preset recall forces input trim to zero.
    controls[16] = 0; // Tuner is host-owned, not part of these saved presets.
    if (variant == "no-fx") { controls[33] = controls[54] = controls[53] = 0; }
    if (variant == "no-boost") controls[kOverdriveEnabledPort] = 0;
    if (variant == "no-cab-b") controls[47] = 0;
    if (variant == "no-compressor") controls[kCompressorEnabledPort] = 0;
    if (variant == "amp-one-step-lower") controls[21] = std::max(4.0f, controls[21] - 1);
    // Full quality is forced by Plugin::work, never modified by the profiler.
    for (uint32_t port = 0; port < Plugin::kPortCount; ++port) {
      void* value = port == 0 ? static_cast<void*>(control.data()) : port == 1 ? notify.data() :
          port == 2 ? static_cast<void*>(input.data()) : port == 3 ? left.data() :
          port == 31 ? static_cast<void*>(right.data()) : &controls[port];
      *(reinterpret_cast<void**>(&plugin.ports) + port) = value;
    }
    LV2_Feature mf{LV2_URID__map, &map}, wf{LV2_WORKER__schedule, &schedule};
    const LV2_Feature* features[] = {&mf, &wf, nullptr};
    require(plugin.initialize(kRate, features), "initialize rig");
    plugin.setMaxBufferSize(frames);
    if (variant == "nam-core")
      for (auto& loader : plugin.loaders) loader.SetWaveNetLoadMode(NeuralAudio::EModelLoadMode::NAMCore);
    mach_timebase_info_data_t tb{}; mach_timebase_info(&tb);
    ticksPerFrame = 1.0e9 * tb.denom / (tb.numer * kRate);
    if (helpers) {
      require(pool.start(nullptr, frames / kRate, helpers), "start offline phase helpers");
      plugin.setPolyphaseWorker(&pool);
    }
    run(); drain(); // Latch modes and enables before load requests.
    LV2_Atom_Forge forge{}; lv2_atom_forge_init(&forge, &map);
    lv2_atom_forge_set_buffer(&forge, control.data(), control.size());
    LV2_Atom_Forge_Frame sequence{}; lv2_atom_forge_sequence_head(&forge, &sequence, 0);
    const std::array<const char*, 4> stageUris{NAM_RIG_PEDAL_URI, NAM_RIG_AMP_URI, NAM_RIG_CAB_URI, NAM_RIG_CAB2_URI};
    for (size_t i = 0; i < kStageCount; ++i) {
      const auto path = stages[i].value("path", std::string{});
      if (path.empty() || controls[i < 3 ? 7 + i : 47] < 0.5f) continue;
      require(std::filesystem::exists(path), "active model missing");
      LV2_Atom_Forge_Frame object{};
      lv2_atom_forge_frame_time(&forge, 0);
      lv2_atom_forge_object(&forge, &object, 0, mapUri(this, LV2_PATCH__Set));
      lv2_atom_forge_key(&forge, mapUri(this, LV2_PATCH__property));
      lv2_atom_forge_urid(&forge, mapUri(this, stageUris[i]));
      lv2_atom_forge_key(&forge, mapUri(this, LV2_PATCH__value));
      lv2_atom_forge_path(&forge, path.c_str(), static_cast<uint32_t>(path.size() + 1));
      lv2_atom_forge_pop(&forge, &object);
    }
    lv2_atom_forge_pop(&forge, &sequence);
    run(false); drain();
    // Settle >1 sec of actual audio so gate, IR and wet tails reach steady state.
    for (unsigned i = 0; i < static_cast<unsigned>(kRate / frames) + 32; ++i) { run(); drain(); }
    for (size_t i = 0; i < kStageCount; ++i)
      if (controls[i < 3 ? 7 + i : 47] >= 0.5f && !stages[i].value("path", std::string{}).empty())
        require(plugin.models[i] || plugin.irs[i], "model failed to load; refusing dry benchmark");
  }
  ~Host() { plugin.setPolyphaseWorker(nullptr); pool.stop(); drain(); }
  void run(bool clear = true) {
    if (clear) {
      auto* seq = reinterpret_cast<LV2_Atom_Sequence*>(control.data());
      seq->atom.type = mapUri(this, LV2_ATOM__Sequence);
      seq->atom.size = sizeof(LV2_Atom_Sequence_Body); seq->body = {};
    }
    reinterpret_cast<LV2_Atom_Sequence*>(notify.data())->atom.size = kAtoms - sizeof(LV2_Atom);
    for (uint32_t i = 0; i < block; ++i) {
      const double t = static_cast<double>(position++) / kRate;
      // Continuous low guitar + picking harmonics, safely above each gate.
      input[i] = static_cast<float>(0.25 * std::sin(6.283185307179586 * 82.4 * t) +
          0.15 * std::sin(6.283185307179586 * 659 * t) + 0.08 * std::sin(6.283185307179586 * 3100 * t));
    }
    plugin.process(block, mach_absolute_time() + static_cast<uint64_t>(block * ticksPerFrame * 0.9));
  }
};

void modelInfo(Host& host) {
  auto* model = host.plugin.models[1];
  auto* current = model;
  while (auto* composite = dynamic_cast<NeuralAudio::CompositeModel*>(current)) current = composite->GetCurrentModel();
  auto* poly = dynamic_cast<NeuralAudio::PolyphaseModel*>(current);
  std::printf("ENGINE amp load=%d static=%d phases=%zu quality=%.1f model_rate=%.0f latency=%.0f\n",
              static_cast<int>(model->GetLoadMode()), model->IsStatic(), poly ? poly->GetNumPhases() : 0,
              model->GetQualityScaleFactor(), model->GetSampleRate(), host.controls[29]);
}

void measure(const json& preset, const std::string& name, uint32_t block, size_t helpers,
             const std::string& variant, unsigned blocks) {
  Host host(preset, block, helpers, variant);
  if ((variant == "full" || variant == "nam-core") && helpers == 3) modelInfo(host);
  std::vector<double> times; times.reserve(blocks);
  RigProfile::microseconds.fill(0); RigProfile::enabled = true;
  const double cpuBegin = cpuSeconds();
  uint64_t hash = 1469598103934665603ull;
  double energy = 0;
  for (unsigned i = 0; i < blocks; ++i) {
    const auto begin = std::chrono::steady_clock::now();
    host.run();
    const auto end = std::chrono::steady_clock::now();
    times.push_back(std::chrono::duration<double, std::micro>(end - begin).count());
    for (uint32_t s = 0; s < block; ++s) {
      require(std::isfinite(host.left[s]) && std::isfinite(host.right[s]), "nonfinite profile output");
      uint32_t bits; std::memcpy(&bits, &host.left[s], sizeof(bits)); hash = (hash ^ bits) * 1099511628211ull;
      energy += static_cast<double>(host.left[s]) * host.left[s];
    }
  }
  const double cpu = cpuSeconds() - cpuBegin;
  RigProfile::enabled = false;
  require(host.jobs.empty() && energy > 1.0e-8, "profile steady state with non-silent output");
  std::sort(times.begin(), times.end());
  const double total = RigProfile::microseconds[RigProfile::Total] / blocks;
  std::printf("RESULT %s block=%u helpers=%zu variant=%s mean=%.2f median=%.2f p95=%.2f budget%%=%.1f process_cpu_ms/s=%.1f hash=%016llx\n",
              name.c_str(), block, helpers, variant.c_str(), total, times[times.size()/2],
              times[static_cast<size_t>(times.size() * .95)], total * kRate / block / 1e4,
              cpu * 1e3 / (blocks * block / kRate), static_cast<unsigned long long>(hash));
  if (variant == "full" && helpers == 3) {
    constexpr std::array<const char*, RigProfile::Count> names{"total", "pedal", "amp", "cab-a-nam", "cab-b-nam",
        "converters", "IR", "boost", "sculpt", "power", "transformer", "speaker", "pins", "compressor", "effects"};
    double explained = 0;
    for (size_t i = 1; i < RigProfile::Count; ++i) {
      const double time = RigProfile::microseconds[i] / blocks;
      explained += time;
      if (time > .01) std::printf("COST %s block=%u %s us=%.2f share=%.1f%%\n", name.c_str(), block, names[i], time, time * 100 / total);
    }
    std::printf("COST %s block=%u remaining us=%.2f\n", name.c_str(), block, total - explained);
  }
}
}

int main(int argc, char** argv) {
  try {
    unsigned blocks = 300;
    std::vector<std::string> paths;
    for (int i = 1; i < argc; ++i)
      if (std::strcmp(argv[i], "--blocks") == 0 && i + 1 < argc) blocks = std::stoul(argv[++i]);
      else paths.emplace_back(argv[i]);
    require(!paths.empty() && blocks >= 20, "supply presets and at least 20 blocks");
    disable_denormals();
    for (const auto& path : paths) {
      const auto preset = load(path);
      const auto name = std::filesystem::path(path).stem().string();
      for (uint32_t block : {32u, 64u, 128u}) {
        for (size_t helpers : {size_t{3}, size_t{1}, size_t{0}}) measure(preset, name, block, helpers, "full", blocks);
        for (const auto& variant : {"no-fx", "no-boost", "no-cab-b", "no-compressor", "amp-one-step-lower", "nam-core"})
          measure(preset, name, block, 3, variant, blocks);
      }
    }
  } catch (const std::exception& error) { std::fprintf(stderr, "FAIL: %s\n", error.what()); return 1; }
}
