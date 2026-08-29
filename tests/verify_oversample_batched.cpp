// Verify + benchmark: batched vDSP_conv oversamplers (src/oversample.cpp)
// vs the previous per-sample vDSP_dotpr formulation, on identical streams.
//
// The OLD formulation is copied verbatim below (pre-2026-08-29 code) as
// OldUp2x/OldDown2x; the NEW one is the real src/oversample.cpp, included
// into this single TU. Both must:
//   - emit identical sample counts for every call and block sequence,
//   - agree within float dot-product summation-order rounding (< 2e-6 on
//     unit-scale data; same taps, same windows, only order differs),
//   - and the new one should be substantially faster (that's the point).
//
// Build & run (wired into tests/run_all.sh):
//   clang++ -std=c++17 -O2 -framework Accelerate -Isrc \
//       tests/verify_oversample_batched.cpp -o /tmp/vob && /tmp/vob
#include "oversample.h"

#include <Accelerate/Accelerate.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

using NAMRig::halfBandInterp;
using NAMRig::halfBandProto;

// ---- OLD Up2x (verbatim pre-batching logic) ----
struct OldUp2x {
  static constexpr size_t kHist = 23;
  float hist_[kHist] = {};
  size_t next_ = 0, provided_ = 0;
  std::vector<float> scr_ = std::vector<float>(23 + 8192, 0.f);

  size_t process(const float* in, size_t n, float* out) {
    const float* P = halfBandInterp();
    const size_t total = kHist + n;
    if (total > scr_.size()) return 0;
    float* scr = scr_.data();
    std::memcpy(scr, hist_, kHist * sizeof(float));
    std::memcpy(scr + kHist, in, n * sizeof(float));
    const long base = (long)provided_ - (long)kHist;
    long p = (long)next_;
    size_t emitted = 0;
    while (true) {
      const long wStartIdx = (p - 11) - base;
      if (wStartIdx < 0) { ++p; continue; }
      if (wStartIdx + 24 > (long)total) break;
      const size_t j = (size_t)wStartIdx;
      out[2 * emitted] = scr[j + 11];
      vDSP_dotpr(scr + j, 1, P, 1, out + 2 * emitted + 1, 24);
      ++emitted;
      p += 1;
    }
    next_ = (size_t)p;
    provided_ += n;
    if (total >= kHist)
      std::memcpy(hist_, scr + total - kHist, kHist * sizeof(float));
    else
      std::memcpy(hist_, scr, total * sizeof(float));
    return 2 * emitted;
  }
};

// ---- OLD Down2x (verbatim pre-batching logic) ----
struct OldDown2x {
  static constexpr size_t kHist = 46;
  float hist_[kHist] = {};
  size_t consumed_ = 0, emitted_ = 0;
  std::vector<float> scr_ = std::vector<float>(46 + 16384, 0.f);

  size_t process(const float* in, size_t n, float* out) {
    const float* H = halfBandProto();
    const size_t total = kHist + n;
    if (total > scr_.size()) return 0;
    float* scr = scr_.data();
    std::memcpy(scr, hist_, kHist * sizeof(float));
    std::memcpy(scr + kHist, in, n * sizeof(float));
    const long base = (long)consumed_ - (long)kHist;
    size_t emitted = 0;
    long a = 2 * (long)emitted_;
    while (true) {
      const long wStartIdx = (a - 23) - base;
      if (wStartIdx < 0) { a += 2; continue; }
      if (wStartIdx + 47 > (long)total) break;
      vDSP_dotpr(scr + wStartIdx, 1, H, 1, out + emitted, 47);
      ++emitted;
      a += 2;
    }
    emitted_ += emitted;
    consumed_ += n;
    if (total >= kHist)
      std::memcpy(hist_, scr + total - kHist, kHist * sizeof(float));
    else
      std::memcpy(hist_, scr, total * sizeof(float));
    return emitted;
  }
};

static int g_fail = 0;
#define CHECK(cond, msg)                                        \
  do {                                                          \
    if (cond) { std::printf("  PASS  %s\n", msg); }             \
    else { g_fail++; std::printf("  FAIL  %s\n", msg); }        \
  } while (0)

int main() {
  std::mt19937 rng(20260829);
  std::uniform_real_distribution<float> dist(-1.f, 1.f);

  // -------- 1. equivalence over adversarial block sequences --------
  double worst_up = 0, worst_dn = 0;
  bool counts_match = true, no_oversize = true;
  for (int trial = 0; trial < 300; ++trial) {
    const size_t n_total = 24 + rng() % 4000;
    std::vector<float> x(n_total);
    for (auto& v : x) v = dist(rng);

    NAMRig::Up2x upNew; OldUp2x upOld;
    upNew.setMaxBlockSize(4096 + 23);
    size_t fed = 0, got_total = 0;
    std::vector<float> outNew(2 * 4096 + 64), outOld(2 * 4096 + 64);
    while (fed < n_total) {
      const size_t n = 1 + rng() % std::min<size_t>(4096, n_total - fed);
      const size_t rN = upNew.process(x.data() + fed, n, outNew.data());
      const size_t rO = upOld.process(x.data() + fed, n, outOld.data());
      if (rN != rO) { counts_match = false; }
      if (rN > outNew.size()) { no_oversize = false; }
      const size_t m = std::min(rN, rO);
      for (size_t i = 0; i < m; ++i)
        worst_up = std::max(worst_up, (double)std::fabs(outNew[i] - outOld[i]));
      fed += n;
      got_total += rN;
    }
  }
  CHECK(counts_match, "Up2x: identical emitted counts, every call/block size");
  CHECK(no_oversize, "Up2x: new return never exceeds caller promise");
  CHECK(worst_up < 2e-6, "Up2x: new == old within float rounding");
  std::printf("        worst Up2x diff %.3e\n", worst_up);

  for (int trial = 0; trial < 300; ++trial) {
    const size_t n_total = 48 + rng() % 8000;
    std::vector<float> u(n_total);
    for (auto& v : u) v = dist(rng);
    NAMRig::Down2x dnNew; OldDown2x dnOld;
    dnNew.setMaxBlockSize(8192 + 46);
    size_t fed = 0;
    std::vector<float> outNew(8192 + 64), outOld(8192 + 64);
    while (fed < n_total) {
      const size_t n = 1 + rng() % std::min<size_t>(8192, n_total - fed);
      const size_t rN = dnNew.process(u.data() + fed, n, outNew.data());
      const size_t rO = dnOld.process(u.data() + fed, n, outOld.data());
      if (rN != rO) { counts_match = false; }
      const size_t m = std::min(rN, rO);
      for (size_t i = 0; i < m; ++i)
        worst_dn = std::max(worst_dn, (double)std::fabs(outNew[i] - outOld[i]));
      fed += n;
    }
  }
  CHECK(counts_match, "Down2x: identical emitted counts, every call/block size");
  CHECK(worst_dn < 2e-6, "Down2x: new == old within float rounding");
  std::printf("        worst Down2x diff %.3e\n", worst_dn);

  // -------- 2. steady-state timing, Element-like 512-sample blocks --------
  // 10 s of 96 kHz audio through UP then DOWN, both formulations.
  const size_t kBlocks = 1875;             // ~10 s at 96k/512
  const size_t kBlock = 512;
  std::vector<float> in(kBlock);
  for (auto& v : in) v = dist(rng);
  std::vector<float> outUp(2 * kBlock), outDn(kBlock);

  auto timeUp = [&](bool old) {
    OldUp2x o; NAMRig::Up2x nw;
    nw.setMaxBlockSize(kBlock);
    uint64_t ticks = 0;
    for (size_t it = 0; it < 3; ++it) {    // 3 runs: worst-case reporter
      const clock_t c = clock();
      for (size_t b = 0; b < kBlocks; ++b) {
        if (old) o.process(in.data(), kBlock, outUp.data());
        else nw.process(in.data(), kBlock, outUp.data());
      }
      ticks = std::max<uint64_t>(ticks, (uint64_t)(clock() - c));
    }
    return ticks;
  };
  const double tUpOld = (double)timeUp(true);
  const double tUpNew = (double)timeUp(false);
  std::printf("  Up2x   old %.0f ms / new %.0f ms for 10 s of 96 kHz audio"
              " -> %.1fx faster\n",
              tUpOld / CLOCKS_PER_SEC * 1e3, tUpNew / CLOCKS_PER_SEC * 1e3,
              tUpOld / std::max(tUpNew, 1.0));

  auto timeDn = [&](bool old) {
    OldDown2x o; NAMRig::Down2x nw;
    nw.setMaxBlockSize(2 * kBlock);
    uint64_t ticks = 0;
    for (size_t it = 0; it < 3; ++it) {
      const clock_t c = clock();
      for (size_t b = 0; b < kBlocks; ++b) {
        if (old) o.process(outUp.data(), 2 * kBlock, outDn.data());
        else nw.process(outUp.data(), 2 * kBlock, outDn.data());
      }
      ticks = std::max<uint64_t>(ticks, (uint64_t)(clock() - c));
    }
    return ticks;
  };
  const double tDnOld = (double)timeDn(true);
  const double tDnNew = (double)timeDn(false);
  std::printf("  Down2x old %.0f ms / new %.0f ms for 10 s of 96 kHz audio"
              " -> %.1fx faster\n",
              tDnOld / CLOCKS_PER_SEC * 1e3, tDnNew / CLOCKS_PER_SEC * 1e3,
              tDnOld / std::max(tDnNew, 1.0));

  CHECK(tUpNew < tUpOld && tDnNew < tDnOld,
        "batched converters faster than per-sample (both stages)");

  std::printf(g_fail ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n",
              g_fail);
  return g_fail ? 1 : 0;
}
