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
constexpr std::array<const char*, 3> kPathURIs{
    "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig-pedal-model",
    "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig-amp-model",
    "http://github.com/mikeoliphant/neural-amp-modeler-lv2#rig-cab-model"};

#import "rig_theme.h"
#include "rig_knobs.h"
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
- (void)zoomChanged:(NSComboBox*)sender;
- (void)stageModelChanged:(NSPopUpButton*)sender;
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

// Per-stage oversample control (pedal/amp tiles): ports 20/21, 7 modes.
- (void)stageOversampleChanged:(NSPopUpButton*)sender {
  if (!_state) return;
  _state->sendControl((uint32_t)sender.tag, (float)sender.indexOfSelectedItem);
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
    state->atomFloat = map->map(map->handle, LV2_ATOM__Float);
    state->tunerNoteURID = map->map(map->handle, NAM_RIG_TUNER_NOTE_URI);
    state->tunerCentsURID = map->map(map->handle, NAM_RIG_TUNER_CENTS_URI);
    state->inputDbURID = map->map(map->handle, NAM_RIG_INPUT_DB_URI);
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

    // Invisible layout anchor replacing the old title/chain labels: the
    // tuner button, tuner panel, input meter and the tile row all pin to it,
    // so it keeps their exact geometry with no visible text.
    NSView* title = [[NSView alloc] initWithFrame:NSZeroRect];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [topView addSubview:title];
    [[title.leadingAnchor constraintEqualToAnchor:topView.leadingAnchor constant:24] setActive:YES];
    [[title.topAnchor constraintEqualToAnchor:topView.topAnchor constant:10] setActive:YES];
    [[title.heightAnchor constraintEqualToConstant:26] setActive:YES];
    [[title.widthAnchor constraintEqualToConstant:10] setActive:YES];

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
    state->tunerButton.translatesAutoresizingMaskIntoConstraints = NO;
    [topView addSubview:state->tunerButton];
    [[state->tunerButton.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:28] setActive:YES];
    [[state->tunerButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor] setActive:YES];
    [[state->tunerButton.widthAnchor constraintEqualToConstant:30] setActive:YES];
    [[state->tunerButton.heightAnchor constraintEqualToConstant:26] setActive:YES];

    // Tuner readout panel — hidden until the toggle is on. Note name, detune
    // in cents, and a needle meter across ±50 cents. Styled like the tiles
    // (panel bg, subtle border, accent highlights).
    NSView* tp = [[NSView alloc] initWithFrame:NSZeroRect];
    tp.wantsLayer = YES;
    tp.layer.backgroundColor = rigPanelBG().CGColor;
    tp.layer.cornerRadius = 8;
    tp.layer.borderWidth = 1.0;
    tp.layer.borderColor = rigPanelBorder().CGColor;
    tp.hidden = YES;
    tp.translatesAutoresizingMaskIntoConstraints = NO;
    [topView addSubview:tp];
    state->tunerPanel = tp;
    [[tp.leadingAnchor constraintEqualToAnchor:state->tunerButton.trailingAnchor constant:20] setActive:YES];
    [[tp.centerYAnchor constraintEqualToAnchor:title.centerYAnchor] setActive:YES];
    [[tp.widthAnchor constraintEqualToConstant:380] setActive:YES];
    [[tp.heightAnchor constraintEqualToConstant:34] setActive:YES];

    NSTextField* noteL = addLabel(tp, @"—", NSZeroRect,
                                  [NSFont monospacedDigitSystemFontOfSize:17 weight:NSFontWeightBold],
                                  rigText(), NSTextAlignmentCenter);
    noteL.translatesAutoresizingMaskIntoConstraints = NO;
    state->tunerNoteLabel = noteL;
    [[noteL.leadingAnchor constraintEqualToAnchor:tp.leadingAnchor constant:14] setActive:YES];
    [[noteL.centerYAnchor constraintEqualToAnchor:tp.centerYAnchor] setActive:YES];
    [[noteL.widthAnchor constraintEqualToConstant:58] setActive:YES];

    NSTextField* centsL = addLabel(tp, @"", NSZeroRect,
                                   [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular],
                                   rigDimText(), NSTextAlignmentCenter);
    centsL.translatesAutoresizingMaskIntoConstraints = NO;
    state->tunerCentsLabel = centsL;
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
    state->tunerNeedle = needle;
    [[needle.topAnchor constraintEqualToAnchor:meter.topAnchor constant:-3] setActive:YES];
    [[needle.bottomAnchor constraintEqualToAnchor:meter.bottomAnchor constant:3] setActive:YES];
    [[needle.widthAnchor constraintEqualToConstant:3] setActive:YES];
    // Horizontal position is set at update time as a fraction of meter width;
    // pin to leading edge with a settable constant.
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
    [topView addSubview:mp];
    [[mp.leadingAnchor constraintEqualToAnchor:tp.trailingAnchor constant:16] setActive:YES];
    [[mp.centerYAnchor constraintEqualToAnchor:title.centerYAnchor] setActive:YES];
    [[mp.widthAnchor constraintEqualToConstant:180] setActive:YES];
    [[mp.heightAnchor constraintEqualToConstant:34] setActive:YES];

    NSTextField* dbL = addLabel(mp, @"  —  dB", NSZeroRect,
                                [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium],
                                rigDimText(), NSTextAlignmentCenter);
    dbL.translatesAutoresizingMaskIntoConstraints = NO;
    state->inDbLabel = dbL;
    [[dbL.leadingAnchor constraintEqualToAnchor:mp.leadingAnchor constant:10] setActive:YES];
    [[dbL.centerYAnchor constraintEqualToAnchor:mp.centerYAnchor] setActive:YES];
    [[dbL.widthAnchor constraintEqualToConstant:56] setActive:YES];

    // Track: dark slot; the fill bar width is set at update time (-60..0 dB).
    NSView* slot = [[NSView alloc] initWithFrame:NSZeroRect];
    slot.wantsLayer = YES;
    slot.layer.backgroundColor = rigRaised().CGColor;
    slot.layer.cornerRadius = 2;
    slot.translatesAutoresizingMaskIntoConstraints = NO;
    [mp addSubview:slot];
    [[slot.leadingAnchor constraintEqualToAnchor:dbL.trailingAnchor constant:8] setActive:YES];
    [[slot.trailingAnchor constraintEqualToAnchor:mp.trailingAnchor constant:-10] setActive:YES];
    [[slot.centerYAnchor constraintEqualToAnchor:mp.centerYAnchor] setActive:YES];
    [[slot.heightAnchor constraintEqualToConstant:8] setActive:YES];

    NSView* fill = [[NSView alloc] initWithFrame:NSZeroRect];
    fill.wantsLayer = YES;
    fill.layer.backgroundColor = rigAccent().CGColor;
    fill.layer.cornerRadius = 2;
    fill.translatesAutoresizingMaskIntoConstraints = NO;
    [slot addSubview:fill];
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
      [[onBtn.widthAnchor constraintEqualToConstant:60] setActive:YES];
      [[onBtn.heightAnchor constraintEqualToConstant:26] setActive:YES];

      // Per-stage oversample dropdown (pedal + amp only — a WAV cab IR is
      // linear and cannot alias; a .nam cab follows the amp's mode). Sits
      // left of the ON button, 7 modes: None / Legacy 2x-4x-8x / True 2x-4x-8x.
      if (i < 2) {
        NSPopUpButton* so = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [so addItemsWithTitles:@[@"None", @"Legacy 2x", @"Legacy 4x", @"Legacy 8x",
                                 @"True 2x", @"True 4x", @"True 8x"]];
        so.controlSize = NSControlSizeSmall;
        so.tag = 20 + i;                 // port 20 = pedal, 21 = amp
        so.target = state->uiController;
        so.action = @selector(stageOversampleChanged:);
        so.translatesAutoresizingMaskIntoConstraints = NO;
        [header addSubview:so];
        [[so.trailingAnchor constraintEqualToAnchor:onBtn.leadingAnchor constant:-8] setActive:YES];
        [[so.centerYAnchor constraintEqualToAnchor:header.centerYAnchor] setActive:YES];
        [[so.widthAnchor constraintEqualToConstant:104] setActive:YES];
        [[so.heightAnchor constraintEqualToConstant:24] setActive:YES];
        [so selectItemAtIndex:1];        // default Legacy 2x = TTL default
        state->stageOsPopup[(size_t)i] = so;
        // Keep the stage name label clear of the popup.
        [[nmL.trailingAnchor constraintLessThanOrEqualToAnchor:so.leadingAnchor
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
  if (format == 0 && buffer && size == sizeof(float) && port >= 4 && port <= 21) {
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
    for (size_t i = 0; i < 3; ++i)
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
