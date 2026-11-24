#pragma once

#import <Cocoa/Cocoa.h>

class FamicomCore;
@class CrtScreenView;

/**
 * Coordinates Famicom Disk System (HVC-022) drive operations: user-supplied
 * BIOS validation, live hot-swapping, side flipping, ejecting, simulated hardware
 * read errors, and non-destructive XOR save diffs.
 */
@interface FdsDriveController : NSObject

@property (nonatomic, copy, readonly) NSString *activeDiskPath;

- (instancetype)initWithCore:(FamicomCore *)core screenView:(CrtScreenView *)screenView;

- (void)saveActiveDiskDiff;
- (void)clearActiveDisk;
- (void)onRomLoadedAtPath:(NSString *)romPath;

/// Returns YES if a BIOS exists (or an active BIOS standby hot-swap handled loading directly).
- (BOOL)prepareOrHotSwapFdsPath:(NSString *)romPath
                     handledOut:(BOOL *)outHandled
                     onInserted:(void (^)(NSString *diskPath))onInserted;

- (BOOL)hotSwapDiskPath:(NSString *)diskPath
         showErrorAlert:(BOOL)showAlert
             onInserted:(void (^)(NSString *diskPath))onInserted;

- (void)openHotSwapDialogWithOnInserted:(void (^)(NSString *diskPath))onInserted;
- (BOOL)flipDiskSide;
- (BOOL)ejectDisk;
- (BOOL)insertSide:(int)side;
- (BOOL)triggerRandomFault;

@end
