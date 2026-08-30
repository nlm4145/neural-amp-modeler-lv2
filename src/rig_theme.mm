#import "rig_theme.h"

// ---- NAM Rig-style theme (deep blue-black + electric blue accent) ----
NSColor* rigBG(void)        { return [NSColor colorWithSRGBRed:0.047 green:0.051 blue:0.066 alpha:1.0]; }
NSColor* rigPanelBG(void)   { return [NSColor colorWithSRGBRed:0.094 green:0.102 blue:0.129 alpha:1.0]; }
NSColor* rigPanelTop(void)  { return [NSColor colorWithSRGBRed:0.114 green:0.124 blue:0.157 alpha:1.0]; }
NSColor* rigPanelBottom(void){ return [NSColor colorWithSRGBRed:0.078 green:0.084 blue:0.108 alpha:1.0]; }
NSColor* rigPanelBorder(void){ return [NSColor colorWithSRGBRed:1.0 green:1.0 blue:1.0 alpha:0.10]; }
NSColor* rigRaised(void)    { return [NSColor colorWithSRGBRed:0.145 green:0.157 blue:0.196 alpha:1.0]; }
NSColor* rigText(void)      { return [NSColor colorWithSRGBRed:0.94 green:0.95 blue:0.97 alpha:1.0]; }
NSColor* rigDimText(void)   { return [NSColor colorWithSRGBRed:0.60 green:0.63 blue:0.69 alpha:1.0]; }
NSColor* rigAccent(void)    { return [NSColor colorWithSRGBRed:0.30 green:0.62 blue:1.00 alpha:1.0]; } // NAM Rig blue
NSColor* rigAccentDim(void) { return [NSColor colorWithSRGBRed:0.17 green:0.36 blue:0.60 alpha:1.0]; }
NSColor* rigOrange(void)    { return [NSColor colorWithSRGBRed:1.00 green:0.55 blue:0.25 alpha:1.0]; } // Tone3000 brand
NSColor* rigGreen(void)     { return [NSColor colorWithSRGBRed:0.35 green:0.84 blue:0.50 alpha:1.0]; }

NSString* rigKnobValueText(uint32_t port, float value) {
  switch (port) {
    case 4:  return [NSString stringWithFormat:@"%+.1f dB", value];
    case 5:  return [NSString stringWithFormat:@"%+.1f dB", value];
    case 12: return [NSString stringWithFormat:@"%+.1f dB", value];
    case 13: return [NSString stringWithFormat:@"%+.1f dB", value];
    case 14: return [NSString stringWithFormat:@"%+.1f dB", value];
    case 15: return value < -79.5f ? @"OFF" : [NSString stringWithFormat:@"%.0f dB", value];
    case 22: return [NSString stringWithFormat:@"%+.1f dB", value];
    case 23: return [NSString stringWithFormat:@"%.0f ms", value];
    case 25: return [NSString stringWithFormat:@"%+.1f dB", value];
    case 26: return value < 1.0f ? @"OFF" : [NSString stringWithFormat:@"%.0f Hz", value];
    case 27: return value > 19990.0f ? @"OFF" : [NSString stringWithFormat:@"%.0f Hz", value];
    case 28: return value < 0.5f ? @"OFF" : [NSString stringWithFormat:@"%.0f%%", value];
    default: return @"";
  }
}
