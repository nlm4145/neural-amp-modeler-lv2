// RigUIState — the LV2 UI state struct (extracted verbatim from nam_rig_ui.mm).
#pragma once

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>

#include <lv2/atom/atom.h>
#include <lv2/atom/forge.h>
#include <lv2/atom/util.h>
#include <lv2/core/lv2.h>
#include <lv2/patch/patch.h>
#include <lv2/ui/ui.h>
#include <lv2/urid/urid.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>

#include "rig_knobs.h"
#include "rack_controls.h"
#include "oversample_modes.h"
#include "output_transformer.h"
#include "speaker_dynamics.h"
#import "rig_theme.h"
#import "rig_widgets.h"
#import "rig_presets.h"

@class NAMRigUIController;
@class ToneBrowserController;

@interface NSObject (NAMRigPresetShortcuts)
- (void)saveCurrentPreset:(id)sender;
- (void)savePresetAs:(id)sender;
- (void)prevPresetClicked:(id)sender;
- (void)nextPresetClicked:(id)sender;
@end

struct RigUIState {
  std::shared_ptr<bool> isAlive = std::make_shared<bool>(true);

  ~RigUIState() {
    if (isAlive) *isAlive = false;
    [transformerPopover close];
    stopKeyEventMonitor();
    stopABTimer();
  }

  LV2UI_Write_Function write = nullptr;
  LV2UI_Controller controller = nullptr;
  LV2_URID_Map* map = nullptr;
  LV2_Atom_Forge forge{};
  LV2_URID eventTransfer = 0;
  LV2_URID atomObject = 0;
  LV2_URID atomPath = 0;
  LV2_URID atomURID = 0;
  LV2_URID patchGet = 0;
  LV2_URID patchSet = 0;
  LV2_URID patchProperty = 0;
  LV2_URID patchValue = 0;
  std::array<LV2_URID, 4> pathURIDs{};
  LV2_URID atomFloat = 0;
  LV2_URID tunerNoteURID = 0;
  LV2_URID tunerCentsURID = 0;
  LV2_URID inputDbURID = 0;
  LV2_URID outputDbURID = 0;

  // Input level meter (title bar): dBFS readout + bar with peak-hold color.
  static constexpr CFAbsoluteTime kMeterUiIntervalSec = 0.5;
  __strong NSTextField* inDbLabel = nil;
  __strong NSView* inDbBar = nil;
  __strong NSLayoutConstraint* inDbBarWidth = nil;
  float lastInputDb = -120.0f;
  CFAbsoluteTime lastInputDbUiTime = 0.0;
  bool inputDbUpdatePending = false;

  // Output level meter: dBFS readout + bar with peak-hold color.
  __strong NSTextField* outDbLabel = nil;
  __strong NSView* outDbBar = nil;
  __strong NSLayoutConstraint* outDbBarWidth = nil;
  float lastOutputDb = -120.0f;
  CFAbsoluteTime lastOutputDbUiTime = 0.0;
  bool outputDbUpdatePending = false;

  // Mute on tune setting
  bool muteOnTune = true;
  float unmutedOutputLevel = 0.0f;
  __strong NSButton* muteOnTuneButton = nil;

  // Lower Studio Deck inside expansionSlot
  __strong NSView* deckContainer = nil;
  __strong NSArray<RigButton*>* deckTabButtons = nil;
  __strong NSArray<NSView*>* deckTabPanes = nil;
  NSInteger activeDeckTab = 0;

  // Deck knobs mirror the 37 DSP parameters:
  std::array<__strong NSSlider*, kRigKnobCount> deckKnobs{};
  std::array<__strong NSTextField*, kRigKnobCount> deckValueLabels{};
  std::array<bool, kRigKnobCount> deckKnobFieldEditing{};

  std::array<float, NAMRig::kRackCount> rackControls = NAMRig::kRackControlDefaults;
  std::array<__strong RigButton*, NAMRig::kRackCount> rackButtons{};

  // Live hardware visualizers for the studio deck:
  __strong NAMDelayTapVisualizer* delayVisualizer = nil;
  __strong NAMReverbDecayVisualizer* reverbVisualizer = nil;
  __strong NAMSpatialAcousticVisualizer* spatialVisualizer = nil;
  __strong NAMPowerStageVisualizer* powerVisualizer = nil;
  __strong NAMSculptVisualizer* sculptVisualizer = nil;
  __strong NAMTransformerVisualizer* transformerVisualizer = nil;
  std::array<__strong NSTextField*, 4> transformerSpecLabels{};
  int transformerProfile = NAMRig::OutputTransformer::kCaptured;
  NAMRig::TransformerAdjustments transformerAdjustments = NAMRig::kTransformerControlDefaults;
  __strong NSPopover* transformerPopover = nil;
  std::array<__strong NSSlider*, NAMRig::kTransformerControlCount> transformerSliders{};
  std::array<__strong NSTextField*, NAMRig::kTransformerControlCount> transformerFields{};
  std::array<bool, NAMRig::kTransformerControlCount> transformerFieldEditing{};
  __strong NAMSpeakerDynamicsVisualizer* speakerVisualizer = nil;
  __strong NAMCabConsoleVisualizer* cabConsoleVisualizer = nil;
  __strong RigButton* cab2PolarityButton = nil;
  bool cab2PolarityInverted = false;

  void selectDeckTab(NSInteger index) {
    const NSInteger prevTab = activeDeckTab;
    activeDeckTab = index;
    auto alive = this->isAlive;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!alive || !*alive) return;
      for (NSInteger i = 0; i < (NSInteger)deckTabButtons.count; ++i) {
        RigButton* b = deckTabButtons[(NSUInteger)i];
        b.state = (i == index) ? NSControlStateValueOn : NSControlStateValueOff;
        b.primary = (i == index);
        b.needsDisplay = YES;
      }
      for (NSInteger i = 0; i < (NSInteger)deckTabPanes.count; ++i) {
        NSView* pane = deckTabPanes[(NSUInteger)i];
        pane.hidden = (i != index);
      }
      if (index == 3) {
        // Switched to Tuner tab: activate tuner DSP
        sendControl(16, 1.0f);
        if (tunerButton) {
          tunerButton.state = NSControlStateValueOn;
          tunerButton.contentTintColor = rigText();
          if ([tunerButton respondsToSelector:@selector(setPrimary:)]) {
            ((RigButton*)tunerButton).primary = YES;
          }
          tunerButton.needsDisplay = YES;
        }
        if (tunerPanel) tunerPanel.hidden = NO;
        if (muteOnTune) {
          for (size_t k = 0; k < kRigKnobCount; ++k) {
            if (kRigKnobPorts[k] == 5) {
              NSSlider* outK = knobs[k] ?: deckKnobs[k];
              if (outK) unmutedOutputLevel = outK.floatValue;
              break;
            }
          }
          sendControl(5, -80.0f);
          updateControl(5, -80.0f);
        }
      } else if (prevTab == 3) {
        // Leaving Tuner tab: disable tuner DSP and restore output if muted
        sendControl(16, 0.0f);
        if (tunerButton) {
          tunerButton.state = NSControlStateValueOff;
          tunerButton.contentTintColor = rigDimText();
          if ([tunerButton respondsToSelector:@selector(setPrimary:)]) {
            ((RigButton*)tunerButton).primary = NO;
          }
          tunerButton.needsDisplay = YES;
        }
        if (tunerPanel) tunerPanel.hidden = YES;
        if (muteOnTune) {
          sendControl(5, unmutedOutputLevel);
          updateControl(5, unmutedOutputLevel);
        }
        if (tunerNoteLabel) {
          tunerNoteLabel.stringValue = @"—";
          tunerNoteLabel.textColor = rigText();
        }
        if (tunerCentsLabel) {
          tunerCentsLabel.stringValue = @"";
          tunerCentsLabel.textColor = rigDimText();
        }
        if (tunerNeedle) tunerNeedle.hidden = YES;
      }
    });
  }

  // Per-stage oversample mode dropdowns (ports 20/21: None / True 2x / True 4x / True 8x).
  __strong NSPopUpButton* stageOsPopup[2] = {nil, nil};  // pedal, amp
  __strong NSPopUpButton* irNormPopup = nil;
  __strong NSPopUpButton* transformerPopup = nil;  // amp output iron, port 30
  __strong NSPopover* ampAdvancedPopover = nil;
  __strong NSPopUpButton* speakerProfilePopup = nil;
  __strong NSPopUpButton* deckTransformerPopup = nil;
  __strong NSPopUpButton* deckSpeakerProfilePopup = nil;
  __strong NSPopover* speakerPopover = nil;
  __strong NSPopover* effectsPopover = nil;

  // Tuner UI: master toggle + readout elements in Pro Studio Deck tab 3.
  __strong NSButton* tunerButton = nil;
  __strong NSView* tunerPanel = nil;
  __strong NSTextField* tunerNoteLabel = nil;
  __strong NSTextField* tunerCentsLabel = nil;
  __strong NSImageView* tunerNeedle = nil;
  __strong NSLayoutConstraint* tunerNeedleLeading = nil;  // constant = pixel offset
  float lastTunerNote = -1.0f;
  float lastTunerCents = 0.0f;

  // Redraw the readout from lastTunerNote/lastTunerCents. Called on the main
  // thread from portEvent.
  void updateTunerDisplay() {
    auto alive = this->isAlive;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!alive || !*alive) return;
      if (activeDeckTab != 3) return;
      if (!tunerPanel || tunerPanel.hidden) return;
      if (tunerButton && tunerButton.state != NSControlStateValueOn) return;
      if (lastTunerNote < 0) {
        tunerNoteLabel.stringValue = @"—";
        tunerNoteLabel.textColor = rigText();
        tunerCentsLabel.stringValue = @"";
        tunerNeedle.hidden = YES;
        return;
      }
      static NSString* const kNames[] = {@"C", @"C#", @"D", @"D#", @"E", @"F",
                                         @"F#", @"G", @"G#", @"A", @"A#", @"B"};
      const int n = (int)(lastTunerNote + 0.5f);
      tunerNoteLabel.stringValue = [NSString stringWithFormat:@"%@%d",
                                    kNames[((n % 12) + 12) % 12], n / 12 - 1];
      const bool inTune = std::fabs(lastTunerCents) <= 5.0f;
      if (std::fabs(lastTunerCents) <= 2.0f) {
        tunerCentsLabel.stringValue = [NSString stringWithFormat:@"%+d¢  ● IN TUNE",
                                       (int)std::lround(lastTunerCents)];
      } else if (lastTunerCents > 2.0f) {
        tunerCentsLabel.stringValue = [NSString stringWithFormat:@"%+d¢ (SHARP)",
                                       (int)std::lround(lastTunerCents)];
      } else {
        tunerCentsLabel.stringValue = [NSString stringWithFormat:@"%+d¢ (FLAT)",
                                       (int)std::lround(lastTunerCents)];
      }
      tunerNoteLabel.textColor = inTune ? rigGreen() : rigText();
      tunerCentsLabel.textColor = inTune ? rigGreen() : (std::fabs(lastTunerCents) <= 15.0f ? rigOrange() : rigDimText());
      tunerNeedle.layer.backgroundColor = (inTune ? rigGreen() : rigOrange()).CGColor;
      tunerNeedle.hidden = NO;
      // Needle across ±50 cents: middle of the meter = in tune.
      NSView* meter = tunerNeedle.superview;
      const CGFloat needleW = tunerNeedle.bounds.size.width > 0 ? tunerNeedle.bounds.size.width : 6.0;
      const CGFloat w = meter.bounds.size.width - needleW;
      if (w > 0) {
        tunerNeedleLeading.constant = (lastTunerCents + 50.0f) / 100.0f * w;
      }
    });
  }

  void applyInputDbDisplayNow() {
    if (!inDbLabel) return;
    const float db = lastInputDb;
    const float clamped = db < -60.0f ? -60.0f : (db > 0.0f ? 0.0f : db);
    inDbLabel.stringValue = db <= -119.0f ? @"  —  dB"
        : [NSString stringWithFormat:@"%+.1f dB", db];
    const CGFloat frac = (clamped + 60.0f) / 60.0f;
    if (inDbBarWidth) inDbBarWidth.constant = 110.0 * frac;
    NSColor* fill = db > -1.0f ? [NSColor colorWithSRGBRed:0.92 green:0.26 blue:0.21 alpha:1.0]
                  : db > -6.0f  ? [NSColor colorWithSRGBRed:1.00 green:0.55 blue:0.25 alpha:1.0]
                                : rigAccent();
    if (inDbBar) inDbBar.layer.backgroundColor = fill.CGColor;
  }

  // Redraw the input meter from lastInputDb on a 500ms cadence.
  void updateInputDbDisplay() {
    auto alive = this->isAlive;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!alive || !*alive) return;
      const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
      const CFAbsoluteTime elapsed = now - lastInputDbUiTime;
      if (elapsed >= kMeterUiIntervalSec) {
        lastInputDbUiTime = now;
        applyInputDbDisplayNow();
      } else if (!inputDbUpdatePending) {
        inputDbUpdatePending = true;
        const double remain = std::max(0.05, kMeterUiIntervalSec - elapsed);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remain * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
          if (!alive || !*alive) return;
          inputDbUpdatePending = false;
          lastInputDbUiTime = CFAbsoluteTimeGetCurrent();
          applyInputDbDisplayNow();
        });
      }
    });
  }

  void applyOutputDbDisplayNow() {
    if (!outDbLabel) return;
    const float db = lastOutputDb;
    const float clamped = db < -60.0f ? -60.0f : (db > 0.0f ? 0.0f : db);
    outDbLabel.stringValue = db <= -119.0f ? @"  —  dB"
        : [NSString stringWithFormat:@"%+.1f dB", db];
    const CGFloat frac = (clamped + 60.0f) / 60.0f;
    if (outDbBarWidth) outDbBarWidth.constant = 110.0 * frac;
    NSColor* fill = db > -0.5f ? [NSColor colorWithSRGBRed:0.95 green:0.20 blue:0.18 alpha:1.0]
                  : db > -4.0f  ? [NSColor colorWithSRGBRed:1.00 green:0.60 blue:0.20 alpha:1.0]
                                : [NSColor colorWithSRGBRed:0.20 green:0.80 blue:0.95 alpha:1.0];
    if (outDbBar) outDbBar.layer.backgroundColor = fill.CGColor;
  }

  // Redraw the output meter from lastOutputDb on a 500ms cadence.
  void updateOutputDbDisplay() {
    auto alive = this->isAlive;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!alive || !*alive) return;
      const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
      const CFAbsoluteTime elapsed = now - lastOutputDbUiTime;
      if (elapsed >= kMeterUiIntervalSec) {
        lastOutputDbUiTime = now;
        applyOutputDbDisplayNow();
      } else if (!outputDbUpdatePending) {
        outputDbUpdatePending = true;
        const double remain = std::max(0.05, kMeterUiIntervalSec - elapsed);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remain * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
          if (!alive || !*alive) return;
          outputDbUpdatePending = false;
          lastOutputDbUiTime = CFAbsoluteTimeGetCurrent();
          applyOutputDbDisplayNow();
        });
      }
    });
  }

  __strong NSView* view = nil;
  __weak NSView* parent = nil;
  __strong NAMRigUIController* uiController = nil;
  __strong ToneBrowserController* browserController = nil;
  std::array<__strong NSTextField*, 4> pathLabels{};
  std::array<__strong NSButton*, 4> powerButtons{};
  std::array<__strong NSImageView*, 3> stageImages{};
  std::array<__strong NSTextField*, 3> stageHeaderArchBadges{};
  std::array<__strong NSTextField*, 4> stageArchBadges{};
  // auto-cab is always on — no toggle or status label needed
  std::array<__strong NSSlider*, kRigKnobCount> knobs{};
  std::array<__strong NSTextField*, kRigKnobCount> valueLabels{};
  // Editable knob value boxes: while the user is typing in one, host-driven
  // updates must not clobber that field (index = kRigKnobPorts index).
  std::array<bool, kRigKnobCount> knobFieldEditing{};
  std::array<__strong NSPopUpButton*, 4> modelPickers{};  // per-stage model selector in each tile
  LV2UI_Resize* hostResize = nullptr;
  CGFloat zoom = 1.0;
  NSComboBox* zoomControl = nil;
  __strong NSView* rigContent = nil;   // the Auto Layout container that fills the window

  // Tabbed panes: Rig (tab 0) and Tone3000 (tab 1).
  __strong NSView* headerBar = nil;
  __strong NSView* rigHeaderGroup = nil;
  __strong NSView* rigPane = nil;
  __strong NSView* tonePane = nil;
  __strong RigButton* rigTabBtn = nil;
  __strong RigButton* toneTabBtn = nil;
  NSInteger activeTab = 0;

  void selectTab(NSInteger tab) {
    activeTab = tab;
    auto alive = this->isAlive;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!alive || !*alive) return;
      if (rigTabBtn) {
        rigTabBtn.state = (tab == 0) ? NSControlStateValueOn : NSControlStateValueOff;
        rigTabBtn.needsDisplay = YES;
      }
      if (toneTabBtn) {
        toneTabBtn.state = (tab == 1) ? NSControlStateValueOn : NSControlStateValueOff;
        toneTabBtn.needsDisplay = YES;
      }
      if (rigHeaderGroup) rigHeaderGroup.hidden = (tab != 0);
      if (rigPane) rigPane.hidden = (tab != 0);
      if (tonePane) tonePane.hidden = (tab != 1);
    });
  }

  // Preset management: title bar dropdown, quick prev/next, and quick save.
  __strong NSPopUpButton* presetPopup = nil;
  __strong NSButton* prevPresetBtn = nil;
  __strong NSButton* nextPresetBtn = nil;
  __strong NSButton* savePresetBtn = nil;
  __strong RigPresetManager* presetManager = nil;

  // Hands-free A/B preset compare: alternates between the active preset (A =
  // whatever is in the main preset window) and a memorized B preset, driven
  // by a UI-side timer so the player can audition while playing (no clicks).
  // When the active preset is modified, B defaults to "<currentPreset> *" so
  // the user can immediately A/B the saved preset against their modified edits,
  // while still allowing any other saved preset to be chosen from Menu B.
  // NSTimer must be invalidated before teardown (cleanup() calls stopAB()).
  __strong NSPopUpButton* abPresetB = nil;
  __strong NSSlider* abIntervalSlider = nil;
  __strong NSTextField* abIntervalLabel = nil;
  __strong NSButton* abCycleBtn = nil;
  __strong NSTextField* abStatusLabel = nil;
  __strong NSTimer* abTimer = nil;
  __strong RigPreset* abModifiedPreset = nil;  // live snapshot of "<currentPresetName> *"
  NSString* abNameA = nil;   // snapshot of the active preset taken at START
  NSString* abNameB = nil;   // B slot memorized from the B dropdown
  double abIntervalSec = 4.0;
  bool abShowingA = true;
  bool abCycling = false;
  bool abUserChoseB = false;     // true only when the user manually selects a different preset in Menu B
  bool abApplyingCycle = false;  // suppresses markModified() while applying a preset or cycling A/B

  static NSString* abModifiedToken() {
    return @"__AB_MODIFIED__";
  }

  void captureModifiedABState() {
    if (!presetManager || abApplyingCycle) return;
    if (abCycling && abShowingA) return;
    NSString* cur = presetManager.currentPresetName ?: @"Default Rig";
    abModifiedPreset = [RigPreset captureFromState:this name:[cur stringByAppendingString:@" *"]];
  }

  void markModified() {
    if (!presetManager || abApplyingCycle) return;
    BOOL wasModified = presetManager.isModified;
    presetManager.isModified = YES;
    captureModifiedABState();
    BOOL missingModItem = abPresetB && ([abPresetB indexOfItemWithRepresentedObject:abModifiedToken()] < 0);
    if (!wasModified || missingModItem) {
      if (!wasModified) abUserChoseB = false;
      updatePresetDisplayTitle();
    } else if (!abUserChoseB && abPresetB) {
      NSString* cur = presetManager.currentPresetName ?: @"Default Rig";
      NSInteger idx = [abPresetB indexOfItemWithRepresentedObject:abModifiedToken()];
      if (idx >= 0) {
        [abPresetB itemAtIndex:idx].title = [cur stringByAppendingString:@" *"];
        if (abPresetB.indexOfSelectedItem != idx) {
          [abPresetB selectItemAtIndex:idx];
        }
        abNameB = abModifiedToken();
        updateABStatus();
      }
    }
  }

  void applyPresetByName(NSString* name) {
    if (!name.length || !presetManager || !uiController) return;
    abApplyingCycle = true;
    RigPreset* preset = [presetManager loadPresetNamed:name];
    if (preset) {
      [preset applyToState:this];
      updatePresetDisplayTitle();
    }
    abApplyingCycle = false;
  }

  // Cycle apply: loads the preset's DSP state WITHOUT touching
  // currentPresetName or the main preset window. This keeps A (main window)
  // and B (B dropdown) fixed while cycling, so they never collapse onto the
  // same value — only the status readout flips to show the sounding side.
  void abApplyCycle(NSString* name) {
    if (!name.length || !presetManager) return;
    abApplyingCycle = true;
    if ([name isEqualToString:abModifiedToken()]) {
      if (abModifiedPreset) [abModifiedPreset applyToState:this];
    } else {
      NSString* path = [[presetManager presetsDirectory]
          stringByAppendingPathComponent:
              [[name lastPathComponent] stringByAppendingPathExtension:@"json"]];
      RigPreset* preset = [RigPreset loadFromFile:path];
      if (preset) [preset applyToState:this];
    }
    abApplyingCycle = false;
  }

  // Drives the A/B cycle and the status readout. Runs on the main thread.
  void abTick() {
    if (!abCycling) return;
    abShowingA = !abShowingA;
    NSString* next = abShowingA ? abNameA : abNameB;
    abApplyCycle(next);
    updateABStatus();
  }

  static void applyABDropdownHighlight(NSPopUpButton* popup, bool highlighted) {
    if (!popup) return;
    popup.wantsLayer = YES;
    if (highlighted) {
      CIFilter* tint = [CIFilter filterWithName:@"CIColorMatrix"];
      if (tint) {
        [tint setDefaults];
        [tint setValue:[CIVector vectorWithX:1.0 Y:0.0 Z:0.0 W:0.0] forKey:@"inputRVector"];
        [tint setValue:[CIVector vectorWithX:0.0 Y:0.86 Z:0.0 W:0.0] forKey:@"inputGVector"];
        [tint setValue:[CIVector vectorWithX:0.0 Y:0.0 Z:0.22 W:0.0] forKey:@"inputBVector"];
        [tint setValue:[CIVector vectorWithX:0.0 Y:0.0 Z:0.0 W:1.0] forKey:@"inputAVector"];
        [tint setValue:[CIVector vectorWithX:0.0 Y:0.0 Z:0.0 W:0.0] forKey:@"inputBiasVector"];
        popup.contentFilters = @[tint];
      }
    } else if (popup.contentFilters.count > 0) {
      popup.contentFilters = @[];
    }
    [popup setNeedsDisplay:YES];
  }

  void updateABStatus() {
    applyABDropdownHighlight(presetPopup, abCycling && abShowingA);
    applyABDropdownHighlight(abPresetB, abCycling && !abShowingA);
    if (!abStatusLabel) return;
    NSString* showing = abShowingA ? @"A" : @"B";
    NSString* name = abShowingA ? abNameA : abNameB;
    if ([name isEqualToString:abModifiedToken()]) {
      NSString* cur = presetManager ? (presetManager.currentPresetName ?: @"Default Rig") : @"Default Rig";
      name = [cur stringByAppendingString:@" *"];
    }
    if (!name.length) name = @"—";
    abStatusLabel.stringValue = abCycling
        ? [NSString stringWithFormat:@"%@: %@", showing, name]
        : @"A/B idle";
  }

  void refreshABMenus() {
    if (!abPresetB || !presetManager) return;
    NSArray<NSString*>* names = presetManager.presetNames ?: @[];
    NSString* cur = presetManager.currentPresetName ?: @"Default Rig";
    NSString* keep = nil;
    if ([abPresetB.selectedItem.representedObject isKindOfClass:[NSString class]])
      keep = abPresetB.selectedItem.representedObject;
    if (!keep.length) keep = abNameB;
    [abPresetB removeAllItems];
    if (presetManager.isModified) {
      NSString* modTitle = [cur stringByAppendingString:@" *"];
      NSMenuItem* modItem = [[NSMenuItem alloc] initWithTitle:modTitle action:NULL keyEquivalent:@""];
      modItem.representedObject = abModifiedToken();
      [[abPresetB menu] addItem:modItem];
    }
    for (NSString* name in names) {
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:name action:NULL keyEquivalent:@""];
      item.representedObject = name;
      [[abPresetB menu] addItem:item];
    }
    NSInteger match = -1;
    if (presetManager.isModified && !abUserChoseB) {
      match = [abPresetB indexOfItemWithRepresentedObject:abModifiedToken()];
    } else if (keep.length) {
      match = [abPresetB indexOfItemWithRepresentedObject:keep];
    }
    if (match < 0 && names.count) {
      // Default B to something other than the active preset when possible.
      NSString* fallback = nil;
      for (NSString* name in names) {
        if (![name isEqualToString:cur]) { fallback = name; break; }
      }
      if (!fallback.length) fallback = names.firstObject;
      match = [abPresetB indexOfItemWithRepresentedObject:fallback];
      if (match < 0) match = 0;
    }
    if (match >= 0) [abPresetB selectItemAtIndex:match];
    if ([abPresetB.selectedItem.representedObject isKindOfClass:[NSString class]])
      abNameB = abPresetB.selectedItem.representedObject;
    updateABStatus();
  }

  // Snap A to the live active preset (called whenever the main preset
  // selection changes while idle, and after STOP restores A).
  void syncABNameA() {
    if (abCycling) return;
    NSString* cur = presetManager ? presetManager.currentPresetName : nil;
    if (cur.length) abNameA = cur;
    if (presetPopup) resyncPresetPopupSelection();
    updateABStatus();
  }

  void startAB() {
    if (presetManager) {
      if (presetManager.isModified && !abCycling) {
        captureModifiedABState();
      }
      BOOL wasModified = presetManager.isModified;
      [presetManager rescanPresets];
      presetManager.isModified = wasModified;
      refreshABMenus();
      // A is always the live active preset — snapshot it now.
      NSString* cur = presetManager.currentPresetName;
      if (cur.length) abNameA = cur;
    }
    if (!abNameA.length || !abNameB.length) return;
    if ([abNameA isEqualToString:abNameB]) return;  // nothing to compare
    stopABTimer();
    abCycling = true;
    abShowingA = false;  // first tick lands on A immediately
    if (abCycleBtn) {
      abCycleBtn.title = @"STOP";
      abCycleBtn.state = NSControlStateValueOn;
    }
    abTick();  // switch to A right away so START is responsive
    restartABTimer();
    updateABStatus();
  }

  void restartABTimer() {
    stopABTimer();
    const double interval = abIntervalSec < 0.25 ? 0.25 : abIntervalSec;
    abTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                              target:uiController
                                            selector:@selector(abTimerFired:)
                                            userInfo:nil
                                             repeats:YES];
  }

  __strong id keyEventMonitor = nil;

  void stopKeyEventMonitor() {
    if (keyEventMonitor) {
      [NSEvent removeMonitor:keyEventMonitor];
      keyEventMonitor = nil;
    }
  }

  void installKeyEventMonitor() {
    stopKeyEventMonitor();
    auto alive = this->isAlive;
    RigUIState* selfState = this;
    keyEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
        handler:^NSEvent* _Nullable(NSEvent* event) {
      if (!alive || !*alive || !selfState->view || !selfState->uiController) return event;
      NSWindow* win = selfState->view.window;
      NSWindow* editorWindow = selfState->transformerPopover.contentViewController.view.window;
      if (!win || selfState->view.isHiddenOrHasHiddenAncestor) return event;
      if (!win.isKeyWindow) {
        if (!editorWindow.isKeyWindow) return event;
        win = editorWindow;
      }
      if ([NSApp modalWindow] != nil) return event;

      NSEventModifierFlags mods = event.modifierFlags &
          (NSEventModifierFlagCommand | NSEventModifierFlagOption |
           NSEventModifierFlagControl | NSEventModifierFlagShift);
      NSString* chars = [event.charactersIgnoringModifiers lowercaseString] ?: @"";

      // Cmd+S saves the current preset (Cmd+Shift+S opens Save Preset As...)
      if (mods == NSEventModifierFlagCommand &&
          ([chars isEqualToString:@"s"] || event.keyCode == 1)) {
        if ([win.firstResponder isKindOfClass:[NSText class]]) {
          [win makeFirstResponder:nil];
        }
        [(id)selfState->uiController saveCurrentPreset:nil];
        return nil;
      }
      if (mods == (NSEventModifierFlagCommand | NSEventModifierFlagShift) &&
          ([chars isEqualToString:@"s"] || event.keyCode == 1)) {
        if ([win.firstResponder isKindOfClass:[NSText class]]) {
          [win makeFirstResponder:nil];
        }
        [(id)selfState->uiController savePresetAs:nil];
        return nil;
      }

      // Left / Right arrows move up / down in preset selection when not editing text
      if (mods == 0 && win == selfState->view.window) {
        BOOL isEditingText = [win.firstResponder isKindOfClass:[NSText class]];
        if (!isEditingText) {
          const unsigned short kc = event.keyCode;
          const unichar ch = chars.length > 0 ? [chars characterAtIndex:0] : 0;
          if (kc == 123 || ch == NSLeftArrowFunctionKey) {
            [(id)selfState->uiController prevPresetClicked:nil];
            return nil;
          }
          if (kc == 124 || ch == NSRightArrowFunctionKey) {
            [(id)selfState->uiController nextPresetClicked:nil];
            return nil;
          }
        }
      }
      return event;
    }];
  }

  void stopABTimer() {
    if (abTimer) {
      [abTimer invalidate];
      abTimer = nil;
    }
  }

  void stopAB() {
    stopABTimer();
    abCycling = false;
    if (abCycleBtn) {
      abCycleBtn.title = @"START";
      abCycleBtn.state = NSControlStateValueOff;
    }
    // If B is the modified state of the current preset, restore that modified
    // state on STOP so the user's unsaved tweaks remain active; otherwise
    // restore A while preserving any modified snapshot.
    if (presetManager && presetManager.isModified && abModifiedPreset &&
        [abNameB isEqualToString:abModifiedToken()]) {
      abApplyCycle(abModifiedToken());
      presetManager.isModified = YES;
    } else if (abNameA.length) {
      BOOL wasModified = presetManager ? presetManager.isModified : NO;
      abApplyCycle(abNameA);
      if (presetManager) presetManager.isModified = wasModified;
    }
    syncABNameA();
    updatePresetDisplayTitle();
  }

  void toggleAB() {
    if (abCycling) stopAB();
    else startAB();
  }

  void rebuildPresetMenu() {
    if (!presetPopup || !presetManager) return;
    [presetPopup removeAllItems];
    NSString* cur = presetManager.currentPresetName ?: @"Default Rig";
    NSInteger match = -1;
    NSInteger i = 0;
    for (NSString* name in presetManager.presetNames) {
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:name action:NULL keyEquivalent:@""];
      item.representedObject = name;
      [[presetPopup menu] addItem:item];
      if ([name isEqualToString:cur]) match = i;
      ++i;
    }

    [[presetPopup menu] addItem:[NSMenuItem separatorItem]];

    NSMenuItem* saveItem = [[NSMenuItem alloc] initWithTitle:@"Save Preset"
                                                      action:@selector(saveCurrentPreset:)
                                               keyEquivalent:@""];
    saveItem.target = (id)uiController;
    [[presetPopup menu] addItem:saveItem];

    NSMenuItem* saveAsItem = [[NSMenuItem alloc] initWithTitle:@"Save As…"
                                                        action:@selector(savePresetAs:)
                                                 keyEquivalent:@""];
    saveAsItem.target = (id)uiController;
    [[presetPopup menu] addItem:saveAsItem];

    NSMenuItem* deleteItem = [[NSMenuItem alloc] initWithTitle:@"Delete Preset"
                                                         action:@selector(deleteCurrentPreset:)
                                                  keyEquivalent:@""];
    deleteItem.target = (id)uiController;
    deleteItem.enabled = ![cur isEqualToString:@"Default Rig"];
    [[presetPopup menu] addItem:deleteItem];

    NSMenuItem* duplicateItem = [[NSMenuItem alloc] initWithTitle:@"Duplicate Preset"
                                                           action:@selector(duplicateCurrentPreset:)
                                                    keyEquivalent:@""];
    duplicateItem.target = (id)uiController;
    [[presetPopup menu] addItem:duplicateItem];

    [[presetPopup menu] addItem:[NSMenuItem separatorItem]];

    NSMenuItem* resetItem = [[NSMenuItem alloc] initWithTitle:@"Reset to Default"
                                                       action:@selector(resetAllKnobs:)
                                                keyEquivalent:@""];
    resetItem.target = (id)uiController;
    [[presetPopup menu] addItem:resetItem];

    [[presetPopup menu] addItem:[NSMenuItem separatorItem]];

    NSMenuItem* revealItem = [[NSMenuItem alloc] initWithTitle:@"Reveal in Finder"
                                                        action:@selector(revealPresetsInFinder:)
                                                 keyEquivalent:@""];
    revealItem.target = (id)uiController;
    [[presetPopup menu] addItem:revealItem];

    if (match >= 0) {
      [presetPopup selectItemAtIndex:match];
    }
    // Newly saved presets should appear in the A/B slots too.
    refreshABMenus();
  }

  void updatePresetDisplayTitle() {
    auto alive = this->isAlive;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!alive || !*alive) return;
      rebuildPresetMenu();
      updateABStatus();
    });
  }

  // Snap the popup back to the current preset without a full menu rebuild.
  // NSPopUpButton keeps whatever row was last picked as its selection — so
  // after a command row (Save / Save As / Delete / Duplicate / Reveal) is
  // chosen and its dialog is cancelled, the button would otherwise keep
  // showing "Delete Preset" etc. Call this synchronously on cancel/failure
  // paths; success paths use updatePresetDisplayTitle() (full rebuild).
  // Must run on the main thread (all preset actions do).
  void resyncPresetPopupSelection() {
    if (!presetPopup || !presetManager) return;
    auto alive = this->isAlive;
    auto resync = ^{
      if (!alive || !*alive) return;
      NSString* cur = presetManager.currentPresetName ?: @"Default Rig";
      NSInteger match = -1;
      NSArray<NSMenuItem*>* items = presetPopup.itemArray;
      for (NSInteger i = 0; i < (NSInteger)items.count; ++i) {
        id rep = items[(NSUInteger)i].representedObject;
        if ([rep isKindOfClass:[NSString class]] && [rep isEqualToString:cur]) {
          match = i;
          break;
        }
      }
      if (match >= 0) [presetPopup selectItemAtIndex:match];
    };
    if ([NSThread isMainThread]) {
      resync();
    } else {
      dispatch_async(dispatch_get_main_queue(), resync);
    }
  }

  // Studio Pro Deck per-slot preset dropdowns & user-saved slot presets.
  // Every rack slot in the Studio Pro Deck (and any future pane/slot) registers
  // a descriptor in deckSlotSpecs and renders a preset NSPopUpButton via
  // addSlotPresetDropdown() so users can pick factory presets or create, save,
  // overwrite, and delete their own presets for that specific module.
  __strong NSMutableArray<NSMutableDictionary*>* deckSlotSpecs = nil;
  __strong NSMutableDictionary<NSString*, NSMutableDictionary<NSString*, NSDictionary<NSString*, NSNumber*>*>*>* userSlotPresets = nil;

  static NSString* slotPresetsFilePath() {
    const char* home = std::getenv("HOME");
    NSString* dir = home
        ? [[NSString stringWithUTF8String:home] stringByAppendingPathComponent:@"Library/Application Support/Axe FX"]
        : @"./Axe FX";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [dir stringByAppendingPathComponent:@"slot-presets.json"];
  }

  void ensureSlotPresetStorage() {
    if (!deckSlotSpecs) deckSlotSpecs = [NSMutableArray array];
    if (userSlotPresets) return;
    userSlotPresets = [NSMutableDictionary dictionary];
    NSData* data = [NSData dataWithContentsOfFile:slotPresetsFilePath()];
    if (!data) return;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:[NSDictionary class]]) return;
    NSDictionary* rootDict = (NSDictionary*)root;
    for (id slotKey in rootDict) {
      if (![slotKey isKindOfClass:[NSString class]]) continue;
      id slotVal = rootDict[slotKey];
      if (![slotVal isKindOfClass:[NSDictionary class]]) continue;
      NSMutableDictionary* map = [NSMutableDictionary dictionary];
      for (id presetName in (NSDictionary*)slotVal) {
        if (![presetName isKindOfClass:[NSString class]]) continue;
        id presetVal = ((NSDictionary*)slotVal)[presetName];
        if ([presetVal isKindOfClass:[NSDictionary class]]) {
          map[presetName] = [presetVal copy];
        }
      }
      userSlotPresets[slotKey] = map;
    }
  }

  void saveUserSlotPresetsToDisk() {
    ensureSlotPresetStorage();
    NSData* data = [NSJSONSerialization dataWithJSONObject:userSlotPresets
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (data) {
      [data writeToFile:slotPresetsFilePath() atomically:YES];
    }
  }

  float currentPortValueForSlot(uint32_t port) const {
    if (port >= NAMRig::kRackControlFirstPort &&
        port < NAMRig::kRackControlFirstPort + NAMRig::kRackCount) {
      return rackControls[port - NAMRig::kRackControlFirstPort];
    }
    if (port == 30) {
      return (float)transformerProfile;
    }
    if (port >= NAMRig::kTransformerControlFirstPort &&
        port < NAMRig::kTransformerControlFirstPort + NAMRig::kTransformerControlCount) {
      return transformerAdjustments[port - NAMRig::kTransformerControlFirstPort];
    }
    if (port == 42) {
      NSPopUpButton* p = deckSpeakerProfilePopup ?: speakerProfilePopup;
      return p ? (float)p.indexOfSelectedItem : 0.0f;
    }
    if (port == 59) {
      return cab2PolarityInverted ? 1.0f : 0.0f;
    }
    for (size_t k = 0; k < kRigKnobCount; ++k) {
      if (kRigKnobPorts[k] == port) {
        NSSlider* knob = knobs[k] ?: deckKnobs[k];
        return knob ? knob.floatValue : kRigKnobDefaults[k];
      }
    }
    return 0.0f;
  }

  NSDictionary<NSString*, NSNumber*>* captureSlotPortValues(NSInteger slotIdx) {
    ensureSlotPresetStorage();
    if (slotIdx < 0 || slotIdx >= (NSInteger)deckSlotSpecs.count) return @{};
    NSDictionary* spec = deckSlotSpecs[(NSUInteger)slotIdx];
    NSArray<NSNumber*>* ports = spec[@"ports"];
    NSMutableDictionary<NSString*, NSNumber*>* out = [NSMutableDictionary dictionaryWithCapacity:ports.count];
    for (NSNumber* pNum in ports) {
      const uint32_t port = pNum.unsignedIntValue;
      out[[pNum stringValue]] = @(currentPortValueForSlot(port));
    }
    return out;
  }

  void rebuildSlotPresetMenu(NSInteger slotIdx) {
    ensureSlotPresetStorage();
    if (slotIdx < 0 || slotIdx >= (NSInteger)deckSlotSpecs.count) return;
    NSMutableDictionary* spec = deckSlotSpecs[(NSUInteger)slotIdx];
    NSPopUpButton* popup = spec[@"popup"];
    if (!popup) return;

    NSString* slotKey = spec[@"key"] ?: @"";
    NSArray<NSString*>* factoryTitles = spec[@"factoryTitles"] ?: @[];
    NSString* selectedTitle = spec[@"selectedTitle"] ?: (factoryTitles.firstObject ?: @"");
    BOOL selectedIsUser = [spec[@"selectedIsUser"] boolValue];

    popup.menu.autoenablesItems = NO;
    [popup removeAllItems];
    NSInteger matchIndex = -1;
    NSInteger itemIdx = 0;

    for (NSUInteger f = 0; f < factoryTitles.count; ++f) {
      NSString* fTitle = factoryTitles[f];
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:fTitle action:NULL keyEquivalent:@""];
      item.representedObject = @{
        @"type": @"factory",
        @"slot": @(slotIdx),
        @"index": @((NSInteger)f),
        @"title": fTitle
      };
      [[popup menu] addItem:item];
      if (!selectedIsUser && [fTitle isEqualToString:selectedTitle]) {
        matchIndex = itemIdx;
      }
      ++itemIdx;
    }

    NSDictionary<NSString*, NSDictionary<NSString*, NSNumber*>*>* userMap = userSlotPresets[slotKey];
    if (userMap.count > 0) {
      [[popup menu] addItem:[NSMenuItem separatorItem]];
      ++itemIdx;
      NSArray<NSString*>* sortedNames = [[userMap allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
      for (NSString* uName in sortedNames) {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:uName action:NULL keyEquivalent:@""];
        item.representedObject = @{
          @"type": @"user",
          @"slot": @(slotIdx),
          @"title": uName,
          @"values": userMap[uName] ?: @{}
        };
        [[popup menu] addItem:item];
        if (selectedIsUser && [uName isEqualToString:selectedTitle]) {
          matchIndex = itemIdx;
        }
        ++itemIdx;
      }
    }

    [[popup menu] addItem:[NSMenuItem separatorItem]];

    NSMenuItem* saveItem = [[NSMenuItem alloc] initWithTitle:@"Save Preset"
                                                      action:@selector(saveSlotPreset:)
                                               keyEquivalent:@""];
    saveItem.target = (id)uiController;
    saveItem.tag = slotIdx;
    [[popup menu] addItem:saveItem];

    NSMenuItem* saveAsItem = [[NSMenuItem alloc] initWithTitle:@"Save Preset As…"
                                                        action:@selector(saveSlotPresetAs:)
                                                 keyEquivalent:@""];
    saveAsItem.target = (id)uiController;
    saveAsItem.tag = slotIdx;
    [[popup menu] addItem:saveAsItem];

    NSMenuItem* deleteItem = [[NSMenuItem alloc] initWithTitle:@"Delete Preset"
                                                        action:@selector(deleteSlotPreset:)
                                                 keyEquivalent:@""];
    deleteItem.target = (id)uiController;
    deleteItem.tag = slotIdx;
    deleteItem.enabled = selectedIsUser;
    [[popup menu] addItem:deleteItem];

    if (matchIndex >= 0) {
      [popup selectItemAtIndex:matchIndex];
    } else if (popup.numberOfItems > 0) {
      [popup selectItemAtIndex:0];
      spec[@"selectedTitle"] = factoryTitles.firstObject ?: @"";
      spec[@"selectedIsUser"] = @NO;
    }
  }

  void resyncSlotPresetPopup(NSInteger slotIdx) {
    auto alive = this->isAlive;
    auto resync = ^{
      if (!alive || !*alive) return;
      rebuildSlotPresetMenu(slotIdx);
    };
    if ([NSThread isMainThread]) {
      resync();
    } else {
      dispatch_async(dispatch_get_main_queue(), resync);
    }
  }

  // UI-side persistence: the UI is the single source of truth for the selected
  // model paths (every selection is sent via sendPath). We write them to disk on
  // change and re-send them on every instantiate, so selections survive a
  // plugin-window recreation regardless of the host's LV2-State handling.
  std::array<std::string, 4> selectedPaths{};
  std::array<std::string, 4> selectedImageURLs{};   // thumbnail metadata (persisted)
  std::array<long, 4> selectedToneIds{};            // key into NAM Rig's artwork cache
  // Every model offered by the selected tone/pack.  Hosts such as Element may
  // tear down and recreate an LV2 UI when its window loses focus; keeping only
  // selectedPaths would then rebuild each popup with just its current item.
  std::array<std::vector<std::string>, 4> availableModelPaths{};
  static std::string uiLegacyPersistFile() {
    const char* home = std::getenv("HOME");
    std::string dir = home ? std::string(home) : std::string(".");
    return dir + "/Library/Application Support/NAM Oversampled Rig/rig-model-paths.txt";
  }
  static std::string uiPersistFile() {
    const char* home = std::getenv("HOME");
    std::string dir = home ? std::string(home) : std::string(".");
    dir += "/Library/Application Support/Axe FX";
    ::mkdir(dir.c_str(), 0755);
    return dir + "/rig-model-paths.txt";
  }
  void persistSelectedPaths() {
    const std::string file = uiPersistFile();
    std::ofstream out(file, std::ios::trunc);
    if (!out) return;
    for (size_t i = 0; i < selectedPaths.size(); ++i)
      out << selectedPaths[i] << "\n"
          << selectedImageURLs[i] << "\n"
          << selectedToneIds[i] << "\n";
  }
  static std::string uiStageModelsFile(size_t stage) {
    return uiPersistFile() + ".stage-" + std::to_string(stage) + "-models";
  }
  void persistStageModels(size_t stage) {
    if (stage >= availableModelPaths.size()) return;
    std::ofstream out(uiStageModelsFile(stage), std::ios::trunc);
    if (!out) return;
    for (const std::string& path : availableModelPaths[stage])
      if (!path.empty()) out << path << "\n";
  }
  void rememberAvailablePath(size_t stage, const char* path) {
    if (stage >= availableModelPaths.size() || !path || !path[0]) return;
    const std::string copy(path);
    auto& paths = availableModelPaths[stage];
    if (std::find(paths.begin(), paths.end(), copy) != paths.end()) return;
    paths.push_back(copy);
    persistStageModels(stage);
  }
  void restoreStageModels() {
    for (size_t stage = 0; stage < availableModelPaths.size(); ++stage) {
      std::ifstream in(uiStageModelsFile(stage));
      if (!in) {
        const std::string legacy = uiLegacyPersistFile() + ".stage-" +
                                   std::to_string(stage) + "-models";
        in.open(legacy);
      }
      if (!in) continue;  // Backward-compatible with the old selection-only file.
      NSMutableArray<NSString*>* paths = [NSMutableArray array];
      std::string path;
      while (std::getline(in, path)) {
        path.erase(path.find_last_not_of("\r\n") + 1);
        if (!path.empty()) [paths addObject:[NSString stringWithUTF8String:path.c_str()]];
      }
      setStageModels(stage, paths);
    }
  }
  // Re-send any previously selected model paths (and re-apply thumbnails) so the
  // rig comes back after a plugin-window/instance recreation.
  void restoreSelectedPaths() {
    // Restore each popup's complete choice set before selecting/echoing its
    // current path.  This order is important: displayPath must never have to
    // synthesize a one-item popup during UI recreation.
    restoreStageModels();
    const std::string file = uiPersistFile();
    std::ifstream in(file);
    bool migrated = false;
    if (!in) {
      in.open(uiLegacyPersistFile());
      migrated = static_cast<bool>(in);
    }
    if (!in) return;
    for (size_t i = 0; i < selectedPaths.size(); ++i) {
      std::string path, imageURL, toneIdStr;
      if (!std::getline(in, path)) break;
      std::getline(in, imageURL);
      std::getline(in, toneIdStr);
      path.erase(path.find_last_not_of("\r\n") + 1);
      imageURL.erase(imageURL.find_last_not_of("\r\n") + 1);
      toneIdStr.erase(toneIdStr.find_last_not_of("\r\n") + 1);
      long toneId = toneIdStr.empty() ? 0 : std::atol(toneIdStr.c_str());
      selectedPaths[i] = path;
      selectedImageURLs[i] = imageURL;
      selectedToneIds[i] = toneId;
      if (!path.empty()) sendPath(i, path.c_str());
      else displayPath(i, "");
      if (imageURL.length() || toneId > 0)
        setStageThumb(i, nil, toneId, imageURL.length() ? [NSString stringWithUTF8String:imageURL.c_str()] : nil);
    }
    if (migrated) persistSelectedPaths();
  }
  void sendPath(size_t stage, const char* path) {
    if (stage >= pathURIDs.size() || !path) return;
    // Remember + persist the selection so it survives a UI/instance recreation.
    rememberAvailablePath(stage, path);
    selectedPaths[stage] = path;
    if (path[0] == '\0') { selectedImageURLs[stage].clear(); selectedToneIds[stage] = 0; }  // clearing a model clears its thumb
    persistSelectedPaths();
    const size_t length = std::strlen(path) + 1;
    std::vector<uint8_t> buffer(length + 256);
    lv2_atom_forge_set_buffer(&forge, buffer.data(), buffer.size());
    LV2_Atom_Forge_Frame frame{};
    auto* message = reinterpret_cast<LV2_Atom*>(lv2_atom_forge_object(&forge, &frame, 0, patchSet));
    if (!message) return;
    lv2_atom_forge_key(&forge, patchProperty);
    lv2_atom_forge_urid(&forge, pathURIDs[stage]);
    lv2_atom_forge_key(&forge, patchValue);
    lv2_atom_forge_path(&forge, path, static_cast<uint32_t>(length));
    lv2_atom_forge_pop(&forge, &frame);
    write(controller, 0, lv2_atom_total_size(message), eventTransfer, message);
    displayPath(stage, path);
  }
  // Zoom scales the WHOLE UI as one unit with a pure layer transform: rigContent
  // is laid out once at base (1280x520) and pinned there, and we scale its layer
  // by `zoom` anchored top-left. Every child — Auto-Layout tiles, the fixed-frame
  // knobs, dropdowns, tone cards, text, images — renders scaled proportionally,
  // because they all live inside rigContent's layer and are never re-laid out at
  // the zoomed size. `state->view` (the widget Element hosts) and ui_resize are
  // sized to base*zoom so the window matches the scaled content.
  void applyZoom() {
    const CGFloat baseW = 1520.0, baseH = 980.0;
    const CGFloat z = zoom;
    NSView* container = rigContent ? rigContent : view;
    container.layer.anchorPoint = CGPointMake(0, 0);
    container.layer.affineTransform = CGAffineTransformMakeScale(z, z);
    [container setFrame:NSMakeRect(0, 0, baseW, baseH)];   // pin layout at base
    [container setNeedsDisplay:YES];
    [view setFrameSize:NSMakeSize(baseW * z, baseH * z)];
    [view setNeedsLayout:YES];
    if (hostResize && hostResize->ui_resize)
      hostResize->ui_resize(hostResize->handle, baseW * z, baseH * z);
  }

  void sendGet() {
    std::vector<uint8_t> buffer(256);
    lv2_atom_forge_set_buffer(&forge, buffer.data(), buffer.size());
    LV2_Atom_Forge_Frame frame{};
    auto* message = reinterpret_cast<LV2_Atom*>(lv2_atom_forge_object(&forge, &frame, 0, patchGet));
    if (!message) return;
    lv2_atom_forge_pop(&forge, &frame);
    write(controller, 0, lv2_atom_total_size(message), eventTransfer, message);
  }

  void sendControl(uint32_t port, float value) {
    write(controller, port, sizeof(value), 0, &value);
  }

  struct RigModelArchInfo {
    NSString* badgeText;      // e.g. @"A2 · WAVENET", @"A1 · WAVENET", @"CUSTOM · WAVENET", @"CUSTOM · LSTM", @"WAV IR"
    NSString* menuTag;        // e.g. @"[A2 · WaveNet]", @"[A1 · WaveNet]", @"[Custom · WaveNet]", @"[WAV IR]"
    NSString* detailSummary;  // e.g. @"A2 Standard · Slimmable WaveNet (48 kHz)"
    NSString* category;       // @"a2", @"a1", @"custom", @"ir", @"none"
  };

  static RigModelArchInfo inspectModelArch(NSString* path) {
    if (!path.length) {
      return {@"NO MODEL", @"", @"No model loaded", @"none"};
    }
    NSString* ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"wav"] || [ext isEqualToString:@"wave"] ||
        [ext isEqualToString:@"aif"] || [ext isEqualToString:@"aiff"] ||
        [ext isEqualToString:@"flac"]) {
      return {@"WAV IR", @"[WAV IR]", @"WAV Impulse Response", @"ir"};
    }

    static NSMutableDictionary<NSString*, NSDictionary*>* sArchCache = nil;
    static NSMutableDictionary<NSString*, NSDictionary*>* sManifestCache = nil;
    if (!sArchCache) sArchCache = [NSMutableDictionary dictionary];
    if (!sManifestCache) sManifestCache = [NSMutableDictionary dictionary];

    NSFileManager* fm = [NSFileManager defaultManager];
    BOOL exists = [fm fileExistsAtPath:path];
    unsigned long long fileSize = 0;
    if (exists) {
      NSDictionary* attr = [fm attributesOfItemAtPath:path error:nil];
      fileSize = [attr fileSize];
    }
    NSString* cacheKey = [NSString stringWithFormat:@"%@|%llu", path, fileSize];
    NSDictionary* cached = exists && fileSize > 0 ? sArchCache[cacheKey] : nil;
    if (cached) {
      return {cached[@"badge"], cached[@"menu"], cached[@"detail"], cached[@"cat"]};
    }

    // Check sibling _tone3000.json metadata first (relays architecture_version even before download finishes).
    NSString* t3kArchVer = nil;
    NSString* folder = [path stringByDeletingLastPathComponent];
    NSString* manifestPath = [folder stringByAppendingPathComponent:@"_tone3000.json"];
    if ([fm fileExistsAtPath:manifestPath]) {
      NSDictionary* mAttr = [fm attributesOfItemAtPath:manifestPath error:nil];
      NSString* mKey = [NSString stringWithFormat:@"%@|%llu", manifestPath, [mAttr fileSize]];
      NSDictionary* manifest = sManifestCache[mKey];
      if (!manifest) {
        NSData* mData = [NSData dataWithContentsOfFile:manifestPath];
        if (mData) {
          id obj = [NSJSONSerialization JSONObjectWithData:mData options:0 error:nil];
          if ([obj isKindOfClass:NSDictionary.class]) {
            manifest = obj;
            sManifestCache[mKey] = manifest;
          }
        }
      }
      NSArray* downloads = [manifest[@"downloads"] isKindOfClass:NSArray.class] ? manifest[@"downloads"] : nil;
      NSString* fileBase = path.lastPathComponent;
      NSString* stem = [fileBase stringByDeletingPathExtension];
      for (NSDictionary* dl in downloads) {
        if (![dl isKindOfClass:NSDictionary.class]) continue;
        NSString* localFn = [dl[@"local_filename"] isKindOfClass:NSString.class] ? dl[@"local_filename"] : @"";
        NSDictionary* orig = [dl[@"original_model"] isKindOfClass:NSDictionary.class] ? dl[@"original_model"] : nil;
        NSString* origName = [orig[@"name"] isKindOfClass:NSString.class] ? orig[@"name"] : @"";
        if ([localFn isEqualToString:fileBase] || (origName.length && [stem hasSuffix:origName])) {
          id av = orig[@"architecture_version"];
          if ([av isKindOfClass:NSString.class]) t3kArchVer = [(NSString*)av lowercaseString];
          else if ([av respondsToSelector:@selector(stringValue)]) t3kArchVer = [[av stringValue] lowercaseString];
          break;
        }
      }
    }

    RigModelArchInfo result = {@"NAM MODEL", @"[NAM]", @"NAM Neural Model", @"a2"};
    if ([t3kArchVer isEqualToString:@"2"]) {
      result = {@"A2 · WAVENET", @"[A2 · WaveNet]", @"A2 Standard · WaveNet", @"a2"};
    } else if ([t3kArchVer isEqualToString:@"1"]) {
      result = {@"A1 · WAVENET", @"[A1 · WaveNet]", @"A1 Legacy · WaveNet", @"a1"};
    } else if ([t3kArchVer isEqualToString:@"custom"]) {
      result = {@"CUSTOM · NAM", @"[Custom]", @"Custom Architecture", @"custom"};
    }

    if (exists && fileSize > 0 && fileSize < 25 * 1024 * 1024) {
      NSData* data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
      NSDictionary* json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
      if ([json isKindOfClass:NSDictionary.class]) {
        NSString* arch = [json[@"architecture"] isKindOfClass:NSString.class] ? json[@"architecture"] : nil;
        NSString* version = [json[@"version"] isKindOfClass:NSString.class] ? json[@"version"] : @"";
        NSDictionary* config = [json[@"config"] isKindOfClass:NSDictionary.class] ? json[@"config"] : nil;
        int sr = [json[@"sample_rate"] respondsToSelector:@selector(intValue)] ? [json[@"sample_rate"] intValue] : 48000;
        if (sr <= 0) sr = 48000;
        int srKhz = sr / 1000;

        if ([arch isEqualToString:@"SlimmableContainer"]) {
          result = {
            @"A2 · WAVENET",
            @"[A2 · WaveNet]",
            [NSString stringWithFormat:@"A2 Standard · Slimmable WaveNet (3ch/8ch · %d kHz)", srKhz],
            @"a2"
          };
        } else if ([arch isEqualToString:@"WaveNet"]) {
          NSArray* layers = [config[@"layers"] isKindOfClass:NSArray.class] ? config[@"layers"] : @[];
          NSDictionary* l0 = layers.count > 0 && [layers[0] isKindOfClass:NSDictionary.class] ? layers[0] : nil;
          NSDictionary* l1 = layers.count > 1 && [layers[1] isKindOfClass:NSDictionary.class] ? layers[1] : nil;
          int ch0 = [l0[@"channels"] respondsToSelector:@selector(intValue)] ? [l0[@"channels"] intValue] : 0;
          int ch1 = [l1[@"channels"] respondsToSelector:@selector(intValue)] ? [l1[@"channels"] intValue] : 0;
          NSUInteger dil0 = [l0[@"dilations"] isKindOfClass:NSArray.class] ? [l0[@"dilations"] count] : 0;
          bool gated = [l0[@"gated"] boolValue] || [l1[@"gated"] boolValue];

          bool isA2 = [t3kArchVer isEqualToString:@"2"] || (layers.count == 1 && dil0 == 23);
          bool isExplicitCustom = [t3kArchVer isEqualToString:@"custom"];
          bool isA1Official = !isExplicitCustom && layers.count == 2 && !gated && (dil0 == 10 || dil0 == 7) &&
                              ((ch0 == 16 && ch1 == 8) || (ch0 == 12 && ch1 == 6) || (ch0 == 6 && ch1 == 3) ||
                               (ch0 == 8 && ch1 == 4) || (ch0 == 4 && ch1 == 2) || (ch0 == 2 && ch1 == 1));
          if (isA2) {
            if (ch0 == 3) {
              result = {
                @"A2 LITE · WAVENET",
                @"[A2 Lite · WaveNet]",
                [NSString stringWithFormat:@"A2 Lite · WaveNet (1L · 3ch · %d kHz)", srKhz],
                @"a2"
              };
            } else {
              result = {
                @"A2 · WAVENET",
                @"[A2 · WaveNet]",
                [NSString stringWithFormat:@"A2 Standard · WaveNet (1L · %dch · %d kHz)", ch0 > 0 ? ch0 : 8, srKhz],
                @"a2"
              };
            }
          } else if (isA1Official || [t3kArchVer isEqualToString:@"1"]) {
            NSString* sub = @"Standard";
            NSString* badge = @"A1 · WAVENET";
            NSString* tag = @"[A1 · WaveNet]";
            if ((ch0 == 12 && ch1 == 6) || (ch0 == 6 && ch1 == 3)) {
              sub = @"Lite"; badge = @"A1 LITE · WAVENET"; tag = @"[A1 Lite · WaveNet]";
            } else if (ch0 == 8 && ch1 == 4) {
              sub = @"Feather"; badge = @"A1 FEATHER · WAVENET"; tag = @"[A1 Feather · WaveNet]";
            } else if ((ch0 == 4 && ch1 == 2) || (ch0 == 2 && ch1 == 1)) {
              sub = @"Nano"; badge = @"A1 NANO · WAVENET"; tag = @"[A1 Nano · WaveNet]";
            }
            result = {
              badge,
              tag,
              [NSString stringWithFormat:@"A1 %@ · WaveNet (%luL · %d→%dch · %d kHz)",
               sub, (unsigned long)layers.count, ch0, ch1, srKhz],
              @"a1"
            };
          } else {
            NSString* chSummary = ch0 > 0 ? [NSString stringWithFormat:@"%dch", ch0] : @"custom";
            if (layers.count == 2 && ch0 > 0 && ch1 > 0 && ch0 != ch1) {
              chSummary = [NSString stringWithFormat:@"%d→%dch", ch0, ch1];
            }
            result = {
              @"CUSTOM · WAVENET",
              @"[Custom · WaveNet]",
              [NSString stringWithFormat:@"Custom · WaveNet (%luL · %@ · %d kHz)",
               (unsigned long)layers.count, chSummary, srKhz],
              @"custom"
            };
          }
        } else if ([arch isEqualToString:@"LSTM"]) {
          int numLayers = [config[@"num_layers"] respondsToSelector:@selector(intValue)] ? [config[@"num_layers"] intValue] : 0;
          int hiddenSize = [config[@"hidden_size"] respondsToSelector:@selector(intValue)] ? [config[@"hidden_size"] intValue] : 0;
          NSString* badge = (numLayers > 0 && hiddenSize > 0)
              ? [NSString stringWithFormat:@"CUSTOM · LSTM %d×%d", numLayers, hiddenSize]
              : @"CUSTOM · LSTM";
          NSString* tag = (numLayers > 0 && hiddenSize > 0)
              ? [NSString stringWithFormat:@"[Custom · LSTM %d×%d]", numLayers, hiddenSize]
              : @"[Custom · LSTM]";
          result = {
            badge,
            tag,
            [NSString stringWithFormat:@"Custom · LSTM (%d layer%@ × %d hidden · %d kHz)",
             numLayers, numLayers == 1 ? @"" : @"s", hiddenSize, srKhz],
            @"custom"
          };
        } else if ([arch isEqualToString:@"ConvNet"]) {
          result = {@"CUSTOM · CONVNET", @"[Custom · ConvNet]",
                    [NSString stringWithFormat:@"Custom · ConvNet (%d kHz)", srKhz], @"custom"};
        } else if ([arch isEqualToString:@"Linear"]) {
          result = {@"LINEAR · NAM", @"[Linear]",
                    [NSString stringWithFormat:@"Linear NAM Model (%d kHz)", srKhz], @"custom"};
        } else if (arch.length) {
          result = {
            [NSString stringWithFormat:@"CUSTOM · %@", arch.uppercaseString],
            [NSString stringWithFormat:@"[Custom · %@]", arch],
            [NSString stringWithFormat:@"Custom · %@ (%@ · %d kHz)", arch, version.length ? version : @"NAM", srKhz],
            @"custom"
          };
        } else if ([json[@"layers"] isKindOfClass:NSArray.class] && [json[@"layers"] count] > 0) {
          NSDictionary* firstLayer = [json[@"layers"][0] isKindOfClass:NSDictionary.class] ? json[@"layers"][0] : nil;
          NSString* ltype = [firstLayer[@"type"] isKindOfClass:NSString.class] ? [firstLayer[@"type"] uppercaseString] : @"RNN";
          result = {
            [NSString stringWithFormat:@"AIDA-X · %@", ltype],
            [NSString stringWithFormat:@"[AIDA-X · %@]", ltype],
            [NSString stringWithFormat:@"AIDA-X / RTNeural (%@)", ltype],
            @"custom"
          };
        }
        sArchCache[cacheKey] = @{
          @"badge": result.badgeText ?: @"NAM",
          @"menu": result.menuTag ?: @"[NAM]",
          @"detail": result.detailSummary ?: @"NAM Model",
          @"cat": result.category ?: @"a2"
        };
      }
    }
    return result;
  }

  static NSString* cleanModelDisplayName(NSString* path) {
    if (!path.length) return @"—";
    NSString* fn = path.lastPathComponent;
    // Strip legacy "preview_<toneId>_<modelId>_" prefix if present.
    if ([fn hasPrefix:@"preview_"]) {
      NSArray<NSString*>* parts = [fn componentsSeparatedByString:@"_"];
      if (parts.count >= 4) {
        NSRange first = [fn rangeOfString:@"_"];
        NSRange second = [fn rangeOfString:@"_" options:0 range:NSMakeRange(NSMaxRange(first), fn.length - NSMaxRange(first))];
        if (second.location != NSNotFound) {
          NSRange third = [fn rangeOfString:@"_" options:0 range:NSMakeRange(NSMaxRange(second), fn.length - NSMaxRange(second))];
          if (third.location != NSNotFound && NSMaxRange(third) < fn.length) {
            fn = [fn substringFromIndex:NSMaxRange(third)];
          }
        }
      }
    }
    return fn;
  }

  static NSString* formattedModelMenuTitle(NSString* path) {
    if (!path.length) return @"—";
    return cleanModelDisplayName(path);
  }

  static void applyArchBadgeStyle(NSTextField* badge, const RigModelArchInfo& info, NSString* prefix = nil) {
    if (!badge) return;
    if ([info.category isEqualToString:@"none"]) {
      badge.stringValue = prefix.length ? [NSString stringWithFormat:@"%@ · —", prefix] : @"—";
      badge.textColor = rigDimText();
      badge.layer.backgroundColor = [NSColor colorWithSRGBRed:0.14 green:0.15 blue:0.18 alpha:0.78].CGColor;
      badge.layer.borderColor = [NSColor colorWithSRGBRed:0.32 green:0.35 blue:0.42 alpha:0.45].CGColor;
      badge.toolTip = @"No model loaded for this stage.";
      return;
    }
    NSString* label = prefix.length
        ? [NSString stringWithFormat:@"%@: %@", prefix, info.badgeText]
        : info.badgeText;
    badge.stringValue = [NSString stringWithFormat:@"  %@  ", label];
    badge.toolTip = [NSString stringWithFormat:@"Underlying Architecture: %@", info.detailSummary];
    if ([info.category isEqualToString:@"a2"]) {
      badge.textColor = [NSColor colorWithSRGBRed:0.38 green:0.86 blue:1.00 alpha:1.0];
      badge.layer.backgroundColor = [NSColor colorWithSRGBRed:0.06 green:0.20 blue:0.30 alpha:0.90].CGColor;
      badge.layer.borderColor = [NSColor colorWithSRGBRed:0.25 green:0.78 blue:0.98 alpha:0.72].CGColor;
    } else if ([info.category isEqualToString:@"a1"]) {
      badge.textColor = [NSColor colorWithSRGBRed:0.42 green:0.94 blue:0.78 alpha:1.0];
      badge.layer.backgroundColor = [NSColor colorWithSRGBRed:0.06 green:0.23 blue:0.20 alpha:0.90].CGColor;
      badge.layer.borderColor = [NSColor colorWithSRGBRed:0.32 green:0.86 blue:0.70 alpha:0.72].CGColor;
    } else if ([info.category isEqualToString:@"custom"]) {
      badge.textColor = [NSColor colorWithSRGBRed:1.00 green:0.68 blue:0.28 alpha:1.0];
      badge.layer.backgroundColor = [NSColor colorWithSRGBRed:0.28 green:0.16 blue:0.05 alpha:0.92].CGColor;
      badge.layer.borderColor = [NSColor colorWithSRGBRed:1.00 green:0.60 blue:0.20 alpha:0.78].CGColor;
    } else if ([info.category isEqualToString:@"ir"]) {
      badge.textColor = [NSColor colorWithSRGBRed:0.45 green:0.92 blue:0.58 alpha:1.0];
      badge.layer.backgroundColor = [NSColor colorWithSRGBRed:0.07 green:0.23 blue:0.12 alpha:0.90].CGColor;
      badge.layer.borderColor = [NSColor colorWithSRGBRed:0.32 green:0.84 blue:0.48 alpha:0.72].CGColor;
    }
  }

  void updateStageArchBadge(size_t stage, NSString* path) {
    RigModelArchInfo info = inspectModelArch(path);
    if (stage < stageHeaderArchBadges.size() && stageHeaderArchBadges[stage]) {
      applyArchBadgeStyle(stageHeaderArchBadges[stage], info, nil);
    }
  }

  void refreshStageArchitectureUI(size_t stage) {
    if (stage >= modelPickers.size()) return;
    auto alive = this->isAlive;
    auto refresh = ^{
      if (!alive || !*alive) return;
      NSPopUpButton* picker = modelPickers[stage];
      if (!picker) return;
      for (NSMenuItem* item in picker.itemArray) {
        NSString* rep = [item.representedObject isKindOfClass:NSString.class] ? item.representedObject : nil;
        if (rep.length) {
          item.title = formattedModelMenuTitle(rep);
          item.toolTip = modelPickerTooltip(stage, rep);
        }
      }
      NSString* cur = [picker.selectedItem.representedObject isKindOfClass:NSString.class]
          ? picker.selectedItem.representedObject
          : (!selectedPaths[stage].empty() ? [NSString stringWithUTF8String:selectedPaths[stage].c_str()] : nil);
      picker.toolTip = modelPickerTooltip(stage, cur);
      updateStageArchBadge(stage, cur);
    };
    if ([NSThread isMainThread]) refresh();
    else dispatch_async(dispatch_get_main_queue(), refresh);
  }

  static NSString* modelPickerTooltip(size_t stage, NSString* path) {
    NSString* role = stage == 0 ? @"pedal" : (stage == 1 ? @"amp" : @"cabinet");
    NSString* behavior = stage == 2
        ? @"Select the active cabinet NAM model or WAV impulse response."
        : stage == 3
        ? @"Select the second cabinet (Cab B) NAM model or WAV impulse response. It runs parallel to Cab A."
        : [NSString stringWithFormat:@"Select the active %@ NAM model.", role];
    if (!path.length) {
      return [NSString stringWithFormat:@"%@ No model is currently loaded.", behavior];
    }
    RigModelArchInfo info = inspectModelArch(path);
    return [NSString stringWithFormat:@"%@\nArchitecture: %@\nCurrent file: %@",
            behavior, info.detailSummary, path];
  }

  void displayPath(size_t stage, const char* path) {
    if (stage >= modelPickers.size() || !modelPickers[stage]) return;
    const std::string copy = path ? path : "";
    NSPopUpButton* picker = modelPickers[stage];
    NSMutableArray<NSString*>* savedPaths = [NSMutableArray array];
    for (const std::string& saved : availableModelPaths[stage])
      [savedPaths addObject:[NSString stringWithUTF8String:saved.c_str()]];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (copy.empty()) {
        [picker removeAllItems];
        [picker addItemWithTitle:(stage == 3 ? @"No Cab B loaded" : @"No model loaded")];
        picker.itemArray.firstObject.enabled = NO;
        picker.itemArray.firstObject.toolTip = modelPickerTooltip(stage, nil);
        for (NSString* p in savedPaths) {
          NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:formattedModelMenuTitle(p) action:NULL keyEquivalent:@""];
          it.representedObject = p; it.toolTip = modelPickerTooltip(stage, p);
          [[picker menu] addItem:it];
        }
        [picker selectItemAtIndex:0];
        picker.enabled = savedPaths.count == 0 ? NO : YES;
        picker.toolTip = modelPickerTooltip(stage, nil);
        updateStageArchBadge(stage, nil);
        return;
      }
      NSString* full = [NSString stringWithUTF8String:copy.c_str()];
      NSArray<NSMenuItem*>* items = picker.itemArray;
      NSInteger match = -1;
      for (NSInteger i = 0; i < (NSInteger)items.count; ++i) {
        NSString* rep = items[(NSUInteger)i].representedObject;
        if (rep && [rep isEqualToString:full]) {
          items[(NSUInteger)i].title = formattedModelMenuTitle(full);
          items[(NSUInteger)i].toolTip = modelPickerTooltip(stage, full);
          match = i;
          break;
        }
      }
      if (match >= 0) {
        [picker selectItemAtIndex:match];
        picker.enabled = YES;
      } else {
        NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:formattedModelMenuTitle(full) action:NULL keyEquivalent:@""];
        it.representedObject = full; it.toolTip = modelPickerTooltip(stage, full);
        [[picker menu] addItem:it];
        [picker selectItem:it];
        picker.enabled = YES;
      }
      picker.toolTip = modelPickerTooltip(stage, full);
      updateStageArchBadge(stage, full);
    });
  }

  // Placeholder SF Symbol shown when no tone artwork is available for a stage.
  static NSString* placeholderSymbolForStage(size_t stage) {
    return stage == 0 ? @"guitars" : (stage == 2 ? @"speaker.wave.3.fill" : @"bolt.fill");
  }

  // Populate a tile's model selector with the models available for that stage.
  // The dropdown is the tile's model control, so it's always visible once a
  // stage has models; the old filename text label is redundant and removed.
  void setStageModels(size_t stage, NSArray<NSString*>* paths) {
    if (stage >= availableModelPaths.size()) return;
    availableModelPaths[stage].clear();
    for (NSString* p in paths)
      if (p.length) availableModelPaths[stage].push_back(p.UTF8String);
    persistStageModels(stage);
    if (stage >= modelPickers.size()) return;

    auto updatePicker = ^{
      NSPopUpButton* picker = modelPickers[stage];
      if (!picker) return;
      [picker removeAllItems];
      for (NSString* p in paths) {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:(p.length ? formattedModelMenuTitle(p) : @"—")
                                                      action:NULL keyEquivalent:@""];
        item.representedObject = p;
        item.toolTip = modelPickerTooltip(stage, p);
        [[picker menu] addItem:item];
      }
      if (paths.count == 0) {
        [picker addItemWithTitle:(stage == 3 ? @"No Cab B loaded" : @"No model loaded")];
        picker.itemArray.firstObject.toolTip = modelPickerTooltip(stage, nil);
        picker.enabled = NO;
        picker.toolTip = modelPickerTooltip(stage, nil);
        updateStageArchBadge(stage, nil);
      } else {
        picker.enabled = YES;
        NSInteger selected = 0;
        if (!selectedPaths[stage].empty()) {
          NSString* current = [NSString stringWithUTF8String:selectedPaths[stage].c_str()];
          for (NSInteger i = 0; i < (NSInteger)picker.itemArray.count; ++i)
            if ([picker.itemArray[(NSUInteger)i].representedObject isEqualToString:current]) {
              selected = i; break;
            }
        }
        [picker selectItemAtIndex:selected];
        NSString* activePath = picker.selectedItem.representedObject;
        picker.toolTip = modelPickerTooltip(stage, activePath);
        updateStageArchBadge(stage, activePath);
      }
      picker.hidden = NO;
    };

    if ([NSThread isMainThread]) {
      updatePicker();
    } else {
      dispatch_async(dispatch_get_main_queue(), updatePicker);
    }
  }

  // Sets the gear thumbnail for a stage. Resolution order:
  //   1. `artworkPath` (NAM Rig's cached PNG) if it exists,
  //   2. NAM Rig's Tone3000 State Artwork cache for stage+toneId,
  //   3. the tone's online `imageURL` (downloaded async),
  //   4. a generic placeholder SF Symbol.
  // A placeholder is shown immediately; the real image swaps in when available.
  void setStageThumb(size_t stage, NSString* artworkPath, NSInteger toneId, NSString* imageURL) {
    if (stage >= stageImages.size() || !stageImages[stage]) return;
    const size_t s = stage;

    // Persist thumbnail metadata so it survives an instance recreation. Only do
    // this when real artwork data is present — placeholder calls (all nil/0),
    // e.g. during initial tile setup, must not clobber the persisted selection.
    if (toneId > 0 || imageURL.length || artworkPath.length) {
      selectedImageURLs[s] = imageURL.length ? imageURL.UTF8String : std::string();
      selectedToneIds[s] = (long)toneId;
      persistSelectedPaths();
    }

    // Fallback placeholder first so the well is never empty.
    dispatch_async(dispatch_get_main_queue(), ^{
      NSImage* icon = [NSImage imageWithSystemSymbolName:placeholderSymbolForStage(s)
                                  accessibilityDescription:nil];
      icon = [icon imageWithSymbolConfiguration:
              [NSImageSymbolConfiguration configurationWithPointSize:22 weight:NSFontWeightRegular]];
      stageImages[s].image = icon;
      stageImages[s].contentTintColor = [NSColor colorWithSRGBRed:0.58 green:0.60 blue:0.65 alpha:1.0];
      stageImages[s].imageScaling = NSImageScaleProportionallyUpOrDown;
    });

    NSImage* image = nil;
    if (artworkPath.length && [[NSFileManager defaultManager] fileExistsAtPath:artworkPath])
      image = [[NSImage alloc] initWithContentsOfFile:artworkPath];
    if (!image && toneId > 0) {
      NSString* prefix = s == 0 ? @"pedal" : (s == 2 ? @"cab" : @"amp");
      NSString* cache = [@"~/Library/Caches/NAM Rig/NAM Rig/Tone3000 State Artwork"
                         stringByExpandingTildeInPath];
      NSString* candidate = [[cache stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"%@-%ld.png", prefix, (long)toneId]] stringByRemovingPercentEncoding];
      if ([[NSFileManager defaultManager] fileExistsAtPath:candidate])
        image = [[NSImage alloc] initWithContentsOfFile:candidate];
    }

    if (image) {
      dispatch_async(dispatch_get_main_queue(), ^{
        stageImages[s].imageScaling = NSImageScaleProportionallyUpOrDown;
        stageImages[s].image = image;
      });
      return;
    }

    // Last resort: fetch the tone's online artwork.
    if (imageURL.length) {
      NSURL* url = [NSURL URLWithString:imageURL];
      // __weak (zeroing): if the UI is torn down before the download lands,
      // iv becomes nil and the guard below actually works. __unsafe_unretained
      // would leave a dangling non-nil pointer -> use-after-free on close.
      __weak NSImageView* iv = stageImages[s];
      [[[NSURLSession sharedSession] dataTaskWithURL:url
                                   completionHandler:^(NSData* data, NSURLResponse*, NSError*) {
        if (!data.length) return;
        NSImage* downloaded = [[NSImage alloc] initWithData:data];
        if (!downloaded || downloaded.size.width <= 0 || downloaded.size.height <= 0) return;
        dispatch_async(dispatch_get_main_queue(), ^{
          if (!iv) return;
          iv.imageScaling = NSImageScaleProportionallyUpOrDown;
          iv.image = downloaded;
        });
      }] resume];
    }
  }

  void cancelTransformerEditing() {
    const auto values = NAMRig::OutputTransformer::controlValues(
        NAMRig::OutputTransformer::parametersForProfile(transformerProfile, transformerAdjustments));
    for (size_t i = 0; i < values.size(); ++i) {
      if (!transformerFieldEditing[i]) continue;
      transformerFieldEditing[i] = false;
      NSTextField* field = transformerFields[i];
      field.stringValue = transformerValueText(i, values[i]);
      [field abortEditing];
      [field.window makeFirstResponder:nil];
    }
  }

  static NSString* transformerValueText(size_t index, float value) {
    if (index == 6 || index == 9)
      return [NSString stringWithFormat:@"%+.2f dB", value];
    if (index == 3) return [NSString stringWithFormat:@"%.1f%%", value];
    if (index == 2) return [NSString stringWithFormat:@"%.2fx", value];
    if (index == 7 || index == 10) return [NSString stringWithFormat:@"%.2f", value];
    return [NSString stringWithFormat:@"%.0f Hz", value];
  }

  std::array<float, 2> transformerControlRange(size_t index) const {
    static constexpr float mins[] = {5, 2000, 0.5f, 0, 20, 100, -12, 0.2f, 100, -12, 0.2f};
    static constexpr float maxes[] = {300, 24000, 10, 100, 400, 12000, 12, 4, 12000, 12, 4};
    const auto base = NAMRig::OutputTransformer::controlValues(
        NAMRig::OutputTransformer::parametersForProfile(transformerProfile));
    const auto& c = NAMRig::kTransformerControls[index];
    const bool ratio = c.defaultValue == 1.0f;
    return {std::max(mins[index], ratio ? base[index] * c.minimum : base[index] + c.minimum),
            std::min(maxes[index], ratio ? base[index] * c.maximum : base[index] + c.maximum)};
  }

  void updateTransformerTelemetry(int idx) {
    idx = NAMRig::OutputTransformer::clampProfile(idx);
    const auto p = NAMRig::OutputTransformer::parametersForProfile(idx, transformerAdjustments);
    if (transformerVisualizer) {
      transformerVisualizer.profile = idx;
      transformerVisualizer.parameters = p;
    }
    NSArray<NSString*>* vals = idx == 0
        ? @[@"Linear (Captured)", @"0% (Transparent)", @"Flat (0.0 dB)", @"None (0.0 dB)"]
        : @[[NSString stringWithFormat:@"%.0f Hz - %.1f kHz", p.lowCutHz, p.highCutHz / 1000.0],
            [NSString stringWithFormat:@"%.2fx / %.0f%% Mix", p.drive, p.saturationMix * 100.0],
            [NSString stringWithFormat:@"%+.1f dB @ %.2f kHz", p.voiceDb, p.voiceHz / 1000.0],
            [NSString stringWithFormat:@"%+.1f dB @ %.2f kHz", p.leakageDb, p.leakageHz / 1000.0]];
    for (size_t i = 0; i < 4; ++i) {
      if (transformerSpecLabels[i]) {
        transformerSpecLabels[i].stringValue = vals[i];
      }
    }
    const auto values = NAMRig::OutputTransformer::controlValues(p);
    for (size_t i = 0; i < values.size(); ++i) {
      NSSlider* slider = transformerSliders[i];
      if (slider) {
        const auto range = transformerControlRange(i);
        const bool log = NAMRig::kTransformerControls[i].logarithmic;
        slider.minValue = log ? std::log(range[0]) : range[0];
        slider.maxValue = log ? std::log(range[1]) : range[1];
        slider.doubleValue = log ? std::log(values[i]) : values[i];
        slider.enabled = idx != 0;
      }
      if (transformerFields[i]) {
        transformerFields[i].enabled = idx != 0;
        if (!transformerFieldEditing[i])
          transformerFields[i].stringValue = transformerValueText(i, values[i]);
      }
    }
  }

  void updateControl(uint32_t port, float value) {
    auto alive = this->isAlive;
    if (port >= NAMRig::kRackControlFirstPort &&
        port < NAMRig::kRackControlFirstPort + NAMRig::kRackCount) {
      const size_t index = port - NAMRig::kRackControlFirstPort;
      // Keep logical state current before preset and A/B snapshots are captured.
      rackControls[index] = std::isfinite(value)
          ? (value >= 0.5f ? 1.0f : 0.0f) : NAMRig::kRackControlDefaults[index];
      auto updateRack = ^{
        if (!alive || !*alive) return;
        RigButton* button = rackButtons[index];
        if (!button) return;
        const bool enabled = rackControls[index] >= 0.5f;
        button.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
        button.title = enabled ? @"ON" : @"OFF";
        button.primary = enabled;
        button.needsDisplay = YES;
      };
      if ([NSThread isMainThread]) updateRack();
      else dispatch_async(dispatch_get_main_queue(), updateRack);
      return;
    }
    if (port >= NAMRig::kTransformerControlFirstPort &&
        port < NAMRig::kTransformerControlFirstPort + NAMRig::kTransformerControlCount) {
      const size_t index = port - NAMRig::kTransformerControlFirstPort;
      const auto& c = NAMRig::kTransformerControls[index];
      const float trim = std::isfinite(value) ? std::clamp(value, c.minimum, c.maximum) : c.defaultValue;
      auto updateTransformer = ^{
        if (!alive || !*alive) return;
        transformerAdjustments[index] = trim;
        updateTransformerTelemetry(transformerProfile);
      };
      if ([NSThread isMainThread]) updateTransformer();
      else dispatch_async(dispatch_get_main_queue(), updateTransformer);
      return;
    }
    if (port == 59) {
      const bool inverted = value >= 0.5f;
      auto updatePolarity = ^{
        if (!alive || !*alive) return;
        cab2PolarityInverted = inverted;
        if (!cab2PolarityButton) return;
        cab2PolarityButton.state = inverted ? NSControlStateValueOn : NSControlStateValueOff;
        cab2PolarityButton.needsDisplay = YES;
      };
      // UI actions must update state before markModified captures an A/B snapshot.
      if ([NSThread isMainThread]) updatePolarity();
      else dispatch_async(dispatch_get_main_queue(), updatePolarity);
      return;
    }
    if ((port >= 7 && port <= 9) || port == 47) {
      const size_t slot = port == 47 ? 3 : port - 7;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!alive || !*alive) return;
        if (!powerButtons[slot]) return;
        powerButtons[slot].state = value >= 0.5f;
        powerButtons[slot].needsDisplay = YES;
      });
      return;
    }
    if (port == 20 || port == 21) {   // per-stage oversample mode (0..6)
      NSPopUpButton* popup = stageOsPopup[port - 20];
      if (popup) {
        const int mode = (int)(value + 0.5f);
        const int idx = NAMRig::oversampleMenuIndexFromMode(mode);
        dispatch_async(dispatch_get_main_queue(), ^{
          if (!alive || !*alive) return;
          if (idx >= 0 && idx < popup.itemArray.count)
            [popup selectItemAtIndex:idx];
          NSString* role = port == 20 ? @"pedal" : @"amp";
          NSString* selected = popup.selectedItem.toolTip ?: @"";
          popup.toolTip = [NSString stringWithFormat:
              @"Sets %@-stage oversampling. %@", role, selected];
        });
      }
      return;
    }
    if (port == 24) {
      const int idx = std::max(0, std::min(3, (int)(value + 0.5f)));
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!alive || !*alive) return;
        if (irNormPopup) {
          [irNormPopup selectItemAtIndex:idx];
          NSString* selected = irNormPopup.selectedItem.toolTip ?: @"";
          irNormPopup.toolTip = [NSString stringWithFormat:
              @"Sets WAV impulse-response gain handling. Changes glide smoothly. %@",
              selected];
        }
      });
      return;
    }
    if (port == 30) {
      const int idx = NAMRig::OutputTransformer::clampProfile(
          std::isfinite(value) ? (int)std::clamp(value + 0.5f, 0.0f, 12.0f) : 0);
      auto updateTransformer = ^{
        if (!alive || !*alive) return;
        transformerProfile = idx;
        if (transformerPopup) {
          [transformerPopup selectItemAtIndex:idx];
          transformerPopup.toolTip = transformerPopup.selectedItem.toolTip;
        }
        if (deckTransformerPopup) {
          [deckTransformerPopup selectItemAtIndex:idx];
          deckTransformerPopup.toolTip = deckTransformerPopup.selectedItem.toolTip;
        }
        updateTransformerTelemetry(idx);
      };
      if ([NSThread isMainThread]) updateTransformer();
      else dispatch_async(dispatch_get_main_queue(), updateTransformer);
      return;
    }
    if (port == 42) {
      const int idx = NAMRig::SpeakerDynamics::clampProfile((int)(value + 0.5f));
      auto updateSpeaker = ^{
        if (!alive || !*alive) return;
        if (speakerProfilePopup) {
          [speakerProfilePopup selectItemAtIndex:idx];
          speakerProfilePopup.toolTip = speakerProfilePopup.selectedItem.toolTip;
        }
        if (deckSpeakerProfilePopup) {
          [deckSpeakerProfilePopup selectItemAtIndex:idx];
          deckSpeakerProfilePopup.toolTip = deckSpeakerProfilePopup.selectedItem.toolTip;
        }
      };
      if ([NSThread isMainThread]) updateSpeaker();
      else dispatch_async(dispatch_get_main_queue(), updateSpeaker);
      return;
    }
    // Map the port to its knob index (ports 10/11 are auto-cab, no-ops in UI).
    ssize_t index = -1;
    for (size_t k = 0; k < kRigKnobCount; ++k)
      if (kRigKnobPorts[k] == port) { index = (ssize_t)k; break; }
    if (index < 0) return;
    auto updateKnob = ^{
      if (!alive || !*alive) return;
      if (knobs[index]) knobs[index].floatValue = value;
      if (!knobFieldEditing[index] && valueLabels[index])
        valueLabels[index].stringValue = rigKnobValueText(port, value);

      if (deckKnobs[index]) deckKnobs[index].floatValue = value;
      if (!deckKnobFieldEditing[index] && deckValueLabels[index])
        deckValueLabels[index].stringValue = rigKnobValueText(port, value);

      if (delayVisualizer && (port >= 50 && port <= 53)) {
        if (port == 50) delayVisualizer.timeMs = value;
        else if (port == 51) delayVisualizer.feedback = value;
        else if (port == 52) delayVisualizer.damping = value;
        else if (port == 53) delayVisualizer.mix = value;
        delayVisualizer.needsDisplay = YES;
      }
      if (reverbVisualizer && (port >= 54 && port <= 58)) {
        if (port == 54) reverbVisualizer.mix = value;
        else if (port == 55) reverbVisualizer.decay = value;
        else if (port == 56) reverbVisualizer.size = value;
        else if (port == 57) reverbVisualizer.damping = value;
        else if (port == 58) reverbVisualizer.preDelay = value;
        reverbVisualizer.needsDisplay = YES;
      }
      if (spatialVisualizer && (port == 32 || port == 33)) {
        if (port == 32) spatialVisualizer.width = value;
        else if (port == 33) spatialVisualizer.room = value;
        spatialVisualizer.needsDisplay = YES;
      }
      if (powerVisualizer && (port == 36 || port == 37 || port == 38 || port == 41)) {
        if (port == 36) powerVisualizer.sag = value;
        else if (port == 37) powerVisualizer.bias = value;
        else if (port == 38) powerVisualizer.feedback = value;
        else if (port == 41) powerVisualizer.master = value;
        powerVisualizer.needsDisplay = YES;
      }
      if (sculptVisualizer && (port == 39 || port == 40)) {
        if (port == 39) sculptVisualizer.bright = value;
        else if (port == 40) sculptVisualizer.inputEq = value;
        sculptVisualizer.needsDisplay = YES;
      }
      if (speakerVisualizer && (port >= 43 && port <= 46)) {
        if (port == 43) speakerVisualizer.drive = value;
        else if (port == 44) speakerVisualizer.comp = value;
        else if (port == 45) speakerVisualizer.thump = value;
        else if (port == 46) speakerVisualizer.resonance = value;
        speakerVisualizer.needsDisplay = YES;
      }
      if (cabConsoleVisualizer && (port == 25 || port == 48 || port == 49 || port == 26 || port == 27)) {
        if (port == 25) cabConsoleVisualizer.cabALevel = value;
        else if (port == 48) cabConsoleVisualizer.cabBLevel = value;
        else if (port == 49) cabConsoleVisualizer.alignDelay = value;
        else if (port == 26) cabConsoleVisualizer.lowCut = value;
        else if (port == 27) cabConsoleVisualizer.highCut = value;
        cabConsoleVisualizer.needsDisplay = YES;
      }
    };
    if ([NSThread isMainThread]) updateKnob();
    else dispatch_async(dispatch_get_main_queue(), updateKnob);
  }
};
#endif
