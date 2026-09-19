#import "rig_widgets.h"
#import "rig_theme.h"
#import <ImageIO/ImageIO.h>

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
  [@"POWER TUBE TRANSFER & SAG COMPRESSION" drawAtPoint:NSMakePoint(14, r.size.height - 18) withAttributes:headerAttrs];

  NSString* stat = [NSString stringWithFormat:@"SAG: %.0f%%  •  BIAS: %+.0f%%  •  NFB: %.0f%%", _sag, _bias, _feedback];
  NSDictionary* statAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.0 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:0.9]
  };
  NSSize ssz = [stat sizeWithAttributes:statAttrs];
  [stat drawAtPoint:NSMakePoint(r.size.width - 14 - ssz.width, r.size.height - 18) withAttributes:statAttrs];

  const CGFloat cx = r.size.width * 0.46;
  const CGFloat cy = (r.size.height - 24) * 0.5 + 8;
  const CGFloat plotW = r.size.width * 0.72;
  const CGFloat plotH = r.size.height - 36;

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
- (BOOL)isFlipped { return NO; }
- (void)setBright:(float)v { _bright = v; self.needsDisplay = YES; }
- (void)setInputEq:(float)v { _inputEq = v; self.needsDisplay = YES; }

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
  [@"PRE-AMP TIGHTENER & BRIGHT SHELF" drawAtPoint:NSMakePoint(14, r.size.height - 18) withAttributes:headerAttrs];

  NSString* stat = [NSString stringWithFormat:@"BRIGHT: %+.1f dB  •  TIGHT: %.0f%%", _bright, _inputEq];
  NSDictionary* statAttrs = @{
    NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.0 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:0.9]
  };
  NSSize ssz = [stat sizeWithAttributes:statAttrs];
  [stat drawAtPoint:NSMakePoint(r.size.width - 14 - ssz.width, r.size.height - 18) withAttributes:statAttrs];

  const CGFloat leftM = 30.0, rightM = 16.0, topM = 24.0, botM = 16.0;
  const CGFloat pw = r.size.width - leftM - rightM;
  const CGFloat ph = r.size.height - topM - botM;
  const CGFloat midY = botM + ph * 0.5;

  NSBezierPath* baseLine = [NSBezierPath bezierPath];
  [baseLine moveToPoint:NSMakePoint(leftM, midY)];
  [baseLine lineToPoint:NSMakePoint(leftM + pw, midY)];
  baseLine.lineWidth = 0.75;
  CGFloat pat[2] = {2.0, 3.0};
  [baseLine setLineDash:pat count:2 phase:0.0];
  [[NSColor colorWithSRGBRed:0.22 green:0.25 blue:0.32 alpha:0.6] setStroke];
  [baseLine stroke];

  NSBezierPath* curve = [NSBezierPath bezierPath];
  const int nPts = 60;
  float tightNorm = _inputEq / 100.0f;
  float brightDb = _bright;

  for (int i = 0; i <= nPts; ++i) {
    float frac = (float)i / (float)nPts;
    CGFloat px = leftM + frac * pw;
    float lowCutDb = (frac < 0.35f) ? -12.0f * tightNorm * (1.0f - frac / 0.35f) : 0.0f;
    float highBoostDb = (frac > 0.60f) ? brightDb * ((frac - 0.60f) / 0.40f) : 0.0f;
    float totalDb = lowCutDb + highBoostDb;

    CGFloat py = midY + (totalDb / 15.0f) * (ph * 0.45);
    if (i == 0) [curve moveToPoint:NSMakePoint(px, py)];
    else [curve lineToPoint:NSMakePoint(px, py)];
  }
  curve.lineWidth = 2.5;
  [[NSColor colorWithSRGBRed:1.0 green:0.75 blue:0.25 alpha:0.95] setStroke];
  [curve stroke];
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

  const CGFloat leftM = 24.0, rightM = 16.0, topM = 24.0, botM = 16.0;
  const CGFloat pw = r.size.width - leftM - rightM;
  const CGFloat ph = r.size.height - topM - botM;

  float lowCutFrac = std::min(0.40f, std::max(0.0f, (_lowCut - 20.0f) / 480.0f * 0.35f));
  float hiCutFrac = std::min(1.0f, std::max(0.60f, 0.60f + (_highCut - 2000.0f) / 18000.0f * 0.40f));

  NSBezierPath* fCurve = [NSBezierPath bezierPath];
  const int nPts = 60;
  for (int i = 0; i <= nPts; ++i) {
    float frac = (float)i / (float)nPts;
    CGFloat px = leftM + frac * pw;
    float gain = 1.0f;
    if (frac < lowCutFrac) {
      float d = (lowCutFrac - frac) / 0.15f;
      gain *= std::max(0.02f, 1.0f - d * d);
    }
    if (frac > hiCutFrac) {
      float d = (frac - hiCutFrac) / 0.15f;
      gain *= std::max(0.02f, 1.0f - d * d);
    }
    CGFloat py = botM + gain * (ph * 0.85);
    if (i == 0) [fCurve moveToPoint:NSMakePoint(px, py)];
    else [fCurve lineToPoint:NSMakePoint(px, py)];
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
