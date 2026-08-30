// Regression coverage for the shared TRUE-domain topology. Two consecutive
// linear stand-ins should see one UP/DOWN round trip, preserve their combined
// gain, and incur less converter startup loss than two split domains.
#include "oversample.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

using NAMRig::Down2x;
using NAMRig::Up2x;

int main() {
  constexpr size_t kFrames = 48000;
  constexpr size_t kBlock = 257;
  std::vector<float> input(kFrames);
  for (size_t i = 0; i < input.size(); ++i)
    input[i] = 0.6f * std::sin(2.0 * 3.14159265358979323846 * 997.0 * i / 48000.0);

  Up2x sharedUp;
  Down2x sharedDown;
  sharedUp.setMaxBlockSize(2 * kBlock);
  sharedDown.setMaxBlockSize(2 * kBlock);
  std::vector<float> upBuf(2 * kBlock + 128);
  std::vector<float> sharedOut(kFrames);
  size_t sharedCount = 0;
  for (size_t pos = 0; pos < kFrames;) {
    const size_t block = std::min(kBlock, kFrames - pos);
    size_t n = sharedUp.process(input.data() + pos, block, upBuf.data());
    for (size_t i = 0; i < n; ++i) {
      upBuf[i] *= 0.5f;  // pedal stand-in
      upBuf[i] *= 0.25f; // amp stand-in, still in the same domain
    }
    sharedCount += sharedDown.process(upBuf.data(), n,
                                      sharedOut.data() + sharedCount);
    pos += block;
  }

  Up2x splitUp1, splitUp2;
  Down2x splitDown1, splitDown2;
  splitUp1.setMaxBlockSize(2 * kBlock);
  splitDown1.setMaxBlockSize(2 * kBlock);
  splitUp2.setMaxBlockSize(2 * kBlock);
  splitDown2.setMaxBlockSize(2 * kBlock);
  std::vector<float> splitBase(kBlock + 128);
  std::vector<float> splitOut(kFrames);
  size_t splitCount = 0;
  for (size_t pos = 0; pos < kFrames;) {
    const size_t block = std::min(kBlock, kFrames - pos);
    size_t n = splitUp1.process(input.data() + pos, block, upBuf.data());
    for (size_t i = 0; i < n; ++i) upBuf[i] *= 0.5f;
    size_t baseN = splitDown1.process(upBuf.data(), n, splitBase.data());
    n = splitUp2.process(splitBase.data(), baseN, upBuf.data());
    for (size_t i = 0; i < n; ++i) upBuf[i] *= 0.25f;
    splitCount += splitDown2.process(upBuf.data(), n,
                                    splitOut.data() + splitCount);
    pos += block;
  }

  double worst = 0.0;
  for (size_t i = 2048; i < sharedCount; ++i)
    worst = std::max(worst, std::fabs((double)sharedOut[i] - 0.125 * input[i]));

  int failures = 0;
  if (worst >= 1e-3) {
    std::fprintf(stderr, "FAIL shared-domain linear gain (worst %.3e)\n", worst);
    ++failures;
  } else {
    std::printf("  PASS  shared domain preserves two-stage linear gain (worst %.3e)\n",
                worst);
  }
  if (sharedCount <= splitCount) {
    std::fprintf(stderr,
                 "FAIL shared domain did not reduce startup loss (%zu vs %zu)\n",
                 sharedCount, splitCount);
    ++failures;
  } else {
    std::printf("  PASS  one shared round trip emits more frames (%zu vs %zu)\n",
                sharedCount, splitCount);
  }
  return failures == 0 ? 0 : 1;
}
