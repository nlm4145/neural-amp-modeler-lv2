#include <algorithm>
#include <cmath>
#include <cstdio>

int main() {
  constexpr int n = 480;
  constexpr double pi = 3.14159265358979323846;
  double previousOut = 2.0;
  double previousIn = -1.0;
  double worstPower = 0.0;
  int failures = 0;
  for (int i = 0; i <= n; ++i) {
    const double t = static_cast<double>(i) / n;
    const double out = std::cos(0.5 * pi * t);
    const double in = std::sin(0.5 * pi * t);
    if (out > previousOut + 1e-12 || in < previousIn - 1e-12) ++failures;
    previousOut = out;
    previousIn = in;
    worstPower = std::max(worstPower, std::fabs(out * out + in * in - 1.0));
  }
  if (std::fabs(previousIn - 1.0) > 1e-12 ||
      std::fabs(std::cos(0.5 * pi)) > 1e-12 || worstPower > 1e-12)
    ++failures;
  if (failures) {
    std::fprintf(stderr, "FAIL transition envelope (%d failures, power %.3e)\n",
                 failures, worstPower);
    return 1;
  }
  std::printf("  PASS  5 ms transition envelopes are monotonic and equal-power\n");
  return 0;
}
