// NAM Rig dark theme palette + shared knob-value formatting.
// Extracted verbatim from nam_rig_ui.mm (pure move, no behavior change).
#pragma once

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>

// ---- NAM Rig-style theme (dark, near-black + blue accent) ----
NSColor* rigBG(void);
NSColor* rigPanelBG(void);
NSColor* rigPanelBorder(void);
NSColor* rigRaised(void);
NSColor* rigText(void);
NSColor* rigDimText(void);
NSColor* rigAccent(void);
NSColor* rigAccentDim(void);
NSColor* rigOrange(void);

// Knob value formatting (dB / OFF) — port numbers match the LV2 port list.
NSString* rigKnobValueText(uint32_t port, float value);
#endif
