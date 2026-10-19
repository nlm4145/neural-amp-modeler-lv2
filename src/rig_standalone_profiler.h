#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface RigStandaloneProfiler : NSObject

// Run the offline DSP performance profiler on the active preset and display results.
+ (void)profileActivePresetWithParentWindow:(nullable NSWindow*)parentWindow;

// Run the offline DSP performance profiler on all presets and display a comparative summary.
+ (void)profileAllPresetsWithParentWindow:(nullable NSWindow*)parentWindow;

@end

NS_ASSUME_NONNULL_END
