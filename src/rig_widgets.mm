#import "rig_widgets.h"
#import "rig_theme.h"
#import <ImageIO/ImageIO.h>

#include "pin_eq.h"
#include "power_tube_controls.h"
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
    arc.lineWidth = 7.0;
    [[valueColor colorWithAlphaComponent:0.22] setStroke];
    [arc stroke];
    arc.lineWidth = 3.0;
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
  if ((self = [super initWithFrame:frame])) _cornerRadius = 12.0;
  return self;
}
- (void)setCornerRadius:(CGFloat)radius { _cornerRadius = radius; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
  NSRect r = NSInsetRect(self.bounds, 0.5, 0.5);
  NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:r
                                                    xRadius:_cornerRadius
                                                    yRadius:_cornerRadius];
  NSGradient* g = [[NSGradient alloc] initWithStartingColor:rigPanelBottom()
                                                endingColor:rigPanelTop()];
  [g drawInBezierPath:p angle:90.0];
  p.lineWidth = 1.0;
  [rigPanelBorder() setStroke];
  [p stroke];
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
    NSColor* base = on ? rigAccent() : rigAccentDim();
    if (self.isHighlighted) base = [base blendedColorWithFraction:0.22 ofColor:NSColor.blackColor];
    else if (_hovered) base = [base blendedColorWithFraction:0.14 ofColor:NSColor.whiteColor];
    NSGradient* g = [[NSGradient alloc]
        initWithStartingColor:[base blendedColorWithFraction:0.18 ofColor:NSColor.blackColor]
                  endingColor:base];
    [g drawInBezierPath:p angle:90.0];
    border = [base blendedColorWithFraction:0.22 ofColor:NSColor.whiteColor];
  } else {
    NSColor* fill = on ? [rigAccent() colorWithAlphaComponent:0.24]
                       : (self.isHighlighted ? rigRaised()
                                             : (_hovered ? [rigRaised() colorWithAlphaComponent:0.85]
                                                         : rigPanelBG()));
    [fill setFill];
    [p fill];
    border = on ? [rigAccent() colorWithAlphaComponent:0.75]
                : ((_hovered || self.isHighlighted) ? [rigAccent() colorWithAlphaComponent:0.45]
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
    NSColor* dc = on ? rigGreen() : [rigDimText() colorWithAlphaComponent:0.5];
    if (on) {
      [[rigGreen() colorWithAlphaComponent:0.30] setFill];
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
    NSColor* tc = self.primary ? NSColor.whiteColor
        : ((_hovered || self.isHighlighted || on) ? rigText() : rigDimText());
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
- (NSPoint)pointForBand:(NSInteger)band {
  const NSRect plot = [self plotRect];
  return NSMakePoint(pinPlotX(plot, [self band:band param:NAMRig::kPinFreq]),
                     pinPlotY(plot, [self band:band param:NAMRig::kPinGain]));
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
  const NAMRig::PinBands bands = [self bands];
  BOOL any = NO;
  for (NSInteger b = 0; b < (NSInteger)NAMRig::kPinEqBandCount; ++b) any |= [self hasPin:b];

  if (any) {
    NSBezierPath* curve = [NSBezierPath bezierPath];
    const int n = std::max(48, (int)(plot.size.width / 2.0));
    for (int i = 0; i <= n; ++i) {
      const double t = (double)i / n;
      const double hz = 20.0 * std::pow(1000.0, t);
      const NSPoint p = NSMakePoint(NSMinX(plot) + t * plot.size.width,
                                    pinPlotY(plot, NAMRig::pinBandsMagnitudeDb(bands, hz, kPinPlotRate)));
      if (i == 0) [curve moveToPoint:p];
      else [curve lineToPoint:p];
    }
    NSBezierPath* fill = [curve copy];
    [fill lineToPoint:NSMakePoint(NSMaxX(plot), NSMidY(plot))];
    [fill lineToPoint:NSMakePoint(NSMinX(plot), NSMidY(plot))];
    [fill closePath];
    [[NSColor colorWithSRGBRed:0.92 green:0.95 blue:1.0 alpha:0.10] setFill];
    [fill fill];
    curve.lineWidth = 1.6;
    curve.lineJoinStyle = NSLineJoinStyleRound;
    [[NSColor colorWithSRGBRed:0.92 green:0.95 blue:1.0 alpha:0.90] setStroke];
    [curve stroke];
  } else if (_mouseInside) {
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
    [self send:b param:NAMRig::kPinFreq value:(float)[self freqAtX:p.x]];
    [self send:b param:NAMRig::kPinGain value:(float)[self gainAtY:p.y]];
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
  _dragMoved = NO;
  self.needsDisplay = YES;
}
- (void)mouseDragged:(NSEvent*)event {
  if (_drag < 0) return;
  const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  [self send:_drag param:NAMRig::kPinFreq value:(float)[self freqAtX:p.x]];
  [self send:_drag param:NAMRig::kPinGain value:(float)[self gainAtY:p.y]];
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

@implementation NAMDelayTapVisualizer
- (BOOL)isFlipped { return NO; }
- (void)setTimeMs:(float)v { _timeMs = v; self.needsDisplay = YES; }
- (void)setFeedback:(float)v { _feedback = v; self.needsDisplay = YES; }
- (void)setDamping:(float)v { _damping = v; self.needsDisplay = YES; }
- (void)setMix:(float)v { _mix = v; self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirty {
  NSRect r = self.bounds;
  if (r.size.width < 10 || r.size.height < 10) return;

  NSBezierPath* bg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:6.0 yRadius:6.0];
  [[NSColor colorWithSRGBRed:0.07 green:0.08 blue:0.10 alpha:1.0] setFill];
  [bg fill];
  [[NSColor colorWithSRGBRed:0.18 green:0.20 blue:0.25 alpha:0.75] setStroke];
  bg.lineWidth = 1.0;
  [bg stroke];

  const CGFloat leftMargin = 32.0;
  const CGFloat rightMargin = 16.0;
  const CGFloat topMargin = 20.0;
  const CGFloat bottomMargin = 18.0;
  const CGFloat plotW = r.size.width - leftMargin - rightMargin;
  const CGFloat plotH = r.size.height - topMargin - bottomMargin;
  const CGFloat midY = bottomMargin + plotH * 0.5;

  const float maxTimeMs = 2000.0f;
  const float gridSteps[4] = {500.0f, 1000.0f, 1500.0f, 2000.0f};
  const char* gridLabels[4] = {"500ms", "1.0s", "1.5s", "2.0s"};

  NSDictionary* gridAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:7.5 weight:NSFontWeightRegular],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.45 green:0.48 blue:0.55 alpha:0.8]
  };

  [@"0" drawAtPoint:NSMakePoint(leftMargin - 4, 3) withAttributes:gridAttrs];

  for (int g = 0; g < 4; ++g) {
    CGFloat gx = leftMargin + (gridSteps[g] / maxTimeMs) * plotW;
    NSBezierPath* line = [NSBezierPath bezierPath];
    [line moveToPoint:NSMakePoint(gx, bottomMargin)];
    [line lineToPoint:NSMakePoint(gx, bottomMargin + plotH)];
    CGFloat pattern[2] = {2.0, 3.0};
    [line setLineDash:pattern count:2 phase:0.0];
    line.lineWidth = 0.75;
    [[NSColor colorWithSRGBRed:0.20 green:0.22 blue:0.28 alpha:0.5] setStroke];
    [line stroke];

    NSString* gl = [NSString stringWithUTF8String:gridLabels[g]];
    [gl drawAtPoint:NSMakePoint(gx - 12, 3) withAttributes:gridAttrs];
  }

  NSBezierPath* base = [NSBezierPath bezierPath];
  [base moveToPoint:NSMakePoint(leftMargin, midY)];
  [base lineToPoint:NSMakePoint(leftMargin + plotW, midY)];
  base.lineWidth = 1.0;
  [[NSColor colorWithSRGBRed:0.25 green:0.28 blue:0.35 alpha:0.8] setStroke];
  [base stroke];

  NSDictionary* chAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:8.0 weight:NSFontWeightBold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.60 green:0.65 blue:0.75 alpha:0.9]
  };
  [@"L" drawAtPoint:NSMakePoint(12, midY + 10) withAttributes:chAttrs];
  [@"R" drawAtPoint:NSMakePoint(12, midY - 20) withAttributes:chAttrs];

  NSString* info = [NSString stringWithFormat:@"%.0f ms  •  FDBK %.0f%%  •  DAMP %.0f%%",
                    _timeMs, _feedback, _damping];
  NSDictionary* infoAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.80 green:0.65 blue:1.0 alpha:0.95]
  };
  NSSize infoSize = [info sizeWithAttributes:infoAttrs];
  [info drawAtPoint:NSMakePoint(r.size.width - rightMargin - infoSize.width, r.size.height - topMargin + 2)
     withAttributes:infoAttrs];

  NSDictionary* titleAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:8.5 weight:NSFontWeightBold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.55 green:0.58 blue:0.68 alpha:0.9]
  };
  [@"PING-PONG ECHO PATTERN" drawAtPoint:NSMakePoint(leftMargin, r.size.height - topMargin + 2)
                         withAttributes:titleAttrs];

  const float mixNorm = std::min(1.0f, std::max(0.0f, _mix / 100.0f));
  if (mixNorm < 0.01f) {
    NSDictionary* offAttrs = @{
      NSFontAttributeName: [NSFont systemFontOfSize:9.0 weight:NSFontWeightMedium],
      NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.45 green:0.48 blue:0.55 alpha:0.8]
    };
    NSString* offTxt = @"[DELAY BYPASSED / MIX OFF]";
    NSSize sz = [offTxt sizeWithAttributes:offAttrs];
    [offTxt drawAtPoint:NSMakePoint(leftMargin + (plotW - sz.width) * 0.5, midY - sz.height * 0.5)
         withAttributes:offAttrs];
    return;
  }

  NSBezierPath* dryLine = [NSBezierPath bezierPath];
  [dryLine moveToPoint:NSMakePoint(leftMargin, midY - 14)];
  [dryLine lineToPoint:NSMakePoint(leftMargin, midY + 14)];
  dryLine.lineWidth = 2.0;
  dryLine.lineCapStyle = NSLineCapStyleRound;
  [[NSColor colorWithSRGBRed:0.35 green:0.85 blue:0.95 alpha:0.9] setStroke];
  [dryLine stroke];

  const float stepMs = std::max(15.0f, _timeMs);
  const float fdbk = std::min(0.96f, std::max(0.0f, _feedback / 100.0f));
  const float damp = std::min(1.0f, std::max(0.0f, _damping / 100.0f));
  const CGFloat maxStemH = (plotH * 0.5 - 6.0);

  int tapIndex = 1;
  float tMs = stepMs;
  while (tMs <= maxTimeMs && tapIndex <= 10) {
    CGFloat x = leftMargin + (tMs / maxTimeMs) * plotW;
    float amp = std::pow(fdbk, (float)(tapIndex - 1)) * mixNorm;
    CGFloat stemH = maxStemH * amp;
    if (stemH < 1.5) break;

    BOOL isLeft = (tapIndex % 2 == 1);
    CGFloat yEnd = isLeft ? (midY + stemH) : (midY - stemH);

    float dampLoss = 1.0f - (float)tapIndex * 0.08f * damp;
    dampLoss = std::max(0.2f, dampLoss);
    NSColor* tapColor = [NSColor colorWithSRGBRed:0.75 + 0.15 * damp * (tapIndex * 0.1)
                                            green:0.55 * dampLoss
                                             blue:0.98 * dampLoss
                                            alpha:0.4 + 0.55 * dampLoss];

    NSBezierPath* stem = [NSBezierPath bezierPath];
    [stem moveToPoint:NSMakePoint(x, midY)];
    [stem lineToPoint:NSMakePoint(x, yEnd)];
    stem.lineWidth = 2.5;
    stem.lineCapStyle = NSLineCapStyleRound;
    [tapColor setStroke];
    [stem stroke];

    NSRect dotR = NSMakeRect(x - 3.5, yEnd - 3.5, 7.0, 7.0);
    NSBezierPath* dot = [NSBezierPath bezierPathWithOvalInRect:dotR];
    [tapColor setFill];
    [dot fill];

    NSRect haloR = NSMakeRect(x - 5.5, yEnd - 5.5, 11.0, 11.0);
    NSBezierPath* halo = [NSBezierPath bezierPathWithOvalInRect:haloR];
    [[tapColor colorWithAlphaComponent:0.25] setStroke];
    halo.lineWidth = 1.5;
    [halo stroke];

    tMs += stepMs;
    tapIndex++;
  }
}
@end

@implementation NAMReverbDecayVisualizer
- (BOOL)isFlipped { return NO; }
- (void)setMix:(float)v { _mix = v; self.needsDisplay = YES; }
- (void)setDecay:(float)v { _decay = v; self.needsDisplay = YES; }
- (void)setSize:(float)v { _size = v; self.needsDisplay = YES; }
- (void)setDamping:(float)v { _damping = v; self.needsDisplay = YES; }
- (void)setPreDelay:(float)v { _preDelay = v; self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirty {
  NSRect r = self.bounds;
  if (r.size.width < 10 || r.size.height < 10) return;

  NSBezierPath* bg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:6.0 yRadius:6.0];
  [[NSColor colorWithSRGBRed:0.07 green:0.08 blue:0.10 alpha:1.0] setFill];
  [bg fill];
  [[NSColor colorWithSRGBRed:0.18 green:0.20 blue:0.25 alpha:0.75] setStroke];
  bg.lineWidth = 1.0;
  [bg stroke];

  const CGFloat leftMargin = 38.0;
  const CGFloat rightMargin = 16.0;
  const CGFloat topMargin = 20.0;
  const CGFloat bottomMargin = 18.0;
  const CGFloat plotW = r.size.width - leftMargin - rightMargin;
  const CGFloat plotH = r.size.height - topMargin - bottomMargin;

  NSDictionary* dbAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:7.5 weight:NSFontWeightRegular],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.45 green:0.48 blue:0.55 alpha:0.8]
  };

  const char* dbLabels[4] = {"0 dB", "-20", "-40", "-60"};
  for (int d = 0; d < 4; ++d) {
    CGFloat y = bottomMargin + plotH * (1.0 - (CGFloat)d / 3.0);
    NSBezierPath* line = [NSBezierPath bezierPath];
    [line moveToPoint:NSMakePoint(leftMargin, y)];
    [line lineToPoint:NSMakePoint(leftMargin + plotW, y)];
    CGFloat pattern[2] = {2.0, 3.0};
    [line setLineDash:pattern count:2 phase:0.0];
    line.lineWidth = 0.75;
    [[NSColor colorWithSRGBRed:0.20 green:0.22 blue:0.28 alpha:0.45] setStroke];
    [line stroke];

    NSString* dbl = [NSString stringWithUTF8String:dbLabels[d]];
    [dbl drawAtPoint:NSMakePoint(4, y - 5) withAttributes:dbAttrs];
  }

  const float maxSec = 4.0f;
  for (int s = 1; s <= 4; ++s) {
    CGFloat sx = leftMargin + ((float)s / maxSec) * plotW;
    NSBezierPath* sline = [NSBezierPath bezierPath];
    [sline moveToPoint:NSMakePoint(sx, bottomMargin)];
    [sline lineToPoint:NSMakePoint(sx, bottomMargin + plotH)];
    CGFloat pattern[2] = {2.0, 3.0};
    [sline setLineDash:pattern count:2 phase:0.0];
    sline.lineWidth = 0.75;
    [[NSColor colorWithSRGBRed:0.20 green:0.22 blue:0.28 alpha:0.45] setStroke];
    [sline stroke];

    NSString* st = [NSString stringWithFormat:@"%ds", s];
    [st drawAtPoint:NSMakePoint(sx - 7, 3) withAttributes:dbAttrs];
  }

  const float rt60 = 0.35f + 4.15f * (_decay / 100.0f) * (0.35f + 0.65f * (_size / 100.0f));
  const float preSec = _preDelay / 1000.0f;

  NSString* info = [NSString stringWithFormat:@"RT60: %.2fs  •  PRE: %.0fms  •  DAMP: %.0f%%",
                    rt60, _preDelay, _damping];
  NSDictionary* infoAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.80 green:0.65 blue:1.0 alpha:0.95]
  };
  NSSize infoSize = [info sizeWithAttributes:infoAttrs];
  [info drawAtPoint:NSMakePoint(r.size.width - rightMargin - infoSize.width, r.size.height - topMargin + 2)
     withAttributes:infoAttrs];

  NSDictionary* titleAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:8.5 weight:NSFontWeightBold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.55 green:0.58 blue:0.68 alpha:0.9]
  };
  [@"EMT 140 PLATE DECAY ENVELOPE" drawAtPoint:NSMakePoint(leftMargin, r.size.height - topMargin + 2)
                               withAttributes:titleAttrs];

  const float mixNorm = std::min(1.0f, std::max(0.0f, _mix / 100.0f));
  if (mixNorm < 0.01f) {
    NSDictionary* offAttrs = @{
      NSFontAttributeName: [NSFont systemFontOfSize:9.0 weight:NSFontWeightMedium],
      NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.45 green:0.48 blue:0.55 alpha:0.8]
    };
    NSString* offTxt = @"[REVERB BYPASSED / MIX OFF]";
    NSSize sz = [offTxt sizeWithAttributes:offAttrs];
    [offTxt drawAtPoint:NSMakePoint(leftMargin + (plotW - sz.width) * 0.5, bottomMargin + plotH * 0.5 - sz.height * 0.5)
         withAttributes:offAttrs];
    return;
  }

  CGFloat xPre = leftMargin + (preSec / maxSec) * plotW;
  xPre = std::min(leftMargin + plotW * 0.4, xPre);

  if (_preDelay > 2.0f) {
    NSBezierPath* preLine = [NSBezierPath bezierPath];
    [preLine moveToPoint:NSMakePoint(xPre, bottomMargin)];
    [preLine lineToPoint:NSMakePoint(xPre, bottomMargin + plotH)];
    preLine.lineWidth = 1.0;
    CGFloat pattern[2] = {2.0, 2.0};
    [preLine setLineDash:pattern count:2 phase:0.0];
    [[NSColor colorWithSRGBRed:0.6 green:0.4 blue:0.8 alpha:0.6] setStroke];
    [preLine stroke];
  }

  NSBezierPath* curve = [NSBezierPath bezierPath];
  [curve moveToPoint:NSMakePoint(xPre, bottomMargin + plotH)];

  const int numPoints = 80;
  for (int i = 1; i <= numPoints; ++i) {
    float fraction = (float)i / (float)numPoints;
    float t = fraction * (maxSec - preSec);
    CGFloat x = xPre + (t / maxSec) * plotW;
    if (x > leftMargin + plotW) x = leftMargin + plotW;
    float db = -60.0f * (t / std::max(0.1f, rt60));
    db = std::max(-60.0f, db);
    CGFloat y = bottomMargin + (1.0f - (-db / 60.0f)) * plotH;
    [curve lineToPoint:NSMakePoint(x, y)];
  }

  NSBezierPath* fillPath = [curve copy];
  [fillPath lineToPoint:NSMakePoint(leftMargin + plotW, bottomMargin)];
  [fillPath lineToPoint:NSMakePoint(xPre, bottomMargin)];
  [fillPath closePath];

  NSGradient* g = [[NSGradient alloc]
      initWithStartingColor:[NSColor colorWithSRGBRed:0.65 green:0.35 blue:0.95 alpha:0.35 * mixNorm]
                endingColor:[NSColor colorWithSRGBRed:0.15 green:0.08 blue:0.25 alpha:0.02]];
  [g drawInBezierPath:fillPath angle:270.0];

  curve.lineWidth = 2.5;
  [[NSColor colorWithSRGBRed:0.80 green:0.55 blue:1.0 alpha:0.95 * mixNorm] setStroke];
  [curve stroke];

  if (_damping > 10.0f) {
    float rt60HF = rt60 * (1.0f - 0.60f * (_damping / 100.0f));
    NSBezierPath* hfCurve = [NSBezierPath bezierPath];
    [hfCurve moveToPoint:NSMakePoint(xPre, bottomMargin + plotH)];
    for (int i = 1; i <= numPoints; ++i) {
      float fraction = (float)i / (float)numPoints;
      float t = fraction * (maxSec - preSec);
      CGFloat x = xPre + (t / maxSec) * plotW;
      if (x > leftMargin + plotW) x = leftMargin + plotW;
      float db = -60.0f * (t / std::max(0.08f, rt60HF));
      db = std::max(-60.0f, db);
      CGFloat y = bottomMargin + (1.0f - (-db / 60.0f)) * plotH;
      [hfCurve lineToPoint:NSMakePoint(x, y)];
    }
    CGFloat pattern[2] = {4.0, 3.0};
    [hfCurve setLineDash:pattern count:2 phase:0.0];
    hfCurve.lineWidth = 1.5;
    [[NSColor colorWithSRGBRed:0.40 green:0.85 blue:0.90 alpha:0.75 * mixNorm] setStroke];
    [hfCurve stroke];
  }
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
  [[NSColor colorWithSRGBRed:0.07 green:0.08 blue:0.10 alpha:1.0] setFill];
  [bg fill];
  [[NSColor colorWithSRGBRed:0.18 green:0.20 blue:0.25 alpha:0.75] setStroke];
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
    NSFontAttributeName: [NSFont systemFontOfSize:8.5 weight:NSFontWeightBold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.95]
  };
  [@"STEREO VECTORSCOPE" drawAtPoint:NSMakePoint(14, r.size.height - 18) withAttributes:headerAttrs];

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
  [@"3D ROOM ACOUSTICS" drawAtPoint:NSMakePoint(splitX + 16, r.size.height - 18) withAttributes:headerAttrs];

  NSString* roomStat = [NSString stringWithFormat:@"SPREAD: %.0f%%  •  ROOM: %.0f%%", _width, _room];
  NSDictionary* rAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.0 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.9]
  };
  NSSize rsz = [roomStat sizeWithAttributes:rAttrs];
  [roomStat drawAtPoint:NSMakePoint(r.size.width - 16 - rsz.width, r.size.height - 18) withAttributes:rAttrs];

  CGFloat rw = r.size.width - splitX - 32.0;
  CGFloat rh = r.size.height - 34.0;
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
  [[NSColor colorWithSRGBRed:0.07 green:0.08 blue:0.10 alpha:1.0] setFill];
  [bg fill];
  [[NSColor colorWithSRGBRed:0.18 green:0.20 blue:0.25 alpha:0.75] setStroke];
  bg.lineWidth = 1.0;
  [bg stroke];

  NSDictionary* headerAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:8.5 weight:NSFontWeightBold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:0.95]
  };
  [@"POWER-STAGE RESPONSE" drawAtPoint:NSMakePoint(14, r.size.height - 18) withAttributes:headerAttrs];

  NSString* stat = [NSString stringWithFormat:@"SAG: %.0f%%  •  BIAS: %+.0f%%  •  NFB: %.0f%%", _sag, _bias, _feedback];
  NSDictionary* statAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.0 weight:NSFontWeightMedium],
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
    _pinEditor = [[NAMPinEQEditor alloc] initWithPane:NAMRig::PinEqPane::Sculpt
        accent:[NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:1.0]];
    [self addSubview:_pinEditor];
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
- (void)setBright:(float)v { _bright = v; self.needsDisplay = YES; }
- (void)setInputEq:(float)v { _inputEq = v; self.needsDisplay = YES; }
- (void)setMidPush:(float)v { _midPush = v; self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirty {
  NSRect r = self.bounds;
  if (r.size.width < 10 || r.size.height < 10) return;

  NSBezierPath* bg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:6.0 yRadius:6.0];
  [[NSColor colorWithSRGBRed:0.07 green:0.08 blue:0.10 alpha:1.0] setFill];
  [bg fill];
  [[NSColor colorWithSRGBRed:0.18 green:0.20 blue:0.25 alpha:0.75] setStroke];
  bg.lineWidth = 1.0;
  [bg stroke];

  NSDictionary* headerAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:8.5 weight:NSFontWeightBold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:0.95]
  };
  [@"PRE-AMP TIGHTENER, MID PUSH & BRIGHT" drawAtPoint:NSMakePoint(14, r.size.height - 18) withAttributes:headerAttrs];

  NSString* stat = [NSString stringWithFormat:@"BRIGHT: %+.1f dB  •  MID: %.0f%%  •  TIGHT: %.0f%%",
                    _bright * 0.06, _midPush, _inputEq];
  NSDictionary* statAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.0 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:0.9]
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

  // The DSP's own filters (amp_advanced.h): Input EQ high-pass at 20..180 Hz,
  // Bright +6 dB shelf at 2.2 kHz, Mid Push +9 dB bell at 750 Hz (Q 0.8).
  NSBezierPath* curve = [NSBezierPath bezierPath];
  const int nPts = 120;
  const float tight = std::clamp(_inputEq / 100.0f, 0.0f, 1.0f);
  const float bright = std::clamp(_bright / 100.0f, 0.0f, 1.0f);
  const float mid = std::clamp(_midPush / 100.0f, 0.0f, 1.0f);
  const NAMRig::PinCoeffs hp = NAMRig::pinPassCoefficients(true, 20.0 + 160.0 * tight, kPinPlotRate);
  const NAMRig::PinCoeffs shelf = NAMRig::pinCoefficients(NAMRig::kPinHighShelf, 2200.0, 6.0 * bright,
                                                          0.7071067811865476, kPinPlotRate);
  const NAMRig::PinCoeffs bell = NAMRig::pinCoefficients(NAMRig::kPinBell, 750.0, 9.0 * mid, 0.8, kPinPlotRate);

  for (int i = 0; i <= nPts; ++i) {
    const double frac = (double)i / (double)nPts;
    const double hz = 20.0 * std::pow(1000.0, frac);
    double totalDb = 0.0;
    if (tight > 0.0f) totalDb += NAMRig::pinMagnitudeDb(hp, hz, kPinPlotRate);
    if (bright > 0.0f) totalDb += NAMRig::pinMagnitudeDb(shelf, hz, kPinPlotRate);
    if (mid > 0.0f) totalDb += NAMRig::pinMagnitudeDb(bell, hz, kPinPlotRate);
    const NSPoint p = NSMakePoint(leftM + frac * pw, pinPlotY(plot, totalDb));
    if (i == 0) [curve moveToPoint:p];
    else [curve lineToPoint:p];
  }
  curve.lineWidth = 2.5;
  [[NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:0.95] setStroke];
  [curve stroke];
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
  [[NSColor colorWithSRGBRed:0.07 green:0.08 blue:0.10 alpha:1.0] setFill];
  [bg fill];
  [[NSColor colorWithSRGBRed:0.18 green:0.20 blue:0.25 alpha:0.75] setStroke];
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
    NSFontAttributeName: [NSFont systemFontOfSize:8.5 weight:NSFontWeightBold],
    NSForegroundColorAttributeName: curveColor,
    NSParagraphStyleAttributeName: textStyle
  };
  NSDictionary* statAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.0 weight:NSFontWeightMedium],
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
    NSFontAttributeName: [NSFont systemFontOfSize:7.0 weight:NSFontWeightRegular],
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
  [[NSColor colorWithSRGBRed:0.07 green:0.08 blue:0.10 alpha:1.0] setFill];
  [bg fill];
  [[NSColor colorWithSRGBRed:0.18 green:0.20 blue:0.25 alpha:0.75] setStroke];
  bg.lineWidth = 1.0;
  [bg stroke];

  const int idx = _profile;
  const auto& p = _parameters;

  NSDictionary* headerAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:8.5 weight:NSFontWeightBold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:0.95]
  };
  [@"CORE FLUX SATURATION & PASSBAND" drawAtPoint:NSMakePoint(14, r.size.height - 18) withAttributes:headerAttrs];

  NSString* stat = (idx == 0)
      ? @"BYPASS  •  CAPTURED RESPONSE"
      : [NSString stringWithFormat:@"FLUX: %.0fHz  •  DRV: %.1fx  •  SAT: %.0f%%",
         p.fluxHz, p.drive, p.saturationMix * 100.0];
  NSDictionary* statAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.0 weight:NSFontWeightMedium],
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
  const CGFloat eqW = eqRight - eqLeft;
  const CGFloat eqMidY = NSMidY(eqPlot);

  NSBezierPath* eqBase = [NSBezierPath bezierPath];
  [eqBase moveToPoint:NSMakePoint(eqLeft, eqMidY)];
  [eqBase lineToPoint:NSMakePoint(eqRight, eqMidY)];
  eqBase.lineWidth = 0.75;
  CGFloat dashPat[2] = {2.0, 3.0};
  [eqBase setLineDash:dashPat count:2 phase:0.0];
  [[NSColor colorWithSRGBRed:0.22 green:0.25 blue:0.32 alpha:0.6] setStroke];
  [eqBase stroke];

  NSBezierPath* eqCurve = [NSBezierPath bezierPath];
  const int eqPts = 128;
  const double rate = 48000.0;
  const double band = rate * 0.42;
  const double pi = 3.14159265358979323846;
  enum class Filter { HighPass, LowPass, Peak };
  const auto rbj = [&](Filter type, double cutoff, double gainDb, double q) {
    const double w = 2.0 * pi * cutoff / rate;
    const double c = std::cos(w), alpha = std::sin(w) / (2.0 * q);
    const double A = std::pow(10.0, gainDb / 40.0);
    if (type == Filter::HighPass)
      return std::array<double, 6>{(1.0 + c) * 0.5, -(1.0 + c), (1.0 + c) * 0.5,
                                 1.0 + alpha, -2.0 * c, 1.0 - alpha};
    if (type == Filter::LowPass)
      return std::array<double, 6>{(1.0 - c) * 0.5, 1.0 - c, (1.0 - c) * 0.5,
                                 1.0 + alpha, -2.0 * c, 1.0 - alpha};
    return std::array<double, 6>{1.0 + alpha * A, -2.0 * c, 1.0 - alpha * A,
                               1.0 + alpha / A, -2.0 * c, 1.0 - alpha / A};
  };
  const auto highPass = rbj(Filter::HighPass, p.lowCutHz, 0.0, 0.7071067811865476);
  const auto voice = rbj(Filter::Peak, std::min(p.voiceHz, band), p.voiceDb, p.voiceQ);
  const auto leakage = rbj(Filter::Peak, std::min(p.leakageHz, band * 0.9), p.leakageDb, p.leakageQ);
  const auto highCut = rbj(Filter::LowPass, std::min(p.highCutHz, band), 0.0, 0.7071067811865476);
  const auto magnitudeDb = [&](const std::array<double, 6>& f, double hz) {
    const double w = 2.0 * pi * hz / rate;
    const double c = std::cos(w), s = std::sin(w);
    const double c2 = std::cos(2.0 * w), s2 = std::sin(2.0 * w);
    const double numerator = std::hypot(f[0] + f[1] * c + f[2] * c2, f[1] * s + f[2] * s2);
    const double denominator = std::hypot(f[3] + f[4] * c + f[5] * c2, f[4] * s + f[5] * s2);
    return 20.0 * std::log10(std::max(1.0e-12, numerator / denominator));
  };
  // Map log frequency 20 Hz .. 20 kHz across [0..1]
  const float logMin = std::log10(20.0f);
  const float logMax = std::log10(20000.0f);
  for (int i = 0; i <= eqPts; ++i) {
    float frac = (float)i / (float)eqPts;
    float hz = std::pow(10.0f, logMin + frac * (logMax - logMin));
    double db = 0.0;
    if (idx != 0) {
      db = magnitudeDb(highPass, hz) + magnitudeDb(voice, hz)
         + magnitudeDb(leakage, hz) + magnitudeDb(highCut, hz)
         + 20.0 * std::log10(p.makeup);
    }
    CGFloat px = eqLeft + frac * eqW;
    CGFloat py = pinPlotY(eqPlot, db);
    if (i == 0) [eqCurve moveToPoint:NSMakePoint(px, py)];
    else [eqCurve lineToPoint:NSMakePoint(px, py)];
  }

  NSBezierPath* eqFill = [eqCurve copy];
  [eqFill lineToPoint:NSMakePoint(eqRight, botM)];
  [eqFill lineToPoint:NSMakePoint(eqLeft, botM)];
  [eqFill closePath];

  NSGradient* fg = [[NSGradient alloc]
      initWithStartingColor:[NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:(idx == 0 ? 0.12 : 0.30)]
                endingColor:[NSColor colorWithSRGBRed:0.25 green:0.15 blue:0.04 alpha:0.02]];
  [fg drawInBezierPath:eqFill angle:270.0];

  eqCurve.lineWidth = 2.0;
  [[NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:(idx == 0 ? 0.45 : 0.95)] setStroke];
  [eqCurve stroke];
}
@end

@implementation NAMSpeakerDynamicsVisualizer
- (BOOL)isFlipped { return NO; }
- (void)setDrive:(float)v { _drive = v; self.needsDisplay = YES; }
- (void)setComp:(float)v { _comp = v; self.needsDisplay = YES; }
- (void)setThump:(float)v { _thump = v; self.needsDisplay = YES; }
- (void)setResonance:(float)v { _resonance = v; self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirty {
  NSRect r = self.bounds;
  if (r.size.width < 10 || r.size.height < 10) return;

  NSBezierPath* bg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:6.0 yRadius:6.0];
  [[NSColor colorWithSRGBRed:0.07 green:0.08 blue:0.10 alpha:1.0] setFill];
  [bg fill];
  [[NSColor colorWithSRGBRed:0.18 green:0.20 blue:0.25 alpha:0.75] setStroke];
  bg.lineWidth = 1.0;
  [bg stroke];

  NSDictionary* headerAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:8.5 weight:NSFontWeightBold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.95]
  };
  [@"SPEAKER IMPEDANCE & CONE EXCURSION" drawAtPoint:NSMakePoint(14, r.size.height - 18) withAttributes:headerAttrs];

  NSString* stat = [NSString stringWithFormat:@"DRV: %.0f%%  •  COMP: %.0f%%  •  THUMP: %.0f%%", _drive, _comp, _thump];
  NSDictionary* statAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.0 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.9]
  };
  NSSize ssz = [stat sizeWithAttributes:statAttrs];
  [stat drawAtPoint:NSMakePoint(r.size.width - 14 - ssz.width, r.size.height - 18) withAttributes:statAttrs];

  const CGFloat leftM = 24.0, rightM = 16.0, topM = 24.0, botM = 16.0;
  const CGFloat pw = r.size.width - leftM - rightM;
  const CGFloat ph = r.size.height - topM - botM;
  const CGFloat base = botM + 6.0;

  NSBezierPath* zCurve = [NSBezierPath bezierPath];
  const int nPts = 60;
  float resPeak = 0.35f + 0.55f * (_resonance / 100.0f);
  float thumpScale = 1.0f + 0.40f * (_thump / 100.0f);

  for (int i = 0; i <= nPts; ++i) {
    float frac = (float)i / (float)nPts;
    CGFloat px = leftM + frac * pw;
    float d = (frac - 0.20f) / 0.08f;
    float bell = std::exp(-0.5f * d * d) * resPeak * thumpScale;
    float indRise = (frac > 0.60f) ? 0.35f * ((frac - 0.60f) / 0.40f) : 0.0f;
    float zNorm = 0.15f + bell + indRise;

    CGFloat py = base + zNorm * (ph * 0.85);
    if (i == 0) [zCurve moveToPoint:NSMakePoint(px, py)];
    else [zCurve lineToPoint:NSMakePoint(px, py)];
  }

  NSBezierPath* zFill = [zCurve copy];
  [zFill lineToPoint:NSMakePoint(leftM + pw, base)];
  [zFill lineToPoint:NSMakePoint(leftM, base)];
  [zFill closePath];

  NSGradient* zg = [[NSGradient alloc]
      initWithStartingColor:[NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.35]
                endingColor:[NSColor colorWithSRGBRed:0.05 green:0.25 blue:0.20 alpha:0.02]];
  [zg drawInBezierPath:zFill angle:270.0];

  zCurve.lineWidth = 2.0;
  [[NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.95] setStroke];
  [zCurve stroke];
}
@end

@implementation NAMCabConsoleVisualizer
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _pinEditor = [[NAMPinEQEditor alloc] initWithPane:NAMRig::PinEqPane::CabConsole
        accent:[NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:1.0]];
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
  [[NSColor colorWithSRGBRed:0.07 green:0.08 blue:0.10 alpha:1.0] setFill];
  [bg fill];
  [[NSColor colorWithSRGBRed:0.18 green:0.20 blue:0.25 alpha:0.75] setStroke];
  bg.lineWidth = 1.0;
  [bg stroke];

  NSDictionary* headerAttrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:8.5 weight:NSFontWeightBold],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.95]
  };
  [@"CAB A / B ALIGNMENT & DUAL CUT FILTERS" drawAtPoint:NSMakePoint(14, r.size.height - 18) withAttributes:headerAttrs];

  NSString* stat = [NSString stringWithFormat:@"ALIGN: %+.2f ms  •  LOW: %.0f Hz  •  HI: %.0f Hz", _alignDelay, _lowCut, _highCut];
  NSDictionary* statAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.0 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.9]
  };
  NSSize ssz = [stat sizeWithAttributes:statAttrs];
  [stat drawAtPoint:NSMakePoint(r.size.width - 14 - ssz.width, r.size.height - 18) withAttributes:statAttrs];

  // The DSP's cut filters (2nd-order Butterworth) on the pin editor's axes:
  // log frequency 20 Hz..20 kHz, +/-18 dB.
  const NSRect plot = [self plotRect];
  const CGFloat leftM = NSMinX(plot), pw = plot.size.width, botM = NSMinY(plot);
  const bool lowOn = _lowCut >= 20.0f;
  const bool highOn = _highCut < 19990.0f;
  const NAMRig::PinCoeffs lowCut = NAMRig::pinPassCoefficients(true, _lowCut, kPinPlotRate);
  const NAMRig::PinCoeffs highCut = NAMRig::pinPassCoefficients(false, std::max(1000.0f, _highCut), kPinPlotRate);

  NSBezierPath* zero = [NSBezierPath bezierPath];
  [zero moveToPoint:NSMakePoint(leftM, NSMidY(plot))];
  [zero lineToPoint:NSMakePoint(leftM + pw, NSMidY(plot))];
  zero.lineWidth = 0.75;
  CGFloat dash[2] = {2.0, 3.0};
  [zero setLineDash:dash count:2 phase:0.0];
  [[NSColor colorWithSRGBRed:0.22 green:0.25 blue:0.32 alpha:0.6] setStroke];
  [zero stroke];

  NSBezierPath* fCurve = [NSBezierPath bezierPath];
  const int nPts = 120;
  for (int i = 0; i <= nPts; ++i) {
    const double frac = (double)i / (double)nPts;
    const double hz = 20.0 * std::pow(1000.0, frac);
    double db = 0.0;
    if (lowOn) db += NAMRig::pinMagnitudeDb(lowCut, hz, kPinPlotRate);
    if (highOn) db += NAMRig::pinMagnitudeDb(highCut, hz, kPinPlotRate);
    const NSPoint p = NSMakePoint(leftM + frac * pw, pinPlotY(plot, db));
    if (i == 0) [fCurve moveToPoint:p];
    else [fCurve lineToPoint:p];
  }

  NSBezierPath* fFill = [fCurve copy];
  [fFill lineToPoint:NSMakePoint(leftM + pw, botM)];
  [fFill lineToPoint:NSMakePoint(leftM, botM)];
  [fFill closePath];

  NSGradient* fg = [[NSGradient alloc]
      initWithStartingColor:[NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.35]
                endingColor:[NSColor colorWithSRGBRed:0.05 green:0.25 blue:0.20 alpha:0.02]];
  [fg drawInBezierPath:fFill angle:270.0];

  fCurve.lineWidth = 2.0;
  [[NSColor colorWithSRGBRed:0.25 green:0.88 blue:0.70 alpha:0.95] setStroke];
  [fCurve stroke];
}
@end
