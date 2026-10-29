#pragma once

#include "rig_ui_state.h"

@interface NAMRigWorkspace : NSView <NAMRigWorkspaceNavigation>
@property(nonatomic, readonly) NSInteger selectedStage;
@property(nonatomic, copy, readonly) NSString* selectedModule;
- (void)selectStage:(NSInteger)stage;
- (void)selectModule:(NSString*)key;
@end

NAMRigWorkspace* rigCreateWorkspace(RigUIState* state,
                                    NSView* rigPane,
                                    NSView* legacyStageRow,
                                    NSView* legacyDeck,
                                    NSArray<NSView*>* knobGroups);
