#include "wav_ir.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "dsp_accel.h"

namespace NAMRig {
namespace {
constexpr double kPi = 3.14159265358979323846;
uint16_t u16(const unsigned char* p) { return uint16_t(p[0]) | (uint16_t(p[1]) << 8); }
uint32_t u32(const unsigned char* p) {
  return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}

struct WavInfo {
  uint16_t format = 0, channels = 0, bits = 0;
  uint32_t rate = 0;
  const unsigned char* audio = nullptr;
  size_t audioBytes = 0;
};

WavInfo parseWav(const std::vector<unsigned char>& bytes) {
  if (bytes.size() < 44 || std::memcmp(bytes.data(), "RIFF", 4) ||
      std::memcmp(bytes.data() + 8, "WAVE", 4))
    throw std::runtime_error("not a RIFF/WAVE file");
  WavInfo info;
  for (size_t pos = 12; pos + 8 <= bytes.size();) {
    const uint32_t size = u32(bytes.data() + pos + 4);
    const size_t dataPos = pos + 8;
    if (dataPos + size > bytes.size()) break;
    if (!std::memcmp(bytes.data() + pos, "fmt ", 4) && size >= 16) {
      info.format = u16(bytes.data() + dataPos);
      info.channels = u16(bytes.data() + dataPos + 2);
      info.rate = u32(bytes.data() + dataPos + 4);
      info.bits = u16(bytes.data() + dataPos + 14);
      if (info.format == 0xFFFE && size >= 26) info.format = u16(bytes.data() + dataPos + 24);
    } else if (!std::memcmp(bytes.data() + pos, "data", 4)) {
      info.audio = bytes.data() + dataPos;
      info.audioBytes = size;
    }
    pos = dataPos + size + (size & 1u);
  }
  if (!info.audio || !info.channels || !info.rate || !info.bits ||
      (info.format != 1 && info.format != 3))
    throw std::runtime_error("unsupported WAV format");
  return info;
}

std::vector<unsigned char> readFile(const char* path) {
  std::ifstream file(path, std::ios::binary);
  if (!file) throw std::runtime_error("cannot open WAV");
  return std::vector<unsigned char>((std::istreambuf_iterator<char>(file)), {});
}

std::vector<float> readWav(const char* path, uint32_t& rate, int channel) {
  const std::vector<unsigned char> bytes = readFile(path);
  const WavInfo info = parseWav(bytes);
  rate = info.rate;
  const uint16_t format = info.format, channels = info.channels, bits = info.bits;
  if (channel >= channels) throw std::runtime_error("WAV channel out of range");
  const size_t sampleBytes = bits / 8;
  const size_t frames = info.audioBytes / (sampleBytes * channels);
  if (!sampleBytes || !frames) throw std::runtime_error("empty WAV");

  const uint16_t first = channel < 0 ? 0 : static_cast<uint16_t>(channel);
  const uint16_t last = channel < 0 ? channels : static_cast<uint16_t>(channel + 1);
  std::vector<float> mono(frames, 0.0f);
  for (size_t frame = 0; frame < frames; ++frame) {
    double sum = 0.0;
    for (uint16_t ch = first; ch < last; ++ch) {
      const unsigned char* p = info.audio + (frame * channels + ch) * sampleBytes;
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
    mono[frame] = float(sum / (last - first));
  }
  return mono;
}

// Cholesky solver for small symmetric positive-definite matrices (flat n x n).
// Returns an empty vector if matrix conditioning fails so callers can safely
// skip adjustments without emitting NaN/Inf.
std::vector<double> solveSymmetricPositiveDefinite(const std::vector<double>& matrix,
                                                 const std::vector<double>& rhs,
                                                 size_t n) {
  std::vector<double> L(n * n, 0.0);
  for (size_t i = 0; i < n; ++i) {
    for (size_t j = 0; j <= i; ++j) {
      double s = matrix[i * n + j];
      for (size_t k = 0; k < j; ++k) s -= L[i * n + k] * L[j * n + k];
      if (i == j) {
        if (!(s > 0.0) || !std::isfinite(s)) return {};
        L[i * n + j] = std::sqrt(s);
      } else {
        L[i * n + j] = s / L[j * n + j];
      }
    }
  }
  std::vector<double> y(n, 0.0);
  for (size_t i = 0; i < n; ++i) {
    double s = rhs[i];
    for (size_t k = 0; k < i; ++k) s -= L[i * n + k] * y[k];
    y[i] = s / L[i * n + i];
  }
  std::vector<double> x(n, 0.0);
  for (size_t ii = n; ii-- > 0;) {
    double s = y[ii];
    for (size_t k = ii + 1; k < n; ++k) s -= L[k * n + ii] * x[k];
    x[ii] = s / L[ii * n + ii];
    if (!std::isfinite(x[ii])) return {};
  }
  return x;
}

// Fast |H(f)| magnitude estimate across normalized frequencies [0, 0.5] via
// RealFFT, used to weight causal boundary repair proportionally across bands
// (e.g., where cab IRs roll off by -40 dB at high frequencies).
std::vector<double> estimateSpectrumEnvelope(const std::vector<double>& full,
                                             const std::vector<double>& normFreqs,
                                             double& peakMag) {
  const size_t specLen = std::min<size_t>(full.size(), 32768);
  double maxAbs = 0.0;
  for (size_t i = 0; i < specLen; ++i)
    maxAbs = std::max(maxAbs, std::fabs(full[i]));
  peakMag = 1.0;
  if (!(maxAbs > 0.0)) return std::vector<double>(normFreqs.size(), 1.0);

  size_t nFft = 2048;
  while (nFft < specLen) nFft <<= 1;
  const size_t halfBins = nFft / 2;

  std::vector<float> timeBuf(nFft, 0.0f);
  const double invScale = 1.0 / maxAbs;
  for (size_t i = 0; i < specLen; ++i)
    timeBuf[i] = static_cast<float>(full[i] * invScale);

  std::vector<float> re(halfBins, 0.0f);
  std::vector<float> im(halfBins, 0.0f);
  DSP::RealFFT fft(nFft);
  fft.forward(timeBuf.data(), re.data(), im.data());

  // Packed real-FFT format puts DC in re[0] and Nyquist in im[0].
  auto binMag = [&](size_t b) -> double {
    if (b == 0) return std::fabs(static_cast<double>(re[0]));
    if (b >= halfBins) return std::fabs(static_cast<double>(im[0]));
    return std::hypot(static_cast<double>(re[b]), static_cast<double>(im[b]));
  };

  std::vector<double> env(normFreqs.size(), 0.0);
  double peak = 0.0;
  const double maxBin = static_cast<double>(halfBins) - 1.0e-9;
  for (size_t m = 0; m < normFreqs.size(); ++m) {
    const double pos = std::max(0.0, std::min(maxBin, normFreqs[m] * static_cast<double>(nFft)));
    const size_t b0 = static_cast<size_t>(pos);
    const size_t b1 = std::min(halfBins, b0 + 1);
    const double frac = pos - static_cast<double>(b0);
    const double mag = binMag(b0) * (1.0 - frac) + binMag(b1) * frac;
    env[m] = mag;
    peak = std::max(peak, mag);
  }
  peakMag = std::max(peak, 1.0e-12);
  return env;
}

// Reconstructs causal energy lost to t < 0 sinc pre-ringing without adding any
// group delay or rig latency: solves for a short causal FIR adjustment
// dh[0..L-1] on [0, L) that compensates the discarded pre-ringing full[0..preOut)
// in complex frequency response across the passband, keeping both magnitude and
// phase aligned for single and dual-cab summation.
void repairCausalPreRinging(std::vector<double>& full, size_t preOut,
                            size_t count, double from, double to) {
  if (preOut == 0 || count == 0) return;
  double maxPre = 0.0, maxBase = 0.0;
  for (size_t i = 0; i < preOut; ++i)
    maxPre = std::max(maxPre, std::fabs(full[i]));
  for (size_t i = 0; i < count; ++i)
    maxBase = std::max(maxBase, std::fabs(full[preOut + i]));
  if (!(maxBase > 1.0e-30) || maxPre <= 1.0e-7 * maxBase) return;

  constexpr size_t kLinBins = 384;
  constexpr size_t kLogBins = 64;
  constexpr size_t kMaxRepairTaps = 96;

  std::vector<double> normFreqs;
  normFreqs.reserve(kLinBins + kLogBins);
  for (size_t i = 0; i < kLinBins; ++i)
    normFreqs.push_back(0.5 * static_cast<double>(i) / static_cast<double>(kLinBins - 1));

  const double lowMin = std::min(15.0 / to, 0.25);
  const double lowMax = std::min(500.0 / to, 0.45);
  if (lowMin > 0.0 && lowMin < lowMax) {
    const double logRatio = std::log(lowMax / lowMin);
    for (size_t i = 0; i < kLogBins; ++i) {
      const double t = static_cast<double>(i) / static_cast<double>(kLogBins - 1);
      normFreqs.push_back(lowMin * std::exp(logRatio * t));
    }
  }
  std::sort(normFreqs.begin(), normFreqs.end());
  normFreqs.erase(std::unique(normFreqs.begin(), normFreqs.end(),
                              [](double a, double b) { return std::fabs(a - b) < 1.0e-12; }),
                  normFreqs.end());

  double peakMag = 1.0;
  const std::vector<double> magEnv = estimateSpectrumEnvelope(full, normFreqs, peakMag);

  const double minRate = std::min(from, to);
  const double fPass = std::min(20000.0, 0.42 * minRate) / to;
  const double fStop = (0.5 * minRate) / to;
  const size_t L = std::min(kMaxRepairTaps, count);

  std::vector<double> c(L, 0.0);
  std::vector<double> rhs(L, 0.0);

  for (size_t m = 0; m < normFreqs.size(); ++m) {
    const double fn = normFreqs[m];
    double w = 0.05;
    if (fn <= fPass) {
      w = 1.0 / std::max(magEnv[m] / peakMag, 0.02);
    } else if (fn >= fStop) {
      w = 0.20;
    }
    const double w2 = w * w;
    const double angle = 2.0 * kPi * fn;
    const double sr = std::cos(angle);
    const double si = std::sin(angle);

    // Target response of discarded pre-ringing: sum_{p=1..preOut} full[preOut-p] * exp(+j*angle*p).
    double tr = 0.0, ti = 0.0;
    double pr = sr, pi = si;
    for (size_t p = 1; p <= preOut; ++p) {
      const double pv = full[preOut - p];
      tr += pv * pr;
      ti += pv * pi;
      const double npr = pr * sr - pi * si;
      pi = pr * si + pi * sr;
      pr = npr;
    }

    // Normal equations form a symmetric Toeplitz Gram matrix:
    // G[j, k] = sum w^2 * cos(angle * (j - k)).
    double dr = 1.0, di = 0.0;
    for (size_t d = 0; d < L; ++d) {
      c[d] += w2 * dr;
      rhs[d] += w2 * (tr * dr - ti * di);
      const double ndr = dr * sr - di * si;
      di = dr * si + di * sr;
      dr = ndr;
    }
  }

  if (!(c[0] > 0.0)) return;
  std::vector<double> G(L * L, 0.0);
  for (size_t j = 0; j < L; ++j) {
    for (size_t k = 0; k < L; ++k) {
      const size_t diff = j >= k ? j - k : k - j;
      G[j * L + k] = c[diff];
    }
    G[j * L + j] += 1.0e-6 * c[0];
  }

  const std::vector<double> dh = solveSymmetricPositiveDefinite(G, rhs, L);
  if (dh.empty()) return;
  for (size_t i = 0; i < L; ++i)
    full[preOut + i] += dh[i];
}

// Bandlimited windowed-sinc resampling, evaluated directly at each output
// position. An IR's spectrum IS its transfer function, so resampling errors
// are tone errors: evaluating the full symmetric sinc (including zero-padded
// support before t = 0) prevents boundary normalization distortion on peaks
// near sample 0, and causal spectral repair recovers any energy clipped at t < 0
// while keeping zero added latency.
std::vector<float> resample(const std::vector<float>& input, double from, double to) {
  if (std::fabs(from - to) < 1.0 || input.size() < 2) return input;
  constexpr int kTaps = 64;                             // kernel half-width (input samples)
  const double ratio = from / to;                       // input samples per output sample
  const double beta = 0.9 * std::min(from, to) / from;  // 2*fc/from, fc = 0.45*min(rate)
  const size_t count = std::max<size_t>(2, std::llround(input.size() * to / from));
  const size_t preOut = static_cast<size_t>(std::ceil(static_cast<double>(kTaps) * to / from));
  const size_t total = preOut + count;

  std::vector<double> full(total, 0.0);
  for (size_t idx = 0; idx < total; ++idx) {
    const long i = static_cast<long>(idx) - static_cast<long>(preOut);
    const double pos = static_cast<double>(i) * ratio;
    const long center = std::lround(pos);
    double acc = 0.0, wsum = 0.0;
    for (long k = center - kTaps; k <= center + kTaps; ++k) {
      const double r = pos - static_cast<double>(k);  // offset in input samples
      const double v = r / kTaps;                     // window argument on [-1, 1]
      if (std::fabs(v) > 1.0) continue;
      const double u = beta * r;
      const double s = std::fabs(u) < 1e-8 ? beta : beta * std::sin(kPi * u) / (kPi * u);
      const double w = 0.35875 + 0.48829 * std::cos(kPi * v) + 0.14128 * std::cos(2.0 * kPi * v)
                     + 0.01168 * std::cos(3.0 * kPi * v);   // Blackman-Harris
      const double sw = s * w;
      if (k >= 0 && k < static_cast<long>(input.size()))
        acc += static_cast<double>(input[static_cast<size_t>(k)]) * sw;
      wsum += sw;
    }
    full[idx] = wsum != 0.0 ? (acc / wsum) : 0.0;
  }

  repairCausalPreRinging(full, preOut, count, from, to);

  std::vector<float> output(count);
  for (size_t i = 0; i < count; ++i)
    output[i] = static_cast<float>(full[preOut + i]);
  return output;
}

struct ResponseStats {
  double peak = 0.0;
  double rms = 0.0;
};

// Measure the filter rather than its individual time-domain coefficients.
// Uniformly spaced physical-Hz samples keep both metrics stable when the same
// IR is resampled for a different host rate. The 20 Hz--20 kHz window also
// avoids ultrasonic bins (which a guitar cabinet does not meaningfully use)
// skewing the average at high host rates.
ResponseStats measureResponse(const std::vector<float>& taps, double rate) {
  constexpr size_t kBins = 512;
  const double lowHz = 20.0;
  const double highHz = std::max(lowHz, std::min(20000.0, rate * 0.45));
  double peakSquared = 0.0;
  double sumSquared = 0.0;
  for (size_t bin = 0; bin < kBins; ++bin) {
    const double t = static_cast<double>(bin) / static_cast<double>(kBins - 1);
    const double radians = -2.0 * kPi * (lowHz + t * (highHz - lowHz)) / rate;
    const double stepReal = std::cos(radians);
    const double stepImag = std::sin(radians);
    double phaseReal = 1.0;
    double phaseImag = 0.0;
    double real = 0.0;
    double imag = 0.0;
    for (float tap : taps) {
      real += tap * phaseReal;
      imag += tap * phaseImag;
      const double nextReal = phaseReal * stepReal - phaseImag * stepImag;
      phaseImag = phaseReal * stepImag + phaseImag * stepReal;
      phaseReal = nextReal;
    }
    const double magnitudeSquared = real * real + imag * imag;
    peakSquared = std::max(peakSquared, magnitudeSquared);
    sumSquared += magnitudeSquared;
  }
  return {std::sqrt(peakSquared), std::sqrt(sumSquared / kBins)};
}
}

WavIR::WavIR(std::vector<float> taps, double sampleRate, int maxBlockSize) {
  (void)maxBlockSize;  // chunking is internal (kBlock); any call size works
  const ResponseStats response = measureResponse(taps, sampleRate);
  responsePeak = response.peak;
  responseRms = response.rms;
  if (response.peak > 1.0e-12)
    peakScale = static_cast<float>(1.0 / response.peak);
  if (response.rms > 1.0e-12)
    loudnessScale = static_cast<float>(1.0 / response.rms);
  scaleSmoothCoeff = 1.0f - std::exp(-1.0f /
      static_cast<float>(0.010 * std::max(8000.0, sampleRate)));

  const size_t headLen = std::min<size_t>(taps.size(), kBlock);
  reversedHead.assign(taps.rbegin() + (taps.size() - headLen), taps.rend());
  historyAndInput.assign(headLen - 1 + kBlock, 0.0f);
  headOut.assign(kBlock, 0.0f);

  if (taps.size() <= kBlock) return;
  partitions = static_cast<uint32_t>((taps.size() - kBlock + kBlock - 1) / kBlock);
  fft = std::make_unique<DSP::RealFFT>(kFft);
  tailSpectra.assign(static_cast<size_t>(partitions) * 2 * kBins, 0.0f);
  tailNyq.assign(partitions, 0.0f);
  fdl.assign(static_cast<size_t>(partitions) * 2 * kBins, 0.0f);
  fdlNyq.assign(partitions, 0.0f);
  fillBuf.assign(kBlock, 0.0f);
  ring.assign(kRing, 0.0f);
  fftTime.assign(kFft, 0.0f);
  accRe.assign(kBins, 0.0f);
  accIm.assign(kBins, 0.0f);
  const float scale = fft->roundTripScale();
  for (uint32_t p = 0; p < partitions; ++p) {
    const size_t start = kBlock + static_cast<size_t>(p) * kBlock;
    const size_t len = std::min<size_t>(kBlock, taps.size() - start);
    std::memset(fftTime.data(), 0, kFft * sizeof(float));
    std::memcpy(fftTime.data(), taps.data() + start, len * sizeof(float));
    float* spRe = tailSpectra.data() + static_cast<size_t>(p) * 2 * kBins;
    float* spIm = spRe + kBins;
    fft->forward(fftTime.data(), spRe, spIm);
    tailNyq[p] = spIm[0] * scale;
    spIm[0] = 0.0f;
    DSP::vsmul(spRe, scale, spRe, kBins);
    DSP::vsmul(spIm, scale, spIm, kBins);
  }
}

WavIR::~WavIR() = default;

void WavIR::linkStereoNormalization(WavIR& left, WavIR& right) noexcept {
  const double peak = std::max(left.responsePeak, right.responsePeak);
  const double rms = std::sqrt(0.5 * (left.responseRms * left.responseRms +
                                      right.responseRms * right.responseRms));
  const float peakScale = peak > 1.0e-12 ? static_cast<float>(1.0 / peak) : 1.0f;
  const float loudnessScale = rms > 1.0e-12 ? static_cast<float>(1.0 / rms) : 1.0f;
  left.peakScale = right.peakScale = peakScale;
  left.loudnessScale = right.loudnessScale = loudnessScale;
}

unsigned WavIR::channelCount(const char* path) {
  try {
    return parseWav(readFile(path)).channels;
  } catch (...) {
    return 0;
  }
}

std::unique_ptr<WavIR> WavIR::load(const char* path, double hostRate,
                                   int maxBlockSize, int channel) {
  auto taps = loadTaps(path, hostRate, channel);
  // Store response-based scales so normalization can change without reloading
  // or destructively altering the corrected taps.
  return std::unique_ptr<WavIR>(
      new WavIR(std::move(taps), hostRate, maxBlockSize));
}

std::vector<float> WavIR::loadTaps(const char* path, double hostRate, int channel) {
  uint32_t sourceRate = 0;
  const auto sourceTaps = readWav(path, sourceRate, channel);
  auto taps = resample(sourceTaps, sourceRate, hostRate);
  // A resampled discrete impulse response needs the inverse sample-density
  // factor to retain its transfer function: interpolating 48 -> 96 kHz creates
  // roughly twice as many taps and would otherwise add about 6 dB of gain.
  if (std::fabs(static_cast<double>(sourceRate) - hostRate) >= 1.0) {
    const float transferScale = static_cast<float>(sourceRate / hostRate);
    for (float& tap : taps) tap *= transferScale;
  }
  // Cabinet IR energy is concentrated near the start; 170 ms (8192 taps at
  // 48 kHz) keeps far-mic and room tails. A hard cut rings (truncation ripple
  // in the transfer function), so the last ~5 ms taper with a raised cosine.
  const size_t maxTaps = static_cast<size_t>(hostRate * kMaxSeconds);
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
  return taps;
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
  float* xRe = fdl.data() + static_cast<size_t>(fdlNewest) * 2 * kBins;
  float* xIm = xRe + kBins;
  fft->forward(fftTime.data(), xRe, xIm);
  fdlNyq[fdlNewest] = xIm[0];
  xIm[0] = 0.0f;

  std::memset(accRe.data(), 0, kBins * sizeof(float));
  std::memset(accIm.data(), 0, kBins * sizeof(float));
  float nyqAcc = 0.0f;
  for (uint32_t p = 0; p < partitions; ++p) {
    const uint32_t slot = fdlNewest >= p ? fdlNewest - p
                                         : fdlNewest + partitions - p;
    const float* xsRe = fdl.data() + static_cast<size_t>(slot) * 2 * kBins;
    const float* xsIm = xsRe + kBins;
    const float* hsRe = tailSpectra.data() + static_cast<size_t>(p) * 2 * kBins;
    const float* hsIm = hsRe + kBins;
    DSP::zvma(xsRe, xsIm, hsRe, hsIm, accRe.data(), accIm.data(), kBins);
    nyqAcc += fdlNyq[slot] * tailNyq[p];
  }
  accIm[0] = nyqAcc;
  fft->inverse(accRe.data(), accIm.data(), fftTime.data());

  const uint32_t first = std::min(kFft, kRing - ringPos);
  DSP::vadd(ring.data() + ringPos, fftTime.data(), first);
  if (first < kFft)
    DSP::vadd(ring.data(), fftTime.data() + first, kFft - first);
  fillPos = 0;
}

void WavIR::process(float* samples, uint32_t count, int normalizationMode) noexcept {
  const float targetScale = normalizationMode == 1 ? peakScale : loudnessScale;
  // The first block starts directly at the requested mode; subsequent UI
  // changes glide over 10 ms instead of stepping by potentially many dB at a
  // host block boundary.
  if (!scaleInitialized) {
    currentScale = targetScale;
    scaleInitialized = true;
  }
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
    DSP::conv(historyAndInput.data(), reversedHead.data(),
              headOut.data(), t, headLen);
    if (history) std::memmove(historyAndInput.data(), historyAndInput.data() + t,
                              history * sizeof(float));
    if (partitions) {
      std::memcpy(fillBuf.data() + fillPos, samples + done, t * sizeof(float));
      fillPos += t;
      for (uint32_t i = 0; i < t; ++i) {
        const uint32_t rp = (ringPos + i) & kRingMask;
        currentScale += (targetScale - currentScale) * scaleSmoothCoeff;
        samples[done + i] = (headOut[i] + ring[rp]) * currentScale;
        ring[rp] = 0.0f;
      }
      ringPos = (ringPos + t) & kRingMask;
      if (fillPos == kBlock) flushBlock();
    } else {
      for (uint32_t i = 0; i < t; ++i) {
        currentScale += (targetScale - currentScale) * scaleSmoothCoeff;
        samples[done + i] = headOut[i] * currentScale;
      }
    }
    done += t;
  }
}
}
