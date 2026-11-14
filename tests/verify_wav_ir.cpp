// Verifies the partitioned-FFT WavIR against a direct-convolution reference:
// exact response (zero latency), arbitrary chunk sizes, head-only and
// multi-partition IR lengths, truncation fade, and normalization modes.
// Build: clang++ -O2 -std=c++17 -framework Accelerate -Isrc src/wav_ir.cpp
//        src/dsp_accel.cpp tests/verify_wav_ir.cpp
//        (run with a scratch dir as argv[1])
#include <algorithm>
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

static double perceptualWeight(double hz) {
  const double ul = hz / 75.0;
  const double ul2 = ul * ul;
  const double ul4 = ul2 * ul2;
  const double hp = ul4 / (1.0 + ul4);

  const double uh = hz / 5400.0;
  const double uh2 = uh * uh;
  const double uh4 = uh2 * uh2;
  const double lp = 1.0 / (1.0 + uh4);

  const double f2 = hz * hz;
  const double shelfRatio = f2 / (f2 + 1682.0 * 1682.0);
  const double kHalfShelf = std::pow(10.0, 0.2 * shelfRatio);
  return hp * lp * kHalfShelf;
}

static ResponseStats responseStats(const std::vector<float>& taps,
                                   double rate) {
  constexpr size_t bins = 512;
  constexpr double pi = 3.14159265358979323846;
  constexpr double low = 20.0;
  constexpr double maxHz = 20000.0;
  const double high = std::max(low, std::min(maxHz, rate * 0.45));
  const double spanRatio = maxHz / low;
  double peak2 = 0.0, wSum2 = 0.0, wSum = 0.0;
  for (size_t b = 0; b < bins; ++b) {
    const double t = static_cast<double>(b) / static_cast<double>(bins - 1);
    const double f = low * std::pow(spanRatio, t);
    if (f > high) break;
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
    const double w = perceptualWeight(f);
    peak2 = std::max(peak2, mag2);
    wSum2 += w * mag2;
    wSum += w;
  }
  return {std::sqrt(peak2), wSum > 0.0 ? std::sqrt(wSum2 / wSum) : 0.0};
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
  const float scale = static_cast<float>(1.0 / responseStats(ref, rate).rms);

  const size_t n = 20000;
  std::vector<float> x(n), y(n);
  for (auto& v : x) v = dist(rng);
  y = x;
  size_t done = 0;
  while (done < n) {
    const size_t t = std::min<size_t>(1 + rng() % 700, n - done);
    ir->process(y.data() + done, static_cast<uint32_t>(t), 2);
    done += t;
  }
  double worst = 0.0, peak = 0.0;
  for (size_t i = 0; i < n; ++i) {
    double acc = 0.0;
    const size_t kMax = std::min(ref.size() - 1, i);
    for (size_t k = 0; k <= kMax; ++k) acc += (double)ref[k] * x[i - k];
    acc *= scale;
    worst = std::max(worst, std::fabs(acc - (double)y[i]));
    peak = std::max(peak, std::fabs(acc));
  }
  return worst / std::max(peak, 1e-12);
}

static void writeWavCustomF32(const std::string& path,
                              const std::vector<float>& interleaved,
                              uint32_t rate,
                              uint16_t channels,
                              bool extensible = false) {
  std::ofstream out(path, std::ios::binary);
  auto w16 = [&](uint16_t v) { out.write(reinterpret_cast<const char*>(&v), 2); };
  auto w32 = [&](uint32_t v) { out.write(reinterpret_cast<const char*>(&v), 4); };
  const uint32_t fmtSize = extensible ? 40u : 16u;
  const uint32_t dataSize = static_cast<uint32_t>(interleaved.size() * sizeof(float));
  const uint16_t blockAlign = static_cast<uint16_t>(channels * 4u);
  out.write("RIFF", 4);
  w32(4u + 8u + fmtSize + 8u + dataSize);
  out.write("WAVEfmt ", 8);
  w32(fmtSize);
  w16(extensible ? 0xFFFEu : 3u);
  w16(channels);
  w32(rate);
  w32(rate * blockAlign);
  w16(blockAlign);
  w16(32);
  if (extensible) {
    w16(22);
    w16(32);
    w32(channels == 6 ? 0x3Fu : channels == 4 ? 0x33u : 0x7u);
    static constexpr uint8_t kSubFloat[16] = {
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
        0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71};
    out.write(reinterpret_cast<const char*>(kSubFloat), 16);
  }
  out.write("data", 4);
  w32(dataSize);
  if (!interleaved.empty()) {
    out.write(reinterpret_cast<const char*>(interleaved.data()), dataSize);
  }
}

static void verifyAutoTrimAndMultichannel(const char* dir) {
  auto argmaxAbs = [](const std::vector<float>& v) -> size_t {
    size_t idx = 0;
    float best = -1.0f;
    for (size_t i = 0; i < v.size(); ++i) {
      const float a = std::fabs(v[i]);
      if (a > best) { best = a; idx = i; }
    }
    return idx;
  };

  // 1. Optional leading-silence auto-trim preserves tail beyond kMaxSeconds.
  {
    const std::string p = std::string(dir) + "/padded_tail.wav";
    std::vector<float> raw(12160, 0.0f);
    for (size_t i = 0; i < 4000; ++i) raw[i] = (i % 2 ? 1.0f : -1.0f) * 3.0e-5f; // -90 dB noise floor
    raw[4000] = 1.0f;
    raw[10000] = 0.25f; // 6000 samples after main impulse
    writeWavCustomF32(p, raw, 48000, 1);

    const auto untrimmed = NAMRig::WavIR::loadTaps(p.c_str(), 48000.0, -1, false);
    const auto trimmed = NAMRig::WavIR::loadTaps(p.c_str(), 48000.0, -1, true);
    CHECK(untrimmed.size() == 8160, "untrimmed IR starts at offset 0 and truncates at 8160");
    CHECK(argmaxAbs(untrimmed) == 4000, "untrimmed IR keeps 4000-sample leading latency");
    CHECK(argmaxAbs(trimmed) == 0, "autoTrimSilence moves main impulse to sample 0");
    CHECK(trimmed.size() == 8160 && std::fabs(trimmed[0]) > 0.0f &&
              std::fabs(trimmed[6000] / trimmed[0] - 0.25f) < 1e-4f,
          "autoTrimSilence recovers late tail after removing leading silence");
  }

  // 2. Stereo cross-channel trim preserves L/R inter-channel arrival delay across resample.
  {
    const std::string p = std::string(dir) + "/stereo_delay_44k.wav";
    const size_t frames = 2000;
    std::vector<float> interleaved(frames * 2, 0.0f);
    interleaved[882 * 2 + 0] = 1.0f;            // L @ 20.0 ms
    interleaved[(882 + 44) * 2 + 1] = 0.9f;     // R @ 21.0 ms (1 ms after L)
    writeWavCustomF32(p, interleaved, 44100, 2);

    const auto stereoTaps = NAMRig::WavIR::loadTapsStereo(p.c_str(), 48000.0, true);
    const size_t peakL = argmaxAbs(stereoTaps.first);
    const size_t peakR = argmaxAbs(stereoTaps.second);
    const ptrdiff_t delta = static_cast<ptrdiff_t>(peakR) - static_cast<ptrdiff_t>(peakL);
    CHECK(peakL <= 4 && delta >= 44 && delta <= 52,
          "stereo autoTrimSilence trims uniformly across channels and keeps L/R delay across resample");

    auto stereoIr = NAMRig::WavIR::loadStereo(p.c_str(), 48000.0, 512, true);
    CHECK(NAMRig::WavIR::channelCount(p.c_str()) == 2 && stereoIr.left && stereoIr.right,
          "loadStereo loads 2ch WavIR pair with autoTrimSilence");
    std::vector<float> bufL(256, 0.0f), bufR(256, 0.0f);
    bufL[0] = 1.0f;
    bufR[0] = 1.0f;
    stereoIr.left->process(bufL.data(), 256, 0);
    stereoIr.right->process(bufR.data(), 256, 0);
    const size_t outL = argmaxAbs(bufL);
    const size_t outR = argmaxAbs(bufR);
    CHECK(outL <= 4 && outR > outL + 40 && outR < outL + 56,
          "live stereo WavIR convolution preserves L/R inter-channel arrival delay");
  }

  // 3. All-zero WAV with autoTrimSilence yields finite zero output.
  {
    const std::string p = std::string(dir) + "/all_zero.wav";
    writeWavCustomF32(p, std::vector<float>(256, 0.0f), 48000, 1);
    auto z = NAMRig::WavIR::load(p.c_str(), 48000.0, 64, 0, true);
    CHECK(z != nullptr, "all-zero WAV loads safely with autoTrimSilence");
    std::vector<float> buf(64, 0.0f);
    buf[0] = 1.0f;
    z->process(buf.data(), 64, 2);
    bool finiteZero = true;
    for (float s : buf) finiteZero &= std::isfinite(s) && s == 0.0f;
    CHECK(finiteZero, "all-zero trimmed IR produces finite zeros");
  }

  // 4. findBestAlignment honors autoTrimSilence on silent-padded stereo pair.
  {
    const std::string aPath = std::string(dir) + "/align_a.wav";
    const std::string bPath = std::string(dir) + "/align_b.wav";
    std::vector<float> a(512, 0.0f), b(1024, 0.0f);
    a[0] = 1.0f; a[1] = 0.5f;
    b[480] = 1.0f; b[481] = 0.5f; // +10 ms leading silence
    writeWavCustomF32(aPath, a, 48000, 1);
    writeWavCustomF32(bPath, b, 48000, 1);
    const auto alignUntrimmed = NAMRig::WavIR::findBestAlignment(aPath.c_str(), bPath.c_str(), 48000.0, false);
    const auto alignTrimmed = NAMRig::WavIR::findBestAlignment(aPath.c_str(), bPath.c_str(), 48000.0, true);
    CHECK(alignUntrimmed.valid && std::fabs(alignUntrimmed.delayMs + 10.0f) < 0.25f,
          "untrimmed findBestAlignment sees 10 ms padding offset");
    CHECK(alignTrimmed.valid && std::fabs(alignTrimmed.delayMs) < 0.1f && !alignTrimmed.invertPolarity,
          "autoTrimSilence findBestAlignment aligns silent-padded IR near 0 ms");
  }

  // 5. Multichannel (> 2 ch) WAV IR stereo folddown (3ch, 4ch, 6ch, WAVE_FORMAT_EXTENSIBLE).
  {
    const std::string p3 = std::string(dir) + "/ir_3ch.wav";
    std::vector<float> i3(128 * 3, 0.0f);
    i3[40 * 3 + 2] = 1.0f; // Center only
    writeWavCustomF32(p3, i3, 48000, 3);
    const auto s3 = NAMRig::WavIR::loadTapsStereo(p3.c_str(), 48000.0, false);
    CHECK(NAMRig::WavIR::channelCount(p3.c_str()) == 3 &&
              s3.first.size() == 128 && s3.second.size() == 128 &&
              s3.first[40] > 0.0f && std::fabs(s3.first[40] - s3.second[40]) <= 1e-6f * std::fabs(s3.first[40]),
          "3ch L/R/C folds Center symmetrically into L and R");

    const std::string p4 = std::string(dir) + "/ir_4ch_ext.wav";
    std::vector<float> i4(128 * 4, 0.0f);
    i4[30 * 4 + 2] = 1.0f;   // Ls
    i4[60 * 4 + 3] = -1.0f;  // Rs
    writeWavCustomF32(p4, i4, 48000, 4, true);
    CHECK(NAMRig::WavIR::channelCount(p4.c_str()) == 4, "4ch WAVE_FORMAT_EXTENSIBLE reports 4 channels");
    const auto s4 = NAMRig::WavIR::loadTapsStereo(p4.c_str(), 48000.0, false);
    CHECK(s4.first.size() == 128 && s4.second.size() == 128 &&
              s4.first[30] > 0.0f && s4.second[60] < 0.0f &&
              std::fabs(s4.first[60]) < 1e-6f && std::fabs(s4.second[30]) < 1e-6f,
          "4ch L/R/Ls/Rs folds Ls->L and Rs->R");

    const std::string p6 = std::string(dir) + "/ir_6ch_ext.wav";
    std::vector<float> i6(128 * 6, 0.0f);
    i6[25 * 6 + 5] = 0.8f; // Rs
    i6[50 * 6 + 2] = 1.0f; // C
    writeWavCustomF32(p6, i6, 48000, 6, true);
    const auto s6 = NAMRig::WavIR::loadTapsStereo(p6.c_str(), 48000.0, false);
    CHECK(NAMRig::WavIR::channelCount(p6.c_str()) == 6 &&
              s6.first.size() == 128 && s6.second.size() == 128 &&
              s6.second[25] > 0.0f && s6.first[50] > 0.0f && s6.second[50] > 0.0f,
          "6ch 5.1 WAVE_FORMAT_EXTENSIBLE folds C and Rs into stereo IR");
  }
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
  verifyAutoTrimAndMultichannel(dir);

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
    const float scale = static_cast<float>(
        1.0 / responseStats(truncateFade(taps, 48000), 48000).rms);
    std::vector<float> rendered(14000, 0.0f);
    rendered[0] = 1.0f;
    ir->process(rendered.data(), static_cast<uint32_t>(rendered.size()), 2);
    char message[192];
    std::snprintf(message, sizeof(message),
                  "a 104 ms tail survives (%.3f) while a 187 ms tail is truncated (%.3e)",
                  static_cast<double>(rendered[5000]),
                  static_cast<double>(rendered[9000]));
    CHECK(std::fabs(rendered[5000] - 0.25f * scale) < 1e-4 &&
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
    auto left = NAMRig::WavIR::load(path.c_str(), 48000, 512, 0);
    auto right = NAMRig::WavIR::load(path.c_str(), 48000, 512, 1);
    auto mono = NAMRig::WavIR::load(path.c_str(), 48000, 512, -1);
    NAMRig::WavIR::linkStereoNormalization(*left, *right);
    std::vector<float> monoTaps(frames, 0.0f);
    monoTaps[0] = 0.5f;
    monoTaps[40] = 0.25f;
    const float monoScale = static_cast<float>(1.0 / responseStats(monoTaps, 48000).peak);
    std::vector<float> l(512, 0.0f), r(512, 0.0f), m(512, 0.0f);
    l[0] = r[0] = m[0] = 1.0f;
    left->process(l.data(), 512, 1);
    right->process(r.data(), 512, 1);
    mono->process(m.data(), 512, 1);
    char message[192];
    std::snprintf(message, sizeof(message),
                  "stereo channels load independently (L[0] %.3f, R[40] %.3f, R[0] %.3e)",
                  static_cast<double>(l[0]), static_cast<double>(r[40]),
                  static_cast<double>(r[0]));
    CHECK(std::fabs(l[0] - 1.0f) < 1e-4 && std::fabs(r[40] - 0.5f) < 1e-4 &&
              std::fabs(r[0]) < 1e-6, message);
    CHECK(std::fabs(m[0] - 0.5f * monoScale) < 1e-4 &&
              std::fabs(m[40] - 0.25f * monoScale) < 1e-4,
          "channel -1 averages both channels before response normalization");

    // Stereo normalization is linked: a deliberately quieter right channel
    // must remain quieter instead of being independently raised to unity.
    std::vector<float> unbalanced(frames * 2, 0.0f);
    unbalanced[0] = 1.0f;
    unbalanced[1] = 0.1f;
    const std::string balancePath = std::string(dir) + "/ir_stereo_balance.wav";
    writeWavF32Stereo(balancePath, unbalanced, 48000);
    for (int mode : {1, 2}) {
      auto linkedL = NAMRig::WavIR::load(balancePath.c_str(), 48000, 512, 0);
      auto linkedR = NAMRig::WavIR::load(balancePath.c_str(), 48000, 512, 1);
      NAMRig::WavIR::linkStereoNormalization(*linkedL, *linkedR);
      std::vector<float> outL(512, 0.0f), outR(512, 0.0f);
      outL[0] = outR[0] = 1.0f;
      linkedL->process(outL.data(), outL.size(), mode);
      linkedR->process(outR.data(), outR.size(), mode);
      CHECK(std::fabs(outR[0] / outL[0] - 0.1f) < 1.0e-4f,
            mode == 1 ? "linked stereo Peak normalization preserves channel balance"
                      : "linked stereo Loudness normalization preserves channel balance");
    }
  }

  // Legacy Preserve (0) and Original (3) values now use Loudness (2).
  {
    std::vector<float> taps(5000);
    for (size_t i = 0; i < taps.size(); ++i)
      taps[i] = static_cast<float>((static_cast<int>(i % 29) - 14) * 0.001);
    const std::string path = std::string(dir) + "/ir_fallback.wav";
    writeWavF32(path, taps, 48000);
    std::vector<float> rendered[4];
    for (int mode : {2, 0, 3}) {
      auto ir = NAMRig::WavIR::load(path.c_str(), 96000, 512);
      rendered[mode].assign(12000, 0.0f);
      rendered[mode][0] = 1.0f;
      ir->process(rendered[mode].data(), static_cast<uint32_t>(rendered[mode].size()), mode);
      if (mode != 2)
        CHECK(std::equal(rendered[mode].begin(), rendered[mode].end(), rendered[2].begin(),
                         [](float a, float b) { return std::fabs(a - b) < 1e-5f; }),
              mode == 0 ? "legacy Preserve matches Loudness" : "legacy Original matches Loudness");
    }
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
    const ResponseStats peak = responseStats(rendered[1], 48000.0);
    const ResponseStats loudness = responseStats(rendered[2], 48000.0);
    CHECK(std::equal(rendered[0].begin(), rendered[0].end(), rendered[2].begin(),
                     [](float a, float b) { return std::fabs(a - b) < 1e-5f; }),
          "legacy mode 0 uses Loudness at the source rate");
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
    for (int mode : {1, 2}) {
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
                  "Peak and Loudness are sample-rate invariant (worst %.3f dB)",
                  worstDb);
    CHECK(worstDb < 0.10, msg);
  }

  // Minimum-phase / peak-near-0 IRs have t = 0 right next to the left
  // boundary: resampling across rate families must not drop pre-ringing energy
  // or distort frequency response or inter-channel phase alignment.
  {
    std::vector<float> damped(512, 0.0f);
    for (size_t i = 0; i < damped.size(); ++i)
      damped[i] = std::exp(-static_cast<float>(i) / 30.0f) *
                  std::cos(0.15f * static_cast<float>(i));

    struct RatePair { double from; double to; double maxAllowedDb; };
    const RatePair pairs[] = {
        {48000.0, 96000.0, 0.10},
        {96000.0, 48000.0, 0.15},
        {192000.0, 48000.0, 0.25},
        {44100.0, 48000.0, 0.05},
        {48000.0, 44100.0, 0.08},
    };
    double worstMinPhaseDb = 0.0;
    for (const auto& rp : pairs) {
      const std::string path = std::string(dir) + "/ir_minphase0.wav";
      writeWavF32(path, damped, static_cast<uint32_t>(rp.from));
      const auto taps = NAMRig::WavIR::loadTaps(path.c_str(), rp.to);
      double caseWorst = 0.0;
      for (double freq : {50.0, 100.0, 500.0, 1000.0, 5000.0, 10000.0, 18000.0}) {
        const double a = magnitudeAt(damped, rp.from, freq);
        const double b = magnitudeAt(taps, rp.to, freq);
        caseWorst = std::max(caseWorst, std::fabs(20.0 * std::log10(b / a)));
      }
      worstMinPhaseDb = std::max(worstMinPhaseDb, caseWorst);
      char msg[160];
      std::snprintf(msg, sizeof(msg),
                    "peak@0 resampling %.0f->%.0f preserves FR (worst %.3f dB < %.2f dB)",
                    rp.from, rp.to, caseWorst, rp.maxAllowedDb);
      CHECK(caseWorst < rp.maxAllowedDb, msg);
    }
    (void)worstMinPhaseDb;

    // Peak at sample 2 (early-peak 192->48 worst case for boundary wsum skew).
    std::vector<float> peak2(512, 0.0f);
    for (size_t i = 2; i < peak2.size(); ++i) peak2[i] = damped[i - 2];
    const std::string path2 = std::string(dir) + "/ir_minphase2.wav";
    writeWavF32(path2, peak2, 192000);
    const auto taps2 = NAMRig::WavIR::loadTaps(path2.c_str(), 48000.0);
    double worstPeak2Db = 0.0;
    for (double freq : {50.0, 100.0, 500.0, 1000.0, 5000.0, 10000.0, 18000.0}) {
      const double a = magnitudeAt(peak2, 192000.0, freq);
      const double b = magnitudeAt(taps2, 48000.0, freq);
      worstPeak2Db = std::max(worstPeak2Db, std::fabs(20.0 * std::log10(b / a)));
    }
    char msg2[160];
    std::snprintf(msg2, sizeof(msg2),
                  "peak@2 resampling 192000->48000 preserves FR (worst %.3f dB < 0.15 dB)",
                  worstPeak2Db);
    CHECK(worstPeak2Db < 0.15, msg2);

    // Stereo phase alignment: L starts at sample 0, R is delayed by 12 samples
    // at 48 kHz; both are resampled to 96 kHz and must retain their L+R comb
    // transfer function without relative group-delay drift.
    const size_t stFrames = 512;
    std::vector<float> stereoInterleaved(stFrames * 2, 0.0f);
    for (size_t i = 0; i < stFrames; ++i) {
      stereoInterleaved[2 * i] = damped[i];
      stereoInterleaved[2 * i + 1] = i >= 12 ? damped[i - 12] : 0.0f;
    }
    const std::string stPath = std::string(dir) + "/ir_stereo_comb.wav";
    writeWavF32Stereo(stPath, stereoInterleaved, 48000);
    const auto l96 = NAMRig::WavIR::loadTaps(stPath.c_str(), 96000.0, 0);
    const auto r96 = NAMRig::WavIR::loadTaps(stPath.c_str(), 96000.0, 1);
    std::vector<float> sum48(stFrames, 0.0f), sum96(std::min(l96.size(), r96.size()), 0.0f);
    for (size_t i = 0; i < stFrames; ++i)
      sum48[i] = stereoInterleaved[2 * i] + stereoInterleaved[2 * i + 1];
    for (size_t i = 0; i < sum96.size(); ++i)
      sum96[i] = l96[i] + r96[i];
    double worstCombDb = 0.0;
    for (double freq : {100.0, 500.0, 1000.0, 3000.0, 6000.0, 12000.0, 16000.0}) {
      const double a = magnitudeAt(sum48, 48000.0, freq);
      const double b = magnitudeAt(sum96, 96000.0, freq);
      if (a > 1.0e-3) worstCombDb = std::max(worstCombDb, std::fabs(20.0 * std::log10(b / a)));
    }
    char combMsg[160];
    std::snprintf(combMsg, sizeof(combMsg),
                  "stereo L@0 + R@12 retains L+R comb response across 48k->96k (worst %.3f dB < 0.15 dB)",
                  worstCombDb);
    CHECK(worstCombDb < 0.15, combMsg);

    // Silence IR resampling remains finite and zero.
    std::vector<float> silent(128, 0.0f);
    const std::string silentPath = std::string(dir) + "/ir_silent.wav";
    writeWavF32(silentPath, silent, 96000);
    const auto silentOut = NAMRig::WavIR::loadTaps(silentPath.c_str(), 48000.0);
    bool allZero = !silentOut.empty();
    for (float v : silentOut) allZero &= (v == 0.0f && std::isfinite(v));
    CHECK(allZero, "all-zero IR resamples cleanly to finite zeros");
  }

  // Switching modes should not step the output gain at a block boundary.
  {
    const std::string path = std::string(dir) + "/ir_smooth.wav";
    writeWavF32(path, std::vector<float>(12, 0.08f), 48000);
    auto ir = NAMRig::WavIR::load(path.c_str(), 48000, 512);
    std::vector<float> before(512, 1.0f), after(4096, 1.0f);
    ir->process(before.data(), static_cast<uint32_t>(before.size()), 1);
    ir->process(after.data(), static_cast<uint32_t>(after.size()), 2);
    CHECK(std::fabs(after.front() - before.back()) < 0.01f &&
              after.back() > 1.20f && after[1000] > after.front(),
          "Peak to Loudness glides without a gain step");
  }

  // Item 4: Perceptual log-spaced Loudness normalization tests.
  {
    constexpr double pi = 3.14159265358979323846;

    // 1. Flat unit impulse preserves unity gain across sample rates.
    const std::string flatPath = std::string(dir) + "/ir_flat_unit.wav";
    writeWavF32(flatPath, {1.0f}, 48000);
    bool flatUnity = true;
    for (double hostRate : {44100.0, 48000.0, 96000.0, 192000.0}) {
      auto ir = NAMRig::WavIR::load(flatPath.c_str(), hostRate, 512);
      std::vector<float> impulse(256, 0.0f);
      impulse[0] = 1.0f;
      ir->process(impulse.data(), static_cast<uint32_t>(impulse.size()), 2);
      const double gainAt1k = magnitudeAt(impulse, hostRate, 1000.0);
      flatUnity &= std::fabs(gainAt1k - 1.0) < 0.02;
    }
    CHECK(flatUnity, "flat unit impulse Loudness normalizes to unity across rates");

    // Helper: synthesize a causal minimum-phase-like damped bandpass IR by
    // inverse-DFT / cosine-bank damped resonators so we can compare realistic
    // Bright vs Dark vs Fizzy vs Boomy cab curves.
    auto makeCabIR = [&](double lowCutHz, double midBumpHz, double midBumpDb,
                         double presHz, double presDb, double hiCutHz,
                         double fizzGain = 0.0, double subThumpGain = 0.0) {
      const size_t n = 1024;
      const double fs = 48000.0;
      std::vector<float> taps(n, 0.0f);
      auto lp = [&](double f, double fc) {
        const double r = f / fc;
        return 1.0 / std::sqrt(1.0 + r * r * r * r);
      };
      auto hp = [&](double f, double fc) {
        const double r = f / fc;
        const double r4 = r * r * r * r;
        return r4 / std::sqrt(1.0 + r4 * r4 + 2.0 * r4);
      };
      auto peak = [&](double f, double f0, double q, double db) {
        const double g = std::pow(10.0, db / 20.0);
        const double d = (f - f0) / (f0 / q);
        return 1.0 + (g - 1.0) / (1.0 + d * d);
      };
      // Build causal real impulse directly via IDFT of target magnitude * causal exponential phase
      const size_t bins = 256;
      for (size_t k = 1; k < bins; ++k) {
        const double f = 20.0 + (20000.0 - 20.0) * k / bins;
        const double mag = hp(f, lowCutHz) * lp(f, hiCutHz) *
                           peak(f, midBumpHz, 1.5, midBumpDb) *
                           peak(f, presHz, 1.3, presDb) *
                           (1.0 + fizzGain * std::exp(-std::pow((f - 12000.0) / 3000.0, 2.0))) *
                           (1.0 + subThumpGain * std::exp(-std::pow((f - 36.0) / 14.0, 2.0)));
        const double decay = std::max(8.0, fs / (2.5 * f));
        const double amp = mag * (20000.0 / bins) / fs;
        for (size_t i = 0; i < n; ++i) {
          const double env = std::exp(-static_cast<double>(i) / (40.0 + decay));
          taps[i] += static_cast<float>(amp * env * std::cos(2.0 * pi * f * i / fs));
        }
      }
      return taps;
    };

    auto kWeightedGuitarRms = [&](NAMRig::WavIR& ir, int mode) {
      // Pink-weighted multi-tone across core electric guitar spectrum (82 Hz .. 5.2 kHz),
      // rendered cleanly after settling and weighted by ITU BS.1770 K-shelf.
      const double fs = 48000.0;
      const size_t N = 4096;
      std::vector<float> buf(N, 0.0f);
      std::vector<double> testFreqs;
      for (int i = 0; i < 24; ++i) {
        testFreqs.push_back(82.0 * std::pow(5200.0 / 82.0, i / 23.0));
      }
      for (double f : testFreqs) {
        // Equal amplitude per log-spaced bin corresponds to 1/f pink spectrum
        // shaped by the guitar harmonic envelope (~80 Hz .. 4.8 kHz).
        const double ul = f / 80.0;
        const double uh = f / 4800.0;
        const double env = (ul * ul / std::sqrt(1.0 + ul * ul * ul * ul)) *
                           (1.0 / std::sqrt(1.0 + uh * uh * uh * uh));
        const double amp = 0.05 * env;
        for (size_t n = 0; n < N; ++n) {
          buf[n] += static_cast<float>(amp * std::sin(2.0 * pi * f * n / fs + f));
        }
      }
      ir.process(buf.data(), static_cast<uint32_t>(N), mode);
      double sum2 = 0.0;
      const size_t start = 1024;
      for (double f : testFreqs) {
        double re = 0.0, im = 0.0;
        for (size_t n = start; n < N; ++n) {
          const double ph = -2.0 * pi * f * n / fs;
          re += buf[n] * std::cos(ph);
          im += buf[n] * std::sin(ph);
        }
        const double kShelf = std::pow(10.0, 0.4 * (f * f / (f * f + 1682.0 * 1682.0)));
        sum2 += kShelf * (re * re + im * im);
      }
      return std::sqrt(sum2);
    };

    const auto cabBase = makeCabIR(85.0, 130.0, 4.0, 2600.0, 4.0, 5200.0);
    const auto cabFizzy = makeCabIR(85.0, 130.0, 4.0, 2600.0, 4.0, 5200.0, 4.0, 0.0);
    const auto cabSub = makeCabIR(30.0, 130.0, 4.0, 2600.0, 4.0, 5200.0, 0.0, 4.5);
    const auto cabBright57 = makeCabIR(95.0, 140.0, 2.0, 3400.0, 6.0, 8000.0);
    const auto cabDark121 = makeCabIR(75.0, 180.0, 5.0, 2400.0, -2.5, 3200.0);

    auto loadFromVec = [&](const std::string& tag, const std::vector<float>& t) {
      const std::string p = std::string(dir) + "/" + tag + ".wav";
      writeWavF32(p, t, 48000);
      return NAMRig::WavIR::load(p.c_str(), 48000.0, 512);
    };

    auto irBase = loadFromVec("ir_base", cabBase);
    auto irFizzy = loadFromVec("ir_fizzy", cabFizzy);
    auto irSub = loadFromVec("ir_sub", cabSub);
    auto irBright = loadFromVec("ir_bright", cabBright57);
    auto irDark = loadFromVec("ir_dark", cabDark121);

    // 2 & 3. High-frequency fizz & sub-36 Hz rumble barely shift Loudness level.
    const double lBase = kWeightedGuitarRms(*irBase, 2);
    const double lFizzy = kWeightedGuitarRms(*irFizzy, 2);
    const double lSub = kWeightedGuitarRms(*irSub, 2);
    const double fizzDriftDb = std::fabs(20.0 * std::log10(lFizzy / lBase));
    const double subDriftDb = std::fabs(20.0 * std::log10(lSub / lBase));
    char msgFizz[160], msgSub[160];
    std::snprintf(msgFizz, sizeof(msgFizz),
                  "Loudness resists 12 kHz HF fizz bias (drift %.2f dB < 0.80 dB)", fizzDriftDb);
    std::snprintf(msgSub, sizeof(msgSub),
                  "Loudness resists 36 Hz sub-rumble bias (drift %.2f dB < 0.80 dB)", subDriftDb);
    CHECK(fizzDriftDb < 0.80, msgFizz);
    CHECK(subDriftDb < 0.80, msgSub);

    // 4. Bright SM57 vs Dark R121 cabs stay perceptually level-matched.
    const double lBright = kWeightedGuitarRms(*irBright, 2);
    const double lDark = kWeightedGuitarRms(*irDark, 2);
    const double brightDarkDb = std::fabs(20.0 * std::log10(lBright / lDark));
    char msgBD[160];
    std::snprintf(msgBD, sizeof(msgBD),
                  "Loudness matches bright vs dark cab IRs (delta %.2f dB < 1.00 dB)", brightDarkDb);
    CHECK(brightDarkDb < 1.00, msgBD);

    // 5. Log-spaced grid captures narrow Q=4 110 Hz resonance peak accurately in Peak mode.
    const double f0 = 110.0, q = 4.0, fsPeak = 48000.0;
    const double omega = 2.0 * pi * f0 / fsPeak;
    const double r = std::exp(-pi * (f0 / q) / fsPeak);
    std::vector<float> resTaps(4096, 0.0f);
    double y1 = 0.0, y2 = 0.0;
    for (size_t i = 0; i < resTaps.size(); ++i) {
      const double x = (i == 0) ? 1.0 : 0.0;
      const double y = x + 2.0 * r * std::cos(omega) * y1 - r * r * y2;
      y2 = y1;
      y1 = y;
      resTaps[i] = static_cast<float>(y);
    }
    const std::string resPath = std::string(dir) + "/ir_res110.wav";
    writeWavF32(resPath, resTaps, 48000);
    auto irRes = NAMRig::WavIR::load(resPath.c_str(), fsPeak, 512);
    const double exactPeakMag = magnitudeAt(resTaps, fsPeak, f0);
    std::vector<float> resImpulse(4096, 0.0f);
    resImpulse[0] = 1.0f;
    irRes->process(resImpulse.data(), 4096, 1);
    const double normPeakDb = std::fabs(20.0 * std::log10(magnitudeAt(resImpulse, fsPeak, f0)));
    (void)exactPeakMag;
    char msgRes[160];
    std::snprintf(msgRes, sizeof(msgRes),
                  "log grid captures Q=4 110 Hz resonance peak (err %.3f dB < 0.05 dB)", normPeakDb);
    CHECK(normPeakDb < 0.05, msgRes);
  }

  std::printf(g_fail ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n", g_fail);
  return g_fail ? 1 : 0;
}
