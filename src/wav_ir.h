#pragma once

#include <cstdint>
#include <memory>
#include <vector>

namespace NAMRig {
class WavIR {
public:
  static std::unique_ptr<WavIR> load(const char* path, double hostRate, int maxBlockSize);
  ~WavIR();
  // normalizationMode: 0 preserve capture level, 1 peak-normalize,
  // 2 energy/loudness normalize (the historical default).
  void process(float* samples, uint32_t count, int normalizationMode) noexcept;

private:
  WavIR(std::vector<float> taps, int maxBlockSize);
  std::vector<float> reversedTaps;
  std::vector<float> historyAndInput;
  std::vector<float> output;
  float peakScale = 1.0f;
  float loudnessScale = 1.0f;
  uint32_t maxBlock = 0;
};
}
