// Runtime test of the built UI, not a source-contract or a recompiled UI copy.
// From the repository root (macOS, with a WindowServer session):
// clang++ -std=c++20 -fobjc-arc -Isrc -Ideps/lv2/include \
//   tests/verify_transformer_ui.mm src/rig_knobs.cpp src/rig_theme.mm -framework Cocoa \
//   -framework QuartzCore -framework CoreImage \
//   -o "$TMPDIR/verify_transformer_ui"
// "$TMPDIR/verify_transformer_ui" \
//   build-test/src/neural_amp_modeler_rig_ui.so
#include "rig_ui_state.h"
#include <dlfcn.h>
#include <unistd.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <cstdio>
#include <limits>
#include <stdexcept>
#include <thread>
#include <unordered_map>

@protocol TransformerTestController <NSTextFieldDelegate>
- (void)showAmpAdvanced:(id)sender;
- (void)resetAllKnobs:(id)sender;
- (void)abTimerFired:(NSTimer*)timer;
@end

static NSString* testRoot;
static const char* stage = "setup";
static int checks = 0, failures = 0;
static NSInteger testedPort = -1;
static RigUIState* saveState = nullptr;
static RigPreset* savedByShortcut;
static int saveCalls = 0, saveAsCalls = 0;
static NSEvent* (^installedKeyHandler)(NSEvent*);
static IMP originalAddMonitor;
static NSWindow* __weak syntheticKeyWindow;
static bool syntheticShortcutFocus = false;
static int slotSaveDialogs = 0, slotDeleteDialogs = 0;
static int powerTubeSaveDialogs = 0;

static bool check(bool condition, const char* expression, int line) {
  ++checks;
  if (!condition) {
    ++failures;
    std::fprintf(stderr, "FAIL [%s, port %ld] line %d: %s\n",
                 stage, (long)testedPort, line, expression);
  }
  return condition;
}
#define CHECK(...) check((__VA_ARGS__), #__VA_ARGS__, __LINE__)
#define REQUIRE(...) do { if (!CHECK(__VA_ARGS__)) throw std::runtime_error(#__VA_ARGS__); } while (0)

static NSModalResponse slotPresetDialog(id alertObject, SEL) {
  NSAlert* alert = (NSAlert*)alertObject;
  const bool transformer = [alert.messageText isEqualToString:@"Save Output Transformer Preset"];
  const bool powerTube = [alert.messageText isEqualToString:@"Save Power Tube Character Preset"];
  if (transformer || powerTube) {
    ++slotSaveDialogs;
    if (powerTube) ++powerTubeSaveDialogs;
    REQUIRE([alert.accessoryView isKindOfClass:NSTextField.class]);
    ((NSTextField*)alert.accessoryView).stringValue = transformer ? @"Menu Saved Transformer"
        : (powerTubeSaveDialogs == 1 ? @"Menu Saved Power Tube" : @"Menu Saved Power Tube As");
  } else {
    REQUIRE([alert.messageText isEqualToString:@"Delete Slot Preset"]);
    ++slotDeleteDialogs;
  }
  return NSAlertFirstButtonReturn;
}

static bool near(double a, double b) {
  return std::isfinite(a) && std::isfinite(b) &&
      std::fabs(a - b) <= 2.0e-5 * std::max(1.0, std::fabs(b));
}

static void drain() {
  [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
}

static NSString* presetsDirectory(id, SEL) {
  NSString* path = [testRoot stringByAppendingPathComponent:@"Presets"];
  [[NSFileManager defaultManager] createDirectoryAtPath:path
      withIntermediateDirectories:YES attributes:nil error:nil];
  return path;
}
static NSString* currentPresetPath(id, SEL) {
  return [testRoot stringByAppendingPathComponent:@"current-preset.txt"];
}
static void skip(id, SEL) {}
static void skipOne(id, SEL, id) {}
static void skipThree(id, SEL, id, id, id) {}
static void skipPreferenceWrite(id, SEL, id, id) {}
static BOOL keyWindowForTest(id window, SEL) { return window == syntheticKeyWindow; }

static id captureKeyMonitor(id cls, SEL selector, NSEventMask mask,
                           NSEvent* (^handler)(NSEvent*)) {
  installedKeyHandler = [handler copy];
  return reinterpret_cast<id (*)(id, SEL, NSEventMask, NSEvent* (^)(NSEvent*))>(
      originalAddMonitor)(cls, selector, mask, handler);
}

static void recordSave(id, SEL selector, id) {
  if (selector == @selector(saveCurrentPreset:)) ++saveCalls;
  else ++saveAsCalls;
  REQUIRE(saveState);
  for (bool editing : saveState->transformerFieldEditing) CHECK(!editing);
  savedByShortcut = [NSClassFromString(@"RigPreset") captureFromState:saveState name:@"Shortcut Capture"];
}

static void replace(Class cls, SEL selector, IMP implementation, bool classMethod = false) {
  REQUIRE(cls != Nil);
  Method method = classMethod ? class_getClassMethod(cls, selector)
                             : class_getInstanceMethod(cls, selector);
  REQUIRE(method != nullptr);
  method_setImplementation(method, implementation);
}

struct Host {
  std::unordered_map<std::string, LV2_URID> urids;
  std::unordered_map<uint32_t, std::vector<float>> writes;
};
static LV2_URID mapURI(LV2_URID_Map_Handle handle, const char* uri) {
  auto& ids = static_cast<Host*>(handle)->urids;
  return ids.emplace(uri, static_cast<LV2_URID>(ids.size() + 1)).first->second;
}
static void recordWrite(LV2UI_Controller controller, uint32_t port,
                        uint32_t size, uint32_t format, const void* buffer) {
  if (format == 0 && size == sizeof(float) && buffer)
    static_cast<Host*>(controller)->writes[port].push_back(*static_cast<const float*>(buffer));
}

static void trimWrites(const Host& host, const NAMRig::TransformerAdjustments& trims) {
  for (size_t i = 0; i < trims.size(); ++i) {
    const auto found = host.writes.find(NAMRig::kTransformerControlFirstPort + i);
    CHECK(found != host.writes.end() && !found->second.empty() && near(found->second.back(), trims[i]));
  }
}

struct Runtime {
  const LV2UI_Descriptor* descriptor = nullptr;
  RigUIState* state = nullptr;
  NSWindow* __strong window = nil;
  ~Runtime() {
    if (state) {
      [state->transformerPopover close];
      descriptor->cleanup(state);
      drain(); // Exercise queued updates after teardown as well.
    }
    [window orderOut:nil];
  }
};

static void action(NSControl* control) {
  REQUIRE(control && control.target && control.action);
  REQUIRE([control sendAction:control.action to:control.target]);
}

static NSTextView* edit(RigUIState* state, size_t index, NSString* text) {
  testedPort = NAMRig::kTransformerControlFirstPort + index;
  NSTextField* field = state->transformerFields[index];
  REQUIRE(field && field.window && field.isEnabled);
  [field.window makeKeyAndOrderFront:nil];
  [field selectText:nil];
  NSTextView* editor = (NSTextView*)field.currentEditor;
  REQUIRE([editor isKindOfClass:NSTextView.class]);
  REQUIRE(field.window.firstResponder == editor);
  [editor insertText:text replacementRange:NSMakeRange(0, editor.string.length)];
  REQUIRE(state->transformerFieldEditing[index]);
  REQUIRE([editor.string isEqualToString:text]);
  return editor;
}

static NSString* valueText(size_t i, float v) {
  if (i == 6 || i == 9) return [NSString stringWithFormat:@"%+.2f dB", v];
  if (i == 3) return [NSString stringWithFormat:@"%.1f%%", v];
  if (i == 2) return [NSString stringWithFormat:@"%.2fx", v];
  if (i == 7 || i == 10) return [NSString stringWithFormat:@"%.2f", v];
  return [NSString stringWithFormat:@"%.0f Hz", v];
}

static void telemetry(RigUIState* state, const NAMRig::TransformerAdjustments& trims) {
  using Transformer = NAMRig::OutputTransformer;
  const auto p = Transformer::parametersForProfile(state->transformerProfile, trims);
  REQUIRE(state->transformerVisualizer);
  CHECK(state->transformerVisualizer.profile == state->transformerProfile);
  const auto expected = Transformer::controlValues(p);
  const auto actual = Transformer::controlValues(state->transformerVisualizer.parameters);
  for (size_t i = 0; i < expected.size(); ++i) {
    CHECK(near(actual[i], expected[i]));
    if (state->transformerSliders[i]) {
      const bool log = NAMRig::kTransformerControls[i].logarithmic;
      CHECK(near(state->transformerSliders[i].doubleValue,
                 log ? std::log(expected[i]) : expected[i]));
    }
    if (state->transformerFields[i] && !state->transformerFieldEditing[i])
      CHECK([state->transformerFields[i].stringValue isEqualToString:valueText(i, expected[i])]);
  }
  NSArray<NSString*>* labels = state->transformerProfile == 0
      ? @[@"Linear (Captured)", @"0% (Transparent)", @"Flat (0.0 dB)", @"None (0.0 dB)"]
      : @[[NSString stringWithFormat:@"%.0f Hz - %.1f kHz", p.lowCutHz, p.highCutHz / 1000.0],
          [NSString stringWithFormat:@"%.2fx / %.0f%% Mix", p.drive, p.saturationMix * 100.0],
          [NSString stringWithFormat:@"%+.1f dB @ %.2f kHz", p.voiceDb, p.voiceHz / 1000.0],
          [NSString stringWithFormat:@"%+.1f dB @ %.2f kHz", p.leakageDb, p.leakageHz / 1000.0]];
  for (size_t i = 0; i < 4; ++i) {
    REQUIRE(state->transformerSpecLabels[i]);
    CHECK([state->transformerSpecLabels[i].stringValue isEqualToString:labels[i]]);
  }
}

static void snapshot(RigUIState* state, Class presetClass,
                     const NAMRig::TransformerAdjustments& trims, bool modified) {
  RigPreset* preset = [presetClass captureFromState:state name:@"Immediate Capture"];
  CHECK(near([preset controlForPort:30], state->transformerProfile));
  CHECK(near([preset stageAtIndex:1]->transformer, state->transformerProfile));
  for (size_t i = 0; i < trims.size(); ++i) {
    const uint32_t port = NAMRig::kTransformerControlFirstPort + i;
    CHECK(near(state->transformerAdjustments[i], trims[i]));
    CHECK([preset allControls].count(port) == 1);
    CHECK(near([preset controlForPort:port], trims[i]));
    if (modified) CHECK(near([state->abModifiedPreset controlForPort:port], trims[i]));
  }
  if (modified) CHECK(state->presetManager.isModified && state->abModifiedPreset);
}

// Graph pins: each frequency graph hosts an editor whose edits reach the host,
// the logical state, preset capture and recall; host echoes update the editor.
static void verifyPinEditors(Runtime& runtime, Host& host, Class presetClass) {
  using namespace NAMRig;
  RigUIState* state = runtime.state;
  stage = "graph pin editors / wiring";
  REQUIRE(state->sculptVisualizer && state->transformerVisualizer && state->cabConsoleVisualizer);
  CHECK(state->pinEditors[(size_t)PinEqPane::Sculpt] == state->sculptVisualizer.pinEditor);
  CHECK(state->pinEditors[(size_t)PinEqPane::Transformer] == state->transformerVisualizer.pinEditor);
  CHECK(state->pinEditors[(size_t)PinEqPane::CabConsole] == state->cabConsoleVisualizer.pinEditor);
  for (size_t pane = 0; pane < kPinEqPaneCount; ++pane) {
    NAMPinEQEditor* editor = state->pinEditors[pane];
    REQUIRE(editor && editor.onChange && editor.onCommit);
    CHECK(editor.pane == (PinEqPane)pane);
  }
  CHECK(state->sculptVisualizer.pinEditor.superview == state->sculptVisualizer);

  stage = "graph pin editors / double-click add writes a bell";
  [runtime.window layoutIfNeeded];
  NAMPinEQEditor* console = state->pinEditors[(size_t)PinEqPane::CabConsole];
  const NSRect b = console.bounds;
  REQUIRE(b.size.width > 40 && b.size.height > 20);
  host.writes.clear();
  // Center of the plot is 632 Hz (log midpoint of 20 Hz..20 kHz) at 0 dB; aim above it.
  const NSPoint at = NSMakePoint(NSMidX(b), NSMidY(b) + (b.size.height * 0.5 - kPinEditorInset) * 0.5);
  ((void (*)(id, SEL, NSPoint))objc_msgSend)(console, sel_registerName("addPinAt:"), at);
  const uint32_t shape = pinEqPort(PinEqPane::CabConsole, 0, kPinShape);
  const uint32_t freq = pinEqPort(PinEqPane::CabConsole, 0, kPinFreq);
  const uint32_t gain = pinEqPort(PinEqPane::CabConsole, 0, kPinGain);
  REQUIRE(!host.writes[shape].empty() && !host.writes[freq].empty() && !host.writes[gain].empty());
  CHECK(host.writes[shape].back() == kPinBell);
  CHECK(std::fabs(host.writes[freq].back() - 632.5f) < 15.0f);
  CHECK(std::fabs(host.writes[gain].back() - kPinGainMax * 0.5f) < 0.5f);
  CHECK(state->pinEqControls[shape - kPinEqFirstPort] == kPinBell);
  CHECK(state->presetManager.isModified);

  stage = "graph pin editors / preset capture, host echo and recall";
  RigPreset* captured = [presetClass captureFromState:state name:@"Pins"];
  CHECK([captured controlForPort:shape] == kPinBell);
  CHECK(near([captured controlForPort:gain], host.writes[gain].back()));
  const uint32_t sculptGain = pinEqPort(PinEqPane::Sculpt, 3, kPinGain);
  const float echoed = -7.5f;
  runtime.descriptor->port_event(state, sculptGain, sizeof(echoed), 0, &echoed);
  drain();
  CHECK(state->pinEqControls[sculptGain - kPinEqFirstPort] == echoed);
  const float wild = 99.0f;  // host values are clamped to the pin range
  runtime.descriptor->port_event(state, sculptGain, sizeof(wild), 0, &wild);
  drain();
  CHECK(state->pinEqControls[sculptGain - kPinEqFirstPort] == kPinGainMax);
  host.writes.clear();
  [[presetClass defaultPreset] applyToState:state];
  drain();
  for (uint32_t i = 0; i < kPinEqPortCount; ++i) {
    const uint32_t port = kPinEqFirstPort + i;
    CHECK(near(state->pinEqControls[i], pinEqDefault(port)));
    CHECK(!host.writes[port].empty() && near(host.writes[port].back(), pinEqDefault(port)));
  }
  [captured applyToState:state];
  drain();
  CHECK(state->pinEqControls[shape - kPinEqFirstPort] == kPinBell);
  [[presetClass defaultPreset] applyToState:state];
  drain();
}

static void verifyRackSwitches(Runtime& runtime, Host& host, Class presetClass) {
  using namespace NAMRig;
  RigUIState* state = runtime.state;
  auto echo = [&](uint32_t port, float value) {
    runtime.descriptor->port_event(state, port, sizeof(value), 0, &value);
  };
  auto values = [&](const std::array<float, kRackCount>& expected, bool writes) {
    RigPreset* captured = [presetClass captureFromState:state name:@"Rack Capture"];
    for (size_t i = 0; i < kRackCount; ++i) {
      testedPort = kRackControlFirstPort + i;
      CHECK(state->rackControls[i] == expected[i]);
      REQUIRE(state->rackButtons[i]);
      CHECK(state->rackButtons[i].state == (expected[i] ? NSControlStateValueOn : NSControlStateValueOff));
      CHECK([state->rackButtons[i].title isEqualToString:(expected[i] ? @"ON" : @"OFF")]);
      CHECK([captured allControls].count((uint32_t)testedPort) == 1);
      CHECK([captured controlForPort:(uint32_t)testedPort] == expected[i]);
      if (writes) {
        const auto& sent = host.writes[(uint32_t)testedPort];
        CHECK(sent.size() == 1 && sent.back() == expected[i]);
      }
    }
  };

  stage = "rack switches / real clicks / unchanged pane settings";
  echo(kPowerTubeTypePort, PowerTube::kEL34);
  echo(kPowerTubeCharacterPort, 63.5f);
  std::array<float, kRackCount> expected = kRackControlDefaults;
  values(expected, false);
  constexpr std::array<NSInteger, kRackCount> tabs = {0, 0, 0, 1, 1, 1, 2, 2, 1};
  for (size_t i = 0; i < kRackCount; ++i) {
    state->selectDeckTab(tabs[i]);
    drain();
    [runtime.window.contentView layoutSubtreeIfNeeded];
    RigButton* button = state->rackButtons[i];
    REQUIRE(button);
    CHECK(button.tag == (NSInteger)(kRackControlFirstPort + i));
    CHECK(button.target == (id)state->uiController);
    CHECK(button.action == NSSelectorFromString(@"controlChanged:"));
    CHECK(button.isEnabled && !button.isHiddenOrHasHiddenAncestor);
    CHECK(button.frame.size.width > 0 && button.frame.size.height > 0);
    RigPreset* before = [presetClass captureFromState:state name:@"Before Toggle"];
    for (float enabled : {0.0f, 1.0f}) {
      host.writes.clear();
      [button performClick:nil];
      expected[i] = enabled;
      CHECK(host.writes.size() == 1);
      CHECK(host.writes[kRackControlFirstPort + i].size() == 1);
      REQUIRE(!host.writes[kRackControlFirstPort + i].empty());
      CHECK(host.writes[kRackControlFirstPort + i].back() == enabled);
      values(expected, false); // Immediate capture must not need a run-loop drain.
      REQUIRE(state->abModifiedPreset);
      CHECK(state->presetManager.isModified);
      CHECK([state->abModifiedPreset controlForPort:kRackControlFirstPort + i] == enabled);
      RigPreset* after = [presetClass captureFromState:state name:@"After Toggle"];
      for (const auto& entry : [before allControls])
        if (entry.first < kRackControlFirstPort ||
            entry.first >= kRackControlFirstPort + kRackCount)
          CHECK(near([after controlForPort:entry.first], entry.second));
      for (NSSlider* knob : state->deckKnobs)
        if (knob) CHECK(knob.isEnabled);
    }
  }

  stage = "rack host echoes / no feedback writes";
  host.writes.clear();
  std::thread automation([&] {
    for (size_t i = 0; i < kRackCount; ++i) echo(kRackControlFirstPort + i, i % 2 ? 1 : 0);
  });
  automation.join();
  drain();
  for (size_t i = 0; i < kRackCount; ++i) expected[i] = i % 2 ? 1 : 0;
  values(expected, false);
  CHECK(host.writes.empty());
  const float rejected = 0;
  runtime.descriptor->port_event(state, kRackControlFirstPort, sizeof(rejected) - 1, 0, &rejected);
  runtime.descriptor->port_event(state, kRackControlFirstPort, sizeof(rejected), 1, &rejected);
  runtime.descriptor->port_event(state, kRackControlFirstPort, sizeof(rejected), 0, nullptr);
  runtime.descriptor->port_event(state, kRigControlPortCount, sizeof(rejected), 0, &rejected);
  values(expected, false);
  CHECK(host.writes.empty());

  stage = "rack rig save / load / named and numeric persistence";
  RigPreset* saved = [presetClass captureFromState:state name:@"Rack Runtime"];
  NSString* file = [testRoot stringByAppendingPathComponent:@"rack-roundtrip.json"];
  REQUIRE([saved saveToFile:file error:nil]);
  NSDictionary* json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:file]
      options:NSJSONReadingMutableContainers error:nil];
  REQUIRE(json);
  for (size_t i = 0; i < kRackCount; ++i) {
    NSString* number = [NSString stringWithFormat:@"%u", kRackControlFirstPort + (uint32_t)i];
    NSString* symbol = [NSString stringWithUTF8String:kRackControlSymbols[i]];
    REQUIRE(json[@"ports"][number] && json[@"params"][symbol]);
    CHECK([json[@"ports"][number] floatValue] == expected[i]);
    CHECK([json[@"params"][symbol] floatValue] == expected[i]);
  }
  RigPreset* loaded = [presetClass loadFromFile:file];
  REQUIRE(loaded);
  [((RigPreset*)[presetClass defaultPreset]) applyToState:state];
  host.writes.clear();
  [loaded applyToState:state];
  values(expected, true);

  stage = "rack reset / A-B persistence";
  host.writes.clear();
  [(id<TransformerTestController>)state->uiController resetAllKnobs:nil];
  values(kRackControlDefaults, true);
  state->abModifiedPreset = loaded;
  state->abNameA = @"Default Rig";
  state->abNameB = RigUIState::abModifiedToken();
  state->abShowingA = true;
  state->abCycling = true;
  host.writes.clear();
  [(id<TransformerTestController>)state->uiController abTimerFired:nil];
  CHECK(!state->abShowingA && !state->abApplyingCycle);
  state->abCycling = false;
  values(expected, true);

  stage = "rack named-symbol load overrides numeric ports";
  NSMutableDictionary* symbolic = [json mutableCopy];
  NSMutableDictionary* numericPorts = [symbolic[@"ports"] mutableCopy];
  for (size_t i = 0; i < kRackCount; ++i)
    numericPorts[[NSString stringWithFormat:@"%u", kRackControlFirstPort + (uint32_t)i]] = @(1 - expected[i]);
  symbolic[@"ports"] = numericPorts;
  NSString* symbolicFile = [testRoot stringByAppendingPathComponent:@"rack-symbols.json"];
  REQUIRE([[NSJSONSerialization dataWithJSONObject:symbolic options:0 error:nil]
      writeToFile:symbolicFile atomically:YES]);
  RigPreset* symbolicPreset = [presetClass loadFromFile:symbolicFile];
  REQUIRE(symbolicPreset);
  host.writes.clear();
  [symbolicPreset applyToState:state];
  values(expected, true);

  stage = "rack legacy / sparse / factory defaults enabled";
  NSMutableDictionary* legacy = [json mutableCopy];
  for (NSString* key in @[@"ports", @"params"]) {
    NSMutableDictionary* entries = [legacy[key] mutableCopy];
    for (size_t i = 0; i < kRackCount; ++i) {
      NSString* name = [key isEqualToString:@"ports"]
          ? [NSString stringWithFormat:@"%u", kRackControlFirstPort + (uint32_t)i]
          : [NSString stringWithUTF8String:kRackControlSymbols[i]];
      [entries removeObjectForKey:name];
    }
    legacy[key] = entries;
  }
  NSString* legacyFile = [testRoot stringByAppendingPathComponent:@"rack-legacy.json"];
  REQUIRE([[NSJSONSerialization dataWithJSONObject:legacy options:0 error:nil]
      writeToFile:legacyFile atomically:YES]);
  RigPreset* legacyPreset = [presetClass loadFromFile:legacyFile];
  REQUIRE(legacyPreset);
  RigPreset* sparse = [[presetClass alloc] init];
  RigPreset* factory = [presetClass defaultPreset];
  for (RigPreset* preset in @[legacyPreset, sparse, factory]) {
    [loaded applyToState:state];
    host.writes.clear();
    [preset applyToState:state];
    values(kRackControlDefaults, true);
  }

  stage = "rack slot capture / disk persistence / apply";
  for (size_t i = 0; i < kRackCount; ++i) {
    NSString* key = [NSString stringWithUTF8String:kRackSlotKeys[i]];
    NSInteger slot = -1;
    for (NSUInteger n = 0; n < state->deckSlotSpecs.count; ++n)
      if ([state->deckSlotSpecs[n][@"key"] isEqualToString:key]) slot = (NSInteger)n;
    REQUIRE(slot >= 0);
    const uint32_t rackPort = kRackControlFirstPort + (uint32_t)i;
    NSString* number = [NSString stringWithFormat:@"%u", rackPort];
    echo(rackPort, 0);
    // Non-default values expose deferred main-thread updates: capture and
    // recall below intentionally never pump the run loop.
    std::unordered_map<uint32_t, float> edited;
    for (NSNumber* entry in state->deckSlotSpecs[(NSUInteger)slot][@"ports"]) {
      const uint32_t controlPort = entry.unsignedIntValue;
      if (controlPort == 42) edited[controlPort] = SpeakerDynamics::kModern412;
      if (controlPort == 59) edited[controlPort] = 1;
      if (controlPort == kPowerTubeTypePort) edited[controlPort] = PowerTube::kEL34;
      for (size_t k = 0; k < kRigKnobCount; ++k) {
        if (kRigKnobPorts[k] != controlPort) continue;
        NSSlider* knob = state->deckKnobs[k] ?: state->knobs[k];
        REQUIRE(knob);
        edited[controlPort] = (float)(knob.minValue + .65 * (knob.maxValue - knob.minValue));
      }
    }
    for (const auto& entry : edited) echo(entry.first, entry.second);
    NSDictionary* captured = state->captureSlotPortValues(slot);
    REQUIRE(captured[number]);
    CHECK([captured[number] floatValue] == 0);
    RigPreset* immediateRig = [presetClass captureFromState:state name:@"Immediate Slot Edits"];
    for (const auto& entry : edited) {
      NSString* key = [NSString stringWithFormat:@"%u", entry.first];
      REQUIRE(captured[key]);
      CHECK(near([captured[key] floatValue], entry.second));
      CHECK(near([immediateRig controlForPort:entry.first], entry.second));
    }
    if (i == (size_t)Rack::CabConsole) {
      REQUIRE(captured[@"59"]);
      CHECK([captured[@"59"] floatValue] == 1);
    }
    state->userSlotPresets[key] = [@{@"Rack Runtime": captured} mutableCopy];
    state->saveUserSlotPresetsToDisk();
    state->userSlotPresets = nil;
    state->ensureSlotPresetStorage();
    CHECK([state->userSlotPresets[key][@"Rack Runtime"] isEqualToDictionary:captured]);
    echo(rackPort, 1);
    for (const auto& entry : edited) echo(entry.first, 0);
    state->rebuildSlotPresetMenu(slot);
    NSPopUpButton* popup = state->deckSlotSpecs[(NSUInteger)slot][@"popup"];
    REQUIRE(popup);
    [popup selectItemWithTitle:@"Rack Runtime"];
    REQUIRE([popup.titleOfSelectedItem isEqualToString:@"Rack Runtime"]);
    host.writes.clear();
    action(popup);
    CHECK(state->rackControls[i] == 0 && state->rackButtons[i].state == NSControlStateValueOff);
    CHECK(host.writes[rackPort].size() == 1 && host.writes[rackPort].back() == 0);
    REQUIRE(state->abModifiedPreset);
    CHECK([state->abModifiedPreset controlForPort:rackPort] == 0);
    NSDictionary* immediateSlot = state->captureSlotPortValues(slot);
    CHECK([immediateSlot isEqualToDictionary:captured]);
    RigPreset* recalled = [presetClass captureFromState:state name:@"Immediate Slot Recall"];
    for (const auto& entry : edited) {
      CHECK(near([recalled controlForPort:entry.first], entry.second));
      CHECK(near([state->abModifiedPreset controlForPort:entry.first], entry.second));
      const auto& sent = host.writes[entry.first];
      CHECK(sent.size() == 1 && near(sent.back(), entry.second));
    }

    NSMutableDictionary* legacyValues = [captured mutableCopy];
    [legacyValues removeObjectForKey:number];
    state->userSlotPresets[key][@"Legacy Rack"] = legacyValues;
    state->rebuildSlotPresetMenu(slot);
    [popup selectItemWithTitle:@"Legacy Rack"];
    REQUIRE([popup.titleOfSelectedItem isEqualToString:@"Legacy Rack"]);
    host.writes.clear();
    action(popup);
    CHECK(state->rackControls[i] == 1 && state->rackButtons[i].state == NSControlStateValueOn);
    CHECK(host.writes[rackPort].size() == 1 && host.writes[rackPort].back() == 1);
    REQUIRE(state->abModifiedPreset);
    CHECK([state->abModifiedPreset controlForPort:rackPort] == 1);
  }
  [factory applyToState:state];
  values(kRackControlDefaults, false);
  state->selectDeckTab(1);
  drain();
  testedPort = -1;
}

static void verifyPowerTube(Runtime& runtime, Host& host, Class presetClass) {
  using namespace NAMRig;
  RigUIState* state = runtime.state;
  constexpr size_t powerIndex = (size_t)Rack::Power, tubeIndex = (size_t)Rack::PowerTube;
  constexpr uint32_t powerPort = kRackControlFirstPort + powerIndex;
  constexpr uint32_t tubePort = kRackControlFirstPort + tubeIndex;
  auto echo = [&](uint32_t port, float value) {
    runtime.descriptor->port_event(state, port, sizeof(value), 0, &value);
  };
  auto sent = [&](uint32_t port, float value) {
    testedPort = port;
    const auto found = host.writes.find(port);
    CHECK(found != host.writes.end() && !found->second.empty() &&
          found->second.size() == 1 && near(found->second.back(), value));
  };
  auto values = [&](int profile, float character, float power, float tube, bool modified) {
    RigPreset* captured = [presetClass captureFromState:state name:@"Immediate Power Tube Capture"];
    CHECK(state->powerTubeProfile == profile && near(state->powerTubeCharacter, character));
    CHECK(state->rackControls[powerIndex] == power && state->rackControls[tubeIndex] == tube);
    CHECK(state->powerTubePopup.indexOfSelectedItem == profile);
    CHECK([state->powerTubePopup.toolTip isEqualToString:state->powerTubePopup.selectedItem.toolTip]);
    CHECK(near(state->deckKnobs[37].floatValue, character));
    CHECK([state->deckValueLabels[37].stringValue isEqualToString:rigKnobValueText(kPowerTubeCharacterPort, character)]);
    CHECK(state->powerTubeVisualizer.profile == profile);
    CHECK(near(state->powerTubeVisualizer.character, character));
    CHECK(bool(state->powerTubeVisualizer.enabled) == bool(tube));
    for (const auto& entry : std::unordered_map<uint32_t, float>{
        {kPowerTubeTypePort, (float)profile}, {kPowerTubeCharacterPort, character},
        {powerPort, power}, {tubePort, tube}}) {
      testedPort = entry.first;
      CHECK([captured allControls].count(entry.first) == 1);
      CHECK(near([captured controlForPort:entry.first], entry.second));
      if (modified) {
        REQUIRE(state->abModifiedPreset);
        CHECK(state->presetManager.isModified);
        CHECK(near([state->abModifiedPreset controlForPort:entry.first], entry.second));
      }
    }
  };

  stage = "Power Tube controls / wiring / defaults";
  state->selectDeckTab(1);
  drain();
  [runtime.window.contentView layoutSubtreeIfNeeded];
  REQUIRE(state->deckTabPanes.count > 1);
  REQUIRE(state->powerTubePopup && state->powerTubeVisualizer);
  NSSlider* knob = state->deckKnobs[37];
  NSTextField* field = state->deckValueLabels[37];
  REQUIRE(knob && field && state->rackButtons[powerIndex] && state->rackButtons[tubeIndex]);
  CHECK(kRigControlPortCount == 155 && tubePort == 79 && kRigKnobPorts[37] == 81);
  CHECK(state->powerTubePopup.tag == 80 && knob.tag == 81 && field.tag == 81);
  CHECK(state->powerTubePopup.numberOfItems == PowerTube::kProfileCount);
  CHECK([state->powerTubePopup.itemTitles isEqualToArray:
      @[@"Captured / No Added Character", @"6L6-inspired", @"EL34-inspired"]]);
  CHECK(state->powerTubePopup.target == (id)state->uiController);
  CHECK(state->powerTubePopup.action == NSSelectorFromString(@"powerTubeChanged:"));
  CHECK(knob.target == (id)state->uiController && knob.action == NSSelectorFromString(@"controlChanged:"));
  CHECK(field.target == (id)state->uiController && field.delegate == (id)state->uiController);
  CHECK(field.action == NSSelectorFromString(@"knobFieldCommitted:"));
  CHECK(knob.minValue == 0 && knob.maxValue == 100 && kRigKnobDefaults[37] == 50);
  CHECK(field.isEditable && field.isEnabled && knob.isEnabled && state->powerTubePopup.isEnabled);
  CHECK(!state->powerTubePopup.isHiddenOrHasHiddenAncestor && !knob.isHiddenOrHasHiddenAncestor);
  values(PowerTube::kCaptured, 50, 1, 1, false);

  stage = "Power Stage four racks / geometry / aligned control zones";
  NSView* pane = state->deckTabPanes[1];
  auto rackFor = [&](NSView* child) -> NSView* {
    for (NSView* view = child.superview; view && view != pane; view = view.superview)
      if ([view isKindOfClass:NSClassFromString(@"RigPanel")]) return view;
    return nil;
  };
  auto directChild = [&](NSView* child, NSView* rack) -> NSView* {
    NSView* view = child;
    while (view && view.superview != rack) view = view.superview;
    return view;
  };
  auto topOffset = [&](NSView* view, NSView* rack) {
    NSRect rect = [view convertRect:view.bounds toView:rack];
    return rack.isFlipped ? NSMinY(rect) - NSMinY(rack.bounds)
                          : NSMaxY(rack.bounds) - NSMaxY(rect);
  };
  NSArray<NSString*>* titles = @[@"DYNAMIC POWER STAGE", @"PRE-AMP TONAL SCULPT",
                               @"POWER TUBE CHARACTER", @"OUTPUT TRANSFORMER"];
  const size_t rackIndices[] = {powerIndex, (size_t)Rack::Sculpt, tubeIndex, (size_t)Rack::Transformer};
  REQUIRE(state->powerVisualizer && state->sculptVisualizer && state->transformerVisualizer);
  REQUIRE(state->deckKnobs[21] && state->deckKnobs[19] && state->transformerSpecLabels[0]);
  NSArray<NSView*>* visualizers = @[state->powerVisualizer, state->sculptVisualizer,
                                 state->powerTubeVisualizer, state->transformerVisualizer];
  NSArray<NSView*>* topControls = @[state->deckKnobs[21], state->deckKnobs[19],
                                 state->powerTubePopup, state->transformerSpecLabels[0]];
  NSMutableArray<NSView*>* racks = [NSMutableArray array];
  for (size_t i = 0; i < 4; ++i) {
    RigButton* bypass = state->rackButtons[rackIndices[i]];
    NSView* rack = rackFor(bypass);
    REQUIRE(rack && [rack isDescendantOf:pane]);
    CHECK(![racks containsObject:rack]);
    [racks addObject:rack];
    NSRect rect = [rack convertRect:rack.bounds toView:pane];
    CHECK(rect.size.width > 0 && rect.size.height > 0);
    CHECK(NSContainsRect(NSInsetRect(pane.bounds, -0.5, -0.5), rect));
    CHECK(!rack.isHiddenOrHasHiddenAncestor);
    NSMutableArray<NSView*>* descendants = [NSMutableArray arrayWithObject:rack];
    NSTextField* title = nil;
    for (NSUInteger n = 0; n < descendants.count; ++n) {
      NSView* view = descendants[n];
      [descendants addObjectsFromArray:view.subviews];
      if ([view isKindOfClass:NSTextField.class] &&
          [((NSTextField*)view).stringValue isEqualToString:titles[i]]) title = (NSTextField*)view;
    }
    REQUIRE(title);
    NSRect titleRect = [title convertRect:title.bounds toView:rack];
    NSRect bypassRect = [bypass convertRect:bypass.bounds toView:rack];
    CHECK(titleRect.size.width > 0 && titleRect.size.height > 0);
    CHECK(bypassRect.size.width > 0 && bypassRect.size.height > 0);
    CHECK(NSContainsRect(rack.bounds, titleRect) && NSContainsRect(rack.bounds, bypassRect));
    CHECK(!NSIntersectsRect(titleRect, bypassRect));
    NSView* top = directChild(topControls[i], rack);
    NSView* card = directChild(visualizers[i], rack);
    REQUIRE(top && card && top != card);
    CHECK(near(top.bounds.size.height, 108));
    CHECK(near(topOffset(top, rack), 40) && near(topOffset(card, rack), 158));
    CHECK(card.bounds.size.width > 0 && card.bounds.size.height > 0);
    CHECK(!NSIntersectsRect(top.frame, card.frame));
  }
  for (NSUInteger i = 0; i < racks.count; ++i)
    for (NSUInteger j = i + 1; j < racks.count; ++j)
      CHECK(!NSIntersectsRect([racks[i] convertRect:racks[i].bounds toView:pane],
                             [racks[j] convertRect:racks[j].bounds toView:pane]));
  for (size_t index : {21u, 16u, 17u, 18u, 19u, 20u, 37u}) {
    NSSlider* control = state->deckKnobs[index];
    NSTextField* value = state->deckValueLabels[index];
    REQUIRE(control && value && control.superview);
    NSView* cell = control.superview;
    CHECK(cell.bounds.size.width > 0 && cell.bounds.size.height > 0);
    NSRect knobRect = [control convertRect:control.bounds toView:cell];
    NSRect fieldRect = [value convertRect:value.bounds toView:cell];
    CHECK(knobRect.size.width > 0 && knobRect.size.height > 0);
    CHECK(fieldRect.size.width > 0 && fieldRect.size.height > 0);
    CHECK(NSContainsRect(NSInsetRect(cell.bounds, -0.5, -0.5), knobRect));
    CHECK(NSContainsRect(NSInsetRect(cell.bounds, -0.5, -0.5), fieldRect));
    CHECK(!NSIntersectsRect(knobRect, fieldRect));
  }
  NSView* tubeRack = rackFor(knob);
  REQUIRE(tubeRack);
  NSRect typeRect = [state->powerTubePopup convertRect:state->powerTubePopup.bounds toView:tubeRack];
  NSRect characterRect = [knob.superview convertRect:knob.superview.bounds toView:tubeRack];
  CHECK(typeRect.size.width > 0 && typeRect.size.height > 0);
  CHECK(NSContainsRect(tubeRack.bounds, typeRect) && NSContainsRect(tubeRack.bounds, characterRect));
  CHECK(!NSIntersectsRect(typeRect, characterRect));

  stage = "Power Tube selector / knob / field writes / immediate A-B";
  int profile = PowerTube::kCaptured;
  float character = 50;
  for (int selected : {PowerTube::k6L6, PowerTube::kEL34, PowerTube::kCaptured}) {
    host.writes.clear();
    [state->powerTubePopup selectItemAtIndex:selected];
    action(state->powerTubePopup);
    profile = selected;
    CHECK(host.writes.size() == 1);
    sent(kPowerTubeTypePort, profile);
    values(profile, character, 1, 1, true); // No run-loop drain before capture.
  }
  for (float amount : {0.0f, 37.25f, 100.0f}) {
    host.writes.clear();
    knob.floatValue = amount;
    action(knob);
    character = amount;
    CHECK(host.writes.size() == 1);
    sent(kPowerTubeCharacterPort, character);
    values(profile, character, 1, 1, true);
  }
  for (NSString* text : @[@" 72.5% ", @"-10", @"120"]) {
    host.writes.clear();
    field.stringValue = text;
    action(field);
    character = std::clamp(text.floatValue, 0.0f, 100.0f);
    CHECK(host.writes.size() == 1);
    sent(kPowerTubeCharacterPort, character);
    values(profile, character, 1, 1, true);
    [(id<TransformerTestController>)state->uiController controlTextDidEndEditing:
        [NSNotification notificationWithName:NSControlTextDidEndEditingNotification object:field]];
    sent(kPowerTubeCharacterPort, character);
  }
  for (NSString* invalid in @[@"", @"junk", @"NaN", @"inf"]) {
    host.writes.clear();
    field.stringValue = invalid;
    action(field);
    CHECK(host.writes.empty());
    values(profile, character, 1, 1, false);
  }

  stage = "Power Tube real field editor / Enter / Tab / host echo preserves typing";
  for (bool enter : {true, false}) {
    [runtime.window makeKeyAndOrderFront:nil];
    [field selectText:nil];
    NSTextView* editor = (NSTextView*)field.currentEditor;
    REQUIRE([editor isKindOfClass:NSTextView.class]);
    NSString* text = enter ? @"64.25%" : @"28.75%";
    host.writes.clear();
    [editor insertText:text replacementRange:NSMakeRange(0, editor.string.length)];
    REQUIRE(state->deckKnobFieldEditing[37]);
    echo(kPowerTubeCharacterPort, 47);
    CHECK([editor.string isEqualToString:text]);
    CHECK(near(state->powerTubeCharacter, 47) && near(state->powerTubeVisualizer.character, 47));
    CHECK(host.writes.empty());
    if (enter) [editor insertNewline:nil];
    else [editor insertTab:nil];
    character = text.floatValue;
    sent(kPowerTubeCharacterPort, character);
    values(profile, character, 1, 1, true);
    CHECK(!state->deckKnobFieldEditing[37]);
    [runtime.window makeFirstResponder:nil];
    drain();
    sent(kPowerTubeCharacterPort, character);
  }

  stage = "Power Tube background host echoes / validation / no feedback";
  host.writes.clear();
  std::thread automation([&] {
    echo(kPowerTubeTypePort, PowerTube::kEL34);
    echo(kPowerTubeCharacterPort, 63.75f);
    echo(powerPort, 0);
    echo(tubePort, 0);
  });
  automation.join();
  drain();
  values(PowerTube::kEL34, 63.75f, 0, 0, false);
  CHECK(host.writes.empty());
  for (const auto& entry : std::array<std::pair<float, int>, 7>{{
      {-1000, 0}, {1000, 2}, {0.49f, 0}, {0.5f, 1},
      {1.49f, 1}, {1.5f, 2}, {std::numeric_limits<float>::max(), 2}}}) {
    echo(kPowerTubeTypePort, entry.first);
    values(entry.second, 63.75f, 0, 0, false);
  }
  for (const auto& entry : std::array<std::pair<float, float>, 4>{{
      {-1000, 0}, {1000, 100}, {-std::numeric_limits<float>::max(), 0},
      {std::numeric_limits<float>::max(), 100}}}) {
    echo(kPowerTubeCharacterPort, entry.first);
    values(PowerTube::kEL34, entry.second, 0, 0, false);
  }
  for (float invalid : {std::numeric_limits<float>::quiet_NaN(),
                        std::numeric_limits<float>::infinity(),
                        -std::numeric_limits<float>::infinity()}) {
    echo(kPowerTubeTypePort, invalid);
    echo(kPowerTubeCharacterPort, invalid);
    values(PowerTube::kCaptured, 50, 0, 0, false);
  }
  const float rejected = 2;
  for (uint32_t port : {kPowerTubeTypePort, kPowerTubeCharacterPort}) {
    runtime.descriptor->port_event(state, port, sizeof(rejected) - 1, 0, &rejected);
    runtime.descriptor->port_event(state, port, sizeof(rejected), 1, &rejected);
    runtime.descriptor->port_event(state, port, sizeof(rejected), 0, nullptr);
  }
  runtime.descriptor->port_event(state, kRigControlPortCount, sizeof(rejected), 0, &rejected);
  drain();
  values(PowerTube::kCaptured, 50, 0, 0, false);
  CHECK(host.writes.empty());

  stage = "independent Power / Tube switches / all combinations / editable while OFF";
  echo(41, 43); echo(36, 61); echo(37, -12); echo(38, 29);
  for (float power : {0.0f, 1.0f}) {
    for (float tube : {0.0f, 1.0f}) {
      RigPreset* before = [presetClass captureFromState:state name:@"Before Power Tube Switches"];
      for (const auto& entry : std::array<std::pair<size_t, float>, 2>{{
          {powerIndex, power}, {tubeIndex, tube}}}) {
        if (state->rackControls[entry.first] == entry.second) continue;
        host.writes.clear();
        [state->rackButtons[entry.first] performClick:nil];
        CHECK(host.writes.size() == 1);
        sent(kRackControlFirstPort + (uint32_t)entry.first, entry.second);
      }
      RigPreset* after = [presetClass captureFromState:state name:@"After Power Tube Switches"];
      for (const auto& entry : [before allControls])
        if (entry.first != powerPort && entry.first != tubePort)
          CHECK(near([after controlForPort:entry.first], entry.second));
      CHECK(state->powerTubePopup.isEnabled && knob.isEnabled && field.isEnabled && field.isEditable);
      for (size_t index : {21u, 16u, 17u, 18u})
        CHECK(state->deckKnobs[index].isEnabled && state->deckValueLabels[index].isEditable &&
              state->deckValueLabels[index].isEnabled);
      host.writes.clear();
      profile = tube ? PowerTube::k6L6 : PowerTube::kEL34;
      [state->powerTubePopup selectItemAtIndex:profile];
      action(state->powerTubePopup);
      character = power ? 24.5f : 72.5f;
      knob.floatValue = character;
      action(knob);
      sent(kPowerTubeTypePort, profile);
      sent(kPowerTubeCharacterPort, character);
      values(profile, character, power, tube, true);
      host.writes.clear();
      field.stringValue = @"31.25%";
      action(field);
      character = 31.25f;
      sent(kPowerTubeCharacterPort, character);
      values(profile, character, power, tube, true);
      host.writes.clear();
      state->deckKnobs[16].floatValue = power ? 62 : 63;
      action(state->deckKnobs[16]);
      sent(36, power ? 62 : 63);
      values(profile, character, power, tube, true);
    }
  }

  stage = "Power Tube slot / factory / user / disk recall";
  NSInteger slot = -1;
  for (NSUInteger i = 0; i < state->deckSlotSpecs.count; ++i)
    if ([state->deckSlotSpecs[i][@"key"] isEqualToString:@"power_tube"]) slot = (NSInteger)i;
  REQUIRE(slot >= 0);
  NSMutableDictionary* spec = state->deckSlotSpecs[(NSUInteger)slot];
  NSPopUpButton* popup = spec[@"popup"];
  REQUIRE(popup);
  CHECK([spec[@"title"] isEqualToString:@"Power Tube Character"]);
  CHECK([NSSet setWithArray:spec[@"ports"]].count == 3);
  CHECK([[NSSet setWithArray:spec[@"ports"]] isEqualToSet:[NSSet setWithArray:@[@79, @80, @81]]]);
  CHECK([spec[@"enabledPort"] unsignedIntValue] == tubePort);
  CHECK(!popup.isHiddenOrHasHiddenAncestor && popup.isEnabled);
  echo(powerPort, 0); echo(tubePort, 0);
  echo(kPowerTubeTypePort, PowerTube::kEL34); echo(kPowerTubeCharacterPort, 72.5f);
  NSDictionary* savedSlot = state->captureSlotPortValues(slot);
  CHECK([savedSlot isEqualToDictionary:@{@"79": @0, @"80": @2, @"81": @72.5}]);
  state->userSlotPresets[@"power_tube"] = [@{@"Runtime Power Tube": savedSlot,
      @"Legacy Power Tube": @{@"80": @1, @"81": @18.75}} mutableCopy];
  state->saveUserSlotPresetsToDisk();
  state->userSlotPresets = nil;
  state->ensureSlotPresetStorage();
  CHECK([state->userSlotPresets[@"power_tube"][@"Runtime Power Tube"] isEqualToDictionary:savedSlot]);
  state->rebuildSlotPresetMenu(slot);
  for (int selected = 0; selected < PowerTube::kProfileCount; ++selected) {
    echo(kPowerTubeCharacterPort, 92);
    host.writes.clear();
    [popup selectItemAtIndex:selected];
    action(popup);
    sent(kPowerTubeTypePort, selected);
    sent(kPowerTubeCharacterPort, 50);
    CHECK(host.writes.size() == 2); // Factory voicing does not toggle either rack.
    values(selected, 50, 0, 0, true);
    CHECK(![spec[@"selectedIsUser"] boolValue]);
  }
  for (NSString* name in @[@"Runtime Power Tube", @"Legacy Power Tube"]) {
    echo(kPowerTubeTypePort, 0); echo(kPowerTubeCharacterPort, 99); echo(tubePort, 0);
    host.writes.clear();
    [popup selectItemWithTitle:name];
    REQUIRE([popup.titleOfSelectedItem isEqualToString:name]);
    action(popup);
    const bool legacy = [name isEqualToString:@"Legacy Power Tube"];
    sent(tubePort, legacy ? 1 : 0);
    sent(kPowerTubeTypePort, legacy ? 1 : 2);
    sent(kPowerTubeCharacterPort, legacy ? 18.75f : 72.5f);
    CHECK(host.writes.size() == 3 && !host.writes.count(powerPort));
    values(legacy ? 1 : 2, legacy ? 18.75f : 72.5f, 0, legacy ? 1 : 0, true);
    if (!legacy) CHECK([state->captureSlotPortValues(slot) isEqualToDictionary:savedSlot]);
  }

  stage = "Power Tube visible menu save / save as / overwrite / delete";
  [popup selectItemAtIndex:PowerTube::k6L6];
  action(popup);
  [popup.menu update];
  CHECK(![popup itemWithTitle:@"Delete Preset"].isEnabled);
  for (NSString* title in @[@"Save Preset", @"Save Preset As…", @"Delete Preset"]) {
    NSMenuItem* item = [popup itemWithTitle:title];
    REQUIRE(item);
    CHECK(item.target == (id)state->uiController && item.tag == slot);
  }
  Method modal = class_getInstanceMethod(NSAlert.class, @selector(runModal));
  IMP originalModal = method_setImplementation(modal, (IMP)slotPresetDialog);
  const int savesBefore = slotSaveDialogs, deletesBefore = slotDeleteDialogs;
  @try {
    for (NSString* command in @[@"Save Preset", @"Save Preset As…"]) {
      [popup.menu performActionForItemAtIndex:[popup indexOfItemWithTitle:command]];
      NSString* name = [command isEqualToString:@"Save Preset"]
          ? @"Menu Saved Power Tube" : @"Menu Saved Power Tube As";
      CHECK([popup.titleOfSelectedItem isEqualToString:name] && [spec[@"selectedIsUser"] boolValue]);
      CHECK([state->userSlotPresets[@"power_tube"][name]
          isEqualToDictionary:state->captureSlotPortValues(slot)]);
    }
    CHECK(slotSaveDialogs == savesBefore + 2 && powerTubeSaveDialogs == 2);
    echo(kPowerTubeTypePort, PowerTube::kEL34); echo(kPowerTubeCharacterPort, 86.25f); echo(tubePort, 0);
    [popup.menu performActionForItemAtIndex:[popup indexOfItemWithTitle:@"Save Preset"]];
    CHECK(slotSaveDialogs == savesBefore + 2);
    NSDictionary* overwritten = state->userSlotPresets[@"power_tube"][@"Menu Saved Power Tube As"];
    CHECK([overwritten isEqualToDictionary:@{@"79": @0, @"80": @2, @"81": @86.25}]);
    echo(kPowerTubeCharacterPort, 3);
    [popup selectItemWithTitle:@"Menu Saved Power Tube As"];
    host.writes.clear();
    action(popup);
    values(2, 86.25f, 0, 0, true);
    sent(kPowerTubeCharacterPort, 86.25f);
    [popup.menu update];
    CHECK([popup itemWithTitle:@"Delete Preset"].isEnabled);
    [popup.menu performActionForItemAtIndex:[popup indexOfItemWithTitle:@"Delete Preset"]];
    CHECK(slotDeleteDialogs == deletesBefore + 1);
    CHECK(!state->userSlotPresets[@"power_tube"][@"Menu Saved Power Tube As"]);
    CHECK(![popup itemWithTitle:@"Menu Saved Power Tube As"]);
    CHECK(![popup itemWithTitle:@"Delete Preset"].isEnabled);
    NSDictionary* persisted = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:RigUIState::slotPresetsFilePath()] options:0 error:nil];
    REQUIRE(persisted);
    CHECK(!persisted[@"power_tube"][@"Menu Saved Power Tube As"]);
    CHECK(persisted[@"power_tube"][@"Menu Saved Power Tube"] && persisted[@"power_tube"][@"Runtime Power Tube"]);
    CHECK([persisted[@"transformer"] isEqualToDictionary:state->userSlotPresets[@"transformer"]]);
  } @finally {
    method_setImplementation(modal, originalModal);
  }

  stage = "Power Tube full rig JSON / numeric / named / override / legacy defaults";
  echo(powerPort, 0); echo(tubePort, 0);
  echo(kPowerTubeTypePort, PowerTube::kEL34); echo(kPowerTubeCharacterPort, 72.5f);
  RigPreset* saved = [presetClass captureFromState:state name:@"Power Tube Runtime"];
  NSString* file = [testRoot stringByAppendingPathComponent:@"power-tube-roundtrip.json"];
  REQUIRE([saved saveToFile:file error:nil]);
  NSDictionary* json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:file]
      options:NSJSONReadingMutableContainers error:nil];
  REQUIRE(json);
  NSArray<NSString*>* numbers = @[@"79", @"80", @"81"];
  NSArray<NSString*>* symbols = @[@"power_tube_enabled", @"power_tube_type", @"power_tube_character"];
  NSArray<NSNumber*>* expected = @[@0, @2, @72.5];
  for (NSUInteger i = 0; i < numbers.count; ++i) {
    REQUIRE(json[@"ports"][numbers[i]] && json[@"params"][symbols[i]]);
    CHECK(near([json[@"ports"][numbers[i]] floatValue], expected[i].floatValue));
    CHECK(near([json[@"params"][symbols[i]] floatValue], expected[i].floatValue));
  }
  RigPreset* loaded = [presetClass loadFromFile:file];
  REQUIRE(loaded);
  for (NSString* format in @[@"numeric", @"named", @"override", @"legacy"]) {
    NSMutableDictionary* variant = [json mutableCopy];
    NSMutableDictionary* ports = [json[@"ports"] mutableCopy];
    NSMutableDictionary* params = [json[@"params"] mutableCopy];
    for (NSUInteger i = 0; i < numbers.count; ++i) {
      if ([format isEqualToString:@"numeric"] || [format isEqualToString:@"legacy"])
        [params removeObjectForKey:symbols[i]];
      if ([format isEqualToString:@"named"] || [format isEqualToString:@"legacy"])
        [ports removeObjectForKey:numbers[i]];
      if ([format isEqualToString:@"override"]) ports[numbers[i]] = @1;
    }
    variant[@"ports"] = ports;
    variant[@"params"] = params;
    NSString* path = [testRoot stringByAppendingPathComponent:
        [NSString stringWithFormat:@"power-tube-%@.json", format]];
    REQUIRE([[NSJSONSerialization dataWithJSONObject:variant options:0 error:nil] writeToFile:path atomically:YES]);
    RigPreset* preset = [presetClass loadFromFile:path];
    REQUIRE(preset);
    const bool legacy = [format isEqualToString:@"legacy"];
    for (NSUInteger i = 0; i < numbers.count; ++i) {
      const uint32_t port = (uint32_t)numbers[i].integerValue;
      CHECK([preset allControls].count(port) == 1);
      CHECK(near([preset controlForPort:port],
                 legacy ? (i == 0 ? 1 : i == 1 ? 0 : 50) : expected[i].floatValue));
    }
    echo(kPowerTubeTypePort, 1); echo(kPowerTubeCharacterPort, 99); echo(tubePort, 0);
    host.writes.clear();
    [preset applyToState:state];
    values(legacy ? 0 : 2, legacy ? 50 : 72.5f, 0, legacy ? 1 : 0, false);
    sent(tubePort, legacy ? 1 : 0);
    sent(kPowerTubeTypePort, legacy ? 0 : 2);
    sent(kPowerTubeCharacterPort, legacy ? 50 : 72.5f);
  }
  stage = "Power Tube sparse / factory / reset defaults type 0 amount 50";
  RigPreset* sparse = [[presetClass alloc] init];
  RigPreset* factory = [presetClass defaultPreset];
  CHECK([factory controlForPort:kPowerTubeTypePort] == 0);
  CHECK([factory controlForPort:kPowerTubeCharacterPort] == 50);
  for (RigPreset* preset in @[sparse, factory]) {
    [loaded applyToState:state];
    host.writes.clear();
    [preset applyToState:state];
    values(0, 50, 1, 1, false);
    sent(kPowerTubeTypePort, 0);
    sent(kPowerTubeCharacterPort, 50);
    sent(tubePort, 1);
  }
  [loaded applyToState:state];
  host.writes.clear();
  [(id<TransformerTestController>)state->uiController resetAllKnobs:nil];
  values(0, 50, 1, 1, true);
  sent(kPowerTubeTypePort, 0);
  sent(kPowerTubeCharacterPort, 50);

  stage = "Power Tube saved and modified A-B recall / no cross-rack leakage";
  REQUIRE([state->presetManager savePreset:loaded error:nil]);
  state->abModifiedPreset = loaded;
  for (NSString* name in @[loaded.name, RigUIState::abModifiedToken()]) {
    state->abNameA = @"Default Rig";
    state->abNameB = name;
    state->abShowingA = true;
    state->abCycling = true;
    for (bool showingA : {false, true, false}) {
      host.writes.clear();
      [(id<TransformerTestController>)state->uiController abTimerFired:nil];
      CHECK(state->abShowingA == showingA && !state->abApplyingCycle);
      values(showingA ? 0 : 2, showingA ? 50 : 72.5f, showingA ? 1 : 0, showingA ? 1 : 0, false);
      sent(kPowerTubeTypePort, showingA ? 0 : 2);
      sent(kPowerTubeCharacterPort, showingA ? 50 : 72.5f);
      sent(powerPort, showingA ? 1 : 0);
      sent(tubePort, showingA ? 1 : 0);
    }
    state->abCycling = false;
  }
  [factory applyToState:state];
  drain();
  testedPort = -1;
}

static void verify(const char* modulePath) {
  using Transformer = NAMRig::OutputTransformer;
  using namespace NAMRig;
  void* module = dlopen(modulePath, RTLD_NOW | RTLD_LOCAL);
  if (!module) {
    std::fprintf(stderr, "dlopen: %s\n", dlerror());
    throw std::runtime_error("UI module could not be loaded");
  }
  auto descriptorFunction = reinterpret_cast<const LV2UI_Descriptor* (*)(uint32_t)>(
      dlsym(module, "lv2ui_descriptor"));
  REQUIRE(descriptorFunction);
  Host host;
  Runtime runtime;
  runtime.descriptor = descriptorFunction(0);
  REQUIRE(runtime.descriptor && !descriptorFunction(1));
  CHECK(std::strcmp(runtime.descriptor->URI,
      "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig-ui") == 0);
  Class presetClass = NSClassFromString(@"RigPreset");
  Class managerClass = NSClassFromString(@"RigPresetManager");
  Class browserClass = NSClassFromString(@"ToneBrowserController");
  REQUIRE(presetClass && managerClass && browserClass);

  // HOME alone does not isolate NSHomeDirectory/tilde expansion. Redirect the
  // manager and bypass browser credentials, keychain, logs, scanning and network.
  // These hooks live only in this executable; transformer/preset code is real.
  replace(managerClass, @selector(presetsDirectory), (IMP)presetsDirectory);
  replace(managerClass, NSSelectorFromString(@"currentPresetFilePath"), (IMP)currentPresetPath);
  replace(browserClass, @selector(init), method_getImplementation(
      class_getInstanceMethod(NSObject.class, @selector(init))));
  replace(browserClass, NSSelectorFromString(@"autoConnect"), (IMP)skip);
  for (NSString* name in @[@"archChanged:", @"reloadLibrary:", @"logTone3000:"])
    replace(browserClass, NSSelectorFromString(name), (IMP)skipOne);
  replace(browserClass, NSSelectorFromString(@"restoreFilterSelectionForGear:sort:arch:"),
          (IMP)skipThree, true);
  replace(NSUserDefaults.class, @selector(setObject:forKey:), (IMP)skipPreferenceWrite);
  originalAddMonitor = method_getImplementation(class_getClassMethod(NSEvent.class,
      @selector(addLocalMonitorForEventsMatchingMask:handler:)));
  replace(NSEvent.class, @selector(addLocalMonitorForEventsMatchingMask:handler:),
          (IMP)captureKeyMonitor, true);

  [NSApplication sharedApplication];
  runtime.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1520, 980)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  runtime.window.releasedWhenClosed = NO;
  LV2_URID_Map map{&host, mapURI};
  LV2_Feature mapFeature{LV2_URID__map, &map};
  LV2_Feature parentFeature{LV2_UI__parent, (__bridge void*)runtime.window.contentView};
  const LV2_Feature* features[] = {&mapFeature, &parentFeature, nullptr};
  LV2UI_Widget widget = nullptr;
  runtime.state = static_cast<RigUIState*>(runtime.descriptor->instantiate(
      runtime.descriptor, "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig",
      nullptr, recordWrite, &host, &widget, features));
  method_setImplementation(class_getClassMethod(NSEvent.class,
      @selector(addLocalMonitorForEventsMatchingMask:handler:)), originalAddMonitor);
  REQUIRE(runtime.state && widget);
  RigUIState* state = runtime.state;
  REQUIRE((__bridge NSView*)widget == state->view);
  REQUIRE(state->presetManager);
  REQUIRE(state->keyEventMonitor && installedKeyHandler);
  CHECK([state->presetManager.presetsDirectory hasPrefix:testRoot]);
  CHECK([RigUIState::slotPresetsFilePath() hasPrefix:testRoot]);
  [(id<TransformerTestController>)state->uiController showAmpAdvanced:nil];
  drain();
  [runtime.window orderFront:nil];
  [runtime.window.contentView layoutSubtreeIfNeeded];
  auto echo = [&](uint32_t port, float value) {
    runtime.descriptor->port_event(state, port, sizeof(value), 0, &value);
  };
  TransformerAdjustments expected = kTransformerControlDefaults;
  snapshot(state, presetClass, expected, false);

  stage = "four edit controls / popovers / ranges";
  NSMutableArray<NSView*>* views = [NSMutableArray arrayWithObject:state->view];
  std::array<NSButton* __strong, 4> buttons{};
  size_t editCount = 0;
  for (NSUInteger n = 0; n < views.count; ++n) {
    NSView* view = views[n];
    [views addObjectsFromArray:view.subviews];
    if (![view isKindOfClass:NSButton.class]) continue;
    NSButton* button = (NSButton*)view;
    if (button.action != NSSelectorFromString(@"showTransformerControls:")) continue;
    REQUIRE(button.tag >= 0 && button.tag < 4);
    CHECK(!buttons[button.tag]);
    buttons[button.tag] = button;
    ++editCount;
  }
  REQUIRE(editCount == 4);
  REQUIRE(state->deckTransformerPopup);
  [state->deckTransformerPopup selectItemAtIndex:Transformer::kUKVintage];
  action(state->deckTransformerPopup);
  CHECK(state->transformerProfile == Transformer::kUKVintage);
  snapshot(state, presetClass, expected, true);
  const auto base = Transformer::controlValues(Transformer::parametersForProfile(Transformer::kUKVintage));
  constexpr float absoluteMin[] = {5, 2000, 0.5f, 0, 20, 100, -12, 0.2f, 100, -12, 0.2f};
  constexpr float absoluteMax[] = {300, 24000, 10, 100, 400, 12000, 12, 4, 12000, 12, 4};
  constexpr size_t starts[] = {0, 2, 5, 8}, counts[] = {2, 3, 3, 3};
  NSArray<NSString*>* buttonTitles = @[@"PASSBAND  EDIT", @"CORE FLUX  EDIT", @"VOICE PEAK  EDIT", @"LEAKAGE  EDIT"];
  NSArray<NSString*>* headings = @[@"Passband", @"Core Flux", @"Voice Peak", @"Leakage Resonance"];
  constexpr float sliderTrims[] = {1.5137f, 0.8137f, 1.2137f, 5.137f, 1.3137f,
                                  1.2137f, 1.5137f, 1.3137f, 0.8137f, -1.137f, 1.4137f};
  for (size_t group = 0; group < buttons.size(); ++group) {
    stage = "four edit controls / popovers / ranges";
    REQUIRE(buttons[group]);
    CHECK([buttons[group].title isEqualToString:buttonTitles[group]]);
    CHECK(buttons[group].target == (id)state->uiController);
    CHECK(!buttons[group].isHiddenOrHasHiddenAncestor);
    CHECK(buttons[group].frame.size.width > 0 && buttons[group].frame.size.height > 0);
    action(buttons[group]);
    drain();
    REQUIRE(state->transformerPopover && state->transformerPopover.isShown);
    NSView* content = state->transformerPopover.contentViewController.view;
    CHECK([((NSTextField*)content.subviews.firstObject).stringValue isEqualToString:headings[group]]);
    size_t visibleControls = 0;
    for (size_t i = 0; i < kTransformerControlCount; ++i) {
      const bool inGroup = i >= starts[group] && i < starts[group] + counts[group];
      CHECK(bool(state->transformerSliders[i]) == inGroup);
      CHECK(bool(state->transformerFields[i]) == inGroup);
      if (!inGroup) continue;
      ++visibleControls;
      stage = "four edit controls / popovers / ranges";
      testedPort = kTransformerControlFirstPort + i;
      NSSlider* slider = state->transformerSliders[i];
      NSTextField* field = state->transformerFields[i];
      REQUIRE(slider && field);
      const auto& c = kTransformerControls[i];
      const bool ratio = c.defaultValue == 1;
      const double lo = std::max(absoluteMin[i], ratio ? base[i] * c.minimum : base[i] + c.minimum);
      const double hi = std::min(absoluteMax[i], ratio ? base[i] * c.maximum : base[i] + c.maximum);
      CHECK(near(slider.minValue, c.logarithmic ? std::log(lo) : lo));
      CHECK(near(slider.maxValue, c.logarithmic ? std::log(hi) : hi));
      CHECK(slider.tag == testedPort && field.tag == testedPort);
      CHECK(field.isEditable && field.isEnabled && slider.isEnabled && slider.isContinuous);
      CHECK(field.delegate == (id)state->uiController);
      CHECK(NSContainsRect(content.bounds, slider.frame) && NSContainsRect(content.bounds, field.frame));
      CHECK([field.stringValue isEqualToString:valueText(i, base[i])]);

      stage = "slider writes / immediate capture / telemetry";
      host.writes.clear();
      expected[i] = sliderTrims[i];
      const double target = ratio ? base[i] * expected[i] : base[i] + expected[i];
      slider.doubleValue = c.logarithmic ? std::log(target) : target;
      action(slider);
      CHECK(host.writes[testedPort].size() == 1);
      REQUIRE(!host.writes[testedPort].empty());
      CHECK(near(host.writes[testedPort].back(), expected[i]));
      snapshot(state, presetClass, expected, true); // Deliberately no run-loop drain.
      telemetry(state, expected);

      stage = "canonical rounded field after slider is idempotent";
      const float effective = Transformer::controlValues(state->transformerVisualizer.parameters)[i];
      REQUIRE(std::fabs(field.stringValue.floatValue - effective) > 1.0e-5f);
      const float exactTrim = state->transformerAdjustments[i];
      host.writes.clear();
      action(field);
      [(id<TransformerTestController>)state->uiController controlTextDidEndEditing:
          [NSNotification notificationWithName:NSControlTextDidEndEditingNotification object:field]];
      CHECK(host.writes.empty());
      CHECK(state->transformerAdjustments[i] == exactTrim);
      snapshot(state, presetClass, expected, true);
      telemetry(state, expected);

      stage = "field writes / units / no duplicate focus commit";
      expected[i] = ratio ? 1.1f : (i == 3 ? -3.0f : -2.0f);
      const float fieldTarget = ratio ? base[i] * expected[i] : base[i] + expected[i];
      field.stringValue = [NSString stringWithFormat:@"  %@  ", valueText(i, fieldTarget).lowercaseString];
      // Integer-Hz fields round to whole Hz before the controller sees them.
      const float parsedTarget = field.stringValue.floatValue;
      expected[i] = ratio ? parsedTarget / base[i] : parsedTarget - base[i];
      host.writes.clear();
      action(field);
      CHECK(host.writes[testedPort].size() == 1);
      REQUIRE(!host.writes[testedPort].empty());
      CHECK(near(host.writes[testedPort].back(), expected[i]));
      snapshot(state, presetClass, expected, true);
      telemetry(state, expected);
      [(id<TransformerTestController>)state->uiController controlTextDidEndEditing:
          [NSNotification notificationWithName:NSControlTextDidEndEditingNotification object:field]];
      CHECK(host.writes[testedPort].size() == 1);

      stage = "invalid / nonfinite field rejection";
      for (NSString* invalid in @[@"", @"garbage", @"NaN", @"nan", @"inf", @"-inf",
                                  @"1e9999", @"--2", @"12garbage", @"1.2.3", @"2 Hz junk",
                                  @"2 bananas", @"2 Hz dB", @"2%%", @"2dBx", @"2 x junk"]) {
        host.writes.clear();
        field.stringValue = invalid;
        action(field);
        const bool rejected = host.writes.empty() && near(state->transformerAdjustments[i], expected[i]);
        if (!rejected) std::fprintf(stderr, "  accepted invalid text: %s\n", invalid.UTF8String);
        CHECK(rejected);
        if (rejected) {
          CHECK([field.stringValue isEqualToString:valueText(i,
              Transformer::controlValues(Transformer::parametersForProfile(state->transformerProfile, expected))[i])]);
        } else {
          echo((uint32_t)testedPort, expected[i]); // Do not let one failure contaminate later checks.
        }
      }

      stage = "field clamping";
      for (double outOfRange : {-1000000.0, 1000000.0}) {
        field.stringValue = [NSString stringWithFormat:@"%.0f", outOfRange];
        action(field);
        const double bound = outOfRange < 0 ? lo : hi;
        CHECK(near(state->transformerAdjustments[i], ratio ? bound / base[i] : bound - base[i]));
        CHECK(near(Transformer::controlValues(state->transformerVisualizer.parameters)[i], bound));
      }
      echo((uint32_t)testedPort, expected[i]);
    }
    CHECK(visibleControls == counts[group]);
  }

  stage = "host echoes preserve tweaks / live field editing";
  host.writes.clear();
  echo(30, Transformer::kModern);
  snapshot(state, presetClass, expected, false);
  telemetry(state, expected);
  CHECK(host.writes.empty());
  action(buttons[2]);
  drain();
  NSTextField* editing = state->transformerFields[5];
  REQUIRE(editing);
  [(id<TransformerTestController>)state->uiController controlTextDidBeginEditing:
      [NSNotification notificationWithName:NSControlTextDidBeginEditingNotification object:editing]];
  REQUIRE(state->transformerFieldEditing[5]);
  editing.stringValue = @"3500 Hz";
  expected[5] = 0.75f;
  echo(65, expected[5]);
  echo(30, Transformer::kModern);
  CHECK([editing.stringValue isEqualToString:@"3500 Hz"]);
  std::thread worker([&] {
    echo(30, Transformer::kUSVintage);
    echo(66, -4.0f);
    echo(70, 1.25f);
  });
  worker.join();
  drain();
  expected[6] = -4.0f;
  expected[10] = 1.25f;
  CHECK(state->transformerProfile == Transformer::kUSVintage);
  CHECK([editing.stringValue isEqualToString:@"3500 Hz"]);
  CHECK(host.writes.empty());
  snapshot(state, presetClass, expected, false);
  telemetry(state, expected);
  [(id<TransformerTestController>)state->uiController controlTextDidEndEditing:
      [NSNotification notificationWithName:NSControlTextDidEndEditingNotification object:editing]];
  expected[5] = 2.0f; // 3500 / US Vintage's 1750 Hz.
  CHECK(!state->transformerFieldEditing[5]);
  CHECK(host.writes[65].size() == 1 && near(host.writes[65].back(), 2));
  snapshot(state, presetClass, expected, true);
  telemetry(state, expected);

  stage = "rig capture / save / load / apply";
  RigPreset* captured = [presetClass captureFromState:state name:@"Transformer Runtime"];
  NSString* file = [testRoot stringByAppendingPathComponent:@"roundtrip.json"];
  REQUIRE([captured saveToFile:file error:nil]);
  NSDictionary* json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:file]
      options:NSJSONReadingMutableContainers error:nil];
  REQUIRE([json isKindOfClass:NSDictionary.class]);
  for (size_t i = 0; i < expected.size(); ++i) {
    NSString* port = [NSString stringWithFormat:@"%u", kTransformerControlFirstPort + (uint32_t)i];
    NSString* symbol = [NSString stringWithUTF8String:kTransformerControls[i].symbol];
    CHECK(near([json[@"ports"][port] floatValue], expected[i]));
    CHECK(near([json[@"params"][symbol] floatValue], expected[i]));
  }
  RigPreset* loaded = [presetClass loadFromFile:file];
  REQUIRE(loaded);
  [state->deckTransformerPopup selectItemAtIndex:Transformer::kSmallIron];
  action(state->deckTransformerPopup);
  host.writes.clear();
  [loaded applyToState:state];
  snapshot(state, presetClass, expected, false);
  CHECK(state->transformerProfile == Transformer::kUSVintage);
  for (size_t i = 0; i < expected.size(); ++i) {
    const auto& writes = host.writes[kTransformerControlFirstPort + i];
    CHECK(writes.size() == 1 && near(writes.back(), expected[i]));
  }
  telemetry(state, expected);
  drain();

  stage = "legacy rig missing trims / sparse preset / factory default";
  NSMutableDictionary* legacy = [json mutableCopy];
  for (NSString* key in @[@"ports", @"params"]) {
    NSMutableDictionary* values = [legacy[key] mutableCopy];
    for (size_t i = 0; i < expected.size(); ++i) {
      NSString* name = [key isEqualToString:@"ports"]
          ? [NSString stringWithFormat:@"%u", kTransformerControlFirstPort + (uint32_t)i]
          : [NSString stringWithUTF8String:kTransformerControls[i].symbol];
      [values removeObjectForKey:name];
    }
    legacy[key] = values;
  }
  NSString* legacyPath = [testRoot stringByAppendingPathComponent:@"legacy.json"];
  REQUIRE([[NSJSONSerialization dataWithJSONObject:legacy options:0 error:nil]
      writeToFile:legacyPath atomically:YES]);
  RigPreset* legacyPreset = [presetClass loadFromFile:legacyPath];
  REQUIRE(legacyPreset);
  expected = kTransformerControlDefaults;
  for (size_t i = 0; i < expected.size(); ++i) {
    CHECK([legacyPreset allControls].count(kTransformerControlFirstPort + i) == 1);
    CHECK(near([legacyPreset controlForPort:kTransformerControlFirstPort + i], expected[i]));
  }
  host.writes.clear();
  [legacyPreset applyToState:state];
  trimWrites(host, expected);
  snapshot(state, presetClass, expected, false);
  CHECK(state->transformerProfile == Transformer::kUSVintage);
  [loaded applyToState:state];
  RigPreset* sparse = [[presetClass alloc] init];
  [sparse stageAtIndex:1]->transformer = Transformer::kUKVintage;
  host.writes.clear();
  [sparse applyToState:state];
  trimWrites(host, expected);
  snapshot(state, presetClass, expected, false);
  RigPreset* factory = [presetClass defaultPreset];
  for (size_t i = 0; i < expected.size(); ++i)
    CHECK(near([factory controlForPort:kTransformerControlFirstPort + i], expected[i]));
  drain();

  stage = "transformer slot capture / saved slot apply / legacy slot";
  [loaded applyToState:state];
  const TransformerAdjustments saved = state->transformerAdjustments;
  NSInteger slot = -1;
  for (NSUInteger i = 0; i < state->deckSlotSpecs.count; ++i)
    if ([state->deckSlotSpecs[i][@"key"] isEqualToString:@"transformer"]) slot = (NSInteger)i;
  REQUIRE(slot >= 0);
  NSDictionary* slotValues = state->captureSlotPortValues(slot);
  // Model selector, eleven trims, the pane's 24 graph-pin ports and rack enable.
  CHECK(slotValues.count == 13 + kPinEqPanePorts);
  for (size_t i = 0; i < kPinEqPanePorts; ++i) {
    const uint32_t port = pinEqPort(PinEqPane::Transformer, 0, 0) + (uint32_t)i;
    NSNumber* pin = slotValues[[NSString stringWithFormat:@"%u", port]];
    CHECK(pin && near([pin floatValue], pinEqDefault(port)));
  }
  NSString* enabledPort = [NSString stringWithFormat:@"%u",
      kRackControlFirstPort + (uint32_t)Rack::Transformer];
  REQUIRE(slotValues[enabledPort]);
  CHECK([slotValues[enabledPort] floatValue] == 1);
  CHECK(near([slotValues[@"30"] floatValue], state->transformerProfile));
  for (size_t i = 0; i < saved.size(); ++i)
    CHECK(near([slotValues[[NSString stringWithFormat:@"%u", kTransformerControlFirstPort + (uint32_t)i]] floatValue], saved[i]));
  NSMutableDictionary* spec = state->deckSlotSpecs[(NSUInteger)slot];
  state->userSlotPresets[@"transformer"] = [@{@"Runtime Slot": slotValues,
      @"Legacy Slot": @{@"30": @(Transformer::kSmallIron)}} mutableCopy];
  state->saveUserSlotPresetsToDisk();
  NSString* slotFile = RigUIState::slotPresetsFilePath();
  CHECK([slotFile hasPrefix:testRoot]);
  state->userSlotPresets = nil;
  state->ensureSlotPresetStorage();
  CHECK([state->userSlotPresets[@"transformer"][@"Runtime Slot"] isEqualToDictionary:slotValues]);
  NSPopUpButton* slotPopup = spec[@"popup"];
  REQUIRE(slotPopup);
  CHECK([spec[@"title"] isEqualToString:@"Output Transformer"]);
  CHECK(!slotPopup.isHiddenOrHasHiddenAncestor);
  CHECK(slotPopup.superview == state->transformerSpecLabels[0].superview.superview.superview.superview);
  CHECK(slotPopup.frame.size.width > 100 && slotPopup.frame.size.height > 0);
  CHECK(slotPopup.superview != state->deckTransformerPopup.superview);
  bool presetLabel = false, baseModelLabel = false, rackTitle = false;
  for (NSView* view in slotPopup.superview.subviews)
    if ([view isKindOfClass:NSTextField.class])
      presetLabel |= [((NSTextField*)view).stringValue isEqualToString:@"PRESET"];
  for (NSView* view in state->deckTransformerPopup.superview.subviews)
    if ([view isKindOfClass:NSTextField.class])
      baseModelLabel |= [((NSTextField*)view).stringValue isEqualToString:@"BASE MODEL"];
  for (NSView* view in views)
    if ([view isKindOfClass:NSTextField.class])
      rackTitle |= [((NSTextField*)view).stringValue isEqualToString:@"OUTPUT TRANSFORMER"];
  CHECK(presetLabel && baseModelLabel && rackTitle);
  state->rebuildSlotPresetMenu(slot);
  for (NSString* name in @[@"Runtime Slot", @"Legacy Slot"]) {
    [slotPopup selectItemWithTitle:name];
    REQUIRE([slotPopup.titleOfSelectedItem isEqualToString:name]);
    host.writes.clear();
    action(slotPopup);
    expected = [name isEqualToString:@"Runtime Slot"] ? saved : kTransformerControlDefaults;
    trimWrites(host, expected);
    snapshot(state, presetClass, expected, true);
    CHECK(state->transformerProfile == ([name isEqualToString:@"Runtime Slot"]
        ? Transformer::kUSVintage : Transformer::kSmallIron));
    telemetry(state, expected);
  }

  stage = "visible slot menu save / save as / delete actions";
  [slotPopup selectItemAtIndex:Transformer::kModern];
  action(slotPopup);
  [slotPopup.menu update];
  CHECK(![slotPopup itemWithTitle:@"Delete Preset"].isEnabled);
  for (NSString* title in @[@"Save Preset", @"Save Preset As…", @"Delete Preset"]) {
    NSMenuItem* item = [slotPopup itemWithTitle:title];
    REQUIRE(item);
    CHECK(item.target == (id)state->uiController && item.tag == slot);
  }
  Method modal = class_getInstanceMethod(NSAlert.class, @selector(runModal));
  IMP originalModal = method_setImplementation(modal, (IMP)slotPresetDialog);
  @try {
    // Factory Save delegates to Save As; explicit Save As uses the same dialog.
    for (NSString* command in @[@"Save Preset", @"Save Preset As…"]) {
      [slotPopup.menu performActionForItemAtIndex:[slotPopup indexOfItemWithTitle:command]];
      CHECK([slotPopup.titleOfSelectedItem isEqualToString:@"Menu Saved Transformer"]);
      CHECK([spec[@"selectedIsUser"] boolValue]);
      CHECK([state->userSlotPresets[@"transformer"][@"Menu Saved Transformer"]
          isEqualToDictionary:state->captureSlotPortValues(slot)]);
    }
    CHECK(slotSaveDialogs == 2);
    echo(60, 1.5f);
    [slotPopup.menu performActionForItemAtIndex:[slotPopup indexOfItemWithTitle:@"Save Preset"]];
    CHECK(slotSaveDialogs == 2); // Overwrite without prompting for a new name.
    CHECK(near([state->userSlotPresets[@"transformer"][@"Menu Saved Transformer"][@"60"] floatValue], 1.5f));
    [slotPopup.menu update];
    CHECK([slotPopup itemWithTitle:@"Delete Preset"].isEnabled);
    [slotPopup.menu performActionForItemAtIndex:[slotPopup indexOfItemWithTitle:@"Delete Preset"]];
    CHECK(slotDeleteDialogs == 1);
    CHECK(!state->userSlotPresets[@"transformer"][@"Menu Saved Transformer"]);
    CHECK(![slotPopup itemWithTitle:@"Menu Saved Transformer"]);
    CHECK(![slotPopup itemWithTitle:@"Delete Preset"].isEnabled);
    NSDictionary* persistedSlots = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:slotFile] options:0 error:nil];
    CHECK(!persistedSlots[@"transformer"][@"Menu Saved Transformer"]);
    CHECK(persistedSlots[@"transformer"][@"Runtime Slot"]);
  } @finally {
    method_setImplementation(modal, originalModal);
  }

  stage = "factory selection / model selector / reset neutral";
  [loaded applyToState:state];
  [slotPopup selectItemAtIndex:Transformer::kModern];
  host.writes.clear();
  action(slotPopup);
  expected = kTransformerControlDefaults;
  trimWrites(host, expected);
  snapshot(state, presetClass, expected, true);
  CHECK(state->transformerProfile == Transformer::kModern);
  [loaded applyToState:state];
  [state->deckTransformerPopup selectItemAtIndex:Transformer::kUKVintage];
  host.writes.clear();
  action(state->deckTransformerPopup);
  trimWrites(host, expected);
  snapshot(state, presetClass, expected, true);
  [loaded applyToState:state];
  action(buttons[0]);
  drain();
  NSButton* reset = nil;
  for (NSView* view in state->transformerPopover.contentViewController.view.subviews)
    if ([view isKindOfClass:NSButton.class] &&
        ((NSButton*)view).action == NSSelectorFromString(@"resetTransformerControls:")) reset = (NSButton*)view;
  REQUIRE(reset);
  host.writes.clear();
  action(reset);
  trimWrites(host, expected);
  snapshot(state, presetClass, expected, true);
  CHECK(state->transformerProfile == Transformer::kUSVintage);
  [loaded applyToState:state];
  host.writes.clear();
  [(id<TransformerTestController>)state->uiController resetAllKnobs:nil];
  trimWrites(host, expected);
  snapshot(state, presetClass, expected, true);
  CHECK(state->transformerProfile == Transformer::kUSVintage);

  stage = "focused pending edit discarded by reset / rig / A-B apply";
  REQUIRE([state->presetManager savePreset:loaded error:nil]);
  const TransformerAdjustments restored = [&] {
    TransformerAdjustments trims;
    for (size_t i = 0; i < trims.size(); ++i)
      trims[i] = [loaded controlForPort:kTransformerControlFirstPort + i];
    return trims;
  }();
  for (NSString* path in @[@"Reset Model Tweaks", @"Full Rig Apply", @"Rig Menu Apply",
                            @"A/B Saved Apply", @"A/B Modified Apply"]) {
    for (size_t group = 0; group < 4; ++group) {
      [loaded applyToState:state];
      action(buttons[group]);
      drain();
      const size_t index = starts[group];
      NSTextField* field = state->transformerFields[index];
      NSWindow* editorWindow = field.window;
      NSButton* resetButton = nil;
      for (NSView* view in state->transformerPopover.contentViewController.view.subviews)
        if ([view isKindOfClass:NSButton.class] &&
            ((NSButton*)view).action == NSSelectorFromString(@"resetTransformerControls:")) resetButton = (NSButton*)view;
      REQUIRE(resetButton);
      host.writes.clear();
      edit(state, index, @"7777");
      CHECK(host.writes.empty());
      if ([path isEqualToString:@"Reset Model Tweaks"]) {
        action(resetButton);
        expected = kTransformerControlDefaults;
      } else {
        expected = restored;
        if ([path isEqualToString:@"Full Rig Apply"]) {
          [loaded applyToState:state];
        } else if ([path isEqualToString:@"Rig Menu Apply"]) {
          state->rebuildPresetMenu();
          [state->presetPopup selectItemWithTitle:loaded.name];
          REQUIRE([state->presetPopup.titleOfSelectedItem isEqualToString:loaded.name]);
          action(state->presetPopup);
        } else {
          // Invoke the module's timer callback, including its A/B dispatch path.
          state->abModifiedPreset = loaded;
          state->abNameA = @"Default Rig";
          state->abNameB = [path isEqualToString:@"A/B Modified Apply"]
              ? RigUIState::abModifiedToken() : loaded.name;
          state->abShowingA = true;
          state->abCycling = true;
          [(id<TransformerTestController>)state->uiController abTimerFired:nil];
          CHECK(!state->abShowingA && !state->abApplyingCycle);
          state->abCycling = false;
        }
      }
      for (bool isEditing : state->transformerFieldEditing) CHECK(!isEditing);
      CHECK(!field.currentEditor);
      CHECK(![editorWindow.firstResponder isKindOfClass:NSText.class]);
      trimWrites(host, expected);
      for (size_t i = 0; i < expected.size(); ++i)
        CHECK(host.writes[kTransformerControlFirstPort + i].size() == 1);
      snapshot(state, presetClass, expected, [path isEqualToString:@"Reset Model Tweaks"]);
      telemetry(state, expected);
      host.writes.clear();
      // A real refocus/Tab cycle and a late delegate callback must not resurrect
      // the discarded editor text or quantize the freshly applied preset.
      [field selectText:nil];
      REQUIRE([field.currentEditor isKindOfClass:NSTextView.class]);
      [(NSTextView*)field.currentEditor insertTab:nil];
      [editorWindow makeFirstResponder:nil];
      [(id<TransformerTestController>)state->uiController controlTextDidEndEditing:
          [NSNotification notificationWithName:NSControlTextDidEndEditingNotification object:field]];
      drain();
      CHECK(host.writes.empty());
      snapshot(state, presetClass, expected, false);
      telemetry(state, expected);
    }
  }

  stage = "actual field editor Enter / Tab commit exactly once";
  [loaded applyToState:state];
  expected = restored;
  action(buttons[0]);
  drain();
  for (bool enter : {true, false}) {
    NSString* text = enter ? @"23.456 Hz" : @"27.891 Hz";
    host.writes.clear();
    NSTextView* editor = edit(state, 0, text);
    CHECK(host.writes.empty());
    if (enter) [editor insertNewline:nil];
    else [editor insertTab:nil];
    expected[0] = text.floatValue / 18.0f; // US Vintage low-cut base.
    drain();
    CHECK(host.writes[60].size() == 1 && near(host.writes[60].back(), expected[0]));
    CHECK(!state->transformerFieldEditing[0]);
    snapshot(state, presetClass, expected, true);
    telemetry(state, expected);
    [state->transformerFields[0].window makeFirstResponder:nil];
    drain();
    CHECK(host.writes[60].size() == 1);
  }

  stage = "popover Cmd+S / Cmd+Shift+S commit before save";
  saveState = state;
  replace(object_getClass((id)state->uiController), @selector(saveCurrentPreset:), (IMP)recordSave);
  replace(object_getClass((id)state->uiController), @selector(savePresetAs:), (IMP)recordSave);
  for (bool saveAs : {false, true}) {
    host.writes.clear();
    NSString* text = saveAs ? @"31.789 Hz" : @"29.567 Hz";
    edit(state, 0, text);
    NSWindow* editorWindow = state->transformerFields[0].window;
    REQUIRE(editorWindow != runtime.window);
    [editorWindow makeKeyWindow];
    drain();
    const bool realKeyFocus = editorWindow.isKeyWindow && !runtime.window.isKeyWindow;
    NSEventModifierFlags modifiers = NSEventModifierFlagCommand |
        (saveAs ? NSEventModifierFlagShift : 0);
    NSEvent* event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:modifiers timestamp:NSProcessInfo.processInfo.systemUptime
        windowNumber:editorWindow.windowNumber context:nil characters:saveAs ? @"S" : @"s"
        charactersIgnoringModifiers:@"s" isARepeat:NO keyCode:1];
    const int beforeSave = saveCalls, beforeSaveAs = saveAsCalls;
    if (realKeyFocus) {
      [NSApp sendEvent:event];
    } else {
      // Inactive CLI processes cannot own the key window. Keep the real window
      // and field editor; fake only key ownership and run the captured handler
      // installed by the module, rather than reimplementing the shortcut logic.
      syntheticShortcutFocus = true;
      syntheticKeyWindow = editorWindow;
      Method keyMethod = class_getInstanceMethod(NSWindow.class, @selector(isKeyWindow));
      IMP originalKey = method_setImplementation(keyMethod, (IMP)keyWindowForTest);
      @try {
        CHECK(editorWindow.isKeyWindow && !runtime.window.isKeyWindow);
        CHECK(installedKeyHandler(event) == nil);
      } @finally {
        method_setImplementation(keyMethod, originalKey);
        syntheticKeyWindow = nil;
      }
    }
    drain();
    CHECK(saveCalls == beforeSave + (saveAs ? 0 : 1));
    CHECK(saveAsCalls == beforeSaveAs + (saveAs ? 1 : 0));
    expected[0] = text.floatValue / 18.0f;
    CHECK(host.writes[60].size() == 1 && near(host.writes[60].back(), expected[0]));
    CHECK(!state->transformerFieldEditing[0] && !state->transformerFields[0].currentEditor);
    REQUIRE(savedByShortcut);
    for (size_t i = 0; i < expected.size(); ++i)
      CHECK(near([savedByShortcut controlForPort:kTransformerControlFirstPort + i], expected[i]));
    snapshot(state, presetClass, expected, true);
    telemetry(state, expected);
  }
  saveState = nullptr;

  stage = "Off disables every group / no control writes";
  [state->deckTransformerPopup selectItemAtIndex:Transformer::kCaptured];
  action(state->deckTransformerPopup);
  expected = kTransformerControlDefaults;
  snapshot(state, presetClass, expected, true);
  telemetry(state, expected);
  for (size_t group = 0; group < 4; ++group) {
    action(buttons[group]);
    drain();
    REQUIRE(state->transformerPopover.isShown);
    for (size_t i = starts[group]; i < starts[group] + counts[group]; ++i) {
      testedPort = kTransformerControlFirstPort + i;
      REQUIRE(state->transformerSliders[i] && state->transformerFields[i]);
      CHECK(!state->transformerSliders[i].isEnabled && !state->transformerFields[i].isEnabled);
      host.writes.clear();
      state->transformerFields[i].stringValue = @"123";
      action(state->transformerFields[i]);
      action(state->transformerSliders[i]);
      CHECK(host.writes.empty());
      snapshot(state, presetClass, expected, false);
    }
  }
  [factory applyToState:state];
  snapshot(state, presetClass, expected, false);
  CHECK(state->transformerProfile == Transformer::kCaptured);
  telemetry(state, expected);
  [state->transformerPopover close];
  verifyRackSwitches(runtime, host, presetClass);
  verifyPowerTube(runtime, host, presetClass);
  verifyPinEditors(runtime, host, presetClass);
  stage = "cleanup";
  // Do not dlclose: Objective-C classes remain registered until process exit.
}

int main(int argc, char** argv) {
  @autoreleasepool {
    if (argc > 2) {
      std::fprintf(stderr, "Usage: %s [built rig UI module]\n", argv[0]);
      return 2;
    }
    std::string root = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"transformer-ui-XXXXXX"] fileSystemRepresentation];
    if (!mkdtemp(root.data())) { std::perror("mkdtemp"); return 2; }
    testRoot = [NSString stringWithUTF8String:root.c_str()];
    setenv("HOME", root.c_str(), 1);
    setenv("CFFIXED_USER_HOME", root.c_str(), 1);
    try {
      @try {
        verify(argc == 2 ? argv[1] : "build-test/src/neural_amp_modeler_rig_ui.so");
      } @catch (NSException* exception) {
        ++failures;
        std::fprintf(stderr, "FAIL [%s]: %s\n", stage, exception.description.UTF8String);
      }
    } catch (const std::exception& error) {
      ++failures;
      std::fprintf(stderr, "FAIL [%s]: %s\n", stage, error.what());
    }
    drain();
    NSError* error = nil;
    if (![[NSFileManager defaultManager] removeItemAtPath:testRoot error:&error]) {
      ++failures;
      std::fprintf(stderr, "Temporary storage cleanup failed: %s\n", error.description.UTF8String);
    }
    std::printf("%s: transformer / power tube / rack UI runtime, %d checks, %d failures\n",
                 failures ? "FAIL" : "PASS", checks, failures);
    if (syntheticShortcutFocus)
      std::puts("LIMITATION: inactive CLI app; save shortcuts used the module's installed key-monitor handler with synthetic key-window ownership.");
    return failures ? 1 : 0;
  }
}
