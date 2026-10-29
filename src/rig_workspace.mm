#import "rig_workspace.h"
#import <QuartzCore/QuartzCore.h>

static NSTextField* workspaceLabel(NSView* parent, NSString* text, CGFloat size,
                                   NSFontWeight weight, NSColor* color) {
  NSTextField* label = [NSTextField labelWithString:text];
  label.font = [NSFont systemFontOfSize:size weight:weight];
  label.textColor = color;
  label.lineBreakMode = NSLineBreakByTruncatingTail;
  [parent addSubview:label];
  return label;
}

static RigButton* workspaceButton(NSView* parent, NSString* title, id target, SEL action) {
  RigButton* button = [[RigButton alloc] initWithFrame:NSZeroRect];
  button.title = title;
  button.target = target;
  button.action = action;
  button.bordered = NO;
  [parent addSubview:button];
  return button;
}

static void detachWorkspaceView(NSView* view) {
  if (!view) return;
  NSView* superview = view.superview;
  if ([superview isKindOfClass:NSStackView.class])
    [(NSStackView*)superview removeArrangedSubview:view];
  for (NSView* ancestor = superview; ancestor; ancestor = ancestor.superview) {
    for (NSLayoutConstraint* constraint in ancestor.constraints.copy) {
      if (constraint.firstItem == view || constraint.secondItem == view)
        constraint.active = NO;
    }
  }
  [view removeFromSuperview];
  view.translatesAutoresizingMaskIntoConstraints = YES;
}

static void deactivateViewConstraints(NSView* view) {
  for (NSView* ancestor = view.superview; ancestor; ancestor = ancestor.superview) {
    for (NSLayoutConstraint* constraint in ancestor.constraints.copy) {
      if (constraint.firstItem == view || constraint.secondItem == view)
        constraint.active = NO;
    }
  }
  view.translatesAutoresizingMaskIntoConstraints = YES;
}

@interface NAMRigWorkspace ()
@property(nonatomic, assign) RigUIState* state;
@property(nonatomic, strong) NSView* pageHost;
@property(nonatomic, strong) NSView* contextHost;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSView*>* pages;
@property(nonatomic, strong) NSMutableArray<RigButton*>* moduleButtons;
@property(nonatomic, strong) NSMutableArray<RigButton*>* chainButtons;
@property(nonatomic, strong) NSArray<NSView*>* knobGroups;
@property(nonatomic, strong) NSMutableDictionary<NSString*, RigPanel*>* moduleRacks;
@property(nonatomic, readwrite) NSInteger selectedStage;
@property(nonatomic, copy, readwrite) NSString* selectedModule;
@end

@implementation NAMRigWorkspace

- (BOOL)isFlipped { return NO; }

- (NSRect)topRect:(NSView*)parent x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h {
  return NSMakeRect(x, parent.bounds.size.height - y - h, w, h);
}

- (void)place:(NSView*)view parent:(NSView*)parent x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h {
  if (!view) return;
  detachWorkspaceView(view);
  [parent addSubview:view];
  view.frame = [self topRect:parent x:x y:y w:w h:h];
  view.hidden = NO;
}

- (void)placeNew:(NSView*)view parent:(NSView*)parent x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h {
  [parent addSubview:view];
  view.frame = [self topRect:parent x:x y:y w:w h:h];
}

- (RigPanel*)panelAt:(NSView*)parent x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h {
  RigPanel* panel = [[RigPanel alloc] initWithFrame:[self topRect:parent x:x y:y w:w h:h]];
  panel.cornerRadius = 12;
  [parent addSubview:panel];
  return panel;
}

- (void)label:(NSString*)text parent:(NSView*)parent x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w
         size:(CGFloat)size weight:(NSFontWeight)weight color:(NSColor*)color {
  NSTextField* label = workspaceLabel(parent, text, size, weight, color);
  label.frame = [self topRect:parent x:x y:y w:w h:ceil(size * 1.45)];
}

- (NSArray<NSView*>*)knobCells:(NSView*)group {
  return group.subviews.copy;
}

- (RigPanel*)knobPanelWithTitle:(NSString*)title group:(NSView*)group parent:(NSView*)parent
                              x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h columns:(NSInteger)columns {
  RigPanel* panel = [self panelAt:parent x:x y:y w:w h:h];
  [self label:title parent:panel x:24 y:22 w:w - 48 size:19 weight:NSFontWeightSemibold color:rigText()];
  [self label:@"Signal-chain controls" parent:panel x:24 y:52 w:w - 48 size:11 weight:NSFontWeightRegular color:rigDimText()];
  NSArray<NSView*>* cells = [self knobCells:group];
  const CGFloat cellW = (w - 48) / columns;
  for (NSUInteger i = 0; i < cells.count; ++i) {
    const NSInteger col = (NSInteger)i % columns;
    const NSInteger row = (NSInteger)i / columns;
    [self place:cells[i] parent:panel x:24 + col * cellW y:104 + row * 170 w:cellW h:142];
  }
  return panel;
}

// Help belongs beside the controls, rather than in a separate full-height card.
- (void)pageHeading:(NSString*)title subtitle:(NSString*)subtitle parent:(NSView*)parent
                  x:(CGFloat)x w:(CGFloat)w {
  [self label:title parent:parent x:x y:4 w:w size:19 weight:NSFontWeightSemibold color:rigText()];
  NSTextField* help = workspaceLabel(parent, subtitle ?: @"", 11, NSFontWeightRegular, rigDimText());
  help.lineBreakMode = NSLineBreakByWordWrapping;
  help.maximumNumberOfLines = 2;
  help.frame = [self topRect:parent x:x y:34 w:w h:34];
}

- (NSView*)newPageWithKey:(NSString*)key {
  NSView* page = [[NSView alloc] initWithFrame:self.pageHost.bounds];
  [self.pageHost addSubview:page];
  page.hidden = YES;
  self.pages[key] = page;
  return page;
}

- (void)addStageHero:(NSInteger)stage page:(NSView*)page {
  RigPanel* card = self.state->stageCards[(size_t)stage];
  const CGFloat cardWidth = 960;
  [self place:card parent:page x:stage == 0 ? 256 : 0 y:0 w:cardWidth h:640];
  const CGFloat imageHeight = stage == 2 ? 350 : 400;
  NSImageView* thumb = self.state->stageImages[(size_t)stage];
  deactivateViewConstraints(thumb);
  thumb.frame = [self topRect:card x:16 y:54 w:cardWidth - 32 h:imageHeight];
  RigPopUpButton* picker = self.state->modelPickers[(size_t)stage];
  deactivateViewConstraints(picker);
  const CGFloat pickerX = stage == 2 ? 35 : 16;
  const CGFloat pickerW = stage == 2 ? 815 : 898;
  picker.frame = [self topRect:card x:pickerX y:54 + imageHeight + 8 w:pickerW h:23];
  if (stage == 2) {
    RigPopUpButton* pickerB = self.state->modelPickers[3];
    deactivateViewConstraints(pickerB);
    pickerB.frame = [self topRect:card x:pickerX y:54 + imageHeight + 35 w:pickerW h:23];
  }
}

- (void)addContextNavigationForPage:(NSView*)page stage:(NSInteger)stage {
  NSArray<NSString*>* keys;
  NSArray<NSString*>* titles;
  if (stage <= 1) {
    keys = @[@"main", @"compressor", @"sculpt", @"boost"];
    titles = @[stage == 0 ? @"Input & Gate" : @"Pedal", @"Compressor", @"Preamp EQ", @"Boost"];
  } else if (stage == 2) {
    keys = @[@"main", @"power", @"transformer"];
    titles = @[@"Amplifier", @"Power Stage", @"Output Transformer"];
  } else if (stage == 3) {
    keys = @[@"main", @"speaker", @"cablab"];
    titles = @[@"Cabinet", @"Speaker Dynamics", @"Cabinet Blend"];
  } else {
    keys = @[@"main", @"postcomp", @"delay", @"reverb", @"spatial"];
    titles = @[@"Master Output", @"Compressor", @"Delay", @"Reverb", @"Spatial"];
  }
  NSMutableArray<RigButton*>* buttons = [NSMutableArray array];
  for (NSUInteger i = 0; i < keys.count; ++i) {
    RigButton* button = workspaceButton(page, titles[i], self, @selector(moduleClicked:));
    button.accessibilityIdentifier = keys[i];
    button.buttonType = NSButtonTypeToggle;
    button.customTextColor = rigOrange();
    [self placeNew:button parent:page x:18 y:92 + i * 58 w:184 h:40];
    [buttons addObject:button];
  }
  [self.moduleButtons addObjectsFromArray:buttons];
}

- (NSView*)modulePageForStage:(NSInteger)stage key:(NSString*)key title:(NSString*)title
                         rack:(RigPanel*)rack rightRack:(RigPanel*)rightRack info:(NSString*)info {
  NSView* page = [self newPageWithKey:key];
  if (stage == 2 || stage == 3) {
    [self pageHeading:title subtitle:info parent:page x:0 w:1472];
    self.moduleRacks[key] = rack;
    [self place:rack parent:page x:0 y:78 w:rightRack ? 1000 : 1472 h:598];
    if (rightRack) [self place:rightRack parent:page x:1016 y:78 w:456 h:598];
    return page;
  }
  RigPanel* nav = [self panelAt:page x:0 y:0 w:220 h:794];
  NSString* navTitle = stage <= 1 ? @"Input & Preamp" : (stage == 2 ? @"Amp Processing" :
      (stage == 3 ? @"Cab Processing" : @"Output & Post-FX"));
  [self label:navTitle parent:nav x:18 y:22 w:184 size:18 weight:NSFontWeightSemibold color:rigText()];
  [self addContextNavigationForPage:nav stage:stage];
  [self pageHeading:title subtitle:info parent:page x:236 w:1236];
  self.moduleRacks[key] = rack;
  [self place:rack parent:page x:236 y:78 w:rightRack ? 824 : 1236 h:716];
  if (rightRack) [self place:rightRack parent:page x:1076 y:78 w:396 h:716];
  return page;
}

- (void)buildMainPages {
  // Compact level controls leave room for the live processing racks below.
  NSView* input = [self newPageWithKey:@"main:0"];
  [self pageHeading:@"Input & Gate" subtitle:@"Set input gain and gate response before the preamp processors."
             parent:input x:0 w:540];
  NSArray<NSView*>* inputCells = [self knobCells:self.knobGroups[0]];
  for (NSUInteger i = 0; i < inputCells.count; ++i)
    [self place:inputCells[i] parent:input x:600 + i * 200 y:4 w:160 h:142];

  NSView* pedal = [self newPageWithKey:@"main:1"];
  [self addStageHero:0 page:pedal];

  NSView* amp = [self newPageWithKey:@"main:2"];
  [self addStageHero:1 page:amp];
  [self knobPanelWithTitle:@"Tone" group:self.knobGroups[1] parent:amp x:976 y:0 w:496 h:640 columns:3];

  NSView* cab = [self newPageWithKey:@"main:3"];
  [self addStageHero:2 page:cab];
  [self pageHeading:@"Speaker Dynamics" subtitle:@"Shape the speaker response. Cabinet Blend opens levels, alignment, and cuts."
             parent:cab x:976 w:496];

  NSView* output = [self newPageWithKey:@"main:4"];
  [self pageHeading:@"Master Output" subtitle:@"Set the final level and shape the stereo post-FX chain below."
             parent:output x:0 w:540];
  NSArray<NSView*>* outputCells = [self knobCells:self.knobGroups[2]];
  for (NSUInteger i = 0; i < outputCells.count; ++i)
    [self place:outputCells[i] parent:output x:600 + i * 160 y:4 w:160 h:142];
}

// Reuse the same controls on overview and detail pages, preserving all bindings
// and preset menus. Only their parent and frame change when navigating.
- (void)mountOverviewRacksForStage:(NSInteger)stage {
  NSArray<NSString*>* keys = stage == 0 ? @[@"compressor", @"sculpt", @"boost"] :
      (stage == 4 ? @[@"postcomp", @"delay", @"reverb", @"spatial"] :
      (stage == 3 ? @[@"speaker"] : @[]));
  if (!keys.count) return;
  NSView* page = self.pages[[NSString stringWithFormat:@"main:%ld", (long)stage]];
  const BOOL besideHero = stage == 3;
  const CGFloat width = besideHero ? 496 : (1472 - 16 * (keys.count - 1)) / MAX((NSUInteger)1, keys.count);
  for (NSUInteger i = 0; i < keys.count; ++i) {
    RigPanel* rack = self.moduleRacks[keys[i]];
    [self place:rack parent:page x:besideHero ? 976 : i * (width + 16)
              y:besideHero ? 78 : 164 w:width h:besideHero ? 562 : 630];
  }
}

- (NSArray<RigPanel*>*)racksForPane:(NSInteger)pane {
  if (pane < 0 || pane >= (NSInteger)self.state->deckTabPanes.count) return @[];
  NSView* view = self.state->deckTabPanes[(NSUInteger)pane];
  for (NSView* child in view.subviews) {
    if ([child isKindOfClass:NSStackView.class]) return [(NSStackView*)child arrangedSubviews];
  }
  return @[];
}

- (void)buildModulePages {
  NSArray<RigPanel*>* pre = [self racksForPane:1];
  NSArray<RigPanel*>* power = [self racksForPane:2];
  NSArray<RigPanel*>* cab = [self racksForPane:3];
  NSArray<RigPanel*>* post = [self racksForPane:4];
  NSArray<RigPanel*>* tuner = [self racksForPane:0];
  if (pre.count == 3) {
    [self modulePageForStage:0 key:@"compressor" title:@"Preamp Compressor" rack:pre[0] rightRack:nil
                        info:@"Dynamic control before the pedal and amplifier captures. Use the response graph to check transient shaping."];
    [self modulePageForStage:0 key:@"sculpt" title:@"Preamp EQ" rack:pre[1] rightRack:nil
                        info:@"Bright, input EQ, mid push, and the complete parametric Pin EQ editor."];
    [self modulePageForStage:0 key:@"boost" title:@"Preamp Boost" rack:pre[2] rightRack:nil
                        info:@"Clean boost or diode overdrive with tightness, tone, level, and voicing controls."];
  }
  if (power.count == 3) {
    [self modulePageForStage:2 key:@"power" title:@"Power Stage" rack:power[0] rightRack:power[1] info:nil];
    [self modulePageForStage:2 key:@"transformer" title:@"Output Transformer" rack:power[2] rightRack:nil
                        info:@"Transformer profile, core behavior, voicing, passband filters, and advanced adjustment controls."];
  }
  if (cab.count == 2) {
    [self modulePageForStage:3 key:@"speaker" title:@"Speaker Dynamics" rack:cab[0] rightRack:nil
                        info:@"Speaker profile, cone drive, compression, thump, resonance, and reactive-load response."];
    [self modulePageForStage:3 key:@"cablab" title:@"Cabinet Blend" rack:cab[1] rightRack:nil
                        info:@"Cab A/B levels, phase alignment, polarity, and low/high cuts. Cabinet model and Loudness dropdowns remain on the main Cabinet page."];
  }
  if (post.count == 4) {
    [self modulePageForStage:4 key:@"postcomp" title:@"Stereo Compressor" rack:post[0] rightRack:nil
                        info:@"Linked stereo compression after the cabinet blend and before delay and reverb."];
    [self modulePageForStage:4 key:@"delay" title:@"Stereo Tape Delay" rack:post[1] rightRack:nil
                        info:@"Ping-pong echoes with feedback, damping, mix, and all delay presets."];
    [self modulePageForStage:4 key:@"reverb" title:@"Studio Plate Reverb" rack:post[2] rightRack:nil
                        info:@"Plate decay, size, damping, pre-delay, and mix controls."];
    [self modulePageForStage:4 key:@"spatial" title:@"Spatial Acoustics" rack:post[3] rightRack:nil
                        info:@"Stereo cabinet spread and early room reflections with mono-safe phase."];
  }
  if (tuner.count == 3) {
    NSView* page = [self newPageWithKey:@"tuner"];
    [self place:tuner[0] parent:page x:0 y:0 w:360 h:794];
    [self place:tuner[1] parent:page x:376 y:0 w:640 h:794];
    [self place:tuner[2] parent:page x:1032 y:0 w:440 h:794];
  }
}

- (void)buildMeters {
  for (NSUInteger i = 0; i < self.state->stageMeters.size(); ++i) {
    RigStageMeterView* meter = self.state->stageMeters[i];
    meter.horizontal = YES;
    [self place:meter parent:self x:24 + i * 372 y:96 w:356 h:42];
  }
}

- (void)buildChain {
  NSArray<NSString*>* titles = @[@"Input", @"Pedal", @"Amp", @"Cab", @"Output"];
  RigButton* tuner = workspaceButton(self, @"Tuner", self, @selector(moduleClicked:));
  tuner.accessibilityIdentifier = @"tuner";
  tuner.buttonType = NSButtonTypeToggle;
  tuner.customTextColor = rigOrange();
  [self placeNew:tuner parent:self x:24 y:48 w:152 h:38];
  [self.moduleButtons addObject:tuner];
  const CGFloat widths[] = {248, 248, 248, 248, 248};
  CGFloat x = 192;
  for (NSInteger i = 0; i < 5; ++i) {
    RigButton* button = workspaceButton(self, titles[i],
                                        self, @selector(chainClicked:));
    button.tag = i;
    button.buttonType = NSButtonTypeToggle;
    button.customTextColor = rigOrange();
    [self placeNew:button parent:self x:x y:48 w:widths[i] h:38];
    [self.chainButtons addObject:button];
    x += widths[i] + 16;
  }
}

- (void)buildContext {
  [self.contextHost.subviews.copy makeObjectsPerformSelector:@selector(removeFromSuperview)];
  // Overview controls and detail-page navigation already provide these actions.
  self.contextHost.hidden = self.selectedStage <= 1 || self.selectedStage == 4 ||
      [self.selectedModule isEqualToString:@"tuner"];
  if (self.contextHost.hidden) return;
  RigPanel* strip = [self panelAt:self.contextHost x:0 y:0 w:1472 h:118];
  NSArray<NSString*>* titles;
  NSArray<NSString*>* keys;
  NSString* heading;
  if (self.selectedStage == 2) {
    heading = @"AMP PROCESSING";
    titles = @[@"Amplifier", @"Power Stage", @"Output Transformer"];
    keys = @[@"main", @"power", @"transformer"];
  } else {
    heading = @"CAB PROCESSING";
    titles = @[@"Cabinet", @"Speaker Dynamics", @"Cabinet Blend"];
    keys = @[@"main", @"speaker", @"cablab"];
  }
  [self label:heading parent:strip x:22 y:22 w:250 size:11 weight:NSFontWeightBold color:rigDimText()];
  [self label:@"Relevant processing, right where you need it." parent:strip x:22 y:52 w:270 size:11 weight:NSFontWeightRegular color:rigDimText()];
  const CGFloat startX = 310;
  const CGFloat gap = 14;
  const CGFloat width = (1472 - startX - 22 - gap * (titles.count - 1)) / titles.count;
  for (NSUInteger i = 0; i < titles.count; ++i) {
    RigButton* button = workspaceButton(strip, titles[i], self, @selector(moduleClicked:));
    button.accessibilityIdentifier = keys[i];
    button.buttonType = NSButtonTypeToggle;
    button.primary = [keys[i] isEqualToString:self.selectedModule];
    button.state = button.primary ? NSControlStateValueOn : NSControlStateValueOff;
    [self placeNew:button parent:strip x:startX + i * (width + gap) y:26 w:width h:66];
  }
}

- (void)chainClicked:(RigButton*)sender {
  [self selectStage:sender.tag];
}

- (void)moduleClicked:(RigButton*)sender {
  [self selectModule:sender.accessibilityIdentifier];
}

- (void)selectStage:(NSInteger)stage {
  if (stage < 0 || stage > 4) return;
  if (!self.state->syncingWorkspaceNavigation && [self.selectedModule isEqualToString:@"tuner"]) {
    self.state->syncingWorkspaceNavigation = true;
    self.state->selectDeckTab(1);
    self.state->syncingWorkspaceNavigation = false;
  }
  self.selectedStage = stage;
  self.selectedModule = @"main";
  [self showSelectedPage];
}

- (void)selectModule:(NSString*)key {
  if (!key.length) return;
  // Keep old navigation requests working without a second visible entry.
  if ([key isEqualToString:@"align"]) key = @"cablab";
  if ([key isEqualToString:@"main"]) {
    [self selectStage:self.selectedStage];
    return;
  }
  if (!self.state->syncingWorkspaceNavigation) {
    if ([key isEqualToString:@"tuner"] && self.state->activeDeckTab != 0) {
      self.state->syncingWorkspaceNavigation = true;
      self.state->selectDeckTab(0);
      self.state->syncingWorkspaceNavigation = false;
    } else if (![key isEqualToString:@"tuner"] && [self.selectedModule isEqualToString:@"tuner"]) {
      self.state->syncingWorkspaceNavigation = true;
      self.state->selectDeckTab(1);
      self.state->syncingWorkspaceNavigation = false;
    }
  }
  self.selectedModule = key;
  [self showSelectedPage];
}

- (void)showSelectedPage {
  const BOOL tuning = [self.selectedModule isEqualToString:@"tuner"];
  for (RigButton* button in self.chainButtons) {
    BOOL selected = !tuning && button.tag == self.selectedStage;
    button.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
    button.primary = selected;
  }
  [self buildContext];
  if ([self.selectedModule isEqualToString:@"main"]) {
    [self mountOverviewRacksForStage:self.selectedStage];
  } else {
    NSString* key = self.selectedModule;
    RigPanel* rack = self.moduleRacks[key];
    if (rack) {
      BOOL bottomNavigation = self.selectedStage == 2 || self.selectedStage == 3;
      [self place:rack parent:self.pages[key] x:bottomNavigation ? 0 : 236 y:78
                 w:bottomNavigation ? ([key isEqualToString:@"power"] ? 1000 : 1472)
                                    : ([key isEqualToString:@"power"] ? 824 : 1236)
                 h:bottomNavigation ? 598 : 716];
    }
  }
  NSString* pageKey = [self.selectedModule isEqualToString:@"main"]
      ? [NSString stringWithFormat:@"main:%ld", (long)self.selectedStage]
      : self.selectedModule;
  for (NSString* key in self.pages) self.pages[key].hidden = ![key isEqualToString:pageKey];
  for (RigButton* button in self.moduleButtons) {
    NSString* key = button.accessibilityIdentifier;
    BOOL selected = [key isEqualToString:self.selectedModule];
    button.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
    button.primary = selected;
  }
}

- (instancetype)initWithState:(RigUIState*)state frame:(NSRect)frame knobGroups:(NSArray<NSView*>*)groups {
  if ((self = [super initWithFrame:frame])) {
    _state = state;
    _knobGroups = groups;
    _pages = [NSMutableDictionary dictionary];
    _moduleRacks = [NSMutableDictionary dictionary];
    _moduleButtons = [NSMutableArray array];
    _chainButtons = [NSMutableArray array];
    self.wantsLayer = YES;
    self.pageHost = [[NSView alloc] initWithFrame:[self topRect:self x:24 y:154 w:1472 h:794]];
    [self addSubview:self.pageHost];
    self.contextHost = [[NSView alloc] initWithFrame:[self topRect:self x:24 y:830 w:1472 h:118]];
    [self addSubview:self.contextHost];
    [self buildChain];
    [self buildMeters];
    [self buildMainPages];
    [self buildModulePages];
    [self selectStage:2];
  }
  return self;
}

@end

NAMRigWorkspace* rigCreateWorkspace(RigUIState* state,
                                    NSView* rigPane,
                                    NSView* legacyStageRow,
                                    NSView* legacyDeck,
                                    NSArray<NSView*>* knobGroups) {
  NAMRigWorkspace* workspace = [[NAMRigWorkspace alloc] initWithState:state
                                                                frame:NSMakeRect(0, 0, 1520, 980)
                                                           knobGroups:knobGroups];
  // Match the fixed design canvas; the root view scales the entire UI for zoom.
  workspace.autoresizingMask = NSViewNotSizable;
  [rigPane addSubview:workspace];
  legacyStageRow.hidden = YES;
  legacyDeck.hidden = YES;
  for (NSView* group in knobGroups) group.hidden = YES;
  return workspace;
}
