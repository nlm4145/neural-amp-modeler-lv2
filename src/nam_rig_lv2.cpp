#include <cfenv>
#include <cstring>
#include <memory>

#include <lv2/core/lv2.h>
#include <lv2/options/options.h>
#include <lv2/state/state.h>
#include <lv2/worker/worker.h>

#include "architecture.hpp"
#include "nam_rig_plugin.h"
#include "rt_worker_pool.h"

static LV2_Handle instantiate(const LV2_Descriptor*,
                              double rate,
                              const char*,
                              const LV2_Feature* const* features) {
  try {
    auto rig = std::make_unique<NAMRig::Plugin>();
    if (!rig->initialize(rate, features)) return nullptr;
    rig->setRealtimeJobDispatcher(NAMRig::sharedRealtimeJobDispatcher());
    rig->setMultiCoreEnabled(true);
    return static_cast<LV2_Handle>(rig.release());
  } catch (...) {
    return nullptr;
  }
}

static void connectPort(LV2_Handle instance, uint32_t port, void* data) {
  auto* rig = static_cast<NAMRig::Plugin*>(instance);
  *(reinterpret_cast<void**>(&rig->ports) + port) = data;
}

static void run(LV2_Handle instance, uint32_t sampleCount) {
#ifdef DISABLE_DENORMALS
  std::fenv_t state;
  std::feholdexcept(&state);
  disable_denormals();
#endif
  static_cast<NAMRig::Plugin*>(instance)->process(sampleCount);
#ifdef DISABLE_DENORMALS
  std::feupdateenv(&state);
#endif
}

static void cleanup(LV2_Handle instance) {
  delete static_cast<NAMRig::Plugin*>(instance);
}

static const void* extensionData(const char* uri) {
  static const LV2_Options_Interface options{NAMRig::Plugin::optionsGet, NAMRig::Plugin::optionsSet};
  static const LV2_State_Interface state{NAMRig::Plugin::save, NAMRig::Plugin::restore};
  static const LV2_Worker_Interface worker{NAMRig::Plugin::work, NAMRig::Plugin::workResponse, nullptr};
  if (!std::strcmp(uri, LV2_OPTIONS__interface)) return &options;
  if (!std::strcmp(uri, LV2_STATE__interface)) return &state;
  if (!std::strcmp(uri, LV2_WORKER__interface)) return &worker;
  return nullptr;
}

static const LV2_Descriptor descriptor{
    NAM_RIG_URI, instantiate, connectPort, nullptr, run, nullptr, cleanup, extensionData};

LV2_SYMBOL_EXPORT const LV2_Descriptor* lv2_descriptor(uint32_t index) {
  return index == 0 ? &descriptor : nullptr;
}
