#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>

#if defined(__APPLE__)
#include <Accelerate/Accelerate.h>
#endif

namespace NAMRig {
namespace DSP {

// 1D Convolution / FIR filtering:
// result[i] = sum_{k=0}^{filter_len - 1} signal[i + k] * filter[k]
// Computes result_len samples with unit strides.
void conv(const float* signal, const float* filter, float* result,
          size_t result_len, size_t filter_len) noexcept;

// Optimized 24-tap convolution specifically for half-band polyphase (Up2x/Down2x).
// Vectorized with AVX2/FMA, SSE, or vDSP.
void conv24(const float* signal, const float* filter24, float* result,
            size_t result_len) noexcept;

// Deinterleave [r0, i0, r1, i1, ...] -> real[0..count-1], imag[0..count-1]
void deinterleave(const float* interleaved, float* real, float* imag, size_t count) noexcept;

// Interleave real[0..count-1], imag[0..count-1] -> [r0, i0, r1, i1, ...]
void interleave(const float* real, const float* imag, float* interleaved, size_t count) noexcept;

// Vector add: dst[i] += src[i]
void vadd(float* dst, const float* src, size_t count) noexcept;

// Vector scalar multiply: dst[i] = src[i] * scale
void vsmul(const float* src, float scale, float* dst, size_t count) noexcept;

// Complex vector multiply-accumulate:
// acc_re[i] += xr[i]*yr[i] - xi[i]*yi[i]
// acc_im[i] += xr[i]*yi[i] + xi[i]*yr[i]
void zvma(const float* xr, const float* xi,
          const float* yr, const float* yi,
          float* acc_re, float* acc_im,
          size_t count) noexcept;

// Fast real FFT for partitioned convolution (e.g. N = 512).
// Time domain: N real floats.
// Frequency domain: split complex real[N/2], imag[N/2].
// Compatible with vDSP packed format where imag[0] holds the Nyquist bin!
class RealFFT {
 public:
  explicit RealFFT(size_t n);
  ~RealFFT();

  RealFFT(const RealFFT&) = delete;
  RealFFT& operator=(const RealFFT&) = delete;

  // Forward FFT: timeDomain (N floats) -> outRe (N/2 floats), outIm (N/2 floats).
  // outIm[0] contains the real Nyquist bin.
  void forward(const float* timeDomain, float* outRe, float* outIm) noexcept;

  // Inverse FFT: inRe (N/2 floats), inIm (N/2 floats with inIm[0] = Nyquist) -> timeDomain (N floats).
  void inverse(const float* inRe, const float* inIm, float* timeDomain) noexcept;

  // Normalization scale factor for a forward + inverse round-trip
  float roundTripScale() const noexcept;

  size_t size() const noexcept { return n_; }

 private:
  size_t n_ = 0;
#if defined(__APPLE__)
  FFTSetup setup_ = nullptr;
  uint32_t log2n_ = 0;
#else
  void* pffftSetup_ = nullptr;
  void* work_ = nullptr;
#endif
};

} // namespace DSP
} // namespace NAMRig
