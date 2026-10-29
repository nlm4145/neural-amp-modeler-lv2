#pragma once
#import <Cocoa/Cocoa.h>
struct RigUIState;
@protocol NAMRigTunerDisplay <NSObject>
- (void)updateLegacyNote:(float)note cents:(float)cents;
- (void)acceptTunerMetric:(NSUInteger)metric value:(float)value;
- (void)setTunerActive:(BOOL)active;
- (void)shutdown;
@end
@interface NAMRigTunerWorkspace : NSView <NAMRigTunerDisplay, NSTextFieldDelegate>
- (instancetype)initWithState:(RigUIState*)state;
- (void)pushPitch:(double)pitch confidence:(double)confidence level:(double)db atTime:(double)time;
@end
NSView* rigCreateTunerWorkspace(RigUIState* state);
