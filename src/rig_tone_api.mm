#import <Cocoa/Cocoa.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

#include <cmath>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <vector>

#import "rig_tone_api.h"
#import "rig_ai_support.h"

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

// ---- SearchCache helpers ----
NSString* searchCacheDir(void) {
  static NSString* dir = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dir = [@("~/Library/Application Support/Axe FX/SearchCache") stringByExpandingTildeInPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
  });
  return dir;
}

NSString* searchCacheKeyForPath(NSString* path) {
  unsigned char digest[CC_SHA1_DIGEST_LENGTH];
  CC_SHA1([path UTF8String], (CC_LONG)strlen([path UTF8String]), digest);
  NSMutableString* hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
  for (size_t i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
  return hex;
}

NSDictionary* cachedSearchPageForPath(NSString* path, NSTimeInterval maxAgeSeconds) {
  NSString* file = [searchCacheDir() stringByAppendingPathComponent:
                    [searchCacheKeyForPath(path) stringByAppendingPathExtension:@"json"]];
  NSDictionary* wrapper = jsonDictionaryAtPath(file);
  NSDictionary* page = [wrapper[@"page"] isKindOfClass:NSDictionary.class] ? wrapper[@"page"] : nil;
  NSNumber* fetched = [wrapper[@"fetchedAt"] respondsToSelector:@selector(doubleValue)]
      ? wrapper[@"fetchedAt"] : nil;
  if (!page || !fetched) return nil;
  if ([[NSDate date] timeIntervalSince1970] - fetched.doubleValue > maxAgeSeconds) return nil;
  return page;
}

void saveSearchPageForPath(NSString* path, NSDictionary* page) {
  if (![page isKindOfClass:NSDictionary.class] || !page[@"data"]) return;
  NSDictionary* wrapper = @{
    @"fetchedAt": @([[NSDate date] timeIntervalSince1970]),
    @"path": path,
    @"page": page,
  };
  NSData* json = [NSJSONSerialization dataWithJSONObject:wrapper options:0 error:nil];
  if (!json) return;
  NSString* file = [searchCacheDir() stringByAppendingPathComponent:
                    [searchCacheKeyForPath(path) stringByAppendingPathExtension:@"json"]];
  [json writeToFile:file options:NSDataWritingAtomic error:nil];
}

@implementation Tone3000FetchResult
@end

Tone3000FetchResult* tone3000FetchBestProfile(NSString* query, NSInteger stage, NSString* libraryRoot) {
  Tone3000FetchResult* result = [[Tone3000FetchResult alloc] init];
  if (!query.length) {
    result.statusMessage = @"Query is empty.";
    return result;
  }
  if (!libraryRoot.length) {
    libraryRoot = [@"~/Music/Tone3000 Library" stringByExpandingTildeInPath];
  }

  // Tokenize query for relevance scoring
  NSArray<NSString*>* rawTokens = [query.lowercaseString componentsSeparatedByCharactersInSet:
      [[NSCharacterSet alphanumericCharacterSet] invertedSet]];
  NSMutableArray<NSString*>* tokens = [NSMutableArray array];
  NSSet<NSString*>* stopWords = [NSSet setWithObjects:@"with", @"and", @"the", @"for", @"tone", @"sound",
                                                       @"preset", @"rhythm", @"lead", @"tight", @"clean",
                                                       @"gain", @"heavy", @"metal", @"rock", @"style",
                                                       @"amp", @"cab", @"pedal", nil];
  for (NSString* t in rawTokens) {
    if (t.length > 2 && ![stopWords containsObject:t]) [tokens addObject:t];
  }
  if (tokens.count == 0) {
    for (NSString* t in rawTokens) if (t.length > 2) [tokens addObject:t];
  }

  NSString* cleanQuery = [tokens componentsJoinedByString:@" "];
  if (!cleanQuery.length) cleanQuery = query;

  NSMutableArray<NSString*>* queryCandidates = [NSMutableArray array];
  if (cleanQuery.length) [queryCandidates addObject:cleanQuery];
  for (NSString* sq in rigAISuggestGearQueries(query)) {
    if (![queryCandidates containsObject:sq]) [queryCandidates addObject:sq];
  }

  NSDictionary* bestTone = nil;
  NSInteger bestScore = -1;
  NSString* lastError = nil;

  for (NSUInteger qIdx = 0; qIdx < queryCandidates.count && qIdx < 4; ++qIdx) {
    NSString* currentQuery = queryCandidates[qIdx];
    NSString* encQuery = percentEncode(currentQuery);
    NSString* searchPath = [NSString stringWithFormat:@"/tones/search?sort=downloads-all-time&page=1&page_size=15&query=%@", encQuery];

    NSDictionary* searchJson = cachedSearchPageForPath(searchPath, 600.0);
    if (!searchJson) {
      NSURL* searchUrl = [NSURL URLWithString:[kToneAPI stringByAppendingString:searchPath]];
      NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:searchUrl];
      req.timeoutInterval = 7.0;
      NSDictionary* session = pluginSession() ?: namRigSession();
      NSString* token = [session[@"accessToken"] isKindOfClass:NSString.class] ? session[@"accessToken"] : nil;
      if (token.length) {
        [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
      }

      dispatch_semaphore_t sem = dispatch_semaphore_create(0);
      __block NSData* respData = nil;
      __block NSInteger respCode = 0;
      NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:req
          completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        respData = data;
        respCode = [(NSHTTPURLResponse*)response statusCode];
        dispatch_semaphore_signal(sem);
      }];
      [task resume];
      if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC))) != 0) {
        [task cancel];
        lastError = @"Tone3000 search timed out.";
        continue;
      }
      if (respCode >= 200 && respCode < 300 && respData.length) {
        id parsed = [NSJSONSerialization JSONObjectWithData:respData options:0 error:nil];
        if ([parsed isKindOfClass:NSDictionary.class]) {
          searchJson = parsed;
          saveSearchPageForPath(searchPath, searchJson);
        }
      } else {
        lastError = [NSString stringWithFormat:@"Tone3000 search returned HTTP %ld.", (long)respCode];
        continue;
      }
    }

    NSArray* items = [searchJson[@"data"] isKindOfClass:NSArray.class] ? searchJson[@"data"] : @[];
    if (items.count == 0) continue;

    for (NSDictionary* tone in items) {
      if (![tone isKindOfClass:NSDictionary.class]) continue;
      NSString* gear = [tone[@"gear"] isKindOfClass:NSString.class] ? [tone[@"gear"] lowercaseString] : @"";
      NSInteger itemStage = stageForGear(gear);

      BOOL compatible = NO;
      if (stage == 1) { // Amp
        compatible = (itemStage == 1 || [gear isEqualToString:@"amp-cab"] || [gear isEqualToString:@"full-rig"]);
      } else if (stage == 2) { // Cab
        compatible = (itemStage == 2 || [gear isEqualToString:@"cab"]);
      } else if (stage == 0) { // Pedal
        compatible = (itemStage == 0 || [gear containsString:@"pedal"]);
      }
      if (!compatible) continue;

      NSInteger a2Count = [tone[@"a2_models_count"] integerValue];
      NSInteger customCount = [tone[@"custom_models_count"] integerValue];
      NSInteger a1Count = [tone[@"a1_models_count"] integerValue];
      NSInteger downloads = [tone[@"downloads_count"] integerValue];
      NSInteger favs = [tone[@"favorites_count"] integerValue];

      NSInteger score = 0;
      if (a2Count > 0) score += 2000;
      else if (customCount > 0) score += 600;
      else if (a1Count > 0) score += 150;

      score += std::min<NSInteger>(1200, downloads);
      score += favs * 10;

      NSString* title = [tone[@"title"] isKindOfClass:NSString.class] ? [tone[@"title"] lowercaseString] : @"";
      NSString* desc = [tone[@"description"] isKindOfClass:NSString.class] ? [tone[@"description"] lowercaseString] : @"";
      for (NSString* token in tokens) {
        if ([title containsString:token]) score += 400;
        if ([desc containsString:token]) score += 120;
      }

      if (score > bestScore) {
        bestScore = score;
        bestTone = tone;
      }
    }

    if (bestScore >= 2500) break;
  }

  if (!bestTone) {
    if (lastError.length && bestScore < 0) {
      result.statusMessage = lastError;
    } else {
      result.statusMessage = [NSString stringWithFormat:@"No matching %@ models found on Tone3000 for '%@'.",
          stage == 1 ? @"amp" : (stage == 2 ? @"cab" : @"pedal"), cleanQuery];
    }
    return result;
  }

  NSString* toneTitle = bestTone[@"title"] ?: @"Tone3000 Tone";
  NSInteger toneId = [bestTone[@"id"] integerValue];
  NSInteger downloads = [bestTone[@"downloads_count"] integerValue];
  result.toneTitle = toneTitle;
  result.downloadsCount = downloads;

  NSDictionary* session = pluginSession() ?: namRigSession();
  NSString* accessToken = [session[@"accessToken"] isKindOfClass:NSString.class] ? session[@"accessToken"] : nil;
  if (!accessToken.length) {
    result.statusMessage = [NSString stringWithFormat:
        @"Found Tone3000 match '%@' (A2, %ld downloads), but Tone3000 is not signed in. Connect in the TONE3000 tab to enable auto-downloads.",
        toneTitle, (long)downloads];
    return result;
  }

  NSString* archFilter = ([bestTone[@"a2_models_count"] integerValue] > 0) ? @"2" : @"all";
  NSString* modelsPath = [NSString stringWithFormat:@"/models?tone_id=%ld&page=1&page_size=25&architecture=%@",
      (long)toneId, archFilter];
  NSDictionary* modelsJson = cachedSearchPageForPath(modelsPath, 3600.0);
  if (!modelsJson) {
    NSURL* modelsUrl = [NSURL URLWithString:[kToneAPI stringByAppendingString:modelsPath]];
    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:modelsUrl];
    req.timeoutInterval = 7.0;
    [req setValue:[@"Bearer " stringByAppendingString:accessToken] forHTTPHeaderField:@"Authorization"];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData* respData = nil;
    __block NSInteger respCode = 0;
    NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
      respData = data;
      respCode = [(NSHTTPURLResponse*)response statusCode];
      dispatch_semaphore_signal(sem);
    }];
    [task resume];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC))) != 0) {
      [task cancel];
      result.statusMessage = [NSString stringWithFormat:@"Fetching models for '%@' timed out.", toneTitle];
      return result;
    }
    if (respCode >= 200 && respCode < 300 && respData.length) {
      id parsed = [NSJSONSerialization JSONObjectWithData:respData options:0 error:nil];
      if ([parsed isKindOfClass:NSDictionary.class]) {
        modelsJson = parsed;
        saveSearchPageForPath(modelsPath, modelsJson);
      }
    }
  }

  NSArray* models = [modelsJson[@"data"] isKindOfClass:NSArray.class] ? modelsJson[@"data"] : @[];
  if (models.count == 0) {
    result.statusMessage = [NSString stringWithFormat:@"No downloadable models available for '%@'.", toneTitle];
    return result;
  }

  NSDictionary* targetModel = nil;
  NSInteger bestModelScore = NSIntegerMin;
  NSString* lowerQuery = query.lowercaseString ?: @"";
  const BOOL wantsChainsawOrFuzz = [lowerQuery containsString:@"chainsaw"] || [lowerQuery containsString:@"hm2"] ||
                                   [lowerQuery containsString:@"hm-2"] || [lowerQuery containsString:@"fuzz"] ||
                                   [lowerQuery containsString:@"doom"] || [lowerQuery containsString:@"sludge"];
  for (NSDictionary* m in models) {
    if (![m isKindOfClass:NSDictionary.class]) continue;
    NSString* av = [m[@"architecture_version"] respondsToSelector:@selector(stringValue)]
        ? [m[@"architecture_version"] stringValue] : (m[@"architecture_version"] ?: @"");
    NSString* mName = [m[@"name"] isKindOfClass:NSString.class] ? [m[@"name"] lowercaseString] : @"";
    NSInteger mScore = 0;
    if ([av isEqualToString:@"2"]) mScore += 100;
    else if ([av isEqualToString:@"custom"]) mScore += 50;
    else if ([av isEqualToString:@"1"]) mScore += 20;
    for (NSString* t in tokens) {
      if (t.length > 2 && [mName containsString:t]) mScore += 15;
    }
    if (!wantsChainsawOrFuzz) {
      if ([mName containsString:@"chainsaw"] || [mName containsString:@"jugendstil"] ||
          [mName containsString:@"hm300"] || [mName containsString:@"hm-2"] ||
          [mName containsString:@"hm2"] || [mName containsString:@"fuzz"] ||
          [mName containsString:@"pickle"] || [mName containsString:@"swollen"] ||
          [mName containsString:@"wendigo"] || [mName containsString:@"altar"]) {
        mScore -= 80;
      }
      if ([mName containsString:@"noboost"] || [mName containsString:@"no boost"] ||
          [mName containsString:@"no-boost"] || [mName containsString:@"direct"]) {
        mScore += 20;
      } else if ([mName containsString:@"od808"] || [mName containsString:@"ts9"] ||
                 [mName containsString:@"sd-1"] || [mName containsString:@"sd1"]) {
        mScore += 12;
      }
      if ([mName containsString:@"higain"] || [mName containsString:@"hi-gain"] ||
          [mName containsString:@"high gain"] || [mName containsString:@"lead"]) {
        mScore += 10;
      }
    }
    if (mScore > bestModelScore) {
      bestModelScore = mScore;
      targetModel = m;
    }
  }
  if (!targetModel) targetModel = models.firstObject;

  NSString* modelUrl = [targetModel[@"model_url"] isKindOfClass:NSString.class] ? targetModel[@"model_url"] : nil;
  if (!modelUrl.length) {
    result.statusMessage = [NSString stringWithFormat:@"Model URL missing for '%@'.", toneTitle];
    return result;
  }

  NSString* modelName = [targetModel[@"name"] isKindOfClass:NSString.class] ? targetModel[@"name"] : toneTitle;
  NSString* ext = modelUrl.pathExtension.length ? modelUrl.pathExtension : (stage == 2 ? @"wav" : @"nam");
  NSString* cleanModelName = safeFilename(modelName);
  NSString* filename = [cleanModelName stringByAppendingPathExtension:ext];

  NSString* category = (stage == 0) ? @"Pedal" : (stage == 2 ? @"Cab" : @"Amp");
  NSString* gear = [bestTone[@"gear"] isKindOfClass:NSString.class] ? [bestTone[@"gear"] lowercaseString] : @"";
  if (stage == 1 && ([gear isEqualToString:@"amp-cab"] || [gear isEqualToString:@"full-rig"])) {
    category = @"Full Rig";
  }

  NSString* folder = [[[libraryRoot stringByAppendingPathComponent:category]
                       stringByAppendingPathComponent:safeFilename(toneTitle)] copy];
  NSFileManager* fm = [NSFileManager defaultManager];
  [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
  NSString* destPath = [folder stringByAppendingPathComponent:filename];

  if (![fm fileExistsAtPath:destPath]) {
    NSURL* fileUrl = [NSURL URLWithString:modelUrl];
    NSMutableURLRequest* dlReq = [NSMutableURLRequest requestWithURL:fileUrl];
    dlReq.timeoutInterval = 15.0;
    [dlReq setValue:[@"Bearer " stringByAppendingString:accessToken] forHTTPHeaderField:@"Authorization"];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData* fileData = nil;
    __block NSInteger dlCode = 0;
    NSURLSessionDataTask* dlTask = [[NSURLSession sharedSession] dataTaskWithRequest:dlReq
        completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
      fileData = data;
      dlCode = [(NSHTTPURLResponse*)response statusCode];
      dispatch_semaphore_signal(sem);
    }];
    [dlTask resume];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC))) != 0) {
      [dlTask cancel];
      result.statusMessage = [NSString stringWithFormat:@"Downloading model '%@' timed out.", modelName];
      return result;
    }
    if (!(dlCode >= 200 && dlCode < 300) || !fileData.length) {
      result.statusMessage = [NSString stringWithFormat:@"Downloading model '%@' failed (HTTP %ld).", modelName, (long)dlCode];
      return result;
    }
    [fileData writeToFile:destPath options:NSDataWritingAtomic error:nil];
  }

  NSString* manifestPath = [folder stringByAppendingPathComponent:@"_tone3000.json"];
  NSDictionary* oldManifest = jsonDictionaryAtPath(manifestPath);
  NSMutableArray* downloadsList = [NSMutableArray array];
  if ([oldManifest[@"downloads"] isKindOfClass:NSArray.class]) {
    [downloadsList addObjectsFromArray:oldManifest[@"downloads"]];
  }
  BOOL alreadyLogged = NO;
  for (NSDictionary* d in downloadsList) {
    if ([d[@"local_filename"] isEqual:filename]) { alreadyLogged = YES; break; }
  }
  if (!alreadyLogged) {
    [downloadsList addObject:@{
      @"model_id": targetModel[@"id"] ?: @0,
      @"original_model": targetModel,
      @"local_filename": filename,
      @"status": @"downloaded",
      @"downloaded_at": [[NSDate date] description]
    }];
  }
  NSDictionary* manifest = @{
    @"powered_by": @"Tone3000",
    @"tone": bestTone ?: @{},
    @"downloads": downloadsList
  };
  NSData* manifestData = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil];
  if (manifestData) [manifestData writeToFile:manifestPath options:NSDataWritingAtomic error:nil];

  result.success = YES;
  result.relativePath = [NSString stringWithFormat:@"%@/%@/%@", category, safeFilename(toneTitle), filename];
  result.modelName = modelName;
  result.architecture = [targetModel[@"architecture_version"] respondsToSelector:@selector(stringValue)]
      ? [targetModel[@"architecture_version"] stringValue] : @"2";
  result.statusMessage = [NSString stringWithFormat:@"Downloaded '%@' (%@) from Tone3000.", toneTitle, filename];
  return result;
}
