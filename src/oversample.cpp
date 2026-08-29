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
  if (total > scratchSize_) return 0;  // block larger than promised; refuse
  float* scr = scratch_;
  std::memcpy(scr, hist_, kHist * sizeof(float));
  std::memcpy(scr + kHist, in, n * sizeof(float));
  // scr[i] = absolute base position (provided_ - kHist) + i? No: hist_ holds
  // the LAST 23 provided samples, i.e. absolute positions
  // [provided_-23, provided_). scr[kHist + j] = in[j] = position provided_+j.
  // Window of position p starts at scr index (p - kLeft) - (provided_ - kHist).
  // Emittable p: p >= kLeft (window start >= 0) and p + kRight < provided_ + n
  // (window end within provided data).
  const long base = (long)provided_ - (long)kHist;  // abs pos of scr[0]
  long p = (long)next_;
  size_t emitted = 0;
  while (true) {
    const long wStartIdx = (p - 11) - base;   // scr index of window start
    if (wStartIdx < 0) { ++p; continue; }     // shouldn't happen (next_ >= 11)
    if (wStartIdx + 24 > (long)total) break;  // window exceeds provided data
    const size_t j = (size_t)wStartIdx;
    out[2 * emitted] = scr[j + 11];           // the sample at p itself
    vDSP_dotpr(scr + j, 1, P, 1, out + 2 * emitted + 1, 24);
    ++emitted;
    p += 1;
  }
  next_ = (size_t)p;
  provided_ += n;
  // hist_ <- last 23 provided samples (tail of scr, possibly including
  // fewer than 23 if the stream is shorter than that).
  if (total >= kHist)
    std::memcpy(hist_, scr + total - kHist, kHist * sizeof(float));
  else
    std::memcpy(hist_, scr, total * sizeof(float));  // very first tiny block
  return 2 * emitted;
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
  const float* H = halfBandProto();
  const size_t total = kHist + n;
  if (total > scratchSize_) return 0;
  float* scr = scratch_;
  std::memcpy(scr, hist_, kHist * sizeof(float));
  std::memcpy(scr + kHist, in, n * sizeof(float));
  // scr[i] = absolute 2x position (consumed_ - kHist) + i.
  const long base = (long)consumed_ - (long)kHist;
  size_t emitted = 0;
  long a = 2 * (long)emitted_;  // next even absolute output position
  while (true) {
    const long wStartIdx = (a - 23) - base;
    if (wStartIdx < 0) { a += 2; continue; }   // window before stream start
    if (wStartIdx + 47 > (long)total) break;   // window beyond provided data
    vDSP_dotpr(scr + wStartIdx, 1, H, 1, out + emitted, 47);
    ++emitted;
    a += 2;
  }
  emitted_ += emitted;
  consumed_ += n;
  // hist_ = last kHist samples of scr — with kHist = 46 (full window width)
  // this always covers the next output's entire window.
  if (total >= kHist)
    std::memcpy(hist_, scr + total - kHist, kHist * sizeof(float));
  else
    std::memcpy(hist_, scr, total * sizeof(float));
  return emitted;
}

}  // namespace NAMRig
