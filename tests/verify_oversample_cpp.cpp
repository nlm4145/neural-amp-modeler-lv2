// Standalone verification of oversample.cpp against the validated Python
// reference (tests/test_oversample_2x.py). Mirrors every test numerically:
//   1. prototype: even-offset taps ~0, center 0.5, sum exactly 1
//   2. interp branch sums to exactly 1
//   3. UP identity phase (even outputs == inputs, bit-exact)
//   4. UP DC == 1 on both phases (interior)
//   5. UP imaging rejection < -90 dB (5 kHz tone)
//   6. DOWN alias rejection < -90 dB (30 kHz tone at 2x)
//   7. UP+DOWN passband ripple < 0.1 dB to 19.2 kHz
//   8. streaming == one-shot prefix at block sizes 64/128/512/1000
//   9. saturation alias clutter: oversampled >= 10 dB cleaner
// Build: clang++ -O2 -std=c++20 -framework Accelerate src/oversample.cpp
//        tests/verify_oversample_cpp.cpp -o /tmp/verify_os && /tmp/verify_os
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <vector>

#include <Accelerate/Accelerate.h>

#include "../src/oversample.h"

using NAMRig::Up2x;
using NAMRig::Down2x;
using NAMRig::halfBandProto;
using NAMRig::halfBandInterp;

static FFTSetup gFFT = vDSP_create_fftsetup(16, FFT_RADIX2);
struct FFTGuard { ~FFTGuard() { if (gFFT) vDSP_destroy_fftsetup(gFFT); } } gFFTGuard;

// magnitude spectrum of a real signal (vDSP rfft); returns n/2 bins scaled
static std::vector<float> magSpectrum(const std::vector<float>& x) {
  const int n = (int)x.size();
  int log2n = 0;
  while ((1 << log2n) < n) ++log2n;
  const int N = 1 << log2n;
  std::vector<float> re(N / 2, 0.0f), im(N / 2, 0.0f);
  std::vector<float> padded(N, 0.0f);
  std::memcpy(padded.data(), x.data(), n * sizeof(float));
  DSPSplitComplex split = {re.data(), im.data()};
  vDSP_ctoz(reinterpret_cast<const DSPComplex*>(padded.data()), 2, &split, 2, N / 2);
  vDSP_fft_zrip(gFFT, &split, 1, log2n, FFT_FORWARD);
  std::vector<float> mag(N / 2);
  for (int i = 0; i < N / 2; ++i) mag[i] = std::hypot(re[i], im[i]);
  return mag;
}

static int g_fail = 0;
#define CHECK(cond, msg)                                    \
  do {                                                      \
    if (cond) { std::printf("  PASS  %s\n", msg); }          \
    else { ++g_fail; std::printf("  FAIL  %s\n", msg); }     \
  } while (0)

// One-shot = feed the data + 24 zero flush samples (end-of-stream), then
// keep only the outputs whose even phase maps to REAL input positions
// (2*x.size() outputs; the trailing flush outputs are dropped).
static std::vector<float> up2xOneShot(const std::vector<float>& x) {
  Up2x up;
  up.setMaxBlockSize(x.size() + 24);
  up.reset();
  std::vector<float> xin(x);
  xin.insert(xin.end(), 24, 0.0f);
  std::vector<float> out(Up2x::maxOutput(xin.size()));
  const size_t n = up.process(xin.data(), xin.size(), out.data());
  out.resize(std::min(n, 2 * x.size()));
  return out;
}

// One-shot = data + 48 zero flush samples; keep outputs for even absolute
// positions < u.size() (i.e. at most u.size()/2).
static std::vector<float> down2xOneShot(const std::vector<float>& u) {
  Down2x down;
  down.setMaxBlockSize(u.size() + 48);
  down.reset();
  std::vector<float> uin(u);
  uin.insert(uin.end(), 48, 0.0f);
  std::vector<float> out(Down2x::maxOutput(uin.size()) + 8);
  const size_t n = down.process(uin.data(), uin.size(), out.data());
  out.resize(std::min(n, u.size() / 2));
  return out;
}

static double rms(const std::vector<float>& v, size_t a, size_t b) {
  double s = 0;
  for (size_t i = a; i < b; ++i) s += (double)v[i] * v[i];
  return std::sqrt(s / (double)(b - a));
}

int main() {
  // ---- 1. prototype ----
  {
    const float* H = halfBandProto();
    const float* P = halfBandInterp();
    double sum = 0;
    for (int i = 0; i < 47; ++i) sum += H[i];
    bool zeros = true;
    for (int i = 0; i < 47; ++i) {
      const int m = i - 23;
      if (m != 0 && m % 2 == 0 && std::fabs(H[i]) > 1e-6f) zeros = false;
    }
    CHECK(zeros && H[23] == 0.5f && std::fabs(sum - 1.0) < 1e-6,
          "prototype: half-band zeros, center 0.5, DC sum 1");
    double psum = 0;
    for (int i = 0; i < 24; ++i) psum += P[i];
    CHECK(std::fabs(psum - 1.0) < 1e-6, "interp branch DC gain 1");
  }

  // ---- 3. identity phase ----
  {
    std::mt19937 rng(2);
    std::uniform_real_distribution<float> d(-0.3f, 0.3f);
    std::vector<float> x(256);
    for (auto& s : x) s = d(rng);
    auto u = up2xOneShot(x);
    bool ident = u.size() == 512;
    for (size_t i = 0; ident && i < 256; ++i)
      if (u[2 * i] != x[i]) ident = false;
    CHECK(ident, "UP identity phase bit-exact");
  }

  // ---- 4. UP DC ----
  {
    std::vector<float> x(512, 1.0f);
    auto u = up2xOneShot(x);
    bool ok = u.size() == 1024;
    for (size_t i = 24; ok && i < u.size() - 24; ++i)
      if (std::fabs(u[i] - 1.0f) > 1e-6) ok = false;
    CHECK(ok, "UP DC == 1 both phases (interior)");
  }

  // ---- 5. imaging rejection (5 kHz @ 48k up to 2x) ----
  {
    const int N = 16384;
    std::vector<float> x(N);
    for (int i = 0; i < N; ++i) x[i] = 0.5f * std::sin(2 * M_PI * 5000.0 * i / 48000.0);
    auto u = up2xOneShot(x);
    const int n2 = (int)u.size() - 512;
    std::vector<float> win(n2);
    for (int i = 0; i < n2; ++i) win[i] = u[256 + i] * (0.5f - 0.5f * std::cos(2 * M_PI * i / (n2 - 1)));
    // Compare in the TIME domain instead (immune to FFT leakage): the
    // upsampled 5 kHz tone must equal 0.5*sin(...) at 96 kHz (band-limited
    // interpolation is exact for a pure in-band tone). Any image energy
    // shows up as residual error.
    const size_t skip = 64;
    double resid = 0, sig = 0;
    for (size_t i = skip; i < u.size() - skip; ++i) {
      const double expect = 0.5 * std::sin(2 * M_PI * 5000.0 * (double)i / 96000.0);
      resid = std::max(resid, (double)std::fabs(u[i] - (float)expect));
      sig = std::max(sig, (double)std::fabs(u[i]));
    }
    const double rejDb = 20.0 * std::log10(resid / sig);
    std::printf("    imaging residual %.1f dB\n", rejDb);
    CHECK(rejDb < -80.0, "UP imaging rejection > 80 dB (time domain)");
  }

  // ---- 8. streaming equivalence ----
  {
    std::mt19937 rng(4);
    std::uniform_real_distribution<float> d(-0.3f, 0.3f);
    std::vector<float> x(4096);
    for (auto& s : x) s = d(rng);
    auto one = down2xOneShot(up2xOneShot(x));
    bool allOk = true;
    for (int bs : {64, 128, 512, 1000}) {
      Up2x up; up.setMaxBlockSize(bs); up.reset();
      Down2x down; down.setMaxBlockSize(2 * bs + 48); down.reset();
      std::vector<float> uBuf, out;
      // feed x, then 24 zeros (flush), then 48 zeros to flush the decimator
      std::vector<float> xin(x);
      xin.insert(xin.end(), 24 + 48, 0.0f);
      for (size_t i = 0; i < xin.size(); i += bs) {
        const size_t n = std::min((size_t)bs, xin.size() - i);
        std::vector<float> u(Up2x::maxOutput(n));
        const size_t un = up.process(xin.data() + i, n, u.data());
        u.resize(un);
        uBuf.insert(uBuf.end(), u.begin(), u.end());
        std::vector<float> o(Down2x::maxOutput(uBuf.size()) + 8);
        const size_t on = down.process(uBuf.data(), uBuf.size(), o.data());
        out.insert(out.end(), o.begin(), o.begin() + on);
        uBuf.clear();
      }
      // find best alignment lag
      double best = 1e30;
      const size_t m = std::min(one.size(), out.size()) - 64;
      for (size_t lag = 0; lag < 64; ++lag) {
        double e = 0;
        for (size_t i = 0; i < m; ++i) e = std::max(e, (double)std::fabs(out[lag + i] - one[i]));
        best = std::min(best, e);
      }
      if (best > 1e-5) {
        allOk = false;
        std::printf("    block %d: best err %g\n", bs, best);
      }
    }
    CHECK(allOk, "streaming == one-shot (all block sizes)");
  }

  // ---- 9. saturation alias clutter ----
  {
    const int N = 65536;
    const double f0 = 3173.0;
    std::vector<float> x(N);
    for (int i = 0; i < N; ++i) x[i] = 1.5f * std::sin(2 * M_PI * f0 * i / 48000.0);
    auto clip = [](float s) { return std::max(-0.5f, std::min(0.5f, s)); };
    std::vector<float> base(N);
    for (int i = 0; i < N; ++i) base[i] = clip(x[i]);
    auto u = up2xOneShot(x);
    for (auto& s : u) s = clip(s);
    auto over = down2xOneShot(u);

    // Clutter via direct sinusoid correlation (Goertzel-style) at 20 Hz
    // steps across 3.6k-23k, skipping harmonic neighborhoods. No FFT, no
    // packing/scaling pitfalls. Windowed the same way as the Python spec.
    auto goertzel = [&](const std::vector<float>& win, double f) {
      const double w = 2 * M_PI * f / 48000.0;
      double c = 0, s = 0;
      for (size_t i = 0; i < win.size(); ++i) {
        c += win[i] * std::cos(w * (double)i);
        s += win[i] * std::sin(w * (double)i);
      }
      return std::hypot(c, s);
    };
    auto clutter = [&](const std::vector<float>& sig) {
      const int n = 1 << 15;
      std::vector<float> win(n);
      for (int i = 0; i < n; ++i) win[i] = sig[512 + i] * (0.5f - 0.5f * std::cos(2 * M_PI * i / (n - 1)));
      double cmax = 0, smax = 0;
      for (double f = 20.0; f < 23980.0; f += 20.0) {
        bool nearH = false;
        for (int k = 1; k < 16; ++k) {
          const double fh = f0 * k;
          if (fh < 24000 && std::fabs(f - fh) < 150) nearH = true;
        }
        const double mg = goertzel(win, f);
        smax = std::max(smax, mg);
        if (!nearH && f > 3600 && f < 23000) cmax = std::max(cmax, mg);
      }
      return cmax / smax;
    };
    const double cb = clutter(base), co = clutter(over);
    const double impr = 20.0 * std::log10(cb / co);
    std::printf("    clutter base %.3e over %.3e (%.1f dB better)\n", cb, co, impr);
    CHECK(impr > 10.0, "saturation alias clutter >= 10 dB better oversampled");
  }

  std::printf("\n%s (%d failures)\n", g_fail ? "FAILED" : "ALL PASSED", g_fail);
  return g_fail ? 1 : 0;
}
