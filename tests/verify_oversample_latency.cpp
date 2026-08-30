// Verifies the fixed pipeline delay of the True-Nx cascades (the values the
// plugin reports on the lv2:latency port): an impulse through the same
// up-chain -> down-chain path as Plugin::processTrueGroup must land exactly
// 23 / 35 / 41 base frames late for 2x / 4x / 8x, at every block size.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "oversample.h"

static int g_fail = 0;
#define CHECK(cond, msg)                                    \
  do {                                                      \
    if (cond) { std::printf("  PASS  %s\n", msg); }         \
    else { ++g_fail; std::printf("  FAIL  %s\n", msg); }    \
  } while (0)

static int measure(int levels, int block) {
  NAMRig::Up2x up[3];
  NAMRig::Down2x dn[3];
  for (int l = 0; l < 3; ++l) {
    up[l].setMaxBlockSize(8 * (size_t)block);
    dn[l].setMaxBlockSize(8 * (size_t)block);
    up[l].reset();
    dn[l].reset();
  }
  const int impulsePos = 10000, totalLen = 20000;
  std::vector<float> in(totalLen, 0.0f), out(totalLen, 0.0f);
  in[impulsePos] = 1.0f;
  std::vector<float> bufA(8 * block + 64), bufB(8 * block + 64);
  float* bufs[2] = {bufA.data(), bufB.data()};
  std::vector<float> chain(block);
  for (int off = 0; off < totalLen; off += block) {
    const int count = std::min(block, totalLen - off);
    std::memcpy(chain.data(), in.data() + off, count * sizeof(float));
    size_t n = up[0].process(chain.data(), count, bufs[0]);
    for (int c = 1; c < levels && n > 0; ++c)
      n = up[c].process(bufs[(c - 1) % 2], n, bufs[c % 2]);
    size_t back = n;
    const float* dnIn = bufs[(levels - 1) % 2];
    for (int c = levels; c-- > 0;) {
      float* dnOut = (c == 0) ? chain.data() : bufs[(c - 1) % 2];
      back = dn[c].process(dnIn, back, dnOut);
      dnIn = dnOut;
    }
    if ((int)back < count) {
      const float fill = back > 0 ? chain[back - 1] : chain[0];
      for (int i = (int)back; i < count; ++i) chain[i] = fill;
    }
    std::memcpy(out.data() + off, chain.data(), count * sizeof(float));
  }
  int best = 0;
  for (int i = 1; i < totalLen; ++i)
    if (std::fabs(out[i]) > std::fabs(out[best])) best = i;
  return best - impulsePos;
}

int main() {
  const int expected[3] = {23, 35, 41};  // == Plugin::cascadeLatencyFrames
  for (int levels = 1; levels <= 3; ++levels) {
    bool ok = true;
    int got = -1;
    for (int block : {512, 137, 64}) {
      got = measure(levels, block);
      if (got != expected[levels - 1]) ok = false;
    }
    char msg[96];
    std::snprintf(msg, sizeof(msg),
                  "True %dx delay == %d frames at all block sizes (got %d)",
                  1 << levels, expected[levels - 1], got);
    CHECK(ok, msg);
  }
  std::printf(g_fail ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n", g_fail);
  return g_fail ? 1 : 0;
}
