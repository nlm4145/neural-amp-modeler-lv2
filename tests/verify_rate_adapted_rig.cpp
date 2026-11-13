// A 44.1 kHz-family session must sound like a 48 kHz session: NAM models are
// trained at 48 kHz, so the rig runs at 48 kHz internally and converts at its
// edges. Runs against the built rig library with a real model, without audio
// hardware.
// Usage: verify_rate_adapted_rig <rig.so> <wavenet-amp.nam>
#include "nam_rig_plugin.h"
#include "rate_adapter.h"
#include "standalone_worker.h"
#include "win32_control_defaults.h"
#include <lv2/atom/forge.h>
#include <lv2/atom/util.h>
#include <dlfcn.h>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <deque>
#include <random>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr double kTwoPi = 6.28318530717958647692;
constexpr uint32_t kLatencyPort = 29;
int failures = 0;

void check(bool ok, const char* message) {
  std::printf("  %s  %s\n", ok ? "PASS" : "FAIL", message);
  if (!ok) ++failures;
}

struct Host {
  static constexpr uint32_t kBlock = 256;
  std::deque<std::string> uris;
  LV2_URID_Map map{this, mapURI};
  NAMRig::StandaloneWorker worker;
  const LV2_Descriptor* descriptor = nullptr;
  LV2_Handle instance = nullptr;
  std::array<float, NAMRig::Plugin::kPortCount> controls{};
  std::array<float, kBlock> input{}, left{}, right{};
  alignas(LV2_Atom_Sequence) std::array<uint8_t, 16384> control{}, notify{};
  bool ampResponded = false;
  LV2_Atom_Forge forge{};

  static LV2_URID mapURI(LV2_URID_Map_Handle handle, const char* uri) {
    auto& uris = static_cast<Host*>(handle)->uris;
    for (size_t i = 0; i < uris.size(); ++i) if (uris[i] == uri) return static_cast<LV2_URID>(i + 1);
    uris.emplace_back(uri);
    return static_cast<LV2_URID>(uris.size());
  }
  ~Host() {
    worker.stop();
    if (instance) descriptor->cleanup(instance);
  }
  void emptyControl() {
    auto* seq = reinterpret_cast<LV2_Atom_Sequence*>(control.data());
    seq->atom.type = mapURI(this, LV2_ATOM__Sequence);
    seq->atom.size = sizeof(LV2_Atom_Sequence_Body);
    seq->body = {};
  }
  bool initialize(const LV2_Descriptor* d, double rate) {
    descriptor = d;
    LV2_Feature mf{LV2_URID__map, &map}, wf{LV2_WORKER__schedule, worker.scheduleFeature()};
    const LV2_Feature* features[] = {&mf, &wf, nullptr};
    instance = d->instantiate(d, rate, "", features);
    if (!instance) return false;
    const auto* callbacks = static_cast<const LV2_Worker_Interface*>(d->extension_data(LV2_WORKER__interface));
    if (!callbacks || !worker.start(instance, *callbacks)) return false;
    NAMRigWin32::forEachWin32ControlDefault([&](uint32_t port, float value) { controls[port] = value; });
    controls[20] = controls[21] = NAMRig::kOversampleTrue8;
    controls[7] = 0; controls[8] = 1; controls[9] = 0; controls[47] = 0;
    controls[15] = -80.0f;  // gate open
    for (uint32_t p : {74u, 76u, 77u, 79u, 185u}) controls[p] = 0;
    d->connect_port(instance, 0, control.data());
    d->connect_port(instance, 1, notify.data());
    d->connect_port(instance, 2, input.data());
    d->connect_port(instance, 3, left.data());
    d->connect_port(instance, 31, right.data());
    for (uint32_t p = 4; p < controls.size(); ++p)
      if (p != 31) d->connect_port(instance, p, &controls[p]);
    lv2_atom_forge_init(&forge, &map);
    emptyControl();
    run();
    return true;
  }
  static constexpr const char* paths[] = {NAM_RIG_PEDAL_URI, NAM_RIG_AMP_URI, NAM_RIG_CAB_URI, NAM_RIG_CAB2_URI};
  void requestAmp(const char* amp) {
    lv2_atom_forge_set_buffer(&forge, control.data(), control.size());
    LV2_Atom_Forge_Frame seq{};
    lv2_atom_forge_sequence_head(&forge, &seq, 0);
    for (size_t s = 0; s < 4; ++s) {
      const char* path = s == 1 ? amp : "";
      LV2_Atom_Forge_Frame obj{};
      lv2_atom_forge_frame_time(&forge, 0);
      lv2_atom_forge_object(&forge, &obj, 0, mapURI(this, LV2_PATCH__Set));
      lv2_atom_forge_key(&forge, mapURI(this, LV2_PATCH__property));
      lv2_atom_forge_urid(&forge, mapURI(this, paths[s]));
      lv2_atom_forge_key(&forge, mapURI(this, LV2_PATCH__value));
      lv2_atom_forge_path(&forge, path, static_cast<uint32_t>(std::strlen(path) + 1));
      lv2_atom_forge_pop(&forge, &obj);
    }
    lv2_atom_forge_pop(&forge, &seq);
  }
  void run() {
    worker.applyResponses();
    reinterpret_cast<LV2_Atom_Sequence*>(notify.data())->atom.size = notify.size() - sizeof(LV2_Atom);
    descriptor->run(instance, kBlock);
    LV2_ATOM_SEQUENCE_FOREACH(reinterpret_cast<const LV2_Atom_Sequence*>(notify.data()), event) {
      if (event->body.type != mapURI(this, LV2_ATOM__Object)) continue;
      const auto* obj = reinterpret_cast<const LV2_Atom_Object*>(&event->body);
      if (obj->body.otype != mapURI(this, LV2_PATCH__Set)) continue;
      const LV2_Atom *property = nullptr, *value = nullptr;
      lv2_atom_object_get(obj, mapURI(this, LV2_PATCH__property), &property, mapURI(this, LV2_PATCH__value), &value, 0);
      if (!property || !value || value->type != mapURI(this, LV2_ATOM__Path)) continue;
      if (reinterpret_cast<const LV2_Atom_URID*>(property)->body == mapURI(this, paths[1]) &&
          reinterpret_cast<const char*>(value + 1)[0] != '\0')
        ampResponded = true;
    }
    emptyControl();
  }
  bool loadAmp(const char* path) {
    requestAmp(path);
    const auto begin = std::chrono::steady_clock::now();
    while (!ampResponded) {
      run();
      if (std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count() > 30.0) return false;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    for (int i = 0; i < 200; ++i) run();  // let the model fade in
    return true;
  }
  std::vector<float> render(const std::vector<float>& in) {
    std::vector<float> out;
    for (size_t off = 0; off + kBlock <= in.size(); off += kBlock) {
      std::memcpy(input.data(), in.data() + off, kBlock * sizeof(float));
      run();
      out.insert(out.end(), left.begin(), left.end());
    }
    return out;
  }
};

std::vector<double> toneFrequencies() {
  std::vector<double> f;
  for (int k = 0; k < 40; ++k) f.push_back(70.0 * std::pow(16000.0 / 70.0, k / 39.0));
  return f;
}

std::vector<float> toneSignal(double rate) {
  std::vector<float> x(static_cast<size_t>(rate * 2.5), 0.0f);
  std::mt19937 rng(9);
  for (double f : toneFrequencies()) {
    const double phase = kTwoPi * static_cast<double>(rng() % 10000) / 10000.0;
    for (size_t i = 0; i < x.size(); ++i)
      x[i] += static_cast<float>(0.012 * std::sin(kTwoPi * f * static_cast<double>(i) / rate + phase));
  }
  return x;
}

std::vector<double> toneLevelsDb(const std::vector<float>& y, double rate) {
  std::vector<double> levels;
  const size_t start = static_cast<size_t>(rate * 1.0), len = static_cast<size_t>(rate * 1.2);
  for (double f : toneFrequencies()) {
    double re = 0.0, im = 0.0, norm = 0.0;
    for (size_t i = 0; i < len && start + i < y.size(); ++i) {
      const double w = 0.5 - 0.5 * std::cos(kTwoPi * static_cast<double>(i) / len);
      const double angle = kTwoPi * f * static_cast<double>(i) / rate;
      re += w * y[start + i] * std::cos(angle);
      im += w * y[start + i] * std::sin(angle);
      norm += w;
    }
    levels.push_back(20.0 * std::log10(2.0 * std::sqrt(re * re + im * im) / norm + 1e-12));
  }
  return levels;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 3) {
    std::fprintf(stderr, "usage: verify_rate_adapted_rig <rig.so> <wavenet-amp.nam>\n");
    return 2;
  }
  void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) { std::fprintf(stderr, "%s\n", dlerror()); return 1; }
  auto get = reinterpret_cast<const LV2_Descriptor* (*)(uint32_t)>(dlsym(library, "lv2_descriptor"));
  if (!get) return 1;
  const LV2_Descriptor* descriptor = get(0);

  std::puts("== 1. no model: exact delay and reported latency ==");
  for (double rate : {44100.0, 88200.0, 48000.0}) {
    Host host;
    if (!host.initialize(descriptor, rate)) { std::fprintf(stderr, "initialize failed\n"); return 1; }
    std::vector<float> impulse(static_cast<size_t>(Host::kBlock) * 64, 0.0f);
    impulse[4000] = 0.5f;
    const std::vector<float> out = host.render(impulse);
    size_t peak = 0;
    for (size_t i = 0; i < out.size(); ++i)
      if (std::fabs(out[i]) > std::fabs(out[peak])) peak = i;
    const bool adapted = NAMRig::HostRateAdapter::internalRate(rate) != rate;
    const size_t expected = adapted ? static_cast<size_t>(NAMRig::HostRateAdapter::kLatencyFrames) : 0;
    char message[160];
    std::snprintf(message, sizeof(message),
                  "%.0f Hz: impulse delay %zu frames equals the latency port (%.0f), expected %zu",
                  rate, peak - 4000, host.controls[kLatencyPort], expected);
    check(peak - 4000 == expected && host.controls[kLatencyPort] == static_cast<float>(expected) &&
          std::fabs(out[peak]) > 0.45f, message);
  }

  std::puts("== 2. real model: 44.1 kHz-family tone equals 48 kHz tone ==");
  std::vector<double> reference;
  float referenceLatency = 0.0f;
  {
    Host host;
    if (!host.initialize(descriptor, 48000.0) || !host.loadAmp(argv[2])) {
      std::fprintf(stderr, "48 kHz model load failed\n");
      return 1;
    }
    reference = toneLevelsDb(host.render(toneSignal(48000.0)), 48000.0);
    referenceLatency = host.controls[kLatencyPort];
  }
  for (double rate : {44100.0, 88200.0}) {
    Host host;
    if (!host.initialize(descriptor, rate) || !host.loadAmp(argv[2])) {
      std::fprintf(stderr, "%.0f Hz model load failed\n", rate);
      return 1;
    }
    const std::vector<double> levels = toneLevelsDb(host.render(toneSignal(rate)), rate);
    double worst = 0.0;
    for (size_t i = 0; i < levels.size(); ++i) worst = std::max(worst, std::fabs(levels[i] - reference[i]));
    char message[160];
    std::snprintf(message, sizeof(message),
                  "%.0f Hz: model response within 0.1 dB of 48 kHz from 70 Hz to 16 kHz (worst %.3f dB)",
                  rate, worst);
    check(worst < 0.1, message);
    if (rate == 44100.0) {
      const float expected = static_cast<float>(
          std::lround(referenceLatency * 44100.0 / 48000.0) + NAMRig::HostRateAdapter::kLatencyFrames);
      std::snprintf(message, sizeof(message),
                    "44100 Hz: latency port %.0f = 48 kHz latency in session frames + converter pair (%.0f)",
                    host.controls[kLatencyPort], expected);
      check(host.controls[kLatencyPort] == expected, message);
    }
  }

  dlclose(library);
  std::printf("%s\n", failures ? "FAILED" : "verify_rate_adapted_rig: all checks passed");
  return failures ? 1 : 0;
}
