// Backend integration through the LV2 descriptor, with an identity amp model.
// Build: clang++ -O2 -std=c++17 -Isrc -Ideps/lv2/include -Ideps/NeuralAudio \
//   -Ideps/NeuralAudio/deps/RTNeural/modules/json tests/verify_transformer_controls.cpp -o <test>
// Usage: <test> <freshly built neural_amp_modeler_rig.so>
#include "nam_rig_plugin.h"

#include <dlfcn.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

namespace {
constexpr size_t kBlock = 128, kAtomBytes = 16384;
int failures = 0;
void check(bool ok, const char* label) {
  std::printf("  %s  %s\n", ok ? "PASS" : "FAIL", label);
  if (!ok) ++failures;
}

class Identity final : public NeuralAudio::NeuralModel {
public:
  float* editDuringProcess = nullptr;
  float GetRecommendedInputDBAdjustment() override { return 0; }
  float GetRecommendedOutputDBAdjustment() override { return 0; }
  void Process(float* input, float* output, size_t count) override {
    if (input != output) std::memcpy(output, input, count * sizeof(float));
    if (editDuringProcess) {
      *editDuringProcess = 12;
      editDuringProcess = nullptr;
    }
  }
};

struct Host {
  const LV2_Descriptor* descriptor;
  std::vector<std::string> uris;
  unsigned scheduled = 0;
  LV2_URID_Map map{this, mapUri};
  LV2_Worker_Schedule schedule{this, scheduleWork};
  LV2_Handle instance = nullptr;
  Identity* identity = nullptr;
  std::array<float, NAMRig::Plugin::kPortCount> controls{};
  std::array<float, kBlock> input{}, output{}, right{};
  alignas(LV2_Atom_Sequence) std::array<uint8_t, kAtomBytes> control{}, notify{};
  double rate;
  size_t position = 0;

  static LV2_URID mapUri(LV2_URID_Map_Handle handle, const char* uri) {
    auto& uris = static_cast<Host*>(handle)->uris;
    const auto found = std::find(uris.begin(), uris.end(), uri);
    if (found != uris.end()) return static_cast<LV2_URID>(found - uris.begin() + 1);
    uris.emplace_back(uri);
    return static_cast<LV2_URID>(uris.size());
  }
  static LV2_Worker_Status scheduleWork(LV2_Worker_Schedule_Handle handle,
                                       uint32_t, const void*) {
    ++static_cast<Host*>(handle)->scheduled;
    return LV2_WORKER_SUCCESS;
  }

  Host(const LV2_Descriptor* d, double sampleRate, int mode, int profile, bool trims)
      : descriptor(d), rate(sampleRate) {
    LV2_Feature mapFeature{LV2_URID__map, &map}, workerFeature{LV2_WORKER__schedule, &schedule};
    const LV2_Feature* features[] = {&mapFeature, &workerFeature, nullptr};
    instance = descriptor->instantiate(descriptor, rate, "", features);
    if (!instance) return;
    controls[8] = 1;
    controls[15] = -80;
    controls[20] = controls[21] = static_cast<float>(mode);
    controls[23] = 150;
    controls[27] = 20000;
    controls[30] = static_cast<float>(profile);
    controls[50] = 400;
    controls[51] = 35;
    controls[52] = 40;
    controls[55] = controls[56] = controls[57] = 50;
    controls[58] = 10;
    std::copy(NAMRig::kTransformerControlDefaults.begin(), NAMRig::kTransformerControlDefaults.end(),
              controls.begin() + NAMRig::kTransformerControlFirstPort);
    descriptor->connect_port(instance, 0, control.data());
    descriptor->connect_port(instance, 1, notify.data());
    descriptor->connect_port(instance, 2, input.data());
    descriptor->connect_port(instance, 3, output.data());
    descriptor->connect_port(instance, 31, right.data());
    for (uint32_t port = 4; port < NAMRig::Plugin::kPortCount; ++port) {
      if (port != 31) descriptor->connect_port(instance, port,
          !trims && port >= NAMRig::kTransformerControlFirstPort ? nullptr : &controls[port]);
    }
    run(); // Latch the requested oversampling mode before installing the amp.
    identity = new Identity;
    NAMRig::LV2SwitchModelMsg message{
        NAMRig::kWorkTypeSwitch, NAMRig::Stage::Amp, mode, 0, {}, identity,
        nullptr, nullptr, false};
    const auto* worker = static_cast<const LV2_Worker_Interface*>(
        descriptor->extension_data(LV2_WORKER__interface));
    if (!worker || worker->work_response(instance, sizeof(message), &message) != LV2_WORKER_SUCCESS)
      check(false, "install identity amp through worker response");
    // Let the existing model-switch fade commit its actual rate domain.
    for (int block = 0; block < 16; ++block) run();
    scheduled = 0;
  }
  ~Host() { if (instance) descriptor->cleanup(instance); }
  bool run() {
    if (!instance) return false;
    auto* sequence = reinterpret_cast<LV2_Atom_Sequence*>(control.data());
    sequence->atom.type = mapUri(this, LV2_ATOM__Sequence);
    sequence->atom.size = sizeof(LV2_Atom_Sequence_Body);
    reinterpret_cast<LV2_Atom_Sequence*>(notify.data())->atom.size = kAtomBytes - sizeof(LV2_Atom);
    for (float& x : input)
      x = .3f * static_cast<float>(std::sin(2 * 3.14159265358979323846 * 997 * position++ / rate));
    descriptor->run(instance, kBlock);
    for (size_t i = 0; i < kBlock; ++i)
      if (!std::isfinite(output[i]) || output[i] != right[i]) return false;
    return true;
  }
  bool matches(const Host& other) const {
    return std::memcmp(output.data(), other.output.data(), sizeof(output)) == 0;
  }
};
} // namespace

int main(int argc, char** argv) {
  if (argc != 2) { std::printf("usage: verify_transformer_controls <rig .so>\n"); return 1; }
  void* library = dlopen(argv[1], RTLD_NOW);
  if (!library) { std::printf("FAIL: %s\n", dlerror()); return 1; }
  auto get = reinterpret_cast<const LV2_Descriptor* (*)(uint32_t)>(dlsym(library, "lv2_descriptor"));
  if (!get || !get(0)) { std::printf("FAIL: missing rig descriptor\n"); return 1; }
  const auto* d = get(0);
  bool neutral = true, off = true, malformed = true, audible = true, noFade = true, snapshot = true;
  bool domains = true;
  for (int mode : {0, 6}) {
    const double rate = mode == 0 ? 48000 : 96000;
    for (int profile = 0; profile < NAMRig::OutputTransformer::kProfileCount; ++profile) {
      Host old(d, rate, mode, profile, false), connected(d, rate, mode, profile, true);
      for (int block = 0; block < 30; ++block)
        neutral &= old.run() && connected.run() && old.matches(connected);
      domains &= connected.controls[29] == (mode == 6 ? 41 : 0);
    }
    Host captured(d, rate, mode, 0, false), editedOff(d, rate, mode, 0, true);
    for (size_t i = 0; i < NAMRig::kTransformerControlCount; ++i)
      editedOff.controls[60 + i] = NAMRig::kTransformerControls[i].maximum;
    for (int block = 0; block < 30; ++block)
      off &= captured.run() && editedOff.run() && captured.matches(editedOff);

    for (float bad : {std::numeric_limits<float>::quiet_NaN(),
                      std::numeric_limits<float>::infinity(), -std::numeric_limits<float>::infinity()}) {
      Host reference(d, rate, mode, 3, false), invalid(d, rate, mode, 3, true);
      for (size_t i = 0; i < NAMRig::kTransformerControlCount; ++i) invalid.controls[60 + i] = bad;
      for (int block = 0; block < 30; ++block)
        malformed &= reference.run() && invalid.run() && reference.matches(invalid);
    }

    Host reference(d, rate, mode, 3, true), moving(d, rate, mode, 3, true);
    for (int block = 0; block < 50; ++block) { reference.run(); moving.run(); }
    moving.identity->editDuringProcess = &moving.controls[66];
    snapshot &= reference.run() && moving.run() && reference.matches(moving);
    // Snapshot now sees +1 dB rather than the model's +12 dB edit. A profile
    // transition would mute the chain; a trim glide must keep it audible.
    moving.controls[66] = 1;
    double difference = 0;
    for (int block = 0; block < 80; ++block) {
      noFade &= reference.run() && moving.run();
      double dryEnergy = 0, wetEnergy = 0;
      for (size_t i = 0; i < kBlock; ++i) {
        dryEnergy += reference.output[i] * reference.output[i];
        wetEnergy += moving.output[i] * moving.output[i];
        difference += std::fabs(reference.output[i] - moving.output[i]);
      }
      noFade &= wetEnergy > dryEnergy * .8;
    }
    audible &= difference > .1;
    noFade &= reference.scheduled == 0 && moving.scheduled == 0;
  }
  check(neutral, "ports 60..70 neutral equal unconnected factory audio in all profiles / base and True 8x");
  check(domains, "integration exercises the actual base/768 kHz domains (reported 0/41 frame latency)");
  check(off, "Off ignores nonneutral connected host trims bit-for-bit");
  check(malformed, "host NaN/Inf trims fall back to neutral and stay finite");
  check(snapshot, "trims are captured once per block before amp model processing");
  check(audible, "live trim edits reach DSP at base and oversampled rates");
  check(noFade, "trim automation stays audible without profile fades or worker reloads");
  dlclose(library);
  std::printf("\n%d failures\n", failures);
  return failures ? 1 : 0;
}
