/* Minimal LV2 host smoke test for the BUILT rig plugin (.so path = argv[1]):
 *   - instantiate with urid:map + worker:schedule, connect all 30 ports,
 *     run blocks both smaller and LARGER than the un-negotiated 512 default
 *     maxBlockLength (the chain must slice, not overrun).
 *   - latency port must read 0 with no models loaded.
 *   - toggling cab_enabled mid-stream must ride the 5 ms fade: the
 *     sample-to-sample output/input gain step stays small, never a hard jump.
 * Plain C so it builds with clang even where the C++ toolchain is broken.
 */
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lv2/core/lv2.h>
#include <lv2/atom/atom.h>
#include <lv2/urid/urid.h>
#include <lv2/worker/worker.h>

static char* uris[256];
static uint32_t nUris = 0;
static LV2_URID mapUri(LV2_URID_Map_Handle h, const char* uri) {
  (void)h;
  for (uint32_t i = 0; i < nUris; ++i)
    if (!strcmp(uris[i], uri)) return i + 1;
  uris[nUris] = strdup(uri);
  return ++nUris;
}

static LV2_Worker_Status scheduleWork(LV2_Worker_Schedule_Handle h,
                                      uint32_t size, const void* data) {
  (void)h; (void)size; (void)data;
  return LV2_WORKER_SUCCESS;  /* no model loads in this test */
}

static int fails = 0;
#define CHECK(cond, msg)                                   \
  do {                                                     \
    if (cond) printf("  PASS  %s\n", msg);                 \
    else { ++fails; printf("  FAIL  %s\n", msg); }         \
  } while (0)

int main(int argc, char** argv) {
  if (argc < 2) { printf("usage: verify_host_smoke <rig .so>\n"); return 1; }
  void* lib = dlopen(argv[1], RTLD_NOW);
  if (!lib) { printf("  FAIL  dlopen: %s\n", dlerror()); return 1; }
  const LV2_Descriptor* (*desc_fn)(uint32_t) =
      (const LV2_Descriptor* (*)(uint32_t))dlsym(lib, "lv2_descriptor");
  const LV2_Descriptor* d = desc_fn(0);

  LV2_URID_Map map = {NULL, mapUri};
  LV2_Worker_Schedule sched = {NULL, scheduleWork};
  LV2_Feature fMap = {LV2_URID__map, &map};
  LV2_Feature fSched = {LV2_WORKER__schedule, &sched};
  const LV2_Feature* features[] = {&fMap, &fSched, NULL};

  LV2_Handle h = d->instantiate(d, 48000.0, "", features);
  CHECK(h != NULL, "instantiate at 48 kHz");
  if (!h) return 1;

  enum { kMax = 4096, kAtom = 16384 };
  static uint8_t controlBuf[kAtom], notifyBuf[kAtom];
  static float inBuf[kMax], outBuf[kMax];
  float ctl[30] = {0};
  ctl[7] = 1.0f; ctl[8] = 1.0f; ctl[9] = 1.0f; ctl[10] = 1.0f; /* enables */
  ctl[20] = 1.0f; ctl[21] = 1.0f;   /* per-stage oversample: Legacy */
  ctl[15] = -80.0f;                  /* gate off */
  ctl[23] = 150.0f;                  /* gate release */
  ctl[27] = 20000.0f;                /* high cut off */

  d->connect_port(h, 0, controlBuf);
  d->connect_port(h, 1, notifyBuf);
  d->connect_port(h, 2, inBuf);
  d->connect_port(h, 3, outBuf);
  for (uint32_t p = 4; p < 30; ++p) d->connect_port(h, p, &ctl[p]);

  double phase = 0.0;
  const double w = 2.0 * M_PI * 220.0 / 48000.0;
  int finite = 1;
  double worstStep = 0.0;
  float prevOut = 0.0f, prevIn = 0.0f;
  long sample = 0;

  const uint32_t sizes[4] = {64, 512, 2048, 4096};
  for (int b = 0; b < 300; ++b) {
    const uint32_t n = sizes[b % 4];
    if (b > 0 && b % 50 == 0) ctl[9] = ctl[9] > 0.5f ? 0.0f : 1.0f;
    LV2_Atom_Sequence* seq = (LV2_Atom_Sequence*)controlBuf;
    seq->atom.size = sizeof(LV2_Atom_Sequence_Body);
    seq->atom.type = mapUri(NULL, LV2_ATOM__Sequence);
    ((LV2_Atom_Sequence*)notifyBuf)->atom.size = kAtom - sizeof(LV2_Atom);
    for (uint32_t i = 0; i < n; ++i) {
      inBuf[i] = (float)(0.5 * sin(phase));
      phase += w;
    }
    d->run(h, n);
    for (uint32_t i = 0; i < n; ++i) {
      if (!isfinite(outBuf[i])) finite = 0;
      if (sample > 480 && fabsf(prevIn) > 0.2f && fabsf(inBuf[i]) > 0.2f) {
        const double step = fabs(outBuf[i] / inBuf[i] - prevOut / prevIn);
        if (step > worstStep) worstStep = step;
      }
      prevOut = outBuf[i]; prevIn = inBuf[i];
      ++sample;
    }
  }
  CHECK(finite, "output finite through 300 blocks incl. 2048/4096 (> 512 default)");
  CHECK(ctl[29] == 0.0f, "latency port reads 0 with no True stages");
  char msg[128];
  snprintf(msg, sizeof(msg),
           "cab toggles ride the fade: worst per-sample gain step %.4f < 0.05",
           worstStep);
  CHECK(worstStep < 0.05, msg);

  d->cleanup(h);
  printf(fails ? "\nFAILED (%d)\n" : "\nALL PASSED (0 failures)\n", fails);
  return fails ? 1 : 0;
}
