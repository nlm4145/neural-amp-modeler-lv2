// Exercise real worker loads and engine path acknowledgements without audio
// hardware, provider requests, or changing the installed rig.
// Usage: verify_model_loads <rig.so> <pedal.nam> <amp.nam> <cab.wav>
#include "nam_rig_plugin.h"
#include "standalone_worker.h"
#include "win32_control_defaults.h"
#include <lv2/atom/forge.h>
#include <lv2/atom/util.h>
#include <dlfcn.h>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <deque>
#include <string>
#include <thread>

struct Host {
  std::deque<std::string> uris;
  LV2_URID_Map map{this, mapURI};
  NAMRig::StandaloneWorker worker;
  const LV2_Descriptor* descriptor = nullptr;
  LV2_Handle instance = nullptr;
  std::array<float, NAMRig::Plugin::kPortCount> controls{};
  std::array<float, 64> input{}, left{}, right{};
  alignas(LV2_Atom_Sequence) std::array<uint8_t, 16384> control{}, notify{};
  std::array<std::string, 4> confirmed{};
  std::array<bool, 4> responded{};
  LV2_Atom_Forge forge{};
  static LV2_URID mapURI(LV2_URID_Map_Handle handle, const char* uri) {
    auto& uris = static_cast<Host*>(handle)->uris;
    for (size_t i = 0; i < uris.size(); ++i) if (uris[i] == uri) return static_cast<LV2_URID>(i + 1);
    uris.emplace_back(uri); return static_cast<LV2_URID>(uris.size());
  }
  ~Host() {
    worker.stop();
    if (instance) descriptor->cleanup(instance);
  }
  void emptyControl() {
    auto* seq = reinterpret_cast<LV2_Atom_Sequence*>(control.data());
    seq->atom.type = mapURI(this, LV2_ATOM__Sequence);
    seq->atom.size = sizeof(LV2_Atom_Sequence_Body); seq->body = {};
  }
  bool initialize(const LV2_Descriptor* d) {
    descriptor = d;
    LV2_Feature mf{LV2_URID__map, &map}, wf{LV2_WORKER__schedule, worker.scheduleFeature()};
    const LV2_Feature* features[] = {&mf, &wf, nullptr};
    instance = d->instantiate(d, 48000, "", features);
    if (!instance) return false;
    const auto* callbacks = static_cast<const LV2_Worker_Interface*>(d->extension_data(LV2_WORKER__interface));
    if (!callbacks || !worker.start(instance, *callbacks)) return false;
    NAMRigWin32::forEachWin32ControlDefault([&](uint32_t port, float value) { controls[port] = value; });
    controls[20] = controls[21] = NAMRig::kOversampleTrue8;
    controls[7] = controls[8] = controls[9] = 1; controls[47] = 0;
    for (uint32_t p : {74u, 76u, 77u, 79u, 185u}) controls[p] = 0;
    d->connect_port(instance, 0, control.data()); d->connect_port(instance, 1, notify.data());
    d->connect_port(instance, 2, input.data()); d->connect_port(instance, 3, left.data());
    d->connect_port(instance, 31, right.data());
    for (uint32_t p = 4; p < controls.size(); ++p) if (p != 31) d->connect_port(instance, p, &controls[p]);
    lv2_atom_forge_init(&forge, &map);
    emptyControl(); run();
    return true;
  }
  static constexpr const char* paths[] = {NAM_RIG_PEDAL_URI, NAM_RIG_AMP_URI, NAM_RIG_CAB_URI, NAM_RIG_CAB2_URI};
  void request(char** files) {
    lv2_atom_forge_set_buffer(&forge, control.data(), control.size());
    LV2_Atom_Forge_Frame seq{};
    lv2_atom_forge_sequence_head(&forge, &seq, 0);
    for (size_t s = 0; s < 4; ++s) {
      const char* path = s < 3 ? files[s] : "";
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
    descriptor->run(instance, input.size());
    LV2_ATOM_SEQUENCE_FOREACH(reinterpret_cast<const LV2_Atom_Sequence*>(notify.data()), event) {
      if (event->body.type != mapURI(this, LV2_ATOM__Object)) continue;
      const auto* obj = reinterpret_cast<const LV2_Atom_Object*>(&event->body);
      if (obj->body.otype != mapURI(this, LV2_PATCH__Set)) continue;
      const LV2_Atom *property = nullptr, *value = nullptr;
      lv2_atom_object_get(obj, mapURI(this, LV2_PATCH__property), &property, mapURI(this, LV2_PATCH__value), &value, 0);
      if (!property || !value || value->type != mapURI(this, LV2_ATOM__Path)) continue;
      const auto id = reinterpret_cast<const LV2_Atom_URID*>(property)->body;
      for (size_t s = 0; s < 4; ++s) if (id == mapURI(this, paths[s])) {
        confirmed[s] = reinterpret_cast<const char*>(value + 1); responded[s] = true;
        std::printf("Stage %zu engine path: %s\n", s, confirmed[s].empty() ? "(empty)" : confirmed[s].c_str());
      }
    }
    emptyControl();
  }
};

int main(int argc, char** argv) {
  if (argc != 5) return 2;
  void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) { std::fprintf(stderr, "%s\n", dlerror()); return 1; }
  auto get = reinterpret_cast<const LV2_Descriptor* (*)(uint32_t)>(dlsym(library, "lv2_descriptor"));
  if (!get) return 1;
  int result = 1;
  {
    Host host;
    if (!host.initialize(get(0))) return 1;
    host.request(argv + 2);
    const auto begin = std::chrono::steady_clock::now();
    for (;;) {
      host.run();
      bool ready = true;
      for (size_t s = 0; s < 4; ++s) ready &= host.responded[s] && host.confirmed[s] == (s < 3 ? argv[s + 2] : "");
      const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
      if (ready) { std::printf("PASS all real models confirmed in %.2f s\n", elapsed); result = 0; break; }
      if (elapsed >= 30) {
        for (size_t s = 0; s < 4; ++s) std::fprintf(stderr, "Stage %zu: responded=%d path=%s\n", s, host.responded[s], host.confirmed[s].c_str());
        break;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  }
  dlclose(library);
  return result;
}
