#include "oversample.h"

#include <cmath>
#include <cstdlib>
#include <cstring>

#include <Accelerate/Accelerate.h>

namespace NAMRig {

// ---- prototype, computed once at static initialization ----
static double besselI0(double x) {
  double sum = 1.0, term = 1.0;
  for (int k = 1; k < 80; ++k) {
    term *= (x / (2.0 * k)) * (x / (2.0 * k));
    sum += term;
    if (term < 1e-18 * sum) break;
  }
  return sum;
}

struct ProtoInit {
  float proto[47];
  float interp[24];
  ProtoInit() {
    constexpr int n = 47;
    constexpr int half = (n - 1) / 2;  // 23
    constexpr double beta = 9.0;
    constexpr double kPi = 3.14159265358979323846;
    const double i0b = besselI0(beta);
    double h[n];
    for (int i = 0; i < n; ++i) {
      const double m = i - half;
      const double r = m / half;
      const double w = besselI0(beta * std::sqrt(std::max(0.0, 1.0 - r * r))) / i0b;
      const double sinc = m == 0.0 ? 1.0 : std::sin(kPi * 0.5 * m) / (kPi * 0.5 * m);
      h[i] = 0.5 * sinc * w;
    }
    h[half] = 0.5;
    double oddSum = 0.0;
    for (int i = 0; i < n; ++i)
      if ((i - half) % 2 != 0) oddSum += h[i];
    const double scale = 0.5 / oddSum;
    for (int i = 0; i < n; ++i)
      if ((i - half) % 2 != 0) h[i] *= scale;
    for (int i = 0; i < n; ++i) proto[i] = (float)h[i];
    // Interp branch: odd OFFSETS live at even INDICES -> 24 symmetric taps,
    // doubled (sum of odd taps is 0.5 -> branch DC gain exactly 1).
    for (int k = 0; k < 24; ++k) interp[k] = (float)(2.0 * h[2 * k]);
  }
};

static const ProtoInit gProto;
const float* halfBandProto() { return gProto.proto; }
const float* halfBandInterp() { return gProto.interp; }

// ---- Up2x ----
// State: hist_ holds the last 23 PROVIDED base samples (or zeros at stream
// start). next_ = next base position to emit; provided_ = count provided.
// A position p is emittable when its 24-tap window [p-11, p+12] lies fully
// within PROVIDED data [0, provided_). After a call we emit all emittable
// positions in [next_, ...) and slide hist_ to the last 23 provided samples.
void Up2x::reset() {
  std::memset(hist_, 0, sizeof(hist_));
  next_ = 0;
  provided_ = 0;
  if (!scratch_) scratch_ = new float[scratchSize_];  // host thread only
}

size_t Up2x::process(const float* in, size_t n, float* out) {
  const float* P = halfBandInterp();
  const size_t total = kHist + n;
  // Refuse if input AND the m conv outputs (m <= n) would exceed scratch.
  if (total + n > scratchSize_) return 0;  // block larger than promised
  float* scr = scratch_;
  std::memcpy(scr, hist_, kHist * sizeof(float));
  std::memcpy(scr + kHist, in, n * sizeof(float));
  // scr[i] = absolute base position (provided_ - kHist) + i; hist_ holds the
  // LAST 23 provided samples, i.e. absolute positions
  // [provided_-23, provided_). scr[kHist + j] = in[j] = position provided_+j.
  // A position p is emittable when its 24-tap window [p-11, p+12] lies fully
  // within PROVIDED data [0, provided_+n). The emittable positions form a
  // contiguous run [pStart, pEnd]:
  //   window start index (p-11)-base >= 0   -> p >= base + 11
  //   window start index + 24 <= total      -> p <= base + total - 13
  // (base = absolute position of scr[0] = provided_ - kHist.)
  const long base = (long)provided_ - (long)kHist;
  long p = (long)next_;
  if (p < base + 11) p = base + 11;            // defensive; mirrors the old
                                               // skip-loop for pre-window p
  const long pEnd = base + (long)total - 13;  // last emittable, inclusive
  size_t m = 0;
  if (pEnd >= p) m = (size_t)(pEnd - p + 1);
  if (m > 0) {
    const size_t j0 = (size_t)((p - 11) - base);  // scr index of first window
    // Batching formulation (benchmark-chosen): one contiguous vDSP_conv of
    // ALL m 24-tap dots into scratch (unit strides = vDSP fast path), then
    // interleave with the pass-through even samples. Same dots as the old
    // per-sample loop — output-stride-2 writes and strided-input convs were
    // both measured SLOWER than the old code; only this shape vectorizes.
    // In-bounds by the same guarantee that made each position emittable:
    // (m-1) + 24 <= total - j0.
    float* dst = scr + total;        // scratch tail: never aliases in/out
    vDSP_conv(scr + j0, 1, P, 1, dst, 1, m, 24);
    for (size_t i = 0; i < m; ++i) {
      out[2 * i] = scr[j0 + 11 + i];
      out[2 * i + 1] = dst[i];
    }
  }
  next_ = (size_t)(p + (long)m);
  provided_ += n;
  // hist_ <- last 23 provided samples (tail of scr, possibly including
  // fewer than 23 if the stream is shorter than that).
  if (total >= kHist)
    std::memcpy(hist_, scr + total - kHist, kHist * sizeof(float));
  else
    std::memcpy(hist_, scr, total * sizeof(float));  // very first tiny block
  return 2 * m;
}

// ---- Down2x ----
// State: hist_ holds the last 23 PROVIDED 2x samples. consumed_ = absolute
// count of 2x samples provided. Output positions are even absolute 2x
// indices whose 47-tap window [a-23, a+23] lies fully in provided data.
void Down2x::reset() {
  std::memset(hist_, 0, sizeof(hist_));
  consumed_ = 0;
  emitted_ = 0;
  if (!scratch_) scratch_ = new float[scratchSize_];  // host thread only
}

size_t Down2x::process(const float* in, size_t n, float* out) {
  const float* P = halfBandInterp();
  const size_t total = kHist + n;
  // Refuse if hist + input + the polyphase work areas (m conv outputs plus
  // two m+23 branches) would exceed scratch; mirrors setMaxBlockSize.
  if (kHist + 3 * n + 128 > scratchSize_) return 0;
  float* scr = scratch_;
  std::memcpy(scr, hist_, kHist * sizeof(float));
  std::memcpy(scr + kHist, in, n * sizeof(float));
  // scr[i] = absolute 2x position (consumed_ - kHist) + i.
  // Output positions are even absolute 2x indices a whose 47-tap window
  // [a-23, a+23] lies fully in provided data. The old per-sample loop's
  // skip (window before stream start) and break (window beyond data) reduce
  // to a closed-form range:
  //   window start index (a-23)-base >= 0  -> a >= base + 23
  //   window start index + 47 <= total     -> a <= base + total - 24
  //   (47 taps starting at (a-23)-base: (a-23)-base+47 <= total
  //    => a <= base + total - 24; NOT -47 — the window START is offset by
  //    the 23-tap left context.)
  // with a even and a >= 2*emitted_ (the next unemitted output position).
  const long base = (long)consumed_ - (long)kHist;
  long a = 2 * (long)emitted_;                 // even
  const long aMin = base + 23;                 // first non-skipped position
  if (a < aMin) a = aMin + ((aMin - a) & 1);   // next even >= max(a, aMin)
  const long aEnd = base + (long)total - 24;   // last emittable, inclusive
  size_t m = 0;
  if (aEnd >= a) m = (size_t)((aEnd - a) / 2 + 1);
  if (m > 0) {
    const size_t j0 = (size_t)((a - 23) - base);  // scr index of 1st window
    // Polyphase formulation: the prototype's even offsets are all sinc zeros
    // except the center tap (exactly 0.5), so each output needs only the
    // window center plus a 24-tap dot over the window's odd positions. One
    // vDSP_ctoz deinterleaves the m windows' shared samples (realp[t] =
    // scr[j0+2t] = odd offsets, imagp[t] = scr[j0+2t+1]; the center of
    // window i is imagp[i+11]); one unit-stride vDSP_conv (fast path) then
    // computes all m odd-branch dots. halfBandInterp() = 2 * the odd-offset
    // taps, so out = 0.5 * (center + dot). Half the multiplies of running
    // the full 47-tap FIR across every 2x position.
    // In-bounds: 2(m-1) + 47 <= total - j0 by the emittability guarantee;
    // ctoz reads at most one float past that, still inside the allocation.
    float* dst = scr + total;        // scratch tail: never aliases in/out
    float* oddB = dst + m;
    float* evenB = oddB + (m + 23);
    DSPSplitComplex split{oddB, evenB};
    vDSP_ctoz(reinterpret_cast<const DSPComplex*>(scr + j0), 2, &split, 1,
              m + 23);
    vDSP_conv(oddB, 1, P, 1, dst, 1, m, 24);
    for (size_t i = 0; i < m; ++i) out[i] = 0.5f * (evenB[i + 11] + dst[i]);
  }
  emitted_ += m;
  consumed_ += n;
  // hist_ = last kHist samples of scr — with kHist = 46 (full window width)
  // this always covers the next output's entire window.
  if (total >= kHist)
    std::memcpy(hist_, scr + total - kHist, kHist * sizeof(float));
  else
    std::memcpy(hist_, scr, total * sizeof(float));
  return m;
}

}  // namespace NAMRig
