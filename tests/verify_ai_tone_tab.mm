// Verify the AI Tone Matcher static tab instantiation, layout, and tab switching.
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <cassert>
#include <iostream>
#include <lv2/core/lv2.h>
#include <lv2/ui/ui.h>
#include <lv2/urid/urid.h>
#include "rig_ui_state.h"

static char* sUris[512];
static uint32_t sNumUris = 0;
static LV2_URID testMap(LV2_URID_Map_Handle, const char* uri) {
  for (uint32_t i = 0; i < sNumUris; ++i) {
    if (!strcmp(sUris[i], uri)) return i + 1;
  }
  sUris[sNumUris] = strdup(uri);
  return ++sNumUris;
}

int main(int argc, char** argv) {
  @autoreleasepool {
    [NSApplication sharedApplication];

    const char* dylibPath = (argc > 1) ? argv[1] : "build/src/neural_amp_modeler_rig_ui.so";
    void* handle = dlopen(dylibPath, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
      std::cerr << "Failed to dlopen UI shared library: " << dlerror() << std::endl;
      return 1;
    }

    auto descFn = (const LV2UI_Descriptor* (*)(uint32_t))dlsym(handle, "lv2ui_descriptor");
    if (!descFn) {
      std::cerr << "Failed to dlsym lv2ui_descriptor" << std::endl;
      return 1;
    }

    const LV2UI_Descriptor* desc = descFn(0);
    assert(desc != nullptr);

    LV2_URID_Map mapFeature = {nullptr, testMap};
    LV2_Feature mapF = {LV2_URID__map, &mapFeature};

    NSView* parentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1520, 980)];
    LV2_Feature parentF = {LV2_UI__parent, (__bridge void*)parentView};

    const LV2_Feature* features[] = {&mapF, &parentF, nullptr};

    LV2UI_Widget widget = nullptr;

    LV2UI_Handle uiHandle = desc->instantiate(desc,
                                             "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig",
                                             "build",
                                             [](LV2UI_Controller, uint32_t, uint32_t, uint32_t, const void*) {},
                                             (LV2UI_Controller)0x1234,
                                             &widget,
                                             features);

    assert(uiHandle != nullptr);
    assert(widget != nullptr);

    RigUIState* state = (RigUIState*)uiHandle;
    assert(state->rigPane != nil);
    assert(state->tonePane != nil);
    assert(state->aiPane != nil);
    assert(state->rigTabBtn != nil);
    assert(state->toneTabBtn != nil);
    assert(state->aiTabBtn != nil);

    // Initial state: tab 0 (Rig)
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    assert(!state->rigPane.isHidden);
    assert(state->tonePane.isHidden);
    assert(state->aiPane.isHidden);

    // Switch to tab 1 (Tone3000)
    state->selectTab(1);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    assert(state->rigPane.isHidden);
    assert(!state->tonePane.isHidden);
    assert(state->aiPane.isHidden);

    // Switch to tab 2 (AI Tone Matcher static page)
    state->selectTab(2);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    assert(state->rigPane.isHidden);
    assert(state->tonePane.isHidden);
    assert(!state->aiPane.isHidden);

    // Verify subviews inside aiPane:
    // Subviews should include: Title, Subtitle, Badge, EngineStrip, Card1, Card2, Card3
    int panelCount = 0;
    for (NSView* sub in state->aiPane.subviews) {
      if ([sub isKindOfClass:NSClassFromString(@"RigPanel")]) {
        panelCount++;
      }
    }
    std::cout << "aiPane subviews verified: panelCount=" << panelCount << std::endl;
    // 1 engineStrip + 3 cards = 4 RigPanels
    assert(panelCount == 4);

    // Clean up
    desc->cleanup(uiHandle);

    std::cout << "PASS verify_ai_tone_tab: static AI Tone Matcher tab and switching fully verified!" << std::endl;
    return 0;
  }
}
