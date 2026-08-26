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

std::vector<float> resample(const std::vector<float>& input, double from, double to) {
  if (std::fabs(from - to) < 1.0 || input.size() < 2) return input;
  const size_t count = std::max<size_t>(2, std::llround(input.size() * to / from));
  std::vector<float> output(count);
  const double step = from / to;
  for (size_t i = 0; i < count; ++i) {
    const double source = std::min<double>(i * step, input.size() - 1);
    const size_t a = static_cast<size_t>(source);
    const size_t b = std::min(a + 1, input.size() - 1);
    const float mix = float(source - a);
    output[i] = input[a] + (input[b] - input[a]) * mix;
  }
  return output;
}
}

WavIR::WavIR(std::vector<float> taps, int maxBlockSize)
    : reversedTaps(taps.rbegin(), taps.rend()),
      historyAndInput(taps.size() - 1 + std::max(1, maxBlockSize), 0.0f),
      output(std::max(1, maxBlockSize), 0.0f),
      maxBlock(static_cast<uint32_t>(std::max(1, maxBlockSize))) {}
WavIR::~WavIR() = default;

std::unique_ptr<WavIR> WavIR::load(const char* path, double hostRate, int maxBlockSize) {
  uint32_t sourceRate = 0;
  auto taps = resample(readWav(path, sourceRate), sourceRate, hostRate);
  // Guitar cabinet IR energy is concentrated near the start. Keeping 80 ms
  // gives natural tails while keeping direct convolution inexpensive at 96 kHz.
  if (taps.size() > static_cast<size_t>(hostRate * 0.08)) taps.resize(static_cast<size_t>(hostRate * 0.08));
  if (taps.empty()) throw std::runtime_error("empty WAV impulse response");
  return std::unique_ptr<WavIR>(new WavIR(std::move(taps), maxBlockSize));
}

void WavIR::process(float* samples, uint32_t count) noexcept {
  const size_t history = reversedTaps.size() - 1;
  uint32_t done = 0;
  while (done < count) {
    const uint32_t block = std::min(maxBlock, count - done);
    std::memcpy(historyAndInput.data() + history, samples + done, block * sizeof(float));
    vDSP_conv(historyAndInput.data(), 1, reversedTaps.data(), 1,
              output.data(), 1, block, reversedTaps.size());
    std::memcpy(samples + done, output.data(), block * sizeof(float));
    if (history) std::memmove(historyAndInput.data(), historyAndInput.data() + block,
                              history * sizeof(float));
    done += block;
  }
}
}
