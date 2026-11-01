#include "master_output.h"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#define check(ok) do { if (!(ok)) { std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #ok); std::abort(); } } while (0)
int main() {
  for (double rate : {44100.0, 48000.0, 96000.0, 192000.0}) {
    NAMRig::MasterOutput fx;
    fx.initialize(rate);
    std::array<float, 1024> l{}, r{};
    for (size_t i = 0; i < l.size(); ++i) {
      l[i] = 4.0f * std::sin(static_cast<float>(i) * .17f);
      r[i] = -.37f * l[i];
    }
    l[0] = -0.0f;
    const auto originalL = l, originalR = r;
    auto exact = [&] {
      check(std::memcmp(l.data(), originalL.data(), sizeof(l)) == 0);
      check(std::memcmp(r.data(), originalR.data(), sizeof(r)) == 0);
    };
    check(fx.process(l.data(), r.data(), l.size(), 0, 0) == 0);
    exact(); // Includes signed zero and peaks well above full scale.
    for (float ceiling : {-24.0f, -6.0f, -1.0f, -.01f}) {
      l = originalL; r = originalR;
      check(fx.process(l.data(), r.data(), l.size(), ceiling, 0) > 0);
      const float limit = std::pow(10.0f, ceiling * .05f);
      for (size_t i = 0; i < l.size(); ++i) {
        check(std::fabs(l[i]) <= limit + 1e-6f);
        check(std::fabs(r[i]) <= limit + 1e-6f);
        check(std::fabs(r[i] + .37f * l[i]) < 1e-6f); // Stereo link.
      }
    }
    // Neutral must remove existing gain reduction and balance history immediately.
    fx.process(l.data(), r.data(), l.size(), -12, 70);
    l = originalL; r = originalR;
    check(fx.process(l.data(), r.data(), l.size(), 0, 0) == 0);
    exact();
    fx.initialize(rate);
    l.fill(.01f); r.fill(-.02f);
    const auto quietL = l, quietR = r;
    check(fx.process(l.data(), r.data(), l.size(), -1, 0) == 0);
    check(l == quietL && r == quietR); // Enabled below threshold stays unity.
    for (float balance : {-100.0f, 100.0f}) {
      fx.initialize(rate);
      for (int block = 0; block < 30; ++block) {
        l.fill(.25f); r.fill(-.5f);
        fx.process(l.data(), r.data(), l.size(), 0, balance);
      }
      check(balance < 0 ? l.back() == .25f && r.back() == 0 : r.back() == -.5f && l.back() == 0);
    }
    // Processing must not depend on host block size.
    NAMRig::MasterOutput whole, split;
    whole.initialize(rate); split.initialize(rate);
    l = originalL; r = originalR;
    auto sl = l, sr = r;
    whole.process(l.data(), r.data(), l.size(), -3, -35);
    for (size_t i = 0; i < l.size(); i += 16)
      split.process(sl.data() + i, sr.data() + i, 16, -3, -35);
    check(l == sl && r == sr);
  }
  std::puts("PASS master output: bit-exact neutral, return to neutral, linked ceilings, balance, block invariance at four rates");
}
