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

static void writeWavF32Stereo(const std::string& path,
                              const std::vector<float>& interleaved,
                              uint32_t rate) {
  std::ofstream f(path, std::ios::binary);
  auto u32 = [&](uint32_t v) { f.write(reinterpret_cast<const char*>(&v), 4); };
  auto u16 = [&](uint16_t v) { f.write(reinterpret_cast<const char*>(&v), 2); };
  const uint32_t dataBytes = static_cast<uint32_t>(interleaved.size() * 4);
  f.write("RIFF", 4); u32(36 + dataBytes); f.write("WAVE", 4);
  f.write("fmt ", 4); u32(16); u16(3); u16(2); u32(rate); u32(rate * 8);
  u16(8); u16(32);
  f.write("data", 4); u32(dataBytes);
  f.write(reinterpret_cast<const char*>(interleaved.data()), dataBytes);
}

struct ResponseStats {
  double peak = 0.0;
  double rms = 0.0;
};

static ResponseStats responseStats(const std::vector<float>& taps,
                                   double rate) {
  constexpr size_t bins = 512;
  constexpr double pi = 3.14159265358979323846;
  const double low = 20.0;
  const double high = std::max(low, std::min(20000.0, rate * 0.45));
  double peak2 = 0.0, sum2 = 0.0;
  for (size_t b = 0; b < bins; ++b) {
    const double f = low + (high - low) * b / (bins - 1);
    const double radians = -2.0 * pi * f / rate;
    const double sr = std::cos(radians), si = std::sin(radians);
    double pr = 1.0, piPhase = 0.0, re = 0.0, im = 0.0;
    for (float tap : taps) {
      re += tap * pr;
      im += tap * piPhase;
      const double nr = pr * sr - piPhase * si;
      piPhase = pr * si + piPhase * sr;
      pr = nr;
    }
    const double mag2 = re * re + im * im;
    peak2 = std::max(peak2, mag2);
    sum2 += mag2;
  }
  return {std::sqrt(peak2), std::sqrt(sum2 / bins)};
}

static double magnitudeAt(const std::vector<float>& taps, double rate,
                          double frequency) {
  constexpr double pi = 3.14159265358979323846;
  double re = 0.0, im = 0.0;
  for (size_t i = 0; i < taps.size(); ++i) {
    const double phase = -2.0 * pi * frequency * i / rate;
    re += taps[i] * std::cos(phase);
    im += taps[i] * std::sin(phase);
  }
  return std::sqrt(re * re + im * im);
}

// Mirrors WavIR::load's truncation + raised-cosine fade. The limit tracks
// WavIR::kMaxSeconds (170 ms, 8192 taps at 48 kHz) so far-mic and room
// captures keep their tails.
static std::vector<float> truncateFade(std::vector<float> taps, double rate) {
  const size_t maxTaps = static_cast<size_t>(rate * NAMRig::WavIR::kMaxSeconds);
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
      {5000, "long untruncated IR (5000 taps, under the 170 ms limit)"},
      {8160, "exactly at the 170 ms limit (8160 taps at 48k)"},
      {20000, "truncated + faded (20000 -> 8160 taps at 48k)"},
  };
  for (auto& c : cases) {
    const double rel = runCase(dir, c.len, 48000, rng);
    char msg[128];
    std::snprintf(msg, sizeof(msg), "%s: rel err %.3e < 1e-4", c.what, rel);
    CHECK(rel < 1e-4, msg);
  }

  // The 170 ms limit is the point of raising it: a tail that used to be cut
  // at 80 ms must now still be convolved.
  {
    std::vector<float> taps(12000, 0.0f);
    taps[0] = 1.0f;
    taps[5000] = 0.25f;   // ~104 ms: inside 170 ms, beyond the old 80 ms cap
    taps[9000] = 0.20f;   // ~187 ms: beyond the limit, must be gone
    const std::string path = std::string(dir) + "/ir_length.wav";
    writeWavF32(path, taps, 48000);
    auto ir = NAMRig::WavIR::load(path.c_str(), 48000, 512);
    std::vector<float> rendered(14000, 0.0f);
    rendered[0] = 1.0f;
    ir->process(rendered.data(), static_cast<uint32_t>(rendered.size()), 0);
    char message[192];
    std::snprintf(message, sizeof(message),
                  "a 104 ms tail survives (%.3f) while a 187 ms tail is truncated (%.3e)",
                  static_cast<double>(rendered[5000]),
                  static_cast<double>(rendered[9000]));
    CHECK(std::fabs(rendered[5000] - 0.25f) < 1e-4 &&
              std::fabs(rendered[9000]) < 1e-6, message);
  }

  // A stereo cabinet IR must load as two independent convolvers. Summing the
  // channels to mono cancels whatever phase difference makes it stereo.
  {
    const size_t frames = 4000;
    std::vector<float> interleaved(frames * 2, 0.0f);
    interleaved[0] = 1.0f;                 // left: unit impulse at 0
    interleaved[2 * 40 + 1] = 0.5f;        // right: half-scale impulse at 40
    const std::string path = std::string(dir) + "/ir_stereo.wav";
    writeWavF32Stereo(path, interleaved, 48000);
    CHECK(NAMRig::WavIR::channelCount(path.c_str()) == 2,
          "channelCount reports a stereo cabinet IR");
    auto left = NAMRig::WavIR::load(path.c_str(), 48000, 512, false, 0);
    auto right = NAMRig::WavIR::load(path.c_str(), 48000, 512, false, 1);
    auto mono = NAMRig::WavIR::load(path.c_str(), 48000, 512, false, -1);
    std::vector<float> l(512, 0.0f), r(512, 0.0f), m(512, 0.0f);
    l[0] = r[0] = m[0] = 1.0f;
    left->process(l.data(), 512, 0);
    right->process(r.data(), 512, 0);
    mono->process(m.data(), 512, 0);
    char message[192];
    std::snprintf(message, sizeof(message),
                  "stereo channels load independently (L[0] %.3f, R[40] %.3f, R[0] %.3e)",
                  static_cast<double>(l[0]), static_cast<double>(r[40]),
                  static_cast<double>(r[0]));
    CHECK(std::fabs(l[0] - 1.0f) < 1e-4 && std::fabs(r[40] - 0.5f) < 1e-4 &&
              std::fabs(r[0]) < 1e-6, message);
    CHECK(std::fabs(m[0] - 0.5f) < 1e-4 && std::fabs(m[40] - 0.25f) < 1e-4,
          "channel -1 averages both channels (the pre-stereo behaviour)");
  }

  // Original mode keeps the decoded source taps exactly as stored, even when
  // the host rate differs. This intentionally skips resampling, transfer-gain
  // correction, truncation, and the truncation fade.
  {
    std::vector<float> taps(5000);
    for (size_t i = 0; i < taps.size(); ++i)
      taps[i] = static_cast<float>((static_cast<int>(i % 29) - 14) * 0.001);
    const std::string path = std::string(dir) + "/ir_original.wav";
    writeWavF32(path, taps, 48000);
    auto ir = NAMRig::WavIR::load(path.c_str(), 96000, 512, true);
    std::vector<float> rendered(7000, 0.0f);
    rendered[0] = 1.0f;
    ir->process(rendered.data(), static_cast<uint32_t>(rendered.size()), 0);
    double worst = 0.0;
    for (size_t i = 0; i < taps.size(); ++i)
      worst = std::max(worst, std::fabs(static_cast<double>(rendered[i] - taps[i])));
    char message[160];
    std::snprintf(message, sizeof(message),
                  "Original keeps every decoded source tap untouched (worst %.3e, tail %.3e)",
                  worst, static_cast<double>(rendered[5000]));
    CHECK(worst < 1e-5 && std::fabs(rendered[5000]) < 1e-5, message);
  }

  // Normalization operates on the audible transfer response, not on an
  // arbitrary individual IR tap.
  {
    std::vector<float> taps(1000);
    std::normal_distribution<float> dist(0.f, 1.f);
    for (size_t i = 0; i < taps.size(); ++i)
      taps[i] = 0.15f * dist(rng) * std::exp(-static_cast<float>(i) / 140.0f);
    const std::string path = std::string(dir) + "/ir_norm.wav";
    writeWavF32(path, taps, 48000);
    std::vector<float> rendered[3];
    for (int mode = 0; mode < 3; ++mode) {
      auto ir = NAMRig::WavIR::load(path.c_str(), 48000, 512);
      rendered[mode].assign(4096, 0.0f);
      rendered[mode][0] = 1.0f;
      ir->process(rendered[mode].data(), 4096, mode);
    }
    double preserveWorst = 0.0;
    for (size_t i = 0; i < taps.size(); ++i)
      preserveWorst = std::max(
          preserveWorst, std::fabs(static_cast<double>(rendered[0][i] - taps[i])));
    const ResponseStats peak = responseStats(rendered[1], 48000.0);
    const ResponseStats loudness = responseStats(rendered[2], 48000.0);
    CHECK(preserveWorst < 1e-5, "Preserve retains source-rate transfer gain");
    CHECK(std::fabs(peak.peak - 1.0) < 2e-3,
          "Peak sets maximum audible response magnitude to unity");
    CHECK(std::fabs(loudness.rms - 1.0) < 2e-3,
          "Loudness sets average audible response energy to unity");
    CHECK(peak.rms < loudness.rms,
          "Peak leaves more headroom than Loudness on a shaped cab response");
  }

  // Resampling an IR must preserve its transfer gain in physical Hz. This is
  // distinct from resampling an ordinary signal, whose sample amplitude stays
  // unchanged while its sample density changes.
  {
    std::vector<float> taps(256, 0.0f);
    taps[64] = 0.70f;
    taps[65] = -0.20f;
    taps[70] = 0.10f;
    const std::string path = std::string(dir) + "/ir_rate.wav";
    writeWavF32(path, taps, 48000);
    double worstDb = 0.0;
    for (int mode = 0; mode < 3; ++mode) {
      std::vector<float> rendered[2];
      const double rates[] = {48000.0, 96000.0};
      for (int r = 0; r < 2; ++r) {
        auto ir = NAMRig::WavIR::load(path.c_str(), rates[r], 512);
        rendered[r].assign(r == 0 ? 1024 : 2048, 0.0f);
        rendered[r][0] = 1.0f;
        ir->process(rendered[r].data(), static_cast<uint32_t>(rendered[r].size()), mode);
      }
      for (double frequency : {1000.0, 5000.0, 12000.0}) {
        const double a = magnitudeAt(rendered[0], rates[0], frequency);
        const double b = magnitudeAt(rendered[1], rates[1], frequency);
        worstDb = std::max(worstDb, std::fabs(20.0 * std::log10(b / a)));
      }
    }
    char msg[160];
    std::snprintf(msg, sizeof(msg),
                  "all normalization modes are sample-rate invariant (worst %.3f dB)",
                  worstDb);
    CHECK(worstDb < 0.10, msg);
  }

  // Switching modes should not step the output gain at a block boundary.
  {
    const std::string path = std::string(dir) + "/ir_smooth.wav";
    writeWavF32(path, {0.1f}, 48000);
    auto ir = NAMRig::WavIR::load(path.c_str(), 48000, 512);
    std::vector<float> before(512, 1.0f), after(4096, 1.0f);
    ir->process(before.data(), static_cast<uint32_t>(before.size()), 0);
    ir->process(after.data(), static_cast<uint32_t>(after.size()), 1);
    CHECK(std::fabs(after.front() - before.back()) < 0.01f &&
              after.back() > 0.99f && after[1000] > after.front(),
          "normalization changes glide without a gain step");
  }

  std::printf(g_fail ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n", g_fail);
  return g_fail ? 1 : 0;
}
