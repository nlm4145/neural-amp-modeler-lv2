#include "amp_advanced.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

static int failures = 0;
#define CHECK(c, m) do { if (c) std::printf("  PASS  %s\n", m); else { ++failures; std::printf("  FAIL  %s\n", m); } } while (0)

int main() {
  constexpr double rate = 96000.0;
  constexpr size_t count = 4096;
  std::vector<float> input(count), output(count);
  for (size_t i = 0; i < count; ++i)
    input[i] = 0.31f * std::sin(2.0 * 3.14159265358979323846 * 110.0 * i / rate)
             + 0.13f * std::sin(2.0 * 3.14159265358979323846 * 4200.0 * i / rate);

  NAMRig::AmpAdvanced amp;
  output = input;
  amp.processPreAmp(output.data(), output.size(), rate, 0.0f, 0.0f);
  amp.processPostAmp(output.data(), output.size(), rate,
                     0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f);
  CHECK(output == input, "neutral advanced controls are bit-transparent");

  amp.reset();
  output = input;
  amp.processPreAmp(output.data(), output.size(), rate, 100.0f, 100.0f);
  double delta = 0.0;
  for (size_t i = 0; i < count; ++i) delta += std::fabs(output[i] - input[i]);
  CHECK(delta > 1.0, "Bright and Input EQ alter the pre-amp signal");

  amp.reset();
  output = input;
  amp.processPostAmp(output.data(), output.size(), rate,
                     6.0f, 6.0f, 60.0f, 35.0f, 50.0f, 70.0f);
  bool finite = true;
  double postDelta = 0.0;
  for (size_t i = 0; i < count; ++i) {
    finite &= std::isfinite(output[i]);
    postDelta += std::fabs(output[i] - input[i]);
  }
  CHECK(finite, "advanced power-amp controls remain finite");
  CHECK(postDelta > 1.0, "advanced power-amp controls alter the post-amp signal");

  std::printf(failures ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n", failures);
  return failures ? 1 : 0;
}
