// Tone3000 API constants + OAuth/Keychain/session/PKCE helpers.
// Extracted verbatim from nam_rig_ui.mm (pure move, no behavior change);
// definitions were file-static and are now external so the browser TU sees them.
#pragma once

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

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

// SearchCache helpers (shared between Tone Browser and AI Tone Copilot)
NSString* searchCacheDir(void);
NSString* searchCacheKeyForPath(NSString* path);
NSDictionary* _Nullable cachedSearchPageForPath(NSString* path, NSTimeInterval maxAgeSeconds);
void saveSearchPageForPath(NSString* path, NSDictionary* page);

@interface Tone3000FetchResult : NSObject
@property(nonatomic) BOOL success;
@property(nonatomic, copy, nullable) NSString* relativePath; // e.g. "Amp/Artist - Tone/Model.nam"
@property(nonatomic, copy, nullable) NSString* toneTitle;
@property(nonatomic, copy, nullable) NSString* modelName;
@property(nonatomic, copy, nullable) NSString* architecture; // "2", "1", "custom"
@property(nonatomic) NSInteger downloadsCount;
@property(nonatomic, copy, nullable) NSString* statusMessage;
@property(nonatomic, strong, nullable) NSError* error;
@end

// Searches Tone3000 online for query and downloads the top matching model for the specified stage
// (0=pedal, 1=amp/full-rig, 2=cab). Prioritizes A2 architecture, high download counts, and exact tag/title matches.
// Synchronous (designed to run on background worker threads).
Tone3000FetchResult* tone3000FetchBestProfile(NSString* query, NSInteger stage, NSString* _Nullable libraryRoot);

NS_ASSUME_NONNULL_END
#endif
