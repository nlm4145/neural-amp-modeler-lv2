// Offline A/B benchmark for the NeuralAudio model DSP + True-Nx converters.
//
// Loads real .nam files the same way the rig plugin does (external sample
// rate = domain rate, full quality tier, worst-case buffer sizing) and times:
//   1. model->Process() alone at each domain rate (96k x factor)
//   2. the Up2x/Down2x converter cascade alone
// so the MULTIFRAME_8X8_CONVOLUTION effect can be separated from the
// sample-count multiplier and the converter cost.
//
// Build (from repo root):
//   cmake -S . -B /tmp/bench-mf4 -DCMAKE_BUILD_TYPE=Release
//   cmake --build /tmp/bench-mf4 --target nam_bench -j$(sysctl -n hw.ncpu)
//   cmake -S . -B /tmp/bench-mf0 -DCMAKE_BUILD_TYPE=Release -DNAM_MULTIFRAME_FORCE=0
//   cmake --build /tmp/bench-mf0 --target nam_bench -j$(sysctl -n hw.ncpu)
//
// Usage:
//   ./nam_bench [--base 96000] [--seconds 2] [--block 512]
//               [--factors 1,2,4,8] model1.nam [model2.nam ...]
//
// The checksum/rms/peak columns let you verify the two binaries produce
// (near-)identical audio: any speed difference must not change the sound.

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <NeuralAudio/NeuralModel.h>

#include "oversample.h"

namespace {

#if defined(MULTIFRAME_8X8_CONVOLUTION)
constexpr int kMultiframe = MULTIFRAME_8X8_CONVOLUTION;
#else
constexpr int kMultiframe = -1;  // macro not defined at all
#endif

const char* loadModeName(NeuralAudio::EModelLoadMode m) {
  using namespace NeuralAudio;
  switch (m) {
    case EModelLoadMode::Internal: return "Internal";
    case EModelLoadMode::RTNeural: return "RTNeural";
    case EModelLoadMode::NAMCore: return "NAMCore";
  }
  return "?";
}

double nowSeconds() {
  using clock = std::chrono::steady_clock;
  return std::chrono::duration<double>(clock::now().time_since_epoch()).count();
}

// Deterministic guitar-ish test signal at the given rate.
void makeSignal(std::vector<float>& out, double rate) {
  uint32_t rng = 0x12345678u;
  auto noise = [&]() {
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return (rng * (1.0f / 4294967296.0f)) * 2.0f - 1.0f;
  };
  const double kPi = 3.14159265358979323846;
  for (size_t i = 0; i < out.size(); ++i) {
    const double t = (double)i / rate;
    float x = 0.25f * std::sin(2.0 * kPi * 110.0 * t) +
              0.12f * std::sin(2.0 * kPi * 440.0 * t) +
              0.06f * std::sin(2.0 * kPi * 3700.0 * t) + 0.03f * noise();
    // Occasional hot palm-mute-ish burst to exercise saturation paths.
    if ((i / (size_t)rate) % 2 == 1) x *= 2.5f;
    out[i] = x;
  }
}

struct Digest {
  double sum = 0.0, sumSq = 0.0, peak = 0.0;
  uint64_t fnv = 1469598103934665603ull;
  void add(const float* p, size_t n) {
    for (size_t i = 0; i < n; ++i) {
      const float v = p[i];
      sum += v;
      sumSq += (double)v * v;
      const float a = std::fabs(v);
      if (a > peak) peak = (double)a;
      uint32_t bits;
      std::memcpy(&bits, &v, sizeof(bits));
      fnv ^= bits;
      fnv *= 1099511628211ull;
    }
  }
};

std::vector<int> parseFactors(const char* s) {
  std::vector<int> out;
  std::string cur;
  for (const char* p = s; *p; ++p) {
    if (*p == ',') {
      if (!cur.empty()) out.push_back(std::stoi(cur));
      cur.clear();
    } else {
      cur += *p;
    }
  }
  if (!cur.empty()) out.push_back(std::stoi(cur));
  if (out.empty()) out = {1, 2, 4, 8};
  return out;
}

}  // namespace

int main(int argc, char** argv) {
  double baseRate = 96000.0;
  double seconds = 2.0;
  size_t block = 512;
  std::vector<int> factors = {1, 2, 4, 8};
  std::vector<std::string> models;

  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--base") && i + 1 < argc)
      baseRate = std::stod(argv[++i]);
    else if (!std::strcmp(argv[i], "--seconds") && i + 1 < argc)
      seconds = std::stod(argv[++i]);
    else if (!std::strcmp(argv[i], "--block") && i + 1 < argc)
      block = (size_t)std::stoul(argv[++i]);
    else if (!std::strcmp(argv[i], "--factors") && i + 1 < argc)
      factors = parseFactors(argv[++i]);
    else
      models.emplace_back(argv[i]);
  }
  if (models.empty()) {
    std::printf("usage: nam_bench [--base 96000] [--seconds 2] [--block 512]\n"
                "                 [--factors 1,2,4,8] model1.nam [model2.nam ...]\n");
    return 1;
  }

  std::printf("MULTIFRAME_8X8_CONVOLUTION=%d  base=%.0fHz block=%zu seconds=%.1f\n",
              kMultiframe, baseRate, block, seconds);

  for (const auto& path : models) {
    std::printf("\n== %s\n", path.c_str());
    std::printf("%-6s %-9s %-11s %-11s %-11s %-11s %-7s %-10s %-8s %s\n",
                "factor", "domainHz", "model_ms/s", "up_ms/s",
                "down_ms/s", "total_ms/s", "core%", "rms", "peak",
                "checksum");
    for (int f : factors) {
      const double domainRate = baseRate * f;
      const size_t levels = f == 8 ? 3 : (f == 4 ? 2 : 1);
      const size_t domBlock = block * (size_t)f;
      const size_t domTotal = (size_t)(domainRate * seconds);
      const size_t baseTotal = (size_t)(baseRate * seconds);

      // ---- load exactly like the plugin's worker thread ----
      NeuralAudio::NeuralModelLoader loader;
      loader.SetExternalSampleRate((int)std::lround(domainRate));
      loader.SetDefaultMaxAudioBufferSize((int)block);
      loader.SetDefaultQualityScaleFactor(1.0f);
      NeuralAudio::NeuralModel* model = nullptr;
      try {
        model = loader.CreateFromFile(path, /*doPrewarm=*/true);
      } catch (const std::exception& e) {
        std::printf("%-6d load threw: %s\n", f, e.what());
        continue;
      }
      if (!model) {
        std::printf("%-6d LOAD FAILED\n", f);
        continue;
      }
      model->SetMaxAudioBufferSize(8 * (int)block);
      model->SetQualityScaleFactor(1.0f);

      const char* mode = loadModeName(model->GetLoadMode());

      // ---- signals ----
      std::vector<float> domIn(domTotal), domWork(domTotal);
      makeSignal(domIn, domainRate);
      std::vector<float> baseIn(baseTotal);
      makeSignal(baseIn, baseRate);

      // ---- time model (chunked like InternalModelT / plugin slices) ----
      std::vector<float> chunk(domBlock);
      // warmup pass
      for (size_t off = 0; off < domTotal; off += domBlock) {
        const size_t n = std::min(domBlock, domTotal - off);
        std::memcpy(chunk.data(), domIn.data() + off, n * sizeof(float));
        model->Process(chunk.data(), chunk.data(), n);
      }
      Digest digest;
      const double t0 = nowSeconds();
      for (size_t off = 0; off < domTotal; off += domBlock) {
        const size_t n = std::min(domBlock, domTotal - off);
        std::memcpy(chunk.data(), domIn.data() + off, n * sizeof(float));
        model->Process(chunk.data(), chunk.data(), n);
        std::memcpy(domWork.data() + off, chunk.data(), n * sizeof(float));
        digest.add(chunk.data(), n);
      }
      const double modelSec = nowSeconds() - t0;
      const double rms =
          std::sqrt(digest.sumSq / (double)std::max<size_t>(1, domTotal));

      // ---- time converters over the base-rate stream ----
      NAMRig::Up2x ups[3];
      NAMRig::Down2x downs[3];
      for (int l = 0; l < 3; ++l) {
        ups[l].setMaxBlockSize(8 * block);
        downs[l].setMaxBlockSize(8 * block);
        ups[l].reset();
        downs[l].reset();
      }
      std::vector<float> upA(8 * block + 64), upB(8 * block + 64);
      std::vector<float> dnA(8 * block + 64), dnB(8 * block + 64);
      double upSec = 0.0, downSec = 0.0;
      if (f > 1) {
        // warmup
        for (size_t off = 0; off < baseTotal; off += block) {
          const size_t n = std::min(block, baseTotal - off);
          float* bufs[2] = {upA.data(), upB.data()};
          size_t m = ups[0].process(baseIn.data() + off, n, bufs[0]);
          for (size_t c = 1; c < levels && m > 0; ++c)
            m = ups[c].process(bufs[(c - 1) % 2], m, bufs[c % 2]);
        }
        for (auto& u : ups) u.reset();
        const double t1 = nowSeconds();
        for (size_t off = 0; off < baseTotal; off += block) {
          const size_t n = std::min(block, baseTotal - off);
          float* bufs[2] = {upA.data(), upB.data()};
          size_t m = ups[0].process(baseIn.data() + off, n, bufs[0]);
          for (size_t c = 1; c < levels && m > 0; ++c)
            m = ups[c].process(bufs[(c - 1) % 2], m, bufs[c % 2]);
        }
        upSec = nowSeconds() - t1;

        // feed domain-rate data down: reuse domIn as the Nx stream
        for (auto& d : downs) d.reset();
        for (size_t off = 0; off < domTotal; off += domBlock) {
          const size_t n = std::min(domBlock, domTotal - off);
          float* bufs[2] = {dnA.data(), dnB.data()};
          // walk the cascade top-down into alternating buffers
          const float* in = domIn.data() + off;
          size_t m = n;
          float* tmp[2] = {bufs[0], bufs[1]};
          // emulate processTrueGroup: down from highest level
          const float* dnIn = in;
          for (size_t c = levels; c-- > 0;) {
            float* dnOut = (c == 0) ? tmp[0] : tmp[(c - 1) % 2];
            // NOTE: downs[c] expects the full Nx stream only at the top
            // level; intermediate levels get the previous output.
            m = downs[c].process(c == levels - 1 ? in : dnIn, m, dnOut);
            dnIn = dnOut;
            in = nullptr;
          }
        }
        for (auto& d : downs) d.reset();
        const double t2 = nowSeconds();
        for (size_t off = 0; off < domTotal; off += domBlock) {
          const size_t n = std::min(domBlock, domTotal - off);
          float* bufs[2] = {dnA.data(), dnB.data()};
          const float* in = domIn.data() + off;
          size_t m = n;
          const float* dnIn = in;
          for (size_t c = levels; c-- > 0;) {
            float* dnOut = (c == 0) ? bufs[0] : bufs[(c - 1) % 2];
            m = downs[c].process(c == levels - 1 ? in : dnIn, m, dnOut);
            dnIn = dnOut;
            in = nullptr;
          }
        }
        downSec = nowSeconds() - t2;
      }

      const double modelMs = 1000.0 * modelSec / seconds;
      const double upMs = 1000.0 * upSec / seconds;
      const double downMs = 1000.0 * downSec / seconds;
      const double totalMs = modelMs + upMs + downMs;
      std::printf("%-6d %-9.0f %-11.1f %-11.2f %-11.2f %-11.1f %-7.1f %-10.4f %-8.3f %016llx  [%s]\n",
                  f, domainRate, modelMs, upMs, downMs, totalMs,
                  totalMs / 10.0, rms, digest.peak,
                  (unsigned long long)digest.fnv, mode);
      delete model;
    }
  }
  return 0;
}
