// Exercise the actual built UI module without provider requests or user preferences.
#import "rig_ai_copilot.h"
#import "rig_local_tone_matcher.h"
#import "rig_riff_recorder.h"
#include "rig_ui_state.h"
#include <objc/runtime.h>
#include <dlfcn.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cstdio>
#import <Security/Security.h>

@protocol AIPrivate
- (void)finishRequest:(NSString*)requestID result:(RigAICopilotResult*)result error:(NSError*)error;
- (void)waitForPaths:(RigAICopilotResult*)result state:(RigUIState*)state
              alive:(std::shared_ptr<bool>)alive serials:(std::array<uint64_t, 4>)serials
             before:(RigPreset*)before deadline:(NSDate*)deadline completion:(void (^)(NSError*))completion;
- (void)sendPrompt:(NSString*)userMessage systemPrompt:(NSString*)systemPrompt config:(RigAIConfig*)config
         localCLI:(NSString*)localCLI audioClips:(NSArray*)clips requestID:(NSString*)requestID;
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
static NSDictionary* toneFixtureReply;
static NSMutableArray<NSDictionary*>* toneFixtureBodies;

@interface ToneFixtureProtocol : NSURLProtocol
@end
@implementation ToneFixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest*)request { return YES; }
+ (NSURLRequest*)canonicalRequestForRequest:(NSURLRequest*)request { return request; }
- (void)startLoading {
  NSData* body = self.request.HTTPBody;
  if (!body && self.request.HTTPBodyStream) {
    NSInputStream* stream = self.request.HTTPBodyStream;
    NSMutableData* bytes = [NSMutableData data];
    [stream open]; uint8_t buffer[4096]; NSInteger n;
    while ((n = [stream read:buffer maxLength:sizeof(buffer)]) > 0) [bytes appendBytes:buffer length:n];
    [stream close]; body = bytes;
  }
  NSDictionary* parsed = body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil;
  NSDictionary* reply;
  @synchronized(ToneFixtureProtocol.class) {
    [toneFixtureBodies addObject:parsed ?: @{}]; reply = toneFixtureReply;
  }
  NSHTTPURLResponse* response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200
      HTTPVersion:@"HTTP/1.1" headerFields:nil];
  [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
  [self.client URLProtocol:self didLoadData:[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil]];
  [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

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
    // Paired recording must ignore bypassed stages with stale engine paths,
    // but still block enabled stages (including an outstanding unload).
    state.selectedPaths[0] = "/Pedal/new.nam";
    state.confirmedPaths[0] = "/Pedal/old.nam";
    state.confirmedPaths[3] = "/Cab/old.wav";
    CHECK(state.unconfirmedRecordingStage() == -1);
    state.powerButtons[0].state = NSControlStateValueOn;
    CHECK(state.unconfirmedRecordingStage() == 0);
    state.confirmedPaths[0] = state.selectedPaths[0];
    CHECK(state.unconfirmedRecordingStage() == -1);
    state.powerButtons[3].state = NSControlStateValueOn;
    CHECK(state.unconfirmedRecordingStage() == 3);
    state.selectedPaths[3] = state.confirmedPaths[3];
    CHECK(state.unconfirmedRecordingStage() == -1);
    state.selectedPaths[1] = "/Amp/new.nam";
    state.powerButtons[1].state = NSControlStateValueOn;
    CHECK(state.unconfirmedRecordingStage() == 1);
    state.confirmedPaths[1] = state.selectedPaths[1];
    CHECK(state.unconfirmedRecordingStage() == -1);
    state.selectedPaths = {}; state.confirmedPaths = {};
    for (size_t i = 0; i < 4; ++i) state.powerButtons[i].state = NSControlStateValueOff;
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
    // A lost one-shot notification triggers Get polling, without retrying the
    // model load or the AI request. An empty Get snapshot is not load rejection.
    state.confirmedPaths[1].clear();
    __block BOOL refreshedLoad = NO;
    [copilot applyResult:result toState:&state completionHandler:^(NSError* failure) {
      CHECK(!failure); refreshedLoad = YES;
    }];
    int beforeRefresh = writes;
    [copilot setValue:[NSDate distantPast] forKey:@"nextPathStatusRefresh"];
    drain();
    CHECK(writes == beforeRefresh + 1 && !refreshedLoad && copilot.isApplying);
    CHECK([[copilot valueForKey:@"pathStatusRefreshRequested"] boolValue]);
    ++state.pathResponseSerial[1]; // Engine still has no amp while the load is pending.
    drain();
    CHECK(!refreshedLoad && copilot.isApplying);
    state.confirmedPaths[1] = model.fileSystemRepresentation; ++state.pathResponseSerial[1];
    drain();
    CHECK(refreshedLoad && !copilot.isApplying);
    // Timeout diagnostics identify the unresolved stage and the actual engine
    // path, and rollback is preserved. Use an expired deadline, not a 10s sleep.
    RigPreset* timeoutBefore = [presetClass defaultPreset];
    state.confirmedPaths[1] = "/previous/amp.nam";
    const auto timeoutSerials = state.pathResponseSerial;
    __block BOOL timedOut = NO;
    [(id<AIPrivate>)copilot waitForPaths:result state:&state alive:state.isAlive serials:timeoutSerials
        before:timeoutBefore deadline:[NSDate distantPast] completion:^(NSError* failure) {
      CHECK(failure && [failure.localizedDescription containsString:@"Amp: requested broken.nam"]);
      CHECK([failure.localizedDescription containsString:@"engine reports amp.nam"]);
      timedOut = YES;
    }];
    CHECK(timedOut && state.selectedPaths[1].empty());
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
    // Exercise the actual Record action: stale bypassed paths must not block
    // pre-roll, while an enabled amp mismatch names the stage and sends Get.
    {
      state.confirmedPaths[3] = "/Cab/stale.wav";
      state.powerButtons[3].state = NSControlStateValueOff;
      [controller performSelector:@selector(toggleCopilotRecordRiff:) withObject:nil];
      CHECK([[controller valueForKey:@"copilotRecordCountdown"] integerValue] == 3);
      CHECK([[[controller valueForKey:@"copilotOutputView"] string] containsString:@"FREE TAKE"]);
      [controller performSelector:@selector(toggleCopilotRecordRiff:) withObject:nil];
      CHECK([[controller valueForKey:@"copilotRecordCountdown"] integerValue] == 0);
      state.selectedPaths[1] = model.fileSystemRepresentation;
      state.powerButtons[1].state = NSControlStateValueOn;
      int previousWrites = writes;
      [controller performSelector:@selector(toggleCopilotRecordRiff:) withObject:nil];
      CHECK(writes == previousWrites + 1);
      CHECK([[[controller valueForKey:@"copilotOutputView"] string] containsString:@"Recording blocked: Amp"]);
      CHECK([[controller valueForKey:@"copilotRecordCountdown"] integerValue] == 0);
      state.selectedPaths[1].clear(); state.confirmedPaths[3].clear();
    }
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
    // Local finalists become normal frozen proposals without an AI request,
    // and Apply & Save preserves local provenance despite cloud UI settings.
    {
      RigPreset* localBase = [presetClass captureFromState:&state name:state.presetManager.currentPresetName ?: @"Current rig"];
      RigPreset* localPreset = [presetClass captureFromState:&state name:@"Local candidate"];
      [localPreset setControl:12 value:-1];
      localPreset.aiMetadata = [@{@"provider":@"local", @"model":@"ridge-surrogate-v1", @"run_id":@"fixture-run",
          @"training_file":@"fixture.json", @"token_cost":@0} mutableCopy];
      RigLocalToneMatch* localMatch = [NSClassFromString(@"RigLocalToneMatch") new];
      localMatch.preset = localPreset; localMatch.score = .5;
      NSPopUpButton* finalists = [[NSPopUpButton alloc] initWithFrame:NSZeroRect];
      [finalists addItemWithTitle:@"#1"];
      [controller setValue:finalists forKey:@"copilotMatchCandidates"];
      [controller setValue:@[localMatch] forKey:@"copilotLocalMatches"];
      [controller setValue:localBase forKey:@"copilotBasePreset"];
      [controller setValue:[copilotClass contextForPreset:localBase compact:NO] forKey:@"copilotBaseContext"];
      [controller performSelector:@selector(selectCopilotLocalMatch:) withObject:nil];
      RigAICopilotResult* localProposal = [controller valueForKey:@"copilotProposal"];
      CHECK(localProposal.proposedPreset == localPreset && localProposal.tokenCost == 0);
      CHECK(localProposal.controls[@"bass"].floatValue == -1);
      CHECK([[[controller valueForKey:@"copilotOutputView"] string] containsString:@"LOCAL PREVIEW READY"]);
      [controller performSelector:@selector(applyCopilotProposal:) withObject:nil];
      CHECK([state.presetManager.presetNames containsObject:@"Local Match test tone"]);
      RigPreset* localSaved = [state.presetManager loadPresetNamed:@"Local Match test tone"];
      CHECK([localSaved.aiMetadata[@"provider"] isEqual:@"local"]);
      CHECK([localSaved.aiMetadata[@"run_id"] isEqual:@"fixture-run"]);
      CHECK([localSaved.aiMetadata[@"token_cost"] doubleValue] == 0);
      [controller setValue:nil forKey:@"copilotBaseContext"];
      [controller setValue:nil forKey:@"copilotBasePreset"];
      [controller setValue:nil forKey:@"copilotLocalMatches"];
    }
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
    // Exercise real request construction and HTTP completion against an
    // in-memory transport. No provider calls, user keys, or paid retries.
    NSURLSessionConfiguration* transportConfig = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    transportConfig.protocolClasses = @[ToneFixtureProtocol.class];
    NSURLSession* transport = [NSURLSession sessionWithConfiguration:transportConfig];
    [copilot setValue:transport forKey:@"networkSession"];
    toneFixtureBodies = [NSMutableArray array];
    NSString* completeJSON = @"{\"preset_name\":\"Test\",\"controls\":{\"bass\":-2}}";
    for (NSString* provider in @[@"claude", @"openai", @"gemini", @"custom", @"truncated-claude"]) {
      BOOL truncated = [provider hasPrefix:@"truncated"];
      NSString* actualProvider = truncated ? @"claude" : provider;
      RigAIConfig* requestConfig = [configClass defaultConfig];
      requestConfig.provider = actualProvider; requestConfig.apiKey = @"fixture-only";
      requestConfig.model = [actualProvider isEqual:@"claude"] ? @"claude-opus-5-5" :
          ([actualProvider isEqual:@"gemini"] ? @"gemini-test" : @"gpt-4o");
      requestConfig.baseURL = @"https://fixture.invalid/v1";
      NSDictionary* reply;
      if ([actualProvider isEqual:@"claude"]) {
        reply = @{@"content":@[@{@"type":@"text", @"text":truncated ? @"```json\n{\"controls\":" :
            [@"```json\n" stringByAppendingString:completeJSON]}],
            @"stop_reason":truncated ? @"max_tokens" : @"end_turn",
            @"usage":@{@"input_tokens":@100, @"output_tokens":truncated ? @8192 : @50}};
      } else if ([actualProvider isEqual:@"gemini"]) {
        reply = @{@"candidates":@[@{@"content":@{@"parts":@[@{@"text":completeJSON}]}, @"finishReason":@"STOP"}],
            @"usageMetadata":@{@"promptTokenCount":@100, @"candidatesTokenCount":@50}};
      } else {
        reply = @{@"choices":@[@{@"message":@{@"content":completeJSON}, @"finish_reason":@"stop"}],
            @"usage":@{@"prompt_tokens":@100, @"completion_tokens":@50}};
      }
      @synchronized(ToneFixtureProtocol.class) { toneFixtureReply = reply; }
      NSString* requestID = NSUUID.UUID.UUIDString;
      [copilot setValue:requestID forKey:@"requestID"];
      [copilot setValue:@YES forKey:@"isProcessing"];
      __block int requestCompletions = 0;
      [copilot setValue:[^(RigAICopilotResult* response, NSError* failure) {
        ++requestCompletions;
        if (truncated) CHECK(!response && [failure.localizedDescription containsString:@"output-token limit"]);
        else CHECK(response && !failure && response.controls[@"bass"].floatValue == -2);
      } copy] forKey:@"pendingCompletion"];
      NSUInteger requestsBefore = toneFixtureBodies.count;
      NSArray* clips = [actualProvider isEqual:@"gemini"] ? @[@{@"label":@"DI", @"mime":@"audio/wav", @"data":NSData.data}] : @[];
      [(id<AIPrivate>)copilot sendPrompt:@"test" systemPrompt:@"return JSON" config:requestConfig
          localCLI:nil audioClips:clips requestID:requestID];
      NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:5];
      while (!requestCompletions && deadline.timeIntervalSinceNow > 0) drain();
      CHECK(requestCompletions == 1 && !copilot.isProcessing);
      CHECK(toneFixtureBodies.count == requestsBefore + 1);
      NSDictionary* body = toneFixtureBodies.lastObject;
      NSNumber* limit = [actualProvider isEqual:@"gemini"] ? body[@"generationConfig"][@"maxOutputTokens"] :
          ([actualProvider isEqual:@"openai"] ? body[@"max_completion_tokens"] : body[@"max_tokens"]);
      CHECK(limit.unsignedIntegerValue == 8192);
    }
    [copilot setValue:nil forKey:@"networkSession"];
    [transport invalidateAndCancel];
    // Full Learn & Match UI workflow with an injected local renderer and an
    // isolated reference: no providers, downloads, or actual live rig writes.
    {
      Class matcherClass = NSClassFromString(@"RigLocalToneMatcher");
      method_setImplementation(class_getClassMethod(matcherClass, @selector(trainingDirectory)), (IMP)isolatedPresets);
      Class recorderClass = NSClassFromString(@"RigRiffRecorder");
      RigRiffRecorder* recorder = [recorderClass sharedRecorder];
      auto pushPair = reinterpret_cast<void (*)(const float*, const float*, const float*, uint32_t, double, uint32_t)>(dlsym(library, "rigRiffRecorderPushPair"));
      CHECK(pushPair);
      std::vector<float> input(24000);
      for (size_t i = 0; i < input.size(); ++i) input[i] = .1f * std::sin(2 * M_PI * 220 * i / 48000);
      [recorder startRecording];
      pushPair(input.data(), input.data(), input.data(), input.size(), 48000, 0);
      [recorder stopRecording];
      NSURL* targetFile = [NSURL fileURLWithPath:[presetRoot stringByAppendingPathComponent:@"target.wav"]];
      [recorder.recordedWavData writeToURL:targetFile atomically:YES];
      CHECK([recorder loadReferenceFromURL:targetFile fullMix:NO error:nil]);
      recorder.renderHandler = ^NSData*(RigPreset* preset, NSData* di, double rate, NSError** error) {
        std::vector<float> output(di.length / sizeof(float) * 2);
        const auto* raw = static_cast<const float*>(di.bytes);
        for (size_t i = 0; i < output.size() / 2; ++i) output[i * 2] = output[i * 2 + 1] = raw[i];
        return [NSData dataWithBytes:output.data() length:output.size() * sizeof(float)];
      };
      state.selectedPaths[1] = model.fileSystemRepresentation;
      state.confirmedPaths[1] = state.selectedPaths[1];
      NSString* fixtureCab = [libraryRoot stringByAppendingPathComponent:@"Cab/Test/mic.wav"];
      [NSFileManager.defaultManager createDirectoryAtPath:fixtureCab.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
      [@"local fixture" writeToFile:fixtureCab atomically:YES encoding:NSUTF8StringEncoding error:nil];
      state.selectedPaths[2] = fixtureCab.fileSystemRepresentation;
      state.confirmedPaths[2] = state.selectedPaths[2];
      state.powerButtons[1].state = NSControlStateValueOn;
      [controller setValue:[NSProgressIndicator new] forKey:@"copilotSpinner"];
      [controller setValue:[NSButton checkboxWithTitle:@"online" target:nil action:nil] forKey:@"copilotMatchOnlineButton"];
      int writesBefore = writes;
      [controller performSelector:@selector(matchCopilotLocally:) withObject:nil];
      CHECK([[controller valueForKey:@"copilotLocalMatching"] boolValue]);
      NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:10];
      while ([[controller valueForKey:@"copilotLocalMatching"] boolValue] && deadline.timeIntervalSinceNow > 0) drain();
      CHECK(![[controller valueForKey:@"copilotLocalMatching"] boolValue]);
      CHECK(writes == writesBefore && state.selectedPaths[1] == model.fileSystemRepresentation);
      NSArray* results = [controller valueForKey:@"copilotLocalMatches"];
      if (!results.count) std::fprintf(stderr, "Local UI log: %s\n", [[[controller valueForKey:@"copilotOutputView"] string] UTF8String]);
      CHECK(results.count > 0);
      RigAICopilotResult* local = [controller valueForKey:@"copilotProposal"];
      CHECK(local.proposedPreset && [local.proposedPreset.aiMetadata[@"provider"] isEqual:@"local"]);
      CHECK(local.tokenCost == 0);
      CHECK([[[controller valueForKey:@"copilotOutputView"] string] containsString:@"LOCAL PREVIEW READY"]);
      [recorder clearRecording]; [recorder clearReference]; recorder.renderHandler = nil;
      state.selectedPaths[1].clear(); state.confirmedPaths[1].clear();
      state.selectedPaths[2].clear(); state.confirmedPaths[2].clear();
    }
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
