#import <Cocoa/Cocoa.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

#include <lv2/atom/atom.h>
#include <lv2/atom/forge.h>
#include <lv2/atom/util.h>
#include <lv2/core/lv2.h>
#include <lv2/patch/patch.h>
#include <lv2/ui/ui.h>
#include <lv2/urid/urid.h>

// Tuner patch property URIs — must match nam_rig_plugin.h (kept local so the
// UI target doesn't need the DSP header's NeuralAudio includes).
#define NAM_RIG_URI "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig"
#define NAM_RIG_TUNER_NOTE_URI NAM_RIG_URI "-tuner-note"
#define NAM_RIG_TUNER_CENTS_URI NAM_RIG_URI "-tuner-cents"
#define NAM_RIG_INPUT_DB_URI NAM_RIG_URI "-input-db"

#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

constexpr const char* kRigURI = "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig";
constexpr const char* kRigUIURI = "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig-ui";
constexpr std::array<const char*, 4> kPathURIs{
    "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig-pedal-model",
    "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig-amp-model",
    "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig-cab-model",
    "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig-cab2-model"};

static NSArray<NSString*>* oversampleDescriptions() {
  static NSArray<NSString*>* descriptions = @[
    @"None — Runs the model without rate adaptation. Use only when the model and session rates already match; otherwise timing and tone may be wrong.",
    @"Legacy — Adapts the model by scaling its internal dilation. Uses less CPU, but does not provide true anti-alias filtering.",
    @"True 2x — Upsamples, runs the nonlinear model at 2x, then filters back down for lower aliasing with a moderate CPU cost.",
    @"True 4x — Runs the nonlinear model in a true 4x domain for stronger alias rejection at a higher CPU cost.",
    @"True 8x — Maximum-quality true oversampling and strongest alias rejection; also the highest CPU setting."
  ];
  return descriptions;
}

static NSString* popupTooltip(NSString* purpose, NSPopUpButton* popup) {
  NSString* selected = popup.selectedItem.toolTip;
  return selected.length
      ? [NSString stringWithFormat:@"%@ %@", purpose, selected]
      : purpose;
}

static NSString* stageName(NSInteger stage) {
  return stage == 0 ? @"pedal" : (stage == 1 ? @"amp" : @"cabinet");
}

#import "rig_theme.h"
#import "rig_widgets.h"
#include "rig_knobs.h"
#include "oversample_modes.h"
#include "rig_ui_state.h"
#import "rig_tone_browser.h"

@interface NAMRigUIController : NSObject <NSComboBoxDelegate, NSTextFieldDelegate>
@property(nonatomic, assign) RigUIState* state;
- (void)chooseModel:(NSButton*)sender;
- (void)clearModel:(NSButton*)sender;
- (void)controlChanged:(NSSlider*)sender;
- (void)knobFieldCommitted:(NSTextField*)sender;
- (void)tunerToggled:(NSButton*)sender;
- (void)oversampleModeChanged:(NSPopUpButton*)sender;      // master (title bar)
- (void)stageOversampleChanged:(NSPopUpButton*)sender;     // per-stage (tiles)
- (void)irNormalizationChanged:(NSPopUpButton*)sender;
- (void)transformerChanged:(NSPopUpButton*)sender;
- (void)showAmpAdvanced:(NSButton*)sender;
- (void)speakerProfileChanged:(NSPopUpButton*)sender;
- (void)showSpeakerLoad:(NSButton*)sender;
- (void)showEffects:(NSButton*)sender;
- (void)resetAllKnobs:(NSButton*)sender;
- (void)zoomChanged:(NSComboBox*)sender;
- (void)stageModelChanged:(NSPopUpButton*)sender;
- (void)presetPopupChanged:(NSPopUpButton*)sender;
- (void)prevPresetClicked:(NSButton*)sender;
- (void)nextPresetClicked:(NSButton*)sender;
- (void)saveCurrentPreset:(id)sender;
- (void)savePresetAs:(id)sender;
- (void)deleteCurrentPreset:(id)sender;
- (void)revealPresetsInFinder:(id)sender;
- (void)switchTab:(NSButton*)sender;
- (void)markPresetModified;
@end
@implementation NAMRigUIController
- (void)switchTab:(NSButton*)sender {
  if (!_state) return;
  _state->selectTab(sender.tag);
}
- (void)markPresetModified {
  if (!_state || !_state->presetManager) return;
  if (!_state->presetManager.isModified) {
    _state->presetManager.isModified = YES;
    _state->updatePresetDisplayTitle();
  }
}
- (void)chooseModel:(NSButton*)sender {
  if (!_state || sender.tag < 0 || sender.tag > 3) return;
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.title = [NSString stringWithFormat:@"Choose %@ NAM Model",
                 @[@"a Pedal", @"an Amp", @"a Cab", @"a Cab B"][(NSUInteger)sender.tag]];
  panel.prompt = @"Load Model";
  panel.canChooseFiles = YES;
  panel.canChooseDirectories = NO;
  panel.allowsMultipleSelection = NO;
  panel.allowedFileTypes = sender.tag >= 2
      ? @[@"nam", @"nammodel", @"json", @"aidax", @"aidadspmodel", @"wav"]
      : @[@"nam", @"nammodel", @"json", @"aidax", @"aidadspmodel"];
  if ([panel runModal] == NSModalResponseOK) {
    NSString* chosen = panel.URL.path;
    std::vector<std::string> discovered = discoverModelsForStagePath(chosen.fileSystemRepresentation, (size_t)sender.tag);
    NSMutableArray<NSString*>* paths = [NSMutableArray arrayWithCapacity:discovered.size()];
    for (const auto& m : discovered) {
      if (!m.empty()) [paths addObject:[NSString stringWithUTF8String:m.c_str()]];
    }
    if (paths.count > 0) {
      _state->setStageModels((size_t)sender.tag, paths);
    }
    _state->sendPath((size_t)sender.tag, chosen.fileSystemRepresentation);
    [self markPresetModified];
  }
}

- (void)clearModel:(NSButton*)sender {
  if (_state && sender.tag >= 0 && sender.tag <= 3) {
    _state->setStageModels((size_t)sender.tag, @[]);
    _state->sendPath((size_t)sender.tag, "");
    _state->setStageThumb((size_t)sender.tag, nil, 0, nil);  // revert to placeholder
    [self markPresetModified];
  }
}

- (void)controlChanged:(NSSlider*)sender {
  if (!_state) return;
  _state->sendControl((uint32_t)sender.tag, sender.floatValue);
  _state->updateControl((uint32_t)sender.tag, sender.floatValue);
  [self markPresetModified];
}

// Delegate: track which knob value box the user is editing so live knob/host
// updates don't overwrite the text they're typing.
- (void)controlTextDidBeginEditing:(NSNotification*)obj {
  if (!_state) return;
  NSTextField* f = obj.object;
  if (![f isKindOfClass:[NSTextField class]]) return;
  for (size_t k = 0; k < kRigKnobCount; ++k)
    if (_state->valueLabels[k] == f) _state->knobFieldEditing[k] = true;
}
- (void)controlTextDidEndEditing:(NSNotification*)obj {
  if (!_state) return;
  NSTextField* f = obj.object;
  if (![f isKindOfClass:[NSTextField class]]) return;
  for (size_t k = 0; k < kRigKnobCount; ++k) {
    if (_state->valueLabels[k] == f) {
      _state->knobFieldEditing[k] = false;
      // Commit on click-away / Tab too (Enter already ran the action; the
      // equality guard keeps a no-op focus visit from re-sending the value).
      NSSlider* knob = _state->knobs[k];
      if (![f.stringValue isEqualToString:rigKnobValueText(kRigKnobPorts[k], knob.floatValue)])
        [self knobFieldCommitted:f];
    }
  }
}

// Return pressed (or focus left) in a knob value box: parse the number,
// clamp to the knob's range, drive the knob + DSP, and rewrite the box in
// canonical format. Accepts bare numbers ("3.5") or pasted strings
// ("+3.5 dB"); text with no numeric characters reverts to the current value.
- (void)knobFieldCommitted:(NSTextField*)sender {
  if (!_state) return;
  const NSInteger port = sender.tag;
  ssize_t index = -1;
  for (size_t k = 0; k < kRigKnobCount; ++k)
    if (kRigKnobPorts[k] == (uint32_t)port) { index = (ssize_t)k; break; }
  if (index < 0) return;
  NSSlider* knob = _state->knobs[index];

  NSString* s = [[sender.stringValue stringByTrimmingCharactersInSet:
                  [NSCharacterSet whitespaceCharacterSet]]
                 stringByReplacingOccurrencesOfString:@"dB" withString:@""];
  static NSCharacterSet* numeric = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ numeric = [NSCharacterSet characterSetWithCharactersInString:@"0123456789+-.eE"]; });
  if (!s.length || [s rangeOfCharacterFromSet:numeric].location == NSNotFound) {
    _state->updateControl((uint32_t)port, knob.floatValue);   // revert display
    return;
  }

  const double v = s.doubleValue;
  double clamped = v;
  if (clamped < knob.minValue) clamped = knob.minValue;
  if (clamped > knob.maxValue) clamped = knob.maxValue;
  knob.doubleValue = clamped;
  _state->sendControl((uint32_t)port, (float)clamped);
  _state->updateControl((uint32_t)port, (float)clamped);
  [self markPresetModified];
}

// Tuner on/off: drives the tuner_enable port, swaps the icon brightness,
// and shows/hides the readout panel. DSP analysis only runs while enabled.
- (void)tunerToggled:(NSButton*)sender {
  if (!_state) return;
  const BOOL on = sender.state == NSControlStateValueOn;
  _state->sendControl(16, on ? 1.0f : 0.0f);
  sender.contentTintColor = on ? rigText() : rigDimText();
  sender.needsDisplay = YES;
  _state->tunerPanel.hidden = !on;
  if (!on) {
    _state->tunerNoteLabel.stringValue = @"—";
    _state->tunerCentsLabel.stringValue = @"";
    _state->tunerNeedle.hidden = YES;
  }
}

// Master oversample control (title bar): applies the chosen mode to BOTH
// stages (ports 20 + 21). Kept for quick global A/B; per-stage popups in the
// tiles override individually. The DSP re-creates the loaded models for the
// new rate domain in its worker and swaps them in.
- (void)oversampleModeChanged:(NSPopUpButton*)sender {
  sender.toolTip = popupTooltip(@"Sets both pedal and amp oversampling.", sender);
  if (!_state) return;
  // Master indexes map to the same five sparse values as the stage menus.
  const NSInteger i = sender.indexOfSelectedItem;
  const float mode = (i >= 0 && i < 5)
      ? static_cast<float>(NAMRig::oversampleModeFromMenuIndex((int)i))
      : static_cast<float>(NAMRig::kOversampleTrue8);
  _state->sendControl(20, mode);
  _state->sendControl(21, mode);
  [self markPresetModified];
}

// Per-stage oversample control (pedal/amp tiles): ports 20/21, five visible
// modes mapped onto the sparse LV2 values 0, 1, 4, 5, 6.
- (void)stageOversampleChanged:(NSPopUpButton*)sender {
  sender.toolTip = popupTooltip(
      [NSString stringWithFormat:@"Sets %@-stage oversampling.",
                                 sender.tag == 20 ? @"pedal" : @"amp"], sender);
  if (!_state) return;
  const int mode = NAMRig::oversampleModeFromMenuIndex(
      static_cast<int>(sender.indexOfSelectedItem));
  _state->sendControl((uint32_t)sender.tag, static_cast<float>(mode));
  [self markPresetModified];
}

- (void)irNormalizationChanged:(NSPopUpButton*)sender {
  sender.toolTip = popupTooltip(
      @"Sets WAV impulse-response gain handling. Changes glide smoothly.", sender);
  if (!_state) return;
  _state->sendControl(24, (float)sender.indexOfSelectedItem);
  // Original changes the taps at load time (it bypasses resampling/truncation),
  // so re-send both current cabinet paths whenever the mode changes in either
  // direction. Element applies the control write before the following patch.
  for (size_t stage = 2; stage <= 3; ++stage)
    if (!_state->selectedPaths[stage].empty())
      _state->sendPath(stage, _state->selectedPaths[stage].c_str());
  [self markPresetModified];
}

- (void)transformerChanged:(NSPopUpButton*)sender {
  sender.toolTip = sender.selectedItem.toolTip;
  if (!_state) return;
  _state->sendControl(30, (float)sender.indexOfSelectedItem);
  [self markPresetModified];
}

- (void)showAmpAdvanced:(NSButton*)sender {
  if (!_state || !_state->ampAdvancedPopover) return;
  [_state->ampAdvancedPopover showRelativeToRect:sender.bounds
                                           ofView:sender
                                    preferredEdge:NSRectEdgeMaxY];
}

- (void)speakerProfileChanged:(NSPopUpButton*)sender {
  sender.toolTip = sender.selectedItem.toolTip;
  if (_state) {
    _state->sendControl(42, (float)sender.indexOfSelectedItem);
    [self markPresetModified];
  }
}

- (void)showSpeakerLoad:(NSButton*)sender {
  if (!_state || !_state->speakerPopover) return;
  [_state->speakerPopover showRelativeToRect:sender.bounds ofView:sender
                               preferredEdge:NSRectEdgeMaxY];
}

- (void)showEffects:(NSButton*)sender {
  if (!_state || !_state->effectsPopover) return;
  [_state->effectsPopover showRelativeToRect:sender.bounds ofView:sender
                               preferredEdge:NSRectEdgeMaxY];
}

- (void)resetAllKnobs:(NSButton*)sender {
  (void)sender;
  if (!_state) return;
  for (size_t k = 0; k < kRigKnobCount; ++k) {
    _state->sendControl(kRigKnobPorts[k], kRigKnobDefaults[k]);
    _state->updateControl(kRigKnobPorts[k], kRigKnobDefaults[k]);
  }
  [self markPresetModified];
}

- (void)zoomChanged:(NSComboBox*)sender {
  if (!_state) return;
  NSString* s = [[sender.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
                 stringByReplacingOccurrencesOfString:@"%" withString:@""];
  double pct = s.doubleValue;
  if (pct < 50) pct = 50;        // clamp to a sane range
  if (pct > 400) pct = 400;
  _state->zoom = (CGFloat)(pct / 100.0);
  _state->applyZoom();
  sender.stringValue = [NSString stringWithFormat:@"%.0f%%", pct];
}

// Picking a predefined zoom value from the combo's dropdown also fires the
// zoom (an editable NSComboBox's action isn't reliable for list selections).
- (void)comboBoxSelectionDidChange:(NSNotification*)notification {
  NSComboBox* combo = (NSComboBox*)notification.object;
  if ([combo isKindOfClass:NSComboBox.class]) [self zoomChanged:combo];
}

- (void)stageModelChanged:(NSPopUpButton*)sender {
  if (!_state) return;
  NSMenuItem* item = sender.selectedItem;
  NSString* path = item.representedObject;
  sender.toolTip = _state->modelPickerTooltip((size_t)sender.tag, path);
  if (path.length) {
    _state->sendPath((size_t)sender.tag, path.fileSystemRepresentation);
    [self markPresetModified];
  }
}

- (void)presetPopupChanged:(NSPopUpButton*)sender {
  if (!_state || !_state->presetManager) return;
  NSMenuItem* item = sender.selectedItem;
  NSString* name = item.representedObject ?: item.title;
  if (!name.length) return;
  RigPreset* preset = [_state->presetManager loadPresetNamed:name];
  if (preset) {
    [preset applyToState:_state];
    _state->updatePresetDisplayTitle();
  }
}

- (void)prevPresetClicked:(NSButton*)sender {
  (void)sender;
  if (!_state || !_state->presetManager) return;
  NSString* prev = [_state->presetManager previousPresetName];
  if (prev) {
    RigPreset* preset = [_state->presetManager loadPresetNamed:prev];
    if (preset) {
      [preset applyToState:_state];
      _state->updatePresetDisplayTitle();
    }
  }
}

- (void)nextPresetClicked:(NSButton*)sender {
  (void)sender;
  if (!_state || !_state->presetManager) return;
  NSString* next = [_state->presetManager nextPresetName];
  if (next) {
    RigPreset* preset = [_state->presetManager loadPresetNamed:next];
    if (preset) {
      [preset applyToState:_state];
      _state->updatePresetDisplayTitle();
    }
  }
}

- (void)saveCurrentPreset:(id)sender {
  (void)sender;
  if (!_state || !_state->presetManager) return;
  if ([_state->presetManager.currentPresetName isEqualToString:@"Default Rig"]) {
    [self savePresetAs:sender];
    return;
  }
  NSError* err = nil;
  if ([_state->presetManager saveCurrentPresetFromState:_state error:&err]) {
    _state->updatePresetDisplayTitle();
  } else if (err) {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Save Failed";
    alert.informativeText = err.localizedDescription;
    [alert runModal];
  }
}

- (void)savePresetAs:(id)sender {
  (void)sender;
  if (!_state || !_state->presetManager) return;
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"Save Preset";
  alert.informativeText = @"Enter a name for this preset:";
  [alert addButtonWithTitle:@"Save"];
  [alert addButtonWithTitle:@"Cancel"];

  NSTextField* input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  NSString* initial = [_state->presetManager.currentPresetName isEqualToString:@"Default Rig"]
      ? @"My Custom Tone"
      : _state->presetManager.currentPresetName;
  input.stringValue = initial;
  alert.accessoryView = input;
  [alert.window setInitialFirstResponder:input];

  if ([alert runModal] == NSAlertFirstButtonReturn) {
    NSString* name = [input.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) return;
    NSError* err = nil;
    if ([_state->presetManager savePresetNamed:name fromState:_state error:&err]) {
      _state->updatePresetDisplayTitle();
    } else if (err) {
      NSAlert* fail = [[NSAlert alloc] init];
      fail.messageText = @"Save Failed";
      fail.informativeText = err.localizedDescription;
      [fail runModal];
    }
  }
}

- (void)deleteCurrentPreset:(id)sender {
  (void)sender;
  if (!_state || !_state->presetManager) return;
  NSString* cur = _state->presetManager.currentPresetName;
  if (!cur.length || [cur isEqualToString:@"Default Rig"]) return;

  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"Delete Preset";
  alert.informativeText = [NSString stringWithFormat:@"Are you sure you want to delete '%@'?", cur];
  alert.alertStyle = NSAlertStyleCritical;
  [alert addButtonWithTitle:@"Delete"];
  [alert addButtonWithTitle:@"Cancel"];

  if ([alert runModal] == NSAlertFirstButtonReturn) {
    NSError* err = nil;
    if ([_state->presetManager deletePresetNamed:cur error:&err]) {
      RigPreset* nextP = [_state->presetManager loadPresetNamed:_state->presetManager.currentPresetName];
      if (nextP) [nextP applyToState:_state];
      _state->updatePresetDisplayTitle();
    }
  }
}

- (void)revealPresetsInFinder:(id)sender {
  (void)sender;
  if (!_state || !_state->presetManager) return;
  [_state->presetManager revealPresetsInFinder];
  _state->updatePresetDisplayTitle();
}
@end
static NSTextField* addLabel(NSView* parent,
                             NSString* text,
                             NSRect frame,
                             NSFont* font,
                             NSColor* color,
                             NSTextAlignment alignment = NSTextAlignmentLeft) {
  NSTextField* label = [NSTextField labelWithString:text];
  label.frame = frame;
  label.font = font;
  label.textColor = color;
  label.alignment = alignment;
  [parent addSubview:label];
  return label;
}

static NSSlider* addKnob(NSView* parent,
                         NSInteger port,
                         double value,
                         double minimum,
                         double maximum,
                         NSPoint origin,
                         id target) {
  RigKnob* knob = [[RigKnob alloc] initWithFrame:NSMakeRect(origin.x, origin.y, 64, 64)];
  knob.minValue = minimum;
  knob.maxValue = maximum;
  knob.doubleValue = value;
  knob.defaultValue = value;
  knob.target = target;
  knob.action = @selector(controlChanged:);
  knob.continuous = YES;
  knob.tag = port;
  [parent addSubview:knob];
  return knob;
}

// Styled NAM Rig-style panel (gradient fill + hairline border).
static RigPanel* addPanel(NSView* parent, NSRect frame) {
  RigPanel* panel = [[RigPanel alloc] initWithFrame:frame];
  [parent addSubview:panel];
  return panel;
}

// Flat dark button using the custom RigButton drawing.
static RigButton* rigButton(NSView* parent, NSString* title, id target, SEL action, NSRect frame) {
  RigButton* b = [[RigButton alloc] initWithFrame:frame];
  b.title = title;
  b.target = target;
  b.action = action;
  b.bordered = NO;
  [parent addSubview:b];
  return b;
}

// Convenience: center a view horizontally on a container with an offset.
static void centerX(NSView* v, NSView* to, CGFloat c) {
  v.translatesAutoresizingMaskIntoConstraints = NO;
  [[v.centerXAnchor constraintEqualToAnchor:to.centerXAnchor constant:c] setActive:YES];
}

// Mode selector buttons are built inline in addToneBrowser with per-button
// state tracking; no extra helper needed.

static void addToneBrowser(RigUIState* state, NSView* tonePane) {
  const CGFloat pad = 24.0;
  const CGFloat bw = 1280.0 - pad * 2;

  ToneBrowserController* controller = [[ToneBrowserController alloc] init];
  controller.state = state; state->browserController = controller;
  dispatch_async(dispatch_get_main_queue(), ^{ [controller autoConnect]; });

  // Header: brand + subtle status line.
  NSTextField* toneTitle = addLabel(tonePane, @"TONE3000", NSZeroRect,
                                    [NSFont fontWithName:@"SF Mono Bold" size:16.0] ?: [NSFont boldSystemFontOfSize:16],
                                    rigOrange());
  toneTitle.toolTip = @"Integrated Tone3000 browser for discovering, downloading, and loading NAM captures and cabinet IRs.";
  toneTitle.translatesAutoresizingMaskIntoConstraints = NO;
  [tonePane addSubview:toneTitle];
  [[toneTitle.leadingAnchor constraintEqualToAnchor:tonePane.leadingAnchor constant:216] setActive:YES];
  [[toneTitle.topAnchor constraintEqualToAnchor:tonePane.topAnchor constant:10] setActive:YES];
  [[toneTitle.heightAnchor constraintEqualToConstant:26] setActive:YES];

  controller.authStatus = addLabel(tonePane, @"", NSZeroRect,
                                   [NSFont systemFontOfSize:10], rigDimText());
  controller.authStatus.translatesAutoresizingMaskIntoConstraints = NO;
  [tonePane addSubview:controller.authStatus];
  [[controller.authStatus.leadingAnchor constraintEqualToAnchor:toneTitle.trailingAnchor constant:10] setActive:YES];
  [[controller.authStatus.centerYAnchor constraintEqualToAnchor:toneTitle.centerYAnchor] setActive:YES];
  [[controller.authStatus.widthAnchor constraintEqualToConstant:100] setActive:YES];

  // Mode selector (toggles) + Connect + gear — single row beneath the brand.
  NSArray<NSString*>* modes = @[@"Browse", @"Favorites", @"Recent", @"Local"];
  NSMutableArray<RigButton*>* modeButtons = [NSMutableArray array];
  NSArray<NSString*>* modeTips = @[
    @"Browse the online Tone3000 catalog and locally cached results.",
    @"Show tones marked as favorites in your Tone3000 account.",
    @"Show locally known tones ordered by most recently modified.",
    @"Show only tone packs already downloaded to this Mac."
  ];
  NSView* prevMode = controller.authStatus;
  for (NSInteger i = 0; i < (NSInteger)modes.count; ++i) {
    RigButton* b = rigButton(tonePane, modes[(NSUInteger)i], controller, @selector(selectMode:), NSZeroRect);
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.state = (i == 0) ? NSControlStateValueOn : NSControlStateValueOff;
    b.toolTip = modeTips[(NSUInteger)i];
    [[b.leadingAnchor constraintEqualToAnchor:prevMode.trailingAnchor constant:(i == 0 ? 12 : 6)] setActive:YES];
    [[b.centerYAnchor constraintEqualToAnchor:toneTitle.centerYAnchor] setActive:YES];
    [[b.widthAnchor constraintEqualToConstant:80] setActive:YES];
    [[b.heightAnchor constraintEqualToConstant:26] setActive:YES];
    [modeButtons addObject:b];
    prevMode = b;
  }
  controller.modeButtons = modeButtons;

  controller.gear = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  [controller.gear addItemsWithTitles:@[@"All Gear", @"Amps", @"Cabs", @"Pedals", @"Amp + Cab"]];
  NSArray<NSString*>* gearTips = @[
    @"All Gear — Show every supported capture type.",
    @"Amps — Show amplifier captures only.",
    @"Cabs — Show cabinet captures and impulse responses only.",
    @"Pedals — Show pedal captures only.",
    @"Amp + Cab — Show full-rig captures containing both amplifier and cabinet response."
  ];
  for (NSUInteger item = 0; item < gearTips.count; ++item)
    [controller.gear itemAtIndex:item].toolTip = gearTips[item];
  controller.gear.target = controller; controller.gear.action = @selector(filterChanged:);
  controller.gear.controlSize = NSControlSizeSmall;
  controller.gear.toolTip = @"Filter Tone3000 results by capture type: amps, cabinets, pedals, or complete amp-and-cab rigs.";
  controller.gear.translatesAutoresizingMaskIntoConstraints = NO;
  [tonePane addSubview:controller.gear];
  [[controller.gear.trailingAnchor constraintEqualToAnchor:tonePane.trailingAnchor constant:-134] setActive:YES];
  [[controller.gear.centerYAnchor constraintEqualToAnchor:toneTitle.centerYAnchor] setActive:YES];
  [[controller.gear.widthAnchor constraintEqualToConstant:104] setActive:YES];
  [[controller.gear.heightAnchor constraintEqualToConstant:26] setActive:YES];

  controller.connectButton = rigButton(tonePane, @"Connect", controller,
      @selector(connectTone3000:), NSZeroRect);
  controller.connectButton.primary = NO;
  controller.connectButton.state = NSControlStateValueOff;
  controller.connectButton.toolTip = @"Sign in to Tone3000 in your browser. A stored valid session reconnects automatically.";
  controller.connectButton.translatesAutoresizingMaskIntoConstraints = NO;
  [[controller.connectButton.trailingAnchor constraintEqualToAnchor:controller.gear.leadingAnchor constant:-10] setActive:YES];
  [[controller.connectButton.centerYAnchor constraintEqualToAnchor:toneTitle.centerYAnchor] setActive:YES];
  [[controller.connectButton.widthAnchor constraintEqualToConstant:88] setActive:YES];
  [[controller.connectButton.heightAnchor constraintEqualToConstant:26] setActive:YES];

  RigPanel* browser = [[RigPanel alloc] initWithFrame:NSZeroRect];
  browser.translatesAutoresizingMaskIntoConstraints = NO;
  [tonePane addSubview:browser];
  [[browser.leadingAnchor constraintEqualToAnchor:tonePane.leadingAnchor constant:pad] setActive:YES];
  [[browser.trailingAnchor constraintEqualToAnchor:tonePane.trailingAnchor constant:-pad] setActive:YES];
  [[browser.topAnchor constraintEqualToAnchor:toneTitle.bottomAnchor constant:12] setActive:YES];
  [[browser.bottomAnchor constraintEqualToAnchor:tonePane.bottomAnchor constant:-14] setActive:YES];

  const CGFloat bh = 980.0 - (10.0 + 26.0 + 12.0) - 14.0;

  // Search / sort row.
  controller.search = [[NSSearchField alloc] initWithFrame:NSMakeRect(24, bh - 38, bw * 0.48, 28)];
  controller.search.placeholderString = @"Search Tone3000";
  controller.search.focusRingType = NSFocusRingTypeNone;
  controller.search.toolTip = @"Search Tone3000 by tone title, creator, or gear type. Online results load page by page.";
  controller.search.delegate = controller; [browser addSubview:controller.search];
  controller.sort = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(24 + bw * 0.48 + 12, bh - 38, 160, 28) pullsDown:NO];
  [controller.sort addItemsWithTitles:@[@"Newest", @"Trending", @"Most Downloaded", @"Oldest", @"Best Match"]];
  NSArray<NSString*>* sortTips = @[
    @"Newest — Show the most recently published tones first.",
    @"Trending — Use Tone3000's current popularity ranking.",
    @"Most Downloaded — Show tones with the highest download counts first.",
    @"Oldest — Show the earliest published tones first.",
    @"Best Match — Prioritize search relevance for the current query."
  ];
  for (NSUInteger item = 0; item < sortTips.count; ++item)
    [controller.sort itemAtIndex:item].toolTip = sortTips[item];
  controller.sort.controlSize = NSControlSizeSmall;
  controller.sort.target = controller; controller.sort.action = @selector(sortChanged:);
  controller.sort.toolTip = @"Choose the ordering used for Tone3000 search results.";
  [browser addSubview:controller.sort];
  [ToneBrowserController restoreFilterSelectionForGear:controller.gear sort:controller.sort];
  controller.gear.toolTip = popupTooltip(@"Filters Tone3000 results by capture type.",
                                         controller.gear);
  controller.sort.toolTip = popupTooltip(@"Orders Tone3000 search results.",
                                         controller.sort);

  // Tone cards — multi-column collection view with large readable cards.
  const CGFloat tableWidth = bw - 48;
  NSCollectionViewGridLayout *grid = [[NSCollectionViewGridLayout alloc] init];
  grid.minimumItemSize = NSMakeSize(270, 108);
  grid.maximumItemSize = NSMakeSize(380, 108);
  grid.minimumInteritemSpacing = 14;
  grid.minimumLineSpacing = 14;
  grid.margins = NSEdgeInsetsMake(10, 10, 10, 10);

  const CGFloat scrollH = bh - 38 - 46;
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 38, tableWidth, scrollH)];
  scroll.drawsBackground = NO; scroll.borderType = NSNoBorder;
  scroll.hasVerticalScroller = YES; scroll.autohidesScrollers = YES;
  scroll.toolTip = @"Scrollable Tone3000 results. More online results load automatically near the bottom.";

  controller.collectionView = [[NSCollectionView alloc] initWithFrame:scroll.bounds];
  controller.collectionView.collectionViewLayout = grid;
  controller.collectionView.backgroundColors = @[[NSColor clearColor]];
  controller.collectionView.dataSource = controller;
  controller.collectionView.delegate = controller;
  controller.collectionView.selectable = YES;
  controller.collectionView.toolTip = @"Click a tone card to load its local models or download its available models. Right-click a card to view it on Tone3000.";
  [controller.collectionView registerClass:[ToneCardItem class] forItemWithIdentifier:@"ToneCard"];

  scroll.documentView = controller.collectionView;
  // Infinite scroll: observe the scrollview's bounds change (no delegate
  // protocol exists for NSScrollView) — notification fires on every scroll.
  [NSNotificationCenter.defaultCenter addObserver:controller
                                         selector:@selector(scrollViewDidScroll:)
                                             name:NSViewBoundsDidChangeNotification
                                           object:scroll.contentView];
  [browser addSubview:scroll];

  controller.status = addLabel(browser, @"Scanning NAM Rig's Tone3000 library…", NSMakeRect(24, 12, bw - 48, 20),
                               [NSFont systemFontOfSize:10.5], rigDimText());
  controller.status.lineBreakMode = NSLineBreakByTruncatingTail;
  controller.authStatus.toolTip = @"Tone3000 sign-in and session status.";
  controller.status.toolTip = @"Tone library, search, download, and model-loading status.";
  [controller reloadLibrary:nil];
}
LV2UI_Handle instantiate(const LV2UI_Descriptor*,
                         const char* pluginURI,
                         const char*,
                         LV2UI_Write_Function writeFunction,
                         LV2UI_Controller controller,
                         LV2UI_Widget* widget,
                         const LV2_Feature* const* features) {
  if (!pluginURI || std::strcmp(pluginURI, kRigURI) || !writeFunction || !controller || !widget)
    return nullptr;

  LV2_URID_Map* map = nullptr;
  NSView* parent = nil;
  LV2UI_Resize* resize = nullptr;
  for (const LV2_Feature* const* feature = features; feature && *feature; ++feature) {
    if (!std::strcmp((*feature)->URI, LV2_URID__map))
      map = static_cast<LV2_URID_Map*>((*feature)->data);
    else if (!std::strcmp((*feature)->URI, LV2_UI__parent))
      parent = (__bridge NSView*)(*feature)->data;
    else if (!std::strcmp((*feature)->URI, LV2_UI__resize))
      resize = static_cast<LV2UI_Resize*>((*feature)->data);
  }
  if (!map || !parent) return nullptr;

  @autoreleasepool {
    // AppKit's default hover delay is long for dense controls. This preference
    // affects the current process and makes explanatory subtitles appear fast.
    [[NSUserDefaults standardUserDefaults] setObject:@150
                                              forKey:@"NSInitialToolTipDelay"];
    auto* state = new RigUIState();
    state->write = writeFunction;
    state->controller = controller;
    state->map = map;
    state->parent = parent;
    state->hostResize = resize;
    state->eventTransfer = map->map(map->handle, LV2_ATOM__eventTransfer);
    state->atomObject = map->map(map->handle, LV2_ATOM__Object);
    state->atomPath = map->map(map->handle, LV2_ATOM__Path);
    state->atomURID = map->map(map->handle, LV2_ATOM__URID);
    state->patchGet = map->map(map->handle, LV2_PATCH__Get);
    state->patchSet = map->map(map->handle, LV2_PATCH__Set);
    state->patchProperty = map->map(map->handle, LV2_PATCH__property);
    state->patchValue = map->map(map->handle, LV2_PATCH__value);
    state->atomFloat = map->map(map->handle, LV2_ATOM__Float);
    state->tunerNoteURID = map->map(map->handle, NAM_RIG_TUNER_NOTE_URI);
    state->tunerCentsURID = map->map(map->handle, NAM_RIG_TUNER_CENTS_URI);
    state->inputDbURID = map->map(map->handle, NAM_RIG_INPUT_DB_URI);
    for (size_t i = 0; i < kPathURIs.size(); ++i) state->pathURIDs[i] = map->map(map->handle, kPathURIs[i]);
    lv2_atom_forge_init(&state->forge, map);

    const CGFloat baseW = 1280.0, baseH = 980.0;

    state->view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, baseW, baseH)];
    state->view.wantsLayer = YES;
    state->view.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    state->view.layer.backgroundColor = rigBG().CGColor;

    // `rigContent` is a plain container that owns the whole laid-out UI at base
    // size. It is positioned by frame (NOT Auto Layout) so the host's re-layout
    // of `state->view` can't fight it; zoom scales its LAYER, scaling every
    // pane/graphic/knob/font/browser proportionally. `state->view` (the widget
    // Element hosts) is sized to the zoomed window by applyZoom.
    // `rigContent` is a layer-backed container laid out ONCE at the base size and
    // pinned there (fixed frame, no autoresizing). Zoom applies a pure layer
    // scale transform to it, so every child — tiles, knobs, dropdowns, tone
    // cards, text, images — renders scaled proportionally as one unit. Because
    // the frame is fixed at base, Auto Layout never re-lays children out at the
    // zoomed size, so nothing "stretches" differently from anything else.
    NSView* content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, baseW, baseH)];
    content.wantsLayer = YES;
    content.autoresizingMask = NSViewNotSizable;   // never re-lay out; transform scales it
    content.layer.anchorPoint = CGPointMake(0, 0);
    [state->view addSubview:content];
    state->rigContent = content;

    state->uiController = [[NAMRigUIController alloc] init];
    state->uiController.state = state;

    // Two panes: rigPane for the complete amplifier/pedal/cab rig, and tonePane for Tone3000.
    NSView* rigPane = [[NSView alloc] initWithFrame:NSZeroRect];
    rigPane.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:rigPane];
    [[rigPane.leadingAnchor constraintEqualToAnchor:content.leadingAnchor] setActive:YES];
    [[rigPane.trailingAnchor constraintEqualToAnchor:content.trailingAnchor] setActive:YES];
    [[rigPane.topAnchor constraintEqualToAnchor:content.topAnchor] setActive:YES];
    [[rigPane.bottomAnchor constraintEqualToAnchor:content.bottomAnchor] setActive:YES];
    state->rigPane = rigPane;

    NSView* tonePane = [[NSView alloc] initWithFrame:NSZeroRect];
    tonePane.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:tonePane];
    [[tonePane.leadingAnchor constraintEqualToAnchor:content.leadingAnchor] setActive:YES];
    [[tonePane.trailingAnchor constraintEqualToAnchor:content.trailingAnchor] setActive:YES];
    [[tonePane.topAnchor constraintEqualToAnchor:content.topAnchor] setActive:YES];
    [[tonePane.bottomAnchor constraintEqualToAnchor:content.bottomAnchor] setActive:YES];
    state->tonePane = tonePane;

    // Persistent top tab switcher & zoom control (added to content so they stay pinned above both panes).
    state->rigTabBtn = rigButton(content, @"RIG", state->uiController, @selector(switchTab:), NSZeroRect);
    state->rigTabBtn.tag = 0;
    state->rigTabBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [[state->rigTabBtn.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24] setActive:YES];
    [[state->rigTabBtn.topAnchor constraintEqualToAnchor:content.topAnchor constant:10] setActive:YES];
    [[state->rigTabBtn.widthAnchor constraintEqualToConstant:76] setActive:YES];
    [[state->rigTabBtn.heightAnchor constraintEqualToConstant:26] setActive:YES];
    state->rigTabBtn.toolTip = @"View the amp, pedal, cabinet stages and tone controls.";

    state->toneTabBtn = rigButton(content, @"TONE3000", state->uiController, @selector(switchTab:), NSZeroRect);
    state->toneTabBtn.tag = 1;
    state->toneTabBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [[state->toneTabBtn.leadingAnchor constraintEqualToAnchor:state->rigTabBtn.trailingAnchor constant:6] setActive:YES];
    [[state->toneTabBtn.topAnchor constraintEqualToAnchor:content.topAnchor constant:10] setActive:YES];
    [[state->toneTabBtn.widthAnchor constraintEqualToConstant:98] setActive:YES];
    [[state->toneTabBtn.heightAnchor constraintEqualToConstant:26] setActive:YES];
    state->toneTabBtn.toolTip = @"Browse, search, and download NAM captures and cabinet IRs from Tone3000.";

    state->zoomControl = [[NSComboBox alloc] initWithFrame:NSZeroRect];
    state->zoomControl.target = state->uiController; state->zoomControl.action = @selector(zoomChanged:);
    state->zoomControl.editable = YES;               // custom zoom % only (no preset list)
    state->zoomControl.controlSize = NSControlSizeSmall;
    state->zoomControl.placeholderString = @"100%";
    state->zoomControl.toolTip = @"Set the plug-in interface scale from 50% to 400%. Type a percentage and press Return.";
    state->zoomControl.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:state->zoomControl];
    [[state->zoomControl.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24] setActive:YES];
    [[state->zoomControl.topAnchor constraintEqualToAnchor:content.topAnchor constant:9] setActive:YES];
    [[state->zoomControl.widthAnchor constraintEqualToConstant:100] setActive:YES];
    [[state->zoomControl.heightAnchor constraintEqualToConstant:28] setActive:YES];

    // Layout anchor for the rig header row, starting to the right of the tab buttons.
    NSView* title = [[NSView alloc] initWithFrame:NSZeroRect];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [rigPane addSubview:title];
    [[title.leadingAnchor constraintEqualToAnchor:rigPane.leadingAnchor constant:216] setActive:YES];
    [[title.topAnchor constraintEqualToAnchor:rigPane.topAnchor constant:10] setActive:YES];
    [[title.heightAnchor constraintEqualToConstant:26] setActive:YES];
    [[title.widthAnchor constraintEqualToConstant:6] setActive:YES];

    // Tuner toggle (title bar) — flat icon button, dim when off, bright when on.
    state->tunerButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    state->tunerButton.bordered = NO;
    state->tunerButton.imagePosition = NSImageOnly;
    state->tunerButton.image = [NSImage imageWithSystemSymbolName:@"guitars"
                                          accessibilityDescription:@"Tuner"];
    state->tunerButton.contentTintColor = rigDimText();
    [state->tunerButton setButtonType:NSButtonTypeToggle];
    state->tunerButton.target = state->uiController;
    state->tunerButton.action = @selector(tunerToggled:);
    state->tunerButton.toolTip = @"Toggle the input tuner. It analyzes the raw guitar signal before the gate, gain controls, and model chain.";
    state->tunerButton.translatesAutoresizingMaskIntoConstraints = NO;
    [rigPane addSubview:state->tunerButton];
    [[state->tunerButton.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:6] setActive:YES];
    [[state->tunerButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor] setActive:YES];
    [[state->tunerButton.widthAnchor constraintEqualToConstant:30] setActive:YES];
    [[state->tunerButton.heightAnchor constraintEqualToConstant:26] setActive:YES];

    // Oversample mode dropdown (title bar, next to the tuner icon)
    state->osPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [state->osPopup addItemsWithTitles:@[@"None", @"Legacy", @"True 2x", @"True 4x",
                                          @"True 8x"]];
    state->osPopup.controlSize = NSControlSizeSmall;
    state->osPopup.target = state->uiController;
    state->osPopup.action = @selector(oversampleModeChanged:);
    for (NSUInteger item = 0; item < oversampleDescriptions().count; ++item)
      [state->osPopup itemAtIndex:item].toolTip = oversampleDescriptions()[item];
    state->osPopup.translatesAutoresizingMaskIntoConstraints = NO;
    [rigPane addSubview:state->osPopup];
    [[state->osPopup.leadingAnchor constraintEqualToAnchor:state->tunerButton.trailingAnchor constant:8] setActive:YES];
    [[state->osPopup.centerYAnchor constraintEqualToAnchor:title.centerYAnchor] setActive:YES];
    [[state->osPopup.widthAnchor constraintEqualToConstant:104] setActive:YES];
    [[state->osPopup.heightAnchor constraintEqualToConstant:26] setActive:YES];
    // Fresh instances start at the uncompromised maximum-quality setting.
    [state->osPopup selectItemAtIndex:4];
    state->osPopup.toolTip = popupTooltip(@"Sets both pedal and amp oversampling.", state->osPopup);

    // Tuner readout panel — hidden until the toggle is on.
    NSView* tp = [[NSView alloc] initWithFrame:NSZeroRect];
    tp.wantsLayer = YES;
    tp.layer.backgroundColor = rigPanelBG().CGColor;
    tp.layer.cornerRadius = 8;
    tp.layer.borderWidth = 1.0;
    tp.layer.borderColor = rigPanelBorder().CGColor;
    tp.hidden = YES;
    tp.translatesAutoresizingMaskIntoConstraints = NO;
    [rigPane addSubview:tp];
    tp.toolTip = @"Live tuner readout from the raw input signal.";
    state->tunerPanel = tp;
    [[tp.leadingAnchor constraintEqualToAnchor:state->tunerButton.leadingAnchor] setActive:YES];
    [[tp.topAnchor constraintEqualToAnchor:state->tunerButton.bottomAnchor constant:6] setActive:YES];
    [[tp.widthAnchor constraintEqualToConstant:240] setActive:YES];
    [[tp.heightAnchor constraintEqualToConstant:34] setActive:YES];

    NSTextField* noteL = addLabel(tp, @"—", NSZeroRect,
                                  [NSFont monospacedDigitSystemFontOfSize:17 weight:NSFontWeightBold],
                                  rigText(), NSTextAlignmentCenter);
    noteL.translatesAutoresizingMaskIntoConstraints = NO;
    state->tunerNoteLabel = noteL;
    noteL.toolTip = @"Detected note from the raw input. A dash means no stable pitch is currently detected.";
    [[noteL.leadingAnchor constraintEqualToAnchor:tp.leadingAnchor constant:14] setActive:YES];
    [[noteL.centerYAnchor constraintEqualToAnchor:tp.centerYAnchor] setActive:YES];
    [[noteL.widthAnchor constraintEqualToConstant:58] setActive:YES];

    NSTextField* centsL = addLabel(tp, @"", NSZeroRect,
                                   [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular],
                                   rigDimText(), NSTextAlignmentCenter);
    centsL.translatesAutoresizingMaskIntoConstraints = NO;
    state->tunerCentsLabel = centsL;
    centsL.toolTip = @"Pitch offset from the detected note in cents; zero is in tune.";
    [[centsL.trailingAnchor constraintEqualToAnchor:tp.trailingAnchor constant:-10] setActive:YES];
    [[centsL.centerYAnchor constraintEqualToAnchor:tp.centerYAnchor] setActive:YES];
    [[centsL.widthAnchor constraintEqualToConstant:74] setActive:YES];

    // Needle: thin accent bar that slides across the ±50-cent scale.
    NSView* meter = [[NSView alloc] initWithFrame:NSZeroRect];
    meter.wantsLayer = YES;
    meter.layer.backgroundColor = rigRaised().CGColor;
    meter.layer.cornerRadius = 2;
    meter.translatesAutoresizingMaskIntoConstraints = NO;
    [tp addSubview:meter];
    meter.toolTip = @"Tuning meter spanning -50 to +50 cents. The center position is in tune.";
    [[meter.leadingAnchor constraintEqualToAnchor:noteL.trailingAnchor constant:10] setActive:YES];
    [[meter.trailingAnchor constraintEqualToAnchor:centsL.leadingAnchor constant:-10] setActive:YES];
    [[meter.centerYAnchor constraintEqualToAnchor:tp.centerYAnchor] setActive:YES];
    [[meter.heightAnchor constraintEqualToConstant:6] setActive:YES];

    NSImageView* needle = [[NSImageView alloc] initWithFrame:NSZeroRect];
    needle.wantsLayer = YES;
    needle.layer.backgroundColor = rigAccent().CGColor;
    needle.layer.cornerRadius = 1.5;
    needle.hidden = YES;
    needle.translatesAutoresizingMaskIntoConstraints = NO;
    [meter addSubview:needle];
    needle.toolTip = @"Current tuning offset; centered and green means in tune.";
    state->tunerNeedle = needle;
    [[needle.topAnchor constraintEqualToAnchor:meter.topAnchor constant:-3] setActive:YES];
    [[needle.bottomAnchor constraintEqualToAnchor:meter.bottomAnchor constant:3] setActive:YES];
    [[needle.widthAnchor constraintEqualToConstant:3] setActive:YES];

    NSLayoutConstraint* needleLeading =
        [NSLayoutConstraint constraintWithItem:needle
                                     attribute:NSLayoutAttributeLeading
                                     relatedBy:NSLayoutRelationEqual
                                         toItem:meter
                                     attribute:NSLayoutAttributeLeading
                                    multiplier:1.0
                                      constant:0];
    needleLeading.active = YES;
    state->tunerNeedleLeading = needleLeading;

    // Input level meter (title bar, always visible): dBFS readout + bar.
    // DSP publishes the raw input peak via change-gated patch:Set atoms.
    NSView* mp = [[NSView alloc] initWithFrame:NSZeroRect];
    mp.wantsLayer = YES;
    mp.layer.backgroundColor = rigPanelBG().CGColor;
    mp.layer.cornerRadius = 8;
    mp.layer.borderWidth = 1.0;
    mp.layer.borderColor = rigPanelBorder().CGColor;
    mp.translatesAutoresizingMaskIntoConstraints = NO;
    [rigPane addSubview:mp];
    mp.toolTip = @"Raw input level meter before the gate, trims, and model stages.";
    [[mp.leadingAnchor constraintEqualToAnchor:state->osPopup.trailingAnchor constant:14] setActive:YES];
    [[mp.centerYAnchor constraintEqualToAnchor:title.centerYAnchor] setActive:YES];
    [[mp.widthAnchor constraintEqualToConstant:140] setActive:YES];
    [[mp.heightAnchor constraintEqualToConstant:30] setActive:YES];

    NSTextField* dbL = addLabel(mp, @"  —  dB", NSZeroRect,
                                [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium],
                                rigDimText(), NSTextAlignmentCenter);
    dbL.translatesAutoresizingMaskIntoConstraints = NO;
    state->inDbLabel = dbL;
    dbL.toolTip = @"Raw input peak level in dBFS, measured before all processing.";
    [[dbL.leadingAnchor constraintEqualToAnchor:mp.leadingAnchor constant:6] setActive:YES];
    [[dbL.centerYAnchor constraintEqualToAnchor:mp.centerYAnchor] setActive:YES];
    [[dbL.widthAnchor constraintEqualToConstant:48] setActive:YES];

    // Track: dark slot; the fill bar width is set at update time (-60..0 dB).
    NSView* slot = [[NSView alloc] initWithFrame:NSZeroRect];
    slot.wantsLayer = YES;
    slot.layer.backgroundColor = rigRaised().CGColor;
    slot.layer.cornerRadius = 2;
    slot.translatesAutoresizingMaskIntoConstraints = NO;
    [mp addSubview:slot];
    slot.toolTip = @"Raw input peak meter from -60 to 0 dBFS. Orange indicates a hot input; red indicates clipping risk.";
    [[slot.leadingAnchor constraintEqualToAnchor:dbL.trailingAnchor constant:6] setActive:YES];
    [[slot.trailingAnchor constraintEqualToAnchor:mp.trailingAnchor constant:-8] setActive:YES];
    [[slot.centerYAnchor constraintEqualToAnchor:mp.centerYAnchor] setActive:YES];
    [[slot.heightAnchor constraintEqualToConstant:8] setActive:YES];

    NSView* fill = [[NSView alloc] initWithFrame:NSZeroRect];
    fill.wantsLayer = YES;
    fill.layer.backgroundColor = rigAccent().CGColor;
    fill.layer.cornerRadius = 2;
    fill.translatesAutoresizingMaskIntoConstraints = NO;
    [slot addSubview:fill];
    fill.toolTip = @"Raw input peak meter from -60 to 0 dBFS. Orange indicates a hot input; red indicates clipping risk.";
    [[fill.leadingAnchor constraintEqualToAnchor:slot.leadingAnchor] setActive:YES];
    [[fill.centerYAnchor constraintEqualToAnchor:slot.centerYAnchor] setActive:YES];
    [[fill.heightAnchor constraintEqualToConstant:8] setActive:YES];
    NSLayoutConstraint* fillW =
        [NSLayoutConstraint constraintWithItem:fill
                                     attribute:NSLayoutAttributeWidth
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:nil
                                     attribute:NSLayoutAttributeNotAnAttribute
                                    multiplier:1.0
                                      constant:0];
    fillW.active = YES;
    state->inDbBar = fill;
    state->inDbBarWidth = fillW;

    // Preset management controls (title bar):
    // [ ◀ ] [ Preset: Name ▾ ] [ ▶ ] [ SAVE ]
    RigButton* prevPresetBtn = rigButton(rigPane, @"◀", state->uiController,
                                         @selector(prevPresetClicked:), NSZeroRect);
    prevPresetBtn.toolTip = @"Switch to the previous preset.";
    prevPresetBtn.translatesAutoresizingMaskIntoConstraints = NO;
    state->prevPresetBtn = prevPresetBtn;
    [[prevPresetBtn.leadingAnchor constraintEqualToAnchor:mp.trailingAnchor constant:14] setActive:YES];
    [[prevPresetBtn.centerYAnchor constraintEqualToAnchor:title.centerYAnchor] setActive:YES];
    [[prevPresetBtn.widthAnchor constraintEqualToConstant:24] setActive:YES];
    [[prevPresetBtn.heightAnchor constraintEqualToConstant:26] setActive:YES];

    NSPopUpButton* presetPop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    presetPop.controlSize = NSControlSizeSmall;
    presetPop.target = state->uiController;
    presetPop.action = @selector(presetPopupChanged:);
    presetPop.toolTip = @"Active preset. Click to select a preset, save, or manage presets.";
    presetPop.translatesAutoresizingMaskIntoConstraints = NO;
    [rigPane addSubview:presetPop];
    state->presetPopup = presetPop;
    [[presetPop.leadingAnchor constraintEqualToAnchor:prevPresetBtn.trailingAnchor constant:4] setActive:YES];
    [[presetPop.centerYAnchor constraintEqualToAnchor:title.centerYAnchor] setActive:YES];
    [[presetPop.widthAnchor constraintEqualToConstant:155] setActive:YES];
    [[presetPop.heightAnchor constraintEqualToConstant:26] setActive:YES];

    RigButton* nextPresetBtn = rigButton(rigPane, @"▶", state->uiController,
                                         @selector(nextPresetClicked:), NSZeroRect);
    nextPresetBtn.toolTip = @"Switch to the next preset.";
    nextPresetBtn.translatesAutoresizingMaskIntoConstraints = NO;
    state->nextPresetBtn = nextPresetBtn;
    [[nextPresetBtn.leadingAnchor constraintEqualToAnchor:presetPop.trailingAnchor constant:4] setActive:YES];
    [[nextPresetBtn.centerYAnchor constraintEqualToAnchor:title.centerYAnchor] setActive:YES];
    [[nextPresetBtn.widthAnchor constraintEqualToConstant:24] setActive:YES];
    [[nextPresetBtn.heightAnchor constraintEqualToConstant:26] setActive:YES];

    RigButton* savePresetBtn = rigButton(rigPane, @"SAVE", state->uiController,
                                         @selector(saveCurrentPreset:), NSZeroRect);
    savePresetBtn.toolTip = @"Save current rig settings to active preset, or save as a new preset.";
    savePresetBtn.translatesAutoresizingMaskIntoConstraints = NO;
    state->savePresetBtn = savePresetBtn;
    [[savePresetBtn.leadingAnchor constraintEqualToAnchor:nextPresetBtn.trailingAnchor constant:8] setActive:YES];
    [[savePresetBtn.centerYAnchor constraintEqualToAnchor:title.centerYAnchor] setActive:YES];
    [[savePresetBtn.widthAnchor constraintEqualToConstant:54] setActive:YES];
    [[savePresetBtn.heightAnchor constraintEqualToConstant:26] setActive:YES];

    RigButton* resetKnobsButton = rigButton(rigPane, @"RESET KNOBS", state->uiController,
                                           @selector(resetAllKnobs:), NSZeroRect);
    resetKnobsButton.toolTip = @"Reset every knob to its factory default. Model selections, stage switches, profiles, and oversampling are unchanged.";
    resetKnobsButton.translatesAutoresizingMaskIntoConstraints = NO;
    [rigPane addSubview:resetKnobsButton];
    [[resetKnobsButton.trailingAnchor constraintEqualToAnchor:rigPane.trailingAnchor constant:-134] setActive:YES];
    [[resetKnobsButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor] setActive:YES];
    [[resetKnobsButton.widthAnchor constraintEqualToConstant:112] setActive:YES];
    [[resetKnobsButton.heightAnchor constraintEqualToConstant:26] setActive:YES];

    NSArray<NSString*>* names = @[@"PEDAL", @"AMP", @"CAB · NAM / WAV IR"];
    // Quality is fixed at 100% — no knob, the DSP never scales model quality.
    // Display names indexed by kRigKnobPorts order; cells are laid out in
    // signal order via kRigKnobDisplayOrder.
    NSArray<NSString*>* knobNames = @[@"GATE", @"RELEASE", @"INPUT", @"COMP",
                                      @"DRIVE", @"BASS", @"MID", @"TREBLE",
                                      @"CAB LVL", @"LOW CUT", @"HIGH CUT", @"OUTPUT",
                                      @"WIDTH", @"ROOM", @"PRESENCE", @"DEPTH",
                                      @"SAG", @"BIAS", @"NEG FDBK", @"BRIGHT",
                                      @"INPUT EQ", @"MASTER", @"SPKR DRIVE", @"SPKR COMP",
                                      @"THUMP", @"RESONANCE",
                                      @"CAB B LVL", @"ALIGN", @"DLY TIME", @"DLY FDBK",
                                      @"DLY DAMP", @"DLY MIX", @"RVB MIX", @"DECAY",
                                      @"SIZE", @"RVB DAMP", @"PRE-DLY"];
    NSArray<NSString*>* knobValues = @[@"OFF", @"150 ms", @"+0.0 dB", @"OFF",
                                       @"+0.0 dB", @"+0.0 dB", @"+0.0 dB", @"+0.0 dB",
                                       @"+0.0 dB", @"OFF", @"OFF", @"+0.0 dB", @"OFF", @"OFF",
                                       @"+0.0 dB", @"+0.0 dB", @"OFF", @"+0%",
                                       @"OFF", @"OFF", @"OFF", @"OFF", @"25%", @"25%", @"50%", @"50%",
                                       @"+0.0 dB", @"OFF", @"400 ms", @"35%", @"40%", @"OFF",
                                       @"OFF", @"50%", @"50%", @"50%", @"10 ms"];
    NSArray<NSString*>* knobDescriptions = @[
      @"Gate threshold. Mutes background hiss and pickup hum when not playing. Raising it clamps down on noise for tight, staccato chugs; setting it too high cuts off decaying note sustain. -80 dB bypasses the gate.",
      @"Gate release time. Controls how quickly the gate closes once your signal falls below the threshold. Shorter times give an immediate, sharp cutoff for aggressive metal rhythms; longer times let chords and sustain fade out naturally.",
      @"Input level trim. Adjusts raw guitar signal strength before hitting any pedals, the amp, or compression. Turn up to push high-gain models harder into saturation; turn down for extra clean headroom.",
      @"Pre-model compressor. Evens out playing dynamics and adds smooth sustain before hitting the amp. Higher settings squash loud pick transients and bring up quiet details while preserving initial pick attack.",
      @"Amp drive boost. Boosts or attenuates the signal between the pedal and the amp model. Turn up to push the amp into richer preamp saturation and harmonic crunch; turn down to clean up the tone.",
      @"Post-cab bass EQ (150 Hz shelf). Shapes the low end of your sound after the cabinet. Turn up to add body, low-frequency warmth, and cabinet weight; turn down to clear up low-end boominess and mud.",
      @"Post-cab midrange EQ (700 Hz bell). Shapes the crucial mid frequencies after the cabinet. Turn up to punch forward and cut through a dense mix; turn down (scoop) for classic aggressive metal rhythm tone.",
      @"Post-cab treble EQ (3 kHz shelf). Shapes top-end brightness after the cabinet. Turn up for crisper pick definition, attack presence, and sheen; turn down to tame harsh digital fizz and ice-pick highs.",
      @"Cab A level trim. Adjusts the volume immediately after Cabinet A. Use it to level-match different impulse responses or balance the blend between Cab A and Cab B without changing tone.",
      @"Cabinet low cut (high-pass filter). Rolls off sub-bass rumble and low-end flub below the cutoff frequency. Raising this tightens palm mutes and keeps deep lows clear of bass and kick drum frequencies; 0 Hz bypasses.",
      @"Cabinet high cut (low-pass filter). Smooths away harsh top-end sizzle and ultra-high fizz above the cutoff frequency. Lowering this rounds off the highs for a warmer, more organic vintage speaker tone; 20 kHz bypasses.",
      @"Master output level. Final output volume trim after the entire rig, cabinets, and effects. Adjusts monitoring or recording level into your DAW without altering distortion, tone balance, or compression.",
      @"Stereo cabinet width. Pans Cab A left and Cab B right, and widens the stereo image of stereo impulse responses. 0% is pure dual-mono; higher settings create a wide, immersive wall-of-sound stereo spread.",
      @"Room reflections. Blends in short early reflections of a physical studio tracking room with high-frequency diffusion. Adds realistic acoustic 3D depth and air to dry cabinet IRs. Reverb Size and Reverb Damping shape it too.",
      @"Presence control (post-amp). Boosts or cuts upper-mid harmonics directly after the amp model. Positive values add cutting bite, overtone sparkle, and attack clarity; negative values soften harsh distortion fizz. Separate from post-cab Treble.",
      @"Depth / resonance control (post-amp). Boosts or cuts deep lows directly after the amp model. Positive values add physical cabinet thump, bottom-end bloom, and resonance; negative values tighten bass response for fast riffs. Separate from post-cab Bass.",
      @"Power sag. Simulates power-supply voltage droop after loud notes. Higher settings soften peaks, add compression and sustain, and recover more slowly. Creates a spongy, organic dynamic feel under the fingers. Works independently of Input EQ and Master.",
      @"Tube bias symmetry. Changes the symmetry of the added post-model saturation, emphasizing different even harmonics. Shifts distortion texture from smooth and warm to raw, gritty, and asymmetric. Works independently; Master adds more drive and makes the result easier to hear.",
      @"Negative feedback. Applies corrective low-frequency feedback after the amp model. Higher settings tighten bass, reduce bloom and make palm mutes more controlled; lower settings feel raw, open, and aggressive. Works independently of Input EQ and Master.",
      @"Bright boost (pre-amp). Boosts upper frequencies before the NAM amp model, so the model distorts a brighter signal. Use it for extra pick attack and clarity. Adds chime and aggressive bite to high notes. Works independently of Input EQ.",
      @"Input EQ (pre-amp tightening). Removes deep bass before the NAM amp model. Higher settings tighten palm mutes, reduce mud and keep bass from overdriving the capture. It does not enable or affect the other knobs.",
      @"Master volume (power-amp drive). Adds a simulated power-stage drive after the NAM amp model. Higher settings add saturation, compression, sustain and flattened peaks. Thickens up tone with rich power-tube overdrive. At 0% the captured amp is untouched; it does not enable Bias or other controls.",
      @"Speaker breakup drive. Simulates mechanical speaker cone breakup under heavy volume. Pushing this adds gritty mid-range distortion, raspy edge, and organic harmonic richness as if a physical speaker is being driven to its limits.",
      @"Speaker compression. Simulates physical speaker cone excursion compression and recovery after the amp. Tames sudden transient spikes from hard picking and smooths out note attack, creating a squashed, punchy response.",
      @"Speaker thump. Simulates nonlinear low-frequency speaker excursion. Adds visceral low-end inertia, chest-thumping bass impact, and dynamic cabinet resonance on palm mutes and deep bass notes.",
      @"Speaker resonance. Strength of the selected speaker impedance curve: the low resonance and the rising voice-coil inductance. Boosting creates a lively, resonant 'in-the-room' cabinet feel; lowering it flattens the response. Negative Feedback flattens both.",
      @"Cab B level trim. Adjusts the volume of the second cabinet (Cab B) before it mixes with Cab A. Use it to balance dual-cabinet blends (e.g. blending a dark ribbon mic with a bright dynamic mic).",
      @"Cab B phase alignment. Delays Cab B by up to 10 ms so two impulse responses can be phase aligned by ear, eliminating hollow comb filtering and locking in full punchy low end.",
      @"Stereo delay time. Sets the time between delay repeats from 20 ms to 2000 ms. Short settings create tight slapback or double-tracking; medium settings create rhythmic groove; long settings create spacious ambient leads.",
      @"Delay feedback. Controls the number of delay repeats. Higher settings produce cascading echoes that slowly decay into a soft, tape-like wash through the damping filter and limiter.",
      @"Delay damping. High-frequency loss of each delay repeat, from bright digital to dark tape-like. Low damping keeps repeats crisp and clear; high damping rolls off top end so repeats sit warmly behind your playing.",
      @"Delay mix. Blends wet delay echoes with dry guitar tone. At 0%, delay is fully bypassed; higher settings make repeats more prominent for atmospheric textures and solos.",
      @"Plate reverb mix. Blends the lush plate reverb tank with the dry guitar sound. At 0%, reverb is fully bypassed; higher settings immerse your tone in deep, shimmering space while Room stays available on its own.",
      @"Reverb decay time. Controls how long the reverb tail lingers. Short settings add subtle studio room ambience; long settings produce cavernous, dreamy reverberation that floats behind sustained notes.",
      @"Reverb space size. Scales the reverb plate tank dimensions and the room's early reflections. Smaller sizes sound tight and intimate; larger sizes expand into a vast acoustic hall.",
      @"Reverb high damping. Controls high-frequency absorption in the plate and room reflections. Lower damping preserves bright, airy shimmer; higher damping darkens the tail for a warm, natural decay that never clutters the mix.",
      @"Reverb pre-delay. Sets the time gap (0-100 ms) before the reverb tail begins. Keeps your initial pick attack and note definition clear and upfront before the ambient reverb blooms."
    ];

    const std::array<double, kRigKnobCount> mins{
        -80.0, 20.0, -20.0, 0.0, -24.0, -12.0, -12.0, -12.0, -24.0, 0.0, 4000.0, -20.0, 0.0, 0.0,
        -12.0, -12.0, 0.0, -100.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        -24.0, 0.0, 20.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0};
    const std::array<double, kRigKnobCount> maxes{
        0.0, 1000.0, 20.0, 100.0, 24.0, 12.0, 12.0, 12.0, 24.0, 200.0, 20000.0, 20.0, 100.0, 100.0,
        12.0, 12.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0,
        24.0, 10.0, 2000.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0};

    NSStackView* boxRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
    boxRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    boxRow.distribution = NSStackViewDistributionFillEqually;
    boxRow.spacing = 22.0;
    boxRow.translatesAutoresizingMaskIntoConstraints = NO;
    [rigPane addSubview:boxRow];
    [[boxRow.leadingAnchor constraintEqualToAnchor:rigPane.leadingAnchor constant:24] setActive:YES];
    [[boxRow.trailingAnchor constraintEqualToAnchor:rigPane.trailingAnchor constant:-24] setActive:YES];
    [[boxRow.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:16] setActive:YES];
    [[boxRow.heightAnchor constraintEqualToConstant:328] setActive:YES];

    // Knobs grouped under the tile they relate to: GATE/INPUT under PEDAL,
    // DRIVE/PRESENCE/DEPTH and the tone controls under AMP, OUTPUT under CAB. Each group's LEADING and
    // TRAILING edges are pinned to its tile box in the tile loop below, so the
    // knobs stay exactly within the tile's footprint at any width/zoom.
    NSView* knobGroups[3] = {nil, nil, nil};

    // Display slots grouped per tile in signal-flow order.
    const size_t groupSlots[3][6] = {{0, 1, 2, 3, 0, 0}, {4, 14, 15, 5, 6, 7}, {8, 9, 10, 11, 26, 27}};
    const size_t groupCounts[3] = {4, 6, 6};

    for (size_t g = 0; g < 3; ++g) {
      NSView* group = [[NSView alloc] initWithFrame:NSZeroRect];
      group.translatesAutoresizingMaskIntoConstraints = NO;
      [rigPane addSubview:group];
      knobGroups[g] = group;
      [[group.topAnchor constraintEqualToAnchor:boxRow.bottomAnchor constant:14] setActive:YES];
      [[group.heightAnchor constraintEqualToConstant:110] setActive:YES];

      // Equal-width cells tiled across the group with the same 22pt spacing
      // the tiles use — knobs stay inside their tile's footprint at any width.
      NSView* prev = nil;
      for (size_t gi = 0; gi < groupCounts[g]; ++gi) {
        const size_t slot = groupSlots[g][gi];
        const size_t k = kRigKnobDisplayOrder[slot];
        NSView* cell = [[NSView alloc] initWithFrame:NSZeroRect];
        cell.translatesAutoresizingMaskIntoConstraints = NO;
        [group addSubview:cell];
        [[cell.topAnchor constraintEqualToAnchor:group.topAnchor] setActive:YES];
        [[cell.bottomAnchor constraintEqualToAnchor:group.bottomAnchor] setActive:YES];
        if (prev) {
          [[cell.leadingAnchor constraintEqualToAnchor:prev.trailingAnchor constant:22] setActive:YES];
          [[cell.widthAnchor constraintEqualToAnchor:prev.widthAnchor] setActive:YES];
        } else {
          [[cell.leadingAnchor constraintEqualToAnchor:group.leadingAnchor] setActive:YES];
        }
        prev = cell;
        if (gi == groupCounts[g] - 1)
          [[cell.trailingAnchor constraintEqualToAnchor:group.trailingAnchor] setActive:YES];

        state->knobs[k] = addKnob(cell, (NSInteger)kRigKnobPorts[k], kRigKnobDefaults[k],
                                  mins[k], maxes[k],
                                  NSMakePoint(0, 0), state->uiController);
        NSSlider* knob = state->knobs[k];
        knob.toolTip = knobDescriptions[k];
        knob.translatesAutoresizingMaskIntoConstraints = NO;
        centerX(knob, cell, 0);
        [[knob.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor constant:-4] setActive:YES];

        NSTextField* kname = addLabel(cell, knobNames[k], NSZeroRect,
                                      [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
                                      rigDimText(), NSTextAlignmentCenter);
        rigApplyTracking(kname, 1.1);
        kname.toolTip = knobDescriptions[k];
        kname.translatesAutoresizingMaskIntoConstraints = NO;
        centerX(kname, cell, 0);
        [[kname.bottomAnchor constraintEqualToAnchor:knob.topAnchor constant:-8] setActive:YES];

        state->valueLabels[k] = addLabel(cell, knobValues[k], NSZeroRect,
          [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightRegular], rigText(), NSTextAlignmentCenter);
        // Turn the value display into an editable text box: type a number and
        // press Return (or click away) to set the knob. Knob turns still update
        // the box text while not editing.
        NSTextField* kval = state->valueLabels[k];
        kval.editable = YES;
        kval.selectable = YES;   // editable alone is NOT enough on label-created fields
        kval.bordered = NO;
        kval.wantsLayer = YES;
        kval.layer.cornerRadius = 4.0;
        kval.layer.masksToBounds = YES;
        kval.drawsBackground = YES;
        kval.backgroundColor = rigRaised();
        kval.textColor = rigText();
        kval.focusRingType = NSFocusRingTypeNone;
        kval.tag = (NSInteger)kRigKnobPorts[k];
        kval.delegate = state->uiController;
        kval.target = state->uiController;
        kval.action = @selector(knobFieldCommitted:);
        kval.toolTip = knobDescriptions[k];
        kval.translatesAutoresizingMaskIntoConstraints = NO;
        centerX(kval, cell, 0);
        [[kval.widthAnchor constraintEqualToConstant:70] setActive:YES];
        [[kval.heightAnchor constraintEqualToConstant:19] setActive:YES];
        [[kval.bottomAnchor constraintEqualToAnchor:kname.topAnchor constant:-6] setActive:YES];
      }
    }

    // Empty space below the rig controls for future expansion modules.
    RigPanel* expansionSlot = addPanel(rigPane, NSZeroRect);
    expansionSlot.translatesAutoresizingMaskIntoConstraints = NO;
    expansionSlot.toolTip = @"Rig expansion area for future signal chain and effect modules.";
    [[expansionSlot.leadingAnchor constraintEqualToAnchor:rigPane.leadingAnchor constant:24] setActive:YES];
    [[expansionSlot.trailingAnchor constraintEqualToAnchor:rigPane.trailingAnchor constant:-24] setActive:YES];
    [[expansionSlot.topAnchor constraintEqualToAnchor:knobGroups[0].bottomAnchor constant:18] setActive:YES];
    [[expansionSlot.bottomAnchor constraintEqualToAnchor:rigPane.bottomAnchor constant:-20] setActive:YES];

    for (NSInteger i = 0; i < 3; ++i) {
      RigPanel* box = addPanel(boxRow, NSMakeRect(0, 0, 100, 100));
      NSArray<NSString*>* stageTips = @[
        @"Pedal stage: dynamics and input conditioning feed the selected pedal NAM model before the amp.",
        @"Amp stage: the selected NAM model, drive trim, and optional output-transformer coloration form the core amp sound.",
        @"Cabinet stage: run a cabinet NAM model or WAV impulse response, optionally a parallel second cabinet, followed by cab level, frequency cuts, and the stereo effects."
      ];
      box.toolTip = stageTips[(NSUInteger)i];

      NSView* header = [[NSView alloc] initWithFrame:NSZeroRect];
      header.toolTip = stageTips[(NSUInteger)i];
      header.translatesAutoresizingMaskIntoConstraints = NO;
      [box addSubview:header];
      [[header.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16] setActive:YES];
      [[header.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16] setActive:YES];
      [[header.topAnchor constraintEqualToAnchor:box.topAnchor constant:14] setActive:YES];
      [[header.heightAnchor constraintEqualToConstant:26] setActive:YES];

      NSTextField* numL = [[NSTextField alloc] initWithFrame:NSZeroRect];
      numL.stringValue = [NSString stringWithFormat:@"%ld", (long)(i + 1)];
      numL.editable = NO; numL.selectable = NO; numL.drawsBackground = NO; numL.bordered = NO;
      numL.font = [NSFont boldSystemFontOfSize:12]; numL.textColor = rigOrange();
      numL.toolTip = stageTips[(NSUInteger)i];
      numL.translatesAutoresizingMaskIntoConstraints = NO;
      [header addSubview:numL];
      [[numL.leadingAnchor constraintEqualToAnchor:header.leadingAnchor] setActive:YES];
      [[numL.centerYAnchor constraintEqualToAnchor:header.centerYAnchor] setActive:YES];

      NSTextField* nmL = [[NSTextField alloc] initWithFrame:NSZeroRect];
      nmL.stringValue = names[(NSUInteger)i]; nmL.editable = NO; nmL.selectable = NO; nmL.drawsBackground = NO; nmL.bordered = NO;
      nmL.font = [NSFont systemFontOfSize:13 weight:NSFontWeightBold]; nmL.textColor = rigText();
      rigApplyTracking(nmL, 0.8);
      nmL.toolTip = stageTips[(NSUInteger)i];
      nmL.translatesAutoresizingMaskIntoConstraints = NO;
      [header addSubview:nmL];
      [[nmL.leadingAnchor constraintEqualToAnchor:numL.trailingAnchor constant:8] setActive:YES];
      [[nmL.centerYAnchor constraintEqualToAnchor:header.centerYAnchor] setActive:YES];
      [[nmL.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor constant:-70] setActive:YES];

      state->powerButtons[(size_t)i] = rigButton(header, @"ON", state->uiController,
                                                 @selector(controlChanged:), NSZeroRect);
      state->powerButtons[(size_t)i].tag = 7 + i;
      state->powerButtons[(size_t)i].state = NSControlStateValueOn;
      state->powerButtons[(size_t)i].buttonType = NSButtonTypeToggle;
      ((RigButton*)state->powerButtons[(size_t)i]).check = YES;
      RigButton* onBtn = (RigButton*)state->powerButtons[(size_t)i];
      onBtn.toolTip = [NSString stringWithFormat:@"Enable or bypass the %@ stage. Changes use a short click-free fade.", stageName(i)];
      onBtn.translatesAutoresizingMaskIntoConstraints = NO;
      [[onBtn.trailingAnchor constraintEqualToAnchor:header.trailingAnchor] setActive:YES];
      [[onBtn.centerYAnchor constraintEqualToAnchor:header.centerYAnchor] setActive:YES];
      [[onBtn.widthAnchor constraintEqualToConstant:60] setActive:YES];
      [[onBtn.heightAnchor constraintEqualToConstant:26] setActive:YES];

      // Per-stage oversample dropdown (pedal + amp only — a WAV cab IR is
      // linear and cannot alias; a .nam cab follows the amp's mode). Sits
      // left of the ON button, five modes: None / Legacy / True 2x-4x-8x.
      if (i < 2) {
        NSPopUpButton* so = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [so addItemsWithTitles:@[@"None", @"Legacy", @"True 2x", @"True 4x",
                                 @"True 8x"]];
        so.controlSize = NSControlSizeSmall;
        so.tag = 20 + i;                 // port 20 = pedal, 21 = amp
        so.target = state->uiController;
        so.action = @selector(stageOversampleChanged:);
        for (NSUInteger item = 0; item < oversampleDescriptions().count; ++item)
          [so itemAtIndex:item].toolTip = oversampleDescriptions()[item];
        so.translatesAutoresizingMaskIntoConstraints = NO;
        [header addSubview:so];
        [[so.trailingAnchor constraintEqualToAnchor:onBtn.leadingAnchor constant:-8] setActive:YES];
        [[so.centerYAnchor constraintEqualToAnchor:header.centerYAnchor] setActive:YES];
        [[so.widthAnchor constraintEqualToConstant:104] setActive:YES];
        [[so.heightAnchor constraintEqualToConstant:24] setActive:YES];
        [so selectItemAtIndex:4];        // default True 8x = TTL default
        so.toolTip = popupTooltip(
            [NSString stringWithFormat:@"Sets %@-stage oversampling.", stageName(i)], so);
        state->stageOsPopup[(size_t)i] = so;
        // Keep the stage name label clear of the popup.
        [[nmL.trailingAnchor constraintLessThanOrEqualToAnchor:so.leadingAnchor
                                                      constant:-8] setActive:YES];
      } else {
        NSPopUpButton* norm = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [norm addItemsWithTitles:@[@"Preserve", @"Peak", @"Loudness", @"Original"]];
        NSArray<NSString*>* normalizationDescriptions = @[
          @"Preserve — Retains the impulse response's captured transfer gain across sample rates.",
          @"Peak — Scales the strongest audible-band response to unity, maximizing headroom without clipping the IR response.",
          @"Loudness — Matches average audible-band response energy to unity for the most consistent perceived level.",
          @"Original — Uses every decoded source tap untouched: no resampling, transfer correction, truncation, fade, or normalization. A sample-rate mismatch intentionally changes playback speed."
        ];
        for (NSUInteger item = 0; item < normalizationDescriptions.count; ++item)
          [norm itemAtIndex:item].toolTip = normalizationDescriptions[item];
        norm.controlSize = NSControlSizeSmall;
        norm.target = state->uiController;
        norm.action = @selector(irNormalizationChanged:);
        norm.translatesAutoresizingMaskIntoConstraints = NO;
        [header addSubview:norm];
        [[norm.trailingAnchor constraintEqualToAnchor:onBtn.leadingAnchor constant:-8] setActive:YES];
        [[norm.centerYAnchor constraintEqualToAnchor:header.centerYAnchor] setActive:YES];
        [[norm.widthAnchor constraintEqualToConstant:104] setActive:YES];
        [[norm.heightAnchor constraintEqualToConstant:24] setActive:YES];
        [norm selectItemAtIndex:2];
        norm.toolTip = popupTooltip(@"Sets WAV impulse-response gain handling. Changes glide smoothly.", norm);
        state->irNormPopup = norm;
        [[nmL.trailingAnchor constraintLessThanOrEqualToAnchor:norm.leadingAnchor
                                                      constant:-8] setActive:YES];
      }

      NSImageView* thumb = [[NSImageView alloc] initWithFrame:NSZeroRect];
      thumb.wantsLayer = YES; thumb.layer.cornerRadius = 12; thumb.layer.masksToBounds = YES;
      thumb.layer.backgroundColor = [NSColor colorWithSRGBRed:0.13 green:0.14 blue:0.17 alpha:1.0].CGColor;
      thumb.imageScaling = NSImageScaleProportionallyUpOrDown;
      thumb.translatesAutoresizingMaskIntoConstraints = NO;
      [box addSubview:thumb];
      [[thumb.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16] setActive:YES];
      [[thumb.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16] setActive:YES];
      [[thumb.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:14] setActive:YES];
      // Leave one compact row for the amp's output-transformer selector while
      // keeping all three model selectors vertically aligned.
      [[thumb.heightAnchor constraintEqualToConstant:112] setActive:YES];
      state->stageImages[(size_t)i] = thumb;
      thumb.toolTip = [NSString stringWithFormat:@"Artwork for the currently selected %@ tone or model.", stageName(i)];

      NSView* modelAnchor = thumb;
      if (i == 1) {
        NSPopUpButton* transformer =
            [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [transformer addItemsWithTitles:@[@"Captured / Off", @"Modern Iron",
                                           @"US Vintage", @"UK Vintage",
                                           @"Small Iron", @"Tight Metal",
                                           @"Extended Range", @"Thrash Bite",
                                           @"Doom Iron", @"Studio Linear",
                                           @"Tweed Bloom", @"Class-A Chime",
                                           @"Bass Iron"]];
        NSArray<NSString*>* transformerDescriptions = @[
          @"Captured / Off — Adds no transformer processing, preserving the output-transformer response already present in the NAM capture.",
          @"Modern Iron — Oversized, wide-bandwidth response with firm lows, open highs, gentle saturation, and very little sag.",
          @"US Vintage — Deep, rounded lows with restrained presence, warm asymmetric harmonics, and moderate vintage compression.",
          @"UK Vintage — Tighter bass, pronounced mid-bass bark, earlier core saturation, and a compressed classic-stack feel.",
          @"Small Iron — Narrower bandwidth, strong low-mid character, early breakup, softened highs, and the most vintage-style compression.",
          @"Tight Metal — Trims sub-bass flub while retaining pick attack, upper-mid definition, air, and fast recovery.",
          @"Extended Range — Preserves low-tuned fundamentals and high-end clarity with disciplined resonance, low saturation, and minimal sag.",
          @"Thrash Bite — Lean, controlled lows with an aggressive upper-mid cut, harder core drive, and quick response.",
          @"Doom Iron — Large low-frequency bloom, dark rolled-off highs, heavy core saturation, and pronounced slow sag.",
          @"Studio Linear — Wide, clean headroom with subtle low-end weight, polished presence, restrained harmonics, and almost no sag.",
          @"Tweed Bloom — Loose warm lows, rich low mids, a soft top end, asymmetric breakup, and deep touch-sensitive sag.",
          @"Class-A Chime — Controlled bass, open highs, a clear presence lift, lively asymmetric harmonics, and moderate compression.",
          @"Bass Iron — Extended deep fundamentals, subdued upper mids, high headroom, restrained saturation, and minimal sag."
        ];
        for (NSUInteger item = 0; item < transformerDescriptions.count; ++item)
          [transformer itemAtIndex:item].toolTip = transformerDescriptions[item];
        transformer.controlSize = NSControlSizeSmall;
        transformer.target = state->uiController;
        transformer.action = @selector(transformerChanged:);
        transformer.translatesAutoresizingMaskIntoConstraints = NO;
        [box addSubview:transformer];
        [[transformer.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16] setActive:YES];
        [[transformer.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16] setActive:YES];
        [[transformer.topAnchor constraintEqualToAnchor:thumb.bottomAnchor constant:5] setActive:YES];
        [[transformer.heightAnchor constraintEqualToConstant:23] setActive:YES];
        [transformer selectItemAtIndex:0];
        transformer.toolTip = transformer.selectedItem.toolTip;
        state->transformerPopup = transformer;
        modelAnchor = transformer;

        RigButton* advanced = rigButton(box, @"ADVANCED AMP", state->uiController,
                                        @selector(showAmpAdvanced:), NSZeroRect);
        advanced.translatesAutoresizingMaskIntoConstraints = NO;
        advanced.toolTip = @"Open optional amp shaping. Every control defaults off, preserving the captured model and existing Bass, Mid, and Treble.";
        [[advanced.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16] setActive:YES];
        [[advanced.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16] setActive:YES];
        [[advanced.topAnchor constraintEqualToAnchor:transformer.bottomAnchor constant:4] setActive:YES];
        [[advanced.heightAnchor constraintEqualToConstant:23] setActive:YES];
        modelAnchor = advanced;

        NSPopover* popover = [[NSPopover alloc] init];
        popover.behavior = NSPopoverBehaviorTransient;
        NSViewController* popController = [[NSViewController alloc] init];
        NSView* popView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 245)];
        popView.wantsLayer = YES;
        popView.layer.backgroundColor = rigPanelBG().CGColor;
        popController.view = popView;
        popover.contentViewController = popController;
        popover.contentSize = NSMakeSize(520, 245);
        state->ampAdvancedPopover = popover;

        NSTextField* advancedTitle = addLabel(popView, @"ADVANCED AMP", NSMakeRect(18, 216, 200, 18),
            [NSFont systemFontOfSize:12 weight:NSFontWeightBold], rigText(), NSTextAlignmentLeft);
        rigApplyTracking(advancedTitle, 1.0);
        // Presence and Depth live in the always-visible AMP row; the popover
        // contains only the remaining dynamic/post-model controls.
        for (size_t a = 0; a < 6; ++a) {
          const size_t k = 16 + a;
          const size_t col = a % 3, row = a / 3;
          NSView* cell = [[NSView alloc] initWithFrame:NSMakeRect(69 + col * 127, 8 + (1 - row) * 100, 119, 100)];
          [popView addSubview:cell];
          state->knobs[k] = addKnob(cell, (NSInteger)kRigKnobPorts[k], kRigKnobDefaults[k], mins[k], maxes[k], NSMakePoint(28, 5), state->uiController);
          state->knobs[k].toolTip = knobDescriptions[k];
          NSTextField* label = addLabel(cell, knobNames[k], NSMakeRect(0, 75, 119, 15),
              [NSFont systemFontOfSize:9 weight:NSFontWeightSemibold], rigDimText(), NSTextAlignmentCenter);
          label.toolTip = knobDescriptions[k];
          state->valueLabels[k] = addLabel(cell, knobValues[k], NSMakeRect(24, 57, 72, 17),
              [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular], rigText(), NSTextAlignmentCenter);
          NSTextField* value = state->valueLabels[k];
          value.editable = YES; value.selectable = YES; value.bordered = NO;
          value.drawsBackground = YES; value.backgroundColor = rigRaised();
          value.tag = (NSInteger)kRigKnobPorts[k]; value.delegate = state->uiController;
          value.target = state->uiController; value.action = @selector(knobFieldCommitted:);
        }
      } else if (i == 2) {
        RigButton* speakerButton = rigButton(box, @"SPEAKER LOAD", state->uiController,
                                             @selector(showSpeakerLoad:), NSZeroRect);
        speakerButton.translatesAutoresizingMaskIntoConstraints = NO;
        speakerButton.toolTip = @"Speaker Dynamics / Impedance — Open speaker dynamics and impedance controls. Captured / Off is exact bypass.";
        [box addSubview:speakerButton];
        [[speakerButton.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16] setActive:YES];
        [[speakerButton.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16] setActive:YES];
        [[speakerButton.topAnchor constraintEqualToAnchor:thumb.bottomAnchor constant:5] setActive:YES];
        [[speakerButton.heightAnchor constraintEqualToConstant:23] setActive:YES];
        modelAnchor = speakerButton;

        RigButton* effectsButton = rigButton(box, @"WIDTH / DELAY / REVERB", state->uiController,
                                             @selector(showEffects:), NSZeroRect);
        effectsButton.translatesAutoresizingMaskIntoConstraints = NO;
        effectsButton.toolTip = @"Open cabinet width, room, stereo delay, and plate reverb controls. Delay and reverb default off.";
        [box addSubview:effectsButton];
        [[effectsButton.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16] setActive:YES];
        [[effectsButton.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16] setActive:YES];
        [[effectsButton.topAnchor constraintEqualToAnchor:speakerButton.bottomAnchor constant:4] setActive:YES];
        [[effectsButton.heightAnchor constraintEqualToConstant:23] setActive:YES];
        modelAnchor = effectsButton;

        {
          NSPopover* fx = [[NSPopover alloc] init];
          fx.behavior = NSPopoverBehaviorTransient;
          NSViewController* fxController = [[NSViewController alloc] init];
          NSView* fxView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 345)];
          fxView.wantsLayer = YES; fxView.layer.backgroundColor = rigPanelBG().CGColor;
          fxController.view = fxView; fx.contentViewController = fxController;
          fx.contentSize = NSMakeSize(520, 345); state->effectsPopover = fx;
          NSTextField* fxTitle = addLabel(fxView, @"WIDTH / ROOM / DELAY / REVERB", NSMakeRect(18, 318, 400, 18),
              [NSFont systemFontOfSize:12 weight:NSFontWeightBold], rigText(), NSTextAlignmentLeft);
          rigApplyTracking(fxTitle, 1.0);
          const size_t fxKnobs[11] = {12, 13, 28, 29, 30, 31, 32, 33, 34, 35, 36};
          for (size_t a = 0; a < 11; ++a) {
            const size_t k = fxKnobs[a];
            const size_t col = a % 4, row = a / 4;
            NSView* cell = [[NSView alloc] initWithFrame:NSMakeRect(10 + col * 127, 8 + (2 - row) * 103, 119, 100)];
            [fxView addSubview:cell];
            state->knobs[k] = addKnob(cell, (NSInteger)kRigKnobPorts[k], kRigKnobDefaults[k], mins[k], maxes[k], NSMakePoint(28, 5), state->uiController);
            state->knobs[k].toolTip = knobDescriptions[k];
            NSTextField* label = addLabel(cell, knobNames[k], NSMakeRect(0, 75, 119, 15), [NSFont systemFontOfSize:9 weight:NSFontWeightSemibold], rigDimText(), NSTextAlignmentCenter);
            label.toolTip = knobDescriptions[k];
            state->valueLabels[k] = addLabel(cell, knobValues[k], NSMakeRect(24, 57, 72, 17), [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular], rigText(), NSTextAlignmentCenter);
            NSTextField* value = state->valueLabels[k]; value.editable = YES; value.selectable = YES;
            value.bordered = NO; value.drawsBackground = YES; value.backgroundColor = rigRaised();
            value.tag = (NSInteger)kRigKnobPorts[k]; value.delegate = state->uiController;
            value.target = state->uiController; value.action = @selector(knobFieldCommitted:);
          }
        }

        NSPopover* popover = [[NSPopover alloc] init];
        popover.behavior = NSPopoverBehaviorTransient;
        NSViewController* controller = [[NSViewController alloc] init];
        NSView* view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 180)];
        view.wantsLayer = YES; view.layer.backgroundColor = rigPanelBG().CGColor;
        controller.view = view; popover.contentViewController = controller;
        popover.contentSize = NSMakeSize(520, 180); state->speakerPopover = popover;
        NSTextField* title = addLabel(view, @"SPEAKER DYNAMICS / IMPEDANCE", NSMakeRect(18, 150, 260, 18),
            [NSFont systemFontOfSize:12 weight:NSFontWeightBold], rigText(), NSTextAlignmentLeft);
        rigApplyTracking(title, 1.0);
        NSPopUpButton* profile = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(300, 146, 200, 25) pullsDown:NO];
        [profile addItemsWithTitles:@[@"Captured / Off", @"Auto", @"Resistive", @"Open Back",
                                      @"Vintage Alnico", @"UK 4x12", @"Modern 4x12", @"Bass"]];
        NSArray<NSString*>* tips = @[
          @"Captured / Off — Exact bypass; preserves the speaker-load behavior already in the NAM capture.",
          @"Auto — Associates a generic profile from the selected cabinet filename; unknown cabinets use Resistive.",
          @"Resistive — Flattest load and fastest response.", @"Open Back — Loose, broad low-frequency response.",
          @"Vintage Alnico — Soft breakup and rounded compression.", @"UK 4x12 — Focused mid-bass resonance.",
          @"Modern 4x12 — Tight low resonance and firm thump.", @"Bass — Deep resonance and slow recovery."];
        for (NSUInteger item = 0; item < tips.count; ++item) [profile itemAtIndex:item].toolTip = tips[item];
        profile.target = state->uiController; profile.action = @selector(speakerProfileChanged:);
        profile.toolTip = profile.selectedItem.toolTip; [view addSubview:profile];
        state->speakerProfilePopup = profile;
        for (size_t a = 0; a < 4; ++a) {
          const size_t k = 22 + a;
          NSView* cell = [[NSView alloc] initWithFrame:NSMakeRect(10 + a * 127, 8, 119, 125)];
          [view addSubview:cell];
          state->knobs[k] = addKnob(cell, (NSInteger)kRigKnobPorts[k], kRigKnobDefaults[k], mins[k], maxes[k], NSMakePoint(28, 5), state->uiController);
          state->knobs[k].toolTip = knobDescriptions[k];
          NSTextField* label = addLabel(cell, knobNames[k], NSMakeRect(0, 75, 119, 15), [NSFont systemFontOfSize:9 weight:NSFontWeightSemibold], rigDimText(), NSTextAlignmentCenter);
          label.toolTip = knobDescriptions[k];
          state->valueLabels[k] = addLabel(cell, knobValues[k], NSMakeRect(24, 57, 72, 17), [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular], rigText(), NSTextAlignmentCenter);
          NSTextField* value = state->valueLabels[k]; value.editable = YES; value.selectable = YES;
          value.bordered = NO; value.drawsBackground = YES; value.backgroundColor = rigRaised();
          value.tag = (NSInteger)kRigKnobPorts[k]; value.delegate = state->uiController;
          value.target = state->uiController; value.action = @selector(knobFieldCommitted:);
        }
      }

      // The dropdown is the tile's model control/display — always visible. The
      // old filename text label was redundant with it and is removed.
      state->modelPickers[(size_t)i] = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
      NSPopUpButton* mp = state->modelPickers[(size_t)i];
      mp.translatesAutoresizingMaskIntoConstraints = NO;
      mp.controlSize = NSControlSizeSmall;
      mp.tag = (NSInteger)i;
      mp.target = state->uiController;
      mp.action = @selector(stageModelChanged:);
      [mp addItemWithTitle:@"No model loaded"];
      [mp itemAtIndex:0].toolTip = RigUIState::modelPickerTooltip((size_t)i, nil);
      mp.toolTip = RigUIState::modelPickerTooltip((size_t)i, nil);
      mp.enabled = NO;
      [box addSubview:mp];
      [[mp.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16] setActive:YES];
      [[mp.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16] setActive:YES];
      if (i == 1 || i == 2)
        [[mp.topAnchor constraintEqualToAnchor:modelAnchor.bottomAnchor constant:4] setActive:YES];
      else
        [[mp.topAnchor constraintEqualToAnchor:thumb.bottomAnchor constant:32] setActive:YES];
      [[mp.heightAnchor constraintEqualToConstant:22] setActive:YES];

      if (i == 2) {
        NSPopUpButton* mpB = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        state->modelPickers[3] = mpB;
        mpB.translatesAutoresizingMaskIntoConstraints = NO;
        mpB.controlSize = NSControlSizeSmall;
        mpB.tag = 3;
        mpB.target = state->uiController;
        mpB.action = @selector(stageModelChanged:);
        [mpB addItemWithTitle:@"No Cab B loaded"];
        [mpB itemAtIndex:0].toolTip = RigUIState::modelPickerTooltip(3, nil);
        mpB.toolTip = RigUIState::modelPickerTooltip(3, nil);
        mpB.enabled = NO;
        [box addSubview:mpB];
        RigButton* browseB = rigButton(box, @"…", state->uiController, @selector(chooseModel:), NSZeroRect);
        browseB.tag = 3;
        browseB.toolTip = @"Choose a Cab B NAM model or WAV impulse response from disk.";
        browseB.translatesAutoresizingMaskIntoConstraints = NO;
        RigButton* onB = rigButton(box, @"B ON", state->uiController, @selector(controlChanged:), NSZeroRect);
        onB.tag = 47;
        onB.buttonType = NSButtonTypeToggle;
        onB.check = YES;
        onB.state = NSControlStateValueOff;
        onB.toolTip = @"Enable the second cabinet. Cab A pans left and Cab B pans right by the Width amount. Changes use a short click-free fade.";
        onB.translatesAutoresizingMaskIntoConstraints = NO;
        state->powerButtons[3] = onB;
        [[mpB.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16] setActive:YES];
        [[mpB.topAnchor constraintEqualToAnchor:mp.bottomAnchor constant:4] setActive:YES];
        [[mpB.heightAnchor constraintEqualToConstant:22] setActive:YES];
        [[browseB.leadingAnchor constraintEqualToAnchor:mpB.trailingAnchor constant:4] setActive:YES];
        [[browseB.centerYAnchor constraintEqualToAnchor:mpB.centerYAnchor] setActive:YES];
        [[browseB.widthAnchor constraintEqualToConstant:26] setActive:YES];
        [[browseB.heightAnchor constraintEqualToConstant:22] setActive:YES];
        [[onB.leadingAnchor constraintEqualToAnchor:browseB.trailingAnchor constant:4] setActive:YES];
        [[onB.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16] setActive:YES];
        [[onB.centerYAnchor constraintEqualToAnchor:mpB.centerYAnchor] setActive:YES];
        [[onB.widthAnchor constraintEqualToConstant:60] setActive:YES];
        [[onB.heightAnchor constraintEqualToConstant:22] setActive:YES];
      }

      // Pin this tile's knob group exactly to the tile's footprint: the
      // group's leading/trailing edges match the box (which insets itself
      // 16pt inside its cell via its own interior padding), so knobs sit
      // within the tile's visual bounds. Vertical placement is fixed above.
      NSView* grp = knobGroups[i];
      [[grp.leadingAnchor constraintEqualToAnchor:box.leadingAnchor] setActive:YES];
      [[grp.trailingAnchor constraintEqualToAnchor:box.trailingAnchor] setActive:YES];

      [boxRow addArrangedSubview:box];
      state->setStageThumb((size_t)i, nil, 0, nil);
    }

    addToneBrowser(state, tonePane);
    state->selectTab(0);
    [parent addSubview:state->view];
    state->applyZoom();                               // default 100%
    *widget = (__bridge void*)state->view;
    state->sendGet();
    state->restoreSelectedPaths();   // re-apply the persisted rig selection
    state->presetManager = [RigPresetManager sharedManager];
    [state->presetManager rescanPresets];
    state->rebuildPresetMenu();
    return state;
  }
}

void cleanup(LV2UI_Handle handle) {
  auto* state = static_cast<RigUIState*>(handle);
  [state->view removeFromSuperview];
  delete state;
}

void portEvent(LV2UI_Handle handle,
               uint32_t port,
               uint32_t size,
               uint32_t format,
               const void* buffer) {
  auto* state = static_cast<RigUIState*>(handle);
  if (!state) return;
  if (format == 0 && buffer && size == sizeof(float) && port >= 4 && port <= 58) {
    state->updateControl(port, *static_cast<const float*>(buffer));
    return;
  }
  if (port != 1 || format != state->eventTransfer || !buffer || size < sizeof(LV2_Atom_Object))
    return;
  const auto* atom = static_cast<const LV2_Atom*>(buffer);
  if (atom->type != state->atomObject) return;
  const auto* object = reinterpret_cast<const LV2_Atom_Object*>(atom);
  if (object->body.otype != state->patchSet) return;
  const LV2_Atom* property = nullptr;
  const LV2_Atom* value = nullptr;
  lv2_atom_object_get(object,
                      state->patchProperty, &property,
                      state->patchValue, &value,
                      0);
  if (!property || property->type != state->atomURID || !value) return;
  const LV2_URID propertyId = reinterpret_cast<const LV2_Atom_URID*>(property)->body;
  if (value->type == state->atomPath && value->size > 0) {
    for (size_t i = 0; i < state->pathURIDs.size(); ++i)
      if (propertyId == state->pathURIDs[i])
        state->displayPath(i, reinterpret_cast<const char*>(value + 1));
    return;
  }
  // Tuner updates: patch:Set floats — note (MIDI number, -1 = none) and cents.
  if (value->type != state->atomFloat || value->size != sizeof(float)) return;
  const float v = *reinterpret_cast<const float*>(value + 1);
  if (propertyId == state->tunerNoteURID)
    state->lastTunerNote = v;
  else if (propertyId == state->tunerCentsURID)
    state->lastTunerCents = v;
  else if (propertyId == state->inputDbURID)
    state->lastInputDb = v;
  else
    return;
  if (propertyId == state->inputDbURID)
    state->updateInputDbDisplay();
  else
    state->updateTunerDisplay();
}

const void* extensionData(const char*) { return nullptr; }

const LV2UI_Descriptor descriptor{
    kRigUIURI, instantiate, cleanup, portEvent, extensionData};

extern "C" __attribute__((visibility("default")))
const LV2UI_Descriptor* lv2ui_descriptor(uint32_t index) {
  return index == 0 ? &descriptor : nullptr;
}
