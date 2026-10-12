#include "dsp_accel.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#if defined(__x86_64__) || defined(_M_AMD64) || defined(__i386__) || defined(_M_IX86)
#include <immintrin.h>
#endif

#if !defined(__APPLE__)
#ifndef PFFFT_STATIC_DEFINE
#define PFFFT_STATIC_DEFINE
#endif
#include "pffft/pffft.h"
#endif

namespace NAMRig {
namespace DSP {

#if defined(__SSE__)
static inline float hsum_ps(__m128 v) noexcept {
  __m128 shuf = _mm_shuffle_ps(v, v, _MM_SHUFFLE(2, 3, 0, 1));
  __m128 sums = _mm_add_ps(v, shuf);
  shuf = _mm_movehl_ps(shuf, sums);
  sums = _mm_add_ss(sums, shuf);
  return _mm_cvtss_f32(sums);
}
#endif

void conv24(const float* signal, const float* filter24, float* result,
            size_t result_len) noexcept {
#if defined(__APPLE__)
  vDSP_conv(signal, 1, filter24, 1, result, 1, (vDSP_Length)result_len, 24);
#elif defined(__AVX2__) && defined(__FMA__)
  const __m256 f0 = _mm256_loadu_ps(filter24);
  const __m256 f1 = _mm256_loadu_ps(filter24 + 8);
  const __m256 f2 = _mm256_loadu_ps(filter24 + 16);
  for (size_t i = 0; i < result_len; ++i) {
    const __m256 s0 = _mm256_loadu_ps(signal + i);
    const __m256 s1 = _mm256_loadu_ps(signal + i + 8);
    const __m256 s2 = _mm256_loadu_ps(signal + i + 16);
    __m256 acc = _mm256_mul_ps(s0, f0);
    acc = _mm256_fmadd_ps(s1, f1, acc);
    acc = _mm256_fmadd_ps(s2, f2, acc);
    __m128 lo = _mm256_castps256_ps128(acc);
    __m128 hi = _mm256_extractf128_ps(acc, 1);
    result[i] = hsum_ps(_mm_add_ps(lo, hi));
  }
#elif defined(__SSE__)
  const __m128 f0 = _mm_loadu_ps(filter24);
  const __m128 f1 = _mm_loadu_ps(filter24 + 4);
  const __m128 f2 = _mm_loadu_ps(filter24 + 8);
  const __m128 f3 = _mm_loadu_ps(filter24 + 12);
  const __m128 f4 = _mm_loadu_ps(filter24 + 16);
  const __m128 f5 = _mm_loadu_ps(filter24 + 20);
  for (size_t i = 0; i < result_len; ++i) {
    const __m128 s0 = _mm_loadu_ps(signal + i);
    const __m128 s1 = _mm_loadu_ps(signal + i + 4);
    const __m128 s2 = _mm_loadu_ps(signal + i + 8);
    const __m128 s3 = _mm_loadu_ps(signal + i + 12);
    const __m128 s4 = _mm_loadu_ps(signal + i + 16);
    const __m128 s5 = _mm_loadu_ps(signal + i + 20);
    __m128 sum = _mm_mul_ps(s0, f0);
    sum = _mm_add_ps(sum, _mm_mul_ps(s1, f1));
    sum = _mm_add_ps(sum, _mm_mul_ps(s2, f2));
    sum = _mm_add_ps(sum, _mm_mul_ps(s3, f3));
    sum = _mm_add_ps(sum, _mm_mul_ps(s4, f4));
    sum = _mm_add_ps(sum, _mm_mul_ps(s5, f5));
    result[i] = hsum_ps(sum);
  }
#else
  for (size_t i = 0; i < result_len; ++i) {
    float sum = 0.0f;
    for (size_t k = 0; k < 24; ++k) sum += signal[i + k] * filter24[k];
    result[i] = sum;
  }
#endif
}

void conv(const float* signal, const float* filter, float* result,
          size_t result_len, size_t filter_len) noexcept {
#if defined(__APPLE__)
  vDSP_conv(signal, 1, filter, 1, result, 1, (vDSP_Length)result_len, (vDSP_Length)filter_len);
#else
  if (filter_len == 24) {
    conv24(signal, filter, result, result_len);
    return;
  }
  for (size_t i = 0; i < result_len; ++i) {
    const float* sig_i = signal + i;
    size_t k = 0;
    float sum = 0.0f;
#if defined(__AVX2__) && defined(__FMA__)
    __m256 acc256 = _mm256_setzero_ps();
    for (; k + 8 <= filter_len; k += 8) {
      __m256 s = _mm256_loadu_ps(sig_i + k);
      __m256 f = _mm256_loadu_ps(filter + k);
      acc256 = _mm256_fmadd_ps(s, f, acc256);
    }
    __m128 lo = _mm256_castps256_ps128(acc256);
    __m128 hi = _mm256_extractf128_ps(acc256, 1);
    sum += hsum_ps(_mm_add_ps(lo, hi));
#elif defined(__SSE__)
    __m128 acc128 = _mm_setzero_ps();
    for (; k + 4 <= filter_len; k += 4) {
      __m128 s = _mm_loadu_ps(sig_i + k);
      __m128 f = _mm_loadu_ps(filter + k);
      acc128 = _mm_add_ps(acc128, _mm_mul_ps(s, f));
    }
    sum += hsum_ps(acc128);
#endif
    for (; k < filter_len; ++k) sum += sig_i[k] * filter[k];
    result[i] = sum;
  }
#endif
}

void deinterleave(const float* interleaved, float* real, float* imag, size_t count) noexcept {
#if defined(__APPLE__)
  DSPSplitComplex sp{real, imag};
  vDSP_ctoz(reinterpret_cast<const DSPComplex*>(interleaved), 2, &sp, 1, (vDSP_Length)count);
#else
  for (size_t i = 0; i < count; ++i) {
    real[i] = interleaved[2 * i];
    imag[i] = interleaved[2 * i + 1];
  }
#endif
}

void interleave(const float* real, const float* imag, float* interleaved, size_t count) noexcept {
#if defined(__APPLE__)
  DSPSplitComplex sp{const_cast<float*>(real), const_cast<float*>(imag)};
  vDSP_ztoc(&sp, 1, reinterpret_cast<DSPComplex*>(interleaved), 2, (vDSP_Length)count);
#else
  for (size_t i = 0; i < count; ++i) {
    interleaved[2 * i] = real[i];
    interleaved[2 * i + 1] = imag[i];
  }
#endif
}

void vadd(float* dst, const float* src, size_t count) noexcept {
#if defined(__APPLE__)
  vDSP_vadd(dst, 1, src, 1, dst, 1, (vDSP_Length)count);
#elif defined(__AVX__)
  size_t i = 0;
  for (; i + 8 <= count; i += 8) {
    __m256 d = _mm256_loadu_ps(dst + i);
    __m256 s = _mm256_loadu_ps(src + i);
    _mm256_storeu_ps(dst + i, _mm256_add_ps(d, s));
  }
  for (; i < count; ++i) dst[i] += src[i];
#elif defined(__SSE__)
  size_t i = 0;
  for (; i + 4 <= count; i += 4) {
    __m128 d = _mm_loadu_ps(dst + i);
    __m128 s = _mm_loadu_ps(src + i);
    _mm_storeu_ps(dst + i, _mm_add_ps(d, s));
  }
  for (; i < count; ++i) dst[i] += src[i];
#else
  for (size_t i = 0; i < count; ++i) dst[i] += src[i];
#endif
}

void vsmul(const float* src, float scale, float* dst, size_t count) noexcept {
#if defined(__APPLE__)
  vDSP_vsmul(src, 1, &scale, dst, 1, (vDSP_Length)count);
#elif defined(__AVX__)
  const __m256 sc = _mm256_set1_ps(scale);
  size_t i = 0;
  for (; i + 8 <= count; i += 8) {
    __m256 s = _mm256_loadu_ps(src + i);
    _mm256_storeu_ps(dst + i, _mm256_mul_ps(s, sc));
  }
  for (; i < count; ++i) dst[i] = src[i] * scale;
#elif defined(__SSE__)
  const __m128 sc = _mm_set1_ps(scale);
  size_t i = 0;
  for (; i + 4 <= count; i += 4) {
    __m128 s = _mm_loadu_ps(src + i);
    _mm_storeu_ps(dst + i, _mm_mul_ps(s, sc));
  }
  for (; i < count; ++i) dst[i] = src[i] * scale;
#else
  for (size_t i = 0; i < count; ++i) dst[i] = src[i] * scale;
#endif
}

void zvma(const float* xr, const float* xi,
          const float* yr, const float* yi,
          float* acc_re, float* acc_im,
          size_t count) noexcept {
#if defined(__APPLE__)
  DSPSplitComplex x{const_cast<float*>(xr), const_cast<float*>(xi)};
  DSPSplitComplex y{const_cast<float*>(yr), const_cast<float*>(yi)};
  DSPSplitComplex acc{acc_re, acc_im};
  vDSP_zvma(&x, 1, &y, 1, &acc, 1, &acc, 1, (vDSP_Length)count);
#elif defined(__AVX2__) && defined(__FMA__)
  size_t i = 0;
  for (; i + 8 <= count; i += 8) {
    __m256 x_r = _mm256_loadu_ps(xr + i);
    __m256 x_i = _mm256_loadu_ps(xi + i);
    __m256 y_r = _mm256_loadu_ps(yr + i);
    __m256 y_i = _mm256_loadu_ps(yi + i);
    __m256 a_r = _mm256_loadu_ps(acc_re + i);
    __m256 a_i = _mm256_loadu_ps(acc_im + i);
    a_r = _mm256_fmadd_ps(x_r, y_r, a_r);
    a_r = _mm256_fnmadd_ps(x_i, y_i, a_r);
    a_i = _mm256_fmadd_ps(x_r, y_i, a_i);
    a_i = _mm256_fmadd_ps(x_i, y_r, a_i);
    _mm256_storeu_ps(acc_re + i, a_r);
    _mm256_storeu_ps(acc_im + i, a_i);
  }
  for (; i < count; ++i) {
    acc_re[i] += xr[i] * yr[i] - xi[i] * yi[i];
    acc_im[i] += xr[i] * yi[i] + xi[i] * yr[i];
  }
#elif defined(__SSE__)
  size_t i = 0;
  for (; i + 4 <= count; i += 4) {
    __m128 x_r = _mm_loadu_ps(xr + i);
    __m128 x_i = _mm_loadu_ps(xi + i);
    __m128 y_r = _mm_loadu_ps(yr + i);
    __m128 y_i = _mm_loadu_ps(yi + i);
    __m128 a_r = _mm_loadu_ps(acc_re + i);
    __m128 a_i = _mm_loadu_ps(acc_im + i);
    a_r = _mm_add_ps(a_r, _mm_sub_ps(_mm_mul_ps(x_r, y_r), _mm_mul_ps(x_i, y_i)));
    a_i = _mm_add_ps(a_i, _mm_add_ps(_mm_mul_ps(x_r, y_i), _mm_mul_ps(x_i, y_r)));
    _mm_storeu_ps(acc_re + i, a_r);
    _mm_storeu_ps(acc_im + i, a_i);
  }
  for (; i < count; ++i) {
    acc_re[i] += xr[i] * yr[i] - xi[i] * yi[i];
    acc_im[i] += xr[i] * yi[i] + xi[i] * yr[i];
  }
#else
  for (size_t i = 0; i < count; ++i) {
    acc_re[i] += xr[i] * yr[i] - xi[i] * yi[i];
    acc_im[i] += xr[i] * yi[i] + xi[i] * yr[i];
  }
#endif
}

RealFFT::RealFFT(size_t n) : n_(n) {
#if defined(__APPLE__)
  log2n_ = static_cast<uint32_t>(std::round(std::log2(static_cast<double>(n))));
  setup_ = vDSP_create_fftsetup(log2n_, kFFTRadix2);
#else
  pffftSetup_ = pffft_new_setup(static_cast<int>(n), PFFFT_REAL);
  work_ = pffft_aligned_malloc(n * sizeof(float));
#endif
}

RealFFT::~RealFFT() {
#if defined(__APPLE__)
  if (setup_) vDSP_destroy_fftsetup(setup_);
#else
  if (pffftSetup_) pffft_destroy_setup(static_cast<PFFFT_Setup*>(pffftSetup_));
  if (work_) pffft_aligned_free(work_);
#endif
}

void RealFFT::forward(const float* timeDomain, float* outRe, float* outIm) noexcept {
#if defined(__APPLE__)
  DSPSplitComplex sp{outRe, outIm};
  vDSP_ctoz(reinterpret_cast<const DSPComplex*>(timeDomain), 2, &sp, 1, (vDSP_Length)(n_ / 2));
  vDSP_fft_zrip(setup_, &sp, 1, log2n_, kFFTDirection_Forward);
#else
  auto* setup = static_cast<PFFFT_Setup*>(pffftSetup_);
  auto* work = static_cast<float*>(work_);
  // Use aligned heap buffer if timeDomain or work isn't 16-byte aligned
  float* tmp = work;
  pffft_transform(setup, timeDomain, tmp, nullptr, PFFFT_FORWARD);
  // PFFFT real transform format:
  // tmp[0] = DC, tmp[1] = Nyquist
  // tmp[2*k] = Re(k), tmp[2*k + 1] = Im(k) for k = 1 .. n/2 - 1
  outRe[0] = tmp[0];
  outIm[0] = tmp[1];
  const size_t kBins = n_ / 2;
  for (size_t k = 1; k < kBins; ++k) {
    outRe[k] = tmp[2 * k];
    outIm[k] = tmp[2 * k + 1];
  }
#endif
}

void RealFFT::inverse(const float* inRe, const float* inIm, float* timeDomain) noexcept {
#if defined(__APPLE__)
  DSPSplitComplex sp{const_cast<float*>(inRe), const_cast<float*>(inIm)};
  vDSP_fft_zrip(setup_, &sp, 1, log2n_, kFFTDirection_Inverse);
  vDSP_ztoc(&sp, 1, reinterpret_cast<DSPComplex*>(timeDomain), 2, (vDSP_Length)(n_ / 2));
#else
  auto* setup = static_cast<PFFFT_Setup*>(pffftSetup_);
  auto* work = static_cast<float*>(work_);
  const size_t kBins = n_ / 2;
  work[0] = inRe[0];
  work[1] = inIm[0];
  for (size_t k = 1; k < kBins; ++k) {
    work[2 * k] = inRe[k];
    work[2 * k + 1] = inIm[k];
  }
  pffft_transform(setup, work, timeDomain, nullptr, PFFFT_BACKWARD);
#endif
}

float RealFFT::roundTripScale() const noexcept {
#if defined(__APPLE__)
  return 1.0f / (4.0f * static_cast<float>(n_));
#else
  return 1.0f / static_cast<float>(n_);
#endif
}

} // namespace DSP
} // namespace NAMRig
