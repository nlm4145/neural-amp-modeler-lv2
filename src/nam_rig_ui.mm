#import <Cocoa/Cocoa.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import "rig_ai_copilot.h"
#import "rig_riff_recorder.h"
#import "rig_local_tone_matcher.h"
#import "rig_ai_support.h"
#import "rig_profile_catalog.h"
#include "rig_control_metadata.h"

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
#define NAM_RIG_PRE_AMP_DB_URI NAM_RIG_URI "-pre-amp-db"
#define NAM_RIG_POST_AMP_DB_URI NAM_RIG_URI "-post-amp-db"
#define NAM_RIG_OUTPUT_DB_URI NAM_RIG_URI "-output-db"

#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
#include <string>
#include <utility>
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
    @"True 8x — Strong alias rejection; the default and the best quality-per-CPU setting.",
    @"True 16x — Maximum true oversampling. Roughly doubles the stage's CPU versus 8x for alias rejection that is mostly inaudible."
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
// Target-section times: "m:ss" for display; accepts "m:ss" or plain seconds.
static NSString* copilotClock(double seconds) {
  const long s = std::lround(std::max(0.0, seconds));
  return [NSString stringWithFormat:@"%ld:%02ld", s / 60, s % 60];
}
static double copilotParseClock(NSString* text) {
  NSArray<NSString*>* parts = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] componentsSeparatedByString:@":"];
  double seconds = 0;
  for (NSString* part in parts) seconds = seconds * 60 + part.doubleValue;
  return std::isfinite(seconds) ? std::max(0.0, seconds) : 0;
}

#import "rig_theme.h"
#import "rig_widgets.h"
#include "overdrive.h"
#include "rig_knobs.h"
#include "oversample_modes.h"
#include "rig_ui_state.h"
#import "rig_tone_browser.h"
#import "rig_tone_api.h"

@interface NAMRigUIController : NSObject <NSComboBoxDelegate, NSTextFieldDelegate, NSMenuDelegate, NSPopoverDelegate>
@property(nonatomic, assign) RigUIState* state;
@property(nonatomic, strong) NSPopUpButton* copilotProvPopup;
@property(nonatomic, strong) NSComboBox* copilotModelComboBox;
@property(nonatomic, strong) RigButton* copilotModelsRefreshBtn;
@property(nonatomic, strong) NSTextField* copilotModelsStatus;
@property(nonatomic) NSUInteger copilotModelsRequestSerial;
@property(nonatomic, strong) NSSecureTextField* copilotKeyField;
@property(nonatomic, strong) NSTextField* copilotPromptInput;
@property(nonatomic, strong) NSTextView* copilotOutputView;
@property(nonatomic, strong) RigButton* copilotDialBtn;
@property(nonatomic, strong) RigButton* copilotUndoBtn;
@property(nonatomic, strong) NSProgressIndicator* copilotSpinner;
@property(nonatomic, strong) NSTextField* copilotURLField;
@property(nonatomic, strong) NSButton* copilotSearxngButton;
@property(nonatomic, strong) RigButton* copilotApplyBtn;
@property(nonatomic, strong) RigButton* copilotCancelBtn;
@property(nonatomic, strong) RigAICopilotResult* copilotProposal;
@property(nonatomic, strong) RigButton* copilotRecordBtn;
@property(nonatomic, strong) RigButton* copilotPlayAlongBtn;
@property(nonatomic, strong) RigButton* copilotPlayBtn;
@property(nonatomic, strong) RigButton* copilotClearBtn;
@property(nonatomic, strong) NSTextField* copilotRiffStatusLabel;
@property(nonatomic, strong) NSProgressIndicator* copilotRiffLevelBar;
@property(nonatomic, strong) NSTimer* copilotRiffTimer;
@property(nonatomic, strong) NSButton* copilotSendAudioButton;
@property(nonatomic, strong) NSButton* copilotGuidedButton;
@property(nonatomic, strong) NSPopUpButton* copilotTrackPopup;
@property(nonatomic, strong) NSPopUpButton* copilotModePopup;
@property(nonatomic, strong) NSTextField* copilotGuitarInfo;
@property(nonatomic, strong) RigButton* copilotRenderBtn;
@property(nonatomic, strong) RigButton* copilotLocalMatchBtn;
@property(nonatomic, strong) RigButton* copilotTargetPlayBtn;
@property(nonatomic, strong) RigButton* copilotTargetClearBtn;
@property(nonatomic, strong) NSTextField* copilotTargetStatus;
@property(nonatomic, strong) NSButton* copilotTargetAutoButton;
@property(nonatomic, strong) NSTextField* copilotTargetStartField;
@property(nonatomic, strong) NSStepper* copilotTargetStartStepper;
@property(nonatomic, strong) NSPopUpButton* copilotTargetLengthPopup;
@property(nonatomic, strong) NSTextField* copilotTargetRangeLabel;
@property(nonatomic, strong) NSTextField* copilotLocalMatchStatus;
@property(nonatomic, strong) NSButton* copilotMatchOnlineButton;
@property(nonatomic, strong) NSButton* copilotMatchResearchButton;
@property(nonatomic, strong) NSButton* copilotAccurateRescoreButton;
@property(nonatomic, strong) NSButton* copilotEmbeddingRerankButton;
@property(nonatomic, strong) NSButton* copilotMatchMixEQButton;
@property(nonatomic, strong) NSPopUpButton* copilotMatchCandidates;
@property(nonatomic, strong) NSArray<RigLocalToneMatch*>* copilotLocalMatches;
@property(nonatomic) BOOL copilotLocalMatching;
@property(nonatomic) BOOL copilotRecordIsPlayAlong;
@property(nonatomic) NSUInteger copilotLocalMatchGeneration;
@property(nonatomic, strong) RigPreset* copilotBasePreset;
@property(nonatomic, strong) NSDictionary* copilotBaseContext;
@property(nonatomic, strong) NSDictionary* copilotAuditionContext;
@property(nonatomic, strong) NSTextField* copilotPresetNameField;
@property(nonatomic, copy) NSString* copilotLogBase;
@property(nonatomic) NSInteger copilotRecordCountdown;
@property(nonatomic) NSInteger copilotLastGuidedSegment;
@property(nonatomic, strong) NSProgressIndicator* copilotDemucsSpinner;
@property(nonatomic, strong) NSTask* copilotDemucsTask;
@property(nonatomic) BOOL copilotDemucsRunning;
- (void)chooseModel:(id)sender;
- (void)clearModel:(id)sender;
- (void)removeStageSelection:(id)sender;
- (void)removeBothCabsSelection:(id)sender;
- (void)downloadStageArchitecture:(NSMenuItem*)sender;
- (BOOL)isStageArchitectureDownloaded:(size_t)stage arch:(NSString*)arch;
- (BOOL)isStageArchitectureAvailable:(size_t)stage arch:(NSString*)arch;
- (ToneItem*)toneItemForStage:(size_t)stage;
- (NSMenuItem*)downloadArchitectureMenuItemForStage:(size_t)stage title:(NSString*)menuTitle;
- (void)menuNeedsUpdate:(NSMenu*)menu;
- (void)controlChanged:(NSControl*)sender;
- (void)knobFieldCommitted:(NSTextField*)sender;
- (void)tunerToggled:(NSButton*)sender;
- (void)stageOversampleChanged:(NSPopUpButton*)sender;     // per-stage (tiles)
- (void)irNormalizationChanged:(NSPopUpButton*)sender;
- (void)transformerChanged:(NSPopUpButton*)sender;
- (void)showTransformerControls:(NSButton*)sender;
- (void)transformerControlChanged:(NSControl*)sender;
- (void)resetTransformerControls:(id)sender;
- (void)showAmpAdvanced:(NSButton*)sender;
- (void)speakerProfileChanged:(NSPopUpButton*)sender;
- (void)showSpeakerLoad:(NSButton*)sender;
- (void)showEffects:(NSButton*)sender;
- (void)resetAllKnobs:(id)sender;
- (void)zoomChanged:(NSComboBox*)sender;
- (void)stageModelChanged:(NSPopUpButton*)sender;
- (void)selectLibraryModelItem:(NSMenuItem*)sender;
- (void)presetPopupChanged:(id)sender;
- (void)prevPresetClicked:(NSButton*)sender;
- (void)nextPresetClicked:(NSButton*)sender;
- (void)saveCurrentPreset:(id)sender;
- (void)savePresetAs:(id)sender;
- (void)renameCurrentPreset:(id)sender;
- (void)duplicateCurrentPreset:(id)sender;
- (void)deleteCurrentPreset:(id)sender;
- (void)revealPresetsInFinder:(id)sender;
- (void)autoOrganizePresetsAction:(id)sender;
- (void)switchTab:(NSButton*)sender;
- (void)switchDeckTab:(NSButton*)sender;
- (void)toggleMuteOnTune:(NSButton*)sender;
- (void)abPresetChanged:(id)sender;
- (void)abIntervalChanged:(NSSlider*)sender;
- (void)abToggleClicked:(NSButton*)sender;
- (void)abTimerFired:(NSTimer*)timer;
- (void)applyDelayPreset:(NSButton*)sender;
- (void)applyReverbPreset:(NSButton*)sender;
- (void)applySpatialPreset:(NSButton*)sender;
- (void)applyPowerPreset:(NSButton*)sender;
- (void)applyCompressorPreset:(NSButton*)sender;
- (void)applySculptPreset:(NSButton*)sender;
- (void)applyBoostPreset:(NSButton*)sender;
- (void)boostVoicingChanged:(NSPopUpButton*)sender;
- (void)sculptPageClicked:(NSButton*)sender;
- (void)applySpeakerPreset:(NSButton*)sender;
- (void)applyCabConsolePreset:(NSButton*)sender;
- (void)applyTransformerPreset:(NSButton*)sender;
- (void)slotPresetPopupChanged:(NSPopUpButton*)sender;
- (void)saveSlotPreset:(NSMenuItem*)sender;
- (void)saveSlotPresetAs:(NSMenuItem*)sender;
- (void)renameSlotPreset:(NSMenuItem*)sender;
- (void)deleteSlotPreset:(NSMenuItem*)sender;
- (void)propagateSlotPresetToAll:(NSMenuItem*)sender;
- (void)selectStageCard:(NSInteger)stageIndex;
- (void)cyclePreviousStageModel;
- (void)cycleNextStageModel;
- (void)cycleSelectedStageModel:(NSInteger)direction;
- (void)markPresetModified;
@end

@interface NAMRigUIController (AICopilot)
- (void)openAICopilot:(id)sender;
- (void)executeCopilotDial:(id)sender;
- (void)undoCopilotDial:(id)sender;
- (void)saveCopilotConfig:(id)sender;
- (void)copilotProviderChanged:(NSPopUpButton*)sender;
- (void)refreshCopilotModelsAction:(id)sender;
- (void)copilotKeyFieldAction:(id)sender;
- (void)updateCopilotProviderControlsForProvider:(NSString*)provider;
- (void)updateCopilotAudioControls;
- (void)copilotAudioUploadToggled:(id)sender;
- (void)refreshCopilotModelsUI;
- (void)refreshCopilotModelsUIForced:(BOOL)force;
- (void)applyCopilotProposal:(id)sender;
- (void)cancelCopilotRequest:(id)sender;
- (void)toggleCopilotRecordRiff:(id)sender;
- (void)toggleCopilotPlayAlong:(id)sender;
- (void)playCopilotRiff:(id)sender;
- (void)clearCopilotRiff:(id)sender;
- (void)updateCopilotRiffUI;
- (void)renderCopilotDI:(id)sender;
- (void)matchCopilotLocally:(id)sender;
- (void)selectCopilotLocalMatch:(id)sender;
- (void)importCopilotReference:(id)sender;
- (void)clearCopilotReference:(id)sender;
- (void)toggleCopilotTargetPreview:(id)sender;
- (void)changeCopilotTargetSection:(id)sender;
- (void)toggleCopilotMatchResearch:(id)sender;
- (void)copilotSearxngToggled:(id)sender;
- (void)appendCopilotLog:(NSString*)line;
- (void)resetCopilotLog:(NSString*)header;
- (void)setCopilotLiveLine:(NSString*)line;
- (NSString*)plannedCopilotPresetName;
@end

@implementation NAMRigUIController
- (void)switchTab:(NSButton*)sender {
  if (!_state) return;
  if (_state->aiCopilotPopover && _state->aiCopilotPopover.isShown) {
    [_state->aiCopilotPopover close];
  }
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
  if ([sender respondsToSelector:@selector(setPrimary:)]) {
    ((RigButton*)sender).primary = _state->muteOnTune;
  }
  sender.needsDisplay = YES;
  if (_state->tunerButton && _state->tunerButton.state == NSControlStateValueOn) {
    if (_state->muteOnTune) _state->muteOutputForTuner();
    else _state->restoreOutputAfterTuner();
  }
}
- (void)markPresetModified {
  if (!_state) return;
  _state->markModified();
}
- (void)chooseModel:(id)sender {
  NSInteger tag = [sender respondsToSelector:@selector(tag)] ? [sender tag] : -1;
  if (!_state || tag < 0 || tag > 3) return;
  [self selectStageCard:tag];
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.title = [NSString stringWithFormat:@"Choose %@ NAM Model",
                 @[@"a Pedal", @"an Amp", @"a Cab", @"a Cab B"][(NSUInteger)tag]];
  panel.prompt = @"Load Model";
  panel.canChooseFiles = YES;
  panel.canChooseDirectories = NO;
  panel.allowsMultipleSelection = NO;
  panel.allowedFileTypes = tag >= 2
      ? @[@"nam", @"nammodel", @"json", @"aidax", @"aidadspmodel", @"wav"]
      : @[@"nam", @"nammodel", @"json", @"aidax", @"aidadspmodel"];

  NSString* defaultDir = nil;
  if (!_state->selectedPaths[(size_t)tag].empty()) {
    NSString* existing = [NSString stringWithUTF8String:_state->selectedPaths[(size_t)tag].c_str()];
    defaultDir = [existing stringByDeletingLastPathComponent];
  }
  if (!defaultDir.length || ![[NSFileManager defaultManager] fileExistsAtPath:defaultDir]) {
    NSString* category = tag == 0 ? @"Pedal" : (tag == 1 ? @"Amp" : @"Cab");
    NSString* toneLib = [[@"~/Music/Tone3000 Library" stringByExpandingTildeInPath] stringByAppendingPathComponent:category];
    if ([[NSFileManager defaultManager] fileExistsAtPath:toneLib]) {
      defaultDir = toneLib;
    }
  }
  if (defaultDir.length) {
    panel.directoryURL = [NSURL fileURLWithPath:defaultDir];
  }

  if ([panel runModal] == NSModalResponseOK) {
    NSString* chosen = panel.URL.path;
    std::vector<std::string> discovered = discoverModelsForStagePath(chosen.fileSystemRepresentation, (size_t)tag);
    NSMutableArray<NSString*>* paths = [NSMutableArray arrayWithCapacity:discovered.size()];
    for (const auto& m : discovered) {
      if (!m.empty()) [paths addObject:[NSString stringWithUTF8String:m.c_str()]];
    }
    if (paths.count > 0) {
      _state->setStageModels((size_t)tag, paths);
    }
    _state->sendPath((size_t)tag, chosen.fileSystemRepresentation);
    _state->updateThumbnailForStagePath((size_t)tag, chosen);
    [self markPresetModified];
  }
}

- (void)clearModel:(id)sender {
  if (!_state) return;
  NSInteger tag = [sender respondsToSelector:@selector(tag)] ? [sender tag] : 0;
  if (tag < 0 || tag > 3) return;
  size_t stage = (size_t)tag;
  _state->setStageModels(stage, @[]);
  _state->sendPath(stage, "");
  if (stage <= 2) {
    _state->setStageThumb(stage, nil, 0, nil);  // revert to placeholder
  }
  if (stage == 3) {
    if (_state->powerButtons[3] && _state->powerButtons[3].state == NSControlStateValueOn) {
      _state->powerButtons[3].state = NSControlStateValueOff;
      _state->sendControl(47, 0.0f);
      _state->updateControl(47, 0.0f);
    }
  }
  [self markPresetModified];
}

- (void)removeStageSelection:(id)sender {
  [self clearModel:sender];
}

- (void)removeBothCabsSelection:(id)sender {
  (void)sender;
  if (!_state) return;
  _state->setStageModels(2, @[]);
  _state->sendPath(2, "");
  _state->setStageThumb(2, nil, 0, nil);
  _state->setStageModels(3, @[]);
  _state->sendPath(3, "");
  if (_state->powerButtons[3] && _state->powerButtons[3].state == NSControlStateValueOn) {
    _state->powerButtons[3].state = NSControlStateValueOff;
    _state->sendControl(47, 0.0f);
    _state->updateControl(47, 0.0f);
  }
  [self markPresetModified];
}

- (ToneItem*)toneItemForStage:(size_t)stage {
  if (!_state || stage >= _state->selectedPaths.size()) return nil;
  NSInteger toneId = (stage < _state->selectedToneIds.size()) ? _state->selectedToneIds[stage] : 0;
  NSString* curPath = !_state->selectedPaths[stage].empty()
      ? [NSString stringWithUTF8String:_state->selectedPaths[stage].c_str()]
      : nil;
  NSString* folder = curPath.length ? [curPath stringByDeletingLastPathComponent] : nil;
  NSString* manifestPath = folder.length ? [folder stringByAppendingPathComponent:@"_tone3000.json"] : nil;
  NSDictionary* root = (manifestPath.length && [[NSFileManager defaultManager] fileExistsAtPath:manifestPath])
      ? jsonDictionaryAtPath(manifestPath) : nil;
  NSDictionary* toneDict = [root[@"tone"] isKindOfClass:NSDictionary.class] ? root[@"tone"] : nil;
  if (toneId <= 0 && toneDict && [toneDict[@"id"] respondsToSelector:@selector(integerValue)]) {
    toneId = [toneDict[@"id"] integerValue];
  }
  if (toneId <= 0 && [curPath containsString:@"/PreviewCache/"]) {
    NSString* seg = [folder lastPathComponent];
    if (seg.integerValue > 0) toneId = seg.integerValue;
  }

  ToneItem* found = nil;
  if (_state->browserController && toneId > 0) {
    for (ToneItem* it in _state->browserController.allItems) {
      if (it.toneId == toneId) { found = it; break; }
    }
    if (!found) {
      for (ToneItem* it in _state->browserController.searchResults) {
        if (it.toneId == toneId) { found = it; break; }
      }
    }
  }
  if (found) {
    if (toneDict) {
      if (found.a2Count <= 0 && [toneDict[@"a2_models_count"] respondsToSelector:@selector(integerValue)])
        found.a2Count = [toneDict[@"a2_models_count"] integerValue];
      if (found.a1Count <= 0 && [toneDict[@"a1_models_count"] respondsToSelector:@selector(integerValue)])
        found.a1Count = [toneDict[@"a1_models_count"] integerValue];
      if (found.customCount <= 0 && [toneDict[@"custom_models_count"] respondsToSelector:@selector(integerValue)])
        found.customCount = [toneDict[@"custom_models_count"] integerValue];
      if (!found.toneData) found.toneData = toneDict;
    }
    return found;
  }

  if (toneDict) {
    NSMutableArray<NSString*>* models = [NSMutableArray array];
    for (NSDictionary* dl in [root[@"downloads"] isKindOfClass:NSArray.class] ? root[@"downloads"] : @[]) {
      NSString* fn = [dl[@"local_filename"] isKindOfClass:NSString.class] ? dl[@"local_filename"] : nil;
      if (fn.length) {
        NSString* p = [folder stringByAppendingPathComponent:fn];
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) [models addObject:p];
      }
    }
    NSDate* mtime = [[[NSFileManager defaultManager] attributesOfItemAtPath:manifestPath error:nil] fileModificationDate];
    ToneItem* item = toneItem(toneDict, models, mtime);
    if (item) return item;
  }

  if (toneId > 0) {
    ToneItem* stub = [[ToneItem alloc] init];
    stub.toneId = toneId;
    stub.stage = (stage == 3) ? 2 : (NSInteger)stage;
    stub.title = curPath ? [curPath.lastPathComponent stringByDeletingPathExtension] : [NSString stringWithFormat:@"Tone #%ld", (long)toneId];
    if (stage < _state->selectedImageURLs.size() && !_state->selectedImageURLs[stage].empty()) {
      stub.imageURL = [NSString stringWithUTF8String:_state->selectedImageURLs[stage].c_str()];
    }
    stub.artworkPath = artworkForTone(stub.toneId, stub.stage);
    return stub;
  }

  return nil;
}

- (BOOL)isStageArchitectureDownloaded:(size_t)stage arch:(NSString*)arch {
  if (!_state || stage >= _state->selectedPaths.size()) return NO;
  NSString* targetCategory = [arch isEqualToString:@"2"] ? @"a2" : ([arch isEqualToString:@"1"] ? @"a1" : @"custom");
  NSFileManager* fm = [NSFileManager defaultManager];

  // 1. Check currently available model paths for this stage:
  if (stage < _state->availableModelPaths.size()) {
    for (const auto& pathStr : _state->availableModelPaths[stage]) {
      if (pathStr.empty()) continue;
      NSString* p = [NSString stringWithUTF8String:pathStr.c_str()];
      if ([fm fileExistsAtPath:p]) {
        RigUIState::RigModelArchInfo info = RigUIState::inspectModelArch(p);
        if ([info.category isEqualToString:targetCategory]) {
          return YES;
        }
      }
    }
  }

  // 2. Candidate folders: current model folder, Tone3000 library folder, preview cache folder
  NSString* curPath = !_state->selectedPaths[stage].empty()
      ? [NSString stringWithUTF8String:_state->selectedPaths[stage].c_str()]
      : nil;
  NSMutableArray<NSString*>* candidateFolders = [NSMutableArray array];
  if (curPath.length) {
    [candidateFolders addObject:[curPath stringByDeletingLastPathComponent]];
  }

  ToneItem* item = [self toneItemForStage:stage];
  if (item) {
    NSString* category = (stage == 0) ? @"Pedal" : ((stage == 2 || stage == 3) ? @"Cab" : @"Amp");
    if ([item.gear.lowercaseString isEqualToString:@"amp-cab"] || [item.gear.lowercaseString isEqualToString:@"full-rig"]) {
      category = @"Full Rig";
    }
    NSString* libFolder = [[[[@"~/Music/Tone3000 Library" stringByExpandingTildeInPath]
                            stringByAppendingPathComponent:category]
                           stringByAppendingPathComponent:safeFilename(item.title)] copy];
    if (libFolder.length && ![candidateFolders containsObject:libFolder]) {
      [candidateFolders addObject:libFolder];
    }
    if (item.toneId > 0) {
      NSString* previewFolder = [[[@("~/Library/Application Support/Axe FX/PreviewCache") stringByExpandingTildeInPath]
                                  stringByAppendingPathComponent:[NSString stringWithFormat:@"%ld", (long)item.toneId]] copy];
      if (previewFolder.length && ![candidateFolders containsObject:previewFolder]) {
        [candidateFolders addObject:previewFolder];
      }
    }
  }

  for (NSString* folder in candidateFolders) {
    if (![fm fileExistsAtPath:folder]) continue;

    // Check _tone3000.json manifest in folder:
    NSString* manifestPath = [folder stringByAppendingPathComponent:@"_tone3000.json"];
    if ([fm fileExistsAtPath:manifestPath]) {
      NSDictionary* manifest = jsonDictionaryAtPath(manifestPath);
      NSArray* downloads = [manifest[@"downloads"] isKindOfClass:NSArray.class] ? manifest[@"downloads"] : nil;
      for (NSDictionary* dl in downloads) {
        if (![dl isKindOfClass:NSDictionary.class]) continue;
        NSString* localFn = [dl[@"local_filename"] isKindOfClass:NSString.class] ? dl[@"local_filename"] : nil;
        if (!localFn.length) continue;
        NSString* modelPath = [folder stringByAppendingPathComponent:localFn];
        if (![fm fileExistsAtPath:modelPath]) continue;

        NSDictionary* orig = [dl[@"original_model"] isKindOfClass:NSDictionary.class] ? dl[@"original_model"] : nil;
        id av = orig[@"architecture_version"];
        NSString* avStr = [av isKindOfClass:NSString.class] ? av : [av respondsToSelector:@selector(stringValue)] ? [av stringValue] : nil;
        if (avStr.length) {
          if ([arch isEqualToString:@"2"] && [avStr isEqualToString:@"2"]) return YES;
          if ([arch isEqualToString:@"1"] && [avStr isEqualToString:@"1"]) return YES;
          if ([arch isEqualToString:@"custom"] && [avStr.lowercaseString isEqualToString:@"custom"]) return YES;
        }

        RigUIState::RigModelArchInfo info = RigUIState::inspectModelArch(modelPath);
        if ([info.category isEqualToString:targetCategory]) {
          return YES;
        }
      }
    }

    // Check directory contents directly:
    NSArray<NSString*>* files = [fm contentsOfDirectoryAtPath:folder error:nil];
    for (NSString* f in files) {
      if ([f hasPrefix:@"."] || [f hasPrefix:@"_"]) continue;
      NSString* ext = f.pathExtension.lowercaseString;
      if ([ext isEqualToString:@"nam"] || [ext isEqualToString:@"nammodel"] ||
          [ext isEqualToString:@"aidax"] || [ext isEqualToString:@"aidadspmodel"]) {
        NSString* fullPath = [folder stringByAppendingPathComponent:f];
        RigUIState::RigModelArchInfo info = RigUIState::inspectModelArch(fullPath);
        if ([info.category isEqualToString:targetCategory]) {
          return YES;
        }
      }
    }
  }

  return NO;
}

- (BOOL)isStageArchitectureAvailable:(size_t)stage arch:(NSString*)arch {
  if (stage >= 2) return NO; // Cabs do not use neural network architectures (A2/A1/Custom)
  ToneItem* item = [self toneItemForStage:stage];
  if (!item || item.toneId <= 0) return NO;

  // 1. If already downloaded on disk, it's definitely available for this profile:
  if ([self isStageArchitectureDownloaded:stage arch:arch]) return YES;

  // 2. Check explicit counts from ToneItem metadata:
  if ([arch isEqualToString:@"2"]) {
    if (item.a2Count > 0) return YES;
  } else if ([arch isEqualToString:@"1"]) {
    if (item.a1Count > 0) return YES;
  } else if ([arch isEqualToString:@"custom"]) {
    if (item.customCount > 0) return YES;
    if ([item.title localizedCaseInsensitiveContainsString:@"Hyper"]) return YES;
  }

  // 3. Check remoteModels if already fetched:
  if (item.remoteModels.count > 0) {
    for (NSDictionary* m in item.remoteModels) {
      if (![m isKindOfClass:NSDictionary.class]) continue;
      id av = m[@"architecture_version"];
      NSString* avStr = [av isKindOfClass:NSString.class] ? av : [av respondsToSelector:@selector(stringValue)] ? [av stringValue] : nil;
      if (avStr.length) {
        if ([arch isEqualToString:@"2"] && [avStr isEqualToString:@"2"]) return YES;
        if ([arch isEqualToString:@"1"] && [avStr isEqualToString:@"1"]) return YES;
        if ([arch isEqualToString:@"custom"] && [avStr.lowercaseString isEqualToString:@"custom"]) return YES;
      }
      NSString* name = [m[@"name"] isKindOfClass:NSString.class] ? [(NSString*)m[@"name"] lowercaseString] : @"";
      if ([arch isEqualToString:@"custom"] && ([name containsString:@"custom"] || [name containsString:@"hyper"])) return YES;
    }
  }

  // 4. Check raw toneData from _tone3000.json or API:
  NSDictionary* td = item.toneData;
  if ([td isKindOfClass:NSDictionary.class]) {
    if ([arch isEqualToString:@"2"] && [td[@"a2_models_count"] respondsToSelector:@selector(integerValue)] && [td[@"a2_models_count"] integerValue] > 0) return YES;
    if ([arch isEqualToString:@"1"] && [td[@"a1_models_count"] respondsToSelector:@selector(integerValue)] && [td[@"a1_models_count"] integerValue] > 0) return YES;
    if ([arch isEqualToString:@"custom"] && [td[@"custom_models_count"] respondsToSelector:@selector(integerValue)] && [td[@"custom_models_count"] integerValue] > 0) return YES;
  }

  // 5. Check _tone3000.json manifest on disk for download entries:
  NSString* curPath = (stage < _state->selectedPaths.size() && !_state->selectedPaths[stage].empty())
      ? [NSString stringWithUTF8String:_state->selectedPaths[stage].c_str()]
      : nil;
  if (curPath.length) {
    NSString* folder = [curPath stringByDeletingLastPathComponent];
    NSString* manifestPath = [folder stringByAppendingPathComponent:@"_tone3000.json"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:manifestPath]) {
      NSDictionary* manifest = jsonDictionaryAtPath(manifestPath);
      NSArray* downloads = [manifest[@"downloads"] isKindOfClass:NSArray.class] ? manifest[@"downloads"] : nil;
      for (NSDictionary* dl in downloads) {
        if (![dl isKindOfClass:NSDictionary.class]) continue;
        NSDictionary* orig = [dl[@"original_model"] isKindOfClass:NSDictionary.class] ? dl[@"original_model"] : nil;
        id av = orig[@"architecture_version"];
        NSString* avStr = [av isKindOfClass:NSString.class] ? av : [av respondsToSelector:@selector(stringValue)] ? [av stringValue] : nil;
        if (avStr.length) {
          if ([arch isEqualToString:@"2"] && [avStr isEqualToString:@"2"]) return YES;
          if ([arch isEqualToString:@"1"] && [avStr isEqualToString:@"1"]) return YES;
          if ([arch isEqualToString:@"custom"] && [avStr.lowercaseString isEqualToString:@"custom"]) return YES;
        }
      }
    }
  }

  return NO;
}

- (void)downloadStageArchitecture:(NSMenuItem*)sender {
  if (!_state) return;
  NSDictionary* dict = [sender.representedObject isKindOfClass:NSDictionary.class] ? sender.representedObject : nil;
  if (!dict) return;
  size_t stage = [dict[@"stage"] unsignedIntegerValue];
  if (stage >= 2) return; // Cabs do not have A2/A1/Custom architectures
  NSString* arch = dict[@"arch"];
  if (!arch.length) return;

  // If already downloaded: NO-OP!
  if ([self isStageArchitectureDownloaded:stage arch:arch]) {
    return;
  }

  ToneItem* item = [self toneItemForStage:stage];
  if (!item || item.toneId <= 0) {
    if (_state->browserController) {
      _state->browserController.status.stringValue = @"Cannot download: capture was not loaded from Tone3000";
    }
    return;
  }

  // Ensure stage matches this target stage so models refresh properly:
  item.stage = (stage == 3) ? 3 : (NSInteger)stage;

  if (!_state->browserController) return;

  if (!_state->browserController.accessToken.length) {
    [_state->browserController connectIfNeeded];
    if (!_state->browserController.accessToken.length) {
      [_state->browserController connectTone3000:nil];
      return;
    }
  }

  [_state->browserController downloadTone:item withArch:arch exact:YES];
}

- (NSMenuItem*)downloadArchitectureMenuItemForStage:(size_t)stage title:(NSString*)menuTitle {
  if (stage >= 2) return nil; // Cabs do not use neural network architectures (A2/A1/Custom)

  BOOL hasModel = (stage < _state->selectedPaths.size() && !_state->selectedPaths[stage].empty());
  if (!hasModel) {
    return nil;
  }

  ToneItem* item = [self toneItemForStage:stage];
  if (!item || item.toneId <= 0) {
    return nil;
  }

  struct ArchOption {
    NSString* archKey;
    NSString* displayName;
    NSInteger modelCount;
  };

  std::vector<ArchOption> options;
  if ([self isStageArchitectureAvailable:stage arch:@"2"]) {
    options.push_back({@"2", @"A2", item.a2Count});
  }
  if ([self isStageArchitectureAvailable:stage arch:@"1"]) {
    options.push_back({@"1", @"A1", item.a1Count});
  }
  if ([self isStageArchitectureAvailable:stage arch:@"custom"]) {
    options.push_back({@"custom", @"Custom", item.customCount});
  }

  if (options.empty()) {
    return nil;
  }

  NSMenuItem* parent = [[NSMenuItem alloc] initWithTitle:menuTitle ?: @"Download Architecture"
                                                  action:NULL
                                           keyEquivalent:@""];
  NSMenu* sub = [[NSMenu alloc] initWithTitle:menuTitle ?: @"Download Architecture"];

  NSInteger undownloadedCount = 0;
  for (const auto& opt : options) {
    BOOL dl = [self isStageArchitectureDownloaded:stage arch:opt.archKey];
    if (!dl) undownloadedCount++;

    NSString* countSuffix = (opt.modelCount > 0)
        ? [NSString stringWithFormat:@" (%ld model%@)", (long)opt.modelCount, opt.modelCount == 1 ? @"" : @"s"]
        : @"";
    NSString* title = dl
        ? [NSString stringWithFormat:@"%@ Architecture%@ (Downloaded)", opt.displayName, countSuffix]
        : [NSString stringWithFormat:@"%@ Architecture%@", opt.displayName, countSuffix];

    NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:title
                                                action:@selector(downloadStageArchitecture:)
                                         keyEquivalent:@""];
    it.target = self;
    it.representedObject = @{ @"stage": @(stage), @"arch": opt.archKey };
    it.state = dl ? NSControlStateValueOn : NSControlStateValueOff;
    it.toolTip = dl
        ? [NSString stringWithFormat:@"%@ architecture is already downloaded for this tone.", opt.displayName]
        : [NSString stringWithFormat:@"Download %@ architecture models for this tone from Tone3000.", opt.displayName];
    [sub addItem:it];
  }

  parent.submenu = sub;
  if (undownloadedCount > 0) {
    parent.toolTip = [NSString stringWithFormat:@"Download alternative architectures for %@ (%ld available to download)",
                      item.title ?: @"this tone", (long)undownloadedCount];
  } else {
    parent.toolTip = [NSString stringWithFormat:@"All available architectures for %@ are already downloaded.",
                      item.title ?: @"this tone"];
  }
  return parent;
}

- (void)menuNeedsUpdate:(NSMenu*)menu {
  [menu removeAllItems];
  if (!_state) return;

  NSInteger stage = -1;
  if ([menu.identifier isEqualToString:@"stage_card_menu_0"]) stage = 0;
  else if ([menu.identifier isEqualToString:@"stage_card_menu_1"]) stage = 1;
  else if ([menu.identifier isEqualToString:@"stage_card_menu_2"]) stage = 2;
  if (stage < 0 || stage > 2) return;

  if (stage < 2) {
    NSMenuItem* loadItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Load %@ Model from Disk…", stageName(stage)]
                                                      action:@selector(chooseModel:)
                                               keyEquivalent:@""];
    loadItem.target = self;
    loadItem.tag = stage;
    [menu addItem:loadItem];

    NSString* curPath = (stage < _state->selectedPaths.size() && !_state->selectedPaths[(size_t)stage].empty())
        ? [NSString stringWithUTF8String:_state->selectedPaths[(size_t)stage].c_str()] : nil;
    NSMenuItem* libItem = [[RigProfileCatalog sharedCatalog] stageCardLibraryMenuItemForStage:(size_t)stage
                                                                                       target:self
                                                                                       action:@selector(selectLibraryModelItem:)
                                                                                  currentPath:curPath];
    if (libItem) {
      [menu addItem:libItem];
    }
    [menu addItem:[NSMenuItem separatorItem]];

    BOOL hasModel = !_state->selectedPaths[(size_t)stage].empty();
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:@"Remove Selection"
                                                  action:@selector(removeStageSelection:)
                                           keyEquivalent:@""];
    item.target = self;
    item.tag = stage;
    item.enabled = hasModel;
    item.toolTip = hasModel
        ? [NSString stringWithFormat:@"Completely remove the selected %@ model.", stageName(stage)]
        : [NSString stringWithFormat:@"No %@ model loaded to remove.", stageName(stage)];
    [menu addItem:item];

    NSMenuItem* archItem = [self downloadArchitectureMenuItemForStage:(size_t)stage title:@"Download Architecture"];
    if (archItem) {
      [menu addItem:[NSMenuItem separatorItem]];
      [menu addItem:archItem];
    }
  } else {
    NSMenuItem* loadCabA = [[NSMenuItem alloc] initWithTitle:@"Load Cab A Model from Disk…"
                                                      action:@selector(chooseModel:)
                                               keyEquivalent:@""];
    loadCabA.target = self;
    loadCabA.tag = 2;
    [menu addItem:loadCabA];

    NSString* curPathA = (!_state->selectedPaths[2].empty())
        ? [NSString stringWithUTF8String:_state->selectedPaths[2].c_str()] : nil;
    NSMenuItem* libCabA = [[RigProfileCatalog sharedCatalog] stageCardLibraryMenuItemForStage:2
                                                                                       target:self
                                                                                       action:@selector(selectLibraryModelItem:)
                                                                                  currentPath:curPathA];
    if (libCabA) {
      [menu addItem:libCabA];
    }

    NSMenuItem* loadCabB = [[NSMenuItem alloc] initWithTitle:@"Load Cab B Model from Disk…"
                                                      action:@selector(chooseModel:)
                                               keyEquivalent:@""];
    loadCabB.target = self;
    loadCabB.tag = 3;
    [menu addItem:loadCabB];

    NSString* curPathB = (!_state->selectedPaths[3].empty())
        ? [NSString stringWithUTF8String:_state->selectedPaths[3].c_str()] : nil;
    NSMenuItem* libCabB = [[RigProfileCatalog sharedCatalog] stageCardLibraryMenuItemForStage:3
                                                                                       target:self
                                                                                       action:@selector(selectLibraryModelItem:)
                                                                                  currentPath:curPathB];
    if (libCabB) {
      [menu addItem:libCabB];
    }
    [menu addItem:[NSMenuItem separatorItem]];

    BOOL hasCabA = !_state->selectedPaths[2].empty();
    BOOL hasCabB = !_state->selectedPaths[3].empty();

    if (!hasCabB) {
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:@"Remove Selection"
                                                    action:@selector(removeStageSelection:)
                                             keyEquivalent:@""];
      item.target = self;
      item.tag = 2;
      item.enabled = hasCabA;
      item.toolTip = hasCabA
          ? @"Completely remove the selected cabinet model or impulse response."
          : @"No cabinet model or IR loaded to remove.";
      [menu addItem:item];
    } else {
      NSMenuItem* itemA = [[NSMenuItem alloc] initWithTitle:@"Remove Selection"
                                                     action:@selector(removeStageSelection:)
                                              keyEquivalent:@""];
      itemA.target = self;
      itemA.tag = 2;
      itemA.enabled = hasCabA;
      itemA.toolTip = hasCabA
          ? @"Completely remove Cabinet A model or impulse response."
          : @"No Cabinet A model or IR loaded to remove.";
      [menu addItem:itemA];

      NSMenuItem* itemB = [[NSMenuItem alloc] initWithTitle:@"Remove Cab B Selection"
                                                     action:@selector(removeStageSelection:)
                                              keyEquivalent:@""];
      itemB.target = self;
      itemB.tag = 3;
      itemB.enabled = hasCabB;
      itemB.toolTip = hasCabB
          ? @"Completely remove Cabinet B model or impulse response."
          : @"No Cabinet B model or IR loaded to remove.";
      [menu addItem:itemB];

      [menu addItem:[NSMenuItem separatorItem]];

      NSMenuItem* itemBoth = [[NSMenuItem alloc] initWithTitle:@"Remove Both Selections"
                                                        action:@selector(removeBothCabsSelection:)
                                                 keyEquivalent:@""];
      itemBoth.target = self;
      itemBoth.tag = 2;
      itemBoth.enabled = hasCabA || hasCabB;
      itemBoth.toolTip = @"Completely remove both Cabinet A and Cabinet B selections.";
      [menu addItem:itemBoth];
    }
  }
}

- (void)menuWillOpen:(NSMenu*)menu {
  if (_state && _state->presetManager &&
      ((_state->presetPopup && menu == _state->presetPopup.menu) ||
       (_state->abPresetB && menu == _state->abPresetB.menu) ||
       [menu.identifier isEqualToString:@"preset_popup_menu"] ||
       [menu.identifier isEqualToString:@"ab_popup_menu"])) {
    [_state->presetManager rescanPresets];
    _state->rebuildPresetMenu();
  }
}

- (void)controlChanged:(NSControl*)sender {
  if (!_state) return;
  const float value = [sender isKindOfClass:NSButton.class]
      ? (((NSButton*)sender).state == NSControlStateValueOn ? 1.0f : 0.0f)
      : sender.floatValue;
  // A manual Output change while tuner-muted takes over from the saved level.
  if (sender.tag == 5) _state->tunerMuted = false;
  if (sender.tag == 47) {
    [self selectStageCard:3];
  }
  _state->sendControl((uint32_t)sender.tag, value);
  _state->updateControl((uint32_t)sender.tag, value);
  [self markPresetModified];
}

// Delegate: track which knob value box the user is editing so live knob/host
// updates don't overwrite the text they're typing.
- (void)controlTextDidBeginEditing:(NSNotification*)obj {
  if (!_state) return;
  NSTextField* f = obj.object;
  if (![f isKindOfClass:[NSTextField class]]) return;
  for (size_t i = 0; i < NAMRig::kTransformerControlCount; ++i)
    if (_state->transformerFields[i] == f) _state->transformerFieldEditing[i] = true;
  for (size_t k = 0; k < kRigKnobCount; ++k) {
    if (_state->valueLabels[k] == f) _state->knobFieldEditing[k] = true;
    if (_state->deckValueLabels[k] == f) _state->deckKnobFieldEditing[k] = true;
  }
}
- (void)controlTextDidEndEditing:(NSNotification*)obj {
  if (obj.object == self.copilotModelComboBox) { [self updateCopilotAudioControls]; return; }
  if (obj.object == self.copilotKeyField || obj.object == self.copilotURLField) {
    [self updateCopilotAudioControls];
    [self refreshCopilotModelsUI];
    return;
  }
  if (!_state) return;
  NSTextField* f = obj.object;
  if (![f isKindOfClass:[NSTextField class]]) return;
  for (size_t i = 0; i < NAMRig::kTransformerControlCount; ++i) {
    if (_state->transformerFields[i] != f) continue;
    _state->transformerFieldEditing[i] = false;
    [self transformerControlChanged:f];
    return;
  }
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
  // Enter can invoke the delegate and action; do not reparse rounded display text.
  if ([sender.stringValue isEqualToString:rigKnobValueText((uint32_t)port, knob.floatValue)]) return;

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
  if (!std::isfinite(v)) {
    _state->updateControl((uint32_t)port, knob.floatValue);
    return;
  }
  double clamped = v;
  if (clamped < knob.minValue) clamped = knob.minValue;
  if (clamped > knob.maxValue) clamped = knob.maxValue;
  knob.doubleValue = clamped;
  if (port == 5) _state->tunerMuted = false;
  _state->sendControl((uint32_t)port, (float)clamped);
  _state->updateControl((uint32_t)port, (float)clamped);
  [self markPresetModified];
  if ([sender.window.firstResponder isKindOfClass:[NSText class]]) {
    [sender.window makeFirstResponder:nil];
  }
}

// Tuner on/off: drives the tuner_enable port and updates active button state.
// If muteOnTune is active, temporarily silences output while tuning.
- (void)tunerToggled:(NSButton*)sender {
  if (!_state) return;
  const BOOL on = sender.state == NSControlStateValueOn;
  _state->sendControl(16, on ? 1.0f : 0.0f);
  sender.contentTintColor = on ? rigText() : rigDimText();
  if ([sender respondsToSelector:@selector(setPrimary:)]) {
    ((RigButton*)sender).primary = on;
  }
  sender.needsDisplay = YES;
  if (on) {
    if (_state->muteOnTune) _state->muteOutputForTuner();
  } else {
    _state->restoreOutputAfterTuner();
    if (_state->tunerNoteLabel) {
      _state->tunerNoteLabel.stringValue = @"—";
      _state->tunerNoteLabel.textColor = rigText();
    }
    if (_state->tunerCentsLabel) {
      _state->tunerCentsLabel.stringValue = @"BYPASSED";
      _state->tunerCentsLabel.textColor = rigDimText();
    }
    if (_state->tunerNeedle) {
      _state->tunerNeedle.hidden = YES;
    }
  }
}

// Per-stage oversample control (pedal/amp tiles): ports 20/21, five visible
// modes mapped onto the sparse LV2 values 0, 4, 5, 6, 7.
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
  _state->sendControl(24, sender.indexOfSelectedItem == 0 ? 1.0f : 2.0f);
  [self markPresetModified];
}

- (void)transformerChanged:(NSPopUpButton*)sender {
  sender.toolTip = sender.selectedItem.toolTip;
  if (!_state) return;
  const float val = (float)sender.indexOfSelectedItem;
  _state->sendControl(30, val);
  _state->updateControl(30, val);
  [self resetTransformerControls:sender];
}

- (void)powerTubeChanged:(NSPopUpButton*)sender {
  if (!_state) return;
  const float profile = (float)sender.indexOfSelectedItem;
  _state->sendControl(NAMRig::kPowerTubeTypePort, profile);
  _state->updateControl(NAMRig::kPowerTubeTypePort, profile);
  [self markPresetModified];
}

- (void)applyPowerTubePreset:(NSButton*)sender {
  if (!_state || sender.tag < 0 || sender.tag >= NAMRig::PowerTube::kProfileCount) return;
  _state->sendControl(NAMRig::kPowerTubeTypePort, (float)sender.tag);
  _state->updateControl(NAMRig::kPowerTubeTypePort, (float)sender.tag);
  _state->sendControl(NAMRig::kPowerTubeCharacterPort, NAMRig::kPowerTubeCharacterDefault);
  _state->updateControl(NAMRig::kPowerTubeCharacterPort, NAMRig::kPowerTubeCharacterDefault);
  [self markPresetModified];
}

- (void)resetTransformerControls:(id)sender {
  (void)sender;
  if (!_state) return;
  _state->cancelTransformerEditing();
  for (size_t i = 0; i < NAMRig::kTransformerControlCount; ++i) {
    const uint32_t port = NAMRig::kTransformerControlFirstPort + i;
    _state->sendControl(port, NAMRig::kTransformerControlDefaults[i]);
    _state->updateControl(port, NAMRig::kTransformerControlDefaults[i]);
  }
  [self markPresetModified];
}

- (void)transformerControlChanged:(NSControl*)sender {
  if (!_state || _state->transformerProfile == 0) return;
  const NSInteger index = sender.tag - NAMRig::kTransformerControlFirstPort;
  if (index < 0 || index >= (NSInteger)NAMRig::kTransformerControlCount) return;
  const auto& c = NAMRig::kTransformerControls[index];
  const auto range = _state->transformerControlRange(index);
  double value;
  const bool field = [sender isKindOfClass:NSTextField.class];
  if (field) {
    NSScanner* scanner = [NSScanner scannerWithString:sender.stringValue];
    if (![scanner scanDouble:&value] || !std::isfinite(value)) {
      _state->transformerFieldEditing[index] = false;
      _state->updateTransformerTelemetry(_state->transformerProfile);
      return;
    }
    NSString* suffix = [[sender.stringValue substringFromIndex:scanner.scanLocation]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString* unit = (index == 6 || index == 9) ? @"dB"
        : index == 3 ? @"%" : index == 2 ? @"x"
        : (index == 7 || index == 10) ? @"" : @"Hz";
    if (suffix.length && [suffix caseInsensitiveCompare:unit] != NSOrderedSame) {
      _state->transformerFieldEditing[index] = false;
      _state->updateTransformerTelemetry(_state->transformerProfile);
      return;
    }
    const auto current = NAMRig::OutputTransformer::controlValues(
        NAMRig::OutputTransformer::parametersForProfile(_state->transformerProfile,
                                                       _state->transformerAdjustments));
    // Enter followed by focus loss must not re-commit a rounded display value.
    if ([sender.stringValue isEqualToString:RigUIState::transformerValueText(index, current[index])]) {
      _state->transformerFieldEditing[index] = false;
      return;
    }
  } else {
    value = c.logarithmic ? std::exp(sender.doubleValue) : sender.doubleValue;
  }
  value = std::clamp(value, (double)range[0], (double)range[1]);
  const auto base = NAMRig::OutputTransformer::controlValues(
      NAMRig::OutputTransformer::parametersForProfile(_state->transformerProfile));
  const float trim = c.defaultValue == 1.0f ? value / base[index] : value - base[index];
  const uint32_t port = NAMRig::kTransformerControlFirstPort + index;
  if (field) _state->transformerFieldEditing[index] = false;
  if (std::fabs(trim - _state->transformerAdjustments[index]) > 1.0e-6f) {
    _state->sendControl(port, trim);
    _state->updateControl(port, trim);
    [self markPresetModified];
  } else {
    _state->updateTransformerTelemetry(_state->transformerProfile);
  }
}

- (void)showTransformerControls:(NSButton*)sender {
  if (!_state) return;
  [_state->transformerPopover close];
  _state->transformerSliders.fill(nil);
  _state->transformerFields.fill(nil);
  _state->transformerFieldEditing.fill(false);
  const size_t starts[] = {0, 2, 5, 8};
  const size_t counts[] = {2, 3, 3, 3};
  const NSInteger group = sender.tag;
  if (group < 0 || group > 3) return;
  NSArray<NSString*>* titles = @[@"Passband", @"Core Flux", @"Voice Peak", @"Leakage Resonance"];
  NSArray<NSString*>* names = @[@"Low Cut", @"High Cut", @"Core Drive", @"Saturation Mix", @"Flux Frequency",
                                @"Voice Frequency", @"Voice Gain", @"Voice Q",
                                @"Leakage Frequency", @"Leakage Gain", @"Leakage Q"];
  NSArray<NSString*>* descriptions = @[
    @"Low-frequency bandwidth limit. Higher values tighten bass before core saturation.",
    @"High-frequency bandwidth limit. Lower values soften the top end.",
    @"Drive into the magnetic core. Higher values saturate earlier, especially on low notes.",
    @"Blend of the saturated core-voltage path with the linear path.",
    @"Frequency of the leaky flux integrator. Sets the core's low-frequency saturation behavior.",
    @"Center frequency of the transformer voicing bell.", @"Boost or cut of the voicing bell.",
    @"Voicing bandwidth. Higher Q makes a narrower peak.",
    @"Center frequency of the winding leakage resonance.", @"Boost or cut of the leakage resonance.",
    @"Leakage resonance bandwidth. Higher Q makes a narrower peak."
  ];
  const CGFloat height = 106 + counts[group] * 44;
  RigPanel* content = [[RigPanel alloc] initWithFrame:NSMakeRect(0, 0, 390, height)];
  NSTextField* heading = [NSTextField labelWithString:titles[group]];
  heading.frame = NSMakeRect(16, height - 34, 350, 20);
  heading.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  heading.textColor = rigText();
  [content addSubview:heading];
  NSTextField* hint = [NSTextField labelWithString:_state->transformerProfile == 0
      ? @"Select an iron core model to enable these controls."
      : @"Drag a slider or enter a value. Edits are saved with your rig."];
  hint.frame = NSMakeRect(16, height - 54, 358, 17);
  hint.font = [NSFont systemFontOfSize:10];
  hint.textColor = rigDimText();
  [content addSubview:hint];
  for (size_t row = 0; row < counts[group]; ++row) {
    const size_t i = starts[group] + row;
    const CGFloat y = height - 90 - row * 44;
    NSTextField* label = [NSTextField labelWithString:names[i]];
    label.frame = NSMakeRect(16, y + 6, 112, 17);
    label.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    label.textColor = rigDimText();
    label.toolTip = descriptions[i];
    [content addSubview:label];
    NSSlider* slider = [[NSSlider alloc] initWithFrame:NSMakeRect(128, y, 140, 28)];
    slider.controlSize = NSControlSizeSmall;
    slider.continuous = YES;
    slider.tag = NAMRig::kTransformerControlFirstPort + i;
    slider.target = self;
    slider.action = @selector(transformerControlChanged:);
    slider.toolTip = descriptions[i];
    [content addSubview:slider];
    _state->transformerSliders[i] = slider;
    NSTextField* field = [[NSTextField alloc] initWithFrame:NSMakeRect(280, y + 4, 94, 22)];
    field.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    field.textColor = rigText();
    field.backgroundColor = rigRaised();
    field.focusRingType = NSFocusRingTypeNone;
    field.alignment = NSTextAlignmentCenter;
    field.tag = slider.tag;
    field.delegate = self;
    field.target = self;
    field.action = @selector(transformerControlChanged:);
    field.toolTip = descriptions[i];
    [content addSubview:field];
    _state->transformerFields[i] = field;
  }
  NSButton* reset = [NSButton buttonWithTitle:@"Reset Model Tweaks" target:self action:@selector(resetTransformerControls:)];
  reset.frame = NSMakeRect(16, 12, 160, 26);
  reset.controlSize = NSControlSizeSmall;
  reset.toolTip = @"Restore all four transformer sections to the selected factory model.";
  [content addSubview:reset];
  NSViewController* controller = [[NSViewController alloc] init];
  controller.view = content;
  NSPopover* popover = [[NSPopover alloc] init];
  popover.contentViewController = controller;
  popover.behavior = NSPopoverBehaviorTransient;
  popover.contentSize = content.frame.size;
  _state->transformerPopover = popover;
  _state->updateTransformerTelemetry(_state->transformerProfile);
  [popover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMaxY];
}

- (void)showAmpAdvanced:(NSButton*)sender {
  (void)sender;
  if (!_state) return;
  _state->selectDeckTab(2);  // Switch to POWER STAGE in Lower Studio Deck
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
  _state->selectDeckTab(3);  // Switch to CAB LAB & SPEAKER in Lower Studio Deck
}

- (void)showEffects:(NSButton*)sender {
  (void)sender;
  if (!_state) return;
  _state->selectDeckTab(4);  // Switch to POST-FX STUDIO in Lower Studio Deck
}

- (void)resetAllKnobs:(id)sender {
  (void)sender;
  if (!_state) return;
  for (size_t k = 0; k < kRigKnobCount; ++k) {
    _state->sendControl(kRigKnobPorts[k], kRigKnobDefaults[k]);
    _state->updateControl(kRigKnobPorts[k], kRigKnobDefaults[k]);
  }
  _state->sendControl(59, 0.0f);
  _state->updateControl(59, 0.0f);
  _state->sendControl(NAMRig::kPowerTubeTypePort, 0.0f);
  _state->updateControl(NAMRig::kPowerTubeTypePort, 0.0f);
  for (size_t i = 0; i < NAMRig::kRackCount; ++i) {
    const uint32_t port = NAMRig::kRackControlFirstPort + i;
    _state->sendControl(port, NAMRig::kRackControlDefaults[i]);
    _state->updateControl(port, NAMRig::kRackControlDefaults[i]);
  }
  _state->sendControl(NAMRig::kPostCompressorEnabledPort, 1.0f);
  _state->updateControl(NAMRig::kPostCompressorEnabledPort, 1.0f);
  [self resetTransformerControls:sender];
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

- (void)applyCompressorPreset:(NSButton*)sender {
  if (!_state) return;
  struct CompPreset { float amount, attack, releaseTime; };
  const CompPreset presets[] = {
    {40.0f, 15.0f, 200.0f},  // SMOOTH SUSTAIN
    {50.0f, 30.0f, 80.0f},   // PUNCHY ATTACK
    {65.0f, 2.0f, 60.0f},    // FAST SQUASH
    {25.0f, 10.0f, 150.0f},  // TRANSPARENT
    {0.0f, 8.0f, 120.0f},    // OFF / BYPASS
    // High-gain captures already compress: use modest amount/makeup and let
    // the pick transient through before leveling the body of the note.
    {22.0f, 35.0f, 70.0f},   // METAL PICK CLARITY
    {28.0f, 25.0f, 50.0f},   // SHRED DEFINITION
    {18.0f, 20.0f, 45.0f},   // THRASH PRECISION
    {32.0f, 30.0f, 140.0f}   // SINGING METAL LEAD
  };
  const NSInteger presetCount = sizeof(presets) / sizeof(presets[0]);
  if (sender.tag >= 0 && sender.tag < presetCount) {
    const auto& p = presets[sender.tag];
    _state->sendControl(28, p.amount); _state->updateControl(28, p.amount);
    _state->sendControl(NAMRig::kCompressorAttackPort, p.attack);
    _state->updateControl(NAMRig::kCompressorAttackPort, p.attack);
    _state->sendControl(NAMRig::kCompressorReleasePort, p.releaseTime);
    _state->updateControl(NAMRig::kCompressorReleasePort, p.releaseTime);
    const float enabled = p.amount > 0.0f ? 1.0f : 0.0f;
    _state->sendControl(NAMRig::kCompressorEnabledPort, enabled);
    _state->updateControl(NAMRig::kCompressorEnabledPort, enabled);
    [self markPresetModified];
  }
}

- (void)sculptPageClicked:(NSButton*)sender {
  if (_state) _state->setSculptPage(sender.tag == 1);
}

- (void)applyPostCompressorPreset:(NSButton*)sender {
  if (!_state) return;
  const float presets[][3] = {
    {0.0f, 8.0f, 120.0f},    // OFF / BYPASS
    {25.0f, 20.0f, 150.0f},  // STUDIO GLUE
    {40.0f, 30.0f, 80.0f},   // PUNCHY ATTACK
    {45.0f, 12.0f, 200.0f},  // SMOOTH LEAD
    {65.0f, 2.0f, 60.0f}     // PEAK CONTROL
  };
  if (sender.tag < 0 || sender.tag >= 5) return;
  for (uint32_t i = 0; i < 3; ++i) {
    const uint32_t port = NAMRig::kPostCompressorFirstPort + i;
    _state->sendControl(port, presets[sender.tag][i]);
    _state->updateControl(port, presets[sender.tag][i]);
  }
  const float enabled = sender.tag == 0 ? 0.0f : 1.0f;
  _state->sendControl(NAMRig::kPostCompressorEnabledPort, enabled);
  _state->updateControl(NAMRig::kPostCompressorEnabledPort, enabled);
  [self markPresetModified];
}

- (void)applySculptPreset:(NSButton*)sender {
  if (!_state) return;
  struct SculptPreset { float bright, inputEq, midPush; };
  const SculptPreset presets[] = {
    {6.0f, 0.0f, 0.0f},    // LEAD BOOST
    {3.0f, 75.0f, 0.0f},   // TIGHT CHUG
    {0.0f, 60.0f, 70.0f},  // MID PUSH
    {5.0f, 30.0f, 40.0f},  // BRIGHT & OPEN
    {0.0f, 0.0f, 0.0f}     // FLAT
  };
  if (sender.tag >= 0 && sender.tag < 5) {
    const auto& p = presets[sender.tag];
    _state->sendControl(39, p.bright); _state->updateControl(39, p.bright);
    _state->sendControl(40, p.inputEq); _state->updateControl(40, p.inputEq);
    _state->sendControl(NAMRig::kMidPushPort, p.midPush);
    _state->updateControl(NAMRig::kMidPushPort, p.midPush);
    [self markPresetModified];
  }
}

- (void)boostVoicingChanged:(NSPopUpButton*)sender {
  if (!_state) return;
  const float val = (float)sender.indexOfSelectedItem;
  _state->sendControl(NAMRig::kOverdriveVoicingPort, val);
  _state->updateControl(NAMRig::kOverdriveVoicingPort, val);
  [self markPresetModified];
}

- (void)applyBoostPreset:(NSButton*)sender {
  if (!_state) return;
  struct BoostPreset { float drive, tight, tone, level, voicing; };
  const BoostPreset presets[] = {
    {0.0f, 720.0f, 50.0f, 6.0f, 2.0f},   // CLEAN BOOST (LED Turbo)
    {35.0f, 720.0f, 55.0f, 2.0f, 0.0f},  // TS9 DRIVE (Classic TS)
    {60.0f, 850.0f, 65.0f, 4.0f, 1.0f},  // LEAD PUSH (SD-1 Asym)
    {15.0f, 1200.0f, 70.0f, 3.0f, 0.0f}, // TIGHT CHUG (Classic TS)
    {45.0f, 350.0f, 40.0f, 0.0f, 3.0f}   // WARM OVERDRIVE (Germanium)
  };
  if (sender.tag >= 0 && sender.tag < 5) {
    const auto& p = presets[sender.tag];
    _state->sendControl(NAMRig::kOverdriveDrivePort, p.drive);
    _state->updateControl(NAMRig::kOverdriveDrivePort, p.drive);
    _state->sendControl(NAMRig::kOverdriveTightPort, p.tight);
    _state->updateControl(NAMRig::kOverdriveTightPort, p.tight);
    _state->sendControl(NAMRig::kOverdriveTonePort, p.tone);
    _state->updateControl(NAMRig::kOverdriveTonePort, p.tone);
    _state->sendControl(NAMRig::kOverdriveLevelPort, p.level);
    _state->updateControl(NAMRig::kOverdriveLevelPort, p.level);
    _state->sendControl(NAMRig::kOverdriveVoicingPort, p.voicing);
    _state->updateControl(NAMRig::kOverdriveVoicingPort, p.voicing);
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
  if (sender.tag >= 0 && sender.tag < NAMRig::OutputTransformer::kProfileCount) {
    int transIdx = (int)sender.tag;
    _state->sendControl(30, (float)transIdx);
    _state->updateControl(30, (float)transIdx);
    [self resetTransformerControls:sender];
  }
}

- (void)slotPresetPopupChanged:(NSPopUpButton*)sender {
  if (!_state) return;
  _state->ensureSlotPresetStorage();
  const NSInteger slotIdx = sender.tag;
  if (slotIdx < 0 || slotIdx >= (NSInteger)_state->deckSlotSpecs.count) return;
  NSMutableDictionary* spec = _state->deckSlotSpecs[(NSUInteger)slotIdx];
  NSMenuItem* item = sender.selectedItem;
  if (![item.representedObject isKindOfClass:[NSDictionary class]]) {
    _state->resyncSlotPresetPopup(slotIdx);
    return;
  }
  NSDictionary* rep = (NSDictionary*)item.representedObject;
  NSString* type = rep[@"type"];
  NSString* title = rep[@"title"] ?: item.title;

  if ([type isEqualToString:@"factory"]) {
    spec[@"selectedTitle"] = title;
    spec[@"selectedIsUser"] = @NO;
    _state->rebuildSlotPresetMenu(slotIdx);
    NSInteger presetIdx = [rep[@"index"] integerValue];
    NSString* selName = spec[@"legacyAction"];
    if (selName.length) {
      SEL sel = NSSelectorFromString(selName);
      if ([self respondsToSelector:sel]) {
        NSButton* dummy = [[NSButton alloc] initWithFrame:NSZeroRect];
        dummy.tag = presetIdx;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:sel withObject:dummy];
#pragma clang diagnostic pop
      }
    }
  } else if ([type isEqualToString:@"user"]) {
    spec[@"selectedTitle"] = title;
    spec[@"selectedIsUser"] = @YES;
    _state->rebuildSlotPresetMenu(slotIdx);
    NSDictionary* values = rep[@"values"];
    if ([values isKindOfClass:[NSDictionary class]]) {
      // Existing transformer slot presets stored only the model selector.
      if ([spec[@"key"] isEqualToString:@"transformer"])
        [self resetTransformerControls:sender];
      // Sculpt presets saved before Mid Push existed recall it as OFF.
      NSString* midPushKey = [NSString stringWithFormat:@"%u", NAMRig::kMidPushPort];
      if ([spec[@"key"] isEqualToString:@"sculpt"] && !values[midPushKey]) {
        _state->sendControl(NAMRig::kMidPushPort, 0.0f);
        _state->updateControl(NAMRig::kMidPushPort, 0.0f);
      }
      // Slot presets saved before graph pins existed recall with no pins.
      for (NSNumber* pNum in spec[@"ports"]) {
        const uint32_t port = pNum.unsignedIntValue;
        if (!NAMRig::isPinEqPort(port) || values[pNum.stringValue]) continue;
        _state->sendControl(port, NAMRig::pinEqDefault(port));
        _state->updateControl(port, NAMRig::pinEqDefault(port));
      }
      NSSet<NSNumber*>* allowedPorts = [NSSet setWithArray:spec[@"ports"] ?: @[]];
      for (id portKey in values) {
        if (![portKey isKindOfClass:[NSString class]]) continue;
        id valObj = values[portKey];
        if (![valObj respondsToSelector:@selector(floatValue)]) continue;
        const uint32_t port = (uint32_t)[(NSString*)portKey integerValue];
        if (![allowedPorts containsObject:@(port)]) continue;
        const float val = [valObj floatValue];
        _state->sendControl(port, val);
        _state->updateControl(port, val);
      }
      NSNumber* enabledPort = spec[@"enabledPort"];
      if (enabledPort && !values[enabledPort.stringValue]) {
        // Slot presets saved before rack switches existed default to enabled.
        _state->sendControl(enabledPort.unsignedIntValue, 1.0f);
        _state->updateControl(enabledPort.unsignedIntValue, 1.0f);
      }
      [self markPresetModified];
    }
  } else {
    _state->resyncSlotPresetPopup(slotIdx);
  }
}

- (void)saveSlotPreset:(NSMenuItem*)sender {
  if (!_state) return;
  _state->ensureSlotPresetStorage();
  const NSInteger slotIdx = sender.tag;
  if (slotIdx < 0 || slotIdx >= (NSInteger)_state->deckSlotSpecs.count) return;
  NSMutableDictionary* spec = _state->deckSlotSpecs[(NSUInteger)slotIdx];
  BOOL isUser = [spec[@"selectedIsUser"] boolValue];
  NSString* curTitle = spec[@"selectedTitle"];
  if (!isUser || !curTitle.length) {
    [self saveSlotPresetAs:sender];
    return;
  }
  NSString* slotKey = spec[@"key"] ?: @"";
  if (!slotKey.length) return;
  NSMutableDictionary* userMap = _state->userSlotPresets[slotKey];
  if (!userMap) {
    userMap = [NSMutableDictionary dictionary];
    _state->userSlotPresets[slotKey] = userMap;
  }
  NSDictionary* captured = _state->captureSlotPortValues(slotIdx);
  userMap[curTitle] = captured;
  _state->saveUserSlotPresetsToDisk();
  _state->rebuildSlotPresetMenu(slotIdx);
  if (_state->presetManager) {
    [_state->presetManager propagateSlotValues:captured
                                       slotKey:slotKey
                                slotPresetName:curTitle
                                         error:nil];
    _state->presetManager.isModified = NO;
    _state->abModifiedPreset = nil;
    _state->updatePresetDisplayTitle();
  }
}

- (void)saveSlotPresetAs:(NSMenuItem*)sender {
  if (!_state) return;
  _state->ensureSlotPresetStorage();
  const NSInteger slotIdx = sender.tag;
  if (slotIdx < 0 || slotIdx >= (NSInteger)_state->deckSlotSpecs.count) return;
  NSMutableDictionary* spec = _state->deckSlotSpecs[(NSUInteger)slotIdx];
  NSString* slotKey = spec[@"key"] ?: @"";
  NSString* slotTitle = spec[@"title"] ?: @"Slot";
  NSString* curTitle = spec[@"selectedTitle"] ?: @"Custom";

  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = [NSString stringWithFormat:@"Save %@ Preset", slotTitle];
  alert.informativeText = @"Enter a name for this preset:";
  [alert addButtonWithTitle:@"Save"];
  [alert addButtonWithTitle:@"Cancel"];

  RigAlertTextField* input = [[RigAlertTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  BOOL isUser = [spec[@"selectedIsUser"] boolValue];
  input.stringValue = isUser
      ? curTitle
      : [NSString stringWithFormat:@"My %@", curTitle];
  alert.accessoryView = input;
  [alert.window setInitialFirstResponder:input];
  [input selectText:nil];

  if ([alert runModal] == NSAlertFirstButtonReturn) {
    NSString* name = [input.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) {
      _state->resyncSlotPresetPopup(slotIdx);
      return;
    }
    NSMutableDictionary* userMap = _state->userSlotPresets[slotKey];
    if (!userMap) {
      userMap = [NSMutableDictionary dictionary];
      _state->userSlotPresets[slotKey] = userMap;
    }
    NSDictionary* captured = _state->captureSlotPortValues(slotIdx);
    userMap[name] = captured;
    spec[@"selectedTitle"] = name;
    spec[@"selectedIsUser"] = @YES;
    _state->saveUserSlotPresetsToDisk();
    _state->rebuildSlotPresetMenu(slotIdx);
    if (_state->presetManager) {
      [_state->presetManager propagateSlotValues:captured
                                         slotKey:slotKey
                                  slotPresetName:name
                                           error:nil];
      _state->presetManager.isModified = NO;
      _state->abModifiedPreset = nil;
      _state->updatePresetDisplayTitle();
    }
  } else {
    _state->resyncSlotPresetPopup(slotIdx);
  }
}

- (void)renameSlotPreset:(NSMenuItem*)sender {
  if (!_state) return;
  _state->ensureSlotPresetStorage();
  const NSInteger slotIdx = sender.tag;
  if (slotIdx < 0 || slotIdx >= (NSInteger)_state->deckSlotSpecs.count) return;
  NSMutableDictionary* spec = _state->deckSlotSpecs[(NSUInteger)slotIdx];
  BOOL isUser = [spec[@"selectedIsUser"] boolValue];
  NSString* curTitle = spec[@"selectedTitle"];
  NSString* slotKey = spec[@"key"] ?: @"";
  NSString* slotTitle = spec[@"title"] ?: @"Slot";
  if (!isUser || !curTitle.length || !slotKey.length) {
    _state->resyncSlotPresetPopup(slotIdx);
    return;
  }

  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = [NSString stringWithFormat:@"Rename %@ Preset", slotTitle];
  alert.informativeText = @"Enter a new name for this preset:";
  [alert addButtonWithTitle:@"Rename"];
  [alert addButtonWithTitle:@"Cancel"];

  RigAlertTextField* input = [[RigAlertTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  input.stringValue = curTitle;
  alert.accessoryView = input;
  [alert.window setInitialFirstResponder:input];
  [input selectText:nil];

  if ([alert runModal] == NSAlertFirstButtonReturn) {
    NSString* newName = [input.stringValue stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!newName.length || [newName isEqualToString:curTitle]) {
      _state->resyncSlotPresetPopup(slotIdx);
      return;
    }

    NSMutableDictionary* userMap = _state->userSlotPresets[slotKey];
    if (!userMap) {
      userMap = [NSMutableDictionary dictionary];
      _state->userSlotPresets[slotKey] = userMap;
    }

    if (userMap[newName] && ![newName isEqualToString:curTitle]) {
      NSAlert* fail = [[NSAlert alloc] init];
      fail.messageText = @"Preset Already Exists";
      fail.informativeText = [NSString stringWithFormat:@"A preset named '%@' already exists for %@.", newName, slotTitle];
      [fail runModal];
      _state->resyncSlotPresetPopup(slotIdx);
      return;
    }

    NSArray<NSString*>* factoryTitles = spec[@"factoryTitles"] ?: @[];
    if ([factoryTitles containsObject:newName]) {
      NSAlert* fail = [[NSAlert alloc] init];
      fail.messageText = @"Reserved Name";
      fail.informativeText = [NSString stringWithFormat:@"'%@' is a factory preset name. Please choose a different name.", newName];
      [fail runModal];
      _state->resyncSlotPresetPopup(slotIdx);
      return;
    }

    NSDictionary<NSString*, NSNumber*>* values = userMap[curTitle];
    if (!values) {
      values = _state->captureSlotPortValues(slotIdx);
    }
    userMap[newName] = values;
    [userMap removeObjectForKey:curTitle];

    spec[@"selectedTitle"] = newName;
    spec[@"selectedIsUser"] = @YES;
    _state->saveUserSlotPresetsToDisk();
    _state->rebuildSlotPresetMenu(slotIdx);
    if (_state->presetManager) {
      [_state->presetManager renameSlotPresetInAllPresetsFrom:curTitle
                                                          to:newName
                                                     slotKey:slotKey];
    }
  } else {
    _state->resyncSlotPresetPopup(slotIdx);
  }
}

- (void)deleteSlotPreset:(NSMenuItem*)sender {
  if (!_state) return;
  _state->ensureSlotPresetStorage();
  const NSInteger slotIdx = sender.tag;
  if (slotIdx < 0 || slotIdx >= (NSInteger)_state->deckSlotSpecs.count) return;
  NSMutableDictionary* spec = _state->deckSlotSpecs[(NSUInteger)slotIdx];
  BOOL isUser = [spec[@"selectedIsUser"] boolValue];
  NSString* curTitle = spec[@"selectedTitle"];
  NSString* slotKey = spec[@"key"] ?: @"";
  if (!isUser || !curTitle.length || !slotKey.length) {
    _state->resyncSlotPresetPopup(slotIdx);
    return;
  }

  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"Delete Slot Preset";
  alert.informativeText = [NSString stringWithFormat:@"Are you sure you want to delete '%@'?", curTitle];
  alert.alertStyle = NSAlertStyleCritical;
  [alert addButtonWithTitle:@"Delete"];
  [alert addButtonWithTitle:@"Cancel"];

  if ([alert runModal] == NSAlertFirstButtonReturn) {
    NSMutableDictionary* userMap = _state->userSlotPresets[slotKey];
    [userMap removeObjectForKey:curTitle];
    NSArray<NSString*>* factoryTitles = spec[@"factoryTitles"] ?: @[];
    spec[@"selectedTitle"] = factoryTitles.firstObject ?: @"";
    spec[@"selectedIsUser"] = @NO;
    _state->saveUserSlotPresetsToDisk();
    _state->rebuildSlotPresetMenu(slotIdx);
    if (_state->presetManager) {
      [_state->presetManager deleteSlotPresetInAllPresetsNamed:curTitle
                                                       slotKey:slotKey];
    }
  } else {
    _state->resyncSlotPresetPopup(slotIdx);
  }
}

- (void)propagateSlotPresetToAll:(NSMenuItem*)sender {
  if (!_state || !_state->presetManager) return;
  _state->ensureSlotPresetStorage();
  const NSInteger slotIdx = sender.tag;
  if (slotIdx < 0 || slotIdx >= (NSInteger)_state->deckSlotSpecs.count) return;
  NSMutableDictionary* spec = _state->deckSlotSpecs[(NSUInteger)slotIdx];
  NSString* slotKey = spec[@"key"] ?: @"";
  NSString* curTitle = spec[@"selectedTitle"] ?: @"";
  NSString* slotTitle = spec[@"title"] ?: @"Slot";
  NSDictionary* captured = _state->captureSlotPortValues(slotIdx);
  NSUInteger count = [_state->presetManager propagateSlotValues:captured
                                                        slotKey:slotKey
                                                 slotPresetName:curTitle
                                                          error:nil];
  _state->presetManager.isModified = NO;
  _state->abModifiedPreset = nil;
  _state->updatePresetDisplayTitle();

  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = [NSString stringWithFormat:@"%@ Settings Propagated", slotTitle];
  alert.informativeText = [NSString stringWithFormat:
      @"Propagated current %@ settings to %lu saved preset%@.",
      slotTitle, (unsigned long)count, count == 1 ? @"" : @"s"];
  [alert addButtonWithTitle:@"OK"];
  [alert runModal];
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
  if (notification.object == self.copilotModelComboBox) {
    // NSComboBox updates its text after this notification is delivered.
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateCopilotAudioControls]; });
    return;
  }
  NSComboBox* combo = (NSComboBox*)notification.object;
  if ([combo isKindOfClass:NSComboBox.class]) [self zoomChanged:combo];
}

- (void)stageModelChanged:(NSPopUpButton*)sender {
  if (!_state) return;
  const size_t stage = (size_t)sender.tag;
  [self selectStageCard:(NSInteger)stage];
  NSMenuItem* item = sender.selectedItem;
  NSString* path = item.representedObject;
  sender.toolTip = _state->modelPickerTooltip(stage, path);
  if (path.length) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
      std::string oldPath = (stage < _state->selectedPaths.size()) ? _state->selectedPaths[stage] : "";
      NSString* oldFolder = oldPath.empty() ? @"" : [[NSString stringWithUTF8String:oldPath.c_str()] stringByDeletingLastPathComponent];
      NSString* newFolder = [path stringByDeletingLastPathComponent];
      BOOL alreadyAvailable = NO;
      if (stage < _state->availableModelPaths.size()) {
        const auto& avail = _state->availableModelPaths[stage];
        if (std::find(avail.begin(), avail.end(), path.fileSystemRepresentation) != avail.end()) {
          alreadyAvailable = YES;
        }
      }
      if (!alreadyAvailable && ![oldFolder isEqualToString:newFolder]) {
        std::vector<std::string> discovered = discoverModelsForStagePath(path.fileSystemRepresentation, stage);
        NSMutableArray<NSString*>* paths = [NSMutableArray arrayWithCapacity:discovered.size()];
        for (const auto& m : discovered) {
          if (!m.empty()) [paths addObject:[NSString stringWithUTF8String:m.c_str()]];
        }
        if (paths.count > 0) {
          _state->setStageModels(stage, paths);
        }
      }
      _state->sendPath(stage, path.fileSystemRepresentation);
      _state->updateThumbnailForStagePath(stage, path);
    } else if (stage < _state->selectedPaths.size()) {
      _state->rememberAvailablePath(stage, path.fileSystemRepresentation);
      _state->selectedPaths[stage] = path.fileSystemRepresentation;
      _state->persistSelectedPaths();
      _state->displayPath(stage, path.fileSystemRepresentation);
    }
    [self markPresetModified];
  }
}

- (void)selectLibraryModelItem:(NSMenuItem*)sender {
  if (!_state) return;
  NSString* path = [sender.representedObject isKindOfClass:[NSString class]] ? sender.representedObject : nil;
  if (!path.length) return;
  const size_t stage = (size_t)sender.tag;
  if (stage >= 4) return;

  [self selectStageCard:(NSInteger)stage];

  // 1. Discover all sibling models in this profile folder
  std::vector<std::string> discovered = discoverModelsForStagePath(path.fileSystemRepresentation, stage);
  NSMutableArray<NSString*>* paths = [NSMutableArray arrayWithCapacity:discovered.size()];
  for (const auto& m : discovered) {
    if (!m.empty()) [paths addObject:[NSString stringWithUTF8String:m.c_str()]];
  }
  if (paths.count > 0) {
    _state->setStageModels(stage, paths);
  }

  // 2. Select this specific model and send to DSP
  _state->sendPath(stage, path.fileSystemRepresentation);
  _state->updateThumbnailForStagePath(stage, path);

  // 3. Update the picker selection to match this model
  NSPopUpButton* picker = _state->modelPickers[stage];
  if (picker) {
    for (NSInteger i = 0; i < picker.numberOfItems; ++i) {
      NSMenuItem* it = [picker itemAtIndex:i];
      if ([it.representedObject isKindOfClass:[NSString class]] &&
          [it.representedObject isEqualToString:path]) {
        [picker selectItemAtIndex:i];
        break;
      }
    }
    picker.toolTip = _state->modelPickerTooltip(stage, path);
  }

  // 4. If Cab B, ensure Cab B is enabled
  if (stage == 3) {
    if (_state->powerButtons[3] && _state->powerButtons[3].state != NSControlStateValueOn) {
      _state->powerButtons[3].state = NSControlStateValueOn;
      _state->sendControl(47, 1.0f);
      _state->updateControl(47, 1.0f);
    }
  }

  [self markPresetModified];
}

- (void)selectStageCard:(NSInteger)stageIndex {
  if (!_state) return;
  _state->selectedStageIndex = stageIndex;
  // Stage cards (0 = Pedal, 1 = Amp, 2 = Cab)
  for (size_t s = 0; s < _state->stageCards.size(); ++s) {
    if (_state->stageCards[s]) {
      // Cab card (stage index 2 in stageCards) NEVER shows a whole-card selection border!
      // Only Pedal (0) or Amp (1) show whole-card selection border.
      if (s < 2) {
        _state->stageCards[s].showsSelection = ((NSInteger)s == stageIndex);
      } else {
        _state->stageCards[s].showsSelection = NO;
      }
    }
  }
  // Selection for the Cab feature is applied directly to the individual dropdowns (Cab A = 2, Cab B = 3)
  if (_state->modelPickers[2]) {
    _state->modelPickers[2].showsSelection = (stageIndex == 2);
  }
  if (_state->modelPickers[3]) {
    _state->modelPickers[3].showsSelection = (stageIndex == 3);
  }
}

- (void)cyclePreviousStageModel {
  [self cycleSelectedStageModel:-1];
}

- (void)cycleNextStageModel {
  [self cycleSelectedStageModel:1];
}

- (void)cycleSelectedStageModel:(NSInteger)direction {
  if (!_state) return;
  NSInteger stage = _state->selectedStageIndex;
  if (stage < 0 || stage >= 4) return;
  NSPopUpButton* picker = _state->modelPickers[(size_t)stage];
  if (!picker || picker.numberOfItems == 0) return;

  NSMutableArray<NSNumber*>* validIndices = [NSMutableArray array];
  for (NSInteger i = 0; i < picker.numberOfItems; ++i) {
    NSMenuItem* it = [picker itemAtIndex:i];
    if (it.representedObject && [(NSString*)it.representedObject length] > 0 && !it.hasSubmenu) {
      [validIndices addObject:@(i)];
    }
  }
  if (validIndices.count == 0) return;

  NSInteger curPickerIndex = picker.indexOfSelectedItem;
  NSInteger validPos = -1;
  for (NSInteger i = 0; i < (NSInteger)validIndices.count; ++i) {
    if (validIndices[(NSUInteger)i].integerValue == curPickerIndex) {
      validPos = i;
      break;
    }
  }
  if (validPos == -1 && stage < (NSInteger)_state->selectedPaths.size()) {
    NSString* curPath = [NSString stringWithUTF8String:_state->selectedPaths[(size_t)stage].c_str()];
    for (NSInteger i = 0; i < (NSInteger)validIndices.count; ++i) {
      NSMenuItem* it = [picker itemAtIndex:validIndices[(NSUInteger)i].integerValue];
      if ([it.representedObject isKindOfClass:[NSString class]] && [(NSString*)it.representedObject isEqualToString:curPath]) {
        validPos = i;
        break;
      }
    }
  }
  if (validPos == -1) {
    validPos = (direction > 0) ? -1 : 0;
  }

  NSInteger newPos = validPos + direction;
  if (newPos < 0) newPos = 0;
  if (newPos >= (NSInteger)validIndices.count) newPos = (NSInteger)validIndices.count - 1;

  NSInteger targetIndex = validIndices[(NSUInteger)newPos].integerValue;
  if (targetIndex != curPickerIndex) {
    [picker selectItemAtIndex:targetIndex];
    [self stageModelChanged:picker];
  }
}

- (void)presetPopupChanged:(id)sender {
  if (!_state || !_state->presetManager) return;
  NSMenuItem* item = nil;
  if ([sender isKindOfClass:[NSMenuItem class]]) {
    item = (NSMenuItem*)sender;
  } else if ([sender isKindOfClass:[NSPopUpButton class]]) {
    item = [(NSPopUpButton*)sender selectedItem];
  }
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
    if (_state->abCycling) _state->stopAB();
    _state->abUserChoseB = false;
    _state->abModifiedPreset = nil;
    _state->abApplyingCycle = true;
    [preset applyToState:_state];
    _state->abApplyingCycle = false;
    _state->syncABNameA();
    _state->updatePresetDisplayTitle();
    if (preset.aiMetadata) {
      NSDictionary* m = preset.aiMetadata;
      NSNumber* inTok = m[@"cumulative_input_tokens"] ?: m[@"input_tokens"];
      NSNumber* outTok = m[@"cumulative_output_tokens"] ?: m[@"output_tokens"];
      NSNumber* cost = m[@"cumulative_token_cost"] ?: m[@"token_cost"];
      if (inTok && outTok && cost) {
        [self appendCopilotLog:[NSString stringWithFormat:@"Loaded AI Tone Preset '%@' (Tokens: %ld in / %ld out · Cost: $%.5f)",
            preset.name, [inTok longValue], [outTok longValue], [cost doubleValue]]];
      }
    }
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
      if (_state->abCycling) _state->stopAB();
      _state->abUserChoseB = false;
      _state->abModifiedPreset = nil;
      _state->abApplyingCycle = true;
      [preset applyToState:_state];
      _state->abApplyingCycle = false;
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
      if (_state->abCycling) _state->stopAB();
      _state->abUserChoseB = false;
      _state->abModifiedPreset = nil;
      _state->abApplyingCycle = true;
      [preset applyToState:_state];
      _state->abApplyingCycle = false;
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
    _state->abUserChoseB = false;
    _state->abModifiedPreset = nil;
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
  alert.informativeText = @"Enter a preset name (use 'Folder/Name' or 'Folder/Subfolder/Name' to organize into folders):";
  [alert addButtonWithTitle:@"Save"];
  [alert addButtonWithTitle:@"Cancel"];

  RigAlertTextField* input = [[RigAlertTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  NSString* initial = [_state->presetManager.currentPresetName isEqualToString:@"Default Rig"]
      ? @"My Custom Tone"
      : _state->presetManager.currentPresetName;
  input.stringValue = initial;
  alert.accessoryView = input;
  [alert.window setInitialFirstResponder:input];
  [input selectText:nil];

  if ([alert runModal] == NSAlertFirstButtonReturn) {
    NSString* name = [input.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) {
      _state->resyncPresetPopupSelection();
      return;
    }
    NSError* err = nil;
    if ([_state->presetManager savePresetNamed:name fromState:_state error:&err]) {
      _state->abUserChoseB = false;
      _state->abModifiedPreset = nil;
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

- (void)renameCurrentPreset:(id)sender {
  (void)sender;
  if (!_state || !_state->presetManager) return;
  NSString* cur = _state->presetManager.currentPresetName;
  if (!cur.length || [cur isEqualToString:@"Default Rig"]) {
    _state->resyncPresetPopupSelection();
    return;
  }

  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"Rename Preset";
  alert.informativeText = @"Enter a new name for this preset (use 'Folder/Name' to move):";
  [alert addButtonWithTitle:@"Rename"];
  [alert addButtonWithTitle:@"Cancel"];

  RigAlertTextField* input = [[RigAlertTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  input.stringValue = cur;
  alert.accessoryView = input;
  [alert.window setInitialFirstResponder:input];
  [input selectText:nil];

  if ([alert runModal] == NSAlertFirstButtonReturn) {
    NSString* newName = [input.stringValue stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!newName.length) {
      _state->resyncPresetPopupSelection();
      return;
    }
    if ([newName isEqualToString:cur]) {
      _state->resyncPresetPopupSelection();
      return;
    }
    NSError* err = nil;
    if ([_state->presetManager renamePresetNamed:cur to:newName fromState:_state error:&err]) {
      if ([_state->abNameB isEqualToString:cur]) {
        _state->abNameB = newName;
      }
      _state->abUserChoseB = false;
      _state->abModifiedPreset = nil;
      _state->updatePresetDisplayTitle();
    } else {
      _state->resyncPresetPopupSelection();
      if (err) {
        NSAlert* fail = [[NSAlert alloc] init];
        fail.messageText = @"Rename Failed";
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
      _state->abUserChoseB = false;
      _state->abModifiedPreset = nil;
      RigPreset* nextP = [_state->presetManager loadPresetNamed:_state->presetManager.currentPresetName];
      if (nextP) {
        _state->abApplyingCycle = true;
        [nextP applyToState:_state];
        _state->abApplyingCycle = false;
      }
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

  RigAlertTextField* input = [[RigAlertTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  input.stringValue = suggestion;
  alert.accessoryView = input;
  [alert.window setInitialFirstResponder:input];
  [input selectText:nil];

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
      _state->abUserChoseB = false;
      _state->abModifiedPreset = nil;
      RigPreset* dup = [_state->presetManager loadPresetNamed:name];
      if (dup) {
        _state->abApplyingCycle = true;
        [dup applyToState:_state];
        _state->abApplyingCycle = false;
      }
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

- (void)autoOrganizePresetsAction:(id)sender {
  (void)sender;
  if (!_state || !_state->presetManager) return;
  NSError* err = nil;
  NSUInteger count = [_state->presetManager autoOrganizeUnsortedPresets:&err];
  _state->updatePresetDisplayTitle();
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"Auto-Organize Presets";
  if (count > 0) {
    alert.informativeText = [NSString stringWithFormat:@"Successfully organized %lu preset%@ into Artist and Genre folders.",
                             (unsigned long)count, count == 1 ? @"" : @"s"];
  } else {
    alert.informativeText = @"All presets are already organized into folders.";
  }
  [alert runModal];
}

// ---- Hands-free A/B preset compare ----
// A is the live active preset (main window); the B dropdown memorizes the
// other side. START alternates between them on a timer so the player can
// audition while playing. STOP (same button, or changing B) halts the cycle
// on the current sound.
- (void)abPresetChanged:(id)sender {
  if (!_state) return;
  NSMenuItem* item = nil;
  if ([sender isKindOfClass:[NSMenuItem class]]) {
    item = (NSMenuItem*)sender;
  } else if ([sender isKindOfClass:[NSPopUpButton class]]) {
    if (sender != _state->abPresetB) return;
    item = [(NSPopUpButton*)sender selectedItem];
  }
  NSString* name = item.representedObject;
  if (![name isKindOfClass:[NSString class]]) return;
  _state->abNameB = name;
  _state->abUserChoseB = ![name isEqualToString:RigUIState::abModifiedToken()];
  // Changing B mid-cycle stops on the newly picked preset: predictable and
  // hands-free (no surprise switch a second later).
  if (_state->abCycling) {
    _state->stopAB();
    if ([name isEqualToString:RigUIState::abModifiedToken()]) {
      _state->abApplyCycle(name);
    } else {
      _state->applyPresetByName(name);
    }
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

@implementation NAMRigUIController (AICopilot)

- (BOOL)popoverShouldClose:(NSPopover*)popover {
  if (_state && popover == _state->aiCopilotPopover) {
    if (![NSApp isActive] || [NSApp modalWindow] != nil) {
      return NO;
    }
  }
  return YES;
}

- (void)popoverWillClose:(NSNotification*)notification {
  if (!_state || notification.object != _state->aiCopilotPopover) return;
  if (self.copilotLocalMatching) [self cancelCopilotRequest:nil];
  if ([RigRiffRecorder sharedRecorder].isRecording || (self.copilotRiffTimer && self.copilotRecordCountdown > 0)) {
    [self.copilotRiffTimer invalidate];
    self.copilotRiffTimer = nil;
    self.copilotRecordCountdown = 0;
    [self setCopilotLiveLine:nil];
    [[RigRiffRecorder sharedRecorder] stopRecording];
  }
  [[RigRiffRecorder sharedRecorder] stopPlayback];
}

- (void)openAICopilot:(id)sender {
  if (!_state) return;
  if (_state->aiCopilotPopover && _state->aiCopilotPopover.isShown) {
    if (self.copilotLocalMatching) [self cancelCopilotRequest:nil];
    if ([RigRiffRecorder sharedRecorder].isRecording || (self.copilotRiffTimer && self.copilotRecordCountdown > 0)) {
      [self.copilotRiffTimer invalidate];
      self.copilotRiffTimer = nil;
      self.copilotRecordCountdown = 0;
      [self setCopilotLiveLine:nil];
      [[RigRiffRecorder sharedRecorder] stopRecording];
    }
    [[RigRiffRecorder sharedRecorder] stopPlayback];
    [_state->aiCopilotPopover close];
    return;
  }

  if (_state->aiCopilotPopover) {
    __weak NAMRigUIController* weakProgressSelf = self;
    [RigAICopilot sharedCopilot].progressHandler = ^(NSString* message) {
      [weakProgressSelf appendCopilotLog:message];
    };
    const BOOL isProc = [RigAICopilot sharedCopilot].isProcessing;
    self.copilotCancelBtn.enabled = isProc;
    self.copilotApplyBtn.enabled = (self.copilotProposal != nil) && !isProc;
    self.copilotUndoBtn.enabled = [RigAICopilot sharedCopilot].canUndo && !isProc;
    if (self.copilotProposal && !self.copilotPresetNameField.stringValue.length) {
      self.copilotPresetNameField.stringValue = [self plannedCopilotPresetName];
    }
    if (self.copilotSearxngButton) {
      self.copilotSearxngButton.state = ([RigAICopilot sharedCopilot].config.useSearxng || [RigAICopilot sharedCopilot].config.searxngURL.length) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [self updateCopilotRiffUI];
    if (!isProc && _state->aiCopilotBtn) {
      _state->aiCopilotBtn.title = @"✨ AI Tone Tuning";
    }
    NSView* anchorView = [sender isKindOfClass:[NSView class]] ? (NSView*)sender : _state->aiCopilotBtn;
    if (!anchorView) anchorView = _state->view;
    [_state->aiCopilotPopover showRelativeToRect:anchorView.bounds ofView:anchorView preferredEdge:NSRectEdgeMaxY];
    if (isProc) [self.copilotSpinner startAnimation:nil];
    else [self.copilotSpinner stopAnimation:nil];
    if (self.copilotOutputView.string.length > 0) {
      [self.copilotOutputView scrollRangeToVisible:NSMakeRange(self.copilotOutputView.string.length, 0)];
    }
    [self.copilotPromptInput.window makeFirstResponder:self.copilotPromptInput];
    return;
  }

  RigAIConfig* config = [RigAICopilot sharedCopilot].config;
  config.allowLocalCLI = YES; // Automatic fallback, requested by the UI policy.

  __weak NAMRigUIController* weakSelf = self;
  [RigRiffRecorder sharedRecorder].onPlaybackFinished = ^{
    [weakSelf updateCopilotRiffUI];
  };

  const CGFloat popW = 540.0;
  const CGFloat popH = 900.0;
  RigPanel* content = [[RigPanel alloc] initWithFrame:NSMakeRect(0, 0, popW, popH)];
  content.wantsLayer = YES;

  // Header
  NSTextField* title = [NSTextField labelWithString:@"✨ AI Tone Tuning"];
  title.frame = NSMakeRect(20, popH - 36, 320, 22);
  title.font = [NSFont systemFontOfSize:16 weight:NSFontWeightBold];
  title.textColor = rigText();
  [content addSubview:title];

  NSTextField* sub = [NSTextField labelWithString:@"AI suggestion or local sound matching → audition → Apply & Save"];
  sub.frame = NSMakeRect(20, popH - 54, 500, 16);
  sub.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
  sub.textColor = rigDimText();
  [content addSubview:sub];

  // Provider row
  NSTextField* provLbl = [NSTextField labelWithString:@"Provider:"];
  provLbl.frame = NSMakeRect(20, popH - 86, 60, 18);
  provLbl.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
  provLbl.textColor = rigText();
  [content addSubview:provLbl];

  self.copilotProvPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(82, popH - 90, 100, 24) pullsDown:NO];
  [self.copilotProvPopup addItemsWithTitles:@[@"Gemini", @"OpenAI", @"Claude", @"Ollama", @"Custom"]];
  self.copilotProvPopup.font = [NSFont systemFontOfSize:11];
  for (NSMenuItem* item in self.copilotProvPopup.itemArray)
    if ([item.title.lowercaseString isEqual:config.provider.lowercaseString]) [self.copilotProvPopup selectItem:item];
  self.copilotProvPopup.target = self;
  self.copilotProvPopup.action = @selector(copilotProviderChanged:);
  [content addSubview:self.copilotProvPopup];

  NSTextField* modLbl = [NSTextField labelWithString:@"Model:"];
  modLbl.frame = NSMakeRect(188, popH - 86, 44, 18);
  modLbl.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
  modLbl.textColor = rigText();
  [content addSubview:modLbl];

  self.copilotModelComboBox = [[NSComboBox alloc] initWithFrame:NSMakeRect(234, popH - 89, 146, 24)];
  self.copilotModelComboBox.font = [NSFont systemFontOfSize:11];
  self.copilotModelComboBox.hasVerticalScroller = YES;
  self.copilotModelComboBox.delegate = self;
  self.copilotModelComboBox.numberOfVisibleItems = 12;
  NSArray<NSString*>* initialModels = [[RigAICopilot sharedCopilot] availableModelsForProvider:config.provider apiKey:nil baseURL:nil];
  [self.copilotModelComboBox addItemsWithObjectValues:initialModels];
  self.copilotModelComboBox.stringValue = config.model.length ? config.model : (initialModels.firstObject ?: @"");
  [content addSubview:self.copilotModelComboBox];

  RigButton* refreshBtn = rigButton(content, @"↻", self, @selector(refreshCopilotModelsAction:), NSMakeRect(384, popH - 88, 28, 22));
  refreshBtn.font = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];
  refreshBtn.toolTip = @"Fetch latest models from provider API";
  self.copilotModelsRefreshBtn = refreshBtn;

  RigButton* saveCfg = rigButton(content, @"Save Config", self, @selector(saveCopilotConfig:), NSMakeRect(418, popH - 88, 102, 22));
  saveCfg.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];

  // API Key row
  NSTextField* keyLbl = [NSTextField labelWithString:@"API Key:"];
  keyLbl.frame = NSMakeRect(20, popH - 116, 60, 18);
  keyLbl.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
  keyLbl.textColor = rigText();
  [content addSubview:keyLbl];

  self.copilotKeyField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(82, popH - 118, 438, 22)];
  self.copilotKeyField.font = [NSFont systemFontOfSize:11];
  self.copilotKeyField.stringValue = config.apiKey ?: @"";
  self.copilotKeyField.target = self;
  self.copilotKeyField.action = @selector(copilotKeyFieldAction:);
  self.copilotKeyField.delegate = self;
  [content addSubview:self.copilotKeyField];
  self.copilotURLField = [[NSTextField alloc] initWithFrame:NSMakeRect(82, popH - 146, 438, 22)];
  self.copilotURLField.stringValue = config.baseURL ?: @"";
  self.copilotURLField.placeholderString = @"HTTPS API URL or loopback Ollama URL";
  self.copilotURLField.font = [NSFont systemFontOfSize:11];
  self.copilotURLField.delegate = self;
  self.copilotURLField.target = self;
  self.copilotURLField.action = @selector(copilotKeyFieldAction:);
  [content addSubview:self.copilotURLField];
  NSTextField* urlLabel = [NSTextField labelWithString:@"API URL:"];
  urlLabel.frame = NSMakeRect(20, popH - 144, 60, 18);
  urlLabel.textColor = rigText();
  [content addSubview:urlLabel];

  self.copilotSendAudioButton = [NSButton checkboxWithTitle:@"Send recordings to cloud AI (optional; extra cost)" target:self action:@selector(copilotAudioUploadToggled:)];
  self.copilotSendAudioButton.frame = NSMakeRect(20, popH - 172, 305, 22);
  self.copilotSendAudioButton.font = [NSFont systemFontOfSize:10];
  self.copilotSendAudioButton.state = config.sendAudio ? NSControlStateValueOn : NSControlStateValueOff;
  [content addSubview:self.copilotSendAudioButton];

  self.copilotSearxngButton = [NSButton checkboxWithTitle:@"Web gear research (SearXNG)" target:self action:@selector(copilotSearxngToggled:)];
  self.copilotSearxngButton.frame = NSMakeRect(335, popH - 172, 185, 22);
  self.copilotSearxngButton.font = [NSFont systemFontOfSize:10];
  self.copilotSearxngButton.state = (config.useSearxng || config.searxngURL.length) ? NSControlStateValueOn : NSControlStateValueOff;
  self.copilotSearxngButton.toolTip = @"Search the web for documented artist gear & rig rundowns using local SearXNG (auto-starts via ./searxng.sh if not running).";
  [content addSubview:self.copilotSearxngButton];
  [self updateCopilotProviderControlsForProvider:config.provider];

  self.copilotModelsStatus = [NSTextField labelWithString:@""];
  self.copilotModelsStatus.frame = NSMakeRect(20, popH - 184, 500, 12);
  self.copilotModelsStatus.font = [NSFont systemFontOfSize:9];
  self.copilotModelsStatus.textColor = rigDimText();
  self.copilotModelsStatus.lineBreakMode = NSLineBreakByTruncatingTail;
  [content addSubview:self.copilotModelsStatus];

  // Query models on popover opening
  [self refreshCopilotModelsUI];

  // Separator 1
  NSBox* sep = [[NSBox alloc] initWithFrame:NSMakeRect(20, popH - 186, popW - 40, 1)];
  sep.boxType = NSBoxSeparator;
  [content addSubview:sep];

  // --- AUDIO RIFF SECTION ---
  NSTextField* riffHeader = [NSTextField labelWithString:@"1. Your guitar — record your playing for matching"];
  riffHeader.frame = NSMakeRect(20, popH - 204, 500, 18);
  riffHeader.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
  riffHeader.textColor = rigText();
  [content addSubview:riffHeader];

  self.copilotRecordBtn = rigButton(content, @"● Record Riff", self, @selector(toggleCopilotRecordRiff:), NSMakeRect(20, popH - 236, 100, 26));
  self.copilotRecordBtn.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
  self.copilotRecordBtn.toolTip = @"Record your guitar, not the song. Captures raw DI (before the rig) and processed output. Required for Learn & Match; standalone app only.";

  self.copilotPlayAlongBtn = rigButton(content, @"● Play Along", self, @selector(toggleCopilotPlayAlong:), NSMakeRect(125, popH - 236, 100, 26));
  self.copilotPlayAlongBtn.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
  self.copilotPlayAlongBtn.toolTip = @"Play along with the loaded target sound. Plays the reference excerpt in your monitors/headphones while recording your guitar DI. Enables aligned note-by-note DTW tone matching.";

  self.copilotPlayBtn = rigButton(content, @"▶ Play", self, @selector(playCopilotRiff:), NSMakeRect(230, popH - 236, 55, 26));
  self.copilotPlayBtn.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
  self.copilotPlayBtn.enabled = NO;

  self.copilotClearBtn = rigButton(content, @"✕ Clear", self, @selector(clearCopilotRiff:), NSMakeRect(290, popH - 236, 58, 26));
  self.copilotClearBtn.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
  self.copilotClearBtn.enabled = NO;

  self.copilotRiffLevelBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(354, popH - 231, 166, 16)];
  self.copilotRiffLevelBar.minValue = 0.0;
  self.copilotRiffLevelBar.maxValue = 1.0;
  self.copilotRiffLevelBar.indeterminate = NO;
  self.copilotRiffLevelBar.doubleValue = 0.0;
  [content addSubview:self.copilotRiffLevelBar];

  self.copilotRiffStatusLabel = [NSTextField labelWithString:@"No riff recorded. Play 5-10s to let AI evaluate attack, mud, and fizz."];
  self.copilotRiffStatusLabel.frame = NSMakeRect(22, popH - 258, popW - 44, 16);
  self.copilotRiffStatusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
  self.copilotRiffStatusLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];
  self.copilotRiffStatusLabel.textColor = rigDimText();
  [content addSubview:self.copilotRiffStatusLabel];

  self.copilotGuidedButton = [NSButton checkboxWithTitle:@"Guided 20s take" target:nil action:nil];
  self.copilotGuidedButton.frame = NSMakeRect(20, popH - 288, 150, 22);
  self.copilotGuidedButton.state = NSControlStateValueOn;
  self.copilotGuidedButton.toolTip = @"Muted strings → chugs → chords → soft/hard notes → sustain. Substitute representative playing for clean/lead tones.";
  [content addSubview:self.copilotGuidedButton];
  self.copilotTrackPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(175, popH - 288, 160, 24)];
  [self.copilotTrackPopup addItemsWithTitles:@[@"Your guitar output", @"Your raw DI", @"Baseline (matched)", @"Candidate (matched)", @"Target sound (guitar stem)", @"Target backing stems"]];
  [content addSubview:self.copilotTrackPopup];
  self.copilotRenderBtn = rigButton(content, @"Render DI A/B", self, @selector(renderCopilotDI:), NSMakeRect(345, popH - 288, 175, 24));
  self.copilotRenderBtn.toolTip = @"Render the same DI through baseline and proposal locally. No AI call, no live rig changes.";
  RigButton* targetButton = rigButton(content, @"2. Load target sound…", self, @selector(importCopilotReference:), NSMakeRect(20, popH - 316, 142, 24));
  targetButton.toolTip = @"Choose an audio file or song to match. Extracts the guitar stem locally via Demucs by default (no upload). Hold Option to load an already-isolated guitar track as-is.";
  self.copilotTargetPlayBtn = rigButton(content, @"▶ Preview", self, @selector(toggleCopilotTargetPreview:), NSMakeRect(168, popH - 316, 80, 24));
  self.copilotTargetPlayBtn.toolTip = @"Preview the extracted guitar stem (or loaded target sound) through your speakers/headphones.";
  self.copilotTargetPlayBtn.enabled = NO;
  self.copilotTargetClearBtn = rigButton(content, @"Clear", self, @selector(clearCopilotReference:), NSMakeRect(254, popH - 316, 50, 24));
  self.copilotDemucsSpinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(310, popH - 313, 18, 18)];
  self.copilotDemucsSpinner.style = NSProgressIndicatorStyleSpinning;
  self.copilotDemucsSpinner.controlSize = NSControlSizeSmall;
  self.copilotDemucsSpinner.hidden = YES;
  [content addSubview:self.copilotDemucsSpinner];
  NSTextField* targetHint = [NSTextField labelWithString:@"extracts guitar stem locally · not uploaded"];
  targetHint.frame = NSMakeRect(334, popH - 312, 186, 18);
  targetHint.font = [NSFont systemFontOfSize:10]; targetHint.textColor = rigDimText();
  [content addSubview:targetHint];
  self.copilotTargetStatus = [NSTextField labelWithString:@""];
  self.copilotTargetStatus.frame = NSMakeRect(20, popH - 340, 214, 18);
  self.copilotTargetStatus.font = [NSFont systemFontOfSize:10];
  self.copilotTargetStatus.lineBreakMode = NSLineBreakByTruncatingTail;
  [content addSubview:self.copilotTargetStatus];
  // Which section of the target song to match (Auto = densest passage).
  NSString* sectionTip = @"Section of the target used for matching and AI context. Auto picks the densest passage; editing Start switches to manual. Play it via the track menu → Target sound.";
  self.copilotTargetAutoButton = [NSButton checkboxWithTitle:@"Auto" target:self action:@selector(changeCopilotTargetSection:)];
  self.copilotTargetAutoButton.frame = NSMakeRect(238, popH - 341, 52, 20);
  self.copilotTargetAutoButton.controlSize = NSControlSizeSmall;
  self.copilotTargetAutoButton.font = [NSFont systemFontOfSize:10];
  self.copilotTargetAutoButton.toolTip = sectionTip;
  [content addSubview:self.copilotTargetAutoButton];
  self.copilotTargetStartField = [[NSTextField alloc] initWithFrame:NSMakeRect(292, popH - 340, 44, 18)];
  self.copilotTargetStartField.font = [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular];
  self.copilotTargetStartField.placeholderString = @"start";
  self.copilotTargetStartField.target = self;
  self.copilotTargetStartField.action = @selector(changeCopilotTargetSection:);
  self.copilotTargetStartField.toolTip = sectionTip;
  [content addSubview:self.copilotTargetStartField];
  self.copilotTargetStartStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(337, popH - 342, 15, 22)];
  self.copilotTargetStartStepper.controlSize = NSControlSizeSmall;
  self.copilotTargetStartStepper.minValue = 0; self.copilotTargetStartStepper.increment = 1;
  self.copilotTargetStartStepper.valueWraps = NO; self.copilotTargetStartStepper.autorepeat = YES;
  self.copilotTargetStartStepper.target = self;
  self.copilotTargetStartStepper.action = @selector(changeCopilotTargetSection:);
  [content addSubview:self.copilotTargetStartStepper];
  self.copilotTargetLengthPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(356, popH - 342, 66, 22)];
  self.copilotTargetLengthPopup.controlSize = NSControlSizeSmall;
  self.copilotTargetLengthPopup.font = [NSFont systemFontOfSize:10];
  for (NSInteger seconds : {5, 10, 15, 20}) {
    [self.copilotTargetLengthPopup addItemWithTitle:[NSString stringWithFormat:@"%ld s", (long)seconds]];
    self.copilotTargetLengthPopup.lastItem.tag = seconds;
  }
  [self.copilotTargetLengthPopup selectItemWithTag:20];
  self.copilotTargetLengthPopup.target = self;
  self.copilotTargetLengthPopup.action = @selector(changeCopilotTargetSection:);
  self.copilotTargetLengthPopup.toolTip = sectionTip;
  [content addSubview:self.copilotTargetLengthPopup];
  self.copilotTargetRangeLabel = [NSTextField labelWithString:@""];
  self.copilotTargetRangeLabel.frame = NSMakeRect(426, popH - 340, 96, 18);
  self.copilotTargetRangeLabel.font = [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular];
  self.copilotTargetRangeLabel.textColor = rigDimText();
  [content addSubview:self.copilotTargetRangeLabel];
  self.copilotGuitarInfo = [[NSTextField alloc] initWithFrame:NSMakeRect(20, popH - 374, 500, 24)];
  self.copilotGuitarInfo.placeholderString = @"Optional: tuning, pickup, interface gain / external pedals";
  self.copilotGuitarInfo.font = [NSFont systemFontOfSize:11];
  [content addSubview:self.copilotGuitarInfo];
  self.copilotModePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, popH - 402, 500, 24)];
  [self.copilotModePopup addItemsWithTitles:@[@"New preset (build from scratch; neutral base)", @"Modify current preset (load your saved preset first)", @"Refine last proposal (same base as the DI audition)"]];
  [content addSubview:self.copilotModePopup];
  self.copilotLocalMatchBtn = rigButton(content, @"Learn & Match", self, @selector(matchCopilotLocally:), NSMakeRect(20, popH - 436, 125, 26));
  self.copilotLocalMatchBtn.toolTip = @"Train and compare locally: your raw guitar recording + target guitar sound. No cloud AI request or upload. May take minutes.";
  self.copilotMatchCandidates = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(155, popH - 436, 155, 26)];
  [self.copilotMatchCandidates addItemWithTitle:@"Local finalists"];
  self.copilotMatchCandidates.enabled = NO;
  self.copilotMatchCandidates.target = self;
  self.copilotMatchCandidates.action = @selector(selectCopilotLocalMatch:);
  [content addSubview:self.copilotMatchCandidates];
  self.copilotMatchMixEQButton = [NSButton checkboxWithTitle:@"Mix EQ (Console pins)" target:self action:@selector(selectCopilotLocalMatch:)];
  self.copilotMatchMixEQButton.frame = NSMakeRect(320, popH - 436, 205, 26);
  self.copilotMatchMixEQButton.state = NSControlStateValueOn;
  self.copilotMatchMixEQButton.enabled = NO;
  self.copilotMatchMixEQButton.toolTip = @"Gentle Console-pin EQ for what amp, cab and tone stack cannot explain (usually the target mix's EQ). Only offered when a real render showed it helps; turn off to audition the same gear without it.";
  [content addSubview:self.copilotMatchMixEQButton];
  self.copilotMatchResearchButton = [NSButton checkboxWithTitle:@"Research gear with AI (text only)" target:self action:@selector(toggleCopilotMatchResearch:)];
  self.copilotMatchResearchButton.frame = NSMakeRect(20, popH - 464, 260, 26);
  self.copilotMatchResearchButton.state = [RigAICopilot sharedCopilot].config.researchGearForLocalMatch ? NSControlStateValueOn : NSControlStateValueOff;
  self.copilotMatchResearchButton.toolTip = @"Opt in: before matching, ask your configured AI provider/CLI which amps, cabs and pedals the prompt's artist/album/song used (cached afterwards). Sends only the prompt text — never audio. Ranks and widens the local amp screen.";
  [content addSubview:self.copilotMatchResearchButton];
  self.copilotMatchOnlineButton = [NSButton checkboxWithTitle:@"Search Tone3000 too" target:nil action:nil];
  self.copilotMatchOnlineButton.frame = NSMakeRect(320, popH - 464, 205, 26);
  self.copilotMatchOnlineButton.toolTip = @"Opt in to online amp search/download (up to 3) using your prompt/gear terms. No audio uploads. Local training remains offline.";
  [content addSubview:self.copilotMatchOnlineButton];
  self.copilotAccurateRescoreButton = [NSButton checkboxWithTitle:@"Accurate Demucs re-score (slow)" target:nil action:nil];
  self.copilotAccurateRescoreButton.frame = NSMakeRect(20, popH - 490, 280, 24);
  self.copilotAccurateRescoreButton.state = NSControlStateValueOff;
  self.copilotAccurateRescoreButton.toolTip = @"Opt in: mix finalist renders back into Demucs backing stems and re-separate them through Demucs before scoring, so candidates and target share the same separation artifacts.";
  [content addSubview:self.copilotAccurateRescoreButton];
  self.copilotEmbeddingRerankButton = [NSButton checkboxWithTitle:@"Embedding re-rank (CLAP)" target:nil action:nil];
  self.copilotEmbeddingRerankButton.frame = NSMakeRect(320, popH - 490, 205, 24);
  self.copilotEmbeddingRerankButton.state = NSControlStateValueOff;
  self.copilotEmbeddingRerankButton.toolTip = @"Opt in: score finalists with audio embedding cosine distance (CLAP) and blend with acoustic feature distance.";
  [content addSubview:self.copilotEmbeddingRerankButton];
  self.copilotLocalMatchStatus = [NSTextField labelWithString:@""];
  self.copilotLocalMatchStatus.frame = NSMakeRect(20, popH - 530, 505, 36);
  self.copilotLocalMatchStatus.font = [NSFont systemFontOfSize:10];
  self.copilotLocalMatchStatus.lineBreakMode = NSLineBreakByWordWrapping;
  self.copilotLocalMatchStatus.maximumNumberOfLines = 2;
  [content addSubview:self.copilotLocalMatchStatus];
  const CGFloat captureOffset = 286;

  // Separator 2
  NSBox* sep2 = [[NSBox alloc] initWithFrame:NSMakeRect(20, popH - 272 - captureOffset, popW - 40, 1)];
  sep2.boxType = NSBoxSeparator;
  [content addSubview:sep2];

  // Prompt input
  NSTextField* pLbl = [NSTextField labelWithString:@"Describe Artist, Song, or Tone Adjustment:"];
  pLbl.frame = NSMakeRect(20, popH - 294 - captureOffset, 350, 18);
  pLbl.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
  pLbl.textColor = rigText();
  [content addSubview:pLbl];

  self.copilotPromptInput = [[NSTextField alloc] initWithFrame:NSMakeRect(20, popH - 344 - captureOffset, popW - 40, 46)];
  self.copilotPromptInput.placeholderString = @"e.g. 'Tighten low-end chug and reduce fizz', 'Warm vintage blues lead', or 'Match this riff to Master of Puppets'";
  self.copilotPromptInput.font = [NSFont systemFontOfSize:12];
  self.copilotPromptInput.target = self;
  self.copilotPromptInput.action = @selector(executeCopilotDial:);
  [content addSubview:self.copilotPromptInput];

  // Action Buttons
  self.copilotDialBtn = rigButton(content, @"Preview Tone", self, @selector(executeCopilotDial:), NSMakeRect(20, popH - 384 - captureOffset, 110, 30));
  self.copilotDialBtn.primary = YES;
  self.copilotDialBtn.enabled = ![RigAICopilot sharedCopilot].isProcessing;
  self.copilotDialBtn.font = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];
  self.copilotDialBtn.toolTip = @"Ask the selected AI provider for settings. Uses text and audio measurements by default; sends clips only with the cloud-audio option enabled. Unlike Learn & Match, it does not locally train against the target.";

  self.copilotApplyBtn = rigButton(content, @"Apply & Save", self, @selector(applyCopilotProposal:), NSMakeRect(140, popH - 384 - captureOffset, 110, 30));
  self.copilotApplyBtn.enabled = self.copilotProposal != nil;
  self.copilotUndoBtn = rigButton(content, @"A/B Toggle", self, @selector(undoCopilotDial:), NSMakeRect(260, popH - 384 - captureOffset, 100, 30));
  self.copilotUndoBtn.enabled = [RigAICopilot sharedCopilot].canUndo;
  self.copilotUndoBtn.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];

  self.copilotCancelBtn = rigButton(content, @"Cancel", self, @selector(cancelCopilotRequest:), NSMakeRect(370, popH - 384 - captureOffset, 80, 30));
  self.copilotCancelBtn.enabled = [RigAICopilot sharedCopilot].isProcessing;
  self.copilotSpinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(470, popH - 380 - captureOffset, 22, 22)];
  self.copilotSpinner.style = NSProgressIndicatorStyleSpinning;
  self.copilotSpinner.controlSize = NSControlSizeSmall;
  self.copilotSpinner.displayedWhenStopped = NO;
  [content addSubview:self.copilotSpinner];

  // Preset name row: shows exactly what Apply & Save will create; editable.
  NSTextField* nameLbl = [NSTextField labelWithString:@"Save as:"];
  nameLbl.frame = NSMakeRect(20, popH - 410 - captureOffset, 60, 18);
  nameLbl.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
  nameLbl.textColor = rigText();
  [content addSubview:nameLbl];
  self.copilotPresetNameField = [[NSTextField alloc] initWithFrame:NSMakeRect(82, popH - 412 - captureOffset, popW - 102, 22)];
  self.copilotPresetNameField.font = [NSFont systemFontOfSize:11];
  self.copilotPresetNameField.placeholderString = @"Preset name is filled in after Preview Tone (edit before Apply & Save)";
  self.copilotPresetNameField.toolTip = @"Apply & Save creates a new preset with this name. A ' Copy N' suffix is added if the name already exists.";
  self.copilotPresetNameField.stringValue = self.copilotProposal ? [self plannedCopilotPresetName] : @"";
  [content addSubview:self.copilotPresetNameField];

  // Activity log / output scroll view
  NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 20, popW - 40, popH - 440 - captureOffset)];
  scroll.hasVerticalScroller = YES;
  scroll.borderType = NSBezelBorder;
  scroll.autohidesScrollers = YES;

  self.copilotOutputView = [[NSTextView alloc] initWithFrame:scroll.contentView.bounds];
  self.copilotOutputView.editable = NO;
  self.copilotOutputView.selectable = YES;
  self.copilotOutputView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
  self.copilotOutputView.textColor = rigText();
  self.copilotOutputView.backgroundColor = [NSColor colorWithSRGBRed:0.07 green:0.08 blue:0.10 alpha:1.0];
  self.copilotOutputView.string = @"";
  self.copilotLogBase = nil;
  scroll.documentView = self.copilotOutputView;
  [content addSubview:scroll];

  __weak NAMRigUIController* weakProgressSelf = self;
  [RigAICopilot sharedCopilot].progressHandler = ^(NSString* message) {
    [weakProgressSelf appendCopilotLog:message];
  };

  [self updateCopilotRiffUI];

  NSPopover* pop = [[NSPopover alloc] init];
  NSViewController* vc = [[NSViewController alloc] init];
  vc.view = content;
  pop.contentViewController = vc;
  pop.behavior = NSPopoverBehaviorSemitransient;
  pop.delegate = self;
  pop.contentSize = content.frame.size;
  _state->aiCopilotPopover = pop;

  NSView* anchorView = [sender isKindOfClass:[NSView class]] ? (NSView*)sender : _state->aiCopilotBtn;
  if (!anchorView) anchorView = _state->view;
  [pop showRelativeToRect:anchorView.bounds ofView:anchorView preferredEdge:NSRectEdgeMaxY];
  if ([RigAICopilot sharedCopilot].isProcessing) [self.copilotSpinner startAnimation:nil];
  [self.copilotPromptInput.window makeFirstResponder:self.copilotPromptInput];
}

- (void)appendCopilotLog:(NSString*)line {
  if (!line.length) return;
  NSTextView* view = self.copilotOutputView;
  if (!view) return;
  NSDateFormatter* formatter = [NSDateFormatter new];
  formatter.dateFormat = @"HH:mm:ss";
  NSString* stamped = [line containsString:@"\n"] ?
      [NSString stringWithFormat:@"[%@]\n%@", [formatter stringFromDate:NSDate.date], line] :
      [NSString stringWithFormat:@"[%@] %@", [formatter stringFromDate:NSDate.date], line];
  NSString* current = self.copilotLogBase ?: view.string ?: @"";
  NSString* next = current.length ? [NSString stringWithFormat:@"%@\n%@", current, stamped] : stamped;
  self.copilotLogBase = next;
  view.string = next;
  [view scrollRangeToVisible:NSMakeRange(next.length, 0)];
  dispatch_async(dispatch_get_main_queue(), ^{
    [view scrollRangeToVisible:NSMakeRange(view.string.length, 0)];
    NSScrollView* sv = view.enclosingScrollView;
    if (sv) {
      NSPoint bottom = NSMakePoint(0, std::max<CGFloat>(0.0, NSMaxY(view.frame) - NSHeight(sv.contentView.bounds)));
      [sv.contentView scrollToPoint:bottom];
      [sv reflectScrolledClipView:sv.contentView];
    }
  });
}

- (void)resetCopilotLog:(NSString*)header {
  self.copilotLogBase = header ?: @"";
  self.copilotOutputView.string = self.copilotLogBase;
  NSTextView* view = self.copilotOutputView;
  if (view) {
    [view scrollRangeToVisible:NSMakeRange(0, 0)];
    NSScrollView* sv = view.enclosingScrollView;
    if (sv) [sv.contentView scrollToPoint:NSMakePoint(0, 0)];
  }
}

- (void)setCopilotLiveLine:(NSString*)line {
  NSTextView* view = self.copilotOutputView;
  if (!view) return;
  if (!self.copilotLogBase) self.copilotLogBase = view.string ?: @"";
  NSString* base = self.copilotLogBase;
  NSString* next = line.length ? (base.length ? [NSString stringWithFormat:@"%@\n%@", base, line] : line) : base;
  view.string = next;
  [view scrollRangeToVisible:NSMakeRange(next.length, 0)];
  dispatch_async(dispatch_get_main_queue(), ^{
    [view scrollRangeToVisible:NSMakeRange(view.string.length, 0)];
    NSScrollView* sv = view.enclosingScrollView;
    if (sv) {
      NSPoint bottom = NSMakePoint(0, std::max<CGFloat>(0.0, NSMaxY(view.frame) - NSHeight(sv.contentView.bounds)));
      [sv.contentView scrollToPoint:bottom];
      [sv reflectScrolledClipView:sv.contentView];
    }
  });
}

- (NSString*)plannedCopilotPresetName {
  NSString* typed = [self.copilotPresetNameField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSString* base = nil;
  if (typed.length) {
    base = [typed stringByReplacingOccurrencesOfString:@":" withString:@"-"];
  } else {
    RigAICopilotResult* proposal = self.copilotProposal;
    NSString* promptText = self.copilotPromptInput.stringValue;
    NSString* rawTitle = proposal.presetName.length ? proposal.presetName :
        [RigAICopilot summarizePromptToPresetName:promptText];
    base = [RigAICopilot hierarchicalPresetPathForTitle:rawTitle
                                                 prompt:promptText
                                                 artist:proposal.artist
                                                  album:proposal.album
                                                   song:proposal.song
                                                  genre:proposal.genre
                                             folderPath:proposal.folderPath];
  }
  base = [base stringByReplacingOccurrencesOfString:@":" withString:@"-"];
  while ([base containsString:@"//"]) base = [base stringByReplacingOccurrencesOfString:@"//" withString:@"/"];
  base = [base stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
  if (!base.length) base = @"Genre/Custom Tones/AI Custom Tone";
  RigPresetManager* manager = _state ? _state->presetManager : nil;
  return manager ? [manager uniquePresetNameForBase:base] : base;
}

- (void)refreshCopilotModelsAction:(id)sender {
  (void)sender;
  [self refreshCopilotModelsUIForced:YES];
}

- (void)copilotKeyFieldAction:(id)sender {
  (void)sender;
  [self updateCopilotAudioControls];
  [self refreshCopilotModelsUI];
}

- (void)refreshCopilotModelsUI {
  [self refreshCopilotModelsUIForced:NO];
}

- (void)comboBoxWillPopUp:(NSNotification*)notification {
  if (notification.object == self.copilotModelComboBox) [self refreshCopilotModelsUI];
}

- (void)refreshCopilotModelsUIForced:(BOOL)force {
  NSString* prov = self.copilotProvPopup.titleOfSelectedItem.lowercaseString;
  NSString* key = self.copilotKeyField.stringValue;
  NSString* baseURL = self.copilotURLField.stringValue;
  NSUInteger serial = ++self.copilotModelsRequestSerial;
  self.copilotModelsStatus.stringValue = @"Checking available models…";
  self.copilotModelsRefreshBtn.enabled = NO;
  __weak NSComboBox* weakBox = self.copilotModelComboBox;
  __weak NAMRigUIController* weakSelf = self;
  [[RigAICopilot sharedCopilot] fetchModelsForProvider:prov
                                                 apiKey:key
                                                baseURL:baseURL forceRefresh:force
                                      completionHandler:^(NSArray<NSString*>* liveModels, NSError* err) {
    NAMRigUIController* controller = weakSelf;
    if (!controller || controller.copilotModelsRequestSerial != serial || controller.copilotModelComboBox != weakBox) return;
    controller.copilotModelsRefreshBtn.enabled = YES;
    if (![controller.copilotProvPopup.titleOfSelectedItem.lowercaseString isEqual:prov] ||
        ![controller.copilotKeyField.stringValue isEqual:key] || ![controller.copilotURLField.stringValue isEqual:baseURL]) return;
    if (liveModels.count > 0 && weakBox) {
      NSString* cur = weakBox.stringValue;
      [weakBox removeAllItems];
      [weakBox addItemsWithObjectValues:liveModels];
      weakBox.stringValue = cur.length ? cur : (liveModels.firstObject ?: @"");
    }
    NSString* status = err ? [NSString stringWithFormat:@"%@%@", liveModels.count ? @"" : @"Keeping starter/current options. ", err.localizedDescription] :
        [NSString stringWithFormat:@"%lu available models · checked hourly · ↻ forces refresh", (unsigned long)liveModels.count];
    controller.copilotModelsStatus.stringValue = status;
    controller.copilotModelsStatus.toolTip = status;
    weakBox.toolTip = status;
    [controller updateCopilotAudioControls];
  }];
}

- (void)copilotProviderChanged:(NSPopUpButton*)sender {
  NSString* sel = sender.titleOfSelectedItem.lowercaseString;
  RigAIConfig* config = [RigAICopilot sharedCopilot].config;
  config.provider = sel;
  config.apiKey = [RigAIConfig storedApiKeyForProvider:sel];
  self.copilotKeyField.stringValue = config.apiKey;

  [self.copilotModelComboBox removeAllItems];
  NSArray<NSString*>* defModels = [[RigAICopilot sharedCopilot] availableModelsForProvider:sel apiKey:config.apiKey
      baseURL:[RigAIConfig defaultBaseURLForProvider:sel]];
  [self.copilotModelComboBox addItemsWithObjectValues:defModels];
  self.copilotModelComboBox.stringValue = defModels.firstObject ?: @"";

  if ([sel isEqualToString:@"gemini"]) {
    config.baseURL = @"https://generativelanguage.googleapis.com/v1beta/openai";
  } else if ([sel isEqualToString:@"openai"]) {
    config.baseURL = @"https://api.openai.com/v1";
  } else if ([sel isEqualToString:@"claude"]) {
    config.baseURL = @"https://api.anthropic.com/v1/messages";
  } else if ([sel isEqualToString:@"ollama"]) {
    config.baseURL = @"http://localhost:11434/v1";
  }
  else config.baseURL = @"";
  self.copilotURLField.stringValue = config.baseURL;
  self.copilotProposal = nil;
  self.copilotLocalMatches = nil;
  self.copilotApplyBtn.enabled = NO;
  [self updateCopilotProviderControlsForProvider:sel];
  [self refreshCopilotModelsUI];
}

- (void)updateCopilotProviderControlsForProvider:(NSString*)prov {
  NSString* sel = prov.lowercaseString;
  NSString* localCLI = [RigAICopilot detectLocalCLIForProvider:sel];
  NSString* cliDisplayName = [sel isEqualToString:@"gemini"] ? @"Antigravity (agy)" :
      ([sel isEqualToString:@"claude"] ? @"Claude" :
      ([sel isEqualToString:@"openai"] ? @"Codex" : nil));

  if ([sel isEqualToString:@"ollama"]) {
    self.copilotKeyField.placeholderString = @"API key not required for local Ollama";
  } else if ([sel isEqualToString:@"custom"]) {
    self.copilotKeyField.placeholderString = @"Enter API key if required by endpoint (optional)";
  } else if (localCLI) {
    self.copilotKeyField.placeholderString = [NSString stringWithFormat:@"Optional: leave empty to use signed-in %@ automatically", cliDisplayName ?: @"CLI"];
  } else {
    self.copilotKeyField.placeholderString = [NSString stringWithFormat:@"Enter %@ API key (or set in environment)", sel.uppercaseString];
  }
  self.copilotKeyField.toolTip = @"An API key uses the cloud API. With no key, a supported installed CLI is used automatically (Claude, Codex, or Antigravity agy), respecting its login and permissions. Local matching needs neither.";
  [self updateCopilotAudioControls];
}

- (void)updateCopilotAudioControls {
  RigAIConfig* saved = [RigAICopilot sharedCopilot].config;
  RigAIConfig* selected = [RigAIConfig new];
  selected.provider = self.copilotProvPopup.titleOfSelectedItem.lowercaseString ?: saved.provider;
  selected.model = self.copilotModelComboBox.stringValue ?: saved.model;
  selected.apiKey = self.copilotKeyField ? self.copilotKeyField.stringValue : saved.effectiveApiKey;
  const BOOL canSend = selected.canSendAudio;
  self.copilotSendAudioButton.enabled = canSend;
  if (!canSend) self.copilotSendAudioButton.state = NSControlStateValueOff;
  self.copilotSendAudioButton.title = [selected.provider isEqual:@"claude"]
      ? @"Claude uses audio measurements only — no clip uploads"
      : @"Send recordings to cloud AI (optional; extra cost)";
  self.copilotSendAudioButton.toolTip = canSend
      ? @"When you click Preview Tone, send your guitar recordings AND the target sound to the selected cloud AI. Off = text/audio measurements only. Loading the target and Learn & Match never upload audio."
      : @"This model/connection cannot receive audio clips in Axe FX. Preview Tone receives text and locally computed measurements instead. Supported Gemini/OpenAI audio models with an API key can optionally receive clips. Loading a target sound or using Learn & Match keeps audio local.";
}

- (void)copilotAudioUploadToggled:(id)sender {
  (void)sender;
  [self updateCopilotAudioControls];
}

- (void)saveCopilotConfig:(id)sender {
  (void)sender;
  RigAIConfig* config = [RigAICopilot sharedCopilot].config;
  config.provider = self.copilotProvPopup.titleOfSelectedItem.lowercaseString;
  config.model = self.copilotModelComboBox.stringValue;
  config.apiKey = self.copilotKeyField.stringValue;
  config.baseURL = self.copilotURLField.stringValue;
  config.useSearxng = (self.copilotSearxngButton.state == NSControlStateValueOn);
  if (config.useSearxng) {
    if (!config.searxngURL.length) config.searxngURL = @"http://localhost:8080";
  } else {
    config.searxngURL = nil;
  }
  config.allowLocalCLI = YES;
  [self updateCopilotAudioControls];
  config.sendAudio = self.copilotSendAudioButton.state == NSControlStateValueOn;
  NSError* err = nil;
  if ([config saveToDisk:&err]) {
    [self resetCopilotLog:[NSString stringWithFormat:@"Configuration saved for provider '%@' (model: %@).", config.provider, config.model]];
    [self refreshCopilotModelsUIForced:YES];
  } else {
    [self resetCopilotLog:[NSString stringWithFormat:@"Failed to save config: %@", err.localizedDescription]];
  }
}

- (void)copilotSearxngToggled:(id)sender {
  (void)sender;
  BOOL enabled = (self.copilotSearxngButton.state == NSControlStateValueOn);
  RigAIConfig* config = [RigAICopilot sharedCopilot].config;
  config.useSearxng = enabled;
  if (enabled) {
    if (!config.searxngURL.length) config.searxngURL = @"http://localhost:8080";
    [self appendCopilotLog:@"SearXNG gear research enabled."];
    __weak NAMRigUIController* weakSelf = self;
    rigAIEnsureSearxngRunning(^(BOOL success, NSString* msg) {
      if (success) {
        [weakSelf appendCopilotLog:[NSString stringWithFormat:@"✓ SearXNG ready (%@).", msg]];
      } else {
        [weakSelf appendCopilotLog:[NSString stringWithFormat:@"⚠️ SearXNG notice: %@.", msg]];
      }
    });
  } else {
    config.searxngURL = nil;
    [self appendCopilotLog:@"SearXNG gear research disabled."];
  }
}

- (void)executeCopilotDial:(id)sender {
  (void)sender;
  if (self.copilotLocalMatching) return;
  NSString* prompt = self.copilotPromptInput.stringValue;
  if (!prompt.length || !_state) return;
  RigRiffRecorder* recorder = [RigRiffRecorder sharedRecorder];
  if (recorder.isRecording || recorder.isRendering) {
    [self resetCopilotLog:@"Stop recording or wait for DI rendering before requesting a tone."]; return;
  }
  RigPreset* previousProposal = self.copilotProposal.proposedPreset;
  if (self.copilotModePopup.indexOfSelectedItem == 2 && !previousProposal) {
    [self resetCopilotLog:@"Generate a proposal first, or select New preset / Modify current preset."]; return;
  }

  // Auto-save any edited config fields first
  RigAIConfig* config = [RigAICopilot sharedCopilot].config;
  config.provider = self.copilotProvPopup.titleOfSelectedItem.lowercaseString;
  config.model = self.copilotModelComboBox.stringValue;
  config.apiKey = self.copilotKeyField.stringValue;
  config.baseURL = self.copilotURLField.stringValue;
  config.useSearxng = (self.copilotSearxngButton.state == NSControlStateValueOn);
  if (config.useSearxng) {
    if (!config.searxngURL.length) config.searxngURL = @"http://localhost:8080";
  } else {
    config.searxngURL = nil;
  }
  config.allowLocalCLI = YES;
  [self updateCopilotAudioControls];
  config.sendAudio = self.copilotSendAudioButton.state == NSControlStateValueOn;
  NSError* configError = nil;
  if (![config saveToDisk:&configError]) {
    [self resetCopilotLog:[NSString stringWithFormat:@"Could not save AI settings securely: %@", configError.localizedDescription]]; return;
  }
  self.copilotProposal = nil;
  self.copilotApplyBtn.enabled = NO;
  self.copilotCancelBtn.enabled = YES;
  self.copilotLocalMatches = nil;
  self.copilotPresetNameField.stringValue = @"";

  self.copilotDialBtn.enabled = NO;
  [self.copilotSpinner startAnimation:nil];
  if (_state->aiCopilotBtn) _state->aiCopilotBtn.title = @"⏳ AI Tone Tuning…";

  NSString* localCLI = config.allowLocalCLI ? [RigAICopilot detectLocalCLIForProvider:config.provider] : nil;
  RigPreset* live = [RigPreset captureFromState:_state name:_state->presetManager.currentPresetName ?: @"Current rig"];
  self.copilotBaseContext = [RigAICopilot contextForPreset:live compact:NO];
  self.copilotBasePreset = self.copilotModePopup.indexOfSelectedItem == 0 ? [RigPreset defaultPreset] :
      (self.copilotModePopup.indexOfSelectedItem == 2 ? previousProposal : live);
  NSMutableString* desc = [NSMutableString string];
  [desc appendFormat:@"REQUEST MODE: %@. The supplied base preset defines what will be applied; do not assume the live rig is that base.\n",
      self.copilotModePopup.titleOfSelectedItem];
  if (recorder.recordedWavData.length) {
    [desc appendFormat:@"PLAYER TAKE:\n%@\n", recorder.audioAnalysisSummary];
    if (recorder.recordingPreset) {
      NSData* data = [NSJSONSerialization dataWithJSONObject:[RigAICopilot contextForPreset:recorder.recordingPreset compact:YES] options:0 error:nil];
      [desc appendFormat:@"RECORDING-TIME RIG (not necessarily current): %@\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
    }
    [desc appendFormat:@"RECORDING-TIME PLAYER METADATA: %@\n", recorder.recordingMetadata];
  }
  if (recorder.referenceWavData.length) [desc appendFormat:@"%@\n", recorder.referenceAnalysis];
  if (recorder.candidateAnalysis.length) {
    [desc appendFormat:@"PREVIOUS DI AUDITION (not the current rig):\n%@\n", recorder.candidateAnalysis];
    if (self.copilotAuditionContext) {
      NSData* data = [NSJSONSerialization dataWithJSONObject:self.copilotAuditionContext options:0 error:nil];
      [desc appendFormat:@"AUDITIONED CANDIDATE SETTINGS: %@\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
    }
  }
  if (self.copilotGuitarInfo.stringValue.length) [desc appendFormat:@"PLAYER CONTEXT NOW: %@\n", self.copilotGuitarInfo.stringValue];
  NSMutableArray* clips = [NSMutableArray array];
  auto attach = [&](NSString* label, NSData* data) {
    if (data.length) [clips addObject:@{@"label":label, @"data":data, @"mime":@"audio/wav"}];
  };
  attach(@"PLAYER RAW DI: before all app processing, not normalized", recorder.recordedDIWavData);
  attach(@"PLAYER PROCESSED OUTPUT: recording-time rig", recorder.recordedWavData);
  attach(@"TARGET REFERENCE: see isolated/full-mix label in analysis", recorder.referenceWavData);
  // Keep uploads to three short clips. Candidate feedback is telemetry, locally generated.
  NSString* audioNote = config.sendAudio && config.canSendAudio
      ? @"\nSending guitar/target audio clips to cloud AI for this preview (extra cost)."
      : @"\nText + audio measurements only; no recordings uploaded or heard. Target sound stays local.";
  [recorder invalidatePreview];
  [self updateCopilotRiffUI];

  NSString* transport = config.effectiveApiKey.length > 0 ? [NSString stringWithFormat:@"cloud %@ API", config.provider] :
      (localCLI ? [NSString stringWithFormat:@"local CLI %@", localCLI.lastPathComponent] :
       [NSString stringWithFormat:@"%@ endpoint", config.provider]);
  [self resetCopilotLog:[NSString stringWithFormat:@"PREVIEW TONE — \"%@\"", prompt]];
  [self appendCopilotLog:[NSString stringWithFormat:@"Mode: %@", self.copilotModePopup.titleOfSelectedItem]];
  [self appendCopilotLog:[NSString stringWithFormat:@"Base preset: %@ · pedal %@ · amp %@ · cab %@",
      self.copilotBasePreset.name ?: @"(none)",
      [self.copilotBasePreset stageAtIndex:0]->path.empty() ? @"—" : [NSString stringWithUTF8String:[self.copilotBasePreset stageAtIndex:0]->path.c_str()].lastPathComponent,
      [self.copilotBasePreset stageAtIndex:1]->path.empty() ? @"—" : [NSString stringWithUTF8String:[self.copilotBasePreset stageAtIndex:1]->path.c_str()].lastPathComponent,
      [self.copilotBasePreset stageAtIndex:2]->path.empty() ? @"—" : [NSString stringWithUTF8String:[self.copilotBasePreset stageAtIndex:2]->path.c_str()].lastPathComponent]];
  [self appendCopilotLog:[NSString stringWithFormat:@"Provider: %@ · model %@ · %@", transport, config.model,
      [[audioNote stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@"\n"].firstObject]];
  if (recorder.recordedWavData.length) [self appendCopilotLog:[NSString stringWithFormat:@"Take attached: %.1f s%@%@", recorder.recordedDuration,
      recorder.recordedDIFrames.length ? @" (DI + output)" : @" (output only)", recorder.referenceWavData.length ? @", target reference attached" : @""]];
  else [self appendCopilotLog:@"No take attached: text-only request."];

  __weak NAMRigUIController* weakSelf = self;
  auto alive = _state->isAlive;
  RigPreset* base = self.copilotBasePreset;
  [[RigAICopilot sharedCopilot] processUserPrompt:prompt
                                        audioClips:clips
                                  audioDescription:desc.length ? desc : nil
                                        basePreset:base
                                        withState:_state
                                completionHandler:^(RigAICopilotResult* res, NSError* err) {
    if (!weakSelf || !alive || !*alive) return;
    [weakSelf.copilotSpinner stopAnimation:nil];
    weakSelf.copilotDialBtn.enabled = YES;
    weakSelf.copilotCancelBtn.enabled = NO;
    RigUIState* st = weakSelf.state;

    if (err) {
      if (st && st->aiCopilotBtn) st->aiCopilotBtn.title = @"✨ AI Tone Tuning";
      [weakSelf appendCopilotLog:[NSString stringWithFormat:@"❌ FAILED — %@", err.localizedDescription]];
      [weakSelf appendCopilotLog:@"Nothing was changed. Fix the issue above and press Preview Tone again."];
      [weakSelf updateCopilotRiffUI];
      return;
    }

    if (!res) {
      if (st && st->aiCopilotBtn) st->aiCopilotBtn.title = @"✨ AI Tone Tuning";
      [weakSelf appendCopilotLog:@"❌ FAILED — no tone proposal returned."];
      return;
    }
    NSError* presetError = nil;
    res.proposedPreset = [RigAICopilot presetForResult:res base:base error:&presetError];
    if (!res.proposedPreset) {
      if (st && st->aiCopilotBtn) st->aiCopilotBtn.title = @"✨ AI Tone Tuning";
      [weakSelf appendCopilotLog:[NSString stringWithFormat:@"❌ FAILED — invalid proposal: %@", presetError.localizedDescription]];
      [weakSelf appendCopilotLog:@"Nothing was changed. Press Preview Tone to request a new proposal."];
      return;
    }
    weakSelf.copilotProposal = res;
    weakSelf.copilotApplyBtn.enabled = YES;
    if (st && st->aiCopilotBtn) {
      const BOOL shown = st->aiCopilotPopover && st->aiCopilotPopover.isShown;
      st->aiCopilotBtn.title = shown ? @"✨ AI Tone Tuning" : @"✨ AI Tone Ready";
    }
    [[RigAICopilot sharedCopilot] completeCurrentTaskWithResult:res savedPresetName:nil];
    weakSelf.copilotPresetNameField.stringValue = @"";
    NSString* plannedName = [weakSelf plannedCopilotPresetName];
    weakSelf.copilotPresetNameField.stringValue = plannedName;

    NSMutableString* msg = [NSMutableString string];
    [msg appendString:@"✅ PREVIEW READY — live rig unchanged.\n"];
    [msg appendFormat:@"Apply & Save will create preset: '%@' (edit the Save as field to rename)\n\n", plannedName];
    if (res.inputTokens > 0 || res.outputTokens > 0 || res.tokenCost > 0.0) {
      [msg appendFormat:@"• TOKEN USAGE & COST: %ld in / %ld out · Cost: $%.5f (In: $%.5f, Out: $%.5f)\n\n",
          (long)res.inputTokens, (long)res.outputTokens, res.tokenCost, res.inputCost, res.outputCost];
    }
    [msg appendFormat:@"SUMMARY:\n%@\n\n", res.explanation ?: @""];
    if (res.thought.length) {
      [msg appendFormat:@"ENGINEERING REASONING:\n%@\n\n", res.thought];
    }
    auto stageName = [&](size_t s) -> NSString* {
      const std::string& path = [res.proposedPreset stageAtIndex:s]->path;
      return path.empty() ? @"(none)" : [NSString stringWithUTF8String:path.c_str()].lastPathComponent;
    };
    [msg appendFormat:@"• Pedal: %@%@\n", stageName(0), res.pedalPath.length ? @"  ← changed" : @"  (kept from base)"];
    [msg appendFormat:@"• Amp: %@%@\n", stageName(1), res.ampPath.length ? @"  ← changed" : @"  (kept from base)"];
    [msg appendFormat:@"• Cab A: %@%@\n", stageName(2), res.cabPath.length ? @"  ← changed" : @"  (kept from base)"];
    if (res.controls.count > 0) {
      [msg appendString:@"• Proposed Controls (engine units):\n"];
      for (NSString* k in [res.controls.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [msg appendFormat:@"   - %@: %@\n", k, res.controls[k]];
      }
    }
    [weakSelf appendCopilotLog:[NSString stringWithFormat:@"Preview complete (Tokens: %ld in / %ld out · Cost: $%.5f).",
        (long)res.inputTokens, (long)res.outputTokens, res.tokenCost]];
    [weakSelf appendCopilotLog:msg];
    [weakSelf updateCopilotRiffUI];
  }];
}

- (void)toggleCopilotPlayAlong:(id)sender {
  (void)sender;
  if (self.copilotLocalMatching) return;
  RigRiffRecorder* recorder = [RigRiffRecorder sharedRecorder];
  if (recorder.isRecording || (self.copilotRiffTimer && self.copilotRecordCountdown > 0)) {
    const BOOL wasCountdown = !recorder.isRecording;
    [recorder stopPlayAlong];
    [self.copilotRiffTimer invalidate];
    self.copilotRiffTimer = nil;
    self.copilotRecordCountdown = 0;
    self.copilotRecordIsPlayAlong = NO;
    [self setCopilotLiveLine:nil];
    [self appendCopilotLog:wasCountdown ? @"Play-along cancelled before it started." :
        [NSString stringWithFormat:@"■ Play-along stopped at %.1f s.", recorder.recordedDuration]];
    [self updateCopilotRiffUI];
  } else {
    if (!recorder.referenceFrames.length) {
      [self appendCopilotLog:@"Load a target sound before starting Play Along."];
      return;
    }
    self.copilotRecordIsPlayAlong = YES;
    [self startCopilotRecordingWithGuided:NO playAlong:YES];
  }
}

- (void)toggleCopilotRecordRiff:(id)sender {
  (void)sender;
  if (self.copilotLocalMatching) return;
  RigRiffRecorder* recorder = [RigRiffRecorder sharedRecorder];
  if (recorder.isRecording || (self.copilotRiffTimer && self.copilotRecordCountdown > 0)) {
    const BOOL wasCountdown = !recorder.isRecording;
    [recorder stopRecording];
    [self.copilotRiffTimer invalidate];
    self.copilotRiffTimer = nil;
    self.copilotRecordCountdown = 0;
    self.copilotRecordIsPlayAlong = NO;
    [self setCopilotLiveLine:nil];
    [self appendCopilotLog:wasCountdown ? @"Recording cancelled before it started." :
        [NSString stringWithFormat:@"■ Stopped manually at %.1f s. Describe the tone you want and press Preview Tone.", recorder.recordedDuration]];
    [self updateCopilotRiffUI];
  } else {
    self.copilotRecordIsPlayAlong = NO;
    const BOOL guided = self.copilotGuidedButton.state == NSControlStateValueOn;
    [self startCopilotRecordingWithGuided:guided playAlong:NO];
  }
}

- (void)startCopilotRecordingWithGuided:(BOOL)guided playAlong:(BOOL)playAlong {
  RigRiffRecorder* recorder = [RigRiffRecorder sharedRecorder];
  if (!_state || [RigAICopilot sharedCopilot].isProcessing || recorder.isRendering) return;
  if ([RigAICopilot sharedCopilot].isApplying) {
    [self appendCopilotLog:@"⚠️ Wait for the tone application to finish before recording a paired take."]; return;
  }
  if (self.copilotRiffTimer) return; // countdown already running
  const int pendingStage = _state->unconfirmedRecordingStage();
  if (pendingStage >= 0) {
    const char* roles[] = {"Pedal", "Amp", "Cab A", "Cab B"};
    NSString* selected = [NSString stringWithUTF8String:_state->selectedPaths[pendingStage].c_str()];
    NSString* confirmed = [NSString stringWithUTF8String:_state->confirmedPaths[pendingStage].c_str()];
    [self appendCopilotLog:[NSString stringWithFormat:
        @"⚠️ Recording blocked: %s is enabled but its model is not confirmed (selected: %@; engine: %@). Refreshing engine status. If this persists, reload that stage or bypass it before recording.",
        roles[pendingStage], selected.length ? selected.lastPathComponent : @"none",
        confirmed.length ? confirmed.lastPathComponent : @"none"]];
    _state->sendGet();
    return;
  }
  self.copilotLocalMatches = nil;
  self.copilotProposal = nil; self.copilotApplyBtn.enabled = NO;
  self.copilotAuditionContext = nil;
  if (self.copilotModePopup.indexOfSelectedItem == 2) [self.copilotModePopup selectItemAtIndex:0];
  self.copilotRenderBtn.enabled = NO; self.copilotDialBtn.enabled = NO;
  self.copilotPlayBtn.enabled = NO;
  self.copilotClearBtn.enabled = NO;
  self.copilotRiffStatusLabel.textColor = [NSColor systemRedColor];

  NSMutableString* plan = [NSMutableString string];
  if (playAlong) {
    [plan appendString:@"PLAY-ALONG TAKE — listen to the target sound in your monitors/headphones and play the same riff. Audio will be aligned note-by-note via DTW.\n"];
  } else if (guided) {
    [plan appendString:@"GUIDED 20-SECOND TAKE — follow each step when it appears below. A beep marks each step change.\n"];
    for (NSDictionary* segment in [RigRiffRecorder guidedPlan])
      [plan appendFormat:@"  %@–%@ s  %@ — %@\n", segment[@"start"], segment[@"end"], segment[@"label"], segment[@"instruction"]];
  } else {
    [plan appendString:@"FREE TAKE (up to 20 s) — play a representative riff with soft and hard picking and a note that fades.\n"];
  }
  [plan appendString:@"Keep guitar volume, pickup and interface gain unchanged during the take. Do not touch rig controls."];
  [self resetCopilotLog:plan];
  self.copilotRecordCountdown = 3;
  self.copilotLastGuidedSegment = -1;
  if (playAlong) self.copilotPlayAlongBtn.title = @"■ Cancel";
  else self.copilotRecordBtn.title = @"■ Cancel";
  self.copilotRiffStatusLabel.stringValue = @"Get ready… recording starts in 3";
  [self setCopilotLiveLine:@"⏳ Get ready… 3"];
  NSBeep();

  __weak NAMRigUIController* weakSelf = self;
  NSDate* countdownStart = NSDate.date;
  self.copilotRiffTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer* timer) {
    if (!weakSelf) { [timer invalidate]; return; }
    RigRiffRecorder* r = [RigRiffRecorder sharedRecorder];
    RigUIState* state = weakSelf.state;
    if (weakSelf.copilotRecordCountdown > 0) {
      const NSInteger left = (NSInteger)std::ceil(3.0 + countdownStart.timeIntervalSinceNow);
      if (left == weakSelf.copilotRecordCountdown) return;
      weakSelf.copilotRecordCountdown = std::max<NSInteger>(0, left);
      NSBeep();
      if (weakSelf.copilotRecordCountdown > 0) {
        weakSelf.copilotRiffStatusLabel.stringValue = [NSString stringWithFormat:@"Get ready… recording starts in %ld", (long)weakSelf.copilotRecordCountdown];
        [weakSelf setCopilotLiveLine:[NSString stringWithFormat:@"⏳ Get ready… %ld", (long)weakSelf.copilotRecordCountdown]];
        return;
      }
      if (!state || !*state->isAlive) { [timer invalidate]; weakSelf.copilotRiffTimer = nil; return; }
      if (state->unconfirmedRecordingStage() >= 0 || [RigAICopilot sharedCopilot].isApplying) {
        [timer invalidate]; weakSelf.copilotRiffTimer = nil;
        [weakSelf setCopilotLiveLine:nil];
        [weakSelf appendCopilotLog:@"⚠️ Recording cancelled: an active model changed during the countdown. Wait for loading, then press Record Riff again."];
        state->sendGet();
        [weakSelf updateCopilotRiffUI];
        return;
      }
      if (playAlong) [r startPlayAlong];
      else [r startRecordingGuided:guided];
      r.recordingPreset = [RigPreset captureFromState:state name:state->presetManager.currentPresetName ?: @"Recorded rig"];
      r.recordingMetadata = @{@"player_context":weakSelf.copilotGuitarInfo.stringValue ?: @"unknown",
          @"hardware_input_gain":@"unknown unless supplied by player", @"captured_at":NSDate.date.description,
          @"play_along":@(playAlong)};
      if (playAlong) weakSelf.copilotPlayAlongBtn.title = @"■ Stop (0:00)";
      else weakSelf.copilotRecordBtn.title = @"■ Stop (0:00)";
      [weakSelf appendCopilotLog:playAlong ? @"● Play-along recording started." : @"● Recording started."];
      return;
    }
    if (state && *state->isAlive && r.recordingPreset) {
      NSDictionary* before = [RigAICopilot contextForPreset:r.recordingPreset compact:NO];
      NSDictionary* now = [RigAICopilot contextForPreset:[RigPreset captureFromState:state name:r.recordingPreset.name] compact:NO];
      if (![before isEqual:now]) {
        NSMutableDictionary* metadata = [r.recordingMetadata mutableCopy];
        metadata[@"warning"] = @"Rig changed during this take; processed audio may not correspond to the starting snapshot. Record again for reliable analysis.";
        r.recordingMetadata = metadata;
      }
    }
    if (!r.isRecording) {
      [r stopRecording];
      [timer invalidate];
      weakSelf.copilotRiffTimer = nil;
      weakSelf.copilotRecordIsPlayAlong = NO;
      [weakSelf setCopilotLiveLine:nil];
      [weakSelf appendCopilotLog:[NSString stringWithFormat:@"■ Take complete: %.1f s, peak %.1f dBFS%@. Describe the tone you want and press Preview Tone.",
          r.recordedDuration, r.peakDbfs, r.recordingMetadata[@"warning"] ? @" — WARNING: rig changed during the take; record again" : @""]];
      [weakSelf updateCopilotRiffUI];
      return;
    }
    NSString* stopTitle = [NSString stringWithFormat:@"■ Stop (0:%02d)", (int)r.recordedDuration];
    if (playAlong) weakSelf.copilotPlayAlongBtn.title = stopTitle;
    else weakSelf.copilotRecordBtn.title = stopTitle;
    weakSelf.copilotRiffLevelBar.doubleValue = r.currentPeakLevel;
    const NSInteger segmentIndex = r.guidedSegmentIndex;
    NSArray* planSegs = [RigRiffRecorder guidedPlan];
    if (segmentIndex >= 0 && segmentIndex < (NSInteger)planSegs.count) {
      NSDictionary* segment = planSegs[(NSUInteger)segmentIndex];
      if (segmentIndex != weakSelf.copilotLastGuidedSegment) {
        weakSelf.copilotLastGuidedSegment = segmentIndex;
        NSBeep();
        [weakSelf appendCopilotLog:[NSString stringWithFormat:@"● %.0f–%.0fs: %@ (%@)",
            [segment[@"start"] doubleValue], [segment[@"end"] doubleValue], segment[@"label"], segment[@"instruction"]]];
      }
      [weakSelf setCopilotLiveLine:[NSString stringWithFormat:@"▶ %d:%02d  %@ — %@",
          (int)r.recordedDuration / 60, (int)r.recordedDuration % 60, segment[@"label"], segment[@"instruction"]]];
      weakSelf.copilotRiffStatusLabel.stringValue = [NSString stringWithFormat:@"%@ (%d:%02d)",
          segment[@"label"], (int)r.recordedDuration / 60, (int)r.recordedDuration % 60];
    } else {
      [weakSelf setCopilotLiveLine:[NSString stringWithFormat:@"▶ %d:%02d recording…",
          (int)r.recordedDuration / 60, (int)r.recordedDuration % 60]];
      weakSelf.copilotRiffStatusLabel.stringValue = [NSString stringWithFormat:@"Recording… (%d:%02d)",
          (int)r.recordedDuration / 60, (int)r.recordedDuration % 60];
    }
  }];
}

- (void)playCopilotRiff:(id)sender {
  (void)sender;
  RigRiffRecorder* r = [RigRiffRecorder sharedRecorder];
  if (r.isPlaying) {
    [r stopPlayback];
  } else {
    NSArray* tracks = @[@"processed", @"di", @"baseline", @"candidate", @"reference", @"backing"];
    NSInteger i = self.copilotTrackPopup.indexOfSelectedItem;
    if (i >= 0 && i < (NSInteger)tracks.count) {
      [r playTrack:tracks[i]];
    }
  }
  [self updateCopilotRiffUI];
}

- (void)toggleCopilotTargetPreview:(id)sender {
  (void)sender;
  RigRiffRecorder* r = [RigRiffRecorder sharedRecorder];
  if (r.isPlaying && ([r.currentPlayingTrack isEqualToString:@"reference"] || [r.currentPlayingTrack isEqualToString:@"target"])) {
    [r stopPlayback];
  } else {
    [r stopPlayback];
    if (self.copilotTrackPopup.numberOfItems > 4) {
      [self.copilotTrackPopup selectItemAtIndex:4];
    }
    [r playTrack:@"reference"];
  }
  [self updateCopilotRiffUI];
}

- (void)clearCopilotRiff:(id)sender {
  (void)sender;
  if (self.copilotLocalMatching) return;
  [self.copilotRiffTimer invalidate];
  self.copilotRiffTimer = nil;
  self.copilotRecordCountdown = 0;
  [self setCopilotLiveLine:nil];
  [[RigRiffRecorder sharedRecorder] clearRecording];
  self.copilotProposal = nil; self.copilotApplyBtn.enabled = NO;
  self.copilotLocalMatches = nil;
  self.copilotAuditionContext = nil;
  if (self.copilotModePopup.indexOfSelectedItem == 2) [self.copilotModePopup selectItemAtIndex:0];
  [self updateCopilotRiffUI];
}

- (void)updateCopilotRiffUI {
  RigRiffRecorder* r = [RigRiffRecorder sharedRecorder];
  const BOOL countingDown = self.copilotRiffTimer && !r.isRecording && self.copilotRecordCountdown > 0;
  const BOOL normalCountingDown = countingDown && !self.copilotRecordIsPlayAlong;
  const BOOL normalRecording = r.isRecording && !self.copilotRecordIsPlayAlong;
  self.copilotRecordBtn.title = normalRecording ? [NSString stringWithFormat:@"■ Stop (0:%02d)", (int)r.recordedDuration] :
      (normalCountingDown ? @"■ Cancel" : @"● Record Riff");
  const BOOL playAlongCountingDown = countingDown && self.copilotRecordIsPlayAlong;
  const BOOL playAlongRecording = r.isRecording && self.copilotRecordIsPlayAlong;
  self.copilotPlayAlongBtn.title = playAlongRecording ? [NSString stringWithFormat:@"■ Stop (0:%02d)", (int)r.recordedDuration] :
      (playAlongCountingDown ? @"■ Cancel" : @"● Play Along");
  self.copilotRiffLevelBar.doubleValue = r.isRecording ? r.currentPeakLevel : 0.0;
  const BOOL busy = self.copilotLocalMatching || r.isRendering || r.isRecording || countingDown ||
      [RigAICopilot sharedCopilot].isProcessing || [RigAICopilot sharedCopilot].isApplying;
  self.copilotRenderBtn.enabled = r.renderHandler && r.recordedDIFrames.length && self.copilotProposal && !busy;
  self.copilotDialBtn.enabled = !busy;
  self.copilotRecordBtn.enabled = r.renderHandler && !self.copilotLocalMatching && !r.isRendering &&
      ![RigAICopilot sharedCopilot].isProcessing && ![RigAICopilot sharedCopilot].isApplying;
  self.copilotPlayAlongBtn.enabled = r.renderHandler && r.referenceFrames.length > 0 && !self.copilotLocalMatching && !r.isRendering &&
      ![RigAICopilot sharedCopilot].isProcessing && ![RigAICopilot sharedCopilot].isApplying;
  NSMutableArray<NSString*>* missing = [NSMutableArray array];
  if (!r.renderHandler) [missing addObject:@"Open standalone Axe FX to record raw guitar"];
  if (!r.recordedDIFrames.length) [missing addObject:@"record your guitar (raw DI)"];
  else if (r.isDIClipped) [missing addObject:@"lower interface gain & re-record (raw DI clipped)"];
  if (!r.referenceFrames.length) [missing addObject:@"load a target guitar sound"];
  else if (r.referenceIsFullMix) [missing addObject:@"use a guitar-only target, not a full song mix"];
  if (r.recordingMetadata[@"warning"]) [missing addObject:@"re-record without changing the rig"];
  self.copilotLocalMatchBtn.enabled = !missing.count && !busy;
  NSString* matchStatus = self.copilotLocalMatching ? @"Training locally… no AI charge. Cancel stops after the current render." :
      (missing.count ? [@"To enable: " stringByAppendingString:[missing componentsJoinedByString:@"; "]] :
       (busy ? @"Finish recording/rendering before local matching." : @"Ready: Learn & Match → Render DI A/B → listen → Apply & Save. No AI charge."));
  self.copilotLocalMatchStatus.stringValue = matchStatus;
  self.copilotLocalMatchStatus.toolTip = matchStatus;
  self.copilotLocalMatchStatus.textColor = missing.count ? [NSColor systemOrangeColor] : rigDimText();
  self.copilotLocalMatchBtn.toolTip = matchStatus;
  NSString* targetStatus = !r.referenceFrames.length ? @"Target sound: not loaded — choose the guitar sound you want to match." :
      (r.referenceIsFullMix ? @"Target sound: full song mix — AI context only; local matching needs guitar-only audio." :
       [NSString stringWithFormat:@"Target: %@ · %.0fs section · local, not uploaded",
           [r.referenceSource isEqualToString:@"demucs"] ? @"Demucs guitar stem" : @"guitar-only track", r.referenceSelectionLength]);
  self.copilotTargetStatus.stringValue = targetStatus;
  self.copilotTargetStatus.toolTip = r.referenceFrames.length ? r.referenceAnalysis : targetStatus;
  self.copilotTargetStatus.textColor = r.referenceIsFullMix ? [NSColor systemOrangeColor] : rigDimText();
  const BOOL hasTarget = r.referenceTotalDuration > 0;
  const BOOL sectionEditable = hasTarget && !busy && !self.copilotDemucsRunning;
  for (NSControl* control in @[self.copilotTargetAutoButton, self.copilotTargetStartField,
                               self.copilotTargetStartStepper, self.copilotTargetLengthPopup])
    control.enabled = sectionEditable;
  self.copilotTargetAutoButton.state = !hasTarget || r.referenceSelectionAuto ? NSControlStateValueOn : NSControlStateValueOff;
  // Do not overwrite a start time the user is typing.
  if (!self.copilotTargetStartField.currentEditor)
    self.copilotTargetStartField.stringValue = hasTarget ? copilotClock(r.referenceSelectionStart) : @"";
  self.copilotTargetStartStepper.maxValue = std::max(0.0, r.referenceTotalDuration - r.referenceSelectionLength);
  self.copilotTargetStartStepper.doubleValue = r.referenceSelectionStart;
  if (hasTarget) {
    const NSInteger lengthTag = std::clamp<NSInteger>((std::lround(r.referenceSelectionLength) + 4) / 5 * 5, 5, 20);
    [self.copilotTargetLengthPopup selectItemWithTag:lengthTag];
  }
  self.copilotTargetRangeLabel.stringValue = hasTarget ?
      [NSString stringWithFormat:@"of %@%@", copilotClock(r.referenceTotalDuration), r.referenceTruncated ? @"+" : @""] : @"";
  self.copilotTargetRangeLabel.toolTip = r.referenceTruncated ? @"Very long file: only the first part fits in memory." : nil;
  self.copilotMatchCandidates.enabled = self.copilotLocalMatches.count > 0 && !busy;
  const NSInteger selectedMatch = self.copilotMatchCandidates.indexOfSelectedItem;
  self.copilotMatchMixEQButton.enabled = !busy && selectedMatch >= 0 && selectedMatch < (NSInteger)self.copilotLocalMatches.count &&
      self.copilotLocalMatches[(NSUInteger)selectedMatch].presetWithoutMixEQ != nil;
  self.copilotMatchResearchButton.enabled = !busy;
  self.copilotMatchOnlineButton.enabled = !busy;
  self.copilotAccurateRescoreButton.enabled = !busy && [r.referenceSource isEqualToString:@"demucs"];
  self.copilotEmbeddingRerankButton.enabled = !busy;
  self.copilotApplyBtn.enabled = self.copilotProposal != nil && !busy;
  self.copilotUndoBtn.enabled = [RigAICopilot sharedCopilot].canUndo && !busy;
  self.copilotCancelBtn.enabled = self.copilotLocalMatching || self.copilotDemucsRunning || [RigAICopilot sharedCopilot].isProcessing;
  self.copilotRecordBtn.toolTip = r.renderHandler ? @"Record YOUR guitar: raw DI before processing plus the rig output. Needed for Learn & Match." : @"Record Riff requires the standalone Axe FX app (captures raw DI + processed output).";
  const BOOL hasBacking = (r.referenceBackingFrames.length > 0 && r.referenceBackingWavData.length > 0);
  NSArray* available = @[
    @(r.recordedWavData.length > 0),
    @(r.recordedDIWavData.length > 0),
    @(r.baselineWavData.length > 0),
    @(r.candidateWavData.length > 0),
    @(r.referenceWavData.length > 0),
    @(hasBacking)
  ];
  self.copilotTrackPopup.autoenablesItems = NO;
  for (NSUInteger i = 0; i < available.count && i < (NSUInteger)self.copilotTrackPopup.numberOfItems; ++i) {
    [self.copilotTrackPopup itemAtIndex:i].enabled = [available[i] boolValue];
  }
  NSInteger selected = self.copilotTrackPopup.indexOfSelectedItem;
  if (selected < 0 || selected >= (NSInteger)available.count || ![available[selected] boolValue]) {
    for (NSUInteger i = 0; i < available.count && i < (NSUInteger)self.copilotTrackPopup.numberOfItems; ++i) {
      if ([available[i] boolValue]) { [self.copilotTrackPopup selectItemAtIndex:i]; break; }
    }
  }

  const BOOL targetIsPlaying = r.isPlaying && ([r.currentPlayingTrack isEqualToString:@"reference"] ||
                                               [r.currentPlayingTrack isEqualToString:@"target"] ||
                                               (r.currentPlayingTrack == nil && self.copilotTrackPopup.indexOfSelectedItem == 4));
  self.copilotTargetPlayBtn.title = targetIsPlaying ? @"❚❚ Stop" : @"▶ Preview";
  self.copilotTargetPlayBtn.enabled = (r.referenceWavData.length > 0) && !busy && !self.copilotDemucsRunning;
  self.copilotTargetPlayBtn.toolTip = targetIsPlaying ? @"Stop target sound preview." :
      ([r.referenceSource isEqualToString:@"demucs"] ? @"Preview the extracted guitar stem through system audio." : @"Preview the loaded target guitar sound.");

  self.copilotPlayBtn.enabled = (r.recordedWavData.length > 0 || r.referenceWavData.length > 0) && !busy;
  self.copilotPlayBtn.title = r.isPlaying ? @"❚❚ Stop" : @"▶ Play";
  self.copilotClearBtn.enabled = r.recordedWavData.length > 0 && !busy;
  self.copilotTargetClearBtn.enabled = r.referenceTotalDuration > 0 && !busy && !self.copilotDemucsRunning;

  if (r.isRecording) {
    self.copilotRiffStatusLabel.stringValue = r.guidance;
    self.copilotPlayBtn.enabled = NO; self.copilotClearBtn.enabled = NO; return;
  }

  if (r.recordedWavData.length > 0) {
    if (r.isDIClipped) {
      self.copilotRiffStatusLabel.stringValue = [NSString stringWithFormat:
        @"Your guitar: raw DI CLIPPED (%.1f dBFS) — lower interface gain & re-record", r.diPeakDbfs];
      self.copilotRiffStatusLabel.textColor = [NSColor systemRedColor];
    } else {
      self.copilotRiffStatusLabel.stringValue = [NSString stringWithFormat:
        @"Your guitar: %@ · %.1fs · output peak %.1f dBFS",
        r.recordedDIFrames.length ? @"raw DI + output" : @"recorded output", r.recordedDuration, r.peakDbfs];
      self.copilotRiffStatusLabel.textColor = [NSColor systemGreenColor];
    }
  } else if (r.referenceWavData.length > 0) {
    self.copilotRiffStatusLabel.stringValue = r.isPlaying ?
        [NSString stringWithFormat:@"Playing %@… (click ❚❚ Stop or ▶ Preview to pause)", self.copilotTrackPopup.titleOfSelectedItem ?: @"target sound"] :
        [NSString stringWithFormat:@"Target loaded: %@ · click ▶ Preview to audition",
            [r.referenceSource isEqualToString:@"demucs"] ? @"Demucs guitar stem" : @"guitar track"];
    self.copilotRiffStatusLabel.textColor = r.isPlaying ? [NSColor systemBlueColor] : rigDimText();
  } else {
    self.copilotRiffStatusLabel.stringValue = @"Your guitar: no recording. Record Riff captures raw DI + output.";
    self.copilotRiffStatusLabel.textColor = rigDimText();
  }
}

- (void)importCopilotReference:(id)sender {
  if (self.copilotLocalMatching || self.copilotDemucsRunning) return;
  RigRiffRecorder* r = [RigRiffRecorder sharedRecorder];
  if (r.isRecording || r.isRendering) return;
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.allowedFileTypes = @[@"wav", @"mp3", @"flac", @"m4a", @"aif", @"aiff", @"ogg", @"opus"];
  panel.title = @"Load target sound (extracts guitar stem)";
  panel.message = @"Choose a song or audio file. Axe FX extracts the guitar stem locally via Demucs by default. Hold Option to load an already-isolated guitar track as-is.";
  panel.prompt = @"Load target sound";
  panel.canChooseDirectories = NO; panel.allowsMultipleSelection = NO;
  __weak NAMRigUIController* weakSelf = self;
  [panel beginWithCompletionHandler:^(NSInteger response) {
    if (response != NSModalResponseOK || !panel.URL) return;
    const BOOL isGuitarStem = [panel.URL.lastPathComponent.lowercaseString isEqualToString:@"guitar.wav"];
    const BOOL optionHeld = ([NSEvent modifierFlags] & NSEventModifierFlagOption) != 0;
    if (optionHeld || isGuitarStem) {
      NSError* error = nil;
      if (![r loadReferenceFromURL:panel.URL fullMix:NO error:&error]) {
        [weakSelf resetCopilotLog:error.localizedDescription];
      } else {
        weakSelf.copilotLocalMatches = nil;
        [weakSelf.copilotTrackPopup selectItemAtIndex:4];
        [weakSelf resetCopilotLog:r.referenceAnalysis];
      }
      [weakSelf updateCopilotRiffUI];
    } else {
      [weakSelf runDemucsOnFile:panel.URL];
    }
  }];
}

- (void)clearCopilotReference:(id)sender {
  if (self.copilotLocalMatching) return;
  self.copilotLocalMatches = nil;
  RigRiffRecorder* r = [RigRiffRecorder sharedRecorder];
  [r stopPlayback];
  [r clearReference];
  [self updateCopilotRiffUI];
}

- (void)changeCopilotTargetSection:(id)sender {
  RigRiffRecorder* r = [RigRiffRecorder sharedRecorder];
  if (r.referenceTotalDuration <= 0 || self.copilotLocalMatching || self.copilotDemucsRunning ||
      r.isRendering || r.isRecording) { [self updateCopilotRiffUI]; return; }
  double start = r.referenceSelectionStart;
  BOOL automatic = r.referenceSelectionAuto;
  if (sender == self.copilotTargetAutoButton) automatic = self.copilotTargetAutoButton.state == NSControlStateValueOn;
  else if (sender == self.copilotTargetStartStepper) { start = self.copilotTargetStartStepper.doubleValue; automatic = NO; }
  else if (sender == self.copilotTargetStartField) { start = copilotParseClock(self.copilotTargetStartField.stringValue); automatic = NO; }
  const double length = MAX(5, self.copilotTargetLengthPopup.selectedTag);
  [r stopPlayback];
  [r selectReferenceStart:start length:length automatic:automatic];
  // Finalists were measured against the previous section.
  self.copilotLocalMatches = nil;
  [self resetCopilotLog:r.referenceAnalysis];
  [self updateCopilotRiffUI];
}

- (void)extractDemucsStem:(id)sender {
  [self importCopilotReference:sender];
}

- (void)runDemucsOnFile:(NSURL*)inputURL {
  NSAssert(NSThread.isMainThread, @"Must be called on main thread");
  if (self.copilotDemucsRunning) return;

  self.copilotDemucsRunning = YES;
  self.copilotDemucsSpinner.hidden = NO;
  [self.copilotDemucsSpinner startAnimation:nil];
  [self resetCopilotLog:[NSString stringWithFormat:@"Demucs: separating guitar stem from \"%@\"...",
      inputURL.lastPathComponent]];
  [self updateCopilotRiffUI];

  // Scratch directory for Demucs output — cleaned up on finish or error.
  NSString* tmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"axefx-demucs-%@", [[NSUUID UUID] UUIDString]]];
  [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir
                            withIntermediateDirectories:YES attributes:nil error:nil];

  __weak NAMRigUIController* weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    // ── 1. Find python3 ──────────────────────────────────────────────────
    NSString* python3 = findPython3();
    if (!python3) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf demucsFinishedWithError:@"Python 3 not found. Install Python from python.org or via Homebrew (brew install python)."];
      });
      return;
    }

    // ── 2. Check / install demucs and all dependencies ───────────────────
    NSError* installErr = nil;
    BOOL demucsReady = ensureDemucsInstalled(python3, ^(NSString* msg) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf appendCopilotLog:msg];
      });
    }, &installErr);

    if (!demucsReady) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf demucsFinishedWithError:installErr.localizedDescription ?: @"Failed to install Demucs and its dependencies."];
      });
      return;
    }

    // ── 3. Run Demucs ────────────────────────────────────────────────────
    // htdemucs_6s provides a dedicated guitar stem (guitar.wav) distinct
    // from bass, drums, vocals, piano, and other. --two-stems merges all
    // non-target stems and loses that precision.
    NSTask* demucsTask = [NSTask new];
    demucsTask.launchPath = python3;
    demucsTask.arguments = @[
      @"-m", @"demucs",
      @"--name=htdemucs_6s",
      @"--out", tmpDir,
      inputURL.path
    ];
    NSPipe* demucsPipe = [NSPipe pipe];
    demucsTask.standardOutput = demucsPipe;
    demucsTask.standardError = demucsPipe; // Demucs progress goes to stderr

    __block NSTask* taskRef = demucsTask;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (weakSelf) weakSelf.copilotDemucsTask = taskRef;
    });

    // Stream progress lines back to the log on the main thread.
    NSFileHandle* fh = demucsPipe.fileHandleForReading;
    __block NSMutableData* accumulator = [NSMutableData data];
    fh.readabilityHandler = ^(NSFileHandle* handle) {
      NSData* chunk = handle.availableData;
      if (!chunk.length) return;
      [accumulator appendData:chunk];
      // Flush complete lines
      NSString* str = [[NSString alloc] initWithData:accumulator encoding:NSUTF8StringEncoding];
      if (!str) return;
      NSArray<NSString*>* lines = [str componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
      if (lines.count > 1) {
        accumulator = [[lines.lastObject dataUsingEncoding:NSUTF8StringEncoding] mutableCopy] ?: [NSMutableData data];
        NSArray<NSString*>* completedLines = [lines subarrayWithRange:NSMakeRange(0, lines.count - 1)];
        dispatch_async(dispatch_get_main_queue(), ^{
          for (NSString* line in completedLines) {
            NSString* trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (trimmed.length) [weakSelf appendCopilotLog:[NSString stringWithFormat:@"Demucs: %@", trimmed]];
          }
        });
      }
    };

    NSError* demucsLaunchErr = nil;
    if (![demucsTask launchAndReturnError:&demucsLaunchErr]) {
      fh.readabilityHandler = nil;
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf demucsFinishedWithError:[NSString stringWithFormat:@"Could not launch Demucs: %@", demucsLaunchErr.localizedDescription]];
      });
      return;
    }
    [demucsTask waitUntilExit];
    fh.readabilityHandler = nil;

    if (demucsTask.terminationStatus != 0) {
      NSString* partial = [[NSString alloc] initWithData:accumulator encoding:NSUTF8StringEncoding] ?: @"";
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf demucsFinishedWithError:[NSString stringWithFormat:@"Demucs exited with status %d. %@",
            demucsTask.terminationStatus,
            [partial stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]]];
      });
      [[NSFileManager defaultManager] removeItemAtPath:tmpDir error:nil];
      return;
    }

    // ── 4. Find guitar.wav and backing stems in Demucs output ───────────
    // Demucs writes: <tmpDir>/<model>/<trackBasename>/guitar.wav
    NSString* guitarWav = nil;
    NSMutableArray<NSString*>* otherStems = [NSMutableArray array];
    NSDirectoryEnumerator* enumerator = [[NSFileManager defaultManager]
        enumeratorAtPath:tmpDir];
    for (NSString* entry in enumerator) {
      if ([entry.lastPathComponent isEqualToString:@"guitar.wav"]) {
        guitarWav = [tmpDir stringByAppendingPathComponent:entry];
      } else if ([entry.pathExtension.lowercaseString isEqualToString:@"wav"]) {
        [otherStems addObject:[tmpDir stringByAppendingPathComponent:entry]];
      }
    }
    if (!guitarWav) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf demucsFinishedWithError:@"Demucs finished but guitar.wav not found in output. Check console for Demucs errors."];
      });
      [[NSFileManager defaultManager] removeItemAtPath:tmpDir error:nil];
      return;
    }

    NSString* backingWav = nil;
    if (otherStems.count > 0) {
      double rate = 0; NSUInteger channels = 0; BOOL trunc = NO;
      NSData* firstAudio = rigDecodeReference([NSURL fileURLWithPath:otherStems[0]], rate, channels, trunc, nil);
      if (firstAudio.length && channels > 0) {
        size_t samples = firstAudio.length / sizeof(float);
        std::vector<float> acc(samples);
        std::memcpy(acc.data(), firstAudio.bytes, firstAudio.length);
        for (size_t i = 1; i < otherStems.count; ++i) {
          double sRate = 0; NSUInteger sChan = 0; BOOL sTrunc = NO;
          NSData* sAudio = rigDecodeReference([NSURL fileURLWithPath:otherStems[i]], sRate, sChan, sTrunc, nil);
          if (sAudio.length && sRate == rate && sChan == channels) {
            const auto* s = static_cast<const float*>(sAudio.bytes);
            size_t n = std::min(samples, sAudio.length / sizeof(float));
            for (size_t j = 0; j < n; ++j) acc[j] += s[j];
          }
        }
        size_t frames = samples / channels;
        NSData* backingData = rigWavDataFromFloatSamples(acc.data(), frames, uint16_t(channels), rate);
        backingWav = [tmpDir stringByAppendingPathComponent:@"backing.wav"];
        [backingData writeToFile:backingWav atomically:YES];
      }
    }

    // ── 5. Load stem as reference on main thread ─────────────────────────
    NSString* guitarWavCopy = guitarWav;
    NSString* backingWavCopy = backingWav;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!weakSelf) return;
      RigRiffRecorder* r = [RigRiffRecorder sharedRecorder];
      NSError* loadErr = nil;
      BOOL loaded = [r loadReferenceFromURL:[NSURL fileURLWithPath:guitarWavCopy]
                                    fullMix:NO
                                     source:@"demucs"
                            backingAudioURL:backingWavCopy ? [NSURL fileURLWithPath:backingWavCopy] : nil
                                      error:&loadErr];
      // Clean up temp files after loading (data is now in memory).
      [[NSFileManager defaultManager] removeItemAtPath:tmpDir error:nil];

      [weakSelf demucsFinishedWithError:loaded ? nil : (loadErr.localizedDescription ?: @"Failed to load guitar stem.")];
      if (loaded) {
        if (weakSelf.copilotTrackPopup.numberOfItems > 4) {
          [weakSelf.copilotTrackPopup selectItemAtIndex:4]; // Switch to "Target sound (guitar stem)" in the track popup
        }
        weakSelf.copilotLocalMatches = nil;
        [r playTrack:@"reference"]; // Immediately audition the extracted guitar stem
        [weakSelf resetCopilotLog:[NSString stringWithFormat:@"Demucs: guitar stem extracted and loaded.\n▶ Previewing extracted stem (click ❚❚ Stop or ▶ Preview to pause/replay).\n%@",
            r.referenceAnalysis]];
        [weakSelf updateCopilotRiffUI];
      }
    });
  });
}

// Called on the main thread after Demucs finishes (successfully or not).
- (void)demucsFinishedWithError:(NSString* _Nullable)errorMessage {
  NSAssert(NSThread.isMainThread, @"");
  self.copilotDemucsRunning = NO;
  self.copilotDemucsTask = nil;
  [self.copilotDemucsSpinner stopAnimation:nil];
  self.copilotDemucsSpinner.hidden = YES;
  if (errorMessage.length) {
    [self appendCopilotLog:[NSString stringWithFormat:@"❌ Demucs failed — %@", errorMessage]];
  }
  [self updateCopilotRiffUI];
}

- (void)matchCopilotLocally:(id)sender {
  (void)sender;
  RigRiffRecorder* r = [RigRiffRecorder sharedRecorder];
  RigAICopilot* ai = [RigAICopilot sharedCopilot];
  if (!_state || self.copilotLocalMatching || [RigLocalToneMatcher sharedMatcher].isRunning ||
      r.isRecording || r.isRendering || self.copilotRecordCountdown > 0 || ai.isProcessing || ai.isApplying) return;
  if (!r.renderHandler || !r.recordedDIFrames.length || !r.referenceFrames.length || r.referenceIsFullMix) {
    NSString* hint = r.referenceIsFullMix
        ? @"Local matching needs a guitar-only target. Re-load target sound to extract the guitar stem via Demucs."
        : @"Local matching needs YOUR raw guitar (Record Riff in standalone Axe FX) and the guitar sound you WANT (Load target sound).";
    [self appendCopilotLog:hint]; return;
  }
  if (r.recordingMetadata[@"warning"]) {
    [self appendCopilotLog:@"Record a new paired take: the rig changed during the previous take."]; return;
  }
  if (r.isDIClipped) {
    NSString* alert =
      @"\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
       "❌ TONE MATCHING HALTED: GUITAR INPUT SIGNAL TOO LOUD\n"
       "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
       "Your raw guitar DI reached digital maximum (0.0 dBFS clipping)\n"
       "on your audio interface.\n\n"
       "Why this matters:\n"
       "  Digital clipping chops off the tops of your guitar sound waves\n"
       "  into square-wave buzz. If the AI matched tone on this take, it\n"
       "  would mistake digital distortion for amplifier drive and dial in\n"
       "  incorrect gain, cabinet cuts, and EQ.\n\n"
       "HOW TO FIX (3 quick steps):\n"
       "  1. Turn down the physical Gain knob on your audio interface.\n"
       "     (Strum your hardest chords: keep the halo green/amber, never red).\n"
       "  2. Click '✕ Clear' above to discard this clipped take.\n"
       "  3. Click '● Play Along' or '● Record Riff' to record an unclipped take.\n"
       "  4. Click 'Learn & Match' again.\n"
       "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━";
    [self appendCopilotLog:alert];
    self.copilotLocalMatchStatus.stringValue = @"Error: Guitar input clipped at 0 dBFS. Lower interface gain & re-record.";
    self.copilotLocalMatchStatus.textColor = [NSColor systemRedColor];
    return;
  }
  if (_state->unconfirmedRecordingStage() >= 0) {
    [self appendCopilotLog:@"Wait for active models to finish loading before starting local matching."]; _state->sendGet(); return;
  }
  RigPreset* live = [RigPreset captureFromState:_state name:_state->presetManager.currentPresetName ?: @"Current rig"];
  self.copilotBaseContext = [RigAICopilot contextForPreset:live compact:NO];
  self.copilotBasePreset = live;
  self.copilotProposal = nil; self.copilotLocalMatches = nil;
  [self.copilotMatchCandidates removeAllItems]; [self.copilotMatchCandidates addItemWithTitle:@"Local finalists"];
  self.copilotLocalMatching = YES;
  const NSUInteger generation = ++self.copilotLocalMatchGeneration;
  [r stopPlayback]; [r invalidatePreview];
  const BOOL research = self.copilotMatchResearchButton.state == NSControlStateValueOn;
  const BOOL accurateRescore = self.copilotAccurateRescoreButton.state == NSControlStateValueOn &&
                               [r.referenceSource isEqualToString:@"demucs"];
  const BOOL embeddingRerank = self.copilotEmbeddingRerankButton.state == NSControlStateValueOn;
  const BOOL playAlong = r.isPlayingAlong;
  NSData* backing = r.referenceBackingFrames;
  NSString* refSource = r.referenceSource;
  [self resetCopilotLog:research ? @"LEARN & MATCH LOCALLY — experimental, live rig unchanged. Gear research sends the prompt text only (no audio). This can take minutes; Cancel stops after the current render."
                                 : @"LEARN & MATCH LOCALLY — experimental, live rig unchanged. No provider request or audio upload. This can take minutes; Cancel stops after the current render."];
  [self updateCopilotRiffUI]; [self.copilotSpinner startAnimation:nil];
  NSData* di = r.recordedDIFrames; double rate = r.recordedSampleRate;
  NSData* target = r.referenceFrames; double targetRate = r.referenceSampleRate;
  NSUInteger channels = r.referenceChannels;
  RigRiffRenderHandler renderer = r.renderHandler;
  NSString* query = self.copilotPromptInput.stringValue ?: @"";
  BOOL online = self.copilotMatchOnlineButton.state == NSControlStateValueOn;
  NSString* root = [RigAICopilot libraryRootPath];
  NSString* cache = [RigLocalToneMatcher trainingDirectory];
  __weak NAMRigUIController* weakSelf = self;
  auto alive = _state->isAlive;
  void (^buildAndMatch)(void) = ^{ dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      NSMutableArray* catalog = [NSMutableArray array];
      NSMutableArray* messages = [NSMutableArray array];
      NSUInteger onlineAmps = 0;
      if (online && query.length) {
        // Explicit download opt-in; only text search terms go to Tone3000.
        NSMutableArray<NSString*>* searches = [[rigAISuggestGearQueries(query) subarrayWithRange:
            NSMakeRange(0, MIN(3u, rigAISuggestGearQueries(query).count))] mutableCopy];
        if (!searches.count) [searches addObject:query];
        for (NSString* search in searches) {
          Tone3000FetchResult* fetch = tone3000FetchBestProfile(search, 1, root);
          if (fetch.success && fetch.relativePath.length) {
            [catalog addObject:@{@"stage":@1, @"path":fetch.relativePath}]; ++onlineAmps;
            [messages addObject:[NSString stringWithFormat:@"Tone3000 candidate downloaded: %@ (not applied).", fetch.toneTitle]];
          } else [messages addObject:fetch.statusMessage ?: [NSString stringWithFormat:@"Tone3000 search for \"%@\" found no candidate.", search]];
        }
      }
      NSUInteger totals[3] = {}, maxScores[3] = {};
      NSArray* library = rigAILibraryCandidatesWithTotalsAndScores(root, query, 60, totals, maxScores);
      [catalog addObjectsFromArray:library];
      RigLocalTonePlan* plan = rigLocalTonePlan(live, catalog, root);
      plan.referenceSource = refSource;
      plan.accurateRescore = accurateRescore;
      plan.referenceBackingFrames = backing;
      plan.embeddingRerank = embeddingRerank;
      plan.playAlong = playAlong;
      // Widen the amp screen only when the prompt or research actually ranked amps.
      if (maxScores[1] == 0 && plan.amps.count > 4 + onlineAmps)
        plan.amps = [plan.amps subarrayWithRange:NSMakeRange(0, 4 + onlineAmps)];
      NSDictionary* gear = query.length ? rigAIGearResearchMatching(query, NO) : nil;
      NSString* pedalText = [[gear[@"pedals"] isKindOfClass:NSArray.class] ? gear[@"pedals"] : @[] componentsJoinedByString:@" "].lowercaseString;
      for (NSString* word in @[@"drive", @"screamer", @"boost", @"ts9", @"ts808", @"ts-9", @"ts-808", @"klon", @"sd-1"])
        if ([pedalText containsString:word]) plan.preferOverdrive = YES;
      if (pedalText.length && maxScores[0] > 0) {
        NSMutableArray* pedals = [NSMutableArray array];
        for (NSDictionary* item in library) {
          if ([item[@"stage"] unsignedIntegerValue] != 0 || pedals.count >= 2) continue;
          NSString* path = rigAIResolveModel(root, item[@"path"], 0, nil);
          if (path.length) [pedals addObject:path];
        }
        plan.pedals = pedals;
      }
      if (gear) [messages addObject:[NSString stringWithFormat:@"Using gear research: %@", rigAIGearResearchSummary(gear)]];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!weakSelf || !alive || !*alive || generation != weakSelf.copilotLocalMatchGeneration) {
          if (weakSelf) { weakSelf.copilotLocalMatching = NO; [weakSelf.copilotSpinner stopAnimation:nil]; [weakSelf updateCopilotRiffUI]; }
          return;
        }
        for (NSString* line in messages) [weakSelf appendCopilotLog:line];
        [weakSelf appendCopilotLog:[NSString stringWithFormat:@"Gear search: %lu amp(s)%@, %lu cab IR(s) screened offline%@. Optimizes amp drive (plus OD/power stage options), cab, bass/mid/treble, cab cuts and optional mix EQ; not a new NAM capture.",
            (unsigned long)plan.amps.count, plan.amps.count > 4 ? @" (quick screen, best 4 at full quality)" : @"",
            (unsigned long)plan.cabs.count, plan.pedals.count ? [NSString stringWithFormat:@", %lu researched pedal(s)", (unsigned long)plan.pedals.count] : @""]];
        [[RigLocalToneMatcher sharedMatcher] matchDI:di rate:rate target:target targetRate:targetRate targetChannels:channels
            plan:plan renderer:renderer cacheDirectory:cache progress:^(NSString* line) {
          if (weakSelf && alive && *alive && generation == weakSelf.copilotLocalMatchGeneration) [weakSelf appendCopilotLog:line];
        } completion:^(NSArray<RigLocalToneMatch*>* matches, NSDictionary* metadata, NSError* error) {
          if (!weakSelf || !alive || !*alive) return;
          weakSelf.copilotLocalMatching = NO; [weakSelf.copilotSpinner stopAnimation:nil];
          if (generation != weakSelf.copilotLocalMatchGeneration) { [weakSelf appendCopilotLog:@"Local matching cancelled; live rig unchanged."]; [weakSelf updateCopilotRiffUI]; return; }
          if (error) {
            NSString* errText = error.localizedDescription ?: @"Local matching error";
            NSString* banner = [NSString stringWithFormat:
              @"\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
               "❌ TONE MATCHING HALTED: %@\n"
               "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
               "%@\n\n"
               "HOW TO PROCEED:\n"
               "  • If the input clipped: turn down interface Gain, Clear, and re-record.\n"
               "  • If active models changed: wait for loading to complete, then retry.\n"
               "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
               [errText containsString:@"clipping"] || [errText containsString:@"full scale"] ? @"INPUT TOO LOUD (0 dBFS)" : @"ERROR",
               errText];
            [weakSelf appendCopilotLog:banner];
            [weakSelf updateCopilotRiffUI];
            weakSelf.copilotLocalMatchStatus.stringValue = [NSString stringWithFormat:@"Error: %@", errText];
            weakSelf.copilotLocalMatchStatus.textColor = [NSColor systemRedColor];
            return;
          }
          // A different take/reference may have been loaded through another route.
          RigRiffRecorder* now = [RigRiffRecorder sharedRecorder];
          if (now.recordedDIFrames != di || now.referenceFrames != target) {
            [weakSelf appendCopilotLog:@"Take or target changed; local results discarded."]; [weakSelf updateCopilotRiffUI]; return;
          }
          NSMutableDictionary* provenance = [metadata mutableCopy];
          // Presets keep the summary; per-run detail stays in the training record.
          [provenance removeObjectsForKeys:@[@"evaluations", @"screening", @"finalists", @"target_features"]];
          provenance[@"provider"] = @"local"; provenance[@"model"] = @"local-screen-v1";
          provenance[@"token_cost"] = @0; provenance[@"prompt"] = query;
          for (RigLocalToneMatch* match in matches) {
            match.preset.aiMetadata = [provenance mutableCopy];
            match.presetWithoutMixEQ.aiMetadata = [provenance mutableCopy];
          }
          weakSelf.copilotLocalMatches = matches;
          [weakSelf.copilotMatchCandidates removeAllItems];
          for (NSUInteger i = 0; i < matches.count; ++i) {
            RigLocalToneMatch* m = matches[i];
            NSMutableString* title = [NSMutableString stringWithFormat:@"#%lu · %.2f dB distance", (unsigned long)i + 1, m.score];
            if (m.alignmentConfident) [title appendString:@" (aligned)"];
            if (m.embeddingDistance >= 0.0) [title appendFormat:@" (emb: %.2f)", m.embeddingDistance];
            [weakSelf.copilotMatchCandidates addItemWithTitle:title];
          }
          for (NSUInteger i = 0; i < matches.count; ++i) [weakSelf.copilotMatchCandidates itemAtIndex:i].toolTip = matches[i].preset.name;
          [weakSelf.copilotMatchCandidates selectItemAtIndex:0];
          [weakSelf selectCopilotLocalMatch:nil];
          if (metadata[@"training_file"]) [weakSelf appendCopilotLog:[NSString stringWithFormat:@"Local training record (features/settings only, no audio): %@", metadata[@"training_file"]]];
          [weakSelf appendCopilotLog:@"Choose a finalist, Render DI A/B, then listen to Candidate (matched). Apply & Save only after auditioning. No automatic application or paid AI call."];
          [weakSelf updateCopilotRiffUI];
        }];
      });
    }
  }); };
  // Opt-in, text-only gear research first (cached entries skip the provider call).
  if (research && query.length && !rigAIGearResearchMatching(query, YES)) {
    [self appendCopilotLog:@"Researching the documented gear for the prompt (text only, no audio)…"];
    [ai researchGearForPrompt:query completion:^(NSDictionary* found, NSString* failure) {
      if (!weakSelf || !alive || !*alive) return;
      if (generation != weakSelf.copilotLocalMatchGeneration) {
        weakSelf.copilotLocalMatching = NO; [weakSelf.copilotSpinner stopAnimation:nil];
        [weakSelf appendCopilotLog:@"Local matching cancelled; live rig unchanged."]; [weakSelf updateCopilotRiffUI];
        return;
      }
      if (!found) [weakSelf appendCopilotLog:[NSString stringWithFormat:@"Gear research skipped (%@); matching with the library keyword ranking.", failure ?: @"no reply"]];
      buildAndMatch();
    }];
  } else {
    if (research && !query.length) [self appendCopilotLog:@"Gear research needs an artist/album/song in the prompt; matching without it."];
    buildAndMatch();
  }
}

- (void)toggleCopilotMatchResearch:(id)sender {
  RigAICopilot* ai = [RigAICopilot sharedCopilot];
  ai.config.researchGearForLocalMatch = self.copilotMatchResearchButton.state == NSControlStateValueOn;
  NSError* error = nil;
  if (![ai.config saveToDisk:&error]) [self appendCopilotLog:[NSString stringWithFormat:@"Could not save the research setting: %@", error.localizedDescription]];
}

- (void)selectCopilotLocalMatch:(id)sender {
  (void)sender;
  if (self.copilotLocalMatching) return;
  NSInteger index = self.copilotMatchCandidates.indexOfSelectedItem;
  if (index < 0 || index >= (NSInteger)self.copilotLocalMatches.count) return;
  RigLocalToneMatch* match = self.copilotLocalMatches[(NSUInteger)index];
  const BOOL mixEQ = match.presetWithoutMixEQ && self.copilotMatchMixEQButton.state == NSControlStateValueOn;
  RigPreset* chosen = match.presetWithoutMixEQ && !mixEQ ? match.presetWithoutMixEQ : match.preset;
  const double score = match.presetWithoutMixEQ && !mixEQ ? match.scoreWithoutMixEQ : match.score;
  RigAICopilotResult* result = [RigAICopilotResult new];
  result.presetName = [NSString stringWithFormat:@"Local Match %@", self.copilotPromptInput.stringValue.length ? self.copilotPromptInput.stringValue : @"Guitar"];
  result.explanation = [NSString stringWithFormat:@"Locally matched and engine-verified candidate #%ld%@. Relative feature distance %.2f dB (lower is better, not an accuracy percentage). Compare with the target by ear; different playing/tuning affects the score.",
      (long)index + 1, match.presetWithoutMixEQ ? (mixEQ ? @" with mix EQ" : @" without mix EQ") : @"", score];
  result.thought = @"Amp drive searched with real amp renders; cab, tone stack, cuts and optional Console-pin mix EQ fitted offline (exact for these linear stages) and verified by the engine. No new NAM model was trained. Captured input amplitude and oversampling were preserved.";
  NSMutableDictionary* controls = [NSMutableDictionary dictionary];
  for (const auto& kv : chosen.allControls) {
    if (kv.second == [self.copilotBasePreset controlForPort:kv.first]) continue;
    const char* symbol = NAMRig::rigControlSymbol(kv.first);
    if (symbol) controls[@(symbol)] = @(kv.second);
  }
  result.controls = controls; result.proposedPreset = chosen;
  result.proposedPreset.name = result.presetName;
  result.tokenUsageSummary = @"Local training · no provider tokens · $0 AI cost";
  self.copilotProposal = result;
  self.copilotPresetNameField.stringValue = result.presetName;
  self.copilotAuditionContext = nil;
  [[RigRiffRecorder sharedRecorder] invalidatePreview];
  NSMutableString* gear = [NSMutableString stringWithFormat:@"Amp: %@ (drive %+.1f dB)\nCab: %@\nTone stack: bass %+.1f, mid %+.1f, treble %+.1f dB; low cut %.0f Hz",
      @([chosen stageAtIndex:1]->path.c_str()).lastPathComponent, [chosen controlForPort:22],
      [chosen stageAtIndex:2]->path.empty() ? @"included in capture" : @([chosen stageAtIndex:2]->path.c_str()).lastPathComponent,
      [chosen controlForPort:12], [chosen controlForPort:13], [chosen controlForPort:14], [chosen controlForPort:26]];
  if (![chosen stageAtIndex:0]->path.empty() && [chosen controlForPort:7] >= .5)
    [gear appendFormat:@"\nPedal: %@", @([chosen stageAtIndex:0]->path.c_str()).lastPathComponent];
  if (mixEQ) {
    [gear appendString:@"\nMix EQ (Console pins):"];
    for (size_t band = 0; band < NAMRig::kPinEqBandCount; ++band)
      [gear appendFormat:@" %.0f Hz %+.1f", [chosen controlForPort:NAMRig::pinEqPort(NAMRig::PinEqPane::CabConsole, band, NAMRig::kPinFreq)],
          [chosen controlForPort:NAMRig::pinEqPort(NAMRig::PinEqPane::CabConsole, band, NAMRig::kPinGain)]];
  }
  if (match.alignmentConfident) {
    [gear appendFormat:@"\nDTW alignment: confident (%.1f%% onset match, %.2f dB aligned distance)",
        match.alignmentConfidence * 100.0, match.alignedDistance];
  }
  if (match.embeddingDistance >= 0.0) {
    [gear appendFormat:@"\nCLAP embedding distance: %.3f", match.embeddingDistance];
  }
  [self appendCopilotLog:[NSString stringWithFormat:@"✅ LOCAL PREVIEW READY — %@\n%@", result.explanation, gear]];
  [self updateCopilotRiffUI];
}

- (void)renderCopilotDI:(id)sender {
  if (self.copilotLocalMatching) return;
  if (!self.copilotProposal.proposedPreset || !self.copilotBasePreset) return;
  RigRiffRecorder* recorder = [RigRiffRecorder sharedRecorder];
  self.copilotAuditionContext = [RigAICopilot contextForPreset:self.copilotProposal.proposedPreset compact:YES];
  if (recorder.recordingMetadata[@"warning"]) {
    [self appendCopilotLog:@"Rig changed during the take. Record a new paired take before comparing presets."]; return;
  }
  [self appendCopilotLog:@"Rendering baseline and candidate from the same raw DI locally. Live rig unchanged; no AI request."];
  __weak NAMRigUIController* weakSelf = self;
  [recorder renderBaseline:self.copilotBasePreset candidate:self.copilotProposal.proposedPreset completion:^(NSError* error) {
    [weakSelf appendCopilotLog:error ? error.localizedDescription :
        [recorder.candidateAnalysis stringByAppendingString:@"\nChoose Baseline/Candidate in the track menu and Play. Describe what needs changing and press Preview Tone for one explicit refinement request."]];
    if (!error) {
      [weakSelf.copilotTrackPopup selectItemAtIndex:3];
      [weakSelf.copilotModePopup selectItemAtIndex:2];
    }
    [weakSelf updateCopilotRiffUI];
  }];
  [self updateCopilotRiffUI];
}

- (void)cancelCopilotRequest:(id)sender {
  if (self.copilotDemucsRunning) {
    [self.copilotDemucsTask terminate];
    [self appendCopilotLog:@"Demucs: cancelled."];
    [self demucsFinishedWithError:nil]; // clean up UI state without logging a second error
    return;
  }
  if (self.copilotLocalMatching) {
    ++self.copilotLocalMatchGeneration;
    [[RigLocalToneMatcher sharedMatcher] cancel];
    [[RigAICopilot sharedCopilot] cancelProcessing]; // Opt-in gear research, if running.
    [self appendCopilotLog:@"Cancelling local matching after the current render/search completes…"];
    return;
  }
  [[RigAICopilot sharedCopilot] cancelProcessing];
}

- (void)applyCopilotProposal:(id)sender {
  if (self.copilotLocalMatching) return;
  if (!_state || !self.copilotProposal) return;
  RigAICopilot* copilot = [RigAICopilot sharedCopilot];
  if (copilot.isProcessing) return;
  if ([RigRiffRecorder sharedRecorder].isRecording || [RigRiffRecorder sharedRecorder].isRendering) return;
  if (self.copilotBaseContext && ![self.copilotBaseContext isEqual:[RigAICopilot contextForPreset:[RigPreset captureFromState:_state name:_state->presetManager.currentPresetName ?: @"Current rig"] compact:NO]]) {
    [self appendCopilotLog:@"⚠️ Apply refused: your live rig changed after the request. Press Preview Tone again so the proposal does not overwrite newer edits."]; return;
  }
  RigAICopilotResult* proposal = self.copilotProposal;
  NSString* prompt = self.copilotPromptInput.stringValue;
  auto alive = _state->isAlive;
  RigUIState* state = _state;
  [state->presetManager rescanPresets];
  NSString* plannedName = [self plannedCopilotPresetName];
  self.copilotPresetNameField.stringValue = plannedName;
  self.copilotApplyBtn.enabled = NO;
  self.copilotDialBtn.enabled = NO;
  self.copilotUndoBtn.enabled = NO;
  self.copilotCancelBtn.enabled = NO;
  [self.copilotSpinner startAnimation:nil];
  [copilot beginPresetTaskForPrompt:prompt];
  [self appendCopilotLog:[NSString stringWithFormat:@"APPLY & SAVE started → target preset '%@'.", plannedName]];
  __weak NAMRigUIController* weakSelf = self;
  [copilot applyResult:proposal toState:state completionHandler:^(NSError* error) {
    [weakSelf.copilotSpinner stopAnimation:nil];
    weakSelf.copilotDialBtn.enabled = YES;
    if (!alive || !*alive || error) {
      NSError* failure = error ?: [NSError errorWithDomain:@"RigAICopilot" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"Rig closed."}];
      [copilot failCurrentTaskWithError:failure];
      [weakSelf appendCopilotLog:[NSString stringWithFormat:@"❌ APPLY FAILED — %@", failure.localizedDescription]];
      [weakSelf appendCopilotLog:@"No preset was saved. The proposal is still available: fix the issue and press Apply & Save again."];
      weakSelf.copilotApplyBtn.enabled = weakSelf.copilotProposal != nil;
      return;
    }
    RigPresetManager* manager = state->presetManager;
    [manager rescanPresets];
    NSString* name = [manager uniquePresetNameForBase:plannedName];
    if (![name isEqualToString:plannedName])
      [weakSelf appendCopilotLog:[NSString stringWithFormat:@"'%@' was taken meanwhile; saving as '%@' instead.", plannedName, name]];
    NSError* saveError = nil;
    BOOL saved = [manager savePresetNamed:name fromState:state error:&saveError];
    if (saved) {
      RigPreset* savedPreset = [manager loadPresetNamed:name];
      if (savedPreset) {
        NSDictionary* localMetadata = proposal.proposedPreset.aiMetadata;
        BOOL isLocal = [localMetadata[@"provider"] isEqual:@"local"];
        NSMutableDictionary* meta = isLocal ? [localMetadata mutableCopy] : [NSMutableDictionary dictionary];
        meta[@"prompt"] = prompt ?: @"";
        meta[@"preset_name"] = name;
        meta[@"provider"] = isLocal ? @"local" : ([RigAICopilot sharedCopilot].config.provider ?: @"");
        meta[@"model"] = isLocal ? @"local-screen-v1" : ([RigAICopilot sharedCopilot].config.model ?: @"");
        meta[@"input_tokens"] = @(proposal.inputTokens);
        meta[@"output_tokens"] = @(proposal.outputTokens);
        meta[@"input_cost"] = @(proposal.inputCost);
        meta[@"output_cost"] = @(proposal.outputCost);
        meta[@"token_cost"] = @(proposal.tokenCost);
        meta[@"timestamp"] = [[NSDate date] description];

        if (weakSelf.copilotBasePreset && weakSelf.copilotBasePreset.aiMetadata) {
          NSDictionary* prevMeta = weakSelf.copilotBasePreset.aiMetadata;
          NSInteger prevIn = [prevMeta[@"cumulative_input_tokens"] ?: prevMeta[@"input_tokens"] integerValue];
          NSInteger prevOut = [prevMeta[@"cumulative_output_tokens"] ?: prevMeta[@"output_tokens"] integerValue];
          double prevCost = [prevMeta[@"cumulative_token_cost"] ?: prevMeta[@"token_cost"] doubleValue];
          NSInteger rev = [prevMeta[@"revision"] integerValue] + 1;

          meta[@"cumulative_input_tokens"] = @(prevIn + proposal.inputTokens);
          meta[@"cumulative_output_tokens"] = @(prevOut + proposal.outputTokens);
          meta[@"cumulative_token_cost"] = @(prevCost + proposal.tokenCost);
          meta[@"revision"] = @(std::max<NSInteger>(2, rev));
        } else {
          meta[@"cumulative_input_tokens"] = @(proposal.inputTokens);
          meta[@"cumulative_output_tokens"] = @(proposal.outputTokens);
          meta[@"cumulative_token_cost"] = @(proposal.tokenCost);
          meta[@"revision"] = @1;
        }

        savedPreset.aiMetadata = meta;
        [savedPreset saveToFile:savedPreset.filePath error:nil];
      }
      [copilot completeCurrentTaskWithResult:proposal savedPresetName:name];
      state->updatePresetDisplayTitle();
      weakSelf.copilotPresetNameField.stringValue = name;
      [weakSelf appendCopilotLog:[NSString stringWithFormat:@"Saved preset file: %@",
          [manager.presetsDirectory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"json"]]]];
      [weakSelf appendCopilotLog:[NSString stringWithFormat:@"✅ DONE — preset '%@' is saved and is now the live rig.\n%@\n• Token Cost: $%.5f (%ld in / %ld out)%@\nA/B Toggle compares it with the previous rig; the saved file is not affected.",
          name, proposal.explanation ?: @"",
          proposal.tokenCost, (long)proposal.inputTokens, (long)proposal.outputTokens,
          (savedPreset && [savedPreset.aiMetadata[@"revision"] integerValue] > 1) ?
              [NSString stringWithFormat:@"\n• Cumulative Token Cost: $%.5f (%ld in / %ld out across %ld revisions)",
                  [savedPreset.aiMetadata[@"cumulative_token_cost"] doubleValue],
                  [savedPreset.aiMetadata[@"cumulative_input_tokens"] longValue],
                  [savedPreset.aiMetadata[@"cumulative_output_tokens"] longValue],
                  [savedPreset.aiMetadata[@"revision"] longValue]] : @""]];

      // Post-apply re-render: render DI through the applied preset, compute fresh
      // spectral delta vs the reference so the copilot can iterate if needed.
      RigRiffRecorder* recorder = [RigRiffRecorder sharedRecorder];
      if (recorder.referenceAnalysis.length && recorder.renderHandler && weakSelf.copilotBasePreset) {
        [weakSelf appendCopilotLog:@"⏳ Re-rendering DI through applied preset to measure residual delta…"];
        RigPreset* appliedPreset = savedPreset;
        [recorder renderBaseline:weakSelf.copilotBasePreset candidate:appliedPreset completion:^(NSError* renderError) {
          if (renderError) {
            [weakSelf appendCopilotLog:[NSString stringWithFormat:@"Re-render skipped: %@", renderError.localizedDescription]];
            return;
          }
          NSString* playerSummary = recorder.candidateAnalysis;
          NSString* refSummary    = recorder.referenceAnalysis;
          if (playerSummary.length && refSummary.length) {
            NSString* delta = rigAIAcousticDeltaGuidance(playerSummary, refSummary);
            if (delta.length) {
              [weakSelf appendCopilotLog:@"POST-APPLY SPECTRAL CHECK (applied preset vs target reference):"];
              [weakSelf appendCopilotLog:delta];
            }
          }
        }];
      }
    } else {
      [copilot failCurrentTaskWithError:saveError ?: [NSError errorWithDomain:@"RigAICopilot" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"Preset save failed."}]];
      [weakSelf appendCopilotLog:[NSString stringWithFormat:@"⚠️ Tone applied to the live rig, but the preset was NOT saved: %@. Use A/B Toggle to restore if needed.",
          saveError.localizedDescription ?: @"Save failed"]];
    }
    weakSelf.copilotProposal = nil;
    weakSelf.copilotLocalMatches = nil;
    weakSelf.copilotUndoBtn.enabled = copilot.canUndo;
    [weakSelf.copilotModePopup selectItemAtIndex:0];
    [weakSelf updateCopilotRiffUI];
  }];
}

- (void)undoCopilotDial:(id)sender {
  (void)sender;
  if (!_state) return;
  NSError* err = nil;
  if ([[RigAICopilot sharedCopilot] undoLastAIApplicationToState:_state error:&err]) {
    [self appendCopilotLog:@"A/B switched. Click again to return to the other tone (saved preset is unchanged)."];
    self.copilotUndoBtn.enabled = [RigAICopilot sharedCopilot].canUndo;
  } else {
    [self appendCopilotLog:[NSString stringWithFormat:@"Undo failed: %@", err.localizedDescription]];
  }
}

@end

void openAICopilotInActiveRig() {
  RigUIState* state = RigUIState::activeState();
  if (state && state->uiController && [state->uiController respondsToSelector:@selector(openAICopilot:)]) {
    [state->uiController performSelector:@selector(openAICopilot:) withObject:state->aiCopilotBtn];
  }
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

  // Search / tone type / sort / arch row: search query, tone type (gear), sort order, and architecture format side-by-side.
  const CGFloat searchW = bw * 0.32;
  controller.search = [[NSSearchField alloc] initWithFrame:NSMakeRect(24, bh - 38, searchW, 28)];
  controller.search.placeholderString = @"Search tones or @author…";
  controller.search.focusRingType = NSFocusRingTypeNone;
  controller.search.toolTip = @"Search Tone3000 by tone title, author (e.g. \"2dor\" or \"@2dor\"), or gear type. Online results load page by page.";
  controller.search.delegate = controller;
  controller.search.target = controller;
  controller.search.action = @selector(searchSubmitted:);
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

  const CGFloat sortW = 180.0;
  controller.sort = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(24 + searchW + 12 + gearW + 10, bh - 38, sortW, 28) pullsDown:NO];
  [controller.sort addItemsWithTitles:@[@"Newest", @"Trending", @"Most Downloaded", @"Oldest", @"Best Match", @"Parameters (Lowest)", @"Parameters (Highest)"]];
  NSArray<NSString*>* sortTips = @[
    @"Newest — Show the most recently published tones first.",
    @"Trending — Use Tone3000's current popularity ranking.",
    @"Most Downloaded — Show tones with the highest download counts first.",
    @"Oldest — Show the earliest published tones first.",
    @"Best Match — Prioritize search relevance for the current query.",
    @"Parameters (Lowest) — Order tones by lowest parameter count first (lightest CPU load, unrounded).",
    @"Parameters (Highest) — Order tones by highest parameter count first (highest neural network capacity, unrounded)."
  ];
  for (NSUInteger item = 0; item < sortTips.count; ++item)
    [controller.sort itemAtIndex:item].toolTip = sortTips[item];
  controller.sort.controlSize = NSControlSizeSmall;
  controller.sort.target = controller;
  controller.sort.action = @selector(sortChanged:);
  controller.sort.toolTip = @"Choose the ordering used for Tone3000 search results.";
  [browser addSubview:controller.sort];

  const CGFloat archW = 310.0;
  controller.archControl = [NSSegmentedControl segmentedControlWithLabels:@[@"A2 Default", @"A1 Legacy", @"Custom", @"All"]
                                                             trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                   target:controller
                                                                   action:@selector(archChanged:)];
  controller.archControl.frame = NSMakeRect(24 + searchW + 12 + gearW + 10 + sortW + 12, bh - 38, archW, 28);
  controller.archControl.controlSize = NSControlSizeSmall;
  controller.archControl.segmentDistribution = NSSegmentDistributionFillEqually;
  controller.archControl.selectedSegment = 0;
  controller.archControl.toolTip = @"Filter search results and choose download format: A2 (Default modern standard), A1 (Legacy standard), Custom architectures, or All formats.";
  [browser addSubview:controller.archControl];

  [ToneBrowserController restoreFilterSelectionForGear:controller.gear sort:controller.sort arch:controller.archControl];
  [controller archChanged:nil];
  [controller updateSortMenuForCurrentMode];
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

  RigToneCollectionView *colView = [[RigToneCollectionView alloc] initWithFrame:scroll.bounds];
  colView.toneController = controller;
  colView.collectionViewLayout = grid;
  colView.backgroundColors = @[[NSColor clearColor]];
  colView.dataSource = controller;
  colView.delegate = controller;
  colView.selectable = YES;
  colView.allowsEmptySelection = NO;
  colView.allowsMultipleSelection = NO;
  colView.toolTip = @"Click a tone card to load its local models or download its available models. Right-click a card to view it on Tone3000.";
  [colView registerClass:[ToneCardItem class] forItemWithIdentifier:@"ToneCard"];
  controller.collectionView = colView;

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
  return nil;
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
  return nil;
}
@end

@interface NAMRigRootView : NSView
@property (nonatomic, strong) NSView* headerBar;
@property (nonatomic, weak) NSView* rigContent;
- (void)layoutHeaderInHostWindow;
- (void)layoutRigContent;
@end

@implementation NAMRigRootView
- (void)mouseDown:(NSEvent*)event {
  if ([self.window.firstResponder isKindOfClass:[NSText class]]) {
    [self.window makeFirstResponder:nil];
  }
  [super mouseDown:event];
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (!self.window) {
    [_headerBar removeFromSuperview];
  } else {
    [self layoutHeaderInHostWindow];
  }
  [self layoutRigContent];
}

- (void)setFrame:(NSRect)frame {
  [super setFrame:frame];
  [self layoutHeaderInHostWindow];
  [self layoutRigContent];
}

- (void)layout {
  [super layout];
  [self layoutHeaderInHostWindow];
  [self layoutRigContent];
}

- (void)layoutRigContent {
  if (!_rigContent) return;
  const CGFloat baseW = 1520.0;
  const CGFloat baseH = 980.0;
  const CGFloat w = self.bounds.size.width;
  const CGFloat h = self.bounds.size.height;
  if (w <= 0.0 || h <= 0.0) return;

  const CGFloat scale = std::max<CGFloat>(1.0, std::min<CGFloat>(w / baseW, h / baseH));
  _rigContent.layer.anchorPoint = CGPointMake(0, 0);
  _rigContent.layer.affineTransform = CGAffineTransformMakeScale(scale, scale);

  const CGFloat scaledW = std::floor(baseW * scale);
  const CGFloat scaledH = std::floor(baseH * scale);
  const CGFloat originX = std::max<CGFloat>(0.0, std::floor((w - scaledW) / 2.0));
  const CGFloat originY = std::max<CGFloat>(0.0, std::floor((h - scaledH) / 2.0));
  [_rigContent setFrame:NSMakeRect(originX, originY, baseW, baseH)];
  [_rigContent setNeedsDisplay:YES];
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

  const bool isStandalone = [NSBundle.mainBundle.bundleIdentifier
      isEqualToString:@"org.neuralampmodeler.lv2.standalone-rig"] ||
      [contentRoot isKindOfClass:NSClassFromString(@"StandaloneContentRootView")];

  NSRect selfFrameInContent = [self convertRect:self.bounds toView:contentRoot];
  CGFloat topSpace = 0.0;
  if (contentRoot.isFlipped) {
    topSpace = NSMinY(selfFrameInContent);
  } else {
    topSpace = contentRoot.bounds.size.height - NSMaxY(selfFrameInContent);
  }

  // When hosted in Element or Standalone, there is a host toolbar strip above the plugin view.
  if (isStandalone || topSpace >= 20.0) {
    CGFloat barH = 26.0;
    CGFloat barY = 0.0;
    CGFloat barX = 0.0;
    CGFloat barW = 0.0;

    if (isStandalone) {
      const CGFloat toolbarH = 28.0;
      barY = contentRoot.bounds.size.height - toolbarH + (toolbarH - barH) / 2.0;
      barX = 46.0;
      barW = std::max<CGFloat>(400.0, contentRoot.bounds.size.width - barX - 320.0);
    } else {
      if (contentRoot.isFlipped) {
        barY = NSMinY(selfFrameInContent) - topSpace + (topSpace - barH) / 2.0;
      } else {
        barY = NSMaxY(selfFrameInContent) + (topSpace - barH) / 2.0;
      }
      barX = NSMinX(selfFrameInContent) + 46.0;
      barW = selfFrameInContent.size.width - 46.0 - 32.0;
      if (barW < 400.0) barW = 400.0;
    }

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
    CGFloat topY = self.isFlipped ? 10.0 : (self.bounds.size.height - 34.0);
    _headerBar.frame = NSMakeRect(24.0, topY, self.bounds.size.width - 48.0, 26.0);
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

static RigPanel* addStudioRackSection(NSView* parent, NSString* title, NSString* subtitle,
                                      NSColor* titleColor, RigUIState* state = nullptr,
                                      NAMRig::Rack rackID = NAMRig::Rack::Count,
                                      uint32_t customPort = 0) {
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

  if (state && (rackID != NAMRig::Rack::Count || customPort != 0)) {
    const uint32_t port = (rackID != NAMRig::Rack::Count)
        ? (NAMRig::kRackControlFirstPort + static_cast<size_t>(rackID))
        : customPort;
    RigButton* button = rigButton(hView, @"ON", state->uiController,
                                  @selector(controlChanged:), NSZeroRect);
    button.tag = port;
    button.buttonType = NSButtonTypeToggle;
    button.check = YES;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = [title stringByAppendingString:@" ON/OFF"];
    button.toolTip = [NSString stringWithFormat:
        @"%@. %@. OFF bypasses this rack without changing its settings; controls remain editable.",
        title, subtitle];
    [[button.trailingAnchor constraintEqualToAnchor:hView.trailingAnchor] setActive:YES];
    [[button.centerYAnchor constraintEqualToAnchor:hView.centerYAnchor] setActive:YES];
    [[button.widthAnchor constraintEqualToConstant:60] setActive:YES];
    [[button.heightAnchor constraintEqualToConstant:22] setActive:YES];
    tLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [tLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    [[tLabel.trailingAnchor constraintLessThanOrEqualToAnchor:button.leadingAnchor constant:-10] setActive:YES];
    if (rackID != NAMRig::Rack::Count) {
      const size_t index = static_cast<size_t>(rackID);
      state->rackButtons[index] = button;
      state->updateControl(port, state->rackControls[index]);
    } else if (customPort == NAMRig::kCompressorEnabledPort) {
      state->compressorButton = button;
      state->updateControl(port, state->compressorEnabled);
    } else if (customPort == NAMRig::kOverdriveEnabledPort) {
      state->boostButton = button;
      state->updateControl(port, state->boostEnabled);
    } else if (customPort == NAMRig::kPostCompressorEnabledPort) {
      state->postCompressorButton = button;
      state->updateControl(port, state->postCompressorEnabled);
    }
  } else if (subtitle.length) {
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

// Registers a Studio Pro Deck slot preset dropdown and mounts it into `container`.
// RULE: Every slot created in any Studio Pro Deck pane must use this helper so
// factory presets and user-saved presets are presented in a unified dropdown menu
// with Save Preset, Save Preset As…, and Delete Preset actions.
// Connects a graph's pin editor to the DSP ports and the preset machinery.
static void installPinEditor(RigUIState* state, NAMPinEQEditor* editor) {
  if (!editor) return;
  const NAMRig::PinEqPane pane = editor.pane;
  state->pinEditors[(size_t)pane] = editor;
  for (size_t i = 0; i < NAMRig::kPinEqPanePorts; ++i) {
    const uint32_t port = NAMRig::pinEqPort(pane, 0, 0) + (uint32_t)i;
    [editor setPortValue:state->pinEqControls[port - NAMRig::kPinEqFirstPort] forPort:port];
  }
  auto alive = state->isAlive;
  editor.onChange = ^(uint32_t port, float value) {
    if (!alive || !*alive) return;
    state->sendControl(port, value);
    state->updateControl(port, value);
  };
  editor.onCommit = ^{
    if (!alive || !*alive) return;
    state->markModified();
  };
}

static NSArray<NSNumber*>* pinEqPorts(NAMRig::PinEqPane pane) {
  NSMutableArray<NSNumber*>* ports = [NSMutableArray arrayWithCapacity:NAMRig::kPinEqPanePorts];
  for (size_t i = 0; i < NAMRig::kPinEqPanePorts; ++i)
    [ports addObject:@(NAMRig::pinEqPort(pane, 0, 0) + (uint32_t)i)];
  return ports;
}

static NSPopUpButton* addSlotPresetDropdown(
    NSView* container,
    RigUIState* state,
    NSString* slotKey,
    NSString* slotTitle,
    NSArray<NSNumber*>* ports,
    NSArray<NSString*>* factoryTitles,
    SEL legacyAction) {
  state->ensureSlotPresetStorage();
  const NSInteger slotIdx = (NSInteger)state->deckSlotSpecs.count;

  NSPopUpButton* popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  popup.controlSize = NSControlSizeSmall;
  popup.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium];
  popup.tag = slotIdx;
  popup.target = state->uiController;
  popup.action = @selector(slotPresetPopupChanged:);
  popup.translatesAutoresizingMaskIntoConstraints = NO;
  popup.cell.lineBreakMode = NSLineBreakByTruncatingTail;
  [popup setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
  [popup setContentHuggingPriority:NSLayoutPriorityDefaultLow
                    forOrientation:NSLayoutConstraintOrientationHorizontal];
  popup.toolTip = [NSString stringWithFormat:
      @"Select a %@ preset, or choose Save Preset As… from the menu to save your own.",
      slotTitle];

  NSMutableDictionary* spec = [@{
    @"key": slotKey ?: @"",
    @"title": slotTitle ?: @"",
    @"ports": ports ?: @[],
    @"factoryTitles": factoryTitles ?: @[],
    @"legacyAction": legacyAction ? NSStringFromSelector(legacyAction) : @"",
    @"popup": popup,
    @"selectedTitle": factoryTitles.firstObject ?: @"",
    @"selectedIsUser": @NO
  } mutableCopy];
  for (size_t i = 0; i < NAMRig::kRackCount; ++i) {
    if (![slotKey isEqualToString:[NSString stringWithUTF8String:NAMRig::kRackSlotKeys[i]]]) continue;
    NSNumber* enabledPort = @(NAMRig::kRackControlFirstPort + i);
    spec[@"ports"] = [(ports ?: @[]) arrayByAddingObject:enabledPort];
    spec[@"enabledPort"] = enabledPort;
    break;
  }
  if ([slotKey isEqualToString:@"compressor"]) {
    NSNumber* enabledPort = @(NAMRig::kCompressorEnabledPort);
    spec[@"ports"] = [(ports ?: @[]) arrayByAddingObject:enabledPort];
    spec[@"enabledPort"] = enabledPort;
  } else if ([slotKey isEqualToString:@"boost"]) {
    NSNumber* enabledPort = @(NAMRig::kOverdriveEnabledPort);
    spec[@"ports"] = [(ports ?: @[]) arrayByAddingObject:enabledPort];
    spec[@"enabledPort"] = enabledPort;
  } else if ([slotKey isEqualToString:@"post_compressor"]) {
    NSNumber* enabledPort = @(NAMRig::kPostCompressorEnabledPort);
    spec[@"ports"] = [(ports ?: @[]) arrayByAddingObject:enabledPort];
    spec[@"enabledPort"] = enabledPort;
  }
  [state->deckSlotSpecs addObject:spec];
  state->rebuildSlotPresetMenu(slotIdx);

  if ([container isKindOfClass:[NSStackView class]]) {
    [(NSStackView*)container addArrangedSubview:popup];
  } else {
    [container addSubview:popup];
  }
  [[popup.heightAnchor constraintEqualToConstant:20] setActive:YES];
  return popup;
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
    @"TUNER",
    @"PREAMP",
    @"POWER STAGE",
    @"CAB LAB & SPEAKER",
    @"POST-FX STUDIO"
  ];
  NSArray<NSColor*>* tabColors = @[
    [NSColor colorWithSRGBRed:0.35 green:0.78 blue:1.00 alpha:1.0],  // Blue (Tuner)
    [NSColor colorWithSRGBRed:1.00 green:0.62 blue:0.18 alpha:1.0],  // Orange (Preamp)
    [NSColor colorWithSRGBRed:0.80 green:0.55 blue:1.00 alpha:1.0],  // Purple (Power Stage)
    [NSColor colorWithSRGBRed:0.30 green:0.90 blue:0.60 alpha:1.0],  // Green (Cab Lab)
    [NSColor colorWithSRGBRed:0.75 green:0.78 blue:0.90 alpha:1.0]   // Subtle Lavender (Post-FX)
  ];
  NSMutableArray<RigButton*>* tabBtns = [NSMutableArray array];
  for (NSInteger i = 0; i < 5; ++i) {
    RigButton* b = rigButton(tabStack, tabTitles[(NSUInteger)i],
                             state->uiController, @selector(switchDeckTab:),
                             NSZeroRect);
    b.tag = i;
    b.buttonType = NSButtonTypeToggle;
    b.check = YES;
    b.customTextColor = tabColors[(NSUInteger)i];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [tabStack addArrangedSubview:b];
    [[b.widthAnchor constraintEqualToConstant:138] setActive:YES];
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

  // Create 5 tab panes
  NSMutableArray<NSView*>* panes = [NSMutableArray array];
  for (NSInteger i = 0; i < 5; ++i) {
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
  // PANE 4: POST-FX STUDIO
  // ==========================================
  NSView* pane0 = panes[4];
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

  // Stereo post-cab dynamics, independent of the Pre-Amp Compressor.
  {
    RigPanel* rack = addStudioRackSection(row0, @"STEREO COMPRESSOR", @"POST-CAB DYNAMICS",
        violetColor, state, NAMRig::Rack::Count, NAMRig::kPostCompressorEnabledPort);
    [row0 addArrangedSubview:rack];
    NSStackView* kr = [[NSStackView alloc] initWithFrame:NSZeroRect];
    kr.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    kr.distribution = NSStackViewDistributionFillEqually;
    kr.spacing = 6;
    kr.translatesAutoresizingMaskIntoConstraints = NO;
    [rack addSubview:kr];
    [[kr.topAnchor constraintEqualToAnchor:rack.topAnchor constant:40] setActive:YES];
    [[kr.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:10] setActive:YES];
    [[kr.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-10] setActive:YES];
    [[kr.heightAnchor constraintEqualToConstant:108] setActive:YES];
    for (size_t idx : {size_t{44}, size_t{45}, size_t{46}})
      [kr addArrangedSubview:addDeckKnobCell(kr, state, idx, mins, maxes, knobNames, knobDescriptions)];

    NSView* card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES;
    card.layer.cornerRadius = 6;
    card.layer.backgroundColor = rigRaised().CGColor;
    [rack addSubview:card];
    [[card.topAnchor constraintEqualToAnchor:kr.bottomAnchor constant:10] setActive:YES];
    [[card.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:12] setActive:YES];
    [[card.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-12] setActive:YES];
    [[card.bottomAnchor constraintEqualToAnchor:rack.bottomAnchor constant:-12] setActive:YES];
    NSTextField* desc = addLabel(card, @"Linked stereo leveling before delay & reverb.\nPreserves the stereo image without pushing the amp.", NSZeroRect,
        [NSFont systemFontOfSize:9 weight:NSFontWeightRegular], rigDimText(), NSTextAlignmentLeft);
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    desc.maximumNumberOfLines = 2;
    [[desc.topAnchor constraintEqualToAnchor:card.topAnchor constant:8] setActive:YES];
    [[desc.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    NSPopUpButton* presets = addSlotPresetDropdown(card, state, @"post_compressor", @"Stereo Compressor",
        @[@(NAMRig::kPostCompressorAmountPort), @(NAMRig::kPostCompressorAttackPort), @(NAMRig::kPostCompressorReleasePort)],
        @[@"OFF / BYPASS", @"STUDIO GLUE", @"PUNCHY ATTACK", @"SMOOTH LEAD", @"PEAK CONTROL"], @selector(applyPostCompressorPreset:));
    [[presets.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:6] setActive:YES];
    [[presets.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[presets.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    NAMCompressorVisualizer* vis = [[NAMCompressorVisualizer alloc] initWithFrame:NSZeroRect];
    vis.compact = YES;
    vis.translatesAutoresizingMaskIntoConstraints = NO;
    vis.amount = 0;
    vis.attack = 8;
    vis.releaseTime = 120;
    vis.enabled = state->postCompressorEnabled >= 0.5f;
    state->postCompressorVisualizer = vis;
    [card addSubview:vis];
    [[vis.topAnchor constraintEqualToAnchor:presets.bottomAnchor constant:8] setActive:YES];
    [[vis.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[vis.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[vis.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8] setActive:YES];
  }

  // 1. Stereo Tape Delay (4 knobs: 28, 29, 30, 31)
  {
    RigPanel* rack = addStudioRackSection(row0, @"STEREO TAPE DELAY", @"PANNED ECHOES & DAMPING", violetColor, state, NAMRig::Rack::Delay);
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
    addSlotPresetDropdown(chips, state, @"delay", @"Stereo Tape Delay",
                          @[@50, @51, @52, @53], delayPresetTitles, @selector(applyDelayPreset:));

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
    RigPanel* rack = addStudioRackSection(row0, @"STUDIO PLATE REVERB", @"DIFFUSE SPACE & SHIMMER", violetColor, state, NAMRig::Rack::Reverb);
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
    addSlotPresetDropdown(chips, state, @"reverb", @"Studio Plate Reverb",
                          @[@54, @55, @56, @57, @58], rvbPresetTitles, @selector(applyReverbPreset:));

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
    RigPanel* rack = addStudioRackSection(row0, @"SPATIAL ACOUSTICS", @"STEREO SPREAD & ROOM", emeraldColor, state, NAMRig::Rack::Spatial);
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
    addSlotPresetDropdown(chips, state, @"spatial", @"Spatial Acoustics",
                          @[@32, @33], spatialPresetTitles, @selector(applySpatialPreset:));

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
  // PANE 2: POWER STAGE & IRON
  // ==========================================
  NSView* pane1 = panes[2];
  NSStackView* row1 = [[NSStackView alloc] initWithFrame:NSZeroRect];
  row1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row1.distribution = NSStackViewDistributionFill;
  row1.spacing = 14.0;
  row1.translatesAutoresizingMaskIntoConstraints = NO;
  [pane1 addSubview:row1];
  [[row1.topAnchor constraintEqualToAnchor:pane1.topAnchor] setActive:YES];
  [[row1.bottomAnchor constraintEqualToAnchor:pane1.bottomAnchor] setActive:YES];
  [[row1.leadingAnchor constraintEqualToAnchor:pane1.leadingAnchor] setActive:YES];
  [[row1.trailingAnchor constraintEqualToAnchor:pane1.trailingAnchor] setActive:YES];

  RigPanel* pwrRackRef = nil;
  RigPanel* transRackRef = nil;
  RigPanel* tubeRackRef = nil;

  // 1. Dynamic Power Stage (4 knobs: 21, 16, 17, 18)
  {
    RigPanel* rack = addStudioRackSection(row1, @"DYNAMIC POWER STAGE", @"DRIVE, SAG & FEEDBACK", goldColor, state, NAMRig::Rack::Power);
    [row1 addArrangedSubview:rack];
    pwrRackRef = rack;

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

    NSTextField* desc = addLabel(card, @"Supply sag, bias and feedback. Master drives the shared stage.",
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
    addSlotPresetDropdown(chips, state, @"power", @"Dynamic Power Stage",
                          @[@41, @36, @37, @38], pwrPresetTitles, @selector(applyPowerPreset:));

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

  // 2. Power Tube Character shares the power-stage engine, not a second saturator.
  {
    RigPanel* rack = addStudioRackSection(row1, @"POWER TUBE CHARACTER", @"TUBE-INSPIRED POST-CAPTURE SHAPING", goldColor, state, NAMRig::Rack::PowerTube);
    [row1 addArrangedSubview:rack];
    tubeRackRef = rack;

    NSView* topZone = [[NSView alloc] initWithFrame:NSZeroRect];
    topZone.translatesAutoresizingMaskIntoConstraints = NO;
    [rack addSubview:topZone];
    [[topZone.topAnchor constraintEqualToAnchor:rack.topAnchor constant:40] setActive:YES];
    [[topZone.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:12] setActive:YES];
    [[topZone.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-12] setActive:YES];
    [[topZone.heightAnchor constraintEqualToConstant:108] setActive:YES];
    NSTextField* typeLabel = addLabel(topZone, @"TUBE TYPE", NSZeroRect,
        [NSFont systemFontOfSize:9 weight:NSFontWeightSemibold], rigDimText(), NSTextAlignmentLeft);
    typeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [[typeLabel.topAnchor constraintEqualToAnchor:topZone.topAnchor constant:4] setActive:YES];
    [[typeLabel.leadingAnchor constraintEqualToAnchor:topZone.leadingAnchor] setActive:YES];
    [[typeLabel.trailingAnchor constraintEqualToAnchor:topZone.trailingAnchor constant:-90] setActive:YES];
    NSPopUpButton* type = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [type addItemsWithTitles:@[@"Captured / No Added Character", @"6L6-inspired", @"EL34-inspired"]];
    NSArray<NSString*>* tips = @[
        @"Preserve the captured tube character. Dynamic Power Stage remains independent.",
        @"6L6-inspired voicing with more headroom and restrained compression. Adds to the capture; does not replace its tubes.",
        @"EL34-inspired voicing with earlier compression and a different clipping knee. Adds to the capture; does not replace its tubes."];
    for (NSUInteger i = 0; i < tips.count; ++i) [type itemAtIndex:i].toolTip = tips[i];
    type.controlSize = NSControlSizeSmall;
    type.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    type.tag = NAMRig::kPowerTubeTypePort;
    type.target = state->uiController;
    type.action = @selector(powerTubeChanged:);
    type.translatesAutoresizingMaskIntoConstraints = NO;
    type.cell.lineBreakMode = NSLineBreakByTruncatingTail;
    [type setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [topZone addSubview:type];
    [[type.topAnchor constraintEqualToAnchor:typeLabel.bottomAnchor constant:6] setActive:YES];
    [[type.leadingAnchor constraintEqualToAnchor:topZone.leadingAnchor] setActive:YES];
    [[type.trailingAnchor constraintEqualToAnchor:topZone.trailingAnchor constant:-90] setActive:YES];
    [[type.heightAnchor constraintEqualToConstant:24] setActive:YES];
    state->powerTubePopup = type;

    NSView* character = addDeckKnobCell(topZone, state, 37, mins, maxes, knobNames, knobDescriptions);
    [[character.topAnchor constraintEqualToAnchor:topZone.topAnchor] setActive:YES];
    [[character.trailingAnchor constraintEqualToAnchor:topZone.trailingAnchor] setActive:YES];
    [[character.widthAnchor constraintEqualToConstant:80] setActive:YES];
    [[character.heightAnchor constraintEqualToAnchor:topZone.heightAnchor] setActive:YES];

    NSView* card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES;
    card.layer.cornerRadius = 6;
    card.layer.backgroundColor = rigRaised().CGColor;
    [rack addSubview:card];
    [[card.topAnchor constraintEqualToAnchor:topZone.bottomAnchor constant:10] setActive:YES];
    [[card.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:12] setActive:YES];
    [[card.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-12] setActive:YES];
    [[card.bottomAnchor constraintEqualToAnchor:rack.bottomAnchor constant:-12] setActive:YES];
    NSTextField* desc = addLabel(card, @"Adds tube-inspired character, not a literal tube swap.\nWorks with Power Stage ON or OFF. Character 0% is neutral.", NSZeroRect,
        [NSFont systemFontOfSize:9 weight:NSFontWeightRegular], rigDimText(), NSTextAlignmentLeft);
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    desc.maximumNumberOfLines = 2;
    [[desc.topAnchor constraintEqualToAnchor:card.topAnchor constant:8] setActive:YES];
    [[desc.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    NSPopUpButton* presets = addSlotPresetDropdown(card, state, @"power_tube", @"Power Tube Character",
        @[@(NAMRig::kPowerTubeTypePort), @(NAMRig::kPowerTubeCharacterPort)],
        @[@"Captured", @"6L6-inspired", @"EL34-inspired"], @selector(applyPowerTubePreset:));
    [[presets.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:6] setActive:YES];
    [[presets.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[presets.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    NAMPowerTubeVisualizer* visualizer = [[NAMPowerTubeVisualizer alloc] initWithFrame:NSZeroRect];
    visualizer.translatesAutoresizingMaskIntoConstraints = NO;
    visualizer.character = state->powerTubeCharacter;
    visualizer.enabled = YES;
    [card addSubview:visualizer];
    [[visualizer.topAnchor constraintEqualToAnchor:presets.bottomAnchor constant:8] setActive:YES];
    [[visualizer.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[visualizer.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[visualizer.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8] setActive:YES];
    state->powerTubeVisualizer = visualizer;
    state->updateControl(NAMRig::kPowerTubeTypePort, (float)state->powerTubeProfile);
  }

  // 4. Output Transformer (model and editable-trim presets)
  {
    RigPanel* rack = addStudioRackSection(row1, @"OUTPUT TRANSFORMER", @"CORE SATURATION & VOICING", goldColor, state, NAMRig::Rack::Transformer);
    [row1 addArrangedSubview:rack];
    transRackRef = rack;

    // 108pt top control & telemetry zone (matches kr height in sibling racks so all 3 inner cards align at Y=158)
    NSView* topZone = [[NSView alloc] initWithFrame:NSZeroRect];
    topZone.translatesAutoresizingMaskIntoConstraints = NO;
    [rack addSubview:topZone];
    [[topZone.topAnchor constraintEqualToAnchor:rack.topAnchor constant:40] setActive:YES];
    [[topZone.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:12] setActive:YES];
    [[topZone.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-12] setActive:YES];
    [[topZone.heightAnchor constraintEqualToConstant:108] setActive:YES];

    NSTextField* presetLbl = addLabel(topZone, @"PRESET", NSZeroRect,
                                    [NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold],
                                    rigDimText(), NSTextAlignmentLeft);
    rigApplyTracking(presetLbl, 1.0);
    presetLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [[presetLbl.leadingAnchor constraintEqualToAnchor:topZone.leadingAnchor constant:2] setActive:YES];
    [[presetLbl.topAnchor constraintEqualToAnchor:topZone.topAnchor constant:6] setActive:YES];
    [presetLbl setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSMutableArray<NSNumber*>* transformerPorts = [NSMutableArray arrayWithObject:@30];
    for (size_t i = 0; i < NAMRig::kTransformerControlCount; ++i)
      [transformerPorts addObject:@(NAMRig::kTransformerControlFirstPort + i)];
    [transformerPorts addObjectsFromArray:pinEqPorts(NAMRig::PinEqPane::Transformer)];
    NSPopUpButton* presets = addSlotPresetDropdown(topZone, state, @"transformer", @"Output Transformer",
        transformerPorts, @[@"Captured / Off", @"Modern Iron", @"US Vintage", @"UK Vintage", @"Small Iron",
                            @"Tight Metal", @"Extended Range", @"Thrash Bite", @"Doom Iron", @"Studio Linear",
                            @"Tweed Bloom", @"Class-A Chime", @"Bass Iron"], @selector(applyTransformerPreset:));
    [[presets.leadingAnchor constraintEqualToAnchor:presetLbl.trailingAnchor constant:10] setActive:YES];
    [[presets.trailingAnchor constraintEqualToAnchor:topZone.trailingAnchor] setActive:YES];
    [[presets.centerYAnchor constraintEqualToAnchor:presetLbl.centerYAnchor] setActive:YES];
    presets.toolTip = @"Recall a transformer model and all its tweaks. Save Preset, Save Preset As… and Delete Preset are at the bottom of this menu. Only user presets can be deleted.";

    NSPopUpButton* deckTrans = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [deckTrans addItemsWithTitles:@[@"Captured / Off", @"Modern Iron",
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
      [deckTrans itemAtIndex:item].toolTip = transformerDescriptions[item];
    deckTrans.controlSize = NSControlSizeSmall;
    deckTrans.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
    deckTrans.tag = 30;
    deckTrans.target = state->uiController;
    deckTrans.action = @selector(transformerChanged:);
    deckTrans.translatesAutoresizingMaskIntoConstraints = NO;
    [[deckTrans.heightAnchor constraintEqualToConstant:24] setActive:YES];
    [deckTrans selectItemAtIndex:0];
    deckTrans.toolTip = deckTrans.selectedItem.toolTip;
    state->deckTransformerPopup = deckTrans;
    state->transformerPopup = deckTrans;

    // 2x2 Hardware Core Spec Pill Grid inside topZone (y = 32..106)
    NSStackView* specGrid = [[NSStackView alloc] initWithFrame:NSZeroRect];
    specGrid.orientation = NSUserInterfaceLayoutOrientationVertical;
    specGrid.distribution = NSStackViewDistributionFillEqually;
    specGrid.spacing = 6.0;
    specGrid.translatesAutoresizingMaskIntoConstraints = NO;
    [topZone addSubview:specGrid];
    [[specGrid.topAnchor constraintEqualToAnchor:presets.bottomAnchor constant:8] setActive:YES];
    [[specGrid.leadingAnchor constraintEqualToAnchor:topZone.leadingAnchor] setActive:YES];
    [[specGrid.trailingAnchor constraintEqualToAnchor:topZone.trailingAnchor] setActive:YES];
    [[specGrid.bottomAnchor constraintEqualToAnchor:topZone.bottomAnchor constant:-2] setActive:YES];

    NSArray<NSString*>* specTitles = @[@"PASSBAND", @"CORE FLUX", @"VOICE PEAK", @"LEAKAGE"];
    for (NSUInteger rowIdx = 0; rowIdx < 2; ++rowIdx) {
      NSStackView* sRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
      sRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
      sRow.distribution = NSStackViewDistributionFillEqually;
      sRow.spacing = 6.0;
      sRow.translatesAutoresizingMaskIntoConstraints = NO;
      [specGrid addArrangedSubview:sRow];
      [[sRow.leadingAnchor constraintEqualToAnchor:specGrid.leadingAnchor] setActive:YES];
      [[sRow.trailingAnchor constraintEqualToAnchor:specGrid.trailingAnchor] setActive:YES];

      for (NSUInteger colIdx = 0; colIdx < 2; ++colIdx) {
        const size_t pillIdx = rowIdx * 2 + colIdx;
        NSView* pill = [[NSView alloc] initWithFrame:NSZeroRect];
        pill.translatesAutoresizingMaskIntoConstraints = NO;
        pill.wantsLayer = YES;
        pill.layer.cornerRadius = 5.0;
        pill.layer.backgroundColor = rigRaised().CGColor;
        pill.layer.borderWidth = 1.0;
        pill.layer.borderColor = [NSColor colorWithSRGBRed:0.20 green:0.22 blue:0.28 alpha:0.75].CGColor;
        [sRow addArrangedSubview:pill];
        [[pill.topAnchor constraintEqualToAnchor:sRow.topAnchor] setActive:YES];
        [[pill.bottomAnchor constraintEqualToAnchor:sRow.bottomAnchor] setActive:YES];

        NSButton* kLbl = [NSButton buttonWithTitle:[specTitles[pillIdx] stringByAppendingString:@"  EDIT"]
                                           target:state->uiController action:@selector(showTransformerControls:)];
        kLbl.bordered = NO;
        kLbl.font = [NSFont systemFontOfSize:7.5 weight:NSFontWeightBold];
        kLbl.contentTintColor = [NSColor colorWithSRGBRed:0.52 green:0.56 blue:0.66 alpha:0.95];
        kLbl.alignment = NSTextAlignmentLeft;
        kLbl.tag = pillIdx;
        kLbl.toolTip = @"Edit this section's transformer parameters.";
        [pill addSubview:kLbl];
        kLbl.translatesAutoresizingMaskIntoConstraints = NO;
        [[kLbl.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:8] setActive:YES];
        [[kLbl.topAnchor constraintEqualToAnchor:pill.topAnchor constant:4] setActive:YES];
        [[kLbl.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-6] setActive:YES];
        [[kLbl.heightAnchor constraintEqualToConstant:12] setActive:YES];

        NSTextField* vLbl = addLabel(pill, @"—", NSZeroRect,
                                     [NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightSemibold],
                                     [NSColor colorWithSRGBRed:1.00 green:0.78 blue:0.32 alpha:0.98],
                                     NSTextAlignmentLeft);
        vLbl.lineBreakMode = NSLineBreakByTruncatingTail;
        vLbl.translatesAutoresizingMaskIntoConstraints = NO;
        [[vLbl.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:8] setActive:YES];
        [[vLbl.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-6] setActive:YES];
        [[vLbl.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-4] setActive:YES];
        state->transformerSpecLabels[pillIdx] = vLbl;
      }
    }

    NSView* card = [[NSView alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES; card.layer.cornerRadius = 6.0;
    card.layer.backgroundColor = [NSColor colorWithSRGBRed:0.11 green:0.12 blue:0.15 alpha:0.95].CGColor;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [NSColor colorWithSRGBRed:0.20 green:0.22 blue:0.28 alpha:0.8].CGColor;
    [rack addSubview:card];
    [[card.topAnchor constraintEqualToAnchor:topZone.bottomAnchor constant:10] setActive:YES];
    [[card.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:12] setActive:YES];
    [[card.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-12] setActive:YES];
    [[card.bottomAnchor constraintEqualToAnchor:rack.bottomAnchor constant:-12] setActive:YES];

    NSTextField* desc = addLabel(card, @"Changing the base model resets all transformer tweaks.",
                                 NSZeroRect, [NSFont systemFontOfSize:9.0 weight:NSFontWeightRegular],
                                 rigDimText(), NSTextAlignmentLeft);
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    [[desc.topAnchor constraintEqualToAnchor:card.topAnchor constant:8] setActive:YES];
    [[desc.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];

    NSTextField* baseLbl = addLabel(card, @"BASE MODEL", NSZeroRect,
                                    [NSFont systemFontOfSize:9.0 weight:NSFontWeightSemibold],
                                    rigDimText(), NSTextAlignmentLeft);
    baseLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:deckTrans];
    [[baseLbl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[baseLbl.centerYAnchor constraintEqualToAnchor:deckTrans.centerYAnchor] setActive:YES];
    [baseLbl setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [[deckTrans.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:6] setActive:YES];
    [[deckTrans.leadingAnchor constraintEqualToAnchor:baseLbl.trailingAnchor constant:8] setActive:YES];
    [[deckTrans.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];

    NAMTransformerVisualizer* transVis = [[NAMTransformerVisualizer alloc] initWithFrame:NSZeroRect];
    transVis.translatesAutoresizingMaskIntoConstraints = NO;
    transVis.profile = 0;
    state->transformerVisualizer = transVis;
    installPinEditor(state, transVis.pinEditor);
    [card addSubview:transVis];
    [[transVis.topAnchor constraintEqualToAnchor:deckTrans.bottomAnchor constant:8] setActive:YES];
    [[transVis.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[transVis.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[transVis.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8] setActive:YES];

    state->updateTransformerTelemetry(0);
  }

  if (pwrRackRef && transRackRef && tubeRackRef) {
    [[tubeRackRef.widthAnchor constraintEqualToAnchor:pwrRackRef.widthAnchor multiplier:0.90] setActive:YES];
    [[transRackRef.widthAnchor constraintEqualToAnchor:pwrRackRef.widthAnchor multiplier:1.05] setActive:YES];
  }

  // ==========================================
  // PANE 3: CAB LAB & SPEAKER
  // ==========================================
  NSView* pane2 = panes[3];
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
    RigPanel* rack = addStudioRackSection(row2, @"PHYSICAL SPEAKER EMULATION", @"CONE DYNAMICS & REACTIVE LOAD", emeraldColor, state, NAMRig::Rack::Speaker);
    [row2 addArrangedSubview:rack];

    NSPopUpButton* deckSpkr = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [deckSpkr addItemsWithTitles:@[@"Captured / Off", @"Auto", @"Resistive", @"Open Back",
                                  @"Vintage Alnico", @"UK 4x12", @"Modern 4x12", @"Bass"]];
    NSArray<NSString*>* speakerDescriptions = @[
      @"Captured / Off — Exact bypass. Preserves the original speaker load and interaction already present in the NAM model without adding reactive impedance or cone dynamics.",
      @"Auto — Automatically detects and selects a matching reactive speaker load based on the loaded Cabinet A impulse response or model name. Defaults to Resistive if unrecognized.",
      @"Resistive — Flat resistive dummy load (attenuator style). Nearly flat impedance with minimal 95 Hz resonance and gentle 2.5 kHz inductive rise for transparent, uncolored dynamic response.",
      @"Open Back — American combo-style open-back cabinet (1x12 or 2x12). Resonant peak at 92 Hz, loose excursion bloom, longer compression decay, and open high-frequency chime above 1.8 kHz.",
      @"Vintage Alnico — British vintage alnico magnet drivers (Celestion Blue/Gold/Cream). Warm, pronounced cone breakup and compression, 105 Hz resonance, and rich upper-mid inductive rise at 1.6 kHz.",
      @"UK 4x12 — Classic British 4x12 closed-back stack with ceramic greenbacks (Marshall 1960). Strong 118 Hz resonance, punchy mid-bass bark, quick excursion response, and 2.0 kHz inductance rise.",
      @"Modern 4x12 — Oversized American closed-back 4x12 with Vintage 30s (Rectifier style). Deep 82 Hz resonance, heavy sub-bass thump, tight excursion control, and 2.2 kHz presence bite.",
      @"Bass — Heavyweight multi-driver bass enclosure (8x10, 4x10, 1x15). Deep 58 Hz low-end resonance, massive 48 Hz sub-bass thump, extended excursion release, and subdued top-end response."
    ];
    for (NSUInteger item = 0; item < speakerDescriptions.count && item < (NSUInteger)deckSpkr.numberOfItems; ++item)
      [deckSpkr itemAtIndex:item].toolTip = speakerDescriptions[item];
    deckSpkr.controlSize = NSControlSizeRegular;
    deckSpkr.tag = 42;
    deckSpkr.target = state->uiController;
    deckSpkr.action = @selector(speakerProfileChanged:);
    deckSpkr.translatesAutoresizingMaskIntoConstraints = NO;
    [deckSpkr selectItemAtIndex:0];
    deckSpkr.toolTip = deckSpkr.selectedItem.toolTip;
    [rack addSubview:deckSpkr];
    [[deckSpkr.topAnchor constraintEqualToAnchor:rack.topAnchor constant:40] setActive:YES];
    [[deckSpkr.leadingAnchor constraintEqualToAnchor:rack.leadingAnchor constant:14] setActive:YES];
    [[deckSpkr.trailingAnchor constraintEqualToAnchor:rack.trailingAnchor constant:-14] setActive:YES];
    [[deckSpkr.heightAnchor constraintEqualToConstant:26] setActive:YES];
    state->deckSpeakerProfilePopup = deckSpkr;
    state->speakerProfilePopup = deckSpkr;

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
    addSlotPresetDropdown(chips, state, @"speaker", @"Physical Speaker Emulation",
                          [@[@42, @43, @44, @45, @46]
                              arrayByAddingObjectsFromArray:pinEqPorts(NAMRig::PinEqPane::Speaker)],
                          spkrPresetTitles, @selector(applySpeakerPreset:));

    NAMSpeakerDynamicsVisualizer* spkVis = [[NAMSpeakerDynamicsVisualizer alloc] initWithFrame:NSZeroRect];
    spkVis.translatesAutoresizingMaskIntoConstraints = NO;
    spkVis.drive = 25.0f;
    spkVis.comp = 25.0f;
    spkVis.thump = 50.0f;
    spkVis.resonance = 50.0f;
    state->speakerVisualizer = spkVis;
    state->refreshSpeakerVisualizer();
    installPinEditor(state, spkVis.pinEditor);
    [card addSubview:spkVis];
    [[spkVis.topAnchor constraintEqualToAnchor:chips.bottomAnchor constant:8] setActive:YES];
    [[spkVis.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[spkVis.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[spkVis.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8] setActive:YES];
  }

  // 2. Dual-Cabinet Blend Console (5 knobs: 8, 26, 27, 9, 10)
  {
    RigPanel* rack = addStudioRackSection(row2, @"DUAL-CABINET BLEND CONSOLE", @"LEVEL, PHASE ALIGN & CUTS", emeraldColor, state, NAMRig::Rack::CabConsole);
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

    NSTextField* desc = addLabel(card, @"Cab A & B balance, signed alignment, B polarity & dual cut filters.",
                                 NSZeroRect, [NSFont systemFontOfSize:9.0 weight:NSFontWeightRegular],
                                 rigDimText(), NSTextAlignmentLeft);
    desc.translatesAutoresizingMaskIntoConstraints = NO;
    [[desc.topAnchor constraintEqualToAnchor:card.topAnchor constant:8] setActive:YES];
    [[desc.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];

    NSStackView* chips = [[NSStackView alloc] initWithFrame:NSZeroRect];
    chips.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chips.distribution = NSStackViewDistributionFill;
    chips.spacing = 6.0;
    chips.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:chips];
    [[chips.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:6] setActive:YES];
    [[chips.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[chips.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[chips.heightAnchor constraintEqualToConstant:20] setActive:YES];

    NSArray<NSString*>* cabPresetTitles = @[@"50/50 STEREO", @"LEAD FOCUS", @"WIDE ROOM"];
    addSlotPresetDropdown(chips, state, @"cab_console", @"Dual-Cabinet Blend Console",
                          [@[@25, @48, @49, @26, @27, @59]
                              arrayByAddingObjectsFromArray:pinEqPorts(NAMRig::PinEqPane::CabConsole)],
                          cabPresetTitles, @selector(applyCabConsolePreset:));
    RigButton* invertB = rigChip(chips, @"B POL INV", state->uiController, @selector(controlChanged:), 59);
    invertB.buttonType = NSButtonTypeToggle;
    invertB.check = YES;
    invertB.state = NSControlStateValueOff;
    invertB.toolTip = @"Invert Cab B polarity before blending with Cab A. Off = normal; on = inverted. Cabinet quick presets preserve this selection.";
    state->cab2PolarityButton = invertB;
    [chips addArrangedSubview:invertB];
    [[invertB.widthAnchor constraintEqualToConstant:78] setActive:YES];
    [[invertB.heightAnchor constraintEqualToConstant:20] setActive:YES];

    NAMCabConsoleVisualizer* cabVis = [[NAMCabConsoleVisualizer alloc] initWithFrame:NSZeroRect];
    cabVis.translatesAutoresizingMaskIntoConstraints = NO;
    cabVis.cabALevel = 0.0f;
    cabVis.cabBLevel = 0.0f;
    cabVis.alignDelay = 0.0f;
    cabVis.lowCut = 0.0f;
    cabVis.highCut = 20000.0f;
    state->cabConsoleVisualizer = cabVis;
    installPinEditor(state, cabVis.pinEditor);
    [card addSubview:cabVis];
    [[cabVis.topAnchor constraintEqualToAnchor:chips.bottomAnchor constant:8] setActive:YES];
    [[cabVis.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[cabVis.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[cabVis.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8] setActive:YES];
  }

  // ==========================================
  // PANE 1: PRE AMP
  // ==========================================
  NSView* pane3 = panes[1];
  NSStackView* row3 = [[NSStackView alloc] initWithFrame:NSZeroRect];
  row3.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row3.distribution = NSStackViewDistributionFillEqually;
  row3.spacing = 14.0;
  row3.translatesAutoresizingMaskIntoConstraints = NO;
  [pane3 addSubview:row3];
  [[row3.topAnchor constraintEqualToAnchor:pane3.topAnchor] setActive:YES];
  [[row3.bottomAnchor constraintEqualToAnchor:pane3.bottomAnchor] setActive:YES];
  [[row3.leadingAnchor constraintEqualToAnchor:pane3.leadingAnchor] setActive:YES];
  [[row3.trailingAnchor constraintEqualToAnchor:pane3.trailingAnchor] setActive:YES];

  // 1. Pre-Amp Compressor (3 knobs: 3 [Amount], 42 [Attack], 43 [Release])
  {
    RigPanel* rack = addStudioRackSection(row3, @"PRE-AMP COMPRESSOR", @"DYNAMIC CONTROL & TRANSIENTS",
                                          goldColor, state, NAMRig::Rack::Count, NAMRig::kCompressorEnabledPort);
    [row3 addArrangedSubview:rack];

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

    const size_t compK[3] = {3, 42, 43};
    for (size_t idx : compK) {
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

    NSTextField* desc = addLabel(card, @"Studio feed-forward VCA compressor with soft knee and dynamic gain reduction.",
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

    NSArray<NSString*>* compPresetTitles = @[@"SMOOTH SUSTAIN", @"PUNCHY ATTACK", @"FAST SQUASH", @"TRANSPARENT", @"OFF / BYPASS",
                                           @"METAL PICK CLARITY", @"SHRED DEFINITION", @"THRASH PRECISION", @"SINGING METAL LEAD"];
    NSPopUpButton* compPresets = addSlotPresetDropdown(chips, state, @"compressor", @"Pre-Amp Compressor",
                          @[@28, @(NAMRig::kCompressorAttackPort), @(NAMRig::kCompressorReleasePort)],
                          compPresetTitles, @selector(applyCompressorPreset:));
    compPresets.toolTip = @"Select a compressor preset, or use Save Preset As… to save your own. For clearer high-gain solo picking, start with METAL PICK CLARITY. SHRED DEFINITION and THRASH PRECISION use shorter releases for fast picking; SINGING METAL LEAD adds gentler sustain. Keep Amount modest: its makeup gain can drive the amp into more saturation.";

    NAMCompressorVisualizer* compVis = [[NAMCompressorVisualizer alloc] initWithFrame:NSZeroRect];
    compVis.translatesAutoresizingMaskIntoConstraints = NO;
    compVis.amount = 0.0f;
    compVis.attack = 8.0f;
    compVis.releaseTime = 120.0f;
    state->compressorVisualizer = compVis;
    [card addSubview:compVis];
    [[compVis.topAnchor constraintEqualToAnchor:chips.bottomAnchor constant:8] setActive:YES];
    [[compVis.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[compVis.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[compVis.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8] setActive:YES];
  }

  // 2. Pre-Amp EQ (left)
  {
    RigPanel* rack = addStudioRackSection(row3, @"PRE-AMP EQ", @"INPUT CONDITIONING & SHAPING", goldColor, state, NAMRig::Rack::Sculpt);
    [row3 addArrangedSubview:rack];

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

    const size_t eqK[3] = {19, 20, 38};
    for (size_t idx : eqK) {
      [kr addArrangedSubview:addDeckKnobCell(kr, state, idx, mins, maxes, knobNames, knobDescriptions)];
    }
    state->sculptEqKnobs = kr;

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

    NSTextField* desc = addLabel(card, @"Bright switch, input EQ, mid push, and 6-band parametric pin EQ.",
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

    NSArray<NSString*>* sculptPresetTitles = @[@"LEAD BOOST", @"TIGHT CHUG", @"MID PUSH", @"BRIGHT & OPEN", @"FLAT"];
    addSlotPresetDropdown(chips, state, @"sculpt", @"Pre-Amp EQ",
                          [@[@39, @40, @(NAMRig::kMidPushPort)]
                              arrayByAddingObjectsFromArray:pinEqPorts(NAMRig::PinEqPane::Sculpt)],
                          sculptPresetTitles,
                          @selector(applySculptPreset:));

    NAMSculptVisualizer* scVis = [[NAMSculptVisualizer alloc] initWithFrame:NSZeroRect];
    scVis.translatesAutoresizingMaskIntoConstraints = NO;
    scVis.bright = 0.0f;
    scVis.inputEq = 0.0f;
    scVis.midPush = 0.0f;
    scVis.odTone = NAMRig::Overdrive::kToneDefault;
    scVis.enabled = state->rackControls[(size_t)NAMRig::Rack::Sculpt] >= 0.5f;
    state->sculptVisualizer = scVis;
    installPinEditor(state, scVis.pinEditor);
    [card addSubview:scVis];
    [[scVis.topAnchor constraintEqualToAnchor:chips.bottomAnchor constant:8] setActive:YES];
    [[scVis.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[scVis.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[scVis.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8] setActive:YES];
  }

  // 3. Pre-Amp Boost (right)
  {
    RigPanel* rack = addStudioRackSection(row3, @"PRE-AMP BOOST", @"TS-STYLE OVERDRIVE & PUSH",
                                          goldColor, state, NAMRig::Rack::Count, NAMRig::kOverdriveEnabledPort);
    [row3 addArrangedSubview:rack];

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

    const size_t boostK[4] = {39, 47, 40, 41};
    for (size_t idx : boostK) {
      [kr addArrangedSubview:addDeckKnobCell(kr, state, idx, mins, maxes, knobNames, knobDescriptions)];
    }
    state->sculptOdKnobs = kr;

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

    NSTextField* desc = addLabel(card, @"Overdrive boost with 4 diode voicings (TS, SD-1, LED, Germanium), variable tight high-pass cut, and active tone shaping.",
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
    [[chips.heightAnchor constraintEqualToConstant:22] setActive:YES];

    NSPopUpButton* voicing = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    voicing.controlSize = NSControlSizeSmall;
    voicing.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium];
    [voicing addItemsWithTitles:@[@"Classic TS", @"SD-1 Asym", @"LED Turbo", @"Germanium"]];
    NSArray<NSString*>* vTips = @[
      @"Classic TS: Symmetric silicon diodes for smooth compression and warm odd harmonics (TS808/TS9).",
      @"SD-1 Asym: Asymmetric silicon diodes (Boss SD-1 style) producing rich 2nd-order even harmonics.",
      @"LED Turbo: High-headroom red LEDs (Turbo/Guv'nor style) for punchy transients and open crunch.",
      @"Germanium: Low-threshold vintage germanium diodes for early compression, fuzzy bite, and warm saturation."
    ];
    for (NSUInteger i = 0; i < vTips.count; ++i) [voicing itemAtIndex:i].toolTip = vTips[i];
    voicing.target = state->uiController;
    voicing.action = @selector(boostVoicingChanged:);
    voicing.tag = NAMRig::kOverdriveVoicingPort;
    [chips addArrangedSubview:voicing];
    state->boostVoicingPopup = voicing;
    [voicing selectItemAtIndex:std::clamp(state->boostVoicing, 0, 3)];

    NSArray<NSString*>* boostPresetTitles = @[@"CLEAN BOOST", @"TS9 DRIVE", @"LEAD PUSH", @"TIGHT CHUG", @"WARM OVERDRIVE"];
    addSlotPresetDropdown(chips, state, @"boost", @"Pre-Amp Boost",
                          @[@(NAMRig::kOverdriveDrivePort), @(NAMRig::kOverdriveTightPort), @(NAMRig::kOverdriveVoicingPort), @(NAMRig::kOverdriveTonePort), @(NAMRig::kOverdriveLevelPort)],
                          boostPresetTitles, @selector(applyBoostPreset:));

    NAMBoostVisualizer* bVis = [[NAMBoostVisualizer alloc] initWithFrame:NSZeroRect];
    bVis.translatesAutoresizingMaskIntoConstraints = NO;
    bVis.drive = 0.0f;
    bVis.tight = NAMRig::kOverdriveTightDefault;
    bVis.voicing = state->boostVoicing;
    bVis.tone = NAMRig::Overdrive::kToneDefault;
    bVis.level = 0.0f;
    bVis.enabled = state->boostEnabled;
    state->boostVisualizer = bVis;
    [card addSubview:bVis];
    [[bVis.topAnchor constraintEqualToAnchor:chips.bottomAnchor constant:8] setActive:YES];
    [[bVis.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10] setActive:YES];
    [[bVis.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10] setActive:YES];
    [[bVis.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8] setActive:YES];
  }

  // ==========================================
  // PANE 0: PRECISION TUNER DECK
  // ==========================================
  NSView* pane4 = panes[0];
  state->tunerPanel = pane4;

  NSStackView* row4 = [[NSStackView alloc] initWithFrame:NSZeroRect];
  row4.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row4.distribution = NSStackViewDistributionFill;
  row4.spacing = 14.0;
  row4.translatesAutoresizingMaskIntoConstraints = NO;
  [pane4 addSubview:row4];
  [[row4.topAnchor constraintEqualToAnchor:pane4.topAnchor] setActive:YES];
  [[row4.bottomAnchor constraintEqualToAnchor:pane4.bottomAnchor] setActive:YES];
  [[row4.leadingAnchor constraintEqualToAnchor:pane4.leadingAnchor] setActive:YES];
  [[row4.trailingAnchor constraintEqualToAnchor:pane4.trailingAnchor] setActive:YES];

  // 1. Pitch Detector Display
  {
    RigPanel* pitchRack = addStudioRackSection(row4, @"PITCH DETECTOR", @"HARMONIC TRACKER", cyanColor);
    [row4 addArrangedSubview:pitchRack];
    [[pitchRack.widthAnchor constraintEqualToConstant:290] setActive:YES];

    NSView* displayBox = [[NSView alloc] initWithFrame:NSZeroRect];
    displayBox.wantsLayer = YES;
    displayBox.layer.backgroundColor = rigRaised().CGColor;
    displayBox.layer.cornerRadius = 8;
    displayBox.layer.borderWidth = 1.0;
    displayBox.layer.borderColor = rigPanelBorder().CGColor;
    displayBox.translatesAutoresizingMaskIntoConstraints = NO;
    [pitchRack addSubview:displayBox];
    [[displayBox.topAnchor constraintEqualToAnchor:pitchRack.topAnchor constant:40] setActive:YES];
    [[displayBox.leadingAnchor constraintEqualToAnchor:pitchRack.leadingAnchor constant:14] setActive:YES];
    [[displayBox.trailingAnchor constraintEqualToAnchor:pitchRack.trailingAnchor constant:-14] setActive:YES];
    [[displayBox.heightAnchor constraintEqualToConstant:118] setActive:YES];

    NSTextField* noteL = addLabel(displayBox, @"—", NSZeroRect,
                                  [NSFont systemFontOfSize:52 weight:NSFontWeightBold],
                                  rigText(), NSTextAlignmentCenter);
    noteL.translatesAutoresizingMaskIntoConstraints = NO;
    state->tunerNoteLabel = noteL;
    noteL.toolTip = @"Detected musical note and octave from raw guitar input.";
    [[noteL.centerXAnchor constraintEqualToAnchor:displayBox.centerXAnchor] setActive:YES];
    [[noteL.topAnchor constraintEqualToAnchor:displayBox.topAnchor constant:10] setActive:YES];

    NSTextField* centsL = addLabel(displayBox, @"", NSZeroRect,
                                   [NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightBold],
                                   rigDimText(), NSTextAlignmentCenter);
    centsL.translatesAutoresizingMaskIntoConstraints = NO;
    state->tunerCentsLabel = centsL;
    centsL.toolTip = @"Cents offset from detected pitch.";
    [[centsL.centerXAnchor constraintEqualToAnchor:displayBox.centerXAnchor] setActive:YES];
    [[centsL.topAnchor constraintEqualToAnchor:noteL.bottomAnchor constant:4] setActive:YES];

    NSView* trackerBadge = [[NSView alloc] initWithFrame:NSZeroRect];
    trackerBadge.wantsLayer = YES;
    trackerBadge.layer.backgroundColor = rigRaised().CGColor;
    trackerBadge.layer.cornerRadius = 4;
    trackerBadge.layer.borderWidth = 1.0;
    trackerBadge.layer.borderColor = rigPanelBorder().CGColor;
    trackerBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [pitchRack addSubview:trackerBadge];
    [[trackerBadge.topAnchor constraintEqualToAnchor:displayBox.bottomAnchor constant:10] setActive:YES];
    [[trackerBadge.leadingAnchor constraintEqualToAnchor:pitchRack.leadingAnchor constant:14] setActive:YES];
    [[trackerBadge.trailingAnchor constraintEqualToAnchor:pitchRack.trailingAnchor constant:-14] setActive:YES];
    [[trackerBadge.heightAnchor constraintEqualToConstant:28] setActive:YES];

    NSTextField* badgeText = addLabel(trackerBadge, @"AUTOCORRELATION • MPM (NSDF)", NSZeroRect,
                                      [NSFont systemFontOfSize:8.5 weight:NSFontWeightBold],
                                      cyanColor, NSTextAlignmentCenter);
    rigApplyTracking(badgeText, 0.8);
    badgeText.translatesAutoresizingMaskIntoConstraints = NO;
    [[badgeText.centerXAnchor constraintEqualToAnchor:trackerBadge.centerXAnchor] setActive:YES];
    [[badgeText.centerYAnchor constraintEqualToAnchor:trackerBadge.centerYAnchor] setActive:YES];
  }

  // 2. Precision Cent Deviation Meter & String Reference
  {
    RigPanel* meterRack = addStudioRackSection(row4, @"PRECISION CENT DEVIATION", @"±50 CENTS HIGH-RES STROBE METER", cyanColor);
    [row4 addArrangedSubview:meterRack];

    // Ruler markings view
    NSView* ruler = [[NSView alloc] initWithFrame:NSZeroRect];
    ruler.translatesAutoresizingMaskIntoConstraints = NO;
    [meterRack addSubview:ruler];
    [[ruler.topAnchor constraintEqualToAnchor:meterRack.topAnchor constant:42] setActive:YES];
    [[ruler.leadingAnchor constraintEqualToAnchor:meterRack.leadingAnchor constant:18] setActive:YES];
    [[ruler.trailingAnchor constraintEqualToAnchor:meterRack.trailingAnchor constant:-18] setActive:YES];
    [[ruler.heightAnchor constraintEqualToConstant:16] setActive:YES];

    NSTextField* l50 = addLabel(ruler, @"-50¢", NSZeroRect, [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium], rigDimText(), NSTextAlignmentLeft);
    l50.translatesAutoresizingMaskIntoConstraints = NO;
    [[l50.leadingAnchor constraintEqualToAnchor:ruler.leadingAnchor] setActive:YES];
    [[l50.centerYAnchor constraintEqualToAnchor:ruler.centerYAnchor] setActive:YES];

    NSTextField* l25 = addLabel(ruler, @"-25¢", NSZeroRect, [NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightMedium], rigDimText(), NSTextAlignmentCenter);
    l25.translatesAutoresizingMaskIntoConstraints = NO;
    [[NSLayoutConstraint constraintWithItem:l25 attribute:NSLayoutAttributeCenterX relatedBy:NSLayoutRelationEqual toItem:ruler attribute:NSLayoutAttributeTrailing multiplier:0.25 constant:0] setActive:YES];
    [[l25.centerYAnchor constraintEqualToAnchor:ruler.centerYAnchor] setActive:YES];

    NSTextField* l0 = addLabel(ruler, @"▼ 0¢ IN TUNE ▼", NSZeroRect, [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightBold], rigGreen(), NSTextAlignmentCenter);
    l0.translatesAutoresizingMaskIntoConstraints = NO;
    [[l0.centerXAnchor constraintEqualToAnchor:ruler.centerXAnchor] setActive:YES];
    [[l0.centerYAnchor constraintEqualToAnchor:ruler.centerYAnchor] setActive:YES];

    NSTextField* r25 = addLabel(ruler, @"+25¢", NSZeroRect, [NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightMedium], rigDimText(), NSTextAlignmentCenter);
    r25.translatesAutoresizingMaskIntoConstraints = NO;
    [[NSLayoutConstraint constraintWithItem:r25 attribute:NSLayoutAttributeCenterX relatedBy:NSLayoutRelationEqual toItem:ruler attribute:NSLayoutAttributeTrailing multiplier:0.75 constant:0] setActive:YES];
    [[r25.centerYAnchor constraintEqualToAnchor:ruler.centerYAnchor] setActive:YES];

    NSTextField* r50 = addLabel(ruler, @"+50¢", NSZeroRect, [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium], rigDimText(), NSTextAlignmentRight);
    r50.translatesAutoresizingMaskIntoConstraints = NO;
    [[r50.trailingAnchor constraintEqualToAnchor:ruler.trailingAnchor] setActive:YES];
    [[r50.centerYAnchor constraintEqualToAnchor:ruler.centerYAnchor] setActive:YES];

    // Wide horizontal meter track
    NSView* meter = [[NSView alloc] initWithFrame:NSZeroRect];
    meter.wantsLayer = YES;
    meter.layer.backgroundColor = rigRaised().CGColor;
    meter.layer.cornerRadius = 4;
    meter.layer.borderWidth = 1.0;
    meter.layer.borderColor = rigPanelBorder().CGColor;
    meter.translatesAutoresizingMaskIntoConstraints = NO;
    [meterRack addSubview:meter];
    meter.toolTip = @"Tuning meter spanning -50 to +50 cents. The center mark is in tune.";
    [[meter.topAnchor constraintEqualToAnchor:ruler.bottomAnchor constant:6] setActive:YES];
    [[meter.leadingAnchor constraintEqualToAnchor:meterRack.leadingAnchor constant:18] setActive:YES];
    [[meter.trailingAnchor constraintEqualToAnchor:meterRack.trailingAnchor constant:-18] setActive:YES];
    [[meter.heightAnchor constraintEqualToConstant:34] setActive:YES];

    // Center in-tune target strip (-5 to +5 cents = 10% width in center)
    NSView* targetZone = [[NSView alloc] initWithFrame:NSZeroRect];
    targetZone.wantsLayer = YES;
    targetZone.layer.backgroundColor = [NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.20].CGColor;
    targetZone.layer.cornerRadius = 2;
    targetZone.translatesAutoresizingMaskIntoConstraints = NO;
    [meter addSubview:targetZone];
    [[targetZone.centerXAnchor constraintEqualToAnchor:meter.centerXAnchor] setActive:YES];
    [[targetZone.centerYAnchor constraintEqualToAnchor:meter.centerYAnchor] setActive:YES];
    [[targetZone.widthAnchor constraintEqualToAnchor:meter.widthAnchor multiplier:0.1] setActive:YES];
    [[targetZone.heightAnchor constraintEqualToAnchor:meter.heightAnchor constant:-4] setActive:YES];

    // Center vertical calibration hairline
    NSView* centerMark = [[NSView alloc] initWithFrame:NSZeroRect];
    centerMark.wantsLayer = YES;
    centerMark.layer.backgroundColor = rigGreen().CGColor;
    centerMark.translatesAutoresizingMaskIntoConstraints = NO;
    [meter addSubview:centerMark];
    [[centerMark.centerXAnchor constraintEqualToAnchor:meter.centerXAnchor] setActive:YES];
    [[centerMark.centerYAnchor constraintEqualToAnchor:meter.centerYAnchor] setActive:YES];
    [[centerMark.widthAnchor constraintEqualToConstant:2] setActive:YES];
    [[centerMark.heightAnchor constraintEqualToAnchor:meter.heightAnchor] setActive:YES];

    // Sliding needle
    NSImageView* needle = [[NSImageView alloc] initWithFrame:NSZeroRect];
    needle.wantsLayer = YES;
    needle.layer.backgroundColor = rigAccent().CGColor;
    needle.layer.cornerRadius = 2.5;
    needle.hidden = YES;
    needle.translatesAutoresizingMaskIntoConstraints = NO;
    [meter addSubview:needle];
    needle.toolTip = @"Current tuning offset; centered and green means in tune.";
    state->tunerNeedle = needle;
    [[needle.centerYAnchor constraintEqualToAnchor:meter.centerYAnchor] setActive:YES];
    [[needle.heightAnchor constraintEqualToAnchor:meter.heightAnchor constant:6] setActive:YES];
    [[needle.widthAnchor constraintEqualToConstant:6] setActive:YES];

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

    // Guidance indicators below meter
    NSView* guideRow = [[NSView alloc] initWithFrame:NSZeroRect];
    guideRow.translatesAutoresizingMaskIntoConstraints = NO;
    [meterRack addSubview:guideRow];
    [[guideRow.leadingAnchor constraintEqualToAnchor:meter.leadingAnchor] setActive:YES];
    [[guideRow.trailingAnchor constraintEqualToAnchor:meter.trailingAnchor] setActive:YES];
    [[guideRow.topAnchor constraintEqualToAnchor:meter.bottomAnchor constant:8] setActive:YES];
    [[guideRow.heightAnchor constraintEqualToConstant:16] setActive:YES];

    NSTextField* flatGuide = addLabel(guideRow, @"◀ FLAT (TUNE UP)", NSZeroRect,
                                      [NSFont systemFontOfSize:9 weight:NSFontWeightBold],
                                      [NSColor colorWithSRGBRed:0.95 green:0.65 blue:0.25 alpha:0.8], NSTextAlignmentLeft);
    flatGuide.translatesAutoresizingMaskIntoConstraints = NO;
    [[flatGuide.leadingAnchor constraintEqualToAnchor:guideRow.leadingAnchor] setActive:YES];
    [[flatGuide.centerYAnchor constraintEqualToAnchor:guideRow.centerYAnchor] setActive:YES];

    NSTextField* centerGuide = addLabel(guideRow, @"● TARGET LOCK ●", NSZeroRect,
                                        [NSFont systemFontOfSize:9 weight:NSFontWeightBold],
                                        rigGreen(), NSTextAlignmentCenter);
    centerGuide.translatesAutoresizingMaskIntoConstraints = NO;
    [[centerGuide.centerXAnchor constraintEqualToAnchor:guideRow.centerXAnchor] setActive:YES];
    [[centerGuide.centerYAnchor constraintEqualToAnchor:guideRow.centerYAnchor] setActive:YES];

    NSTextField* sharpGuide = addLabel(guideRow, @"SHARP (TUNE DOWN) ▶", NSZeroRect,
                                       [NSFont systemFontOfSize:9 weight:NSFontWeightBold],
                                       [NSColor colorWithSRGBRed:0.95 green:0.65 blue:0.25 alpha:0.8], NSTextAlignmentRight);
    sharpGuide.translatesAutoresizingMaskIntoConstraints = NO;
    [[sharpGuide.trailingAnchor constraintEqualToAnchor:guideRow.trailingAnchor] setActive:YES];
    [[sharpGuide.centerYAnchor constraintEqualToAnchor:guideRow.centerYAnchor] setActive:YES];

    // Standard Tuning String Reference Guide
    NSStackView* stringStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stringStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stringStack.distribution = NSStackViewDistributionFillEqually;
    stringStack.spacing = 8.0;
    stringStack.translatesAutoresizingMaskIntoConstraints = NO;
    [meterRack addSubview:stringStack];
    [[stringStack.leadingAnchor constraintEqualToAnchor:meter.leadingAnchor] setActive:YES];
    [[stringStack.trailingAnchor constraintEqualToAnchor:meter.trailingAnchor] setActive:YES];
    [[stringStack.topAnchor constraintEqualToAnchor:guideRow.bottomAnchor constant:12] setActive:YES];
    [[stringStack.heightAnchor constraintEqualToConstant:32] setActive:YES];

    NSArray<NSString*>* strings = @[
      @"6 : E2 • 82.4 Hz",
      @"5 : A2 • 110.0 Hz",
      @"4 : D3 • 146.8 Hz",
      @"3 : G3 • 196.0 Hz",
      @"2 : B3 • 246.9 Hz",
      @"1 : E4 • 329.6 Hz"
    ];
    for (NSString* str in strings) {
      NSView* pill = [[NSView alloc] initWithFrame:NSZeroRect];
      pill.wantsLayer = YES;
      pill.layer.backgroundColor = rigRaised().CGColor;
      pill.layer.cornerRadius = 4;
      pill.layer.borderWidth = 1.0;
      pill.layer.borderColor = rigPanelBorder().CGColor;
      NSTextField* pl = addLabel(pill, str, NSZeroRect,
                                 [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightMedium],
                                 rigDimText(), NSTextAlignmentCenter);
      pl.translatesAutoresizingMaskIntoConstraints = NO;
      [[pl.centerXAnchor constraintEqualToAnchor:pill.centerXAnchor] setActive:YES];
      [[pl.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor] setActive:YES];
      [stringStack addArrangedSubview:pill];
    }
  }

  // 3. Tuner Controls & Calibration
  {
    RigPanel* ctrlRack = addStudioRackSection(row4, @"TUNER CONTROLS & ROUTING", @"CALIBRATION & MUTE", cyanColor);
    [row4 addArrangedSubview:ctrlRack];
    [[ctrlRack.widthAnchor constraintEqualToConstant:290] setActive:YES];

    RigButton* tBtn = rigButton(ctrlRack, @"TUNER ACTIVE", state->uiController,
                                @selector(tunerToggled:), NSZeroRect);
    tBtn.toolTip = @"Enable or disable guitar pitch detection.";
    tBtn.buttonType = NSButtonTypeToggle;
    tBtn.state = NSControlStateValueOn;
    tBtn.primary = YES;
    tBtn.translatesAutoresizingMaskIntoConstraints = NO;
    state->tunerButton = tBtn;
    [[tBtn.topAnchor constraintEqualToAnchor:ctrlRack.topAnchor constant:40] setActive:YES];
    [[tBtn.leadingAnchor constraintEqualToAnchor:ctrlRack.leadingAnchor constant:14] setActive:YES];
    [[tBtn.trailingAnchor constraintEqualToAnchor:ctrlRack.trailingAnchor constant:-14] setActive:YES];
    [[tBtn.heightAnchor constraintEqualToConstant:32] setActive:YES];

    RigButton* muteBtn = rigButton(ctrlRack, @"MUTE GUITAR OUTPUT", state->uiController,
                                   @selector(toggleMuteOnTune:), NSZeroRect);
    muteBtn.toolTip = @"Mute guitar output while tuning for silent on-stage tuning.";
    muteBtn.buttonType = NSButtonTypeToggle;
    muteBtn.state = state->muteOnTune ? NSControlStateValueOn : NSControlStateValueOff;
    muteBtn.primary = state->muteOnTune;
    muteBtn.translatesAutoresizingMaskIntoConstraints = NO;
    state->muteOnTuneButton = muteBtn;
    [[muteBtn.topAnchor constraintEqualToAnchor:tBtn.bottomAnchor constant:8] setActive:YES];
    [[muteBtn.leadingAnchor constraintEqualToAnchor:ctrlRack.leadingAnchor constant:14] setActive:YES];
    [[muteBtn.trailingAnchor constraintEqualToAnchor:ctrlRack.trailingAnchor constant:-14] setActive:YES];
    [[muteBtn.heightAnchor constraintEqualToConstant:32] setActive:YES];

    // Info card below buttons
    NSView* infoCard = [[NSView alloc] initWithFrame:NSZeroRect];
    infoCard.wantsLayer = YES;
    infoCard.layer.backgroundColor = rigRaised().CGColor;
    infoCard.layer.cornerRadius = 6;
    infoCard.layer.borderWidth = 1.0;
    infoCard.layer.borderColor = rigPanelBorder().CGColor;
    infoCard.translatesAutoresizingMaskIntoConstraints = NO;
    [ctrlRack addSubview:infoCard];
    [[infoCard.topAnchor constraintEqualToAnchor:muteBtn.bottomAnchor constant:10] setActive:YES];
    [[infoCard.leadingAnchor constraintEqualToAnchor:ctrlRack.leadingAnchor constant:14] setActive:YES];
    [[infoCard.trailingAnchor constraintEqualToAnchor:ctrlRack.trailingAnchor constant:-14] setActive:YES];
    [[infoCard.heightAnchor constraintEqualToConstant:68] setActive:YES];

    NSTextField* info1 = addLabel(infoCard, @"CONCERT PITCH : A4 = 440.0 Hz", NSZeroRect,
                                  [NSFont systemFontOfSize:8.5 weight:NSFontWeightMedium],
                                  rigDimText(), NSTextAlignmentLeft);
    info1.translatesAutoresizingMaskIntoConstraints = NO;
    [[info1.topAnchor constraintEqualToAnchor:infoCard.topAnchor constant:8] setActive:YES];
    [[info1.leadingAnchor constraintEqualToAnchor:infoCard.leadingAnchor constant:10] setActive:YES];

    NSTextField* info2 = addLabel(infoCard, @"SIGNAL TAP : PRE-AMP DIRECT TAP", NSZeroRect,
                                  [NSFont systemFontOfSize:8.5 weight:NSFontWeightMedium],
                                  rigDimText(), NSTextAlignmentLeft);
    info2.translatesAutoresizingMaskIntoConstraints = NO;
    [[info2.topAnchor constraintEqualToAnchor:info1.bottomAnchor constant:5] setActive:YES];
    [[info2.leadingAnchor constraintEqualToAnchor:infoCard.leadingAnchor constant:10] setActive:YES];

    NSTextField* info3 = addLabel(infoCard, @"DETECTION RANGE : 55 Hz – 1400 Hz", NSZeroRect,
                                  [NSFont systemFontOfSize:8.5 weight:NSFontWeightMedium],
                                  rigDimText(), NSTextAlignmentLeft);
    info3.translatesAutoresizingMaskIntoConstraints = NO;
    [[info3.topAnchor constraintEqualToAnchor:info2.bottomAnchor constant:5] setActive:YES];
    [[info3.leadingAnchor constraintEqualToAnchor:infoCard.leadingAnchor constant:10] setActive:YES];
  }
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
    state->preAmpDbURID = map->map(map->handle, NAM_RIG_PRE_AMP_DB_URI);
    state->postAmpDbURID = map->map(map->handle, NAM_RIG_POST_AMP_DB_URI);
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
    headerBar.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
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
    rootView.rigContent = content;

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

    state->aiCopilotBtn = rigButton(headerBar, @"✨ AI Tone Tuning", state->uiController, @selector(openAICopilot:), NSZeroRect);
    state->aiCopilotBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [[state->aiCopilotBtn.leadingAnchor constraintEqualToAnchor:state->toneTabBtn.trailingAnchor constant:6] setActive:YES];
    [[state->aiCopilotBtn.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor] setActive:YES];
    [[state->aiCopilotBtn.widthAnchor constraintEqualToConstant:140] setActive:YES];
    [[state->aiCopilotBtn.heightAnchor constraintEqualToConstant:24] setActive:YES];
    state->aiCopilotBtn.toolTip = @"AI Tone Tuning (⌘K): Describe any artist, song, or tone adjustment in plain English.";

    // Rig header group (tuner, preset management, A/B compare):
    // active in RIG tab, hidden in TONE3000 tab.
    NAMRigHeaderGroup* rigGroup = [[NAMRigHeaderGroup alloc] initWithFrame:NSZeroRect];
    rigGroup.translatesAutoresizingMaskIntoConstraints = NO;
    rigGroup.wantsLayer = YES;
    rigGroup.layer.masksToBounds = NO;
    [headerBar addSubview:rigGroup];
    state->rigHeaderGroup = rigGroup;
    [[rigGroup.leadingAnchor constraintEqualToAnchor:state->aiCopilotBtn.trailingAnchor constant:14] setActive:YES];
    [[rigGroup.trailingAnchor constraintEqualToAnchor:headerBar.trailingAnchor] setActive:YES];
    [[rigGroup.topAnchor constraintEqualToAnchor:headerBar.topAnchor] setActive:YES];
    [[rigGroup.bottomAnchor constraintEqualToAnchor:headerBar.bottomAnchor] setActive:YES];

    // Preset management controls: [ ◀ ] [ Preset: Name ▾ ] [ ▶ ] [ SAVE ]
    RigButton* prevPresetBtn = rigButton(rigGroup, @"◀", state->uiController,
                                         @selector(prevPresetClicked:), NSZeroRect);
    prevPresetBtn.toolTip = @"Switch to the previous preset (Left Arrow ←).";
    prevPresetBtn.translatesAutoresizingMaskIntoConstraints = NO;
    state->prevPresetBtn = prevPresetBtn;
    [[prevPresetBtn.leadingAnchor constraintEqualToAnchor:rigGroup.leadingAnchor] setActive:YES];
    [[prevPresetBtn.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[prevPresetBtn.widthAnchor constraintEqualToConstant:24] setActive:YES];
    [[prevPresetBtn.heightAnchor constraintEqualToConstant:24] setActive:YES];

    NSPopUpButton* presetPop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    presetPop.controlSize = NSControlSizeSmall;
    presetPop.target = state->uiController;
    presetPop.action = @selector(presetPopupChanged:);
    presetPop.toolTip = @"Active preset. Click to select a preset, use ←/→ to step up/down through presets, or press ⌘S to save.";
    presetPop.translatesAutoresizingMaskIntoConstraints = NO;
    [rigGroup addSubview:presetPop];
    state->presetPopup = presetPop;
    presetPop.menu.delegate = (id<NSMenuDelegate>)state->uiController;
    presetPop.menu.identifier = @"preset_popup_menu";
    [[presetPop.leadingAnchor constraintEqualToAnchor:prevPresetBtn.trailingAnchor constant:4] setActive:YES];
    [[presetPop.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[presetPop.widthAnchor constraintEqualToConstant:155] setActive:YES];
    [[presetPop.heightAnchor constraintEqualToConstant:24] setActive:YES];

    RigButton* nextPresetBtn = rigButton(rigGroup, @"▶", state->uiController,
                                         @selector(nextPresetClicked:), NSZeroRect);
    nextPresetBtn.toolTip = @"Switch to the next preset (Right Arrow →).";
    nextPresetBtn.translatesAutoresizingMaskIntoConstraints = NO;
    state->nextPresetBtn = nextPresetBtn;
    [[nextPresetBtn.leadingAnchor constraintEqualToAnchor:presetPop.trailingAnchor constant:4] setActive:YES];
    [[nextPresetBtn.centerYAnchor constraintEqualToAnchor:rigGroup.centerYAnchor] setActive:YES];
    [[nextPresetBtn.widthAnchor constraintEqualToConstant:24] setActive:YES];
    [[nextPresetBtn.heightAnchor constraintEqualToConstant:24] setActive:YES];

    // Hands-free A/B compare strip: B slot + 0-30s interval slider + START/STOP.
    // A is the live active preset in the main window; status shows the sounding side.
    NSTextField* abBLabel = addLabel(rigGroup, @"B", NSZeroRect,
                                     [NSFont systemFontOfSize:10 weight:NSFontWeightBold],
                                     rigDimText(), NSTextAlignmentCenter);
    abBLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [[abBLabel.leadingAnchor constraintEqualToAnchor:nextPresetBtn.trailingAnchor constant:10] setActive:YES];
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
    abPopB.menu.delegate = (id<NSMenuDelegate>)state->uiController;
    abPopB.menu.identifier = @"ab_popup_menu";
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
    [[abToggle.trailingAnchor constraintLessThanOrEqualToAnchor:rigGroup.trailingAnchor constant:-8] setActive:YES];

    NSArray<NSString*>* names = @[@"PEDAL", @"AMP", @"CAB"];
    // Quality is fixed at 100% — no knob, the DSP never scales model quality.
    // Display names indexed by kRigKnobPorts order; cells are laid out in
    // signal order via kRigKnobDisplayOrder.
    NSArray<NSString*>* knobNames = @[@"GATE", @"RELEASE", @"INPUT", @"COMP",
                                      @"DRIVE", @"BASS", @"MID", @"TREBLE",
                                      @"CAB A LVL", @"LOW CUT", @"HIGH CUT", @"OUTPUT",
                                      @"WIDTH", @"ROOM", @"PRESENCE", @"DEPTH",
                                      @"SAG", @"BIAS", @"NEG FDBK", @"BRIGHT",
                                      @"INPUT EQ", @"MASTER", @"SPKR DRIVE", @"SPKR COMP",
                                      @"THUMP", @"RESONANCE",
                                      @"CAB B LVL", @"ALIGN", @"DLY TIME", @"DLY FDBK",
                                      @"DLY DAMP", @"DLY MIX", @"RVB MIX", @"DECAY",
                                      @"SIZE", @"RVB DAMP", @"PRE-DLY", @"CHARACTER",
                                      @"MID PUSH", @"OD DRIVE", @"OD TONE", @"OD LEVEL",
                                      @"ATTACK", @"RELEASE", @"AMOUNT", @"ATTACK", @"RELEASE", @"OD TIGHT"];
    NSArray<NSString*>* knobValues = @[@"OFF", @"150 ms", @"+0.0 dB", @"OFF",
                                       @"+0.0 dB", @"+0.0 dB", @"+0.0 dB", @"+0.0 dB",
                                       @"+0.0 dB", @"OFF", @"OFF", @"+0.0 dB", @"OFF", @"OFF",
                                       @"+0.0 dB", @"+0.0 dB", @"OFF", @"+0%",
                                       @"OFF", @"OFF", @"OFF", @"OFF", @"25%", @"25%", @"50%", @"50%",
                                       @"+0.0 dB", @"OFF", @"400 ms", @"35%", @"40%", @"OFF",
                                       @"OFF", @"50%", @"50%", @"50%", @"10 ms", @"50%", @"OFF",
                                       @"OFF", @"50%", @"+0.0 dB", @"8.0 ms", @"120 ms", @"OFF", @"8.0 ms", @"120 ms", @"720 Hz"];
    NSArray<NSString*>* knobDescriptions = @[
      @"Gate threshold. Mutes background hiss and pickup hum when not playing. Raising it clamps down on noise for tight, staccato chugs; setting it too high cuts off decaying note sustain. -80 dB bypasses the gate.",
      @"Gate release time. Controls how quickly the gate closes once your signal falls below the threshold. Shorter times give an immediate, sharp cutoff for aggressive metal rhythms; longer times let chords and sustain fade out naturally.",
      @"Input level trim. Adjusts raw guitar signal strength before hitting any pedals, the amp, or compression. Turn up to push high-gain models harder into saturation; turn down for extra clean headroom.",
      @"Pre-model compressor. Evens out playing dynamics and adds smooth sustain before hitting the amp. Higher settings squash loud pick transients and bring up quiet details while preserving initial pick attack.",
      @"Amp drive boost. Boosts or attenuates the signal between the pedal and the amp model. Turn up to push the amp into richer preamp saturation and harmonic crunch; turn down to clean up the tone.",
      @"Post-cab bass EQ (150 Hz shelf). Shapes the low end of your sound after the cabinet. Turn up to add body, low-frequency warmth, and cabinet weight; turn down to clear up low-end boominess and mud.",
      @"Post-cab midrange EQ (700 Hz bell). Shapes the crucial mid frequencies after the cabinet. Turn up to punch forward and cut through a dense mix; turn down (scoop) for classic aggressive metal rhythm tone.",
      @"Post-cab treble EQ (3 kHz shelf). Shapes top-end brightness after the cabinet. Turn up for crisper pick definition, attack presence, and sheen; turn down to tame harsh digital fizz and ice-pick highs.",
      @"Cab A level trim. Adjusts the volume of Cabinet A independently before it blends with Cabinet B. Use it to level-match different impulse responses or balance the blend between Cab A and Cab B without changing tone; -24 dB mutes Cab A (OFF).",
      @"Cabinet low cut (high-pass filter). Rolls off sub-bass rumble and low-end flub below the cutoff frequency. Raising this tightens palm mutes and keeps deep lows clear of bass and kick drum frequencies; 0 Hz bypasses.",
      @"Cabinet high cut (low-pass filter). Smooths away harsh top-end sizzle and ultra-high fizz above the cutoff frequency. Lowering this rounds off the highs for a warmer, more organic vintage speaker tone; 20 kHz bypasses.",
      @"Master output level (blended Cab A + B output). Final output volume trim after the cabinets and rig. Adjusts overall output level without altering distortion, tone balance, or Cab A/B blend ratio.",
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
      @"Cab B level trim. Adjusts the volume of the second cabinet (Cab B) before it mixes with Cab A. Use it to balance dual-cabinet blends (e.g. blending a dark ribbon mic with a bright dynamic mic); -24 dB mutes Cab B (OFF).",
      @"Cab alignment (-10 to +10 ms). Negative values delay Cab A; positive values delay Cab B, by up to 10 ms. Zero adds no user delay; pipeline latency compensation is unchanged. Align two cabinets by ear to reduce comb filtering.",
      @"Stereo delay time. Sets the time between delay repeats from 20 ms to 2000 ms. Short settings create tight slapback or double-tracking; medium settings create rhythmic groove; long settings create spacious ambient leads.",
      @"Delay feedback. Controls the number of delay repeats. Higher settings produce cascading echoes that slowly decay into a soft, tape-like wash through the damping filter and limiter.",
      @"Delay damping. High-frequency loss of each delay repeat, from bright digital to dark tape-like. Low damping keeps repeats crisp and clear; high damping rolls off top end so repeats sit warmly behind your playing.",
      @"Delay mix. Blends wet delay echoes with dry guitar tone. At 0%, delay is fully bypassed; higher settings make repeats more prominent for atmospheric textures and solos.",
      @"Plate reverb mix. Blends the lush plate reverb tank with the dry guitar sound. At 0%, reverb is fully bypassed; higher settings immerse your tone in deep, shimmering space while Room stays available on its own.",
      @"Reverb decay time. Controls how long the reverb tail lingers. Short settings add subtle studio room ambience; long settings produce cavernous, dreamy reverberation that floats behind sustained notes.",
      @"Reverb space size. Scales the reverb plate tank dimensions and the room's early reflections. Smaller sizes sound tight and intimate; larger sizes expand into a vast acoustic hall.",
      @"Reverb high damping. Controls high-frequency absorption in the plate and room reflections. Lower damping preserves bright, airy shimmer; higher damping darkens the tail for a warm, natural decay that never clutters the mix.",
      @"Reverb pre-delay. Sets the time gap (0-100 ms) before the reverb tail begins. Keeps your initial pick attack and note definition clear and upfront before the ambient reverb blooms.",
      @"Amount of added tube-inspired character. Changes clipping knee, headroom and asymmetry in the shared power-stage engine. 0% preserves the existing power-stage response. The captured amp's original tubes are not removed.",
      @"Mid push (pre-amp). Overdrive-style midrange bell (750 Hz, up to +9 dB) before the NAM amp model, like a Tube Screamer or tight boost. Pair with Input EQ and a little Drive to stand in for a separate overdrive capture. 0% is exact bypass.",
      @"Overdrive drive (pre-amp, Tube Screamer-style). Clips only the mids above 720 Hz with a soft diode pair and mixes the clean signal back, so bass stays tight and pick attack survives. Sits in front of the amp like a pedal, ahead of Amp Drive. At 0%, acts as a distortionless clean boost.",
      @"Overdrive tone. Treble roll-off after the clipper, from dark (700 Hz) to bright (8.4 kHz). Shown on the Sculpt graph.",
      @"Overdrive level. Output of the overdrive into the amp, -12 to +12 dB. Raise it to hit the amp harder with clean or saturated boost. Shown on the Sculpt graph.",
      @"Attack time for the pre-model compressor (1 to 100 ms). Faster attack clamps pick transients sooner; slower attack lets the transient through for more snap.",
      @"Release time for the pre-model compressor (10 to 1000 ms). Faster release gives a breathing, lively response; slower release yields smooth sustain.",
      @"Post-cab stereo compression before delay and reverb. Amount lowers threshold, raises ratio and adds makeup gain. Both channels share gain reduction to preserve the stereo image. 0% is exact bypass; independent of pre-amp compression.",
      @"Post-cab compressor attack (1 to 100 ms). Slower attack preserves pick punch; faster attack controls peaks. No lookahead or added latency.",
      @"Post-cab compressor release (10 to 1000 ms). Short releases recover between notes; longer releases smooth sustained leads.",
      @"Overdrive tight high-pass cutoff (100 to 1500 Hz). Sweeps the pre-clip bass roll-off frequency: lower settings give warm, full-range drive; higher settings tighten flub and sharpen pick attack for modern rhythms."
    ];

    const std::array<double, kRigKnobCount> mins{
        -80.0, 20.0, -20.0, 0.0, -24.0, -12.0, -12.0, -12.0, -24.0, 0.0, 4000.0, -20.0, 0.0, 0.0,
        -12.0, -12.0, 0.0, -100.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        -24.0, -10.0, 20.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        0.0, 0.0, -12.0, 1.0, 10.0, 0.0, 1.0, 10.0, 100.0};
    const std::array<double, kRigKnobCount> maxes{
        0.0, 1000.0, 20.0, 100.0, 24.0, 12.0, 12.0, 12.0, 24.0, 200.0, 20000.0, 20.0, 100.0, 100.0,
        12.0, 12.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0,
        24.0, 10.0, 2000.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0, 100.0,
        100.0, 100.0, 12.0, 100.0, 1000.0, 100.0, 100.0, 1000.0, 1500.0};

    NSStackView* boxRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
    boxRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    boxRow.translatesAutoresizingMaskIntoConstraints = NO;
    [rigPane addSubview:boxRow];
    [[boxRow.leadingAnchor constraintEqualToAnchor:rigPane.leadingAnchor constant:24] setActive:YES];
    [[boxRow.trailingAnchor constraintEqualToAnchor:rigPane.trailingAnchor constant:-24] setActive:YES];
    [[boxRow.topAnchor constraintEqualToAnchor:rigPane.topAnchor constant:12] setActive:YES];
    [[boxRow.heightAnchor constraintEqualToConstant:242] setActive:YES];

    // Reserve pedal header space beside the meters without shrinking the amp's
    // six 70pt value cells. Cabinet blend controls live in the lower console;
    // only the OUTPUT knob remains under the cabinet card.
    const CGFloat tileUnits[3] = {4.65, 6.0, 6.0};
    NSView* knobGroups[3] = {nil, nil, nil};
    RigPanel* tileBoxes[3] = {nil, nil, nil};

    // Display slots grouped per tile in signal-flow order.
    // Pedal tile displays Gate threshold and release, plus Input level trim when a pedal model is active.
    const size_t groupSlots[3][6] = {{0, 1, 2, 0, 0, 0}, {4, 14, 15, 5, 6, 7}, {11, 0, 0, 0, 0, 0}};
    const size_t groupCounts[3] = {3, 6, 1};

    const CGFloat groupPad = 4.0;
    const CGFloat knobSide = 64.0;

    for (size_t g = 0; g < 3; ++g) {
      NSView* group = nil;
      NSStackView* pedalStack = nil;
      if (g == 0) {
        pedalStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
        pedalStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        pedalStack.distribution = NSStackViewDistributionFillEqually;
        pedalStack.spacing = 0.0;
        pedalStack.edgeInsets = NSEdgeInsetsMake(0, groupPad, 0, groupPad);
        group = pedalStack;
      } else {
        group = [[NSView alloc] initWithFrame:NSZeroRect];
      }
      group.translatesAutoresizingMaskIntoConstraints = NO;
      [rigPane addSubview:group];
      knobGroups[g] = group;
      [[group.topAnchor constraintEqualToAnchor:boxRow.bottomAnchor constant:14] setActive:YES];
      [[group.heightAnchor constraintEqualToConstant:110] setActive:YES];

      // Equal-width cells tiled across the group. All knobs stay full-size
      // 64pt. Cell width must fit the 70pt value box, so each 6-knob group
      // gets 1/6 of its tile width; spacing only separates groups, never
      // cells — knobs can't drift together no matter how wide the window is.
      // The pedal group uses an NSStackView: 2 knobs when no pedal model is chosen,
      // revealing Input trim when a pedal model is active.
      NSView* prev = nil;
      for (size_t gi = 0; gi < groupCounts[g]; ++gi) {
        const size_t slot = groupSlots[g][gi];
        const size_t k = kRigKnobDisplayOrder[slot];
        NSView* cell = [[NSView alloc] initWithFrame:NSZeroRect];
        cell.translatesAutoresizingMaskIntoConstraints = NO;
        if (pedalStack) {
          [pedalStack addArrangedSubview:cell];
          [[cell.topAnchor constraintEqualToAnchor:pedalStack.topAnchor] setActive:YES];
          [[cell.bottomAnchor constraintEqualToAnchor:pedalStack.bottomAnchor] setActive:YES];
          if (kRigKnobPorts[k] == 4) {
            state->pedalInputKnobCell = cell;
            cell.hidden = state->selectedPaths[0].empty() ? YES : NO;
          }
        } else {
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
        }

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
    state->selectDeckTab(1);

    for (NSInteger i = 0; i < 3; ++i) {
      RigPanel* box = addPanel(boxRow, NSMakeRect(0, 0, 100, 100));
      __weak NAMRigUIController* weakCtrl = state->uiController;
      if (i < 2) {
        box.onClick = ^{
          if (weakCtrl) {
            [weakCtrl selectStageCard:i];
          }
        };
      } else {
        // Cabinet stage card (i == 2):
        // Do NOT apply the selection border to the whole card!
        // Instead, clicking inside selects Cab A or Cab B dropdown based on horizontal click location.
        box.onClickWithEvent = ^(NSEvent* event, RigPanel* pnl) {
          if (weakCtrl && pnl) {
            NSPoint loc = [pnl convertPoint:event.locationInWindow fromView:nil];
            if (loc.x >= pnl.bounds.size.width * 0.5) {
              [weakCtrl selectStageCard:3];
            } else {
              [weakCtrl selectStageCard:2];
            }
          }
        };
      }
      NSArray<NSString*>* stageTips = @[
        @"Pedal stage: dynamics and input conditioning feed the selected pedal NAM model before the amp. Right-click card to remove selection.",
        @"Amp stage: the selected NAM model, drive trim, and optional output-transformer coloration form the core amp sound. Right-click card to remove selection.",
        @"Cabinet stage: run a cabinet NAM model or WAV impulse response, optionally a parallel second cabinet, followed by cab level, frequency cuts, and the stereo effects. Right-click card to remove selection."
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
      [nmL setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

      NSTextField* hdrArch = [[NSTextField alloc] initWithFrame:NSZeroRect];
      hdrArch.editable = NO; hdrArch.selectable = NO; hdrArch.drawsBackground = NO; hdrArch.bordered = NO;
      hdrArch.font = [NSFont systemFontOfSize:9.5 weight:NSFontWeightBold];
      hdrArch.alignment = NSTextAlignmentCenter;
      hdrArch.lineBreakMode = NSLineBreakByTruncatingTail;
      hdrArch.wantsLayer = YES;
      hdrArch.layer.cornerRadius = 5.0;
      hdrArch.layer.borderWidth = 1.0;
      hdrArch.layer.masksToBounds = YES;
      hdrArch.translatesAutoresizingMaskIntoConstraints = NO;
      [hdrArch setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
      [header addSubview:hdrArch];
      [[hdrArch.leadingAnchor constraintEqualToAnchor:nmL.trailingAnchor constant:8] setActive:YES];
      [[hdrArch.centerYAnchor constraintEqualToAnchor:header.centerYAnchor] setActive:YES];
      [[hdrArch.heightAnchor constraintEqualToConstant:18] setActive:YES];
      state->stageHeaderArchBadges[(size_t)i] = hdrArch;
      state->updateStageArchBadge((size_t)i, nil);

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
      // left of the ON button, five modes: None / True 2x / 4x / 8x / 16x.
      if (i < 2) {
        NSPopUpButton* so = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [so addItemsWithTitles:@[@"None", @"True 2x", @"True 4x", @"True 8x", @"True 16x"]];
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
        [[so.widthAnchor constraintEqualToConstant:94] setActive:YES];
        [[so.heightAnchor constraintEqualToConstant:24] setActive:YES];
        [so selectItemAtIndex:3];        // default True 8x = TTL default
        so.toolTip = popupTooltip(
            [NSString stringWithFormat:@"Sets %@-stage oversampling.", stageName(i)], so);
        state->stageOsPopup[(size_t)i] = so;
        // Keep the stage architecture badge clear of the popup.
        [[hdrArch.trailingAnchor constraintLessThanOrEqualToAnchor:so.leadingAnchor
                                                          constant:-6] setActive:YES];
      } else {
        NSPopUpButton* norm = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [norm addItemsWithTitles:@[@"Peak", @"Loudness"]];
        NSArray<NSString*>* normalizationDescriptions = @[
          @"Peak - Scales the strongest audible-band response to unity for more headroom; this is not an output limiter.",
          @"Loudness - Matches average audible-band response energy to unity for consistent cabinet levels."
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
        [norm selectItemAtIndex:1];
        norm.toolTip = popupTooltip(@"Sets WAV impulse-response gain handling. Changes glide smoothly.", norm);
        state->irNormPopup = norm;
        [[hdrArch.trailingAnchor constraintLessThanOrEqualToAnchor:norm.leadingAnchor
                                                          constant:-6] setActive:YES];
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
      // Keep artwork wells and model selectors vertically aligned across all 3 tiles.
      [[thumb.heightAnchor constraintEqualToConstant:141] setActive:YES];
      state->stageImages[(size_t)i] = thumb;
      thumb.toolTip = [NSString stringWithFormat:@"Artwork for the currently selected %@ tone or model. Right-click card to remove selection.", stageName(i)];

      NSMenu* cardMenu = [[NSMenu alloc] initWithTitle:[NSString stringWithFormat:@"%@ Card Menu", names[(NSUInteger)i]]];
      cardMenu.identifier = [NSString stringWithFormat:@"stage_card_menu_%ld", (long)i];
      cardMenu.delegate = state->uiController;
      box.menu = cardMenu;
      thumb.menu = cardMenu;
      header.menu = cardMenu;
      state->stageCards[(size_t)i] = box;

      // Legacy compatibility references (docked into Lower Studio Deck):
      // "ADVANCED AMP", "SPEAKER LOAD", "Speaker Dynamics / Impedance", "WIDTH / DELAY / REVERB"
      // state->effectsPopover, state->speakerPopover, state->ampAdvancedPopover

      // The dropdown is the tile's model control/display — always visible.
      state->modelPickers[(size_t)i] = [[RigPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
      RigPopUpButton* mp = state->modelPickers[(size_t)i];
      mp.wantsLayer = YES;
      mp.layer.cornerRadius = 4.0;
      mp.onClick = ^{
        if (weakCtrl) {
          [weakCtrl selectStageCard:i];
        }
      };
      mp.translatesAutoresizingMaskIntoConstraints = NO;
      mp.controlSize = NSControlSizeSmall;
      mp.tag = (NSInteger)i;
      mp.target = state->uiController;
      mp.action = @selector(stageModelChanged:);
      [mp addItemWithTitle:@"No model loaded"];
      [mp itemAtIndex:0].toolTip = RigUIState::modelPickerTooltip((size_t)i, nil);
      mp.toolTip = RigUIState::modelPickerTooltip((size_t)i, nil);
      mp.enabled = NO;
      mp.cell.lineBreakMode = NSLineBreakByTruncatingTail;
      [mp setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
      [mp setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
      [box addSubview:mp];
      [[mp.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16] setActive:YES];
      [[mp.topAnchor constraintEqualToAnchor:thumb.bottomAnchor constant:8] setActive:YES];
      [[mp.heightAnchor constraintEqualToConstant:23] setActive:YES];

      if (i < 2) {
        RigButton* browseBtn = rigButton(box, @"…", state->uiController, @selector(chooseModel:), NSZeroRect);
        browseBtn.tag = (NSInteger)i;
        browseBtn.toolTip = [NSString stringWithFormat:@"Choose a %@ NAM model from disk.",
                             i == 0 ? @"Pedal" : @"Amp"];
        browseBtn.translatesAutoresizingMaskIntoConstraints = NO;
        [[mp.trailingAnchor constraintEqualToAnchor:browseBtn.leadingAnchor constant:-4] setActive:YES];
        [[browseBtn.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16] setActive:YES];
        [[browseBtn.centerYAnchor constraintEqualToAnchor:mp.centerYAnchor] setActive:YES];
        [[browseBtn.widthAnchor constraintEqualToConstant:26] setActive:YES];
        [[browseBtn.heightAnchor constraintEqualToConstant:23] setActive:YES];
      } else {
        RigButton* browseA = rigButton(box, @"…", state->uiController, @selector(chooseModel:), NSZeroRect);
        browseA.tag = 2;
        browseA.toolTip = @"Choose a Cab A NAM model or WAV impulse response from disk.";
        browseA.translatesAutoresizingMaskIntoConstraints = NO;
        [[mp.trailingAnchor constraintEqualToAnchor:browseA.leadingAnchor constant:-4] setActive:YES];
        [[browseA.centerYAnchor constraintEqualToAnchor:mp.centerYAnchor] setActive:YES];
        [[browseA.widthAnchor constraintEqualToConstant:26] setActive:YES];
        [[browseA.heightAnchor constraintEqualToConstant:23] setActive:YES];

        RigPopUpButton* mpB = [[RigPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        state->modelPickers[3] = mpB;
        mpB.wantsLayer = YES;
        mpB.layer.cornerRadius = 4.0;
        mpB.onClick = ^{
          if (weakCtrl) {
            [weakCtrl selectStageCard:3];
          }
        };
        mpB.translatesAutoresizingMaskIntoConstraints = NO;
        mpB.controlSize = NSControlSizeSmall;
        mpB.tag = 3;
        mpB.target = state->uiController;
        mpB.action = @selector(stageModelChanged:);
        [mpB addItemWithTitle:@"No Cab B loaded"];
        [mpB itemAtIndex:0].toolTip = RigUIState::modelPickerTooltip(3, nil);
        mpB.toolTip = RigUIState::modelPickerTooltip(3, nil);
        mpB.enabled = NO;
        mpB.cell.lineBreakMode = NSLineBreakByTruncatingTail;
        [mpB setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [mpB setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
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
        [[mpB.leadingAnchor constraintEqualToAnchor:browseA.trailingAnchor constant:6] setActive:YES];
        [[mpB.centerYAnchor constraintEqualToAnchor:mp.centerYAnchor] setActive:YES];
        [[mpB.heightAnchor constraintEqualToConstant:23] setActive:YES];
        [[mpB.widthAnchor constraintEqualToAnchor:mp.widthAnchor] setActive:YES];
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
      state->setStageThumb((size_t)i, nil, 0, nil);
    }

    const CGFloat meterWidth = 36.0;
    const CGFloat meterGap = 8.0;
    NSColor* goldColor = [NSColor colorWithSRGBRed:1.00 green:0.75 blue:0.25 alpha:1.0];
    NSColor* violetColor = [NSColor colorWithSRGBRed:0.80 green:0.60 blue:1.00 alpha:1.0];
    NSColor* emeraldColor = [NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:1.0];

    RigStageMeterView* m0 = [[RigStageMeterView alloc] initWithTitle:@"IN"
                                                            subtitle:@"RAW"
                                                         accentColor:rigAccent()];
    m0.toolTip = @"Raw input peak meter (dBFS) before all gate, compressor, and stage processing.";
    m0.translatesAutoresizingMaskIntoConstraints = NO;

    RigStageMeterView* m1 = [[RigStageMeterView alloc] initWithTitle:@"PRE"
                                                            subtitle:@"AMP IN"
                                                         accentColor:goldColor];
    m1.toolTip = @"Pre-amp peak meter (dBFS) after the pedal, overdrive, amp drive boost, and pre-amp tonal sculpt, directly before entering the NAM amp model.";
    m1.translatesAutoresizingMaskIntoConstraints = NO;

    RigStageMeterView* m2 = [[RigStageMeterView alloc] initWithTitle:@"POST"
                                                            subtitle:@"CAB IN"
                                                         accentColor:violetColor];
    m2.toolTip = @"Post-amp peak meter (dBFS) after the NAM amp model, power stage, tube, output transformer, and speaker dynamics, directly before entering the cabinet stage.";
    m2.translatesAutoresizingMaskIntoConstraints = NO;

    RigStageMeterView* m3 = [[RigStageMeterView alloc] initWithTitle:@"OUT"
                                                            subtitle:@"MASTER"
                                                         accentColor:emeraldColor];
    m3.toolTip = @"Master output peak meter (dBFS) after the cabinet and master stereo effects.";
    m3.translatesAutoresizingMaskIntoConstraints = NO;

    state->stageMeters[0] = m0;
    state->stageMeters[1] = m1;
    state->stageMeters[2] = m2;
    state->stageMeters[3] = m3;

    [boxRow addArrangedSubview:m0];
    [boxRow addArrangedSubview:tileBoxes[0]];
    [boxRow addArrangedSubview:m1];
    [boxRow addArrangedSubview:tileBoxes[1]];
    [boxRow addArrangedSubview:m2];
    [boxRow addArrangedSubview:tileBoxes[2]];
    [boxRow addArrangedSubview:m3];

    for (RigStageMeterView* m : {m0, m1, m2, m3}) {
      [[m.widthAnchor constraintEqualToConstant:meterWidth] setActive:YES];
      [[m.topAnchor constraintEqualToAnchor:boxRow.topAnchor] setActive:YES];
      [[m.bottomAnchor constraintEqualToAnchor:boxRow.bottomAnchor] setActive:YES];
    }

    // Proportional stage tile widths, including the pedal header's minimum budget.
    [[tileBoxes[1].widthAnchor constraintEqualToAnchor:tileBoxes[0].widthAnchor
                                           multiplier:tileUnits[1] / tileUnits[0]] setActive:YES];
    [[tileBoxes[2].widthAnchor constraintEqualToAnchor:tileBoxes[0].widthAnchor
                                           multiplier:tileUnits[2] / tileUnits[0]] setActive:YES];

    // Horizontal inter-stage chain: IN -> Pedal -> PRE -> Amp -> POST -> Cab -> OUT
    [[m0.leadingAnchor constraintEqualToAnchor:boxRow.leadingAnchor] setActive:YES];
    [[tileBoxes[0].leadingAnchor constraintEqualToAnchor:m0.trailingAnchor constant:meterGap] setActive:YES];
    [[m1.leadingAnchor constraintEqualToAnchor:tileBoxes[0].trailingAnchor constant:meterGap] setActive:YES];
    [[tileBoxes[1].leadingAnchor constraintEqualToAnchor:m1.trailingAnchor constant:meterGap] setActive:YES];
    [[m2.leadingAnchor constraintEqualToAnchor:tileBoxes[1].trailingAnchor constant:meterGap] setActive:YES];
    [[tileBoxes[2].leadingAnchor constraintEqualToAnchor:m2.trailingAnchor constant:meterGap] setActive:YES];
    [[m3.leadingAnchor constraintEqualToAnchor:tileBoxes[2].trailingAnchor constant:meterGap] setActive:YES];
    [[m3.trailingAnchor constraintEqualToAnchor:boxRow.trailingAnchor] setActive:YES];

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
    // Only the standalone app owns startup preset recall; hosts restore their own state.
    const bool standalone = [NSBundle.mainBundle.bundleIdentifier
        isEqualToString:@"org.neuralampmodeler.lv2.standalone-rig"];
    if (standalone && state->presetManager.currentPresetName.length) {
      RigPreset* curPreset = [state->presetManager loadPresetNamed:state->presetManager.currentPresetName];
      if (curPreset) {
        state->abApplyingCycle = true;
        [curPreset applyToState:state];
        state->abApplyingCycle = false;
      }
    }
    state->syncABNameA();
    state->rebuildPresetMenu();
    state->refreshABMenus();
    state->updateABStatus();
    state->installKeyEventMonitor();
    return state;
  }
}

void cleanup(LV2UI_Handle handle) {
  auto* state = static_cast<RigUIState*>(handle);
  if (state) {
    state->stopKeyEventMonitor();
    state->stopABTimer();   // invalidate the A/B timer before teardown (do not call stopAB() which queues UI rebuilds)
    if (state->uiController) {
      if (state->uiController.copilotLocalMatching) [state->uiController cancelCopilotRequest:nil];
      [state->uiController.copilotRiffTimer invalidate];
      state->uiController.copilotRiffTimer = nil;
      [RigAICopilot sharedCopilot].progressHandler = nil;
      if (state->aiCopilotPopover && state->aiCopilotPopover.isShown) {
        [state->aiCopilotPopover close];
      }
      state->aiCopilotPopover = nil;
      state->uiController.state = nullptr;
    }
    if (state->browserController) {
      state->browserController.state = nullptr;
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
  if (format == 0 && buffer && size == sizeof(float) && port >= 4 &&
      port < NAMRig::kRigControlPortCount) {
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
    const char* path = reinterpret_cast<const char*>(value + 1);
    if (!memchr(path, '\0', value->size)) return;
    std::string confirmed(path);
    auto alive = state->isAlive;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!alive || !*alive) return;
      for (size_t i = 0; i < state->pathURIDs.size(); ++i) if (propertyId == state->pathURIDs[i]) {
        state->confirmedPaths[i] = confirmed;
        ++state->pathResponseSerial[i];
        state->displayPath(i, confirmed.c_str());
      }
    });
    return;
  }
  // Tuner updates: patch:Set floats — note (MIDI number, -1 = none) and cents.
  if (value->type != state->atomFloat || value->size != sizeof(float)) return;
  const float v = *reinterpret_cast<const float*>(value + 1);
  if (propertyId == state->tunerNoteURID)
    state->lastTunerNote = v;
  else if (propertyId == state->tunerCentsURID)
    state->lastTunerCents = v;
  else {
    const LV2_URID meters[] = {state->inputDbURID, state->preAmpDbURID,
                              state->postAmpDbURID, state->outputDbURID};
    for (size_t i = 0; i < 4; ++i)
      if (propertyId == meters[i]) {
        state->updateStageMeter(i, v);
        return;
      }
    return;
  }
  state->updateTunerDisplay();
}

const void* extensionData(const char*) { return nullptr; }

const LV2UI_Descriptor descriptor{
    kRigUIURI, instantiate, cleanup, portEvent, extensionData};

extern "C" __attribute__((visibility("default")))
const LV2UI_Descriptor* lv2ui_descriptor(uint32_t index) {
  return index == 0 ? &descriptor : nullptr;
}
