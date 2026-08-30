#import "rig_widgets.h"
#import "rig_theme.h"
#import <ImageIO/ImageIO.h>

#include <cmath>

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

- (void)drawRect:(NSRect)dirty {
  const NSRect b = self.bounds;
  const CGFloat side = MIN(NSWidth(b), NSHeight(b));
  const NSPoint c = NSMakePoint(NSMidX(b), NSMidY(b));
  const double range = self.maxValue - self.minValue;
  double t = range > 0.0 ? (self.doubleValue - self.minValue) / range : 0.0;
  t = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
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
    [[rigAccent() colorWithAlphaComponent:0.22] setStroke];
    [arc stroke];
    arc.lineWidth = 3.0;
    [rigAccent() setStroke];
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
  [(_hovered ? [rigAccent() colorWithAlphaComponent:0.45]
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
