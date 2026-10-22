// RigAICopilot — Universal AI Tone Copilot for Axe FX.
// macOS UI integration supporting OpenAI-compatible APIs, Gemini, Claude, and Ollama.
#pragma once

#import <Foundation/Foundation.h>

#ifdef __OBJC__

struct RigUIState;
@class RigPreset;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RigAITaskStatus) {
  RigAITaskStatusInProgress,
  RigAITaskStatusComplete,
  RigAITaskStatusFailed
};

@interface RigAIPresetTask : NSObject
@property(nonatomic, copy) NSString* taskId;
@property(nonatomic, copy) NSString* prompt;
@property(nonatomic, copy) NSString* summary; // e.g. "<Artist> - <Song>" or "<Artist> - <Album>"
@property(nonatomic) RigAITaskStatus status;
@property(nonatomic, copy, nullable) NSString* savedPresetName;
@property(nonatomic, copy, nullable) NSString* ampModel;
@property(nonatomic, copy, nullable) NSString* cabIR;
@property(nonatomic, copy, nullable) NSString* keyDials;
@property(nonatomic, copy, nullable) NSString* explanation;
@property(nonatomic, copy, nullable) NSString* errorMessage;
@property(nonatomic, copy) NSString* provider;
@property(nonatomic, copy) NSString* model;
@property(nonatomic, copy) NSString* executionMode;
@property(nonatomic, strong) NSDate* timestamp;

- (NSString*)displayText;
@end

@interface RigAIConfig : NSObject
@property(nonatomic, copy) NSString* provider;    // @"gemini", @"openai", @"claude", @"ollama", @"custom"
@property(nonatomic, copy) NSString* apiKey;
@property(nonatomic, copy) NSString* model;       // e.g. @"gemini-2.5-flash", @"gpt-4o", @"claude-3-7-sonnet-20250219", @"llama3.3"
@property(nonatomic, copy) NSString* baseURL;     // e.g. @"https://generativelanguage.googleapis.com/v1beta/openai", @"https://api.openai.com/v1"
@property(nonatomic) float temperature;
@property(nonatomic) BOOL allowLocalCLI; // Explicit opt-in; never bypass CLI permissions.
@property(nonatomic) BOOL sendAudio; // Explicit opt-in; telemetry-only by default to limit cost.
- (BOOL)canSendAudio; // Conservative model/transport capability check.

+ (instancetype)defaultConfig;
+ (instancetype)loadFromDisk;
+ (NSString*)defaultBaseURLForProvider:(NSString*)provider;
+ (NSString*)storedApiKeyForProvider:(NSString*)provider;
- (BOOL)saveToDisk:(NSError**)error;
- (NSString*)effectiveApiKey;
- (NSString*)effectiveEndpointURL;
@end

@interface RigAICopilotResult : NSObject
@property(nonatomic, copy) NSString* explanation;
@property(nonatomic, copy) NSString* thought;
@property(nonatomic, copy, nullable) NSString* presetName;
@property(nonatomic, strong) NSDictionary<NSString*, NSNumber*>* controls;
@property(nonatomic, copy, nullable) NSString* ampPath;
@property(nonatomic, copy, nullable) NSString* cabPath;
@property(nonatomic, copy, nullable) NSString* pedalPath; // Catalog path, "none" to remove, or empty if unchanged
@property(nonatomic, strong, nullable) NSDictionary<NSString*, NSString*>* slotPresets;
@property(nonatomic, strong, nullable) NSDictionary* rawJson;
@property(nonatomic, strong, nullable) RigPreset* proposedPreset; // Frozen base + validated proposal
@end

@interface RigAICopilot : NSObject
+ (instancetype)sharedCopilot;

@property(nonatomic, strong) RigAIConfig* config;
@property(nonatomic, readonly) BOOL isProcessing;
- (void)cancelProcessing;

// Human-readable progress lines (catalog, request, response, apply steps). Called on the main thread.
@property(nonatomic, copy, nullable) void (^progressHandler)(NSString* message);

// Active session preset tasks list
@property(nonatomic, readonly, strong) NSArray<RigAIPresetTask*>* sessionTasks;
@property(nonatomic, readonly, nullable) RigAIPresetTask* currentTask;

// Session task lifecycle methods
- (RigAIPresetTask*)beginPresetTaskForPrompt:(NSString*)prompt;
- (void)completeCurrentTaskWithResult:(RigAICopilotResult*)result savedPresetName:(nullable NSString*)savedPresetName;
- (void)failCurrentTaskWithError:(NSError*)error;
- (NSString*)sessionTasksDisplayText;
- (void)clearSessionTasks;

// Summarizes any arbitrary prompt into a clean "<Artist> - <Song>" or "<Artist> - <Album>" title.
+ (NSString*)summarizePromptToPresetName:(NSString*)prompt;

// Sends a user prompt (e.g. "Mick Thomson Before I Forget rhythm, tight attack, no feedback")
// along with the live rig state and library context to the configured LLM.
- (void)processUserPrompt:(NSString*)userPrompt
                withState:(nullable RigUIState*)state
        completionHandler:(void (^)(RigAICopilotResult* _Nullable result, NSError* _Nullable error))completionHandler;

// Clips are dictionaries with label/data/mime keys. At most DI, processed,
// reference, and candidate. No uploads unless config.sendAudio && canSendAudio.
- (void)processUserPrompt:(NSString*)userPrompt
               audioClips:(NSArray<NSDictionary*>*)clips
          audioDescription:(nullable NSString*)description
                basePreset:(nullable RigPreset*)basePreset
                 withState:(nullable RigUIState*)state
         completionHandler:(void (^)(RigAICopilotResult* _Nullable result, NSError* _Nullable error))completionHandler;

+ (NSDictionary*)contextForPreset:(RigPreset*)preset compact:(BOOL)compact;
+ (nullable RigPreset*)presetForResult:(RigAICopilotResult*)result base:(RigPreset*)base error:(NSError**)error;

// Sends a user prompt along with optional recorded audio (e.g. riff WAV clip) and live rig state to the configured LLM.
- (void)processUserPrompt:(NSString*)userPrompt
                audioData:(nullable NSData*)audioData
            audioMimeType:(nullable NSString*)audioMimeType
         audioDescription:(nullable NSString*)audioDescription
                withState:(nullable RigUIState*)state
        completionHandler:(void (^)(RigAICopilotResult* _Nullable result, NSError* _Nullable error))completionHandler;

// Applies the AI result directly to the RigUIState on the main thread safely.
// Optionally captures an undo snapshot before applying.
- (BOOL)applyResult:(RigAICopilotResult*)result
            toState:(RigUIState*)state
      saveUndoState:(BOOL)saveUndo
              error:(NSError**)error;
// Waits for engine path acknowledgements; restores the prior rig if loading fails.
- (void)applyResult:(RigAICopilotResult*)result toState:(RigUIState*)state
  completionHandler:(void (^)(NSError* _Nullable error))completionHandler;

// Exchanges the current rig with the last snapshot (repeatable A/B, same live instance).
- (BOOL)undoLastAIApplicationToState:(RigUIState*)state error:(NSError**)error;
@property(nonatomic, readonly) BOOL canUndo;

// Helper to scan installed Tone3000 library models and generate a concise catalog summary.
+ (NSString*)generateLibrarySummary;

// Default curated models for each provider
+ (NSArray<NSString*>*)defaultModelsForProvider:(NSString*)provider;

// Detects if a local CLI tool exists on the system for this provider (e.g. agy, claude, codex)
+ (nullable NSString*)detectLocalCLIForProvider:(NSString*)provider;

// Fetches the live list of models from the provider's /models endpoint asynchronously
- (void)fetchModelsForProvider:(NSString*)provider
             completionHandler:(void (^)(NSArray<NSString*>* _Nullable models, NSError* _Nullable error))completionHandler;

- (void)fetchModelsForProvider:(NSString*)provider
                         apiKey:(nullable NSString*)apiKey
              completionHandler:(void (^)(NSArray<NSString*>* _Nullable models, NSError* _Nullable error))completionHandler;

// Uses unsaved UI settings without mutating the active tone request configuration.
- (NSArray<NSString*>*)availableModelsForProvider:(NSString*)provider
                                          apiKey:(nullable NSString*)apiKey baseURL:(nullable NSString*)baseURL;
- (void)fetchModelsForProvider:(NSString*)provider apiKey:(nullable NSString*)apiKey
                       baseURL:(nullable NSString*)baseURL forceRefresh:(BOOL)forceRefresh
             completionHandler:(void (^)(NSArray<NSString*>* _Nullable models, NSError* _Nullable error))completionHandler;

@end

NS_ASSUME_NONNULL_END

#endif // __OBJC__
