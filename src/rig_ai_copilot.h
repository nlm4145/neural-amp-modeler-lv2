// RigAICopilot — Universal AI Tone Copilot for Axe FX.
// Platform-independent: supports OpenAI, Google Gemini, Anthropic Claude, and local Ollama.
#pragma once

#import <Foundation/Foundation.h>

#ifdef __OBJC__

struct RigUIState;

NS_ASSUME_NONNULL_BEGIN

@interface RigAIConfig : NSObject
@property(nonatomic, copy) NSString* provider;    // @"gemini", @"openai", @"claude", @"ollama", @"custom"
@property(nonatomic, copy) NSString* apiKey;
@property(nonatomic, copy) NSString* model;       // e.g. @"gemini-2.5-flash", @"gpt-4o", @"claude-3-7-sonnet-20250219", @"llama3.3"
@property(nonatomic, copy) NSString* baseURL;     // e.g. @"https://generativelanguage.googleapis.com/v1beta/openai", @"https://api.openai.com/v1"
@property(nonatomic) float temperature;

+ (instancetype)defaultConfig;
+ (instancetype)loadFromDisk;
- (BOOL)saveToDisk:(NSError**)error;
- (NSString*)effectiveApiKey;
- (NSString*)effectiveEndpointURL;
@end

@interface RigAICopilotResult : NSObject
@property(nonatomic, copy) NSString* explanation;
@property(nonatomic, copy) NSString* thought;
@property(nonatomic, strong) NSDictionary<NSString*, NSNumber*>* controls;
@property(nonatomic, copy, nullable) NSString* ampPath;
@property(nonatomic, copy, nullable) NSString* cabPath;
@property(nonatomic, strong, nullable) NSDictionary<NSString*, NSString*>* slotPresets;
@property(nonatomic, strong, nullable) NSDictionary* rawJson;
@end

@interface RigAICopilot : NSObject
+ (instancetype)sharedCopilot;

@property(nonatomic, strong) RigAIConfig* config;
@property(nonatomic, readonly) BOOL isProcessing;

// Sends a user prompt (e.g. "Mick Thomson Before I Forget rhythm, tight attack, no feedback")
// along with the live rig state and library context to the configured LLM.
- (void)processUserPrompt:(NSString*)userPrompt
                withState:(nullable RigUIState*)state
        completionHandler:(void (^)(RigAICopilotResult* _Nullable result, NSError* _Nullable error))completionHandler;

// Applies the AI result directly to the RigUIState on the main thread safely.
// Optionally captures an undo snapshot before applying.
- (BOOL)applyResult:(RigAICopilotResult*)result
            toState:(RigUIState*)state
      saveUndoState:(BOOL)saveUndo
              error:(NSError**)error;

// Restores the snapshot captured prior to the last applied AI result.
- (BOOL)undoLastAIApplicationToState:(RigUIState*)state error:(NSError**)error;
@property(nonatomic, readonly) BOOL canUndo;

// Helper to scan installed Tone3000 library models and generate a concise catalog summary.
+ (NSString*)generateLibrarySummary;

// Default curated models for each provider
+ (NSArray<NSString*>*)defaultModelsForProvider:(NSString*)provider;

// Fetches the live list of models from the provider's /models endpoint asynchronously
- (void)fetchModelsForProvider:(NSString*)provider
             completionHandler:(void (^)(NSArray<NSString*>* _Nullable models, NSError* _Nullable error))completionHandler;

- (void)fetchModelsForProvider:(NSString*)provider
                        apiKey:(nullable NSString*)apiKey
             completionHandler:(void (^)(NSArray<NSString*>* _Nullable models, NSError* _Nullable error))completionHandler;

@end

NS_ASSUME_NONNULL_END

#endif // __OBJC__
