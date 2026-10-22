// Real discovery/cache code against an in-memory NSURLProtocol: no provider calls.
#import "rig_ai_model_catalog.h"
#include <cstdio>

static int failures = 0;
#define CHECK(x) do { if (!(x)) { ++failures; std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); } } while (0)
static NSMutableArray<NSDictionary*>* replies;
static NSMutableArray<NSURLRequest*>* requests;

@interface ModelFixtureProtocol : NSURLProtocol
@end
@implementation ModelFixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest*)request { return YES; }
+ (NSURLRequest*)canonicalRequestForRequest:(NSURLRequest*)request { return request; }
- (void)startLoading {
  NSDictionary* reply;
  @synchronized(ModelFixtureProtocol.class) {
    [requests addObject:self.request];
    reply = replies.firstObject;
    if (reply) [replies removeObjectAtIndex:0];
  }
  if (!reply) {
    [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:nil]];
    return;
  }
  if (reply[@"networkError"]) {
    [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:[reply[@"networkError"] integerValue] userInfo:nil]];
    return;
  }
  NSHTTPURLResponse* response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
      statusCode:reply[@"status"] ? [reply[@"status"] integerValue] : 200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
  [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
  NSData* data = reply[@"raw"] ? [reply[@"raw"] dataUsingEncoding:NSUTF8StringEncoding] :
      [NSJSONSerialization dataWithJSONObject:reply[@"json"] ?: @{} options:NSJSONWritingFragmentsAllowed error:nil];
  [self.client URLProtocol:self didLoadData:data];
  [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

static void fixture(NSArray* script) {
  @synchronized(ModelFixtureProtocol.class) {
    replies = [script mutableCopy]; requests = [NSMutableArray array];
  }
}
static NSArray* refresh(RigAIModelCatalog* catalog, NSString* provider, NSString* key, NSString* base,
                       BOOL force, NSError** outError) {
  __block BOOL done = NO;
  __block NSArray* result;
  __block NSError* error;
  [catalog refreshModelsForProvider:provider apiKey:key baseURL:base force:force completion:^(NSArray* models, NSError* err) {
    CHECK(NSThread.isMainThread); CHECK(!done);
    result = models; error = err; done = YES;
  }];
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:5];
  while (!done && deadline.timeIntervalSinceNow > 0)
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  CHECK(done);
  if (outError) *outError = error;
  return result;
}

int main(int argc, char** argv) {
  @autoreleasepool {
    CHECK(argc == 2 || argc == 3); if (argc != 2 && argc != 3) return 1;
    NSString* root = @(argv[1]);
    // Optional, explicit smoke check of the public docs path. Never uses API keys.
    if (argc == 3 && [@(argv[2]) isEqual:@"--live-public"]) {
      NSURLSession* liveSession = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
      RigAIModelCatalog* liveCatalog = [[RigAIModelCatalog alloc] initWithSession:liveSession cacheDirectory:root];
      NSDictionary* bases = @{@"openai": @"https://api.openai.com/v1", @"claude": @"https://api.anthropic.com/v1/messages",
                              @"gemini": @"https://generativelanguage.googleapis.com/v1beta/openai"};
      for (NSString* provider in @[@"openai", @"claude", @"gemini"]) {
        NSError* warning;
        NSArray* models = refresh(liveCatalog, provider, @"", bases[provider], YES, &warning);
        CHECK(models.count > 0 && warning.code == -2);
        if ([provider isEqual:@"openai"]) CHECK([models containsObject:@"gpt-6.1-sol"] && [models.firstObject hasPrefix:@"gpt-6"]);
        std::printf("%s public catalog: %lu models; %s\n", provider.UTF8String, (unsigned long)models.count,
            [[models subarrayWithRange:NSMakeRange(0, MIN(models.count, 5))] componentsJoinedByString:@", "].UTF8String);
      }
      [liveSession invalidateAndCancel];
      return failures ? 1 : 0;
    }
    NSURLSessionConfiguration* config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.protocolClasses = @[ModelFixtureProtocol.class];
    NSURLSession* session = [NSURLSession sessionWithConfiguration:config];
    RigAIModelCatalog* catalog = [[RigAIModelCatalog alloc] initWithSession:session cacheDirectory:root];
    NSString* openai = @"https://api.openai.com/v1/chat/completions/";
    NSError* error = nil;

    // Future model IDs are discovered rather than pinned to an old release list.
    fixture(@[@{@"json": @{@"data": @[
      @{@"id": @"gpt-4o", @"created": @10}, @{@"id": @"gpt-9.2", @"created": @20},
      @{@"id": @"o9", @"created": @30}, @{@"id": @"gpt-audio", @"created": @15},
      @{@"id": @"text-embedding-3-small"}, @{@"id": @"gpt-image-1"}, @{@"id": @"gpt-realtime"},
      @{@"id": @"o9-pro"}, @{@"id": NSNull.null}, NSNull.null, @{@"id": @"gpt-4o", @"created": @10}
    ]}}]);
    NSArray* live = refresh(catalog, @"OpenAI", @"test-key-a", openai, NO, &error);
    CHECK(!error && [live isEqual:(@[@"o9", @"gpt-9.2", @"gpt-audio", @"gpt-4o"])]);
    CHECK([requests.firstObject.URL.absoluteString isEqual:@"https://api.openai.com/v1/models"]);
    CHECK([[requests.firstObject valueForHTTPHeaderField:@"Authorization"] isEqual:@"Bearer test-key-a"]);
    CHECK(![requests.firstObject.URL.absoluteString containsString:@"test-key"]);

    // Fresh cache avoids repeated network calls, survives relaunch, and contains no credentials.
    fixture(@[]);
    RigAIModelCatalog* reopened = [[RigAIModelCatalog alloc] initWithSession:session cacheDirectory:root];
    CHECK([refresh(reopened, @"openai", @"test-key-a", openai, NO, &error) isEqual:live]);
    CHECK(!error && requests.count == 0);
    CHECK(![reopened cachedModelsForProvider:@"openai" apiKey:@"test-key-b" baseURL:openai]);
    CHECK(![reopened cachedModelsForProvider:@"openai" apiKey:@"test-key-a" baseURL:@"https://proxy.example/v1"]);
    NSString* filename = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil].firstObject;
    NSString* cachePath = [root stringByAppendingPathComponent:filename];
    NSString* cacheText = [NSString stringWithContentsOfFile:cachePath encoding:NSUTF8StringEncoding error:nil];
    CHECK(![filename containsString:@"test-key"] && ![cacheText containsString:@"test-key"]);

    // Forced failures keep last-known-good results and report the error, not fake success.
    fixture(@[@{@"status": @401}]);
    CHECK([refresh(reopened, @"openai", @"test-key-a", openai, YES, &error) isEqual:live]);
    CHECK(error.code == 401 && requests.count == 1);
    for (NSDictionary* reply in @[@{@"raw": @"not JSON"}, @{@"json": @[]},
                                  @{@"json": @{@"data": NSNull.null}}, @{@"json": @{@"data": @[]}}]) {
      fixture(@[reply]);
      CHECK([refresh(reopened, @"openai", @"test-key-a", openai, YES, &error) isEqual:live]);
      CHECK(error != nil);
    }

    // Expiry fetches again. Failures for a different account don't leak the old list.
    NSMutableDictionary* stale = [[NSJSONSerialization JSONObjectWithData:[cacheText dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] mutableCopy];
    stale[@"fetched_at"] = @1;
    [[NSJSONSerialization dataWithJSONObject:stale options:0 error:nil] writeToFile:cachePath atomically:YES];
    reopened = [[RigAIModelCatalog alloc] initWithSession:session cacheDirectory:root];
    fixture(@[@{@"json": @{@"data": @[@{@"id": @"gpt-10", @"created": @40}]}}]);
    CHECK([refresh(reopened, @"openai", @"test-key-a", openai, NO, &error) isEqual:(@[@"gpt-10"])]);
    CHECK(!error && requests.count == 1);
    fixture(@[@{@"status": @403}]);
    CHECK(!refresh(reopened, @"openai", @"test-key-b", openai, YES, &error));
    CHECK(error.code == 403);

    // Native Gemini pagination, generation capability checks and numeric newest-first sorting.
    NSString* gemini = @"https://generativelanguage.googleapis.com/v1beta/openai";
    fixture(@[
      @{@"json": @{@"models": @[
        @{@"name": @"models/gemini-9.2-flash", @"supportedGenerationMethods": @[@"generateContent"]},
        @{@"name": @"models/gemini-10-tts", @"supportedGenerationMethods": @[@"generateContent"]},
        @{@"name": @"models/gemini-embedding", @"supportedGenerationMethods": @[@"embedContent"]}
      ], @"nextPageToken": @"token+/="}},
      @{@"json": @{@"models": @[
        @{@"name": @"models/gemini-9.10-flash", @"supportedGenerationMethods": @[@"generateContent"]},
        @{@"name": @"models/gemini-9.2-flash", @"supportedGenerationMethods": @[@"generateContent"]}
      ]}}
    ]);
    CHECK([refresh(catalog, @"gemini", @"google-key", gemini, YES, &error) isEqual:(@[@"gemini-9.10-flash", @"gemini-9.2-flash"])]);
    CHECK(!error && requests.count == 2);
    CHECK([requests.firstObject.URL.path isEqual:@"/v1beta/models"]);
    CHECK([[requests.firstObject valueForHTTPHeaderField:@"x-goog-api-key"] isEqual:@"google-key"]);
    NSURLComponents* page2 = [NSURLComponents componentsWithURL:requests.lastObject.URL resolvingAgainstBaseURL:NO];
    CHECK([page2.queryItems.lastObject.value isEqual:@"token+/="]);

    // Anthropic pagination and release dates (not alphabetic family ordering).
    NSString* claude = @"https://api.anthropic.com/v1/messages";
    fixture(@[
      @{@"json": @{@"data": @[@{@"id": @"claude-opus-9", @"created_at": @"2026-01-01T00:00:00Z"}], @"has_more": @YES, @"last_id": @"claude-opus-9"}},
      @{@"json": @{@"data": @[@{@"id": @"claude-haiku-9", @"created_at": @"2026-02-01T00:00:00.000Z"}], @"has_more": @NO}}
    ]);
    CHECK([refresh(catalog, @"claude", @"anthropic-key", claude, YES, &error) isEqual:(@[@"claude-haiku-9", @"claude-opus-9"])]);
    CHECK(!error && requests.count == 2);
    CHECK([requests.firstObject.URL.path isEqual:@"/v1/models"]);
    CHECK([[requests.firstObject valueForHTTPHeaderField:@"x-api-key"] isEqual:@"anthropic-key"]);
    CHECK([[requests.firstObject valueForHTTPHeaderField:@"anthropic-version"] isEqual:@"2023-06-01"]);
    CHECK([requests.lastObject.URL.query containsString:@"after_id=claude-opus-9"]);

    // Pagination failure must not replace a complete cache with a partial list.
    fixture(@[@{@"json": @{@"data": @[@{@"id": @"claude-partial"}], @"has_more": @YES}}, @{@"status": @500}]);
    CHECK([refresh(catalog, @"claude", @"anthropic-key", claude, YES, &error) isEqual:(@[@"claude-haiku-9", @"claude-opus-9"])]);
    CHECK(error != nil && requests.count == 1);
    fixture(@[
      @{@"json": @{@"data": @[@{@"id": @"claude-partial"}], @"has_more": @YES, @"last_id": @"claude-partial"}},
      @{@"status": @403}
    ]);
    CHECK([refresh(catalog, @"claude", @"anthropic-key", claude, YES, &error) isEqual:(@[@"claude-haiku-9", @"claude-opus-9"])]);
    CHECK(error.code == 403 && requests.count == 2);
    fixture(@[
      @{@"json": @{@"models": @[], @"nextPageToken": @"loop"}},
      @{@"json": @{@"models": @[], @"nextPageToken": @"loop"}}
    ]);
    CHECK([refresh(catalog, @"gemini", @"google-key", gemini, YES, &error) count] == 2);
    CHECK(error != nil && requests.count == 2);

    // Native installed Ollama models and keyless OpenAI-compatible custom servers.
    fixture(@[@{@"json": @{@"models": @[@{@"name": @"llama4:latest"}, @{@"model": @"qwen3:8b"}]}}]);
    CHECK([refresh(catalog, @"ollama", @"", @"http://localhost:11434/v1/chat/completions", YES, &error) count] == 2);
    CHECK(!error && [requests.firstObject.URL.path isEqual:@"/api/tags"]);
    fixture(@[@{@"json": @{@"data": @[@{@"id": @"my-private-model"}]}}]);
    CHECK([refresh(catalog, @"custom", @"", @"http://127.0.0.1:1234/v1/", YES, &error) isEqual:(@[@"my-private-model"])]);
    CHECK(!error && [requests.firstObject.URL.path isEqual:@"/v1/models"]);

    // Unsafe URLs never start a request.
    fixture(@[]);
    for (NSString* base in @[@"http://remote.example/v1", @"https://user:pass@remote.example/v1", @"not a URL", @"https://example.com/v1?key=secret"])
      CHECK(!refresh(catalog, @"custom", @"key", base, YES, &error) && error);
    CHECK(requests.count == 0);

    // No API key: refresh exact model IDs from public official docs, not GPT-4-only starters.
    fixture(@[@{@"raw": @"- [Sol](/api/docs/models/gpt-6.1-sol.md)\n- [Astra](/api/docs/models/gpt-6-astra.md)\n- [Image](/api/docs/models/gpt-image-2.5-sunburst.md)\n- [o3](/api/docs/models/o3.md)"}]);
    CHECK([refresh(catalog, @"openai", @"", openai, YES, &error) isEqual:(@[@"gpt-6.1-sol", @"gpt-6-astra", @"o3"])]);
    CHECK(error.code == -2 && [error.localizedDescription containsString:@"Public model catalog"]);
    CHECK([requests.firstObject.URL.host isEqual:@"developers.openai.com"]);
    CHECK(![requests.firstObject valueForHTTPHeaderField:@"Authorization"]);
    fixture(@[]);
    CHECK([refresh(catalog, @"openai", @"", openai, NO, &error) count] == 3 && requests.count == 0);
    fixture(@[@{@"status": @403}]);
    CHECK([refresh(catalog, @"openai", @"", openai, YES, &error) count] == 3 && error.code == 403);
    fixture(@[@{@"raw": @"| API ID | `claude-sonnet-5-5` | `claude-opus-5-5` |"}]);
    CHECK([refresh(catalog, @"claude", @"", claude, YES, &error) count] == 2 && error.code == -2);
    CHECK(![requests.firstObject valueForHTTPHeaderField:@"x-api-key"]);
    fixture(@[@{@"raw": @"<a href='/gemini-api/docs/models/gemini-4-argon'>Argon</a><a href='/gemini-api/docs/models/gemini-3.8-flash'>Flash</a><a href='/gemini-api/docs/models/gemini-3.8-live'>Live</a>"}]);
    CHECK([refresh(catalog, @"gemini", @"", gemini, YES, &error) isEqual:(@[@"gemini-4-argon", @"gemini-3.8-flash"])] && error.code == -2);
    CHECK(![requests.firstObject valueForHTTPHeaderField:@"x-goog-api-key"]);

    // Retry transient discovery once, but never retry paid tone-generation calls.
    fixture(@[@{@"status": @503}, @{@"json": @{@"data": @[@{@"id": @"gpt-11"}]}}]);
    CHECK([refresh(catalog, @"openai", @"retry-key", openai, YES, &error) isEqual:(@[@"gpt-11"])]);
    CHECK(!error && requests.count == 2);

    fixture(@[@{@"status": @429}, @{@"status": @429}]);
    CHECK([refresh(catalog, @"openai", @"retry-key", openai, YES, &error) isEqual:(@[@"gpt-11"])]);
    CHECK(error.code == 429 && requests.count == 2);

    // Repeated UI events share a single in-flight discovery request.
    fixture(@[@{@"json": @{@"data": @[@{@"id": @"shared-model"}]}}]);
    __block int callbacks = 0;
    for (int i = 0; i < 2; ++i)
      [catalog refreshModelsForProvider:@"custom" apiKey:@"" baseURL:@"https://shared.example/v1" force:YES completion:^(NSArray* models, NSError* err) {
        CHECK(NSThread.isMainThread && !err && models.count == 1); ++callbacks;
      }];
    NSDate* end = [NSDate dateWithTimeIntervalSinceNow:3];
    while (callbacks < 2 && end.timeIntervalSinceNow > 0)
      [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK(callbacks == 2 && requests.count == 1);
    // An automatic check during a forced refresh must join it, not return stale cache.
    fixture(@[@{@"json": @{@"data": @[@{@"id": @"new-shared-model"}]}}]);
    callbacks = 0;
    for (int i = 0; i < 2; ++i)
      [catalog refreshModelsForProvider:@"custom" apiKey:@"" baseURL:@"https://shared.example/v1" force:i == 0 completion:^(NSArray* models, NSError* err) {
        CHECK(!err && [models isEqual:(@[@"new-shared-model"])]); ++callbacks;
      }];
    end = [NSDate dateWithTimeIntervalSinceNow:3];
    while (callbacks < 2 && end.timeIntervalSinceNow > 0)
      [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    CHECK(callbacks == 2 && requests.count == 1);
    [session invalidateAndCancel];
    std::printf("Model catalog: %d failures\n", failures);
    return failures ? 1 : 0;
  }
}
