#import "rig_ai_model_catalog.h"
#import <CommonCrypto/CommonDigest.h>

static NSError* modelCatalogError(NSInteger code, NSString* message) {
  return [NSError errorWithDomain:@"RigAIModelCatalog" code:code
                        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSURL* publicModelCatalogURL(NSString* provider) {
  NSDictionary* urls = @{
    @"openai": @"https://developers.openai.com/api/docs/models.md",
    @"claude": @"https://platform.claude.com/docs/en/models/overview.md",
    @"gemini": @"https://ai.google.dev/gemini-api/docs/models"
  };
  return urls[provider] ? [NSURL URLWithString:urls[provider]] : nil;
}

static NSArray* publicModelCatalogItems(NSData* data, NSString* provider) {
  NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (!text.length) return nil;
  // Official documentation exposes exact API IDs in model links / comparison tables.
  // Do not infer model IDs from display names, and never scrape CLI credentials.
  NSString* pattern = [provider isEqual:@"openai"] ? @"/api/docs/models/([a-z0-9.-]+)\\.md" :
      ([provider isEqual:@"claude"] ? @"`(claude-[a-z0-9.-]+)`" : @"/gemini-api/docs/models/(gemini-[a-z0-9.-]+)");
  NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
  NSMutableArray* items = [NSMutableArray array];
  for (NSTextCheckingResult* match in [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
    NSString* model = [text substringWithRange:[match rangeAtIndex:1]];
    [items addObject:@{@"id": model, @"supportedGenerationMethods": @[@"generateContent"]}];
  }
  return items;
}

static NSURL* modelCatalogURL(NSString* provider, NSString* baseURL) {
  NSURLComponents* url = [NSURLComponents componentsWithString:baseURL];
  BOOL loopback = [@[@"localhost", @"127.0.0.1", @"::1"] containsObject:url.host.lowercaseString];
  if (!url.host.length || url.user.length || url.password.length || url.query.length || url.fragment.length ||
      !([url.scheme.lowercaseString isEqual:@"https"] || ([url.scheme.lowercaseString isEqual:@"http"] && loopback))) return nil;
  NSString* path = url.path;
  while ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
  for (NSString* suffix in @[@"/chat/completions", @"/messages", @"/models", @"/api/tags"]) {
    if ([path hasSuffix:suffix]) { path = [path substringToIndex:path.length - suffix.length]; break; }
  }
  if ([provider isEqual:@"gemini"] && [path hasSuffix:@"/openai"])
    path = [path substringToIndex:path.length - 7];
  if ([provider isEqual:@"ollama"]) {
    for (NSString* suffix in @[@"/v1", @"/api"])
      if ([path hasSuffix:suffix]) { path = [path substringToIndex:path.length - suffix.length]; break; }
    url.path = [path stringByAppendingString:@"/api/tags"];
  } else {
    url.path = [path stringByAppendingString:@"/models"];
    if ([provider isEqual:@"gemini"]) url.queryItems = @[[NSURLQueryItem queryItemWithName:@"pageSize" value:@"100"]];
    if ([provider isEqual:@"claude"]) url.queryItems = @[[NSURLQueryItem queryItemWithName:@"limit" value:@"100"]];
  }
  return url.URL;
}

static NSString* modelCatalogIdentity(NSString* provider, NSURL* url, NSString* key) {
  // Account and endpoint scoped; never write keys (or key-bearing URLs) to disk.
  NSData* input = [[NSString stringWithFormat:@"v2\n%@\n%@\n%@", provider, url.absoluteString, key]
      dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(input.bytes, (CC_LONG)input.length, digest);
  NSMutableString* hash = [NSMutableString string];
  for (unsigned char byte : digest) [hash appendFormat:@"%02x", byte];
  return hash;
}

static NSDictionary* usableModel(NSDictionary* item, NSString* provider) {
  NSString* model = item[@"id"] ?: item[@"name"] ?: item[@"model"];
  if (![model isKindOfClass:NSString.class] || !model.length) return nil;
  if ([model hasPrefix:@"models/"]) model = [model substringFromIndex:7];
  NSString* lower = model.lowercaseString;
  if ([provider isEqual:@"gemini"]) {
    NSArray* methods = item[@"supportedGenerationMethods"];
    if (![methods isKindOfClass:NSArray.class] || ![methods containsObject:@"generateContent"] ||
        ![lower hasPrefix:@"gemini-"]) return nil;
    for (NSString* excluded in @[@"embedding", @"image", @"tts", @"robotics", @"computer-use", @"live", @"transcribe", @"omni", @"nano-banana", @"native-audio"])
      if ([lower containsString:excluded]) return nil;
  } else if ([provider isEqual:@"openai"]) {
    BOOL reasoning = lower.length > 1 && [lower characterAtIndex:0] == 'o' &&
        [lower characterAtIndex:1] >= '0' && [lower characterAtIndex:1] <= '9';
    if (![lower hasPrefix:@"gpt-"] && !reasoning && ![lower hasPrefix:@"chatgpt-"]) return nil;
    // This tuner uses Chat Completions, not image, realtime or Responses-only APIs.
    for (NSString* excluded in @[@"realtime", @"transcribe", @"tts", @"image", @"search", @"deep-research", @"codex", @"-pro", @"gpt-live", @"gpt-oss", @"cyber", @"daybreak"])
      if ([lower containsString:excluded]) return nil;
  } else if ([provider isEqual:@"claude"] && ![lower hasPrefix:@"claude-"]) return nil;
  NSNumber* created = [item[@"created"] isKindOfClass:NSNumber.class] ? item[@"created"] : @0;
  if ([item[@"created_at"] isKindOfClass:NSString.class]) {
    NSISO8601DateFormatter* formatter = [NSISO8601DateFormatter new];
    NSDate* date = [formatter dateFromString:item[@"created_at"]];
    if (!date) {
      formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
      date = [formatter dateFromString:item[@"created_at"]];
    }
    if (date) created = @(date.timeIntervalSince1970);
  }
  return @{@"id": model, @"created": created};
}

// Provider keys use nonstandard headers that URLSession may retain on redirect.
// Refuse redirects rather than risk sending credentials to a different origin.
@interface RigAIModelsSessionDelegate : NSObject <NSURLSessionTaskDelegate>
@end
@implementation RigAIModelsSessionDelegate
- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task
    willPerformHTTPRedirection:(NSHTTPURLResponse*)response newRequest:(NSURLRequest*)request
    completionHandler:(void (^)(NSURLRequest* _Nullable))completionHandler {
  completionHandler(nil);
}
@end

@interface RigAIModelCatalog ()
@property(nonatomic, strong) NSURLSession* session;
@property(nonatomic, copy) NSString* cacheDirectory;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSDictionary*>* cache;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSMutableArray<RigAIModelsCompletion>*>* pending;
- (void)fetchPage:(NSURL*)url provider:(NSString*)provider apiKey:(NSString*)key identity:(NSString*)identity
           items:(NSMutableDictionary*)items visited:(NSMutableSet*)visited deadline:(NSDate*)deadline retry:(BOOL)retry;
@end

@implementation RigAIModelCatalog

+ (instancetype)sharedCatalog {
  static RigAIModelCatalog* catalog;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString* root = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSURLSessionConfiguration* config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 8;
    config.timeoutIntervalForResource = 30;
    catalog = [[self alloc] initWithSession:[NSURLSession sessionWithConfiguration:config
        delegate:[RigAIModelsSessionDelegate new] delegateQueue:nil]
        cacheDirectory:[root stringByAppendingPathComponent:@"Axe FX/AI Models"]];
  });
  return catalog;
}

- (instancetype)initWithSession:(NSURLSession*)session cacheDirectory:(NSString*)directory {
  if ((self = [super init])) {
    _session = session;
    _cacheDirectory = [directory copy];
    _cache = [NSMutableDictionary dictionary];
    _pending = [NSMutableDictionary dictionary];
  }
  return self;
}

- (NSString*)cachePath:(NSString*)identity {
  return [self.cacheDirectory stringByAppendingPathComponent:[identity stringByAppendingString:@".json"]];
}

- (NSDictionary*)entryForIdentity:(NSString*)identity {
  NSDictionary* entry = self.cache[identity];
  if (!entry) {
    NSData* data = [NSData dataWithContentsOfFile:[self cachePath:identity]];
    if (data.length && data.length <= 1024 * 1024) {
      id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      if ([json isKindOfClass:NSDictionary.class] && [json[@"models"] isKindOfClass:NSArray.class] &&
          [json[@"fetched_at"] isKindOfClass:NSNumber.class] && [json[@"models"] count] > 0) {
        BOOL valid = YES;
        for (id model in json[@"models"]) if (![model isKindOfClass:NSString.class] || ![model length]) valid = NO;
        if (valid) { entry = json; self.cache[identity] = entry; }
      }
    }
  }
  return entry;
}

- (NSArray<NSString*>*)cachedModelsForProvider:(NSString*)provider apiKey:(NSString*)key baseURL:(NSString*)baseURL {
  NSAssert(NSThread.isMainThread, @"Model catalog is main-thread owned");
  NSString* p = provider.lowercaseString;
  NSURL* url = modelCatalogURL(p, baseURL);
  if (url && !key.length && publicModelCatalogURL(p)) url = publicModelCatalogURL(p);
  return url ? [self entryForIdentity:modelCatalogIdentity(p, url, key)][@"models"] : nil;
}

- (void)refreshModelsForProvider:(NSString*)provider apiKey:(NSString*)key baseURL:(NSString*)baseURL
                          force:(BOOL)force completion:(RigAIModelsCompletion)completion {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self refreshModelsForProvider:provider apiKey:key baseURL:baseURL force:force completion:completion];
    });
    return;
  }
  NSString* p = provider.lowercaseString;
  NSURL* url = modelCatalogURL(p, baseURL);
  if (!url || ![@[@"gemini", @"openai", @"claude", @"ollama", @"custom"] containsObject:p]) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, modelCatalogError(-1,
        @"Enter a valid HTTPS API URL (HTTP is allowed only on loopback), without credentials or query parameters.")); });
    return;
  }
  BOOL publicCatalog = !key.length && publicModelCatalogURL(p) != nil;
  if (publicCatalog) {
    url = publicModelCatalogURL(p);
    RigAIModelsCompletion original = [completion copy];
    completion = ^(NSArray<NSString*>* models, NSError* error) {
      original(models, error ?: modelCatalogError(-2,
          @"Public model catalog; account access is unverified. Add an API key for your account's available models."));
    };
  }
  NSString* identity = modelCatalogIdentity(p, url, key);
  NSDictionary* entry = [self entryForIdentity:identity];
  // Join an explicit refresh even when the old cache is still fresh. Otherwise a
  // dropdown-open event could supersede the UI callback with the pre-refresh list.
  if (self.pending[identity]) { [self.pending[identity] addObject:[completion copy]]; return; }
  NSTimeInterval age = NSDate.date.timeIntervalSince1970 - [entry[@"fetched_at"] doubleValue];
  if (!force && entry && age >= 0 && age < (publicCatalog ? 86400 : 3600)) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(entry[@"models"], nil); });
    return;
  }
  self.pending[identity] = [NSMutableArray arrayWithObject:[completion copy]];
  [self fetchPage:url provider:p apiKey:key identity:identity items:[NSMutableDictionary dictionary]
      visited:[NSMutableSet set] deadline:[NSDate dateWithTimeIntervalSinceNow:30] retry:NO];
}

- (void)finishIdentity:(NSString*)identity items:(NSMutableDictionary*)items error:(NSError*)error {
  NSArray* models = nil;
  if (!error) {
    NSArray* sorted = [items.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
      NSComparisonResult dates = [b[@"created"] compare:a[@"created"]];
      if (dates != NSOrderedSame) return dates;
      // Public docs have no release timestamps: numeric GPT generations must
      // precede older o-series / audio aliases instead of sorting 'o' above 'g'.
      NSString* first = a[@"id"];
      NSString* second = b[@"id"];
      BOOL firstGPT = [first hasPrefix:@"gpt-"] && first.length > 4 && [first characterAtIndex:4] >= '0' && [first characterAtIndex:4] <= '9';
      BOOL secondGPT = [second hasPrefix:@"gpt-"] && second.length > 4 && [second characterAtIndex:4] >= '0' && [second characterAtIndex:4] <= '9';
      if (firstGPT != secondGPT) return firstGPT ? NSOrderedAscending : NSOrderedDescending;
      return [b[@"id"] compare:a[@"id"] options:NSNumericSearch | NSCaseInsensitiveSearch];
    }];
    models = [sorted valueForKey:@"id"];
    if (!models.count) error = modelCatalogError(-3, @"The provider returned no models compatible with tone tuning. You can still enter a model ID manually.");
  }
  if (error) models = [self entryForIdentity:identity][@"models"];
  else {
    NSDictionary* entry = @{@"models": models, @"fetched_at": @(NSDate.date.timeIntervalSince1970)};
    self.cache[identity] = entry;
    [NSFileManager.defaultManager createDirectoryAtPath:self.cacheDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    NSData* data = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
    [data writeToFile:[self cachePath:identity] options:NSDataWritingAtomic error:nil];
  }
  NSArray<RigAIModelsCompletion>* callbacks = [self.pending[identity] copy];
  [self.pending removeObjectForKey:identity];
  for (RigAIModelsCompletion callback in callbacks) callback(models, error);
}

- (void)fetchPage:(NSURL*)url provider:(NSString*)provider apiKey:(NSString*)key identity:(NSString*)identity
           items:(NSMutableDictionary*)items visited:(NSMutableSet*)visited deadline:(NSDate*)deadline retry:(BOOL)retry {
  if (deadline.timeIntervalSinceNow <= 0 || (!retry && (visited.count >= 20 || [visited containsObject:url.absoluteString]))) {
    [self finishIdentity:identity items:items error:modelCatalogError(-4, @"Model discovery timed out or returned an invalid pagination loop. Try Refresh again.")];
    return;
  }
  [visited addObject:url.absoluteString];
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
      timeoutInterval:MIN(8.0, deadline.timeIntervalSinceNow)];
  BOOL publicCatalog = [url isEqual:publicModelCatalogURL(provider)];
  [request setValue:publicCatalog ? @"text/markdown, text/html, text/plain" : @"application/json" forHTTPHeaderField:@"Accept"];
  if (!publicCatalog && [provider isEqual:@"claude"]) {
    [request setValue:key forHTTPHeaderField:@"x-api-key"];
    [request setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
  } else if (!publicCatalog && [provider isEqual:@"gemini"]) [request setValue:key forHTTPHeaderField:@"x-goog-api-key"];
  else if (key.length) [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
  [[self.session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* networkError) {
    dispatch_async(dispatch_get_main_queue(), ^{
      NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse*)response statusCode] : 0;
      BOOL transient = status == 429 || status >= 500 || networkError.code == NSURLErrorTimedOut ||
          networkError.code == NSURLErrorNetworkConnectionLost;
      if (!retry && transient && deadline.timeIntervalSinceNow > 2) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          [self fetchPage:url provider:provider apiKey:key identity:identity items:items visited:visited deadline:deadline retry:YES];
        });
        return;
      }
      NSError* error = networkError ? modelCatalogError(networkError.code, @"Could not reach the provider's models API. Check your connection and API URL.") : nil;
      if (!error && (status < 200 || status >= 300)) {
        NSString* message = status == 401 || status == 403 ? @"Model discovery was denied. Check the API key and its model-list permissions." :
            (status == 429 ? @"The provider rate-limited model discovery. Try Refresh later." : @"Could not fetch the provider's models. Check the API URL.");
        error = modelCatalogError(status, [NSString stringWithFormat:@"%@ (HTTP %ld)", message, (long)status]);
      }
      id json = nil;
      if (!error && data.length && data.length <= (publicCatalog ? 2 : 1) * 1024 * 1024) {
        if (publicCatalog) {
          NSArray* entries = publicModelCatalogItems(data, provider);
          if (entries) json = @{@"data": entries};
        } else json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      }
      if (!error && ![json isKindOfClass:NSDictionary.class]) error = modelCatalogError(-5, @"The models API returned an invalid or oversized response.");
      NSArray* pageItems = !error ? (json[@"data"] ?: json[@"models"]) : nil;
      if (!error && ![pageItems isKindOfClass:NSArray.class]) error = modelCatalogError(-5, @"The models API response did not contain a model list.");
      if (error) { [self finishIdentity:identity items:items error:error]; return; }
      for (id item in pageItems) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary* model = usableModel(item, provider);
        if (model) items[model[@"id"]] = model;
      }
      NSString* cursor = nil;
      NSString* parameter = nil;
      if ([provider isEqual:@"claude"] && json[@"has_more"] && ![json[@"has_more"] isKindOfClass:NSNumber.class]) {
        [self finishIdentity:identity items:items error:modelCatalogError(-6, @"The models API returned invalid pagination metadata.")]; return;
      }
      if ([provider isEqual:@"gemini"] && json[@"nextPageToken"] != nil && json[@"nextPageToken"] != NSNull.null) {
        cursor = json[@"nextPageToken"]; parameter = @"pageToken";
      } else if ([provider isEqual:@"claude"] && [json[@"has_more"] isKindOfClass:NSNumber.class] && [json[@"has_more"] boolValue]) {
        cursor = json[@"last_id"]; parameter = @"after_id";
        if (![cursor isKindOfClass:NSString.class] || !cursor.length) {
          [self finishIdentity:identity items:items error:modelCatalogError(-6, @"The models API returned an invalid pagination cursor.")]; return;
        }
      }
      if (parameter && ![cursor isKindOfClass:NSString.class]) {
        [self finishIdentity:identity items:items error:modelCatalogError(-6, @"The models API returned an invalid pagination cursor.")]; return;
      }
      if (cursor.length) {
        NSURLComponents* next = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSMutableArray* query = [NSMutableArray array];
        for (NSURLQueryItem* item in next.queryItems) if (![item.name isEqual:parameter]) [query addObject:item];
        [query addObject:[NSURLQueryItem queryItemWithName:parameter value:cursor]];
        next.queryItems = query;
        [self fetchPage:next.URL provider:provider apiKey:key identity:identity items:items visited:visited deadline:deadline retry:NO];
      } else [self finishIdentity:identity items:items error:nil];
    });
  }] resume];
}

@end
