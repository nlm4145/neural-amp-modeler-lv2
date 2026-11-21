#pragma once

namespace NAMRig {

// LV2 port values are intentionally sparse: 2 and 3 remain reserved for
// legacy sessions that exposed "Legacy 4x/8x".  The current UI therefore
// must not send its raw menu index.  True 16x was appended as 7, True 32x as 8.
static constexpr int kOversampleNone = 0;
static constexpr int kOversampleLegacy = 1;
static constexpr int kOversampleTrue2 = 4;
static constexpr int kOversampleTrue4 = 5;
static constexpr int kOversampleTrue8 = 6;
static constexpr int kOversampleTrue16 = 7;
static constexpr int kOversampleTrue32 = 8;

constexpr int oversampleModeFromMenuIndex(int index) {
  return index <= 0 ? kOversampleNone
       : index == 1 ? kOversampleTrue2
       : index == 2 ? kOversampleTrue4
       : index == 3 ? kOversampleTrue8
       : index == 4 ? kOversampleTrue16
                    : kOversampleTrue32;
}

constexpr int oversampleMenuIndexFromMode(int mode) {
  return mode <= kOversampleNone ? 0
       : mode < kOversampleTrue4 ? 1
       : mode == kOversampleTrue4 ? 2
       : mode == kOversampleTrue8 ? 3
       : mode == kOversampleTrue16 ? 4
                                   : 5;
}

} // namespace NAMRig
