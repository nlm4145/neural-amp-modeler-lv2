// Shared custom controls for both NAM UIs (simple + rig): the arc knob, the
// gradient panel, the flat button, and image-decode helpers.
#pragma once

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>

// Modern arc knob. Keeps the full NSSlider contract (value/min/max/tag/
// target/action) so existing wiring is untouched. Interaction: vertical drag
// (Shift = fine), scroll wheel, double-click resets to defaultValue.
@interface RigKnob : NSSlider
@property(nonatomic) double defaultValue;
@end

// Rounded panel with a vertical gradient fill and a hairline border.
// Replaces the old flat NSBox panels.
@interface RigPanel : NSView
@property(nonatomic) CGFloat cornerRadius;
@end

// A flat, dark-theme rounded button. "primary" renders with an accent fill;
// otherwise a dark fill + subtle border. "check" adds a status dot (used by
// the stage power toggles). Hover brightens the fill.
@interface RigButton : NSButton
@property(nonatomic) BOOL primary;
@property(nonatomic) BOOL check;
@end

// ImageIO decode at the target pixel size instead of full resolution — grid
// scrolling stays cheap even when tones ship multi-megapixel artwork.
NSImage* rigThumbnailFromFile(NSString* path, CGFloat maxPixelSize);
NSImage* rigThumbnailFromData(NSData* data, CGFloat maxPixelSize);

// Letterspacing for the uppercase micro-labels (knob names, stage names).
void rigApplyTracking(NSTextField* label, CGFloat kern);
#endif
