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

// Perceptual + guitar-band loudness weighting on a log-spaced frequency grid:
//  - Log-frequency spacing itself contributes 1/f weighting (equal energy per
//    octave, matching pink/musical spectra instead of weighting 5-20 kHz 75%).
//  - 2nd-order Butterworth HPF (75 Hz) and LPF (5.4 kHz) attenuate subsonic
//    proximity thump and high-frequency mic fizz outside the guitar cab passband.
//  - A +2.0 dB ITU-R BS.1770 acoustic head-shelf contour (above ~1.68 kHz) keeps
//    dark ribbon IRs and bright presence-heavy IRs matched in perceived level.
inline double perceptualLoudnessWeight(double hz) noexcept {
  const double uLow = hz / 75.0;
  const double uLow2 = uLow * uLow;
  const double uLow4 = uLow2 * uLow2;
  const double hp = uLow4 / (1.0 + uLow4);

  const double uHigh = hz / 5400.0;
  const double uHigh2 = uHigh * uHigh;
  const double uHigh4 = uHigh2 * uHigh2;
  const double lp = 1.0 / (1.0 + uHigh4);

  const double f2 = hz * hz;
  const double shelfRatio = f2 / (f2 + 1682.0 * 1682.0);
  const double kHalfShelf = std::pow(10.0, 0.2 * shelfRatio);
  return hp * lp * kHalfShelf;
}

// Measure the filter rather than its individual time-domain coefficients.
// Fixed physical-Hz log-spaced samples keep both metrics stable when the same
// IR is resampled for a different host rate, improve low-frequency resonance
// resolution, and measure perceived loudness across octaves rather than
// letting linear 5-20 kHz bins dominate bright vs dark cabinet comparisons.
ResponseStats measureResponse(const std::vector<float>& taps, double rate) {
  constexpr size_t kBins = 512;
  constexpr double kLowHz = 20.0;
  constexpr double kMaxHz = 20000.0;
  const double highHz = std::max(kLowHz, std::min(kMaxHz, rate * 0.45));
  const double spanRatio = kMaxHz / kLowHz;
  double peakSquared = 0.0;
  double weightedSumSquared = 0.0;
  double weightSum = 0.0;
  for (size_t bin = 0; bin < kBins; ++bin) {
    const double t = static_cast<double>(bin) / static_cast<double>(kBins - 1);
    const double hz = kLowHz * std::pow(spanRatio, t);
    if (hz > highHz) break;
    const double radians = -2.0 * kPi * hz / rate;
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
    const double weight = perceptualLoudnessWeight(hz);
    peakSquared = std::max(peakSquared, magnitudeSquared);
    weightedSumSquared += weight * magnitudeSquared;
    weightSum += weight;
  }
  const double rms =
      weightSum > 0.0 ? std::sqrt(weightedSumSquared / weightSum) : 0.0;
  return {std::sqrt(peakSquared), rms};
}
}

WavIR::WavIR(std::vector<float> taps, double sampleRate, int maxBlockSize) {
  (void)maxBlockSize;  // chunking is internal (kBlock); any call size works
  const ResponseStats response = measureResponse(taps, sampleRate);
  responsePeak = response.peak;
  responseRms = response.rms;
  // Precompute complex DFT across [45..210 Hz] so the audio thread can score
  // dual-cab low-end coherence with zero allocations or transforms.
  {
    double energySum = 0.0;
    for (size_t b = 0; b < LowBandSignature::kBins; ++b) {
      const double t = static_cast<double>(b) /
                       static_cast<double>(LowBandSignature::kBins - 1);
      const double hz = LowBandSignature::kMinHz +
                        t * (LowBandSignature::kMaxHz - LowBandSignature::kMinHz);
      const double radians = -2.0 * kPi * hz / std::max(8000.0, sampleRate);
      const double stepRe = std::cos(radians);
      const double stepIm = std::sin(radians);
      double phRe = 1.0, phIm = 0.0;
      double re = 0.0, im = 0.0;
      for (float tap : taps) {
        re += tap * phRe;
        im += tap * phIm;
        const double nextRe = phRe * stepRe - phIm * stepIm;
        phIm = phRe * stepIm + phIm * stepRe;
        phRe = nextRe;
      }
      lowBand.re[b] = static_cast<float>(re);
      lowBand.im[b] = static_cast<float>(im);
      energySum += re * re + im * im;
    }
    lowBand.energy = static_cast<float>(energySum);
  }
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

float WavIR::nominalLowBandDelayCoherence(float alignmentMs) noexcept {
  if (alignmentMs == 0.0f) return 1.0f;
  const double tau = static_cast<double>(alignmentMs) * 0.001;
  double sum = 0.0;
  for (size_t b = 0; b < LowBandSignature::kBins; ++b) {
    const double t = static_cast<double>(b) /
                     static_cast<double>(LowBandSignature::kBins - 1);
    const double hz = LowBandSignature::kMinHz +
                      t * (LowBandSignature::kMaxHz - LowBandSignature::kMinHz);
    sum += std::cos(2.0 * kPi * hz * tau);
  }
  return std::max(-1.0f, std::min(1.0f,
      static_cast<float>(sum / static_cast<double>(LowBandSignature::kBins))));
}

float WavIR::lowBandCoherence(const WavIR* irA, const WavIR* irB,
                              float alignmentMs) noexcept {
  if (!irA || !irB) return nominalLowBandDelayCoherence(alignmentMs);
  const auto& sigA = irA->lowBandSignature();
  const auto& sigB = irB->lowBandSignature();
  const double denom = std::sqrt(static_cast<double>(sigA.energy) *
                                 static_cast<double>(sigB.energy));
  if (denom <= 1.0e-18) return nominalLowBandDelayCoherence(alignmentMs);

  const double tau = static_cast<double>(alignmentMs) * 0.001;
  double realSum = 0.0;
  for (size_t b = 0; b < LowBandSignature::kBins; ++b) {
    const double t = static_cast<double>(b) /
                     static_cast<double>(LowBandSignature::kBins - 1);
    const double hz = LowBandSignature::kMinHz +
                      t * (LowBandSignature::kMaxHz - LowBandSignature::kMinHz);
    const double phase = 2.0 * kPi * hz * tau;
    const double c = std::cos(phase);
    const double s = std::sin(phase);
    const double aRe = sigA.re[b];
    const double aIm = sigA.im[b];
    const double bRe = sigB.re[b];
    const double bIm = sigB.im[b];
    // Re((A * conj(B)) * exp(+j * 2*pi*f*tau)):
    // tau > 0 delays B -> phase shift exp(-j*w*tau) on B -> exp(+j*w*tau) on conj(B).
    // tau < 0 delays A -> phase shift exp(+j*w*tau) on A (since tau < 0).
    const double prodRe = aRe * bRe + aIm * bIm;
    const double prodIm = aIm * bRe - aRe * bIm;
    realSum += prodRe * c - prodIm * s;
  }
  const double rho = realSum / denom;
  return std::max(-1.0f, std::min(1.0f, static_cast<float>(rho)));
}

WavIR::AlignmentResult WavIR::findBestAlignment(const char* pathA, const char* pathB,
                                                double sampleRate) {
  AlignmentResult result;
  if (!pathA || !pathA[0] || !pathB || !pathB[0]) return result;
  const double rate = std::max(8000.0, sampleRate);
  try {
    auto tapsA = loadTaps(pathA, rate, -1);
    auto tapsB = loadTaps(pathB, rate, -1);
    const size_t maxWindow = static_cast<size_t>(std::llround(rate * 0.060));
    const size_t lenA = std::min(tapsA.size(), maxWindow);
    const size_t lenB = std::min(tapsB.size(), maxWindow);
    if (lenA == 0 || lenB == 0) return result;

    double energyA = 0.0, energyB = 0.0;
    for (size_t i = 0; i < lenA; ++i) energyA += static_cast<double>(tapsA[i]) * tapsA[i];
    for (size_t i = 0; i < lenB; ++i) energyB += static_cast<double>(tapsB[i]) * tapsB[i];
    const double denom = std::sqrt(energyA * energyB);
    if (denom <= 1.0e-18) return result;

    const long maxLag = std::max<long>(1, std::lround(rate * 0.010));
    std::vector<double> corr(static_cast<size_t>(2 * maxLag + 1), 0.0);
    size_t bestIdx = static_cast<size_t>(maxLag);
    double bestAbs = -1.0;

    for (long lag = -maxLag; lag <= maxLag; ++lag) {
      // Positive lag delays B: sum tapsA[n] * tapsB[n - lag]
      const size_t nStart = lag > 0 ? static_cast<size_t>(lag) : 0;
      const size_t nEnd = std::min(lenA, static_cast<size_t>(
          std::max<long>(0, static_cast<long>(lenB) + lag)));
      double sum = 0.0;
      for (size_t n = nStart; n < nEnd; ++n) {
        sum += static_cast<double>(tapsA[n]) *
               static_cast<double>(tapsB[static_cast<size_t>(static_cast<long>(n) - lag)]);
      }
      const double c = sum / denom;
      const size_t idx = static_cast<size_t>(lag + maxLag);
      corr[idx] = c;
      const double absC = std::fabs(c);
      const long bestLag = static_cast<long>(bestIdx) - maxLag;
      if (absC > bestAbs + 1.0e-9 ||
          (std::fabs(absC - bestAbs) <= 1.0e-9 && std::abs(lag) < std::abs(bestLag))) {
        bestAbs = absC;
        bestIdx = idx;
      }
    }

    const long bestLag = static_cast<long>(bestIdx) - maxLag;
    const double peakCorr = corr[bestIdx];
    double exactLag = static_cast<double>(bestLag);
    if (bestIdx > 0 && bestIdx + 1 < corr.size()) {
      const double sgn = peakCorr >= 0.0 ? 1.0 : -1.0;
      const double y0 = corr[bestIdx - 1] * sgn;
      const double y1 = peakCorr * sgn;
      const double y2 = corr[bestIdx + 1] * sgn;
      const double quad = y0 - 2.0 * y1 + y2;
      if (quad < -1.0e-12) {
        const double delta = std::max(-0.5, std::min(0.5, 0.5 * (y0 - y2) / quad));
        exactLag += delta;
      }
    }

    const double delayMs = std::max(-10.0, std::min(10.0, exactLag * 1000.0 / rate));
    result.valid = true;
    result.delayMs = static_cast<float>(delayMs);
    result.invertPolarity = peakCorr < 0.0;
    result.correlation = static_cast<float>(peakCorr);
    return result;
  } catch (...) {
    return AlignmentResult{};
  }
}
}
