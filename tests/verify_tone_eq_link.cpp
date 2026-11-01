#include "tone_eq_link.h"
#include <cstdio>
#include <cstdlib>

using namespace NAMRig;
static void check(bool ok, const char* message) {
  if (!ok) { std::fprintf(stderr, "FAIL %s\n", message); std::exit(1); }
}
int main() {
  const auto flat = toneLeversFromKnobs({0, 0, 0});
  for (float gain : flat) check(gain == 0, "flat knobs map to flat levers");
  for (float gain : toneKnobsFromLevers(flat)) check(gain == 0, "flat levers map to flat knobs");
  const auto bass = toneLeversFromKnobs({6, 0, 0});
  const auto mid = toneLeversFromKnobs({0, -6, 0});
  const auto treble = toneLeversFromKnobs({0, 0, 6});
  check(bass[0] > 3 && bass[1] > 3 && std::abs(bass[6]) < 1, "bass edit moves low levers");
  check(mid[3] < -3 && std::abs(mid[0]) < 1, "mid edit moves mid lever");
  check(treble[5] > 3 && treble[6] > 3 && std::abs(treble[0]) < 1, "treble edit moves high levers");
  const ToneLeverGains scoop = {7, 5, -2, -9, -3, 5, 7};
  const auto coarse = toneKnobsFromLevers(scoop);
  check(coarse[0] > 0 && coarse[1] < -3 && coarse[2] > 0, "scooped levers yield scooped knob approximation");
  for (float value : {-12.f, 0.f, 12.f}) {
    const auto levers = toneLeversFromKnobs({value, -value, value});
    for (float gain : levers) check(std::isfinite(gain) && std::abs(gain) <= 18, "mapped levers stay bounded");
    for (float gain : toneKnobsFromLevers(levers)) check(std::isfinite(gain) && std::abs(gain) <= 12, "mapped knobs stay bounded");
  }
  std::puts("PASS tone EQ response projection: flat, bass/mid/treble, scoop, and bounds");
}
