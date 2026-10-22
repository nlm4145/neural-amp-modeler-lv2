// Shared custom controls for both NAM UIs (simple + rig): the arc knob, the
// gradient panel, the flat button, and image-decode helpers.
#pragma once

#include "output_transformer.h"
#include "pin_eq.h"

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
@property(nonatomic) BOOL showsSelection;
@property(nonatomic, strong) NSColor* selectionBorderColor;
@property(nonatomic, copy) void (^onClick)(void);
@property(nonatomic, copy) void (^onClickWithEvent)(NSEvent* event, RigPanel* panel);
@end

// Dropdown popup button with optional selection highlight border and click callback.
@interface RigPopUpButton : NSPopUpButton
@property(nonatomic) BOOL showsSelection;
@property(nonatomic, strong) NSColor* selectionBorderColor;
@property(nonatomic, copy) void (^onClick)(void);
@end

// A flat, dark-theme rounded button. "primary" renders with an accent fill;
// otherwise a dark fill + subtle border. "check" adds a status dot (used by
// the stage power toggles). Hover brightens the fill.
@interface RigButton : NSButton
@property(nonatomic) BOOL primary;
@property(nonatomic) BOOL check;
@property(nonatomic, strong) NSColor* customTextColor;
@end

// Text field that supports standard editing shortcuts (Cmd+A for select all,
// Cmd+C, Cmd+V, Cmd+X, Cmd+Z) even in contexts without an active Edit menu.
@interface RigAlertTextField : NSTextField
@end

// Freeform pin EQ drawn over a graph's frequency plot (log 20 Hz..20 kHz,
// +/-18 dB). The frame is the plot rect outset by kPinEditorInset so edge pins
// are not clipped. Double-click adds or removes a pin, drag moves it, the
// scroll wheel sets its width (Q), right-click picks bell/shelf.
static constexpr CGFloat kPinEditorInset = 6.0;
@interface NAMPinEQEditor : NSView
- (instancetype)initWithPane:(NAMRig::PinEqPane)pane accent:(NSColor*)accent;
@property(nonatomic, readonly) NAMRig::PinEqPane pane;
// Fired for every value the editor changes (drag, scroll, menus).
@property(nonatomic, copy) void (^onChange)(uint32_t port, float value);
// Fired once a gesture finishes, for preset "modified" tracking.
@property(nonatomic, copy) void (^onCommit)(void);
- (void)setPortValue:(float)value forPort:(uint32_t)port;
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

@interface NAMCompressorVisualizer : NSView
@property(nonatomic) BOOL compact;
@property(nonatomic) float amount;
@property(nonatomic) float attack;
@property(nonatomic) float releaseTime;
@property(nonatomic) BOOL enabled;
@end

@interface NAMPowerStageVisualizer : NSView
@property(nonatomic) float sag;
@property(nonatomic) float bias;
@property(nonatomic) float feedback;
@property(nonatomic) float master;
@end

@interface NAMSculptVisualizer : NSView
@property(nonatomic, readonly) NAMPinEQEditor* pinEditor;
@property(nonatomic) float bright;
@property(nonatomic) float inputEq;
@property(nonatomic) float midPush;
@property(nonatomic) float odDrive;
@property(nonatomic) float odTone;
@property(nonatomic) float odLevel;
@property(nonatomic) BOOL enabled;
@end

@interface NAMBoostVisualizer : NSView
@property(nonatomic) float drive;
@property(nonatomic) float tight;
@property(nonatomic) float tone;
@property(nonatomic) float level;
@property(nonatomic) int voicing;
@property(nonatomic) BOOL enabled;
@end

@interface NAMPowerTubeVisualizer : NSView
@property(nonatomic) int profile;
@property(nonatomic) float character;
@property(nonatomic) BOOL enabled;
@end

@interface NAMTransformerVisualizer : NSView
@property(nonatomic, readonly) NAMPinEQEditor* pinEditor;
@property(nonatomic) int profile;
@property(nonatomic) NAMRig::OutputTransformer::Parameters parameters;
@end

@interface NAMSpeakerDynamicsVisualizer : NSView
@property(nonatomic, readonly) NAMPinEQEditor* pinEditor;
// Resolved SpeakerDynamics profile (Auto already mapped) and power-amp
// damping 0..1 (negative feedback while the Power rack is on).
@property(nonatomic) int profile;
@property(nonatomic) float damping;
@property(nonatomic) float drive;
@property(nonatomic) float comp;
@property(nonatomic) float thump;
@property(nonatomic) float resonance;
@end

@interface NAMCabConsoleVisualizer : NSView
@property(nonatomic, readonly) NAMPinEQEditor* pinEditor;
@property(nonatomic) float cabALevel;
@property(nonatomic) float cabBLevel;
@property(nonatomic) float alignDelay;
@property(nonatomic) float lowCut;
@property(nonatomic) float highCut;
@end

// Vertical inter-stage decibel meter (IN, PRE, POST, OUT).
// Features hardware-style scale markings (-60..0 dBFS), clip LED,
// peak-hold bar, dynamic level-responsive fill, and digital numeric dB readout.
@interface RigStageMeterView : NSView
- (instancetype)initWithTitle:(NSString*)title
                     subtitle:(NSString*)subtitle
                  accentColor:(NSColor*)accentColor;
- (void)setLevelDb:(float)db;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* subtitle;
@property(nonatomic, strong) NSColor* accentColor;
@property(nonatomic, readonly) float levelDb;
@property(nonatomic, readonly) float peakDb;
@property(nonatomic, readonly) BOOL clipping;
@end

// ImageIO decode at the target pixel size instead of full resolution — grid
// scrolling stays cheap even when tones ship multi-megapixel artwork.
NSImage* rigThumbnailFromFile(NSString* path, CGFloat maxPixelSize);
NSImage* rigThumbnailFromData(NSData* data, CGFloat maxPixelSize);

// Letterspacing for the uppercase micro-labels (knob names, stage names).
void rigApplyTracking(NSTextField* label, CGFloat kern);
#endif
