// Verify the PER-LEVEL cascade (True 4x = TWO chained 2x pairs, each with
// its own converter instance, ping-pong buffers) against the mathematical
// reference: up_2x(up_2x(x)) through a linear stage, decimated back down.
// Mirrors src/oversample.cpp exactly (same ProtoInit taps).
//
// Build: clang++ -O2 -std=c++17 -framework Accelerate -Isrc \
//            src/oversample.cpp tests/verify_oversample_cascade.cpp -o /tmp/voc
#include "oversample.h"

#include <Accelerate/Accelerate.h>
#include <cmath>
#include <cstdio>
#include <random>
#include <vector>

using NAMRig::Down2x;
using NAMRig::Up2x;

static int g_fail = 0;
#define CHECK(cond, msg)                                          \
  do {                                                            \
    if (cond) { std::printf("  PASS  %s\n", msg); }               \
    else { g_fail++; std::printf("  FAIL  %s\n", msg); }          \
  } while (0)

// One-shot 4x reference: apply the 2x FIR twice. The odd outputs of level 1
// become even-positioned samples for level 2; the composed filter is the
// convolution of the half-band with itself (a 2x-band filter), so any signal
// bandlimited to 0.45*fs passes with DC gain 1.
static double last_err = 0;

int main() {
  std::mt19937 rng(4242);
  std::uniform_real_distribution<float> dist(-1.f, 1.f);

  // --- 1. Streaming True-4x round trip: DC and band-limited tone ---
  for (int trial = 0; trial < 3; ++trial) {
    const size_t n = 8192;
    std::vector<float> x(n);
    if (trial == 0) {
      for (auto& v : x) v = 1.0f;                       // DC
    } else {
      const double f = trial == 1 ? 3000.0 : 11000.0;   // in-band tones
      for (size_t i = 0; i < n; ++i)
        x[i] = (float)(0.8 * std::sin(2 * M_PI * f * (double)i / 48000.0));
    }

    // Plugin-shaped cascade: per-level converters, ping-pong buffers,
    // adversarial block sizes. Level sizing mirrors the plugin's worst-case
    // approach (every level sized for the largest block it could ever see).
    std::array<Up2x, 3> ups;
    std::array<Down2x, 3> downs;
    for (auto& u : ups) u.setMaxBlockSize(8 * 8192);
    for (auto& d : downs) d.setMaxBlockSize(8 * 8192);
    std::vector<float> bufA(8192 * 8 + 64), bufB(8192 * 8 + 64);
    float* bufs[2] = {bufA.data(), bufB.data()};

    std::vector<float> y(n + 4096);
    size_t got = 0;
    size_t fed = 0;
    while (fed < n) {
      const size_t blk = std::min<size_t>(1 + rng() % 700, n - fed);
      size_t m = ups[0].process(x.data() + fed, blk, bufs[0]);
      for (size_t c = 1; c < 2; ++c)                    // 4x = 2 levels
        m = ups[c].process(bufs[(c - 1) % 2], m, bufs[c % 2]);
      float* domain = bufs[1 % 2];
      // linear stand-in for the model (cascade math under test)
      for (size_t i = 0; i < m; ++i) domain[i] *= 0.5f;
      size_t back = m;
      const float* dnIn = domain;
      for (size_t c = 2; c-- > 0;) {
        float* dnOut = (c == 0) ? y.data() + got : bufs[(c - 1) % 2];
        // intermediate lands in the OTHER buffer (ping-pong)
        back = downs[c].process(dnIn, back, dnOut);
        dnIn = dnOut;
      }
      fed += blk;
      got += back;
      if (got > y.size() - 8192) break;
    }

    // Reference: the same 0.5 gain applied at BASE rate (linear stage ->
    // domain doesn't matter) => y should converge to 0.5 * x.
    double worst = 0;
    const size_t settle = 4096;   // skip converter warm-up
    for (size_t i = settle; i < got && i < n; ++i)
      worst = std::max(worst, (double)std::fabs(y[i] - 0.5f * x[i]));
    last_err = worst;
    char msg[128];
    std::snprintf(msg, sizeof msg,
                  "True-4x linear round trip == 0.5*x (trial %d, worst %.2e)",
                  trial, worst);
    CHECK(worst < 1e-3, msg);
  }

  // --- 2. Sample-count sanity: 4x domain must actually QUADRUPLE ---
  {
    std::array<Up2x, 3> ups;
    for (auto& u : ups) u.setMaxBlockSize(8 * 4096);
    std::vector<float> x(40000);
    for (auto& v : x) v = dist(rng);
    std::vector<float> bufA(40000 * 8), bufB(40000 * 8);
    float* bufs[2] = {bufA.data(), bufB.data()};
    // feed a big contiguous block: emitted counts should be ~2x and ~4x
    const size_t m1 = ups[0].process(x.data(), 4096, bufs[0]);
    const size_t m2 = ups[1].process(bufs[0], m1, bufs[1]);
    CHECK(m1 >= 4096 * 2 - 64 && m1 <= 4096 * 2, "level 1 emits ~2x samples");
    CHECK(m2 >= 4096 * 4 - 256 && m2 <= 4096 * 4, "level 2 emits ~4x samples");
  }

  std::printf(g_fail ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n", g_fail);
  return g_fail ? 1 : 0;
}
