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

// Only the card header starts an internal drag; model controls remain clickable.
static BOOL isPedalModelURL(NSURL* url) {
  return [@[@"nam", @"nammodel", @"aidax", @"aidadspmodel"] containsObject:url.pathExtension.lowercaseString];
}
static NSString* const pedalDragType = @"com.axefx.pedal-slot";
@interface RigPedalCard : RigPanel <NSDraggingSource>
@property(nonatomic) NSInteger slot;
@property(nonatomic, copy) void (^moveSlot)(NSInteger, NSInteger);
@property(nonatomic, copy) void (^loadFile)(NSURL*);
@end
@implementation RigPedalCard
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame]))
    [self registerForDraggedTypes:@[pedalDragType, NSPasteboardTypeFileURL]];
  return self;
}
- (NSView*)hitTest:(NSPoint)point {
  NSView* hit = [super hitTest:point];
  NSPoint local = [self convertPoint:point fromView:self.superview];
  if (hit && local.y >= self.bounds.size.height - 52 && ![hit isKindOfClass:NSButton.class]) return self;
  return hit;
}
- (void)mouseDragged:(NSEvent*)event {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  if (point.y < self.bounds.size.height - 52) return;
  NSPasteboardItem* item = [NSPasteboardItem new];
  [item setString:[NSString stringWithFormat:@"%ld", (long)self.slot] forType:pedalDragType];
  NSDraggingItem* drag = [[NSDraggingItem alloc] initWithPasteboardWriter:item];
  NSImage* image = [NSImage imageWithSystemSymbolName:@"rectangle.3.group" accessibilityDescription:@"Pedal"];
  [drag setDraggingFrame:NSMakeRect(point.x, point.y, 80, 48) contents:image];
  [self beginDraggingSessionWithItems:@[drag] event:event source:self];
}
- (NSDragOperation)draggingSession:(NSDraggingSession*)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
  return context == NSDraggingContextWithinApplication ? NSDragOperationMove : NSDragOperationNone;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  if ([sender.draggingSource isKindOfClass:RigPedalCard.class] &&
      [(RigPedalCard*)sender.draggingSource superview] == self.superview)
    return NSDragOperationMove;
  NSURL* url = [NSURL URLFromPasteboard:sender.draggingPasteboard];
  return isPedalModelURL(url) ? NSDragOperationCopy : NSDragOperationNone;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  if ([self draggingEntered:sender] == NSDragOperationMove) {
    if (self.moveSlot) self.moveSlot([(RigPedalCard*)sender.draggingSource slot], self.slot);
    return YES;
  }
  NSURL* url = [NSURL URLFromPasteboard:sender.draggingPasteboard];
  if (isPedalModelURL(url) && self.loadFile) {
    self.loadFile(url); return YES;
  }
  return NO;
}
@end

// Native slider tracking and accessibility, with a short metal lever cap.
@interface RigGraphicEQSliderCell : NSSliderCell
@end
@implementation RigGraphicEQSliderCell
- (NSRect)knobRectFlipped:(BOOL)flipped {
  const NSRect bounds = self.controlView.bounds;
  const CGFloat t = (self.doubleValue - self.minValue) / (self.maxValue - self.minValue);
  const CGFloat y = 7 + (flipped ? 1 - t : t) * (bounds.size.height - 14);
  return NSMakeRect(NSMidX(bounds) - 15, y - 6, 30, 12);
}
- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped {
  const NSRect bounds = self.controlView.bounds;
  NSRect track = NSMakeRect(NSMidX(bounds) - 3, 7, 6, bounds.size.height - 14);
  [[NSColor colorWithWhite:0.025 alpha:1] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:track xRadius:3 yRadius:3] fill];
  for (int i = 0; i <= 6; ++i) {
    CGFloat y = 7 + i * (bounds.size.height - 14) / 6;
    [[rigDimText() colorWithAlphaComponent:i == 3 ? 0.75 : 0.35] setStroke];
    NSBezierPath* tick = [NSBezierPath bezierPath];
    [tick moveToPoint:NSMakePoint(NSMidX(bounds) - 12, y)];
    [tick lineToPoint:NSMakePoint(NSMidX(bounds) + 12, y)]; [tick stroke];
  }
}
- (void)drawKnob:(NSRect)rect {
  NSBezierPath* cap = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 0.5, 0.5) xRadius:2 yRadius:2];
  NSGradient* metal = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:0.86 alpha:1]
      endingColor:[NSColor colorWithWhite:0.38 alpha:1]];
  [metal drawInBezierPath:cap angle:270];
  [[NSColor colorWithWhite:0.12 alpha:1] setStroke]; cap.lineWidth = 1; [cap stroke];
  [rigOrange() setFill];
  NSRectFill(NSMakeRect(NSMinX(rect) + 3, NSMidY(rect) - 1, rect.size.width - 6, 2));
}
@end

@interface NAMRigWorkspace ()
@property(nonatomic, assign) RigUIState* state;
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, RigPedalCard*>* pedalCards;
@property(nonatomic, strong) NSView* pageHost;
@property(nonatomic, strong) NSView* contextHost;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSView*>* pages;
@property(nonatomic, strong) NSMutableArray<RigButton*>* moduleButtons;
@property(nonatomic, strong) NSMutableArray<RigButton*>* chainButtons;
@property(nonatomic, strong) NSArray<NSView*>* knobGroups;
@property(nonatomic, strong) NSMutableDictionary<NSString*, RigPanel*>* moduleRacks;
@property(nonatomic, strong) RigPanel* powerTubeRack;
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

- (void)toneEqLeverChanged:(NSSlider*)sender {
  const uint32_t port = (uint32_t)sender.tag;
  self.state->sendControl(port, sender.floatValue);
  self.state->updateControl(port, sender.floatValue);
  self.state->markModified();
}

- (void)toneEqModeChanged:(NSSegmentedControl*)sender {
  self.state->showToneEqView(sender.selectedSegment == 1);
}

- (RigPanel*)knobPanelWithTitle:(NSString*)title group:(NSView*)group parent:(NSView*)parent
                              x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h columns:(NSInteger)columns {
  RigPanel* panel = [self panelAt:parent x:x y:y w:w h:h];
  [self label:title parent:panel x:24 y:18 w:w - 48 size:18 weight:NSFontWeightSemibold color:rigText()];
  [self label:@"Amp drive, power voicing, and switchable post-stack EQ."
       parent:panel x:24 y:44 w:w - 48 size:11 weight:NSFontWeightRegular color:rigDimText()];

  RigPanel* driveCard = [self panelAt:panel x:20 y:76 w:w - 40 h:294];
  driveCard.cornerRadius = 10;
  [self label:@"AMP DRIVE & POWER VOICING" parent:driveCard x:20 y:16 w:w - 80 size:11 weight:NSFontWeightBold color:rigOrange()];
  [self label:@"Drive feeds the amp; Presence adds bite; Depth adds thump."
       parent:driveCard x:20 y:36 w:w - 80 size:10.5 weight:NSFontWeightRegular color:rigDimText()];

  RigPanel* eqCard = [self panelAt:panel x:20 y:388 w:w - 40 h:294];
  eqCard.cornerRadius = 10;
  [self label:@"POST-STACK EQ" parent:eqCard x:20 y:16 w:150 size:11 weight:NSFontWeightBold color:rigAccent()];
  NSSegmentedControl* mode = [NSSegmentedControl segmentedControlWithLabels:@[@"3-Band", @"7-Band"]
      trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(toneEqModeChanged:)];
  mode.segmentStyle = NSSegmentStyleRounded;
  mode.toolTip = @"Two linked views of the same tone. Knob edits update the levers; lever edits update approximate knob values. Switching views preserves the sound.";
  [self placeNew:mode parent:eqCard x:w - 238 y:10 w:178 h:26];
  self.state->toneEqModeSwitch = mode;

  NSView* knobView = [[NSView alloc] initWithFrame:eqCard.bounds];
  [eqCard addSubview:knobView positioned:NSWindowBelow relativeTo:mode];
  self.state->toneEqKnobView = knobView;
  [self label:@"Shelving and midrange bell filters for final tone balance."
       parent:knobView x:20 y:40 w:w - 80 size:10.5 weight:NSFontWeightRegular color:rigDimText()];
  NSView* graphView = [[NSView alloc] initWithFrame:[self topRect:eqCard x:14 y:44 w:w - 68 h:236]];
  [eqCard addSubview:graphView];
  self.state->toneEqGraphView = graphView;
  [self label:@"GRAPHIC EQ · Boost / cut ±18 dB"
       parent:graphView x:6 y:0 w:w - 80 size:10 weight:NSFontWeightRegular color:rigDimText()];
  const CGFloat leverW = (graphView.bounds.size.width - 28) / NAMRig::kToneEqBandCount;
  for (size_t band = 0; band < NAMRig::kToneEqBandCount; ++band) {
    const CGFloat x = 14 + band * leverW;
    const float hz = NAMRig::kToneEqFreqDefaults[band];
    NSString* frequency = hz >= 1000 ? [NSString stringWithFormat:@"%.1fk", hz / 1000] : [NSString stringWithFormat:@"%.0f", hz];
    NSTextField* label = workspaceLabel(graphView, frequency, 10, NSFontWeightBold, rigText());
    label.alignment = NSTextAlignmentCenter;
    label.frame = [self topRect:graphView x:x y:24 w:leverW h:16];
    NSSlider* lever = [[NSSlider alloc] initWithFrame:[self topRect:graphView x:x + (leverW - 36) / 2 y:45 w:36 h:158]];
    lever.cell = [[RigGraphicEQSliderCell alloc] init];
    lever.minValue = -NAMRig::kPinGainMax; lever.maxValue = NAMRig::kPinGainMax;
    lever.continuous = YES;
    lever.tag = NAMRig::toneEqPort(band, NAMRig::kPinGain);
    lever.target = self; lever.action = @selector(toneEqLeverChanged:);
    lever.toolTip = [NSString stringWithFormat:@"%@ Hz: boost / cut ±18 dB. Center is flat.", frequency];
    [lever setAccessibilityLabel:[NSString stringWithFormat:@"Graphic EQ %@ Hz", frequency]];
    [graphView addSubview:lever];
    self.state->toneEqLevers[band] = lever;
    NSTextField* value = workspaceLabel(graphView, @"0.0", 10, NSFontWeightMedium, rigDimText());
    value.alignment = NSTextAlignmentCenter;
    value.frame = [self topRect:graphView x:x y:211 w:leverW h:16];
    self.state->toneEqLeverValues[band] = value;
  }
  for (uint32_t port = NAMRig::kToneEqModePort;
       port < NAMRig::kToneEqModePort + NAMRig::kToneEqControlCount; ++port)
    self.state->updateControl(port, self.state->toneEqControls[port - NAMRig::kToneEqModePort]);
  self.state->showToneEqView(self.state->toneEqShowsGraphic);

  NSArray<NSView*>* cells = [self knobCells:group];
  const CGFloat subW = w - 40;
  const CGFloat cellW = (subW - 36) / columns;
  NSArray<NSString*>* row0Tags = @[@"PRE-AMP GAIN", @"UPPER-MID BITE", @"SUB RESONANCE"];
  NSArray<NSString*>* row1Tags = @[@"150 Hz SHELF", @"700 Hz BELL", @"3.0 kHz SHELF"];
  for (NSUInteger i = 0; i < cells.count; ++i) {
    const NSInteger col = (NSInteger)i % columns;
    const NSInteger row = (NSInteger)i / columns;
    NSView* hostCard = (row == 0) ? driveCard : knobView;
    [self place:cells[i] parent:hostCard x:18 + col * cellW y:82 w:cellW h:128];
    NSString* tagText = (row == 0 && col < (NSInteger)row0Tags.count) ? row0Tags[(NSUInteger)col]
                      : (row == 1 && col < (NSInteger)row1Tags.count) ? row1Tags[(NSUInteger)col] : @"";
    if (tagText.length) {
      NSTextField* tag = workspaceLabel(hostCard, tagText, 9.5, NSFontWeightBold, rigDimText());
      tag.alignment = NSTextAlignmentCenter;
      tag.frame = [self topRect:hostCard x:18 + col * cellW y:244 w:cellW h:16];
    }
  }
  return panel;
}

// Help belongs beside the controls, rather than in a separate full-height card.
- (void)pageHeading:(NSString*)title subtitle:(NSString*)subtitle parent:(NSView*)parent
                  x:(CGFloat)x w:(CGFloat)w {
  [self label:title parent:parent x:x y:2 w:w size:18 weight:NSFontWeightSemibold color:rigText()];
  if (subtitle.length) {
    NSTextField* help = workspaceLabel(parent, subtitle, 11, NSFontWeightRegular, rigDimText());
    help.lineBreakMode = NSLineBreakByTruncatingTail;
    help.maximumNumberOfLines = 1;
    help.frame = [self topRect:parent x:x y:26 w:w h:18];
  }
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
  const CGFloat cardWidth = (stage == 2) ? 728 : 960;
  const CGFloat cardHeight = 702;
  [self place:card parent:page x:stage == 0 ? 256 : 0 y:0 w:cardWidth h:cardHeight];
  NSImageView* thumb = self.state->stageImages[(size_t)stage];
  const CGFloat imageHeight = cardHeight - 101;
  for (NSLayoutConstraint* c in thumb.constraints) {
    if (c.firstItem == thumb && c.firstAttribute == NSLayoutAttributeHeight)
      c.constant = imageHeight;
  }
  for (NSLayoutConstraint* c in card.constraints) {
    if (c.firstItem == thumb && c.firstAttribute == NSLayoutAttributeHeight)
      c.constant = imageHeight;
  }
  [card layoutSubtreeIfNeeded];
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
    [self placeNew:button parent:page x:18 y:68 + i * 52 w:184 h:40];
    [buttons addObject:button];
  }
  [self.moduleButtons addObjectsFromArray:buttons];

  const CGFloat cardY = 68 + keys.count * 52 + 12;
  const CGFloat cardH = 794 - cardY - 16;
  if (cardH >= 200) {
    RigPanel* flowCard = [self panelAt:page x:14 y:cardY w:192 h:cardH];
    flowCard.cornerRadius = 8;
    [self label:@"STAGE SIGNAL PATH" parent:flowCard x:14 y:14 w:164 size:10 weight:NSFontWeightBold color:rigOrange()];
    NSArray<NSString*>* steps = stage <= 1
        ? @[@"1. Input Trim & Noise Gate",
            @"2. Preamp Studio Compressor",
            @"3. Preamp Sculpt & Pin EQ",
            @"4. Clean Boost / Overdrive",
            @"5. Into Pedalboard & Amp"]
        : @[@"1. Stereo Bus Compressor",
            @"2. Ping-Pong Tape Delay",
            @"3. Studio Plate Reverb",
            @"4. Spatial Room & Width",
            @"5. Master Stereo Output"];
    for (NSUInteger s = 0; s < steps.count; ++s) {
      [self label:steps[s] parent:flowCard x:14 y:42 + s * 32 w:164 size:10.5 weight:NSFontWeightMedium color:rigDimText()];
    }
    NSTextField* tip = workspaceLabel(flowCard,
        @"Tip: Drag response graph pins directly or double-click any pin/knob to reset to default.",
        10, NSFontWeightRegular, rigDimText());
    tip.lineBreakMode = NSLineBreakByWordWrapping;
    tip.maximumNumberOfLines = 4;
    tip.frame = [self topRect:flowCard x:14 y:214 w:164 h:64];
  }
}

- (NSView*)modulePageForStage:(NSInteger)stage key:(NSString*)key title:(NSString*)title
                         rack:(RigPanel*)rack rightRack:(RigPanel*)rightRack info:(NSString*)info {
  NSView* page = [self newPageWithKey:key];
  if (stage == 2 || stage == 3) {
    [self pageHeading:title subtitle:info ?: @"Interactive response curves and studio hardware voicing." parent:page x:0 w:1472];
    self.moduleRacks[key] = rack;
    [self place:rack parent:page x:0 y:48 w:rightRack ? 888 : 1472 h:654];
    if (rightRack) [self place:rightRack parent:page x:904 y:48 w:568 h:654];
    return page;
  }
  RigPanel* nav = [self panelAt:page x:0 y:0 w:220 h:794];
  NSString* navTitle = stage <= 1 ? @"Input & Preamp" : (stage == 2 ? @"Amp Processing" :
      (stage == 3 ? @"Cab Processing" : @"Output & Post-FX"));
  [self label:navTitle parent:nav x:18 y:20 w:184 size:18 weight:NSFontWeightSemibold color:rigText()];
  [self addContextNavigationForPage:nav stage:stage];
  [self pageHeading:title subtitle:info parent:page x:236 w:1236];
  self.moduleRacks[key] = rack;
  [self place:rack parent:page x:236 y:48 w:rightRack ? 824 : 1236 h:746];
  if (rightRack) [self place:rightRack parent:page x:1076 y:48 w:396 h:746];
  return page;
}

- (void)pedalChanged {
  if ([(id)self.state->uiController respondsToSelector:@selector(markPresetModified)])
    [(id)self.state->uiController performSelector:@selector(markPresetModified)];
}
- (void)loadPedalURL:(NSURL*)url slot:(NSInteger)slot {
  if (!isPedalModelURL(url) ||
      ![[NSFileManager defaultManager] fileExistsAtPath:url.path]) return;
  self.state->setStageModels(slot, @[url.path]);
  self.state->sendPath(slot, url.fileSystemRepresentation);
  self.state->updateThumbnailForStagePath(slot, url.path);
  [self pedalChanged];
}
- (void)choosePedal:(NSButton*)sender {
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.allowedFileTypes = @[@"nam", @"nammodel", @"aidax", @"aidadspmodel"];
  panel.allowsMultipleSelection = NO;
  if ([panel runModal] == NSModalResponseOK) [self loadPedalURL:panel.URL slot:sender.tag];
}
- (void)clearPedal:(NSButton*)sender {
  self.state->sendPath(sender.tag, "");
  self.state->updateThumbnailForStagePath(sender.tag, nil);
  [self pedalChanged];
}
- (void)togglePedal:(NSButton*)sender {
  const uint32_t port = sender.tag == 0 ? 7 : (uint32_t)(192 + sender.tag - 4);
  const float value = sender.state == NSControlStateValueOn ? 1 : 0;
  self.state->sendControl(port, value);
  self.state->updateControl(port, value);
  [self pedalChanged];
}
- (void)movePedal:(NSInteger)source to:(NSInteger)destination {
  if (source == destination) return;
  static const NSInteger orders[6][3] = {{0,4,5},{0,5,4},{4,0,5},{4,5,0},{5,0,4},{5,4,0}};
  NSMutableArray<NSNumber*>* order = [NSMutableArray array];
  for (NSInteger slot : orders[self.state->pedalOrder]) [order addObject:@(slot)];
  NSUInteger target = [order indexOfObject:@(destination)];
  [order removeObject:@(source)];
  [order insertObject:@(source) atIndex:target];
  for (int i = 0; i < 6; ++i) {
    if (order[0].integerValue == orders[i][0] && order[1].integerValue == orders[i][1]) {
      self.state->sendControl(NAMRig::kPedalOrderPort, i);
      self.state->updateControl(NAMRig::kPedalOrderPort, i);
      [self pedalChanged]; break;
    }
  }
}
- (void)refreshPedalBoard {
  static const NSInteger orders[6][3] = {{0,4,5},{0,5,4},{4,0,5},{4,5,0},{5,0,4},{5,4,0}};
  for (int position = 0; position < 3; ++position) {
    NSInteger slot = orders[self.state->pedalOrder][position];
    RigPedalCard* card = self.pedalCards[@(slot)];
    NSRect frame = card.frame; frame.origin.x = position * 496; card.frame = frame;
    if (slot >= 4) {
      NSButton* power = self.state->powerButtons[slot];
      power.state = self.state->extraPedalEnabled[slot - 4] >= 0.5f;
      power.title = power.state ? @"ON" : @"OFF";
    }
  }
}
- (void)buildPedalBoard:(NSView*)page {
  self.pedalCards = [NSMutableDictionary dictionary];
  [self pageHeading:@"Pedalboard" subtitle:@"Signal flows left to right into the amp. Drag a card header to reorder. Drop a .nam file onto a card to load it."
             parent:page x:0 w:1020];
  [self label:@"Pedal quality (all three slots)" parent:page x:1048 y:12 w:220 size:13 weight:NSFontWeightMedium color:rigDimText()];
  [self place:self.state->stageOsPopup[0] parent:page x:1276 y:8 w:196 h:28];
  __weak NAMRigWorkspace* weakSelf = self;
  for (NSInteger slot : {0, 4, 5}) {
    RigPedalCard* card = [[RigPedalCard alloc] initWithFrame:[self topRect:page x:0 y:52 w:480 h:742]];
    card.slot = slot; card.cornerRadius = 12;
    card.moveSlot = ^(NSInteger from, NSInteger to) { [weakSelf movePedal:from to:to]; };
    card.loadFile = ^(NSURL* url) { [weakSelf loadPedalURL:url slot:slot]; };
    [page addSubview:card]; self.pedalCards[@(slot)] = card;
    if (slot == 0) self.state->stageCards[0] = card;
    [self label:[NSString stringWithFormat:@"⠿  PEDAL %ld", (long)(slot == 0 ? 1 : slot - 2)] parent:card
               x:20 y:16 w:140 size:18 weight:NSFontWeightSemibold color:rigText()];
    NSTextField* badge = workspaceLabel(card, @"", 9.5, NSFontWeightBold, rigDimText());
    badge.alignment = NSTextAlignmentCenter;
    badge.wantsLayer = YES;
    badge.layer.cornerRadius = 5.0;
    badge.layer.borderWidth = 1.0;
    badge.layer.masksToBounds = YES;
    badge.frame = [self topRect:card x:170 y:18 w:200 h:20];
    self.state->stageArchBadges[slot] = badge;
    if (slot == 0) {
      self.state->stageHeaderArchBadges[0] = badge;
      self.state->updateStageArchBadge(0, nil);
    }
    RigButton* power = workspaceButton(card, @"OFF", self, @selector(togglePedal:));
    power.tag = slot; power.buttonType = NSButtonTypeToggle;
    power.state = slot == 0 ? self.state->powerButtons[0].state : NSControlStateValueOff;
    power.title = power.state ? @"ON" : @"OFF";
    self.state->powerButtons[slot] = power;
    [self placeNew:power parent:card x:386 y:12 w:74 h:32];
    NSImageView* image = [[NSImageView alloc] initWithFrame:NSZeroRect];
    image.wantsLayer = YES;
    image.layer.cornerRadius = 8.0;
    image.layer.masksToBounds = YES;
    image.layer.backgroundColor = rigBG().CGColor;
    image.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.state->stageImages[slot] = image;
    [self placeNew:image parent:card x:20 y:54 w:440 h:580];
    RigPopUpButton* picker = slot == 0 ? self.state->modelPickers[0] : [[RigPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    picker.tag = slot; picker.target = self.state->uiController; picker.action = @selector(stageModelChanged:);
    self.state->modelPickers[slot] = picker;
    [self place:picker parent:card x:20 y:646 w:440 h:28];
    RigButton* load = workspaceButton(card, @"Load Model…", self, @selector(choosePedal:)); load.tag = slot;
    [self placeNew:load parent:card x:20 y:686 w:212 h:38];
    RigButton* clear = workspaceButton(card, @"Remove Model", self, @selector(clearPedal:)); clear.tag = slot;
    [self placeNew:clear parent:card x:248 y:686 w:212 h:38];
    self.state->displayPath(slot, self.state->selectedPaths[slot].c_str());
    self.state->setStageThumb(slot, nil, 0, nil);
  }
  [self refreshPedalBoard];
}

- (void)buildMainPages {
  // Compact level controls leave room for the live processing racks below.
  NSView* input = [self newPageWithKey:@"main:0"];
  RigPanel* inputConsole = [self panelAt:input x:0 y:0 w:1472 h:148];
  [self label:@"Input & Gate" parent:inputConsole x:28 y:36 w:580 size:20 weight:NSFontWeightSemibold color:rigText()];
  [self label:@"Set input gain and noise gate response before the preamp processors below."
       parent:inputConsole x:28 y:68 w:580 size:11.5 weight:NSFontWeightRegular color:rigDimText()];

  // Drop Pitch / Virtual Capo strip
  [self label:@"DROP PITCH" parent:inputConsole x:28 y:105 w:82 size:10.5 weight:NSFontWeightBold color:rigDimText()];
  RigButton* dropDownBtn = workspaceButton(inputConsole, @"−", self.state->uiController,
                                           @selector(dropPitchStepDown:));
  dropDownBtn.frame = [self topRect:inputConsole x:114 y:100 w:26 h:24];
  dropDownBtn.toolTip = @"Drop pitch down 1 semitone (e.g. D Standard → Db → C → B).";

  NSPopUpButton* dropPop = [[NSPopUpButton alloc] initWithFrame:[self topRect:inputConsole x:144 y:100 w:176 h:24] pullsDown:NO];
  dropPop.controlSize = NSControlSizeSmall;
  dropPop.target = self.state->uiController;
  dropPop.action = @selector(dropPitchChanged:);
  dropPop.toolTip = @"Polyphonic pre-amp Drop Pitch / Virtual Capo (-12 to +12 semitones). Example from D Standard: -1 = Db, -2 = C, -3 = B. 0 = exact bypass.";
  auto addDropItem = [&](NSString* title, int tag) {
    [dropPop addItemWithTitle:title];
    dropPop.lastItem.tag = tag;
  };
  addDropItem(@"+12 st (+1 Oct)", 12);
  for (int st = 11; st >= 1; --st) {
    addDropItem([NSString stringWithFormat:@"+%d st", st], st);
  }
  addDropItem(@"OFF (0 st)", 0);
  addDropItem(@"-1 st (½ Step / Db)", -1);
  addDropItem(@"-2 st (Whole Step / C)", -2);
  addDropItem(@"-3 st (1½ Steps / B)", -3);
  addDropItem(@"-4 st (2 Steps / Bb)", -4);
  addDropItem(@"-5 st (2½ Steps / A)", -5);
  addDropItem(@"-6 st (3 Steps / Ab)", -6);
  addDropItem(@"-7 st (3½ Steps / G)", -7);
  addDropItem(@"-8 st (4 Steps / F#)", -8);
  addDropItem(@"-9 st (4½ Steps / F)", -9);
  addDropItem(@"-10 st (5 Steps / E)", -10);
  addDropItem(@"-11 st (5½ Steps / Eb)", -11);
  addDropItem(@"-12 st (-1 Octave)", -12);
  [dropPop selectItemWithTag:self.state->dropPitch];
  [self.state->dropPitchPopups addObject:dropPop];
  [inputConsole addSubview:dropPop];

  RigButton* dropUpBtn = workspaceButton(inputConsole, @"+", self.state->uiController,
                                         @selector(dropPitchStepUp:));
  dropUpBtn.frame = [self topRect:inputConsole x:324 y:100 w:26 h:24];
  dropUpBtn.toolTip = @"Raise pitch up 1 semitone.";

  RigButton* bandLimitBtn = workspaceButton(inputConsole, @"HF FILTER", self.state->uiController,
                                            @selector(modelBandLimitToggled:));
  bandLimitBtn.buttonType = NSButtonTypeToggle;
  bandLimitBtn.check = YES;
  bandLimitBtn.state = self.state->modelBandLimit ? NSControlStateValueOn : NSControlStateValueOff;
  bandLimitBtn.frame = [self topRect:inputConsole x:366 y:100 w:104 h:24];
  bandLimitBtn.toolTip = @"A/B switch. On: a 20.5 kHz low-pass in front of each oversampled NAM model removes ultrasonic content from the overdrive and pedal models, which the models were not trained on. Off: the models receive the full oversampled signal. Presets do not change this switch.";
  [self.state->modelBandLimitButtons addObject:bandLimitBtn];
  NSArray<NSView*>* inputCells = [self knobCells:self.knobGroups[0]];
  for (NSUInteger i = 0; i < inputCells.count; ++i)
    [self place:inputCells[i] parent:inputConsole x:680 + i * 260 y:14 w:220 h:124];

  NSView* pedal = [self newPageWithKey:@"main:1"];
  [self buildPedalBoard:pedal];

  NSView* amp = [self newPageWithKey:@"main:2"];
  [self addStageHero:1 page:amp];
  [self knobPanelWithTitle:@"Tone & Voicing" group:self.knobGroups[1] parent:amp x:976 y:0 w:496 h:702 columns:3];

  NSView* cab = [self newPageWithKey:@"main:3"];
  [self addStageHero:2 page:cab];
  RigPanel* cabACard = self.state->stageCards[2];
  cabACard.onClickWithEvent = nil;
  cabACard.onClick = self.state->modelPickers[2].onClick;
  NSView* browseB = nil;
  NSView* labelB = nil;
  for (NSView* sub in cabACard.subviews.copy) {
    if ([sub isKindOfClass:NSButton.class] && ((NSButton*)sub).tag == 3 &&
        ((NSButton*)sub).action == NSSelectorFromString(@"chooseModel:")) {
      browseB = sub;
    } else if ([sub isKindOfClass:NSTextField.class] &&
               [((NSTextField*)sub).stringValue isEqualToString:@"B"]) {
      labelB = sub;
    } else {
      for (NSView* hSub in sub.subviews) {
        if ([hSub isKindOfClass:NSTextField.class] &&
            [((NSTextField*)hSub).stringValue isEqualToString:@"CAB"]) {
          ((NSTextField*)hSub).stringValue = @"CAB A";
        }
      }
    }
  }

  RigPanel* cabBCard = [self panelAt:cab x:744 y:0 w:728 h:702];
  cabBCard.onClick = self.state->modelPickers[3].onClick;
  [self label:@"3B" parent:cabBCard x:16 y:18 w:24 size:12 weight:NSFontWeightBold color:rigOrange()];
  [self label:@"CAB B" parent:cabBCard x:44 y:17 w:54 size:13 weight:NSFontWeightSemibold color:rigText()];
  NSTextField* cabBBadge = workspaceLabel(cabBCard, @"", 9.5, NSFontWeightBold, rigDimText());
  cabBBadge.alignment = NSTextAlignmentCenter;
  cabBBadge.wantsLayer = YES;
  cabBBadge.layer.cornerRadius = 5.0;
  cabBBadge.layer.borderWidth = 1.0;
  cabBBadge.layer.masksToBounds = YES;
  cabBBadge.frame = [self topRect:cabBCard x:104 y:18 w:180 h:18];
  self.state->stageArchBadges[3] = cabBBadge;
  self.state->updateStageArchBadge(3, nil);
  if (self.state->powerButtons[3]) {
    [self place:self.state->powerButtons[3] parent:cabBCard x:652 y:14 w:60 h:26];
  }
  NSImageView* cabBImage = [[NSImageView alloc] initWithFrame:NSZeroRect];
  cabBImage.wantsLayer = YES;
  cabBImage.layer.cornerRadius = 8.0;
  cabBImage.layer.masksToBounds = YES;
  cabBImage.layer.backgroundColor = rigBG().CGColor;
  cabBImage.imageScaling = NSImageScaleProportionallyUpOrDown;
  self.state->stageImages[3] = cabBImage;
  [self placeNew:cabBImage parent:cabBCard x:16 y:54 w:696 h:601];
  if (labelB) {
    [self place:labelB parent:cabBCard x:16 y:666 w:14 h:17];
  } else {
    [self label:@"B" parent:cabBCard x:16 y:666 w:14 size:11 weight:NSFontWeightBold color:rigDimText()];
  }
  if (self.state->modelPickers[3]) {
    [self place:self.state->modelPickers[3] parent:cabBCard x:35 y:663 w:583 h:23];
  }
  if (browseB) {
    [self place:browseB parent:cabBCard x:622 y:663 w:26 h:23];
  }
  RigButton* clearCabB = workspaceButton(cabBCard, @"CLEAR", self, @selector(clearPedal:));
  clearCabB.tag = 3;
  clearCabB.toolTip = @"Unload the second cabinet (Cab B) model or impulse response.";
  [self placeNew:clearCabB parent:cabBCard x:652 y:663 w:60 h:23];
  [cabACard layoutSubtreeIfNeeded];
  self.state->setStageThumb(3, nil, 0, nil);

  NSView* output = [self newPageWithKey:@"main:4"];
  RigPanel* outputConsole = [self panelAt:output x:0 y:0 w:1472 h:148];
  [self label:@"Master Output" parent:outputConsole x:28 y:36 w:580 size:20 weight:NSFontWeightSemibold color:rigText()];
  [self label:@"Set level, catch peaks, and balance the final stereo image."
       parent:outputConsole x:28 y:68 w:580 size:11.5 weight:NSFontWeightRegular color:rigDimText()];
  NSArray<NSView*>* outputCells = [self knobCells:self.knobGroups[2]];
  for (NSUInteger i = 0; i < outputCells.count; ++i)
    [self place:outputCells[i] parent:outputConsole x:700 + i * 180 y:14 w:180 h:124];
  [self label:@"Ceiling OFF + Balance CENTER preserves the current sound."
       parent:outputConsole x:28 y:91 w:620 size:11 weight:NSFontWeightRegular color:rigDimText()];
  [self label:@"LIMITER REDUCTION" parent:outputConsole x:1260 y:38 w:180 size:10 weight:NSFontWeightMedium color:rigDimText()];
  NSLevelIndicator* reduction = [[NSLevelIndicator alloc] initWithFrame:NSZeroRect];
  reduction.levelIndicatorStyle = NSLevelIndicatorStyleContinuousCapacity;
  reduction.minValue = 0; reduction.maxValue = 24;
  reduction.warningValue = 12; reduction.criticalValue = 20;
  reduction.editable = NO;
  reduction.toolTip = @"Gain removed by the final peak limiter in dB. Ceiling OFF bypasses completely.";
  self.state->outputReductionMeter = reduction;
  [self placeNew:reduction parent:outputConsole x:1260 y:65 w:180 h:12];
  NSTextField* reductionLabel = workspaceLabel(outputConsole, @"0.0 dB", 11, NSFontWeightMedium, rigDimText());
  self.state->outputReductionLabel = reductionLabel;
  [self place:reductionLabel parent:outputConsole x:1260 y:86 w:180 h:18];
}

// Reuse the same controls on overview and detail pages, preserving all bindings
// and preset menus. Only their parent and frame change when navigating.
- (void)mountOverviewRacksForStage:(NSInteger)stage {
  NSArray<NSString*>* keys = stage == 0 ? @[@"compressor", @"sculpt", @"boost"] :
      (stage == 4 ? @[@"postcomp", @"delay", @"reverb", @"spatial"] : @[]);
  if (!keys.count) return;
  NSView* page = self.pages[[NSString stringWithFormat:@"main:%ld", (long)stage]];
  const CGFloat width = (1472 - 16 * (keys.count - 1)) / MAX((NSUInteger)1, keys.count);
  for (NSUInteger i = 0; i < keys.count; ++i) {
    RigPanel* rack = self.moduleRacks[keys[i]];
    [self place:rack parent:page x:i * (width + 16) y:164 w:width h:630];
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
    self.powerTubeRack = power[1];
    [self modulePageForStage:2 key:@"power" title:@"Power Stage" rack:power[0] rightRack:power[1]
                        info:@"Dynamic power amp compression, push-pull sag, presence/depth, and power tube harmonic saturation."];
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
    [self place:rigCreateTunerWorkspace(self.state) parent:page x:0 y:0 w:1472 h:794];
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
  RigPanel* strip = [self panelAt:self.contextHost x:0 y:0 w:1472 h:76];
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
  [self label:heading parent:strip x:22 y:16 w:250 size:11 weight:NSFontWeightBold color:rigDimText()];
  [self label:@"Relevant processing, right where you need it." parent:strip x:22 y:38 w:270 size:11 weight:NSFontWeightRegular color:rigDimText()];
  const CGFloat startX = 310;
  const CGFloat gap = 14;
  const CGFloat width = (1472 - startX - 22 - gap * (titles.count - 1)) / titles.count;
  for (NSUInteger i = 0; i < titles.count; ++i) {
    RigButton* button = workspaceButton(strip, titles[i], self, @selector(moduleClicked:));
    button.accessibilityIdentifier = keys[i];
    button.buttonType = NSButtonTypeToggle;
    button.primary = [keys[i] isEqualToString:self.selectedModule];
    button.state = button.primary ? NSControlStateValueOn : NSControlStateValueOff;
    [self placeNew:button parent:strip x:startX + i * (width + gap) y:15 w:width h:46];
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
      BOOL bottomNavigation = [@[@"power", @"transformer", @"speaker", @"cablab"] containsObject:key];
      [self place:rack parent:self.pages[key] x:bottomNavigation ? 0 : 236 y:48
                 w:bottomNavigation ? ([key isEqualToString:@"power"] ? 888 : 1472)
                                    : ([key isEqualToString:@"power"] ? 824 : 1236)
                 h:bottomNavigation ? 654 : 746];
      if ([key isEqualToString:@"power"] && self.powerTubeRack) {
        [self place:self.powerTubeRack parent:self.pages[key] x:bottomNavigation ? 904 : 1076 y:48
                   w:bottomNavigation ? 568 : 396 h:bottomNavigation ? 654 : 746];
      }
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
    self.contextHost = [[NSView alloc] initWithFrame:[self topRect:self x:24 y:872 w:1472 h:76]];
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
