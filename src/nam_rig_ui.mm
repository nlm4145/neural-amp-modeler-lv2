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

@interface NAMRigUIController : NSObject <NSComboBoxDelegate>
@property(nonatomic, assign) RigUIState* state;
- (void)chooseModel:(NSButton*)sender;
- (void)clearModel:(NSButton*)sender;
- (void)controlChanged:(NSSlider*)sender;
- (void)zoomChanged:(NSComboBox*)sender;
- (void)stageModelChanged:(NSPopUpButton*)sender;
@end

// Knob configuration — port-index order matches display order in the footer
// strip. Atom ports (0/1) and the stage toggles (7–10) are handled separately.
constexpr size_t kRigKnobCount = 7;
const std::array<uint32_t, kRigKnobCount> kRigKnobPorts{15, 4, 6, 5, 12, 13, 14};

static NSString* rigKnobValueText(uint32_t port, float value) {
  switch (port) {
    case 4:  return [NSString stringWithFormat:@"%+.1f dB", value];
    case 5:  return [NSString stringWithFormat:@"%+.1f dB", value];
    case 6:  return [NSString stringWithFormat:@"%.0f%%", value * 100.0f];
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
// One-shot OAuth login state (authorization-code + PKCE via a localhost callback).
@property(nonatomic) BOOL oauthActive;
@property(nonatomic) int oauthPort;
@property(nonatomic, copy) NSString* oauthVerifier;
@property(nonatomic, copy) NSString* oauthState;
@property(nonatomic, strong) NSTimer* oauthTimer;
- (void)reloadLibrary:(id)sender;
- (void)selectMode:(NSButton*)sender;
- (void)filterChanged:(id)sender;
- (void)sortChanged:(id)sender;
- (void)connectTone3000:(id)sender;
- (void)refreshToneSession;
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
@end
@implementation ToneCardItem {
  NSImageView *_artView;
  NSTextField *_titleField;
  NSTextField *_detailField;
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

  _titleField = [[NSTextField alloc] initWithFrame:NSMakeRect(72, 42, 112, 16)];
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

  self.view = v;
}
- (void)setRepresentedObject:(id)representedObject {
  [super setRepresentedObject:representedObject];
  if (![representedObject isKindOfClass:[ToneItem class]]) return;
  ToneItem *item = (ToneItem *)representedObject;
  _titleField.stringValue = item.title ?: @"";
  _detailField.stringValue = [NSString stringWithFormat:@"@%@  ·  %@", item.creator, item.gear.uppercaseString];

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
static NSString* const kNamRigPublishableKey = @"t3k_pub_axcZuBDWv8fHFR4LN0UV5kLXjIqbQ5G-";

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
- (instancetype)init {
  if ((self = [super init])) {
    _allItems = [NSMutableArray array]; _visibleItems = @[];
    _images = [NSMutableDictionary dictionary]; _mode = @"Browse";
    _nextSearchPage = 1; _searchTotalPages = 0; _searchGeneration = 0;
    _searchIds = [NSMutableSet set];
    // Prefer the plugin's OWN persisted session. If absent (fresh install / not
    // yet connected), bootstrap from NAM Rig's session so we can refresh it and
    // persist our own copy — from then on we no longer depend on NAM Rig.
    NSDictionary* session = pluginSession();
    if (!session) session = namRigSession();
    _accessToken = [session[@"accessToken"] isKindOfClass:NSString.class]
        ? session[@"accessToken"] : nil;
    _refreshToken = [session[@"refreshToken"] isKindOfClass:NSString.class]
        ? session[@"refreshToken"] : nil;
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
  // A fresh search: draw a new generation and drop the previous search's rows
  // (favorites and locally downloaded tones stay intact).
  self.searchGeneration++;
  NSMutableArray<ToneItem*>* survivors = [NSMutableArray array];
  for (ToneItem* item in self.allItems)
    if (![self.searchIds containsObject:@(item.toneId)]) [survivors addObject:item];
  self.allItems = survivors;
  [self.searchIds removeAllObjects];
  self.nextSearchPage = 1;
  self.searchTotalPages = 0;
  [self fetchSearchPagesWithPrefix:prefix];
  [self apiGET:@"/tones/favorited?page=1&page_size=100" completion:^(NSDictionary* json, NSInteger status, NSError* error) {
    NSArray* data = [json[@"data"] isKindOfClass:NSArray.class] ? json[@"data"] : @[];
    [self mergeRemoteTones:data favorite:YES];
  }];
}

// Fetches every page of the current search, chaining in server order, then
// merges the complete set in ONE call so results match tone3000.com exactly
// (the site paginates "Newest" across, e.g., 127 pages for amp heads; the old
// code fetched only page 1 and topped out at 100 rows + favorites).
// Response shape (shared with the site and NAM Rig):
//   {data: [...], page, page_size, total, total_pages}
- (void)fetchSearchPagesWithPrefix:(NSString*)prefix {
  const NSInteger generation = self.searchGeneration;
  // Accumulate pages here so the final merge sees page1..pageN in server
  // order (merging per page would re-order the list on every merge).
  NSMutableArray<NSDictionary*>* collected = [NSMutableArray array];
  [self fetchSearchPage:self.nextSearchPage prefix:prefix generation:generation collected:collected];
}

- (void)fetchSearchPage:(NSInteger)page
                 prefix:(NSString*)prefix
             generation:(NSInteger)generation
              collected:(NSMutableArray<NSDictionary*>*)collected {
  if (self.searchTotalPages > 0 && page > self.searchTotalPages) return;
  NSString* path = [NSString stringWithFormat:@"%@&page=%ld&page_size=100", prefix, (long)page];
  __weak ToneBrowserController* weakSelf = self;
  [self apiGET:path completion:^(NSDictionary* json, NSInteger status, NSError* error) {
    __strong ToneBrowserController* s = weakSelf;
    if (!s || s.searchGeneration != generation) return;   // a newer search took over
    if (status == 401) {
      dispatch_async(dispatch_get_main_queue(), ^{ [s refreshToneSession]; });
      return;
    }
    NSArray* data = [json[@"data"] isKindOfClass:NSArray.class] ? json[@"data"] : @[];
    const NSInteger got = [json[@"page"] respondsToSelector:@selector(integerValue)]
        ? [json[@"page"] integerValue] : page;
    const NSInteger pages = [json[@"total_pages"] respondsToSelector:@selector(integerValue)]
        ? [json[@"total_pages"] integerValue] : (data.count ? got : got - 1);
    if (pages > 0) s.searchTotalPages = pages;
    const BOOL done = (data.count == 0) || (pages > 0 && got >= pages);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (s.searchGeneration != generation) return;
      [collected addObjectsFromArray:data];
      for (NSDictionary* tone in data) {
        if ([tone[@"id"] respondsToSelector:@selector(integerValue)])
          [s.searchIds addObject:@([tone[@"id"] integerValue])];
      }
      if (done) {
        [s mergeRemoteTones:collected favorite:NO];   // page1..pageN in server order
      } else {
        [s fetchSearchPage:got + 1 prefix:prefix generation:generation collected:collected];
      }
    });
  }];
}

- (void)sortChanged:(id)sender { [self refreshOnline]; }

- (void)connectTone3000:(id)sender {
  // The plugin owns its own TONE3000 session. "Connect" uses the plugin's own
  // keychain session; if it has none yet it bootstraps from NAM Rig's session
  // (refreshed + persisted to our own entry), then loads the online library.
  __weak ToneBrowserController* weakSelf = self;
  [self setAuthStatus:@"CHECKING SESSION…" color:NSColor.systemOrangeColor];

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    ToneBrowserController* strongSelf = weakSelf;
    if (!strongSelf) return;
    NSDictionary* session = pluginSession();
    BOOL fromNamRig = NO;
    if (!session) { session = namRigSession(); fromNamRig = YES; }
    NSString* access = [session[@"accessToken"] isKindOfClass:NSString.class] ? session[@"accessToken"] : nil;
    NSString* refresh = [session[@"refreshToken"] isKindOfClass:NSString.class] ? session[@"refreshToken"] : nil;
    [strongSelf logTone3000:[NSString stringWithFormat:@"CONNECT session=%@ source=%@ access=%d refresh=%d",
                             session ? @"yes" : @"no", fromNamRig ? @"namrig" : @"own",
                             (int)access.length, (int)refresh.length]];
    if (!session || !access.length) {
      // No stored session at all: go straight to a real browser login.
      dispatch_async(dispatch_get_main_queue(), ^{ [strongSelf startOAuthLogin]; });
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
      dispatch_async(dispatch_get_main_queue(), ^{ [strongSelf refreshToneSession]; });
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
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongSelf setAuthStatus:(fromNamRig ? @"Signed in via NAM Rig" : @"Signed in")
                          color:NSColor.systemGreenColor];
      [strongSelf refreshOnline];
    });
  });
}

// ---- TONE3000 OAuth login flow (authorization-code + PKCE) ----
// Binds a one-shot HTTP listener on 127.0.0.1 at an OS-chosen port, opens the
// authorize page in the default browser, waits for the redirect, exchanges the
// code for tokens, and persists the session to the plugin's keychain.
- (void)startOAuthLogin {
  if (self.oauthActive) return;
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
      kToneAPI, kNamRigPublishableKey,
      percentEncode(redirect), challenge, self.oauthState];
  [self setAuthStatus:@"Waiting for browser sign-in…" color:NSColor.systemOrangeColor];
  self.status.stringValue = @"Authorize in the browser that opened — then come back here";
  [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:authorizeURL]];
  [self logTone3000:[NSString stringWithFormat:@"OAUTH authorize opened (port %d)", self.oauthPort]];

  __weak ToneBrowserController* weakSelf = self;
  self.oauthTimer = [NSTimer scheduledTimerWithTimeInterval:180.0 repeats:NO block:^(NSTimer* t) {
    __strong ToneBrowserController* s = weakSelf; if (!s) return;
    if (s.oauthActive) {
      [s oauthCleanup];
      [s setAuthStatus:@"Sign-in timed out — click Connect to try again" color:NSColor.systemRedColor];
    }
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
      }
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
  if (![state isEqualToString:self.oauthState]) {
    [self oauthCleanup];
    [self setAuthStatus:@"Sign-in failed (state mismatch) — click Connect to try again" color:NSColor.systemRedColor];
    return;
  }
  [self setAuthStatus:@"Completing sign-in…" color:NSColor.systemOrangeColor];
  NSString* verifier = self.oauthVerifier;
  NSString* redirect = [NSString stringWithFormat:@"http://127.0.0.1:%d/callback", self.oauthPort];
  NSString* body = [NSString stringWithFormat:
      @"grant_type=authorization_code&code=%@&client_id=%@&redirect_uri=%@&code_verifier=%@",
      percentEncode(code), kNamRigPublishableKey, percentEncode(redirect), percentEncode(verifier)];
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kToneAPI stringByAppendingString:@"/oauth/token"]]];
  request.HTTPMethod = @"POST";
  request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
  [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
  __weak ToneBrowserController* weakSelf = self;
  [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                   completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    __strong ToneBrowserController* s = weakSelf; if (!s) return;
    NSInteger statusCode = [(NSHTTPURLResponse*)response statusCode];
    NSDictionary* token = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString* access = [token[@"access_token"] isKindOfClass:NSString.class] ? token[@"access_token"] : nil;
    if (statusCode == 200 && access.length) {
      NSString* refresh = [token[@"refresh_token"] isKindOfClass:NSString.class] ? token[@"refresh_token"] : @"";
      NSNumber* expMs = [token[@"expires_at"] respondsToSelector:@selector(doubleValue)]
          ? @([token[@"expires_at"] doubleValue] * 1000.0) : nil;
      if (!expMs && [token[@"expires_at_millis"] respondsToSelector:@selector(doubleValue)])
        expMs = token[@"expires_at_millis"];
      if (!expMs && [token[@"expires_in"] respondsToSelector:@selector(doubleValue)])
        expMs = @(([[NSDate date] timeIntervalSince1970] + [token[@"expires_in"] doubleValue]) * 1000.0);
      NSMutableDictionary* saved = [@{@"accessToken": access} mutableCopy];
      if (refresh.length) saved[@"refreshToken"] = refresh;
      if (expMs) saved[@"expiresAtMilliseconds"] = expMs;
      savePluginSession(saved);
      s.accessToken = access;
      s.refreshToken = refresh;
      [s oauthCleanup];
      [s logTone3000:@"OAUTH login success (session saved)"];
      [s setAuthStatus:@"Signed in" color:NSColor.systemGreenColor];
      [s refreshOnline];
    } else {
      [s oauthCleanup];
      [s logTone3000:[NSString stringWithFormat:@"OAUTH exchange failed (%ld)", (long)statusCode]];
      [s setAuthStatus:@"Sign-in failed — click Connect to try again" color:NSColor.systemRedColor];
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

// Best-effort token refresh through NAM Rig's stored session. NAM Rig usually
// refreshes on its own; this is a safety net when the local token has expired.
// On success the updated token pair is applied in memory (NAM Rig's keychain
// entry is left untouched, since NAM Rig is the session owner).
- (void)refreshToneSession {
  if (!self.refreshToken.length) return;
  NSString* clientId = kNamRigPublishableKey;
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
          || [err containsString:@"expired"] || [err containsString:@"invalid_request"]) {
        clearPluginSession();
        dispatch_async(dispatch_get_main_queue(), ^{
          strongSelf.accessToken = nil;
          strongSelf.refreshToken = nil;
          [strongSelf setAuthStatus:@"Session expired — signing you in again…" color:NSColor.systemOrangeColor];
          [strongSelf startOAuthLogin];
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
  NSString* query = self.search.stringValue.lowercaseString;
  NSString* gear = self.gear.titleOfSelectedItem;
  NSMutableArray<ToneItem*>* shown = [NSMutableArray array];
  for (ToneItem* item in self.allItems) {
    if ([self.mode isEqualToString:@"Favorites"] && !item.favorite) continue;
    if ([self.mode isEqualToString:@"Local"] && !item.local) continue;
    if ([gear isEqualToString:@"Pedals"] && item.stage != 0) continue;
    if ([gear isEqualToString:@"Amps"] && item.stage != 1) continue;
    if ([gear isEqualToString:@"Cabs"] && item.stage != 2) continue;
    if ([gear isEqualToString:@"Amp + Cab"] && item.stage != 1 && item.stage != 2) continue;
    NSString* searchable = [NSString stringWithFormat:@"%@ %@ %@", item.title, item.creator, item.gear].lowercaseString;
    if (query.length && [searchable rangeOfString:query].location == NSNotFound) continue;
    [shown addObject:item];
  }
  if ([self.mode isEqualToString:@"Recent"]) {
    [shown sortUsingComparator:^NSComparisonResult(ToneItem* a, ToneItem* b) { return [b.modified compare:a.modified]; }];
  } else if ([self.mode isEqualToString:@"Browse"]) {
    // In Browse mode the sort popup mirrors tone3000.com's ordering. Trending
    // and Best Match are server-computed (no local equivalent), so we preserve
    // the order the search API returned; the rest sort locally by real fields.
    NSString* sort = self.sort.titleOfSelectedItem;
    if (sort != nil && [sort isEqualToString:@"Oldest"]) {
      [shown sortUsingComparator:^NSComparisonResult(ToneItem* a, ToneItem* b) { return [a.createdAt compare:b.createdAt]; }];
    } else if (sort != nil && [sort isEqualToString:@"Most Downloaded"]) {
      [shown sortUsingComparator:^NSComparisonResult(ToneItem* a, ToneItem* b) {
        if (b.downloadsCount == a.downloadsCount) return NSOrderedSame;
        return b.downloadsCount > a.downloadsCount ? NSOrderedAscending : NSOrderedDescending;
      }];
    } else if (sort == nil || [sort isEqualToString:@"Newest"]) {
      [shown sortUsingComparator:^NSComparisonResult(ToneItem* a, ToneItem* b) { return [b.createdAt compare:a.createdAt]; }];
    }
    // Trending / Best Match: leave in server-returned order.
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
          strongSelf.status.stringValue = [NSString stringWithFormat:@"%lu models available — downloading first…", (unsigned long)data.count];
          [strongSelf downloadFirstModel:item];
        } else {
          strongSelf.status.stringValue = @"No downloadable models found";
        }
      });
    };
    void (^fetchA2MaybeA1)(NSArray*) = ^(NSArray *a2) {
      if (a2.count > 0) { finish(a2); }
      else { fetch(@"1", ^(NSArray *a1) { finish(a1); }); }
    };
    fetch(@"2", fetchA2MaybeA1);
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

- (void)downloadFirstModel:(ToneItem*)item {
  if (!self.accessToken.length || item.remoteModels.count == 0) return;
  NSDictionary* model = item.remoteModels.firstObject;
  NSString* urlString = [model[@"model_url"] isKindOfClass:NSString.class] ? model[@"model_url"] : nil;
  if (!urlString.length) return;
  self.status.stringValue = @"Downloading model…";
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
  [request setValue:[@"Bearer " stringByAppendingString:self.accessToken] forHTTPHeaderField:@"Authorization"];
  [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    NSInteger code = [(NSHTTPURLResponse*)response statusCode];
    if (!data.length || code < 200 || code >= 300) { [self setOnlineStatus:code == 401 ? @"Tone3000 session expired — reconnect" : @"Model download failed"]; return; }
    NSString* category = item.stage == 0 ? @"Pedal" : (item.stage == 2 ? @"Cab" : @"Amp");
    NSString* folder = [[[[[@"~/Music/Tone3000 Library" stringByExpandingTildeInPath] stringByAppendingPathComponent:category]
                         stringByAppendingPathComponent:@"NAM Oversampled Rig"] stringByAppendingPathComponent:safeFilename(item.title)] copy];
    [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* ext = [NSURL URLWithString:urlString].pathExtension.length ? [NSURL URLWithString:urlString].pathExtension : (item.stage == 2 ? @"wav" : @"nam");
    NSString* filename = [[safeFilename([model[@"name"] isKindOfClass:NSString.class] ? model[@"name"] : @"Tone3000 Model") stringByAppendingPathExtension:ext] copy];
    NSString* path = [folder stringByAppendingPathComponent:filename]; NSError* writeError = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) { [self setOnlineStatus:@"Could not save the downloaded model"]; return; }
    NSDictionary* download = @{@"model_id": model[@"id"] ?: @0, @"original_model": model,
                               @"local_filename": filename, @"status": @"downloaded",
                               @"bytes": @(data.length), @"downloaded_at": [[NSDate date] description]};
    NSDictionary* manifest = @{@"powered_by": @"Tone3000", @"tone": item.toneData ?: @{}, @"downloads": @[download]};
    NSData* json = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[folder stringByAppendingPathComponent:@"_tone3000.json"] options:NSDataWritingAtomic error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      item.models = @[path]; item.local = YES;
      self.status.stringValue = @"Downloaded and loaded";
      if (self.state) {
        self.state->sendPath((size_t)item.stage, path.fileSystemRepresentation);
        self.state->setStageThumb((size_t)item.stage, item.artworkPath, item.toneId, item.imageURL);
      }
      [self showModelsForItem:item andLoad:NO];
    });
  }] resume];
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
    NSArray<NSString*>* knobNames = @[@"GATE", @"INPUT", @"QUALITY", @"OUTPUT", @"BASS", @"MID", @"TREBLE"];
    NSArray<NSString*>* knobValues = @[@"OFF", @"+0.0 dB", @"100%", @"+0.0 dB", @"+0.0 dB", @"+0.0 dB", @"+0.0 dB"];
    const std::array<double, kRigKnobCount> defaults{-80.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0};
    const std::array<double, kRigKnobCount> mins{-80.0, -20.0, 0.0, -20.0, -12.0, -12.0, -12.0};
    const std::array<double, kRigKnobCount> maxes{0.0, 20.0, 1.0, 20.0, 12.0, 12.0, 12.0};

    // Global INPUT / QUALITY / OUTPUT strip — these are scoped to the whole
    // signal chain (not per stage), so they live in a shared footer row.
    NSStackView* knobRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
    knobRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    knobRow.distribution = NSStackViewDistributionFillEqually;
    knobRow.spacing = 22.0;
    knobRow.translatesAutoresizingMaskIntoConstraints = NO;
    [topView addSubview:knobRow];
    [[knobRow.leadingAnchor constraintEqualToAnchor:topView.leadingAnchor constant:24] setActive:YES];
    [[knobRow.trailingAnchor constraintEqualToAnchor:topView.trailingAnchor constant:-24] setActive:YES];
    [[knobRow.bottomAnchor constraintEqualToAnchor:topView.bottomAnchor constant:-16] setActive:YES];
    [[knobRow.heightAnchor constraintEqualToConstant:110] setActive:YES];

    for (NSInteger k = 0; k < (NSInteger)kRigKnobCount; ++k) {
      NSView* cell = [[NSView alloc] initWithFrame:NSZeroRect];
      [knobRow addArrangedSubview:cell];

      state->knobs[(size_t)k] = addKnob(cell, (NSInteger)kRigKnobPorts[(NSUInteger)k], defaults[(NSUInteger)k],
                                        mins[(NSUInteger)k], maxes[(NSUInteger)k],
                                        NSMakePoint(0, 0), state->uiController);
      NSSlider* knob = state->knobs[(size_t)k];
      knob.translatesAutoresizingMaskIntoConstraints = NO;
      centerX(knob, cell, 0);
      [[knob.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor constant:-4] setActive:YES];

      NSTextField* kname = addLabel(cell, knobNames[(NSUInteger)k], NSZeroRect,
                                    [NSFont boldSystemFontOfSize:10.5], rigDimText(), NSTextAlignmentCenter);
      kname.translatesAutoresizingMaskIntoConstraints = NO;
      centerX(kname, cell, 0);
      [[kname.bottomAnchor constraintEqualToAnchor:knob.topAnchor constant:-8] setActive:YES];

      state->valueLabels[(size_t)k] = addLabel(cell, knobValues[(NSUInteger)k], NSZeroRect,
        [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightRegular], rigText(), NSTextAlignmentCenter);
      NSTextField* kval = state->valueLabels[(size_t)k];
      kval.translatesAutoresizingMaskIntoConstraints = NO;
      centerX(kval, cell, 0);
      [[kval.bottomAnchor constraintEqualToAnchor:kname.topAnchor constant:-4] setActive:YES];
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
    [[boxRow.bottomAnchor constraintEqualToAnchor:knobRow.topAnchor constant:-12] setActive:YES];

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
