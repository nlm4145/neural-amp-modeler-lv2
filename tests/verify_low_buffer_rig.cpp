// Before/after through the LV2 interface (no dependence on private Plugin layout).
// Usage: verify_low_buffer_rig <new rig .so> [baseline rig .so] [--bench]
#include "nam_rig_plugin.h"
#include "win32_control_defaults.h"

#include <dlfcn.h>
#include <lv2/atom/util.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <deque>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using namespace NAMRig;
constexpr size_t kAudio = 2048, kAtoms = 16384;
void require(bool ok, const char* label) { if (!ok) throw std::runtime_error(label); }

struct Library {
  void* handle;
  const LV2_Descriptor* descriptor;
  explicit Library(const char* path) : handle(dlopen(path, RTLD_NOW | RTLD_LOCAL)) {
    if (!handle) throw std::runtime_error(dlerror());
    auto get = reinterpret_cast<const LV2_Descriptor* (*)(uint32_t)>(dlsym(handle, "lv2_descriptor"));
    require(get && (descriptor = get(0)), "rig descriptor available");
  }
  ~Library() { dlclose(handle); }
};

struct Model final : NeuralAudio::NeuralModel {
  float inputDb = -1.0f, outputDb = 2.0f;
  int flavor = 0;
  float GetRecommendedInputDBAdjustment() override { return inputDb; }
  float GetRecommendedOutputDBAdjustment() override { return outputDb; }
  void Process(float* input, float* output, size_t count) override {
    for (size_t i = 0; i < count; ++i) output[i] = flavor == 1 ? std::tanh(input[i] * 3.0f) : flavor == 2 ? input[i] * input[i] + input[i] * 0.2f : input[i] * 0.7f;
  }
};

struct Host {
  const LV2_Descriptor* d;
  const LV2_Worker_Interface* worker;
  LV2_Handle instance;
  std::vector<std::string> uris;
  LV2_URID_Map map{this, mapUri};
  LV2_Worker_Schedule schedule{this, scheduleWork};
  std::deque<std::vector<uint8_t>> jobs;
  std::array<float, Plugin::kPortCount> controls{};
  std::array<Model*, kStageCount> models{};
  std::array<float, kAudio> input{}, left{}, right{};
  alignas(LV2_Atom_Sequence) std::array<uint8_t, kAtoms> control{}, notify{};
  double rate;
  float amplitude = 0.2f;
  size_t position = 0;
  static LV2_URID mapUri(LV2_URID_Map_Handle handle, const char* uri) {
    auto& ids = static_cast<Host*>(handle)->uris;
    const auto found = std::find(ids.begin(), ids.end(), uri);
    if (found != ids.end()) return static_cast<LV2_URID>(found - ids.begin() + 1);
    ids.emplace_back(uri);
    return static_cast<LV2_URID>(ids.size());
  }
  static LV2_Worker_Status scheduleWork(LV2_Worker_Schedule_Handle handle, uint32_t size, const void* data) {
    const auto* bytes = static_cast<const uint8_t*>(data);
    static_cast<Host*>(handle)->jobs.emplace_back(bytes, bytes + size);
    return LV2_WORKER_SUCCESS;
  }
  Host(const LV2_Descriptor* descriptor, double sampleRate, int mode) : d(descriptor), rate(sampleRate) {
    worker = static_cast<const LV2_Worker_Interface*>(d->extension_data(LV2_WORKER__interface));
    LV2_Feature mf{LV2_URID__map, &map}, wf{LV2_WORKER__schedule, &schedule};
    const LV2_Feature* features[] = {&mf, &wf, nullptr};
    instance = d->instantiate(d, rate, "", features);
    require(instance && worker, "instantiate low-buffer rig");
    NAMRigWin32::forEachWin32ControlDefault([&](uint32_t port, float value) { controls[port] = value; });
    controls[20] = controls[21] = static_cast<float>(mode);
    controls[47] = 1;
    const auto pins = pinEqDefaults();
    std::copy(pins.begin(), pins.end(), controls.begin() + kPinEqFirstPort);
    d->connect_port(instance, 0, control.data());
    d->connect_port(instance, 1, notify.data());
    d->connect_port(instance, 2, input.data());
    d->connect_port(instance, 3, left.data());
    d->connect_port(instance, 31, right.data());
    for (uint32_t port = 4; port < Plugin::kPortCount; ++port)
      if (port != 31) d->connect_port(instance, port, &controls[port]);
    run(0);
  }
  ~Host() {
    // Do not throw during unwinding if a fixture unexpectedly requested a load.
    for (const auto& job : jobs)
      if (*reinterpret_cast<const LV2WorkType*>(job.data()) == kWorkTypeFree)
        worker->work(instance, nullptr, nullptr, static_cast<uint32_t>(job.size()), job.data());
    d->cleanup(instance);
  }
  void drain() {
    while (!jobs.empty()) {
      auto job = std::move(jobs.front()); jobs.pop_front();
      require(*reinterpret_cast<const LV2WorkType*>(job.data()) == kWorkTypeFree,
              "no unexpected reload with empty fixture paths");
      require(worker->work(instance, nullptr, nullptr, static_cast<uint32_t>(job.size()), job.data()) ==
                  LV2_WORKER_SUCCESS, "free replaced fixture outside process");
    }
  }
  void install(Stage stage, int mode) {
    auto* model = new Model;
    models[static_cast<size_t>(stage)] = model;
    LV2SwitchModelMsg message{kWorkTypeSwitch, stage, mode, 0, {}, model, nullptr, nullptr, false, 0.0f};
    require(worker->work_response(instance, sizeof(message), &message) == LV2_WORKER_SUCCESS, "install fixture");
  }
  static LV2_Worker_Status respondModel(LV2_Worker_Respond_Handle handle, uint32_t size, const void* data) {
    auto* host = static_cast<Host*>(handle);
    return host->worker->work_response(host->instance, size, data);
  }
  void loadReal(Stage stage, int mode, const char* path) {
    LV2LoadModelMsg message{kWorkTypeLoad, stage, mode, 0, {}};
    require(std::strlen(path) < MAX_FILE_NAME, "real fixture path fits");
    std::strcpy(message.path, path);
    require(worker->work(instance, respondModel, this, sizeof(message), &message) == LV2_WORKER_SUCCESS,
            "real NAM fixture load");
  }
  void maximum(int value) {
    auto* options = static_cast<const LV2_Options_Interface*>(d->extension_data(LV2_OPTIONS__interface));
    LV2_Options_Option values[] = {
        {LV2_OPTIONS_INSTANCE, 0, mapUri(this, LV2_BUF_SIZE__maxBlockLength), sizeof(value),
         mapUri(this, LV2_ATOM__Int), &value}, {}};
    require(options && options->set(instance, values) == 0, "resize negotiated buffer");
  }
  double run(uint32_t count) {
    auto* seq = reinterpret_cast<LV2_Atom_Sequence*>(control.data());
    seq->atom.type = mapUri(this, LV2_ATOM__Sequence);
    seq->atom.size = sizeof(LV2_Atom_Sequence_Body);
    seq->body = {};
    notify.fill(0);
    reinterpret_cast<LV2_Atom_Sequence*>(notify.data())->atom.size = kAtoms - sizeof(LV2_Atom);
    left.fill(NAN); right.fill(NAN);
    for (uint32_t i = 0; i < count; ++i)
      input[i] = amplitude * static_cast<float>(std::sin(6.283185307179586 * 997 * position++ / rate));
    const auto begin = std::chrono::steady_clock::now();
    d->run(instance, count);
    const auto end = std::chrono::steady_clock::now();
    require(std::isnan(left[count]) && std::isnan(right[count]), "audio guards intact");
    return std::chrono::duration<double, std::micro>(end - begin).count();
  }
};

void compare(const Host& a, const Host& b, uint32_t count) {
  require(std::memcmp(a.left.data(), b.left.data(), count * sizeof(float)) == 0 &&
              std::memcmp(a.right.data(), b.right.data(), count * sizeof(float)) == 0,
          "before/after audio bit-exact");
  for (uint32_t i = 0; i < count; ++i)
    require(std::isfinite(a.left[i]) && std::isfinite(a.right[i]), "finite stereo output");
  for (size_t port : {11u, 17u, 18u, 29u})
    require(a.controls[port] == b.controls[port], "identical output ports and latency");
  const auto bytes = reinterpret_cast<const LV2_Atom_Sequence*>(a.notify.data())->atom.size + sizeof(LV2_Atom);
  require(bytes <= kAtoms && std::memcmp(a.notify.data(), b.notify.data(), bytes) == 0, "identical notify atoms");
}

void verifySinglePedal(const LV2_Descriptor* current, const LV2_Descriptor* baseline) {
  for (int mode : {0, kOversampleTrue2, kOversampleTrue8})
    for (size_t activeSlot : {0u, 4u, 5u})
      for (int order = 0; order < 6; ++order) {
        Host actual(current, 48000, mode), expected(baseline, 48000, mode);
        expected.install(Stage::Pedal, mode); expected.install(Stage::Amp, mode);
        for (Stage stage : {Stage::Pedal, Stage::Pedal2, Stage::Pedal3, Stage::Amp}) actual.install(stage, mode);
        actual.controls[7] = activeSlot == 0;
        actual.controls[kPedal2EnabledPort] = activeSlot == 4;
        actual.controls[kPedal3EnabledPort] = activeSlot == 5;
        actual.controls[kPedalOrderPort] = order;
        for (Host* h : {&actual, &expected}) {
          h->amplitude = 0;
          for (int block = 0; block < 100; ++block) { h->run(64); h->drain(); }
          h->amplitude = 0.2f;
        }
        for (int block = 0; block < 100; ++block) {
          actual.run(64); expected.run(64);
          require(std::memcmp(actual.left.data(), expected.left.data(), 64 * sizeof(float)) == 0 &&
                  std::memcmp(actual.right.data(), expected.right.data(), 64 * sizeof(float)) == 0,
                  "one active pedal in any slot/order is bit-identical to original pedal");
          require(actual.controls[29] == expected.controls[29], "one pedal has original latency");
          actual.drain(); expected.drain();
        }
      }
  std::puts("PASS: one active pedal in any slot and all six orders is bit-identical to baseline, including loaded bypassed extras");
}

void verifyPedalOrder(const LV2_Descriptor* current) {
  static constexpr size_t orders[6][3] = {{0,4,5},{0,5,4},{4,0,5},{4,5,0},{5,0,4},{5,4,0}};
  for (int mode : {0, kOversampleTrue2, kOversampleTrue8}) {
    for (int order = 0; order < 6; ++order) {
      Host actual(current, 48000, mode), expected(current, 48000, mode);
      for (Host* h : {&actual, &expected}) {
        for (Stage stage : {Stage::Pedal, Stage::Pedal2, Stage::Pedal3, Stage::Amp}) h->install(stage, mode);
        h->controls[kPedal2EnabledPort] = h->controls[kPedal3EnabledPort] = 1;
      }
      actual.controls[kPedalOrderPort] = order;
      for (size_t slot : {0u,4u,5u}) actual.models[slot]->flavor = slot == 0 ? 1 : slot == 4 ? 2 : 0;
      for (size_t position = 0; position < 3; ++position)
        expected.models[orders[0][position]]->flavor = actual.models[orders[order][position]]->flavor;
      // Settle the model/order fades on silence, then compare independent histories.
      for (Host* h : {&actual, &expected}) {
        h->controls[4] = -120;
        for (int i = 0; i < 100; ++i) { h->run(64); h->drain(); }
        h->controls[4] = 0;
      }
      for (int block = 0; block < 100; ++block) {
        actual.run(64); expected.run(64);
        for (size_t i = 0; i < 64; ++i)
          require(std::fabs(actual.left[i] - expected.left[i]) < 1e-6f, "pedal order matches physically rearranged nonlinear models");
        require(actual.controls[29] == expected.controls[29], "reorder preserves latency");
        actual.drain(); expected.drain();
      }
    }
  }
  std::puts("PASS: all six pedal orders match independently rearranged nonlinear models at None/True2/True8");
}

void verify(const LV2_Descriptor* current, const LV2_Descriptor* baseline, bool bench) {
  for (double rate : {48000.0, 96000.0, 192000.0})
    for (int mode : {0, kOversampleTrue2, kOversampleTrue8}) {
      Host a(current, rate, mode), b(baseline, rate, mode);
      for (Host* h : {&a, &b}) {
        h->maximum(64);
        h->install(Stage::Pedal, mode);
        h->install(Stage::Amp, mode);
        h->install(Stage::Cab, mode);
        h->install(Stage::Cab2, kOversampleLegacy);
      }
      constexpr std::array<uint32_t, 10> counts{32, 64, 1, 17, 31, 33, 65, 128, 513, 32};
      for (unsigned block = 0; block < 1000; ++block) {
        if (block % 100 == 0) {
          for (Host* h : {&a, &b}) {
            h->controls[4] = block % 200 ? -3 : 1;
            h->controls[5] = block % 200 ? -6 : 0;
            h->controls[22] = block % 200 ? 6 : -2;
            h->controls[25] = block % 200 ? -24 : -1;
            h->controls[48] = block % 200 ? -4 : 2;
            h->controls[32] = block % 200 ? 100 : 35;
            h->controls[59] = block % 200 ? 1 : 0;
            h->controls[28] = block % 300 ? 22 : 0;
            h->controls[kCompressorAttackPort] = block % 200 ? 35 : 8;
            h->controls[kCompressorReleasePort] = block % 200 ? 70 : 120;
            h->models[1]->inputDb = block % 200 ? -2 : 0;
            h->models[1]->outputDb = block % 200 ? 1 : 3;
            h->controls[kRackControlFirstPort + static_cast<size_t>(Rack::Spatial)] = block % 300 ? 1 : 0;
          }
        }
        if (block == 500)
          for (Host* h : {&a, &b}) { h->install(Stage::Pedal, mode);
        h->install(Stage::Amp, mode); h->maximum(32); }
        const uint32_t count = counts[block % counts.size()];
        a.run(count); b.run(count); compare(a, b, count);
        a.drain(); b.drain();
      }
      std::printf("PASS: %.0f Hz mode=%d; 32/64 and irregular/oversized blocks, trims, compressor timing, width, polarity, rack bypass, model swap, resize, audio/atoms/latency exact\n", rate, mode);
    }
  if (!bench) return;
  for (uint32_t count : {32u, 64u}) {
    Host a(current, 96000, 0), b(baseline, 96000, 0);
    for (Host* h : {&a, &b}) {
      h->install(Stage::Amp, 0); h->install(Stage::Cab, 0); h->install(Stage::Cab2, kOversampleLegacy);
      h->controls[4] = -3; h->controls[22] = 6; h->controls[32] = 35;
    }
    std::vector<double> before, after;
    for (unsigned block = 0; block < 1500; ++block) {
      double x, y;
      if (block % 2) { x = a.run(count); y = b.run(count); }
      else { y = b.run(count); x = a.run(count); }
      compare(a, b, count); a.drain(); b.drain();
      if (block >= 1000) { after.push_back(x); before.push_back(y); }
    }
    std::sort(before.begin(), before.end()); std::sort(after.begin(), after.end());
    std::printf("BENCH settled controls / lightweight dual-cab fixture, 96k block=%u: before median=%.2f p95=%.2f us, after median=%.2f p95=%.2f us (not real NAM model CPU)\n",
                count, before[250], before[474], after[250], after[474]);
  }
}
}

int main(int argc, char** argv) {
  try {
    require(argc >= 2 && argc <= 4, "usage: verify_low_buffer_rig <new .so> [baseline .so] [--bench]");
    Library current(argv[1]);
    const bool bench = argc >= 3 && std::strcmp(argv[argc - 1], "--bench") == 0;
    Library baseline(argc >= 3 && std::strcmp(argv[2], "--bench") != 0 ? argv[2] : argv[1]);
    verify(current.descriptor, baseline.descriptor, bench);
    verifyPedalOrder(current.descriptor);
    verifySinglePedal(current.descriptor, baseline.descriptor);
    if (const char* path = std::getenv("AXE_FX_PEDAL_REAL_MODEL")) {
      for (double rate : {48000.0, 96000.0})
        for (int mode : {0, kOversampleTrue8}) {
          Host a(current.descriptor, rate, mode), b(baseline.descriptor, rate, mode);
          for (Host* h : {&a, &b}) {
            h->loadReal(Stage::Pedal, mode, path);
            h->loadReal(Stage::Amp, mode, path);
          }
          for (unsigned block = 0; block < 120; ++block) {
            const uint32_t count = block % 2 ? 64 : 17;
            a.run(count); b.run(count); compare(a, b, count); a.drain(); b.drain();
          }
          std::printf("PASS: real NAM pedal + amp baseline bit equality at %.0f Hz mode=%d\n", rate, mode);
        }
    }
  } catch (const std::exception& e) { std::fprintf(stderr, "FAIL: %s\n", e.what()); return 1; }
}
