// RigProfileCatalog — Discovers and categorizes local profiles (Amps, Pedals, Cabs)
// by Manufacturer/Brand, Model Family, and Profile Pack for cascading menus.
#pragma once

#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#include <string>
#include <vector>

NS_ASSUME_NONNULL_BEGIN

@interface RigProfileCatalog : NSObject

+ (instancetype)sharedCatalog;

// Invalidate cached library index (e.g. after downloading a new tone or editing files).
- (void)invalidateCache;

// Returns a populated hierarchical NSMenu for the given stage (0=Pedal, 1=Amp, 2=Cab A, 3=Cab B).
// Items fire the given action on target with representedObject = fullFilePath and tag = (NSInteger)stage.
- (NSMenu*)buildLibraryMenuForStage:(size_t)stage
                             target:(id)target
                             action:(SEL)action
                        currentPath:(nullable NSString*)currentPath;

// Build an NSMenuItem titled "Choose from Library" (or "Choose Cab A/B from Library")
// with its submenu fully attached, ready to add to stage card context menus.
- (nullable NSMenuItem*)stageCardLibraryMenuItemForStage:(size_t)stage
                                                  target:(id)target
                                                  action:(SEL)action
                                             currentPath:(nullable NSString*)currentPath;

// Build a "Browse Local Library" menu item suitable for appending to the stage model popup button.
- (nullable NSMenuItem*)modelPickerLibraryMenuItemForStage:(size_t)stage
                                                    target:(id)target
                                                    action:(SEL)action
                                               currentPath:(nullable NSString*)currentPath;

@end

NS_ASSUME_NONNULL_END
