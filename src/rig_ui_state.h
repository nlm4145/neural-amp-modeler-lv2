// RigUIState — the LV2 UI state struct (extracted verbatim from nam_rig_ui.mm).
#pragma once

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>

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
#include <string>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>

#include "rig_knobs.h"
#include "oversample_modes.h"
#include "output_transformer.h"
#include "speaker_dynamics.h"
#import "rig_theme.h"
#import "rig_widgets.h"
#import "rig_presets.h"

@class NAMRigUIController;
@class ToneBrowserController;

struct RigUIState {
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
  __strong NSTextField* inDbLabel = nil;
  __strong NSView* inDbBar = nil;
  __strong NSLayoutConstraint* inDbBarWidth = nil;
  float lastInputDb = -120.0f;

  // Output level meter: dBFS readout + bar with peak-hold color.
  __strong NSTextField* outDbLabel = nil;
  __strong NSView* outDbBar = nil;
  __strong NSLayoutConstraint* outDbBarWidth = nil;
  float lastOutputDb = -120.0f;

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

  // Live hardware visualizers for the studio deck:
  __strong NAMDelayTapVisualizer* delayVisualizer = nil;
  __strong NAMReverbDecayVisualizer* reverbVisualizer = nil;
  __strong NAMSpatialAcousticVisualizer* spatialVisualizer = nil;
  __strong NAMPowerStageVisualizer* powerVisualizer = nil;
  __strong NAMSculptVisualizer* sculptVisualizer = nil;
  __strong NAMSpeakerDynamicsVisualizer* speakerVisualizer = nil;
  __strong NAMCabConsoleVisualizer* cabConsoleVisualizer = nil;

  void selectDeckTab(NSInteger index) {
    activeDeckTab = index;
    dispatch_async(dispatch_get_main_queue(), ^{
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

  // Tuner UI: toggle button in the title bar + the display panel it reveals.
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
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!tunerPanel || tunerPanel.hidden) return;
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
      tunerCentsLabel.stringValue = [NSString stringWithFormat:@"%+d¢",
                                     (int)std::lround(lastTunerCents)];
      const bool inTune = std::fabs(lastTunerCents) <= 5.0f;
      tunerNoteLabel.textColor = inTune ? rigGreen() : rigText();
      tunerNeedle.layer.backgroundColor = (inTune ? rigGreen() : rigOrange()).CGColor;
      tunerNeedle.hidden = NO;
      // Needle across ±50 cents: middle of the meter = in tune.
      NSView* meter = tunerNeedle.superview;
      const CGFloat w = meter.bounds.size.width - 6.0;
      tunerNeedleLeading.constant = 3.0 + (lastTunerCents + 50.0f) / 100.0f * w;
    });
  }

  // Redraw the input meter from lastInputDb. Called on the main thread
  // from portEvent. Scale: -60..0 dBFS mapped across the bar; color shifts
  // to orange above -6 dB (hot) and red above -1 dB (clip risk).
  void updateInputDbDisplay() {
    const float db = lastInputDb;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!inDbLabel) return;
      const float clamped = db < -60.0f ? -60.0f : (db > 0.0f ? 0.0f : db);
      inDbLabel.stringValue = db <= -119.0f ? @"  —  dB"
          : [NSString stringWithFormat:@"%+.1f dB", db];
      const CGFloat frac = (clamped + 60.0f) / 60.0f;
      inDbBarWidth.constant = 110.0 * frac;
      NSColor* fill = db > -1.0f ? [NSColor colorWithSRGBRed:0.92 green:0.26 blue:0.21 alpha:1.0]
                    : db > -6.0f  ? [NSColor colorWithSRGBRed:1.00 green:0.55 blue:0.25 alpha:1.0]
                                  : rigAccent();
      inDbBar.layer.backgroundColor = fill.CGColor;
    });
  }

  // Redraw the output meter from lastOutputDb. Scale: -60..0 dBFS.
  void updateOutputDbDisplay() {
    const float db = lastOutputDb;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!outDbLabel) return;
      const float clamped = db < -60.0f ? -60.0f : (db > 0.0f ? 0.0f : db);
      outDbLabel.stringValue = db <= -119.0f ? @"  —  dB"
          : [NSString stringWithFormat:@"%+.1f dB", db];
      const CGFloat frac = (clamped + 60.0f) / 60.0f;
      if (outDbBarWidth) outDbBarWidth.constant = 110.0 * frac;
      NSColor* fill = db > -0.5f ? [NSColor colorWithSRGBRed:0.95 green:0.20 blue:0.18 alpha:1.0]
                    : db > -4.0f  ? [NSColor colorWithSRGBRed:1.00 green:0.60 blue:0.20 alpha:1.0]
                                  : [NSColor colorWithSRGBRed:0.20 green:0.80 blue:0.95 alpha:1.0];
      if (outDbBar) outDbBar.layer.backgroundColor = fill.CGColor;
    });
  }

  __strong NSView* view = nil;
  __weak NSView* parent = nil;
  __strong NAMRigUIController* uiController = nil;
  __strong ToneBrowserController* browserController = nil;
  std::array<__strong NSTextField*, 4> pathLabels{};
  std::array<__strong NSButton*, 4> powerButtons{};
  std::array<__strong NSImageView*, 3> stageImages{};
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
    dispatch_async(dispatch_get_main_queue(), ^{
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

  void rebuildPresetMenu() {
    if (!presetPopup || !presetManager) return;
    [presetPopup removeAllItems];
    NSString* cur = presetManager.currentPresetName ?: @"Default Rig";
    NSInteger match = -1;
    NSInteger i = 0;
    for (NSString* name in presetManager.presetNames) {
      NSString* title = ([name isEqualToString:cur] && presetManager.isModified)
          ? [name stringByAppendingString:@" *"]
          : name;
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
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

    [[presetPopup menu] addItem:[NSMenuItem separatorItem]];

    NSMenuItem* revealItem = [[NSMenuItem alloc] initWithTitle:@"Reveal in Finder"
                                                        action:@selector(revealPresetsInFinder:)
                                                 keyEquivalent:@""];
    revealItem.target = (id)uiController;
    [[presetPopup menu] addItem:revealItem];

    if (match >= 0) {
      [presetPopup selectItemAtIndex:match];
    }
  }

  void updatePresetDisplayTitle() {
    dispatch_async(dispatch_get_main_queue(), ^{
      rebuildPresetMenu();
    });
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
    const CGFloat baseW = 1280.0, baseH = 980.0;
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

  static NSString* modelPickerTooltip(size_t stage, NSString* path) {
    NSString* role = stage == 0 ? @"pedal" : (stage == 1 ? @"amp" : @"cabinet");
    NSString* behavior = stage == 2
        ? @"Select the active cabinet NAM model or WAV impulse response."
        : stage == 3
        ? @"Select the second cabinet (Cab B) NAM model or WAV impulse response. It runs parallel to Cab A."
        : [NSString stringWithFormat:@"Select the active %@ NAM model.", role];
    return path.length
        ? [NSString stringWithFormat:@"%@ Current file: %@", behavior, path]
        : [NSString stringWithFormat:@"%@ No model is currently loaded.", behavior];
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
        [picker addItemWithTitle:@"No model loaded"];
        picker.itemArray.firstObject.enabled = NO;
        picker.itemArray.firstObject.toolTip = modelPickerTooltip(stage, nil);
        for (NSString* p in savedPaths) {
          NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:p.lastPathComponent action:NULL keyEquivalent:@""];
          it.representedObject = p; it.toolTip = modelPickerTooltip(stage, p);
          [[picker menu] addItem:it];
        }
        [picker selectItemAtIndex:0];
        picker.enabled = savedPaths.count == 0 ? NO : YES;
        picker.toolTip = modelPickerTooltip(stage, nil);
        return;
      }
      NSString* full = [NSString stringWithUTF8String:copy.c_str()];
      NSArray<NSMenuItem*>* items = picker.itemArray;
      NSInteger match = -1;
      for (NSInteger i = 0; i < (NSInteger)items.count; ++i) {
        NSString* rep = items[(NSUInteger)i].representedObject;
        if (rep && [rep isEqualToString:full]) { match = i; break; }
      }
      if (match >= 0) {
        [picker selectItemAtIndex:match];
        picker.enabled = YES;
      } else {
        NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:full.lastPathComponent action:NULL keyEquivalent:@""];
        it.representedObject = full; it.toolTip = modelPickerTooltip(stage, full);
        [[picker menu] addItem:it];
        [picker selectItem:it];
        picker.enabled = YES;
      }
      picker.toolTip = modelPickerTooltip(stage, full);
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
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:(p.length ? p.lastPathComponent : @"—")
                                                      action:NULL keyEquivalent:@""];
        item.representedObject = p;
        item.toolTip = modelPickerTooltip(stage, p);
        [[picker menu] addItem:item];
      }
      if (paths.count == 0) {
        [picker addItemWithTitle:@"No model loaded"];
        picker.itemArray.firstObject.toolTip = modelPickerTooltip(stage, nil);
        picker.enabled = NO;
        picker.toolTip = modelPickerTooltip(stage, nil);
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
        picker.toolTip = modelPickerTooltip(stage,
            picker.selectedItem.representedObject);
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

  void updateControl(uint32_t port, float value) {
    if ((port >= 7 && port <= 9) || port == 47) {
      const size_t slot = port == 47 ? 3 : port - 7;
      dispatch_async(dispatch_get_main_queue(), ^{
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
          (int)(value + 0.5f));
      dispatch_async(dispatch_get_main_queue(), ^{
        if (transformerPopup) {
          [transformerPopup selectItemAtIndex:idx];
          transformerPopup.toolTip = transformerPopup.selectedItem.toolTip;
        }
        if (deckTransformerPopup) {
          [deckTransformerPopup selectItemAtIndex:idx];
          deckTransformerPopup.toolTip = deckTransformerPopup.selectedItem.toolTip;
        }
      });
      return;
    }
    if (port == 42) {
      const int idx = NAMRig::SpeakerDynamics::clampProfile((int)(value + 0.5f));
      dispatch_async(dispatch_get_main_queue(), ^{
        if (speakerProfilePopup) {
          [speakerProfilePopup selectItemAtIndex:idx];
          speakerProfilePopup.toolTip = speakerProfilePopup.selectedItem.toolTip;
        }
        if (deckSpeakerProfilePopup) {
          [deckSpeakerProfilePopup selectItemAtIndex:idx];
          deckSpeakerProfilePopup.toolTip = deckSpeakerProfilePopup.selectedItem.toolTip;
        }
      });
      return;
    }
    // Map the port to its knob index (ports 10/11 are auto-cab, no-ops in UI).
    ssize_t index = -1;
    for (size_t k = 0; k < kRigKnobCount; ++k)
      if (kRigKnobPorts[k] == port) { index = (ssize_t)k; break; }
    if (index < 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
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
    });
  }
};
#endif
