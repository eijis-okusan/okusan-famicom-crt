#import "app/FdsDriveController.hpp"
#import "app/AppLocalization.hpp"
#import "app/AppPreferences.hpp"
#import "core/FamicomCore.hpp"
#import "video/CrtScreenView.hpp"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation FdsDriveController {
    FamicomCore *_core;
    __weak CrtScreenView *_screenView;
    NSString *_activeDiskPath;
}

@synthesize activeDiskPath = _activeDiskPath;

+ (NSString *)labelForSide:(int)side totalSides:(int)totalSides {
    if (totalSides <= 2) {
        return app_l10n::tr((side == 0) ? @"A面" : @"B面", (side == 0) ? @"Side A" : @"Side B");
    }
    const int diskNo = 1 + (side / 2);
    const char sideCh = (side & 1) ? 'B' : 'A';
    return app_l10n::tr(
        [NSString stringWithFormat:@"ディスク %d %c面", diskNo, sideCh],
        [NSString stringWithFormat:@"Disk %d Side %c", diskNo, sideCh]);
}

- (instancetype)initWithCore:(FamicomCore *)core screenView:(CrtScreenView *)screenView {
    self = [super init];
    if (self) {
        _core = core;
        _screenView = screenView;
    }
    return self;
}

- (void)saveActiveDiskDiff {
    if (_core && _core->isLoaded() && _core->isFdsActive() && _activeDiskPath.length > 0) {
        _core->saveFdsDiskDiff(app_prefs::fdsSaveDiffPathForDisk(_activeDiskPath));
    }
}

- (void)clearActiveDisk {
    _activeDiskPath = nil;
}

- (void)onRomLoadedAtPath:(NSString *)romPath {
    NSString *ext = [romPath.pathExtension lowercaseString];
    if ([ext isEqualToString:@"fds"]) {
        _activeDiskPath = [romPath copy];
        if (_core) {
            _core->loadFdsDiskDiff(app_prefs::fdsSaveDiffPathForDisk(_activeDiskPath));
        }
    } else {
        _activeDiskPath = nil;
    }
}

- (BOOL)prepareOrHotSwapFdsPath:(NSString *)romPath
                     handledOut:(BOOL *)outHandled
                     onInserted:(void (^)(NSString *diskPath))onInserted {
    if (outHandled) *outHandled = NO;
    NSString *ext = [romPath.pathExtension lowercaseString];
    if (![ext isEqualToString:@"fds"]) {
        return YES;
    }

    // Hot-swap cleanly onto a running FDS BIOS standby without cold resetting.
    if (_core && _core->isLoaded() && _core->isFdsActive()) {
        const FdsDriveStatus fst = _core->fdsDriveStatus();
        if (fst.totalSides == 0) {
            const BOOL ok = [self hotSwapDiskPath:romPath showErrorAlert:YES onInserted:onInserted];
            if (outHandled) *outHandled = YES;
            return ok;
        }
    }

    const std::string biosPath = app_prefs::applicationSupportDirectory() + "/disksys.rom";
    if (![[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithUTF8String:biosPath.c_str()]]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = app_l10n::tr(
            @"FDS BIOS (disksys.rom) が見つかりません",
            @"FDS BIOS (disksys.rom) Not Found");
        alert.informativeText = app_l10n::tr(
            @"先に FDS BIOS (disksys.rom / .rom / .bin / .nes) を開くと自動登録され、そのまま .fds を入れ替えられます。",
            @"Open your FDS BIOS file (disksys.rom / .rom / .bin / .nes) first to register it automatically, then load or drop a .fds image.");
        [alert runModal];
        if (outHandled) *outHandled = YES;
        return NO;
    }
    return YES;
}

- (BOOL)hotSwapDiskPath:(NSString *)diskPath
         showErrorAlert:(BOOL)showAlert
             onInserted:(void (^)(NSString *diskPath))onInserted {
    if (!_core || !_core->isLoaded() || !_core->isFdsActive() || !diskPath) return NO;
    [self saveActiveDiskDiff];
    const int sides = _core->hotSwapFdsDisk([diskPath UTF8String]);
    if (sides <= 0) {
        if (showAlert) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = app_l10n::tr(@"FDS ディスクを読み込めませんでした", @"Failed to Load FDS Disk");
            alert.informativeText = diskPath;
            [alert runModal];
        }
        return NO;
    }

    _activeDiskPath = [diskPath copy];
    _core->loadFdsDiskDiff(app_prefs::fdsSaveDiffPathForDisk(_activeDiskPath));
    if (onInserted) onInserted(diskPath);

    NSString *baseName = [[diskPath lastPathComponent] stringByDeletingPathExtension];
    [_screenView showStatusBannerText:app_l10n::tr(
        [NSString stringWithFormat:@"ディスク挿入: %@ (%d面)", baseName, sides],
        [NSString stringWithFormat:@"Disk Inserted: %@ (%d sides)", baseName, sides])];
    return YES;
}

- (void)openHotSwapDialogWithOnInserted:(void (^)(NSString *diskPath))onInserted {
    if (!_core || !_core->isLoaded() || !_core->isFdsActive()) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    if (@available(macOS 11.0, *)) {
        UTType *fdsType = [UTType typeWithFilenameExtension:@"fds"];
        if (fdsType) panel.allowedContentTypes = @[fdsType];
    }
    if ([panel runModal] == NSModalResponseOK && panel.URL.isFileURL) {
        [self hotSwapDiskPath:panel.URL.path showErrorAlert:YES onInserted:onInserted];
    }
}

- (BOOL)flipDiskSide {
    if (!_core || !_core->isLoaded() || !_core->isFdsActive()) return NO;
    const FdsDriveStatus fst = _core->fdsDriveStatus();
    if (fst.insertedSide < 0 || fst.totalSides < 2) return NO;

    int nextSide = (fst.insertedSide ^ 1);
    if (nextSide >= fst.totalSides) nextSide = (fst.insertedSide + 1) % fst.totalSides;
    _core->setFdsDiskSide(nextSide);

    NSString *lbl = [FdsDriveController labelForSide:nextSide totalSides:fst.totalSides];
    [_screenView showStatusBannerText:app_l10n::tr(
        [NSString stringWithFormat:@"ディスク裏返し: %@", lbl],
        [NSString stringWithFormat:@"Flipped Disk: %@", lbl])];
    return YES;
}

- (BOOL)ejectDisk {
    if (!_core || !_core->isLoaded() || !_core->isFdsActive()) return NO;
    const FdsDriveStatus fst = _core->fdsDriveStatus();
    if (fst.insertedSide < 0) return NO;
    _core->ejectFdsDisk();
    [_screenView showStatusBannerText:app_l10n::tr(@"ディスクを抜きました", @"Disk Ejected")];
    return YES;
}

- (BOOL)insertSide:(int)side {
    if (!_core || !_core->isLoaded() || !_core->isFdsActive()) return NO;
    const FdsDriveStatus fst = _core->fdsDriveStatus();
    if (fst.insertedSide >= 0 || side < 0 || side >= fst.totalSides) return NO;
    _core->setFdsDiskSide(side);
    NSString *lbl = [FdsDriveController labelForSide:side totalSides:fst.totalSides];
    [_screenView showStatusBannerText:app_l10n::tr(
        [NSString stringWithFormat:@"ディスク挿入: %@", lbl],
        [NSString stringWithFormat:@"Inserted: %@", lbl])];
    return YES;
}

- (BOOL)triggerRandomFault {
    if (!_core || !_core->isLoaded() || !_core->isFdsActive()) return NO;
    const FdsDriveStatus fst = _core->fdsDriveStatus();
    if (fst.totalSides <= 0) return NO;
    if (_core->triggerRandomFdsFault() <= 0) return NO;
    [_screenView showStatusBannerText:app_l10n::tr(
        @"FDS: 読込エラー再現 (ランダム故障)",
        @"FDS: Simulated Read Error (Random Fault)")];
    return YES;
}

@end
