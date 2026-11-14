#pragma once

#include <array>
#include <cstdint>
#include <memory>
#include <utility>
#include <vector>

#include "dsp_accel.h"

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
  struct StereoIR {
    std::unique_ptr<WavIR> left;
    std::unique_ptr<WavIR> right;
  };
  // channel: -1 sums every channel to mono, otherwise selects one channel.
  // When autoTrimSilence is true, trims leading digital silence (< -80 dB vs
  // global peak across all channels) uniformly across channels before resampling.
  static std::unique_ptr<WavIR> load(const char* path, double hostRate,
                                     int maxBlockSize, int channel = -1,
                                     bool autoTrimSilence = false);
  // Loads 1-ch (left only), 2-ch (L/R), or >2-ch (balanced surround/multi-mic
  // stereo folddown with linked normalization) WAV IRs.
  static StereoIR loadStereo(const char* path, double hostRate, int maxBlockSize,
                             bool autoTrimSilence = false);
  // Peak/Loudness normalization for a stereo IR must use one linked scale so
  // the source file's inter-channel balance is preserved.
  static void linkStereoNormalization(WavIR& left, WavIR& right) noexcept;
  static unsigned channelCount(const char* path);
  // The exact taps load() convolves with (resampled, transfer-scaled, 170 ms
  // tapered), before normalization. Used for offline cab screening.
  static std::vector<float> loadTaps(const char* path, double hostRate,
                                     int channel = -1,
                                     bool autoTrimSilence = false);
  // Stereo taps for 2-ch and >2-ch multichannel WAV IRs before normalization.
  static std::pair<std::vector<float>, std::vector<float>> loadTapsStereo(
      const char* path, double hostRate, bool autoTrimSilence = false);
  static constexpr double kMaxSeconds = 0.17;

  // Compact worker-computed low-band complex response (45..210 Hz) used for
  // lock-free coherence estimation in dualCabShelf.
  struct LowBandSignature {
    static constexpr size_t kBins = 24;
    static constexpr float kMinHz = 45.0f;
    static constexpr float kMaxHz = 210.0f;
    std::array<float, kBins> re{};
    std::array<float, kBins> im{};
    float energy = 0.0f;
  };
  const LowBandSignature& lowBandSignature() const noexcept { return lowBand; }

  // Band-averaged cosine coherence of two ideal in-phase signals shifted by
  // alignmentMs across [45..210 Hz]. Equals +1.0 at alignmentMs == 0.
  static float nominalLowBandDelayCoherence(float alignmentMs) noexcept;
  // Signed low-band cross-correlation [-1..+1] between irA and irB at signed
  // alignmentMs (negative delays A, positive delays B). Falls back cleanly to
  // nominalLowBandDelayCoherence if either branch is non-WAV (nullptr) or silent.
  static float lowBandCoherence(const WavIR* irA, const WavIR* irB,
                                float alignmentMs) noexcept;

  struct AlignmentResult {
    bool valid = false;
    float delayMs = 0.0f;       // [-10, +10]; negative delays A, positive delays B
    bool invertPolarity = false;
    float correlation = 0.0f;   // signed normalized peak correlation [-1, +1]
  };
  static AlignmentResult findBestAlignment(const char* pathA, const char* pathB,
                                           double sampleRate = 48000.0,
                                           bool autoTrimSilence = false);

  ~WavIR();
  // normalizationMode: 1 peak, 2 loudness; all other values use loudness.
  void process(float* samples, uint32_t count, int normalizationMode) noexcept;

private:
  WavIR(std::vector<float> taps, double sampleRate, int maxBlockSize);
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
  std::unique_ptr<DSP::RealFFT> fft;
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
  double responsePeak = 0.0;
  double responseRms = 0.0;
  LowBandSignature lowBand{};
  float currentScale = 1.0f;
  float scaleSmoothCoeff = 1.0f;
  bool scaleInitialized = false;
};
}
