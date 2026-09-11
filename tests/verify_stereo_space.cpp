#include "stereo_space.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

static int failures = 0;
#define CHECK(c, m) do { if (c) std::printf("  PASS  %s\n", m); else { ++failures; std::printf("  FAIL  %s\n", m); } } while (0)

static std::vector<float> signal(size_t n, double rate) {
  std::vector<float> x(n);
  for (size_t i = 0; i < n; ++i)
    x[i] = 0.25f * std::sin(2.0 * 3.141592653589793 * 317.0 * i / rate);
  return x;
}

int main() {
  constexpr double rate = 48000.0;
  const auto input = signal(24000, rate);

  {
    NAMRig::StereoSpace fx;
    fx.initialize(rate);
    auto left = input, right = input;
    fx.process(left.data(), right.data(), left.size(), 0.0f, 0.0f);
    CHECK(left == input && right == input, "Width 0 / Room 0 is bit-transparent dual mono");
  }

  {
    NAMRig::StereoSpace fx;
    fx.initialize(rate);
    auto left = input, right = input;
    fx.process(left.data(), right.data(), left.size(), 100.0f, 0.0f);
    float difference = 0.0f;
    for (size_t i = 2000; i < left.size(); ++i)
      difference = std::max(difference, std::fabs(left[i] - right[i]));
    CHECK(difference > 0.05f, "Width creates an audible left/right timing difference");
  }

  {
    NAMRig::StereoSpace one;
    one.initialize(rate);
    auto leftOne = input, rightOne = input;
    one.process(leftOne.data(), rightOne.data(), leftOne.size(), 62.0f, 48.0f);

    NAMRig::StereoSpace split;
    split.initialize(rate);
    auto leftSplit = input, rightSplit = input;
    const size_t blocks[] = {1, 17, 64, 511, 128, 3, 997};
    size_t offset = 0, block = 0;
    while (offset < input.size()) {
      const size_t n = std::min(blocks[block++ % 7], input.size() - offset);
      split.process(leftSplit.data() + offset, rightSplit.data() + offset,
                    n, 62.0f, 48.0f);
      offset += n;
    }
    float worst = 0.0f;
    for (size_t i = 0; i < input.size(); ++i) {
      worst = std::max(worst, std::fabs(leftOne[i] - leftSplit[i]));
      worst = std::max(worst, std::fabs(rightOne[i] - rightSplit[i]));
    }
    CHECK(worst < 1.0e-7f, "stereo delay and room are invariant to host block boundaries");
  }

  {
    NAMRig::StereoSpace fx;
    fx.initialize(rate);
    auto left = input, right = input;
    fx.process(left.data(), right.data(), left.size(), 100.0f, 100.0f);
    bool finite = true;
    float roomDifference = 0.0f;
    for (size_t i = 3000; i < left.size(); ++i) {
      finite = finite && std::isfinite(left[i]) && std::isfinite(right[i]);
      roomDifference = std::max(roomDifference, std::fabs(left[i] - right[i]));
    }
    CHECK(finite, "maximum Width and Room remain finite");
    CHECK(roomDifference > 0.05f, "Room uses decorrelated early reflections across channels");
  }

  std::printf(failures ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n", failures);
  return failures ? 1 : 0;
}
