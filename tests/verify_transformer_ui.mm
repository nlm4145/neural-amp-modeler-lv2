// Runtime test of the built UI, not a source-contract or a recompiled UI copy.
// From the repository root (macOS, with a WindowServer session):
// clang++ -std=c++20 -fobjc-arc -Isrc -Ideps/lv2/include \
//   tests/verify_transformer_ui.mm src/rig_knobs.cpp src/rig_theme.mm src/rig_profile_catalog.mm -framework Cocoa \
//   -framework QuartzCore -framework CoreImage \
//   -o "$TMPDIR/verify_transformer_ui"
// "$TMPDIR/verify_transformer_ui" \
//   build-test/src/neural_amp_modeler_rig_ui.so
#include "overdrive.h"
#include "rig_ui_state.h"
#include "rig_control_contract.h"
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
  if ([alert.messageText isEqualToString:@"Save Tuning As"] ||
      [alert.messageText isEqualToString:@"Rename Tuning"]) {
    ((NSTextField*)alert.accessoryView).stringValue =
      [alert.messageText isEqualToString:@"Rename Tuning"] ? @"Runtime Renamed Tuning" : @"Runtime Saved Tuning";
    return NSAlertFirstButtonReturn;
  }
  if ([alert.messageText isEqualToString:@"Delete Tuning"]) return NSAlertFirstButtonReturn;
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
  // A first layout can consume a whole run-loop slice. Wait for delivery blocks
  // and their immediate UI updates instead of assuming 30 ms drained the queue.
  for (int pass = 0; pass < 2; ++pass) {
    __block BOOL finished = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ finished = YES; });
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!finished && deadline.timeIntervalSinceNow > 0)
      [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    if (!finished) throw std::runtime_error("main queue did not drain");
  }
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
  std::vector<std::pair<LV2_URID, float>> patches;
};
static LV2_URID mapURI(LV2_URID_Map_Handle handle, const char* uri) {
  auto& ids = static_cast<Host*>(handle)->urids;
  return ids.emplace(uri, static_cast<LV2_URID>(ids.size() + 1)).first->second;
}
static void recordWrite(LV2UI_Controller controller, uint32_t port,
                        uint32_t size, uint32_t format, const void* buffer) {
  if (format == 0 && size == sizeof(float) && buffer)
    static_cast<Host*>(controller)->writes[port].push_back(*static_cast<const float*>(buffer));
  else if (buffer && size >= sizeof(LV2_Atom_Object)) {
    auto* host = static_cast<Host*>(controller);
    const auto* object = static_cast<const LV2_Atom_Object*>(buffer);
    const LV2_Atom *property = nullptr, *value = nullptr;
    lv2_atom_object_get(object, mapURI(host, LV2_PATCH__property), &property,
                        mapURI(host, LV2_PATCH__value), &value, 0);
    if (property && value && property->type == mapURI(host, LV2_ATOM__URID) &&
        value->type == mapURI(host, LV2_ATOM__Float))
      host->patches.emplace_back(((const LV2_Atom_URID*)property)->body,
                                 ((const LV2_Atom_Float*)value)->body);
  }
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
      // Retain the widgets and their timers to check actual UI teardown even
      // while AppKit/test traversal arrays still retain the view hierarchy.
      auto meters = state->stageMeters;
      std::array<NSTimer* __strong, 4> timers{};
      std::array<float, 4> levels{};
      for (size_t i = 0; i < meters.size(); ++i) {
        timers[i] = [meters[i] valueForKey:@"meterTimer"];
        levels[i] = meters[i].levelDb;
      }
      descriptor->cleanup(state);
      state = nullptr;
      drain(); // Exercise queued updates after teardown as well.
      for (size_t i = 0; i < meters.size(); ++i) {
        CHECK(!meters[i].window);
        CHECK(!timers[i].isValid);
        CHECK(near(meters[i].levelDb, levels[i]));
      }
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

@interface PedalTestDrag : NSObject
@property(nonatomic, strong) NSView* draggingSource;
@end
@implementation PedalTestDrag
@end

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
  REQUIRE(state->sculptVisualizer && state->transformerVisualizer && state->cabConsoleVisualizer &&
          state->speakerVisualizer);
  CHECK(state->pinEditors[(size_t)PinEqPane::Sculpt] == state->sculptVisualizer.pinEditor);
  CHECK(state->pinEditors[(size_t)PinEqPane::Transformer] == state->transformerVisualizer.pinEditor);
  CHECK(state->pinEditors[(size_t)PinEqPane::CabConsole] == state->cabConsoleVisualizer.pinEditor);
  CHECK(state->pinEditors[(size_t)PinEqPane::Speaker] == state->speakerVisualizer.pinEditor);
  for (size_t pane = 0; pane < kPinEqPaneCount; ++pane) {
    NAMPinEQEditor* editor = state->pinEditors[pane];
    REQUIRE(editor && editor.onChange && editor.onCommit);
    CHECK(editor.pane == (PinEqPane)pane);
  }
  CHECK(state->sculptVisualizer.pinEditor.superview == state->sculptVisualizer);
  CHECK(state->speakerVisualizer.pinEditor.superview == state->speakerVisualizer);

  stage = "graph pin editors / speaker slot preset and drawn load";
  NSInteger speakerSlot = -1;
  for (NSUInteger i = 0; i < state->deckSlotSpecs.count; ++i)
    if ([state->deckSlotSpecs[i][@"key"] isEqualToString:@"speaker"]) speakerSlot = (NSInteger)i;
  REQUIRE(speakerSlot >= 0);
  NSDictionary* speakerValues = state->captureSlotPortValues(speakerSlot);
  for (size_t i = 0; i < kPinEqPanePorts; ++i) {
    const uint32_t port = pinEqPort(PinEqPane::Speaker, 0, 0) + (uint32_t)i;
    CHECK(speakerValues[[NSString stringWithFormat:@"%u", port]] != nil);
  }
  // Auto resolves from the displayed Cab A path, as in the DSP; Power ON feeds damping.
  drain();
  state->displayPath(2, "/irs/Mesa Recto V30.wav");
  drain();
  CHECK(state->speakerCabPath == "/irs/Mesa Recto V30.wav");
  const float autoProfile = SpeakerDynamics::kAuto;
  runtime.descriptor->port_event(state, 42, sizeof(autoProfile), 0, &autoProfile);
  drain();
  CHECK(state->speakerVisualizer.profile == SpeakerDynamics::kModern412);
  const float nfb = 50.0f, powerOn = 1.0f, powerOff = 0.0f;
  const uint32_t powerPort = kRackControlFirstPort + (uint32_t)Rack::Power;
  runtime.descriptor->port_event(state, powerPort, sizeof(powerOn), 0, &powerOn);
  runtime.descriptor->port_event(state, 38, sizeof(nfb), 0, &nfb);
  drain();
  CHECK(near(state->speakerVisualizer.damping, 0.5f));
  runtime.descriptor->port_event(state, powerPort, sizeof(powerOff), 0, &powerOff);
  drain();
  CHECK(state->speakerVisualizer.damping == 0.0f);
  const float captured0 = SpeakerDynamics::kCaptured;
  runtime.descriptor->port_event(state, 42, sizeof(captured0), 0, &captured0);
  runtime.descriptor->port_event(state, powerPort, sizeof(powerOn), 0, &powerOn);
  drain();
  CHECK(state->speakerVisualizer.profile == SpeakerDynamics::kCaptured);

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
  CHECK(host.writes[shape].back() == (float)kPinBell);
  CHECK(std::fabs(host.writes[freq].back() - 632.5f) < 15.0f);
  CHECK(std::fabs(host.writes[gain].back() - kPinGainMax * 0.5f) < 0.5f);
  CHECK(state->pinEqControls[shape - kPinEqFirstPort] == (float)kPinBell);
  CHECK(state->presetManager.isModified);

  stage = "graph pin editors / preset capture, host echo and recall";
  RigPreset* captured = [presetClass captureFromState:state name:@"Pins"];
  CHECK([captured controlForPort:shape] == (float)kPinBell);
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
  CHECK(state->pinEqControls[shape - kPinEqFirstPort] == (float)kPinBell);
  [[presetClass defaultPreset] applyToState:state];
  drain();
}

static void verifySculptOverdrive(Runtime& runtime, Host& host, Class presetClass) {
  using namespace NAMRig;
  RigUIState* state = runtime.state;
  auto echo = [&](uint32_t port, float value) {
    runtime.descriptor->port_event(state, port, sizeof(value), 0, &value);
  };
  stage = "sculpt overdrive / knobs and graph";
  CHECK(kRigKnobPorts[39] == kOverdriveDrivePort && kRigKnobPorts[40] == kOverdriveTonePort &&
        kRigKnobPorts[41] == kOverdriveLevelPort && kRigKnobPorts[47] == kOverdriveTightPort);
  CHECK(kRigKnobDefaults[39] == 0.0f && kRigKnobDefaults[40] == Overdrive::kToneDefault &&
        kRigKnobDefaults[41] == 0.0f && kRigKnobDefaults[47] == Overdrive::kTightDefault);
  for (size_t k : {39u, 40u, 41u, 47u}) {
    REQUIRE(state->deckKnobs[k]);
    CHECK(state->deckKnobs[k].tag == (NSInteger)kRigKnobPorts[k]);
    CHECK([state->deckKnobs[k] isDescendantOf:state->boostVisualizer.superview.superview]);
  }
  REQUIRE(state->sculptVisualizer);
  REQUIRE(state->boostVisualizer);
  CHECK(state->boostVisualizer.tone == Overdrive::kToneDefault);
  CHECK(state->boostVisualizer.tight == Overdrive::kTightDefault);

  stage = "pre-amp EQ and Boost cards layout and bypass";
  REQUIRE(state->sculptEqKnobs && state->sculptOdKnobs);
  CHECK(!state->sculptEqKnobs.hidden && !state->sculptOdKnobs.hidden);
  for (size_t k : {19u, 20u, 38u}) CHECK([state->deckKnobs[k] isDescendantOf:state->sculptEqKnobs]);
  for (size_t k : {39u, 40u, 41u, 47u}) CHECK([state->deckKnobs[k] isDescendantOf:state->sculptOdKnobs]);

  // Check ON/OFF toggle buttons for both cards:
  RigButton* eqButton = state->rackButtons[(size_t)NAMRig::Rack::Sculpt];
  REQUIRE(eqButton);
  CHECK(eqButton.tag == (NSInteger)(NAMRig::kRackControlFirstPort + (size_t)NAMRig::Rack::Sculpt));
  CHECK(state->sculptVisualizer.enabled);
  echo(NAMRig::kRackControlFirstPort + (size_t)NAMRig::Rack::Sculpt, 0.0f);
  drain();
  CHECK(!state->sculptVisualizer.enabled);
  CHECK([eqButton.title isEqualToString:@"OFF"]);
  echo(NAMRig::kRackControlFirstPort + (size_t)NAMRig::Rack::Sculpt, 1.0f);
  drain();
  CHECK(state->sculptVisualizer.enabled);
  CHECK([eqButton.title isEqualToString:@"ON"]);

  RigButton* boostButton = state->boostButton;
  REQUIRE(boostButton);
  CHECK(boostButton.tag == (NSInteger)kOverdriveEnabledPort);
  CHECK(state->boostVisualizer.enabled);
  echo(kOverdriveEnabledPort, 0.0f);
  drain();
  CHECK(!state->boostVisualizer.enabled);
  CHECK([boostButton.title isEqualToString:@"OFF"]);
  echo(kOverdriveEnabledPort, 1.0f);
  drain();
  CHECK(state->boostVisualizer.enabled);
  CHECK([boostButton.title isEqualToString:@"ON"]);

  [state->sculptOdKnobs.window layoutIfNeeded];
  for (size_t k : {39u, 40u, 41u}) {
    NSSlider* control = state->deckKnobs[k];
    NSTextField* value = state->deckValueLabels[k];
    REQUIRE(control && value);
    NSView* cell = control.superview;
    const NSRect knobRect = [control convertRect:control.bounds toView:cell];
    const NSRect fieldRect = [value convertRect:value.bounds toView:cell];
    CHECK(knobRect.size.width > 0 && fieldRect.size.width > 0);
    CHECK(NSContainsRect(NSInsetRect(cell.bounds, -0.5, -0.5), knobRect));
    CHECK(NSContainsRect(NSInsetRect(cell.bounds, -0.5, -0.5), fieldRect));
    CHECK(!NSIntersectsRect(knobRect, fieldRect));
  }

  echo(kOverdriveDrivePort, 40.0f);
  echo(kOverdriveTonePort, 20.0f);
  echo(kOverdriveLevelPort, -3.0f);
  drain();
  CHECK(state->boostVisualizer.drive == 40.0f && state->boostVisualizer.tone == 20.0f &&
        state->boostVisualizer.level == -3.0f);
  CHECK(near(state->deckKnobs[39].floatValue, 40.0f));
  RigPreset* captured = [presetClass captureFromState:state name:@"Overdrive"];
  CHECK(near([captured controlForPort:kOverdriveDrivePort], 40.0f));
  CHECK(near([captured controlForPort:kOverdriveLevelPort], -3.0f));

  stage = "sculpt and boost slot presets";
  NSInteger eqSlot = -1, boostSlot = -1;
  for (NSUInteger i = 0; i < state->deckSlotSpecs.count; ++i) {
    if ([state->deckSlotSpecs[i][@"key"] isEqualToString:@"sculpt"]) eqSlot = (NSInteger)i;
    if ([state->deckSlotSpecs[i][@"key"] isEqualToString:@"boost"]) boostSlot = (NSInteger)i;
  }
  REQUIRE(eqSlot >= 0);
  REQUIRE(boostSlot >= 0);

  // EQ slot preset
  NSPopUpButton* eqPopup = state->deckSlotSpecs[(NSUInteger)eqSlot][@"popup"];
  REQUIRE(eqPopup);
  [eqPopup selectItemWithTitle:@"TIGHT CHUG"];
  REQUIRE([eqPopup.titleOfSelectedItem isEqualToString:@"TIGHT CHUG"]);
  host.writes.clear();
  action(eqPopup);
  drain();
  REQUIRE(!host.writes[40].empty());
  CHECK(host.writes[40].back() == 75.0f);

  // Boost slot preset
  NSDictionary* boostValues = state->captureSlotPortValues(boostSlot);
  for (uint32_t port : {kOverdriveDrivePort, kOverdriveTonePort, kOverdriveLevelPort, kOverdriveTightPort})
    CHECK(boostValues[[NSString stringWithFormat:@"%u", port]] != nil);
  CHECK(boostValues[[NSString stringWithFormat:@"%u", kOverdriveEnabledPort]] != nil);

  NSPopUpButton* boostPopup = state->deckSlotSpecs[(NSUInteger)boostSlot][@"popup"];
  REQUIRE(boostPopup);
  [boostPopup selectItemWithTitle:@"TS9 DRIVE"];
  REQUIRE([boostPopup.titleOfSelectedItem isEqualToString:@"TS9 DRIVE"]);
  host.writes.clear();
  action(boostPopup);
  drain();
  REQUIRE(!host.writes[kOverdriveDrivePort].empty());
  CHECK(host.writes[kOverdriveDrivePort].back() > 0.0f);
  CHECK(state->boostVisualizer.drive > 0.0f);

  state->ensureSlotPresetStorage();
  if (!state->userSlotPresets[@"boost"]) state->userSlotPresets[@"boost"] = [NSMutableDictionary dictionary];
  state->userSlotPresets[@"boost"][@"MyBoost"] = @{@"179": @25.0f, @"180": @50.0f, @"181": @2.0f};
  state->rebuildSlotPresetMenu(boostSlot);
  [boostPopup selectItemWithTitle:@"MyBoost"];
  REQUIRE([boostPopup.titleOfSelectedItem isEqualToString:@"MyBoost"]);
  host.writes.clear();
  action(boostPopup);
  drain();
  REQUIRE(!host.writes[kOverdriveDrivePort].empty());
  CHECK(host.writes[kOverdriveDrivePort].back() == 25.0f);
  CHECK(state->boostVisualizer.drive == 25.0f);

  // Pre-Amp EQ and Boost presets unlinking verification:
  // 1. Set distinct boost parameters
  echo(kOverdriveDrivePort, 35.0f);
  echo(kOverdriveTonePort, 55.0f);
  echo(kOverdriveLevelPort, 2.0f);
  drain();
  CHECK(state->boostVisualizer.drive == 35.0f);

  // 2. User preset with legacy overdrive keys (e.g. "TS9 (No Clipping)") must NOT modify boost
  if (!state->userSlotPresets[@"sculpt"]) state->userSlotPresets[@"sculpt"] = [NSMutableDictionary dictionary];
  state->userSlotPresets[@"sculpt"][@"TS9 (No Clipping)"] = @{
    @"39": @0.0f, @"40": @0.0f, @"82": @0.0f,
    @"179": @9.5f, @"180": @50.0f, @"181": @-8.0f
  };
  state->rebuildSlotPresetMenu(eqSlot);
  [eqPopup selectItemWithTitle:@"TS9 (No Clipping)"];
  REQUIRE([eqPopup.titleOfSelectedItem isEqualToString:@"TS9 (No Clipping)"]);
  host.writes.clear();
  action(eqPopup);
  drain();
  CHECK(host.writes[kOverdriveDrivePort].empty());
  CHECK(host.writes[kOverdriveTonePort].empty());
  CHECK(host.writes[kOverdriveLevelPort].empty());
  CHECK(state->boostVisualizer.drive == 35.0f);
  CHECK(state->boostVisualizer.tone == 55.0f);
  CHECK(state->boostVisualizer.level == 2.0f);

  // 3. User preset without overdrive keys must NOT reset boost to odDefaults
  state->userSlotPresets[@"sculpt"][@"Clean EQ"] = @{
    @"39": @5.0f, @"40": @30.0f, @"82": @40.0f
  };
  state->rebuildSlotPresetMenu(eqSlot);
  [eqPopup selectItemWithTitle:@"Clean EQ"];
  REQUIRE([eqPopup.titleOfSelectedItem isEqualToString:@"Clean EQ"]);
  host.writes.clear();
  action(eqPopup);
  drain();
  CHECK(host.writes[kOverdriveDrivePort].empty());
  CHECK(host.writes[kOverdriveTonePort].empty());
  CHECK(host.writes[kOverdriveLevelPort].empty());
  CHECK(state->boostVisualizer.drive == 35.0f);
  CHECK(state->boostVisualizer.tone == 55.0f);
  CHECK(state->boostVisualizer.level == 2.0f);

  // 4. Boost preset selection must not touch sculpt controls (39, 40, 82)
  [boostPopup selectItemWithTitle:@"TS9 DRIVE"];
  host.writes.clear();
  action(boostPopup);
  drain();
  CHECK(host.writes[39].empty());
  CHECK(host.writes[40].empty());
  CHECK(host.writes[kMidPushPort].empty());

  // Every new factory preset applies its own controls without changing the other slot.
  struct BoostFactoryCase { __unsafe_unretained NSString* title; float drive, tight, tone, level, voicing; };
  const BoostFactoryCase boostCases[] = {
    {@"TS808 STYLE", 30.0f, 720.0f, 45.0f, 2.0f, 0.0f},
    {@"TS9 AMP PUSH", 10.0f, 720.0f, 55.0f, 6.0f, 0.0f},
    {@"BOSS SD-1 STYLE", 35.0f, 720.0f, 55.0f, 2.0f, 1.0f},
    {@"SD-1 TIGHT PUSH", 10.0f, 950.0f, 60.0f, 6.0f, 1.0f},
    {@"LED OPEN DRIVE", 45.0f, 550.0f, 60.0f, 2.0f, 2.0f},
    {@"GERMANIUM GRIT", 65.0f, 450.0f, 40.0f, 0.0f, 3.0f},
    {@"WARM BLUES", 20.0f, 400.0f, 45.0f, 3.0f, 0.0f},
    {@"SINGING LEAD", 55.0f, 850.0f, 55.0f, 3.0f, 0.0f}
  };
  NSString* selectedEQ = [eqPopup.titleOfSelectedItem copy];
  for (const auto& preset : boostCases) {
    [boostPopup selectItemWithTitle:preset.title];
    REQUIRE([boostPopup.titleOfSelectedItem isEqualToString:preset.title]);
    host.writes.clear();
    action(boostPopup);
    drain();
    const std::pair<uint32_t, float> expected[] = {
      {kOverdriveDrivePort, preset.drive}, {kOverdriveTightPort, preset.tight},
      {kOverdriveTonePort, preset.tone}, {kOverdriveLevelPort, preset.level},
      {kOverdriveVoicingPort, preset.voicing}
    };
    for (const auto& [port, value] : expected) {
      REQUIRE(!host.writes[port].empty());
      CHECK(near(host.writes[port].back(), value));
    }
    for (NSNumber* port in state->deckSlotSpecs[(NSUInteger)eqSlot][@"ports"])
      CHECK(host.writes[port.unsignedIntValue].empty());
    CHECK([eqPopup.titleOfSelectedItem isEqualToString:selectedEQ]);
  }

  struct EqFactoryCase { __unsafe_unretained NSString* title; float bright, inputEq, midPush; };
  const EqFactoryCase eqCases[] = {
    {@"WARM MID FOCUS", 0.0f, 20.0f, 25.0f}, {@"CLEAR & OPEN", 10.0f, 20.0f, 0.0f},
    {@"MODERN TIGHT", 0.0f, 85.0f, 30.0f}, {@"LEAD PRESENCE", 5.0f, 45.0f, 55.0f}
  };
  NSString* selectedBoost = [boostPopup.titleOfSelectedItem copy];
  for (const auto& preset : eqCases) {
    [eqPopup selectItemWithTitle:preset.title];
    REQUIRE([eqPopup.titleOfSelectedItem isEqualToString:preset.title]);
    host.writes.clear();
    action(eqPopup);
    drain();
    const std::pair<uint32_t, float> expected[] = {
      {39, preset.bright}, {40, preset.inputEq}, {kMidPushPort, preset.midPush}
    };
    for (const auto& [port, value] : expected) {
      REQUIRE(!host.writes[port].empty());
      CHECK(near(host.writes[port].back(), value));
    }
    for (NSNumber* port in state->deckSlotSpecs[(NSUInteger)boostSlot][@"ports"])
      CHECK(host.writes[port.unsignedIntValue].empty());
    CHECK([boostPopup.titleOfSelectedItem isEqualToString:selectedBoost]);
  }

  [state->userSlotPresets[@"sculpt"] removeObjectForKey:@"TS9 (No Clipping)"];
  [state->userSlotPresets[@"sculpt"] removeObjectForKey:@"Clean EQ"];
  [state->userSlotPresets[@"boost"] removeObjectForKey:@"MyBoost"];
  [[presetClass defaultPreset] applyToState:state];
  drain();
  CHECK(state->sculptVisualizer.odDrive == 0.0f && state->sculptVisualizer.odLevel == 0.0f);
}

static void verifyCompressorPreAmp(Runtime& runtime, Host& host, Class presetClass) {
  using namespace NAMRig;
  RigUIState* state = runtime.state;
  auto echo = [&](uint32_t port, float value) {
    runtime.descriptor->port_event(state, port, sizeof(value), 0, &value);
  };
  stage = "Pre-Amp pane / compressor knobs and visualizer";
  state->selectDeckTab(1);
  drain();
  [runtime.window.contentView layoutSubtreeIfNeeded];
  REQUIRE(state->deckTabPanes.count >= 5);
  NSView* pane1 = (NSView*)state->workspace;
  REQUIRE(pane1 && !pane1.isHiddenOrHasHiddenAncestor);

  // Check tab titles and custom colors
  REQUIRE(state->deckTabButtons.count == 5);
  CHECK([state->deckTabButtons[0].title isEqualToString:@"TUNER"]);
  CHECK([state->deckTabButtons[1].title isEqualToString:@"PREAMP"]);
  CHECK([state->deckTabButtons[2].title isEqualToString:@"POWER STAGE"]);
  CHECK([state->deckTabButtons[3].title isEqualToString:@"CAB LAB & SPEAKER"]);
  CHECK([state->deckTabButtons[4].title isEqualToString:@"POST-FX STUDIO"]);
  for (NSInteger i = 0; i < 5; ++i) {
    CHECK(state->deckTabButtons[i].customTextColor != nil);
  }

  // Check compressor bypass button
  REQUIRE(state->compressorButton);
  CHECK([state->compressorButton isDescendantOf:pane1]);
  CHECK(state->compressorButton.tag == (NSInteger)kCompressorEnabledPort);
  CHECK(state->compressorButton.state == NSControlStateValueOn);
  CHECK([state->compressorButton.title isEqualToString:@"ON"]);

  // Check compressor knobs 3, 42, 43
  CHECK(kRigKnobPorts[3] == 28 && kRigKnobPorts[42] == kCompressorAttackPort &&
        kRigKnobPorts[43] == kCompressorReleasePort);
  CHECK(kRigKnobDefaults[3] == 0.0f && kRigKnobDefaults[42] == kCompressorAttackDefault &&
        kRigKnobDefaults[43] == kCompressorReleaseDefault);
  for (size_t k : {3u, 42u, 43u}) {
    REQUIRE(state->deckKnobs[k] && state->deckValueLabels[k]);
    CHECK(state->deckKnobs[k].tag == (NSInteger)kRigKnobPorts[k]);
    CHECK([state->deckKnobs[k] isDescendantOf:pane1]);
  }

  // Check compressor visualizer
  REQUIRE(state->compressorVisualizer);
  CHECK([state->compressorVisualizer isDescendantOf:pane1]);
  CHECK(state->compressorVisualizer.enabled == YES);
  CHECK(near(state->compressorVisualizer.amount, 0.0f));
  CHECK(near(state->compressorVisualizer.attack, 8.0f));
  CHECK(near(state->compressorVisualizer.releaseTime, 120.0f));

  // Echo telemetry updates visualizer and bypass
  echo(kCompressorEnabledPort, 0.0f);
  drain();
  CHECK(state->compressorVisualizer.enabled == NO);
  CHECK(state->compressorButton.state == NSControlStateValueOff);
  CHECK([state->compressorButton.title isEqualToString:@"OFF"]);

  echo(kCompressorEnabledPort, 1.0f);
  drain();
  CHECK(state->compressorVisualizer.enabled == YES);
  CHECK(state->compressorButton.state == NSControlStateValueOn);
  CHECK([state->compressorButton.title isEqualToString:@"ON"]);

  echo(28, 65.0f);
  echo(kCompressorAttackPort, 15.5f);
  echo(kCompressorReleasePort, 350.0f);
  drain();
  CHECK(near(state->compressorVisualizer.amount, 65.0f));
  CHECK(near(state->compressorVisualizer.attack, 15.5f));
  CHECK(near(state->compressorVisualizer.releaseTime, 350.0f));
  CHECK(near(state->deckKnobs[3].floatValue, 65.0f));
  CHECK(near(state->deckKnobs[42].floatValue, 15.5f));
  CHECK(near(state->deckKnobs[43].floatValue, 350.0f));

  // User toggle writes to host
  host.writes.clear();
  state->compressorButton.state = NSControlStateValueOff;
  action(state->compressorButton);
  CHECK(host.writes[kCompressorEnabledPort].size() == 1);
  CHECK(near(host.writes[kCompressorEnabledPort].back(), 0.0f));

  // User knob changes write to host
  host.writes.clear();
  state->deckKnobs[42].floatValue = 25.0f;
  action(state->deckKnobs[42]);
  CHECK(host.writes[kCompressorAttackPort].size() == 1);
  CHECK(near(host.writes[kCompressorAttackPort].back(), 25.0f));

  host.writes.clear();
  state->deckKnobs[43].floatValue = 200.0f;
  action(state->deckKnobs[43]);
  CHECK(host.writes[kCompressorReleasePort].size() == 1);
  CHECK(near(host.writes[kCompressorReleasePort].back(), 200.0f));

  // Check slot preset dropdown for compressor
  stage = "Pre-Amp compressor / slot presets";
  NSInteger slot = -1;
  for (NSUInteger i = 0; i < state->deckSlotSpecs.count; ++i) {
    if ([state->deckSlotSpecs[i][@"key"] isEqualToString:@"compressor"]) slot = (NSInteger)i;
  }
  REQUIRE(slot >= 0);
  NSMutableDictionary* spec = state->deckSlotSpecs[(NSUInteger)slot];
  NSPopUpButton* popup = spec[@"popup"];
  REQUIRE(popup);
  CHECK([spec[@"title"] isEqualToString:@"Pre-Amp Compressor"]);
  CHECK([[NSSet setWithArray:spec[@"ports"]]
      isEqualToSet:[NSSet setWithArray:@[@28, @(kCompressorAttackPort), @(kCompressorReleasePort), @(kCompressorEnabledPort)]]]);

  // Exercise every factory menu entry, including enabling after bypass and
  // values captured by user-saved slot presets. Keep the legacy indices intact.
  struct ExpectedPreset { NSString* title; float amount, attack, releaseTime; };
  const ExpectedPreset presets[] = {
      {@"SMOOTH SUSTAIN", 40.0f, 15.0f, 200.0f},
      {@"PUNCHY ATTACK", 50.0f, 30.0f, 80.0f},
      {@"FAST SQUASH", 65.0f, 2.0f, 60.0f},
      {@"TRANSPARENT", 25.0f, 10.0f, 150.0f},
      {@"OFF / BYPASS", 0.0f, 8.0f, 120.0f},
      {@"METAL PICK CLARITY", 22.0f, 35.0f, 70.0f},
      {@"SHRED DEFINITION", 28.0f, 25.0f, 50.0f},
      {@"THRASH PRECISION", 18.0f, 20.0f, 45.0f},
      {@"SINGING METAL LEAD", 32.0f, 30.0f, 140.0f}};
  CHECK([spec[@"factoryTitles"] count] == sizeof(presets) / sizeof(presets[0]));
  for (const auto& p : presets) {
    [popup selectItemWithTitle:p.title];
    REQUIRE([popup.titleOfSelectedItem isEqualToString:p.title]);
    host.writes.clear();
    action(popup);
    drain();
    const float enabled = p.amount > 0.0f ? 1.0f : 0.0f;
    const std::pair<uint32_t, float> values[] = {
        {28, p.amount}, {kCompressorAttackPort, p.attack},
        {kCompressorReleasePort, p.releaseTime}, {kCompressorEnabledPort, enabled}};
    NSDictionary* captured = state->captureSlotPortValues(slot);
    CHECK(host.writes.size() == 4);
    for (const auto& [port, value] : values) {
      REQUIRE(host.writes[port].size() == 1);
      CHECK(near(host.writes[port].back(), value));
      NSNumber* saved = captured[[NSString stringWithFormat:@"%u", port]];
      REQUIRE(saved);
      CHECK(near(saved.floatValue, value));
    }
    CHECK(near(state->deckKnobs[3].floatValue, p.amount));
    CHECK(near(state->deckKnobs[42].floatValue, p.attack));
    CHECK(near(state->deckKnobs[43].floatValue, p.releaseTime));
    CHECK(near(state->compressorVisualizer.amount, p.amount));
    CHECK(near(state->compressorVisualizer.attack, p.attack));
    CHECK(near(state->compressorVisualizer.releaseTime, p.releaseTime));
    CHECK(state->compressorVisualizer.enabled == (enabled > 0.0f));
    CHECK(state->compressorButton.state == (enabled > 0.0f ? NSControlStateValueOn : NSControlStateValueOff));
    CHECK([spec[@"selectedTitle"] isEqualToString:p.title]);
    CHECK([spec[@"selectedIsUser"] boolValue] == NO);
  }

  // Reset to default
  [[presetClass defaultPreset] applyToState:state];
  drain();
}

static void verifyTunerDeck(Runtime& runtime, Host& host) {
  RigUIState* state = runtime.state;
  stage = "Tuner deck / tab 0 selection and display update";
  state->selectDeckTab(0);
  drain();
  [runtime.window.contentView layoutSubtreeIfNeeded];

  REQUIRE(state->deckTabPanes.count >= 5);
  NSView* pane0 = (NSView*)state->workspace;
  REQUIRE(pane0 && !pane0.isHiddenOrHasHiddenAncestor);
  REQUIRE(state->tunerPanel && !state->tunerPanel.isHidden);
  REQUIRE(state->tunerButton);
  CHECK(state->tunerButton.state == NSControlStateValueOn);
  CHECK(state->activeDeckTab == 0);

  // Initial state without notes
  state->lastTunerNote = -1.0f;
  state->lastTunerCents = 0.0f;
  state->updateTunerDisplay();
  drain();
  CHECK([state->tunerNoteLabel.stringValue isEqualToString:@"—"]);
  CHECK(state->tunerNeedle.isHidden == YES);

  // Send detected pitch (e.g. A4 = 69, 0 cents)
  state->lastTunerNote = 69.0f;
  state->lastTunerCents = 0.0f;
  state->updateTunerDisplay();
  drain();
  CHECK([state->tunerNoteLabel.stringValue isEqualToString:@"A4"]);
  CHECK([state->tunerCentsLabel.stringValue containsString:@"IN TUNE"]);
  CHECK(state->tunerNeedle.isHidden == NO);

  // Send flat pitch (e.g. E2 = 40, -10 cents)
  state->lastTunerNote = 40.0f;
  state->lastTunerCents = -10.0f;
  state->updateTunerDisplay();
  drain();
  CHECK([state->tunerNoteLabel.stringValue isEqualToString:@"E2"]);
  CHECK([state->tunerCentsLabel.stringValue containsString:@"FLAT"]);

  // Switch to another tab (e.g. tab 1 PREAMP)
  state->selectDeckTab(1);
  drain();
  CHECK(state->tunerPanel.isHidden == YES);
  CHECK(state->tunerButton.state == NSControlStateValueOff);
  CHECK([state->tunerNoteLabel.stringValue isEqualToString:@"—"]);
  CHECK(state->tunerNeedle.isHidden == YES);

  // While inactive, updateTunerDisplay should not display pitch on inactive deck
  state->lastTunerNote = 45.0f;
  state->updateTunerDisplay();
  drain();
  CHECK([state->tunerNoteLabel.stringValue isEqualToString:@"—"]);

  // Switch back to Tuner tab
  state->selectDeckTab(0);
  drain();
  CHECK(state->tunerPanel.isHidden == NO);
  CHECK(state->tunerButton.state == NSControlStateValueOn);
  state->lastTunerNote = 64.0f; // E4
  state->lastTunerCents = 3.0f;
  state->updateTunerDisplay();
  drain();
  CHECK([state->tunerNoteLabel.stringValue isEqualToString:@"E4"]);
  CHECK([state->tunerCentsLabel.stringValue containsString:@"SHARP"]);

  // Workspace navigation must activate the tuner and leave it without resetting
  // the requested stage or module through the legacy tab synchronization.
  RigButton* tunerNavigation = nil;
  NSUInteger tunerDestinations = 0;
  for (RigButton* button in [(id)state->workspace valueForKey:@"moduleButtons"]) {
    if (![button.accessibilityIdentifier isEqualToString:@"tuner"]) continue;
    tunerNavigation = button;
    ++tunerDestinations;
  }
  REQUIRE(tunerNavigation);
  CHECK(tunerDestinations == 1);
  NSArray<RigButton*>* chainButtons = [(id)state->workspace valueForKey:@"chainButtons"];
  CHECK(tunerNavigation.superview == (NSView*)state->workspace);
  CHECK(NSMaxX(tunerNavigation.frame) < NSMinX(chainButtons.firstObject.frame));
  [state->workspace selectStage:4];
  [tunerNavigation performClick:nil];
  CHECK(tunerNavigation.primary);
  for (RigButton* button in chainButtons) CHECK(!button.primary);
  CHECK(state->activeDeckTab == 0);
  CHECK([state->workspace.selectedModule isEqualToString:@"tuner"]);
  state->selectDeckTab(0);
  CHECK(state->activeDeckTab == 0);
  CHECK([state->workspace.selectedModule isEqualToString:@"tuner"]);
  [state->workspace selectModule:@"delay"];
  CHECK(state->activeDeckTab != 0);
  CHECK(state->workspace.selectedStage == 4);
  CHECK([state->workspace.selectedModule isEqualToString:@"delay"]);
  NSArray<RigButton*>* moduleButtons = [(id)state->workspace valueForKey:@"moduleButtons"];
  NSUInteger visibleSelected = 0;
  for (RigButton* button in moduleButtons) {
    if (!button.isHiddenOrHasHiddenAncestor && button.primary) {
      ++visibleSelected;
      CHECK([button.accessibilityIdentifier isEqualToString:@"delay"]);
    }
  }
  CHECK(visibleSelected == 1);
  [state->workspace selectModule:@"tuner"];
  [state->workspace selectStage:2];
  CHECK(state->activeDeckTab != 0);
  CHECK(state->workspace.selectedStage == 2);
  CHECK([state->workspace.selectedModule isEqualToString:@"main"]);
}


static void verifyTunerTools(Runtime& runtime, Host& host) {
  stage = "Tuner tools / tuning, calibration, intonation and tone lifetime";
  auto* state = runtime.state;
  [state->workspace selectModule:@"tuner"];
  auto* panel = (NAMRigTunerWorkspace*)state->tunerWorkspace;
  REQUIRE(panel);
  NSPopUpButton* preset = [panel valueForKey:@"preset"];
  CHECK([preset.itemTitles containsObject:@"8-string Drop E"]);
  CHECK([preset.itemTitles containsObject:@"Save Tuning As…"]);
  [preset selectItemWithTitle:@"7-string Drop A"]; action(preset);
  NSArray<RigButton*>* strings = [panel valueForKey:@"stringButtons"];
  CHECK(strings.count == 7);
  action(strings.firstObject);
  CHECK(strings.firstObject.primary);
  CHECK([[(NSTextField*)[panel valueForKey:@"target"] stringValue] containsString:@"A1"]);
  NSTextField* notes = [panel valueForKey:@"notes"];
  notes.stringValue = @"E1 B1 E2 A2 D3 G3 B3 E4"; action(notes);
  CHECK([[panel valueForKey:@"stringButtons"] count] == 8);
  notes.stringValue = @"invalid"; action(notes);
  CHECK([[panel valueForKey:@"stringButtons"] count] == 8);
  notes.stringValue = @"E2 A2 D3 G3 B3 E4"; action(notes);
  NSTextField* reference = [panel valueForKey:@"reference"];
  reference.stringValue = @"442 Hz"; action(reference);
  CHECK(near(reference.doubleValue, 442));
  reference.stringValue = @"999"; action(reference);
  CHECK(near(reference.doubleValue, 442));
  reference.stringValue = @"440"; action(reference);
  Method modal = class_getInstanceMethod(NSAlert.class, @selector(runModal));
  IMP originalModal = method_setImplementation(modal, (IMP)slotPresetDialog);
  [preset selectItemWithTitle:@"Save Tuning As…"]; action(preset);
  CHECK([preset.titleOfSelectedItem isEqualToString:@"Runtime Saved Tuning"]);
  notes.stringValue = @"B1 E2 A2 D3 G3 B3 E4"; action(notes);
  [preset selectItemWithTitle:@"Save Tuning"]; action(preset);
  [preset selectItemWithTitle:@"6-string Standard"]; action(preset);
  [preset selectItemWithTitle:@"Runtime Saved Tuning"]; action(preset);
  CHECK([[panel valueForKey:@"stringButtons"] count] == 7);
  [preset selectItemWithTitle:@"Rename Tuning…"]; action(preset);
  CHECK([preset.titleOfSelectedItem isEqualToString:@"Runtime Renamed Tuning"]);
  CHECK(![preset.itemTitles containsObject:@"Runtime Saved Tuning"]);
  [preset selectItemWithTitle:@"Delete Tuning"]; action(preset);
  CHECK(![preset.itemTitles containsObject:@"Runtime Renamed Tuning"]);
  CHECK([[panel valueForKey:@"stringButtons"] count] == 6);
  method_setImplementation(modal, originalModal);
  double time = CACurrentMediaTime();
  auto feed = [&](double pitch) {
    for (int i=0;i<16;++i) {
      time += .05;
      [panel pushPitch:pitch confidence:.99 level:-18 atTime:time];
    }
  };
  feed(40);
  CHECK([[(NSTextField*)[panel valueForKey:@"quality"] stringValue] isEqualToString:@"Stable"]);
  RigButton* base = [panel valueForKey:@"captureBase"];
  RigButton* fret = [panel valueForKey:@"captureFret"];
  CHECK(base.enabled); action(base);
  feed(40); CHECK(!fret.enabled); // Reject the open-string octave.
  feed(52.12); CHECK(fret.enabled); action(fret);
  CHECK([[(NSTextField*)[panel valueForKey:@"intonation"] stringValue] containsString:@"+12.0"]);
  CHECK([[(NSTextField*)[panel valueForKey:@"advice"] stringValue] containsString:@"Lengthen"]);
  if (const char* png = std::getenv("AXE_FX_TUNER_UI_PNG")) {
    [runtime.window orderFront:nil];
    [runtime.window.contentView layoutSubtreeIfNeeded];
    NSBitmapImageRep* rep = [panel bitmapImageRepForCachingDisplayInRect:panel.bounds];
    [panel cacheDisplayInRect:panel.bounds toBitmapImageRep:rep];
    CHECK([[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
      writeToFile:[NSString stringWithUTF8String:png] atomically:YES]);
  }
  NSPopUpButton* baseline = [panel valueForKey:@"baselineMode"];
  [baseline selectItemAtIndex:1]; action(baseline);
  feed(52); action(base); feed(51.92); action(fret);
  CHECK([[(NSTextField*)[panel valueForKey:@"intonation"] stringValue] containsString:@"-8.0"]);
  RigButton* tone = [panel valueForKey:@"toneButton"];
  host.patches.clear(); action(tone);
  CHECK(!host.patches.empty());
  CHECK(host.patches.back().first == state->tunerToneURID);
  CHECK(near(host.patches.back().second,440));
  CHECK(!base.enabled);
  [state->workspace selectStage:2];
  CHECK(host.patches.back().first == state->tunerToneURID);
  CHECK(near(host.patches.back().second,0));
  [state->workspace selectModule:@"tuner"];
  strings = [panel valueForKey:@"stringButtons"]; action(strings.firstObject);
  NSPopUpButton* toneTarget = [panel valueForKey:@"toneTarget"];
  [toneTarget selectItemAtIndex:1]; action(toneTarget);
  action(tone);
  CHECK(near(host.patches.back().second, 82.406889));
  state->selectTab(1);
  [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
  CHECK(near(host.patches.back().second,0));
  state->selectTab(0);
  [toneTarget selectItemAtIndex:0]; action(toneTarget);
  [state->workspace selectStage:2];
}

static void verifyDeckTabSelection(Runtime& runtime, Host& host) {
  RigUIState* state = runtime.state;
  stage = "deck tab selection / immediate visibility and serialized background requests";
  testedPort = -1;
  auto selected = [&](NSInteger tab) {
    CHECK(state->activeDeckTab == tab);
    for (NSUInteger i = 0; i < state->deckTabPanes.count; ++i) {
      CHECK(bool(state->deckTabPanes[i].hidden) == ((NSInteger)i != tab));
      CHECK(state->deckTabButtons[i].state == ((NSInteger)i == tab
          ? NSControlStateValueOn : NSControlStateValueOff));
    }
  };
  host.writes.clear();
  for (NSInteger tab : {4, 1, 2, 3, 2}) {
    state->selectDeckTab(tab);
    selected(tab); // No run-loop pump: the main-thread transaction is immediate.
  }
  CHECK(host.writes.empty());
  std::thread selection([&] {
    for (NSInteger tab : {4, 1, 2}) state->selectDeckTab(tab);
  });
  selection.join();
  // Wait for the queued transitions themselves, rather than a fixed run-loop slice.
  __block BOOL selectionFinished = NO;
  dispatch_async(dispatch_get_main_queue(), ^{ selectionFinished = YES; });
  while (!selectionFinished) drain();
  selected(2);
  CHECK(host.writes.empty());
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
  constexpr std::array<NSInteger, kRackCount> tabs = {4, 4, 4, 2, 1, 2, 3, 3, 2};
  NSArray<NSString*>* moduleKeys = @[@"delay", @"reverb", @"spatial", @"power", @"sculpt",
                                     @"transformer", @"speaker", @"cablab", @"power"];
  for (size_t i = 0; i < kRackCount; ++i) {
    state->selectDeckTab(tabs[i]);
    [state->workspace selectModule:moduleKeys[i]];
    CHECK(!state->deckTabPanes[(NSUInteger)tabs[i]].hidden);
    drain();
    [runtime.window.contentView layoutSubtreeIfNeeded];
    RigButton* button = state->rackButtons[i];
    REQUIRE(button);
    testedPort = button.tag;
    CHECK(button.tag == (NSInteger)(kRackControlFirstPort + i));
    CHECK(button.target == (id)state->uiController);
    CHECK(button.action == NSSelectorFromString(@"controlChanged:"));
    if (!CHECK(button.isEnabled && !button.isHiddenOrHasHiddenAncestor)) {
      std::fprintf(stderr, "  rack index: %zu, port: %ld, tab: %ld, active tab: %ld, enabled: %d\n",
                   i, (long)button.tag, (long)tabs[i], (long)state->activeDeckTab, (int)button.isEnabled);
    }
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
  state->selectDeckTab(2);
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
  state->selectDeckTab(2);
  drain();
  [runtime.window.contentView layoutSubtreeIfNeeded];
  REQUIRE(state->deckTabPanes.count > 1);
  REQUIRE(state->powerTubePopup && state->powerTubeVisualizer);
  NSSlider* knob = state->deckKnobs[37];
  NSTextField* field = state->deckValueLabels[37];
  REQUIRE(knob && field && state->rackButtons[powerIndex] && state->rackButtons[tubeIndex]);
  CHECK(kRigControlPortCount == 195 && tubePort == 79 && kRigKnobPorts[37] == 81);
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

  stage = "Power Stage three racks / geometry / aligned control zones";
  NSView* pane = (NSView*)state->workspace;
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
  NSArray<NSString*>* titles = @[@"DYNAMIC POWER STAGE",
                               @"POWER TUBE CHARACTER", @"OUTPUT TRANSFORMER"];
  const size_t rackIndices[] = {powerIndex, tubeIndex, (size_t)Rack::Transformer};
  REQUIRE(state->powerVisualizer && state->powerTubeVisualizer && state->transformerVisualizer);
  REQUIRE(state->deckKnobs[21] && state->powerTubePopup && state->transformerSpecLabels[0]);
  NSArray<NSView*>* visualizers = @[state->powerVisualizer,
                                 state->powerTubeVisualizer, state->transformerVisualizer];
  NSArray<NSView*>* topControls = @[state->deckKnobs[21],
                                 state->powerTubePopup, state->transformerSpecLabels[0]];
  NSMutableArray<NSView*>* racks = [NSMutableArray array];
  NSArray<NSString*>* moduleKeys = @[@"power", @"power", @"transformer"];
  for (size_t i = 0; i < 3; ++i) {
    [state->workspace selectModule:moduleKeys[i]];
    drain();
    [runtime.window.contentView layoutSubtreeIfNeeded];
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
  for (size_t index : {21u, 16u, 17u, 18u, 37u}) {
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
  [state->workspace selectModule:@"power"];
  drain();
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

static void verifyPostCompressor(Runtime& runtime, Host& host, Class presetClass) {
  using namespace NAMRig;
  RigUIState* state = runtime.state;
  stage = "Post-FX compressor / layout, automation, presets and independent bypass";
  state->selectDeckTab(4);
  drain();
  [runtime.window.contentView layoutSubtreeIfNeeded];
  NSView* pane = (NSView*)state->workspace;
  REQUIRE(state->postCompressorButton && state->postCompressorVisualizer);
  CHECK([state->postCompressorButton isDescendantOf:pane]);
  CHECK([state->postCompressorVisualizer isDescendantOf:pane]);
  CHECK(state->postCompressorVisualizer.bounds.size.width > 150);
  CHECK(state->postCompressorVisualizer.bounds.size.height > 30);
  for (size_t k : {44u, 45u, 46u}) {
    REQUIRE(state->deckKnobs[k] && state->deckValueLabels[k]);
    CHECK([state->deckKnobs[k] isDescendantOf:pane]);
    CHECK(state->deckKnobs[k].tag == (NSInteger)kRigKnobPorts[k]);
    NSView* cell = state->deckKnobs[k].superview;
    CHECK(cell.bounds.size.width >= 70);
    CHECK(NSContainsRect(NSInsetRect(cell.bounds, -0.5, -0.5), state->deckValueLabels[k].frame));
  }
  NSInteger slot = -1;
  for (NSUInteger i = 0; i < state->deckSlotSpecs.count; ++i)
    if ([state->deckSlotSpecs[i][@"key"] isEqualToString:@"post_compressor"]) slot = (NSInteger)i;
  REQUIRE(slot >= 0);
  NSMutableDictionary* spec = state->deckSlotSpecs[(NSUInteger)slot];
  NSPopUpButton* popup = spec[@"popup"];
  CHECK([spec[@"ports"] count] == 4);
  const float preAmount = state->currentPortValueForSlot(28);
  [popup selectItemWithTitle:@"SMOOTH LEAD"];
  host.writes.clear();
  action(popup);
  drain();
  CHECK(near(state->postCompressorVisualizer.amount, 45));
  CHECK(near(state->postCompressorVisualizer.attack, 12));
  CHECK(near(state->postCompressorVisualizer.releaseTime, 200));
  CHECK(state->postCompressorEnabled == 1);
  CHECK(host.writes[28].empty() && host.writes[kCompressorEnabledPort].empty());
  CHECK(near(state->currentPortValueForSlot(28), preAmount));

  float attack = 35;
  runtime.descriptor->port_event(state, kPostCompressorAttackPort, sizeof(attack), 0, &attack);
  drain();
  CHECK(near(state->deckKnobs[45].floatValue, 35));
  CHECK(near(state->postCompressorVisualizer.attack, 35));
  state->postCompressorButton.state = NSControlStateValueOff;
  host.writes.clear();
  action(state->postCompressorButton);
  drain();
  CHECK(state->postCompressorEnabled == 0 && !state->postCompressorVisualizer.enabled);
  CHECK(near(state->currentPortValueForSlot(kPostCompressorAmountPort), 45));
  CHECK(host.writes[kPostCompressorEnabledPort].size() == 1);
  NSDictionary* values = state->captureSlotPortValues(slot);
  CHECK([values[@"189"] floatValue] == 0);
  CHECK([values[@"186"] floatValue] == 45);
  state->userSlotPresets[@"post_compressor"] = [@{@"Test Stereo": values} mutableCopy];
  state->rebuildSlotPresetMenu(slot);
  [popup selectItemWithTitle:@"STUDIO GLUE"];
  action(popup);
  drain();
  [popup selectItemWithTitle:@"Test Stereo"];
  action(popup);
  drain();
  CHECK(state->postCompressorEnabled == 0);
  CHECK(near(state->postCompressorVisualizer.amount, 45));
  RigPreset* captured = [presetClass captureFromState:state name:@"Post Dynamics"];
  CHECK([captured controlForPort:kPostCompressorEnabledPort] == 0);
  CHECK([captured controlForPort:kPostCompressorAmountPort] == 45);
  NSString* path = [testRoot stringByAppendingPathComponent:@"post-dynamics.json"];
  REQUIRE([captured saveToFile:path error:nil]);
  RigPreset* loaded = [presetClass loadFromFile:path];
  REQUIRE(loaded);
  CHECK([loaded controlForPort:kPostCompressorAmountPort] == 45);
  CHECK([loaded controlForPort:kPostCompressorAttackPort] == 35);
  CHECK([loaded controlForPort:kPostCompressorReleasePort] == 200);
  CHECK([loaded controlForPort:kPostCompressorEnabledPort] == 0);
  [[presetClass defaultPreset] applyToState:state];
  drain();
  CHECK(state->postCompressorEnabled == 1 && state->postCompressorVisualizer.amount == 0);
  [captured applyToState:state];
  drain();
  CHECK(state->postCompressorEnabled == 0 && state->postCompressorVisualizer.amount == 45);
  RigPreset* sparse = [[presetClass alloc] init];
  [sparse applyToState:state];
  drain();
  CHECK(state->postCompressorEnabled == 1 && state->postCompressorVisualizer.amount == 0);
  CHECK(state->postCompressorVisualizer.attack == 8 && state->postCompressorVisualizer.releaseTime == 120);
  [state->userSlotPresets[@"post_compressor"] removeObjectForKey:@"Test Stereo"];
}

static void verifyPedalInputVisibility(Runtime& runtime, Host& host, Class presetClass) {
  RigUIState* state = runtime.state;
  stage = "pedal input visibility / display refresh must not reset recalled gain";
  testedPort = 4;
  REQUIRE(state->pedalInputKnobCell);
  const float gain = 3.25f;
  runtime.descriptor->port_event(state, 4, sizeof(gain), 0, &gain);
  drain();
  host.writes.clear();
  state->displayPath(0, "");
  state->displayPath(0, "");
  drain();
  CHECK(!state->pedalInputKnobCell.hidden);


  CHECK(host.writes.empty());
  CHECK(near(state->currentPortValueForSlot(4), gain));

  // Exercise the exported host-notification path as well as direct refreshes.
  LV2_Atom_Forge forge;
  lv2_atom_forge_init(&forge, state->map);
  alignas(LV2_Atom_Object) uint8_t buffer[128]{};
  lv2_atom_forge_set_buffer(&forge, buffer, sizeof(buffer));
  LV2_Atom_Forge_Frame frame;
  REQUIRE(lv2_atom_forge_object(&forge, &frame, 0, state->patchSet));
  lv2_atom_forge_key(&forge, state->patchProperty);
  lv2_atom_forge_urid(&forge, state->pathURIDs[0]);
  lv2_atom_forge_key(&forge, state->patchValue);
  lv2_atom_forge_path(&forge, "", 1);
  lv2_atom_forge_pop(&forge, &frame);
  const auto* atom = reinterpret_cast<const LV2_Atom*>(buffer);
  runtime.descriptor->port_event(state, 1, lv2_atom_total_size(atom), state->eventTransfer, buffer);
  drain();
  CHECK(host.writes.empty());
  CHECK(near(state->currentPortValueForSlot(4), gain));

  RigPreset* recalled = [presetClass captureFromState:state name:@"Hidden Pedal Input"];
  CHECK(near([recalled controlForPort:4], gain));
  [recalled applyToState:state];
  CHECK(near(state->currentPortValueForSlot(4), gain));
  host.writes.clear();
  drain();
  CHECK(host.writes.empty());
  CHECK(near(state->currentPortValueForSlot(4), gain));
  [[presetClass defaultPreset] applyToState:state];
  drain();
  host.writes.clear();
}

static void verifyEffectGraphGeometry(Runtime& runtime) {
  RigUIState* state = runtime.state;
  stage = "effect graphics / parameter meaning / readable compact and wide plots";
  NAMCompressorVisualizer* comp = state->compressorVisualizer;
  NAMCompressorVisualizer* stereo = state->postCompressorVisualizer;
  NAMDelayTapVisualizer* delay = state->delayVisualizer;
  NAMReverbDecayVisualizer* reverb = state->reverbVisualizer;
  NAMBoostVisualizer* boost = state->boostVisualizer;
  comp.amount = 40; comp.attack = 8; comp.releaseTime = 120;
  stereo.amount = 40; stereo.attack = 8; stereo.releaseTime = 120;
  delay.timeMs = 400; delay.feedback = 40; delay.mix = 40;
  reverb.preDelay = 20; reverb.decay = 20; reverb.size = 50; reverb.mix = 40;
  boost.drive = 40; boost.tight = 400; boost.tone = 50; boost.voicing = 0;
  NSArray<NAMInteractiveGraph*>* graphs = @[comp, stereo, delay, reverb, boost];
  const NSUInteger pinCounts[] = {3, 3, 2, 2, 3};
  for (NSUInteger i = 0; i < graphs.count; ++i) {
    NSRect frame = graphs[i].frame;
    for (CGFloat width : {320.0, 1000.0}) {
      [graphs[i] setFrameSize:NSMakeSize(width, 420)];
      for (NSUInteger pin = 0; pin < pinCounts[i]; ++pin) {
        NSPoint p = [graphs[i] controlPointForIndex:pin];
        CHECK(std::isfinite(p.x) && std::isfinite(p.y));
        CHECK(NSContainsRect(graphs[i].bounds, NSMakeRect(p.x - 5, p.y - 5, 10, 10)));
      }
    }
    graphs[i].frame = frame;
  }
  NSPoint original = [comp controlPointForIndex:1];
  comp.attack = 60;
  CHECK([comp controlPointForIndex:1].x > original.x);
  original = [comp controlPointForIndex:2];
  comp.releaseTime = 600;
  CHECK([comp controlPointForIndex:2].x > original.x);
  original = [stereo controlPointForIndex:2];
  stereo.releaseTime = 600;
  CHECK([stereo controlPointForIndex:2].x > original.x);
  original = [delay controlPointForIndex:0];
  delay.timeMs = 800;
  CHECK([delay controlPointForIndex:0].x > original.x);
  original = [delay controlPointForIndex:1];
  delay.feedback = 70;
  CHECK([delay controlPointForIndex:1].y > original.y);
  original = [delay controlPointForIndex:0];
  delay.mix = 80;
  CHECK([delay controlPointForIndex:0].y > original.y);
  original = [reverb controlPointForIndex:0];
  reverb.preDelay = 200;
  CHECK([reverb controlPointForIndex:0].x > original.x);
  original = [reverb controlPointForIndex:0];
  reverb.mix = 80;
  CHECK([reverb controlPointForIndex:0].y > original.y);
  original = [boost controlPointForIndex:1];
  boost.tight = 1000;
  CHECK([boost controlPointForIndex:1].x > original.x);
  original = [boost controlPointForIndex:2];
  boost.tone = 80;
  CHECK([boost controlPointForIndex:2].y > original.y);
  boost.voicing = (int)NAMRig::Overdrive::Voicing::Clean;
  boost.drive = 0;
  original = [boost controlPointForIndex:0];
  boost.drive = 100;
  CHECK(near([boost controlPointForIndex:0].y, original.y)); // Clean gain must not falsely show clipping.
  [[NSClassFromString(@"RigPreset") defaultPreset] applyToState:state];
  drain();
}

static void verifyCombinedPinResponse(Runtime& runtime, Host& host) {
  using namespace NAMRig;
  RigUIState* state = runtime.state;
  stage = "pin EQ / one combined response / overlapping bands / drag follows curve";
  [state->workspace selectStage:3];
  [state->workspace selectModule:@"cablab"];
  state->updateControl(26, 80);
  state->updateControl(27, 10000);
  const auto setBand = [&](size_t band, int shape, float hz, float gain) {
    state->updateControl(pinEqPort(PinEqPane::CabConsole, band, kPinShape), shape);
    state->updateControl(pinEqPort(PinEqPane::CabConsole, band, kPinFreq), hz);
    state->updateControl(pinEqPort(PinEqPane::CabConsole, band, kPinGain), gain);
    state->updateControl(pinEqPort(PinEqPane::CabConsole, band, kPinQ), .8f);
  };
  for (size_t b = 0; b < kPinEqBandCount; ++b) setBand(b, kPinOff, 1000, 0);
  setBand(0, kPinBell, 80, 0);
  setBand(1, kPinBell, 160, 6);
  drain();
  [runtime.window.contentView layoutSubtreeIfNeeded];
  NAMPinEQEditor* editor = state->cabConsoleVisualizer.pinEditor;
  REQUIRE(editor.baseResponseDb);
  const NSRect plot = NSInsetRect(editor.bounds, kPinEditorInset, kPinEditorInset);
  const auto point = [&](size_t band) {
    return ((NSPoint (*)(id, SEL, NSInteger))objc_msgSend)(editor, sel_registerName("pointForBand:"), (NSInteger)band);
  };
  const auto pointFor = [&](double hz, double db) {
    return NSMakePoint(NSMinX(plot) + std::log(hz / 20) / std::log(1000.0) * NSWidth(plot),
        NSMidY(plot) + std::clamp(db, -18.0, 18.0) / 18 * NSHeight(plot) * .5);
  };
  const auto bands = readPinBands(PinEqPane::CabConsole, [&](uint32_t port) { return state->currentPortValueForSlot(port); });
  for (size_t b = 0; b < 2; ++b) {
    double hz = bands[b].freq;
    double expected = editor.baseResponseDb(hz) + pinBandsMagnitudeDb(bands, hz, 192000.0);
    CHECK(std::abs([editor responseDbAtFrequency:hz] - expected) < .0001);
    CHECK(std::abs(point(b).y - pointFor(hz, expected).y) < .001);
  }
  CHECK(std::abs(point(0).y - pointFor(80, 0).y) > 1); // The pin follows the filters, not raw band gain.
  const auto mouse = [&](NSEventType type, NSPoint p) {
    return [NSEvent mouseEventWithType:type location:[editor convertPoint:p toView:nil]
        modifierFlags:0 timestamp:0 windowNumber:runtime.window.windowNumber context:nil
        eventNumber:0 clickCount:1 pressure:1];
  };
  for (int shape : {kPinBell, kPinLowShelf, kPinHighShelf}) {
    setBand(0, shape, 80, 0);
    NSPoint start = point(0);
    NSPoint desired = pointFor(100, 5);
    // A grab slightly off-center must preserve its offset rather than jump.
    NSPoint down = NSMakePoint(start.x + 2, start.y - 2);
    NSPoint destination = NSMakePoint(desired.x + 2, desired.y - 2);
    host.writes.clear();
    [editor mouseDown:mouse(NSEventTypeLeftMouseDown, down)];
    [editor mouseDragged:mouse(NSEventTypeLeftMouseDragged, destination)];
    [editor mouseUp:mouse(NSEventTypeLeftMouseUp, destination)];
    CHECK(std::abs([editor responseDbAtFrequency:100] - 5) < .002);
    CHECK(std::hypot(point(0).x - desired.x, point(0).y - desired.y) < .1);
    CHECK(host.writes.count(pinEqPort(PinEqPane::CabConsole, 0, kPinGain)) == 1);
    CHECK(host.writes.count(26) == 0 && host.writes.count(27) == 0);
  }
  stage = "pin EQ / adding a pin on the curve preserves the response";
  double before = [editor responseDbAtFrequency:400];
  NSPoint onCurve = pointFor(400, before);
  host.writes.clear();
  ((void (*)(id, SEL, NSPoint))objc_msgSend)(editor, sel_registerName("addPinAt:"), onCurve);
  CHECK(std::abs([editor responseDbAtFrequency:400] - before) < .001);
  CHECK(std::abs(state->currentPortValueForSlot(pinEqPort(PinEqPane::CabConsole, 2, kPinGain))) < .001);
  for (NAMPinEQEditor* graph : state->pinEditors) CHECK(graph.baseResponseDb != nil);
  [[NSClassFromString(@"RigPreset") defaultPreset] applyToState:state];
  drain();
}

static void verifyGraphEditing(Runtime& runtime, Host& host, Class presetClass) {
  RigUIState* state = runtime.state;
  stage = "transformer summaries / direct typing / units / atomic validation";
  const auto echo = [&](uint32_t port, float value) {
    runtime.descriptor->port_event(state, port, sizeof(value), 0, &value);
  };
  echo(30, NAMRig::OutputTransformer::kUKVintage);
  for (size_t i = 0; i < NAMRig::kTransformerControlCount; ++i)
    echo(60 + i, NAMRig::kTransformerControlDefaults[i]);
  drain();
  const size_t indices[4][2] = {{0, 1}, {2, 3}, {6, 5}, {9, 8}};
  const float values[4][2] = {{80, 12000}, {3, 44}, {2.8f, 2850}, {1.6f, 6500}};
  NSArray<NSString*>* inputs = @[@"8e1 Hz - 1.2e1 kHz", @"3x / 44% Mix", @"+2.8 dB @ 2.85 kHz", @"+1.6 dB @ 6.50 kHz"];
  for (size_t group = 0; group < 4; ++group) {
    NSTextField* field = state->transformerSpecLabels[group];
    REQUIRE(field && field.editable && field.selectable && field.enabled);
    CHECK(field.target == (id)state->uiController && field.delegate == (id)state->uiController);
    host.writes.clear();
    field.stringValue = inputs[group];
    action(field);
    auto actual = NAMRig::OutputTransformer::controlValues(state->transformerVisualizer.parameters);
    for (size_t k = 0; k < 2; ++k) {
      CHECK(near(actual[indices[group][k]], values[group][k]));
      CHECK(host.writes[60 + indices[group][k]].size() == 1);
    }
    CHECK(state->presetManager.isModified);
    RigPreset* captured = [presetClass captureFromState:state name:@"Typed Transformer"];
    for (size_t k = 0; k < 2; ++k)
      CHECK(near([captured controlForPort:60 + indices[group][k]], state->transformerAdjustments[indices[group][k]]));
    host.writes.clear();
    action(field); // Enter followed by focus loss must not commit rounded text twice.
    [(id<TransformerTestController>)state->uiController controlTextDidEndEditing:
        [NSNotification notificationWithName:NSControlTextDidEndEditingNotification object:field]];
    CHECK(host.writes.empty());
  }
  NSArray<NSString*>* invalid = @[@"80 Hz - nope", @"3x / 1e999%", @"+2 dB @ 4 kHz junk", @"nan dB @ 5 kHz"];
  for (size_t group = 0; group < 4; ++group) {
    auto before = state->transformerAdjustments;
    NSTextField* field = state->transformerSpecLabels[group];
    NSString* original = field.stringValue;
    field.stringValue = invalid[group];
    host.writes.clear();
    action(field);
    CHECK(host.writes.empty());
    CHECK(state->transformerAdjustments == before);
    CHECK([field.stringValue isEqualToString:original]);
  }
  NSTextField* editing = state->transformerSpecLabels[0];
  [(id<TransformerTestController>)state->uiController controlTextDidBeginEditing:
      [NSNotification notificationWithName:NSControlTextDidBeginEditingNotification object:editing]];
  editing.stringValue = @"90 Hz - 11 kHz";
  echo(60, 1);
  drain();
  CHECK([editing.stringValue isEqualToString:@"90 Hz - 11 kHz"]);
  [(id<TransformerTestController>)state->uiController controlTextDidEndEditing:
      [NSNotification notificationWithName:NSControlTextDidEndEditingNotification object:editing]];
  CHECK(near(state->transformerVisualizer.parameters.lowCutHz, 90));
  CHECK(near(state->transformerVisualizer.parameters.highCutHz, 11000));

  stage = "response pins / real mouse drags / knob binding / host writes / preset capture";
  echo(36, 25); echo(37, 0); echo(28, 40); echo(NAMRig::kPostCompressorAmountPort, 40);
  echo(NAMRig::kCompressorEnabledPort, 1);
  echo(53, 35); echo(54, 30); echo(33, 35); echo(NAMRig::kOverdriveDrivePort, 30);
  echo(NAMRig::kOverdriveEnabledPort, 1);
  drain();
  NSArray<NSView*>* graphs = @[state->powerVisualizer, state->compressorVisualizer,
      state->postCompressorVisualizer, state->delayVisualizer, state->reverbVisualizer,
      state->spatialVisualizer, state->boostVisualizer, state->powerTubeVisualizer,
      state->transformerVisualizer];
  NSArray<NSString*>* modules = @[@"power", @"compressor", @"postcomp", @"delay", @"reverb", @"spatial", @"boost", @"power", @"transformer"];
  const std::vector<std::vector<uint32_t>> expectedPorts = {
    {37, 36}, {28, 182, 183}, {186, 187, 188}, {50, 51}, {58, 55}, {32, 33}, {179, 190, 180}, {81}, {62, 60, 61, 65, 68}
  };
  for (NSUInteger i = 0; i < graphs.count; ++i) {
    [state->workspace selectModule:modules[i]];
    drain();
    [runtime.window.contentView layoutSubtreeIfNeeded];
    NAMGraphControlEditor* editor = nil;
    for (NSView* view in graphs[i].subviews)
      if ([view isKindOfClass:NSClassFromString(@"NAMGraphControlEditor")]) editor = (NAMGraphControlEditor*)view;
    REQUIRE(editor && editor.pins.count > 0);
    CHECK(NSEqualRects(editor.frame, graphs[i].bounds));
    REQUIRE(editor.pins.count == expectedPorts[i].size());
    for (NSUInteger pinIndex = 0; pinIndex < editor.pins.count; ++pinIndex) {
    NSPoint start = [editor pointForPin:pinIndex];
    CHECK(NSContainsRect(editor.bounds, NSMakeRect(start.x - 5, start.y - 5, 10, 10)));
    CHECK([editor hitTest:[editor convertPoint:start toView:editor.superview]] == editor);
    CHECK([editor hitTest:[editor convertPoint:NSMakePoint(2, 2) toView:editor.superview]] == nil);
    uint32_t port = expectedPorts[i][pinIndex];
    testedPort = port;
    float before = state->currentPortValueForSlot(port);
    const auto event = [&](NSEventType type, NSPoint point, NSEventModifierFlags modifiers = 0) {
      return [NSEvent mouseEventWithType:type location:[editor convertPoint:point toView:nil]
          modifierFlags:modifiers timestamp:0 windowNumber:runtime.window.windowNumber context:nil
          eventNumber:0 clickCount:1 pressure:1];
    };
    host.writes.clear();
    [editor mouseDown:event(NSEventTypeLeftMouseDown, start)];
    [editor mouseUp:event(NSEventTypeLeftMouseUp, start)];
    CHECK(host.writes.empty());
    [editor mouseDown:event(NSEventTypeLeftMouseDown, start)];
    NSPoint finish = NSMakePoint(start.x + 24, start.y - 20);
    [editor mouseDragged:event(NSEventTypeLeftMouseDragged, finish)];
    [editor mouseUp:event(NSEventTypeLeftMouseUp, finish)];
    REQUIRE(host.writes.count(port) == 1 && !host.writes[port].empty());
    float after = state->currentPortValueForSlot(port);
    CHECK(!near(after, before));
    CHECK(near(host.writes[port].back(), after));
    const auto* contract = NAMRig::rigControlContract(port);
    REQUIRE(contract);
    CHECK(NAMRig::validRigControlValue(*contract, after));
    RigPreset* captured = [presetClass captureFromState:state name:@"Dragged Response"];
    CHECK(near([captured controlForPort:port], after));
    if (i == 0 && pinIndex == 0) {
      float fullChange = std::abs(after - before);
      echo(port, before);
      drain();
      start = [editor pointForPin:pinIndex];
      finish = NSMakePoint(start.x + 24, start.y - 20);
      [editor mouseDown:event(NSEventTypeLeftMouseDown, start)];
      [editor mouseDragged:event(NSEventTypeLeftMouseDragged, finish, NSEventModifierFlagShift)];
      [editor mouseUp:event(NSEventTypeLeftMouseUp, finish)];
      after = state->currentPortValueForSlot(port);
      CHECK(std::abs(std::abs(after - before) / fullChange - .1) < .002);
    }
    if (port < 60 || port == 81) {
      for (size_t k = 0; k < kRigKnobCount; ++k)
        if (kRigKnobPorts[k] == port && state->knobs[k]) CHECK(near(state->knobs[k].floatValue, after));
    }
  }
  }
  stage = "transformer pins / captured bypass rejects edits";
  echo(30, 0);
  drain();
  NAMGraphControlEditor* editor = nil;
  for (NSView* view in state->transformerVisualizer.subviews)
    if ([view isKindOfClass:NSClassFromString(@"NAMGraphControlEditor")]) editor = (NAMGraphControlEditor*)view;
  REQUIRE(editor);
  CHECK(!editor.pins[0].isEnabled());
  NSView* graph = state->transformerVisualizer;
  NSPoint emptyFrequencyPoint = [state->transformerVisualizer.pinEditor convertPoint:NSMakePoint(40, 40) toView:graph.superview];
  CHECK([graph hitTest:emptyFrequencyPoint] == state->transformerVisualizer.pinEditor);
  host.writes.clear();
  editor.pins[0].onBegin();
  editor.pins[0].onDrag(NSMakePoint(.2, .2));
  editor.pins[0].onCommit();
  CHECK(host.writes.empty());
}

static void verifyStageMeters(Runtime& runtime) {
  RigUIState* state = runtime.state;
  testedPort = -1;
  stage = "stage meters / 1520pt layout / architecture badges / amp value cells";
  [runtime.window.contentView layoutSubtreeIfNeeded];
  CHECK(near(state->rigContent.bounds.size.width, 1520));
  CHECK(near(((NSView*)state->workspace).bounds.size.width, 1520));
  CHECK(near(((NSView*)state->workspace).bounds.size.height, 980));
  CHECK(near(runtime.window.contentView.bounds.size.width, 1520));
  REQUIRE(state->stageCards[0] && state->stageCards[1] && state->stageCards[2]);
  for (size_t i = 0; i < 3; ++i) {
    [state->workspace selectStage:(NSInteger)i + 1];
    CHECK(!state->stageCards[i].isHiddenOrHasHiddenAncestor);
    CHECK(near(state->stageCards[i].bounds.size.width, i == 0 ? 480 : 960));
  }
  for (size_t i = 0; i < 3; ++i) {
    NSTextField* badge = state->stageHeaderArchBadges[i];
    REQUIRE(badge && badge.superview);
    NSString* original = badge.stringValue;
    badge.stringValue = i < 2 ? @"  A2 \u00b7 WAVENET  " : @"  WAV IR  ";
    [runtime.window.contentView layoutSubtreeIfNeeded];
    CHECK(badge.bounds.size.width + 0.5 >= badge.intrinsicContentSize.width);
    CHECK(NSContainsRect(badge.superview.bounds, badge.frame));
    for (NSView* sibling in badge.superview.subviews)
      if (sibling != badge && !sibling.hidden) CHECK(!NSIntersectsRect(badge.frame, sibling.frame));
    badge.stringValue = original;
  }
  for (size_t slot : {4u, 14u, 15u, 5u, 6u, 7u}) {
    const size_t k = kRigKnobDisplayOrder[slot];
    NSSlider* knob = state->knobs[k];
    NSTextField* value = state->valueLabels[k];
    REQUIRE(knob && value && knob.superview);
    NSView* cell = knob.superview;
    CHECK(cell.bounds.size.width >= 70.0);
    CHECK(near(value.bounds.size.width, 70));
    CHECK(NSContainsRect(NSInsetRect(cell.bounds, -0.5, -0.5),
                         [value convertRect:value.bounds toView:cell]));
    CHECK(NSContainsRect(NSInsetRect(cell.bounds, -0.5, -0.5),
                         [knob convertRect:knob.bounds toView:cell]));
  }

  stage = "workspace / compact overviews / shared meters / detail navigation";
  id workspace = state->workspace;
  NSDictionary* pages = [workspace valueForKey:@"pages"];
  NSDictionary* racks = [workspace valueForKey:@"moduleRacks"];
  NSArray<NSArray<NSString*>*>* overviewKeys = @[
    @[@"compressor", @"sculpt", @"boost"], @[], @[], @[@"speaker"],
    @[@"postcomp", @"delay", @"reverb", @"spatial"]
  ];
  for (NSInteger index = 0; index < 5; ++index) {
    [state->workspace selectStage:index];
    drain();
    NSView* page = pages[[NSString stringWithFormat:@"main:%ld", (long)index]];
    NSView* context = [workspace valueForKey:@"contextHost"];
    CHECK(context.hidden == (index <= 1 || index == 4));
    if (context.hidden) CHECK(context.subviews.count == 0);
    if (index == 1) {
      for (NSString* key in @[@"compressor", @"sculpt", @"boost"])
        CHECK(((NSView*)racks[key]).superview == pages[@"main:0"]);
    }


    for (NSString* key in overviewKeys[index]) {
      NSView* rack = racks[key];
      CHECK(rack.superview == page);
      CHECK(!rack.isHiddenOrHasHiddenAncestor);
      if (index == 0 || index == 4) CHECK(near(rack.bounds.size.height, 630));
      CHECK(NSContainsRect(page.bounds, rack.frame));
      [state->workspace selectModule:key];
      CHECK(rack.superview == pages[key]);
      CHECK(context.hidden == (index <= 1 || index == 4));
      if (context.hidden) CHECK(context.subviews.count == 0);
      CHECK(!rack.isHiddenOrHasHiddenAncestor);
      [state->workspace selectStage:index];
      CHECK(rack.superview == page);
    }
    for (RigStageMeterView* meter : state->stageMeters) {
      CHECK(meter.horizontal);
      CHECK(!meter.isHiddenOrHasHiddenAncestor);
      CHECK(meter.bounds.size.height <= 42);
      CHECK(meter.bounds.size.width >= 300);
    }
  }

  stage = "workspace / cabinet navigation has one blend destination";
  [state->workspace selectStage:3];
  [state->workspace selectModule:@"align"];
  CHECK([state->workspace.selectedModule isEqualToString:@"cablab"]);
  CHECK(!((NSView*)racks[@"cablab"]).isHiddenOrHasHiddenAncestor);
  for (RigButton* button in [workspace valueForKey:@"moduleButtons"])
    CHECK(![button.accessibilityIdentifier isEqualToString:@"align"]);

  stage = "stage meters / independent exported patch:Set routing";
  const std::array<LV2_URID, 4> properties = {state->inputDbURID, state->preAmpDbURID,
                                            state->postAmpDbURID, state->outputDbURID};
  NSArray<NSString*>* titles = @[@"IN", @"PRE", @"POST", @"OUT"];
  LV2_Atom_Forge forge;
  lv2_atom_forge_init(&forge, state->map);
  auto notify = [&](size_t i, float db) {
    alignas(LV2_Atom_Object) uint8_t buffer[128]{};
    lv2_atom_forge_set_buffer(&forge, buffer, sizeof(buffer));
    LV2_Atom_Forge_Frame frame;
    REQUIRE(lv2_atom_forge_object(&forge, &frame, 0, state->patchSet));
    lv2_atom_forge_key(&forge, state->patchProperty);
    lv2_atom_forge_urid(&forge, properties[i]);
    lv2_atom_forge_key(&forge, state->patchValue);
    lv2_atom_forge_float(&forge, db);
    lv2_atom_forge_pop(&forge, &frame);
    const auto* atom = reinterpret_cast<const LV2_Atom*>(buffer);
    runtime.descriptor->port_event(state, 1, lv2_atom_total_size(atom), state->eventTransfer, buffer);
  };
  std::array<float, 4> expected = {-35, -45, -55, -65};
  auto coherent = ^{
    const float last[] = {state->lastInputDb, state->lastPreAmpDb,
                          state->lastPostAmpDb, state->lastOutputDb};
    for (size_t i = 0; i < state->stageMeters.size(); ++i)
      CHECK(near(state->stageMeters[i].levelDb, last[i]));
  };
  auto levels = [&] {
    const float last[] = {state->lastInputDb, state->lastPreAmpDb,
                          state->lastPostAmpDb, state->lastOutputDb};
    for (size_t i = 0; i < expected.size(); ++i) {
      CHECK(near(state->stageMeters[i].levelDb, expected[i]));
      CHECK(near(last[i], expected[i]));
    }
  };
  for (size_t i = 0; i < properties.size(); ++i) {
    REQUIRE(properties[i] && state->stageMeters[i]);
    CHECK(state->stageMeters[i].window == runtime.window);
    NSTimer* timer = [state->stageMeters[i] valueForKey:@"meterTimer"];
    REQUIRE(timer && timer.isValid);
    CHECK(near(timer.timeInterval, 1.0 / 30.0));
    CHECK([state->stageMeters[i].title isEqualToString:titles[i]]);
    [state->workspace selectStage:(NSInteger)(i == 0 ? 0 : i == 1 ? 1 : i == 2 ? 3 : 4)];
    CHECK(!state->stageMeters[i].isHiddenOrHasHiddenAncestor);
    CHECK(state->stageMeters[i].bounds.size.width > 0 && state->stageMeters[i].bounds.size.height > 0);
    for (size_t j = 0; j < i; ++j) CHECK(properties[i] != properties[j]);
    notify(i, expected[i]);
  }
  // Run immediately after delivery blocks but before any nested dispatches.
  // Widget levels and logical telemetry must advance in the same transaction.
  dispatch_async(dispatch_get_main_queue(), coherent);
  drain();
  levels();
  for (size_t i = 0; i < properties.size(); ++i) {
    expected[i] = -30.0f - (float)i;
    notify(i, expected[i]);
    drain();
    levels();
    CHECK(near(state->stageMeters[i].peakDb, expected[i]));
    CHECK(!state->stageMeters[i].clipping);
  }

  stage = "stage meters / queued clip peak survives 20dB per second notifications";
  const double start = CACurrentMediaTime();
  auto waitUntil = [&](double seconds) {
    const double remaining = start + seconds - CACurrentMediaTime();
    if (remaining > 0)
      [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:remaining]];
  };
  // Queue peaks and lower levels before any drain: reading a shared last-value
  // slot in the dispatched block would lose both the transient and its clip.
  notify(0, 0); // No more valid IN notifications: sustained clipping must outlive the hold.
  notify(3, 0); notify(3, -1);
  for (size_t i : {1u, 2u}) { notify(i, -20); notify(i, -40); }
  expected = {0, -40, -40, -1};
  drain();
  levels();
  for (int step = 1; step <= 3; ++step) {
    waitUntil(step * 0.1);
    expected[3] = -2.0f * step;
    notify(3, expected[3]);
    drain();
    levels();
    for (size_t i : {0u, 3u}) {
      CHECK(near(state->stageMeters[i].peakDb, 0));
      CHECK(state->stageMeters[i].clipping);
    }
  }
  CHECK(CACurrentMediaTime() - start < 0.5);

  stage = "stage meters / nonfinite notifications ignored / 1.2 second clip hold";
  waitUntil(0.9);
  std::array<float, 4> peaks{};
  for (size_t i = 0; i < properties.size(); ++i) peaks[i] = state->stageMeters[i].peakDb;
  for (float invalid : {std::numeric_limits<float>::quiet_NaN(),
                        std::numeric_limits<float>::infinity(),
                        -std::numeric_limits<float>::infinity()}) {
    for (size_t i = 0; i < properties.size(); ++i) {
      notify(i, invalid);
      [state->stageMeters[i] setLevelDb:invalid];
    }
  }
  drain();
  levels();
  for (size_t i = 0; i < properties.size(); ++i) {
    CHECK(near(state->stageMeters[i].peakDb, peaks[i]));
    CHECK(bool(state->stageMeters[i].clipping) == (i == 0 || i == 3));
  }

  stage = "stage meters / autonomous decay / transient clip expires / sustained clip remains";
  waitUntil(1.35);
  for (size_t i = 0; i < properties.size(); ++i)
    CHECK(bool(state->stageMeters[i].clipping) == (i == 0));
  waitUntil(1.8);
  const double elapsed = CACurrentMediaTime() - start;
  const float decayed = std::max(-40.0f, -20.0f - (float)(20.0 * std::max(0.0, elapsed - 1.2)));
  CHECK(decayed < -28); // About -32 dB, not a frozen -20 dB or an immediate -40 dB.
  for (size_t i : {1u, 2u}) CHECK(std::fabs(state->stageMeters[i].peakDb - decayed) < 1.5f);
  for (size_t i : {0u, 3u}) CHECK(near(state->stageMeters[i].peakDb, expected[i]));
  for (size_t i = 0; i < properties.size(); ++i)
    CHECK(bool(state->stageMeters[i].clipping) == (i == 0));
  levels();
  // The current layout draws readouts and bars inside the four stage widgets;
  // the retired title-bar labels/width constraints are no longer instantiated.
  for (RigStageMeterView* meter : state->stageMeters) {
    NSBitmapImageRep* image = [meter bitmapImageRepForCachingDisplayInRect:meter.bounds];
    REQUIRE(image && image.pixelsWide > 0 && image.pixelsHigh > 0);
    [meter cacheDisplayInRect:meter.bounds toBitmapImageRep:image];
    CHECK(image.bitmapData != nullptr);
  }

  stage = "stage meters / timer attach / detach / reattach / no widget retain cycle";
  __weak RigStageMeterView* weakMeter;
  @autoreleasepool {
    Class meterClass = NSClassFromString(@"RigStageMeterView");
    REQUIRE(meterClass);
    RigStageMeterView* meter = [(RigStageMeterView*)[meterClass alloc]
        initWithTitle:@"TEST" subtitle:@"" accentColor:rigAccent()];
    weakMeter = meter;
    CHECK([meter valueForKey:@"meterTimer"] == nil);
    [runtime.window.contentView addSubview:meter];
    NSTimer* timer = [meter valueForKey:@"meterTimer"];
    REQUIRE(timer && timer.isValid);
    CHECK(near(timer.timeInterval, 1.0 / 30.0));
    [meter removeFromSuperview];
    CHECK(!timer.isValid && [meter valueForKey:@"meterTimer"] == nil);
    [runtime.window.contentView addSubview:meter];
    NSTimer* restarted = [meter valueForKey:@"meterTimer"];
    REQUIRE(restarted && restarted.isValid && restarted != timer);
    [meter removeFromSuperview];
    CHECK(!restarted.isValid);
    meter = nil;
  }
  drain();
  CHECK(weakMeter == nil);

  stage = "stage meters / queued notifications discarded after UI cleanup";
  // No drain before Runtime's destructor: the retained widgets must not receive
  // these valid updates once cleanup has cleared the shared isAlive guard.
  for (size_t i = 0; i < properties.size(); ++i) notify(i, -80.0f - (float)i);
  levels();
}

static void verifyCabSwap(Runtime& runtime) {
  stage = "cab swap / model choices";
  RigUIState* state = runtime.state;
  NSButton* swap = nil;
  for (NSView* view in state->stageCards[2].subviews)
    if ([view isKindOfClass:NSButton.class] &&
        ((NSButton*)view).action == NSSelectorFromString(@"swapCabSelections:"))
      swap = (NSButton*)view;
  REQUIRE(swap);

  NSArray<NSString*>* choicesA = @[@"/tmp/cab-a-1.wav", @"/tmp/cab-a-2.wav"];
  NSArray<NSString*>* choicesB = @[@"/tmp/cab-b-1.wav", @"/tmp/cab-b-2.wav"];
  for (size_t slot : {2u, 3u}) {
    NSArray<NSString*>* choices = slot == 2 ? choicesA : choicesB;
    state->availableModelPaths[slot].clear();
    for (NSString* path in choices) state->availableModelPaths[slot].push_back(path.UTF8String);
  }
  state->selectedPaths[2] = choicesA[1].UTF8String;
  state->selectedPaths[3] = choicesB[0].UTF8String;

  auto verifyChoices = [&](size_t slot, NSArray<NSString*>* expected, NSString* selected) {
    NSPopUpButton* picker = state->modelPickers[slot];
    REQUIRE(picker);
    CHECK(state->availableModelPaths[slot].size() == expected.count);
    for (NSString* path in expected) {
      CHECK(std::find(state->availableModelPaths[slot].begin(),
                      state->availableModelPaths[slot].end(), path.UTF8String) !=
            state->availableModelPaths[slot].end());
      CHECK([picker.menu indexOfItemWithRepresentedObject:path] != -1);
    }
    CHECK([picker.selectedItem.representedObject isEqualToString:selected]);
  };
  action(swap);
  drain();
  verifyChoices(2, choicesB, choicesB[0]);
  verifyChoices(3, choicesA, choicesA[1]);
  for (size_t slot : {2u, 3u}) {
    std::ifstream saved(RigUIState::uiStageModelsFile(slot));
    std::vector<std::string> paths;
    std::string path;
    while (std::getline(saved, path)) paths.push_back(path);
    CHECK(paths == state->availableModelPaths[slot]);
  }
  action(swap);
  drain();
  verifyChoices(2, choicesA, choicesA[1]);
  verifyChoices(3, choicesB, choicesB[0]);

  state->availableModelPaths[3].clear();
  state->selectedPaths[3].clear();
  action(swap);
  drain();
  CHECK(state->selectedPaths[2].empty());
  CHECK(state->availableModelPaths[2].empty());
  CHECK(state->modelPickers[2].selectedItem.representedObject == nil);
  verifyChoices(3, choicesA, choicesA[1]);
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
  stage = "pedalboard / layout, order echo and preset round trip";
  const NSInteger savedBoardTab = state->activeTab;
  state->selectTab(0);
  drain();
  [state->workspace selectStage:1];
  NSDictionary* pedalCards = [(id)state->workspace valueForKey:@"pedalCards"];
  REQUIRE(pedalCards.count == 3);
  for (NSNumber* slot in @[@0, @4, @5]) {
    NSView* card = pedalCards[slot];
    CHECK(!card.isHiddenOrHasHiddenAncestor);
    CHECK(near(card.bounds.size.width, 480));
    REQUIRE(state->modelPickers[slot.unsignedIntegerValue]);
    REQUIRE(state->powerButtons[slot.unsignedIntegerValue]);
  }
  void (^moveSlot)(NSInteger, NSInteger) = [pedalCards[@0] valueForKey:@"moveSlot"];
  REQUIRE(moveSlot);
  if (const char* png = std::getenv("AXE_FX_PEDAL_UI_PNG")) {
    [runtime.window.contentView layoutSubtreeIfNeeded];
    NSBitmapImageRep* image = [state->view bitmapImageRepForCachingDisplayInRect:state->view.bounds];
    [state->view cacheDisplayInRect:state->view.bounds toBitmapImageRep:image];
    CHECK([[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[NSString stringWithUTF8String:png] atomically:YES]);
  }
  NSView* sourceCard = pedalCards[@0];
  NSPoint headerPoint = NSMakePoint(NSMinX(sourceCard.frame) + 40, NSMaxY(sourceCard.frame) - 28);
  CHECK([sourceCard hitTest:headerPoint] == sourceCard);
  PedalTestDrag* drag = [PedalTestDrag new];
  drag.draggingSource = sourceCard;
  CHECK([(id)pedalCards[@5] draggingEntered:(id)drag] == NSDragOperationMove);
  CHECK([(id)pedalCards[@5] performDragOperation:(id)drag]);
  CHECK(state->pedalOrder == 3);
  CHECK(near([pedalCards[@0] frame].origin.x, 992));
  state->updateControl(NAMRig::kPedalOrderPort, 5);
  state->updateControl(NAMRig::kPedal2EnabledPort, 1);
  state->updateControl(NAMRig::kPedal3EnabledPort, 1);
  CHECK(near([pedalCards[@5] frame].origin.x, 0));
  CHECK(near([pedalCards[@4] frame].origin.x, 496));
  RigPreset* boardPreset = [(id)NSClassFromString(@"RigPreset") captureFromState:state name:@"Three pedals"];
  NSString* boardFile = [testRoot stringByAppendingPathComponent:@"pedalboard.json"];
  CHECK([boardPreset saveToFile:boardFile error:nil]);
  RigPreset* boardRead = [(id)NSClassFromString(@"RigPreset") loadFromFile:boardFile];
  REQUIRE(boardRead);
  CHECK([boardRead stageAtIndex:4]->enabled && [boardRead stageAtIndex:5]->enabled);
  CHECK([boardRead controlForPort:NAMRig::kPedalOrderPort] == 5);
  [[(id)NSClassFromString(@"RigPreset") defaultPreset] applyToState:state];
  CHECK(state->extraPedalEnabled[0] == 0 && state->extraPedalEnabled[1] == 0);
  CHECK(state->pedalOrder == 0);
  state->selectTab(savedBoardTab);
  drain();
  host.writes.clear();

  CHECK(!state->pedalInputKnobCell.hidden);
  REQUIRE(state->keyEventMonitor && installedKeyHandler);
  CHECK([state->presetManager.presetsDirectory hasPrefix:testRoot]);
  CHECK([RigUIState::slotPresetsFilePath() hasPrefix:testRoot]);
  [(id<TransformerTestController>)state->uiController showAmpAdvanced:nil];
  [state->workspace selectModule:@"transformer"];
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
      if (!CHECK(host.writes.empty())) {
        std::fprintf(stderr, "  apply path: %s, group: %zu\n", path.UTF8String, group);
        for (const auto& [port, sent] : host.writes)
          for (float value : sent)
            std::fprintf(stderr, "  unexpected write: port %u = %.9g\n", port, value);
      }
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
  verifyDeckTabSelection(runtime, host);
  verifyRackSwitches(runtime, host, presetClass);
  verifyPowerTube(runtime, host, presetClass);
  verifyPinEditors(runtime, host, presetClass);
  verifySculptOverdrive(runtime, host, presetClass);
  verifyCompressorPreAmp(runtime, host, presetClass);
  verifyPostCompressor(runtime, host, presetClass);
  verifyTunerDeck(runtime, host);
  verifyTunerTools(runtime, host);
  verifyPedalInputVisibility(runtime, host, presetClass);
  verifyCabSwap(runtime);
  verifyStageMeters(runtime);
  verifyGraphEditing(runtime, host, presetClass);
  verifyCombinedPinResponse(runtime, host);
  verifyEffectGraphGeometry(runtime);
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
    std::printf("%s: transformer / power tube / rack / stage meter UI runtime, %d checks, %d failures\n",
                 failures ? "FAIL" : "PASS", checks, failures);
    if (syntheticShortcutFocus)
      std::puts("LIMITATION: inactive CLI app; save shortcuts used the module's installed key-monitor handler with synthetic key-window ownership.");
    return failures ? 1 : 0;
  }
}
