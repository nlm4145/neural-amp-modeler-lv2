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

#include <array>
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
constexpr std::array<const char*, 3> kPathURIs{
    "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig-pedal-model",
    "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig-amp-model",
    "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig-cab-model"};

struct RigUIState;
@class ToneBrowserController;
@class RigButton;

@interface NAMRigUIController : NSObject <NSComboBoxDelegate, NSTextFieldDelegate>
@property(nonatomic, assign) RigUIState* state;
- (void)chooseModel:(NSButton*)sender;
- (void)clearModel:(NSButton*)sender;
- (void)controlChanged:(NSSlider*)sender;
- (void)knobFieldCommitted:(NSTextField*)sender;
- (void)zoomChanged:(NSComboBox*)sender;
- (void)stageModelChanged:(NSPopUpButton*)sender;
@end

// Knob configuration — index order matches the LV2 port list in nam_rig_plugin.ttl.
// strip. Atom ports (0/1) and the stage toggles (7–10) are handled separately.
constexpr size_t kRigKnobCount = 6;
const std::array<uint32_t, kRigKnobCount> kRigKnobPorts{15, 4, 5, 12, 13, 14};
// Footer display order follows the SIGNAL CHAIN, not the port list:
// GATE → INPUT → [pedal/amp/cab stages] → BASS → MID → TREBLE → OUTPUT.
// Maps display slot → index into kRigKnobPorts (port tags / state arrays unchanged).
const std::array<size_t, kRigKnobCount> kRigKnobDisplayOrder{0, 1, 3, 4, 5, 2};

static NSString* rigKnobValueText(uint32_t port, float value) {
  switch (port) {
    case 4:  return [NSString stringWithFormat:@"%+.1f dB", value];
    case 5:  return [NSString stringWithFormat:@"%+.1f dB", value];
    case 12: return [NSString stringWithFormat:@"%+.1f dB", value];
    case 13: return [NSString stringWithFormat:@"%+.1f dB", value];
    case 14: return [NSString stringWithFormat:@"%+.1f dB", value];
    case 15: return value < -79.5f ? @"OFF" : [NSString stringWithFormat:@"%.0f dB", value];
    default: return @"";
  }
}

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
      __unsafe_unretained NSImageView* iv = stageImages[s];
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

@interface ToneItem : NSObject
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* creator;
@property(nonatomic, copy) NSString* gear;
@property(nonatomic, copy) NSString* toneURL;
@property(nonatomic, copy) NSString* imageURL;
@property(nonatomic, copy) NSString* artworkPath;
@property(nonatomic, strong) NSArray<NSString*>* models;
@property(nonatomic, strong) NSArray<NSDictionary*>* remoteModels;
@property(nonatomic, strong) NSDictionary* toneData;
@property(nonatomic, strong) NSDate* modified;
@property(nonatomic, strong) NSDate* createdAt;
@property(nonatomic) NSInteger downloadsCount;
@property(nonatomic) NSInteger toneId;
@property(nonatomic) NSInteger stage;
@property(nonatomic) BOOL favorite;
@property(nonatomic) BOOL local;
@end
@implementation ToneItem @end

@interface ToneBrowserController : NSObject <NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate>
@property(nonatomic, assign) RigUIState* state;
@property(nonatomic, strong) NSMutableArray<ToneItem*>* allItems;
@property(nonatomic, strong) NSArray<ToneItem*>* visibleItems;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSImage*>* images;
@property(nonatomic, strong) NSCollectionView* collectionView;
@property(nonatomic, strong) NSSearchField* search;
@property(nonatomic, strong) NSPopUpButton* gear;
@property(nonatomic, strong) NSPopUpButton* sort;
@property(nonatomic, strong) NSTextField* status;
@property(nonatomic, strong) NSTextField* authStatus;
@property(nonatomic, strong) RigButton* connectButton;
@property(nonatomic, strong) NSArray<RigButton*>* modeButtons;
@property(nonatomic, copy) NSString* accessToken;
@property(nonatomic, copy) NSString* refreshToken;
@property(nonatomic, copy) NSString* mode;
// Pagination state for the online search. The explorer mirrors tone3000.com:
// the API returns {data, page, page_size, total, total_pages} and a search is
// fetched page-by-page (page_size=100) in server order until exhausted.
@property(nonatomic) NSInteger nextSearchPage;
@property(nonatomic) NSInteger searchTotalPages;
@property(nonatomic) NSInteger searchGeneration;   // bumped on every new search
@property(nonatomic, strong) NSMutableSet<NSNumber*>* searchIds;  // tone ids from the current search
@property(nonatomic, strong) NSMutableArray<ToneItem*>* searchResults;  // current search, strict server order
// One-shot OAuth login state (authorization-code + PKCE via a localhost callback).
@property(nonatomic) BOOL oauthActive;
@property(nonatomic) int oauthPort;
@property(nonatomic, copy) NSString* oauthVerifier;
@property(nonatomic, copy) NSString* oauthState;
@property(nonatomic, strong) NSTimer* oauthTimer;
// Background connect state: startup + the periodic timer only use a valid
// session and silently refresh an expired one — they NEVER open the browser.
// The browser login runs only from the manual Connect button.
// connectIfNeededAllowBrowser: is guarded so startup, the periodic timer and
// manual Connect clicks never stack concurrent attempts.
@property(nonatomic) BOOL connectRequested;
@property(nonatomic) NSInteger oauthLoginAttempts;   // reserved; login is manual-only now
@property(nonatomic, strong) NSTimer* connectTimer;
// Cooldown after a failed login so a re-click can't instantly re-open the
// browser. Manual Connect resets it.
@property(nonatomic) NSTimeInterval loginBackoffUntil;
@property(nonatomic) BOOL refreshingToken;   // guards concurrent refresh calls
// Cooldown after the server rate-limits (429) or WAF-blocks (403) us. While
// active, refreshOnline does nothing so browsing can't escalate the block.
@property(nonatomic) NSTimeInterval rateLimitUntil;
@property(nonatomic) BOOL loadingNextPage;          // one search page in flight
@property(nonatomic, copy) NSString* activeSearchPrefix;  // prefix the current page state belongs to
- (void)loadMoreSearchResults;
- (void)mergeArchPages:(NSDictionary<NSString*, NSDictionary*>*)fetched page:(NSInteger)page generation:(NSInteger)generation fromCache:(BOOL)fromCache;
- (void)applySearchPage:(NSDictionary*)json page:(NSInteger)page generation:(NSInteger)generation fromCache:(BOOL)fromCache;
- (void)downloadAllModels:(ToneItem*)item;
- (void)downloadModelStep:(NSInteger)index of:(NSArray*)models item:(ToneItem*)item folder:(NSString*)folder downloads:(NSMutableArray<NSDictionary*>*)downloads;
- (void)finishModelDownload:(ToneItem*)item folder:(NSString*)folder downloads:(NSMutableArray<NSDictionary*>*)downloads;
- (void)reloadLibrary:(id)sender;
- (void)selectMode:(NSButton*)sender;
- (void)filterChanged:(id)sender;
- (void)sortChanged:(id)sender;
+ (void)restoreFilterSelectionForGear:(NSPopUpButton*)gear sort:(NSPopUpButton*)sort;
- (void)toggleFavoriteFromCard:(ToneItem*)item;
- (void)connectTone3000:(id)sender;
- (void)connectIfNeeded;
- (void)connectIfNeededAllowBrowser:(BOOL)allowBrowser;
- (void)refreshToneSession;
- (void)refreshToneSessionAllowBrowser:(BOOL)allowBrowser;
@end

@implementation NAMRigUIController
- (void)chooseModel:(NSButton*)sender {
  if (!_state || sender.tag < 0 || sender.tag > 2) return;
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.title = [NSString stringWithFormat:@"Choose %@ NAM Model",
                 @[@"a Pedal", @"an Amp", @"a Cab"][(NSUInteger)sender.tag]];
  panel.prompt = @"Load Model";
  panel.canChooseFiles = YES;
  panel.canChooseDirectories = NO;
  panel.allowsMultipleSelection = NO;
  panel.allowedFileTypes = sender.tag == 2
      ? @[@"nam", @"nammodel", @"json", @"aidax", @"aidadspmodel", @"wav"]
      : @[@"nam", @"nammodel", @"json", @"aidax", @"aidadspmodel"];
  if ([panel runModal] == NSModalResponseOK)
    _state->sendPath((size_t)sender.tag, panel.URL.path.fileSystemRepresentation);
}

- (void)clearModel:(NSButton*)sender {
  if (_state && sender.tag >= 0 && sender.tag <= 2) {
    _state->sendPath((size_t)sender.tag, "");
    _state->setStageThumb((size_t)sender.tag, nil, 0, nil);  // revert to placeholder
  }
}

- (void)controlChanged:(NSSlider*)sender {
  if (!_state) return;
  _state->sendControl((uint32_t)sender.tag, sender.floatValue);
  _state->updateControl((uint32_t)sender.tag, sender.floatValue);
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
  if (path.length) {
    _state->sendPath((size_t)sender.tag, path.fileSystemRepresentation);
  }
}
@end

static NSDictionary* jsonDictionaryAtPath(NSString* path) {
  NSData* data = [NSData dataWithContentsOfFile:path];
  if (!data) return nil;
  id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSString* const kToneAPI = @"https://www.tone3000.com/api/v1";

// ---- NAM Rig-style theme (dark, near-black + blue accent) ----
static NSColor* rigBG(void)        { return [NSColor colorWithSRGBRed:0.055 green:0.059 blue:0.071 alpha:1.0]; }
static NSColor* rigPanelBG(void)   { return [NSColor colorWithSRGBRed:0.098 green:0.106 blue:0.129 alpha:1.0]; }
static NSColor* rigPanelBorder(void){ return [NSColor colorWithSRGBRed:0.18 green:0.19 blue:0.22 alpha:1.0]; }
static NSColor* rigRaised(void)    { return [NSColor colorWithSRGBRed:0.14 green:0.15 blue:0.18 alpha:1.0]; }
static NSColor* rigText(void)      { return [NSColor colorWithSRGBRed:0.93 green:0.94 blue:0.96 alpha:1.0]; }
static NSColor* rigDimText(void)   { return [NSColor colorWithSRGBRed:0.58 green:0.60 blue:0.65 alpha:1.0]; }
static NSColor* rigAccent(void)    { return [NSColor colorWithSRGBRed:0.24 green:0.55 blue:0.86 alpha:1.0]; } // NAM Rig blue
static NSColor* rigAccentDim(void) { return [NSColor colorWithSRGBRed:0.14 green:0.31 blue:0.50 alpha:1.0]; }
static NSColor* rigOrange(void)    { return [NSColor colorWithSRGBRed:1.00 green:0.55 blue:0.25 alpha:1.0]; } // Tone3000 brand

// Shared image cache so tone cards don't re-read artwork from disk on every layout.
static NSCache<NSString*, NSImage*>* artworkCache(void) {
  static NSCache *cache = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [[NSCache alloc] init];
    cache.countLimit = 200;
  });
  return cache;
}

// Forward declarations (definitions are below, after the keychain helpers).
static NSString* artworkCachePathForTone(NSInteger toneId, NSInteger stage);
static NSString* artworkForTone(NSInteger toneId, NSInteger stage);

// Multi-column tone card for the collection-view grid.
@interface ToneCardItem : NSCollectionViewItem
@property(nonatomic, copy) void (^onFavToggle)(ToneItem*);
@end
@implementation ToneCardItem {
  NSImageView *_artView;
  NSTextField *_titleField;
  NSTextField *_detailField;
  NSButton *_favButton;
}
- (void)loadView {
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 190, 74)];
  v.wantsLayer = YES;
  v.layer.backgroundColor = rigRaised().CGColor;
  v.layer.cornerRadius = 8;

  _artView = [[NSImageView alloc] initWithFrame:NSMakeRect(6, 7, 60, 60)];
  _artView.imageScaling = NSImageScaleProportionallyUpOrDown;
  _artView.wantsLayer = YES;
  _artView.layer.cornerRadius = 6;
  _artView.layer.masksToBounds = YES;
  [v addSubview:_artView];

  _titleField = [[NSTextField alloc] initWithFrame:NSMakeRect(72, 42, 92, 16)];
  _titleField.font = [NSFont boldSystemFontOfSize:11];
  _titleField.textColor = rigText();
  _titleField.lineBreakMode = NSLineBreakByTruncatingTail;
  _titleField.editable = NO; _titleField.selectable = NO; _titleField.drawsBackground = NO; _titleField.bordered = NO;
  [v addSubview:_titleField];

  _detailField = [[NSTextField alloc] initWithFrame:NSMakeRect(72, 24, 112, 14)];
  _detailField.font = [NSFont systemFontOfSize:9.5];
  _detailField.textColor = rigDimText();
  _detailField.lineBreakMode = NSLineBreakByTruncatingTail;
  _detailField.editable = NO; _detailField.selectable = NO; _detailField.drawsBackground = NO; _detailField.bordered = NO;
  [v addSubview:_detailField];

  // Favorite star (top-right). Clicking reports to the browser controller;
  // the star is intentionally NOT a title/mode control, just a toggle.
  _favButton = [[NSButton alloc] initWithFrame:NSMakeRect(168, 42, 18, 18)];
  _favButton.bordered = NO;
  _favButton.imagePosition = NSImageOnly;
  _favButton.target = self;
  _favButton.action = @selector(favClicked:);
  [v addSubview:_favButton];

  self.view = v;
  [self attachTone3000Menu];
}
- (void)setRepresentedObject:(id)representedObject {
  [super setRepresentedObject:representedObject];
  if (![representedObject isKindOfClass:[ToneItem class]]) return;
  ToneItem *item = (ToneItem *)representedObject;
  _titleField.stringValue = item.title ?: @"";
  _detailField.stringValue = [NSString stringWithFormat:@"@%@  ·  %@", item.creator, item.gear.uppercaseString];
  _favButton.image = [NSImage imageWithSystemSymbolName:(item.favorite ? @"star.fill" : @"star") accessibilityDescription:nil];
  _favButton.contentTintColor = item.favorite ? rigAccent() : rigDimText();

  // Placeholder immediately; load real artwork asynchronously from cache or disk.
  _artView.image = [NSImage imageWithSystemSymbolName:@"guitars" accessibilityDescription:nil];

  // Resolution order: downloaded artwork file → NAM Rig's cached PNG → online JPEG.
  NSString *path = item.artworkPath;
  if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path])
    path = artworkForTone(item.toneId, item.stage);

  __weak NSImageView *weakArt = _artView;
  if (path.length) {
    NSImage *cached = [artworkCache() objectForKey:path];
    if (cached) { _artView.image = cached; return; }
    NSString *capturedPath = [path copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSImage *img = [[NSImage alloc] initWithContentsOfFile:capturedPath];
      if (!img) return;
      [artworkCache() setObject:img forKey:capturedPath];
      dispatch_async(dispatch_get_main_queue(), ^{
        NSImageView *strongArt = weakArt;
        if (strongArt) strongArt.image = img;
      });
    });
    return;
  }

  // No local artwork yet — fetch the online JPEG and cache it to disk so the
  // thumbnail is ready before the tone's model is even downloaded.
  NSString *urlString = item.imageURL.length ? item.imageURL : nil;
  if (!urlString.length) return;

  NSImage *mem = [artworkCache() objectForKey:urlString];
  if (mem) { _artView.image = mem; return; }

  NSString *capturedURL = [urlString copy];
  NSString *cacheName = artworkCachePathForTone(item.toneId, item.stage);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:capturedURL]];
    if (!data.length) return;
    NSImage *img = [[NSImage alloc] initWithData:data];
    if (!img) return;
    // Persist to NAM Rig's artwork cache directory.
    NSError *dirErr = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:cacheName.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:&dirErr];
    [data writeToFile:cacheName atomically:YES];
    [artworkCache() setObject:img forKey:capturedURL];
    [artworkCache() setObject:img forKey:cacheName];
    dispatch_async(dispatch_get_main_queue(), ^{
      NSImageView *strongArt = weakArt;
      if (strongArt) strongArt.image = img;
    });
  });
}
- (IBAction)favClicked:(id)sender {
  if (self.onFavToggle && self.representedObject) self.onFavToggle((ToneItem*)self.representedObject);
}
// Right-click on the card offers "View on Tone3000" — opens the tone's page
// (https://www.tone3000.com/tones/<id>) in the default browser. Works for both
// search results and local-library cards: toneItem() builds toneURL with an
// id-based fallback when the manifest doesn't carry one. The menu is attached
// to the card's root view; right-clicks on any subview (art, title, star) with
// no menu of their own climb the responder chain to it.
- (void)attachTone3000Menu {
  if (!self.view) return;
  NSMenu *m = [[NSMenu alloc] init];
  NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"View on Tone3000"
                                                   action:@selector(openTone3000:)
                                            keyEquivalent:@""];
  openItem.target = self;  // reads self.representedObject at click time
  [m addItem:openItem];
  self.view.menu = m;
}
- (IBAction)openTone3000:(id)sender {
  ToneItem *item = (ToneItem *)self.representedObject;
  if (![item isKindOfClass:[ToneItem class]] || !item.toneURL.length) return;
  NSURL *url = [NSURL URLWithString:item.toneURL];
  if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}
@end

// A flat, NAM Rig-style rounded button drawn in dark theme. "primary" renders
// with an accent fill; otherwise a dark fill + subtle border. Highlight state
// brightens the fill so the active mode button reads as selected.
@interface RigButton : NSButton
@property(nonatomic) BOOL primary;
@property(nonatomic) BOOL check;
@end
@implementation RigButton
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }
- (void)drawRect:(NSRect)dirty {
  NSRect r = NSInsetRect(self.bounds, 0.5, 0.5);
  NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:5 yRadius:5];
  NSColor* fill;
  if (self.primary) {
    fill = (self.state == NSControlStateValueOn) ? rigAccent() : rigAccentDim();
  } else {
    BOOL on = self.state == NSControlStateValueOn;
    fill = on ? [rigAccent() colorWithAlphaComponent:0.32]
              : (self.isHighlighted ? rigRaised() : rigPanelBG());
  }
  [fill setFill]; [p fill];
  NSColor* border = self.primary ? rigAccent() : (self.state == NSControlStateValueOn
      ? [rigAccent() colorWithAlphaComponent:0.7] : rigPanelBorder());
  border = self.isHighlighted ? rigAccent() : border;
  [border setStroke]; p.lineWidth = 1.0; [p stroke];
  NSString* title = self.title;
  if (title.length) {
    NSMutableParagraphStyle* ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSColor* tc = self.primary ? rigText() : (self.isHighlighted || self.state == NSControlStateValueOn ? rigText() : rigDimText());
    if (self.enabled == NO) tc = [rigDimText() colorWithAlphaComponent:0.5];
    NSDictionary* attrs = @{NSFontAttributeName: [NSFont boldSystemFontOfSize:11],
                            NSForegroundColorAttributeName: tc,
                            NSParagraphStyleAttributeName: ps};
    NSRect tr = NSInsetRect(self.bounds, 4, 0);
    [title drawInRect:tr withAttributes:attrs];
  }
}
@end

// NAM Rig is the app that owns the TONE3000 OAuth session on this machine. The
// plugin shares NAM Rig's library and URL cache, so it reuses the same session
// instead of attempting its own (unsupported, non-standard) OAuth flow.
static NSString* const kNamRigKeychainService = @"Nouratone.comnouratonenamrig.Tone3000";
static NSString* const kNamRigAccountPrefix = @"apiv1tone3000.";
static NSString* const kNamRigAccountSuffix = @".refresh-token";
static NSString* const kPluginPublishableKey = @"t3k_pub_ScsutPfmPM2CwvG726tU60R5WN_KChza";

// The plugin keeps its OWN TONE3000 session in a separate keychain entry so it
// stops depending on NAM Rig. It bootstraps once from NAM Rig's session, then
// refreshes and persists independently from here on.
static NSString* const kPluginKeychainService = @"NAM Oversampled Rig Tone3000";
static NSString* const kPluginKeychainAccount = @"session";

// Reads NAM Rig's stored TONE3000 OAuth session (a JSON blob holding
// accessToken, refreshToken and expiresAtMilliseconds) from the Keychain.
// Returns the parsed dictionary, or nil if NAM Rig has no saved session.
static NSDictionary* namRigSession(void) {
  NSDictionary* query = @{
    (__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService:kNamRigKeychainService,
    (__bridge id)kSecReturnData:@YES,
    (__bridge id)kSecReturnAttributes:@YES,
  };
  CFTypeRef result = nullptr;
  if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess) return nil;
  NSDictionary* entry = (__bridge_transfer NSDictionary*)result;
  if (![entry isKindOfClass:NSDictionary.class]) return nil;
  NSString* account = entry[(__bridge id)kSecAttrAccount];
  if (![account hasPrefix:kNamRigAccountPrefix] || ![account hasSuffix:kNamRigAccountSuffix]) return nil;
  NSData* data = entry[(__bridge id)kSecValueData];
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

// Reads the plugin's own stored TONE3000 session (same JSON shape as NAM
// Rig's: accessToken, refreshToken, expiresAtMilliseconds) from the Keychain.
static NSDictionary* pluginSession(void) {
  NSDictionary* query = @{
    (__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService:kPluginKeychainService,
    (__bridge id)kSecAttrAccount:kPluginKeychainAccount,
    (__bridge id)kSecReturnData:@YES,
  };
  CFDataRef data = nullptr;
  if (SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef*)&data) != errSecSuccess) return nil;
  NSData* nsdata = (__bridge_transfer NSData*)data;
  id json = [NSJSONSerialization JSONObjectWithData:nsdata options:0 error:nil];
  return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

// Writes (or updates) the plugin's own TONE3000 session in the Keychain.
static void savePluginSession(NSDictionary* session) {
  if (!session) return;
  NSData* json = [NSJSONSerialization dataWithJSONObject:session options:0 error:nil];
  if (!json) return;
  NSDictionary* query = @{
    (__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService:kPluginKeychainService,
    (__bridge id)kSecAttrAccount:kPluginKeychainAccount,
  };
  NSDictionary* update = @{(__bridge id)kSecValueData: json};
  OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update);
  if (status == errSecItemNotFound) {
    NSMutableDictionary* add = [query mutableCopy];
    add[(__bridge id)kSecValueData] = json;
    SecItemAdd((__bridge CFDictionaryRef)add, nullptr);
  }
}

// Deletes the plugin's own TONE3000 session. Used when the stored refresh
// token has been rotated server-side ("refresh_token_already_used"): keeping
// it poisons every request with a 401 and "REFRESH failed" forever.
static void clearPluginSession(void) {
  NSDictionary* query = @{
    (__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService:kPluginKeychainService,
    (__bridge id)kSecAttrAccount:kPluginKeychainAccount,
  };
  SecItemDelete((__bridge CFDictionaryRef)query);
}

// ---- TONE3000 OAuth2 authorization-code + PKCE helpers ----
// The plugin logs in directly against the same OAuth endpoints NAM Rig uses
// (www.tone3000.com/api/v1/oauth/authorize + /oauth/token). This makes the
// explorer self-sufficient: Connect opens the browser once and the plugin then
// owns a session it can refresh forever, instead of depending on NAM Rig or a
// stale keychain copy.

static NSData* randomDataOfLength(size_t len) {
  NSMutableData* d = [NSMutableData dataWithLength:len];
  SecRandomCopyBytes(kSecRandomDefault, len, d.mutableBytes);
  return d;
}

// RFC 4648 base64url WITHOUT padding. Used for the PKCE code_verifier
// (43 chars from 32 random bytes), the S256 challenge and the state value.
static NSString* base64URLStringNoPadding(NSData* data) {
  NSString* b64 = [data base64EncodedStringWithOptions:0];
  b64 = [b64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
  b64 = [b64 stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
  b64 = [b64 stringByReplacingOccurrencesOfString:@"=" withString:@""];
  return b64;
}

// RFC 3986 unreserved-only percent-encoding, safe for form bodies and query
// values (URLQueryAllowedCharacterSet would let & and + through).
static NSString* percentEncode(NSString* s) {
  static NSCharacterSet* allowed = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableCharacterSet* set = [NSMutableCharacterSet alphanumericCharacterSet];
    [set addCharactersInString:@"-._~"];
    allowed = set;
  });
  return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

static NSData* sha256Data(NSString* s) {
  NSData* data = [s dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  return [NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH];
}

// JWT "exp" claim in milliseconds, or 0 if the token isn't a parseable JWT.
static NSTimeInterval jwtExpiryMilliseconds(NSString* token) {
  if (![token isKindOfClass:NSString.class] || ![token hasPrefix:@"eyJ"]) return 0;
  NSArray* parts = [token componentsSeparatedByString:@"."];
  if (parts.count < 2) return 0;
  NSString* payload = [parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
  payload = [payload stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
  while (payload.length % 4) payload = [payload stringByAppendingString:@"="];
  NSData* data = [[NSData alloc] initWithBase64EncodedString:payload options:0];
  if (!data) return 0;
  NSDictionary* claims = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  NSNumber* exp = [claims isKindOfClass:NSDictionary.class] ? claims[@"exp"] : nil;
  if (![exp respondsToSelector:@selector(doubleValue)]) return 0;
  return exp.doubleValue * 1000.0;
}

// Minimal query-string parser for the OAuth callback (GET /callback?code=..&state=..).
static NSDictionary* parseQueryString(NSString* query) {
  NSMutableDictionary* d = [NSMutableDictionary dictionary];
  for (NSString* pair in [query componentsSeparatedByString:@"&"]) {
    NSArray* kv = [pair componentsSeparatedByString:@"="];
    if (kv.count != 2) continue;
    NSString* k = [kv[0] stringByRemovingPercentEncoding];
    NSString* v = [kv[1] stringByRemovingPercentEncoding];
    if (k.length) d[k] = v ?: @"";
  }
  return d;
}

static NSString* safeFilename(NSString* name) {
  NSCharacterSet* bad = [NSCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<>\n\r"];
  NSArray* parts = [name componentsSeparatedByCharactersInSet:bad];
  NSString* result = [parts componentsJoinedByString:@"-"];
  return result.length ? [result substringToIndex:MIN((NSUInteger)120, result.length)] : @"Tone3000 Model";
}

static NSInteger stageForGear(NSString* gear) {
  NSString* value = gear.lowercaseString;
  if ([value containsString:@"pedal"]) return 0;
  if ([value isEqualToString:@"cab"] || [value containsString:@"ir"]) return 2;
  return 1;
}

// Filter a tone by the gear dropdown using the API's own Gear enum values
// (amp / amp-cab / pedal / cab / outboard / space / experimental) — NOT the
// collapsed 3-stage value. stageForGear maps amp-cab to the amp tile for
// playback, but amp and amp-cab are DISTINCT site categories and must filter
// separately (they were being combined before).
static BOOL gearMatchesFilter(NSString* itemGear, NSString* filterTitle) {
  NSString* g = itemGear.lowercaseString;
  if ([filterTitle isEqualToString:@"Amps"]) return [g isEqualToString:@"amp"];
  if ([filterTitle isEqualToString:@"Cabs"]) return [g isEqualToString:@"cab"];
  if ([filterTitle isEqualToString:@"Pedals"]) return [g isEqualToString:@"pedal"];
  if ([filterTitle isEqualToString:@"Amp + Cab"]) return [g isEqualToString:@"amp-cab"] || [g isEqualToString:@"full-rig"];
  return YES;   // All Gear
}

// Computes the on-disk artwork cache path for a tone (shared with NAM Rig's
// "Tone3000 State Artwork" cache so thumbnails persist across launches).
static NSString* artworkCachePathForTone(NSInteger toneId, NSInteger stage) {
  NSString* prefix = stage == 0 ? @"pedal" : (stage == 2 ? @"cab" : @"amp");
  NSString* name = [NSString stringWithFormat:@"%@-%ld.png", prefix, (long)toneId];
  NSString* root = [@"~/Library/Caches/NAM Rig/NAM Rig/Tone3000 State Artwork"
                    stringByExpandingTildeInPath];
  return [root stringByAppendingPathComponent:name];
}

static NSString* artworkForTone(NSInteger toneId, NSInteger stage) {
  NSString* path = artworkCachePathForTone(toneId, stage);
  return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

// ---- TONE3000 search cache (NAM-Rig-style: cache-first browsing) ----
// Full pagination of every keystroke/sort-change was getting us 429-throttled
// then 403-WAF-blocked (427 requests in ~2 minutes). NAM Rig avoids this by
// browsing from local data. We now do the same: every search page fetched from
// the API is persisted under ~/Library/Application Support/NAM Oversampled
// Rig/SearchCache/<sha1 of path>.json and served from disk when fresh (<10 min
// old). Pages load lazily (one page per filter change / scroll), so a full
// 30-page browse never re-downloads pages it already has.
static NSString* searchCacheDir(void) {
  static NSString* dir = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dir = [@("~/Library/Application Support/NAM Oversampled Rig/SearchCache")
           stringByExpandingTildeInPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
  });
  return dir;
}

// A stable cache key: the request path (sort/gears/query/page), hashed so the
// filesystem doesn't see query characters it dislikes.
static NSString* searchCacheKeyForPath(NSString* path) {
  unsigned char digest[CC_SHA1_DIGEST_LENGTH];
  CC_SHA1([path UTF8String], (CC_LONG)strlen([path UTF8String]), digest);
  NSMutableString* hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
  for (size_t i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
  return hex;
}

// Returns the cached {data, page, total_pages, ...} dictionary for a search
// page if it exists and is younger than maxAgeSeconds; nil otherwise.
static NSDictionary* cachedSearchPageForPath(NSString* path, NSTimeInterval maxAgeSeconds) {
  NSString* file = [searchCacheDir() stringByAppendingPathComponent:
                    [searchCacheKeyForPath(path) stringByAppendingPathExtension:@"json"]];
  NSDictionary* wrapper = jsonDictionaryAtPath(file);
  NSDictionary* page = [wrapper[@"page"] isKindOfClass:NSDictionary.class] ? wrapper[@"page"] : nil;
  NSNumber* fetched = [wrapper[@"fetchedAt"] respondsToSelector:@selector(doubleValue)]
      ? wrapper[@"fetchedAt"] : nil;
  if (!page || !fetched) return nil;
  if ([[NSDate date] timeIntervalSince1970] - fetched.doubleValue > maxAgeSeconds) return nil;
  return page;
}

// Persists a fetched search page (called after every successful API page).
static void saveSearchPageForPath(NSString* path, NSDictionary* page) {
  if (![page isKindOfClass:NSDictionary.class] || !page[@"data"]) return;
  NSDictionary* wrapper = @{
    @"fetchedAt": @([[NSDate date] timeIntervalSince1970]),
    @"path": path,
    @"page": page,
  };
  NSData* json = [NSJSONSerialization dataWithJSONObject:wrapper options:0 error:nil];
  if (!json) return;
  NSString* file = [searchCacheDir() stringByAppendingPathComponent:
                    [searchCacheKeyForPath(path) stringByAppendingPathExtension:@"json"]];
  [json writeToFile:file options:NSDataWritingAtomic error:nil];
}

static ToneItem* toneItem(NSDictionary* tone, NSArray<NSString*>* models, NSDate* modified) {
  if (![tone[@"title"] isKindOfClass:NSString.class] || ![tone[@"id"] respondsToSelector:@selector(integerValue)])
    return nil;
  ToneItem* item = [[ToneItem alloc] init];
  item.toneId = [tone[@"id"] integerValue];
  item.title = tone[@"title"];
  item.gear = [tone[@"gear"] isKindOfClass:NSString.class] ? tone[@"gear"] : @"unknown";
  item.stage = stageForGear(item.gear);
  NSDictionary* user = [tone[@"user"] isKindOfClass:NSDictionary.class] ? tone[@"user"] : nil;
  item.creator = [user[@"username"] isKindOfClass:NSString.class] ? user[@"username"] : @"Tone3000";
  item.toneURL = [tone[@"url"] isKindOfClass:NSString.class] ? tone[@"url"] :
      [NSString stringWithFormat:@"https://www.tone3000.com/tones/%ld", (long)item.toneId];
  NSArray* images = [tone[@"images"] isKindOfClass:NSArray.class] ? tone[@"images"] : nil;
  item.imageURL = [images.firstObject isKindOfClass:NSString.class] ? images.firstObject : nil;
  item.artworkPath = artworkForTone(item.toneId, item.stage);
  item.models = models ?: @[];
  item.remoteModels = @[];
  item.toneData = tone;
  item.local = item.models.count > 0;
  item.favorite = [tone[@"is_favorite"] respondsToSelector:@selector(boolValue)] && [tone[@"is_favorite"] boolValue];

  // Capture the tone's real publication date and download count so the list
  // can mirror tone3000.com's Newest/Oldest/Most Downloaded ordering locally.
  NSString* createdAtString = [tone[@"created_at"] isKindOfClass:NSString.class] ? tone[@"created_at"] : nil;
  NSDate* createdAt = nil;
  if (createdAtString.length) {
    static NSISO8601DateFormatter* sDateFmt = nil;
    static dispatch_once_t sOnce;
    dispatch_once(&sOnce, ^{
      sDateFmt = [NSISO8601DateFormatter new];
      sDateFmt.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    createdAt = [sDateFmt dateFromString:createdAtString];
  }
  item.createdAt = createdAt;
  item.downloadsCount = [tone[@"downloads_count"] respondsToSelector:@selector(integerValue)] ? [tone[@"downloads_count"] integerValue] : 0;

  // Leave `modified` exactly as the original code set it (caller-supplied file
  // date for local items, distant-past for online items). Only the new,
  // additive `createdAt`/`downloadsCount` feed the Browse-mode sorts.
  item.modified = modified ?: [NSDate distantPast];
  return item;
}

@implementation ToneBrowserController
// Persist the Browse filter dropdowns (gear + sort) to disk on every USER change
// (sender != nil; programmatic [self filterChanged:nil] calls never write), and
// re-select the saved titles when the popup is built. Element recreates the
// plugin editor (and these NSPopUpButtons) every time the window is reopened,
// so without this the selections reset to "All Gear"/"Newest".
- (void)persistFilterSelection {
  NSString* dir = [@("~/Library/Application Support/NAM Oversampled Rig") stringByExpandingTildeInPath];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  NSString* path = [dir stringByAppendingPathComponent:@"browse-filters.txt"];
  NSString* line = [NSString stringWithFormat:@"%@\n%@\n",
                    self.gear.titleOfSelectedItem ?: @"", self.sort.titleOfSelectedItem ?: @""];
  [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
+ (void)restoreFilterSelectionForGear:(NSPopUpButton*)gear sort:(NSPopUpButton*)sort {
  NSString* path = [[@("~/Library/Application Support/NAM Oversampled Rig") stringByExpandingTildeInPath]
                    stringByAppendingPathComponent:@"browse-filters.txt"];
  NSString* text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  if (![text isKindOfClass:[NSString class]] || !text.length) return;
  NSArray* lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
  NSString* savedGear = lines.count > 0 ? lines[0] : @"";
  NSString* savedSort = lines.count > 1 ? lines[1] : @"";
  for (NSString* title in gear.itemTitles)
    if ([title isEqualToString:savedGear]) { [gear selectItemWithTitle:title]; break; }
  for (NSString* title in sort.itemTitles)
    if ([title isEqualToString:savedSort]) { [sort selectItemWithTitle:title]; break; }
}

- (void)dealloc {
  [self logTone3000:@"ToneBrowserController dealloc"];
}
- (instancetype)init {
  if ((self = [super init])) {
    _allItems = [NSMutableArray array]; _visibleItems = @[];
    _searchResults = [NSMutableArray array];
    _images = [NSMutableDictionary dictionary]; _mode = @"Browse";
    _nextSearchPage = 1; _searchTotalPages = 0; _searchGeneration = 0;
    _searchIds = [NSMutableSet set];
    // Prefer the plugin's OWN persisted session. If absent (fresh install / not
    // yet connected), bootstrap from NAM Rig's session so we can refresh it and
    // persist our own copy — from then on we no longer depend on NAM Rig.
    // Only adopt plausible tokens (same gate as connectIfNeeded): a rotated
    // refresh stub would poison the refresh path with 401s. NOTE: real
    // Tone3000 refresh tokens are SHORT (~12 chars — verified against NAM
    // Rig's own working keychain session), so the floor is 8, not 20+.
    NSDictionary* session = pluginSession();
    if (!session) session = namRigSession();
    NSString* access = [session[@"accessToken"] isKindOfClass:NSString.class]
        ? session[@"accessToken"] : nil;
    NSString* refresh = [session[@"refreshToken"] isKindOfClass:NSString.class]
        ? session[@"refreshToken"] : nil;
    if (access.length >= 100 && (!refresh.length || refresh.length >= 8)) {
      _accessToken = access;
      _refreshToken = refresh;
    }
    [self logTone3000:[NSString stringWithFormat:@"INIT tokens access=%d refresh=%d",
                       (int)access.length, (int)refresh.length]];
  }
  return self;
}

- (void)setOnlineStatus:(NSString*)message {
  dispatch_async(dispatch_get_main_queue(), ^{ self.status.stringValue = message; });
}

- (void)setAuthStatus:(NSString*)message color:(NSColor*)color {
  dispatch_async(dispatch_get_main_queue(), ^{ self.authStatus.stringValue = message; self.authStatus.textColor = color; });
}

- (void)logTone3000:(NSString*)message {
  NSString* line = [NSString stringWithFormat:@"%@  %@\n", [NSDate date], message ?: @""];
  NSString* path = @"/private/tmp/nam_oversampled_rig_tone3000.log";
  NSFileHandle* file = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!file) { [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
  [file seekToEndOfFile]; [file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [file closeFile];
}

- (void)apiGET:(NSString*)path completion:(void (^)(NSDictionary*, NSInteger, NSError*))completion {
  NSURL* url = [NSURL URLWithString:[kToneAPI stringByAppendingString:path]];
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
  if (self.accessToken.length) [request setValue:[@"Bearer " stringByAppendingString:self.accessToken] forHTTPHeaderField:@"Authorization"];
  [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    NSInteger status = [(NSHTTPURLResponse*)response statusCode];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    [self logTone3000:[NSString stringWithFormat:@"GET %@ -> %ld, rows=%lu, error=%@", path, (long)status,
                       (unsigned long)([json[@"data"] isKindOfClass:NSArray.class] ? [json[@"data"] count] : 0), error.localizedDescription ?: @"none"]];
    completion([json isKindOfClass:NSDictionary.class] ? json : nil, status, error);
  }] resume];
}

- (void)mergeRemoteTones:(NSArray*)tones favorite:(BOOL)favorite {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSMutableDictionary<NSNumber*, ToneItem*>* byId = [NSMutableDictionary dictionary];
    for (ToneItem* item in self.allItems) byId[@(item.toneId)] = item;
    NSMutableArray<ToneItem*>* ordered = [NSMutableArray array];
    for (NSDictionary* tone in tones) {
      if (![tone isKindOfClass:NSDictionary.class]) continue;
      NSNumber* key = [tone[@"id"] respondsToSelector:@selector(integerValue)] ? @([tone[@"id"] integerValue]) : nil;
      if (!key) continue;
      ToneItem* existing = byId[key];
      if (existing) { existing.favorite |= favorite; existing.toneData = tone; if (!favorite) [ordered addObject:existing]; continue; }
      ToneItem* item = toneItem(tone, @[], nil); if (!item) continue;
      item.favorite |= favorite; [self.allItems addObject:item]; byId[key] = item; if (!favorite) [ordered addObject:item];
    }
    if (!favorite) {
      NSMutableSet<NSNumber*>* seen = [NSMutableSet set]; for (ToneItem* item in ordered) [seen addObject:@(item.toneId)];
      for (ToneItem* item in self.allItems) if (![seen containsObject:@(item.toneId)]) [ordered addObject:item];
      self.allItems = ordered;
    }
    [self filterChanged:nil];
  });
}

// Favorite/unfavorite a tone from its card's star toggle. Optimistic UI: flip
// the flag and redraw immediately; revert if the API call fails. Idempotent
// per API docs (PUT → 200, DELETE → 204), so retries are safe.
- (void)toggleFavoriteFromCard:(ToneItem*)item {
  if (!item) return;
  if (!self.accessToken.length) {
    self.status.stringValue = @"Connect to Tone3000 to save favorites";
    return;
  }
  BOOL adding = !item.favorite;
  item.favorite = adding;

  // If the card is visible, redraw it (and siblings sharing the tone).
  for (ToneCardItem *card in self.collectionView.visibleItems) {
    ToneItem *cardItem = (ToneItem *)card.representedObject;
    if ([cardItem isKindOfClass:[ToneItem class]] && cardItem.toneId == item.toneId) {
      card.representedObject = cardItem;   // re-runs setRepresentedObject → star redraw
    }
  }

  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@/tones/%ld/favorite", kToneAPI, (long)item.toneId]]];
  request.HTTPMethod = adding ? @"PUT" : @"DELETE";
  request.timeoutInterval = 15;
  [request setValue:[@"Bearer " stringByAppendingString:self.accessToken] forHTTPHeaderField:@"Authorization"];

  __weak ToneBrowserController *weakSelf = self;
  [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    NSInteger status = [(NSHTTPURLResponse*)response statusCode];
    BOOL ok = (status >= 200 && status < 300) && !error;
    dispatch_async(dispatch_get_main_queue(), ^{
      ToneBrowserController *strongSelf = weakSelf; if (!strongSelf) return;
      if (ok) {
        [strongSelf logTone3000:[NSString stringWithFormat:@"FAVORITE %@ -> %ld tone=%ld", adding ? @"PUT" : @"DELETE", (long)status, (long)item.toneId]];
        strongSelf.status.stringValue = adding ? @"Added to favorites" : @"Removed from favorites";
        if (!adding) {
          // Drop the tone from the in-memory union so Favorites mode and the
          // extras section stop offering it (mirrors mergeRemoteTones cleanup).
          NSMutableArray<ToneItem*>* kept = [NSMutableArray array];
          for (ToneItem* it in strongSelf.allItems) if (it.toneId != item.toneId) [kept addObject:it];
          strongSelf.allItems = kept;
          [strongSelf filterChanged:nil];
        }
      } else {
        item.favorite = !adding;   // revert optimistic flip
        [strongSelf logTone3000:[NSString stringWithFormat:@"FAVORITE FAILED tone=%ld -> %ld %@ %@", (long)item.toneId, (long)status, error.localizedDescription ?: @"", data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @""]];
        strongSelf.status.stringValue = @"Favorite failed — try again";
        for (ToneCardItem *card in strongSelf.collectionView.visibleItems) {
          ToneItem *cardItem = (ToneItem *)card.representedObject;
          if ([cardItem isKindOfClass:[ToneItem class]] && cardItem.toneId == item.toneId) card.representedObject = cardItem;
        }
      }
    });
  }] resume];
}

- (void)refreshOnline {
  // Prefer the plugin's own persisted session; refresh it (and persist) on 401.
  // NAM Rig is only consulted as a bootstrap seed when we have no session yet.
  NSDictionary* session = pluginSession();
  if (!session) session = namRigSession();
  NSString* fresh = [session[@"accessToken"] isKindOfClass:NSString.class] ? session[@"accessToken"] : nil;
  if (fresh.length) self.accessToken = fresh;
  if (!self.accessToken.length) { return; }
  NSDictionary* sortValues = @{@"Newest":@"newest", @"Trending":@"trending",
                               @"Most Downloaded":@"downloads-all-time", @"Oldest":@"oldest",
                               @"Best Match":@"best-match"};
  NSString* sort = sortValues[self.sort.titleOfSelectedItem] ?: @"newest";
  // Mirror tone3000.com's server-side gear filter so the result set and order
  // match the site (the site/NAM Rig send &gears=... rather than filtering
  // client-side after pulling all gear types). No &architecture= param is sent
  // because the site's default Format filter shows every model architecture;
  // hardcoding architecture=2 previously shrank result sets to A2-only.
  NSString* gearTitle = self.gear.titleOfSelectedItem;
  NSString* gearParam = @"";
  if ([gearTitle isEqualToString:@"Amps"]) gearParam = @"&gears=amp";
  else if ([gearTitle isEqualToString:@"Cabs"]) gearParam = @"&gears=cab";
  else if ([gearTitle isEqualToString:@"Pedals"]) gearParam = @"&gears=pedal";
  else if ([gearTitle isEqualToString:@"Amp + Cab"]) gearParam = @"&gears=amp-cab";
  NSString* encodedQuery = [self.search.stringValue stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
  NSString* prefix = [NSString stringWithFormat:@"/tones/search?sort=%@%@%@", sort, gearParam,
                      encodedQuery.length ? [@"&query=" stringByAppendingString:encodedQuery] : @""];
  // A fresh search: draw a new generation and reset paging state. allItems is
  // a persistent union (local packs, favorites, previously seen tones) — we do
  // NOT prune it here; filterChanged renders searchResults first, extras after.
  self.searchGeneration++;
  [self.searchIds removeAllObjects];
  self.activeSearchPrefix = prefix;
  self.nextSearchPage = 1;
  self.searchTotalPages = 0;
  // Cache-first: page 1 comes from the local SearchCache when fresh, so re-
  // sorting / re-searching within 10 minutes costs ZERO network requests.
  [self loadMoreSearchResults];
  // Favorites still come from the API (small, single page) — but not while a
  // rate-limit cooldown is active; the cached flags carry us until it lifts.
  if ([[NSDate date] timeIntervalSince1970] >= self.rateLimitUntil) {
    [self apiGET:@"/tones/favorited?page=1&page_size=100" completion:^(NSDictionary* json, NSInteger status, NSError* error) {
      NSArray* data = [json[@"data"] isKindOfClass:NSArray.class] ? json[@"data"] : @[];
      [self mergeRemoteTones:data favorite:YES];
    }];
  }
}

// Loads the NEXT page of the active search — NAM-Rig-style cache-first lazy
// pagination. Page 1 loads on every refresh; further pages load only as the
// user scrolls toward the bottom of the list (scrollViewDidScroll). Fresh
// pages are persisted to the SearchCache so revisits never touch the network.
- (void)loadMoreSearchResults {
  NSString* prefix = self.activeSearchPrefix;
  if (!prefix.length) return;
  if (self.loadingNextPage) return;                       // one page unit in flight
  if (self.searchTotalPages > 0 && self.nextSearchPage > self.searchTotalPages) return;  // exhausted
  if ([[NSDate date] timeIntervalSince1970] < self.rateLimitUntil) return;
  const NSInteger page = self.nextSearchPage;
  const NSInteger generation = self.searchGeneration;
  // The API caps search page_size at 25 (docs). CRITICAL: omitting the
  // architecture param applies the LEGACY default (A1 + Custom ONLY —
  // documented "excludes A2-only tones"), which hides nearly all new uploads
  // and mismatched the site's result set/order. We fetch each architecture
  // explicitly and merge: A2 first, then Custom, then A1, deduped by tone id.
  NSString* p2  = [NSString stringWithFormat:@"%@&page=%ld&page_size=25&architecture=2", prefix, (long)page];
  NSString* p1  = [NSString stringWithFormat:@"%@&page=%ld&page_size=25&architecture=1", prefix, (long)page];
  NSString* pc  = [NSString stringWithFormat:@"%@&page=%ld&page_size=25&architecture=custom", prefix, (long)page];
  NSArray<NSString*>* paths = @[p2, pc, p1];

  // 1) Cache-first: serve any page (<10 min old) from disk; only the misses
  // hit the network (sequential, ~150ms apart — server-friendly).
  NSMutableDictionary* fetched = [NSMutableDictionary dictionary];   // path -> json
  NSMutableArray<NSString*>* misses = [NSMutableArray array];
  for (NSString* p in paths) {
    NSDictionary* cached = cachedSearchPageForPath(p, 600.0);
    if (cached) fetched[p] = cached; else [misses addObject:p];
  }
  if (misses.count == 0) {
    [self mergeArchPages:fetched page:page generation:generation fromCache:YES];
    return;
  }
  self.loadingNextPage = YES;
  __weak ToneBrowserController* weakSelf = self;
  __block NSInteger missIndex = 0;
  void (^fetchNextMiss)(void);
  void (^__block fetchNextMissCopy)(void);
  fetchNextMiss = ^{
    ToneBrowserController* s = weakSelf;
    if (!s) return;
    if (missIndex >= (NSInteger)misses.count) {   // all done — merge
      s.loadingNextPage = NO;
      [s mergeArchPages:fetched page:page generation:generation fromCache:NO];
      return;
    }
    NSString* p = misses[missIndex];
    [s apiGET:p completion:^(NSDictionary* json, NSInteger status, NSError* error) {
      __strong ToneBrowserController* s2 = weakSelf;
      if (!s2) return;
      if (s2.searchGeneration != generation) { s2.loadingNextPage = NO; return; }
      if (status == 401) {
        s2.loadingNextPage = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ [s2 refreshToneSession]; });
        return;
      }
      if (status == 429 || status == 403) {
        s2.loadingNextPage = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
          [s2 logTone3000:[NSString stringWithFormat:@"RATE LIMIT: %ld — serving cache; cooling down 60s", (long)status]];
          s2.rateLimitUntil = [[NSDate date] timeIntervalSince1970] + 60.0;
        });
        return;
      }
      if (status == 200 && [json isKindOfClass:NSDictionary.class]) {
        saveSearchPageForPath(p, json);
        fetched[p] = json;
      }
      missIndex++;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), fetchNextMissCopy);
    }];
  };
  fetchNextMissCopy = fetchNextMiss;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    fetchNextMiss();
  });
}

// Merges the three architecture pages of one page index into a single search
// page and applies it. A2 first (matches the site's default), then Custom,
// then A1, deduped by tone id. total_pages = max across arches, so the scroll
// chain runs until every architecture is exhausted.
- (void)mergeArchPages:(NSDictionary<NSString*, NSDictionary*>*)fetched page:(NSInteger)page generation:(NSInteger)generation fromCache:(BOOL)fromCache {
  NSMutableArray<NSDictionary*>* merged = [NSMutableArray array];
  NSMutableSet<NSNumber*>* seen = [NSMutableSet set];
  NSInteger totalPages = 0;
  for (NSString* p in @[
        [NSString stringWithFormat:@"%@&page=%ld&page_size=25&architecture=2", self.activeSearchPrefix, (long)page],
        [NSString stringWithFormat:@"%@&page=%ld&page_size=25&architecture=custom", self.activeSearchPrefix, (long)page],
        [NSString stringWithFormat:@"%@&page=%ld&page_size=25&architecture=1", self.activeSearchPrefix, (long)page]]) {
    NSDictionary* json = fetched[p];
    if (!json) continue;
    NSInteger tp = [json[@"total_pages"] respondsToSelector:@selector(integerValue)] ? [json[@"total_pages"] integerValue] : 0;
    if (tp > totalPages) totalPages = tp;
    for (NSDictionary* tone in [json[@"data"] isKindOfClass:NSArray.class] ? json[@"data"] : @[]) {
      if (![tone isKindOfClass:NSDictionary.class]) continue;
      NSNumber* key = [tone[@"id"] respondsToSelector:@selector(integerValue)] ? @([tone[@"id"] integerValue]) : nil;
      if (!key || [seen containsObject:key]) continue;
      [seen addObject:key];
      [merged addObject:tone];
    }
  }
  if (totalPages <= 0) totalPages = (merged.count > 0) ? page + 1 : page;
  NSDictionary* synthesized = @{@"data": merged, @"page": @(page), @"page_size": @(25), @"total_pages": @(totalPages)};
  [self applySearchPage:synthesized page:page generation:generation fromCache:fromCache];
}

// Merges one search page (cache or network) into the list. Pages merge in
// ascending order, so appending new items at the END preserves the server's
// ordering across the whole search. Search results live in their own array
// (strict server order); everything else (local packs, favorites) renders
// after them, never interleaved — this keeps page1→pageN contiguous.
- (void)applySearchPage:(NSDictionary*)json page:(NSInteger)page generation:(NSInteger)generation fromCache:(BOOL)fromCache {
  NSArray* data = [json[@"data"] isKindOfClass:NSArray.class] ? json[@"data"] : @[];
  NSInteger pages = [json[@"total_pages"] respondsToSelector:@selector(integerValue)]
      ? [json[@"total_pages"] integerValue] : 0;
  if (pages <= 0) pages = (data.count >= 25) ? page + 1 : page;   // full page ⇒ probably more
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.searchGeneration != generation) return;
    self.searchTotalPages = pages;
    NSMutableDictionary<NSNumber*, ToneItem*>* byId = [NSMutableDictionary dictionary];
    for (ToneItem* item in self.allItems) byId[@(item.toneId)] = item;
    NSMutableArray<ToneItem*>* pageItems = [NSMutableArray array];
    for (NSDictionary* tone in data) {
      if (![tone isKindOfClass:NSDictionary.class]) continue;
      NSNumber* key = [tone[@"id"] respondsToSelector:@selector(integerValue)] ? @([tone[@"id"] integerValue]) : nil;
      if (!key) continue;
      ToneItem* existing = byId[key];
      if (existing) {
        existing.toneData = tone;            // refresh metadata in place
        [byId removeObjectForKey:key];       // claimed
      } else {
        ToneItem* item = toneItem(tone, @[], nil);
        if (!item) continue;
        existing = item;
        [self.allItems addObject:item];      // allItems stays the full union
        byId[key] = item;
      }
      if (![self.searchIds containsObject:key]) [self.searchIds addObject:key];
      [pageItems addObject:existing];
    }
    // Page 1 replaces any previously-loaded search rows; later pages append
    // (pages load strictly in ascending order via the scroll chain).
    BOOL page1 = (page == 1);
    if (page1) {
      // Drop any previously-loaded search rows (all pages) then add this page.
      NSMutableIndexSet* drop = [NSMutableIndexSet indexSet];
      for (NSUInteger i = 0; i < self.searchResults.count; i++)
        if ([self.searchIds containsObject:@(self.searchResults[i].toneId)]) [drop addIndex:i];
      [self.searchResults removeObjectsAtIndexes:drop];
      [self.searchResults replaceObjectsInRange:NSMakeRange(0, 0) withObjectsFromArray:pageItems];
    } else {
      // Append (pages load strictly in ascending order via the scroll chain).
      [self.searchResults addObjectsFromArray:pageItems];
    }
    self.nextSearchPage = page + 1;
    [self filterChanged:nil];
    self.status.stringValue = [NSString stringWithFormat:@"%lu tones • page %ld of %ld%@ — scroll for more",
                               (unsigned long)self.visibleItems.count, (long)page, (long)pages,
                               fromCache ? @" (cached)" : @""];
  });
}

- (void)sortChanged:(id)sender { if (sender) [self persistFilterSelection]; [self refreshOnline]; }

// Infinite scroll: as the user nears the bottom of the tone list, pull the
// next search page (cache-first, one page at a time). Fired via the clip
// view's bounds-change notification; note.object is the NSClipView.
- (void)scrollViewDidScroll:(NSNotification *)note {
  if (![self.activeSearchPrefix length]) return;
  NSClipView* clip = note.object;
  if (![clip isKindOfClass:NSClipView.class] || !clip.documentView) return;
  const CGFloat visibleHeight = clip.bounds.size.height;
  if (visibleHeight <= 0) return;
  const CGFloat documentHeight = clip.documentView.bounds.size.height;
  const CGFloat distanceToBottom = documentHeight - clip.bounds.origin.y - visibleHeight;
  if (distanceToBottom < 240.0)   // within ~2 rows of the bottom
    [self loadMoreSearchResults];
}

- (void)connectTone3000:(id)sender {
  // Manual Connect button — the ONLY user gesture that may open the browser.
  // Clears the login backoff so an explicit click always tries immediately.
  self.oauthLoginAttempts = 0;
  self.loginBackoffUntil = 0;
  [self setAuthStatus:@"CHECKING SESSION…" color:NSColor.systemOrangeColor];
  [self connectIfNeededAllowBrowser:YES];
}

// Background connection. Uses a stored session when valid and silently
// refreshes when expired — it NEVER opens the browser on its own. If the
// session is dead or missing it falls back to a "Not connected" state and
// waits for the user to click Connect (the only path that opens the browser).
- (void)connectIfNeededAllowBrowser:(BOOL)allowBrowser {
  if (self.connectRequested || self.oauthActive) return;   // don't stack attempts
  self.connectRequested = YES;
  __weak ToneBrowserController* weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    ToneBrowserController* strongSelf = weakSelf;
    if (!strongSelf) { return; }
    NSDictionary* session = pluginSession();
    BOOL fromNamRig = NO;
    if (!session) { session = namRigSession(); fromNamRig = YES; }
    NSString* access = [session[@"accessToken"] isKindOfClass:NSString.class] ? session[@"accessToken"] : nil;
    NSString* refresh = [session[@"refreshToken"] isKindOfClass:NSString.class] ? session[@"refreshToken"] : nil;
    [strongSelf logTone3000:[NSString stringWithFormat:@"CONNECT session=%@ source=%@ access=%d refresh=%d",
                             session ? @"yes" : @"no", fromNamRig ? @"namrig" : @"own",
                             (int)access.length, (int)refresh.length]];
    // Sanity gate: never adopt a session whose tokens are garbage. A real
    // access token is a ~900-char JWT. A real Tone3000 refresh token is SHORT
    // (~12 chars — e.g. NAM Rig's own keychain session holds a 12-char one),
    // so the floor is 8; only a missing/empty refresh is treated as poisoned.
    if ((access.length < 100) || (refresh.length && refresh.length < 8)) {
      [strongSelf logTone3000:[NSString stringWithFormat:@"CONNECT rejecting implausible session (access=%d refresh=%d)",
                               (int)access.length, (int)refresh.length]];
      strongSelf.connectRequested = NO;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (allowBrowser)
          [strongSelf startOAuthLogin];
        else
          [strongSelf setAuthStatus:@"Not connected — click Connect to sign in"
                              color:NSColor.systemGrayColor];
      });
      return;
    }
    if (!session || !access.length) {
      // No stored session. Only a manual Connect click may open the browser;
      // background paths just show the signed-out state and stay usable.
      strongSelf.connectRequested = NO;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (allowBrowser)
          [strongSelf startOAuthLogin];
        else
          [strongSelf setAuthStatus:@"Not connected — click Connect to sign in"
                              color:NSColor.systemGrayColor];
      });
      return;
    }
    strongSelf.accessToken = access;
    strongSelf.refreshToken = refresh;
    // If the stored access token has already expired, don't claim "Signed in".
    // Try a refresh first (fast path); when the refresh token is also dead, the
    // refresh handler clears the poisoned session and auto-launches the login.
    NSTimeInterval expMs = jwtExpiryMilliseconds(access);
    NSNumber* savedExp = [session[@"expiresAtMilliseconds"] respondsToSelector:@selector(doubleValue)]
        ? session[@"expiresAtMilliseconds"] : nil;
    if (savedExp) expMs = savedExp.doubleValue;
    const BOOL expired = expMs > 0 && expMs < ([[NSDate date] timeIntervalSince1970] * 1000.0 + 60000.0);
    if (expired) {
      // Try a silent refresh when a refresh token exists; otherwise (corrupt
      // or partial session) only a manual Connect click opens the browser.
      strongSelf.connectRequested = NO;
      if (refresh.length)
        dispatch_async(dispatch_get_main_queue(), ^{ [strongSelf refreshToneSessionAllowBrowser:allowBrowser]; });
      else
        dispatch_async(dispatch_get_main_queue(), ^{
          if (allowBrowser)
            [strongSelf startOAuthLogin];
          else
            [strongSelf setAuthStatus:@"Session expired — click Connect to sign in again"
                                color:NSColor.systemOrangeColor];
        });
      return;
    }
    // If we bootstrapped from NAM Rig, persist our own copy immediately.
    if (fromNamRig && refresh.length) {
      NSMutableDictionary* saved = [NSMutableDictionary dictionary];
      if (access.length) saved[@"accessToken"] = access;
      saved[@"refreshToken"] = refresh;
      savePluginSession(saved);
      [strongSelf logTone3000:@"BOOTSTRAP: saved plugin session from NAM Rig"];
    }
    strongSelf.connectRequested = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongSelf setAuthStatus:(fromNamRig ? @"Signed in via NAM Rig" : @"Signed in")
                          color:NSColor.systemGreenColor];
      [strongSelf refreshOnline];
    });
  });
}

// Silent variant used by UI build + periodic timer; never opens the browser.
- (void)connectIfNeeded {
  [self connectIfNeededAllowBrowser:NO];
}

// Kick-starts the background connect when the browser UI is built and keeps a
// periodic safety net: if the session dies silently while the plugin is open
// (no request fired to trigger the 401 chain), re-establish it. This path is
// silent-only: it may refresh tokens but never launches a browser login.
- (void)autoConnect {
  __weak ToneBrowserController* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    __strong ToneBrowserController* s = weakSelf; if (!s) return;
    [s connectIfNeeded];
  });
  if (self.connectTimer) return;
  self.connectTimer = [NSTimer scheduledTimerWithTimeInterval:1200.0 repeats:YES block:^(NSTimer* t) {
    __strong ToneBrowserController* s = weakSelf; if (!s) return;
    if (s.oauthActive || s.connectRequested) return;      // a flow is already running
    [s connectIfNeeded];                                  // silent: never opens the browser
  }];
}

// ---- TONE3000 OAuth login flow (authorization-code + PKCE) ----
// Binds a one-shot HTTP listener on 127.0.0.1 at an OS-chosen port, opens the
// authorize page in the default browser, waits for the redirect, exchanges the
// code for tokens, and persists the session to the plugin's keychain.
- (void)startOAuthLogin {
  if (self.oauthActive) return;
  // Auto-retry pacing: don't re-open the browser during a backoff window set
  // by a recent failed attempt. Manual Connect clears the backoff.
  if ([[NSDate date] timeIntervalSince1970] < self.loginBackoffUntil) {
    [self setAuthStatus:@"Sign-in is on a short cooldown — click Connect again in a moment"
                  color:NSColor.systemOrangeColor];
    return;
  }
  self.oauthActive = YES;

  int sock = socket(AF_INET, SOCK_STREAM, 0);
  if (sock < 0) { [self oauthCleanup]; [self setAuthStatus:@"Could not start sign-in" color:NSColor.systemRedColor]; return; }
  int yes = 1;
  setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;   // OS-assigned free port
  if (bind(sock, (struct sockaddr*)&addr, sizeof addr) < 0) { close(sock); [self oauthCleanup]; [self setAuthStatus:@"Could not start sign-in" color:NSColor.systemRedColor]; return; }
  socklen_t alen = sizeof addr;
  getsockname(sock, (struct sockaddr*)&addr, &alen);
  self.oauthPort = ntohs(addr.sin_port);
  if (listen(sock, 1) < 0) { close(sock); [self oauthCleanup]; [self setAuthStatus:@"Could not start sign-in" color:NSColor.systemRedColor]; return; }

  NSString* verifier = base64URLStringNoPadding(randomDataOfLength(32));   // 43 chars
  self.oauthVerifier = verifier;
  self.oauthState = base64URLStringNoPadding(randomDataOfLength(24));
  NSString* challenge = base64URLStringNoPadding(sha256Data(verifier));

  // Accept the browser redirect on a background thread.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [self acceptOAuthCallbackOnSocket:sock];
  });

  NSString* redirect = [NSString stringWithFormat:@"http://127.0.0.1:%d/callback", self.oauthPort];
  NSString* authorizeURL = [NSString stringWithFormat:
      @"%@/oauth/authorize?client_id=%@&response_type=code&redirect_uri=%@&code_challenge=%@&code_challenge_method=S256&state=%@",
      kToneAPI, kPluginPublishableKey,
      percentEncode(redirect), challenge, self.oauthState];
  [self setAuthStatus:@"Waiting for browser sign-in…" color:NSColor.systemOrangeColor];
  self.status.stringValue = @"Authorize in the browser that opened — then come back here";
  [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:authorizeURL]];
  [self logTone3000:[NSString stringWithFormat:@"OAUTH authorize opened (port %d)", self.oauthPort]];

  __weak ToneBrowserController* weakSelf = self;
  // Timeout: stop the flow quietly. Login is always user-initiated now, so the
  // next attempt happens only when the user clicks Connect again — never by
  // re-opening the browser on a timer.
  self.oauthTimer = [NSTimer scheduledTimerWithTimeInterval:180.0 repeats:NO block:^(NSTimer* t) {
    __strong ToneBrowserController* s = weakSelf; if (!s) return;
    if (!s.oauthActive) return;
    [s oauthCleanup];
    [s setAuthStatus:@"Sign-in timed out — click Connect to try again" color:NSColor.systemRedColor];
  }];
}

// Runs on a background thread: accept()s the browser's redirect, parses the
// callback query, responds with a tiny HTML page, then hands off to main.
- (void)acceptOAuthCallbackOnSocket:(int)sock {
  NSString* code = nil;
  NSString* state = nil;
  BOOL failed = NO;
  int c = accept(sock, NULL, NULL);
  close(sock);
  if (c >= 0) {
    char buf[16384];
    ssize_t n = read(c, buf, sizeof buf - 1);
    if (n > 0) {
      buf[n] = 0;
      NSString* req = [NSString stringWithUTF8String:buf];
      NSRange sp = [req rangeOfString:@" "];
      if (sp.location != NSNotFound) {
        NSRange rest = NSMakeRange(sp.location + 1, req.length - sp.location - 1);
        NSRange sp2 = [req rangeOfString:@" " options:0 range:rest];
        NSString* target = sp2.location == NSNotFound
            ? [req substringWithRange:rest]
            : [req substringWithRange:NSMakeRange(rest.location, sp2.location - rest.location)];
        NSRange q = [target rangeOfString:@"?"];
        NSString* query = q.location == NSNotFound ? @"" : [target substringFromIndex:q.location + 1];
        NSDictionary* params = parseQueryString(query);
        if (params[@"error"]) failed = YES;
        code = [params[@"code"] isKindOfClass:NSString.class] ? params[@"code"] : nil;
        state = params[@"state"];
        [self logTone3000:[NSString stringWithFormat:@"OAUTH callback received (code=%lu state=%@)", (unsigned long)code.length, state ? @"yes" : @"no"]];
      } else {
        failed = YES;
      }
    } else {
      failed = YES;
    }
    const char* resp =
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"
        "<html><body style='font-family:sans-serif;padding:2em'><h2>Sign-in complete</h2>"
        "<p>You can close this window and return to the plugin.</p></body></html>";
    write(c, resp, strlen(resp));
    close(c);
  } else {
    failed = YES;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    if (failed || !code.length) {
      [self oauthCleanup];
      [self setAuthStatus:@"Sign-in failed — click Connect to try again" color:NSColor.systemRedColor];
      return;
    }
    [self handleOAuthCode:code state:state];
  });
}

- (void)handleOAuthCode:(NSString*)code state:(NSString*)state {
  [self logTone3000:[NSString stringWithFormat:@"OAUTH handle: code=%lu state=%lu expect=%lu",
                     (unsigned long)code.length, (unsigned long)state.length,
                     (unsigned long)self.oauthState.length]];
  if (![state isEqualToString:self.oauthState]) {
    [self logTone3000:@"OAUTH handle: STATE MISMATCH — aborting"];
    [self oauthCleanup];
    [self setAuthStatus:@"Sign-in failed (state mismatch) — click Connect to try again" color:NSColor.systemRedColor];
    return;
  }
  [self setAuthStatus:@"Completing sign-in…" color:NSColor.systemOrangeColor];
  // Strong capture — the login flow MUST survive UI teardown. Element can
  // destroy the plugin window while the browser authorize is in flight (e.g.
  // the user switches to the browser to approve); with a weak capture the
  // controller would deallocate and the exchange would die silently. Retain
  // self so the flow completes and the session is saved even if the window
  // is gone. The blocks release the controller once the exchange resolves.
  ToneBrowserController* strongSelf = self;
  NSString* verifier = self.oauthVerifier;
  NSString* redirect = [NSString stringWithFormat:@"http://127.0.0.1:%d/callback", self.oauthPort];
  NSString* body = [NSString stringWithFormat:
      @"grant_type=authorization_code&code=%@&client_id=%@&redirect_uri=%@&code_verifier=%@",
      percentEncode(code), kPluginPublishableKey, percentEncode(redirect), percentEncode(verifier)];
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kToneAPI stringByAppendingString:@"/oauth/token"]]];
  request.HTTPMethod = @"POST";
  request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
  [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
  __block BOOL finished = NO;
  // Hard timeout so a hung exchange can never die silently.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (finished) return;
    finished = YES;
    [strongSelf logTone3000:@"EXCHANGE timed out after 25s (no response from /oauth/token)"];
    [strongSelf oauthCleanup];
    [strongSelf setAuthStatus:@"Sign-in didn't complete (timeout) — click Connect to try again" color:NSColor.systemRedColor];
  });
  [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                   completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    NSInteger statusCode = [(NSHTTPURLResponse*)response statusCode];
    if (finished) { return; }
    finished = YES;
    NSDictionary* token = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    [strongSelf logTone3000:[NSString stringWithFormat:@"EXCHANGE response: status=%ld data=%lu err=%@",
                    (long)statusCode, (unsigned long)data.length, error.localizedDescription ?: @"none"]];
    // Tolerate both flat responses and a nested {"data": {...}} envelope.
    NSDictionary* payload = token;
    NSDictionary* nested = [token[@"data"] isKindOfClass:NSDictionary.class] ? token[@"data"] : nil;
    if (nested) payload = nested;
    NSString* access = [payload[@"access_token"] isKindOfClass:NSString.class] ? payload[@"access_token"] : nil;
    if (statusCode == 200 && access.length) {
      NSString* refresh = [payload[@"refresh_token"] isKindOfClass:NSString.class] ? payload[@"refresh_token"] : @"";
      NSNumber* expMs = [payload[@"expires_at"] respondsToSelector:@selector(doubleValue)]
          ? @([payload[@"expires_at"] doubleValue] * 1000.0) : nil;
      if (!expMs && [payload[@"expires_at_millis"] respondsToSelector:@selector(doubleValue)])
        expMs = payload[@"expires_at_millis"];
      if (!expMs && [payload[@"expires_in"] respondsToSelector:@selector(doubleValue)])
        expMs = @(([[NSDate date] timeIntervalSince1970] + [payload[@"expires_in"] doubleValue]) * 1000.0);
      NSMutableDictionary* saved = [@{@"accessToken": access} mutableCopy];
      if (refresh.length) saved[@"refreshToken"] = refresh;
      if (expMs) saved[@"expiresAtMilliseconds"] = expMs;
      savePluginSession(saved);
      strongSelf.accessToken = access;
      strongSelf.refreshToken = refresh;
      strongSelf.oauthLoginAttempts = 0;         // login succeeded: reset retry budget + backoff
      strongSelf.loginBackoffUntil = 0;
      [strongSelf oauthCleanup];
      [strongSelf logTone3000:@"OAUTH login success (session saved)"];
      [strongSelf setAuthStatus:@"Signed in" color:NSColor.systemGreenColor];
      [strongSelf refreshOnline];
    } else {
      [strongSelf oauthCleanup];
      NSString* errMsg = [token[@"error_description"] isKindOfClass:NSString.class] ? token[@"error_description"]
          : ([token[@"msg"] isKindOfClass:NSString.class] ? token[@"msg"]
             : [NSString stringWithFormat:@"HTTP %ld", (long)statusCode]);
      [strongSelf logTone3000:[NSString stringWithFormat:@"OAUTH exchange failed: %@", errMsg]];
      strongSelf.loginBackoffUntil = [[NSDate date] timeIntervalSince1970] + 30.0;
      [strongSelf setAuthStatus:@"Sign-in didn't complete — click Connect to try again" color:NSColor.systemRedColor];
    }
  }] resume];
    }

- (void)oauthCleanup {
  self.oauthActive = NO;
  [self.oauthTimer invalidate];
  self.oauthTimer = nil;
  self.oauthVerifier = nil;
  self.oauthState = nil;
}

// Best-effort token refresh. NAM Rig usually refreshes on its own; this is a
// safety net when the local token has expired. On success the updated token
// pair is applied in memory and persisted to the plugin's own keychain entry
// (NAM Rig's keychain entry is left untouched, since NAM Rig is the owner).
- (void)refreshToneSession {
  [self refreshToneSessionAllowBrowser:NO];
}

// Refreshes the access token with the stored refresh token. Called from the
// search-401 path and the background connect with allowBrowser=NO: on failure
// the poisoned session is cleared and the UI shows the signed-out state
// instead of launching a browser. Only the manual Connect button passes
// allowBrowser=YES.
- (void)refreshToneSessionAllowBrowser:(BOOL)allowBrowser {
  if (!self.refreshToken.length) return;
  if (self.refreshingToken) return;   // concurrent 401s can't stack refreshes
  self.refreshingToken = YES;
  NSString* clientId = kPluginPublishableKey;
  NSString* body = [NSString stringWithFormat:@"grant_type=refresh_token&refresh_token=%@&client_id=%@",
                    [self.refreshToken stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet],
                    [clientId stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kToneAPI stringByAppendingString:@"/oauth/token"]]];
  request.HTTPMethod = @"POST"; request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
  [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
  __weak ToneBrowserController* weakSelf = self;
  [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                   completionHandler:^(NSData* data, NSURLResponse* response, NSError* e) {
    ToneBrowserController* strongSelf = weakSelf;
    if (!strongSelf) return;
    strongSelf.refreshingToken = NO;    // clear before the branches below
    NSDictionary* token = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString* access = [token[@"access_token"] isKindOfClass:NSString.class]
        ? token[@"access_token"] : nil;
    if (access.length) {
      strongSelf.accessToken = access;
      NSString* newRefresh = [token[@"refresh_token"] isKindOfClass:NSString.class]
          ? token[@"refresh_token"] : nil;
      if (newRefresh.length) strongSelf.refreshToken = newRefresh;
      // The plugin now owns this session: persist it to OUR keychain entry so
      // future loads no longer depend on NAM Rig.
      NSNumber* expiry = [token[@"expires_at"] respondsToSelector:@selector(longLongValue)]
          ? @([token[@"expires_at"] longLongValue] * 1000.0) : nil;
      if (!expiry) expiry = [token[@"expires_at_millis"] respondsToSelector:@selector(longLongValue)]
          ? @([token[@"expires_at_millis"] longLongValue]) : nil;
      NSMutableDictionary* saved = [NSMutableDictionary dictionary];
      saved[@"accessToken"] = access;
      if (newRefresh.length) saved[@"refreshToken"] = newRefresh;
      if (expiry) saved[@"expiresAtMilliseconds"] = expiry;
      savePluginSession(saved);
      [strongSelf logTone3000:@"REFRESH token success (saved to plugin session)"];
      dispatch_async(dispatch_get_main_queue(), ^{ [strongSelf refreshOnline]; });
    } else {
      // The refresh endpoint reports failures as {"code":400,"error_code":"...","msg":"..."};
      // some grants use the standard {"error","error_description"} shape. Read both.
      NSString* err = [token[@"error_code"] isKindOfClass:NSString.class] ? token[@"error_code"]
          : ([token[@"error"] isKindOfClass:NSString.class] ? token[@"error"] : @"?");
      NSString* desc = [token[@"msg"] isKindOfClass:NSString.class] ? token[@"msg"]
          : ([token[@"error_description"] isKindOfClass:NSString.class] ? token[@"error_description"]
             : (e.localizedDescription ?: @"?"));
      [strongSelf logTone3000:[NSString stringWithFormat:@"REFRESH failed: %@ / %@", err, desc]];
      // A value error (not a network problem) means the stored refresh token
      // was rotated server-side ("refresh_token_already_used" / "not_found");
      // keeping it poisons every request with 401. Drop the poisoned session
      // and open a fresh browser login so Connect never dead-ends again.
      if ([err containsString:@"used"] || [err containsString:@"not_found"]
          || [err containsString:@"invalid_grant"] || [err containsString:@"invalid-client"]
          || [err containsString:@"invalid_client"]   // server sends underscore form ("Client does not match the session's OAuth client")
          || [err containsString:@"expired"] || [err containsString:@"invalid_request"]) {
        clearPluginSession();
        dispatch_async(dispatch_get_main_queue(), ^{
          strongSelf.accessToken = nil;
          strongSelf.refreshToken = nil;
          if (allowBrowser) {
            [strongSelf setAuthStatus:@"Session expired — signing you in…" color:NSColor.systemOrangeColor];
            [strongSelf startOAuthLogin];
          } else {
            [strongSelf setAuthStatus:@"Session expired — click Connect to sign in again"
                                color:NSColor.systemRedColor];
          }
        });
        return;
      }
      // Fall back to any NAM Rig tokens we still have.
      NSDictionary* s = pluginSession();
      if (!s) s = namRigSession();
      NSString* fresh = [s[@"accessToken"] isKindOfClass:NSString.class] ? s[@"accessToken"] : nil;
      if (fresh.length) strongSelf.accessToken = fresh;
    }
  }] resume];
}

- (void)reloadLibrary:(id)sender {
  self.status.stringValue = @"Refreshing NAM Rig / Tone3000 cache…";
  __weak ToneBrowserController* weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    ToneBrowserController* strongSelf = weakSelf; if (!strongSelf) return;
    NSMutableArray<ToneItem*>* items = [NSMutableArray array];
    NSMutableDictionary<NSNumber*, ToneItem*>* localByTone = [NSMutableDictionary dictionary];
    NSString* library = [@"~/Music/Tone3000 Library" stringByExpandingTildeInPath];
    NSDirectoryEnumerator* files = [[NSFileManager defaultManager] enumeratorAtPath:library];
    for (NSString* relative in files) {
      if (![relative.lastPathComponent isEqualToString:@"_tone3000.json"]) continue;
      NSString* manifest = [library stringByAppendingPathComponent:relative];
      NSDictionary* root = jsonDictionaryAtPath(manifest);
      NSDictionary* tone = [root[@"tone"] isKindOfClass:NSDictionary.class] ? root[@"tone"] : nil;
      if (!tone) continue;
      NSString* folder = manifest.stringByDeletingLastPathComponent;
      NSMutableArray<NSString*>* models = [NSMutableArray array];
      for (NSDictionary* download in [root[@"downloads"] isKindOfClass:NSArray.class] ? root[@"downloads"] : @[]) {
        NSString* filename = [download[@"local_filename"] isKindOfClass:NSString.class] ? download[@"local_filename"] : nil;
        if (!filename) continue;
        NSString* path = [folder stringByAppendingPathComponent:filename];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) [models addObject:path];
      }
      NSDate* date = [[[NSFileManager defaultManager] attributesOfItemAtPath:manifest error:nil]
                      fileModificationDate];
      ToneItem* item = toneItem(tone, models, date);
      if (item) {
        ToneItem *existing = localByTone[@(item.toneId)];
        if (existing) {
          // Same tone found in another folder — merge models into the existing item.
          NSMutableArray *merged = [existing.models mutableCopy];
          for (NSString *m in item.models) {
            if (![merged containsObject:m]) [merged addObject:m];
          }
          existing.models = merged;
        } else {
          [items addObject:item];
          localByTone[@(item.toneId)] = item;
        }
      }
    }

    // NAM Rig's URL cache contains Browse/Favorites tone metadata. Reuse the
    // public metadata while leaving NAM Rig's OAuth credentials untouched.
    NSString* cache = [@"~/Library/Caches/com.nouratone.namrig/fsCachedData" stringByExpandingTildeInPath];
    for (NSString* name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:cache error:nil]) {
      NSDictionary* page = jsonDictionaryAtPath([cache stringByAppendingPathComponent:name]);
      NSArray* data = [page[@"data"] isKindOfClass:NSArray.class] ? page[@"data"] : nil;
      if (!data || ![data.firstObject isKindOfClass:NSDictionary.class]) continue;
      for (NSDictionary* tone in data) {
        if (![tone[@"title"] isKindOfClass:NSString.class] || ![tone[@"gear"] isKindOfClass:NSString.class]) continue;
        NSNumber* key = [tone[@"id"] respondsToSelector:@selector(integerValue)] ? @([tone[@"id"] integerValue]) : nil;
        if (!key) continue;
        ToneItem* local = localByTone[key];
        const BOOL favorite = [tone[@"is_favorite"] respondsToSelector:@selector(boolValue)] && [tone[@"is_favorite"] boolValue];
        if (local) { if (favorite) local.favorite = YES; continue; }
        ToneItem* item = toneItem(tone, @[], nil);
        if (item && ![items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ToneItem* x, NSDictionary*) { return x.toneId == item.toneId; }]].count)
          [items addObject:item];
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      ToneBrowserController* selfRef = weakSelf; if (!selfRef) return;
      selfRef.allItems = items; [selfRef filterChanged:nil]; [selfRef refreshOnline];
    });
  });
}

- (void)selectMode:(NSButton*)sender {
  self.mode = sender.title;
  for (RigButton* b in self.modeButtons) b.state = (b == sender) ? NSControlStateValueOn : NSControlStateValueOff;
  [self filterChanged:nil];
}
- (void)controlTextDidChange:(NSNotification*)notification { [self filterChanged:nil]; }
- (void)controlTextDidEndEditing:(NSNotification*)notification { if (self.accessToken.length) [self refreshOnline]; }

- (void)filterChanged:(id)sender {
  if (sender) [self persistFilterSelection];
  NSString* query = self.search.stringValue.lowercaseString;
  NSString* gear = self.gear.titleOfSelectedItem;
  NSMutableArray<ToneItem*>* shown = [NSMutableArray array];
  // Browse mode: the search API returns results ALREADY sorted — render
  // searchResults (strict server order, page1→pageN contiguous) first, then
  // locally-known extras (local packs, favorites not in this search). Never
  // re-sort by local fields: a downloaded tone's createdAt is its file's
  // modification date, which would scramble the true server ordering.
  const BOOL browseServerOrder = [self.mode isEqualToString:@"Browse"] && self.searchResults.count > 0;
  if (browseServerOrder) {
    for (ToneItem* item in self.searchResults) {
      if (!gearMatchesFilter(item.gear, gear)) continue;
      NSString* searchable = [NSString stringWithFormat:@"%@ %@ %@", item.title, item.creator, item.gear].lowercaseString;
      if (query.length && [searchable rangeOfString:query].location == NSNotFound) continue;
      [shown addObject:item];
    }
  }
  NSMutableSet<NSNumber*>* emitted = [NSMutableSet set];
  for (ToneItem* item in shown) [emitted addObject:@(item.toneId)];
  for (ToneItem* item in self.allItems) {
    if (browseServerOrder && [emitted containsObject:@(item.toneId)]) continue;   // already shown
    if ([self.mode isEqualToString:@"Favorites"] && !item.favorite) continue;
    if ([self.mode isEqualToString:@"Local"] && !item.local) continue;
    if (!gearMatchesFilter(item.gear, gear)) continue;
    NSString* searchable = [NSString stringWithFormat:@"%@ %@ %@", item.title, item.creator, item.gear].lowercaseString;
    if (query.length && [searchable rangeOfString:query].location == NSNotFound) continue;
    [shown addObject:item];
  }
  if ([self.mode isEqualToString:@"Recent"]) {
    [shown sortUsingComparator:^NSComparisonResult(ToneItem* a, ToneItem* b) { return [b.modified compare:a.modified]; }];
  }
  self.visibleItems = shown;
  [self.collectionView reloadData];
  self.status.stringValue = [NSString stringWithFormat:@"%lu tones • %lu local packs • shared with NAM Rig",
                             (unsigned long)shown.count,
                             (unsigned long)[shown filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ToneItem* x, NSDictionary*) { return x.local; }]].count];
}

- (NSInteger)numberOfSectionsInCollectionView:(NSCollectionView *)collectionView { return 1; }
- (NSInteger)collectionView:(NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section { return self.visibleItems.count; }
- (NSCollectionViewItem *)collectionView:(NSCollectionView *)collectionView itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath {
  ToneCardItem *card = [collectionView makeItemWithIdentifier:@"ToneCard" forIndexPath:indexPath];
  card.representedObject = self.visibleItems[indexPath.item];
  __weak ToneBrowserController *weakSelf = self;
  card.onFavToggle = ^(ToneItem *item) {
    [weakSelf toggleFavoriteFromCard:item];
  };
  return card;
}

- (void)collectionView:(NSCollectionView *)collectionView didSelectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths {
  NSIndexPath *path = indexPaths.anyObject;
  if (!path || path.item >= (NSInteger)self.visibleItems.count) return;
  ToneItem *item = self.visibleItems[path.item];
  if (item.local) {
    [self showModelsForItem:item andLoad:YES];
    return;
  }
  self.status.stringValue = @"Getting this tone's models…";
  if (self.accessToken.length) {
    NSInteger selectedToneId = item.toneId;
    __weak ToneBrowserController *weakSelf = self;
    // The /models endpoint is architecture-specific: omitting the param returns
    // NOTHING even when models exist. Default to A2 (the current default), and
    // fall back to A1 legacy if that tone only has A1 models.
    void (^fetch)(NSString*, void (^)(NSArray*)) = ^(NSString *arch, void (^done)(NSArray*)) {
      __strong ToneBrowserController *s = weakSelf;
      if (!s) { done(@[]); return; }
      [s apiGET:[NSString stringWithFormat:@"/models?tone_id=%ld&page=1&page_size=100&architecture=%@", (long)selectedToneId, arch]
          completion:^(NSDictionary *json, NSInteger status, NSError *error) {
        done([json[@"data"] isKindOfClass:NSArray.class] ? json[@"data"] : @[]);
      }];
    };
    void (^finish)(NSArray*) = ^(NSArray *data) {
      dispatch_async(dispatch_get_main_queue(), ^{
        ToneBrowserController *strongSelf = weakSelf; if (!strongSelf) return;
        NSIndexPath *current = strongSelf.collectionView.selectionIndexPaths.anyObject;
        if (!current || current.item >= (NSInteger)strongSelf.visibleItems.count || strongSelf.visibleItems[current.item].toneId != selectedToneId) return;
        item.remoteModels = data;
        if (data.count > 0) {
          strongSelf.status.stringValue = [NSString stringWithFormat:@"%lu models — downloading all…", (unsigned long)data.count];
          [strongSelf downloadAllModels:item];
        } else {
          strongSelf.status.stringValue = @"No downloadable models found";
        }
      });
    };
    // A2 + Custom are the default set (merged, deduped by model id). A1 legacy
    // is fetched ONLY when neither A2 nor Custom has any models. Verified
    // against the live API: tone 44691 → arch2=44, arch1=39, arch3=0 rows.
    void (^fetchMaybeA1)(NSArray*, NSArray*) = ^(NSArray *a2, NSArray *custom) {
      if (a2.count == 0 && custom.count == 0) {
        fetch(@"1", ^(NSArray *a1) { finish(a1); });
        return;
      }
      NSMutableArray *merged = [NSMutableArray arrayWithArray:a2];
      for (NSDictionary *m in custom) {
        id mid = m[@"id"];
        BOOL dup = NO;
        for (NSDictionary *e in a2) if (mid && [e[@"id"] isEqual:mid]) { dup = YES; break; }
        if (!dup) [merged addObject:m];
      }
      finish(merged);
    };
    fetch(@"2", ^(NSArray *a2) {
      fetch(@"custom", ^(NSArray *custom) { fetchMaybeA1(a2, custom); });
    });
  } else {
    self.status.stringValue = @"Connect Tone3000 to download models";
  }
}

// Populate the selected stage's tile selector and load the first model.
- (void)showModelsForItem:(ToneItem *)item andLoad:(BOOL)load {
  if (self.state)
    self.state->setStageModels((size_t)item.stage, item.models);
  if (item.models.count > 0) {
    if (load && self.state) {
      self.state->sendPath((size_t)item.stage, item.models.firstObject.fileSystemRepresentation);
      self.state->setStageThumb((size_t)item.stage, item.artworkPath, item.toneId, item.imageURL);
      self.status.stringValue = [NSString stringWithFormat:@"%lu models — loaded", (unsigned long)item.models.count];
    }
  }
}

// Downloads EVERY model of a tone into one folder (one card = one folder =
// one _tone3000.json whose downloads[] fills the tile's model dropdown),
// mirroring NAM Rig's layout. Sequential (one request at a time) to stay
// server-friendly. Self-healing: files already on disk with the right size
// are skipped, so re-selecting a tone only fetches missing models — and
// folders created by the old first-model-only build get topped up here.
- (void)downloadAllModels:(ToneItem*)item {
  if (!self.accessToken.length || item.remoteModels.count == 0) return;
  NSString* category;
  if (item.stage == 0) category = @"Pedal";
  else if (item.stage == 2) category = @"Cab";
  else if ([item.gear.lowercaseString isEqualToString:@"amp-cab"] || [item.gear.lowercaseString isEqualToString:@"full-rig"])
    category = @"Full Rig";   // NAM Rig's library layout: full rigs get their own folder
  else category = @"Amp";
  NSString* folder = [[[[[@"~/Music/Tone3000 Library" stringByExpandingTildeInPath]
                        stringByAppendingPathComponent:category]
                       stringByAppendingPathComponent:@"NAM Oversampled Rig"]
                      stringByAppendingPathComponent:safeFilename(item.title)] copy];
  NSFileManager* fm = [NSFileManager defaultManager];
  [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
  NSMutableArray<NSDictionary*>* downloads = [NSMutableArray array];
  NSDictionary* old = jsonDictionaryAtPath([folder stringByAppendingPathComponent:@"_tone3000.json"]);
  for (NSDictionary* d in [old[@"downloads"] isKindOfClass:NSArray.class] ? old[@"downloads"] : @[])
    if ([d isKindOfClass:NSDictionary.class]) [downloads addObject:d];
  [self downloadModelStep:0 of:item.remoteModels item:item folder:folder downloads:downloads];
}

// One step of the sequential downloader: process models[index], then recurse.
- (void)downloadModelStep:(NSInteger)index
                       of:(NSArray*)models
                     item:(ToneItem*)item
                   folder:(NSString*)folder
                downloads:(NSMutableArray<NSDictionary*>*)downloads {
  if (index >= (NSInteger)models.count) {
    [self finishModelDownload:item folder:folder downloads:downloads];
    return;
  }
  NSFileManager* fm = [NSFileManager defaultManager];
  NSDictionary* model = models[index];
  NSString* name = [model[@"name"] isKindOfClass:NSString.class] ? model[@"name"] : @"Tone3000 Model";
  NSString* ext = [model[@"model_url"] isKindOfClass:NSString.class] && [model[@"model_url"] pathExtension].length
      ? [model[@"model_url"] pathExtension] : (item.stage == 2 ? @"wav" : @"nam");
  NSString* filename = [safeFilename(name) stringByAppendingPathExtension:ext];
  NSString* path = [folder stringByAppendingPathComponent:filename];
  self.status.stringValue = [NSString stringWithFormat:@"Downloading model %ld of %ld — %@",
                            (long)index + 1, (long)models.count, name];
  // Self-heal skip: already on disk at the expected size → just record it.
  NSDictionary* existing = nil;
  for (NSDictionary* d in downloads)
    if ([d[@"local_filename"] isKindOfClass:NSString.class] && [d[@"local_filename"] isEqualToString:filename]) { existing = d; break; }
  NSUInteger expected = [model[@"size"] respondsToSelector:@selector(longLongValue)] ? [model[@"size"] longLongValue] : 0;
  if (existing && [fm fileExistsAtPath:path]) {
    NSDictionary* attr = [fm attributesOfItemAtPath:path error:nil];
    if (!expected || [attr fileSize] == expected) {
      [self downloadModelStep:index + 1 of:models item:item folder:folder downloads:downloads];
      return;
    }
  }
  NSString* urlString = [model[@"model_url"] isKindOfClass:NSString.class] ? model[@"model_url"] : nil;
  if (!urlString.length) {
    [self downloadModelStep:index + 1 of:models item:item folder:folder downloads:downloads];
    return;
  }
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
  [request setValue:[@"Bearer " stringByAppendingString:self.accessToken] forHTTPHeaderField:@"Authorization"];
  __weak ToneBrowserController* weakSelf = self;
  [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    NSInteger code = [(NSHTTPURLResponse*)response statusCode];
    dispatch_async(dispatch_get_main_queue(), ^{
      ToneBrowserController* s = weakSelf; if (!s) return;
      if (data.length && code >= 200 && code < 300) {
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
        NSDictionary* download = @{@"model_id": model[@"id"] ?: @0, @"original_model": model,
                                   @"local_filename": filename, @"bytes": @(data.length),
                                   @"status": @"downloaded", @"downloaded_at": [[NSDate date] description]};
        if (existing) [downloads removeObjectIdenticalTo:existing];
        [downloads addObject:download];
      } else {
        [s logTone3000:[NSString stringWithFormat:@"MODEL DOWNLOAD FAILED (%@, HTTP %ld): %@",
                        name, (long)code, error.localizedDescription ?: @"none"]];
      }
      [s downloadModelStep:index + 1 of:models item:item folder:folder downloads:downloads];
    });
  }] resume];
}

// All models processed: write the complete manifest (schema matches NAM
// Rig's exactly, so reloadLibrary merges it like any NAM Rig pack) and
// populate the stage tile with every downloaded file.
- (void)finishModelDownload:(ToneItem*)item folder:(NSString*)folder downloads:(NSMutableArray<NSDictionary*>*)downloads {
  NSDictionary* manifest = @{@"powered_by": @"Tone3000", @"tone": item.toneData ?: @{}, @"downloads": downloads};
  NSData* json = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil];
  [json writeToFile:[folder stringByAppendingPathComponent:@"_tone3000.json"] options:NSDataWritingAtomic error:nil];
  NSFileManager* fm = [NSFileManager defaultManager];
  NSMutableArray<NSString*>* paths = [NSMutableArray array];
  for (NSDictionary* d in downloads) {
    NSString* p = [folder stringByAppendingPathComponent:d[@"local_filename"]];
    if (p.length && [fm fileExistsAtPath:p]) [paths addObject:p];
  }
  item.models = paths; item.local = YES;
  self.status.stringValue = [NSString stringWithFormat:@"%ld models ready — %@", (long)paths.count, item.title];
  if (self.state) {
    self.state->setStageModels((size_t)item.stage, item.models);
    if (paths.count) {
      self.state->sendPath((size_t)item.stage, paths.firstObject.fileSystemRepresentation);
      self.state->setStageThumb((size_t)item.stage, item.artworkPath, item.toneId, item.imageURL);
    }
  }
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
  NSSlider* knob = [NSSlider sliderWithValue:value minValue:minimum maxValue:maximum
                                      target:target action:@selector(controlChanged:)];
  knob.sliderType = NSSliderTypeCircular;
  knob.continuous = YES;
  knob.tag = port;
  knob.frame = NSMakeRect(origin.x, origin.y, 64, 64);
  [parent addSubview:knob];
  return knob;
}

// Styled NAM Rig-style panel box.
static NSBox* addPanel(NSView* parent, NSRect frame) {
  NSBox* box = [[NSBox alloc] initWithFrame:frame];
  box.boxType = NSBoxCustom;
  box.borderType = NSLineBorder;
  box.borderWidth = 1.0;
  box.cornerRadius = 10.0;
  box.borderColor = rigPanelBorder();
  box.fillColor = rigPanelBG();
  [parent addSubview:box];
  return box;
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

static void addToneBrowser(RigUIState* state, NSView* content) {
  const CGFloat pad = 24.0;
  NSBox* browser = [[NSBox alloc] initWithFrame:NSZeroRect];
  browser.boxType = NSBoxCustom; browser.cornerRadius = 10.0; browser.borderWidth = 1.0;
  browser.borderColor = rigPanelBorder(); browser.fillColor = rigPanelBG();
  browser.translatesAutoresizingMaskIntoConstraints = NO;
  // Pin below the topView (which is the previous subview of `content`).
  NSView* topView = content.subviews.count ? content.subviews.firstObject : content;
  [content addSubview:browser];
  [[browser.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:pad] setActive:YES];
  [[browser.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-pad] setActive:YES];
  [[browser.topAnchor constraintEqualToAnchor:topView.bottomAnchor constant:12] setActive:YES];
  [[browser.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12] setActive:YES];

  ToneBrowserController* controller = [[ToneBrowserController alloc] init];
  controller.state = state; state->browserController = controller;
  // Connect automatically in the background — no button click required. The
  // deferred dispatch lets the rest of the browser UI (search/gear/sort) wire
  // up before the first connect; autoConnect also installs the periodic
  // re-connect safety net.
  dispatch_async(dispatch_get_main_queue(), ^{ [controller autoConnect]; });

  const CGFloat bw = content.bounds.size.width - pad * 2;

  // Header: brand + subtle status line.
  addLabel(browser, @"TONE3000", NSMakeRect(28, 300, 130, 24),
           [NSFont fontWithName:@"SF Mono Bold" size:16.0] ?: [NSFont boldSystemFontOfSize:16],
           rigOrange());
  controller.authStatus = addLabel(browser, @"", NSMakeRect(140, 302, 300, 14),
                                   [NSFont systemFontOfSize:10], rigDimText());

  // Mode selector (toggles) + Connect + gear — single row beneath the brand.
  NSArray<NSString*>* modes = @[@"Browse", @"Favorites", @"Recent", @"Local"];
  NSMutableArray<RigButton*>* modeButtons = [NSMutableArray array];
  for (NSInteger i = 0; i < (NSInteger)modes.count; ++i) {
    RigButton* b = rigButton(browser, modes[(NSUInteger)i], controller, @selector(selectMode:),
                             NSMakeRect(200 + i * 88, 294, 84, 30));
    b.state = (i == 0) ? NSControlStateValueOn : NSControlStateValueOff;
    [modeButtons addObject:b];
  }
  controller.modeButtons = modeButtons;
  controller.connectButton = rigButton(browser, @"Connect", controller,
      @selector(connectTone3000:), NSMakeRect(bw - 230, 294, 92, 30));
  controller.connectButton.primary = NO;
  controller.connectButton.state = NSControlStateValueOff;

  controller.gear = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(bw - 128, 294, 104, 30) pullsDown:NO];
  [controller.gear addItemsWithTitles:@[@"All Gear", @"Amps", @"Cabs", @"Pedals", @"Amp + Cab"]];
  controller.gear.target = controller; controller.gear.action = @selector(filterChanged:);
  controller.gear.controlSize = NSControlSizeSmall;
  [browser addSubview:controller.gear];

  // Search / sort row.
  controller.search = [[NSSearchField alloc] initWithFrame:NSMakeRect(28, 252, bw * 0.48, 30)];
  controller.search.placeholderString = @"Search Tone3000";
  controller.search.focusRingType = NSFocusRingTypeNone;
  controller.search.delegate = controller; [browser addSubview:controller.search];
  controller.sort = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(28 + bw * 0.48 + 12, 252, 160, 30) pullsDown:NO];
  [controller.sort addItemsWithTitles:@[@"Newest", @"Trending", @"Most Downloaded", @"Oldest", @"Best Match"]];
  controller.sort.controlSize = NSControlSizeSmall;
  controller.sort.target = controller; controller.sort.action = @selector(sortChanged:);
  [browser addSubview:controller.sort];
  [ToneBrowserController restoreFilterSelectionForGear:controller.gear sort:controller.sort];

  // Tone cards — multi-column collection view, click to load/download.
  const CGFloat tableWidth = bw - 56;
  NSCollectionViewGridLayout *grid = [[NSCollectionViewGridLayout alloc] init];
  grid.minimumItemSize = NSMakeSize(180, 74);
  grid.maximumItemSize = NSMakeSize(260, 74);
  grid.minimumInteritemSpacing = 10;
  grid.minimumLineSpacing = 10;
  grid.margins = NSEdgeInsetsMake(6, 6, 6, 6);

  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(28, 48, tableWidth, 190)];
  scroll.drawsBackground = NO; scroll.borderType = NSNoBorder;
  scroll.hasVerticalScroller = YES; scroll.autohidesScrollers = YES;

  controller.collectionView = [[NSCollectionView alloc] initWithFrame:scroll.bounds];
  controller.collectionView.collectionViewLayout = grid;
  controller.collectionView.backgroundColors = @[[NSColor clearColor]];
  controller.collectionView.dataSource = controller;
  controller.collectionView.delegate = controller;
  controller.collectionView.selectable = YES;
  [controller.collectionView registerClass:[ToneCardItem class] forItemWithIdentifier:@"ToneCard"];

  scroll.documentView = controller.collectionView;
  // Infinite scroll: observe the scrollview's bounds change (no delegate
  // protocol exists for NSScrollView) — notification fires on every scroll.
  [NSNotificationCenter.defaultCenter addObserver:controller
                                         selector:@selector(scrollViewDidScroll:)
                                             name:NSViewBoundsDidChangeNotification
                                           object:scroll.contentView];
  [browser addSubview:scroll];

  controller.status = addLabel(browser, @"Scanning NAM Rig's Tone3000 library…", NSMakeRect(28, 16, bw - 56, 22),
                               [NSFont systemFontOfSize:10.5], rigDimText());
  controller.status.lineBreakMode = NSLineBreakByTruncatingTail;
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
    for (size_t i = 0; i < 3; ++i) state->pathURIDs[i] = map->map(map->handle, kPathURIs[i]);
    lv2_atom_forge_init(&state->forge, map);

    const CGFloat baseW = 1280.0, baseH = 830.0;

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

    // Top section: title bar + 3 stage boxes. A compact FIXED height keeps the
    // tiles tight near the top; the browser fills all remaining space below.
    NSView* topView = [[NSView alloc] initWithFrame:NSZeroRect];
    topView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:topView];
    [[topView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor] setActive:YES];
    [[topView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor] setActive:YES];
    [[topView.topAnchor constraintEqualToAnchor:content.topAnchor] setActive:YES];
    [[topView.heightAnchor constraintEqualToConstant:440] setActive:YES];

    state->uiController = [[NAMRigUIController alloc] init];
    state->uiController.state = state;

    NSTextField* title = [[NSTextField alloc] initWithFrame:NSZeroRect];
    title.stringValue = @"NAM OVERSAMPLED RIG"; title.editable = NO; title.selectable = NO; title.drawsBackground = NO; title.bordered = NO;
    title.font = [NSFont boldSystemFontOfSize:21.0]; title.textColor = rigText();
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [topView addSubview:title];
    [[title.leadingAnchor constraintEqualToAnchor:topView.leadingAnchor constant:24] setActive:YES];
    [[title.topAnchor constraintEqualToAnchor:topView.topAnchor constant:10] setActive:YES];
    [[title.heightAnchor constraintEqualToConstant:26] setActive:YES];

    NSTextField* chain = [[NSTextField alloc] initWithFrame:NSZeroRect];
    chain.stringValue = @"PEDAL   →   AMP   →   CAB"; chain.editable = NO; chain.selectable = NO; chain.drawsBackground = NO; chain.bordered = NO;
    chain.font = [NSFont monospacedSystemFontOfSize:14.0 weight:NSFontWeightMedium]; chain.textColor = rigDimText();
    chain.alignment = NSTextAlignmentRight; chain.translatesAutoresizingMaskIntoConstraints = NO;
    [topView addSubview:chain];
    [[chain.trailingAnchor constraintEqualToAnchor:topView.trailingAnchor constant:-170] setActive:YES];
    [[chain.topAnchor constraintEqualToAnchor:topView.topAnchor constant:14] setActive:YES];
    [[chain.widthAnchor constraintEqualToConstant:300] setActive:YES];

    state->zoomControl = [[NSComboBox alloc] initWithFrame:NSZeroRect];
    state->zoomControl.target = state->uiController; state->zoomControl.action = @selector(zoomChanged:);
    state->zoomControl.editable = YES;               // custom zoom % only (no preset list)
    state->zoomControl.controlSize = NSControlSizeSmall;
    state->zoomControl.translatesAutoresizingMaskIntoConstraints = NO;
    [topView addSubview:state->zoomControl];
    [[state->zoomControl.trailingAnchor constraintEqualToAnchor:topView.trailingAnchor constant:-24] setActive:YES];
    [[state->zoomControl.topAnchor constraintEqualToAnchor:topView.topAnchor constant:8] setActive:YES];
    [[state->zoomControl.widthAnchor constraintEqualToConstant:110] setActive:YES];
    [[state->zoomControl.heightAnchor constraintEqualToConstant:28] setActive:YES];

    NSArray<NSString*>* names = @[@"PEDAL", @"AMP", @"CAB · NAM / WAV IR"];
    // Quality is fixed at 100% — no knob, the DSP never scales model quality.
    // Display names indexed by kRigKnobPorts order; cells are laid out in
    // signal order via kRigKnobDisplayOrder.
    NSArray<NSString*>* knobNames = @[@"GATE", @"INPUT", @"OUTPUT", @"BASS", @"MID", @"TREBLE"];
    NSArray<NSString*>* knobValues = @[@"OFF", @"+0.0 dB", @"+0.0 dB", @"+0.0 dB", @"+0.0 dB", @"+0.0 dB"];
    const std::array<double, kRigKnobCount> defaults{-80.0, 0.0, 0.0, 0.0, 0.0, 0.0};
    const std::array<double, kRigKnobCount> mins{-80.0, -20.0, -20.0, -12.0, -12.0, -12.0};
    const std::array<double, kRigKnobCount> maxes{0.0, 20.0, 20.0, 12.0, 12.0, 12.0};

    // Knobs grouped under the tile they relate to: GATE/INPUT under PEDAL,
    // BASS/MID/TREBLE under AMP, OUTPUT under CAB. Each group's LEADING and
    // TRAILING edges are pinned to its tile box in the tile loop below, so the
    // knobs stay exactly within the tile's footprint at any width/zoom.
    NSView* knobGroups[3] = {nil, nil, nil};

    // Display slots (indices into kRigKnobDisplayOrder, i.e. signal order)
    // grouped per tile: PEDAL {GATE, INPUT}, AMP {BASS, MID, TREBLE}, CAB {OUTPUT}.
    const size_t groupSlots[3][3] = {{0, 1}, {2, 3, 4}, {5}};
    const size_t groupCounts[3] = {2, 3, 1};

    for (size_t g = 0; g < 3; ++g) {
      NSView* group = [[NSView alloc] initWithFrame:NSZeroRect];
      group.translatesAutoresizingMaskIntoConstraints = NO;
      [topView addSubview:group];
      knobGroups[g] = group;
      [[group.bottomAnchor constraintEqualToAnchor:topView.bottomAnchor constant:-16] setActive:YES];
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

        state->knobs[k] = addKnob(cell, (NSInteger)kRigKnobPorts[k], defaults[k],
                                  mins[k], maxes[k],
                                  NSMakePoint(0, 0), state->uiController);
        NSSlider* knob = state->knobs[k];
        knob.translatesAutoresizingMaskIntoConstraints = NO;
        centerX(knob, cell, 0);
        [[knob.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor constant:-4] setActive:YES];

        NSTextField* kname = addLabel(cell, knobNames[k], NSZeroRect,
                                      [NSFont boldSystemFontOfSize:10.5], rigDimText(), NSTextAlignmentCenter);
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
        kval.bordered = YES;
        kval.drawsBackground = YES;
        kval.backgroundColor = rigRaised();
        kval.textColor = rigText();
        kval.focusRingType = NSFocusRingTypeNone;
        kval.tag = (NSInteger)kRigKnobPorts[k];
        kval.delegate = state->uiController;
        kval.target = state->uiController;
        kval.action = @selector(knobFieldCommitted:);
        kval.translatesAutoresizingMaskIntoConstraints = NO;
        centerX(kval, cell, 0);
        [[kval.widthAnchor constraintEqualToConstant:70] setActive:YES];
        [[kval.heightAnchor constraintEqualToConstant:19] setActive:YES];
        [[kval.bottomAnchor constraintEqualToAnchor:kname.topAnchor constant:-6] setActive:YES];
      }
    }

    NSStackView* boxRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
    boxRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    boxRow.distribution = NSStackViewDistributionFillEqually;
    boxRow.spacing = 22.0;
    boxRow.translatesAutoresizingMaskIntoConstraints = NO;
    [topView addSubview:boxRow];
    [[boxRow.leadingAnchor constraintEqualToAnchor:topView.leadingAnchor constant:24] setActive:YES];
    [[boxRow.trailingAnchor constraintEqualToAnchor:topView.trailingAnchor constant:-24] setActive:YES];
    [[boxRow.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:18] setActive:YES];
    [[boxRow.bottomAnchor constraintEqualToAnchor:knobGroups[0].topAnchor constant:-12] setActive:YES];

    for (NSInteger i = 0; i < 3; ++i) {
      NSBox* box = addPanel(boxRow, NSMakeRect(0, 0, 100, 100));

      NSView* header = [[NSView alloc] initWithFrame:NSZeroRect];
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
      numL.translatesAutoresizingMaskIntoConstraints = NO;
      [header addSubview:numL];
      [[numL.leadingAnchor constraintEqualToAnchor:header.leadingAnchor] setActive:YES];
      [[numL.centerYAnchor constraintEqualToAnchor:header.centerYAnchor] setActive:YES];

      NSTextField* nmL = [[NSTextField alloc] initWithFrame:NSZeroRect];
      nmL.stringValue = names[(NSUInteger)i]; nmL.editable = NO; nmL.selectable = NO; nmL.drawsBackground = NO; nmL.bordered = NO;
      nmL.font = [NSFont boldSystemFontOfSize:14]; nmL.textColor = rigText();
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
      onBtn.translatesAutoresizingMaskIntoConstraints = NO;
      [[onBtn.trailingAnchor constraintEqualToAnchor:header.trailingAnchor] setActive:YES];
      [[onBtn.centerYAnchor constraintEqualToAnchor:header.centerYAnchor] setActive:YES];
      [[onBtn.widthAnchor constraintEqualToConstant:76] setActive:YES];
      [[onBtn.heightAnchor constraintEqualToConstant:26] setActive:YES];

      NSImageView* thumb = [[NSImageView alloc] initWithFrame:NSZeroRect];
      thumb.wantsLayer = YES; thumb.layer.cornerRadius = 12; thumb.layer.masksToBounds = YES;
      thumb.layer.backgroundColor = [NSColor colorWithSRGBRed:0.13 green:0.14 blue:0.17 alpha:1.0].CGColor;
      thumb.imageScaling = NSImageScaleProportionallyUpOrDown;
      thumb.translatesAutoresizingMaskIntoConstraints = NO;
      [box addSubview:thumb];
      [[thumb.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16] setActive:YES];
      [[thumb.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16] setActive:YES];
      [[thumb.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:14] setActive:YES];
      [[thumb.heightAnchor constraintEqualToConstant:140] setActive:YES];
      state->stageImages[(size_t)i] = thumb;

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
      mp.enabled = NO;
      [box addSubview:mp];
      [[mp.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16] setActive:YES];
      [[mp.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16] setActive:YES];
      [[mp.topAnchor constraintEqualToAnchor:thumb.bottomAnchor constant:8] setActive:YES];
      [[mp.heightAnchor constraintEqualToConstant:22] setActive:YES];

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

    addToneBrowser(state, content);
    [parent addSubview:state->view];
    state->applyZoom();                               // default 100%
    *widget = (__bridge void*)state->view;
    state->sendGet();
    state->restoreSelectedPaths();   // re-apply the persisted rig selection
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
  if (format == 0 && buffer && size == sizeof(float) && port >= 4 && port <= 15) {
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
  if (!property || property->type != state->atomURID || !value ||
      value->type != state->atomPath || value->size == 0) return;
  const LV2_URID propertyId = reinterpret_cast<const LV2_Atom_URID*>(property)->body;
  for (size_t i = 0; i < 3; ++i)
    if (propertyId == state->pathURIDs[i])
      state->displayPath(i, reinterpret_cast<const char*>(value + 1));
}

const void* extensionData(const char*) { return nullptr; }

const LV2UI_Descriptor descriptor{
    kRigUIURI, instantiate, cleanup, portEvent, extensionData};

extern "C" __attribute__((visibility("default")))
const LV2UI_Descriptor* lv2ui_descriptor(uint32_t index) {
  return index == 0 ? &descriptor : nullptr;
}
