#import "app/AppDelegate.hpp"
#import "app/AppLocalization.hpp"
#import "app/AppMenuController.hpp"
#import "app/AppPreferences.hpp"
#import "app/LicensesWindow.hpp"

#import <Carbon/Carbon.h>
#import <GameController/GameController.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <mach/mach_time.h>

#include "audio/MacAudioEngine.hpp"
#include "core/CartridgeFaultInjector.hpp"
#include "core/FamicomCore.hpp"
#include "input/ControllerSettingsWindow.hpp"
#include "input/InputBindings.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <string>

namespace {

enum RetroJoypadBit : unsigned {
    JOYPAD_B      = 0,
    JOYPAD_SELECT = 2,
    JOYPAD_START  = 3,
    JOYPAD_UP     = 4,
    JOYPAD_DOWN   = 5,
    JOYPAD_LEFT   = 6,
    JOYPAD_RIGHT  = 7,
    JOYPAD_A      = 8,
};

uint64_t monotonicNowNs() {
    static mach_timebase_info_data_t timebase{};
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    return (mach_absolute_time() * timebase.numer) / timebase.denom;
}

bool isBindingDown(const KeyBindingGroup &group, const std::array<bool, 256> &pressedKeys) {
    return (group.primary < pressedKeys.size() && pressedKeys[group.primary]) ||
           (group.alt1    < pressedKeys.size() && pressedKeys[group.alt1])    ||
           (group.alt2    < pressedKeys.size() && pressedKeys[group.alt2]);
}

// Match cartridge contact keys by character when possible so both US ANSI and Japanese JIS
// keyboards work intuitively (e.g., JIS '@' sits at kVK_ANSI_LeftBracket, and ']' sits at Backslash).
bool isContactFaultBootShortcut(NSEvent *event) {
    NSString *chars = event.characters ?: @"";
    NSString *charsIgn = event.charactersIgnoringModifiers ?: @"";
    return [chars isEqualToString:@"@"] || [charsIgn isEqualToString:@"@"];
}

bool isCartridgeContactShortcut(NSEvent *event) {
    NSString *charsIgn = event.charactersIgnoringModifiers ?: @"";
    return event.keyCode == kVK_ANSI_Comma ||
           event.keyCode == kVK_ANSI_Period ||
           event.keyCode == kVK_ANSI_Slash ||
           [charsIgn isEqualToString:@"["] ||
           [charsIgn isEqualToString:@"]"] ||
           [charsIgn isEqualToString:@"\\"] ||
           [charsIgn isEqualToString:@"¥"];
}

} // namespace

@implementation AppDelegate {
    NSWindow *_window;
    CrtScreenView *_screenView;
    FamicomCore _famicom;
    MacAudioEngine _audioEngine;
    double _audioSampleRate;
    BOOL _audioStarted;

    NSTimer *_frameTimer;
    uint64_t _nextFrameDeadlineNs;
    std::array<bool, 256> _pressedKeys;

    BOOL _paused;
    BOOL _frozen;
    int _lastFreezeStyle;
    BOOL _resetHeld;
    int _cartTilt;
    int _cartLift;
    int _cartPitch;
    BOOL _prevGamepadL2;
    BOOL _prevGamepadR2;

    NSString *_loadedRomPath;
    NSString *_pendingRomPath;
    NSMutableArray<NSString *> *_recentRoms;

    AppMenuController *_menuController;
    InputBindings _bindings;
    ControllerSettingsWindow *_settingsWindow;
    LicensesWindowController *_licensesController;
}

#pragma mark - Preferences & Menu Sync

- (void)loadUserPreferences {
    CrtDisplayConfig config = _screenView.displayConfig;
    bool muted = false;
    app_prefs::loadDisplayPreferences(config, muted);
    _screenView.displayConfig = config;
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
    [_menuController refreshStatesWithDisplayConfig:_screenView.displayConfig
                                              muted:(_audioEngine.isMuted() ? YES : NO)
                                             paused:_paused
                                             frozen:_frozen
                                     consolePowered:(_famicom.isLoaded() && _screenView.consolePowered)
                                      inputBindings:_bindings];
}

#pragma mark - ROM Loading & Actions

- (BOOL)loadAndPowerOnRom:(NSString *)romPath {
    if (!romPath || ![[NSFileManager defaultManager] fileExistsAtPath:romPath]) {
        return NO;
    }

    NSString *corePath = [[[NSBundle mainBundle] privateFrameworksPath]
                          stringByAppendingPathComponent:@"fceumm_libretro.dylib"];
    const std::string supportDir = app_prefs::applicationSupportDirectory();

    if (!corePath || !_famicom.load([corePath UTF8String], [romPath UTF8String], supportDir, supportDir)) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = app_l10n::tr(@"NES ROM を読み込めませんでした", @"Failed to Load NES ROM");
        alert.informativeText = romPath;
        [alert runModal];

        [_screenView setConsolePowered:NO instant:YES];
        _audioEngine.setConsolePowered(false);
        [self refreshMenuStates];
        return NO;
    }

    _loadedRomPath = [romPath copy];
    app_prefs::recordRecentRomPath(_recentRoms, romPath);
    [_menuController rebuildHistoryMenuWithPaths:_recentRoms activePath:_loadedRomPath target:self];

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

    if (_audioStarted && std::abs(_famicom.sampleRate() - _audioSampleRate) > 1.0) {
        _audioSampleRate = _famicom.sampleRate();
        _audioEngine.start(_audioSampleRate);
        const CrtDisplayConfig config = _screenView.displayConfig;
        _audioEngine.setRfTvMode(config.rfMode, config.rfSnow, config.rfSignal);
    }

    [_screenView setConsolePowered:YES instant:NO];
    _audioEngine.setConsolePowered(true);
    [self refreshMenuStates];
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
        UTType *nesType = [UTType typeWithFilenameExtension:@"nes"];
        if (nesType) panel.allowedContentTypes = @[nesType];
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
    app_prefs::saveDisplayPreferences(config, _audioEngine.isMuted());
    [self refreshMenuStates];
    [_screenView requestRedraw];
}

- (void)selectRgbMode:(id)sender     { [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.rfMode = false; c.monochrome = false; }]; }
- (void)selectColorRfMode:(id)sender { [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.rfMode = true;  c.monochrome = false; }]; }
- (void)selectBwRfMode:(id)sender    { [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.rfMode = true;  c.monochrome = true;  }]; }
- (void)toggleInterlaced:(id)sender  { [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.interlaced = !c.interlaced; }]; }
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
    app_prefs::saveDisplayPreferences(_screenView.displayConfig, _audioEngine.isMuted());
    [self refreshMenuStates];
}

- (void)toggleFullScreen:(id)sender {
    [_window toggleFullScreen:nil];
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

    const BOOL shiftDown = (event.modifierFlags & NSEventModifierFlagShift) != 0;
    NSString *charsIgn = event.charactersIgnoringModifiers ?: @"";
    const BOOL isPinKey = [charsIgn isEqualToString:@"\\"] || [charsIgn isEqualToString:@"¥"] ||
                          (event.keyCode == kVK_ANSI_Backslash && ![charsIgn isEqualToString:@"]"]);

    if (isPinKey) {
        if (!event.isARepeat) [_screenView toggleConnectorHudPinned];
        return;
    }
    if (event.keyCode == kVK_ANSI_Slash) {
        if (event.isARepeat) return;
        _cartTilt = 0;
        _cartLift = 0;
        _cartPitch = 0;
        _famicom.reseatCartridge();
        if (_screenView.consolePowered) {
            [_screenView triggerCartridgeBump];
        }
        [_screenView showConnectorHud];
        return;
    }

    const int prevTilt = _cartTilt;
    const int prevLift = _cartLift;
    const int prevPitch = _cartPitch;

    if ([charsIgn isEqualToString:@"["]) {
        _cartPitch = std::max(-8, _cartPitch - 1);
    } else if ([charsIgn isEqualToString:@"]"]) {
        _cartPitch = std::min(8, _cartPitch + 1);
    } else if (event.keyCode == kVK_ANSI_Comma) {
        if (shiftDown) _cartLift = std::min(16, _cartLift + 1);
        else           _cartTilt = std::max(-32, _cartTilt - 1);
    } else if (shiftDown) {
        if (_cartLift > 0)      _cartLift = std::max(0, _cartLift - 1);
        else if (_cartTilt < 0) _cartTilt += 1;
        else if (_cartTilt > 0) _cartTilt -= 1;
    } else {
        _cartTilt = std::min(32, _cartTilt + 1);
    }

    if (_cartTilt != prevTilt || _cartLift != prevLift || _cartPitch != prevPitch) {
        _famicom.setCartridgePose(_cartTilt, _cartLift, _cartPitch);
        if (_screenView.consolePowered && (!event.isARepeat || (std::abs(_cartTilt) & 3) == 0)) {
            [_screenView triggerCartridgeBump];
        }
    }
    [_screenView showConnectorHud];
}

- (void)crtScreenDidReceiveKeyDown:(NSEvent *)event {
    const NSEventModifierFlags cmdMods =
        event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption);

    if (cmdMods == 0) {
        if (isContactFaultBootShortcut(event)) {
            if (!event.isARepeat) [self toggleBadBootSwitch:nil];
            return;
        }
        if (isCartridgeContactShortcut(event)) {
            [self handleCartridgeContactKey:event];
            return;
        }
    }

    if (!event.isARepeat && cmdMods == 0) {
        if (event.keyCode == kVK_ANSI_O) {
            [self toggleConsolePower:nil];
            return;
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

- (uint32_t)sampleKeyboardMask {
    uint32_t mask = 0;
    if (isBindingDown(_bindings.keys[FC_BTN_UP], _pressedKeys))     mask |= (1u << JOYPAD_UP);
    if (isBindingDown(_bindings.keys[FC_BTN_DOWN], _pressedKeys))   mask |= (1u << JOYPAD_DOWN);
    if (isBindingDown(_bindings.keys[FC_BTN_LEFT], _pressedKeys))   mask |= (1u << JOYPAD_LEFT);
    if (isBindingDown(_bindings.keys[FC_BTN_RIGHT], _pressedKeys))  mask |= (1u << JOYPAD_RIGHT);
    if (isBindingDown(_bindings.keys[FC_BTN_B], _pressedKeys))      mask |= (1u << JOYPAD_B);
    if (isBindingDown(_bindings.keys[FC_BTN_A], _pressedKeys))      mask |= (1u << JOYPAD_A);
    if (isBindingDown(_bindings.keys[FC_BTN_SELECT], _pressedKeys)) mask |= (1u << JOYPAD_SELECT);
    if (isBindingDown(_bindings.keys[FC_BTN_START], _pressedKeys))  mask |= (1u << JOYPAD_START);
    return mask;
}

- (uint32_t)sampleControllerMask {
    uint32_t mask = [self sampleKeyboardMask];
    bool l2Held = false;
    bool r2Held = false;
    bool selectHeld = false;

    for (GCController *controller in [GCController controllers]) {
        GCExtendedGamepad *pad = controller.extendedGamepad;
        if (!pad) continue;

        const bool optionsDown = ([pad respondsToSelector:@selector(buttonOptions)] &&
                                  pad.buttonOptions && pad.buttonOptions.pressed);
        const bool stickUp    = _bindings.useLeftStick && (pad.leftThumbstick.yAxis.value > 0.35f);
        const bool stickDown  = _bindings.useLeftStick && (pad.leftThumbstick.yAxis.value < -0.35f);
        const bool stickLeft  = _bindings.useLeftStick && (pad.leftThumbstick.xAxis.value < -0.35f);
        const bool stickRight = _bindings.useLeftStick && (pad.leftThumbstick.xAxis.value > 0.35f);

        const bool faceB = pad.buttonB.pressed || pad.buttonX.pressed;
        const bool faceA = pad.buttonA.pressed || pad.buttonY.pressed;
        const bool nesB = _bindings.swapGamepadAB ? faceA : faceB;
        const bool nesA = _bindings.swapGamepadAB ? faceB : faceA;

        if (pad.dpad.up.pressed || stickUp)          mask |= (1u << JOYPAD_UP);
        if (pad.dpad.down.pressed || stickDown)      mask |= (1u << JOYPAD_DOWN);
        if (pad.dpad.left.pressed || stickLeft)      mask |= (1u << JOYPAD_LEFT);
        if (pad.dpad.right.pressed || stickRight)    mask |= (1u << JOYPAD_RIGHT);
        if (nesB)                                    mask |= (1u << JOYPAD_B);
        if (nesA)                                    mask |= (1u << JOYPAD_A);
        if (pad.buttonMenu.pressed)                  mask |= (1u << JOYPAD_START);
        if (optionsDown || pad.leftShoulder.pressed) mask |= (1u << JOYPAD_SELECT);

        if (_bindings.allowGamepadSaveLoad) {
            l2Held = l2Held || (pad.leftTrigger.value > 0.65f);
            r2Held = r2Held || (pad.rightTrigger.value > 0.65f);
            selectHeld = selectHeld || optionsDown || pad.leftShoulder.pressed;
        }
    }

    if (l2Held && !_prevGamepadL2) [self quickSave:nil];
    if (r2Held && !_prevGamepadR2 && selectHeld) [self quickLoad:nil];
    _prevGamepadL2 = l2Held ? YES : NO;
    _prevGamepadR2 = r2Held ? YES : NO;
    return mask;
}

#pragma mark - Emulation Loop & Lifecycle

- (void)tickEmulation:(NSTimer *)timer {
    // Micro-adjust frame deadline toward nominal audio queue fill so NTSC 60.0988 Hz runs crackle-free.
    const double nominalPeriodNs = 1e9 / std::max(_famicom.fps(), 50.0);
    const size_t queued = _audioEngine.queuedFrames();
    const size_t target = _audioEngine.targetBufferFrames();
    double clockAdjust = 1.0;
    if (queued > target + 1024)      clockAdjust = 1.006;
    else if (queued + 1024 < target) clockAdjust = 0.994;

    const uint64_t now = monotonicNowNs();
    if (_nextFrameDeadlineNs == 0) _nextFrameDeadlineNs = now;
    if (now < _nextFrameDeadlineNs) return;

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
        _audioEngine.updateScreenMetrics(_famicom.currentPixels(), _famicom.width(), _famicom.height());
        [_screenView presentLatestFrame];
    }

    _nextFrameDeadlineNs += static_cast<uint64_t>(nominalPeriodNs * clockAdjust);
    // Snap deadline forward after window drag or macOS sleep rather than catching up in a burst.
    if (now > _nextFrameDeadlineNs + static_cast<uint64_t>(nominalPeriodNs * 3.0)) {
        _nextFrameDeadlineNs = now;
    }
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    if (![[filename.pathExtension lowercaseString] isEqualToString:@"nes"]) {
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

    [self loadUserPreferences];
    [self rebuildMenuBar];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    _audioSampleRate = _famicom.sampleRate();
    _audioStarted = _audioEngine.start(_audioSampleRate) ? YES : NO;

    NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];
    NSString *startupRom = _pendingRomPath;
    _pendingRomPath = nil;
    if (!startupRom && args.count > 1 && [[args[1].pathExtension lowercaseString] isEqualToString:@"nes"]) {
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

    _frameTimer = [NSTimer timerWithTimeInterval:0.002
                                          target:self
                                        selector:@selector(tickEmulation:)
                                        userInfo:nil
                                         repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:_frameTimer forMode:NSRunLoopCommonModes];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    _pressedKeys.fill(false);
    [self releaseResetButtonIfHeld];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [_frameTimer invalidate];
    _frameTimer = nil;
    _audioEngine.stop();
    _famicom.unload();
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end
