// Verifies the tuner's vectorized NSDF (one vDSP_conv for all acf lags plus
// a prefix sum of squares for m[tau]) against the original scalar loop, on
// noisy sine windows across the guitar range.
#include <Accelerate/Accelerate.h>
#include <cmath>
#include <cstdio>
#include <random>
#include <vector>

int main() {
  constexpr int kWindow = 1024, kMinTau = 8, kMaxTau = 300;
  constexpr int span = kWindow + kMaxTau;
  std::mt19937 rng(20260830);
  std::uniform_real_distribution<float> noise(-0.05f, 0.05f);
  double worst = 0.0;
  for (int trial = 0; trial < 50; ++trial) {
    std::vector<float> win(span);
    const double f = 60.0 + trial * 25.0;
    for (int i = 0; i < span; ++i)
      win[i] = 0.4f * (float)std::sin(2.0 * M_PI * f * i / 12000.0) + noise(rng);

    std::vector<float> nsdfOld(kMaxTau + 2, 0.0f), nsdfNew(kMaxTau + 2, 0.0f);
    for (int tau = kMinTau; tau <= kMaxTau; ++tau) {
      float acf = 0.0f, m = 0.0f;
      for (int i = 0; i < kWindow; ++i) {
        const float a = win[i], b = win[i + tau];
        acf += a * b;
        m += a * a + b * b;
      }
      nsdfOld[tau] = (m > 0.0f) ? (2.0f * acf / m) : 0.0f;
    }

    std::vector<float> acf(kMaxTau + 1);
    std::vector<double> pre(span + 1, 0.0);
    vDSP_conv(win.data(), 1, win.data(), 1, acf.data(), 1,
              (vDSP_Length)(kMaxTau + 1), (vDSP_Length)kWindow);
    double c = 0.0;
    for (int i = 0; i < span; ++i) { c += (double)win[i] * win[i]; pre[i + 1] = c; }
    const double e0 = pre[kWindow];
    for (int tau = kMinTau; tau <= kMaxTau; ++tau) {
      const double m = e0 + pre[tau + kWindow] - pre[tau];
      nsdfNew[tau] = m > 0.0 ? (float)(2.0 * acf[tau] / m) : 0.0f;
    }
    for (int tau = kMinTau; tau <= kMaxTau; ++tau)
      worst = std::max(worst, (double)std::fabs(nsdfNew[tau] - nsdfOld[tau]));
  }
  const bool ok = worst < 1e-4;
  std::printf("  %s  vectorized NSDF == scalar (worst diff %.3e)\n",
              ok ? "PASS" : "FAIL", worst);
  std::printf(ok ? "\nALL PASSED (0 failures)\n" : "\nFAILED (1)\n");
  return ok ? 0 : 1;
}
