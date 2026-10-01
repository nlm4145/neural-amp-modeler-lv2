/* Black-box tuner stabilization regressions for the BUILT rig LV2 plugin.
 * clang -O2 -Ideps/lv2/include tests/verify_tuner.c -o /tmp/verify_tuner
 * /tmp/verify_tuner <rig .so>
 * No models, production headers, or Python detector mirror are needed.
 * Timing is measured in input samples, not wall time or callback counts.
 */
#include <dlfcn.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lv2/atom/atom.h>
#include <lv2/atom/util.h>
#include <lv2/buf-size/buf-size.h>
#include <lv2/core/lv2.h>
#include <lv2/options/options.h>
#include <lv2/patch/patch.h>
#include <lv2/urid/urid.h>
#include <lv2/worker/worker.h>

enum { kPorts = 79, kMax = 4096, kAtom = 16384,
       kEnable = 16, kNote = 17, kCents = 18 };
static const double pi = 3.14159265358979323846;
static char* uris[256];
static uint32_t nUris;
static int checks, fails;

static LV2_URID mapUri(LV2_URID_Map_Handle handle, const char* uri) {
  (void)handle;
  for (uint32_t i = 0; i < nUris; ++i)
    if (!strcmp(uris[i], uri)) return i + 1;
  if (nUris == 256 || !(uris[nUris] = strdup(uri))) {
    fprintf(stderr, "FAIL: URID map exhausted\n");
    exit(1);
  }
  return ++nUris;
}

static LV2_Worker_Status scheduleWork(LV2_Worker_Schedule_Handle handle,
                                      uint32_t size, const void* data) {
  (void)handle; (void)size; (void)data;
  return LV2_WORKER_SUCCESS; /* no model loads */
}

static void check(int ok, const char* format, ...) {
  ++checks;
  if (!ok) ++fails;
  printf("  %s  ", ok ? "PASS" : "FAIL");
  va_list args;
  va_start(args, format);
  vprintf(format, args);
  va_end(args);
  putchar('\n');
}

typedef union {
  LV2_Atom_Sequence alignment;
  uint8_t bytes[kAtom];
} AtomBuffer;

typedef struct {
  const LV2_Descriptor* descriptor;
  LV2_Handle instance;
  LV2_URID_Map map;
  LV2_Worker_Schedule schedule;
  AtomBuffer control, notify;
  float input[kMax], output[kMax], right[kMax], ctl[kPorts];
  double rate, phase;
  uint32_t block, rng;
  int healthy;
  float sentNote, sentCents;
} Host;

static int openHost(Host* h, const LV2_Descriptor* d, double rate,
                    uint32_t block) {
  memset(h, 0, sizeof(*h));
  h->descriptor = d;
  h->rate = rate;
  h->block = block;
  h->rng = 0x53a9b417u;
  h->healthy = 1;
  h->sentNote = -1.0f;
  h->map = (LV2_URID_Map){NULL, mapUri};
  h->schedule = (LV2_Worker_Schedule){NULL, scheduleWork};
  LV2_Feature fMap = {LV2_URID__map, &h->map};
  LV2_Feature fSchedule = {LV2_WORKER__schedule, &h->schedule};
  const int32_t maxBlock = kMax;
  LV2_Options_Option options[] = {
    {LV2_OPTIONS_INSTANCE, 0, mapUri(NULL, LV2_BUF_SIZE__maxBlockLength),
     sizeof(maxBlock), mapUri(NULL, LV2_ATOM__Int), &maxBlock},
    {0}
  };
  LV2_Feature fOptions = {LV2_OPTIONS__options, options};
  const LV2_Feature* features[] = {&fMap, &fSchedule, &fOptions, NULL};
  h->instance = d->instantiate(d, rate, "", features);
  if (!h->instance) {
    check(0, "instantiate at %.0f Hz / %u samples", rate, block);
    return 0;
  }

  /* Same 79-port defaults as verify_host_smoke.c, with the tuner enabled. */
  h->ctl[7] = h->ctl[8] = h->ctl[9] = h->ctl[10] = 1.0f;
  h->ctl[20] = h->ctl[21] = 1.0f;
  h->ctl[15] = -80.0f;
  h->ctl[23] = 150.0f;
  h->ctl[27] = 20000.0f;
  h->ctl[43] = h->ctl[44] = 25.0f;
  h->ctl[45] = h->ctl[46] = 50.0f;
  h->ctl[50] = 400.0f; h->ctl[51] = 35.0f; h->ctl[52] = 40.0f;
  h->ctl[55] = h->ctl[56] = h->ctl[57] = 50.0f;
  h->ctl[58] = 10.0f;
  const float trims[11] = {1, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1};
  memcpy(h->ctl + 60, trims, sizeof(trims));
  for (uint32_t p = 71; p < kPorts; ++p) h->ctl[p] = 1.0f;
  h->ctl[kEnable] = 1.0f;
  h->ctl[kNote] = -1.0f;
  for (uint32_t p = 0; p < kPorts; ++p) {
    void* buffer = &h->ctl[p];
    if (p == 0) buffer = h->control.bytes;
    else if (p == 1) buffer = h->notify.bytes;
    else if (p == 2) buffer = h->input;
    else if (p == 3) buffer = h->output;
    else if (p == 31) buffer = h->right;
    d->connect_port(h->instance, p, buffer);
  }
  if (d->activate) d->activate(h->instance);
  return 1;
}

static void closeHost(Host* h) {
  if (h->descriptor->deactivate) h->descriptor->deactivate(h->instance);
  h->descriptor->cleanup(h->instance);
}

enum Shape { steady, jitter, pluck, decay, silence, noise, ramp, repeatedPluck };
typedef struct {
  enum Shape shape;
  double frequency, cents, amplitude;
  uint64_t samples;
} Signal;

typedef struct {
  unsigned valid, missing;
  int cleared;
  double weight, sum, sumSq, minCents, maxCents, maxError;
  double firstPitch, firstMidi, withinOne, rawRms;
  double maxUnchanged;
} Measurement;

/* A six-harmonic string, with continuous phase even across tuning changes.
 * The 1/h spectrum is peak-normalized; decay damps upper partials faster.
 * Signal.samples keeps ramps and pluck/decay timing continuous across feed calls.
 */
static Measurement feed(Host* h, Signal* signal, double seconds,
                        double measureAfter, double targetMidi) {
  Measurement m = {0};
  m.cleared = 1;
  m.minCents = INFINITY;
  m.maxCents = -INFINITY;
  m.firstPitch = m.withinOne = -1.0;
  m.firstMidi = -999.0;
  const uint64_t count = (uint64_t)llround(seconds * h->rate);
  double energy = 0.0;
  double previousNote = NAN, previousCents = NAN, unchanged = 0.0;
  for (uint64_t done = 0; done < count;) {
    const uint32_t n = (uint32_t)fmin(h->block, count - done);
    for (uint32_t i = 0; i < n; ++i, ++signal->samples) {
      const double t = signal->samples / h->rate;
      double cents = signal->cents, amplitude = signal->amplitude;
      double damping = 0.0;
      if (signal->shape == jitter)
        cents += ((uint64_t)(t / 0.060) & 1) ? -3.0 : 3.0;
      if (signal->shape == ramp) cents += 200.0 * t;
      if (signal->shape == pluck) {
        if (t < 0.120) cents += 6.0;
        damping = fmax(0.0, t - 0.120) / 1.2;
      } else if (signal->shape == decay) {
        damping = t / 0.120;
      } else if (signal->shape == repeatedPluck) {
        damping = fmod(t, 0.250) / 0.120;
      }
      amplitude *= exp(-damping);
      double x = 0.0;
      if (signal->shape == noise) {
        h->rng ^= h->rng << 13;
        h->rng ^= h->rng >> 17;
        h->rng ^= h->rng << 5;
        x = amplitude * (2.0 * (h->rng >> 8) / 16777216.0 - 1.0);
      } else if (signal->shape != silence) {
        for (int harmonic = 1; harmonic <= 6; ++harmonic)
          x += sin(harmonic * h->phase + 0.17 * (harmonic - 1)) *
               exp(-0.15 * damping * (harmonic - 1)) / harmonic;
        x *= amplitude / 2.45;
      }
      h->input[i] = (float)x;
      energy += x * x;
      h->phase += 2.0 * pi * signal->frequency * exp2(cents / 1200.0) / h->rate;
      if (h->phase >= 2.0 * pi) h->phase -= 2.0 * pi;
    }
    LV2_Atom_Sequence* control = (LV2_Atom_Sequence*)h->control.bytes;
    control->atom.type = mapUri(NULL, LV2_ATOM__Sequence);
    control->atom.size = sizeof(LV2_Atom_Sequence_Body);
    control->body.unit = control->body.pad = 0;
    ((LV2_Atom_Sequence*)h->notify.bytes)->atom.size = kAtom - sizeof(LV2_Atom);
    h->descriptor->run(h->instance, n);
    LV2_ATOM_SEQUENCE_FOREACH((LV2_Atom_Sequence*)h->notify.bytes, event) {
      if (event->body.type != mapUri(NULL, LV2_ATOM__Object)) continue;
      const LV2_Atom_Object* object = (const LV2_Atom_Object*)&event->body;
      if (object->body.otype != mapUri(NULL, LV2_PATCH__Set)) continue;
      const LV2_Atom *property = NULL, *value = NULL;
      lv2_atom_object_get(object, mapUri(NULL, LV2_PATCH__property), &property,
                          mapUri(NULL, LV2_PATCH__value), &value, 0);
      if (!property || !value || property->type != mapUri(NULL, LV2_ATOM__URID) ||
          value->type != mapUri(NULL, LV2_ATOM__Float)) continue;
      const LV2_URID id = ((const LV2_Atom_URID*)property)->body;
      const float v = ((const LV2_Atom_Float*)value)->body;
      if (id == mapUri(NULL, "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig-tuner-note"))
        h->sentNote = v;
      if (id == mapUri(NULL, "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig-tuner-cents"))
        h->sentCents = v;
    }
    done += n;
    const double time = done / h->rate;
    const double note = h->ctl[kNote], cents = h->ctl[kCents];
    if (round(h->sentNote) != round(note) || fabs(h->sentCents - cents) > 1.01)
      h->healthy = 0;
    if (!isfinite(note) || !isfinite(cents) || cents < -50.0 || cents > 50.0 ||
        (note < 0.0 && note != -1.0)) h->healthy = 0;
    if (note >= 0.0) {
      if (fabs(cents - 100.0 * (note - round(note))) > 0.05) h->healthy = 0;
      if (m.firstPitch < 0.0) {
        m.firstPitch = time;
        m.firstMidi = note;
      }
      if (m.withinOne < 0.0 && fabs(note - targetMidi) * 100.0 <= 1.0)
        m.withinOne = time;
    }
    if (time <= measureAfter) continue;
    const double weight = fmin(n / h->rate, time - measureAfter);
    unchanged = note == previousNote && cents == previousCents ? unchanged + weight : weight;
    m.maxUnchanged = fmax(m.maxUnchanged, unchanged);
    previousNote = note;
    previousCents = cents;
    if (note != -1.0 || cents != 0.0) m.cleared = 0;
    if (note < 0.0) {
      ++m.missing;
    } else {
      ++m.valid;
      m.weight += weight;
      m.sum += weight * cents;
      m.sumSq += weight * cents * cents;
      m.minCents = fmin(m.minCents, cents);
      m.maxCents = fmax(m.maxCents, cents);
      m.maxError = fmax(m.maxError, fabs(note - targetMidi) * 100.0);
    }
  }
  m.rawRms = count ? sqrt(energy / count) : 0.0;
  return m;
}

static int accurate(Measurement m, double tolerance) {
  return m.valid && !m.missing && m.maxError <= tolerance;
}

static void verifyTracking(Host* h) {
  const double lowE = 440.0 * exp2((40.0 - 69.0) / 12.0);
  Signal s = {steady, lowE, 0.0, 0.05, 0};
  Measurement m = feed(h, &s, 1.2, 0.8, 40.0);
  check(accurate(m, 2.0), "steady low E: worst %.2fc, missing %u", m.maxError, m.missing);

  const double quietNote = h->ctl[kNote], quietCents = h->ctl[kCents];
  s = (Signal){steady, lowE, 0.3, 0.05, 0};
  m = feed(h, &s, 1.0, 0.0, quietNote);
  check(quietNote >= 0.0 && accurate(m, 0.1) &&
        fmax(fabs(m.minCents - quietCents), fabs(m.maxCents - quietCents)) <= 0.1,
        "sub-0.5c deadband: +0.3c input, display drift %.2fc", m.maxError);

  s = (Signal){jitter, lowE, 0.0, 0.05, 0};
  m = feed(h, &s, 3.0, 1.0, 40.0);
  const double mean = m.weight ? m.sum / m.weight : INFINITY;
  const double deviation = m.weight ? sqrt(fmax(0.0, m.sumSq / m.weight - mean * mean)) : INFINITY;
  /* Broad peak bound; attenuation is judged primarily by time-weighted SD,
   * not a brittle maximum at one analysis/block alignment. Input SD is 3c. */
  check(m.valid && !m.missing && fabs(mean) < 1.0 && deviation < 1.25 && m.maxError < 3.0,
        "low-E +/-3c / 60ms jitter: mean %.2fc, SD %.2fc, peak %.2fc", mean, deviation, m.maxError);

  s = (Signal){steady, lowE, 0.0, 0.05, 0};
  feed(h, &s, 0.8, 0.0, 40.0);
  const double heldNote = h->ctl[kNote], heldCents = h->ctl[kCents];
  s = (Signal){pluck, lowE, 0.0, 0.4, 0};
  m = feed(h, &s, 0.180, 0.0, heldNote);
  const double centsMove = fmax(fabs(m.minCents - heldCents), fabs(m.maxCents - heldCents));
  check(heldNote >= 0.0 && accurate(m, 0.1) && centsMove <= 0.1,
        "0.05 -> 0.4 re-pluck, +6c for 120ms: 180ms hold drift %.2fc / %.2fc, missing %u",
        m.maxError, centsMove, m.missing);
  m = feed(h, &s, 1.32, 0.0, 40.0);
  check(accurate(m, 1.5), "re-pluck attack excluded from history: recovery peak %.2fc, missing %u",
        m.maxError, m.missing);

  /* Match the end of the decay envelope: a tuning adjustment is not a pluck. */
  const double tailAmplitude = 0.4 * exp(-(1.5 - 0.120) / 1.2);
  s = (Signal){steady, lowE, 10.0, tailAmplitude, 0};
  m = feed(h, &s, 0.350, 0.0, 40.1);
  const double response = (h->ctl[kNote] - 40.0) * 100.0;
  check(m.valid && !m.missing && response > 2.0 && response < 8.0,
        "+10c adjustment at 350ms: %.2fc (gradual 250ms smoothing)", response);
  m = feed(h, &s, 0.650, 0.550, 40.1);
  check(accurate(m, 1.0), "+10c adjustment by 1s: worst %.2fc from target, final %.2fc",
        m.maxError, h->ctl[kCents]);

  s = (Signal){steady, 110.0, 0.0, tailAmplitude, 0};
  m = feed(h, &s, 0.7, 0.5, 45.0);
  check(m.withinOne >= 0.0 && m.withinOne < 0.5 && accurate(m, 2.0),
        "next string 110Hz: relatch %.0fms (<500ms), settled error %.2fc",
        m.withinOne * 1000.0, m.maxError);

  s = (Signal){steady, 110.0, -7.0, tailAmplitude, 0};
  m = feed(h, &s, 1.2, 0.8, 44.93);
  const int decayLatched = accurate(m, 2.0) && fabs(h->ctl[kCents]) > 4.0;
  s = (Signal){decay, 110.0, -7.0, tailAmplitude, 0};
  m = feed(h, &s, 1.0, 0.8, 44.93);
  check(decayLatched && m.cleared, "decay clears note AND nonzero cents: note %.3f, cents %.3f",
        h->ctl[kNote], h->ctl[kCents]);

  s = (Signal){steady, 440.0, 0.0, 0.05, 0};
  m = feed(h, &s, 1.2, 0.8, 69.0);
  check(accurate(m, 2.0), "steady A4: worst %.2fc, missing %u", m.maxError, m.missing);
  const double a4Bias = m.weight ? m.sum / m.weight : INFINITY;
  s = (Signal){jitter, 440.0, 0.0, 0.05, 0};
  m = feed(h, &s, 3.0, 1.0, 69.0);
  const double a4Mean = m.weight ? m.sum / m.weight : INFINITY;
  const double a4Deviation = m.weight ? sqrt(fmax(0.0, m.sumSq / m.weight - a4Mean * a4Mean)) : INFINITY;
  const double a4Peak = fmax(fabs(m.minCents - a4Bias), fabs(m.maxCents - a4Bias));
  check(m.valid && !m.missing && fabs(a4Mean - a4Bias) < 1.0 &&
        a4Deviation < 1.25 && a4Peak < 3.0,
        "A4 +/-3c / 60ms jitter: bias %.2fc, mean %.2fc, SD %.2fc, peak %.2fc",
        a4Bias, a4Mean, a4Deviation, a4Peak);
  s = (Signal){steady, 440.0, 8.0, 0.05, 0};
  m = feed(h, &s, 1.2, 0.8, 69.08);
  const int silenceLatched = accurate(m, 2.0) && fabs(h->ctl[kCents]) > 4.0;
  const double beforeSilence = h->ctl[kNote];
  s = (Signal){silence, 440.0, 0.0, 0.0, 0};
  m = feed(h, &s, 0.080, 0.0, beforeSilence);
  check(silenceLatched && accurate(m, 0.5), "short 80ms dropout holds note: drift %.2fc, missing %u",
        m.maxError, m.missing);
  m = feed(h, &s, 0.620, 0.420, 69.08);
  check(m.cleared, "silence / 8 misses clears both: note %.3f, cents %.3f",
        h->ctl[kNote], h->ctl[kCents]);

  s = (Signal){steady, 440.0, 8.0, 0.05, 0};
  m = feed(h, &s, 1.2, 0.8, 69.08);
  const int disableLatched = accurate(m, 2.0);
  h->ctl[kEnable] = 0.0f;
  s = (Signal){steady, 110.0, -9.0, 0.05, 0};
  m = feed(h, &s, 0.2, 0.0, 44.91);
  check(disableLatched && m.cleared, "disable clears both outputs: note %.3f, cents %.3f",
        h->ctl[kNote], h->ctl[kCents]);
  h->ctl[kEnable] = 1.0f;
  s = (Signal){silence, 110.0, 0.0, 0.0, 0};
  m = feed(h, &s, 0.100, 0.0, 44.91);
  check(m.cleared, "re-enable with 100ms fresh silence: stale acquisitions %u", m.valid);
  s = (Signal){steady, 110.0, -9.0, 0.05, 0};
  m = feed(h, &s, 0.8, 0.5, 44.91);
  check(m.firstPitch >= 0.0 && fabs(m.firstMidi - 44.91) * 100.0 < 2.0 && accurate(m, 2.0),
        "re-enable acquires only new 110Hz samples: first MIDI %.3f at %.0fms, error %.2fc",
        m.firstMidi, m.firstPitch * 1000.0, m.maxError);
  check(h->healthy, "finite, consistent note/cents outputs throughout tracking");
}

static void verifyAcquisition(Host* h) {
  const double lowE = 440.0 * exp2((40.0 - 69.0) / 12.0);
  Signal s = {pluck, lowE, 0.0, 0.4, 0};
  Measurement m = feed(h, &s, 0.120, 0.0, 40.0);
  int ignored = m.cleared;
  double firstTime = m.firstPitch, firstMidi = m.firstMidi;
  m = feed(h, &s, 0.060, 0.0, 40.0);
  ignored = ignored && m.cleared;
  if (firstTime < 0.0 && m.firstPitch >= 0.0) {
    firstTime = 0.120 + m.firstPitch;
    firstMidi = m.firstMidi;
  }
  m = feed(h, &s, 0.820, 0.400, 40.0);
  if (firstTime < 0.0 && m.firstPitch >= 0.0) {
    firstTime = 0.180 + m.firstPitch;
    firstMidi = m.firstMidi;
  }
  check(ignored && firstTime >= 0.0 && fabs(firstMidi - 40.0) * 100.0 <= 1.5 && accurate(m, 1.5),
        "acquisition ignores sharp first 120ms / holds 180ms: first %.0fms, %.2fc; settled %.2fc",
        firstTime * 1000.0, (firstMidi - 40.0) * 100.0, m.maxError);
  check(h->healthy, "finite, consistent acquisition outputs");
}

static void verifyResponsiveness(Host* h) {
  /* Only 70ms between 180ms attack holds: reliable history must survive
   * each onset to acquire and follow a new string under repeated picking. */
  Signal s = {repeatedPluck, 110.0, 0.0, 0.4, 0};
  Measurement m = feed(h, &s, 3.0, 1.0, 45.0);
  check(m.withinOne >= 0.0 && m.withinOne <= 1.0 && accurate(m, 2.0),
        "fresh 110Hz plucks every 250ms: acquire %.0fms (<=1s), thereafter error %.2fc, missing %u",
        m.withinOne * 1000.0, m.maxError, m.missing);

  const double lowE = 440.0 * exp2((40.0 - 69.0) / 12.0);
  s = (Signal){steady, lowE, 0.0, 0.05, 0};
  m = feed(h, &s, 1.2, 0.8, 40.0);
  check(accurate(m, 2.0), "latched low E before repeated picking: error %.2fc, missing %u",
        m.maxError, m.missing);
  s = (Signal){repeatedPluck, 110.0, 0.0, 0.4, 0};
  m = feed(h, &s, 3.0, 1.0, 45.0);
  check(m.withinOne >= 0.0 && m.withinOne <= 1.0 && accurate(m, 2.0),
        "low E -> 110Hz plucks every 250ms: switch %.0fms (<=1s), thereafter error %.2fc, missing %u",
        m.withinOne * 1000.0, m.maxError, m.missing);

  s = (Signal){steady, 110.0, 0.0, 0.05, 0};
  feed(h, &s, 0.8, 0.0, 45.0);
  s = (Signal){ramp, 110.0, 0.0, 0.05, 0};
  m = feed(h, &s, 3.0, 1.0, 51.0);
  const double finalError = fabs(h->ctl[kNote] - 51.0) * 100.0;
  check(h->ctl[kNote] >= 0.0 && finalError <= 60.0,
        "110Hz +200c/sec phase-continuous ramp for 3s: final MIDI %.3f, expected 51.0, error %.2fc (<=60c)",
        h->ctl[kNote], finalError);
  check(m.valid && !m.missing && m.maxUnchanged <= 0.5,
        "ramp last 2s: longest unchanged note/cents %.0fms (<=500ms), missing %u",
        m.maxUnchanged * 1000.0, m.missing);
  check(h->healthy, "finite, consistent responsiveness outputs");
}

static void verifyNoise(Host* h) {
  Signal s = {noise, 110.0, 0.0, 0.08, 0};
  Measurement m = feed(h, &s, 3.0, 0.0, 45.0);
  check(m.rawRms > 0.02 && m.cleared,
        "deterministic noise above RMS gate never acquires: RMS %.4f, acquisitions %u",
        m.rawRms, m.valid);
  s = (Signal){steady, 440.0, 9.0, 0.05, 0};
  m = feed(h, &s, 1.2, 0.8, 69.09);
  const int latched = accurate(m, 2.0) && fabs(h->ctl[kCents]) > 4.0;
  s = (Signal){noise, 110.0, 0.0, 0.08, 0};
  m = feed(h, &s, 1.0, 0.7, 69.09);
  check(latched && m.cleared, "low-confidence noise / 8 misses clears both: note %.3f, cents %.3f",
        h->ctl[kNote], h->ctl[kCents]);
  check(h->healthy, "finite, consistent noise outputs");
}

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: verify_tuner <rig .so>\n");
    return 1;
  }
  void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) {
    fprintf(stderr, "FAIL: dlopen: %s\n", dlerror());
    return 1;
  }
  const LV2_Descriptor* (*descriptorFn)(uint32_t) =
      (const LV2_Descriptor* (*)(uint32_t))dlsym(library, "lv2_descriptor");
  const LV2_Descriptor* d = descriptorFn ? descriptorFn(0) : NULL;
  if (!d || !d->instantiate || !d->connect_port || !d->run || !d->cleanup) {
    fprintf(stderr, "FAIL: missing LV2 descriptor/callbacks\n");
    dlclose(library);
    return 1;
  }
  Host* h = calloc(1, sizeof(*h));
  if (!h) {
    fprintf(stderr, "FAIL: host allocation\n");
    dlclose(library);
    return 1;
  }
  const double rates[] = {48000.0, 96000.0};
  const uint32_t blocks[] = {64, 512, 2048};
  printf("Tuner stabilization: %s (no models, max buffer %d)\n", argv[1], kMax);
  /* The LV2 ABI exposes no live sample-rate setter. Fresh instances exercise
   * initialization at both rates without relying on internal C++ symbols. */
  for (unsigned r = 0; r < 2; ++r) {
    for (unsigned b = 0; b < 3; ++b) {
      printf("\n%.0f Hz / %u samples\n", rates[r], blocks[b]);
      if (openHost(h, d, rates[r], blocks[b])) {
        verifyTracking(h);
        closeHost(h);
      }
      if (openHost(h, d, rates[r], blocks[b])) {
        verifyAcquisition(h);
        closeHost(h);
      }
      if (openHost(h, d, rates[r], blocks[b])) {
        verifyResponsiveness(h);
        closeHost(h);
      }
      if (openHost(h, d, rates[r], blocks[b])) {
        verifyNoise(h);
        closeHost(h);
      }
    }
  }
  free(h);
  dlclose(library);
  for (uint32_t i = 0; i < nUris; ++i) free(uris[i]);
  printf("\n%s (%d/%d checks passed, %d failures)\n",
         fails ? "FAILED" : "ALL PASSED", checks - fails, checks, fails);
  return fails ? 1 : 0;
}
