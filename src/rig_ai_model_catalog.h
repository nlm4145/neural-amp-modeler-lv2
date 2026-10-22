// Provider model discovery, independent of tone generation and audio processing.
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^RigAIModelsCompletion)(NSArray<NSString*>* _Nullable models, NSError* _Nullable error);

@interface RigAIModelCatalog : NSObject
+ (instancetype)sharedCatalog;
// Injectable session/cache location keep tests offline and away from user settings.
- (instancetype)initWithSession:(NSURLSession*)session cacheDirectory:(NSString*)directory;
- (nullable NSArray<NSString*>*)cachedModelsForProvider:(NSString*)provider
                                                apiKey:(NSString*)apiKey baseURL:(NSString*)baseURL;
// Main-thread completion. Automatic API refreshes reuse a successful list for one hour;
// without cloud credentials, public official documentation is refreshed daily and
// returned with an account-access-unverified warning.
// force bypasses freshness. Failures return the last successful list, with an error.
- (void)refreshModelsForProvider:(NSString*)provider apiKey:(NSString*)apiKey
                        baseURL:(NSString*)baseURL force:(BOOL)force
                     completion:(RigAIModelsCompletion)completion;
@end

NS_ASSUME_NONNULL_END
