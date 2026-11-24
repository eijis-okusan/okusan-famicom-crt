#import "app/AppDelegate.hpp"
#import "app/AppLocalization.hpp"
#import "app/AppMenuController.hpp"
#import "app/AppPreferences.hpp"
#import "app/EmulationPacer.hpp"
#import "app/FdsDriveController.hpp"
#import "app/LicensesWindow.hpp"

#import <Carbon/Carbon.h>
#import <GameController/GameController.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "audio/MacAudioEngine.hpp"
#include "core/CartridgeFaultInjector.hpp"
#include "core/FamicomCore.hpp"
#include "input/ControllerSettingsWindow.hpp"
#include "input/InputBindings.hpp"
#include "input/InputPoller.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <string>

@implementation AppDelegate {
    NSWindow *_window;
    CrtScreenView *_screenView;
    FamicomCore _famicom;
    MacAudioEngine _audioEngine;
    double _audioSampleRate;
    BOOL _audioStarted;

    EmulationPacer *_pacer;
    std::array<bool, 256> _pressedKeys;
    famicom_input::GamepadHotkeyState _gamepadHotkeys;

    BOOL _paused;
    BOOL _frozen;
    int _lastFreezeStyle;
    BOOL _resetHeld;
    int _cartTilt;
    int _cartLift;
    int _cartPitch;

    NSString *_loadedRomPath;
    NSString *_pendingRomPath;
    NSMutableArray<NSString *> *_recentRoms;

    AppMenuController *_menuController;
    FdsDriveController *_fdsController;
    InputBindings _bindings;
    ControllerSettingsWindow *_settingsWindow;
    LicensesWindowController *_licensesController;
}

static bool isSupportedRomOrBiosPath(NSString *path) {
    NSString *ext = [path.pathExtension lowercaseString];
    return [ext isEqualToString:@"nes"] ||
           [ext isEqualToString:@"fds"] ||
           [ext isEqualToString:@"rom"] ||
           [ext isEqualToString:@"bin"];
}

#pragma mark - Preferences & Menu Sync

- (void)loadUserPreferences {
    CrtDisplayConfig config = _screenView.displayConfig;
    bool muted = false;
    bool invert3d = false;
    app_prefs::loadDisplayPreferences(config, muted, invert3d);
    _screenView.displayConfig = config;
    _screenView.view3dMode = Famicom3dViewMode::NakedCrt;
    _screenView.invert3dEyes = invert3d ? YES : NO;
    _audioEngine.setRfTvMode(config.rfMode, config.rfSnow, config.rfSignal);
    _audioEngine.setMuted(muted);

    _bindings.loadFromDefaults();
    _recentRoms = app_prefs::loadRecentRomPaths();
}

- (void)rebuildMenuBar {
    if (!_menuController) {
        _menuController = [[AppMenuController alloc] init];
    }
    [_menuController installMenuBarWithTarget:self];
    [_menuController rebuildHistoryMenuWithPaths:_recentRoms activePath:_loadedRomPath target:self];
    [self refreshMenuStates];
}

- (void)refreshMenuStates {
    const FdsDriveStatus fdsStatus = _famicom.fdsDriveStatus();
    [_menuController refreshStatesWithDisplayConfig:_screenView.displayConfig
                                              muted:(_audioEngine.isMuted() ? YES : NO)
                                             paused:_paused
                                             frozen:_frozen
                                         coreLoaded:(_famicom.isLoaded() ? YES : NO)
                                     consolePowered:(_famicom.isLoaded() && _screenView.consolePowered)
                                      inputBindings:_bindings
                                       threeDActive:(_famicom.is3dSystemActive() ? YES : NO)
                                         view3dMode:_screenView.view3dMode
                                       invert3dEyes:_screenView.invert3dEyes
                                          fdsStatus:fdsStatus];
}

#pragma mark - ROM & FDS Disk Loading

- (void)recordLoadedRomHistory:(NSString *)romPath {
    _loadedRomPath = [romPath copy];
    app_prefs::recordRecentRomPath(_recentRoms, romPath);
    [_menuController rebuildHistoryMenuWithPaths:_recentRoms activePath:_loadedRomPath target:self];
    [self refreshMenuStates];
}

- (void)resetRuntimeStateForNewRom {
    _paused = NO;
    _frozen = NO;
    _resetHeld = NO;
    _cartTilt = 0;
    _cartLift = 0;
    _cartPitch = 0;
    _famicom.setPinFaultMasks(0, 0);
    _famicom.setCartridgePose(0, 0, 0);
    _audioEngine.setFrozen(false);
    _audioEngine.setResetHeld(false);
    [_screenView setFreezeEffect:FreezeStyle::CleanTone seed:0 active:NO];
    _screenView.view3dMode = Famicom3dViewMode::NakedCrt;

    if (_audioStarted && std::abs(_famicom.sampleRate() - _audioSampleRate) > 1.0) {
        _audioSampleRate = _famicom.sampleRate();
        _audioEngine.start(_audioSampleRate);
        const CrtDisplayConfig config = _screenView.displayConfig;
        _audioEngine.setRfTvMode(config.rfMode, config.rfSnow, config.rfSignal);
    }
}

- (BOOL)loadAndPowerOnRom:(NSString *)romPath {
    if (!romPath || ![[NSFileManager defaultManager] fileExistsAtPath:romPath]) {
        return NO;
    }

    __weak AppDelegate *weakSelf = self;
    BOOL fdsHandled = NO;
    const BOOL fdsReady = [_fdsController prepareOrHotSwapFdsPath:romPath
                                                       handledOut:&fdsHandled
                                                       onInserted:^(NSString *diskPath) {
                                                           AppDelegate *strong = weakSelf;
                                                           if (strong) [strong recordLoadedRomHistory:diskPath];
                                                       }];
    if (fdsHandled) {
        return fdsReady;
    }

    [_fdsController saveActiveDiskDiff];
    [_fdsController clearActiveDisk];
    app_prefs::cacheFdsBiosIfValid(romPath);

    NSString *corePath = [[[NSBundle mainBundle] privateFrameworksPath]
                          stringByAppendingPathComponent:@"fceumm_libretro.dylib"];
    const std::string supportDir = app_prefs::applicationSupportDirectory();
    if (!corePath || !_famicom.load([corePath UTF8String], [romPath UTF8String], supportDir, supportDir)) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = app_l10n::tr(@"ROM / ディスクを読み込めませんでした", @"Failed to Load ROM / Disk Image");
        alert.informativeText = romPath;
        [alert runModal];

        [_screenView setConsolePowered:NO instant:YES];
        _audioEngine.setConsolePowered(false);
        [self refreshMenuStates];
        return NO;
    }

    [_fdsController onRomLoadedAtPath:romPath];
    [self resetRuntimeStateForNewRom];
    [self recordLoadedRomHistory:romPath];

    [_screenView setConsolePowered:YES instant:NO];
    _audioEngine.setConsolePowered(true);
    [_window makeKeyAndOrderFront:nil];
    return YES;
}

- (void)playRecentRom:(NSMenuItem *)sender {
    NSString *romPath = [sender representedObject];
    if (![romPath isKindOfClass:[NSString class]] || romPath.length == 0) return;

    if (![[NSFileManager defaultManager] fileExistsAtPath:romPath]) {
        [_recentRoms removeObject:romPath];
        app_prefs::saveRecentRomPaths(_recentRoms);
        [_menuController rebuildHistoryMenuWithPaths:_recentRoms activePath:_loadedRomPath target:self];

        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = app_l10n::tr(@"NES ROM が見つかりませんでした", @"NES ROM File Not Found");
        alert.informativeText = romPath;
        [alert runModal];
        return;
    }

    [self loadAndPowerOnRom:romPath];
}

- (void)clearRecentRoms:(id)sender {
    [_recentRoms removeAllObjects];
    app_prefs::saveRecentRomPaths(_recentRoms);
    [_menuController rebuildHistoryMenuWithPaths:_recentRoms activePath:_loadedRomPath target:self];
}

- (void)openRomDialog:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    if (@available(macOS 11.0, *)) {
        NSMutableArray<UTType *> *types = [NSMutableArray array];
        for (NSString *ext in @[@"nes", @"fds", @"rom", @"bin"]) {
            UTType *t = [UTType typeWithFilenameExtension:ext];
            if (t) [types addObject:t];
        }
        if (types.count > 0) panel.allowedContentTypes = types;
    }
    if ([panel runModal] == NSModalResponseOK && panel.URL.isFileURL) {
        [self loadAndPowerOnRom:panel.URL.path];
    }
}

- (void)applyDisplayConfig:(void (^)(CrtDisplayConfig &config))mutator {
    CrtDisplayConfig config = _screenView.displayConfig;
    mutator(config);
    _screenView.displayConfig = config;
    _audioEngine.setRfTvMode(config.rfMode, config.rfSnow, config.rfSignal);
    app_prefs::saveDisplayPreferences(config, _audioEngine.isMuted(), _screenView.invert3dEyes == YES);
    [self refreshMenuStates];
    [_screenView requestRedraw];
}

- (void)selectRgbMode:(id)sender     { [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.rfMode = false; c.monochrome = false; }]; }
- (void)selectColorRfMode:(id)sender { [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.rfMode = true;  c.monochrome = false; }]; }
- (void)selectBwRfMode:(id)sender    { [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.rfMode = true;  c.monochrome = true;  }]; }
- (void)selectPresetRgbFlat:(id)sender {
    [self applyDisplayConfig:^(CrtDisplayConfig &c) { c = CrtDisplayConfig::rgbFlatPreset(c); }];
    [_screenView showStatusBannerText:app_l10n::tr(@"プリセット: RGB + フラット", @"Preset: RGB + Flat")];
}
- (void)selectPresetRfCurvedNoise:(id)sender {
    [self applyDisplayConfig:^(CrtDisplayConfig &c) { c = CrtDisplayConfig::rfCurvedNoisePreset(c); }];
    [_screenView showStatusBannerText:app_l10n::tr(@"プリセット: RF + 湾曲・ノイズ付き", @"Preset: RF + Curved & Noise")];
}
- (void)toggleInterlaced:(id)sender  { [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.interlaced = !c.interlaced; }]; }
- (void)toggleHdr:(id)sender {
    [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.hdrEnabled = !c.hdrEnabled; }];
    const float hr = _screenView.activeHdrHeadroom;
    NSString *msg = _screenView.displayConfig.hdrEnabled
                        ? app_l10n::tr([NSString stringWithFormat:@"HDR ピーク強調: オン (%.1f倍)", hr],
                                       [NSString stringWithFormat:@"HDR CRT (EDR): ON (%.1fx)", hr])
                        : app_l10n::tr(@"HDR ピーク強調: オフ (SDR)", @"HDR CRT (EDR): OFF (SDR)");
    [_screenView showStatusBannerText:msg];
}
- (void)toggleHvBloom:(id)sender     { [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.hvBloom = (c.hvBloom > 0.1f) ? 0.0f : 1.0f; }]; }
- (void)toggleCurvature:(id)sender   { [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.curvature = (c.curvature > 0.1f) ? 0.0f : 1.0f; }]; }
- (void)toggleSlotMask:(id)sender    { [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.slotMask = (c.slotMask > 0.1f) ? 0.0f : 1.0f; }]; }
- (void)selectRfMild:(id)sender      { [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.rfMode = true; c.rfSnow = 0.5f; c.rfSignal = 0.65f; }]; }
- (void)selectRfStandard:(id)sender  { [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.rfMode = true; c.rfSnow = 1.0f; c.rfSignal = 1.0f;  }]; }
- (void)selectRfHeavy:(id)sender     { [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.rfMode = true; c.rfSnow = 1.6f; c.rfSignal = 1.35f; }]; }

- (void)togglePause:(id)sender {
    if (!_famicom.isLoaded()) return;
    _paused = !_paused;
    [self refreshMenuStates];
}

- (void)triggerConsoleReset {
    if (_famicom.isLoaded() && _screenView.consolePowered) {
        _famicom.clearFdsFault();
        _famicom.reset();
        [_screenView triggerResetGlitch];
    }
    [self refreshMenuStates];
}

- (void)exitFreezeIfActive {
    if (!_frozen) return;
    _frozen = NO;
    _audioEngine.setFrozen(false);
    [_screenView setFreezeEffect:FreezeStyle::CleanTone seed:0 active:NO];
}

- (void)resetConsole:(id)sender {
    [self exitFreezeIfActive];
    _resetHeld = NO;
    _audioEngine.setResetHeld(false);
    [self triggerConsoleReset];
}

- (void)quickSave:(id)sender {
    if (_famicom.isLoaded() && _screenView.consolePowered && !_frozen) {
        _famicom.saveState(app_prefs::quickStatePathForRom(_loadedRomPath));
    }
}

- (void)quickLoad:(id)sender {
    if (_famicom.isLoaded() && _screenView.consolePowered && !_frozen) {
        _famicom.loadState(app_prefs::quickStatePathForRom(_loadedRomPath));
    }
}

- (void)toggleMute:(id)sender {
    _audioEngine.setMuted(!_audioEngine.isMuted());
    app_prefs::saveDisplayPreferences(_screenView.displayConfig, _audioEngine.isMuted(), _screenView.invert3dEyes == YES);
    [self refreshMenuStates];
}

- (void)toggleFullScreen:(id)sender {
    [_window toggleFullScreen:nil];
}

#pragma mark - Famicom 3D System

- (void)select3dModeFromMenu:(NSMenuItem *)sender {
    const int tag = static_cast<int>(sender.tag);
    if (tag < 0 || tag > 3) return;
    _screenView.view3dMode = static_cast<Famicom3dViewMode>(tag);
    [self refreshMenuStates];
    [_screenView show3dModeBanner];
}

- (void)cycle3dViewMode {
    const int cur = static_cast<int>(_screenView.view3dMode);
    _screenView.view3dMode = static_cast<Famicom3dViewMode>((cur + 1) % 4);
    [self refreshMenuStates];
    [_screenView show3dModeBanner];
}

- (void)toggleInvert3dEyes:(id)sender {
    (void)sender;
    _screenView.invert3dEyes = !_screenView.invert3dEyes;
    app_prefs::saveDisplayPreferences(_screenView.displayConfig, _audioEngine.isMuted(), _screenView.invert3dEyes == YES);
    [self refreshMenuStates];
    [_screenView show3dModeBanner];
}

#pragma mark - Famicom Disk System

- (void)openFdsHotSwapDialog:(id)sender {
    (void)sender;
    __weak AppDelegate *weakSelf = self;
    [_fdsController openHotSwapDialogWithOnInserted:^(NSString *diskPath) {
        AppDelegate *strong = weakSelf;
        if (strong) [strong recordLoadedRomHistory:diskPath];
    }];
}

- (void)flipFdsDisk:(id)sender {
    (void)sender;
    if ([_fdsController flipDiskSide]) [self refreshMenuStates];
}

- (void)ejectFdsDisk:(id)sender {
    (void)sender;
    if ([_fdsController ejectDisk]) [self refreshMenuStates];
}

- (void)insertFdsSide:(int)side {
    if ([_fdsController insertSide:side]) [self refreshMenuStates];
}

- (void)insertFdsSideFromMenu:(NSMenuItem *)sender {
    [self insertFdsSide:static_cast<int>(sender.tag)];
}

- (void)triggerFdsRandomFault:(id)sender {
    (void)sender;
    if ([_fdsController triggerRandomFault]) [self refreshMenuStates];
}

- (void)toggleFreeze:(id)sender {
    if (!_famicom.isLoaded() || !_screenView.consolePowered || _resetHeld) return;
    if (_frozen) {
        [self exitFreezeIfActive];
    } else {
        const int styleCount = static_cast<int>(FreezeStyle::Count);
        int picked = static_cast<int>(arc4random_uniform(static_cast<uint32_t>(styleCount)));
        if (styleCount > 1 && _lastFreezeStyle >= 0 && picked == _lastFreezeStyle) {
            picked = (picked + 1 + static_cast<int>(arc4random_uniform(static_cast<uint32_t>(styleCount - 1)))) % styleCount;
        }
        _lastFreezeStyle = picked;
        const FreezeStyle style = static_cast<FreezeStyle>(picked);
        const uint32_t seed = arc4random();
        _frozen = YES;
        _audioEngine.setFrozen(true, style, seed);
        [_screenView setFreezeEffect:style seed:seed active:YES];
    }
    [self refreshMenuStates];
}

#pragma mark - Power & Contact Faults

- (void)prepareConsoleForPowerTransition {
    [self exitFreezeIfActive];
    _resetHeld = NO;
    _audioEngine.setResetHeld(false);
    _cartTilt = 0;
    _cartLift = 0;
    _cartPitch = 0;
    if (_famicom.isLoaded()) {
        _famicom.setPinFaultMasks(0, 0);
        _famicom.setCartridgePose(0, 0, 0);
    }
}

- (void)powerOffConsole {
    [self prepareConsoleForPowerTransition];
    if (_famicom.isLoaded()) {
        _famicom.reset();
    }
    if (!_screenView.displayConfig.rfMode) {
        [_screenView clearToBlack];
    }
    [_screenView setConsolePowered:NO instant:NO];
    _audioEngine.setConsolePowered(false);
    [self refreshMenuStates];
}

- (void)launchRandomContactFaultBoot {
    [self prepareConsoleForPowerTransition];
    if (!_famicom.isLoaded()) {
        [_screenView setConsolePowered:NO instant:YES];
        _audioEngine.setConsolePowered(false);
        [self refreshMenuStates];
        return;
    }

    _paused = NO;
    // Apply randomized pin/pose faults BEFORE reset so corruption starts from frame 0.
    const CartridgeFaultPlan faultPlan = selectViableRandomFaultBoot(_famicom);
    _cartTilt = faultPlan.tilt;
    _cartLift = faultPlan.lift;
    _cartPitch = faultPlan.pitch;
    _famicom.setPinFaultMasks(faultPlan.weakMask, faultPlan.openMask);
    _famicom.setCartridgePose(_cartTilt, _cartLift, _cartPitch);
    _famicom.reset();

    [_screenView setConsolePowered:YES instant:NO];
    _audioEngine.setConsolePowered(true);
    [_screenView triggerResetGlitch];
    [_screenView showConnectorHud];
    [self refreshMenuStates];
}

- (void)toggleBadBootSwitch:(id)sender {
    if (!_famicom.isLoaded() || _screenView.consolePowered) {
        [self powerOffConsole];
        return;
    }
    [self launchRandomContactFaultBoot];
}

- (void)toggleConsolePower:(id)sender {
    if (!_famicom.isLoaded() || _screenView.consolePowered) {
        [self powerOffConsole];
        return;
    }

    [self prepareConsoleForPowerTransition];
    _paused = NO;
    _famicom.reset();
    [_screenView setConsolePowered:YES instant:NO];
    _audioEngine.setConsolePowered(true);
    [self refreshMenuStates];
}

- (void)crtScreenDidDropRom:(NSString *)romPath {
    [self loadAndPowerOnRom:romPath];
}

- (void)releaseResetButtonIfHeld {
    if (!_resetHeld) return;
    _resetHeld = NO;
    _audioEngine.setResetHeld(false);
    [self triggerConsoleReset];
}

#pragma mark - Keyboard, Cartridge Pose & Gamepad Input

- (void)handleCartridgeContactKey:(NSEvent *)event {
    if (!_famicom.isLoaded()) return;

    switch (famicom_input::applyCartridgeContactKeyEvent(event, _cartTilt, _cartLift, _cartPitch)) {
        case famicom_input::CartridgeContactAction::None:
            return;
        case famicom_input::CartridgeContactAction::TogglePinHud:
            [_screenView toggleConnectorHudPinned];
            return;
        case famicom_input::CartridgeContactAction::Reseat:
            _famicom.reseatCartridge();
            if (_screenView.consolePowered) [_screenView triggerCartridgeBump];
            [_screenView showConnectorHud];
            return;
        case famicom_input::CartridgeContactAction::PoseChanged:
            _famicom.setCartridgePose(_cartTilt, _cartLift, _cartPitch);
            if (_screenView.consolePowered && (!event.isARepeat || (std::abs(_cartTilt) & 3) == 0)) {
                [_screenView triggerCartridgeBump];
            }
            [_screenView showConnectorHud];
            return;
        case famicom_input::CartridgeContactAction::Unchanged:
            [_screenView showConnectorHud];
            return;
    }
}

- (void)crtScreenDidReceiveKeyDown:(NSEvent *)event {
    const NSEventModifierFlags cmdMods =
        event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption);

    if (cmdMods == 0) {
        if (famicom_input::isContactFaultBootShortcut(event)) {
            if (!event.isARepeat) [self toggleBadBootSwitch:nil];
            return;
        }
        if (famicom_input::isCartridgeContactShortcut(event)) {
            [self handleCartridgeContactKey:event];
            return;
        }
    }

    if (!event.isARepeat && cmdMods == 0) {
        if (event.keyCode == kVK_ANSI_O) {
            [self toggleConsolePower:nil];
            return;
        }
        if (event.keyCode == kVK_ANSI_G && _famicom.isLoaded() && _screenView.consolePowered && _famicom.is3dSystemActive()) {
            [self cycle3dViewMode];
            return;
        }
        if (_famicom.isLoaded() && _famicom.isFdsActive()) {
            if (event.keyCode == kVK_ANSI_C) {
                [self flipFdsDisk:nil];
                return;
            }
            if (event.keyCode == kVK_ANSI_E) {
                [self ejectFdsDisk:nil];
                return;
            }
            if (event.keyCode == kVK_ANSI_T) {
                [self triggerFdsRandomFault:nil];
                return;
            }
            int sideKey = -1;
            if (event.keyCode == kVK_ANSI_1) sideKey = 0;
            else if (event.keyCode == kVK_ANSI_2) sideKey = 1;
            else if (event.keyCode == kVK_ANSI_3) sideKey = 2;
            else if (event.keyCode == kVK_ANSI_4) sideKey = 3;
            if (sideKey >= 0) {
                [self insertFdsSide:sideKey];
                return;
            }
        }
        if (event.keyCode == kVK_ANSI_F) {
            [self toggleFreeze:nil];
            return;
        }
        if (event.keyCode == kVK_ANSI_R) {
            if (_famicom.isLoaded() && _screenView.consolePowered && !_resetHeld) {
                _resetHeld = YES;
                [self exitFreezeIfActive];
                _audioEngine.setResetHeld(true);
                [self refreshMenuStates];
            }
            return;
        }
    }

    if (event.keyCode < _pressedKeys.size()) {
        _pressedKeys[event.keyCode] = true;
    }
}

- (void)crtScreenDidReceiveKeyUp:(NSEvent *)event {
    if (event.keyCode == kVK_ANSI_R) {
        [self releaseResetButtonIfHeld];
    }
    if (event.keyCode < _pressedKeys.size()) {
        _pressedKeys[event.keyCode] = false;
    }
}

- (void)openControllerSettings:(id)sender {
    if (!_settingsWindow) {
        __weak AppDelegate *weakSelf = self;
        _settingsWindow = [[ControllerSettingsWindow alloc] initWithBindings:&_bindings onChange:^{
            AppDelegate *strongSelf = weakSelf;
            if (strongSelf) [strongSelf refreshMenuStates];
        }];
    }
    [_settingsWindow refreshUI];
    [_settingsWindow showWindow:nil];
    [_settingsWindow.window makeKeyAndOrderFront:nil];
}

- (void)applyLanguageMode:(AppLanguageMode)mode {
    app_l10n::saveLanguageMode(mode);
    _window.title = app_l10n::tr(@"(´❝᷀ົ👄❝᷀ົ)おくさんファミコン", @"(´❝᷀ົ👄❝᷀ົ) Okusan Famicom CRT");
    [self rebuildMenuBar];
    if (_settingsWindow) [_settingsWindow refreshUI];
    if (_licensesController) [_licensesController refreshLocalization];
    [_screenView invalidateConnectorHud];
}

- (void)selectLanguageSystem:(id)sender   { [self applyLanguageMode:AppLanguageMode::System]; }
- (void)selectLanguageJapanese:(id)sender { [self applyLanguageMode:AppLanguageMode::Japanese]; }
- (void)selectLanguageEnglish:(id)sender  { [self applyLanguageMode:AppLanguageMode::English]; }
- (void)showAboutPanel:(id)sender         { presentAboutDialog(); }

- (void)showOpenSourceLicenses:(id)sender {
    if (!_licensesController) {
        _licensesController = [[LicensesWindowController alloc] init];
    }
    [_licensesController showLicenses];
}

- (void)applyInputBindings:(void (^)(InputBindings &bindings))mutator {
    mutator(_bindings);
    _bindings.saveToDefaults();
    [self refreshMenuStates];
    if (_settingsWindow) [_settingsWindow refreshUI];
}

- (void)toggleSwapGamepadAB:(id)sender     { [self applyInputBindings:^(InputBindings &b) { b.swapGamepadAB = !b.swapGamepadAB; }]; }
- (void)toggleLeftStickDpad:(id)sender     { [self applyInputBindings:^(InputBindings &b) { b.useLeftStick = !b.useLeftStick; }]; }
- (void)resetBindingsToDefaults:(id)sender { [self applyInputBindings:^(InputBindings &b) { b = InputBindings::defaults(); }]; }

- (void)resetAllSettingsToDefaults:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = app_l10n::tr(@"すべての設定を初期値に戻しますか？",
                                     @"Reset all settings to defaults?");
    alert.informativeText = app_l10n::tr(
        @"CRT表示（RF/RGB・走査線・歪み等）、音声ミュート、コントローラキー割り当て、言語設定がすべて初期設定に戻ります。（ROM履歴とステートセーブは保持されます）",
        @"CRT display options, audio mute state, controller bindings, and language preference will all be restored to defaults. Recent ROM history and save states are kept.");
    [alert addButtonWithTitle:app_l10n::tr(@"初期値に戻す", @"Reset")];
    [alert addButtonWithTitle:app_l10n::tr(@"キャンセル", @"Cancel")];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    app_prefs::clearDisplayPreferences();
    const CrtDisplayConfig defaults{};
    _screenView.displayConfig = defaults;
    _screenView.view3dMode = Famicom3dViewMode::NakedCrt;
    _screenView.invert3dEyes = NO;
    _audioEngine.setRfTvMode(defaults.rfMode, defaults.rfSnow, defaults.rfSignal);
    _audioEngine.setMuted(false);
    _bindings = InputBindings::defaults();
    _bindings.saveToDefaults();
    [self applyLanguageMode:AppLanguageMode::System];
    [_screenView showStatusBannerText:app_l10n::tr(@"すべての設定を初期値に戻しました", @"All settings reset to defaults")];
}

- (uint32_t)sampleControllerMask {
    const famicom_input::PollResult result =
        famicom_input::sampleControllerInput(_bindings, _pressedKeys, _gamepadHotkeys);
    if (result.quickSaveTriggered) [self quickSave:nil];
    if (result.quickLoadTriggered) [self quickLoad:nil];
    return result.padMask;
}

#pragma mark - Emulation Loop & Lifecycle

- (void)advanceOneFrame {
    const size_t samplesPerFrame =
        static_cast<size_t>(std::round(_famicom.sampleRate() / std::max(_famicom.fps(), 50.0)));

    if (!_famicom.isLoaded() || !_screenView.consolePowered || _resetHeld || !_famicom.isCartridgePowered()) {
        _audioEngine.setConsolePowered(_famicom.isLoaded() && _screenView.consolePowered && _famicom.isCartridgePowered());
        _audioEngine.pushSilenceFrames(samplesPerFrame);
        [_screenView advanceTvRasterFrame];
    } else if (_frozen) {
        _audioEngine.pushFrozenFrames(samplesPerFrame);
        [_screenView advanceFreezeEffect];
    } else if (_paused) {
        _audioEngine.pushSilenceFrames(samplesPerFrame);
        if ([_screenView isConnectorHudVisible]) {
            [_screenView requestRedraw];
        }
    } else {
        const uint32_t padMask = [self sampleControllerMask];
        _audioEngine.setConsolePowered(true);
        _famicom.runFrame(padMask, [self](const int16_t *frames, size_t count) {
            _audioEngine.pushFrames(frames, count);
        });
        _audioEngine.setCartridgeAudioGain(_famicom.cartridgeAudioGain());
        const FdsDriveStatus fst = _famicom.fdsDriveStatus();
        const BOOL threeDNow = _famicom.is3dSystemActive() ? YES : NO;
        if ([_menuController needsDynamicMenuSyncForThreeD:threeDNow fdsStatus:fst]) {
            [self refreshMenuStates];
        }
        _audioEngine.updateScreenMetrics(_famicom.currentPixels(), _famicom.width(), _famicom.height());
        [_screenView presentLatestFrame];
    }
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    if (!isSupportedRomOrBiosPath(filename)) {
        return NO;
    }
    if (_screenView) {
        return [self loadAndPowerOnRom:filename];
    }
    _pendingRomPath = [filename copy];
    return YES;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _pressedKeys.fill(false);
    _lastFreezeStyle = -1;

    const NSRect initialFrame = NSMakeRect(0, 0, 1024, 768);
    _window = [[NSWindow alloc] initWithContentRect:initialFrame
                                          styleMask:(NSWindowStyleMaskTitled |
                                                     NSWindowStyleMaskClosable |
                                                     NSWindowStyleMaskMiniaturizable |
                                                     NSWindowStyleMaskResizable)
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = app_l10n::tr(@"(´❝᷀ົ👄❝᷀ົ)おくさんファミコン", @"(´❝᷀ົ👄❝᷀ົ) Okusan Famicom CRT");
    _window.backgroundColor = [NSColor blackColor];
    [_window center];
    _window.delegate = self;

    _screenView = [[CrtScreenView alloc] initWithFrame:initialFrame core:&_famicom];
    _screenView.screenDelegate = self;
    _window.contentView = _screenView;
    [_window makeFirstResponder:_screenView];
    _fdsController = [[FdsDriveController alloc] initWithCore:&_famicom screenView:_screenView];

    [self loadUserPreferences];
    [self rebuildMenuBar];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    _audioSampleRate = _famicom.sampleRate();
    _audioStarted = _audioEngine.start(_audioSampleRate) ? YES : NO;

    NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];
    NSString *startupRom = _pendingRomPath;
    _pendingRomPath = nil;
    if (!startupRom && args.count > 1 && isSupportedRomOrBiosPath(args[1])) {
        startupRom = args[1];
    }

    if (startupRom) {
        [self loadAndPowerOnRom:startupRom];
    } else {
        [_screenView setConsolePowered:NO instant:YES];
        _audioEngine.setConsolePowered(false);
        [self refreshMenuStates];
    }

    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];

    _pacer = [[EmulationPacer alloc] init];
    __weak AppDelegate *weakSelf = self;
    [_pacer startWithView:_screenView
              fpsProvider:^double {
                  AppDelegate *strong = weakSelf;
                  return strong ? strong->_famicom.fps() : 60.0988;
              }
                stepBlock:^{
                    AppDelegate *strong = weakSelf;
                    if (strong) [strong advanceOneFrame];
                }];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    _pressedKeys.fill(false);
    [self releaseResetButtonIfHeld];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [_fdsController saveActiveDiskDiff];
    [_pacer stop];
    _pacer = nil;
    _audioEngine.stop();
    _famicom.unload();
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end
