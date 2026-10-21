#pragma once
#import "rig_riff_recorder.h"
#import "rig_presets.h"

// Standalone-only adapter, using the production engine without touching the live rig.
NS_ASSUME_NONNULL_BEGIN
NSData* _Nullable rigRenderDI(RigPreset* preset, NSData* di, double rate, NSError** error);
NS_ASSUME_NONNULL_END
