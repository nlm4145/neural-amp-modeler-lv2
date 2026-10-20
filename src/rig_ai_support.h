#pragma once
#import <Foundation/Foundation.h>
#import "rig_ai_copilot.h"

// Foundation-only validation/catalog helpers, shared by the copilot and local API.
NSString* rigAIControlReference();
BOOL rigAIValidateControls(NSDictionary* controls, NSError** error);
RigAICopilotResult* rigAIParseResponse(NSString* content, NSError** error);
NSArray<NSDictionary*>* rigAILibraryCandidates(NSString* root, NSString* query, NSUInteger limit);
NSString* rigAIResolveModel(NSString* root, NSString* target, NSUInteger stage, NSError** error);
BOOL rigAIModelIncludesCab(NSString* path);
