// Verifies NeuralAudio's polyphase oversampling (PolyphaseModel) and the NEON
// 8-channel WaveNet layer kernels on real .nam files.
//
//   A. Bookkeeping: a polyphase model at F x the native rate must equal, bit for
//      bit, F native-rate models each run on its own phase (samples p, p+F, ...),
//      under irregular block sizes, in place, and with chunking forced by a
//      scratch smaller than the block.
//   B. Equivalence: it must match NeuralAudio's legacy dilation-scaling path
//      (loader.SetPolyphaseOversampling(false)) to float-rounding tolerance.
//      This is the claim the whole optimization rests on: a WaveNet with every
//      dilation scaled by F is F independent native-rate copies.
//   C. Eligibility: models whose scaled form is not phase-separable (condition
//      DSP), LSTMs, native-rate loads and non-integer ratios are not wrapped.
//
// Build: cmake --build <dir> --target verify_polyphase_model
// Usage: verify_polyphase_model [extra.nam ...]   (extra models get A + B)

#include <NeuralAudio/NeuralModel.h>
#include <NeuralAudio/PolyphaseModel.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#ifndef NAM_REPO_DIR
#define NAM_REPO_DIR "."
#endif

namespace {

using NeuralAudio::NeuralModel;
using NeuralAudio::NeuralModelLoader;
using NeuralAudio::PolyphaseModel;

int failures = 0;

void check(bool ok, const std::string& what) {
  std::printf("  %s  %s\n", ok ? "PASS" : "FAIL", what.c_str());
  if (!ok) ++failures;
}

constexpr int kNativeRate = 48000;
constexpr int kMaxBlock = 4096;

std::unique_ptr<NeuralModel> load(const std::string& path, int externalRate,
                                  bool polyphase, int maxBlock = kMaxBlock,
                                  float quality = 1.0f) {
  NeuralModelLoader loader;
  loader.SetExternalSampleRate(externalRate);
  loader.SetDefaultMaxAudioBufferSize(maxBlock);
  loader.SetDefaultQualityScaleFactor(quality);
  loader.SetPolyphaseOversampling(polyphase);
  std::unique_ptr<NeuralModel> model(loader.CreateFromFile(path, true));
  if (model) {
    model->SetMaxAudioBufferSize(maxBlock);  // mirrors the rig plugin
    model->SetQualityScaleFactor(quality);
  }
  return model;
}

std::vector<float> makeSignal(size_t n) {
  std::vector<float> x(n);
  uint32_t rng = 0x9e3779b9u;
  for (size_t i = 0; i < n; ++i) {
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    const float noise = (rng * (1.0f / 4294967296.0f)) * 2.0f - 1.0f;
    const double t = (double)i / 48000.0;
    float v = 0.3f * (float)std::sin(2.0 * 3.14159265358979 * 82.4 * t) +
              0.1f * (float)std::sin(2.0 * 3.14159265358979 * 1234.5 * t) +
              0.05f * noise;
    if ((i / 9000) % 2) v *= 3.0f;  // drive the nonlinearity harder
    x[i] = v;
  }
  return x;
}

// Irregular block sizes, including 1, odd/prime lengths, and > WaveNet's
// internal 64-frame chunk.
const size_t kBlocks[] = {1, 7, 64, 513, 3, 1000, 2, 4096, 255, 31, 65, 1};

std::vector<float> runBlocks(NeuralModel& model, const std::vector<float>& in,
                             bool inPlace) {
  std::vector<float> out(in.size());
  std::vector<float> work(kMaxBlock);
  size_t pos = 0, b = 0;
  while (pos < in.size()) {
    const size_t n = std::min(kBlocks[b++ % (sizeof(kBlocks) / sizeof(kBlocks[0]))],
                              in.size() - pos);
    if (inPlace) {
      std::copy(in.begin() + pos, in.begin() + pos + n, work.begin());
      model.Process(work.data(), work.data(), n);
      std::copy(work.begin(), work.begin() + n, out.begin() + pos);
    } else {
      std::vector<float> src(in.begin() + pos, in.begin() + pos + n);
      model.Process(src.data(), out.data() + pos, n);
    }
    pos += n;
  }
  return out;
}

struct Diff {
  double maxAbs = 0.0, rmsErr = 0.0, rmsRef = 0.0;
};

Diff compare(const std::vector<float>& a, const std::vector<float>& ref) {
  Diff d;
  double se = 0.0, sr = 0.0;
  for (size_t i = 0; i < a.size(); ++i) {
    const double e = (double)a[i] - (double)ref[i];
    d.maxAbs = std::max(d.maxAbs, std::fabs(e));
    se += e * e;
    sr += (double)ref[i] * ref[i];
  }
  d.rmsErr = std::sqrt(se / (double)a.size());
  d.rmsRef = std::sqrt(sr / (double)a.size());
  return d;
}

bool finite(const std::vector<float>& v) {
  for (float x : v)
    if (!std::isfinite(x)) return false;
  return true;
}

std::string name(const std::string& path) {
  return path.substr(path.find_last_of('/') + 1);
}

// A: polyphase output == F native models on deinterleaved phases, bit-exact.
void testBookkeeping(const std::string& path, int factor, size_t frames) {
  const auto x = makeSignal(frames);

  auto poly = load(path, kNativeRate * factor, true);
  if (!poly) {
    check(false, name(path) + " F=" + std::to_string(factor) + ": load");
    return;
  }

  std::vector<float> ref(frames);
  for (int p = 0; p < factor; ++p) {
    auto phase = load(path, kNativeRate, true);
    std::vector<float> sub;
    for (size_t i = (size_t)p; i < frames; i += (size_t)factor) sub.push_back(x[i]);
    for (size_t off = 0; off < sub.size(); off += 100) {
      const size_t n = std::min<size_t>(100, sub.size() - off);
      phase->Process(sub.data() + off, sub.data() + off, n);
    }
    for (size_t i = (size_t)p, j = 0; i < frames; i += (size_t)factor, ++j) ref[i] = sub[j];
  }

  // Some backends (Eigen GEMM for 16-channel layers, the dynamic WaveNet,
  // NAM Core) round differently depending on the block size they are handed.
  // Measure that on a native model: when the backend is block-size invariant,
  // the polyphase result must be bit-exact; otherwise it may differ by no more
  // than the backend's own block-size jitter allows.
  double jitter = 0.0;
  {
    auto a = load(path, kNativeRate, true), b = load(path, kNativeRate, true);
    std::vector<float> ya(x.begin(), x.begin() + frames / (size_t)factor);
    const auto yb = runBlocks(*b, ya, true);
    for (size_t off = 0; off < ya.size(); off += 100)
      a->Process(ya.data() + off, ya.data() + off, std::min<size_t>(100, ya.size() - off));
    jitter = compare(ya, yb).maxAbs;
  }
  const double tolerance = jitter == 0.0 ? 0.0 : 1e-5;
  const std::string label = name(path) + " F=" + std::to_string(factor) + ": ";
  char buf[64];
  std::snprintf(buf, sizeof buf, "%.3g", jitter);
  const std::string bound = jitter == 0.0 ? " (backend block-invariant: exact)"
                                          : std::string(" (backend block jitter ") + buf + ")";

  const auto inPlace = runBlocks(*poly, x, true);
  const Diff d = compare(inPlace, ref);
  std::snprintf(buf, sizeof buf, "%.3g", d.maxAbs);
  check(d.maxAbs <= tolerance && finite(inPlace),
        label + "== per-phase native models (in place, irregular blocks), max diff " + buf + bound);

  // Separate in/out buffers, and a scratch far smaller than the blocks so
  // Process() must chunk internally (phase alignment must carry across chunks).
  auto small = load(path, kNativeRate * factor, true, 37);
  const auto chunked = runBlocks(*small, x, false);
  const Diff dc = compare(chunked, ref);
  std::snprintf(buf, sizeof buf, "%.3g", dc.maxAbs);
  check(dc.maxAbs <= tolerance,
        label + "== reference with internal chunking (scratch 37), max diff " + buf + bound);
}

// B: polyphase == legacy dilation scaling, to rounding tolerance.
void testEquivalence(const std::string& path, int factor, size_t frames,
                     float quality = 1.0f) {
  const auto x = makeSignal(frames);
  auto poly = load(path, kNativeRate * factor, true, kMaxBlock, quality);
  auto legacy = load(path, kNativeRate * factor, false, kMaxBlock, quality);
  const std::string label = name(path) + " F=" + std::to_string(factor) +
                            (quality != 1.0f ? " q=" + std::to_string(quality) : "");
  if (!poly || !legacy) {
    check(false, label + ": load");
    return;
  }

  const auto a = runBlocks(*poly, x, true);
  const auto b = runBlocks(*legacy, x, true);
  const Diff d = compare(a, b);
  char buf[160];
  std::snprintf(buf, sizeof buf,
                ": == legacy dilation scaling, max diff %.3g, rms err %.3g (%.1f dB below signal)",
                d.maxAbs, d.rmsErr,
                d.rmsErr > 0 ? 20.0 * std::log10(d.rmsRef / d.rmsErr) : 999.0);
  check(finite(a) && d.rmsRef > 1e-3 && d.maxAbs < 2e-4, label + buf);

  check(poly->GetSampleRate() == legacy->GetSampleRate() &&
            poly->GetRecommendedInputDBAdjustment() ==
                legacy->GetRecommendedInputDBAdjustment() &&
            poly->GetRecommendedOutputDBAdjustment() ==
                legacy->GetRecommendedOutputDBAdjustment(),
        label + ": sample rate and level metadata match legacy");
}

bool isPolyphase(NeuralModel* m) { return dynamic_cast<PolyphaseModel*>(m) != nullptr; }

}  // namespace

int main(int argc, char** argv) {
  const std::string nam = std::string(NAM_REPO_DIR) + "/deps/NeuralAudio/Utils/Models/";
  const std::string core =
      std::string(NAM_REPO_DIR) + "/deps/NeuralAudio/deps/NeuralAmpModelerCore/example_models/";

  std::vector<std::string> wavenets = {
      nam + "BossWN-a2.nam",          // SlimmableContainer of A2 (3 / 8 channels)
      nam + "BossWN-standard.nam",    // static standard WaveNet (16 + 8 ch, tanh)
      nam + "BossWN-feather.nam",     // static lite WaveNet
      nam + "BossWN-nano.nam",
      core + "wavenet.nam",           // custom: dynamic WaveNet
      core + "slimmable_wavenet.nam", // NAM Core (slimmable layers)
      core + "slimmable_container.nam",  // LSTM + WaveNet submodels
  };
  for (int i = 1; i < argc; ++i) wavenets.emplace_back(argv[i]);

  std::printf("== A. polyphase bookkeeping\n");
  for (const auto& path : wavenets)
    for (int f : {2, 3, 16}) testBookkeeping(path, f, 24000 * (size_t)f);

  std::printf("== B. equivalence to legacy dilation scaling\n");
  for (const auto& path : wavenets)
    for (int f : {2, 4, 8, 16}) testEquivalence(path, f, 16000 * (size_t)f);
  testEquivalence(nam + "BossWN-a2.nam", 8, 128000, 0.5f);  // 3-channel A2 tier

  std::printf("== C. eligibility\n");
  {
    auto m = load(core + "wavenet_condition_dsp.nam", kNativeRate * 4, true);
    check(m && !isPolyphase(m.get()), "condition_dsp WaveNet keeps dilation scaling");
  }
  {
    auto m = load(core + "wavenet_a2_max.nam", kNativeRate * 4, true);
    check(m && !isPolyphase(m.get()), "A2-max (condition_dsp) keeps dilation scaling");
  }
  {
    auto m = load(nam + "BossLSTM-1x16.nam", kNativeRate * 4, true);
    check(m && !isPolyphase(m.get()), "LSTM is not wrapped");
  }
  {
    auto m = load(nam + "BossWN-standard.nam", kNativeRate, true);
    check(m && !isPolyphase(m.get()), "native rate is not wrapped");
  }
  {
    auto m = load(nam + "BossWN-standard.nam", 44100 * 8, true);
    check(m && !isPolyphase(m.get()), "non-integer rate ratio is not wrapped");
  }
  {
    auto m = load(nam + "BossWN-standard.nam", kNativeRate * 8, true);
    auto* p = dynamic_cast<PolyphaseModel*>(m.get());
    check(p && p->GetNumPhases() == 8 && p->IsStatic(),
          "8x standard WaveNet -> 8 static native-rate phases");
  }
  {
    auto m = load(nam + "BossWN-standard.nam", kNativeRate * 8, false);
    check(m && !isPolyphase(m.get()), "SetPolyphaseOversampling(false) disables it");
  }

  std::printf("%s (%d failure%s)\n", failures ? "FAILED" : "ALL PASSED", failures,
              failures == 1 ? "" : "s");
  return failures ? 1 : 0;
}
