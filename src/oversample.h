#pragma once
// True 2x oversampling of the nonlinear (model) stages — half-band polyphase.
//
// Design (spec = tests/test_oversample_2x.py, verified by
// tests/verify_oversample_cpp.cpp):
//   Prototype: 47-tap Kaiser half-band, beta 9.0 (~100 dB stopband).
//     Even-offset taps are sinc zeros; center tap exactly 0.5; odd-offset
//     taps rescaled so the prototype sums to EXACTLY 1.
//   UP 2x: even outputs = input samples verbatim; odd outputs = centered
//     24-tap FIR (P = 2*h[odd offsets], DC gain exactly 1).
//   DOWN 2x: full 47-tap prototype FIR at the 2x rate, centered, even
//     absolute positions only.
//   Streaming: Up2x keeps the last 23 base samples as context and tracks the
//     next position to emit; Down2x keeps the last 23 2x-samples and tracks
//     absolute even output positions. Block boundaries can never flip
//     parity or drop positions. Fixed pipeline delay, any block size.
//
// Real-time safety: process() does no allocation; scratch buffers are
// pre-sized via setMaxBlockSize() (host thread, before audio starts).

#include <cstddef>
#include <cstdint>

namespace NAMRig {

class Up2x {
 public:
  static constexpr size_t maxOutput(size_t n) { return 2 * n; }
  void reset();
  // n = the largest input block you will ever feed process(). Must be
  // called before the first process() (and before reset() to size the
  // initial allocation).
  void setMaxBlockSize(size_t n) {
    const size_t want = kHist + n;
    if (want != scratchSize_) {
      delete[] scratch_;
      scratch_ = new float[want];
      scratchSize_ = want;
    }
  }
  // out must hold 2*n floats. Returns samples written.
  size_t process(const float* in, size_t n, float* out);

 private:
  static constexpr size_t kHist = 23;  // 11 left + 12 right context
  float hist_[kHist] = {};
  size_t scratchSize_ = 23 + 8192;
  // scratch_ is allocated lazily on first setMaxBlockSize/reset (host side);
  // process() never allocates.
  float* scratch_ = nullptr;
  size_t next_ = 0;      // next base position to emit (absolute)
  size_t provided_ = 0;  // base samples provided so far (absolute)
};

class Down2x {
 public:
  static constexpr size_t maxOutput(size_t n2x) { return n2x / 2; }
  void reset();
  // n2x = the largest 2x-rate block you will ever feed process().
  void setMaxBlockSize(size_t n2x) {
    const size_t want = kHist + n2x;
    if (want != scratchSize_) {
      delete[] scratch_;
      scratch_ = new float[want];
      scratchSize_ = want;
    }
  }
  size_t process(const float* in, size_t n, float* out);

 private:
  // Full window width of history: after emitting up to position a, the next
  // output a+2 needs context [a-21, a+25] — positions both BEFORE and AFTER
  // the trim point. Keeping a full 46-sample window guarantees coverage
  // regardless of how the next block lands.
  static constexpr size_t kHist = 46;
  float hist_[kHist] = {};
  size_t scratchSize_ = 46 + 16384;
  float* scratch_ = nullptr;
  size_t consumed_ = 0;  // absolute 2x samples fed
  size_t emitted_ = 0;   // absolute base positions emitted
};

const float* halfBandProto();
const float* halfBandInterp();

}  // namespace NAMRig
