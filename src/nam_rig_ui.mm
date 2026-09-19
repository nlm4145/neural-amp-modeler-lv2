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
#define NAM_RIG_OUTPUT_DB_URI NAM_RIG_URI "-output-db"

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
- (void)duplicateCurrentPreset:(id)sender;
- (void)deleteCurrentPreset:(id)sender;
- (void)revealPresetsInFinder:(id)sender;
- (void)switchTab:(NSButton*)sender;
- (void)switchDeckTab:(NSButton*)sender;
- (void)toggleMuteOnTune:(NSButton*)sender;
- (void)abPresetChanged:(NSPopUpButton*)sender;
- (void)abIntervalChanged:(NSSlider*)sender;
- (void)abToggleClicked:(NSButton*)sender;
- (void)abTimerFired:(NSTimer*)timer;
- (void)applyDelayPreset:(NSButton*)sender;
- (void)applyReverbPreset:(NSButton*)sender;
- (void)applySpatialPreset:(NSButton*)sender;
- (void)applyPowerPreset:(NSButton*)sender;
- (void)applySculptPreset:(NSButton*)sender;
- (void)applySpeakerPreset:(NSButton*)sender;
- (void)applyCabConsolePreset:(NSButton*)sender;
- (void)applyTransformerPreset:(NSButton*)sender;
- (void)markPresetModified;
@end
@implementation NAMRigUIController
- (void)switchTab:(NSButton*)sender {
  if (!_state) return;
  _state->selectTab(sender.tag);
}
- (void)switchDeckTab:(NSButton*)sender {
  if (!_state) return;
  _state->selectDeckTab(sender.tag);
}
- (void)toggleMuteOnTune:(NSButton*)sender {
  if (!_state) return;
  _state->muteOnTune = (sender.state == NSControlStateValueOn);
  sender.contentTintColor = _state->muteOnTune ? rigText() : rigDimText();
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
  for (size_t k = 0; k < kRigKnobCount; ++k) {
    if (_state->valueLabels[k] == f) _state->knobFieldEditing[k] = true;
    if (_state->deckValueLabels[k] == f) _state->deckKnobFieldEditing[k] = true;
  }
}
- (void)controlTextDidEndEditing:(NSNotification*)obj {
  if (!_state) return;
  NSTextField* f = obj.object;
  if (![f isKindOfClass:[NSTextField class]]) return;
  for (size_t k = 0; k < kRigKnobCount; ++k) {
    if (_state->valueLabels[k] == f || _state->deckValueLabels[k] == f) {
      _state->knobFieldEditing[k] = false;
      _state->deckKnobFieldEditing[k] = false;
      // Commit on click-away / Tab too (Enter already ran the action; the
      // equality guard keeps a no-op focus visit from re-sending the value).
      NSSlider* knob = _state->knobs[k] ?: _state->deckKnobs[k];
      if (knob && ![f.stringValue isEqualToString:rigKnobValueText(kRigKnobPorts[k], knob.floatValue)])
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
  NSSlider* knob = _state->knobs[index] ?: _state->deckKnobs[index];
  if (!knob) return;

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
// If muteOnTune is active, temporarily silences output while tuning.
- (void)tunerToggled:(NSButton*)sender {
  if (!_state) return;
  const BOOL on = sender.state == NSControlStateValueOn;
  _state->sendControl(16, on ? 1.0f : 0.0f);
  sender.contentTintColor = on ? rigText() : rigDimText();
  sender.needsDisplay = YES;
  _state->tunerPanel.hidden = !on;
  if (on) {
    if (_state->muteOnTune) {
      for (size_t k = 0; k < kRigKnobCount; ++k) {
        if (kRigKnobPorts[k] == 5) {
          NSSlider* outK = _state->knobs[k] ?: _state->deckKnobs[k];
          if (outK) _state->unmutedOutputLevel = outK.floatValue;
          break;
        }
      }
      _state->sendControl(5, -80.0f);
      _state->updateControl(5, -80.0f);
    }
  } else {
    if (_state->muteOnTune) {
      _state->sendControl(5, _state->unmutedOutputLevel);
      _state->updateControl(5, _state->unmutedOutputLevel);
    }
    _state->tunerNoteLabel.stringValue = @"—";
    _state->tunerCentsLabel.stringValue = @"";
    _state->tunerNeedle.hidden = YES;
  }
}

// Per-stage oversample control (pedal/amp tiles): ports 20/21, four visible
// modes mapped onto the sparse LV2 values 0, 4, 5, 6.
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
  (void)sender;
  if (!_state) return;
  _state->selectDeckTab(1);  // Switch to POWER STAGE & IRON in Lower Studio Deck
}

- (void)speakerProfileChanged:(NSPopUpButton*)sender {
  sender.toolTip = sender.selectedItem.toolTip;
  if (_state) {
    _state->sendControl(42, (float)sender.indexOfSelectedItem);
    [self markPresetModified];
  }
}

- (void)showSpeakerLoad:(NSButton*)sender {
  (void)sender;
  if (!_state) return;
  _state->selectDeckTab(2);  // Switch to CAB LAB & SPEAKER in Lower Studio Deck
}

- (void)showEffects:(NSButton*)sender {
  (void)sender;
  if (!_state) return;
  _state->selectDeckTab(0);  // Switch to POST-FX STUDIO in Lower Studio Deck
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

- (void)applyDelayPreset:(NSButton*)sender {
  if (!_state) return;
  const float times[] = {80.0f, 375.0f, 500.0f, 1000.0f, 1400.0f};
  if (sender.tag >= 0 && sender.tag < 5) {
    const float t = times[sender.tag];
    _state->sendControl(50, t);
    _state->updateControl(50, t);
    if (_state->knobs[31] && _state->knobs[31].floatValue < 1.0f) {
      _state->sendControl(53, 30.0f);
      _state->updateControl(53, 30.0f);
    }
    [self markPresetModified];
  }
}

- (void)applyReverbPreset:(NSButton*)sender {
  if (!_state) return;
  struct ReverbPreset { float mix, decay, size, damp, pre; };
  const ReverbPreset presets[] = {
    {30.0f, 50.0f, 60.0f, 40.0f, 15.0f}, // EMT 140
    {35.0f, 40.0f, 45.0f, 65.0f, 20.0f}, // WARM PLATE
    {25.0f, 70.0f, 80.0f, 80.0f, 30.0f}, // DARK TANK
    {40.0f, 85.0f, 95.0f, 15.0f, 5.0f},  // SHIMMER
    {20.0f, 20.0f, 30.0f, 45.0f, 8.0f}   // TIGHT ROOM
  };
  if (sender.tag >= 0 && sender.tag < 5) {
    const auto& p = presets[sender.tag];
    _state->sendControl(54, p.mix); _state->updateControl(54, p.mix);
    _state->sendControl(55, p.decay); _state->updateControl(55, p.decay);
    _state->sendControl(56, p.size); _state->updateControl(56, p.size);
    _state->sendControl(57, p.damp); _state->updateControl(57, p.damp);
    _state->sendControl(58, p.pre); _state->updateControl(58, p.pre);
    [self markPresetModified];
  }
}

- (void)applySpatialPreset:(NSButton*)sender {
  if (!_state) return;
  struct SpatialPreset { float width, room; };
  const SpatialPreset presets[] = {
    {0.0f, 0.0f},    // MONO CENTER
    {60.0f, 25.0f},  // STUDIO SPREAD
    {100.0f, 50.0f}, // WIDE 3D
    {80.0f, 85.0f}   // DEEP ROOM
  };
  if (sender.tag >= 0 && sender.tag < 4) {
    const auto& p = presets[sender.tag];
    _state->sendControl(32, p.width); _state->updateControl(32, p.width);
    _state->sendControl(33, p.room); _state->updateControl(33, p.room);
    [self markPresetModified];
  }
}

- (void)applyPowerPreset:(NSButton*)sender {
  if (!_state) return;
  struct PowerPreset { float sag, bias, fdbk; };
  const PowerPreset presets[] = {
    {40.0f, 15.0f, 20.0f}, // VINTAGE SAG
    {15.0f, 50.0f, 10.0f}, // HOT BIAS
    {5.0f, 0.0f, 40.0f},   // TIGHT NFB
    {0.0f, 0.0f, 0.0f}     // PURE CLEAN
  };
  if (sender.tag >= 0 && sender.tag < 4) {
    const auto& p = presets[sender.tag];
    _state->sendControl(36, p.sag); _state->updateControl(36, p.sag);
    _state->sendControl(37, p.bias); _state->updateControl(37, p.bias);
    _state->sendControl(38, p.fdbk); _state->updateControl(38, p.fdbk);
    [self markPresetModified];
  }
}

- (void)applySculptPreset:(NSButton*)sender {
  if (!_state) return;
  struct SculptPreset { float bright, inputEq; };
  const SculptPreset presets[] = {
    {6.0f, 0.0f},  // LEAD BOOST
    {3.0f, 75.0f}, // TIGHT CHUG
    {0.0f, 0.0f}   // FLAT
  };
  if (sender.tag >= 0 && sender.tag < 3) {
    const auto& p = presets[sender.tag];
    _state->sendControl(39, p.bright); _state->updateControl(39, p.bright);
    _state->sendControl(40, p.inputEq); _state->updateControl(40, p.inputEq);
    [self markPresetModified];
  }
}

- (void)applySpeakerPreset:(NSButton*)sender {
  if (!_state) return;
  struct SpeakerPreset { float drv, comp, thump, res; };
  const SpeakerPreset presets[] = {
    {30.0f, 25.0f, 60.0f, 50.0f}, // PUNCHY 4x12
    {45.0f, 40.0f, 35.0f, 70.0f}, // VINTAGE OPEN
    {50.0f, 50.0f, 85.0f, 40.0f}, // HEAVY THUMP
    {0.0f, 0.0f, 0.0f, 0.0f}      // FLAT BYPASS
  };
  if (sender.tag >= 0 && sender.tag < 4) {
    const auto& p = presets[sender.tag];
    _state->sendControl(43, p.drv); _state->updateControl(43, p.drv);
    _state->sendControl(44, p.comp); _state->updateControl(44, p.comp);
    _state->sendControl(45, p.thump); _state->updateControl(45, p.thump);
    _state->sendControl(46, p.res); _state->updateControl(46, p.res);
    [self markPresetModified];
  }
}

- (void)applyCabConsolePreset:(NSButton*)sender {
  if (!_state) return;
  struct CabConsolePreset { float aLvl, bLvl, align, lowCut, hiCut; };
  const CabConsolePreset presets[] = {
    {0.0f, 0.0f, 0.0f, 60.0f, 12000.0f},    // 50/50 STEREO
    {2.0f, -4.0f, 0.5f, 80.0f, 10000.0f},   // LEAD FOCUS
    {-1.0f, -1.0f, 1.2f, 50.0f, 15000.0f}   // WIDE ROOM
  };
  if (sender.tag >= 0 && sender.tag < 3) {
    const auto& p = presets[sender.tag];
    _state->sendControl(25, p.aLvl); _state->updateControl(25, p.aLvl);
    _state->sendControl(48, p.bLvl); _state->updateControl(48, p.bLvl);
    _state->sendControl(49, p.align); _state->updateControl(49, p.align);
    _state->sendControl(26, p.lowCut); _state->updateControl(26, p.lowCut);
    _state->sendControl(27, p.hiCut); _state->updateControl(27, p.hiCut);
    [self markPresetModified];
  }
}

- (void)applyTransformerPreset:(NSButton*)sender {
  if (!_state) return;
  const int transMap[] = {0, 3, 5, 11};
  if (sender.tag >= 0 && sender.tag < 4) {
    int transIdx = transMap[sender.tag];
    _state->sendControl(30, (float)transIdx);
    _state->updateControl(30, (float)transIdx);
    [self markPresetModified];
  }
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
  // Command rows (Save / Save As… / Delete / Duplicate / Reveal) and the
  // separators carry no representedObject — they fire their own actions via
  // target/action (or do nothing), so ignore them here instead of treating
  // their title as a preset name. Just snap the button back to the current
  // preset; the command's own action runs separately through the responder
  // chain when applicable.
  NSString* name = nil;
  if ([item.representedObject isKindOfClass:[NSString class]])
    name = item.representedObject;
  if (!name.length) {
    _state->resyncPresetPopupSelection();
    return;
  }
  RigPreset* preset = [_state->presetManager loadPresetNamed:name];
  if (preset) {
    [preset applyToState:_state];
    _state->syncABNameA();
    _state->updatePresetDisplayTitle();
  } else {
    _state->resyncPresetPopupSelection();
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
      _state->syncABNameA();
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
      _state->syncABNameA();
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
  } else {
    _state->resyncPresetPopupSelection();
    if (err) {
      NSAlert* alert = [[NSAlert alloc] init];
      alert.messageText = @"Save Failed";
      alert.informativeText = err.localizedDescription;
      [alert runModal];
    }
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
    if (!name.length) {
      _state->resyncPresetPopupSelection();
      return;
    }
    NSError* err = nil;
    if ([_state->presetManager savePresetNamed:name fromState:_state error:&err]) {
      _state->updatePresetDisplayTitle();
    } else {
      _state->resyncPresetPopupSelection();
      if (err) {
        NSAlert* fail = [[NSAlert alloc] init];
        fail.messageText = @"Save Failed";
        fail.informativeText = err.localizedDescription;
        [fail runModal];
      }
    }
  } else {
    _state->resyncPresetPopupSelection();
  }
}

- (void)deleteCurrentPreset:(id)sender {
  (void)sender;
  if (!_state || !_state->presetManager) return;
  NSString* cur = _state->presetManager.currentPresetName;
  if (!cur.length || [cur isEqualToString:@"Default Rig"]) {
    _state->resyncPresetPopupSelection();
    return;
  }

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
    } else {
      _state->resyncPresetPopupSelection();
    }
  } else {
    _state->resyncPresetPopupSelection();
  }
}

- (void)duplicateCurrentPreset:(id)sender {
  (void)sender;
  if (!_state || !_state->presetManager) return;
  NSString* base = _state->presetManager.currentPresetName.length
      ? _state->presetManager.currentPresetName : @"Default Rig";
  NSString* suggestion = [_state->presetManager uniquePresetNameForBase:base];

  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"Duplicate Preset";
  alert.informativeText = [NSString stringWithFormat:
      @"Duplicate '%@' as:", base];
  [alert addButtonWithTitle:@"Duplicate"];
  [alert addButtonWithTitle:@"Cancel"];

  NSTextField* input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  input.stringValue = suggestion;
  alert.accessoryView = input;
  [alert.window setInitialFirstResponder:input];

  if ([alert runModal] == NSAlertFirstButtonReturn) {
    NSString* name = [input.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) name = suggestion;
    // A taken name (e.g. typed while another duplicate landed) auto-bumps to
    // the next free "Copy N" instead of failing.
    if ([_state->presetManager.presetNames containsObject:name])
      name = [_state->presetManager uniquePresetNameForBase:name];
    NSError* err = nil;
    if ([_state->presetManager duplicateCurrentPresetFromState:_state
                                                      withName:name
                                                         error:&err]) {
      RigPreset* dup = [_state->presetManager loadPresetNamed:name];
      if (dup) [dup applyToState:_state];
      _state->updatePresetDisplayTitle();
    } else {
      _state->resyncPresetPopupSelection();
      if (err) {
        NSAlert* fail = [[NSAlert alloc] init];
        fail.messageText = @"Duplicate Failed";
        fail.informativeText = err.localizedDescription;
        [fail runModal];
      }
    }
  } else {
    _state->resyncPresetPopupSelection();
  }
}

- (void)revealPresetsInFinder:(id)sender {
  (void)sender;
  if (!_state || !_state->presetManager) return;
  [_state->presetManager revealPresetsInFinder];
  // Opening Finder doesn't change the rig, so keep the popup on the current
  // preset instead of rebuilding (rebuild is harmless but flashes the menu).
  _state->resyncPresetPopupSelection();
}

// ---- Hands-free A/B preset compare ----
// A is the live active preset (main window); the B dropdown memorizes the
// other side. START alternates between them on a timer so the player can
// audition while playing. STOP (same button, or changing B) halts the cycle
// on the current sound.
- (void)abPresetChanged:(NSPopUpButton*)sender {
  if (!_state || sender != _state->abPresetB) return;
  NSString* name = sender.selectedItem.representedObject;
  if (![name isKindOfClass:[NSString class]]) return;
  _state->abNameB = name;
  // Changing B mid-cycle stops on the newly picked preset: predictable and
  // hands-free (no surprise switch a second later).
  if (_state->abCycling) {
    _state->stopAB();
    _state->applyPresetByName(name);
    _state->abShowingA = NO;
    _state->updateABStatus();
  } else {
    _state->updateABStatus();
  }
}
- (void)abIntervalChanged:(NSSlider*)sender {
  if (!_state) return;
  // Slider spans 0..30s; clamp the timer floor to 0.25s so 0 stays usable as
  // "switch as fast as possible" without hammering preset loads.
  double secs = sender.doubleValue;
  if (secs < 0.0) secs = 0.0;
  if (secs > 30.0) secs = 30.0;
  _state->abIntervalSec = secs;
  if (_state->abIntervalLabel)
    _state->abIntervalLabel.stringValue = [NSString stringWithFormat:@"%.0fs", secs];
  // Restart the cadence mid-cycle so the new interval takes effect now.
  if (_state->abCycling) _state->restartABTimer();
}
- (void)abToggleClicked:(NSButton*)sender {
  (void)sender;
  if (!_state) return;
  _state->toggleAB();
}
- (void)abTimerFired:(NSTimer*)timer {
  (void)timer;
  if (!_state) return;
  _state->abTick();
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
  knob.colorStyle = rigKnobColorStyleForPort((uint32_t)port);
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

static RigButton* rigChip(NSView* parent, NSString* title, id target, SEL action, NSInteger tag) {
  RigButton* b = [[RigButton alloc] initWithFrame:NSZeroRect];
  b.title = title;
  b.target = target;
  b.action = action;
  b.tag = tag;
  b.font = [NSFont systemFontOfSize:8.0 weight:NSFontWeightBold];
  b.bordered = NO;
  b.translatesAutoresizingMaskIntoConstraints = NO;
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
  const CGFloat bw = 1520.0 - pad * 2;

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
  [[toneTitle.leadingAnchor constraintEqualToAnchor:tonePane.leadingAnchor constant:24] setActive:YES];
  [[toneTitle.topAnchor constraintEqualToAnchor:tonePane.topAnchor constant:10] setActive:YES];
  [[toneTitle.heightAnchor constraintEqualToConstant:26] setActive:YES];

  controller.authStatus = addLabel(tonePane, @"", NSZeroRect,
                                   [NSFont systemFontOfSize:10], rigDimText());
  controller.authStatus.translatesAutoresizingMaskIntoConstraints = NO;
  [tonePane addSubview:controller.authStatus];
  [[controller.authStatus.leadingAnchor constraintEqualToAnchor:toneTitle.trailingAnchor constant:10] setActive:YES];
  [[controller.authStatus.centerYAnchor constraintEqualToAnchor:toneTitle.centerYAnchor] setActive:YES];
  [[controller.authStatus.widthAnchor constraintEqualToConstant:100] setActive:YES];

  // Mode selector (toggles) + Connect — single row beneath the brand.
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

  controller.connectButton = rigButton(tonePane, @"Connect", controller,
      @selector(connectTone3000:), NSZeroRect);
  controller.connectButton.primary = NO;
  controller.connectButton.state = NSControlStateValueOff;
  controller.connectButton.toolTip = @"Sign in to Tone3000 in your browser. A stored valid session reconnects automatically.";
  controller.connectButton.translatesAutoresizingMaskIntoConstraints = NO;
  [tonePane addSubview:controller.connectButton];
  [[controller.connectButton.trailingAnchor constraintEqualToAnchor:tonePane.trailingAnchor constant:-24] setActive:YES];
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

  // Search / tone type / sort row: search query, tone type (gear), and sort order side-by-side.
  const CGFloat searchW = bw * 0.42;
  controller.search = [[NSSearchField alloc] initWithFrame:NSMakeRect(24, bh - 38, searchW, 28)];
  controller.search.placeholderString = @"Search Tone3000";
  controller.search.focusRingType = NSFocusRingTypeNone;
  controller.search.toolTip = @"Search Tone3000 by tone title, creator, or gear type. Online results load page by page.";
  controller.search.delegate = controller;
  [browser addSubview:controller.search];

  const CGFloat gearW = 126.0;
  controller.gear = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(24 + searchW + 12, bh - 38, gearW, 28) pullsDown:NO];
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
  controller.gear.target = controller;
  controller.gear.action = @selector(filterChanged:);
  controller.gear.controlSize = NSControlSizeSmall;
  controller.gear.toolTip = @"Filter Tone3000 results by capture type: amps, cabinets, pedals, or complete amp-and-cab rigs.";
  [browser addSubview:controller.gear];

  const CGFloat sortW = 160.0;
  controller.sort = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(24 + searchW + 12 + gearW + 10, bh - 38, sortW, 28) pullsDown:NO];
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
  controller.sort.target = controller;
  controller.sort.action = @selector(sortChanged:);
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

@interface NAMRigHeaderBar : NSView
@end
@implementation NAMRigHeaderBar
- (NSView *)hitTest:(NSPoint)point {
  // NOTE: point is in superview coordinates (AppKit contract). Convert to
  // self coordinates once, then let each subview hit-test from there. The
  // manual front-to-back walk (instead of relying solely on super) keeps the
  // tuner readout panel — which overflows below the 26pt bar — hoverable and
  // ensures the tuner toggle itself stays clickable.
  if (!self.superview) return [super hitTest:point];
  NSPoint pSelf = [self convertPoint:point fromView:self.superview];
  for (NSView *sub in [self.subviews reverseObjectEnumerator]) {
    if (sub.isHidden) continue;
    NSView *hit = [sub hitTest:pSelf];
    if (hit) return hit;
  }
  return [super hitTest:point];
}
@end

@interface NAMRigHeaderGroup : NSView
@end
@implementation NAMRigHeaderGroup
- (NSView *)hitTest:(NSPoint)point {
  if (!self.superview) return [super hitTest:point];
  NSPoint pSelf = [self convertPoint:point fromView:self.superview];
  for (NSView *sub in [self.subviews reverseObjectEnumerator]) {
    if (sub.isHidden) continue;
    NSView *hit = [sub hitTest:pSelf];
    if (hit) return hit;
  }
  return [super hitTest:point];
}
@end

@interface NAMRigRootView : NSView
@property (nonatomic, strong) NSView* headerBar;
- (void)layoutHeaderInHostWindow;
@end

@implementation NAMRigRootView
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (!self.window) {
    [_headerBar removeFromSuperview];
  } else {
    [self layoutHeaderInHostWindow];
  }
}

- (void)setFrame:(NSRect)frame {
  [super setFrame:frame];
  [self layoutHeaderInHostWindow];
}

- (void)layout {
  [super layout];
  [self layoutHeaderInHostWindow];
}

- (void)setHidden:(BOOL)hidden {
  [super setHidden:hidden];
  if (_headerBar && _headerBar.superview != self) {
    _headerBar.hidden = hidden;
  }
}

- (void)layoutHeaderInHostWindow {
  if (!self.window || !_headerBar) return;
  NSView* contentRoot = self.window.contentView;
  if (!contentRoot) return;

  NSRect selfFrameInContent = [self convertRect:self.bounds toView:contentRoot];
  CGFloat topSpace = 0.0;
  if (contentRoot.isFlipped) {
    topSpace = NSMinY(selfFrameInContent);
  } else {
    topSpace = contentRoot.bounds.size.height - NSMaxY(selfFrameInContent);
  }

  // When hosted in Element, there is a 24-26pt host toolbar strip above the plugin view.
  if (topSpace >= 20.0) {
    CGFloat barH = 26.0;
    CGFloat barY = 0.0;
    if (contentRoot.isFlipped) {
      barY = NSMinY(selfFrameInContent) - topSpace + (topSpace - barH) / 2.0;
    } else {
      barY = NSMaxY(selfFrameInContent) + (topSpace - barH) / 2.0;
    }
    CGFloat barX = NSMinX(selfFrameInContent) + 46.0;
    CGFloat barW = selfFrameInContent.size.width - 46.0 - 32.0;
    if (barW < 400.0) barW = 400.0;

    if (_headerBar.superview != contentRoot) {
      [_headerBar removeFromSuperview];
      _headerBar.translatesAutoresizingMaskIntoConstraints = YES;
      _headerBar.autoresizingMask = NSViewNotSizable;
      [contentRoot addSubview:_headerBar positioned:NSWindowAbove relativeTo:nil];
    }
    _headerBar.frame = NSMakeRect(barX, barY, barW, barH);
  } else {
    // Non-Element host fallback: header stays pinned at top of plugin view
    if (_headerBar.superview != self) {
      [_headerBar removeFromSuperview];
      _headerBar.translatesAutoresizingMaskIntoConstraints = YES;
      [self addSubview:_headerBar];
    }
    _headerBar.frame = NSMakeRect(24.0, 10.0, self.bounds.size.width - 48.0, 26.0);
  }
}
@end

static NSView* addDeckKnobCell(NSView* parent,
                               RigUIState* state,
                               size_t k,
                               const std::array<double, kRigKnobCount>& mins,
                               const std::array<double, kRigKnobCount>& maxes,
                               NSArray<NSString*>* knobNames,
                               NSArray<NSString*>* knobDescriptions) {
  NSView* cell = [[NSView alloc] initWithFrame:NSZeroRect];
  cell.translatesAutoresizingMaskIntoConstraints = NO;
  [parent addSubview:cell];

  NSTextField* kname = addLabel(cell, knobNames[k], NSZeroRect,
                                [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
                                rigDimText(), NSTextAlignmentCenter);
  rigApplyTracking(kname, 1.1);
  kname.toolTip = knobDescriptions[k];
  kname.translatesAutoresizingMaskIntoConstraints = NO;
  centerX(kname, cell, 0);
  [[kname.topAnchor constraintEqualToAnchor:cell.topAnchor constant:2] setActive:YES];

  state->deckKnobs[k] = addKnob(cell, (NSInteger)kRigKnobPorts[k], kRigKnobDefaults[k],
                                mins[k], maxes[k],
                                NSMakePoint(0, 0), state->uiController);
  NSSlider* knob = state->deckKnobs[k];
  knob.toolTip = knobDescriptions[k];
  knob.translatesAutoresizingMaskIntoConstraints = NO;
  centerX(knob, cell, 0);
  [[knob.topAnchor constraintEqualToAnchor:kname.bottomAnchor constant:4] setActive:YES];

  state->deckValueLabels[k] = addLabel(cell, rigKnobValueText(kRigKnobPorts[k], kRigKnobDefaults[k]), NSZeroRect,
    [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightRegular], rigText(), NSTextAlignmentCenter);
  NSTextField* kval = state->deckValueLabels[k];
  kval.editable = YES;
  kval.selectable = YES;
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
  [[kval.topAnchor constraintEqualToAnchor:knob.bottomAnchor constant:4] setActive:YES];
  [[cell.bottomAnchor constraintGreaterThanOrEqualToAnchor:kval.bottomAnchor constant:2] setActive:YES];

  return cell;
}

static RigPanel* addStudioRackSection(NSView* parent, NSString* title, NSString* subtitle, NSColor* titleColor) {
  RigPanel* rack = addPanel(parent, NSZeroRect);
  rack.translatesAutoresizingMaskIntoConstraints = NO;

  NSView* hView = [[NSView alloc] initWithFrame:NSZeroRect];
  hView.translatesAutoresizingMaskIntoConstraints = NO;
  [rack addSubview:hView];
  [[hView.topAnchor constraintEqualToAnchor:rack.topAnchor constant:10] setActive:YES];
  [[hView.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:14] setActive:YES];
  [[hView.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-14] setActive:YES];
  [[hView.heightAnchor constraintEqualToConstant:22] setActive:YES];

  NSTextField* tLabel = addLabel(hView, title, NSZeroRect,
                                 [NSFont systemFontOfSize:11 weight:NSFontWeightBold],
                                 titleColor, NSTextAlignmentLeft);
  rigApplyTracking(tLabel, 1.1);
  tLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [[tLabel.leadingAnchor constraintEqualToAnchor:hView.leadingAnchor] setActive:YES];
  [[tLabel.centerYAnchor constraintEqualToAnchor:hView.centerYAnchor] setActive:YES];

  if (subtitle.length) {
    NSTextField* sLabel = addLabel(hView, subtitle, NSZeroRect,
                                   [NSFont systemFontOfSize:8.5 weight:NSFontWeightMedium],
                                   rigDimText(), NSTextAlignmentRight);
    rigApplyTracking(sLabel, 0.6);
    sLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [[sLabel.trailingAnchor constraintEqualToAnchor:hView.trailingAnchor] setActive:YES];
    [[sLabel.centerYAnchor constraintEqualToAnchor:hView.centerYAnchor] setActive:YES];
    [[sLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:tLabel.trailingAnchor constant:8] setActive:YES];
  }

  NSBox* sep = [[NSBox alloc] initWithFrame:NSZeroRect];
  sep.boxType = NSBoxSeparator;
  sep.translatesAutoresizingMaskIntoConstraints = NO;
  [rack addSubview:sep];
  [[sep.topAnchor constraintEqualToAnchor:hView.bottomAnchor constant:6] setActive:YES];
  [[sep.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:12] setActive:YES];
  [[sep.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-12] setActive:YES];
  [[sep.heightAnchor constraintEqualToConstant:1] setActive:YES];

  return rack;
}

static NSView* addSignalNodeCard(NSView* parent, NSString* num, NSString* title, NSString* tech, NSString* badge, NSColor* accent) {
  NSView* card = [[NSView alloc] initWithFrame:NSZeroRect];
  card.translatesAutoresizingMaskIntoConstraints = NO;
  card.wantsLayer = YES;
  card.layer.cornerRadius = 6.0;
  card.layer.backgroundColor = [NSColor colorWithSRGBRed:0.11 green:0.12 blue:0.15 alpha:0.95].CGColor;
  card.layer.borderWidth = 1.0;
  card.layer.borderColor = [NSColor colorWithSRGBRed:0.20 green:0.22 blue:0.28 alpha:0.8].CGColor;
  [parent addSubview:card];

  NSTextField* numLbl = addLabel(card, num, NSZeroRect,
                                 [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightBold],
                                 accent, NSTextAlignmentLeft);
  numLbl.translatesAutoresizingMaskIntoConstraints = NO;
  [[numLbl.topAnchor constraintEqualToAnchor:card.topAnchor constant:8] setActive:YES];
  [[numLbl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8] setActive:YES];

  NSTextField* badgeLbl = addLabel(card, badge, NSZeroRect,
                                   [NSFont systemFontOfSize:8 weight:NSFontWeightBold],
                                   accent, NSTextAlignmentRight);
  rigApplyTracking(badgeLbl, 0.8);
  badgeLbl.translatesAutoresizingMaskIntoConstraints = NO;
  [[badgeLbl.topAnchor constraintEqualToAnchor:card.topAnchor constant:8] setActive:YES];
  [[badgeLbl.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8] setActive:YES];

  NSTextField* tLbl = addLabel(card, title, NSZeroRect,
                               [NSFont systemFontOfSize:10 weight:NSFontWeightBold],
                               rigText(), NSTextAlignmentLeft);
  rigApplyTracking(tLbl, 0.6);
  tLbl.translatesAutoresizingMaskIntoConstraints = NO;
  [[tLbl.topAnchor constraintEqualToAnchor:numLbl.bottomAnchor constant:4] setActive:YES];
  [[tLbl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8] setActive:YES];
  [[tLbl.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8] setActive:YES];

  NSTextField* dLbl = addLabel(card, tech, NSZeroRect,
                               [NSFont systemFontOfSize:8.5 weight:NSFontWeightRegular],
                               rigDimText(), NSTextAlignmentLeft);
  dLbl.translatesAutoresizingMaskIntoConstraints = NO;
  [[dLbl.topAnchor constraintEqualToAnchor:tLbl.bottomAnchor constant:4] setActive:YES];
  [[dLbl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8] setActive:YES];
  [[dLbl.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8] setActive:YES];
  [[card.bottomAnchor constraintGreaterThanOrEqualToAnchor:dLbl.bottomAnchor constant:8] setActive:YES];

  return card;
}

static void addLowerStudioDeck(RigUIState* state,
                               RigPanel* expansionSlot,
                               const std::array<double, kRigKnobCount>& mins,
                               const std::array<double, kRigKnobCount>& maxes,
                               NSArray<NSString*>* knobNames,
                               NSArray<NSString*>* knobDescriptions) {
  // 1. Deck Header Bar
  NSView* deckHeader = [[NSView alloc] initWithFrame:NSZeroRect];
  deckHeader.translatesAutoresizingMaskIntoConstraints = NO;
  [expansionSlot addSubview:deckHeader];
  [[deckHeader.topAnchor constraintEqualToAnchor:expansionSlot.topAnchor constant:10] setActive:YES];
  [[deckHeader.leadingAnchor constraintEqualToAnchor:expansionSlot.leadingAnchor constant:16] setActive:YES];
  [[deckHeader.trailingAnchor constraintEqualToAnchor:expansionSlot.trailingAnchor constant:-16] setActive:YES];
  [[deckHeader.heightAnchor constraintEqualToConstant:32] setActive:YES];

  // Title on the left
  NSTextField* deckTitle = addLabel(deckHeader, @"STUDIO PRO DECK", NSZeroRect,
                                    [NSFont systemFontOfSize:12 weight:NSFontWeightBold],
                                    rigText(), NSTextAlignmentLeft);
  rigApplyTracking(deckTitle, 1.2);
  deckTitle.translatesAutoresizingMaskIntoConstraints = NO;
  [[deckTitle.leadingAnchor constraintEqualToAnchor:deckHeader.leadingAnchor] setActive:YES];
  [[deckTitle.centerYAnchor constraintEqualToAnchor:deckHeader.centerYAnchor] setActive:YES];

  NSTextField* deckSub = addLabel(deckHeader, @"DOCKED HARDWARE CONSOLE", NSZeroRect,
                                  [NSFont systemFontOfSize:9 weight:NSFontWeightSemibold],
                                  rigDimText(), NSTextAlignmentLeft);
  rigApplyTracking(deckSub, 0.9);
  deckSub.translatesAutoresizingMaskIntoConstraints = NO;
  [[deckSub.leadingAnchor constraintEqualToAnchor:deckTitle.trailingAnchor constant:10] setActive:YES];
  [[deckSub.centerYAnchor constraintEqualToAnchor:deckHeader.centerYAnchor] setActive:YES];

  // Tab Buttons stack on the right
  NSStackView* tabStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
  tabStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  tabStack.distribution = NSStackViewDistributionFillEqually;
  tabStack.spacing = 8.0;
  tabStack.translatesAutoresizingMaskIntoConstraints = NO;
  [deckHeader addSubview:tabStack];
  [[tabStack.trailingAnchor constraintEqualToAnchor:deckHeader.trailingAnchor] setActive:YES];
  [[tabStack.centerYAnchor constraintEqualToAnchor:deckHeader.centerYAnchor] setActive:YES];
  [[tabStack.heightAnchor constraintEqualToConstant:26] setActive:YES];

  NSArray<NSString*>* tabTitles = @[
    @"POST-FX STUDIO",
    @"POWER STAGE & IRON",
    @"CAB LAB & SPEAKER",
    @"SIGNAL CHAIN MAP"
  ];
  NSMutableArray<RigButton*>* tabBtns = [NSMutableArray array];
  for (NSInteger i = 0; i < 4; ++i) {
    RigButton* b = rigButton(tabStack, tabTitles[(NSUInteger)i],
                             state->uiController, @selector(switchDeckTab:),
                             NSZeroRect);
    b.tag = i;
    b.buttonType = NSButtonTypeToggle;
    b.check = YES;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [tabStack addArrangedSubview:b];
    [[b.widthAnchor constraintEqualToConstant:162] setActive:YES];
    [[b.heightAnchor constraintEqualToConstant:26] setActive:YES];
    [tabBtns addObject:b];
  }
  state->deckTabButtons = tabBtns;

  // Hairline separator
  NSBox* sep = [[NSBox alloc] initWithFrame:NSZeroRect];
  sep.boxType = NSBoxSeparator;
  sep.translatesAutoresizingMaskIntoConstraints = NO;
  [expansionSlot addSubview:sep];
  [[sep.topAnchor constraintEqualToAnchor:deckHeader.bottomAnchor constant:6] setActive:YES];
  [[sep.leadingAnchor constraintEqualToAnchor:expansionSlot.leadingAnchor constant:16] setActive:YES];
  [[sep.trailingAnchor constraintEqualToAnchor:expansionSlot.trailingAnchor constant:-16] setActive:YES];
  [[sep.heightAnchor constraintEqualToConstant:1] setActive:YES];

  // 2. Deck Container
  NSView* deckContainer = [[NSView alloc] initWithFrame:NSZeroRect];
  deckContainer.translatesAutoresizingMaskIntoConstraints = NO;
  [expansionSlot addSubview:deckContainer];
  state->deckContainer = deckContainer;
  [[deckContainer.topAnchor constraintEqualToAnchor:sep.bottomAnchor constant:8] setActive:YES];
  [[deckContainer.leadingAnchor constraintEqualToAnchor:expansionSlot.leadingAnchor constant:16] setActive:YES];
  [[deckContainer.trailingAnchor constraintEqualToAnchor:expansionSlot.trailingAnchor constant:-16] setActive:YES];
  [[deckContainer.bottomAnchor constraintEqualToAnchor:expansionSlot.bottomAnchor constant:-12] setActive:YES];

  // Create 4 tab panes
  NSMutableArray<NSView*>* panes = [NSMutableArray array];
  for (NSInteger i = 0; i < 4; ++i) {
    NSView* p = [[NSView alloc] initWithFrame:NSZeroRect];
    p.translatesAutoresizingMaskIntoConstraints = NO;
    [deckContainer addSubview:p];
    [[p.topAnchor constraintEqualToAnchor:deckContainer.topAnchor] setActive:YES];
    [[p.bottomAnchor constraintEqualToAnchor:deckContainer.bottomAnchor] setActive:YES];
    [[p.leadingAnchor constraintEqualToAnchor:deckContainer.leadingAnchor] setActive:YES];
    [[p.trailingAnchor constraintEqualToAnchor:deckContainer.trailingAnchor] setActive:YES];
    [panes addObject:p];
  }
  state->deckTabPanes = panes;

  NSColor* violetColor = [NSColor colorWithSRGBRed:0.80 green:0.60 blue:1.00 alpha:1.0];
  NSColor* goldColor = [NSColor colorWithSRGBRed:1.00 green:0.75 blue:0.25 alpha:1.0];
  NSColor* emeraldColor = [NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:1.0];
  NSColor* cyanColor = [NSColor colorWithSRGBRed:0.25 green:0.85 blue:0.98 alpha:1.0];

  // ==========================================
  // PANE 0: POST-FX STUDIO
  // ==========================================
  NSView* pane0 = panes[0];
  NSStackView* row0 = [[NSStackView alloc] initWithFrame:NSZeroRect];
  row0.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row0.distribution = NSStackViewDistributionFillProportionally;
  row0.spacing = 14.0;
  row0.translatesAutoresizingMaskIntoConstraints = NO;
  [pane0 addSubview:row0];
  [[row0.topAnchor constraintEqualToAnchor:pane0.topAnchor] setActive:YES];
  [[row0.bottomAnchor constraintEqualToAnchor:pane0.bottomAnchor] setActive:YES];
  [[row0.leadingAnchor constraintEqualToAnchor:pane0.leadingAnchor] setActive:YES];
  [[row0.trailingAnchor constraintEqualToAnchor:pane0.trailingAnchor] setActive:YES];

  // 1. Stereo Tape Delay (4 knobs: 28, 29, 30, 31)
  {
    RigPanel* rack = addStudioRackSection(row0, @"STEREO TAPE DELAY", @"PANNED ECHOES & DAMPING", violetColor);
    [row0 addArrangedSubview:rack];

    NSStackView* kr = [[NSStackView alloc] initWithFrame:NSZeroRect];
    kr.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    kr.distribution = NSStackViewDistributionFillEqually;
    kr.spacing = 6.0;
    kr.translatesAutoresizingMaskIntoConstraints = NO;
    [rack addSubview:kr];
    [[kr.topAnchor constraintEqualToAnchor:rack.topAnchor constant:40] setActive:YES];
    [[kr.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:10] setActive:YES];
    [[kr.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-10] setActive:YES];
    [[kr.heightAnchor constraintEqualToConstant:108] setActive:YES];

    const size_t dlyK[4] = {28, 29, 30, 31};
    for (size_t idx : dlyK) {
      [kr addArrangedSubview:addDeckKnobCell(kr, state, idx, mins, maxes, knobNames, knobDescriptions)];
    }

    NSView* card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES; card.layer.cornerRadius = 6.0;
    card.layer.backgroundColor = [NSColor colorWithSRGBRed:0.11 green:0.12 blue:0.15 alpha:0.95].CGColor;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [NSColor colorWithSRGBRed:0.20 green:0.22 blue:0.28 alpha:0.8].CGColor;
    [rack addSubview:card];
    [[card.topAnchor constraintEqualToAnchor:kr.bottomAnchor constant:10] setActive:YES];
    [[card.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:12] setActive:YES];
    [[card.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-12] setActive:YES];
    [[card.bottomAnchor constraintEqualToAnchor:rack.bottomAnchor constant:-12] setActive:YES];

    NSTextField* desc = addLabel(card, @"Dual-tap ping-pong tape delay with analog high-frequency absorption and feedback limiting.",
                                 NSZeroRect, [NSFont systemFontOfSize:9.0 weight:NSFontWeightRegular],
                                 rigDimText(), NSTextAlignmentLeft);
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    [[desc.topAnchor constraintEqualToAnchor:card.topAnchor constant:8] setActive:YES];
    [[desc.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];

    NSStackView* chips = [[NSStackView alloc] initWithFrame:NSZeroRect];
    chips.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chips.distribution = NSStackViewDistributionFillEqually;
    chips.spacing = 6.0;
    chips.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:chips];
    [[chips.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:6] setActive:YES];
    [[chips.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[chips.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[chips.heightAnchor constraintEqualToConstant:20] setActive:YES];

    NSArray<NSString*>* delayPresetTitles = @[@"SLAP 80ms", @"1/8 DOT", @"1/4 NOTE", @"1/2 NOTE", @"AMBIENT"];
    for (NSInteger p = 0; p < (NSInteger)delayPresetTitles.count; ++p) {
      RigButton* b = rigChip(chips, delayPresetTitles[(NSUInteger)p], state->uiController, @selector(applyDelayPreset:), p);
      [chips addArrangedSubview:b];
    }

    NAMDelayTapVisualizer* delayVis = [[NAMDelayTapVisualizer alloc] initWithFrame:NSZeroRect];
    delayVis.translatesAutoresizingMaskIntoConstraints = NO;
    delayVis.timeMs = 400.0f;
    delayVis.feedback = 35.0f;
    delayVis.damping = 40.0f;
    delayVis.mix = 0.0f;
    state->delayVisualizer = delayVis;
    [card addSubview:delayVis];
    [[delayVis.topAnchor constraintEqualToAnchor:chips.bottomAnchor constant:8] setActive:YES];
    [[delayVis.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[delayVis.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[delayVis.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8] setActive:YES];
  }

  // 2. Studio Plate Reverb (5 knobs: 32, 33, 34, 35, 36)
  {
    RigPanel* rack = addStudioRackSection(row0, @"STUDIO PLATE REVERB", @"DIFFUSE SPACE & SHIMMER", violetColor);
    [row0 addArrangedSubview:rack];

    NSStackView* kr = [[NSStackView alloc] initWithFrame:NSZeroRect];
    kr.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    kr.distribution = NSStackViewDistributionFillEqually;
    kr.spacing = 6.0;
    kr.translatesAutoresizingMaskIntoConstraints = NO;
    [rack addSubview:kr];
    [[kr.topAnchor constraintEqualToAnchor:rack.topAnchor constant:40] setActive:YES];
    [[kr.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:10] setActive:YES];
    [[kr.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-10] setActive:YES];
    [[kr.heightAnchor constraintEqualToConstant:108] setActive:YES];

    const size_t rvbK[5] = {32, 33, 34, 35, 36};
    for (size_t idx : rvbK) {
      [kr addArrangedSubview:addDeckKnobCell(kr, state, idx, mins, maxes, knobNames, knobDescriptions)];
    }

    NSView* card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES; card.layer.cornerRadius = 6.0;
    card.layer.backgroundColor = [NSColor colorWithSRGBRed:0.11 green:0.12 blue:0.15 alpha:0.95].CGColor;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [NSColor colorWithSRGBRed:0.20 green:0.22 blue:0.28 alpha:0.8].CGColor;
    [rack addSubview:card];
    [[card.topAnchor constraintEqualToAnchor:kr.bottomAnchor constant:10] setActive:YES];
    [[card.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:12] setActive:YES];
    [[card.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-12] setActive:YES];
    [[card.bottomAnchor constraintEqualToAnchor:rack.bottomAnchor constant:-12] setActive:YES];

    NSTextField* desc = addLabel(card, @"Lush EMT 140 mechanical plate simulation with non-aliasing dispersion and damping.",
                                 NSZeroRect, [NSFont systemFontOfSize:9.0 weight:NSFontWeightRegular],
                                 rigDimText(), NSTextAlignmentLeft);
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    [[desc.topAnchor constraintEqualToAnchor:card.topAnchor constant:8] setActive:YES];
    [[desc.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];

    NSStackView* chips = [[NSStackView alloc] initWithFrame:NSZeroRect];
    chips.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chips.distribution = NSStackViewDistributionFillEqually;
    chips.spacing = 6.0;
    chips.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:chips];
    [[chips.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:6] setActive:YES];
    [[chips.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[chips.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[chips.heightAnchor constraintEqualToConstant:20] setActive:YES];

    NSArray<NSString*>* rvbPresetTitles = @[@"EMT 140", @"WARM PLATE", @"DARK TANK", @"SHIMMER", @"TIGHT ROOM"];
    for (NSInteger p = 0; p < (NSInteger)rvbPresetTitles.count; ++p) {
      RigButton* b = rigChip(chips, rvbPresetTitles[(NSUInteger)p], state->uiController, @selector(applyReverbPreset:), p);
      [chips addArrangedSubview:b];
    }

    NAMReverbDecayVisualizer* rvbVis = [[NAMReverbDecayVisualizer alloc] initWithFrame:NSZeroRect];
    rvbVis.translatesAutoresizingMaskIntoConstraints = NO;
    rvbVis.mix = 0.0f;
    rvbVis.decay = 50.0f;
    rvbVis.size = 50.0f;
    rvbVis.damping = 50.0f;
    rvbVis.preDelay = 10.0f;
    state->reverbVisualizer = rvbVis;
    [card addSubview:rvbVis];
    [[rvbVis.topAnchor constraintEqualToAnchor:chips.bottomAnchor constant:8] setActive:YES];
    [[rvbVis.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[rvbVis.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[rvbVis.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8] setActive:YES];
  }

  // 3. Spatial Acoustics (2 knobs: 12, 13)
  {
    RigPanel* rack = addStudioRackSection(row0, @"SPATIAL ACOUSTICS", @"STEREO SPREAD & ROOM", emeraldColor);
    [row0 addArrangedSubview:rack];

    NSStackView* kr = [[NSStackView alloc] initWithFrame:NSZeroRect];
    kr.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    kr.distribution = NSStackViewDistributionFillEqually;
    kr.spacing = 6.0;
    kr.translatesAutoresizingMaskIntoConstraints = NO;
    [rack addSubview:kr];
    [[kr.topAnchor constraintEqualToAnchor:rack.topAnchor constant:40] setActive:YES];
    [[kr.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:10] setActive:YES];
    [[kr.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-10] setActive:YES];
    [[kr.heightAnchor constraintEqualToConstant:108] setActive:YES];

    const size_t spkK[2] = {12, 13};
    for (size_t idx : spkK) {
      [kr addArrangedSubview:addDeckKnobCell(kr, state, idx, mins, maxes, knobNames, knobDescriptions)];
    }

    NSView* card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES; card.layer.cornerRadius = 6.0;
    card.layer.backgroundColor = [NSColor colorWithSRGBRed:0.11 green:0.12 blue:0.15 alpha:0.95].CGColor;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [NSColor colorWithSRGBRed:0.20 green:0.22 blue:0.28 alpha:0.8].CGColor;
    [rack addSubview:card];
    [[card.topAnchor constraintEqualToAnchor:kr.bottomAnchor constant:10] setActive:YES];
    [[card.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:12] setActive:YES];
    [[card.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-12] setActive:YES];
    [[card.bottomAnchor constraintEqualToAnchor:rack.bottomAnchor constant:-12] setActive:YES];

    NSTextField* desc = addLabel(card, @"True stereo width expansion and physical studio tracking room early reflections.",
                                 NSZeroRect, [NSFont systemFontOfSize:9.0 weight:NSFontWeightRegular],
                                 rigDimText(), NSTextAlignmentLeft);
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    [[desc.topAnchor constraintEqualToAnchor:card.topAnchor constant:8] setActive:YES];
    [[desc.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];

    NSStackView* chips = [[NSStackView alloc] initWithFrame:NSZeroRect];
    chips.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chips.distribution = NSStackViewDistributionFillEqually;
    chips.spacing = 6.0;
    chips.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:chips];
    [[chips.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:6] setActive:YES];
    [[chips.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[chips.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[chips.heightAnchor constraintEqualToConstant:20] setActive:YES];

    NSArray<NSString*>* spatialPresetTitles = @[@"MONO CENTER", @"STUDIO SPREAD", @"WIDE 3D", @"DEEP ROOM"];
    for (NSInteger p = 0; p < (NSInteger)spatialPresetTitles.count; ++p) {
      RigButton* b = rigChip(chips, spatialPresetTitles[(NSUInteger)p], state->uiController, @selector(applySpatialPreset:), p);
      [chips addArrangedSubview:b];
    }

    NAMSpatialAcousticVisualizer* spkVis = [[NAMSpatialAcousticVisualizer alloc] initWithFrame:NSZeroRect];
    spkVis.translatesAutoresizingMaskIntoConstraints = NO;
    spkVis.width = 0.0f;
    spkVis.room = 0.0f;
    state->spatialVisualizer = spkVis;
    [card addSubview:spkVis];
    [[spkVis.topAnchor constraintEqualToAnchor:chips.bottomAnchor constant:8] setActive:YES];
    [[spkVis.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[spkVis.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[spkVis.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8] setActive:YES];
  }

  // ==========================================
  // PANE 1: POWER STAGE & IRON
  // ==========================================
  NSView* pane1 = panes[1];
  NSStackView* row1 = [[NSStackView alloc] initWithFrame:NSZeroRect];
  row1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row1.distribution = NSStackViewDistributionFillProportionally;
  row1.spacing = 14.0;
  row1.translatesAutoresizingMaskIntoConstraints = NO;
  [pane1 addSubview:row1];
  [[row1.topAnchor constraintEqualToAnchor:pane1.topAnchor] setActive:YES];
  [[row1.bottomAnchor constraintEqualToAnchor:pane1.bottomAnchor] setActive:YES];
  [[row1.leadingAnchor constraintEqualToAnchor:pane1.leadingAnchor] setActive:YES];
  [[row1.trailingAnchor constraintEqualToAnchor:pane1.trailingAnchor] setActive:YES];

  // 1. Dynamic Power Stage (4 knobs: 21, 16, 17, 18)
  {
    RigPanel* rack = addStudioRackSection(row1, @"DYNAMIC POWER STAGE", @"DRIVE, SAG & FEEDBACK", goldColor);
    [row1 addArrangedSubview:rack];

    NSStackView* kr = [[NSStackView alloc] initWithFrame:NSZeroRect];
    kr.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    kr.distribution = NSStackViewDistributionFillEqually;
    kr.spacing = 6.0;
    kr.translatesAutoresizingMaskIntoConstraints = NO;
    [rack addSubview:kr];
    [[kr.topAnchor constraintEqualToAnchor:rack.topAnchor constant:40] setActive:YES];
    [[kr.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:10] setActive:YES];
    [[kr.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-10] setActive:YES];
    [[kr.heightAnchor constraintEqualToConstant:108] setActive:YES];

    const size_t pwrK[4] = {21, 16, 17, 18};
    for (size_t idx : pwrK) {
      [kr addArrangedSubview:addDeckKnobCell(kr, state, idx, mins, maxes, knobNames, knobDescriptions)];
    }

    NSView* card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES; card.layer.cornerRadius = 6.0;
    card.layer.backgroundColor = [NSColor colorWithSRGBRed:0.11 green:0.12 blue:0.15 alpha:0.95].CGColor;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [NSColor colorWithSRGBRed:0.20 green:0.22 blue:0.28 alpha:0.8].CGColor;
    [rack addSubview:card];
    [[card.topAnchor constraintEqualToAnchor:kr.bottomAnchor constant:10] setActive:YES];
    [[card.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:12] setActive:YES];
    [[card.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-12] setActive:YES];
    [[card.bottomAnchor constraintEqualToAnchor:rack.bottomAnchor constant:-12] setActive:YES];

    NSTextField* desc = addLabel(card, @"Power-supply sag droop, asymmetric tube harmonics, and output damping feedback.",
                                 NSZeroRect, [NSFont systemFontOfSize:9.0 weight:NSFontWeightRegular],
                                 rigDimText(), NSTextAlignmentLeft);
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    [[desc.topAnchor constraintEqualToAnchor:card.topAnchor constant:8] setActive:YES];
    [[desc.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];

    NSStackView* chips = [[NSStackView alloc] initWithFrame:NSZeroRect];
    chips.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chips.distribution = NSStackViewDistributionFillEqually;
    chips.spacing = 6.0;
    chips.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:chips];
    [[chips.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:6] setActive:YES];
    [[chips.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[chips.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[chips.heightAnchor constraintEqualToConstant:20] setActive:YES];

    NSArray<NSString*>* pwrPresetTitles = @[@"VINTAGE SAG", @"HOT BIAS", @"TIGHT NFB", @"PURE CLEAN"];
    for (NSInteger p = 0; p < (NSInteger)pwrPresetTitles.count; ++p) {
      RigButton* b = rigChip(chips, pwrPresetTitles[(NSUInteger)p], state->uiController, @selector(applyPowerPreset:), p);
      [chips addArrangedSubview:b];
    }

    NAMPowerStageVisualizer* pwrVis = [[NAMPowerStageVisualizer alloc] initWithFrame:NSZeroRect];
    pwrVis.translatesAutoresizingMaskIntoConstraints = NO;
    pwrVis.master = 0.0f;
    pwrVis.sag = 0.0f;
    pwrVis.bias = 0.0f;
    pwrVis.feedback = 0.0f;
    state->powerVisualizer = pwrVis;
    [card addSubview:pwrVis];
    [[pwrVis.topAnchor constraintEqualToAnchor:chips.bottomAnchor constant:8] setActive:YES];
    [[pwrVis.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[pwrVis.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[pwrVis.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8] setActive:YES];
  }

  // 2. Pre-Amp Sculpting (2 knobs: 19, 20)
  {
    RigPanel* rack = addStudioRackSection(row1, @"PRE-AMP TONAL SCULPT", @"INPUT CONDITIONING", goldColor);
    [row1 addArrangedSubview:rack];

    NSStackView* kr = [[NSStackView alloc] initWithFrame:NSZeroRect];
    kr.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    kr.distribution = NSStackViewDistributionFillEqually;
    kr.spacing = 6.0;
    kr.translatesAutoresizingMaskIntoConstraints = NO;
    [rack addSubview:kr];
    [[kr.topAnchor constraintEqualToAnchor:rack.topAnchor constant:40] setActive:YES];
    [[kr.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:10] setActive:YES];
    [[kr.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-10] setActive:YES];
    [[kr.heightAnchor constraintEqualToConstant:108] setActive:YES];

    const size_t sculptK[2] = {19, 20};
    for (size_t idx : sculptK) {
      [kr addArrangedSubview:addDeckKnobCell(kr, state, idx, mins, maxes, knobNames, knobDescriptions)];
    }

    NSView* card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES; card.layer.cornerRadius = 6.0;
    card.layer.backgroundColor = [NSColor colorWithSRGBRed:0.11 green:0.12 blue:0.15 alpha:0.95].CGColor;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [NSColor colorWithSRGBRed:0.20 green:0.22 blue:0.28 alpha:0.8].CGColor;
    [rack addSubview:card];
    [[card.topAnchor constraintEqualToAnchor:kr.bottomAnchor constant:10] setActive:YES];
    [[card.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:12] setActive:YES];
    [[card.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-12] setActive:YES];
    [[card.bottomAnchor constraintEqualToAnchor:rack.bottomAnchor constant:-12] setActive:YES];

    NSTextField* desc = addLabel(card, @"High-shelf bright boost and input high-pass tightener before the NAM capture.",
                                 NSZeroRect, [NSFont systemFontOfSize:9.0 weight:NSFontWeightRegular],
                                 rigDimText(), NSTextAlignmentLeft);
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    [[desc.topAnchor constraintEqualToAnchor:card.topAnchor constant:8] setActive:YES];
    [[desc.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];

    NSStackView* chips = [[NSStackView alloc] initWithFrame:NSZeroRect];
    chips.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chips.distribution = NSStackViewDistributionFillEqually;
    chips.spacing = 6.0;
    chips.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:chips];
    [[chips.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:6] setActive:YES];
    [[chips.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[chips.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[chips.heightAnchor constraintEqualToConstant:20] setActive:YES];

    NSArray<NSString*>* sculptPresetTitles = @[@"LEAD BOOST", @"TIGHT CHUG", @"FLAT"];
    for (NSInteger p = 0; p < (NSInteger)sculptPresetTitles.count; ++p) {
      RigButton* b = rigChip(chips, sculptPresetTitles[(NSUInteger)p], state->uiController, @selector(applySculptPreset:), p);
      [chips addArrangedSubview:b];
    }

    NAMSculptVisualizer* scVis = [[NAMSculptVisualizer alloc] initWithFrame:NSZeroRect];
    scVis.translatesAutoresizingMaskIntoConstraints = NO;
    scVis.bright = 0.0f;
    scVis.inputEq = 0.0f;
    state->sculptVisualizer = scVis;
    [card addSubview:scVis];
    [[scVis.topAnchor constraintEqualToAnchor:chips.bottomAnchor constant:8] setActive:YES];
    [[scVis.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[scVis.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[scVis.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8] setActive:YES];
  }

  // 3. Output Transformer Iron (Profile selector, port 30)
  {
    RigPanel* rack = addStudioRackSection(row1, @"OUTPUT TRANSFORMER IRON", @"MAGNETIC CORE SATURATION", goldColor);
    [row1 addArrangedSubview:rack];

    NSPopUpButton* deckTrans = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [deckTrans addItemsWithTitles:@[@"Captured / Off", @"Modern Iron",
                                   @"US Vintage", @"UK Vintage",
                                   @"Small Iron", @"Tight Metal",
                                   @"Extended Range", @"Thrash Bite",
                                   @"Doom Iron", @"Studio Linear",
                                   @"Tweed Bloom", @"Class-A Chime",
                                   @"Bass Iron"]];
    deckTrans.controlSize = NSControlSizeRegular;
    deckTrans.tag = 30;
    deckTrans.target = state->uiController;
    deckTrans.action = @selector(transformerChanged:);
    deckTrans.translatesAutoresizingMaskIntoConstraints = NO;
    [rack addSubview:deckTrans];
    [[deckTrans.topAnchor constraintEqualToAnchor:rack.topAnchor constant:44] setActive:YES];
    [[deckTrans.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:14] setActive:YES];
    [[deckTrans.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-14] setActive:YES];
    [[deckTrans.heightAnchor constraintEqualToConstant:26] setActive:YES];
    state->deckTransformerPopup = deckTrans;

    NSView* card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES; card.layer.cornerRadius = 6.0;
    card.layer.backgroundColor = [NSColor colorWithSRGBRed:0.11 green:0.12 blue:0.15 alpha:0.95].CGColor;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [NSColor colorWithSRGBRed:0.20 green:0.22 blue:0.28 alpha:0.8].CGColor;
    [rack addSubview:card];
    [[card.topAnchor constraintEqualToAnchor:deckTrans.bottomAnchor constant:10] setActive:YES];
    [[card.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:12] setActive:YES];
    [[card.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-12] setActive:YES];
    [[card.bottomAnchor constraintEqualToAnchor:rack.bottomAnchor constant:-12] setActive:YES];

    NSTextField* desc = addLabel(card, @"13 modeled grain-oriented steel laminations with core flux saturation & low-end bloom.",
                                 NSZeroRect, [NSFont systemFontOfSize:9.0 weight:NSFontWeightRegular],
                                 rigDimText(), NSTextAlignmentLeft);
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    [[desc.topAnchor constraintEqualToAnchor:card.topAnchor constant:8] setActive:YES];
    [[desc.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];

    NSStackView* chips = [[NSStackView alloc] initWithFrame:NSZeroRect];
    chips.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chips.distribution = NSStackViewDistributionFillEqually;
    chips.spacing = 6.0;
    chips.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:chips];
    [[chips.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:6] setActive:YES];
    [[chips.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[chips.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[chips.heightAnchor constraintEqualToConstant:20] setActive:YES];

    NSArray<NSString*>* transPresetTitles = @[@"CAPTURED/OFF", @"UK VINTAGE", @"TIGHT METAL", @"CLASS-A"];
    for (NSInteger p = 0; p < (NSInteger)transPresetTitles.count; ++p) {
      RigButton* b = rigChip(chips, transPresetTitles[(NSUInteger)p], state->uiController, @selector(applyTransformerPreset:), p);
      [chips addArrangedSubview:b];
    }

    NSStackView* specs = [[NSStackView alloc] initWithFrame:NSZeroRect];
    specs.orientation = NSUserInterfaceLayoutOrientationVertical;
    specs.distribution = NSStackViewDistributionFillEqually;
    specs.spacing = 5.0;
    specs.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:specs];
    [[specs.topAnchor constraintEqualToAnchor:chips.bottomAnchor constant:10] setActive:YES];
    [[specs.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12] setActive:YES];
    [[specs.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12] setActive:YES];
    [[specs.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10] setActive:YES];

    auto addSpecRow = ^(NSString* key, NSString* val) {
      NSStackView* row = [[NSStackView alloc] initWithFrame:NSZeroRect];
      row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
      row.distribution = NSStackViewDistributionFill;
      NSTextField* kLbl = addLabel(row, key, NSZeroRect, [NSFont systemFontOfSize:8.0 weight:NSFontWeightBold],
                                   [NSColor colorWithSRGBRed:0.50 green:0.55 blue:0.65 alpha:0.9], NSTextAlignmentLeft);
      rigApplyTracking(kLbl, 0.8);
      NSTextField* vLbl = addLabel(row, val, NSZeroRect, [NSFont monospacedDigitSystemFontOfSize:8.0 weight:NSFontWeightMedium],
                                   [NSColor colorWithSRGBRed:0.95 green:0.80 blue:0.40 alpha:0.95], NSTextAlignmentRight);
      [row addArrangedSubview:kLbl];
      [row addArrangedSubview:vLbl];
      [specs addArrangedSubview:row];
    };
    addSpecRow(@"CORE LAMINATION", @"M6 Grain-Oriented Silicon Steel");
    addSpecRow(@"SATURATION KNEE", @"1.85 Tesla Soft Flux Limiting");
    addSpecRow(@"REACTIVE BLOOM", @"LF Sub-Bass Inductance (<80 Hz)");
    addSpecRow(@"WINDING TOPOLOGY", @"Interleaved Bi-Filar Segments");
  }

  // ==========================================
  // PANE 2: CAB LAB & SPEAKER
  // ==========================================
  NSView* pane2 = panes[2];
  NSStackView* row2 = [[NSStackView alloc] initWithFrame:NSZeroRect];
  row2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row2.distribution = NSStackViewDistributionFillProportionally;
  row2.spacing = 14.0;
  row2.translatesAutoresizingMaskIntoConstraints = NO;
  [pane2 addSubview:row2];
  [[row2.topAnchor constraintEqualToAnchor:pane2.topAnchor] setActive:YES];
  [[row2.bottomAnchor constraintEqualToAnchor:pane2.bottomAnchor] setActive:YES];
  [[row2.leadingAnchor constraintEqualToAnchor:pane2.leadingAnchor] setActive:YES];
  [[row2.trailingAnchor constraintEqualToAnchor:pane2.trailingAnchor] setActive:YES];

  // 1. Physical Speaker Emulation (4 knobs: 22, 23, 24, 25 + profile popup port 42)
  {
    RigPanel* rack = addStudioRackSection(row2, @"PHYSICAL SPEAKER EMULATION", @"CONE DYNAMICS & REACTIVE LOAD", emeraldColor);
    [row2 addArrangedSubview:rack];

    NSPopUpButton* deckSpkr = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [deckSpkr addItemsWithTitles:@[@"Captured / Off", @"Auto", @"Resistive", @"Open Back",
                                  @"Vintage Alnico", @"UK 4x12", @"Modern 4x12", @"Bass"]];
    deckSpkr.controlSize = NSControlSizeRegular;
    deckSpkr.tag = 42;
    deckSpkr.target = state->uiController;
    deckSpkr.action = @selector(speakerProfileChanged:);
    deckSpkr.translatesAutoresizingMaskIntoConstraints = NO;
    [rack addSubview:deckSpkr];
    [[deckSpkr.topAnchor constraintEqualToAnchor:rack.topAnchor constant:40] setActive:YES];
    [[deckSpkr.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:14] setActive:YES];
    [[deckSpkr.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-14] setActive:YES];
    [[deckSpkr.heightAnchor constraintEqualToConstant:26] setActive:YES];
    state->deckSpeakerProfilePopup = deckSpkr;

    NSStackView* kr = [[NSStackView alloc] initWithFrame:NSZeroRect];
    kr.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    kr.distribution = NSStackViewDistributionFillEqually;
    kr.spacing = 6.0;
    kr.translatesAutoresizingMaskIntoConstraints = NO;
    [rack addSubview:kr];
    [[kr.topAnchor constraintEqualToAnchor:deckSpkr.bottomAnchor constant:8] setActive:YES];
    [[kr.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:10] setActive:YES];
    [[kr.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-10] setActive:YES];
    [[kr.heightAnchor constraintEqualToConstant:108] setActive:YES];

    const size_t spkrK[4] = {22, 23, 24, 25};
    for (size_t idx : spkrK) {
      [kr addArrangedSubview:addDeckKnobCell(kr, state, idx, mins, maxes, knobNames, knobDescriptions)];
    }

    NSView* card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES; card.layer.cornerRadius = 6.0;
    card.layer.backgroundColor = [NSColor colorWithSRGBRed:0.11 green:0.12 blue:0.15 alpha:0.95].CGColor;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [NSColor colorWithSRGBRed:0.20 green:0.22 blue:0.28 alpha:0.8].CGColor;
    [rack addSubview:card];
    [[card.topAnchor constraintEqualToAnchor:kr.bottomAnchor constant:10] setActive:YES];
    [[card.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:12] setActive:YES];
    [[card.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-12] setActive:YES];
    [[card.bottomAnchor constraintEqualToAnchor:rack.bottomAnchor constant:-12] setActive:YES];

    NSTextField* desc = addLabel(card, @"Physical voice-coil excursion limits, cone breakup, and nonlinear thump.",
                                 NSZeroRect, [NSFont systemFontOfSize:9.0 weight:NSFontWeightRegular],
                                 rigDimText(), NSTextAlignmentLeft);
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    [[desc.topAnchor constraintEqualToAnchor:card.topAnchor constant:8] setActive:YES];
    [[desc.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];

    NSStackView* chips = [[NSStackView alloc] initWithFrame:NSZeroRect];
    chips.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chips.distribution = NSStackViewDistributionFillEqually;
    chips.spacing = 6.0;
    chips.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:chips];
    [[chips.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:6] setActive:YES];
    [[chips.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[chips.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[chips.heightAnchor constraintEqualToConstant:20] setActive:YES];

    NSArray<NSString*>* spkrPresetTitles = @[@"PUNCHY 4x12", @"VINTAGE OPEN", @"HEAVY THUMP", @"FLAT BYPASS"];
    for (NSInteger p = 0; p < (NSInteger)spkrPresetTitles.count; ++p) {
      RigButton* b = rigChip(chips, spkrPresetTitles[(NSUInteger)p], state->uiController, @selector(applySpeakerPreset:), p);
      [chips addArrangedSubview:b];
    }

    NAMSpeakerDynamicsVisualizer* spkVis = [[NAMSpeakerDynamicsVisualizer alloc] initWithFrame:NSZeroRect];
    spkVis.translatesAutoresizingMaskIntoConstraints = NO;
    spkVis.drive = 25.0f;
    spkVis.comp = 25.0f;
    spkVis.thump = 50.0f;
    spkVis.resonance = 50.0f;
    state->speakerVisualizer = spkVis;
    [card addSubview:spkVis];
    [[spkVis.topAnchor constraintEqualToAnchor:chips.bottomAnchor constant:8] setActive:YES];
    [[spkVis.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[spkVis.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[spkVis.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8] setActive:YES];
  }

  // 2. Dual-Cabinet Blend Console (5 knobs: 8, 26, 27, 9, 10)
  {
    RigPanel* rack = addStudioRackSection(row2, @"DUAL-CABINET BLEND CONSOLE", @"LEVEL, PHASE ALIGN & CUTS", emeraldColor);
    [row2 addArrangedSubview:rack];

    NSStackView* kr = [[NSStackView alloc] initWithFrame:NSZeroRect];
    kr.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    kr.distribution = NSStackViewDistributionFillEqually;
    kr.spacing = 6.0;
    kr.translatesAutoresizingMaskIntoConstraints = NO;
    [rack addSubview:kr];
    [[kr.topAnchor constraintEqualToAnchor:rack.topAnchor constant:40] setActive:YES];
    [[kr.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:10] setActive:YES];
    [[kr.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-10] setActive:YES];
    [[kr.heightAnchor constraintEqualToConstant:108] setActive:YES];

    const size_t dualK[5] = {8, 26, 27, 9, 10};
    for (size_t idx : dualK) {
      [kr addArrangedSubview:addDeckKnobCell(kr, state, idx, mins, maxes, knobNames, knobDescriptions)];
    }

    NSView* card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES; card.layer.cornerRadius = 6.0;
    card.layer.backgroundColor = [NSColor colorWithSRGBRed:0.11 green:0.12 blue:0.15 alpha:0.95].CGColor;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [NSColor colorWithSRGBRed:0.20 green:0.22 blue:0.28 alpha:0.8].CGColor;
    [rack addSubview:card];
    [[card.topAnchor constraintEqualToAnchor:kr.bottomAnchor constant:10] setActive:YES];
    [[card.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:12] setActive:YES];
    [[card.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-12] setActive:YES];
    [[card.bottomAnchor constraintEqualToAnchor:rack.bottomAnchor constant:-12] setActive:YES];

    NSTextField* desc = addLabel(card, @"Cab A & B volume balance, microsecond delay phase-alignment & dual cut filters.",
                                 NSZeroRect, [NSFont systemFontOfSize:9.0 weight:NSFontWeightRegular],
                                 rigDimText(), NSTextAlignmentLeft);
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    [[desc.topAnchor constraintEqualToAnchor:card.topAnchor constant:8] setActive:YES];
    [[desc.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];

    NSStackView* chips = [[NSStackView alloc] initWithFrame:NSZeroRect];
    chips.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chips.distribution = NSStackViewDistributionFillEqually;
    chips.spacing = 6.0;
    chips.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:chips];
    [[chips.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:6] setActive:YES];
    [[chips.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[chips.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[chips.heightAnchor constraintEqualToConstant:20] setActive:YES];

    NSArray<NSString*>* cabPresetTitles = @[@"50/50 STEREO", @"LEAD FOCUS", @"WIDE ROOM"];
    for (NSInteger p = 0; p < (NSInteger)cabPresetTitles.count; ++p) {
      RigButton* b = rigChip(chips, cabPresetTitles[(NSUInteger)p], state->uiController, @selector(applyCabConsolePreset:), p);
      [chips addArrangedSubview:b];
    }

    NAMCabConsoleVisualizer* cabVis = [[NAMCabConsoleVisualizer alloc] initWithFrame:NSZeroRect];
    cabVis.translatesAutoresizingMaskIntoConstraints = NO;
    cabVis.cabALevel = 0.0f;
    cabVis.cabBLevel = 0.0f;
    cabVis.alignDelay = 0.0f;
    cabVis.lowCut = 0.0f;
    cabVis.highCut = 20000.0f;
    state->cabConsoleVisualizer = cabVis;
    [card addSubview:cabVis];
    [[cabVis.topAnchor constraintEqualToAnchor:chips.bottomAnchor constant:8] setActive:YES];
    [[cabVis.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[cabVis.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[cabVis.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8] setActive:YES];
  }

  // ==========================================
  // PANE 3: SIGNAL CHAIN MAP
  // ==========================================
  NSView* pane3 = panes[3];
  RigPanel* mapPanel = addPanel(pane3, NSZeroRect);
  mapPanel.translatesAutoresizingMaskIntoConstraints = NO;
  [[mapPanel.topAnchor constraintEqualToAnchor:pane3.topAnchor] setActive:YES];
  [[mapPanel.bottomAnchor constraintEqualToAnchor:pane3.bottomAnchor] setActive:YES];
  [[mapPanel.leadingAnchor constraintEqualToAnchor:pane3.leadingAnchor] setActive:YES];
  [[mapPanel.trailingAnchor constraintEqualToAnchor:pane3.trailingAnchor] setActive:YES];

  NSView* mh = [[NSView alloc] initWithFrame:NSZeroRect];
  mh.translatesAutoresizingMaskIntoConstraints = NO;
  [mapPanel addSubview:mh];
  [[mh.topAnchor constraintEqualToAnchor:mapPanel.topAnchor constant:10] setActive:YES];
  [[mh.leadingAnchor constraintEqualToAnchor:mapPanel.leadingAnchor constant:16] setActive:YES];
  [[mh.trailingAnchor constraintEqualToAnchor:mapPanel.trailingAnchor constant:-16] setActive:YES];
  [[mh.heightAnchor constraintEqualToConstant:22] setActive:YES];

  NSTextField* mt = addLabel(mh, @"AUDIO DSP SIGNAL FLOW ARCHITECTURE", NSZeroRect,
                             [NSFont systemFontOfSize:11 weight:NSFontWeightBold],
                             cyanColor, NSTextAlignmentLeft);
  rigApplyTracking(mt, 1.1);
  mt.translatesAutoresizingMaskIntoConstraints = NO;
  [[mt.leadingAnchor constraintEqualToAnchor:mh.leadingAnchor] setActive:YES];
  [[mt.centerYAnchor constraintEqualToAnchor:mh.centerYAnchor] setActive:YES];

  NSTextField* ms = addLabel(mh, @"END-TO-END DSP PROCESSING PIPELINE (INPUT JACK ➔ STEREO MASTER OUT)", NSZeroRect,
                             [NSFont systemFontOfSize:9 weight:NSFontWeightMedium],
                             rigDimText(), NSTextAlignmentRight);
  rigApplyTracking(ms, 0.7);
  ms.translatesAutoresizingMaskIntoConstraints = NO;
  [[ms.trailingAnchor constraintEqualToAnchor:mh.trailingAnchor] setActive:YES];
  [[ms.centerYAnchor constraintEqualToAnchor:mh.centerYAnchor] setActive:YES];

  NSBox* msep = [[NSBox alloc] initWithFrame:NSZeroRect];
  msep.boxType = NSBoxSeparator;
  msep.translatesAutoresizingMaskIntoConstraints = NO;
  [mapPanel addSubview:msep];
  [[msep.topAnchor constraintEqualToAnchor:mh.bottomAnchor constant:6] setActive:YES];
  [[msep.leadingAnchor constraintEqualToAnchor:mapPanel.leadingAnchor constant:16] setActive:YES];
  [[msep.trailingAnchor constraintEqualToAnchor:mapPanel.trailingAnchor constant:-16] setActive:YES];
  [[msep.heightAnchor constraintEqualToConstant:1] setActive:YES];

  // Row A (Nodes 01 - 05)
  NSStackView* rowA = [[NSStackView alloc] initWithFrame:NSZeroRect];
  rowA.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  rowA.distribution = NSStackViewDistributionFillEqually;
  rowA.spacing = 10.0;
  rowA.translatesAutoresizingMaskIntoConstraints = NO;
  [mapPanel addSubview:rowA];
  [[rowA.topAnchor constraintEqualToAnchor:msep.bottomAnchor constant:10] setActive:YES];
  [[rowA.leadingAnchor constraintEqualToAnchor:mapPanel.leadingAnchor constant:16] setActive:YES];
  [[rowA.trailingAnchor constraintEqualToAnchor:mapPanel.trailingAnchor constant:-16] setActive:YES];
  [[rowA.heightAnchor constraintEqualToConstant:94] setActive:YES];

  [rowA addArrangedSubview:addSignalNodeCard(rowA, @"01", @"INPUT & TUNER", @"Raw Input Trim • MPM Pitch Tracker", @"PRE-AMP", cyanColor)];
  [rowA addArrangedSubview:addSignalNodeCard(rowA, @"02", @"NOISE GATE & COMP", @"Opto-Comp • Fast Attack Noise Gate", @"DYNAMICS", cyanColor)];
  [rowA addArrangedSubview:addSignalNodeCard(rowA, @"03", @"NAM PEDAL", @"Neural Drive/Boost • True 8x OS", @"NEURAL", cyanColor)];
  [rowA addArrangedSubview:addSignalNodeCard(rowA, @"04", @"PRE-AMP SCULPT", @"Bright Boost • Input EQ Tightener", @"ANALOG EQ", goldColor)];
  [rowA addArrangedSubview:addSignalNodeCard(rowA, @"05", @"NAM AMP CORE", @"Core Neural Amp Head • True 8x OS", @"NEURAL CORE", goldColor)];

  // Connector between rows
  NSTextField* conn = addLabel(mapPanel, @"▼   ROUTING TO POWER STAGE, REACTIVE LOAD, DUAL CABINET CONVOLUTION & STEREO FX   ▼", NSZeroRect,
                               [NSFont systemFontOfSize:8.5 weight:NSFontWeightBold],
                               [NSColor colorWithSRGBRed:0.40 green:0.55 blue:0.75 alpha:0.8], NSTextAlignmentCenter);
  rigApplyTracking(conn, 1.4);
  conn.translatesAutoresizingMaskIntoConstraints = NO;
  [[conn.topAnchor constraintEqualToAnchor:rowA.bottomAnchor constant:8] setActive:YES];
  [[conn.leadingAnchor constraintEqualToAnchor:mapPanel.leadingAnchor constant:16] setActive:YES];
  [[conn.trailingAnchor constraintEqualToAnchor:mapPanel.trailingAnchor constant:-16] setActive:YES];

  // Row B (Nodes 06 - 11)
  NSStackView* rowB = [[NSStackView alloc] initWithFrame:NSZeroRect];
  rowB.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  rowB.distribution = NSStackViewDistributionFillEqually;
  rowB.spacing = 10.0;
  rowB.translatesAutoresizingMaskIntoConstraints = NO;
  [mapPanel addSubview:rowB];
  [[rowB.topAnchor constraintEqualToAnchor:conn.bottomAnchor constant:8] setActive:YES];
  [[rowB.leadingAnchor constraintEqualToAnchor:mapPanel.leadingAnchor constant:16] setActive:YES];
  [[rowB.trailingAnchor constraintEqualToAnchor:mapPanel.trailingAnchor constant:-16] setActive:YES];
  [[rowB.heightAnchor constraintEqualToConstant:94] setActive:YES];

  [rowB addArrangedSubview:addSignalNodeCard(rowB, @"06", @"POWER STAGE", @"Dynamic Sag • Tube Bias • Master", @"TUBE STAGE", goldColor)];
  [rowB addArrangedSubview:addSignalNodeCard(rowB, @"07", @"IRON CORE", @"Output Transformer Core Hysteresis", @"MAGNETIC", goldColor)];
  [rowB addArrangedSubview:addSignalNodeCard(rowB, @"08", @"SPEAKER LOAD", @"Reactive Impedance • Excursion Thump", @"REACTIVE LOAD", emeraldColor)];
  [rowB addArrangedSubview:addSignalNodeCard(rowB, @"09", @"DUAL CAB / IR", @"Parallel Cab A & B • Phase Alignment", @"CONVOLUTION", emeraldColor)];
  [rowB addArrangedSubview:addSignalNodeCard(rowB, @"10", @"POST-CAB EQ", @"3-Band Post EQ • Low/High Cuts", @"EQ / FILTER", emeraldColor)];
  [rowB addArrangedSubview:addSignalNodeCard(rowB, @"11", @"STEREO FX & OUT", @"Tape Delay • Plate Reverb • Master Out", @"POST-FX", violetColor)];
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
    state->outputDbURID = map->map(map->handle, NAM_RIG_OUTPUT_DB_URI);
    for (size_t i = 0; i < kPathURIs.size(); ++i) state->pathURIDs[i] = map->map(map->handle, kPathURIs[i]);
    lv2_atom_forge_init(&state->forge, map);

    const CGFloat baseW = 1520.0, baseH = 980.0;

    NAMRigRootView* rootView = [[NAMRigRootView alloc] initWithFrame:NSMakeRect(0, 0, baseW, baseH)];
    rootView.wantsLayer = YES;
    rootView.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    rootView.layer.backgroundColor = rigBG().CGColor;
    state->view = rootView;

    NAMRigHeaderBar* headerBar = [[NAMRigHeaderBar alloc] initWithFrame:NSMakeRect(46, 0, baseW - 78, 26)];
    headerBar.wantsLayer = YES;
    headerBar.layer.masksToBounds = NO;
    state->headerBar = headerBar;
    rootView.headerBar = headerBar;

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

    // Top tab switcher & zoom control mounted in headerBar.
    state->rigTabBtn = rigButton(headerBar, @"RIG", state->uiController, @selector(switchTab:), NSZeroRect);
    state->rigTabBtn.tag = 0;
    state->rigTabBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [[state->rigTabBtn.leadingAnchor constraintEqualToAnchor:headerBar.leadingAnchor] setActive:YES];
    [[state->rigTabBtn.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor] setActive:YES];
    [[state->rigTabBtn.widthAnchor constraintEqualToConstant:76] setActive:YES];
    [[state->rigTabBtn.heightAnchor constraintEqualToConstant:24] setActive:YES];
    state->rigTabBtn.toolTip = @"View the amp, pedal, cabinet stages and tone controls.";

    state->toneTabBtn = rigButton(headerBar, @"TONE3000", state->uiController, @selector(switchTab:), NSZeroRect);
    state->toneTabBtn.tag = 1;
    state->toneTabBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [[state->toneTabBtn.leadingAnchor constraintEqualToAnchor:state->rigTabBtn.trailingAnchor constant:6] setActive:YES];
    [[state->toneTabBtn.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor] setActive:YES];
    [[state->toneTabBtn.widthAnchor constraintEqualToConstant:98] setActive:YES];
    [[state->toneTabBtn.heightAnchor constraintEqualToConstant:24] setActive:YES];
    state->toneTabBtn.toolTip = @"Browse, search, and download NAM captures and cabinet IRs from Tone3000.";

    state->zoomControl = [[NSComboBox alloc] initWithFrame:NSZeroRect];
    state->zoomControl.target = state->uiController; state->zoomControl.action = @selector(zoomChanged:);
    state->zoomControl.editable = YES;               // custom zoom % only (no preset list)
    state->zoomControl.controlSize = NSControlSizeSmall;
    state->zoomControl.placeholderString = @"100%";
    state->zoomControl.toolTip = @"Set the plug-in interface scale from 50% to 400%. Type a percentage and press Return.";
    state->zoomControl.translatesAutoresizingMaskIntoConstraints = NO;
    [headerBar addSubview:state->zoomControl];
    [[state->zoomControl.trailingAnchor constraintEqualToAnchor:headerBar.trailingAnchor] setActive:YES];
    [[state->zoomControl.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor] setActive:YES];
    [[state->zoomControl.widthAnchor constraintEqualToConstant:90] setActive:YES];
    [[state->zoomControl.heightAnchor constraintEqualToConstant:24] setActive:YES];

    // Rig header group (tuner, input meter, preset management, reset knobs):
    // active in RIG tab, hidden in TONE3000 tab.
    NAMRigHeaderGroup* rigGroup = [[NAMRigHeaderGroup alloc] initWithFrame:NSZeroRect];
    rigGroup.translatesAutoresizingMaskIntoConstraints = NO;
    rigGroup.wantsLayer = YES;
    rigGroup.layer.masksToBounds = NO;
    [headerBar addSubview:rigGroup];
    state->rigHeaderGroup = rigGroup;
    [[rigGroup.leadingAnchor constraintEqualToAnchor:state->toneTabBtn.trailingAnchor constant:14] setActive:YES];
    [[rigGroup.trailingAnchor constraintEqualToAnchor:state->zoomControl.leadingAnchor constant:-10] setActive:YES];
    [[rigGroup.topAnchor constraintEqualToAnchor:headerBar.topAnchor] setActive:YES];
    [[rigGroup.bottomAnchor constraintEqualToAnchor:headerBar.bottomAnchor] setActive:YES];

    // Tuner toggle — flat icon button, dim when off, bright when on.
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
    [rigGroup addSubview:state->tunerButton];
    [[state->tunerButton.leadingAnchor constraintEqualToAnchor:rigGroup.leadingAnchor] setActive:YES];
    [[state->tunerButton.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[state->tunerButton.widthAnchor constraintEqualToConstant:28] setActive:YES];
    [[state->tunerButton.heightAnchor constraintEqualToConstant:24] setActive:YES];

    // Tuner readout panel — hidden until the toggle is on.
    NSView* tp = [[NSView alloc] initWithFrame:NSZeroRect];
    tp.wantsLayer = YES;
    tp.layer.backgroundColor = rigPanelBG().CGColor;
    tp.layer.cornerRadius = 8;
    tp.layer.borderWidth = 1.0;
    tp.layer.borderColor = rigPanelBorder().CGColor;
    tp.hidden = YES;
    tp.translatesAutoresizingMaskIntoConstraints = NO;
    [rigGroup addSubview:tp];
    tp.toolTip = @"Live tuner readout from the raw input signal.";
    state->tunerPanel = tp;
    [[tp.leadingAnchor constraintEqualToAnchor:state->tunerButton.leadingAnchor] setActive:YES];
    [[tp.topAnchor constraintEqualToAnchor:state->tunerButton.bottomAnchor constant:4] setActive:YES];
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

    // Tuner mute toggle button
    RigButton* muteBtn = rigButton(rigGroup, @"MUTE", state->uiController,
                                   @selector(toggleMuteOnTune:), NSZeroRect);
    muteBtn.toolTip = @"Mute guitar output while the tuner is active for silent tuning.";
    muteBtn.translatesAutoresizingMaskIntoConstraints = NO;
    muteBtn.buttonType = NSButtonTypeToggle;
    muteBtn.state = state->muteOnTune ? NSControlStateValueOn : NSControlStateValueOff;
    state->muteOnTuneButton = muteBtn;
    [[muteBtn.leadingAnchor constraintEqualToAnchor:state->tunerButton.trailingAnchor constant:4] setActive:YES];
    [[muteBtn.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[muteBtn.widthAnchor constraintEqualToConstant:48] setActive:YES];
    [[muteBtn.heightAnchor constraintEqualToConstant:24] setActive:YES];

    // Input level meter (always visible in rig header): dBFS readout + bar.
    NSView* mp = [[NSView alloc] initWithFrame:NSZeroRect];
    mp.wantsLayer = YES;
    mp.layer.backgroundColor = rigPanelBG().CGColor;
    mp.layer.cornerRadius = 8;
    mp.layer.borderWidth = 1.0;
    mp.layer.borderColor = rigPanelBorder().CGColor;
    mp.translatesAutoresizingMaskIntoConstraints = NO;
    [rigGroup addSubview:mp];
    mp.toolTip = @"Raw input level meter before the gate, trims, and model stages.";
    [[mp.leadingAnchor constraintEqualToAnchor:muteBtn.trailingAnchor constant:8] setActive:YES];
    [[mp.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[mp.widthAnchor constraintEqualToConstant:120] setActive:YES];
    [[mp.heightAnchor constraintEqualToConstant:24] setActive:YES];

    NSTextField* dbL = addLabel(mp, @"  —  dB", NSZeroRect,
                                [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightMedium],
                                rigDimText(), NSTextAlignmentCenter);
    dbL.translatesAutoresizingMaskIntoConstraints = NO;
    state->inDbLabel = dbL;
    dbL.toolTip = @"Raw input peak level in dBFS, measured before all processing.";
    [[dbL.leadingAnchor constraintEqualToAnchor:mp.leadingAnchor constant:4] setActive:YES];
    [[dbL.centerYAnchor constraintEqualToAnchor:mp.centerYAnchor] setActive:YES];
    [[dbL.widthAnchor constraintEqualToConstant:44] setActive:YES];

    // Track: dark slot; the fill bar width is set at update time (-60..0 dB).
    NSView* slot = [[NSView alloc] initWithFrame:NSZeroRect];
    slot.wantsLayer = YES;
    slot.layer.backgroundColor = rigRaised().CGColor;
    slot.layer.cornerRadius = 2;
    slot.translatesAutoresizingMaskIntoConstraints = NO;
    [mp addSubview:slot];
    slot.toolTip = @"Raw input peak meter from -60 to 0 dBFS. Orange indicates a hot input; red indicates clipping risk.";
    [[slot.leadingAnchor constraintEqualToAnchor:dbL.trailingAnchor constant:4] setActive:YES];
    [[slot.trailingAnchor constraintEqualToAnchor:mp.trailingAnchor constant:-6] setActive:YES];
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

    // Output level meter (post-effects combined peak)
    NSView* outMp = [[NSView alloc] initWithFrame:NSZeroRect];
    outMp.wantsLayer = YES;
    outMp.layer.backgroundColor = rigPanelBG().CGColor;
    outMp.layer.cornerRadius = 8;
    outMp.layer.borderWidth = 1.0;
    outMp.layer.borderColor = rigPanelBorder().CGColor;
    outMp.translatesAutoresizingMaskIntoConstraints = NO;
    [rigGroup addSubview:outMp];
    outMp.toolTip = @"Master output peak meter (combined L/R). Red indicates digital clipping.";
    [[outMp.leadingAnchor constraintEqualToAnchor:mp.trailingAnchor constant:8] setActive:YES];
    [[outMp.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[outMp.widthAnchor constraintEqualToConstant:120] setActive:YES];
    [[outMp.heightAnchor constraintEqualToConstant:24] setActive:YES];

    NSTextField* outDbL = addLabel(outMp, @"  —  dB", NSZeroRect,
                                   [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightMedium],
                                   rigDimText(), NSTextAlignmentCenter);
    outDbL.translatesAutoresizingMaskIntoConstraints = NO;
    state->outDbLabel = outDbL;
    outDbL.toolTip = @"Master output peak level in dBFS.";
    [[outDbL.leadingAnchor constraintEqualToAnchor:outMp.leadingAnchor constant:4] setActive:YES];
    [[outDbL.centerYAnchor constraintEqualToAnchor:outMp.centerYAnchor] setActive:YES];
    [[outDbL.widthAnchor constraintEqualToConstant:44] setActive:YES];

    NSView* outSlot = [[NSView alloc] initWithFrame:NSZeroRect];
    outSlot.wantsLayer = YES;
    outSlot.layer.backgroundColor = rigRaised().CGColor;
    outSlot.layer.cornerRadius = 2;
    outSlot.translatesAutoresizingMaskIntoConstraints = NO;
    [outMp addSubview:outSlot];
    outSlot.toolTip = @"Master output peak meter from -60 to 0 dBFS.";
    [[outSlot.leadingAnchor constraintEqualToAnchor:outDbL.trailingAnchor constant:4] setActive:YES];
    [[outSlot.trailingAnchor constraintEqualToAnchor:outMp.trailingAnchor constant:-6] setActive:YES];
    [[outSlot.centerYAnchor constraintEqualToAnchor:outMp.centerYAnchor] setActive:YES];
    [[outSlot.heightAnchor constraintEqualToConstant:8] setActive:YES];

    NSView* outFill = [[NSView alloc] initWithFrame:NSZeroRect];
    outFill.wantsLayer = YES;
    outFill.layer.backgroundColor = [NSColor colorWithSRGBRed:0.20 green:0.80 blue:0.95 alpha:1.0].CGColor;
    outFill.layer.cornerRadius = 2;
    outFill.translatesAutoresizingMaskIntoConstraints = NO;
    [outSlot addSubview:outFill];
    outFill.toolTip = @"Master output peak meter from -60 to 0 dBFS.";
    [[outFill.leadingAnchor constraintEqualToAnchor:outSlot.leadingAnchor] setActive:YES];
    [[outFill.centerYAnchor constraintEqualToAnchor:outSlot.centerYAnchor] setActive:YES];
    [[outFill.heightAnchor constraintEqualToConstant:8] setActive:YES];
    NSLayoutConstraint* outFillW =
        [NSLayoutConstraint constraintWithItem:outFill
                                     attribute:NSLayoutAttributeWidth
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:nil
                                     attribute:NSLayoutAttributeNotAnAttribute
                                    multiplier:1.0
                                      constant:0];
    outFillW.active = YES;
    state->outDbBar = outFill;
    state->outDbBarWidth = outFillW;

    // Preset management controls: [ ◀ ] [ Preset: Name ▾ ] [ ▶ ] [ SAVE ]
    RigButton* prevPresetBtn = rigButton(rigGroup, @"◀", state->uiController,
                                         @selector(prevPresetClicked:), NSZeroRect);
    prevPresetBtn.toolTip = @"Switch to the previous preset.";
    prevPresetBtn.translatesAutoresizingMaskIntoConstraints = NO;
    state->prevPresetBtn = prevPresetBtn;
    [[prevPresetBtn.leadingAnchor constraintEqualToAnchor:outMp.trailingAnchor constant:12] setActive:YES];
    [[prevPresetBtn.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[prevPresetBtn.widthAnchor constraintEqualToConstant:24] setActive:YES];
    [[prevPresetBtn.heightAnchor constraintEqualToConstant:24] setActive:YES];

    NSPopUpButton* presetPop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    presetPop.controlSize = NSControlSizeSmall;
    presetPop.target = state->uiController;
    presetPop.action = @selector(presetPopupChanged:);
    presetPop.toolTip = @"Active preset. Click to select a preset, save, or manage presets.";
    presetPop.translatesAutoresizingMaskIntoConstraints = NO;
    [rigGroup addSubview:presetPop];
    state->presetPopup = presetPop;
    [[presetPop.leadingAnchor constraintEqualToAnchor:prevPresetBtn.trailingAnchor constant:4] setActive:YES];
    [[presetPop.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[presetPop.widthAnchor constraintEqualToConstant:155] setActive:YES];
    [[presetPop.heightAnchor constraintEqualToConstant:24] setActive:YES];

    RigButton* nextPresetBtn = rigButton(rigGroup, @"▶", state->uiController,
                                         @selector(nextPresetClicked:), NSZeroRect);
    nextPresetBtn.toolTip = @"Switch to the next preset.";
    nextPresetBtn.translatesAutoresizingMaskIntoConstraints = NO;
    state->nextPresetBtn = nextPresetBtn;
    [[nextPresetBtn.leadingAnchor constraintEqualToAnchor:presetPop.trailingAnchor constant:4] setActive:YES];
    [[nextPresetBtn.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[nextPresetBtn.widthAnchor constraintEqualToConstant:24] setActive:YES];
    [[nextPresetBtn.heightAnchor constraintEqualToConstant:24] setActive:YES];

    RigButton* savePresetBtn = rigButton(rigGroup, @"SAVE", state->uiController,
                                         @selector(saveCurrentPreset:), NSZeroRect);
    savePresetBtn.toolTip = @"Save current rig settings to active preset, or save as a new preset.";
    savePresetBtn.translatesAutoresizingMaskIntoConstraints = NO;
    state->savePresetBtn = savePresetBtn;
    [[savePresetBtn.leadingAnchor constraintEqualToAnchor:nextPresetBtn.trailingAnchor constant:6] setActive:YES];
    [[savePresetBtn.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[savePresetBtn.widthAnchor constraintEqualToConstant:54] setActive:YES];
    [[savePresetBtn.heightAnchor constraintEqualToConstant:24] setActive:YES];

    RigButton* resetKnobsButton = rigButton(rigGroup, @"RESET KNOBS", state->uiController,
                                           @selector(resetAllKnobs:), NSZeroRect);
    resetKnobsButton.toolTip = @"Reset every knob to its factory default. Model selections, stage switches, profiles, and oversampling are unchanged.";
    resetKnobsButton.translatesAutoresizingMaskIntoConstraints = NO;
    [rigGroup addSubview:resetKnobsButton];
    [[resetKnobsButton.trailingAnchor constraintEqualToAnchor:rigGroup.trailingAnchor] setActive:YES];
    [[resetKnobsButton.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[resetKnobsButton.widthAnchor constraintEqualToConstant:112] setActive:YES];
    [[resetKnobsButton.heightAnchor constraintEqualToConstant:24] setActive:YES];

    // Hands-free A/B compare strip: B slot + 0-30s interval slider + START/STOP,
    // chained after SAVE so trailing RESET KNOBS stays put. A is the live
    // active preset in the main window; status shows the sounding side.
    NSTextField* abBLabel = addLabel(rigGroup, @"B", NSZeroRect,
                                     [NSFont systemFontOfSize:10 weight:NSFontWeightBold],
                                     rigDimText(), NSTextAlignmentCenter);
    abBLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [[abBLabel.leadingAnchor constraintEqualToAnchor:savePresetBtn.trailingAnchor constant:10] setActive:YES];
    [[abBLabel.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[abBLabel.widthAnchor constraintEqualToConstant:12] setActive:YES];
    abBLabel.toolTip = @"Preset slot B for hands-free compare. A is the active preset in the main window.";

    NSPopUpButton* abPopB = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    abPopB.controlSize = NSControlSizeSmall;
    abPopB.target = state->uiController;
    abPopB.action = @selector(abPresetChanged:);
    abPopB.tag = 1;
    abPopB.toolTip = @"Preset B: the other side of the hands-free A/B compare. A is the active preset.";
    abPopB.translatesAutoresizingMaskIntoConstraints = NO;
    [rigGroup addSubview:abPopB];
    state->abPresetB = abPopB;
    [[abPopB.leadingAnchor constraintEqualToAnchor:abBLabel.trailingAnchor constant:2] setActive:YES];
    [[abPopB.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[abPopB.widthAnchor constraintEqualToConstant:148] setActive:YES];
    [[abPopB.heightAnchor constraintEqualToConstant:24] setActive:YES];

    NSSlider* abIntSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    abIntSlider.minValue = 0.0;
    abIntSlider.maxValue = 30.0;
    abIntSlider.doubleValue = state->abIntervalSec;
    abIntSlider.target = state->uiController;
    abIntSlider.action = @selector(abIntervalChanged:);
    abIntSlider.continuous = YES;
    abIntSlider.toolTip = @"Seconds on each side before auto-switching (0-30s). Dragging mid-cycle restarts the cadence.";
    abIntSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [rigGroup addSubview:abIntSlider];
    state->abIntervalSlider = abIntSlider;
    [[abIntSlider.leadingAnchor constraintEqualToAnchor:abPopB.trailingAnchor constant:8] setActive:YES];
    [[abIntSlider.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[abIntSlider.widthAnchor constraintEqualToConstant:90] setActive:YES];

    NSTextField* abIntLabel = addLabel(rigGroup, @"4s", NSZeroRect,
                                       [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightMedium],
                                       rigDimText(), NSTextAlignmentLeft);
    abIntLabel.translatesAutoresizingMaskIntoConstraints = NO;
    state->abIntervalLabel = abIntLabel;
    abIntLabel.toolTip = @"A/B cycle interval in seconds.";
    [[abIntLabel.leadingAnchor constraintEqualToAnchor:abIntSlider.trailingAnchor constant:4] setActive:YES];
    [[abIntLabel.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[abIntLabel.widthAnchor constraintEqualToConstant:30] setActive:YES];

    RigButton* abToggle = rigButton(rigGroup, @"START", state->uiController,
                                    @selector(abToggleClicked:), NSZeroRect);
    abToggle.toolTip = @"Start or stop hands-free A/B cycling. START jumps to A immediately; STOP holds the current sound.";
    abToggle.translatesAutoresizingMaskIntoConstraints = NO;
    abToggle.buttonType = NSButtonTypeToggle;
    state->abCycleBtn = abToggle;
    [[abToggle.leadingAnchor constraintEqualToAnchor:abIntLabel.trailingAnchor constant:6] setActive:YES];
    [[abToggle.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[abToggle.widthAnchor constraintEqualToConstant:58] setActive:YES];
    [[abToggle.heightAnchor constraintEqualToConstant:24] setActive:YES];

    NSTextField* abStatus = addLabel(rigGroup, @"A/B idle", NSZeroRect,
                                     [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightMedium],
                                     rigDimText(), NSTextAlignmentLeft);
    abStatus.translatesAutoresizingMaskIntoConstraints = NO;
    state->abStatusLabel = abStatus;
    abStatus.toolTip = @"Which A/B side is currently sounding while cycling.";
    [[abStatus.leadingAnchor constraintEqualToAnchor:abToggle.trailingAnchor constant:6] setActive:YES];
    [[abStatus.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[abStatus.trailingAnchor constraintLessThanOrEqualToAnchor:resetKnobsButton.leadingAnchor constant:-8] setActive:YES];
    [[abStatus.heightAnchor constraintEqualToConstant:24] setActive:YES];

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
    boxRow.translatesAutoresizingMaskIntoConstraints = NO;
    [rigPane addSubview:boxRow];
    [[boxRow.leadingAnchor constraintEqualToAnchor:rigPane.leadingAnchor constant:24] setActive:YES];
    [[boxRow.trailingAnchor constraintEqualToAnchor:rigPane.trailingAnchor constant:-24] setActive:YES];
    [[boxRow.topAnchor constraintEqualToAnchor:rigPane.topAnchor constant:12] setActive:YES];
    [[boxRow.heightAnchor constraintEqualToConstant:242] setActive:YES];

    // Stage tiles get widths proportional to their knob counts (4/6/6):
    // each knob column gets the same pixel width everywhere, so 64pt knobs
    // and 70pt value boxes fit identically in every tile. The pedal tile is
    // narrower, amp and cab wider — no squish, no oversized cab card.
    // NSStackView proportions: use explicit width ratios via constraints
    // after adding (FillProportionally can't be trusted with custom views).
    const CGFloat tileUnits[3] = {4.0, 6.0, 6.0};
    const CGFloat tileGap = 22.0;
    NSView* knobGroups[3] = {nil, nil, nil};
    RigPanel* tileBoxes[3] = {nil, nil, nil};

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

      // Equal-width cells tiled across the group. All knobs stay full-size
      // 64pt. Cell width must fit the 70pt value box, so each 6-knob group
      // gets 1/6 of its tile width; spacing only separates groups, never
      // cells — knobs can't drift together no matter how wide the window is.
      // The 4-knob pedal group keeps roomier cells for the same knob size.
      const CGFloat groupPad = 4.0;
      const CGFloat knobSide = 64.0;
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
          [[cell.leadingAnchor constraintEqualToAnchor:prev.trailingAnchor constant:0] setActive:YES];
          [[cell.widthAnchor constraintEqualToAnchor:prev.widthAnchor] setActive:YES];
        } else {
          [[cell.leadingAnchor constraintEqualToAnchor:group.leadingAnchor constant:groupPad] setActive:YES];
        }
        prev = cell;
        if (gi == groupCounts[g] - 1)
          [[cell.trailingAnchor constraintEqualToAnchor:group.trailingAnchor constant:-groupPad] setActive:YES];

        state->knobs[k] = addKnob(cell, (NSInteger)kRigKnobPorts[k], kRigKnobDefaults[k],
                                  mins[k], maxes[k],
                                  NSMakePoint(0, 0), state->uiController);
        NSSlider* knob = state->knobs[k];
        knob.toolTip = knobDescriptions[k];
        knob.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField* kname = addLabel(cell, knobNames[k], NSZeroRect,
                                      [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
                                      rigDimText(), NSTextAlignmentCenter);
        rigApplyTracking(kname, 1.1);
        kname.toolTip = knobDescriptions[k];
        kname.translatesAutoresizingMaskIntoConstraints = NO;
        centerX(kname, cell, 0);
        [[kname.topAnchor constraintEqualToAnchor:cell.topAnchor constant:2] setActive:YES];

        centerX(knob, cell, 0);
        [[knob.topAnchor constraintEqualToAnchor:kname.bottomAnchor constant:4] setActive:YES];
        [[knob.widthAnchor constraintEqualToConstant:knobSide] setActive:YES];
        [[knob.heightAnchor constraintEqualToConstant:knobSide] setActive:YES];

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
        [[kval.topAnchor constraintEqualToAnchor:knob.bottomAnchor constant:4] setActive:YES];
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

    addLowerStudioDeck(state, expansionSlot, mins, maxes, knobNames, knobDescriptions);
    state->selectDeckTab(0);

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
      // left of the ON button, four modes: None / True 2x / True 4x / True 8x.
      if (i < 2) {
        NSPopUpButton* so = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [so addItemsWithTitles:@[@"None", @"True 2x", @"True 4x", @"True 8x"]];
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
        [so selectItemAtIndex:3];        // default True 8x = TTL default
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
      // Keep model selectors vertically aligned across all 3 tiles.
      [[thumb.heightAnchor constraintEqualToConstant:(i == 0 ? 141 : 112)] setActive:YES];
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
        [[transformer.topAnchor constraintEqualToAnchor:thumb.bottomAnchor constant:8] setActive:YES];
        [[transformer.heightAnchor constraintEqualToConstant:23] setActive:YES];
        [transformer selectItemAtIndex:0];
        transformer.toolTip = transformer.selectedItem.toolTip;
        state->transformerPopup = transformer;
        modelAnchor = transformer;
      }

      // Legacy compatibility references (docked into Lower Studio Deck):
      // "ADVANCED AMP", "SPEAKER LOAD", "Speaker Dynamics / Impedance", "WIDTH / DELAY / REVERB"
      // state->effectsPopover, state->speakerPopover, state->ampAdvancedPopover

      // The dropdown is the tile's model control/display — always visible.
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
      if (i == 1)
        [[mp.topAnchor constraintEqualToAnchor:modelAnchor.bottomAnchor constant:6] setActive:YES];
      else
        [[mp.topAnchor constraintEqualToAnchor:thumb.bottomAnchor constant:8] setActive:YES];
      [[mp.heightAnchor constraintEqualToConstant:23] setActive:YES];

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
        [[mpB.topAnchor constraintEqualToAnchor:mp.bottomAnchor constant:6] setActive:YES];
        [[mpB.heightAnchor constraintEqualToConstant:23] setActive:YES];
        [[browseB.leadingAnchor constraintEqualToAnchor:mpB.trailingAnchor constant:4] setActive:YES];
        [[browseB.centerYAnchor constraintEqualToAnchor:mpB.centerYAnchor] setActive:YES];
        [[browseB.widthAnchor constraintEqualToConstant:26] setActive:YES];
        [[browseB.heightAnchor constraintEqualToConstant:23] setActive:YES];
        [[onB.leadingAnchor constraintEqualToAnchor:browseB.trailingAnchor constant:4] setActive:YES];
        [[onB.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16] setActive:YES];
        [[onB.centerYAnchor constraintEqualToAnchor:mpB.centerYAnchor] setActive:YES];
        [[onB.widthAnchor constraintEqualToConstant:60] setActive:YES];
        [[onB.heightAnchor constraintEqualToConstant:23] setActive:YES];
      }

      // Pin this tile's knob group exactly to the tile's footprint, with the
      // same 16pt interior inset the tile's own children use — knob columns
      // line up 1:1 with the columns implied by the tile width.
      NSView* grp = knobGroups[i];
      [[grp.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16] setActive:YES];
      [[grp.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16] setActive:YES];

      tileBoxes[i] = box;
      [boxRow addArrangedSubview:box];
      if (i > 0) {
        // Width proportional to knob count: pedal 4 units, amp/cab 6 each.
        // (boxRow has no distribution; these constraints set the ratios.)
        [[box.widthAnchor constraintEqualToAnchor:tileBoxes[0].widthAnchor
                                       multiplier:tileUnits[i] / tileUnits[0]] setActive:YES];
      }
      // Fixed 22pt gaps between tiles (NSStackView spacing is off without
      // a distribution, so use explicit inter-tile spacing constraints).
      if (i > 0) {
        [[box.leadingAnchor constraintEqualToAnchor:tileBoxes[i-1].trailingAnchor
                                           constant:tileGap] setActive:YES];
      }
      state->setStageThumb((size_t)i, nil, 0, nil);
    }
    // Pin the row ends so the proportional widths resolve against boxRow.
    [[tileBoxes[0].leadingAnchor constraintEqualToAnchor:boxRow.leadingAnchor] setActive:YES];
    [[tileBoxes[2].trailingAnchor constraintEqualToAnchor:boxRow.trailingAnchor] setActive:YES];

    for (size_t k = 0; k < kRigKnobCount; ++k) {
      if (!state->knobs[k] && state->deckKnobs[k]) state->knobs[k] = state->deckKnobs[k];
      if (!state->valueLabels[k] && state->deckValueLabels[k]) state->valueLabels[k] = state->deckValueLabels[k];
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
    state->refreshABMenus();
    state->updateABStatus();
    return state;
  }
}

void cleanup(LV2UI_Handle handle) {
  auto* state = static_cast<RigUIState*>(handle);
  if (state) {
    state->stopABTimer();   // invalidate the A/B timer before teardown (do not call stopAB() which queues UI rebuilds)
    if (state->uiController) {
      state->uiController.state = nullptr;
    }
  }
  [state->headerBar removeFromSuperview];
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
  else if (propertyId == state->outputDbURID)
    state->lastOutputDb = v;
  else
    return;
  if (propertyId == state->inputDbURID)
    state->updateInputDbDisplay();
  else if (propertyId == state->outputDbURID)
    state->updateOutputDbDisplay();
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
