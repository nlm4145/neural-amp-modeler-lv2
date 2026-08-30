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
#import "rig_theme.h"

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
  std::array<LV2_URID, 3> pathURIDs{};
  LV2_URID atomFloat = 0;
  LV2_URID tunerNoteURID = 0;
  LV2_URID tunerCentsURID = 0;
  LV2_URID inputDbURID = 0;

  // Input level meter (title bar): dBFS readout + bar with peak-hold color.
  __strong NSTextField* inDbLabel = nil;
  __strong NSView* inDbBar = nil;
  __strong NSLayoutConstraint* inDbBarWidth = nil;
  float lastInputDb = -120.0f;

  // Oversample mode dropdowns. The title-bar popup is the MASTER (sets both
  // stages); the pedal and amp tiles each have their own per-stage popup
  // (ports 20/21, five modes: None / Legacy / True 2x-4x-8x). The cab
  // has none — a WAV IR is linear and cannot alias; a .nam cab follows the
  // amp's mode.
  __strong NSPopUpButton* osPopup = nil;               // master (title bar)
  __strong NSPopUpButton* stageOsPopup[2] = {nil, nil};  // pedal, amp

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

  __strong NSView* view = nil;
  __weak NSView* parent = nil;
  __strong NAMRigUIController* uiController = nil;
  __strong ToneBrowserController* browserController = nil;
  std::array<__strong NSTextField*, 3> pathLabels{};
  std::array<__strong NSButton*, 3> powerButtons{};
  std::array<__strong NSImageView*, 3> stageImages{};
  // auto-cab is always on — no toggle or status label needed
  std::array<__strong NSSlider*, kRigKnobCount> knobs{};
  std::array<__strong NSTextField*, kRigKnobCount> valueLabels{};
  // Editable knob value boxes: while the user is typing in one, host-driven
  // updates must not clobber that field (index = kRigKnobPorts index).
  std::array<bool, kRigKnobCount> knobFieldEditing{};
  std::array<__strong NSPopUpButton*, 3> modelPickers{};  // per-stage model selector in each tile
  LV2UI_Resize* hostResize = nullptr;
  CGFloat zoom = 1.0;
  NSComboBox* zoomControl = nil;
  __strong NSView* rigContent = nil;   // the Auto Layout container that fills the window

  // UI-side persistence: the UI is the single source of truth for the selected
  // model paths (every selection is sent via sendPath). We write them to disk on
  // change and re-send them on every instantiate, so selections survive a
  // plugin-window recreation regardless of the host's LV2-State handling.
  std::array<std::string, 3> selectedPaths{};
  std::array<std::string, 3> selectedImageURLs{};   // thumbnail metadata (persisted)
  std::array<long, 3> selectedToneIds{};            // key into NAM Rig's artwork cache
  static std::string uiPersistFile() {
    const char* home = std::getenv("HOME");
    std::string dir = home ? std::string(home) : std::string(".");
    dir += "/Library/Application Support/NAM Oversampled Rig";
    ::mkdir(dir.c_str(), 0755);
    return dir + "/rig-model-paths.txt";
  }
  void persistSelectedPaths() {
    const std::string file = uiPersistFile();
    std::ofstream out(file, std::ios::trunc);
    if (!out) return;
    for (size_t i = 0; i < 3; ++i)
      out << selectedPaths[i] << "\n"
          << selectedImageURLs[i] << "\n"
          << selectedToneIds[i] << "\n";
  }
  // Re-send any previously selected model paths (and re-apply thumbnails) so the
  // rig comes back after a plugin-window/instance recreation.
  void restoreSelectedPaths() {
    const std::string file = uiPersistFile();
    std::ifstream in(file);
    if (!in) return;
    for (size_t i = 0; i < 3 && i < selectedPaths.size(); ++i) {
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
      if (path.empty() && imageURL.empty() && toneId <= 0) continue;
      if (!path.empty()) { sendPath(i, path.c_str()); displayPath(i, path.c_str()); }
      if (imageURL.length() || toneId > 0)
        setStageThumb(i, nil, toneId, imageURL.length() ? [NSString stringWithUTF8String:imageURL.c_str()] : nil);
    }
  }
  void sendPath(size_t stage, const char* path) {
    if (stage >= pathURIDs.size() || !path) return;
    // Remember + persist the selection so it survives a UI/instance recreation.
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
  // is laid out once at base (1280x830) and pinned there, and we scale its layer
  // by `zoom` anchored top-left. Every child — Auto-Layout tiles, the fixed-frame
  // knobs, dropdowns, tone cards, text, images — renders scaled proportionally,
  // because they all live inside rigContent's layer and are never re-laid out at
  // the zoomed size. `state->view` (the widget Element hosts) and ui_resize are
  // sized to base*zoom so the window matches the scaled content.
  void applyZoom() {
    const CGFloat baseW = 1280.0, baseH = 830.0;
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

  void displayPath(size_t stage, const char* path) {
    if (stage >= modelPickers.size() || !modelPickers[stage]) return;
    const std::string copy = path ? path : "";
    dispatch_async(dispatch_get_main_queue(), ^{
      NSPopUpButton* picker = modelPickers[stage];
      if (copy.empty()) {
        [picker removeAllItems];
        [picker addItemWithTitle:@"No model loaded"];
        picker.enabled = NO;
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
        [picker removeAllItems];
        NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:full.lastPathComponent action:NULL keyEquivalent:@""];
        it.representedObject = full; it.toolTip = full;
        [[picker menu] addItem:it];
        [picker selectItemAtIndex:0];
        picker.enabled = YES;
      }
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
    if (stage >= modelPickers.size() || !modelPickers[stage]) return;
    NSPopUpButton* picker = modelPickers[stage];
    [picker removeAllItems];
    for (NSString* p in paths) {
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:(p.length ? p.lastPathComponent : @"—")
                                                    action:NULL keyEquivalent:@""];
      item.representedObject = p;
      item.toolTip = p;
      [[picker menu] addItem:item];
    }
    if (paths.count == 0) {
      [picker addItemWithTitle:@"No model loaded"];
      picker.enabled = NO;
    } else {
      picker.enabled = YES;
      [picker selectItemAtIndex:0];
    }
    picker.hidden = NO;
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
    if (port >= 7 && port <= 9) {
      dispatch_async(dispatch_get_main_queue(), ^{ powerButtons[port - 7].state = value >= 0.5f; powerButtons[port - 7].needsDisplay = YES; });
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
        });
      }
      return;
    }
    if (port == 19) {   // legacy global mode: reflect onto the master popup
      const int idx = value < 0.5f ? 0 : (value < 1.5f ? 1 : 2);
      dispatch_async(dispatch_get_main_queue(), ^{ [osPopup selectItemAtIndex:idx]; });
      return;
    }
    // Map the port to its knob index (ports 10/11 are auto-cab, no-ops in UI).
    ssize_t index = -1;
    for (size_t k = 0; k < kRigKnobCount; ++k)
      if (kRigKnobPorts[k] == port) { index = (ssize_t)k; break; }
    if (index < 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      knobs[index].floatValue = value;
      if (knobFieldEditing[index]) return;   // user is typing — don't clobber the field
      valueLabels[index].stringValue = rigKnobValueText(port, value);
    });
  }
};
#endif
