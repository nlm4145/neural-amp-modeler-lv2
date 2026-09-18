#include "oversample_modes.h"

#include <cstdio>

int main() {
  constexpr int expectedModes[] = {0, 4, 5, 6};
  int failures = 0;
  for (int index = 0; index < 4; ++index) {
    const int mode = NAMRig::oversampleModeFromMenuIndex(index);
    const int roundTrip = NAMRig::oversampleMenuIndexFromMode(mode);
    if (mode != expectedModes[index] || roundTrip != index) {
      std::fprintf(stderr,
                   "FAIL menu index %d -> mode %d -> index %d (expected mode %d)\n",
                   index, mode, roundTrip, expectedModes[index]);
      ++failures;
    }
  }
  // Old sessions may still provide the retired Legacy (1) or Legacy 4x/8x (2, 3) values.
  // All must display as True 2x (menu index 1).
  if (NAMRig::oversampleMenuIndexFromMode(1) != 1 ||
      NAMRig::oversampleMenuIndexFromMode(2) != 1 ||
      NAMRig::oversampleMenuIndexFromMode(3) != 1) {
    std::fputs("FAIL retired legacy values did not map to True 2x\n", stderr);
    ++failures;
  }
  if (failures == 0)
    std::puts("  PASS  sparse oversample menu/port mapping");
  return failures == 0 ? 0 : 1;
}
