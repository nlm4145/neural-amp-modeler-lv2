// RigLocalServer — Embedded Local HTTP REST API for Axe FX.
// Enables external AI agents (Claude Code, Gemini/Antigravity, OpenAI/Codex)
// and local tools to query and control Axe FX in real time.
#pragma once

#import <Foundation/Foundation.h>

#ifdef __OBJC__

NS_ASSUME_NONNULL_BEGIN

@interface RigLocalServer : NSObject
+ (instancetype)sharedServer;

- (BOOL)startWithPort:(uint16_t)port;
- (void)stop;

@property(nonatomic, readonly) BOOL isRunning;
@property(nonatomic, readonly) uint16_t port;

@end

NS_ASSUME_NONNULL_END

#endif // __OBJC__
