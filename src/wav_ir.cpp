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

WavIR::WavIR(std::vector<float> taps, int maxBlockSize) {
  (void)maxBlockSize;  // chunking is internal (kBlock); any call size works
  double energy = 0.0;
  float peak = 0.0f;
  for (float tap : taps) {
    energy += static_cast<double>(tap) * tap;
    peak = std::max(peak, std::fabs(tap));
  }
  if (peak > 0.0f) peakScale = 1.0f / peak;
  if (energy > 0.0) loudnessScale = static_cast<float>(1.0 / std::sqrt(energy));

  const size_t headLen = std::min<size_t>(taps.size(), kBlock);
  reversedHead.assign(taps.rbegin() + (taps.size() - headLen), taps.rend());
  historyAndInput.assign(headLen - 1 + kBlock, 0.0f);
  headOut.assign(kBlock, 0.0f);

  if (taps.size() <= kBlock) return;
  partitions = static_cast<uint32_t>((taps.size() - kBlock + kBlock - 1) / kBlock);
  fftSetup = vDSP_create_fftsetup(kLog2Fft, kFFTRadix2);
  tailSpectra.assign(static_cast<size_t>(partitions) * 2 * kBins, 0.0f);
  tailNyq.assign(partitions, 0.0f);
  fdl.assign(static_cast<size_t>(partitions) * 2 * kBins, 0.0f);
  fdlNyq.assign(partitions, 0.0f);
  fillBuf.assign(kBlock, 0.0f);
  ring.assign(kRing, 0.0f);
  fftTime.assign(kFft, 0.0f);
  accRe.assign(kBins, 0.0f);
  accIm.assign(kBins, 0.0f);
  const float scale = 1.0f / (4.0f * static_cast<float>(kFft));
  for (uint32_t p = 0; p < partitions; ++p) {
    const size_t start = kBlock + static_cast<size_t>(p) * kBlock;
    const size_t len = std::min<size_t>(kBlock, taps.size() - start);
    std::memset(fftTime.data(), 0, kFft * sizeof(float));
    std::memcpy(fftTime.data(), taps.data() + start, len * sizeof(float));
    DSPSplitComplex sp{tailSpectra.data() + static_cast<size_t>(p) * 2 * kBins,
                       tailSpectra.data() + static_cast<size_t>(p) * 2 * kBins + kBins};
    vDSP_ctoz(reinterpret_cast<const DSPComplex*>(fftTime.data()), 2, &sp, 1, kBins);
    vDSP_fft_zrip(fftSetup, &sp, 1, kLog2Fft, kFFTDirection_Forward);
    tailNyq[p] = sp.imagp[0] * scale;
    sp.imagp[0] = 0.0f;
    vDSP_vsmul(sp.realp, 1, &scale, sp.realp, 1, kBins);
    vDSP_vsmul(sp.imagp, 1, &scale, sp.imagp, 1, kBins);
  }
}

WavIR::~WavIR() {
  if (fftSetup) vDSP_destroy_fftsetup(fftSetup);
}

std::unique_ptr<WavIR> WavIR::load(const char* path, double hostRate, int maxBlockSize) {
  uint32_t sourceRate = 0;
  auto taps = resample(readWav(path, sourceRate), sourceRate, hostRate);
  // Guitar cabinet IR energy is concentrated near the start; 80 ms keeps
  // natural tails. A hard cut rings (truncation ripple in the transfer
  // function), so the last ~5 ms taper with a raised cosine.
  const size_t maxTaps = static_cast<size_t>(hostRate * 0.08);
  if (maxTaps > 0 && taps.size() > maxTaps) {
    taps.resize(maxTaps);
    const size_t fade = std::min(taps.size(),
        static_cast<size_t>(std::llround(hostRate * 0.005)));
    for (size_t i = 0; i < fade; ++i) {
      const double t = static_cast<double>(i + 1) / static_cast<double>(fade);
      taps[taps.size() - fade + i] *= static_cast<float>(0.5 * (1.0 + std::cos(kPi * t)));
    }
  }
  if (taps.empty()) throw std::runtime_error("empty WAV impulse response");

  // Keep the resampled capture level intact. WavIR stores peak and energy
  // scales so the user can change normalization instantly without reloading
  // or destructively altering the taps. Mode 2 preserves the old default.
  return std::unique_ptr<WavIR>(new WavIR(std::move(taps), maxBlockSize));
}

// Completed kBlock input block: FFT it into the delay line, accumulate
// Y = sum_p X[newest-p] * H[p] (one complex MAC pass per partition), IFFT,
// and overlap-add the kFft result into the ring starting at the CURRENT
// read position — which is exactly the first output sample the tail may
// touch (see the header comment).
void WavIR::flushBlock() noexcept {
  std::memcpy(fftTime.data(), fillBuf.data(), kBlock * sizeof(float));
  std::memset(fftTime.data() + kBlock, 0, kBlock * sizeof(float));
  fdlNewest = fdlNewest + 1 == partitions ? 0 : fdlNewest + 1;
  DSPSplitComplex x{fdl.data() + static_cast<size_t>(fdlNewest) * 2 * kBins,
                    fdl.data() + static_cast<size_t>(fdlNewest) * 2 * kBins + kBins};
  vDSP_ctoz(reinterpret_cast<const DSPComplex*>(fftTime.data()), 2, &x, 1, kBins);
  vDSP_fft_zrip(fftSetup, &x, 1, kLog2Fft, kFFTDirection_Forward);
  fdlNyq[fdlNewest] = x.imagp[0];
  x.imagp[0] = 0.0f;

  std::memset(accRe.data(), 0, kBins * sizeof(float));
  std::memset(accIm.data(), 0, kBins * sizeof(float));
  DSPSplitComplex acc{accRe.data(), accIm.data()};
  float nyqAcc = 0.0f;
  for (uint32_t p = 0; p < partitions; ++p) {
    const uint32_t slot = fdlNewest >= p ? fdlNewest - p
                                         : fdlNewest + partitions - p;
    DSPSplitComplex xs{fdl.data() + static_cast<size_t>(slot) * 2 * kBins,
                       fdl.data() + static_cast<size_t>(slot) * 2 * kBins + kBins};
    DSPSplitComplex hs{tailSpectra.data() + static_cast<size_t>(p) * 2 * kBins,
                       tailSpectra.data() + static_cast<size_t>(p) * 2 * kBins + kBins};
    vDSP_zvma(&xs, 1, &hs, 1, &acc, 1, &acc, 1, kBins);
    nyqAcc += fdlNyq[slot] * tailNyq[p];
  }
  accIm[0] = nyqAcc;
  vDSP_fft_zrip(fftSetup, &acc, 1, kLog2Fft, kFFTDirection_Inverse);
  vDSP_ztoc(&acc, 1, reinterpret_cast<DSPComplex*>(fftTime.data()), 2, kBins);

  const uint32_t first = std::min(kFft, kRing - ringPos);
  vDSP_vadd(ring.data() + ringPos, 1, fftTime.data(), 1,
            ring.data() + ringPos, 1, first);
  if (first < kFft)
    vDSP_vadd(ring.data(), 1, fftTime.data() + first, 1, ring.data(), 1,
              kFft - first);
  fillPos = 0;
}

void WavIR::process(float* samples, uint32_t count, int normalizationMode) noexcept {
  const float scale = normalizationMode <= 0 ? 1.0f
                    : normalizationMode == 1 ? peakScale
                                             : loudnessScale;
  const uint32_t headLen = static_cast<uint32_t>(reversedHead.size());
  const uint32_t history = headLen - 1;
  uint32_t done = 0;
  while (done < count) {
    // Sub-chunks end exactly on kBlock input boundaries so a completed
    // block always flushes before the sample that first needs its tail.
    const uint32_t t = partitions
        ? std::min(count - done, kBlock - fillPos)
        : std::min(count - done, kBlock);
    std::memcpy(historyAndInput.data() + history, samples + done, t * sizeof(float));
    vDSP_conv(historyAndInput.data(), 1, reversedHead.data(), 1,
              headOut.data(), 1, t, headLen);
    if (history) std::memmove(historyAndInput.data(), historyAndInput.data() + t,
                              history * sizeof(float));
    if (partitions) {
      std::memcpy(fillBuf.data() + fillPos, samples + done, t * sizeof(float));
      fillPos += t;
      for (uint32_t i = 0; i < t; ++i) {
        const uint32_t rp = (ringPos + i) & kRingMask;
        samples[done + i] = (headOut[i] + ring[rp]) * scale;
        ring[rp] = 0.0f;
      }
      ringPos = (ringPos + t) & kRingMask;
      if (fillPos == kBlock) flushBlock();
    } else {
      for (uint32_t i = 0; i < t; ++i) samples[done + i] = headOut[i] * scale;
    }
    done += t;
  }
}
}
