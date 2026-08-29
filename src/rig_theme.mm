#import "rig_theme.h"

// ---- NAM Rig-style theme (dark, near-black + blue accent) ----
NSColor* rigBG(void)        { return [NSColor colorWithSRGBRed:0.055 green:0.059 blue:0.071 alpha:1.0]; }
NSColor* rigPanelBG(void)   { return [NSColor colorWithSRGBRed:0.098 green:0.106 blue:0.129 alpha:1.0]; }
NSColor* rigPanelBorder(void){ return [NSColor colorWithSRGBRed:0.18 green:0.19 blue:0.22 alpha:1.0]; }
NSColor* rigRaised(void)    { return [NSColor colorWithSRGBRed:0.14 green:0.15 blue:0.18 alpha:1.0]; }
NSColor* rigText(void)      { return [NSColor colorWithSRGBRed:0.93 green:0.94 blue:0.96 alpha:1.0]; }
NSColor* rigDimText(void)   { return [NSColor colorWithSRGBRed:0.58 green:0.60 blue:0.65 alpha:1.0]; }
NSColor* rigAccent(void)    { return [NSColor colorWithSRGBRed:0.24 green:0.55 blue:0.86 alpha:1.0]; } // NAM Rig blue
NSColor* rigAccentDim(void) { return [NSColor colorWithSRGBRed:0.14 green:0.31 blue:0.50 alpha:1.0]; }
NSColor* rigOrange(void)    { return [NSColor colorWithSRGBRed:1.00 green:0.55 blue:0.25 alpha:1.0]; } // Tone3000 brand

NSString* rigKnobValueText(uint32_t port, float value) {
  switch (port) {
    case 4:  return [NSString stringWithFormat:@"%+.1f dB", value];
    case 5:  return [NSString stringWithFormat:@"%+.1f dB", value];
    case 12: return [NSString stringWithFormat:@"%+.1f dB", value];
    case 13: return [NSString stringWithFormat:@"%+.1f dB", value];
    case 14: return [NSString stringWithFormat:@"%+.1f dB", value];
    case 15: return value < -79.5f ? @"OFF" : [NSString stringWithFormat:@"%.0f dB", value];
    default: return @"";
  }
}
