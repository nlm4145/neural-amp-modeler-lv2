// A True oversampling mode must oversample an LSTM amp model. The loader runs
// the LSTM as native-rate copies on the sample phases of the True domain, so
// the model joins that domain like a WaveNet and its alias noise falls.
// Runs against the built rig library with a real model, without audio hardware.
// Usage: verify_lstm_oversampling <rig.so> <lstm-amp.nam>
#include "nam_rig_plugin.h"
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
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr double kTwoPi = 6.28318530717958647692;
constexpr uint32_t kLatencyPort = 29;
constexpr uint32_t kAmpOversamplePort = 21;
constexpr size_t kAnalysisFrames = 131072;
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

struct Measurement {
  double aliasDb = 0.0;
  float latency = -1.0f;
  bool loaded = false;
};

void fft(std::vector<double>& re, std::vector<double>& im) {
  const size_t n = re.size();
  for (size_t i = 1, j = 0; i < n; ++i) {
    size_t bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      std::swap(re[i], re[j]);
      std::swap(im[i], im[j]);
    }
  }
  for (size_t len = 2; len <= n; len <<= 1) {
    const double angle = -kTwoPi / static_cast<double>(len);
    for (size_t start = 0; start < n; start += len) {
      for (size_t k = 0; k < len / 2; ++k) {
        const double wr = std::cos(angle * static_cast<double>(k));
        const double wi = std::sin(angle * static_cast<double>(k));
        const size_t a = start + k, b = a + len / 2;
        const double xr = re[b] * wr - im[b] * wi;
        const double xi = re[b] * wi + im[b] * wr;
        re[b] = re[a] - xr;
        im[b] = im[a] - xi;
        re[a] += xr;
        im[a] += xi;
      }
    }
  }
}

// Drives the amp with a 2637 Hz sine. Energy from 20 Hz to 16 kHz that is not
// on a harmonic of the sine is alias noise. The result is that energy
// relative to the harmonics, in dB.
Measurement measure(const LV2_Descriptor* d, double rate, const char* model, int mode) {
  constexpr double kToneHz = 2637.0;
  Measurement result;
  Host host;
  if (!host.initialize(d, rate)) return result;
  host.controls[kAmpOversamplePort] = static_cast<float>(mode);
  if (!host.loadAmp(model)) return result;
  result.loaded = true;

  const size_t warmup = static_cast<size_t>(rate) / Host::kBlock * Host::kBlock;
  const size_t total = warmup + kAnalysisFrames + Host::kBlock;
  std::vector<float> in(total);
  for (size_t i = 0; i < total; ++i)
    in[i] = 0.5f * static_cast<float>(std::sin(kTwoPi * kToneHz * static_cast<double>(i) / rate));
  const std::vector<float> out = host.render(in);
  result.latency = host.controls[kLatencyPort];
  if (out.size() < warmup + kAnalysisFrames) return result;

  std::vector<double> re(kAnalysisFrames), im(kAnalysisFrames, 0.0);
  for (size_t i = 0; i < kAnalysisFrames; ++i) {
    const double t = kTwoPi * static_cast<double>(i) / kAnalysisFrames;
    const double window = 0.35875 - 0.48829 * std::cos(t) + 0.14128 * std::cos(2.0 * t) -
                          0.01168 * std::cos(3.0 * t);
    re[i] = window * out[warmup + i];
  }
  fft(re, im);

  const double binHz = rate / kAnalysisFrames;
  double harmonics = 0.0, noise = 0.0;
  for (size_t bin = 1; bin < kAnalysisFrames / 2; ++bin) {
    const double hz = static_cast<double>(bin) * binHz;
    const double power = re[bin] * re[bin] + im[bin] * im[bin];
    const double nearest = std::round(hz / kToneHz);
    const bool harmonic = nearest >= 1.0 && std::fabs(hz - nearest * kToneHz) < 8.0 * binHz;
    if (harmonic) harmonics += power;
    else if (hz >= 20.0 && hz <= 16000.0) noise += power;
  }
  result.aliasDb = 10.0 * std::log10((noise + 1.0e-30) / (harmonics + 1.0e-30));
  return result;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 3) return 2;
  void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) {
    std::fprintf(stderr, "%s\n", dlerror());
    return 1;
  }
  auto get = reinterpret_cast<const LV2_Descriptor* (*)(uint32_t)>(dlsym(library, "lv2_descriptor"));
  if (!get) return 1;
  const LV2_Descriptor* d = get(0);

  for (double rate : {48000.0, 96000.0}) {
    char message[200];
    const Measurement off = measure(d, rate, argv[2], NAMRig::kOversampleNone);
    const Measurement true8 = measure(d, rate, argv[2], NAMRig::kOversampleTrue8);
    const Measurement true16 = measure(d, rate, argv[2], NAMRig::kOversampleTrue16);
    check(off.loaded && true8.loaded && true16.loaded, "LSTM amp model loads in Off, True 8x and True 16x");

    std::snprintf(message, sizeof(message),
                  "%.0f Hz: Off adds no latency (latency %.0f, alias %.1f dB)",
                  rate, off.latency, off.aliasDb);
    check(off.latency == 0.0f, message);

    // True Nx means N x 96 kHz. One cascade is 41 frames at 8x and 44 at 16x.
    const int factor8 = rate < 72000.0 ? 16 : 8;
    const float cascade8 = factor8 == 16 ? 44.0f : 41.0f;
    std::snprintf(message, sizeof(message),
                  "%.0f Hz: True 8x runs the LSTM in the True domain (latency %.0f = one %dx cascade %.0f)",
                  rate, true8.latency, factor8, cascade8);
    check(true8.latency == cascade8, message);
    std::snprintf(message, sizeof(message),
                  "%.0f Hz: True 8x keeps LSTM alias noise at -80 dB or less (%.1f dB; -45 dB at the native rate)",
                  rate, true8.aliasDb);
    check(true8.aliasDb <= -80.0, message);

    const int factor16 = 16;
    const float cascade16 = 44.0f;
    std::snprintf(message, sizeof(message),
                  "%.0f Hz: True 16x runs the LSTM in the True domain (latency %.0f = one %dx cascade %.0f, alias %.1f dB)",
                  rate, true16.latency, factor16, cascade16, true16.aliasDb);
    check(true16.latency == cascade16 && true16.aliasDb <= -80.0, message);
  }

  std::puts(failures ? "FAILED" : "ALL PASSED (0 failures)");
  return failures ? 1 : 0;
}
