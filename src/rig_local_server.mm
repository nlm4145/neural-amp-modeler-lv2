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

#import "rig_ai_copilot.h"
#import "rig_control_metadata.h"
#import "rig_presets.h"
#import "rig_ui_state.h"

extern NSDictionary<NSString*, NSNumber*>* rigSymbolToPortMap();
extern NSDictionary<NSNumber*, NSString*>* rigPortToSymbolMap();

static void sendHttpResponse(int clientSock, int statusCode, const char* statusText, const char* contentType, NSData* bodyData) {
  NSMutableString* headers = [NSMutableString stringWithFormat:
    @"HTTP/1.1 %d %s\r\n"
    @"Content-Type: %s; charset=utf-8\r\n"
    @"Content-Length: %lu\r\n"
    @"Access-Control-Allow-Origin: *\r\n"
    @"Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
    @"Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
    @"Connection: close\r\n\r\n",
    statusCode, statusText, contentType, (unsigned long)bodyData.length];
  NSData* headerData = [headers dataUsingEncoding:NSUTF8StringEncoding];
  send(clientSock, headerData.bytes, headerData.length, 0);
  if (bodyData.length > 0) {
    send(clientSock, bodyData.bytes, bodyData.length, 0);
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

static void sendOptions(int clientSock) {
  const char* resp =
    "HTTP/1.1 204 No Content\r\n"
    "Access-Control-Allow-Origin: *\r\n"
    "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
    "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
    "Connection: close\r\n\r\n";
  send(clientSock, resp, strlen(resp), 0);
}

@interface RigLocalServer () {
  int _serverSock;
  std::thread _workerThread;
  std::atomic<bool> _shouldStop;
}
@property(nonatomic, assign) BOOL isRunning;
@property(nonatomic, assign) uint16_t port;
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

  _serverSock = socket(AF_INET, SOCK_STREAM, 0);
  if (_serverSock < 0) return NO;

  int yes = 1;
  setsockopt(_serverSock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#ifdef SO_REUSEPORT
  setsockopt(_serverSock, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes));
#endif

  struct sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons(port);

  if (bind(_serverSock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
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

  if (_serverSock >= 0) {
    shutdown(_serverSock, SHUT_RDWR);
    close(_serverSock);
    _serverSock = -1;
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

    // Set timeout on client socket so it doesn't hang indefinitely
    struct timeval tv{5, 0};
    setsockopt(clientSock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
    setsockopt(clientSock, SOL_SOCKET, SO_SNDTIMEO, (const char*)&tv, sizeof(tv));

    @autoreleasepool {
      [self handleClientSocket:clientSock];
    }
    close(clientSock);
  }
}

- (void)handleClientSocket:(int)clientSock {
  std::vector<char> reqBuffer(65536, 0);
  ssize_t bytesRead = recv(clientSock, reqBuffer.data(), reqBuffer.size() - 1, 0);
  if (bytesRead <= 0) return;

  reqBuffer[bytesRead] = '\0';
  NSString* reqString = [NSString stringWithUTF8String:reqBuffer.data()];
  if (!reqString.length) return;

  NSScanner* scanner = [NSScanner scannerWithString:reqString];
  NSString* method = nil;
  NSString* fullPath = nil;
  [scanner scanUpToCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:&method];
  [scanner scanCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:NULL];
  [scanner scanUpToCharactersFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet] intoString:&fullPath];

  if (!method.length || !fullPath.length) return;

  if ([method.uppercaseString isEqualToString:@"OPTIONS"]) {
    sendOptions(clientSock);
    return;
  }

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
  NSRange headerEnd = [reqString rangeOfString:@"\r\n\r\n"];
  if (headerEnd.location != NSNotFound) {
    NSString* bodyStr = [reqString substringFromIndex:headerEnd.location + headerEnd.length];
    if (bodyStr.length > 0) {
      NSData* bodyData = [bodyStr dataUsingEncoding:NSUTF8StringEncoding];
      bodyJson = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
    }
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
    dispatch_sync(dispatch_get_main_queue(), ^{
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
    });

    sendJson(clientSock, 200, stateDict);
    return;
  }

  if ([path isEqualToString:@"/api/v1/controls"]) {
    if (![bodyJson isKindOfClass:[NSDictionary class]]) {
      sendJson(clientSock, 400, @{@"status": @"error", @"message": @"Expected JSON object of control key-values"});
      return;
    }

    __block NSMutableArray<NSString*>* updated = [NSMutableArray array];
    dispatch_sync(dispatch_get_main_queue(), ^{
      RigUIState* state = RigUIState::activeState();
      if (!state) return;

      NSDictionary<NSString*, NSNumber*>* symMap = rigSymbolToPortMap();
      for (NSString* key in bodyJson) {
        NSNumber* portNum = symMap[key];
        uint32_t port = 0;
        if (portNum) {
          port = portNum.unsignedIntValue;
        } else {
          // Check if numeric port was passed directly
          port = (uint32_t)[key integerValue];
        }

        if (port > 0) {
          float val = [bodyJson[key] floatValue];
          state->sendControl(port, val);
          state->updateControl(port, val);
          [updated addObject:key];
        }
      }
      state->markModified();
    });

    sendJson(clientSock, 200, @{@"status": @"ok", @"updated": updated});
    return;
  }

  if ([path isEqualToString:@"/api/v1/models/load"]) {
    NSString* modelPath = bodyJson[@"path"];
    NSString* amp = bodyJson[@"amp"];
    NSString* cab = bodyJson[@"cab"];
    NSNumber* stageNum = bodyJson[@"stage"];

    __block NSMutableArray<NSString*>* loaded = [NSMutableArray array];
    dispatch_sync(dispatch_get_main_queue(), ^{
      RigUIState* state = RigUIState::activeState();
      if (!state) return;

      auto resolveAndLoad = ^(size_t stIdx, NSString* target) {
        if (!target.length) return;
        NSString* rootLib = [@"~/Music/Tone3000 Library" stringByExpandingTildeInPath];
        NSFileManager* fm = [NSFileManager defaultManager];
        NSString* fullPath = target;
        if (![fm fileExistsAtPath:fullPath]) {
          NSString* sub = (stIdx == 1) ? @"Amp" : (stIdx == 2 || stIdx == 3) ? @"Cabinet" : @"Pedal";
          fullPath = [[rootLib stringByAppendingPathComponent:sub] stringByAppendingPathComponent:target];
        }
        if (![fm fileExistsAtPath:fullPath]) {
          // Fuzzy search by filename
          NSDirectoryEnumerator* en = [fm enumeratorAtPath:rootLib];
          NSString* rel = nil;
          while ((rel = [en nextObject])) {
            if ([rel.lastPathComponent.lowercaseString isEqualToString:target.lastPathComponent.lowercaseString]) {
              fullPath = [rootLib stringByAppendingPathComponent:rel];
              break;
            }
          }
        }

        if ([fm fileExistsAtPath:fullPath]) {
          std::string cpp = fullPath.fileSystemRepresentation;
          if (stIdx == 1) {
            std::vector<std::string> models = discoverModelsForStagePath(cpp, 1);
            if (std::find(models.begin(), models.end(), cpp) == models.end()) models.push_back(cpp);
            NSMutableArray<NSString*>* mPaths = [NSMutableArray array];
            for (const auto& m : models) [mPaths addObject:[NSString stringWithUTF8String:m.c_str()]];
            state->setStageModels(1, mPaths);
          }
          state->sendPath(stIdx, cpp.c_str());
          [loaded addObject:fullPath.lastPathComponent];
        }
      };

      if (modelPath.length && stageNum) {
        resolveAndLoad(stageNum.unsignedIntegerValue, modelPath);
      }
      if (amp.length) resolveAndLoad(1, amp);
      if (cab.length) resolveAndLoad(2, cab);
      state->markModified();
    });

    sendJson(clientSock, 200, @{@"status": @"ok", @"loaded": loaded});
    return;
  }

  if ([path isEqualToString:@"/api/v1/presets"]) {
    __block NSDictionary* resp = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      RigPresetManager* pm = [RigPresetManager sharedManager];
      [pm rescanPresets];
      resp = @{
        @"status": @"ok",
        @"current": pm.currentPresetName ?: @"",
        @"presets": pm.presetNames ?: @[]
      };
    });
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
    dispatch_sync(dispatch_get_main_queue(), ^{
      RigUIState* state = RigUIState::activeState();
      if (state) {
        state->applyPresetByName(name);
        ok = YES;
      }
    });

    sendJson(clientSock, ok ? 200 : 500, @{@"status": ok ? @"ok" : @"error", @"loaded": name});
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
    dispatch_sync(dispatch_get_main_queue(), ^{
      RigUIState* state = RigUIState::activeState();
      if (state) {
        ok = [[RigPresetManager sharedManager] savePresetNamed:name fromState:state error:&saveErr];
      }
    });

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
          unsigned long long sz = [attrs fileSize] / 1024;
          [results addObject:@{
            @"name": rel.lastPathComponent,
            @"path": full,
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

    // Call In-App Copilot asynchronously
    __block RigUIState* state = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      state = RigUIState::activeState();
    });

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block RigAICopilotResult* aiResult = nil;
    __block NSError* aiError = nil;

    [[RigAICopilot sharedCopilot] processUserPrompt:prompt
                                          withState:state
                                  completionHandler:^(RigAICopilotResult* res, NSError* err) {
                                    aiResult = res;
                                    aiError = err;
                                    dispatch_semaphore_signal(sema);
                                  }];

    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_SEC));

    if (aiError || !aiResult) {
      sendJson(clientSock, 500, @{
        @"status": @"error",
        @"message": aiError.localizedDescription ?: @"AI request timed out or returned no result."
      });
      return;
    }

    if (apply && state) {
      dispatch_sync(dispatch_get_main_queue(), ^{
        [[RigAICopilot sharedCopilot] applyResult:aiResult toState:state saveUndoState:YES error:nil];
      });
    }

    sendJson(clientSock, 200, @{
      @"status": @"ok",
      @"thought": aiResult.thought ?: @"",
      @"explanation": aiResult.explanation ?: @"",
      @"controls": aiResult.controls ?: @{},
      @"amp_model": aiResult.ampPath ?: @"",
      @"cab_ir": aiResult.cabPath ?: @"",
      @"applied": @(apply)
    });
    return;
  }

  if ([path isEqualToString:@"/api/v1/ai/config"]) {
    RigAIConfig* cfg = [RigAICopilot sharedCopilot].config;
    if ([method.uppercaseString isEqualToString:@"GET"]) {
      NSString* key = cfg.apiKey ?: @"";
      NSString* masked = key.length > 8
          ? [NSString stringWithFormat:@"%@...%@", [key substringToIndex:4], [key substringFromIndex:key.length - 4]]
          : (key.length ? @"****" : @"");
      sendJson(clientSock, 200, @{
        @"provider": cfg.provider ?: @"gemini",
        @"model": cfg.model ?: @"",
        @"base_url": cfg.baseURL ?: @"",
        @"temperature": @(cfg.temperature),
        @"api_key_masked": masked,
        @"has_key": @(cfg.effectiveApiKey.length > 0)
      });
      return;
    } else if ([method.uppercaseString isEqualToString:@"POST"]) {
      if (bodyJson[@"provider"]) cfg.provider = bodyJson[@"provider"];
      if (bodyJson[@"api_key"]) cfg.apiKey = bodyJson[@"api_key"];
      if (bodyJson[@"model"]) cfg.model = bodyJson[@"model"];
      if (bodyJson[@"base_url"]) cfg.baseURL = bodyJson[@"base_url"];
      if (bodyJson[@"temperature"]) cfg.temperature = [bodyJson[@"temperature"] floatValue];
      [cfg saveToDisk:nil];
      sendJson(clientSock, 200, @{@"status": @"ok", @"message": @"Config updated successfully"});
      return;
    }
  }

  sendJson(clientSock, 404, @{@"status": @"error", @"message": @"Not Found"});
}

@end
