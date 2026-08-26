#pragma once

#include <cstdint>
#include <memory>
#include <vector>

namespace NAMRig {
class WavIR {
public:
  static std::unique_ptr<WavIR> load(const char* path, double hostRate, int maxBlockSize);
  ~WavIR();
  void process(float* samples, uint32_t count) noexcept;

private:
  WavIR(std::vector<float> taps, int maxBlockSize);
  std::vector<float> reversedTaps;
  std::vector<float> historyAndInput;
  std::vector<float> output;
  uint32_t maxBlock = 0;
};
}
