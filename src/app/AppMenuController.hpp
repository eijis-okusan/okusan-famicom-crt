#pragma once

#import <Cocoa/Cocoa.h>

struct CrtDisplayConfig;
struct InputBindings;

/**
 * Owns the macOS top menu bar construction, localized labels, recent ROM history items,
 * and checkmark state synchronization so `AppDelegate` can stay focused on emulation flow.
 */
@interface AppMenuController : NSObject

- (void)installMenuBarWithTarget:(id)target;

- (void)rebuildHistoryMenuWithPaths:(NSArray<NSString *> *)recentPaths
                         activePath:(NSString *)activeRomPath
                             target:(id)target;

- (void)refreshStatesWithDisplayConfig:(const CrtDisplayConfig &)config
                                 muted:(BOOL)muted
                                paused:(BOOL)paused
                                frozen:(BOOL)frozen
                        consolePowered:(BOOL)consolePowered
                         inputBindings:(const InputBindings &)bindings;

@end
