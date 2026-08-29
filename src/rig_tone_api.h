// Tone3000 API constants + OAuth/Keychain/session/PKCE helpers.
// Extracted verbatim from nam_rig_ui.mm (pure move, no behavior change);
// definitions were file-static and are now external so the browser TU sees them.
#pragma once

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>

extern NSString* const kToneAPI;
extern NSString* const kPluginPublishableKey;

NSDictionary* jsonDictionaryAtPath(NSString* path);
NSDictionary* namRigSession(void);
NSDictionary* pluginSession(void);
void savePluginSession(NSDictionary* session);
void clearPluginSession(void);
NSData* randomDataOfLength(size_t len);
NSString* base64URLStringNoPadding(NSData* data);
NSString* percentEncode(NSString* s);
NSData* sha256Data(NSString* s);
NSTimeInterval jwtExpiryMilliseconds(NSString* token);
NSDictionary* parseQueryString(NSString* query);
NSString* safeFilename(NSString* name);
NSInteger stageForGear(NSString* gear);
BOOL gearMatchesFilter(NSString* itemGear, NSString* filterTitle);
#endif
