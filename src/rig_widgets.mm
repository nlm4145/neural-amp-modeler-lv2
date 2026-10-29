#import "rig_widgets.h"
#import "rig_theme.h"
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>

#include "dynamics.h"
#include "pin_eq.h"
#include "power_tube_controls.h"
#include "overdrive.h"
#include "speaker_dynamics.h"
#include <array>
#include <cmath>
#include <algorithm>

// ---- RigKnob ----
// The knob sweeps 270°: min at the 7:30 position, max at 4:30, clockwise.
// All drawing is vector work in drawRect — no images, no layer shadows.

@implementation RigKnob {
  NSPoint _lastDragPoint;
  BOOL _dragging;
  BOOL _hovered;
  NSTrackingArea* _hoverArea;
}

- (BOOL)isFlipped { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }
- (NSSize)intrinsicContentSize { return NSMakeSize(64, 64); }

// NSSlider's cell doesn't know our drawing depends on the value.
- (void)setFloatValue:(float)v { [super setFloatValue:v]; self.needsDisplay = YES; }
- (void)setDoubleValue:(double)v { [super setDoubleValue:v]; self.needsDisplay = YES; }

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_hoverArea) [self removeTrackingArea:_hoverArea];
  _hoverArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow
             owner:self
          userInfo:nil];
  [self addTrackingArea:_hoverArea];
}
- (void)mouseEntered:(NSEvent*)event { _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent*)event { _hovered = NO; self.needsDisplay = YES; }

// Vertical drag replaces the cell's angular tracking: no value jumps when the
// pointer crosses the knob center, and Shift gives a 10x fine mode mid-drag
// (incremental deltas, so toggling Shift can't make the value leap).
- (void)mouseDown:(NSEvent*)event {
  if (!self.enabled) return;
  if ([self.window.firstResponder isKindOfClass:[NSText class]]) {
    [self.window makeFirstResponder:nil];
  }
  if (event.clickCount == 2) {
    self.doubleValue = self.defaultValue;
    [self sendAction:self.action to:self.target];
    return;
  }
  _dragging = YES;
  _lastDragPoint = [self convertPoint:event.locationInWindow fromView:nil];
}

- (void)mouseDragged:(NSEvent*)event {
  if (!_dragging) return;
  const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  const double range = self.maxValue - self.minValue;
  const BOOL fine = (event.modifierFlags & NSEventModifierFlagShift) != 0;
  const double pixelsForFullRange = fine ? 1700.0 : 170.0;
  self.doubleValue += (p.y - _lastDragPoint.y) / pixelsForFullRange * range;
  _lastDragPoint = p;
  if (self.continuous) [self sendAction:self.action to:self.target];
}

- (void)mouseUp:(NSEvent*)event {
  if (_dragging && !self.continuous) [self sendAction:self.action to:self.target];
  _dragging = NO;
}

- (void)scrollWheel:(NSEvent*)event {
  if (!self.enabled) return;
  const double dy = event.scrollingDeltaY;
  if (dy == 0.0) return;
  const double range = self.maxValue - self.minValue;
  const double step = range / (event.hasPreciseScrollingDeltas ? 600.0 : 120.0);
  const BOOL fine = (event.modifierFlags & NSEventModifierFlagShift) != 0;
  self.doubleValue += dy * step * (fine ? 0.1 : 1.0);
  [self sendAction:self.action to:self.target];
}

- (void)setColorStyle:(RigKnobColorStyle)colorStyle {
  _colorStyle = colorStyle;
  self.needsDisplay = YES;
}

RigKnobColorStyle rigKnobColorStyleForPort(uint32_t port) {
  switch (port) {
    case 22: // Amp Drive
    case 34: // Presence
    case 35: // Depth
    case 39: // Bright
    case 40: // Input EQ
    case 41: // Master
    case 43: // Speaker Drive
    case 45: // Speaker Thump
      return RigKnobColorStyleWarm;
    case 15: // Gate
    case 23: // Release
    case 28: // Comp
    case 36: // Sag
    case 37: // Bias
    case 38: // Neg Fdbk
    case 44: // Speaker Comp
    case 46: // Speaker Resonance
    case 81: // Power Tube Character
      return RigKnobColorStyleDynamics;
    case 32: // Width
    case 33: // Room
    case 50: // Delay Time
    case 51: // Delay Feedback
    case 52: // Delay Damping
    case 53: // Delay Mix
    case 54: // Reverb Mix
    case 55: // Reverb Decay
    case 56: // Reverb Size
    case 57: // Reverb Damping
    case 58: // Reverb Pre-delay
      return RigKnobColorStyleSpatial;
    default:
      return RigKnobColorStyleDefault;
  }
}

- (void)drawRect:(NSRect)dirty {
  const NSRect b = self.bounds;
  const CGFloat side = MIN(NSWidth(b), NSHeight(b));
  const NSPoint c = NSMakePoint(NSMidX(b), NSMidY(b));
  const double range = self.maxValue - self.minValue;
  double t = range > 0.0 ? (self.doubleValue - self.minValue) / range : 0.0;
  t = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);

  NSColor* lowColor = nil;
  NSColor* highColor = nil;
  switch (self.colorStyle) {
    case RigKnobColorStyleWarm:
      lowColor = [NSColor colorWithSRGBRed:0.96 green:0.68 blue:0.18 alpha:1.0];
      highColor = [NSColor colorWithSRGBRed:1.00 green:0.35 blue:0.10 alpha:1.0];
      break;
    case RigKnobColorStyleSpatial:
      lowColor = [NSColor colorWithSRGBRed:0.66 green:0.42 blue:0.98 alpha:1.0];
      highColor = [NSColor colorWithSRGBRed:0.94 green:0.38 blue:0.90 alpha:1.0];
      break;
    case RigKnobColorStyleDynamics:
      lowColor = [NSColor colorWithSRGBRed:0.20 green:0.86 blue:0.55 alpha:1.0];
      highColor = [NSColor colorWithSRGBRed:0.15 green:0.92 blue:0.82 alpha:1.0];
      break;
    case RigKnobColorStyleDefault:
    default:
      lowColor = [NSColor colorWithSRGBRed:0.22 green:0.72 blue:0.98 alpha:1.0];
      highColor = [NSColor colorWithSRGBRed:0.30 green:0.88 blue:1.00 alpha:1.0];
      break;
  }
  NSColor* valueColor = [lowColor blendedColorWithFraction:(CGFloat)t ofColor:highColor];
  if (_hovered) {
    valueColor = [valueColor blendedColorWithFraction:0.20 ofColor:NSColor.whiteColor];
  }
  const CGFloat arcRadius = side * 0.5 - 4.0;
  const CGFloat valueAngle = 225.0 - 270.0 * (CGFloat)t;

  NSBezierPath* track = [NSBezierPath bezierPath];
  [track appendBezierPathWithArcWithCenter:c radius:arcRadius
                                startAngle:225.0 endAngle:-45.0 clockwise:YES];
  track.lineWidth = 3.0;
  track.lineCapStyle = NSLineCapStyleRound;
  [[NSColor colorWithWhite:1.0 alpha:_hovered ? 0.15 : 0.10] setStroke];
  [track stroke];

  // Two passes read as a glow without a (costly) layer shadow.
  if (t > 0.001) {
    NSBezierPath* arc = [NSBezierPath bezierPath];
    [arc appendBezierPathWithArcWithCenter:c radius:arcRadius
                                startAngle:225.0 endAngle:valueAngle clockwise:YES];
    arc.lineCapStyle = NSLineCapStyleRound;
    arc.lineWidth = 5.0;
    [[valueColor colorWithAlphaComponent:0.16] setStroke];
    [arc stroke];
    arc.lineWidth = 2.5;
    [valueColor setStroke];
    [arc stroke];
  }

  const CGFloat faceRadius = side * 0.5 - 10.0;
  NSRect faceRect = NSMakeRect(c.x - faceRadius, c.y - faceRadius,
                               faceRadius * 2.0, faceRadius * 2.0);
  NSBezierPath* face = [NSBezierPath bezierPathWithOvalInRect:faceRect];
  NSGradient* g = [[NSGradient alloc]
      initWithStartingColor:[NSColor colorWithSRGBRed:0.098 green:0.106 blue:0.137 alpha:1.0]
                endingColor:[NSColor colorWithSRGBRed:0.212 green:0.227 blue:0.278 alpha:1.0]];
  [g drawInBezierPath:face angle:90.0];
  face.lineWidth = 1.0;
  [(_hovered ? [valueColor colorWithAlphaComponent:0.45]
             : [NSColor colorWithWhite:0.0 alpha:0.55]) setStroke];
  [face stroke];

  NSBezierPath* sheen = [NSBezierPath bezierPath];
  [sheen appendBezierPathWithArcWithCenter:c radius:faceRadius - 1.0
                                startAngle:35.0 endAngle:145.0 clockwise:NO];
  sheen.lineWidth = 1.0;
  [[NSColor colorWithWhite:1.0 alpha:0.10] setStroke];
  [sheen stroke];

  const double rad = valueAngle * M_PI / 180.0;
  NSBezierPath* pointer = [NSBezierPath bezierPath];
  [pointer moveToPoint:NSMakePoint(c.x + std::cos(rad) * faceRadius * 0.35,
                                   c.y + std::sin(rad) * faceRadius * 0.35)];
  [pointer lineToPoint:NSMakePoint(c.x + std::cos(rad) * (faceRadius - 3.5),
                                   c.y + std::sin(rad) * (faceRadius - 3.5))];
  pointer.lineWidth = 2.5;
  pointer.lineCapStyle = NSLineCapStyleRound;
  [rigText() setStroke];
  [pointer stroke];
}
@end

// ---- RigPanel ----

@implementation RigPanel
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) _cornerRadius = 10.0;
  return self;
}
- (void)setCornerRadius:(CGFloat)radius { _cornerRadius = radius; self.needsDisplay = YES; }
- (void)setShowsSelection:(BOOL)showsSelection {
  if (_showsSelection != showsSelection) {
    _showsSelection = showsSelection;
    self.needsDisplay = YES;
    if (self.layer) {
      [self.layer setNeedsDisplay];
    }
  }
}
- (NSView *)hitTest:(NSPoint)point {
  NSView *hit = [super hitTest:point];
  // If clicked inside panel on whitespace or on an NSImageView (artwork), return self so panel receives mouseDown:
  if (hit && ([hit isKindOfClass:[NSImageView class]] || hit == self)) {
    return self;
  }
  return hit;
}
- (void)mouseDown:(NSEvent*)event {
  if (_onClickWithEvent) {
    _onClickWithEvent(event, self);
  } else if (_onClick) {
    _onClick();
  }
  [super mouseDown:event];
}
- (void)drawRect:(NSRect)dirty {
  NSRect r = NSInsetRect(self.bounds, 0.5, 0.5);
  NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:r
                                                    xRadius:_cornerRadius
                                                    yRadius:_cornerRadius];
  NSGradient* g = [[NSGradient alloc] initWithStartingColor:rigPanelBottom()
                                                endingColor:rigPanelTop()];
  [g drawInBezierPath:p angle:90.0];
  if (_showsSelection) {
    p.lineWidth = 1.5;
    NSColor* selColor = _selectionBorderColor ?: [NSColor colorWithSRGBRed:1.00 green:0.86 blue:0.18 alpha:1.0];
    [selColor setStroke];
    [p stroke];
  } else {
    p.lineWidth = 1.0;
    [rigPanelBorder() setStroke];
    [p stroke];
  }
}
@end

// ---- RigPopUpButton ----

@implementation RigPopUpButton
- (void)setShowsSelection:(BOOL)showsSelection {
  if (_showsSelection != showsSelection) {
    _showsSelection = showsSelection;
    self.needsDisplay = YES;
    if (self.layer) {
      [self.layer setNeedsDisplay];
    }
  }
}

- (void)mouseDown:(NSEvent*)event {
  if (_onClick) {
    _onClick();
  }
  [super mouseDown:event];
}

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
  if (_showsSelection) {
    NSRect r = NSInsetRect(self.bounds, 1.0, 1.0);
    NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:4.0 yRadius:4.0];
    p.lineWidth = 1.5;
    NSColor* selColor = _selectionBorderColor ?: [NSColor colorWithSRGBRed:1.00 green:0.86 blue:0.18 alpha:1.0];
    [selColor setStroke];
    [p stroke];
  }
}
@end

// ---- RigButton ----

@implementation RigButton {
  BOOL _hovered;
  NSTrackingArea* _hoverArea;
}
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_hoverArea) [self removeTrackingArea:_hoverArea];
  _hoverArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow
             owner:self
          userInfo:nil];
  [self addTrackingArea:_hoverArea];
}
- (void)mouseEntered:(NSEvent*)event { _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent*)event { _hovered = NO; self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirty {
  NSRect r = NSInsetRect(self.bounds, 0.5, 0.5);
  const CGFloat radius = MIN(7.0, NSHeight(r) * 0.5);
  NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius];
  const BOOL on = self.state == NSControlStateValueOn;

  NSColor* border;
  if (self.primary) {
    NSColor* base = self.customTextColor
        ? [self.customTextColor blendedColorWithFraction:0.74 ofColor:NSColor.blackColor]
        : (on ? rigAccent() : rigAccentDim());
    if (self.isHighlighted) base = [base blendedColorWithFraction:0.22 ofColor:NSColor.blackColor];
    else if (_hovered) base = [base blendedColorWithFraction:0.10 ofColor:NSColor.whiteColor];
    NSGradient* g = [[NSGradient alloc]
        initWithStartingColor:[base blendedColorWithFraction:0.10 ofColor:NSColor.blackColor]
                  endingColor:base];
    [g drawInBezierPath:p angle:90.0];
    border = self.customTextColor
        ? [self.customTextColor colorWithAlphaComponent:0.65]
        : [base blendedColorWithFraction:0.22 ofColor:NSColor.whiteColor];
  } else {
    NSColor* fill = on ? [rigAccent() colorWithAlphaComponent:0.20]
                       : (self.isHighlighted ? rigRaised()
                                             : (_hovered ? [rigRaised() colorWithAlphaComponent:0.85]
                                                         : rigBG()));
    [fill setFill];
    [p fill];
    border = on ? [rigAccent() colorWithAlphaComponent:0.65]
                : ((_hovered || self.isHighlighted) ? [rigAccent() colorWithAlphaComponent:0.40]
                                                    : rigPanelBorder());
  }
  p.lineWidth = 1.0;
  [border setStroke];
  [p stroke];

  CGFloat textLeft = NSMinX(r) + 4.0;
  CGFloat textRight = NSMaxX(r) - 4.0;
  if (self.check) {
    const CGFloat d = 6.0;
    NSRect dot = NSMakeRect(NSMinX(r) + 9.0, NSMidY(r) - d * 0.5, d, d);
    NSColor* dotColor = self.customTextColor ?: rigGreen();
    NSColor* dc = on ? dotColor : [rigDimText() colorWithAlphaComponent:0.5];
    if (on) {
      [[dotColor colorWithAlphaComponent:0.30] setFill];
      [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dot, -2.5, -2.5)] fill];
    }
    [dc setFill];
    [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
    textLeft = NSMinX(r) + 18.0;
  }

  NSString* title = self.title;
  if (title.length) {
    NSMutableParagraphStyle* ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSColor* tc;
    if (self.customTextColor) {
      tc = self.primary ? self.customTextColor
                        : (_hovered ? self.customTextColor : [self.customTextColor colorWithAlphaComponent:0.85]);
    } else {
      tc = self.primary ? NSColor.whiteColor
                        : ((_hovered || self.isHighlighted || on) ? rigText() : rigDimText());
    }
    if (!self.enabled) tc = [rigDimText() colorWithAlphaComponent:0.5];
    NSDictionary* attrs = @{
      NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
      NSForegroundColorAttributeName: tc,
      NSParagraphStyleAttributeName: ps,
    };
    const NSSize ts = [title sizeWithAttributes:attrs];
    NSRect tr = NSMakeRect(textLeft, NSMidY(self.bounds) - ts.height * 0.5,
                           textRight - textLeft, ts.height);
    [title drawInRect:tr withAttributes:attrs];
  }
}
@end

// ---- Image helpers ----

static NSImage* thumbnailFromSource(CGImageSourceRef source, CGFloat maxPixelSize) {
  if (!source) return nil;
  NSDictionary* options = @{
    (__bridge NSString*)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
    (__bridge NSString*)kCGImageSourceCreateThumbnailWithTransform: @YES,
    (__bridge NSString*)kCGImageSourceShouldCacheImmediately: @YES,
    (__bridge NSString*)kCGImageSourceThumbnailMaxPixelSize: @(maxPixelSize),
  };
  CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
  if (!cg) return nil;
  NSImage* image = [[NSImage alloc] initWithCGImage:cg size:NSZeroSize];
  CGImageRelease(cg);
  return image;
}

NSImage* rigThumbnailFromFile(NSString* path, CGFloat maxPixelSize) {
  if (!path.length) return nil;
  NSURL* url = [NSURL fileURLWithPath:path];
  CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
  NSImage* image = thumbnailFromSource(source, maxPixelSize);
  if (source) CFRelease(source);
  return image;
}

NSImage* rigThumbnailFromData(NSData* data, CGFloat maxPixelSize) {
  if (!data.length) return nil;
  CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
  NSImage* image = thumbnailFromSource(source, maxPixelSize);
  if (source) CFRelease(source);
  return image;
}

void rigApplyTracking(NSTextField* label, CGFloat kern) {
  if (!label.stringValue.length) return;
  NSMutableAttributedString* s = [label.attributedStringValue mutableCopy];
  [s addAttribute:NSKernAttributeName value:@(kern) range:NSMakeRange(0, s.length)];
  label.attributedStringValue = s;
}

// ==============================================================================
// Studio Deck Hardware Visualizers
// ==============================================================================

// ---- NAMPinEQEditor ----
// Shared plot mapping for the frequency graphs that host pins: x is log
// frequency 20 Hz..20 kHz, y is +/-kPinGainMax dB around the vertical center.
static constexpr double kPinPlotRate = 192000.0;  // drawing reference, near-analog up to 20 kHz
static CGFloat pinPlotX(NSRect plot, double hz) {
  return NSMinX(plot) + std::log(hz / 20.0) / std::log(1000.0) * plot.size.width;
}
static CGFloat pinPlotY(NSRect plot, double db) {
  const double g = std::max<double>(-NAMRig::kPinGainMax, std::min<double>(NAMRig::kPinGainMax, db));
  return NSMidY(plot) + g / NAMRig::kPinGainMax * plot.size.height * 0.5;
}

@implementation NAMPinEQEditor {
  std::array<float, NAMRig::kPinEqPanePorts> _values;
  NSColor* _accent;
  NSInteger _hover;
  NSInteger _drag;
  BOOL _dragMoved;
  NSPoint _dragOffset;
  BOOL _mouseInside;
  NSTrackingArea* _tracking;
}

- (instancetype)initWithPane:(NAMRig::PinEqPane)pane accent:(NSColor*)accent {
  if ((self = [super initWithFrame:NSZeroRect])) {
    _pane = pane;
    _accent = accent ?: [NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:1.0];
    for (size_t i = 0; i < _values.size(); ++i)
      _values[i] = NAMRig::pinEqDefault([self portForIndex:i]);
    _hover = _drag = -1;
    self.toolTip = @"Pin EQ: double-click to add a pin (up to 6). Drag a pin to set frequency and gain, "
                   @"scroll over it to set its width (Q), right-click for bell / low shelf / high shelf, "
                   @"double-click a pin to remove it.";
  }
  return self;
}

- (BOOL)isFlipped { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (uint32_t)portForIndex:(size_t)i { return NAMRig::pinEqPort(_pane, 0, 0) + (uint32_t)i; }
- (uint32_t)portForBand:(NSInteger)band param:(size_t)param {
  return NAMRig::pinEqPort(_pane, (size_t)band, param);
}
- (float)band:(NSInteger)band param:(size_t)param {
  return _values[(size_t)band * NAMRig::kPinEqBandParams + param];
}
- (BOOL)hasPin:(NSInteger)band { return (int)[self band:band param:NAMRig::kPinShape] != NAMRig::kPinOff; }

- (NAMRig::PinBands)bands {
  return NAMRig::readPinBands(_pane, [&](uint32_t port) {
    return _values[port - NAMRig::pinEqPort(_pane, 0, 0)];
  });
}

- (void)setPortValue:(float)value forPort:(uint32_t)port {
  if (!NAMRig::isPinEqPort(port) || NAMRig::pinEqPaneOf(port) != (size_t)_pane) return;
  const float v = NAMRig::clampPinEqValue(port, value);
  float& slot = _values[port - NAMRig::pinEqPort(_pane, 0, 0)];
  if (slot == v) return;
  slot = v;
  self.needsDisplay = YES;
}

- (void)send:(NSInteger)band param:(size_t)param value:(float)value {
  const uint32_t port = [self portForBand:band param:param];
  const float v = NAMRig::clampPinEqValue(port, value);
  _values[port - NAMRig::pinEqPort(_pane, 0, 0)] = v;
  if (self.onChange) self.onChange(port, v);
  self.needsDisplay = YES;
}

- (void)commit {
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(commit) object:nil];
  if (self.onCommit) self.onCommit();
}

// ---- geometry ----
- (NSRect)plotRect { return NSInsetRect(self.bounds, kPinEditorInset, kPinEditorInset); }
- (double)responseDbAtFrequency:(double)hz {
  const double base = self.baseResponseDb ? self.baseResponseDb(hz) : 0;
  return base + NAMRig::pinBandsMagnitudeDb([self bands], hz, kPinPlotRate);
}
- (NSPoint)pointForBand:(NSInteger)band {
  const NSRect plot = [self plotRect];
  const double hz = [self band:band param:NAMRig::kPinFreq];
  return NSMakePoint(pinPlotX(plot, hz), pinPlotY(plot, [self responseDbAtFrequency:hz]));
}
// Solve the selected band's gain against the complete response. Other bands
// and the processor's cut filters remain part of the curve under the cursor.
- (float)gainForBand:(NSInteger)band frequency:(double)hz response:(double)desired {
  auto bands = [self bands];
  const auto own = bands[(size_t)band];
  bands[(size_t)band].shape = NAMRig::kPinOff;
  const double base = (self.baseResponseDb ? self.baseResponseDb(hz) : 0) +
      NAMRig::pinBandsMagnitudeDb(bands, hz, kPinPlotRate);
  const int shape = own.shape == NAMRig::kPinOff ? NAMRig::kPinBell : own.shape;
  const double q = own.shape == NAMRig::kPinOff ? NAMRig::kPinQDefault : own.q;
  double low = -NAMRig::kPinGainMax, high = NAMRig::kPinGainMax;
  for (int i = 0; i < 30; ++i) {
    double gain = (low + high) * .5;
    double response = base + NAMRig::pinMagnitudeDb(
        NAMRig::pinCoefficients(shape, hz, gain, q, kPinPlotRate), hz, kPinPlotRate);
    if (response < desired) low = gain;
    else high = gain;
  }
  return (float)((low + high) * .5);
}
- (double)freqAtX:(CGFloat)x {
  const NSRect plot = [self plotRect];
  const double t = std::clamp((x - NSMinX(plot)) / std::max<CGFloat>(1.0, plot.size.width), 0.0, 1.0);
  return 20.0 * std::pow(1000.0, t);
}
- (double)gainAtY:(CGFloat)y {
  const NSRect plot = [self plotRect];
  const double t = (y - NSMidY(plot)) / std::max<CGFloat>(1.0, plot.size.height * 0.5);
  return std::clamp(t, -1.0, 1.0) * NAMRig::kPinGainMax;
}
- (NSInteger)pinAtPoint:(NSPoint)p {
  NSInteger best = -1;
  CGFloat bestDist = 9.0;
  for (NSInteger b = 0; b < (NSInteger)NAMRig::kPinEqBandCount; ++b) {
    if (![self hasPin:b]) continue;
    const NSPoint c = [self pointForBand:b];
    const CGFloat d = std::hypot(c.x - p.x, c.y - p.y);
    if (d < bestDist) { bestDist = d; best = b; }
  }
  return best;
}

// ---- drawing ----
- (void)drawRect:(NSRect)dirty {
  const NSRect plot = [self plotRect];
  if (plot.size.width < 10 || plot.size.height < 10) return;
  BOOL any = NO;
  for (NSInteger b = 0; b < (NSInteger)NAMRig::kPinEqBandCount; ++b) any |= [self hasPin:b];

  if (any || self.baseResponseDb) {
    NSBezierPath* curve = [NSBezierPath bezierPath];
    const int n = std::max(48, (int)(plot.size.width / 2.0));
    for (int i = 0; i <= n; ++i) {
      const double t = (double)i / n;
      const double hz = 20.0 * std::pow(1000.0, t);
      const NSPoint p = NSMakePoint(NSMinX(plot) + t * plot.size.width,
                                    pinPlotY(plot, [self responseDbAtFrequency:hz]));
      if (i == 0) [curve moveToPoint:p];
      else [curve lineToPoint:p];
    }
    NSBezierPath* fill = [curve copy];
    const CGFloat floor = self.baseResponseDb ? NSMinY(plot) : NSMidY(plot);
    [fill lineToPoint:NSMakePoint(NSMaxX(plot), floor)];
    [fill lineToPoint:NSMakePoint(NSMinX(plot), floor)];
    [fill closePath];
    if (self.baseResponseDb) {
      NSGradient* gradient = [[NSGradient alloc] initWithStartingColor:[_accent colorWithAlphaComponent:.30]
          endingColor:[_accent colorWithAlphaComponent:.02]];
      [gradient drawInBezierPath:fill angle:270];
    } else {
      [[_accent colorWithAlphaComponent:.10] setFill];
      [fill fill];
    }
    curve.lineWidth = 2.0;
    curve.lineJoinStyle = NSLineJoinStyleRound;
    [[_accent colorWithAlphaComponent:.95] setStroke];
    [curve stroke];
  }
  if (!any && _mouseInside) {
    NSDictionary* hintAttrs = @{
      NSFontAttributeName: [NSFont systemFontOfSize:8.0 weight:NSFontWeightMedium],
      NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.75 green:0.80 blue:0.90 alpha:0.55]
    };
    NSString* hint = @"DOUBLE-CLICK TO ADD A PIN";
    const NSSize sz = [hint sizeWithAttributes:hintAttrs];
    [hint drawAtPoint:NSMakePoint(NSMidX(plot) - sz.width * 0.5, NSMinY(plot) + 2.0) withAttributes:hintAttrs];
  }

  NSDictionary* numAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:7.0 weight:NSFontWeightHeavy],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.06 green:0.07 blue:0.09 alpha:1.0]
  };
  for (NSInteger b = 0; b < (NSInteger)NAMRig::kPinEqBandCount; ++b) {
    if (![self hasPin:b]) continue;
    const NSPoint c = [self pointForBand:b];
    const BOOL hot = (b == _hover || b == _drag);
    const CGFloat r = hot ? 6.5 : 5.5;
    NSBezierPath* dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - r, c.y - r, 2 * r, 2 * r)];
    [(hot ? [_accent highlightWithLevel:0.35] : _accent) setFill];
    [dot fill];
    dot.lineWidth = hot ? 1.5 : 1.0;
    [[NSColor colorWithWhite:1.0 alpha:hot ? 0.95 : 0.55] setStroke];
    [dot stroke];
    NSString* num = [NSString stringWithFormat:@"%ld", (long)b + 1];
    const NSSize sz = [num sizeWithAttributes:numAttrs];
    [num drawAtPoint:NSMakePoint(c.x - sz.width * 0.5, c.y - sz.height * 0.5) withAttributes:numAttrs];
  }

  const NSInteger shown = _drag >= 0 ? _drag : _hover;
  if (shown >= 0 && [self hasPin:shown]) {
    static NSString* const kShapeNames[] = {@"OFF", @"BELL", @"LOW SHELF", @"HIGH SHELF"};
    const double hz = [self band:shown param:NAMRig::kPinFreq];
    NSString* freq = hz >= 1000.0 ? [NSString stringWithFormat:@"%.2f kHz", hz / 1000.0]
                                  : [NSString stringWithFormat:@"%.0f Hz", hz];
    NSString* text = [NSString stringWithFormat:@"%ld · %@ · %@ · %+.1f dB · Q %.2f", (long)shown + 1,
                      kShapeNames[(int)[self band:shown param:NAMRig::kPinShape]], freq,
                      [self band:shown param:NAMRig::kPinGain], [self band:shown param:NAMRig::kPinQ]];
    NSDictionary* attrs = @{
      NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.0 weight:NSFontWeightSemibold],
      NSForegroundColorAttributeName: [NSColor colorWithWhite:0.96 alpha:1.0]
    };
    const NSSize sz = [text sizeWithAttributes:attrs];
    NSRect box = NSMakeRect(NSMaxX(plot) - sz.width - 8.0, NSMaxY(plot) - sz.height - 3.0,
                            sz.width + 8.0, sz.height + 3.0);
    box.origin.x = std::max(NSMinX(plot), box.origin.x);
    [[NSColor colorWithSRGBRed:0.04 green:0.05 blue:0.07 alpha:0.85] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:box xRadius:3.0 yRadius:3.0] fill];
    [text drawAtPoint:NSMakePoint(NSMinX(box) + 4.0, NSMinY(box) + 1.5) withAttributes:attrs];
  }
}

// ---- tracking ----
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_tracking) [self removeTrackingArea:_tracking];
  _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
      options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
              NSTrackingActiveAlways | NSTrackingInVisibleRect
      owner:self userInfo:nil];
  [self addTrackingArea:_tracking];
}
- (void)mouseEntered:(NSEvent*)event { _mouseInside = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent*)event {
  _mouseInside = NO;
  _hover = -1;
  self.needsDisplay = YES;
}
- (void)mouseMoved:(NSEvent*)event {
  const NSInteger hit = [self pinAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
  if (hit != _hover) {
    _hover = hit;
    self.needsDisplay = YES;
  }
}

// ---- editing ----
- (void)addPinAt:(NSPoint)p {
  for (NSInteger b = 0; b < (NSInteger)NAMRig::kPinEqBandCount; ++b) {
    if ([self hasPin:b]) continue;
    const double hz = [self freqAtX:p.x];
    const float gain = [self gainForBand:b frequency:hz response:[self gainAtY:p.y]];
    [self send:b param:NAMRig::kPinFreq value:(float)hz];
    [self send:b param:NAMRig::kPinGain value:gain];
    [self send:b param:NAMRig::kPinQ value:NAMRig::kPinQDefault];
    [self send:b param:NAMRig::kPinShape value:(float)NAMRig::kPinBell];
    _hover = b;
    [self commit];
    return;
  }
  NSBeep();
}
- (void)removePin:(NSInteger)band {
  // Frequency and Q stay put so the DSP fades the band out without sweeping it.
  [self send:band param:NAMRig::kPinShape value:(float)NAMRig::kPinOff];
  [self send:band param:NAMRig::kPinGain value:0.0f];
  if (_hover == band) _hover = -1;
  [self commit];
}

- (void)mouseDown:(NSEvent*)event {
  const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  const NSInteger hit = [self pinAtPoint:p];
  if (event.clickCount >= 2) {
    if (hit >= 0) [self removePin:hit];
    else [self addPinAt:p];
    return;
  }
  _drag = hit;
  if (hit >= 0) {
    NSPoint center = [self pointForBand:hit];
    _dragOffset = NSMakePoint(center.x - p.x, center.y - p.y);
  }
  _dragMoved = NO;
  self.needsDisplay = YES;
}
- (void)mouseDragged:(NSEvent*)event {
  if (_drag < 0) return;
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  p.x += _dragOffset.x;
  p.y += _dragOffset.y;
  const double hz = [self freqAtX:p.x];
  const float gain = [self gainForBand:_drag frequency:hz response:[self gainAtY:p.y]];
  [self send:_drag param:NAMRig::kPinFreq value:(float)hz];
  [self send:_drag param:NAMRig::kPinGain value:gain];
  _dragMoved = YES;
}
- (void)mouseUp:(NSEvent*)event {
  if (_drag >= 0 && _dragMoved) [self commit];
  _hover = [self pinAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
  _drag = -1;
  self.needsDisplay = YES;
}

- (void)scrollWheel:(NSEvent*)event {
  const NSInteger band = _drag >= 0 ? _drag
      : [self pinAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
  if (band < 0) {
    [super scrollWheel:event];
    return;
  }
  const double dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.1 : event.scrollingDeltaY;
  if (dy == 0.0) return;
  const double q = [self band:band param:NAMRig::kPinQ] * std::exp(dy * 0.08);
  [self send:band param:NAMRig::kPinQ value:(float)q];
  _hover = band;
  // Scroll arrives as a stream of events; mark the preset modified once it settles.
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(commit) object:nil];
  [self performSelector:@selector(commit) withObject:nil afterDelay:0.35];
}

- (NSMenu*)menuForEvent:(NSEvent*)event {
  const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  const NSInteger hit = [self pinAtPoint:p];
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Pin"];
  menu.autoenablesItems = NO;
  if (hit >= 0) {
    const int shape = (int)[self band:hit param:NAMRig::kPinShape];
    NSArray<NSString*>* titles = @[@"Bell", @"Low Shelf", @"High Shelf"];
    for (int s = NAMRig::kPinBell; s <= NAMRig::kPinHighShelf; ++s) {
      NSMenuItem* item = [menu addItemWithTitle:titles[(NSUInteger)(s - 1)]
                                         action:@selector(pinShapeChosen:) keyEquivalent:@""];
      item.target = self;
      item.tag = hit * 16 + s;
      item.state = s == shape ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* flat = [menu addItemWithTitle:@"Reset Gain & Width" action:@selector(pinResetChosen:) keyEquivalent:@""];
    flat.target = self;
    flat.tag = hit;
    NSMenuItem* remove = [menu addItemWithTitle:@"Remove Pin" action:@selector(pinRemoveChosen:) keyEquivalent:@""];
    remove.target = self;
    remove.tag = hit;
  } else {
    NSMenuItem* add = [menu addItemWithTitle:@"Add Pin Here" action:@selector(pinAddChosen:) keyEquivalent:@""];
    add.target = self;
    add.representedObject = [NSValue valueWithPoint:p];
    BOOL any = NO, full = YES;
    for (NSInteger b = 0; b < (NSInteger)NAMRig::kPinEqBandCount; ++b) {
      any |= [self hasPin:b];
      full &= [self hasPin:b];
    }
    add.enabled = !full;
    NSMenuItem* clear = [menu addItemWithTitle:@"Remove All Pins" action:@selector(pinClearChosen:) keyEquivalent:@""];
    clear.target = self;
    clear.enabled = any;
  }
  return menu;
}
- (void)pinShapeChosen:(NSMenuItem*)item {
  [self send:item.tag / 16 param:NAMRig::kPinShape value:(float)(item.tag % 16)];
  [self commit];
}
- (void)pinResetChosen:(NSMenuItem*)item {
  [self send:item.tag param:NAMRig::kPinGain value:0.0f];
  [self send:item.tag param:NAMRig::kPinQ value:NAMRig::kPinQDefault];
  [self commit];
}
- (void)pinRemoveChosen:(NSMenuItem*)item { [self removePin:item.tag]; }
- (void)pinAddChosen:(NSMenuItem*)item { [self addPinAt:[item.representedObject pointValue]]; }
- (void)pinClearChosen:(NSMenuItem*)item {
  for (NSInteger b = 0; b < (NSInteger)NAMRig::kPinEqBandCount; ++b)
    if ([self hasPin:b]) [self removePin:b];
}
@end

@implementation NAMGraphControlPin
@end

@implementation NAMInteractiveGraph
- (double)responseDbAtFrequency:(double)hz { return 0; }
- (NSPoint)controlPointForIndex:(NSUInteger)index { return NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds)); }
- (void)viewWillDraw {
  [super viewWillDraw];
  for (NSView* view in self.subviews)
    if ([view isKindOfClass:NAMGraphControlEditor.class] || [view isKindOfClass:NAMPinEQEditor.class])
      view.needsDisplay = YES;
}
@end

@implementation NAMGraphControlEditor {
  NAMGraphControlPin* _activePin;
  NSPoint _lastPoint;
  NSPoint _delta;
}
- (BOOL)isFlipped { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }
- (NSPoint)pointForPin:(NSUInteger)index {
  NSPoint point = self.pins[index].position(self.bounds);
  point.x = std::clamp(point.x, 8.0, MAX(8.0, NSWidth(self.bounds) - 8));
  point.y = std::clamp(point.y, 8.0, MAX(8.0, NSHeight(self.bounds) - 56));
  return point;
}
- (NSInteger)pinAtPoint:(NSPoint)point {
  NSInteger found = -1;
  CGFloat distance = 12;
  for (NSUInteger i = 0; i < self.pins.count; ++i) {
    NAMGraphControlPin* pin = self.pins[i];
    if (pin.isEnabled && !pin.isEnabled()) continue;
    NSPoint p = [self pointForPin:i];
    CGFloat d = std::hypot(p.x - point.x, p.y - point.y);
    if (d < distance) { distance = d; found = (NSInteger)i; }
  }
  return found;
}
- (NSView*)hitTest:(NSPoint)point {
  if (self.hidden) return nil;
  NSPoint local = [self convertPoint:point fromView:self.superview];
  return NSPointInRect(local, self.bounds) && [self pinAtPoint:local] >= 0 ? self : nil;
}
- (void)resetCursorRects {
  for (NSUInteger i = 0; i < self.pins.count; ++i) {
    NAMGraphControlPin* pin = self.pins[i];
    if (pin.isEnabled && !pin.isEnabled()) continue;
    NSPoint p = [self pointForPin:i];
    [self addCursorRect:NSMakeRect(p.x - 12, p.y - 12, 24, 24) cursor:NSCursor.openHandCursor];
  }
}
- (void)mouseDown:(NSEvent*)event {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  NSInteger index = [self pinAtPoint:point];
  if (index < 0) return;
  _activePin = self.pins[(NSUInteger)index];
  _lastPoint = point;
  _delta = NSZeroPoint;
  if (_activePin.onBegin) _activePin.onBegin();
}
- (void)mouseDragged:(NSEvent*)event {
  if (!_activePin) return;
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  CGFloat fine = (event.modifierFlags & NSEventModifierFlagShift) ? 0.1 : 1;
  _delta.x += fine * (p.x - _lastPoint.x) / MAX(1.0, NSWidth(self.bounds));
  _delta.y += fine * (p.y - _lastPoint.y) / MAX(1.0, NSHeight(self.bounds));
  _lastPoint = p;
  if (_activePin.onDrag) _activePin.onDrag(_delta);
  self.needsDisplay = YES;
}
- (void)mouseUp:(NSEvent*)event {
  if (_activePin.onCommit) _activePin.onCommit();
  _activePin = nil;
  [self.window invalidateCursorRectsForView:self];
}
- (void)drawRect:(NSRect)dirty {
  NSMutableArray<NSValue*>* labels = [NSMutableArray array];
  for (NSUInteger i = 0; i < self.pins.count; ++i) {
    NAMGraphControlPin* pin = self.pins[i];
    BOOL enabled = !pin.isEnabled || pin.isEnabled();
    NSPoint p = [self pointForPin:i];
    NSColor* color = enabled ? rigOrange() : rigDimText();
    NSBezierPath* dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - 5, p.y - 5, 10, 10)];
    [rigBG() setFill];
    [dot fill];
    [color setStroke];
    dot.lineWidth = 2;
    [dot stroke];
    NSDictionary* attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:8 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: color};
    NSSize size = [pin.label sizeWithAttributes:attributes];
    CGFloat x = p.x + 9;
    if (x + size.width > NSWidth(self.bounds) - 4) x = p.x - size.width - 9;
    NSRect label = NSMakeRect(MAX(4.0, x), pin.labelBelow ? p.y - size.height - 8 : p.y + 7,
        MIN(size.width + 4, NSWidth(self.bounds) - 8), size.height);
    const CGFloat labelFloor = MIN(44.0, MAX(4.0, NSHeight(self.bounds) - 80));
    label.origin.y = std::clamp(label.origin.y, labelFloor, MAX(labelFloor, NSHeight(self.bounds) - 50 - size.height));
    for (int attempt = 0; attempt < 8; ++attempt) {
      BOOL collision = NO;
      for (NSValue* placed in labels) collision |= NSIntersectsRect(NSInsetRect(label, -3, -2), placed.rectValue);
      for (NSUInteger j = 0; j < self.pins.count; ++j) {
        NSPoint marker = [self pointForPin:j];
        collision |= NSIntersectsRect(label, NSMakeRect(marker.x - 7, marker.y - 7, 14, 14));
      }
      if (!collision) break;
      label.origin.y -= size.height + 5;
      if (label.origin.y < labelFloor) label.origin.y = MIN(p.y + 22, NSHeight(self.bounds) - 50 - size.height);
    }
    [labels addObject:[NSValue valueWithRect:label]];
    if (std::abs(NSMidY(label) - p.y) > 24) {
      NSBezierPath* connector = [NSBezierPath bezierPath];
      [connector moveToPoint:p]; [connector lineToPoint:NSMakePoint(NSMidX(label), NSMidY(label))];
      connector.lineWidth = .5; [[color colorWithAlphaComponent:.4] setStroke]; [connector stroke];
    }
    [[rigBG() colorWithAlphaComponent:0.9] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(label, -2, -1) xRadius:2 yRadius:2] fill];
    [pin.label drawInRect:label withAttributes:attributes];
  }
}
@end

namespace {
NSColor* effectPurple() { return [NSColor colorWithSRGBRed:.80 green:.55 blue:1 alpha:1]; }
void effectText(NSString* text, NSRect rect, CGFloat size, NSColor* color,
                NSTextAlignment alignment = NSTextAlignmentLeft, NSFontWeight weight = NSFontWeightRegular) {
  NSMutableParagraphStyle* style = [NSMutableParagraphStyle new];
  style.alignment = alignment;
  style.lineBreakMode = NSLineBreakByTruncatingTail;
  [text drawInRect:rect withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:size weight:weight],
      NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: style}];
}
void effectLine(NSPoint from, NSPoint to, NSColor* color, BOOL dashed = NO) {
  NSBezierPath* line = [NSBezierPath bezierPath];
  [line moveToPoint:from]; [line lineToPoint:to];
  line.lineWidth = .75;
  if (dashed) { CGFloat dash[] = {3, 3}; [line setLineDash:dash count:2 phase:0]; }
  [color setStroke]; [line stroke];
}
void effectHeader(NSRect r, NSString* title, NSString* description, NSColor* color) {
  NSBezierPath* background = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, .5, .5) xRadius:6 yRadius:6];
  [rigBG() setFill]; [background fill];
  [rigPanelBorder() setStroke]; [background stroke];
  effectText(title, NSMakeRect(14, NSHeight(r) - 26, NSWidth(r) - 28, 17), 11, color, NSTextAlignmentLeft, NSFontWeightSemibold);
  effectText(description, NSMakeRect(14, NSHeight(r) - 45, NSWidth(r) - 28, 15), 9, rigDimText());
}
CGFloat effectX(NSRect r, double x, double maximum) { return NSMinX(r) + std::clamp(x / maximum, 0.0, 1.0) * NSWidth(r); }
CGFloat effectY(NSRect r, double db, double minimum, double maximum) {
  return NSMinY(r) + std::clamp((db - minimum) / (maximum - minimum), 0.0, 1.0) * NSHeight(r);
}
void effectDbGrid(NSRect plot, double minimum, double maximum, std::initializer_list<double> ticks) {
  for (double db : ticks) {
    CGFloat y = effectY(plot, db, minimum, maximum);
    effectLine(NSMakePoint(NSMinX(plot), y), NSMakePoint(NSMaxX(plot), y), rigPanelBorder(), YES);
    effectText([NSString stringWithFormat:@"%.0f", db], NSMakeRect(NSMinX(plot) - 38, y - 5, 31, 12), 8, rigDimText(), NSTextAlignmentRight);
  }
}
void effectCurve(NSBezierPath* curve, NSRect plot, CGFloat baseline, NSColor* color) {
  NSBezierPath* fill = [curve copy];
  [fill lineToPoint:NSMakePoint(NSMaxX(plot), baseline)];
  [fill lineToPoint:NSMakePoint(NSMinX(plot), baseline)];
  [fill closePath];
  NSGradient* gradient = [[NSGradient alloc] initWithStartingColor:[color colorWithAlphaComponent:.20]
      endingColor:[color colorWithAlphaComponent:.02]];
  [gradient drawInBezierPath:fill angle:270];
  curve.lineWidth = 2; curve.lineJoinStyle = NSLineJoinStyleRound;
  [color setStroke]; [curve stroke];
}
void effectTitle(NSRect plot, NSString* title) {
  effectText(title, NSMakeRect(NSMinX(plot), NSMaxY(plot) + 13, NSWidth(plot), 14), 9, rigText(), NSTextAlignmentLeft, NSFontWeightMedium);
}
NSString* effectTime(double milliseconds) {
  return milliseconds >= 1000 ? [NSString stringWithFormat:@"%.1f s", milliseconds / 1000] :
      [NSString stringWithFormat:@"%.0f ms", milliseconds];
}
NSRect effectTimePlot(NSRect r) { return NSMakeRect(48, 46, MAX(12.0, NSWidth(r) - 70), MAX(12.0, NSHeight(r) - 124)); }
struct CompressorPlots { NSRect transfer, timing; };
CompressorPlots compressorPlots(NSRect r) {
  if (NSWidth(r) < 640) {
    CGFloat h = MAX(20.0, (NSHeight(r) - 198) * .5);
    return {NSMakeRect(46, 46 + h + 70, NSWidth(r) - 68, h), NSMakeRect(46, 46, NSWidth(r) - 68, h)};
  }
  CGFloat w = (NSWidth(r) - 124) * .5;
  return {NSMakeRect(46, 46, w, NSHeight(r) - 128), NSMakeRect(102 + w, 46, w, NSHeight(r) - 128)};
}
double compAmount(NAMCompressorVisualizer* v) { return std::clamp(v.amount * .01, 0.0, 1.0); }
double compEnd(NAMCompressorVisualizer* v) { return 250; }
double compWindow(NAMCompressorVisualizer* v) { return 1500; }
double compReduction(NAMCompressorVisualizer* v, double time) {
  double a = compAmount(v), target = NAMRig::compressorReductionDb(-6, -12 - 24 * a, 1 + 5 * a);
  double attack = std::max(1.0f, v.attack), end = compEnd(v);
  if (time < 50) return 0;
  if (time < end) return target * (1 - std::exp(-(time - 50) / attack));
  return target * (1 - std::exp(-(end - 50) / attack)) * std::exp(-(time - end) / std::max(10.0f, v.releaseTime));
}
NSPoint delayPoint(NAMDelayTapVisualizer* v, NSRect r, int repeat, BOOL right) {
  NSRect plot = effectTimePlot(r);
  CGFloat baseline = NSMinY(plot) + (right ? 0 : NSHeight(plot) * .55);
  double level = v.mix * .01 * std::pow(v.feedback * .0095, repeat - 1);
  return NSMakePoint(effectX(plot, v.timeMs * repeat, 5000), baseline + level * NSHeight(plot) * .40);
}
double reverbTail(NAMReverbDecayVisualizer* v) {
  // Nominal low-frequency decay of space_fx.h's two recirculating tank paths.
  // Each traversal applies the feedback gain twice; damping shortens the highs.
  double feedback = .30 + .68 * std::clamp(v.decay * .01, 0.0, 1.0);
  double size = .6 + .8 * std::clamp(v.size * .01, 0.0, 1.0);
  double seconds = ((672 + 4453 + 1800 + 3720) + (908 + 4217 + 2656 + 3163)) * .5 / 29761.0 * size;
  return seconds * std::log(.001) / std::log(feedback * feedback);
}
double reverbWindow(NAMReverbDecayVisualizer* v) {
  double seconds = 4;
  while (seconds < reverbTail(v) * 1.15 + v.preDelay * .001) seconds *= 2;
  return seconds;
}
double reverbLevel(NAMReverbDecayVisualizer* v) { return v.mix > 0 ? 20 * std::log10(v.mix * .01) : -60; }
struct BoostPlots { NSRect wave, tone; };
BoostPlots boostPlots(NSRect r) {
  if (NSWidth(r) < 640) {
    CGFloat h = MAX(20.0, (NSHeight(r) - 198) * .5);
    return {NSMakeRect(46, 46 + h + 70, NSWidth(r) - 68, h), NSMakeRect(46, 46, NSWidth(r) - 68, h)};
  }
  CGFloat w = (NSWidth(r) - 124) * .5;
  return {NSMakeRect(46, 46, w, NSHeight(r) - 128), NSMakeRect(102 + w, 46, w, NSHeight(r) - 128)};
}
double boostShape(NAMBoostVisualizer* v, double input) {
  double amount = std::clamp(v.drive * .01, 0.0, 1.0), gain = NAMRig::Overdrive::branchGain(amount);
  const double amplitude = .15; // A normalized preview of a fixed input sine.
  double maximum = amplitude + amount * NAMRig::Overdrive::clip(gain * amplitude, v.voicing);
  return (input * amplitude + amount * NAMRig::Overdrive::clip(gain * input * amplitude, v.voicing)) / maximum;
}
double boostToneDb(NAMBoostVisualizer* v, double hz) {
  return NAMRig::Overdrive::preClipHighPassResponseDb(hz, kPinPlotRate, v.tight) +
      NAMRig::Overdrive::postClipResponseDb(hz, kPinPlotRate, v.tone, v.level);
}
NSPoint boostFrequencyPoint(NAMBoostVisualizer* v, double hz) {
  NSRect plot = boostPlots(v.bounds).tone;
  return NSMakePoint(pinPlotX(plot, hz), effectY(plot, boostToneDb(v, hz), -24, 12));
}
}

@implementation NAMDelayTapVisualizer
- (BOOL)isFlipped { return NO; }
- (void)setTimeMs:(float)v { _timeMs = v; self.needsDisplay = YES; }
- (void)setFeedback:(float)v { _feedback = v; self.needsDisplay = YES; }
- (void)setDamping:(float)v { _damping = v; self.needsDisplay = YES; }
- (void)setMix:(float)v { _mix = v; self.needsDisplay = YES; }

- (NSPoint)controlPointForIndex:(NSUInteger)index {
  return delayPoint(self, self.bounds, index == 0 ? 1 : 2, index != 0);
}
- (void)drawRect:(NSRect)dirty {
  NSRect r = self.bounds;
  if (NSWidth(r) < 80 || NSHeight(r) < 120) return;
  NSColor* violet = effectPurple();
  effectHeader(r, @"Stereo echoes", _mix > 0 ? @"Time spaces the repeats. Feedback adds more." : @"Mix is 0%: no audible echoes.", violet);
  NSRect plot = effectTimePlot(r);
  CGFloat laneHeight = NSHeight(plot) * .40;
  for (int second = 0; second <= 5; ++second) {
    CGFloat x = effectX(plot, second * 1000, 5000);
    effectLine(NSMakePoint(x, NSMinY(plot)), NSMakePoint(x, NSMaxY(plot)), rigPanelBorder(), YES);
    effectText([NSString stringWithFormat:@"%d s", second], NSMakeRect(x - 12, NSMinY(plot) - 20, 32, 13), 8, rigDimText());
  }
  for (int channel = 0; channel < 2; ++channel) {
    CGFloat base = NSMinY(plot) + (channel ? 0 : NSHeight(plot) * .55);
    effectText(channel ? @"RIGHT" : @"LEFT", NSMakeRect(8, base + laneHeight * .5 - 6, 35, 13), 8, rigDimText(), NSTextAlignmentRight, NSFontWeightSemibold);
    effectLine(NSMakePoint(NSMinX(plot), base), NSMakePoint(NSMaxX(plot), base), rigDimText());
    effectLine(NSMakePoint(NSMinX(plot), base), NSMakePoint(NSMinX(plot), base + laneHeight), rigDimText());
    effectText(@"Dry", NSMakeRect(NSMinX(plot) + 3, base + laneHeight - 12, 35, 12), 8, rigDimText());
    for (int repeat = 1; repeat <= 24; ++repeat) {
      if (_timeMs * repeat > 5000) break;
      NSPoint point = delayPoint(self, r, repeat, channel != 0);
      if (point.y - base < .8) continue;
      double darkness = std::clamp(_damping * .01 * (repeat - 1) * .18, 0.0, .8);
      NSColor* color = [violet blendedColorWithFraction:darkness ofColor:rigDimText()];
      NSBezierPath* bar = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(point.x - 2, base, 4, point.y - base) xRadius:2 yRadius:2];
      [color setFill]; [bar fill];
    }
  }
  effectText(_mix > 0 ? @"Darker repeats = less treble." : @"Raise Mix to add audible repeats.", NSMakeRect(14, 1, NSWidth(r) - 28, 10), 7.5, rigDimText());
}

@end

@implementation NAMReverbDecayVisualizer
- (BOOL)isFlipped { return NO; }
- (void)setMix:(float)v { _mix = v; self.needsDisplay = YES; }
- (void)setDecay:(float)v { _decay = v; self.needsDisplay = YES; }
- (void)setSize:(float)v { _size = v; self.needsDisplay = YES; }
- (void)setDamping:(float)v { _damping = v; self.needsDisplay = YES; }
- (void)setPreDelay:(float)v { _preDelay = v; self.needsDisplay = YES; }

- (NSPoint)controlPointForIndex:(NSUInteger)index {
  NSRect plot = effectTimePlot(self.bounds);
  double tail = reverbTail(self), time = _preDelay * .001 + (index ? tail * .5 : 0);
  return NSMakePoint(effectX(plot, time, reverbWindow(self)), effectY(plot, reverbLevel(self) - (index ? 30 : 0), -60, 0));
}
- (void)drawRect:(NSRect)dirty {
  NSRect r = self.bounds;
  if (NSWidth(r) < 80 || NSHeight(r) < 120) return;
  NSColor* violet = effectPurple();
  NSString* description = _mix > 0 ? [NSString stringWithFormat:@"%.0f ms before the tail starts. Decay and size set its length.", _preDelay] : @"Mix is 0%: the reverb tail is muted.";
  effectHeader(r, @"Reverb tail", description, violet);
  NSRect plot = effectTimePlot(r);
  effectDbGrid(plot, -60, 0, {0, -20, -40, -60});
  effectTitle(plot, @"Tail level (dB) · approximate envelope");
  for (int tick = 0; tick <= 4; ++tick) {
    double second = reverbWindow(self) * tick / 4;
    CGFloat x = effectX(plot, second, reverbWindow(self));
    effectText([NSString stringWithFormat:@"%.0f s", second], NSMakeRect(x - 10, NSMinY(plot) - 20, 24, 12), 8, rigDimText());
  }
  double pre = _preDelay * .001, tail = reverbTail(self), level = reverbLevel(self);
  CGFloat preX = effectX(plot, pre, reverbWindow(self));
  effectLine(NSMakePoint(preX, NSMinY(plot)), NSMakePoint(preX, NSMaxY(plot)), rigDimText(), YES);
  NSBezierPath* curve = [NSBezierPath bezierPath];
  for (int i = 0; i <= 240; ++i) {
    double time = reverbWindow(self) * i / 240;
    double db = time < pre ? -60 : level - 60 * (time - pre) / tail;
    NSPoint point = NSMakePoint(effectX(plot, time, reverbWindow(self)), effectY(plot, db, -60, 0));
    if (!i) [curve moveToPoint:point]; else [curve lineToPoint:point];
  }
  effectCurve(curve, plot, NSMinY(plot), violet);
  if (_damping > 0 && _mix > 0) {
    NSBezierPath* highs = [NSBezierPath bezierPath];
    for (int i = 0; i <= 240; ++i) {
      double time = reverbWindow(self) * i / 240;
      double db = time < pre ? -60 : level - 60 * (time - pre) / (tail * (1 - _damping * .0065));
      NSPoint point = NSMakePoint(effectX(plot, time, reverbWindow(self)), effectY(plot, db, -60, 0));
      if (!i) [highs moveToPoint:point]; else [highs lineToPoint:point];
    }
    CGFloat dash[] = {4, 4}; [highs setLineDash:dash count:2 phase:0];
    highs.lineWidth = 1; [rigDimText() setStroke]; [highs stroke];
  }
  effectText(_mix > 0 ? @"Dashed tail = faster loss of high frequencies." : @"Raise Mix to hear the reverb tail.", NSMakeRect(14, 1, NSWidth(r) - 28, 10), 7.5, rigDimText());
}

@end

@implementation NAMSpatialAcousticVisualizer
- (BOOL)isFlipped { return NO; }
- (void)setWidth:(float)v { _width = v; self.needsDisplay = YES; }
- (void)setRoom:(float)v { _room = v; self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirty {
  NSRect r = self.bounds;
  if (r.size.width < 10 || r.size.height < 10) return;

  NSBezierPath* bg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:6.0 yRadius:6.0];
  [rigBG() setFill];
  [bg fill];
  [rigPanelBorder() setStroke];
  bg.lineWidth = 1.0;
  [bg stroke];

  CGFloat splitX = r.size.width * 0.46;

  NSBezierPath* sep = [NSBezierPath bezierPath];
  [sep moveToPoint:NSMakePoint(splitX, 8)];
  [sep lineToPoint:NSMakePoint(splitX, r.size.height - 8)];
  sep.lineWidth = 1.0;
  [[NSColor colorWithSRGBRed:0.18 green:0.20 blue:0.25 alpha:0.8] setStroke];
  [sep stroke];

  // Left Module: Stereo Goniometer
  NSDictionary* headerAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:9.0 weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.95]
  };
  [@"STEREO SCOPE" drawAtPoint:NSMakePoint(14, r.size.height - 18) withAttributes:headerAttrs];

  NSPoint gc = NSMakePoint(splitX * 0.5, (r.size.height - 20) * 0.5 + 14);
  CGFloat gRad = std::min(splitX * 0.36, (r.size.height - 36.0) * 0.44);

  NSBezierPath* ringOuter = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(gc.x - gRad, gc.y - gRad, gRad * 2, gRad * 2)];
  [[NSColor colorWithSRGBRed:0.18 green:0.22 blue:0.28 alpha:0.5] setStroke];
  ringOuter.lineWidth = 1.0;
  [ringOuter stroke];

  NSBezierPath* ringInner = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(gc.x - gRad * 0.5, gc.y - gRad * 0.5, gRad, gRad)];
  [[NSColor colorWithSRGBRed:0.16 green:0.19 blue:0.25 alpha:0.4] setStroke];
  ringInner.lineWidth = 0.75;
  [ringInner stroke];

  NSBezierPath* cross = [NSBezierPath bezierPath];
  [cross moveToPoint:NSMakePoint(gc.x, gc.y - gRad - 3)];
  [cross lineToPoint:NSMakePoint(gc.x, gc.y + gRad + 3)];
  [cross moveToPoint:NSMakePoint(gc.x - gRad - 3, gc.y)];
  [cross lineToPoint:NSMakePoint(gc.x + gRad + 3, gc.y)];
  cross.lineWidth = 0.75;
  [[NSColor colorWithSRGBRed:0.22 green:0.25 blue:0.32 alpha:0.6] setStroke];
  [cross stroke];

  NSDictionary* axisAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:7.0 weight:NSFontWeightBold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.50 green:0.55 blue:0.65 alpha:0.8]
  };
  [@"M" drawAtPoint:NSMakePoint(gc.x - 3, gc.y + gRad + 2) withAttributes:axisAttrs];
  [@"S" drawAtPoint:NSMakePoint(gc.x + gRad + 3, gc.y - 4) withAttributes:axisAttrs];

  float wNorm = std::min(1.0f, std::max(0.0f, _width / 100.0f));
  if (wNorm < 0.02f) {
    NSBezierPath* beam = [NSBezierPath bezierPath];
    [beam moveToPoint:NSMakePoint(gc.x, gc.y - gRad * 0.9)];
    [beam lineToPoint:NSMakePoint(gc.x, gc.y + gRad * 0.9)];
    beam.lineWidth = 2.5;
    beam.lineCapStyle = NSLineCapStyleRound;
    [[NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.95] setStroke];
    [beam stroke];
  } else {
    CGFloat sideSpan = gRad * (0.15 + 0.85 * wNorm);
    CGFloat midSpan = gRad * 0.90;
    NSRect ellRect = NSMakeRect(gc.x - sideSpan, gc.y - midSpan, sideSpan * 2.0, midSpan * 2.0);
    NSBezierPath* ell = [NSBezierPath bezierPathWithOvalInRect:ellRect];
    NSGradient* eg = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.35 * wNorm]
                  endingColor:[NSColor colorWithSRGBRed:0.10 green:0.40 blue:0.50 alpha:0.03]];
    [eg drawInBezierPath:ell relativeCenterPosition:NSMakePoint(0, 0)];
    ell.lineWidth = 2.0;
    [[NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.95] setStroke];
    [ell stroke];
  }

  NSRect corrRect = NSMakeRect(16, 5, splitX - 32, 12);
  NSBezierPath* corrBg = [NSBezierPath bezierPathWithRoundedRect:corrRect xRadius:3 yRadius:3];
  [[NSColor colorWithSRGBRed:0.12 green:0.14 blue:0.18 alpha:0.9] setFill];
  [corrBg fill];
  NSDictionary* corrAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:7.5 weight:NSFontWeightBold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.95]
  };
  [@"+1.00 MONO-SAFE PHASE" drawAtPoint:NSMakePoint(corrRect.origin.x + 6, corrRect.origin.y + 1) withAttributes:corrAttrs];

  // Right Module: 3D Tracking Room Wireframe
  [@"ROOM ACOUSTICS" drawAtPoint:NSMakePoint(splitX + 16, r.size.height - 18) withAttributes:headerAttrs];

  NSString* roomStat = [NSString stringWithFormat:@"SPREAD: %.0f%%  •  ROOM: %.0f%%", _width, _room];
  NSDictionary* rAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.9]
  };
  NSSize rsz = [roomStat sizeWithAttributes:rAttrs];
  [roomStat drawAtPoint:NSMakePoint(r.size.width - 16 - rsz.width, r.size.height - 32) withAttributes:rAttrs];

  CGFloat rw = r.size.width - splitX - 32.0;
  CGFloat rh = r.size.height - 48.0;
  CGFloat rx = splitX + 16.0;
  CGFloat ry = 10.0;

  NSBezierPath* backWall = [NSBezierPath bezierPath];
  [backWall moveToPoint:NSMakePoint(rx + rw * 0.20, ry + rh * 0.30)];
  [backWall lineToPoint:NSMakePoint(rx + rw * 0.80, ry + rh * 0.30)];
  [backWall lineToPoint:NSMakePoint(rx + rw * 0.80, ry + rh * 0.85)];
  [backWall lineToPoint:NSMakePoint(rx + rw * 0.20, ry + rh * 0.85)];
  [backWall closePath];
  [[NSColor colorWithSRGBRed:0.15 green:0.18 blue:0.24 alpha:0.6] setStroke];
  backWall.lineWidth = 1.0;
  [backWall stroke];

  NSBezierPath* roomFloor = [NSBezierPath bezierPath];
  [roomFloor moveToPoint:NSMakePoint(rx, ry)];
  [roomFloor lineToPoint:NSMakePoint(rx + rw * 0.20, ry + rh * 0.30)];
  [roomFloor moveToPoint:NSMakePoint(rx + rw, ry)];
  [roomFloor lineToPoint:NSMakePoint(rx + rw * 0.80, ry + rh * 0.30)];
  [roomFloor moveToPoint:NSMakePoint(rx, ry + rh)];
  [roomFloor lineToPoint:NSMakePoint(rx + rw * 0.20, ry + rh * 0.85)];
  [roomFloor moveToPoint:NSMakePoint(rx + rw, ry + rh)];
  [roomFloor lineToPoint:NSMakePoint(rx + rw * 0.80, ry + rh * 0.85)];
  roomFloor.lineWidth = 1.0;
  [[NSColor colorWithSRGBRed:0.14 green:0.17 blue:0.22 alpha:0.5] setStroke];
  [roomFloor stroke];

  NSPoint spkA = NSMakePoint(rx + rw * 0.28, ry + rh * 0.35);
  NSPoint spkB = NSMakePoint(rx + rw * 0.72, ry + rh * 0.35);
  NSPoint listener = NSMakePoint(rx + rw * 0.50, ry + rh * 0.08);

  NSDictionary* spkAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:7.5 weight:NSFontWeightBold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.65 green:0.70 blue:0.80 alpha:0.9]
  };
  [@"CAB A" drawAtPoint:NSMakePoint(spkA.x - 14, spkA.y + 4) withAttributes:spkAttrs];
  [@"CAB B" drawAtPoint:NSMakePoint(spkB.x - 14, spkB.y + 4) withAttributes:spkAttrs];
  [@"LISTENER" drawAtPoint:NSMakePoint(listener.x - 18, listener.y - 10) withAttributes:spkAttrs];

  NSBezierPath* directRays = [NSBezierPath bezierPath];
  [directRays moveToPoint:spkA];
  [directRays lineToPoint:listener];
  [directRays moveToPoint:spkB];
  [directRays lineToPoint:listener];
  directRays.lineWidth = 1.2;
  [[NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.45] setStroke];
  [directRays stroke];

  float roomNorm = std::min(1.0f, std::max(0.0f, _room / 100.0f));
  if (roomNorm > 0.02f) {
    NSPoint bounceL = NSMakePoint(rx + rw * 0.08, ry + rh * 0.32);
    NSPoint bounceR = NSMakePoint(rx + rw * 0.92, ry + rh * 0.32);

    NSBezierPath* reflL = [NSBezierPath bezierPath];
    [reflL moveToPoint:spkA];
    [reflL lineToPoint:bounceL];
    [reflL lineToPoint:listener];
    reflL.lineWidth = 1.5;
    [[NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.3 + 0.65 * roomNorm] setStroke];
    [reflL stroke];

    NSBezierPath* reflR = [NSBezierPath bezierPath];
    [reflR moveToPoint:spkB];
    [reflR lineToPoint:bounceR];
    [reflR lineToPoint:listener];
    reflR.lineWidth = 1.5;
    [[NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.3 + 0.65 * roomNorm] setStroke];
    [reflR stroke];

    CGFloat nodeRad = 3.0 + 3.0 * roomNorm;
    NSBezierPath* nodeL = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(bounceL.x - nodeRad, bounceL.y - nodeRad, nodeRad * 2, nodeRad * 2)];
    NSBezierPath* nodeR = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(bounceR.x - nodeRad, bounceR.y - nodeRad, nodeRad * 2, nodeRad * 2)];
    [[NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.8 * roomNorm] setFill];
    [nodeL fill];
    [nodeR fill];
  }
}
@end

@implementation NAMCompressorVisualizer
- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _enabled = YES;
  }
  return self;
}
- (BOOL)isFlipped { return NO; }
- (void)setEnabled:(BOOL)v { _enabled = v; self.needsDisplay = YES; }
- (void)setAmount:(float)v { _amount = v; self.needsDisplay = YES; }
- (void)setAttack:(float)v { _attack = v; self.needsDisplay = YES; }
- (void)setReleaseTime:(float)v { _releaseTime = v; self.needsDisplay = YES; }
- (void)setCompact:(BOOL)v { _compact = v; self.needsDisplay = YES; }

- (NSPoint)controlPointForIndex:(NSUInteger)index {
  CompressorPlots plots = compressorPlots(self.bounds);
  double amount = compAmount(self);
  if (index == 0) {
    double threshold = -12 - 24 * amount;
    double output = threshold + 6 * amount - NAMRig::compressorReductionDb(threshold, threshold, 1 + 5 * amount);
    return NSMakePoint(effectX(plots.transfer, threshold + 60, 60), effectY(plots.transfer, output, -60, 6));
  }
  double time = index == 1 ? 50 + std::max(1.0f, _attack) : compEnd(self) + std::max(10.0f, _releaseTime);
  return NSMakePoint(effectX(plots.timing, time, compWindow(self)), effectY(plots.timing, -compReduction(self, time), -30, 0));
}
- (void)drawRect:(NSRect)dirty {
  NSRect r = self.bounds;
  if (NSWidth(r) < 100 || NSHeight(r) < 200) return;
  double amount = compAmount(self), threshold = -12 - 24 * amount, ratio = 1 + 5 * amount;
  NSString* description = !_enabled ? @"Bypassed · preview of the stored settings." : amount <= .0001 ? @"Amount is 0%: no gain reduction." :
      [NSString stringWithFormat:@"Threshold %.0f dB · Ratio %.1f:1 · Make-up +%.1f dB", threshold, ratio, 6 * amount];
  NSColor* warm = [rigOrange() colorWithAlphaComponent:_enabled ? .95 : .45];
  effectHeader(r, _compact ? @"Linked stereo compression" : @"Preamp compression", description, warm);
  CompressorPlots plots = compressorPlots(r);
  effectTitle(plots.transfer, @"Input level → output level (dB)");
  effectTitle(plots.timing, @"Attack & release · gain reduction (dB)");
  effectDbGrid(plots.transfer, -60, 6, {-60, -40, -20, 0});
  effectDbGrid(plots.timing, -30, 0, {-30, -20, -10, 0});
  for (int db : {-60, -30, 0}) {
    CGFloat x = effectX(plots.transfer, db + 60, 60);
    effectText([NSString stringWithFormat:@"%d", db], NSMakeRect(x - 12, NSMinY(plots.transfer) - 18, 24, 12), 8, rigDimText(), NSTextAlignmentCenter);
  }
  effectText(@"Input (dB)", NSMakeRect(NSMidX(plots.transfer) - 45, NSMinY(plots.transfer) - 33, 90, 12), 8, rigDimText(), NSTextAlignmentCenter);
  effectLine(NSMakePoint(NSMinX(plots.transfer), effectY(plots.transfer, -60, -60, 6)),
      NSMakePoint(NSMaxX(plots.transfer), effectY(plots.transfer, 0, -60, 6)), rigDimText(), YES);
  NSBezierPath* transfer = [NSBezierPath bezierPath];
  for (int i = 0; i <= 120; ++i) {
    double input = -60 + .5 * i;
    double output = input + 6 * amount - NAMRig::compressorReductionDb(input, threshold, ratio);
    NSPoint point = NSMakePoint(effectX(plots.transfer, input + 60, 60), effectY(plots.transfer, output, -60, 6));
    if (!i) [transfer moveToPoint:point]; else [transfer lineToPoint:point];
  }
  transfer.lineWidth = 2; [warm setStroke]; [transfer stroke];
  double window = compWindow(self);
  for (double fraction : {0.0, .5, 1.0}) {
    CGFloat x = effectX(plots.timing, window * fraction, window);
    effectText(effectTime(window * fraction), NSMakeRect(x - 24, NSMinY(plots.timing) - 20, 50, 12), 8, rigDimText(), NSTextAlignmentCenter);
  }
  CGFloat startX = effectX(plots.timing, 50, window), endX = effectX(plots.timing, compEnd(self), window);
  [[warm colorWithAlphaComponent:.06] setFill];
  [[NSBezierPath bezierPathWithRect:NSMakeRect(startX, NSMinY(plots.timing), endX - startX, NSHeight(plots.timing))] fill];
  effectLine(NSMakePoint(endX, NSMinY(plots.timing)), NSMakePoint(endX, NSMaxY(plots.timing)), rigDimText(), YES);
  NSBezierPath* envelope = [NSBezierPath bezierPath];
  for (int i = 0; i <= 240; ++i) {
    double time = window * i / 240;
    NSPoint point = NSMakePoint(effectX(plots.timing, time, window), effectY(plots.timing, -compReduction(self, time), -30, 0));
    if (!i) [envelope moveToPoint:point]; else [envelope lineToPoint:point];
  }
  effectCurve(envelope, plots.timing, NSMaxY(plots.timing), rigGreen());
  effectText(@"Timing preview · Shaded = 200 ms note · Dashed = unchanged level", NSMakeRect(14, 1, NSWidth(r) - 28, 10), 7.5, rigDimText());
}

@end

@implementation NAMPowerStageVisualizer
- (BOOL)isFlipped { return NO; }
- (void)setSag:(float)v { _sag = v; self.needsDisplay = YES; }
- (void)setBias:(float)v { _bias = v; self.needsDisplay = YES; }
- (void)setFeedback:(float)v { _feedback = v; self.needsDisplay = YES; }
- (void)setMaster:(float)v { _master = v; self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirty {
  NSRect r = self.bounds;
  if (r.size.width < 10 || r.size.height < 10) return;

  NSBezierPath* bg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:6.0 yRadius:6.0];
  [rigBG() setFill];
  [bg fill];
  [rigPanelBorder() setStroke];
  bg.lineWidth = 1.0;
  [bg stroke];

  NSDictionary* headerAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:9.0 weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:0.95]
  };
  [@"POWER-STAGE RESPONSE" drawAtPoint:NSMakePoint(14, r.size.height - 18) withAttributes:headerAttrs];

  NSString* stat = [NSString stringWithFormat:@"SAG: %.0f%%  •  BIAS: %+.0f%%  •  NFB: %.0f%%", _sag, _bias, _feedback];
  NSDictionary* statAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:0.9]
  };
  [stat drawAtPoint:NSMakePoint(14, r.size.height - 34) withAttributes:statAttrs];

  const CGFloat topMargin = 44.0;
  const CGFloat bottomMargin = 12.0;
  const CGFloat cx = r.size.width * 0.46;
  const CGFloat plotW = r.size.width * 0.72;
  const CGFloat plotH = r.size.height - topMargin - bottomMargin;
  if (plotH < 8.0) return;
  const CGFloat cy = bottomMargin + plotH * 0.5;

  NSBezierPath* grid = [NSBezierPath bezierPath];
  [grid moveToPoint:NSMakePoint(cx - plotW * 0.5, cy)];
  [grid lineToPoint:NSMakePoint(cx + plotW * 0.5, cy)];
  [grid moveToPoint:NSMakePoint(cx, cy - plotH * 0.5)];
  [grid lineToPoint:NSMakePoint(cx, cy + plotH * 0.5)];
  grid.lineWidth = 0.75;
  [[NSColor colorWithSRGBRed:0.20 green:0.22 blue:0.28 alpha:0.6] setStroke];
  [grid stroke];

  float biasShift = (_bias / 100.0f) * 0.25f;
  float sagSquash = 1.0f - (_sag / 100.0f) * 0.40f;

  NSBezierPath* curve = [NSBezierPath bezierPath];
  const int nPts = 60;
  for (int i = 0; i <= nPts; ++i) {
    float xIn = ((float)i / (float)nPts) * 2.0f - 1.0f;
    float xBiased = xIn + biasShift;
    float yOut = std::tanh(xBiased * 1.8f) * sagSquash;
    CGFloat px = cx + xIn * (plotW * 0.48);
    CGFloat py = cy + yOut * (plotH * 0.45);
    if (i == 0) [curve moveToPoint:NSMakePoint(px, py)];
    else [curve lineToPoint:NSMakePoint(px, py)];
  }
  curve.lineWidth = 2.5;
  [[NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:0.95] setStroke];
  [curve stroke];

  CGFloat barX = r.size.width - 24;
  CGFloat barH = plotH * 0.8;
  CGFloat barY = cy - barH * 0.5;
  NSRect barBg = NSMakeRect(barX, barY, 10, barH);
  NSBezierPath* bbg = [NSBezierPath bezierPathWithRoundedRect:barBg xRadius:2 yRadius:2];
  [[NSColor colorWithSRGBRed:0.12 green:0.14 blue:0.18 alpha:0.9] setFill];
  [bbg fill];

  CGFloat sagDrop = barH * (_sag / 100.0f);
  NSRect sagRect = NSMakeRect(barX, barY + barH - sagDrop, 10, sagDrop);
  NSBezierPath* sbar = [NSBezierPath bezierPathWithRoundedRect:sagRect xRadius:2 yRadius:2];
  [[NSColor colorWithSRGBRed:1.0 green:0.45 blue:0.20 alpha:0.85] setFill];
  [sbar fill];
}
@end

@implementation NAMSculptVisualizer
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _enabled = YES;
    _pinEditor = [[NAMPinEQEditor alloc] initWithPane:NAMRig::PinEqPane::Sculpt
        accent:[NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:1.0]];
    __weak NAMInteractiveGraph* weakSelf = self;
    _pinEditor.baseResponseDb = ^double(double hz) { return [weakSelf responseDbAtFrequency:hz]; };
    [self addSubview:_pinEditor];
    _odTone = NAMRig::Overdrive::kToneDefault;
    self.toolTip = @"Pre-amp EQ before the capture: Tight, Bright, Mid Push and 6-band parametric pin EQ.";
  }
  return self;
}
- (NSRect)plotRect {
  const NSRect r = self.bounds;
  return NSMakeRect(30.0, 16.0, r.size.width - 46.0, r.size.height - 54.0);
}
- (void)layout {
  [super layout];
  _pinEditor.frame = NSInsetRect([self plotRect], -kPinEditorInset, -kPinEditorInset);
}
- (BOOL)isFlipped { return NO; }
- (void)setEnabled:(BOOL)v { _enabled = v; _pinEditor.hidden = !v; self.needsDisplay = YES; }
- (void)setBright:(float)v { _bright = v; self.needsDisplay = YES; }
- (void)setInputEq:(float)v { _inputEq = v; self.needsDisplay = YES; }
- (void)setMidPush:(float)v { _midPush = v; self.needsDisplay = YES; }
- (void)setOdDrive:(float)v { _odDrive = v; self.needsDisplay = YES; }
- (void)setOdTone:(float)v { _odTone = v; self.needsDisplay = YES; }
- (void)setOdLevel:(float)v { _odLevel = v; self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirty {
  NSRect r = self.bounds;
  if (r.size.width < 10 || r.size.height < 10) return;

  NSBezierPath* bg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:6.0 yRadius:6.0];
  [rigBG() setFill];
  [bg fill];
  [rigPanelBorder() setStroke];
  bg.lineWidth = 1.0;
  [bg stroke];

  NSDictionary* headerAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:9.0 weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:0.95]
  };
  [@"PRE-AMP TONAL SCULPT & EQ" drawAtPoint:NSMakePoint(14, r.size.height - 18) withAttributes:headerAttrs];

  NSString* stat;
  if (!_enabled) {
    stat = @"PRE-AMP EQ BYPASSED (OFF)";
  } else {
    stat = [NSString stringWithFormat:@"BRIGHT: %+.1f dB  •  MID: %.0f%%  •  TIGHT: %.0f%%",
                                       _bright * 0.06, _midPush, _inputEq];
  }
  NSDictionary* statAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: _enabled
        ? [NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:0.9]
        : [NSColor colorWithSRGBRed:0.50 green:0.53 blue:0.60 alpha:0.8]
  };
  NSSize ssz = [stat sizeWithAttributes:statAttrs];
  [stat drawAtPoint:NSMakePoint(std::max(14.0, r.size.width - 14 - ssz.width), r.size.height - 32) withAttributes:statAttrs];

  // Log frequency 20 Hz..20 kHz, +/-18 dB: the same axes as the pin editor.
  const NSRect plot = [self plotRect];
  const CGFloat leftM = NSMinX(plot), pw = plot.size.width;
  const CGFloat midY = NSMidY(plot);

  NSBezierPath* baseLine = [NSBezierPath bezierPath];
  [baseLine moveToPoint:NSMakePoint(leftM, midY)];
  [baseLine lineToPoint:NSMakePoint(leftM + pw, midY)];
  baseLine.lineWidth = 0.75;
  CGFloat pat[2] = {2.0, 3.0};
  [baseLine setLineDash:pat count:2 phase:0.0];
  [[NSColor colorWithSRGBRed:0.22 green:0.25 blue:0.32 alpha:0.6] setStroke];
  [baseLine stroke];

}
- (double)responseDbAtFrequency:(double)hz {
  const float tight = std::clamp(_inputEq * .01f, 0.0f, 1.0f);
  const float bright = std::clamp(_bright * .01f, 0.0f, 1.0f);
  const float mid = std::clamp(_midPush * .01f, 0.0f, 1.0f);
  double db = 0;
  if (tight > 0) db += NAMRig::pinMagnitudeDb(NAMRig::pinPassCoefficients(true, 20 + 160 * tight, kPinPlotRate), hz, kPinPlotRate);
  if (bright > 0) db += NAMRig::pinMagnitudeDb(NAMRig::pinCoefficients(NAMRig::kPinHighShelf, 2200, 6 * bright, .7071067811865476, kPinPlotRate), hz, kPinPlotRate);
  if (mid > 0) db += NAMRig::pinMagnitudeDb(NAMRig::pinCoefficients(NAMRig::kPinBell, 750, 9 * mid, .8, kPinPlotRate), hz, kPinPlotRate);
  return db;
}

@end

@implementation NAMBoostVisualizer
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _tight = NAMRig::Overdrive::kTightDefault;
    _tone = NAMRig::Overdrive::kToneDefault;
    _voicing = 0;
    _enabled = YES;
    self.toolTip = @"Clean linear boost or diode overdrive, with variable tight high-pass filtering and tone shaping in front of the amplifier.";
  }
  return self;
}
- (BOOL)isFlipped { return NO; }
- (void)setDrive:(float)v { _drive = v; self.needsDisplay = YES; }
- (void)setTight:(float)v { _tight = v; self.needsDisplay = YES; }
- (void)setTone:(float)v { _tone = v; self.needsDisplay = YES; }
- (void)setLevel:(float)v { _level = v; self.needsDisplay = YES; }
- (void)setVoicing:(int)v { _voicing = std::clamp(v, 0, (int)NAMRig::Overdrive::Voicing::Count - 1); self.needsDisplay = YES; }
- (void)setEnabled:(BOOL)v { _enabled = v; self.needsDisplay = YES; }

- (NSPoint)controlPointForIndex:(NSUInteger)index {
  if (index == 1) return boostFrequencyPoint(self, _tight);
  if (index == 2) return boostFrequencyPoint(self, 4000);
  NSRect plot = boostPlots(self.bounds).wave;
  return NSMakePoint(NSMinX(plot) + NSWidth(plot) / 12, NSMidY(plot) + boostShape(self, .5) * NSHeight(plot) * .45);
}
- (void)drawRect:(NSRect)dirty {
  NSRect r = self.bounds;
  if (NSWidth(r) < 100 || NSHeight(r) < 200) return;
  NSColor* warm = [rigOrange() colorWithAlphaComponent:_enabled ? .95 : .45];
  NSString* description = !_enabled ? @"Bypassed · preview of the stored settings." : _voicing == (int)NAMRig::Overdrive::Voicing::Clean ? @"Clean voice: added gain without diode clipping." : @"Drive reshapes the wave. Tight trims bass; Tone sets brightness.";
  effectHeader(r, @"Boost & overdrive", description, warm);
  BoostPlots plots = boostPlots(r);
  effectTitle(plots.wave, @"Clipping preview · normalized level");
  effectTitle(plots.tone, @"Low cut & brightness (dB)");
  effectLine(NSMakePoint(NSMinX(plots.wave), NSMidY(plots.wave)), NSMakePoint(NSMaxX(plots.wave), NSMidY(plots.wave)), rigPanelBorder(), YES);
  for (int sign : {-1, 1}) {
    CGFloat y = NSMidY(plots.wave) + sign * NSHeight(plots.wave) * .45;
    effectText(sign > 0 ? @"+1" : @"−1", NSMakeRect(NSMinX(plots.wave) - 28, y - 6, 22, 12), 8, rigDimText());
  }
  NSBezierPath* input = [NSBezierPath bezierPath];
  NSBezierPath* output = [NSBezierPath bezierPath];
  for (int i = 0; i <= 240; ++i) {
    double phase = 2 * 3.141592653589793 * i / 240;
    double sample = std::sin(phase);
    CGFloat x = NSMinX(plots.wave) + NSWidth(plots.wave) * i / 240;
    NSPoint dry = NSMakePoint(x, NSMidY(plots.wave) + sample * NSHeight(plots.wave) * .45);
    NSPoint wet = NSMakePoint(x, NSMidY(plots.wave) + boostShape(self, sample) * NSHeight(plots.wave) * .45);
    if (!i) { [input moveToPoint:dry]; [output moveToPoint:wet]; }
    else { [input lineToPoint:dry]; [output lineToPoint:wet]; }
  }
  CGFloat dash[] = {4, 3}; [input setLineDash:dash count:2 phase:0];
  input.lineWidth = 1; [rigDimText() setStroke]; [input stroke];
  output.lineWidth = 2; [warm setStroke]; [output stroke];
  effectDbGrid(plots.tone, -24, 12, {-24, -12, 0, 12});
  for (double hz : {20.0, 100.0, 1000.0, 10000.0}) {
    CGFloat x = pinPlotX(plots.tone, hz);
    effectText(hz >= 1000 ? [NSString stringWithFormat:@"%.0fk", hz / 1000] : [NSString stringWithFormat:@"%.0f", hz],
        NSMakeRect(x - 12, NSMinY(plots.tone) - 18, 28, 12), 8, rigDimText(), NSTextAlignmentCenter);
  }
  effectText(@"Frequency (Hz)", NSMakeRect(NSMidX(plots.tone) - 55, NSMinY(plots.tone) - 33, 110, 12), 8, rigDimText(), NSTextAlignmentCenter);
  NSBezierPath* curve = [NSBezierPath bezierPath];
  for (int i = 0; i <= 180; ++i) {
    double hz = 20 * std::pow(1000.0, i / 180.0);
    NSPoint point = boostFrequencyPoint(self, hz);
    if (!i) [curve moveToPoint:point]; else [curve lineToPoint:point];
  }
  effectCurve(curve, plots.tone, NSMinY(plots.tone), rigAccent());
  effectText(@"Dashed = clean input · Solid = shaped output", NSMakeRect(14, 1, NSWidth(r) - 28, 10), 7.5, rigDimText());
}

@end

@implementation NAMPowerTubeVisualizer
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _profile = NAMRig::PowerTube::kCaptured;
    _character = NAMRig::kPowerTubeCharacterDefault;
    _enabled = YES;
    self.toolTip = @"Illustrative static transfer of design voicings, not a measured tube response or a physical tube swap. Excludes the live power-stage feedback, bias and supply dynamics.";
  }
  return self;
}
- (BOOL)isFlipped { return NO; }
- (void)setProfile:(int)p {
  _profile = NAMRig::PowerTube::clampProfile(p);
  self.needsDisplay = YES;
}
- (void)setCharacter:(float)v {
  _character = NAMRig::PowerTube::clampCharacter(v);
  self.needsDisplay = YES;
}
- (void)setEnabled:(BOOL)v { _enabled = v; self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirty {
  const NSRect r = self.bounds;
  if (NSWidth(r) < 10.0 || NSHeight(r) < 10.0) return;

  NSBezierPath* bg = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0.5, 0.5)
                                                   xRadius:6.0 yRadius:6.0];
  [rigBG() setFill];
  [bg fill];
  [rigPanelBorder() setStroke];
  bg.lineWidth = 1.0;
  [bg stroke];

  const auto& legacy = NAMRig::PowerTube::kProfiles[NAMRig::PowerTube::kCaptured];
  const auto& profile = NAMRig::PowerTube::kProfiles[_profile];
  const double amount = _enabled && _profile != NAMRig::PowerTube::kCaptured
      ? _character * 0.01 : 0.0;
  NSColor* curveColor = [NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25
                                         alpha:(amount > 0.0 ? 0.95 : 0.45)];
  NSMutableParagraphStyle* textStyle = [NSMutableParagraphStyle new];
  textStyle.lineBreakMode = NSLineBreakByTruncatingTail;
  NSDictionary* headerAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:9.0 weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName: curveColor,
    NSParagraphStyleAttributeName: textStyle
  };
  NSDictionary* statAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: rigDimText(),
    NSParagraphStyleAttributeName: textStyle
  };
  const CGFloat textX = NSMinX(r) + 14.0;
  const CGFloat textW = std::max(0.0, NSWidth(r) - 28.0);
  [@"POWER TUBE CHARACTER" drawInRect:NSMakeRect(textX, NSMaxY(r) - 20.0, textW, 14.0)
                      withAttributes:headerAttrs];
  [[NSString stringWithUTF8String:profile.name]
      drawInRect:NSMakeRect(textX, NSMaxY(r) - 36.0, textW, 14.0) withAttributes:statAttrs];
  NSString* status = !_enabled ? @"OFF / BYPASSED - FLAT"
      : (_profile == NAMRig::PowerTube::kCaptured ? @"FLAT / NO ADDED CHARACTER"
         : [NSString stringWithFormat:@"CHARACTER: %.0f%%%s", _character,
                                      amount == 0.0 ? " / FLAT" : ""]);
  [status drawInRect:NSMakeRect(textX, NSMaxY(r) - 52.0, textW, 14.0) withAttributes:statAttrs];
  [@"ILLUSTRATIVE / NOT A TUBE SWAP"
      drawInRect:NSMakeRect(textX, NSMinY(r) + 5.0, textW, 14.0) withAttributes:statAttrs];

  const NSRect plot = NSMakeRect(NSMinX(r) + 28.0, NSMinY(r) + 36.0,
                                 NSWidth(r) - 44.0, NSHeight(r) - 98.0);
  if (NSWidth(plot) < 8.0 || NSHeight(plot) < 8.0) return;

  NSDictionary* axisAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:7.5 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.45 green:0.48 blue:0.55 alpha:0.8]
  };
  [@"OUTPUT" drawAtPoint:NSMakePoint(NSMinX(plot), NSMaxY(plot) + 1.0) withAttributes:axisAttrs];
  [@"INPUT" drawAtPoint:NSMakePoint(NSMaxX(plot) - 24.0, NSMinY(plot) - 14.0) withAttributes:axisAttrs];
  NSBezierPath* grid = [NSBezierPath bezierPathWithRect:plot];
  [grid moveToPoint:NSMakePoint(NSMinX(plot), NSMidY(plot))];
  [grid lineToPoint:NSMakePoint(NSMaxX(plot), NSMidY(plot))];
  [grid moveToPoint:NSMakePoint(NSMidX(plot), NSMinY(plot))];
  [grid lineToPoint:NSMakePoint(NSMidX(plot), NSMaxY(plot))];
  grid.lineWidth = 0.75;
  [[NSColor colorWithSRGBRed:0.20 green:0.22 blue:0.28 alpha:0.6] setStroke];
  [grid stroke];

  const NSRect data = NSInsetRect(plot, 3.0, 3.0);
  NSBezierPath* reference = [NSBezierPath bezierPath];
  [reference moveToPoint:NSMakePoint(NSMinX(data), NSMinY(data))];
  [reference lineToPoint:NSMakePoint(NSMaxX(data), NSMaxY(data))];
  const CGFloat dash[2] = {2.0, 3.0};
  [reference setLineDash:dash count:2 phase:0.0];
  reference.lineWidth = 0.75;
  [[NSColor colorWithSRGBRed:0.45 green:0.48 blue:0.55 alpha:0.35] setStroke];
  [reference stroke];

  // Static sketch only: interpolate legacy parameters, without the DSP's live loop.
  const double knee = legacy.knee + amount * (profile.knee - legacy.knee);
  const double headroom = legacy.headroom + amount * (profile.headroom - legacy.headroom);
  const double asymmetry = legacy.asymmetry + amount * (profile.asymmetry - legacy.asymmetry);
  const auto saturate = [knee](double x) {
    const double a = std::fabs(x);
    if (a <= knee) return x;
    const double d = 1.0 - knee;
    const double v = a - knee;
    return std::copysign(knee + d * v / (d + v), x);
  };
  const double biasOut = saturate(asymmetry);
  NSBezierPath* curve = [NSBezierPath bezierPath];
  const int nPts = 80;
  for (int i = 0; i <= nPts; ++i) {
    const double x = 2.0 * i / nPts - 1.0;
    const double shaped = headroom * (saturate(x / headroom + asymmetry) - biasOut);
    const double y = std::clamp(x + amount * (shaped - x), -1.0, 1.0);
    const NSPoint point = NSMakePoint(NSMidX(data) + x * NSWidth(data) * 0.5,
                                      NSMidY(data) + y * NSHeight(data) * 0.5);
    if (i == 0) [curve moveToPoint:point];
    else [curve lineToPoint:point];
  }
  curve.lineWidth = 2.2;
  curve.lineCapStyle = NSLineCapStyleRound;
  [curveColor setStroke];
  [curve stroke];
}
@end

@implementation NAMTransformerVisualizer
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.profile = NAMRig::OutputTransformer::kCaptured;
    self.toolTip = @"Illustrative core flux transfer and linear filters at 48 kHz (including makeup). Not the full level-dependent audio response; flux frequency controls the core's memory.";
    _pinEditor = [[NAMPinEQEditor alloc] initWithPane:NAMRig::PinEqPane::Transformer
        accent:[NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:1.0]];
    __weak NAMInteractiveGraph* weakSelf = self;
    _pinEditor.baseResponseDb = ^double(double hz) { return [weakSelf responseDbAtFrequency:hz]; };
    [self addSubview:_pinEditor];
  }
  return self;
}
// Right-hand passband plot; shared by drawRect and the pin editor.
- (NSRect)passbandRect {
  const NSRect r = self.bounds;
  const CGFloat topM = 38.0, botM = 10.0;
  const CGFloat splitX = std::round(r.size.width * 0.36);
  const CGFloat left = splitX + 12.0;
  return NSMakeRect(left, botM, r.size.width - 12.0 - left, r.size.height - topM - botM);
}
- (void)layout {
  [super layout];
  _pinEditor.frame = NSInsetRect([self passbandRect], -kPinEditorInset, -kPinEditorInset);
}
- (BOOL)isFlipped { return NO; }
- (void)setProfile:(int)p {
  _profile = NAMRig::OutputTransformer::clampProfile(p);
  self.parameters = NAMRig::OutputTransformer::parametersForProfile(_profile);
}
- (void)setParameters:(NAMRig::OutputTransformer::Parameters)p {
  _parameters = p;
  self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirty {
  NSRect r = self.bounds;
  if (r.size.width < 10 || r.size.height < 10) return;

  NSBezierPath* bg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:6.0 yRadius:6.0];
  [rigBG() setFill];
  [bg fill];
  [rigPanelBorder() setStroke];
  bg.lineWidth = 1.0;
  [bg stroke];

  const int idx = _profile;
  const auto& p = _parameters;

  NSDictionary* headerAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:9.0 weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:0.95]
  };
  [@"CORE FLUX SATURATION & PASSBAND" drawAtPoint:NSMakePoint(14, r.size.height - 18) withAttributes:headerAttrs];

  NSString* stat = (idx == 0)
      ? @"BYPASS  •  CAPTURED RESPONSE"
      : [NSString stringWithFormat:@"FLUX: %.0fHz  •  DRV: %.1fx  •  SAT: %.0f%%",
         p.fluxHz, p.drive, p.saturationMix * 100.0];
  NSDictionary* statAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:0.9]
  };
  NSSize ssz = [stat sizeWithAttributes:statAttrs];
  [stat drawAtPoint:NSMakePoint(std::max(14.0, r.size.width - 14 - ssz.width), r.size.height - 32) withAttributes:statAttrs];

  const CGFloat topM = 38.0;
  const CGFloat botM = 10.0;
  const CGFloat plotH = r.size.height - topM - botM;
  if (plotH < 8.0) return;

  // Split view: Left 36% = Core Flux Transfer, Right 64% = Linear Passband & Leakage
  const CGFloat splitX = std::round(r.size.width * 0.36);

  NSBezierPath* sep = [NSBezierPath bezierPath];
  [sep moveToPoint:NSMakePoint(splitX, botM)];
  [sep lineToPoint:NSMakePoint(splitX, r.size.height - topM)];
  sep.lineWidth = 1.0;
  [[NSColor colorWithSRGBRed:0.18 green:0.20 blue:0.25 alpha:0.8] setStroke];
  [sep stroke];

  // Left: Static flux transfer, not a hysteresis loop or voltage-domain response.
  const CGFloat bhCx = splitX * 0.5;
  const CGFloat bhCy = botM + plotH * 0.5;
  const CGFloat bhW = splitX - 24.0;
  const CGFloat bhH = plotH - 6.0;

  NSBezierPath* bhAxes = [NSBezierPath bezierPath];
  [bhAxes moveToPoint:NSMakePoint(bhCx - bhW * 0.5, bhCy)];
  [bhAxes lineToPoint:NSMakePoint(bhCx + bhW * 0.5, bhCy)];
  [bhAxes moveToPoint:NSMakePoint(bhCx, bhCy - bhH * 0.5)];
  [bhAxes lineToPoint:NSMakePoint(bhCx, bhCy + bhH * 0.5)];
  bhAxes.lineWidth = 0.75;
  [[NSColor colorWithSRGBRed:0.20 green:0.22 blue:0.28 alpha:0.6] setStroke];
  [bhAxes stroke];

  NSBezierPath* bhCurve = [NSBezierPath bezierPath];
  const int bhPts = 40;
  const auto sigmoid = [](double x) { return x / std::sqrt(1.0 + x * x); };
  const double bias = sigmoid(p.asymmetry);
  for (int i = 0; i <= bhPts; ++i) {
    double x = ((double)i / (double)bhPts) * 2.0 - 1.0;
    double ySat = (sigmoid(p.drive * x + p.asymmetry) - bias) / p.drive;
    double y = (idx == 0) ? x : x + p.saturationMix * (ySat - x);
    CGFloat px = bhCx + x * (bhW * 0.46);
    CGFloat py = bhCy + y * (bhH * 0.45);
    if (i == 0) [bhCurve moveToPoint:NSMakePoint(px, py)];
    else [bhCurve lineToPoint:NSMakePoint(px, py)];
  }
  bhCurve.lineWidth = 2.2;
  [[NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:(idx == 0 ? 0.45 : 0.95)] setStroke];
  [bhCurve stroke];

  // Right: DSP's linear RBJ filters at a fixed reference rate, excluding core saturation.
  const NSRect eqPlot = [self passbandRect];
  const CGFloat eqLeft = NSMinX(eqPlot);
  const CGFloat eqRight = NSMaxX(eqPlot);
  const CGFloat eqMidY = NSMidY(eqPlot);

  NSBezierPath* eqBase = [NSBezierPath bezierPath];
  [eqBase moveToPoint:NSMakePoint(eqLeft, eqMidY)];
  [eqBase lineToPoint:NSMakePoint(eqRight, eqMidY)];
  eqBase.lineWidth = 0.75;
  CGFloat dashPat[2] = {2.0, 3.0};
  [eqBase setLineDash:dashPat count:2 phase:0.0];
  [[NSColor colorWithSRGBRed:0.22 green:0.25 blue:0.32 alpha:0.6] setStroke];
  [eqBase stroke];

}
- (double)responseDbAtFrequency:(double)hz {
  if (_profile == NAMRig::OutputTransformer::kCaptured) return 0;
  const auto& p = _parameters;
  const double rate = 48000.0;
  const double band = rate * .42;
  return NAMRig::pinMagnitudeDb(NAMRig::pinPassCoefficients(true, p.lowCutHz, rate), hz, rate)
      + NAMRig::pinMagnitudeDb(NAMRig::pinCoefficients(NAMRig::kPinBell, std::min(p.voiceHz, band), p.voiceDb, p.voiceQ, rate), hz, rate)
      + NAMRig::pinMagnitudeDb(NAMRig::pinCoefficients(NAMRig::kPinBell, std::min(p.leakageHz, band * .9), p.leakageDb, p.leakageQ, rate), hz, rate)
      + NAMRig::pinMagnitudeDb(NAMRig::pinPassCoefficients(false, std::min(p.highCutHz, band), rate), hz, rate)
      + 20 * std::log10(p.makeup);
}

@end

@implementation NAMSpeakerDynamicsVisualizer
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.toolTip = @"Quiet-signal response of the speaker load (resonance, voice-coil rise, thump) including the power amp's damping. Cone compression and drive react to level and are not drawn.";
    _pinEditor = [[NAMPinEQEditor alloc] initWithPane:NAMRig::PinEqPane::Speaker
        accent:[NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:1.0]];
    __weak NAMInteractiveGraph* weakSelf = self;
    _pinEditor.baseResponseDb = ^double(double hz) { return [weakSelf responseDbAtFrequency:hz]; };
    [self addSubview:_pinEditor];
  }
  return self;
}
- (NSRect)plotRect {
  const NSRect r = self.bounds;
  return NSMakeRect(24.0, 16.0, r.size.width - 40.0, r.size.height - 40.0);
}
- (void)layout {
  [super layout];
  _pinEditor.frame = NSInsetRect([self plotRect], -kPinEditorInset, -kPinEditorInset);
}
- (BOOL)isFlipped { return NO; }
- (void)setDrive:(float)v { _drive = v; self.needsDisplay = YES; }
- (void)setComp:(float)v { _comp = v; self.needsDisplay = YES; }
- (void)setThump:(float)v { _thump = v; self.needsDisplay = YES; }
- (void)setResonance:(float)v { _resonance = v; self.needsDisplay = YES; }
- (void)setProfile:(int)v { _profile = NAMRig::SpeakerDynamics::clampProfile(v); self.needsDisplay = YES; }
- (void)setDamping:(float)v { _damping = v; self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirty {
  NSRect r = self.bounds;
  if (r.size.width < 10 || r.size.height < 10) return;

  NSBezierPath* bg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:6.0 yRadius:6.0];
  [rigBG() setFill];
  [bg fill];
  [rigPanelBorder() setStroke];
  bg.lineWidth = 1.0;
  [bg stroke];

  NSDictionary* headerAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:9.0 weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.95]
  };
  [@"SPEAKER LOAD RESPONSE" drawAtPoint:NSMakePoint(14, r.size.height - 18) withAttributes:headerAttrs];

  const bool captured = _profile == NAMRig::SpeakerDynamics::kCaptured;
  NSString* stat = captured
      ? @"CAPTURED LOAD  •  BYPASS"
      : [NSString stringWithFormat:@"DRV: %.0f%%  •  COMP: %.0f%%  •  THUMP: %.0f%%", _drive, _comp, _thump];
  NSDictionary* statAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.9]
  };
  NSSize ssz = [stat sizeWithAttributes:statAttrs];
  [stat drawAtPoint:NSMakePoint(r.size.width - 14 - ssz.width, r.size.height - 18) withAttributes:statAttrs];

  // The DSP's own load filters (speaker_dynamics.h) on the pin editor's axes:
  // log frequency 20 Hz..20 kHz, +/-18 dB.
  const NSRect plot = [self plotRect];
  const CGFloat leftM = NSMinX(plot), pw = plot.size.width;

  NSBezierPath* zero = [NSBezierPath bezierPath];
  [zero moveToPoint:NSMakePoint(leftM, NSMidY(plot))];
  [zero lineToPoint:NSMakePoint(leftM + pw, NSMidY(plot))];
  zero.lineWidth = 0.75;
  CGFloat dash[2] = {2.0, 3.0};
  [zero setLineDash:dash count:2 phase:0.0];
  [[NSColor colorWithSRGBRed:0.22 green:0.25 blue:0.32 alpha:0.6] setStroke];
  [zero stroke];

}
- (double)responseDbAtFrequency:(double)hz {
  return NAMRig::SpeakerDynamics::responseDb(_profile, hz, kPinPlotRate, _thump, _resonance, _damping);
}

@end

@implementation NAMCabConsoleVisualizer
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _pinEditor = [[NAMPinEQEditor alloc] initWithPane:NAMRig::PinEqPane::CabConsole
        accent:[NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:1.0]];
    __weak NAMInteractiveGraph* weakSelf = self;
    _pinEditor.baseResponseDb = ^double(double hz) { return [weakSelf responseDbAtFrequency:hz]; };
    [self addSubview:_pinEditor];
  }
  return self;
}
- (NSRect)plotRect {
  const NSRect r = self.bounds;
  return NSMakeRect(24.0, 16.0, r.size.width - 40.0, r.size.height - 40.0);
}
- (void)layout {
  [super layout];
  _pinEditor.frame = NSInsetRect([self plotRect], -kPinEditorInset, -kPinEditorInset);
}
- (BOOL)isFlipped { return NO; }
- (void)setCabALevel:(float)v { _cabALevel = v; self.needsDisplay = YES; }
- (void)setCabBLevel:(float)v { _cabBLevel = v; self.needsDisplay = YES; }
- (void)setAlignDelay:(float)v { _alignDelay = v; self.needsDisplay = YES; }
- (void)setLowCut:(float)v { _lowCut = v; self.needsDisplay = YES; }
- (void)setHighCut:(float)v { _highCut = v; self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirty {
  NSRect r = self.bounds;
  if (r.size.width < 10 || r.size.height < 10) return;

  NSBezierPath* bg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:6.0 yRadius:6.0];
  [rigBG() setFill];
  [bg fill];
  [rigPanelBorder() setStroke];
  bg.lineWidth = 1.0;
  [bg stroke];

  NSDictionary* headerAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:9.0 weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.95]
  };
  [@"CAB A / B ALIGNMENT & DUAL CUT FILTERS" drawAtPoint:NSMakePoint(14, r.size.height - 18) withAttributes:headerAttrs];

  NSString* stat = [NSString stringWithFormat:@"ALIGN: %+.2f ms  •  LOW: %.0f Hz  •  HI: %.0f Hz", _alignDelay, _lowCut, _highCut];
  NSDictionary* statAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.9]
  };
  NSSize ssz = [stat sizeWithAttributes:statAttrs];
  [stat drawAtPoint:NSMakePoint(r.size.width - 14 - ssz.width, r.size.height - 18) withAttributes:statAttrs];

  // The DSP's cut filters (2nd-order Butterworth) on the pin editor's axes:
  // log frequency 20 Hz..20 kHz, +/-18 dB.
  const NSRect plot = [self plotRect];
  const CGFloat leftM = NSMinX(plot), pw = plot.size.width;
  NSBezierPath* zero = [NSBezierPath bezierPath];
  [zero moveToPoint:NSMakePoint(leftM, NSMidY(plot))];
  [zero lineToPoint:NSMakePoint(leftM + pw, NSMidY(plot))];
  zero.lineWidth = 0.75;
  CGFloat dash[2] = {2.0, 3.0};
  [zero setLineDash:dash count:2 phase:0.0];
  [[NSColor colorWithSRGBRed:0.22 green:0.25 blue:0.32 alpha:0.6] setStroke];
  [zero stroke];

}
- (double)responseDbAtFrequency:(double)hz {
  double db = 0;
  if (_lowCut >= 20) db += NAMRig::pinMagnitudeDb(NAMRig::pinPassCoefficients(true, _lowCut, kPinPlotRate), hz, kPinPlotRate);
  if (_highCut < 19990) db += NAMRig::pinMagnitudeDb(NAMRig::pinPassCoefficients(false, std::max(1000.0f, _highCut), kPinPlotRate), hz, kPinPlotRate);
  return db;
}

@end

@implementation RigAlertTextField
- (BOOL)performKeyEquivalent:(NSEvent*)event {
  NSEventModifierFlags mods = event.modifierFlags &
      (NSEventModifierFlagCommand | NSEventModifierFlagOption |
       NSEventModifierFlagControl | NSEventModifierFlagShift);
  NSString* chars = [event.charactersIgnoringModifiers lowercaseString] ?: @"";
  if (mods == NSEventModifierFlagCommand) {
    if ([chars isEqualToString:@"a"] || event.keyCode == 0) {
      NSText* editor = [self currentEditor];
      if (editor) [editor selectAll:nil];
      else [self selectText:nil];
      return YES;
    }
    if ([chars isEqualToString:@"c"] || event.keyCode == 8) {
      NSText* editor = [self currentEditor];
      if (editor) [editor copy:nil];
      return YES;
    }
    if ([chars isEqualToString:@"v"] || event.keyCode == 9) {
      NSText* editor = [self currentEditor];
      if (editor) [editor paste:nil];
      return YES;
    }
    if ([chars isEqualToString:@"x"] || event.keyCode == 7) {
      NSText* editor = [self currentEditor];
      if (editor) [editor cut:nil];
      return YES;
    }
    if ([chars isEqualToString:@"z"] || event.keyCode == 6) {
      NSText* editor = [self currentEditor];
      if (editor && [editor.undoManager canUndo]) {
        [editor.undoManager undo];
        return YES;
      }
    }
  }
  return [super performKeyEquivalent:event];
}
@end

// ---- RigStageMeterView ----

@implementation RigStageMeterView {
  float _levelDb;
  float _peakDb;
  CFAbsoluteTime _peakHoldTime;
  CFAbsoluteTime _lastPeakUpdateTime;
  CFAbsoluteTime _clipUntil;
  NSTimer* _meterTimer;
}

- (instancetype)initWithTitle:(NSString*)title
                     subtitle:(NSString*)subtitle
                  accentColor:(NSColor*)accentColor {
  if ((self = [super initWithFrame:NSZeroRect])) {
    _title = [title copy];
    _subtitle = [subtitle copy];
    _accentColor = accentColor ?: rigAccent();
    _levelDb = -120.0f;
    _peakDb = -120.0f;
    _peakHoldTime = 0.0;
    self.wantsLayer = YES;
  }
  return self;
}

- (BOOL)isFlipped { return YES; }

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [_meterTimer invalidate];
  _meterTimer = nil;
  if (!self.window) return;
  __weak RigStageMeterView* weakSelf = self;
  _meterTimer = [NSTimer timerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer* timer) {
    RigStageMeterView* meter = weakSelf;
    if (!meter) { [timer invalidate]; return; }
    [meter advancePeakAtTime:CACurrentMediaTime()];
    meter.needsDisplay = YES;
  }];
  [[NSRunLoop mainRunLoop] addTimer:_meterTimer forMode:NSRunLoopCommonModes];
}

- (void)dealloc { [_meterTimer invalidate]; }

- (void)advancePeakAtTime:(CFAbsoluteTime)now {
  const double elapsed = std::max(0.0, now - std::max(_lastPeakUpdateTime, _peakHoldTime));
  _peakDb = std::max(_levelDb, _peakDb - static_cast<float>(20.0 * elapsed));
  _lastPeakUpdateTime = now;
}

- (void)setLevelDb:(float)db {
  if (!std::isfinite(db)) return;
  const CFAbsoluteTime now = CACurrentMediaTime();
  [self advancePeakAtTime:now];
  _levelDb = db;
  if (db >= _peakDb) {
    _peakDb = db;
    _peakHoldTime = now + 1.2;
  }
  if (db >= -0.5f) _clipUntil = now + 1.2;
}

- (float)levelDb { return _levelDb; }
- (float)peakDb { return _peakDb; }
- (BOOL)clipping { return _levelDb >= -0.5f || CACurrentMediaTime() < _clipUntil; }

- (void)drawHorizontalMeter {
  const CGFloat w = self.bounds.size.width;
  NSString* name = [NSString stringWithFormat:@"%@ · %@", _title, _subtitle];
  [name drawInRect:NSMakeRect(0, 0, w - 90, 14) withAttributes:@{
    NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName: _accentColor
  }];
  NSMutableParagraphStyle* right = [[NSMutableParagraphStyle alloc] init];
  right.alignment = NSTextAlignmentRight;
  NSColor* hot = [NSColor colorWithSRGBRed:0.95 green:0.20 blue:0.18 alpha:1];
  NSColor* color = self.clipping ? hot : (_levelDb >= -6 ? rigOrange() : _accentColor);
  NSString* value = _levelDb <= -119 ? @"— dB" : [NSString stringWithFormat:@"%+.1f dB", _levelDb];
  [value drawInRect:NSMakeRect(w - 90, 0, 78, 14) withAttributes:@{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: color,
    NSParagraphStyleAttributeName: right
  }];
  NSBezierPath* led = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(w - 6, 4, 5, 5)];
  [(self.clipping ? hot : [hot colorWithAlphaComponent:0.2]) setFill];
  [led fill];
  const CGFloat trackW = w - 2;
  NSRect track = NSMakeRect(1, 18, trackW, 7);
  [rigRaised() setFill];
  [[NSBezierPath bezierPathWithRoundedRect:track xRadius:3 yRadius:3] fill];
  CGFloat fraction = (std::clamp(_levelDb, -60.0f, 0.0f) + 60) / 60;
  if (fraction > 0) {
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1, 18, trackW * fraction, 7)
                                   xRadius:3 yRadius:3] fill];
  }
  if (_peakDb > -60) {
    CGFloat peakX = 1 + (trackW - 1.5) * (std::clamp(_peakDb, -60.0f, 0.0f) + 60) / 60;
    [rigText() setFill];
    NSRectFill(NSMakeRect(peakX, 17, 1.5, 9));
  }
  for (int db : {-60, -24, -12, -6, 0}) {
    CGFloat x = 1 + trackW * (db + 60) / 60;
    [rigPanelBorder() setFill];
    NSRectFill(NSMakeRect(MIN(x, w - 1), 27, 1, 2));
    [[NSString stringWithFormat:@"%d", db] drawInRect:NSMakeRect(std::clamp(x - 8, 0.0, w - 20), 30, 20, 10)
        withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:7],
                         NSForegroundColorAttributeName: rigDimText()}];
  }
}

- (void)drawRect:(NSRect)dirtyRect {
  const NSRect bounds = self.bounds;
  const CGFloat w = bounds.size.width;
  const CGFloat h = bounds.size.height;
  if (w <= 0 || h <= 0) return;

  if (self.horizontal) { [self drawHorizontalMeter]; return; }

  // Background panel
  NSRect panelRect = NSInsetRect(bounds, 0.5, 0.5);
  NSBezierPath* panelPath = [NSBezierPath bezierPathWithRoundedRect:panelRect xRadius:8.0 yRadius:8.0];
  NSGradient* bgGrad = [[NSGradient alloc] initWithStartingColor:rigPanelBottom() endingColor:rigPanelTop()];
  [bgGrad drawInBezierPath:panelPath angle:-90.0];
  panelPath.lineWidth = 1.0;
  [rigPanelBorder() setStroke];
  [panelPath stroke];

  // Header Title
  NSMutableParagraphStyle* centerStyle = [[NSMutableParagraphStyle alloc] init];
  centerStyle.alignment = NSTextAlignmentCenter;
  NSDictionary* titleAttr = @{
    NSFontAttributeName: [NSFont systemFontOfSize:9.5 weight:NSFontWeightBold],
    NSForegroundColorAttributeName: _accentColor,
    NSParagraphStyleAttributeName: centerStyle
  };
  NSRect titleRect = NSMakeRect(2, 6, w - 4, 13);
  [_title drawInRect:titleRect withAttributes:titleAttr];

  // Subtitle
  NSDictionary* subAttr = @{
    NSFontAttributeName: [NSFont systemFontOfSize:7.0 weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName: rigDimText(),
    NSParagraphStyleAttributeName: centerStyle
  };
  NSRect subRect = NSMakeRect(1, 19, w - 2, 11);
  [_subtitle drawInRect:subRect withAttributes:subAttr];

  // Numeric dB readout pill
  NSRect readoutPill = NSMakeRect(2, 31, w - 4, 14);
  NSBezierPath* pillPath = [NSBezierPath bezierPathWithRoundedRect:readoutPill xRadius:3.0 yRadius:3.0];
  [rigRaised() setFill];
  [pillPath fill];
  [rigPanelBorder() setStroke];
  pillPath.lineWidth = 0.5;
  [pillPath stroke];

  NSString* dbStr = (_levelDb <= -119.0f) ? @"  —  "
      : [NSString stringWithFormat:@"%+.1f", _levelDb];
  NSColor* dbTextColor = (_levelDb >= -0.5f) ? [NSColor colorWithSRGBRed:0.95 green:0.20 blue:0.18 alpha:1.0]
      : (_levelDb >= -6.0f) ? rigOrange()
      : (_levelDb >= -12.0f) ? [NSColor colorWithSRGBRed:1.00 green:0.75 blue:0.25 alpha:1.0]
      : rigText();
  NSDictionary* dbAttr = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: dbTextColor,
    NSParagraphStyleAttributeName: centerStyle
  };
  NSRect dbTextRect = NSMakeRect(readoutPill.origin.x, readoutPill.origin.y + 1, readoutPill.size.width, readoutPill.size.height - 2);
  [dbStr drawInRect:dbTextRect withAttributes:dbAttr];

  // Track Slot Geometry
  const CGFloat trackW = 7.0;
  const CGFloat trackX = w - trackW - 6.0;
  const CGFloat trackTopY = 56.0;
  const CGFloat trackBottomY = h - 10.0;
  const CGFloat trackH = trackBottomY - trackTopY;
  if (trackH <= 0) return;
  NSRect trackRect = NSMakeRect(trackX, trackTopY, trackW, trackH);

  // Clip LED (at top of meter)
  const CGFloat ledSize = 4.0;
  const CGFloat ledX = trackX + (trackW - ledSize) * 0.5;
  const CGFloat ledY = trackTopY - 6.5;
  NSRect ledRect = NSMakeRect(ledX, ledY, ledSize, ledSize);
  NSBezierPath* ledPath = [NSBezierPath bezierPathWithOvalInRect:ledRect];
  if (self.clipping) {
    [[NSColor colorWithSRGBRed:1.0 green:0.18 blue:0.18 alpha:1.0] setFill];
  } else {
    [[NSColor colorWithSRGBRed:0.28 green:0.08 blue:0.08 alpha:1.0] setFill];
  }
  [ledPath fill];

  // Track Slot Background
  NSBezierPath* trackPath = [NSBezierPath bezierPathWithRoundedRect:trackRect xRadius:2.5 yRadius:2.5];
  [[rigRaised() blendedColorWithFraction:0.35 ofColor:NSColor.blackColor] setFill];
  [trackPath fill];
  trackPath.lineWidth = 0.5;
  [[rigPanelBorder() colorWithAlphaComponent:0.6] setStroke];
  [trackPath stroke];

  // Fill Bar
  const float clampedDb = std::clamp(_levelDb, -60.0f, 0.0f);
  const CGFloat frac = (_levelDb <= -119.0f) ? 0.0 : (clampedDb + 60.0f) / 60.0f;
  const CGFloat fillH = trackH * frac;
  if (fillH > 0.5) {
    NSRect fillRect = NSMakeRect(trackX + 0.5, trackBottomY - fillH, trackW - 1.0, fillH);
    NSBezierPath* fillPath = [NSBezierPath bezierPathWithRoundedRect:fillRect xRadius:1.5 yRadius:1.5];
    NSColor* fillColor = (_levelDb >= -0.5f) ? [NSColor colorWithSRGBRed:0.95 green:0.20 blue:0.18 alpha:1.0]
        : (_levelDb >= -6.0f) ? rigOrange()
        : (_levelDb >= -12.0f) ? [NSColor colorWithSRGBRed:1.00 green:0.75 blue:0.25 alpha:1.0]
        : _accentColor;
    [fillColor setFill];
    [fillPath fill];
  }

  // Peak Hold Indicator
  if (_peakDb > -60.0f) {
    const float clampedPeak = std::clamp(_peakDb, -60.0f, 0.0f);
    const CGFloat peakFrac = (clampedPeak + 60.0f) / 60.0f;
    const CGFloat peakY = trackBottomY - trackH * peakFrac;
    NSRect peakRect = NSMakeRect(trackX, peakY - 0.75, trackW, 1.5);
    NSBezierPath* peakPath = [NSBezierPath bezierPathWithRect:peakRect];
    [[NSColor colorWithSRGBRed:1.0 green:1.0 blue:1.0 alpha:0.9] setFill];
    [peakPath fill];
  }

  // Scale Tick Marks and Labels (Left of track)
  static const struct {
    float dbVal;
    const char* label;
  } kTicks[] = {
    {0.0f, "0"},
    {-6.0f, "-6"},
    {-12.0f, "-12"},
    {-24.0f, "-24"},
    {-40.0f, "-40"},
    {-60.0f, "-60"}
  };

  NSMutableParagraphStyle* rightStyle = [[NSMutableParagraphStyle alloc] init];
  rightStyle.alignment = NSTextAlignmentRight;
  NSDictionary* tickAttr = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:6.5 weight:NSFontWeightRegular],
    NSForegroundColorAttributeName: [rigDimText() colorWithAlphaComponent:0.7],
    NSParagraphStyleAttributeName: rightStyle
  };

  for (const auto& tick : kTicks) {
    const CGFloat vFrac = (tick.dbVal + 60.0f) / 60.0f;
    const CGFloat tickY = trackBottomY - trackH * vFrac;

    // Tick notch line
    NSBezierPath* notch = [NSBezierPath bezierPath];
    [notch moveToPoint:NSMakePoint(trackX - 3.5, tickY)];
    [notch lineToPoint:NSMakePoint(trackX - 1.0, tickY)];
    notch.lineWidth = 1.0;
    [[rigPanelBorder() colorWithAlphaComponent:0.8] setStroke];
    [notch stroke];

    // Label
    NSString* tStr = [NSString stringWithUTF8String:tick.label];
    NSRect tRect = NSMakeRect(1.0, tickY - 4.5, trackX - 5.0, 9.0);
    [tStr drawInRect:tRect withAttributes:tickAttr];
  }
}
@end
