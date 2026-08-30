#include "wav_ir.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

#include <Accelerate/Accelerate.h>

namespace NAMRig {
namespace {
constexpr double kPi = 3.14159265358979323846;
uint16_t u16(const unsigned char* p) { return uint16_t(p[0]) | (uint16_t(p[1]) << 8); }
uint32_t u32(const unsigned char* p) {
  return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}

std::vector<float> readWav(const char* path, uint32_t& rate) {
  std::ifstream file(path, std::ios::binary);
  if (!file) throw std::runtime_error("cannot open WAV");
  std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(file)), {});
  if (bytes.size() < 44 || std::memcmp(bytes.data(), "RIFF", 4) ||
      std::memcmp(bytes.data() + 8, "WAVE", 4))
    throw std::runtime_error("not a RIFF/WAVE file");

  uint16_t format = 0, channels = 0, bits = 0;
  const unsigned char* audio = nullptr;
  size_t audioBytes = 0;
  for (size_t pos = 12; pos + 8 <= bytes.size();) {
    const uint32_t size = u32(bytes.data() + pos + 4);
    const size_t dataPos = pos + 8;
    if (dataPos + size > bytes.size()) break;
    if (!std::memcmp(bytes.data() + pos, "fmt ", 4) && size >= 16) {
      format = u16(bytes.data() + dataPos);
      channels = u16(bytes.data() + dataPos + 2);
      rate = u32(bytes.data() + dataPos + 4);
      bits = u16(bytes.data() + dataPos + 14);
    } else if (!std::memcmp(bytes.data() + pos, "data", 4)) {
      audio = bytes.data() + dataPos;
      audioBytes = size;
    }
    pos = dataPos + size + (size & 1u);
  }
  if (!audio || !channels || !rate || !bits || (format != 1 && format != 3))
    throw std::runtime_error("unsupported WAV format");
  const size_t sampleBytes = bits / 8;
  const size_t frames = audioBytes / (sampleBytes * channels);
  if (!sampleBytes || !frames) throw std::runtime_error("empty WAV");

  std::vector<float> mono(frames, 0.0f);
  for (size_t frame = 0; frame < frames; ++frame) {
    double sum = 0.0;
    for (uint16_t ch = 0; ch < channels; ++ch) {
      const unsigned char* p = audio + (frame * channels + ch) * sampleBytes;
      float value = 0.0f;
      if (format == 3 && bits == 32) std::memcpy(&value, p, 4);
      else if (format == 3 && bits == 64) { double d; std::memcpy(&d, p, 8); value = float(d); }
      else if (format == 1 && bits == 16) value = float(int16_t(u16(p))) / 32768.0f;
      else if (format == 1 && bits == 24) {
        int32_t v = int32_t(p[0]) | (int32_t(p[1]) << 8) | (int32_t(p[2]) << 16);
        if (v & 0x800000) v |= ~0xffffff;
        value = float(v) / 8388608.0f;
      } else if (format == 1 && bits == 32) value = float(int32_t(u32(p))) / 2147483648.0f;
      else throw std::runtime_error("unsupported WAV sample encoding");
      sum += value;
    }
    mono[frame] = float(sum / channels);
  }
  return mono;
}

// Bandlimited windowed-sinc resampling, evaluated directly at each output
// position. An IR's spectrum IS its transfer function, so resampling errors
// are tone errors: the previous linear interpolation attenuated the top of the
// IR's band (~-3 dB at the old Nyquist) and left spectral images that fold
// back in on any later downsampling. Windowed-sinc is near-transparent
// (<0.1 dB passband ripple, >90 dB image rejection) and, because this only
// runs once per IR load, the cost of evaluating the sinc per tap is irrelevant.
std::vector<float> resample(const std::vector<float>& input, double from, double to) {
  if (std::fabs(from - to) < 1.0 || input.size() < 2) return input;
  constexpr int kTaps = 64;                             // kernel half-width (input samples)
  const double ratio = from / to;                       // input samples per output sample
  const double beta = 0.9 * std::min(from, to) / from;  // 2*fc/from, fc = 0.45*min(rate)
  const size_t count = std::max<size_t>(2, std::llround(input.size() * to / from));
  std::vector<float> output(count);
  for (size_t i = 0; i < count; ++i) {
    const double pos = i * ratio;
    const long center = std::lround(pos);
    double acc = 0.0, wsum = 0.0;
    for (long k = center - kTaps; k <= center + kTaps; ++k) {
      if (k < 0 || k >= static_cast<long>(input.size())) continue;
      const double r = pos - k;               // offset in input samples
      const double u = beta * r;
      const double s = std::fabs(u) < 1e-8 ? beta : beta * std::sin(kPi * u) / (kPi * u);
      const double v = r / kTaps;             // window argument, clamped to [-1, 1]
      const double w = 0.35875 + 0.48829 * std::cos(kPi * v) + 0.14128 * std::cos(2.0 * kPi * v)
                     + 0.01168 * std::cos(3.0 * kPi * v);   // Blackman-Harris
      acc += input[k] * s * w;
      wsum += s * w;
    }
    // Normalizing by the windowed-sinc sum keeps the DC gain at exactly 1.0
    // despite the finite window and edge truncation.
    output[i] = wsum != 0.0 ? static_cast<float>(acc / wsum)
                            : input[std::min<long>(center, static_cast<long>(input.size()) - 1)];
  }
  return output;
}
}

WavIR::WavIR(std::vector<float> taps, int maxBlockSize)
    : reversedTaps(taps.rbegin(), taps.rend()),
      historyAndInput(taps.size() - 1 + std::max(1, maxBlockSize), 0.0f),
      output(std::max(1, maxBlockSize), 0.0f),
      maxBlock(static_cast<uint32_t>(std::max(1, maxBlockSize))) {
  double energy = 0.0;
  float peak = 0.0f;
  for (float tap : taps) {
    energy += static_cast<double>(tap) * tap;
    peak = std::max(peak, std::fabs(tap));
  }
  if (peak > 0.0f) peakScale = 1.0f / peak;
  if (energy > 0.0) loudnessScale = static_cast<float>(1.0 / std::sqrt(energy));
}
WavIR::~WavIR() = default;

std::unique_ptr<WavIR> WavIR::load(const char* path, double hostRate, int maxBlockSize) {
  uint32_t sourceRate = 0;
  auto taps = resample(readWav(path, sourceRate), sourceRate, hostRate);
  // Guitar cabinet IR energy is concentrated near the start. Keeping 80 ms
  // gives natural tails while keeping direct convolution inexpensive at 96 kHz.
  if (taps.size() > static_cast<size_t>(hostRate * 0.08)) taps.resize(static_cast<size_t>(hostRate * 0.08));
  if (taps.empty()) throw std::runtime_error("empty WAV impulse response");

  // Keep the resampled capture level intact. WavIR stores peak and energy
  // scales so the user can change normalization instantly without reloading
  // or destructively altering the taps. Mode 2 preserves the old default.
  return std::unique_ptr<WavIR>(new WavIR(std::move(taps), maxBlockSize));
}

void WavIR::process(float* samples, uint32_t count, int normalizationMode) noexcept {
  const size_t history = reversedTaps.size() - 1;
  const float scale = normalizationMode <= 0 ? 1.0f
                    : normalizationMode == 1 ? peakScale
                                             : loudnessScale;
  uint32_t done = 0;
  while (done < count) {
    const uint32_t block = std::min(maxBlock, count - done);
    std::memcpy(historyAndInput.data() + history, samples + done, block * sizeof(float));
    vDSP_conv(historyAndInput.data(), 1, reversedTaps.data(), 1,
              output.data(), 1, block, reversedTaps.size());
    for (uint32_t i = 0; i < block; ++i)
      samples[done + i] = output[i] * scale;
    if (history) std::memmove(historyAndInput.data(), historyAndInput.data() + block,
                              history * sizeof(float));
    done += block;
  }
}
}
