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

- (RigPanel*)meterPanelWithTitle:(NSString*)title meter:(RigStageMeterView*)meter
                          parent:(NSView*)parent x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h {
  RigPanel* panel = [self panelAt:parent x:x y:y w:w h:h];
  [self label:title parent:panel x:24 y:22 w:w - 48 size:19 weight:NSFontWeightSemibold color:rigText()];
  [self place:meter parent:panel x:24 y:82 w:64 h:h - 116];
  return panel;
}

- (RigPanel*)infoPanelWithTitle:(NSString*)title subtitle:(NSString*)subtitle
                         parent:(NSView*)parent x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h {
  RigPanel* panel = [self panelAt:parent x:x y:y w:w h:h];
  [self label:title parent:panel x:22 y:22 w:w - 44 size:17 weight:NSFontWeightSemibold color:rigText()];
  NSTextField* body = workspaceLabel(panel, subtitle, 11, NSFontWeightRegular, rigDimText());
  body.lineBreakMode = NSLineBreakByWordWrapping;
  body.maximumNumberOfLines = 0;
  body.frame = [self topRect:panel x:22 y:58 w:w - 44 h:h - 82];
  return panel;
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
  [self place:card parent:page x:0 y:0 w:960 h:704];
  const CGFloat imageHeight = stage == 2 ? 390 : 450;
  NSImageView* thumb = self.state->stageImages[(size_t)stage];
  deactivateViewConstraints(thumb);
  thumb.frame = [self topRect:card x:16 y:54 w:928 h:imageHeight];
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
    keys = @[@"main", @"speaker", @"cablab", @"align"];
    titles = @[@"Cabinet", @"Speaker Dynamics", @"Cabinet Blend", @"Alignment & Cuts"];
  } else {
    keys = @[@"main", @"postcomp", @"delay", @"reverb", @"spatial", @"tuner"];
    titles = @[@"Master Output", @"Compressor", @"Delay", @"Reverb", @"Spatial", @"Tuner"];
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
  RigPanel* nav = [self panelAt:page x:0 y:0 w:220 h:704];
  NSString* navTitle = stage <= 1 ? @"Input & Preamp" : (stage == 2 ? @"Amp Processing" :
      (stage == 3 ? @"Cab Processing" : @"Output & Post-FX"));
  [self label:navTitle parent:nav x:18 y:22 w:184 size:18 weight:NSFontWeightSemibold color:rigText()];
  [self addContextNavigationForPage:nav stage:stage];
  [self place:rack parent:page x:236 y:0 w:rightRack || info ? 824 : 1236 h:704];
  if (rightRack) [self place:rightRack parent:page x:1076 y:0 w:396 h:704];
  else if (info) [self infoPanelWithTitle:title subtitle:info parent:page x:1076 y:0 w:396 h:704];
  return page;
}

- (void)buildMainPages {
  // Input: level/gate controls and the input meter.
  NSView* input = [self newPageWithKey:@"main:0"];
  [self meterPanelWithTitle:@"Input" meter:self.state->stageMeters[0] parent:input x:0 y:0 w:280 h:704];
  [self knobPanelWithTitle:@"Input & Gate" group:self.knobGroups[0] parent:input x:296 y:0 w:1176 h:704 columns:3];

  // Pedal: the original model card, oversampling, and power control remain intact.
  NSView* pedal = [self newPageWithKey:@"main:1"];
  [self addStageHero:0 page:pedal];
  [self infoPanelWithTitle:@"Pedal & Preamp"
                  subtitle:@"The pedal capture stays front and center. Compressor, preamp EQ, and boost are available below only when you need them."
                    parent:pedal x:976 y:0 w:496 h:330];
  [self meterPanelWithTitle:@"Pre-Amp Input" meter:self.state->stageMeters[1] parent:pedal x:976 y:346 w:496 h:358];

  NSView* amp = [self newPageWithKey:@"main:2"];
  [self addStageHero:1 page:amp];
  [self knobPanelWithTitle:@"Tone" group:self.knobGroups[1] parent:amp x:976 y:0 w:496 h:704 columns:3];

  NSView* cab = [self newPageWithKey:@"main:3"];
  [self addStageHero:2 page:cab];
  [self infoPanelWithTitle:@"Cabinet Processing"
                  subtitle:@"Cab A/B selection and Loudness normalization remain in the cabinet card. Open Speaker Dynamics or Cabinet Blend below for the related processors."
                    parent:cab x:976 y:0 w:496 h:330];
  [self meterPanelWithTitle:@"Cabinet Input" meter:self.state->stageMeters[2] parent:cab x:976 y:346 w:496 h:358];

  NSView* output = [self newPageWithKey:@"main:4"];
  [self meterPanelWithTitle:@"Master Output" meter:self.state->stageMeters[3] parent:output x:0 y:0 w:360 h:704];
  [self knobPanelWithTitle:@"Output Level" group:self.knobGroups[2] parent:output x:376 y:0 w:1096 h:704 columns:1];
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
                        info:@"Dynamic control before the pedal and amplifier captures. The response graph and all preset actions remain live."];
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
    RigPanel* nav = [self panelAt:page x:0 y:0 w:220 h:704];
    [self label:@"Output & Post-FX" parent:nav x:18 y:22 w:184 size:18 weight:NSFontWeightSemibold color:rigText()];
    [self addContextNavigationForPage:nav stage:4];
    [self place:tuner[0] parent:page x:236 y:0 w:360 h:704];
    [self place:tuner[1] parent:page x:612 y:0 w:540 h:704];
    [self place:tuner[2] parent:page x:1168 y:0 w:304 h:704];
  }
}

- (void)buildChain {
  NSArray<NSString*>* titles = @[@"Input", @"Pedal", @"Amp", @"Cab", @"Output"];
  NSArray<NSString*>* subtitles = @[@"Preamp", @"Capture + Boost", @"Power + Iron", @"Speaker + Blend", @"Master + Post-FX"];
  const CGFloat widths[] = {250, 282, 282, 282, 280};
  CGFloat x = 24;
  for (NSInteger i = 0; i < 5; ++i) {
    RigButton* button = workspaceButton(self, [NSString stringWithFormat:@"%@  ·  %@", titles[i], subtitles[i]],
                                        self, @selector(chainClicked:));
    button.tag = i;
    button.buttonType = NSButtonTypeToggle;
    button.customTextColor = rigOrange();
    [self placeNew:button parent:self x:x y:18 w:widths[i] h:68];
    [self.chainButtons addObject:button];
    x += widths[i] + 16;
  }
}

- (void)buildContext {
  [self.contextHost.subviews.copy makeObjectsPerformSelector:@selector(removeFromSuperview)];
  RigPanel* strip = [self panelAt:self.contextHost x:0 y:0 w:1472 h:118];
  NSArray<NSString*>* titles;
  NSArray<NSString*>* keys;
  NSString* heading;
  if (self.selectedStage <= 1) {
    heading = @"INPUT & PREAMP";
    titles = @[@"Compressor", @"Preamp EQ", @"Boost"];
    keys = @[@"compressor", @"sculpt", @"boost"];
  } else if (self.selectedStage == 2) {
    heading = @"AMP PROCESSING";
    titles = @[@"Power Stage", @"Output Transformer"];
    keys = @[@"power", @"transformer"];
  } else if (self.selectedStage == 3) {
    heading = @"CAB PROCESSING";
    titles = @[@"Speaker Dynamics", @"Cabinet Blend", @"Alignment & Cuts"];
    keys = @[@"speaker", @"cablab", @"align"];
  } else {
    heading = @"OUTPUT & POST-FX";
    titles = @[@"Compressor", @"Delay", @"Reverb", @"Spatial", @"Tuner"];
    keys = @[@"postcomp", @"delay", @"reverb", @"spatial", @"tuner"];
  }
  [self label:heading parent:strip x:22 y:22 w:250 size:11 weight:NSFontWeightBold color:rigDimText()];
  [self label:@"Relevant processing, right where you need it." parent:strip x:22 y:52 w:270 size:11 weight:NSFontWeightRegular color:rigDimText()];
  const CGFloat startX = 310;
  const CGFloat gap = 14;
  const CGFloat width = (1472 - startX - 22 - gap * (titles.count - 1)) / titles.count;
  for (NSUInteger i = 0; i < titles.count; ++i) {
    RigButton* button = workspaceButton(strip, titles[i], self, @selector(moduleClicked:));
    button.accessibilityIdentifier = keys[i];
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
  for (NSInteger i = 0; i < (NSInteger)self.chainButtons.count; ++i) {
    self.chainButtons[(NSUInteger)i].state = i == stage ? NSControlStateValueOn : NSControlStateValueOff;
    self.chainButtons[(NSUInteger)i].primary = i == stage;
  }
  [self buildContext];
  [self showSelectedPage];
}

- (void)selectModule:(NSString*)key {
  if (!key.length) return;
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
  NSString* pageKey = [self.selectedModule isEqualToString:@"main"]
      ? [NSString stringWithFormat:@"main:%ld", (long)self.selectedStage]
      : ([self.selectedModule isEqualToString:@"align"] ? @"cablab" : self.selectedModule);
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
    _moduleButtons = [NSMutableArray array];
    _chainButtons = [NSMutableArray array];
    self.wantsLayer = YES;
    self.pageHost = [[NSView alloc] initWithFrame:[self topRect:self x:24 y:106 w:1472 h:704]];
    [self addSubview:self.pageHost];
    self.contextHost = [[NSView alloc] initWithFrame:[self topRect:self x:24 y:830 w:1472 h:118]];
    [self addSubview:self.contextHost];
    [self buildChain];
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
  workspace.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [rigPane addSubview:workspace];
  legacyStageRow.hidden = YES;
  legacyDeck.hidden = YES;
  for (NSView* group in knobGroups) group.hidden = YES;
  return workspace;
}
