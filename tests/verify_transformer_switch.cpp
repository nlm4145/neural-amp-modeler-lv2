/* End-to-end transformer-switch regression against a built rig plugin.
 *
 * Loads a real bundled NAM amp through the LV2 worker interface, lets the
 * click-safe model transition settle, then switches Captured -> Studio Linear
 * -> Modern.  Every selection must fade back to audible, finite output.
 *
 * Build:
 *   clang++ -O2 -std=c++17 -Ideps/lv2/include \
 *     tests/verify_transformer_switch.cpp -o /tmp/verify_transformer_switch
 */
#include <dlfcn.h>
#include <lv2/atom/atom.h>
#include <lv2/core/lv2.h>
#include <lv2/urid/urid.h>
#include <lv2/worker/worker.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr unsigned kMaxFileName = 1024;
enum class Stage : uint32_t { Pedal = 0, Amp = 1, Cab = 2 };
enum WorkType : uint32_t { WorkLoad, WorkSwitch, WorkFree };

// These mirror the public worker-message ABI in nam_rig_plugin.h without
// pulling the NeuralAudio C++ implementation into this small dlopen harness.
struct LoadMessage {
  WorkType type;
  Stage stage;
  int32_t oversampleMode;
  uint64_t generation;
  char path[kMaxFileName];
};

struct SwitchMessage {
  WorkType type;
  Stage stage;
  int32_t oversampleMode;
  uint64_t generation;
  char path[kMaxFileName];
  void* model;
  void* ir;
  bool fullRig;
};

std::vector<std::string> uris;
LV2_URID mapUri(LV2_URID_Map_Handle, const char* uri) {
  const auto found = std::find(uris.begin(), uris.end(), uri);
  if (found != uris.end())
    return static_cast<LV2_URID>(found - uris.begin() + 1);
  uris.emplace_back(uri);
  return static_cast<LV2_URID>(uris.size());
}

LV2_Worker_Status scheduleWork(LV2_Worker_Schedule_Handle, uint32_t,
                               const void*) {
  // Model deletion requests are immaterial to this short-lived harness. The
  // installed model is owned by the plugin and is deleted during cleanup.
  return LV2_WORKER_SUCCESS;
}

std::vector<uint8_t> workerResponse;
LV2_Worker_Status captureResponse(LV2_Worker_Respond_Handle, uint32_t size,
                                  const void* data) {
  const auto* bytes = static_cast<const uint8_t*>(data);
  workerResponse.assign(bytes, bytes + size);
  return LV2_WORKER_SUCCESS;
}

int failures = 0;
void check(bool condition, const char* message) {
  std::printf("  %s  %s\n", condition ? "PASS" : "FAIL", message);
  if (!condition) ++failures;
}

} // namespace

int main(int argc, char** argv) {
  if (argc != 3 && argc != 5) {
    std::printf("usage: verify_transformer_switch <rig .so> <amp .nam> "
                "[sample-rate oversample-mode]\n");
    return 1;
  }
  const double sampleRate = argc == 5 ? std::strtod(argv[3], nullptr) : 48000.0;
  const int oversampleMode = argc == 5 ? std::atoi(argv[4]) : 0;

  void* library = dlopen(argv[1], RTLD_NOW);
  if (!library) {
    std::printf("  FAIL  dlopen: %s\n", dlerror());
    return 1;
  }
  using DescriptorFn = const LV2_Descriptor* (*)(uint32_t);
  auto descriptorFn = reinterpret_cast<DescriptorFn>(
      dlsym(library, "lv2_descriptor"));
  if (!descriptorFn) {
    std::printf("  FAIL  missing lv2_descriptor\n");
    return 1;
  }
  const LV2_Descriptor* descriptor = descriptorFn(0);
  const auto* worker = static_cast<const LV2_Worker_Interface*>(
      descriptor->extension_data(LV2_WORKER__interface));
  check(worker != nullptr, "plugin exposes the LV2 worker interface");
  if (!worker) return 1;

  LV2_URID_Map map{nullptr, mapUri};
  LV2_Worker_Schedule schedule{nullptr, scheduleWork};
  LV2_Feature mapFeature{LV2_URID__map, &map};
  LV2_Feature scheduleFeature{LV2_WORKER__schedule, &schedule};
  const LV2_Feature* features[] = {&mapFeature, &scheduleFeature, nullptr};
  LV2_Handle instance = descriptor->instantiate(descriptor, sampleRate, "", features);
  check(instance != nullptr, "instantiate at requested sample rate");
  if (!instance) return 1;

  constexpr uint32_t kBlock = 128;
  constexpr uint32_t kAtomBytes = 16384;
  alignas(LV2_Atom_Sequence) uint8_t control[kAtomBytes]{};
  alignas(LV2_Atom_Sequence) uint8_t notify[kAtomBytes]{};
  float input[kBlock]{}, output[kBlock]{}, outputRight[kBlock]{}, ports[32]{};
  ports[7] = ports[8] = ports[9] = ports[10] = 1.0f;
  ports[15] = -80.0f;
  ports[20] = ports[21] = static_cast<float>(oversampleMode);
  ports[23] = 150.0f;
  ports[27] = 20000.0f;

  descriptor->connect_port(instance, 0, control);
  descriptor->connect_port(instance, 1, notify);
  descriptor->connect_port(instance, 2, input);
  descriptor->connect_port(instance, 3, output);
  for (uint32_t port = 4; port <= 30; ++port)
    descriptor->connect_port(instance, port, &ports[port]);
  descriptor->connect_port(instance, 31, outputRight);

  double phase = 0.0;
  const double step = 2.0 * 3.14159265358979323846 * 220.0 / sampleRate;
  auto runBlock = [&]() {
    auto* sequence = reinterpret_cast<LV2_Atom_Sequence*>(control);
    sequence->atom.size = sizeof(LV2_Atom_Sequence_Body);
    sequence->atom.type = mapUri(nullptr, LV2_ATOM__Sequence);
    reinterpret_cast<LV2_Atom_Sequence*>(notify)->atom.size =
        kAtomBytes - sizeof(LV2_Atom);
    for (float& sample : input) {
      sample = 0.1f * static_cast<float>(std::sin(phase));
      phase += step;
    }
    descriptor->run(instance, kBlock);
  };

  // Latch the controls before the manual worker request, including the mode
  // selected by this test invocation.
  runBlock();

  LoadMessage load{WorkLoad, Stage::Amp, oversampleMode, 0, {}};
  const size_t pathLength = std::strlen(argv[2]);
  check(pathLength < kMaxFileName, "model path fits worker message");
  if (pathLength >= kMaxFileName) return 1;
  std::memcpy(load.path, argv[2], pathLength + 1);
  workerResponse.clear();
  const auto workStatus = worker->work(instance, captureResponse, nullptr,
                                       sizeof(load), &load);
  check(workStatus == LV2_WORKER_SUCCESS &&
            workerResponse.size() == sizeof(SwitchMessage),
        "worker loads bundled amp model");
  if (workerResponse.size() != sizeof(SwitchMessage)) return 1;
  const auto responseStatus = worker->work_response(
      instance, static_cast<uint32_t>(workerResponse.size()),
      workerResponse.data());
  check(responseStatus == LV2_WORKER_SUCCESS, "audio thread accepts loaded model");

  auto settledRms = [&](int profile) {
    ports[30] = static_cast<float>(profile);
    double energy = 0.0;
    bool finite = true;
    // 40 blocks is far beyond both 5 ms transition halves and model warm-up.
    for (int block = 0; block < 40; ++block) {
      runBlock();
      if (block >= 32) {
        for (float sample : output) {
          finite = finite && std::isfinite(sample);
          energy += static_cast<double>(sample) * sample;
        }
      }
    }
    return finite ? std::sqrt(energy / (8.0 * kBlock)) : -1.0;
  };

  const double captured = settledRms(0);
  const double studio = settledRms(9);
  const double modern = settledRms(1);
  char result[256];
  std::snprintf(result, sizeof(result),
                "switches recover: Captured %.6f, Studio %.6f, Modern %.6f RMS",
                captured, studio, modern);
  check(captured > 1.0e-5 && studio > 1.0e-5 && modern > 1.0e-5, result);
  check(studio < captured * 2.0 && studio > captured * 0.5,
        "Studio Linear remains within +/-6 dB of Captured after settling");

  descriptor->cleanup(instance);
  dlclose(library);
  std::printf(failures ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n",
              failures);
  return failures ? 1 : 0;
}
