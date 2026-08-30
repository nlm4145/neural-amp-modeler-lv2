// Verifies the partitioned-FFT WavIR against a direct-convolution reference:
// exact response (zero latency), arbitrary chunk sizes, head-only and
// multi-partition IR lengths, truncation fade, and normalization modes.
// Build: clang++ -O2 -std=c++17 -framework Accelerate -Isrc src/wav_ir.cpp
//        tests/verify_wav_ir.cpp   (run with a scratch dir as argv[1])
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <random>
#include <string>
#include <vector>

#include "wav_ir.h"

static int g_fail = 0;
#define CHECK(cond, msg)                                    \
  do {                                                      \
    if (cond) { std::printf("  PASS  %s\n", msg); }         \
    else { ++g_fail; std::printf("  FAIL  %s\n", msg); }    \
  } while (0)

static void writeWavF32(const std::string& path, const std::vector<float>& x,
                        uint32_t rate) {
  std::ofstream f(path, std::ios::binary);
  auto u32 = [&](uint32_t v) { f.write(reinterpret_cast<const char*>(&v), 4); };
  auto u16 = [&](uint16_t v) { f.write(reinterpret_cast<const char*>(&v), 2); };
  const uint32_t dataBytes = static_cast<uint32_t>(x.size() * 4);
  f.write("RIFF", 4); u32(36 + dataBytes); f.write("WAVE", 4);
  f.write("fmt ", 4); u32(16); u16(3); u16(1); u32(rate); u32(rate * 4);
  u16(4); u16(32);
  f.write("data", 4); u32(dataBytes);
  f.write(reinterpret_cast<const char*>(x.data()), dataBytes);
}

// Mirrors WavIR::load's truncation + raised-cosine fade.
static std::vector<float> truncateFade(std::vector<float> taps, double rate) {
  const size_t maxTaps = static_cast<size_t>(rate * 0.08);
  if (maxTaps > 0 && taps.size() > maxTaps) {
    taps.resize(maxTaps);
    const size_t fade = std::min(taps.size(),
        static_cast<size_t>(std::llround(rate * 0.005)));
    for (size_t i = 0; i < fade; ++i) {
      const double t = static_cast<double>(i + 1) / static_cast<double>(fade);
      taps[taps.size() - fade + i] *=
          static_cast<float>(0.5 * (1.0 + std::cos(3.14159265358979323846 * t)));
    }
  }
  return taps;
}

static double runCase(const char* dir, size_t irLen, uint32_t rate,
                      std::mt19937& rng) {
  std::uniform_real_distribution<float> dist(-1.f, 1.f);
  std::vector<float> taps(irLen);
  for (auto& v : taps) v = dist(rng);
  const std::string path = std::string(dir) + "/ir_" + std::to_string(irLen) + ".wav";
  writeWavF32(path, taps, rate);
  auto ir = NAMRig::WavIR::load(path.c_str(), rate, 512);
  const auto ref = truncateFade(taps, rate);

  const size_t n = 20000;
  std::vector<float> x(n), y(n);
  for (auto& v : x) v = dist(rng);
  y = x;
  size_t done = 0;
  while (done < n) {
    const size_t t = std::min<size_t>(1 + rng() % 700, n - done);
    ir->process(y.data() + done, static_cast<uint32_t>(t), 0);
    done += t;
  }
  double worst = 0.0, peak = 0.0;
  for (size_t i = 0; i < n; ++i) {
    double acc = 0.0;
    const size_t kMax = std::min(ref.size() - 1, i);
    for (size_t k = 0; k <= kMax; ++k) acc += (double)ref[k] * x[i - k];
    worst = std::max(worst, std::fabs(acc - (double)y[i]));
    peak = std::max(peak, std::fabs(acc));
  }
  return worst / std::max(peak, 1e-12);
}

int main(int argc, char** argv) {
  const char* dir = argc > 1 ? argv[1] : "/tmp";
  std::mt19937 rng(20260830);
  struct { size_t len; const char* what; } cases[] = {
      {100, "head-only IR (100 taps)"},
      {256, "exact head boundary (256 taps)"},
      {300, "one partial partition (300 taps)"},
      {3000, "11 partitions (3000 taps)"},
      {5000, "truncated + faded (5000 -> 3840 taps at 48k)"},
  };
  for (auto& c : cases) {
    const double rel = runCase(dir, c.len, 48000, rng);
    char msg[128];
    std::snprintf(msg, sizeof(msg), "%s: rel err %.3e < 1e-4", c.what, rel);
    CHECK(rel < 1e-4, msg);
  }

  // Normalization modes only rescale the same response.
  {
    std::uniform_real_distribution<float> dist(-1.f, 1.f);
    std::vector<float> taps(1000);
    for (auto& v : taps) v = dist(rng);
    const std::string path = std::string(dir) + "/ir_norm.wav";
    writeWavF32(path, taps, 48000);
    float peak = 0.0f; double energy = 0.0;
    for (float t : taps) { peak = std::max(peak, std::fabs(t)); energy += (double)t * t; }
    std::vector<float> x(4096);
    for (auto& v : x) v = dist(rng);
    double worst = 0.0;
    for (int mode = 1; mode <= 2; ++mode) {
      auto a = NAMRig::WavIR::load(path.c_str(), 48000, 512);
      auto b = NAMRig::WavIR::load(path.c_str(), 48000, 512);
      std::vector<float> ya = x, yb = x;
      a->process(ya.data(), 4096, mode);
      b->process(yb.data(), 4096, 0);
      const double s = mode == 1 ? 1.0 / peak : 1.0 / std::sqrt(energy);
      for (size_t i = 0; i < ya.size(); ++i)
        worst = std::max(worst, std::fabs((double)ya[i] - s * yb[i]));
    }
    char msg[128];
    std::snprintf(msg, sizeof(msg), "peak/loudness modes rescale only (worst %.3e)", worst);
    CHECK(worst < 1e-5, msg);
  }

  std::printf(g_fail ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n", g_fail);
  return g_fail ? 1 : 0;
}
