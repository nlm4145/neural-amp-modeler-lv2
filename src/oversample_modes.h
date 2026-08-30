#pragma once

namespace NAMRig {

// LV2 port values are intentionally sparse: 2 and 3 remain reserved for
// legacy sessions that exposed "Legacy 4x/8x".  The current five-item UI
// therefore must not send its raw menu index.
static constexpr int kOversampleNone = 0;
static constexpr int kOversampleLegacy = 1;
static constexpr int kOversampleTrue2 = 4;
static constexpr int kOversampleTrue4 = 5;
static constexpr int kOversampleTrue8 = 6;

constexpr int oversampleModeFromMenuIndex(int index) {
  return index <= 0 ? kOversampleNone
       : index == 1 ? kOversampleLegacy
       : index == 2 ? kOversampleTrue2
       : index == 3 ? kOversampleTrue4
                    : kOversampleTrue8;
}

constexpr int oversampleMenuIndexFromMode(int mode) {
  return mode <= kOversampleNone ? 0
       : mode < kOversampleTrue2 ? 1
       : mode == kOversampleTrue2 ? 2
       : mode == kOversampleTrue4 ? 3
                                  : 4;
}

} // namespace NAMRig
