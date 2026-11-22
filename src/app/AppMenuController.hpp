#pragma once

#import <Cocoa/Cocoa.h>

struct CrtDisplayConfig;
struct FdsDriveStatus;
struct InputBindings;
enum class Famicom3dViewMode : int;

/**
 * Owns the macOS top menu bar construction, localized labels, recent ROM history items,
 * dynamic 3D System & FDS Disk submenus, and checkmark state synchronization so
 * `AppDelegate` stays focused on emulation flow.
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
                            coreLoaded:(BOOL)coreLoaded
                        consolePowered:(BOOL)consolePowered
                         inputBindings:(const InputBindings &)bindings
                          threeDActive:(BOOL)threeDActive
                            view3dMode:(Famicom3dViewMode)view3dMode
                          invert3dEyes:(BOOL)invert3dEyes
                             fdsStatus:(const FdsDriveStatus &)fdsStatus;

- (BOOL)needsDynamicMenuSyncForThreeD:(BOOL)threeDActive
                            fdsStatus:(const FdsDriveStatus &)fdsStatus;

@end
