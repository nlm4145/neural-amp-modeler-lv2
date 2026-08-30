#pragma once

#include <cstdint>
#include <memory>
#include <vector>

#include <Accelerate/Accelerate.h>

namespace NAMRig {
// Cab impulse response convolution with ZERO added latency:
//   - taps [0, kBlock): direct vDSP_conv (the head), any chunk size.
//   - taps [kBlock, end): uniform partitioned FFT convolution (the tail).
//     Input is assembled into fixed kBlock blocks. A block's contribution
//     through partition p starts (p+1)*kBlock samples after the block's own
//     first sample, so the earliest tail output lands exactly one sample
//     AFTER the block completes — a completed block's spectrum enters a
//     frequency-domain delay line, one MAC + one IFFT per block overlap-adds
//     the tail into an output ring, and head + tail together equal a single
//     direct convolution with no lookahead.
class WavIR {
public:
  static std::unique_ptr<WavIR> load(const char* path, double hostRate, int maxBlockSize);
  ~WavIR();
  // normalizationMode: 0 preserve capture level, 1 peak-normalize,
  // 2 energy/loudness normalize (the historical default).
  void process(float* samples, uint32_t count, int normalizationMode) noexcept;

private:
  WavIR(std::vector<float> taps, int maxBlockSize);
  void flushBlock() noexcept;

  static constexpr uint32_t kBlock = 256;      // head length + partition size
  static constexpr uint32_t kFft = 2 * kBlock;
  static constexpr uint32_t kLog2Fft = 9;
  static constexpr uint32_t kBins = kFft / 2;  // packed real spectrum size
  static constexpr uint32_t kRing = 4 * kBlock;
  static constexpr uint32_t kRingMask = kRing - 1;
  static_assert((1u << kLog2Fft) == kFft);
  static_assert((kRing & kRingMask) == 0);

  // Head: direct convolution state (history + current sub-chunk).
  std::vector<float> reversedHead;
  std::vector<float> historyAndInput;
  std::vector<float> headOut;

  // Tail: spectra are split-complex (re then im, kBins each). The packed
  // vDSP real-FFT format stores the Nyquist bin in imagp[0], which would
  // corrupt a plain complex multiply — so imagp[0] is zeroed everywhere and
  // the Nyquist bins are accumulated separately (tailNyq/fdlNyq). The vDSP
  // forward+inverse round-trip scale, 1/(4*kFft), is folded into the stored
  // partition spectra at load time.
  uint32_t partitions = 0;
  FFTSetup fftSetup = nullptr;
  std::vector<float> tailSpectra;  // partitions * 2 * kBins
  std::vector<float> tailNyq;      // partitions
  std::vector<float> fdl;          // partitions * 2 * kBins
  std::vector<float> fdlNyq;       // partitions
  uint32_t fdlNewest = 0;
  std::vector<float> fillBuf;      // kBlock input assembly
  uint32_t fillPos = 0;
  std::vector<float> ring;         // kRing overlap-add output accumulator
  uint32_t ringPos = 0;
  std::vector<float> fftTime;      // kFft time-domain workspace
  std::vector<float> accRe, accIm; // kBins spectrum accumulator

  float peakScale = 1.0f;
  float loudnessScale = 1.0f;
};
}
