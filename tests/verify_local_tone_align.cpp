#include "local_tone_align.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <random>
#include <vector>

using namespace NAMRig::LocalTone;

int main() {
  const double rate = 48000.0;
  const size_t frames = static_cast<size_t>(rate * 2.0); // 2 seconds

  // Synthesize a pulsed riff with 4 distinct note events
  std::vector<float> base(frames, 0.0f);
  for (int note = 0; note < 4; ++note) {
    const size_t start = static_cast<size_t>((0.2 + note * 0.4) * rate);
    const double freq = 220.0 * (1.0 + note * 0.25);
    for (size_t i = 0; i < static_cast<size_t>(0.25 * rate); ++i) {
      const double t = i / rate;
      const double env = std::exp(-8.0 * t);
      base[start + i] = static_cast<float>(0.3 * env * std::sin(2.0 * M_PI * freq * t));
    }
  }

  // 1. Time-shifted candidate (+40 ms = 1920 samples) with slight timing jitter
  const int shiftSamples = static_cast<int>(0.040 * rate);
  std::vector<float> candidate(frames, 0.0f);
  for (int note = 0; note < 4; ++note) {
    // Add ±5 ms jitter per note
    const int jitter = (note % 2 == 0 ? 1 : -1) * static_cast<int>(0.005 * rate);
    const size_t start = static_cast<size_t>((0.2 + note * 0.4) * rate + shiftSamples + jitter);
    const double freq = 220.0 * (1.0 + note * 0.25);
    for (size_t i = 0; i < static_cast<size_t>(0.25 * rate) && (start + i) < frames; ++i) {
      const double t = i / rate;
      const double env = std::exp(-8.0 * t);
      candidate[start + i] = static_cast<float>(0.25 * env * std::sin(2.0 * M_PI * freq * t));
    }
  }

  // Test alignment between candidate and base
  AlignmentResult res = alignAudio(candidate.data(), candidate.size(), 1,
                                   base.data(), base.size(), 1, rate);

  std::printf("Aligned candidate: confident=%d, confidence=%.3f, offsetSamples=%lld (expected ~%d), dist=%.2f dB\n",
              res.confident, res.confidence, (long long)res.coarseOffsetFrames, shiftSamples, res.alignedDistance);

  assert(res.confident);
  assert(res.confidence >= 0.5);
  // Coarse offset within 20 ms tolerance
  assert(std::abs(res.coarseOffsetFrames - shiftSamples) <= static_cast<int64_t>(0.020 * rate));

  // 2. Uncorrelated signal: random white noise
  std::mt19937 rng(42);
  std::uniform_real_distribution<float> dist(-0.1f, 0.1f);
  std::vector<float> noise(frames);
  for (float& s : noise) s = dist(rng);

  AlignmentResult noiseRes = alignAudio(noise.data(), noise.size(), 1,
                                        base.data(), base.size(), 1, rate);

  std::printf("Uncorrelated noise: confident=%d, confidence=%.3f\n",
              noiseRes.confident, noiseRes.confidence);
  assert(!noiseRes.confident || noiseRes.confidence < 0.5);

  // 3. Stereo candidate (2 channels) vs mono target
  std::vector<float> stereoCandidate(frames * 2, 0.0f);
  for (size_t i = 0; i < frames; ++i) {
    stereoCandidate[i * 2] = candidate[i];
    stereoCandidate[i * 2 + 1] = candidate[i] * 0.9f;
  }

  AlignmentResult stereoRes = alignAudio(stereoCandidate.data(), frames, 2,
                                         base.data(), base.size(), 1, rate);
  assert(stereoRes.confident);
  assert(stereoRes.confidence >= 0.5);

  // 4. Blended score function
  const double statScore = 2.0;
  const double blended = res.blendedScore(statScore);
  assert(blended == 0.5 * statScore + 0.5 * res.alignedDistance);

  std::puts("PASS verify_local_tone_align");
  return 0;
}
