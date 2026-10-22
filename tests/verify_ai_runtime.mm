// Exercise the actual built UI module without provider requests or user preferences.
#import "rig_ai_copilot.h"
#include "rig_ui_state.h"
#include <objc/runtime.h>
#include <dlfcn.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cstdio>
#import <Security/Security.h>

@protocol AIPrivate
- (void)finishRequest:(NSString*)requestID result:(RigAICopilotResult*)result error:(NSError*)error;
@end
@protocol LocalPrivate
- (void)handleClientSocket:(int)socket;
@end
@protocol ControllerPrivate
- (void)setState:(RigUIState*)state;
- (void)refreshCopilotModelsUIForced:(BOOL)force;
@end

static int failures = 0;
#define CHECK(x) do { if (!(x)) { ++failures; std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); } } while (0)
static void drain() { [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]; }
static NSString* configPath;
static NSString* libraryRoot;
static NSString* presetRoot;
static NSString* isolatedPresets(id, SEL) { return presetRoot; }
static NSString* isolatedCurrentPreset(id, SEL) { return [presetRoot stringByAppendingPathComponent:@"current.txt"]; }
static NSString* isolatedLibrary(id, SEL) { return libraryRoot; }
static NSString* isolatedConfig(id, SEL) { return configPath; }
static id skipConfigLoad(id, SEL) { return nil; }
static NSMutableArray* modelCallbacks;
static NSString* discoveryProvider;
static NSString* discoveryKey;
static NSString* discoveryURL;
static BOOL discoveryForce;
static void captureModelDiscovery(id, SEL, NSString* provider, NSString* key, NSString* url, BOOL force,
                                  void (^callback)(NSArray*, NSError*)) {
  discoveryProvider = provider; discoveryKey = key; discoveryURL = url; discoveryForce = force;
  [modelCallbacks addObject:[callback copy]];
}
static id isolatedKeychain(id, SEL, id) {
  return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
           (__bridge id)kSecAttrService: @"Axe FX AI Test", (__bridge id)kSecAttrAccount: configPath};
}
static void writeControl(LV2UI_Controller handle, uint32_t, uint32_t, uint32_t, const void*) { ++*static_cast<int*>(handle); }

int main(int argc, char** argv) {
  @autoreleasepool {
    CHECK(argc == 3);
    if (argc != 3) return 1;
    void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    CHECK(library);
    if (!library) { std::fprintf(stderr, "%s\n", dlerror()); return 1; }
    Class configClass = NSClassFromString(@"RigAIConfig");
    Class copilotClass = NSClassFromString(@"RigAICopilot");
    Class presetClass = NSClassFromString(@"RigPreset");
    configPath = [[NSString stringWithUTF8String:argv[2]] stringByAppendingPathComponent:@"config.json"];
    libraryRoot = [[NSString stringWithUTF8String:argv[2]] stringByAppendingPathComponent:@"Library"];
    presetRoot = [[NSString stringWithUTF8String:argv[2]] stringByAppendingPathComponent:@"Presets"];
    [NSFileManager.defaultManager createDirectoryAtPath:presetRoot withIntermediateDirectories:YES attributes:nil error:nil];
    Class managerClass = NSClassFromString(@"RigPresetManager");
    method_setImplementation(class_getInstanceMethod(managerClass, @selector(presetsDirectory)), (IMP)isolatedPresets);
    method_setImplementation(class_getInstanceMethod(managerClass, NSSelectorFromString(@"currentPresetFilePath")), (IMP)isolatedCurrentPreset);
    method_setImplementation(class_getClassMethod(copilotClass, NSSelectorFromString(@"libraryRootPath")), (IMP)isolatedLibrary);
    method_setImplementation(class_getClassMethod(configClass, @selector(configFilePath)), (IMP)isolatedConfig);
    method_setImplementation(class_getClassMethod(configClass, @selector(loadFromDisk)), (IMP)skipConfigLoad);
    method_setImplementation(class_getClassMethod(configClass, NSSelectorFromString(@"keychainQueryForProvider:")), (IMP)isolatedKeychain);
    RigAICopilot* copilot = [copilotClass new];
    RigUIState state;
    int writes = 0;
    state.write = writeControl;
    state.controller = &writes;
    for (size_t i = 0; i < kRigKnobCount; ++i) {
      state.knobs[i] = [[NSSlider alloc] initWithFrame:NSZeroRect];
      state.knobs[i].minValue = -100;
      state.knobs[i].maxValue = 20000;
      state.knobs[i].floatValue = kRigKnobDefaults[i];
    }
    for (size_t i = 0; i < 4; ++i) state.powerButtons[i] = [[NSButton alloc] initWithFrame:NSZeroRect];
    state.stageOsPopup[1] = [[NSPopUpButton alloc] initWithFrame:NSZeroRect];
    [state.stageOsPopup[1] addItemsWithTitles:@[@"off", @"2", @"4", @"8", @"16"]];
    state.irNormPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect];
    [state.irNormPopup addItemsWithTitles:@[@"peak", @"loudness"]];
    state.speakerProfilePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect];
    for (int i = 0; i < 8; ++i) [state.speakerProfilePopup addItemWithTitle:[NSString stringWithFormat:@"%d", i]];
    RigAICopilotResult* result = [NSClassFromString(@"RigAICopilotResult") new];
    result.controls = @{@"bass": @-2, @"od_tone": @62, @"compressor_enabled": @0, @"od_enabled": @0,
                        @"speaker_profile": @6, @"amp_oversample": @7, @"ir_normalization": @2, @"cab_enabled": @1, @"input_level": @3};
    NSError* error = nil;
    CHECK([copilot applyResult:result toState:&state saveUndoState:YES error:&error]);
    CHECK(copilot.canUndo && writes == 9);
    RigPreset* captured = [presetClass captureFromState:&state name:@"test"];
    CHECK([captured controlForPort:12] == -2 && [captured controlForPort:180] == 62);
    CHECK([captured controlForPort:4] == 3);
    CHECK([captured controlForPort:184] == 0 && [captured controlForPort:185] == 0);
    CHECK([captured controlForPort:21] == 7 && [captured controlForPort:24] == 2 && [captured controlForPort:9] == 1);
    CHECK([copilot undoLastAIApplicationToState:&state error:nil]);
    CHECK(state.compressorEnabled == 1 && state.boostEnabled == 1 && copilot.canUndo);
    CHECK([copilot undoLastAIApplicationToState:&state error:nil]);
    CHECK(state.compressorEnabled == 0 && state.boostEnabled == 0 && copilot.canUndo);
    int before = writes;
    result.controls = @{@"bass": @20};
    CHECK(![copilot applyResult:result toState:&state saveUndoState:YES error:nil] && writes == before);
    result.controls = @{@"bass": @1}; result.ampPath = @"Amp/does-not-exist.nam";
    CHECK(![copilot applyResult:result toState:&state saveUndoState:YES error:nil] && writes == before);
    result.ampPath = nil;
    __block BOOL applied = NO;
    [copilot applyResult:result toState:&state completionHandler:^(NSError* failure) { CHECK(!failure); applied = YES; }];
    CHECK(applied);
    // Model application does not report success until a new engine acknowledgement arrives.
    NSString* model = [[NSString stringWithUTF8String:argv[2]] stringByAppendingPathComponent:@"Library/Amp/Test/broken.nam"];
    [NSFileManager.defaultManager createDirectoryAtPath:model.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [@"invalid NAM fixture" writeToFile:model atomically:YES encoding:NSUTF8StringEncoding error:nil];
    result.ampPath = @"Amp/Test/broken.nam";
    __block BOOL failedLoad = NO;
    [copilot applyResult:result toState:&state completionHandler:^(NSError* failure) { CHECK(failure); failedLoad = YES; }];
    CHECK(!failedLoad);
    state.confirmedPaths[1] = ""; ++state.pathResponseSerial[1];
    drain();
    CHECK(failedLoad && state.selectedPaths[1].empty());
    result.ampPath = @"Amp/Test/broken.nam";
    __block BOOL confirmedLoad = NO;
    [copilot applyResult:result toState:&state completionHandler:^(NSError* failure) { CHECK(!failure); confirmedLoad = YES; }];
    CHECK(!confirmedLoad);
    state.confirmedPaths[1] = model.fileSystemRepresentation; ++state.pathResponseSerial[1];
    drain();
    CHECK(confirmedLoad);
    result.ampPath = nil;
    state.selectedPaths[1].clear();
    state.confirmedPaths[1].clear();
    // Build-from-scratch proposals carry a full proposedPreset where unused stages (e.g. pedal, cab B)
    // have empty paths that match the engine's already-empty confirmedPaths without a new serial bump.
    {
      RigPreset* scratchBase = [presetClass defaultPreset];
      RigAICopilotResult* scratchProposal = [NSClassFromString(@"RigAICopilotResult") new];
      scratchProposal.presetName = @"Scratch Test";
      scratchProposal.pedalPath = @"none";
      scratchProposal.ampPath = @"Amp/Test/broken.nam";
      scratchProposal.controls = @{@"bass": @0.5, @"pedal_enabled": @0};
      scratchProposal.proposedPreset = [copilotClass presetForResult:scratchProposal base:scratchBase error:&error];
      CHECK(scratchProposal.proposedPreset && !error);
      __block BOOL scratchDone = NO;
      [copilot applyResult:scratchProposal toState:&state completionHandler:^(NSError* failure) {
        CHECK(!failure);
        scratchDone = YES;
      }];
      CHECK(!scratchDone);
      // Only stage 1 (amp) changed from empty to a file; stages 0, 2, 3 remain empty (confirmedPaths == "").
      // An intermediate stale confirmation for a previous non-empty path must not be treated as a rejection.
      state.confirmedPaths[1] = "/tmp/previous_model.nam"; ++state.pathResponseSerial[1];
      drain();
      CHECK(!scratchDone);
      state.confirmedPaths[1] = model.fileSystemRepresentation; ++state.pathResponseSerial[1];
      drain();
      CHECK(scratchDone);
      state.selectedPaths[1].clear();
      state.confirmedPaths[1].clear();
    }
    // Exercise the real UI Apply & Save action and unique-name collision handling.
    state.presetManager = [managerClass sharedManager];
    id controller = [NSClassFromString(@"NAMRigUIController") new];
    [(id<ControllerPrivate>)controller setState:&state];
    NSTextField* promptField = [NSTextField new]; promptField.stringValue = @"test tone";
    [controller setValue:promptField forKey:@"copilotPromptInput"];
    [controller setValue:[NSTextView new] forKey:@"copilotOutputView"];
    RigAICopilotResult* proposal = [NSClassFromString(@"RigAICopilotResult") new];
    proposal.controls = @{@"bass": @-3}; proposal.presetName = @"AI Test"; proposal.explanation = @"test";
    [controller setValue:proposal forKey:@"copilotProposal"];
    [controller performSelector:@selector(applyCopilotProposal:) withObject:nil];
    CHECK([state.presetManager.presetNames containsObject:@"AI Test"]);
    NSString* log = [[controller valueForKey:@"copilotOutputView"] string];
    CHECK([log containsString:@"APPLY & SAVE started → target preset 'AI Test'"]);
    CHECK([log containsString:@"✅ DONE — preset 'AI Test'"] && [log containsString:@"AI Test.json"]);
    [controller setValue:proposal forKey:@"copilotProposal"];
    [controller performSelector:@selector(applyCopilotProposal:) withObject:nil];
    CHECK(state.presetManager.presetNames.count >= 3);
    CHECK([[[controller valueForKey:@"copilotOutputView"] string] containsString:@"✅ DONE — preset 'AI Test Copy'"]);
    // The Save as field names the preset exactly, and shows the final unique name after saving.
    NSTextField* nameField = [NSTextField new]; nameField.stringValue = @"  Mellencamp - Jack & Diane ";
    [controller setValue:nameField forKey:@"copilotPresetNameField"];
    [controller setValue:proposal forKey:@"copilotProposal"];
    [controller performSelector:@selector(applyCopilotProposal:) withObject:nil];
    CHECK([state.presetManager.presetNames containsObject:@"Mellencamp - Jack & Diane"]);
    CHECK([nameField.stringValue isEqual:@"Mellencamp - Jack & Diane"]);
    [controller setValue:nil forKey:@"copilotPresetNameField"];
    // Progress lines reach the handler during application.
    NSMutableArray<NSString*>* progress = [NSMutableArray array];
    copilot.progressHandler = ^(NSString* line) { [progress addObject:line]; };
    RigAICopilotResult* direct = [NSClassFromString(@"RigAICopilotResult") new];
    direct.controls = @{@"mid": @1};
    CHECK([copilot applyResult:direct toState:&state saveUndoState:NO error:nil]);
    CHECK(progress.count == 1 && [progress.firstObject containsString:@"Applying 1 control changes"]);
    direct.ampPath = @"none";
    error = nil;
    CHECK(![copilot applyResult:direct toState:&state saveUndoState:NO error:&error] && error);
    direct.ampPath = nil;
    copilot.progressHandler = nil;
    RigUIState other;
    CHECK(![copilot undoLastAIApplicationToState:&other error:nil]);
    state.activeState() = &state;
    // A cancelled request completes once. A stale provider callback cannot overwrite the next request.
    __block int completions = 0;
    [copilot setValue:@YES forKey:@"isProcessing"];
    [copilot setValue:@"old" forKey:@"requestID"];
    [copilot setValue:[^(RigAICopilotResult*, NSError* failure) { CHECK(failure); ++completions; } copy] forKey:@"pendingCompletion"];
    [copilot cancelProcessing];
    CHECK(!copilot.isProcessing && completions == 1);
    [(id<AIPrivate>)copilot finishRequest:@"old" result:nil error:nil];
    CHECK(completions == 1);
    // Saving with an empty key must never put plaintext secrets in JSON (isolated Keychain account).
    RigAIConfig* config = [configClass defaultConfig];
    CHECK(!config.sendAudio && !config.canSendAudio);
    config.apiKey = @"test-only"; config.provider = @"openai"; config.model = @"gpt-4o";
    CHECK(!config.canSendAudio);
    config.model = @"gpt-4o-audio-preview"; CHECK(config.canSendAudio);
    config.provider = @"claude"; CHECK(!config.canSendAudio);
    config.provider = @"gemini"; config.model = @"gemini-2.5-flash"; CHECK(config.canSendAudio);
    config.apiKey = @"";
    RigPreset* base = [presetClass defaultPreset];
    [base setControl:12 value:-4];
    RigAICopilotResult* candidate = [NSClassFromString(@"RigAICopilotResult") new];
    candidate.controls = @{@"mid":@2, @"cab_enabled":@0};
    RigPreset* composed = [copilotClass presetForResult:candidate base:base error:&error];
    CHECK(composed && [composed controlForPort:12] == -4 && [composed controlForPort:13] == 2);
    CHECK(![composed stageAtIndex:2]->enabled);
    // "none" removes a pedal capture and switches the Pedal stage off.
    [base stageAtIndex:0]->path = "/somewhere/Pedal/Old/old.nam";
    [base stageAtIndex:0]->toneId = 42;
    [base setControl:7 value:1];
    RigAICopilotResult* noPedal = [NSClassFromString(@"RigAICopilotResult") new];
    noPedal.controls = @{}; noPedal.pedalPath = @"none";
    RigPreset* withoutPedal = [copilotClass presetForResult:noPedal base:base error:&error];
    CHECK(withoutPedal && [withoutPedal stageAtIndex:0]->path.empty() && [withoutPedal stageAtIndex:0]->toneId == 0);
    CHECK([withoutPedal controlForPort:7] == 0 && ![withoutPedal stageAtIndex:0]->enabled);
    noPedal.pedalPath = @"Pedal/Missing/x.nam";
    CHECK(![copilotClass presetForResult:noPedal base:base error:nil]);
    [base stageAtIndex:0]->path.clear(); [base stageAtIndex:0]->toneId = 0;
    [base setControl:12 value:3]; CHECK([composed controlForPort:12] == -4);
    CHECK([[copilotClass contextForPreset:composed compact:YES][@"controls"][@"bass"] floatValue] == -4);
    candidate.proposedPreset = composed;
    CHECK([copilot applyResult:candidate toState:&state saveUndoState:YES error:&error]);
    RigPreset* recalled = [presetClass captureFromState:&state name:@"Frozen proposal"];
    CHECK([recalled controlForPort:12] == -4 && [recalled controlForPort:13] == 2);
    CHECK(![recalled stageAtIndex:2]->enabled);
    config.provider = @"custom"; config.baseURL = @"http://127.0.0.1:11434/v1";
    CHECK([config saveToDisk:&error]);
    NSDictionary* saved = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:configPath] options:0 error:nil];
    CHECK(!saved[@"api_key"]);
    config.baseURL = @"http://example.com/v1";
    CHECK(![config saveToDisk:nil]);
    RigAICopilot* singleton = [copilotClass sharedCopilot];
    CHECK(!singleton.config); // load was stubbed before either instance was initialized.
    NSArray* openAIStarters = [copilotClass defaultModelsForProvider:@"OpenAI"];
    CHECK([openAIStarters containsObject:@"gpt-6.1-sol"] && [openAIStarters containsObject:@"gpt-6-luna"]);
    // Exercise actual UI refresh wiring with injected completions; no provider requests.
    Method fetchMethod = class_getInstanceMethod(copilotClass, @selector(fetchModelsForProvider:apiKey:baseURL:forceRefresh:completionHandler:));
    IMP originalFetch = method_setImplementation(fetchMethod, (IMP)captureModelDiscovery);
    modelCallbacks = [NSMutableArray array];
    NSPopUpButton* providerPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect];
    [providerPopup addItemsWithTitles:@[@"Gemini", @"OpenAI", @"Claude"]];
    [providerPopup selectItemWithTitle:@"OpenAI"];
    NSComboBox* modelsBox = [NSComboBox new];
    [modelsBox addItemWithObjectValue:@"starter"]; modelsBox.stringValue = @"my-selected-model";
    NSSecureTextField* keyField = [NSSecureTextField new]; keyField.stringValue = @"unsaved-key";
    NSTextField* urlField = [NSTextField new]; urlField.stringValue = @"https://proxy.example/v1";
    NSTextField* modelsStatus = [NSTextField labelWithString:@""];
    NSButton* refreshButton = [NSButton new];
    [controller setValue:providerPopup forKey:@"copilotProvPopup"];
    [controller setValue:modelsBox forKey:@"copilotModelComboBox"];
    [controller setValue:keyField forKey:@"copilotKeyField"];
    [controller setValue:urlField forKey:@"copilotURLField"];
    [controller setValue:modelsStatus forKey:@"copilotModelsStatus"];
    [controller setValue:refreshButton forKey:@"copilotModelsRefreshBtn"];
    [(id<ControllerPrivate>)controller refreshCopilotModelsUIForced:YES];
    CHECK([discoveryProvider isEqual:@"openai"] && [discoveryKey isEqual:@"unsaved-key"]);
    CHECK([discoveryURL isEqual:@"https://proxy.example/v1"] && discoveryForce && !refreshButton.enabled);
    CHECK(!singleton.config); // Discovery did not mutate the tone request configuration.
    // A newer key refresh completes first. The old callback must not overwrite its list.
    keyField.stringValue = @"newer-key";
    [controller performSelector:@selector(copilotKeyFieldAction:) withObject:nil];
    CHECK(!discoveryForce && modelCallbacks.count == 2);
    void (^latestModels)(NSArray*, NSError*) = modelCallbacks.lastObject;
    latestModels(@[@"gpt-future", @"gpt-other"], nil);
    CHECK(refreshButton.enabled && [modelsBox.objectValues isEqual:(@[@"gpt-future", @"gpt-other"])]);
    CHECK([modelsBox.stringValue isEqual:@"my-selected-model"]);
    void (^oldModels)(NSArray*, NSError*) = modelCallbacks.firstObject;
    oldModels(@[@"stale-model"], nil);
    CHECK([modelsBox.objectValues isEqual:(@[@"gpt-future", @"gpt-other"])]);
    // Failed discovery keeps the current list and reports an actionable status.
    [controller performSelector:@selector(refreshCopilotModelsAction:) withObject:nil];
    latestModels = modelCallbacks.lastObject;
    latestModels(nil, [NSError errorWithDomain:@"test" code:401 userInfo:@{NSLocalizedDescriptionKey:@"Check API key"}]);
    CHECK([modelsStatus.stringValue containsString:@"Check API key"] && refreshButton.enabled);
    CHECK([modelsBox.stringValue isEqual:@"my-selected-model"] && modelsBox.numberOfItems == 2);
    // Click-away/Tab commits URL changes, and opening the dropdown checks freshness.
    urlField.stringValue = @"https://new-proxy.example/v1";
    [controller performSelector:@selector(controlTextDidEndEditing:) withObject:
        [NSNotification notificationWithName:NSControlTextDidEndEditingNotification object:urlField]];
    CHECK([discoveryURL isEqual:urlField.stringValue] && !discoveryForce);
    [controller performSelector:@selector(comboBoxWillPopUp:) withObject:
        [NSNotification notificationWithName:NSComboBoxWillPopUpNotification object:modelsBox]];
    CHECK(modelCallbacks.count == 5 && !discoveryForce);
    // Switching away before a callback arrives cannot inject another provider's models.
    latestModels = modelCallbacks.lastObject;
    [providerPopup selectItemWithTitle:@"Claude"];
    latestModels(@[@"wrong-provider"], nil);
    CHECK(modelsBox.numberOfItems == 2);
    method_setImplementation(fetchMethod, originalFetch);
    [modelCallbacks removeAllObjects];
    // Do not execute a user's CLI or send requests: completion/cancellation above use injected lifecycle state.
    // Raw socket route tests: no server startup/token writes, no live networking.
    id server = [NSClassFromString(@"RigLocalServer") new];
    [server setValue:@"test-token" forKey:@"authToken"];
    auto request = [&](NSString* headers, NSString* body) {
      int sockets[2]; CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
      int client = sockets[1];
      NSData* headerData = [headers dataUsingEncoding:NSUTF8StringEncoding];
      write(sockets[0], headerData.bytes, headerData.length);
      int writer = sockets[0];
      if (body.length) {
        NSData* bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
          write(writer, bodyData.bytes, bodyData.length);
        });
      }
      __block BOOL done = NO;
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [(id<LocalPrivate>)server handleClientSocket:client];
        close(client);
        dispatch_async(dispatch_get_main_queue(), ^{ done = YES; });
      });
      while (!done) drain();
      char buffer[32768]; ssize_t count = read(sockets[0], buffer, sizeof(buffer));
      close(sockets[0]);
      return [[NSString alloc] initWithBytes:buffer length:count > 0 ? count : 0 encoding:NSUTF8StringEncoding];
    };
    CHECK([request(@"GET /api/v1/ping HTTP/1.1\r\nHost: 127.0.0.1:48920\r\n\r\n", nil) containsString:@"401"]);
    CHECK([request(@"GET /api/v1/ping HTTP/1.1\r\nHost: evil.test\r\nAuthorization: Bearer test-token\r\n\r\n", nil) containsString:@"403"]);
    CHECK([request(@"GET /api/v1/ping HTTP/1.1\r\nHost: 127.0.0.1:48920\r\nOrigin: https://evil.test\r\nAuthorization: Bearer test-token\r\n\r\n", nil) containsString:@"403"]);
    CHECK([request(@"GET /api/v1/ping HTTP/1.1\r\nHost: 127.0.0.1:48920\r\nAuthorization: Bearer test-token\r\n\r\n", nil) containsString:@"200"]);
    CHECK([request(@"GET /api/v1/controls HTTP/1.1\r\nHost: 127.0.0.1:48920\r\nAuthorization: Bearer test-token\r\n\r\n", nil) containsString:@"405"]);
    CHECK([request(@"POST /api/v1/controls HTTP/1.1\r\nHost: 127.0.0.1:48920\r\nAuthorization: Bearer test-token\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n", @"{\"bass\":99}") containsString:@"400"]);
    // A valid control request fragmented between headers and body is fully received.
    CHECK([request(@"POST /api/v1/controls HTTP/1.1\r\nHost: 127.0.0.1:48920\r\nAuthorization: Bearer test-token\r\nContent-Type: application/json\r\nContent-Length: 10\r\n\r\n", @"{\"bass\":2}") containsString:@"200"]);
    std::printf("AI runtime: %d failures\n", failures);
  }
  return failures ? 1 : 0;
}
