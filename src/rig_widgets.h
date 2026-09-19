// Shared custom controls for both NAM UIs (simple + rig): the arc knob, the
// gradient panel, the flat button, and image-decode helpers.
#pragma once

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, RigKnobColorStyle) {
  RigKnobColorStyleDefault = 0,   // Electric Cyan / Ice Blue
  RigKnobColorStyleWarm = 1,      // Fire Amber / Sunset Orange (Gain, Drive, Master)
  RigKnobColorStyleSpatial = 2,   // Amethyst Violet / Orchid (Delay, Reverb, Room, Width)
  RigKnobColorStyleDynamics = 3   // Mint Emerald / Neon Green (Gate, Comp, Sag, Neg Fdbk)
};

// Modern arc knob. Keeps the full NSSlider contract (value/min/max/tag/
// target/action) so existing wiring is untouched. Interaction: vertical drag
// (Shift = fine), scroll wheel, double-click resets to defaultValue.
@interface RigKnob : NSSlider
@property(nonatomic) double defaultValue;
@property(nonatomic) RigKnobColorStyle colorStyle;
@end

RigKnobColorStyle rigKnobColorStyleForPort(uint32_t port);

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

// Studio Deck Hardware Visualizers
@interface NAMDelayTapVisualizer : NSView
@property(nonatomic) float timeMs;
@property(nonatomic) float feedback;
@property(nonatomic) float damping;
@property(nonatomic) float mix;
@end

@interface NAMReverbDecayVisualizer : NSView
@property(nonatomic) float mix;
@property(nonatomic) float decay;
@property(nonatomic) float size;
@property(nonatomic) float damping;
@property(nonatomic) float preDelay;
@end

@interface NAMSpatialAcousticVisualizer : NSView
@property(nonatomic) float width;
@property(nonatomic) float room;
@end

@interface NAMPowerStageVisualizer : NSView
@property(nonatomic) float sag;
@property(nonatomic) float bias;
@property(nonatomic) float feedback;
@property(nonatomic) float master;
@end

@interface NAMSculptVisualizer : NSView
@property(nonatomic) float bright;
@property(nonatomic) float inputEq;
@end

@interface NAMSpeakerDynamicsVisualizer : NSView
@property(nonatomic) float drive;
@property(nonatomic) float comp;
@property(nonatomic) float thump;
@property(nonatomic) float resonance;
@end

@interface NAMCabConsoleVisualizer : NSView
@property(nonatomic) float cabALevel;
@property(nonatomic) float cabBLevel;
@property(nonatomic) float alignDelay;
@property(nonatomic) float lowCut;
@property(nonatomic) float highCut;
@end

// ImageIO decode at the target pixel size instead of full resolution — grid
// scrolling stays cheap even when tones ship multi-megapixel artwork.
NSImage* rigThumbnailFromFile(NSString* path, CGFloat maxPixelSize);
NSImage* rigThumbnailFromData(NSData* data, CGFloat maxPixelSize);

// Letterspacing for the uppercase micro-labels (knob names, stage names).
void rigApplyTracking(NSTextField* label, CGFloat kern);
#endif
