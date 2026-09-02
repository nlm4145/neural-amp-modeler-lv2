#include "phase_lanes.h"
#include <NeuralAudioCApi.h>

#include <array>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <future>
#include <vector>

namespace {
constexpr size_t kFactor = 4;

struct Bank {
  NeuralModelLoader* loader = CreateLoader();
  std::array<NeuralModel*, kFactor> models{};
  std::array<std::vector<float>, kFactor> input;
  std::array<std::vector<float>, kFactor> output;
  size_t cursor = 0;

  explicit Bank(const std::filesystem::path& path) {
    SetDefaultMaxAudioBufferSize(loader, 513);
    for (size_t phase = 0; phase < kFactor; ++phase) {
      models[phase] = CreateModelFromFile(loader, path.wstring().c_str());
      input[phase].resize(513);
      output[phase].resize(513);
    }
  }

  ~Bank() {
    for (auto* model : models) DeleteModel(model);
    DeleteLoader(loader);
  }

  bool valid() const {
    for (auto* model : models) if (!model) return false;
    return true;
  }

  void process(float* samples, size_t count, bool parallel) {
    const auto lengths = NAMRig::deinterleavePhases(
        samples, count, kFactor, input, cursor);
    std::array<std::future<void>, kFactor - 1> futures;
    if (parallel) {
      for (size_t phase = 1; phase < kFactor; ++phase)
        futures[phase - 1] = std::async(std::launch::async, [&, phase] {
          Process(models[phase], input[phase].data(), output[phase].data(),
                  lengths[phase]);
        });
    } else {
      for (size_t phase = 1; phase < kFactor; ++phase)
        Process(models[phase], input[phase].data(), output[phase].data(),
                lengths[phase]);
    }
    Process(models[0], input[0].data(), output[0].data(), lengths[0]);
    if (parallel)
      for (auto& future : futures) future.get();
    NAMRig::interleavePhases(output, samples, count, kFactor, cursor);
    cursor = (cursor + count) % kFactor;
  }
};
}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) return 2;
  Bank serial(argv[1]), parallel(argv[1]);
  if (!serial.valid() || !parallel.valid()) return 1;
  double phase = 0.0;
  for (size_t block : {64u, 127u, 256u, 511u, 93u, 512u}) {
    std::vector<float> a(block), b;
    for (auto& sample : a) {
      sample = 0.2f * std::sin(static_cast<float>(phase));
      phase += 0.017;
    }
    b = a;
    serial.process(a.data(), a.size(), false);
    parallel.process(b.data(), b.size(), true);
    if (a != b) {
      std::puts("  FAIL  serial and parallel phase models differ");
      return 1;
    }
  }
  std::puts("  PASS  serial and parallel recurrent phase models are bit-exact");
  return 0;
}
