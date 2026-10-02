/* Black-box per-pluck tuner regressions for the BUILT rig LV2 plugin.
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

enum { kPorts = 83, kRackEnd = 80, kMax = 4096, kAtom = 16384,
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

  /* Same 83-port defaults as verify_host_smoke.c, with the tuner enabled. */
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
  for (uint32_t p = 71; p < kRackEnd; ++p) h->ctl[p] = 1.0f;
  h->ctl[80] = 0.0f; h->ctl[81] = 50.0f; /* Captured profile */
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

enum Shape { steady, jitter, lateAttack, earlySustain, fadedTail, decay,
             silence, noise, ramp, repeatedPluck, fastPluck };
typedef struct {
  enum Shape shape;
  double frequency, cents, amplitude;
  uint64_t samples;
} Signal;

typedef struct {
  unsigned valid, missing;
  int cleared;
  double weight, sum, sumSq, minCents, maxCents, maxError;
  double firstPitch, firstMidi, firstChange, firstChangedMidi, rawRms;
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
  m.firstPitch = m.firstChange = -1.0;
  m.firstMidi = m.firstChangedMidi = -999.0;
  const uint64_t count = (uint64_t)llround(seconds * h->rate);
  double energy = 0.0;
  const double initialNote = h->ctl[kNote], initialCents = h->ctl[kCents];
  for (uint64_t done = 0; done < count;) {
    const uint32_t n = (uint32_t)fmin(h->block, count - done);
    for (uint32_t i = 0; i < n; ++i, ++signal->samples) {
      const double t = signal->samples / h->rate;
      double cents = signal->cents, amplitude = signal->amplitude;
      double damping = 0.0;
      if (signal->shape == jitter)
        cents += ((uint64_t)(t / 0.060) & 1) ? -3.0 : 3.0;
      if (signal->shape == ramp) cents += 200.0 * t;
      if (signal->shape == lateAttack) {
        if (t < 0.250) cents += 6.0;
      } else if (signal->shape == earlySustain) {
        /* Full amplitude even in the flat tail isolates the 1s cutoff. */
        cents += t < 0.250 ? 6.0 : t < 1.0 ? 4.0 : -8.0;
      } else if (signal->shape == fadedTail) {
        cents += t < 0.650 ? 4.0 : -8.0;
        if (t >= 0.650) amplitude *= 0.20;
      } else if (signal->shape == decay) {
        damping = t / 0.120;
      } else if (signal->shape == repeatedPluck || signal->shape == fastPluck) {
        /* 700ms picking leaves enough sustain for acceptance before the
         * -12dB cutoff; 250ms picking always restarts the attack guard. */
        const double period = signal->shape == fastPluck ? 0.250 : 0.700;
        damping = fmod(t, period) / (signal->shape == fastPluck ? 0.120 : 0.500);
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
    }
    if (m.firstChange < 0.0 && (note != initialNote || cents != initialCents)) {
      m.firstChange = time;
      m.firstChangedMidi = note;
    }
    if (time <= measureAfter) continue;
    const double weight = fmin(n / h->rate, time - measureAfter);
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

static int held(Measurement m, double note, double cents) {
  return note >= 0.0 && accurate(m, 0.0) &&
         m.minCents == cents && m.maxCents == cents;
}

static void verifyTracking(Host* h) {
  const double lowE = 440.0 * exp2((40.0 - 69.0) / 12.0);
  Signal s = {steady, lowE, 0.0, 0.05, 0};
  Measurement m = feed(h, &s, 0.600, 0.590, 40.0);
  check(accurate(m, 2.0), "steady low E: worst %.2fc, missing %u", m.maxError, m.missing);

  const double quietNote = h->ctl[kNote], quietCents = h->ctl[kCents];
  s = (Signal){steady, lowE, 0.3, 0.05, 0};
  m = feed(h, &s, 0.200, 0.0, quietNote);
  check(quietNote >= 0.0 && accurate(m, 0.1) &&
        fmax(fabs(m.minCents - quietCents), fabs(m.maxCents - quietCents)) <= 0.1,
         "sub-0.5c deadband inside sustain window: +0.3c input, display drift %.2fc", m.maxError);

  /* A >2x amplitude restart opens a fresh window. The +8c center ensures
   * an unchanged old reading cannot masquerade as jitter attenuation.
   * Measure after the ~500ms acquisition, but before the 1s cutoff. */
  s = (Signal){jitter, lowE, 8.0, 0.12, 0};
  m = feed(h, &s, 0.950, 0.600, 40.08);
  const double mean = m.weight ? m.sum / m.weight : INFINITY;
  const double deviation = m.weight ? sqrt(fmax(0.0, m.sumSq / m.weight - mean * mean)) : INFINITY;
  /* Broad peak bound; attenuation is judged primarily by time-weighted SD,
   * not a brittle maximum at one analysis/block alignment. Input SD is 3c. */
  check(m.firstChange >= 0.300 && m.firstChange <= 0.600 &&
        m.valid && !m.missing && fabs(mean - 8.0) < 1.0 && deviation < 1.25 && m.maxError < 3.0,
         "low-E early-window +/-3c / 60ms jitter around +8c: mean %.2fc, SD %.2fc, peak %.2fc",
         mean, deviation, m.maxError);

  const double heldNote = h->ctl[kNote], heldCents = h->ctl[kCents];
  s = (Signal){lateAttack, lowE, 0.0, 0.4, 0};
  m = feed(h, &s, 0.300, 0.0, heldNote);
  check(held(m, heldNote, heldCents),
         "re-pluck +6c for 250ms: exact 300ms attack hold, drift %.2fc, missing %u",
         m.maxError, m.missing);
  m = feed(h, &s, 0.300, 0.250, 40.0);
  check(m.firstChange >= 0.060 && m.firstChange <= 0.300 &&
        fabs(m.firstChangedMidi - 40.0) * 100.0 <= 1.5 && accurate(m, 1.5),
         "first stable re-pluck estimate snaps, not smoothed from +8c: first %.2fc at %.0fms, error %.2fc",
         (m.firstChangedMidi - 40.0) * 100.0, (0.300 + m.firstChange) * 1000.0, m.maxError);

  const double beforeAdjustment = h->ctl[kNote];
  s = (Signal){steady, lowE, 10.0, 0.4, 0};
  m = feed(h, &s, 0.250, 0.0, 40.1);
  const double response = (h->ctl[kNote] - beforeAdjustment) * 100.0;
  check(m.valid && !m.missing && response > 2.0 && response < 8.0,
         "+10c adjustment inside window at 250ms: moved %.2fc (250ms smoothing)", response);
  feed(h, &s, 0.450, 0.0, 40.1);

  const double targets[] = {40.18, 39.93, 44.93};
  for (unsigned i = 0; i < 3; ++i) {
    const double frequency = i < 2 ? lowE : 110.0;
    const double cents = i == 0 ? 18.0 : -7.0;
    const double oldNote = h->ctl[kNote], oldCents = h->ctl[kCents];
    s = (Signal){steady, frequency, cents, 0.05, 0};
    m = feed(h, &s, 0.500, 0.0, oldNote);
    check(held(m, oldNote, oldCents),
           "late %s target MIDI %.2f needs re-pluck: exact hold, drift %.2fc",
           i < 2 ? "same-string tuning" : "new string", targets[i], m.maxError);
    s = (Signal){lateAttack, frequency, cents, 0.4, 0};
    m = feed(h, &s, 0.300, 0.0, oldNote);
    check(held(m, oldNote, oldCents),
           "re-pluck target MIDI %.2f: old result held exactly through 300ms attack", targets[i]);
    m = feed(h, &s, 0.300, 0.250, targets[i]);
    check(m.firstChange >= 0.060 && m.firstChange <= 0.300 &&
          fabs(m.firstChangedMidi - targets[i]) * 100.0 <= 1.5 && accurate(m, 1.5),
           "re-pluck target MIDI %.2f: first changed estimate %.3f at %.0fms, error %.2fc",
           targets[i], m.firstChangedMidi, (0.300 + m.firstChange) * 1000.0, m.maxError);
    m = feed(h, &s, 0.600, 0.400, targets[i]);
    check(accurate(m, 1.5), "re-pluck target MIDI %.2f stays accurate after window: %.2fc",
           targets[i], m.maxError);
  }

  const int decayLatched = fabs(h->ctl[kNote] - 44.93) * 100.0 <= 1.5 && fabs(h->ctl[kCents]) > 4.0;
  s = (Signal){decay, 110.0, -7.0, 0.05, 0};
  m = feed(h, &s, 1.0, 0.8, 44.93);
  check(decayLatched && m.cleared, "decay clears note AND nonzero cents: note %.3f, cents %.3f",
        h->ctl[kNote], h->ctl[kCents]);

  s = (Signal){steady, 440.0, 0.0, 0.05, 0};
  m = feed(h, &s, 1.2, 0.8, 69.0);
  check(accurate(m, 2.0), "steady A4: worst %.2fc, missing %u", m.maxError, m.missing);
  const double a4Bias = m.weight ? m.sum / m.weight : INFINITY;
  s = (Signal){jitter, 440.0, 8.0, 0.12, 0};
  m = feed(h, &s, 0.950, 0.600, 69.08);
  const double a4Mean = m.weight ? m.sum / m.weight : INFINITY;
  const double a4Deviation = m.weight ? sqrt(fmax(0.0, m.sumSq / m.weight - a4Mean * a4Mean)) : INFINITY;
  const double a4Peak = fmax(fabs(m.minCents - a4Bias - 8.0), fabs(m.maxCents - a4Bias - 8.0));
  check(m.firstChange >= 0.300 && m.firstChange <= 0.600 &&
        m.valid && !m.missing && fabs(a4Mean - a4Bias - 8.0) < 1.0 &&
        a4Deviation < 1.25 && a4Peak < 3.0,
         "A4 early-window +/-3c / 60ms jitter around +8c: bias %.2fc, mean %.2fc, SD %.2fc, peak %.2fc",
        a4Bias, a4Mean, a4Deviation, a4Peak);
  s = (Signal){steady, 440.0, 8.0, 0.12, 0};
  m = feed(h, &s, 0.400, 0.200, 69.08);
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
  m = feed(h, &s, 0.8, 0.6, 44.91);
  check(m.firstPitch >= 0.300 && m.firstPitch <= 0.600 &&
        fabs(m.firstMidi - 44.91) * 100.0 < 2.0 && accurate(m, 2.0),
        "re-enable acquires only new 110Hz samples: first MIDI %.3f at %.0fms, error %.2fc",
        m.firstMidi, m.firstPitch * 1000.0, m.maxError);
  check(h->healthy, "finite, consistent note/cents outputs throughout tracking");
}

static void verifyAcquisition(Host* h, enum Shape shape) {
  const double lowE = 440.0 * exp2((40.0 - 69.0) / 12.0);
  const char* name = shape == lateAttack ? "late attack" :
                     shape == earlySustain ? "full-amplitude tail" : "20%-amplitude tail";
  const double target = shape == lateAttack ? 40.0 : 40.04;
  Signal s = {shape, lowE, 0.0, 0.4, 0};
  Measurement m = feed(h, &s, 0.300, 0.0, target);
  check(m.cleared, "%s: fresh pluck stays blank through 300ms, acquisitions %u", name, m.valid);
  m = feed(h, &s, 0.300, 0.250, target);
  /* Wait for the 300ms attack plus the ~110ms NSDF span before adding
   * history. Three clean frames put the first accepted estimate near 500ms. */
  check(m.firstPitch >= 0.060 && m.firstPitch <= 0.300 &&
        fabs(m.firstMidi - target) * 100.0 <= 1.5 && accurate(m, 1.5),
         "%s: accurate first output %.0fms, %.2fc from sustain; acquired by 600ms, error %.2fc",
         name, (0.300 + m.firstPitch) * 1000.0, (m.firstMidi - target) * 100.0, m.maxError);
  m = feed(h, &s, 0.050, 0.0, target);
  check(accurate(m, 1.5), "%s: early sustain target %+.0fc, error %.2fc",
         name, (target - 40.0) * 100.0, m.maxError);
  if (shape == fadedTail) {
    const double note = h->ctl[kNote], cents = h->ctl[kCents];
    m = feed(h, &s, 0.550, 0.0, note);
    check(m.rawRms > 0.003 && held(m, note, cents) && fabs(note - target) * 100.0 <= 1.5,
           "20%% tail from 650ms closes before 1s: -8c input RMS %.4f, exact +4c hold, drift %.2fc",
           m.rawRms, m.maxError);
    /* Recover only 1.5x, so this is not a new onset. The closed window
     * must not reopen just because amplitude climbs back above 25%. */
    s = (Signal){steady, lowE, -8.0, 0.12, 0};
    m = feed(h, &s, 0.500, 0.0, note);
    check(held(m, note, cents), "faded-tail latch survives non-onset amplitude recovery: drift %.2fc", m.maxError);
  } else {
    m = feed(h, &s, 0.550, 0.0, target);
    check(accurate(m, 1.5), "%s: through 1.2s, tail cannot contaminate accepted result, error %.2fc",
           name, m.maxError);
    const double note = h->ctl[kNote], cents = h->ctl[kCents];
    m = feed(h, &s, 0.800, 0.0, note);
    check(m.rawRms > 0.003 && held(m, note, cents) && fabs(note - target) * 100.0 <= 1.5,
           "%s: post-1.2s exact hold at 100%% amplitude, RMS %.4f, drift %.2fc",
           name, m.rawRms, m.maxError);
  }
  check(h->healthy, "finite, consistent acquisition outputs");
}

static void verifyAcquisitionEdges(Host* h) {
  const double lowE = 440.0 * exp2((40.0 - 69.0) / 12.0);
  Signal s = {steady, lowE, 4.0, 0.4, 0};
  Measurement m = feed(h, &s, 0.300, 0.0, 40.0);
  check(m.cleared, "+4c attack through 300ms: fresh output stays blank");
  s.cents = 0.0;
  m = feed(h, &s, 0.300, 0.250, 40.0);
  check(m.firstPitch >= 0.060 && m.firstPitch <= 0.300 &&
        fabs(m.firstMidi - 40.0) * 100.0 <= 0.5 && accurate(m, 0.5),
         "300ms attack excluded from entire NSDF span: first %.0fms, error %.3fc; clean by 600ms",
         (0.300 + m.firstPitch) * 1000.0, (m.firstMidi - 40.0) * 100.0);

  /* Reset via the public enable port; exercise every quarter-cycle onset,
   * including phase zero, where the first 10ms RMS can miss the rise gate. */
  for (unsigned phase = 0; phase < 4; ++phase) {
    h->ctl[kEnable] = 0.0f;
    s = (Signal){silence, lowE, 0.0, 0.0, 0};
    feed(h, &s, 0.100, 0.0, -1.0);
    h->ctl[kEnable] = 1.0f;
    h->phase = phase * pi / 2.0;
    s = (Signal){steady, lowE, 0.0, 0.018, 0};
    m = feed(h, &s, 0.600, 0.590, 40.0);
    check(m.rawRms >= 0.003 && m.firstPitch >= 0.300 && m.firstPitch < 0.600 &&
          fabs(m.firstMidi - 40.0) * 100.0 <= 0.5 && accurate(m, 0.5),
           "quiet fresh low E amplitude 0.018, phase %u/4: RMS %.4f, first %.0fms, error %.3fc",
           phase, m.rawRms, m.firstPitch * 1000.0, m.maxError);
  }

  s = (Signal){silence, 110.0, 0.0, 0.0, 0};
  m = feed(h, &s, 0.700, 0.500, -1.0);
  check(m.cleared, "quiet-pluck history clears through silence");
  h->phase = 0.0;
  s = (Signal){steady, 110.0, 0.0, 0.016, 0};
  m = feed(h, &s, 0.600, 0.590, 45.0);
  check(m.rawRms >= 0.003 && m.firstPitch >= 0.300 && m.firstPitch < 0.600 && accurate(m, 0.5),
        "quiet re-pluck after silence: RMS %.4f, first %.0fms, error %.3fc",
        m.rawRms, m.firstPitch * 1000.0, m.maxError);

  h->ctl[kEnable] = 0.0f;
  s = (Signal){silence, 110.0, 0.0, 0.0, 0};
  feed(h, &s, 0.100, 0.0, -1.0);
  h->ctl[kEnable] = 1.0f;
  s = (Signal){steady, 110.0, 0.0, 0.4, 0};
  m = feed(h, &s, 0.180, 0.0, 45.0);
  int blank = m.cleared;
  s.amplitude = 0.08;
  m = feed(h, &s, 0.020, 0.0, 45.0);
  blank = blank && m.cleared;
  /* Recover without a >2x rise, so acceptance proves the short dip did
   * not latch the original pluck's measurement window closed. */
  for (unsigned i = 0; i < 4; ++i) {
    s.amplitude *= 1.49;
    m = feed(h, &s, 0.020, 0.0, 45.0);
    blank = blank && m.cleared;
  }
  m = feed(h, &s, 0.320, 0.270, 45.0);
  check(blank && m.firstPitch >= 0.080 && m.firstPitch <= 0.320 &&
        fabs(m.firstMidi - 45.0) * 100.0 <= 0.5 && accurate(m, 0.5),
         "20ms dip at 180ms, 1.49x recovery steps: original pluck acquired at %.0fms, error %.3fc",
         (0.280 + m.firstPitch) * 1000.0, m.maxError);
  check(h->healthy, "finite, consistent edge-case outputs and notifications");
}

static void verifyResponsiveness(Host* h) {
  Signal s = {ramp, 110.0, 0.0, 0.4, 0};
  Measurement m = feed(h, &s, 1.200, 0.0, 45.0);
  check(m.cleared,
         "fresh +200c/sec ramp never has 3 frames within 3c: acquisitions %u", m.valid);
  const double unstableNote = h->ctl[kNote], unstableCents = h->ctl[kCents];
  s = (Signal){steady, 110.0, 240.0, 0.4, 0};
  m = feed(h, &s, 0.500, 0.0, unstableNote);
  check(unstableNote == -1.0 && unstableCents == 0.0 && m.cleared,
         "stabilizing only after closed 1s window cannot acquire without re-pluck: acquisitions %u", m.valid);
  s = (Signal){silence, 110.0, 0.0, 0.0, 0};
  feed(h, &s, 0.700, 0.0, 45.0);
  s = (Signal){fastPluck, 110.0, 0.0, 0.4, 0};
  m = feed(h, &s, 2.0, 0.0, 45.0);
  check(m.cleared, "fresh 250ms plucks never reach early sustain: acquisitions %u", m.valid);

  const double lowE = 440.0 * exp2((40.0 - 69.0) / 12.0);
  s = (Signal){silence, lowE, 0.0, 0.0, 0};
  feed(h, &s, 0.700, 0.0, 40.0);
  s = (Signal){steady, lowE, 0.0, 0.05, 0};
  m = feed(h, &s, 1.2, 0.8, 40.0);
  check(accurate(m, 2.0), "latched low E before repeated picking: error %.2fc, missing %u",
         m.maxError, m.missing);
  const double note = h->ctl[kNote], cents = h->ctl[kCents];
  s = (Signal){fastPluck, 110.0, -7.0, 0.4, 0};
  m = feed(h, &s, 2.0, 0.0, note);
  check(held(m, note, cents),
         "250ms new-string plucks preserve prior low E exactly: drift %.2fc, missing %u", m.maxError, m.missing);

  s = (Signal){steady, lowE, 0.0, 0.05, 0};
  feed(h, &s, 0.500, 0.0, note);
  s = (Signal){repeatedPluck, 110.0, -7.0, 0.4, 0};
  m = feed(h, &s, 0.600, 0.550, 44.93);
  check(m.firstChange >= 0.360 && m.firstChange <= 0.600 &&
        fabs(m.firstChangedMidi - 44.93) * 100.0 <= 1.5 && accurate(m, 1.5),
         "700ms plucks allow acquisition: first new-string estimate %.3f at %.0fms, error %.2fc",
         m.firstChangedMidi, m.firstChange * 1000.0, m.maxError);
  m = feed(h, &s, 1.500, 0.0, 44.93);
  check(accurate(m, 1.5), "700ms repeated plucks hold accepted result without tail drift/dropout: error %.2fc, missing %u",
         m.maxError, m.missing);

  const double rampNote = h->ctl[kNote], rampCents = h->ctl[kCents];
  s = (Signal){ramp, 110.0, -7.0, 0.05, 0};
  m = feed(h, &s, 3.0, 0.0, rampNote);
  check(held(m, rampNote, rampCents),
         "late +200c/sec tuning ramp for 3s stays latched until re-pluck: drift %.2fc, missing %u",
         m.maxError, m.missing);
  s = (Signal){lateAttack, 110.0, 593.0, 0.4, 0};
  m = feed(h, &s, 0.600, 0.550, 50.93);
  check(m.firstChange >= 0.360 && m.firstChange <= 0.600 &&
        fabs(m.firstChangedMidi - 50.93) * 100.0 <= 1.5 && accurate(m, 1.5),
         "re-pluck after ramp snaps to final MIDI 50.93: first %.3f at %.0fms, error %.2fc",
         m.firstChangedMidi, m.firstChange * 1000.0, m.maxError);
  check(h->healthy, "finite, consistent responsiveness outputs");
}

static void verifyNoise(Host* h) {
  Signal s = {noise, 110.0, 0.0, 0.08, 0};
  Measurement m = feed(h, &s, 3.0, 0.0, 45.0);
  check(m.rawRms > 0.02 && m.cleared,
        "deterministic noise above RMS gate never acquires: RMS %.4f, acquisitions %u",
        m.rawRms, m.valid);
  s = (Signal){steady, 440.0, 9.0, 0.4, 0};
  m = feed(h, &s, 1.2, 0.8, 69.09);
  const int latched = accurate(m, 2.0) && fabs(h->ctl[kCents]) > 4.0;
  s = (Signal){noise, 110.0, 0.0, 0.08, 0};
  m = feed(h, &s, 1.0, 0.7, 69.09);
  check(latched && m.cleared, "low-confidence noise / 8 misses clears both: note %.3f, cents %.3f",
        h->ctl[kNote], h->ctl[kCents]);
  check(h->healthy, "finite, consistent noise outputs");
}

static void verifyMissRecovery(Host* h) {
  /* Longer analysis hops cannot fit acquisition, eight misses and a clean
   * recovery span into one second. Exercise this edge on the shorter hops. */
  if (h->block / h->rate > 0.011) return;
  Signal s = {steady, 110.0, 0.0, 0.4, 0};
  Measurement m = feed(h, &s, 0.520, 0.519, 45.0);
  check(m.firstPitch >= 0.360 && m.firstPitch <= 0.520 && accurate(m, 0.5),
         "110Hz acquired before in-window misses: error %.3fc", m.maxError);
  /* Noise stays above the tail gate and near the string's filtered RMS.
   * Returning at the same amplitude must not create a replacement onset. */
  s = (Signal){noise, 110.0, 0.0, 0.32, 0};
  feed(h, &s, 0.300, 0.0, 45.0);
  s = (Signal){ramp, 110.0, 0.0, 0.4, 0};
  /* Allow the remaining noise in the NSDF span to finish the eight misses,
   * then observe every output while the original window is still eligible. */
  m = feed(h, &s, 0.040, 0.039, 45.0);
  check(m.cleared, "300ms noise plus residual analysis span clears result in-window: note %.3f, cents %.3f",
         h->ctl[kNote], h->ctl[kCents]);
  m = feed(h, &s, 0.140, 0.0, 45.0);
  check(m.cleared,
         "after 8 misses, in-window ramp needs 3 new agreeing frames: reacquisitions %u", m.valid);
  check(h->healthy, "finite, consistent miss-recovery outputs and notifications");
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
      const enum Shape shapes[] = {lateAttack, earlySustain, fadedTail};
      for (unsigned i = 0; i < 3; ++i) {
        if (openHost(h, d, rates[r], blocks[b])) {
          verifyAcquisition(h, shapes[i]);
          closeHost(h);
        }
      }
      if (openHost(h, d, rates[r], blocks[b])) {
        verifyAcquisitionEdges(h);
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
      if (openHost(h, d, rates[r], blocks[b])) {
        verifyMissRecovery(h);
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
