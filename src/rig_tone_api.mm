#import <Cocoa/Cocoa.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

#include <cmath>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <vector>

#import "rig_tone_api.h"

NSDictionary* jsonDictionaryAtPath(NSString* path) {
  NSData* data = [NSData dataWithContentsOfFile:path];
  if (!data) return nil;
  id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

NSString* const kToneAPI = @"https://www.tone3000.com/api/v1";

// NAM Rig is the app that owns the TONE3000 OAuth session on this machine. The
// plugin shares NAM Rig's library and URL cache, so it reuses the same session
// instead of attempting its own (unsupported, non-standard) OAuth flow.
static NSString* const kNamRigKeychainService = @"Nouratone.comnouratonenamrig.Tone3000";
static NSString* const kNamRigAccountPrefix = @"apiv1tone3000.";
static NSString* const kNamRigAccountSuffix = @".refresh-token";
NSString* const kPluginPublishableKey = @"t3k_pub_ScsutPfmPM2CwvG726tU60R5WN_KChza";

// The plugin and standalone app share a single user-owned session file (0600)
// in Application Support so ad-hoc rebuilds and switching between Element and
// Axe FX standalone never trigger macOS Keychain password prompts.
static NSString* const kPluginKeychainService = @"Axe FX Tone3000";
static NSString* const kLegacyPluginKeychainService = @"NAM Oversampled Rig Tone3000";
static NSString* const kPluginKeychainAccount = @"session";

static NSString* pluginSessionFilePath(void) {
  NSString* dir = [@"~/Library/Application Support/Axe FX" stringByExpandingTildeInPath];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  return [dir stringByAppendingPathComponent:@"tone3000-session.json"];
}

// Reads NAM Rig's stored TONE3000 OAuth session (a JSON blob holding
// accessToken, refreshToken and expiresAtMilliseconds) from the Keychain
// silently (never showing a Keychain password prompt).
NSDictionary* namRigSession(void) {
  NSDictionary* query = @{
    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService: kNamRigKeychainService,
    (__bridge id)kSecUseAuthenticationUI: (__bridge id)kSecUseAuthenticationUISkip,
    (__bridge id)kSecReturnData: @YES,
    (__bridge id)kSecReturnAttributes: @YES,
  };
  CFTypeRef result = nullptr;
  if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess) return nil;
  NSDictionary* entry = (__bridge_transfer NSDictionary*)result;
  if (![entry isKindOfClass:NSDictionary.class]) return nil;
  NSString* account = entry[(__bridge id)kSecAttrAccount];
  if (![account hasPrefix:kNamRigAccountPrefix] || ![account hasSuffix:kNamRigAccountSuffix]) return nil;
  NSData* data = entry[(__bridge id)kSecValueData];
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

// Writes (or updates) the plugin's own TONE3000 session to the user-owned
// session file (0600) in ~/Library/Application Support/Axe FX/.
void savePluginSession(NSDictionary* session) {
  if (!session) return;
  NSData* json = [NSJSONSerialization dataWithJSONObject:session
                                                 options:NSJSONWritingPrettyPrinted
                                                   error:nil];
  if (!json) return;
  NSString* path = pluginSessionFilePath();
  if ([json writeToFile:path options:NSDataWritingAtomic error:nil]) {
    chmod(path.fileSystemRepresentation, S_IRUSR | S_IWUSR);
  }
}

// Reads the plugin's own stored TONE3000 session (same JSON shape as NAM
// Rig's: accessToken, refreshToken, expiresAtMilliseconds) from disk first,
// falling back silently (without UI prompts) to any legacy Keychain entry.
NSDictionary* pluginSession(void) {
  NSString* path = pluginSessionFilePath();
  NSDictionary* diskSession = jsonDictionaryAtPath(path);
  if ([diskSession isKindOfClass:NSDictionary.class] &&
      [diskSession[@"accessToken"] isKindOfClass:NSString.class]) {
    return diskSession;
  }
  for (NSString* service in @[kPluginKeychainService, kLegacyPluginKeychainService]) {
    NSDictionary* query = @{
      (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
      (__bridge id)kSecAttrService: service,
      (__bridge id)kSecAttrAccount: kPluginKeychainAccount,
      (__bridge id)kSecUseAuthenticationUI: (__bridge id)kSecUseAuthenticationUISkip,
      (__bridge id)kSecReturnData: @YES,
    };
    CFDataRef data = nullptr;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef*)&data) != errSecSuccess) continue;
    NSData* nsdata = (__bridge_transfer NSData*)data;
    id json = [NSJSONSerialization JSONObjectWithData:nsdata options:0 error:nil];
    if ([json isKindOfClass:NSDictionary.class]) {
      savePluginSession(json);
      return json;
    }
  }
  return nil;
}

// Deletes the plugin's own TONE3000 session. Used when the stored refresh
// token has been rotated server-side ("refresh_token_already_used"): keeping
// it poisons every request with a 401 and "REFRESH failed" forever.
void clearPluginSession(void) {
  [[NSFileManager defaultManager] removeItemAtPath:pluginSessionFilePath() error:nil];
  for (NSString* service in @[kPluginKeychainService, kLegacyPluginKeychainService]) {
    NSDictionary* query = @{
      (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
      (__bridge id)kSecAttrService: service,
      (__bridge id)kSecAttrAccount: kPluginKeychainAccount,
      (__bridge id)kSecUseAuthenticationUI: (__bridge id)kSecUseAuthenticationUISkip,
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
  }
}

// ---- TONE3000 OAuth2 authorization-code + PKCE helpers ----
// The plugin logs in directly against the same OAuth endpoints NAM Rig uses
// (www.tone3000.com/api/v1/oauth/authorize + /oauth/token). This makes the
// explorer self-sufficient: Connect opens the browser once and the plugin then
// owns a session it can refresh forever, instead of depending on NAM Rig or a
// stale keychain copy.

NSData* randomDataOfLength(size_t len) {
  NSMutableData* d = [NSMutableData dataWithLength:len];
  (void)SecRandomCopyBytes(kSecRandomDefault, len, d.mutableBytes);
  return d;
}

// RFC 4648 base64url WITHOUT padding. Used for the PKCE code_verifier
// (43 chars from 32 random bytes), the S256 challenge and the state value.
NSString* base64URLStringNoPadding(NSData* data) {
  NSString* b64 = [data base64EncodedStringWithOptions:0];
  b64 = [b64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
  b64 = [b64 stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
  b64 = [b64 stringByReplacingOccurrencesOfString:@"=" withString:@""];
  return b64;
}

// RFC 3986 unreserved-only percent-encoding, safe for form bodies and query
// values (URLQueryAllowedCharacterSet would let & and + through).
NSString* percentEncode(NSString* s) {
  static NSCharacterSet* allowed = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableCharacterSet* set = [NSMutableCharacterSet alphanumericCharacterSet];
    [set addCharactersInString:@"-._~"];
    allowed = set;
  });
  return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

NSData* sha256Data(NSString* s) {
  NSData* data = [s dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  return [NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH];
}

// JWT "exp" claim in milliseconds, or 0 if the token isn't a parseable JWT.
NSTimeInterval jwtExpiryMilliseconds(NSString* token) {
  if (![token isKindOfClass:NSString.class] || ![token hasPrefix:@"eyJ"]) return 0;
  NSArray* parts = [token componentsSeparatedByString:@"."];
  if (parts.count < 2) return 0;
  NSString* payload = [parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
  payload = [payload stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
  while (payload.length % 4) payload = [payload stringByAppendingString:@"="];
  NSData* data = [[NSData alloc] initWithBase64EncodedString:payload options:0];
  if (!data) return 0;
  NSDictionary* claims = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  NSNumber* exp = [claims isKindOfClass:NSDictionary.class] ? claims[@"exp"] : nil;
  if (![exp respondsToSelector:@selector(doubleValue)]) return 0;
  return exp.doubleValue * 1000.0;
}

// Minimal query-string parser for the OAuth callback (GET /callback?code=..&state=..).
NSDictionary* parseQueryString(NSString* query) {
  NSMutableDictionary* d = [NSMutableDictionary dictionary];
  for (NSString* pair in [query componentsSeparatedByString:@"&"]) {
    NSArray* kv = [pair componentsSeparatedByString:@"="];
    if (kv.count != 2) continue;
    NSString* k = [kv[0] stringByRemovingPercentEncoding];
    NSString* v = [kv[1] stringByRemovingPercentEncoding];
    if (k.length) d[k] = v ?: @"";
  }
  return d;
}

NSString* safeFilename(NSString* name) {
  NSCharacterSet* bad = [NSCharacterSet characterSetWithCharactersInString:@"/:\\?%*|\"<>\n\r"];
  NSArray* parts = [name componentsSeparatedByCharactersInSet:bad];
  NSString* result = [parts componentsJoinedByString:@"-"];
  return result.length ? [result substringToIndex:MIN((NSUInteger)120, result.length)] : @"Tone3000 Model";
}

NSInteger stageForGear(NSString* gear) {
  NSString* value = gear.lowercaseString;
  if ([value containsString:@"pedal"]) return 0;
  if ([value isEqualToString:@"cab"] || [value containsString:@"ir"]) return 2;
  return 1;
}

// Filter a tone by the gear dropdown using the API's own Gear enum values
// (amp / amp-cab / pedal / cab / outboard / space / experimental) — NOT the
// collapsed 3-stage value. stageForGear maps amp-cab to the amp tile for
// playback, but amp and amp-cab are DISTINCT site categories and must filter
// separately (they were being combined before).
BOOL gearMatchesFilter(NSString* itemGear, NSString* filterTitle) {
  NSString* g = itemGear.lowercaseString;
  if ([filterTitle isEqualToString:@"Amps"]) return [g isEqualToString:@"amp"];
  if ([filterTitle isEqualToString:@"Cabs"]) return [g isEqualToString:@"cab"];
  if ([filterTitle isEqualToString:@"Pedals"]) return [g isEqualToString:@"pedal"];
  if ([filterTitle isEqualToString:@"Amp + Cab"]) return [g isEqualToString:@"amp-cab"] || [g isEqualToString:@"full-rig"];
  return YES;   // All Gear
}
