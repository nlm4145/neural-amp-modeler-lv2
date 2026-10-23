// RigLocalServer — Embedded Local HTTP REST API for Axe FX.
#import "rig_local_server.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <thread>
#include <atomic>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <cerrno>
#import <Security/Security.h>
#import "rig_ai_support.h"

#import "rig_ai_copilot.h"
#import "rig_control_metadata.h"
#import "rig_presets.h"
#import "rig_ui_state.h"

extern NSDictionary<NSString*, NSNumber*>* rigSymbolToPortMap();
extern NSDictionary<NSNumber*, NSString*>* rigPortToSymbolMap();

static bool sendAll(int socket, const void* bytes, size_t count) {
  const char* data = static_cast<const char*>(bytes);
  while (count) {
    ssize_t sent = send(socket, data, count, 0);
    if (sent < 0 && errno == EINTR) continue;
    if (sent <= 0) return false;
    data += sent; count -= sent;
  }
  return true;
}

static void sendHttpResponse(int clientSock, int statusCode, const char* statusText, const char* contentType, NSData* bodyData) {
  NSMutableString* headers = [NSMutableString stringWithFormat:
    @"HTTP/1.1 %d %s\r\n"
    @"Content-Type: %s; charset=utf-8\r\n"
    @"Content-Length: %lu\r\n"
    @"Connection: close\r\n\r\n",
    statusCode, statusText, contentType, (unsigned long)bodyData.length];
  NSData* headerData = [headers dataUsingEncoding:NSUTF8StringEncoding];
  if (!sendAll(clientSock, headerData.bytes, headerData.length)) return;
  if (bodyData.length > 0) {
    sendAll(clientSock, bodyData.bytes, bodyData.length);
  }
}

static void sendJson(int clientSock, int statusCode, id jsonObject) {
  NSError* err = nil;
  NSData* data = nil;
  if (jsonObject) {
    data = [NSJSONSerialization dataWithJSONObject:jsonObject options:NSJSONWritingPrettyPrinted error:&err];
  }
  if (!data) {
    data = [@"{\"status\":\"error\",\"message\":\"JSON serialization error\"}" dataUsingEncoding:NSUTF8StringEncoding];
  }
  sendHttpResponse(clientSock, statusCode, statusCode == 200 ? "OK" : "Error", "application/json", data);
}

static NSString* tokenFilePath() {
  NSString* dir = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject]
      stringByAppendingPathComponent:@"Axe FX"];
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  return [dir stringByAppendingPathComponent:@"local-api-token"];
}

@interface RigLocalServer () {
  std::atomic<int> _serverSock;
  std::atomic<int> _clientSock;
  std::thread _workerThread;
  std::atomic<bool> _shouldStop;
}
@property(nonatomic, assign) BOOL isRunning;
@property(nonatomic, assign) uint16_t port;
@property(nonatomic, copy) NSString* authToken;
@end

@implementation RigLocalServer

+ (instancetype)sharedServer {
  static RigLocalServer* sInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sInstance = [[RigLocalServer alloc] init];
  });
  return sInstance;
}

- (instancetype)init {
  if ((self = [super init])) {
    _serverSock = -1;
    _clientSock = -1;
    _shouldStop = false;
    _port = 48920;
  }
  return self;
}

- (void)dealloc {
  [self stop];
}

- (BOOL)startWithPort:(uint16_t)port {
  if (self.isRunning) return YES;

  NSString* tokenPath = tokenFilePath();
  struct stat tokenStat;
  if (lstat(tokenPath.fileSystemRepresentation, &tokenStat) == 0 &&
      (!S_ISREG(tokenStat.st_mode) || tokenStat.st_uid != getuid())) return NO;
  NSString* token = [NSString stringWithContentsOfFile:tokenPath encoding:NSUTF8StringEncoding error:nil];
  if (token.length != 64) {
    uint8_t bytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) return NO;
    NSMutableString* generated = [NSMutableString string];
    for (uint8_t b : bytes) [generated appendFormat:@"%02x", b];
    int fd = open(tokenPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    if (fd < 0) return NO;
    BOOL ok = fchmod(fd, 0600) == 0 && write(fd, generated.UTF8String, 64) == 64;
    close(fd);
    if (!ok) return NO;
    token = generated;
  }
  if (chmod(tokenPath.fileSystemRepresentation, 0600) != 0) return NO;
  self.authToken = token;

  _serverSock = socket(AF_INET, SOCK_STREAM, 0);
  if (_serverSock < 0) return NO;

  int yes = 1;
  setsockopt(_serverSock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

  struct sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons(port);

  if (::bind(_serverSock.load(), (struct sockaddr*)&addr, sizeof(addr)) < 0) {
    close(_serverSock);
    _serverSock = -1;
    return NO;
  }

  if (listen(_serverSock, 16) < 0) {
    close(_serverSock);
    _serverSock = -1;
    return NO;
  }

  _port = port;
  _shouldStop = false;
  _isRunning = YES;

  _workerThread = std::thread([self]() {
    [self runServerLoop];
  });

  NSLog(@"[RigLocalServer] Axe FX Local API listening on http://127.0.0.1:%d", port);
  return YES;
}

- (void)stop {
  if (!self.isRunning) return;
  _shouldStop = true;
  _isRunning = NO;
  int client = _clientSock.load();
  if (client >= 0) shutdown(client, SHUT_RDWR);

  int server = _serverSock.exchange(-1);
  if (server >= 0) {
    shutdown(server, SHUT_RDWR);
    close(server);
  }

  if (_workerThread.joinable()) {
    _workerThread.join();
  }
  NSLog(@"[RigLocalServer] Server stopped.");
}

- (void)runServerLoop {
  while (!_shouldStop) {
    struct sockaddr_in clientAddr{};
    socklen_t clientLen = sizeof(clientAddr);
    int clientSock = accept(_serverSock, (struct sockaddr*)&clientAddr, &clientLen);
    if (clientSock < 0) {
      if (_shouldStop) break;
      continue;
    }
    _clientSock = clientSock;
    int noSigPipe = 1;
    setsockopt(clientSock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

    // Set timeout on client socket so it doesn't hang indefinitely
    struct timeval tv{5, 0};
    setsockopt(clientSock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
    setsockopt(clientSock, SOL_SOCKET, SO_SNDTIMEO, (const char*)&tv, sizeof(tv));

    @autoreleasepool {
      [self handleClientSocket:clientSock];
    }
    _clientSock = -1;
    close(clientSock);
  }
}

- (BOOL)onMain:(void (^)(void))block {
  // Never join a worker waiting synchronously for the main thread during shutdown.
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self->_shouldStop) block();
    dispatch_semaphore_signal(done);
  });
  while (!_shouldStop) {
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) == 0) return YES;
  }
  return NO;
}

- (void)handleClientSocket:(int)clientSock {
  std::string raw;
  size_t headerEnd = std::string::npos;
  while ((headerEnd = raw.find("\r\n\r\n")) == std::string::npos) {
    char buffer[4096];
    ssize_t count = recv(clientSock, buffer, sizeof(buffer), 0);
    if (count <= 0) return;
    raw.append(buffer, count);
    if (raw.size() > 16384) { sendJson(clientSock, 413, @{ @"status": @"error", @"message": @"Headers too large" }); return; }
  }
  NSString* reqString = [[NSString alloc] initWithBytes:raw.data() length:headerEnd encoding:NSUTF8StringEncoding];
  if (!reqString) { sendJson(clientSock, 400, @{ @"status": @"error", @"message": @"Invalid headers" }); return; }
  NSMutableDictionary* headers = [NSMutableDictionary dictionary];
  NSArray* lines = [reqString componentsSeparatedByString:@"\r\n"];
  for (NSUInteger i = 1; i < lines.count; ++i) {
    NSRange colon = [lines[i] rangeOfString:@":"];
    if (colon.location == NSNotFound) { sendJson(clientSock, 400, @{ @"status": @"error", @"message": @"Invalid header" }); return; }
    NSString* key = [[lines[i] substringToIndex:colon.location] lowercaseString];
    if (headers[key]) { sendJson(clientSock, 400, @{ @"status": @"error", @"message": @"Duplicate header" }); return; }
    headers[key] = [[lines[i] substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  }
  NSString* host = [NSString stringWithFormat:@"127.0.0.1:%u", _port];
  NSString* localhost = [NSString stringWithFormat:@"localhost:%u", _port];
  if (headers[@"origin"] || (![headers[@"host"] isEqual:host] && ![headers[@"host"] isEqual:localhost])) {
    sendJson(clientSock, 403, @{ @"status": @"error", @"message": @"Browser origins and non-loopback hosts are not allowed" }); return;
  }
  if (![headers[@"authorization"] isEqual:[@"Bearer " stringByAppendingString:self.authToken]]) {
    sendJson(clientSock, 401, @{ @"status": @"error", @"message": @"Local API bearer token required" }); return;
  }
  NSString* lengthText = headers[@"content-length"] ?: @"0";
  NSCharacterSet* digits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
  if (!lengthText.length || [lengthText rangeOfCharacterFromSet:digits.invertedSet].location != NSNotFound ||
      lengthText.length > 6 || lengthText.longLongValue > 65536 || headers[@"transfer-encoding"]) {
    sendJson(clientSock, 400, @{ @"status": @"error", @"message": @"Invalid body length or transfer encoding" }); return;
  }
  size_t bodyLength = lengthText.longLongValue;
  const size_t bodyStart = headerEnd + 4;
  while (raw.size() < bodyStart + bodyLength) {
    char buffer[4096];
    ssize_t count = recv(clientSock, buffer, std::min(sizeof(buffer), bodyStart + bodyLength - raw.size()), 0);
    if (count <= 0) { sendJson(clientSock, 400, @{ @"status": @"error", @"message": @"Incomplete request body" }); return; }
    raw.append(buffer, count);
  }

  NSScanner* scanner = [NSScanner scannerWithString:reqString];
  NSString* method = nil;
  NSString* fullPath = nil;
  [scanner scanUpToCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:&method];
  [scanner scanCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:NULL];
  [scanner scanUpToCharactersFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet] intoString:&fullPath];

  if (!method.length || !fullPath.length) return;

  // Parse path and query parameters
  NSURLComponents* comps = [NSURLComponents componentsWithString:fullPath];
  NSString* path = comps.path ?: fullPath;
  NSMutableDictionary<NSString*, NSString*>* queryParams = [NSMutableDictionary dictionary];
  for (NSURLQueryItem* item in comps.queryItems) {
    if (item.name.length && item.value) {
      queryParams[item.name] = item.value;
    }
  }

  // Extract JSON body if present
  NSDictionary* bodyJson = nil;
  if (bodyLength) {
    if (![[headers[@"content-type"] lowercaseString] hasPrefix:@"application/json"]) {
      sendJson(clientSock, 415, @{@"status": @"error", @"message": @"JSON Content-Type required"}); return;
    }
    NSData* data = [NSData dataWithBytes:raw.data() + bodyStart length:bodyLength];
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class]) { sendJson(clientSock, 400, @{ @"status": @"error", @"message": @"Expected JSON object" }); return; }
    bodyJson = json;
  }
  bodyJson = bodyJson ?: @{};
  NSSet* reads = [NSSet setWithArray:@[@"/api/v1/ping", @"/api/v1/state", @"/api/v1/controls/schema", @"/api/v1/presets", @"/api/v1/library/search"]];
  BOOL configRoute = [path isEqual:@"/api/v1/ai/config"];
  if (!([method isEqual:@"GET"] && ([reads containsObject:path] || configRoute)) &&
      !([method isEqual:@"POST"] && ![reads containsObject:path])) {
    sendJson(clientSock, 405, @{ @"status": @"error", @"message": @"Method not allowed" }); return;
  }
  for (NSString* key in @[@"path", @"amp", @"cab", @"name", @"prompt", @"provider", @"api_key", @"model", @"base_url"]) {
    if (bodyJson[key] && ![bodyJson[key] isKindOfClass:NSString.class]) {
      sendJson(clientSock, 400, @{ @"status": @"error", @"message": [key stringByAppendingString:@" must be a string"] }); return;
    }
  }
  for (NSString* key in @[@"stage", @"apply", @"temperature", @"allow_local_cli"]) {
    if (bodyJson[key] && ![bodyJson[key] isKindOfClass:NSNumber.class]) {
      sendJson(clientSock, 400, @{ @"status": @"error", @"message": [key stringByAppendingString:@" must be numeric/boolean"] }); return;
    }
  }
  if ([path isEqual:@"/api/v1/controls/schema"]) {
    sendJson(clientSock, 200, @{ @"status": @"ok", @"reference": rigAIControlReference() }); return;
  }

  // Route Dispatching
  if ([path isEqualToString:@"/api/v1/ping"]) {
    sendJson(clientSock, 200, @{
      @"status": @"ok",
      @"app": @"Axe FX",
      @"port": @(_port),
      @"version": @"1.0"
    });
    return;
  }

  if ([path isEqualToString:@"/api/v1/state"]) {
    __block NSDictionary* stateDict = nil;
    [self onMain:^{
      RigUIState* state = RigUIState::activeState();
      if (!state) {
        stateDict = @{@"status": @"error", @"message": @"No active UI state running"};
        return;
      }

      RigPreset* curPreset = [RigPreset captureFromState:state name:@"Active State"];
      NSMutableDictionary* ctrls = [NSMutableDictionary dictionary];
      for (const auto& kv : curPreset.allControls) {
        const char* sym = NAMRig::rigControlSymbol(kv.first);
        if (sym && sym[0]) {
          ctrls[[NSString stringWithUTF8String:sym]] = @(kv.second);
        }
      }

      NSDictionary* (^readStage)(size_t) = ^NSDictionary*(size_t s) {
        const auto* st = [curPreset stageAtIndex:s];
        NSString* p = st ? [NSString stringWithUTF8String:st->path.c_str()] : @"";
        return @{
          @"enabled": @(st ? st->enabled : false),
          @"path": p ?: @"",
          @"name": p.lastPathComponent ?: @"",
          @"toneId": @(st ? st->toneId : 0)
        };
      };

      stateDict = @{
        @"status": @"ok",
        @"current_preset": state->presetManager.currentPresetName ?: @"Default Rig",
        @"controls": ctrls,
        @"stages": @{
          @"pedal": readStage(0),
          @"amp": readStage(1),
          @"cab": readStage(2),
          @"cab2": readStage(3)
        },
        @"slot_presets": curPreset.slotPresets ?: @{},
        @"meters": @{
          @"input_db": @(state->lastInputDb)
        }
      };
    }];

    sendJson(clientSock, 200, stateDict);
    return;
  }

  if ([path isEqualToString:@"/api/v1/controls"]) {
    NSError* validationError = nil;
    if (!rigAIValidateControls(bodyJson, &validationError)) {
      sendJson(clientSock, 400, @{@"status": @"error", @"message": validationError.localizedDescription});
      return;
    }

    __block NSMutableArray<NSString*>* updated = [NSMutableArray array];
    __block BOOL active = NO;
    [self onMain:^{
      RigUIState* state = RigUIState::activeState();
      if (!state) return;
      active = YES;

      NSDictionary<NSString*, NSNumber*>* symMap = rigSymbolToPortMap();
      for (NSString* key in bodyJson) {
        NSNumber* portNum = symMap[key];
        uint32_t port = portNum.unsignedIntValue;

        if (port > 0) {
          float val = [bodyJson[key] floatValue];
          state->sendControl(port, val);
          state->updateControl(port, val);
          [updated addObject:key];
        }
      }
      state->markModified();
    }];

    sendJson(clientSock, active ? 200 : 503, @{@"status": active ? @"ok" : @"error", @"updated": updated});
    return;
  }

  if ([path isEqualToString:@"/api/v1/models/load"]) {
    NSString* modelPath = bodyJson[@"path"];
    NSString* amp = bodyJson[@"amp"];
    NSString* cab = bodyJson[@"cab"];
    NSNumber* stageNum = bodyJson[@"stage"];

    NSMutableDictionary<NSNumber*, NSString*>* paths = [NSMutableDictionary dictionary];
    NSString* root = [@"~/Music/Tone3000 Library" stringByExpandingTildeInPath];
    NSError* resolveError = nil;
    if (modelPath.length) {
      if (!stageNum || !std::isfinite(stageNum.doubleValue) || stageNum.doubleValue < 0 || stageNum.doubleValue > 3 || std::floor(stageNum.doubleValue) != stageNum.doubleValue) {
        sendJson(clientSock, 400, @{@"status": @"error", @"message": @"stage must be 0..3"}); return;
      }
      NSString* resolved = rigAIResolveModel(root, modelPath, stageNum.unsignedIntegerValue, &resolveError);
      if (resolved) paths[stageNum] = resolved;
    }
    for (NSNumber* stage in @[@1, @2]) {
      NSString* target = stage.intValue == 1 ? amp : cab;
      if (!target.length) continue;
      NSString* resolved = rigAIResolveModel(root, target, stage.unsignedIntegerValue, &resolveError);
      if (resolved) paths[stage] = resolved;
    }
    if (resolveError || !paths.count) { sendJson(clientSock, 400, @{@"status": @"error", @"message": resolveError.localizedDescription ?: @"No models supplied"}); return; }
    __block NSMutableArray<NSString*>* loaded = [NSMutableArray array];
    __block BOOL active = NO;
    [self onMain:^{
      RigUIState* state = RigUIState::activeState();
      if (!state) return;
      active = YES;
      for (NSNumber* stage in paths) {
          size_t stIdx = stage.unsignedIntegerValue;
          NSString* fullPath = paths[stage];
          std::string cpp = fullPath.fileSystemRepresentation;
            std::vector<std::string> models = discoverModelsForStagePath(cpp, stIdx);
            if (std::find(models.begin(), models.end(), cpp) == models.end()) models.push_back(cpp);
            NSMutableArray<NSString*>* mPaths = [NSMutableArray array];
            for (const auto& m : models) [mPaths addObject:[NSString stringWithUTF8String:m.c_str()]];
            state->setStageModels(stIdx, mPaths);
          state->sendPath(stIdx, cpp.c_str());
          state->updateThumbnailForStagePath(stIdx, fullPath);
          [loaded addObject:fullPath.lastPathComponent];
      }
      state->markModified();
    }];

    sendJson(clientSock, active ? 200 : 503, @{@"status": active ? @"ok" : @"error", @"requested_models": loaded});
    return;
  }

  if ([path isEqualToString:@"/api/v1/presets"]) {
    __block NSDictionary* resp = nil;
    [self onMain:^{
      RigPresetManager* pm = [RigPresetManager sharedManager];
      [pm rescanPresets];
      resp = @{
        @"status": @"ok",
        @"current": pm.currentPresetName ?: @"",
        @"presets": pm.presetNames ?: @[]
      };
    }];
    sendJson(clientSock, 200, resp);
    return;
  }

  if ([path isEqualToString:@"/api/v1/presets/load"]) {
    NSString* name = bodyJson[@"name"];
    if (!name.length) {
      sendJson(clientSock, 400, @{@"status": @"error", @"message": @"Missing preset 'name'"});
      return;
    }

    __block BOOL ok = NO;
    __block NSDictionary* aiMetadata = nil;
    [self onMain:^{
      RigUIState* state = RigUIState::activeState();
      if (state) {
        NSString* resolvedName = name;
        if (![[RigPresetManager sharedManager].presetNames containsObject:resolvedName]) {
          for (NSString* p in [RigPresetManager sharedManager].presetNames) {
            if ([p.lastPathComponent localizedCaseInsensitiveCompare:name] == NSOrderedSame) {
              resolvedName = p;
              break;
            }
          }
        }
        if (![[RigPresetManager sharedManager].presetNames containsObject:resolvedName]) return;
        state->applyPresetByName(resolvedName);
        RigPreset* p = [[RigPresetManager sharedManager] loadPresetNamed:resolvedName];
        if (p && p.aiMetadata) aiMetadata = [p.aiMetadata copy];
        ok = YES;
      }
    }];

    NSMutableDictionary* resp = [NSMutableDictionary dictionaryWithDictionary:@{
      @"status": ok ? @"ok" : @"error",
      @"loaded": name
    }];
    if (aiMetadata) {
      resp[@"ai_metadata"] = aiMetadata;
      if (aiMetadata[@"input_tokens"]) resp[@"input_tokens"] = aiMetadata[@"input_tokens"];
      if (aiMetadata[@"output_tokens"]) resp[@"output_tokens"] = aiMetadata[@"output_tokens"];
      if (aiMetadata[@"token_cost"]) resp[@"token_cost"] = aiMetadata[@"token_cost"];
      if (aiMetadata[@"cumulative_token_cost"]) resp[@"cumulative_token_cost"] = aiMetadata[@"cumulative_token_cost"];
    }
    sendJson(clientSock, ok ? 200 : 500, resp);
    return;
  }

  if ([path isEqualToString:@"/api/v1/presets/save"]) {
    NSString* name = bodyJson[@"name"];
    if (!name.length) {
      sendJson(clientSock, 400, @{@"status": @"error", @"message": @"Missing preset 'name'"});
      return;
    }

    __block BOOL ok = NO;
    __block NSError* saveErr = nil;
    [self onMain:^{
      RigUIState* state = RigUIState::activeState();
      if (state) {
        ok = [[RigPresetManager sharedManager] savePresetNamed:name fromState:state error:&saveErr];
      }
    }];

    if (ok) {
      sendJson(clientSock, 200, @{@"status": @"ok", @"saved": name});
    } else {
      sendJson(clientSock, 500, @{@"status": @"error", @"message": saveErr.localizedDescription ?: @"Save failed"});
    }
    return;
  }

  if ([path isEqualToString:@"/api/v1/library/search"]) {
    NSString* q = [queryParams[@"q"] lowercaseString] ?: @"";
    NSString* libRoot = [@"~/Music/Tone3000 Library" stringByExpandingTildeInPath];
    NSFileManager* fm = [NSFileManager defaultManager];
    NSMutableArray* results = [NSMutableArray array];

    NSDirectoryEnumerator* en = [fm enumeratorAtPath:libRoot];
    NSString* rel = nil;
    while ((rel = [en nextObject])) {
      NSString* ext = rel.pathExtension.lowercaseString;
      if ([ext isEqualToString:@"nam"] || [ext isEqualToString:@"wav"]) {
        NSString* lower = rel.lowercaseString;
        if (q.length == 0 || [lower containsString:q]) {
          NSString* full = [libRoot stringByAppendingPathComponent:rel];
          NSDictionary* attrs = [fm attributesOfItemAtPath:full error:nil];
          if (![attrs[NSFileType] isEqual:NSFileTypeRegular]) continue;
          unsigned long long sz = [attrs fileSize] / 1024;
          [results addObject:@{
            @"name": rel.lastPathComponent,
            @"path": rel,
            @"category": [rel pathComponents].count > 1 ? [rel pathComponents][0] : @"",
            @"extension": ext,
            @"size_kb": @(sz)
          }];
          if (results.count >= 100) break;
        }
      }
    }

    sendJson(clientSock, 200, @{@"status": @"ok", @"count": @(results.count), @"results": results});
    return;
  }

  if ([path isEqualToString:@"/api/v1/ai/prompt"]) {
    NSString* prompt = bodyJson[@"prompt"];
    BOOL apply = [bodyJson[@"apply"] boolValue];
    if (!prompt.length) {
      sendJson(clientSock, 400, @{@"status": @"error", @"message": @"Missing 'prompt' string"});
      return;
    }

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block RigAICopilotResult* aiResult = nil;
    __block NSError* aiError = nil;

    __block BOOL abandoned = NO; // Accessed only on main queue.
    __block BOOL applied = NO;
    __block BOOL ownsRequest = NO;
    [self onMain:^{
      RigUIState* state = RigUIState::activeState();
      auto alive = state ? state->isAlive : std::shared_ptr<bool>();
      ownsRequest = ![RigAICopilot sharedCopilot].isProcessing;
      [[RigAICopilot sharedCopilot] processUserPrompt:prompt
                                          withState:state
                                  completionHandler:^(RigAICopilotResult* res, NSError* err) {
                                     if (abandoned) return;
                                     if (apply && res && !err) {
                                       if (!alive || !*alive) {
                                         aiError = [NSError errorWithDomain:@"RigAICopilot" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"Rig closed before application."}];
                                         dispatch_semaphore_signal(sema); return;
                                       }
                                       [[RigAICopilot sharedCopilot] applyResult:res toState:state completionHandler:^(NSError* applyError) {
                                         aiResult = res; aiError = applyError; applied = !applyError;
                                         if (applyError) [[RigAICopilot sharedCopilot] failCurrentTaskWithError:applyError];
                                         else [[RigAICopilot sharedCopilot] completeCurrentTaskWithResult:res savedPresetName:nil];
                                         dispatch_semaphore_signal(sema);
                                       }];
                                       return;
                                     }
                                     aiResult = res;
                                     aiError = err;
                                     if (res && !err) [[RigAICopilot sharedCopilot] completeCurrentTaskWithResult:res savedPresetName:nil];
                                    dispatch_semaphore_signal(sema);
                                   }];
    }];

    BOOL completed = NO;
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:130];
    while (!_shouldStop && deadline.timeIntervalSinceNow > 0) {
      if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) == 0) { completed = YES; break; }
    }
    if (!completed) {
      dispatch_async(dispatch_get_main_queue(), ^{ abandoned = YES; if (ownsRequest) [[RigAICopilot sharedCopilot] cancelProcessing]; });
      if (!_shouldStop) sendJson(clientSock, 504, @{@"status": @"error", @"message": @"AI request timed out"});
      return;
    }

    if (aiError || !aiResult) {
      sendJson(clientSock, 500, @{
        @"status": @"error",
        @"message": aiError.localizedDescription ?: @"AI request timed out or returned no result."
      });
      return;
    }

    sendJson(clientSock, 200, @{
      @"status": @"ok",
      @"thought": aiResult.thought ?: @"",
      @"explanation": aiResult.explanation ?: @"",
      @"controls": aiResult.controls ?: @{},
      @"amp_model": aiResult.ampPath ?: @"",
      @"cab_ir": aiResult.cabPath ?: @"",
      @"applied": @(applied),
      @"input_tokens": @(aiResult.inputTokens),
      @"output_tokens": @(aiResult.outputTokens),
      @"input_cost": @(aiResult.inputCost),
      @"output_cost": @(aiResult.outputCost),
      @"token_cost": @(aiResult.tokenCost),
      @"token_usage": aiResult.tokenUsageSummary ?: [NSString stringWithFormat:@"%ld in / %ld out · Cost: $%.5f", (long)aiResult.inputTokens, (long)aiResult.outputTokens, aiResult.tokenCost]
    });
    return;
  }

  if ([path isEqualToString:@"/api/v1/ai/config"]) {
    __block NSDictionary* configResponse = nil;
    __block NSError* configError = nil;
    [self onMain:^{
    RigAIConfig* cfg = [RigAICopilot sharedCopilot].config;
    if ([method.uppercaseString isEqualToString:@"GET"]) {
      configResponse = @{
        @"provider": cfg.provider ?: @"gemini",
        @"model": cfg.model ?: @"",
        @"base_url": cfg.baseURL ?: @"",
        @"temperature": @(cfg.temperature),
        @"allow_local_cli": @(cfg.allowLocalCLI),
        @"has_key": @(cfg.effectiveApiKey.length > 0)
      };
      return;
    } else if ([method.uppercaseString isEqualToString:@"POST"]) {
      NSString* provider = bodyJson[@"provider"] ?: cfg.provider;
      if (![@[@"gemini", @"openai", @"claude", @"ollama", @"custom"] containsObject:provider] ||
          (bodyJson[@"temperature"] && (!std::isfinite([bodyJson[@"temperature"] doubleValue]) ||
           [bodyJson[@"temperature"] doubleValue] < 0 || [bodyJson[@"temperature"] doubleValue] > 1))) {
        configError = [NSError errorWithDomain:@"RigAICopilot" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"Invalid provider or temperature."}]; return;
      }
      if (![provider isEqual:cfg.provider]) {
        cfg.provider = provider;
        cfg.apiKey = [RigAIConfig storedApiKeyForProvider:provider];
        cfg.baseURL = [RigAIConfig defaultBaseURLForProvider:provider];
        cfg.model = [RigAICopilot defaultModelsForProvider:provider].firstObject ?: @"";
      }
      if (bodyJson[@"api_key"]) cfg.apiKey = bodyJson[@"api_key"];
      if (bodyJson[@"model"]) cfg.model = bodyJson[@"model"];
      if (bodyJson[@"base_url"]) cfg.baseURL = bodyJson[@"base_url"];
      if (bodyJson[@"temperature"]) cfg.temperature = [bodyJson[@"temperature"] floatValue];
      if (bodyJson[@"allow_local_cli"]) cfg.allowLocalCLI = [bodyJson[@"allow_local_cli"] boolValue];
      if ([cfg saveToDisk:&configError]) configResponse = @{@"status": @"ok", @"message": @"Config updated successfully"};
      return;
    }
    }];
    sendJson(clientSock, configError ? 400 : 200, configResponse ?: @{@"status": @"error", @"message": configError.localizedDescription ?: @"Server stopped"});
    return;
  }

  sendJson(clientSock, 404, @{@"status": @"error", @"message": @"Not Found"});
}

@end
