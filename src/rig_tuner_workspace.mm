#import "rig_tuner_workspace.h"
#import "rig_ui_state.h"
#import <QuartzCore/QuartzCore.h>
#include "tuner_tools.h"
#include <sstream>

using NAMRig::Tuning::Model;
using NAMRig::Tuning::Status;
namespace {
NSRect top(NSView* parent, CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
  return NSMakeRect(x, NSHeight(parent.bounds) - y - h, w, h);
}
NSTextField* label(NSView* parent, NSString* text, CGFloat x, CGFloat y, CGFloat w, CGFloat h, CGFloat size = 12) {
  NSTextField* f = [NSTextField labelWithString:text];
  f.font = [NSFont systemFontOfSize:size weight:NSFontWeightMedium]; f.textColor = rigText();
  f.lineBreakMode = NSLineBreakByTruncatingTail;
  f.frame = top(parent,x,y,w,h); [parent addSubview:f]; return f;
}
RigPanel* card(NSView* parent, NSString* title, CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
  RigPanel* panel = [[RigPanel alloc] initWithFrame:top(parent,x,y,w,h)]; panel.cornerRadius = 12;
  [parent addSubview:panel]; label(panel,title,22,18,w-44,26,18); return panel;
}
RigButton* button(NSView* parent, NSString* title, id target, SEL action, CGFloat x, CGFloat y, CGFloat w, CGFloat h = 30) {
  RigButton* b = [[RigButton alloc] initWithFrame:top(parent,x,y,w,h)];
  b.title = title; b.target = target; b.action = action; b.bordered = NO;
  [parent addSubview:b]; return b;
}
NSString* noteName(int midi) { return [NSString stringWithUTF8String:NAMRig::Tuning::noteName(midi).c_str()]; }
NSString* notesText(const std::vector<int>& notes) {
  NSMutableArray* strings = [NSMutableArray array]; for (int midi : notes) [strings addObject:noteName(midi)];
  return [strings componentsJoinedByString:@" "];
}
NSArray<NSNumber*>* numbers(const std::vector<int>& notes) {
  NSMutableArray* values = [NSMutableArray array]; for (int midi : notes) [values addObject:@(midi)]; return values;
}
NSTextField* input(NSView* parent, NSString* text, id delegate, SEL action, CGFloat x, CGFloat y, CGFloat w) {
  RigAlertTextField* f = [[RigAlertTextField alloc] initWithFrame:top(parent,x,y,w,28)];
  f.stringValue = text; f.font = [NSFont systemFontOfSize:12];
  f.textColor = rigText(); f.backgroundColor = rigRaised(); f.bordered = NO;
  f.delegate = delegate; f.target = delegate; f.action = action; [parent addSubview:f]; return f;
}
void drawText(NSString* text, NSRect rect, NSColor* color, CGFloat size = 10) {
  [text drawInRect:rect withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:size],NSForegroundColorAttributeName:color}];
}
}

@interface NAMTunerHistory : NSView
- (void)update:(const std::deque<NAMRig::Tuning::Trace>&)points now:(double)now;
@end
@implementation NAMTunerHistory {
  std::deque<NAMRig::Tuning::Trace> _points;
  double _now;
}
- (void)update:(const std::deque<NAMRig::Tuning::Trace>&)points now:(double)now { _points = points; _now = now; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
  NSRect plot = NSMakeRect(46,30,NSWidth(self.bounds)-62,NSHeight(self.bounds)-48);
  [rigBG() setFill]; [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:8 yRadius:8] fill];
  const auto y = [&](double cents) { return NSMidY(plot) + std::clamp(cents,-50.0,50.0) / 100 * NSHeight(plot); };
  [[rigGreen() colorWithAlphaComponent:.10] setFill];
  [[NSBezierPath bezierPathWithRect:NSMakeRect(NSMinX(plot),y(-2),NSWidth(plot),y(2)-y(-2))] fill];
  for (int cents : {-50,-25,0,25,50}) {
    NSBezierPath* line = [NSBezierPath bezierPath]; [line moveToPoint:NSMakePoint(NSMinX(plot),y(cents))]; [line lineToPoint:NSMakePoint(NSMaxX(plot),y(cents))];
    line.lineWidth = cents == 0 ? 1 : .5; [rigPanelBorder() setStroke]; [line stroke];
    drawText([NSString stringWithFormat:@"%+d¢",cents],NSMakeRect(5,y(cents)-6,38,14),rigDimText(),9);
  }
  for (int seconds : {0,5,10}) drawText(seconds == 10 ? @"Now" : [NSString stringWithFormat:@"−%d s",10-seconds],
      NSMakeRect(NSMinX(plot)+NSWidth(plot)*seconds/10-8,6,40,14),rigDimText(),9);
  NSBezierPath* trace = [NSBezierPath bezierPath]; BOOL joined = NO, any = NO;
  for (const auto& p : _points) {
    if (!p.valid || std::abs(p.cents)>100 || p.time<_now-10) { joined=NO; continue; }
    NSPoint point = NSMakePoint(NSMaxX(plot)-( _now-p.time)/10*NSWidth(plot),y(p.cents));
    if (joined) [trace lineToPoint:point]; else [trace moveToPoint:point]; joined=YES; any=YES;
  }
  trace.lineWidth=2; [rigAccent() setStroke]; [trace stroke];
  if (!any) drawText(@"Pluck a string to see its pitch settle.", NSMakeRect(NSMinX(plot)+20,NSMidY(plot)+20,NSWidth(plot)-40,20),rigDimText(),12);
}
@end
@interface NAMTunerMeter : NSView @end
@implementation NAMTunerMeter
- (void)drawRect:(NSRect)dirty {
  [rigBG() setFill]; [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
  [[rigGreen() colorWithAlphaComponent:.20] setFill];
  [[NSBezierPath bezierPathWithRect:NSMakeRect(NSWidth(self.bounds)*.48,20,NSWidth(self.bounds)*.04,32)] fill];
  for (int cents : {-50,-25,0,25,50}) {
    CGFloat x=3+(NSWidth(self.bounds)-6)*(cents+50)/100;
    NSBezierPath* tick=[NSBezierPath bezierPath];[tick moveToPoint:NSMakePoint(x,20)];[tick lineToPoint:NSMakePoint(x,52)];
    [rigPanelBorder() setStroke];[tick stroke];
    drawText([NSString stringWithFormat:@"%+d¢",cents],NSMakeRect(std::clamp(x-16,0.0,NSWidth(self.bounds)-34),3,38,13),rigDimText(),9);
  }
}
@end

@implementation NAMRigTunerWorkspace {
  RigUIState* _state;
  std::shared_ptr<bool> _alive;
  Model _model;
  NSTimer* _timer;
  BOOL _active, _toneOn, _referenceEditing;
  double _livePitch, _confidence, _level, _lastLiveAt, _lastLease;
  double _toneDb;
  NSString* _currentName;
  NSString* _tuningError;
  NSMutableDictionary<NSString*,NSArray<NSNumber*>*>* _userTunings;
  NSPopUpButton* _preset;
  NSTextField* _notes;
  NSTextField* _target;
  NSView* _stringGrid;
  NSMutableArray<RigButton*>* _stringButtons;
  NSTextField* _frequency;
  NSTextField* _quality;
  NSTextField* _reference;
  NSStepper* _referenceStep;
  NSPopUpButton* _toneTarget;
  RigButton* _toneButton;
  NSSlider* _toneLevel;
  NSTextField* _toneCaption;
  NAMTunerHistory* _history;
  NSTextField* _historyTarget;
  NSPopUpButton* _baselineMode;
  RigButton* _captureBase;
  RigButton* _captureFret;
  NSTextField* _baseResult;
  NSTextField* _fretResult;
  NSTextField* _intonation;
  NSTextField* _advice;
}
- (BOOL)isFlipped { return NO; }
- (instancetype)initWithState:(RigUIState*)state {
  if (!(self=[super initWithFrame:NSMakeRect(0,0,1472,794)])) return nil;
  _state=state; _alive=state->isAlive; _livePitch=-1; _level=-120; _lastLiveAt=-100;
  _toneDb=-30; _currentName=@"6-string Standard"; _userTunings=[NSMutableDictionary dictionary]; _stringButtons=[NSMutableArray array];
  NSDictionary* saved=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"AxeFXTunerTools"];
  if ([saved isKindOfClass:NSDictionary.class]) {
    double reference=[saved[@"reference"] doubleValue]; if (reference>=400 && reference<=480) _model.reference=reference;
    if ([saved[@"volume"] respondsToSelector:@selector(doubleValue)]) _toneDb=std::clamp([saved[@"volume"] doubleValue],-40.0,-12.0);
    if ([saved[@"tunings"] isKindOfClass:NSDictionary.class]) {
      for (NSString* name in saved[@"tunings"]) {
        id values=saved[@"tunings"][name]; if (![values isKindOfClass:NSArray.class] || [values count]<1 || [values count]>12) continue;
        BOOL valid=YES;
        for (id v in values) valid &= [v isKindOfClass:NSNumber.class] && [v intValue]>=23 && [v intValue]<=89;
        if (valid) _userTunings[name]=values;
      }
    }
    if ([saved[@"selected"] isKindOfClass:NSString.class]) _currentName=saved[@"selected"];
  }
  RigPanel* main=card(self,@"Instrument tuner",0,0,560,360);
  _quality=label(main,@"Listening",344,22,190,22,12); _quality.alignment=NSTextAlignmentRight;
  state->tunerNoteLabel=label(main,@"—",24,57,510,96,72); state->tunerNoteLabel.alignment=NSTextAlignmentCenter;
  state->tunerCentsLabel=label(main,@"",24,155,512,32,22); state->tunerCentsLabel.alignment=NSTextAlignmentCenter;
  _frequency=label(main,@"Pluck one string",24,195,512,22,13); _frequency.alignment=NSTextAlignmentCenter; _frequency.textColor=rigDimText();
  NAMTunerMeter* meter=[[NAMTunerMeter alloc] initWithFrame:top(main,24,232,512,64)]; [main addSubview:meter];
  NSImageView* needle=[[NSImageView alloc] initWithFrame:NSZeroRect];needle.wantsLayer=YES;needle.layer.backgroundColor=rigAccent().CGColor;needle.translatesAutoresizingMaskIntoConstraints=NO;needle.hidden=YES;[meter addSubview:needle];
  state->tunerNeedle=needle; state->tunerNeedleLeading=[needle.leadingAnchor constraintEqualToAnchor:meter.leadingAnchor constant:253];
  [NSLayoutConstraint activateConstraints:@[state->tunerNeedleLeading,[needle.widthAnchor constraintEqualToConstant:6],[needle.heightAnchor constraintEqualToConstant:28],[needle.centerYAnchor constraintEqualToAnchor:meter.centerYAnchor constant:5]]];
  RigButton* active=button(main,@"TUNER ACTIVE",state->uiController,NSSelectorFromString(@"tunerToggled:"),24,313,182);
  active.buttonType=NSButtonTypeToggle;active.check=YES;state->tunerButton=active;
  RigButton* mute=button(main,@"Mute guitar while tuning",state->uiController,NSSelectorFromString(@"toggleMuteOnTune:"),218,313,318);
  mute.buttonType=NSButtonTypeToggle;mute.check=YES;mute.state=state->muteOnTune?NSControlStateValueOn:NSControlStateValueOff;mute.primary=state->muteOnTune;state->muteOnTuneButton=mute;

  RigPanel* tuning=card(self,@"Tuning & string targets",576,0,480,360);
  _preset=[[NSPopUpButton alloc] initWithFrame:top(tuning,22,57,436,28)];_preset.target=self;_preset.action=@selector(presetChanged:);[tuning addSubview:_preset];
  label(tuning,@"Low → high · click a string to lock its target",22,99,436,20,11).textColor=rigDimText();
  _stringGrid=[[NSView alloc] initWithFrame:top(tuning,22,127,436,124)];[tuning addSubview:_stringGrid];
  _notes=input(tuning,@"",self,@selector(applyNotes:),22,268,338);
  _notes.toolTip=@"Custom tuning: enter 1–12 notes from low to high, including octaves (e.g. B1 E2 A2 D3 G3 B3 E4).";
  button(tuning,@"Apply",self,@selector(applyNotes:),370,268,88,28);
  _target=label(tuning,@"Automatic note detection",22,308,318,34,11);_target.maximumNumberOfLines=2;_target.lineBreakMode=NSLineBreakByWordWrapping;
  button(tuning,@"Auto",self,@selector(autoTarget:),370,309,88,28);

  RigPanel* reference=card(self,@"Reference & tone",1072,0,400,360);
  label(reference,@"A4 reference",22,62,125,22,12);
  _reference=input(reference,@"440.0",self,@selector(referenceChanged:),154,57,94);_reference.delegate=self;
  label(reference,@"Hz",259,61,32,22,12);
  _referenceStep=[[NSStepper alloc] initWithFrame:top(reference,298,57,20,28)];_referenceStep.minValue=400;_referenceStep.maxValue=480;_referenceStep.increment=.5;_referenceStep.target=self;_referenceStep.action=@selector(referenceStepped:);[reference addSubview:_referenceStep];
  button(reference,@"440",self,@selector(resetReference:),328,57,50,28);
  _toneTarget=[[NSPopUpButton alloc] initWithFrame:top(reference,22,113,356,28)];[_toneTarget addItemsWithTitles:@[@"Concert A4",@"Locked string target"]];_toneTarget.target=self;_toneTarget.action=@selector(toneTargetChanged:);[reference addSubview:_toneTarget];
  _toneButton=button(reference,@"Play reference tone",self,@selector(toggleTone:),22,161,356,36);_toneButton.buttonType=NSButtonTypeToggle;
  _toneCaption=label(reference,@"Tone level: −30 dBFS",22,221,356,22,12);
  _toneLevel=[[NSSlider alloc] initWithFrame:top(reference,22,251,356,24)];_toneLevel.minValue=-40;_toneLevel.maxValue=-12;_toneLevel.doubleValue=_toneDb;_toneLevel.continuous=YES;_toneLevel.target=self;_toneLevel.action=@selector(toneLevelChanged:);[reference addSubview:_toneLevel];
  NSTextField* toneHelp=label(reference,@"Reference tone stays audible while the guitar is muted. Stops when you leave the tuner.",22,296,356,44,11);
  toneHelp.maximumNumberOfLines=3; toneHelp.lineBreakMode=NSLineBreakByWordWrapping;

  RigPanel* history=card(self,@"Pitch stability · last 10 seconds",0,376,900,418);
  _historyTarget=label(history,@"Green band = within ±2 cents",22,52,720,22,12);_historyTarget.textColor=rigDimText();
  button(history,@"Clear",self,@selector(clearHistory:),792,20,86,27);
  _history=[[NAMTunerHistory alloc] initWithFrame:top(history,18,88,864,310)];[history addSubview:_history];

  RigPanel* intonation=card(self,@"Intonation check",916,376,556,418);
  label(intonation,@"Compare a reference note with the fretted 12th fret.",22,55,512,22,12).textColor=rigDimText();
  _baselineMode=[[NSPopUpButton alloc] initWithFrame:top(intonation,22,92,512,28)];[_baselineMode addItemsWithTitles:@[@"Reference: open string",@"Reference: 12th-fret harmonic"]];_baselineMode.target=self;_baselineMode.action=@selector(resetIntonation:);[intonation addSubview:_baselineMode];
  _captureBase=button(intonation,@"1 · Capture reference",self,@selector(captureBaseline:),22,139,246,34);
  _captureFret=button(intonation,@"2 · Capture fretted 12th",self,@selector(captureFretted:),280,139,254,34);
  _baseResult=label(intonation,@"Reference: —",22,191,512,22,12);
  _fretResult=label(intonation,@"Fretted 12th: —",22,222,512,22,12);
  _intonation=label(intonation,@"Wait for a stable note",22,262,512,32,24);
  _advice=label(intonation,@"Use normal fretting pressure. Retune after each saddle adjustment.",22,308,512,54,12);_advice.maximumNumberOfLines=3;_advice.lineBreakMode=NSLineBreakByWordWrapping;
  button(intonation,@"Reset check",self,@selector(resetIntonation:),22,370,150,28);
  [self loadCurrentTuning]; [self rebuildMenu]; [self rebuildStrings]; [self render];
  state->tunerPanel=self; state->tunerWorkspace=self;
  return self;
}
- (BOOL)validState { return _state && _alive && *_alive; }
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];[_timer invalidate];_timer=nil;
  if (!self.window) { [self stopTone]; return; }
  __weak NAMRigTunerWorkspace* weak=self;
  _timer=[NSTimer timerWithTimeInterval:.05 repeats:YES block:^(NSTimer* timer){ [weak tick]; }];
  [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}
- (void)dealloc { [_timer invalidate]; }
- (void)shutdown { [self stopTone]; [_timer invalidate]; _timer=nil; _state=nullptr; }
- (void)setTunerActive:(BOOL)active {
  _active=active; _model.clearHistory(); _model.status=Status::Listening;
  _livePitch=-1; _lastLiveAt=-100;
  if (!active) { [self stopTone]; _model.pitch=-1; }
  [self render];
}
- (void)updateLegacyNote:(float)note cents:(float)cents {
  if (CACurrentMediaTime()-_lastLiveAt<.25) return;
  [self pushPitch:note<0?-1:std::round(note)+cents*.01 confidence:note<0?0:1 level:note<0?-120:-18 atTime:CACurrentMediaTime()];
}
- (void)acceptTunerMetric:(NSUInteger)metric value:(float)value {
  if (!std::isfinite(value)) return;
  if (metric==0) { _livePitch=value; _lastLiveAt=CACurrentMediaTime(); }
  else if (metric==1) _confidence=value;
  else if (metric==2) _level=value;
}
- (void)tick {
  if (![self validState]) return;
  if (!_active || self.isHiddenOrHasHiddenAncestor || _state->activeDeckTab!=0 || _state->tunerButton.state!=NSControlStateValueOn) { [self stopTone]; return; }
  double now=CACurrentMediaTime();
  if (_lastLiveAt>-99) [self pushPitch:now-_lastLiveAt<.2?_livePitch:-1 confidence:_confidence level:_level atTime:now];
  if (_toneOn && now-_lastLease>.2) [self renewTone];
}
- (void)pushPitch:(double)pitch confidence:(double)confidence level:(double)db atTime:(double)time {
  _model.update(time,pitch,confidence,db);[_history update:_model.history now:time];[self render];
}
- (void)render {
  if (![self validState] || !_frequency) return;
  if (!_referenceEditing) _reference.stringValue=[NSString stringWithFormat:@"%.1f",_model.reference];
  _referenceStep.doubleValue=_model.reference;
  _toneCaption.stringValue=[NSString stringWithFormat:@"Tone level: %.0f dBFS",_toneDb];
  const BOOL valid=_active && _model.pitch>=0 && _model.status!=Status::Weak;
  if (valid) {
    int midi=(int)std::lround(_model.pitch-NAMRig::Tuning::referenceOffset(_model.reference));
    _state->tunerNoteLabel.stringValue=noteName(midi);
    double cents=_model.cents;BOOL inTune=std::abs(cents)<=2;
    _state->tunerCentsLabel.stringValue=[NSString stringWithFormat:inTune?@"%+.1f¢  ● IN TUNE":cents>0?@"%+.1f¢ (SHARP)":@"%+.1f¢ (FLAT)",cents];
    _state->tunerCentsLabel.textColor=inTune?rigGreen():rigOrange();
    _state->tunerNoteLabel.textColor=inTune?rigGreen():rigText();
    _frequency.stringValue=[NSString stringWithFormat:@"%.2f Hz  ·  target %.2f Hz",NAMRig::Tuning::frequency(_model.pitch),NAMRig::Tuning::frequency(_model.targetRaw())];
    _state->tunerNeedle.hidden=NO;
    _state->tunerNeedle.layer.backgroundColor=(inTune?rigGreen():rigOrange()).CGColor;
    _state->tunerNeedleLeading.constant=(std::clamp(cents,-50.0,50.0)+50)/100*506;
  } else {
    _state->tunerNoteLabel.stringValue=@"—";_state->tunerNoteLabel.textColor=rigText();
    _state->tunerCentsLabel.stringValue=@"";_state->tunerNeedle.hidden=YES;
    _frequency.stringValue=_active?@"Pluck one string":@"Tuner bypassed";
  }
  NSString* statuses[] = {@"Listening",@"Weak signal",@"Fading · pluck again",@"Settling…",@"Stable"};
  _quality.stringValue=_active?statuses[(int)_model.status]:@"Inactive";
  _quality.textColor=_model.status==Status::Stable&&_active?rigGreen():rigDimText();
  if (_tuningError.length) { _target.stringValue=_tuningError;_target.textColor=rigOrange(); }
  else {
    _target.textColor=rigDimText();
    _target.stringValue=_model.locked>=0?[NSString stringWithFormat:@"Locked: string %lu · %@ · %.2f Hz",(unsigned long)(_model.strings.size()-_model.locked),noteName(_model.strings[_model.locked]),NAMRig::Tuning::frequency(_model.strings[_model.locked],_model.reference)]:@"Auto · follows the note you play";
  }
  if (_model.hasBaseline && !_tuningError.length) _target.stringValue=[NSString stringWithFormat:@"Intonation target: %@ · %.2f Hz",noteName((int)std::lround(_model.targetRaw()-NAMRig::Tuning::referenceOffset(_model.reference))),NAMRig::Tuning::frequency(_model.targetRaw())];
  for (NSUInteger i=0;i<_stringButtons.count;++i) { _stringButtons[i].primary=(int)i==_model.locked;_stringButtons[i].state=(int)i==_model.locked?NSControlStateValueOn:NSControlStateValueOff; }
  _toneButton.enabled=_active && (_toneTarget.indexOfSelectedItem==0 || _model.locked>=0);
  double toneFrequency=_toneTarget.indexOfSelectedItem==0?_model.reference:_model.locked>=0?NAMRig::Tuning::frequency(_model.strings[_model.locked],_model.reference):0;
  NSString* toneNote=_toneTarget.indexOfSelectedItem==0?@"A4":_model.locked>=0?noteName(_model.strings[_model.locked]):@"";
  _toneButton.title=_toneOn?@"Stop reference tone":toneFrequency>0?[NSString stringWithFormat:@"Play %@ · %.2f Hz",toneNote,toneFrequency]:@"Choose a string target";_toneButton.primary=_toneOn;
  _historyTarget.stringValue=_model.hasBaseline?@"Intonation target · green band = within ±2 cents":_model.locked>=0?[NSString stringWithFormat:@"Target %@ · green band = within ±2 cents",noteName(_model.strings[_model.locked])]:@"Cents from the nearest note · green band = within ±2 cents";
  _captureBase.enabled=_active && !_toneOn && _model.status==Status::Stable;
  double expected=_model.baseline+(_model.harmonicBaseline?0:12);
  _captureFret.enabled=_captureBase.enabled && _model.hasBaseline && std::abs(_model.pitch-expected)<=1;
  _baseResult.stringValue=_model.hasBaseline?[NSString stringWithFormat:@"Reference: %@ · %.2f Hz",noteName((int)std::lround(_model.baseline-NAMRig::Tuning::referenceOffset(_model.reference))),NAMRig::Tuning::frequency(_model.baseline)]:@"Reference: —";
  _fretResult.stringValue=_model.hasComparison?[NSString stringWithFormat:@"Fretted 12th: %.2f Hz",NAMRig::Tuning::frequency(_model.comparison)]:@"Fretted 12th: —";
  if (_model.hasComparison) {
    double error=_model.intonationCents();BOOL close=std::abs(error)<=2;
    _intonation.stringValue=[NSString stringWithFormat:@"%+.1f¢ · %@",error,close?@"intonation matches":error>0?@"fretted note is sharp":@"fretted note is flat"];
    _intonation.textColor=close?rigGreen():rigOrange();
    _advice.stringValue=close?@"Open or harmonic reference and fretted pitch agree. Check again with normal fretting pressure.":error>0?@"Lengthen the string (move its saddle away from the nut), retune, and measure again.":@"Shorten the string (move its saddle toward the nut), retune, and measure again.";
  } else {
    _intonation.stringValue=_model.hasBaseline?@"Now fret the 12th fret":@"Wait for a stable reference";_intonation.textColor=rigText();
    _advice.stringValue=_model.hasBaseline?@"Let the fretted note settle, then capture it. Use normal fretting pressure.":@"Play the open string or chosen harmonic. Capture becomes available when its pitch is stable.";
  }
}
- (void)savePreferences {
  [NSUserDefaults.standardUserDefaults setObject:@{@"reference":@(_model.reference),@"volume":@(_toneDb),@"selected":_currentName?:@"Custom",@"notes":numbers(_model.strings),@"tunings":_userTunings} forKey:@"AxeFXTunerTools"];
}
- (void)loadCurrentTuning {
  BOOL found=NO;
  for (const auto& preset:NAMRig::Tuning::factoryTunings()) if ([_currentName isEqualToString:[NSString stringWithUTF8String:preset.name]]) { _model.strings=preset.notes;found=YES;break; }
  NSArray* stored=_userTunings[_currentName];
  if (!found && [stored isKindOfClass:NSArray.class]) { _model.strings.clear();for(NSNumber* n in stored)_model.strings.push_back(n.intValue);found=YES; }
  if (!found && [_currentName isEqualToString:@"Custom"]) {
    NSArray* notes=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"AxeFXTunerTools"][@"notes"];
    if ([notes isKindOfClass:NSArray.class] && notes.count>=1 && notes.count<=12) {
      std::vector<int> parsed;for(id n in notes)if([n isKindOfClass:NSNumber.class]&&[n intValue]>=23&&[n intValue]<=89)parsed.push_back([n intValue]);
      if (parsed.size()==notes.count) { _model.strings=parsed;found=YES; }
    }
  }
  if (!found) { _currentName=@"6-string Standard";_model.strings=NAMRig::Tuning::factoryTunings()[0].notes; }
  _model.locked=-1;_model.clearHistory();_model.resetIntonation();_notes.stringValue=notesText(_model.strings);_tuningError=nil;
}
- (void)rebuildMenu {
  [_preset removeAllItems]; _preset.menu.autoenablesItems=NO;
  for (const auto& p:NAMRig::Tuning::factoryTunings()) [_preset addItemWithTitle:[NSString stringWithUTF8String:p.name]];
  for (NSString* name in [[_userTunings allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) [_preset addItemWithTitle:name];
  [_preset addItemWithTitle:@"Custom"];
  [_preset.menu addItem:NSMenuItem.separatorItem];
  NSArray* actions=@[@"Save Tuning",@"Save Tuning As…",@"Rename Tuning…",@"Delete Tuning"];
  for (NSUInteger i=0;i<actions.count;++i) { [_preset addItemWithTitle:actions[i]];_preset.lastItem.tag=1000+i;_preset.lastItem.enabled=i==1 || _userTunings[_currentName]!=nil; }
  [_preset selectItemWithTitle:_currentName];
}
- (void)rebuildStrings {
  [_stringGrid.subviews.copy makeObjectsPerformSelector:@selector(removeFromSuperview)];[_stringButtons removeAllObjects];
  const CGFloat width=(_stringGrid.bounds.size.width-24)/4;
  for (NSUInteger i=0;i<_model.strings.size();++i) {
    RigButton* b=button(_stringGrid,[NSString stringWithFormat:@"%lu · %@",(unsigned long)(_model.strings.size()-i),noteName(_model.strings[i])],self,@selector(stringClicked:),(i%4)*(width+8),(i/4)*40,width,32);
    b.tag=i;b.buttonType=NSButtonTypeToggle;b.toolTip=[NSString stringWithFormat:@"Lock to %.2f Hz. Auto returns to chromatic tuning.",NAMRig::Tuning::frequency(_model.strings[i],_model.reference)];[_stringButtons addObject:b];
  }
}
- (void)presetChanged:(NSPopUpButton*)sender {
  NSInteger tag=sender.selectedItem.tag;
  if (tag>=1000) { [self tuningAction:tag]; [self rebuildMenu]; return; }
  _currentName=sender.titleOfSelectedItem;[self loadCurrentTuning];[self rebuildStrings];[self stopTone];[self savePreferences];[self render];
}
- (void)tuningAction:(NSInteger)tag {
  if (tag==1000 && _userTunings[_currentName]) { _userTunings[_currentName]=numbers(_model.strings);[self savePreferences];return; }
  if (tag==1003) {
    NSAlert* alert=[NSAlert new];alert.messageText=@"Delete Tuning";alert.informativeText=_currentName;[alert addButtonWithTitle:@"Delete"];[alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal]==NSAlertFirstButtonReturn) { [_userTunings removeObjectForKey:_currentName];_currentName=@"6-string Standard";[self loadCurrentTuning];[self rebuildStrings];[self savePreferences];[self render]; }return;
  }
  NSAlert* alert=[NSAlert new];alert.messageText=tag==1002?@"Rename Tuning":@"Save Tuning As";
  RigAlertTextField* name=[[RigAlertTextField alloc] initWithFrame:NSMakeRect(0,0,320,26)];name.stringValue=tag==1002?_currentName:[_currentName stringByAppendingString:@" Copy"];alert.accessoryView=name;
  [alert addButtonWithTitle:@"Save"];[alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal]!=NSAlertFirstButtonReturn)return;
  NSString* text=[name.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  BOOL reserved=[text isEqualToString:@"Custom"];
  for(const auto& p:NAMRig::Tuning::factoryTunings())reserved|=[text isEqualToString:[NSString stringWithUTF8String:p.name]];
  if (!text.length || text.length>80 || reserved || (_userTunings[text] && ![text isEqualToString:_currentName])) { _tuningError=@"Choose a new tuning name (1–80 characters).";[self render];return; }
  if(tag==1002)[_userTunings removeObjectForKey:_currentName];
  _userTunings[text]=numbers(_model.strings);_currentName=text;[self savePreferences];[self render];
}
- (void)applyNotes:(id)sender {
  NSString* text=[[_notes.stringValue stringByReplacingOccurrencesOfString:@"♯" withString:@"#"] stringByReplacingOccurrencesOfString:@"♭" withString:@"b"];
  NSArray* tokens=[text componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ,\t\n"]];
  std::vector<int> notes;
  for(NSString* token in tokens) { if(!token.length)continue;int n=NAMRig::Tuning::parseNote(token.UTF8String);if(n<0){_tuningError=@"Use note names with octaves, between B0 and F6.";[self render];return;}notes.push_back(n); }
  if(notes.empty()||notes.size()>12){_tuningError=@"Enter 1–12 notes, from low to high.";[self render];return;}
  _model.strings=notes;_model.locked=-1;_model.clearHistory();_model.resetIntonation();_tuningError=nil;
  if(!_userTunings[_currentName])_currentName=@"Custom";
  [self stopTone];[self rebuildMenu];[self rebuildStrings];[self savePreferences];[self render];
}
- (void)stringClicked:(RigButton*)sender { _model.locked=(int)sender.tag;_model.resetIntonation();_model.clearHistory();[self render];if(_toneOn)[self renewTone]; }
- (void)autoTarget:(id)sender { _model.locked=-1;_model.resetIntonation();_model.clearHistory();[self stopTone];[self render]; }
- (void)controlTextDidBeginEditing:(NSNotification*)notification { if(notification.object==_reference)_referenceEditing=YES; }
- (void)controlTextDidEndEditing:(NSNotification*)notification { if(notification.object==_reference)[self referenceChanged:_reference]; }
- (void)referenceChanged:(NSTextField*)sender {
  NSString* text=[sender.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if([text.lowercaseString hasSuffix:@"hz"])text=[[text substringToIndex:text.length-2] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  NSScanner* scan=[NSScanner scannerWithString:text];double value=0;
  if([scan scanDouble:&value]&&scan.isAtEnd&&std::isfinite(value)&&value>=400&&value<=480) { _model.setReference(value);[self savePreferences];if(_toneOn)[self renewTone]; }
  _referenceEditing=NO;[self render];
}
- (void)referenceStepped:(NSStepper*)sender { _model.setReference(sender.doubleValue);[self savePreferences];[self render];if(_toneOn)[self renewTone]; }
- (void)resetReference:(id)sender { _model.setReference(440);[self savePreferences];[self render];if(_toneOn)[self renewTone]; }
- (void)toneTargetChanged:(id)sender { [self stopTone];[self render]; }
- (void)toneLevelChanged:(NSSlider*)sender { _toneDb=sender.doubleValue;[self savePreferences];[self render];if(_toneOn)[self renewTone]; }
- (void)toggleTone:(id)sender { if(_toneOn)[self stopTone];else if(_active && (_toneTarget.indexOfSelectedItem==0||_model.locked>=0)){_toneOn=YES;[self renewTone];}[self render]; }
- (void)renewTone {
  if(![self validState]||!_active||!self.window){[self stopTone];return;}
  double hz=_toneTarget.indexOfSelectedItem==0?_model.reference:_model.locked>=0?NAMRig::Tuning::frequency(_model.strings[_model.locked],_model.reference):0;
  if(hz<=0){[self stopTone];return;}
  _state->sendTunerProperty(_state->tunerToneGainURID,(float)std::pow(10,_toneDb/20));
  _state->sendTunerProperty(_state->tunerToneURID,(float)hz);_lastLease=CACurrentMediaTime();
}
- (void)stopTone { if(_toneOn&&[self validState])_state->sendTunerProperty(_state->tunerToneURID,0);_toneOn=NO;_toneButton.state=NSControlStateValueOff;_toneButton.primary=NO;_toneButton.title=@"Play reference tone"; }
- (void)clearHistory:(id)sender { _model.clearHistory();[_history update:_model.history now:CACurrentMediaTime()];[self render]; }
- (void)resetIntonation:(id)sender { _model.harmonicBaseline=_baselineMode.indexOfSelectedItem==1;_model.resetIntonation();_model.clearHistory();[self render]; }
- (void)captureBaseline:(id)sender { if(!_toneOn && _model.captureBaseline()){[self stopTone];[self render];} }
- (void)captureFretted:(id)sender { if(!_toneOn && _model.captureFretted()){[self stopTone];[self render];} }
@end
NSView* rigCreateTunerWorkspace(RigUIState* state) { return [[NAMRigTunerWorkspace alloc] initWithState:state]; }
