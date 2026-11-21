#import "AppDelegate.hpp"
#import "AppLocalization.hpp"

#import <Carbon/Carbon.h>
#import <GameController/GameController.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <mach/mach_time.h>

#include "audio/MacAudioEngine.hpp"
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

constexpr NSUInteger kMaxRecentRoms = 10;

uint64_t monotonicNowNs() {
    static mach_timebase_info_data_t timebase{};
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    return (mach_absolute_time() * timebase.numer) / timebase.denom;
}

std::string applicationSupportDir() {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = dirs.firstObject ?: NSTemporaryDirectory();
    NSString *appDir = [base stringByAppendingPathComponent:@"Okusan-Famicom-CRT-Player"];
    [[NSFileManager defaultManager] createDirectoryAtPath:appDir withIntermediateDirectories:YES attributes:nil error:nil];
    return std::string([appDir UTF8String]);
}

bool isBindingDown(const KeyBindingGroup &group, const std::array<bool, 256> &pressedKeys) {
    if (group.primary < pressedKeys.size() && pressedKeys[group.primary]) return true;
    if (group.alt1 < pressedKeys.size() && pressedKeys[group.alt1]) return true;
    if (group.alt2 < pressedKeys.size() && pressedKeys[group.alt2]) return true;
    return false;
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
    BOOL _resetHeld;
    int _cartTilt;
    int _cartLift;
    int _cartPitch;
    BOOL _prevGamepadL2;
    BOOL _prevGamepadR2;

    NSString *_loadedRomPath;
    NSString *_pendingRomPath;
    NSMutableArray<NSString *> *_recentRoms;
    NSMenu *_historyMenu;

    NSMenuItem *_menuRgb;
    NSMenuItem *_menuRf;
    NSMenuItem *_menuBwRf;
    NSMenuItem *_menuInterlaced;
    NSMenuItem *_menuHvBloom;
    NSMenuItem *_menuCurvature;
    NSMenuItem *_menuSlotMask;
    NSMenuItem *_menuMute;
    NSMenuItem *_menuPause;
    NSMenuItem *_menuFreeze;
    NSMenuItem *_menuPower;
    NSMenuItem *_menuSwapPadAB;
    NSMenuItem *_menuLeftStick;
    NSMenuItem *_menuLangSystem;
    NSMenuItem *_menuLangJapanese;
    NSMenuItem *_menuLangEnglish;

    InputBindings _bindings;
    ControllerSettingsWindow *_settingsWindow;
    NSWindow *_licensesWindow;
    NSTextView *_licensesTextView;
}

- (void)loadUserPreferences {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    CrtDisplayConfig config = _screenView.displayConfig;

    if ([defaults objectForKey:@"useRf"])        config.rfMode = [defaults boolForKey:@"useRf"];
    if ([defaults objectForKey:@"monochrome"])   config.monochrome = [defaults boolForKey:@"monochrome"];
    if ([defaults objectForKey:@"interlaced"])   config.interlaced = [defaults boolForKey:@"interlaced"];
    if ([defaults objectForKey:@"hvBloom"])      config.hvBloom = [defaults floatForKey:@"hvBloom"];
    if ([defaults objectForKey:@"curvature"])    config.curvature = [defaults floatForKey:@"curvature"];
    if ([defaults objectForKey:@"maskStrength"]) config.slotMask = [defaults floatForKey:@"maskStrength"];
    if ([defaults objectForKey:@"rfSnow"])       config.rfSnow = [defaults floatForKey:@"rfSnow"];
    if ([defaults objectForKey:@"rfSignal"])     config.rfSignal = [defaults floatForKey:@"rfSignal"];

    _screenView.displayConfig = config;
    _audioEngine.setRfTvMode(config.rfMode, config.rfSnow, config.rfSignal);
    if ([defaults objectForKey:@"muted"]) {
        _audioEngine.setMuted([defaults boolForKey:@"muted"]);
    }
    _bindings.loadFromDefaults();

    _recentRoms = [NSMutableArray array];
    for (id entry in [defaults arrayForKey:@"recentRoms"]) {
        if (![entry isKindOfClass:[NSString class]]) continue;
        NSString *normalized = [(NSString *)entry stringByStandardizingPath];
        if (normalized.length == 0 || [_recentRoms containsObject:normalized]) continue;
        [_recentRoms addObject:normalized];
        if (_recentRoms.count >= kMaxRecentRoms) break;
    }
}

- (void)saveDisplayPreferences {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    const CrtDisplayConfig config = _screenView.displayConfig;
    [defaults setBool:config.rfMode forKey:@"useRf"];
    [defaults setBool:config.monochrome forKey:@"monochrome"];
    [defaults setBool:config.interlaced forKey:@"interlaced"];
    [defaults setFloat:config.hvBloom forKey:@"hvBloom"];
    [defaults setFloat:config.curvature forKey:@"curvature"];
    [defaults setFloat:config.slotMask forKey:@"maskStrength"];
    [defaults setFloat:config.rfSnow forKey:@"rfSnow"];
    [defaults setFloat:config.rfSignal forKey:@"rfSignal"];
    [defaults setBool:_audioEngine.isMuted() forKey:@"muted"];
}

- (void)saveRecentRoms {
    [[NSUserDefaults standardUserDefaults] setObject:[_recentRoms copy] forKey:@"recentRoms"];
}

- (void)rebuildHistoryMenu {
    if (!_historyMenu) return;
    [_historyMenu removeAllItems];

    if (_recentRoms.count == 0) {
        NSMenuItem *emptyItem = [_historyMenu addItemWithTitle:app_l10n::tr(@"(履歴なし)", @"No Recent ROMs")
                                                        action:nil
                                                 keyEquivalent:@""];
        emptyItem.enabled = NO;
        [_historyMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *clearItem = [_historyMenu addItemWithTitle:app_l10n::tr(@"履歴をクリア", @"Clear History")
                                                        action:@selector(clearRecentRoms:)
                                                 keyEquivalent:@""];
        clearItem.target = self;
        clearItem.enabled = NO;
        return;
    }

    NSString *activeRom = _loadedRomPath ? [_loadedRomPath stringByStandardizingPath] : nil;
    for (NSUInteger i = 0; i < _recentRoms.count; ++i) {
        NSString *romPath = _recentRoms[i];
        NSString *displayName = [[romPath lastPathComponent] stringByDeletingPathExtension];
        if (displayName.length == 0) {
            displayName = romPath.lastPathComponent.length ? romPath.lastPathComponent : romPath;
        }
        NSString *itemTitle = [NSString stringWithFormat:@"%lu. %@", (unsigned long)(i + 1), displayName];
        NSMenuItem *item = [_historyMenu addItemWithTitle:itemTitle
                                                   action:@selector(playRecentRom:)
                                            keyEquivalent:@""];
        item.target = self;
        item.representedObject = romPath;
        item.toolTip = romPath;
        item.enabled = YES;
        item.state = (activeRom && [activeRom isEqualToString:romPath])
            ? NSControlStateValueOn
            : NSControlStateValueOff;
    }

    [_historyMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *clearItem = [_historyMenu addItemWithTitle:app_l10n::tr(@"履歴をクリア", @"Clear History")
                                                    action:@selector(clearRecentRoms:)
                                             keyEquivalent:@""];
    clearItem.target = self;
    clearItem.enabled = YES;
}

- (void)recordRecentRom:(NSString *)romPath {
    if (!romPath || romPath.length == 0) return;
    if (!_recentRoms) _recentRoms = [NSMutableArray array];

    NSString *normalized = [romPath stringByStandardizingPath];
    [_recentRoms removeObject:normalized];
    [_recentRoms insertObject:normalized atIndex:0];
    while (_recentRoms.count > kMaxRecentRoms) {
        [_recentRoms removeLastObject];
    }
    [self saveRecentRoms];
    [self rebuildHistoryMenu];
}

- (void)refreshMenuStates {
    const CrtDisplayConfig config = _screenView.displayConfig;
    const BOOL isBwMode = config.rfMode && config.monochrome;

    _menuRgb.state = !config.rfMode ? NSControlStateValueOn : NSControlStateValueOff;
    _menuRf.state = (config.rfMode && !config.monochrome) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuBwRf.state = isBwMode ? NSControlStateValueOn : NSControlStateValueOff;
    _menuInterlaced.state = config.interlaced ? NSControlStateValueOn : NSControlStateValueOff;
    _menuHvBloom.state = (config.hvBloom > 0.1f) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuCurvature.state = (config.curvature > 0.1f) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuSlotMask.state = (config.slotMask > 0.1f && !isBwMode) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuSlotMask.enabled = !isBwMode;

    _menuMute.state = _audioEngine.isMuted() ? NSControlStateValueOn : NSControlStateValueOff;
    _menuPause.state = _paused ? NSControlStateValueOn : NSControlStateValueOff;
    _menuFreeze.state = _frozen ? NSControlStateValueOn : NSControlStateValueOff;
    _menuPower.state = (_famicom.isLoaded() && _screenView.consolePowered)
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    _menuSwapPadAB.state = _bindings.swapGamepadAB ? NSControlStateValueOn : NSControlStateValueOff;
    _menuLeftStick.state = _bindings.useLeftStick ? NSControlStateValueOn : NSControlStateValueOff;

    const AppLanguageMode langMode = app_l10n::loadLanguageMode();
    _menuLangSystem.state = (langMode == AppLanguageMode::System) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuLangJapanese.state = (langMode == AppLanguageMode::Japanese) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuLangEnglish.state = (langMode == AppLanguageMode::English) ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)buildMenuBar {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:app_l10n::tr(@"おくさんファミコンについて", @"About Okusan Famicom CRT")
                       action:@selector(showAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItemWithTitle:app_l10n::tr(@"オープンソースライセンス...", @"Open Source Licenses...")
                       action:@selector(showOpenSourceLicenses:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *langRootItem = [[NSMenuItem alloc] initWithTitle:app_l10n::tr(@"言語 / Language", @"Language")
                                                          action:nil
                                                   keyEquivalent:@""];
    NSMenu *langMenu = [[NSMenu alloc] initWithTitle:langRootItem.title];
    _menuLangSystem = [langMenu addItemWithTitle:app_l10n::tr(@"システムに合わせる", @"Follow System")
                                          action:@selector(selectLanguageSystem:)
                                   keyEquivalent:@""];
    _menuLangJapanese = [langMenu addItemWithTitle:@"日本語"
                                            action:@selector(selectLanguageJapanese:)
                                     keyEquivalent:@""];
    _menuLangEnglish = [langMenu addItemWithTitle:@"English"
                                           action:@selector(selectLanguageEnglish:)
                                    keyEquivalent:@""];
    langRootItem.submenu = langMenu;
    [appMenu addItem:langRootItem];

    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:app_l10n::tr(@"おくさんファミコンを終了", @"Quit Okusan Famicom CRT")
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [mainMenu addItem:appItem];

    NSMenuItem *emuItem = [[NSMenuItem alloc] init];
    NSMenu *emuMenu = [[NSMenu alloc] initWithTitle:app_l10n::tr(@"エミュレータ", @"Emulator")];
    [emuMenu addItemWithTitle:app_l10n::tr(@"NES ROM を開く...", @"Open NES ROM...")
                       action:@selector(openRomDialog:)
                keyEquivalent:@"o"];
    [emuMenu addItem:[NSMenuItem separatorItem]];
    _menuPause = [emuMenu addItemWithTitle:app_l10n::tr(@"一時停止", @"Pause")
                                    action:@selector(togglePause:)
                             keyEquivalent:@"p"];
    _menuFreeze = [emuMenu addItemWithTitle:app_l10n::tr(@"接触フリーズ (F)", @"Freeze Famicom (F)")
                                     action:@selector(toggleFreeze:)
                              keyEquivalent:@""];
    [emuMenu addItemWithTitle:app_l10n::tr(@"リセット (R長押し)", @"Reset (Hold R)")
                       action:@selector(resetConsole:)
                keyEquivalent:@"r"];
    [emuMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quickSaveItem = [emuMenu addItemWithTitle:app_l10n::tr(@"クイックセーブ", @"Quick Save")
                                                   action:@selector(quickSave:)
                                            keyEquivalent:@""];
    const unichar f5Key = NSF5FunctionKey;
    quickSaveItem.keyEquivalent = [NSString stringWithCharacters:&f5Key length:1];
    quickSaveItem.keyEquivalentModifierMask = 0;

    NSMenuItem *quickLoadItem = [emuMenu addItemWithTitle:app_l10n::tr(@"クイックロード", @"Quick Load")
                                                   action:@selector(quickLoad:)
                                            keyEquivalent:@""];
    const unichar f8Key = NSF8FunctionKey;
    quickLoadItem.keyEquivalent = [NSString stringWithCharacters:&f8Key length:1];
    quickLoadItem.keyEquivalentModifierMask = 0;

    [emuMenu addItem:[NSMenuItem separatorItem]];
    _menuMute = [emuMenu addItemWithTitle:app_l10n::tr(@"ミュート", @"Mute Audio")
                                   action:@selector(toggleMute:)
                            keyEquivalent:@"m"];
    emuItem.submenu = emuMenu;
    [mainMenu addItem:emuItem];

    NSMenuItem *historyItem = [[NSMenuItem alloc] init];
    _historyMenu = [[NSMenu alloc] initWithTitle:app_l10n::tr(@"履歴", @"History")];
    _historyMenu.autoenablesItems = NO;
    historyItem.submenu = _historyMenu;
    [mainMenu addItem:historyItem];
    [self rebuildHistoryMenu];

    NSMenuItem *displayItem = [[NSMenuItem alloc] init];
    NSMenu *displayMenu = [[NSMenu alloc] initWithTitle:app_l10n::tr(@"CRT ディスプレイ", @"CRT Display")];
    displayMenu.autoenablesItems = NO;
    _menuPower = [displayMenu addItemWithTitle:app_l10n::tr(@"ファミコン電源 (O)", @"Famicom Power (O)")
                                        action:@selector(toggleConsolePower:)
                                 keyEquivalent:@""];
    [displayMenu addItem:[NSMenuItem separatorItem]];
    _menuRgb = [displayMenu addItemWithTitle:app_l10n::tr(@"RGB モニター (okusan-crt-rgb)", @"RGB Monitor (okusan-crt-rgb)")
                                      action:@selector(selectRgbMode:)
                               keyEquivalent:@"1"];
    _menuRf = [displayMenu addItemWithTitle:app_l10n::tr(@"カラー RF テレビ (okusan-crt-rf)", @"Color RF Television (okusan-crt-rf)")
                                     action:@selector(selectColorRfMode:)
                              keyEquivalent:@"2"];
    _menuBwRf = [displayMenu addItemWithTitle:app_l10n::tr(@"白黒 RF テレビ (P4蛍光体)", @"B&W RF Television (P4 Phosphor)")
                                       action:@selector(selectBwRfMode:)
                                keyEquivalent:@"3"];
    [displayMenu addItem:[NSMenuItem separatorItem]];
    _menuInterlaced = [displayMenu addItemWithTitle:app_l10n::tr(@"525本 480i インターレース (OFF = 240p)",
                                                                 @"525-Line 480i Interlace (Off = 240p)")
                                             action:@selector(toggleInterlaced:)
                                      keyEquivalent:@"i"];
    _menuHvBloom = [displayMenu addItemWithTitle:app_l10n::tr(@"フライバック HV ブルーム", @"Flyback HV Bloom")
                                          action:@selector(toggleHvBloom:)
                                   keyEquivalent:@"b"];
    _menuCurvature = [displayMenu addItemWithTitle:app_l10n::tr(@"ブラウン管曲率 (OFF = 平面)", @"Tube Curvature (Off = Flat)")
                                            action:@selector(toggleCurvature:)
                                     keyEquivalent:@"c"];
    _menuSlotMask = [displayMenu addItemWithTitle:app_l10n::tr(@"蛍光体スロットマスク", @"Phosphor Slot Mask")
                                           action:@selector(toggleSlotMask:)
                                    keyEquivalent:@"k"];
    [displayMenu addItem:[NSMenuItem separatorItem]];
    [displayMenu addItemWithTitle:app_l10n::tr(@"RF ノイズ: 弱 (0.5x)", @"RF Static: Mild (0.5x)")
                           action:@selector(selectRfMild:)
                    keyEquivalent:@""];
    [displayMenu addItemWithTitle:app_l10n::tr(@"RF ノイズ: 標準 (1.0x)", @"RF Static: Standard (1.0x)")
                           action:@selector(selectRfStandard:)
                    keyEquivalent:@""];
    [displayMenu addItemWithTitle:app_l10n::tr(@"RF ノイズ: 強 (1.6x)", @"RF Static: Heavy (1.6x)")
                           action:@selector(selectRfHeavy:)
                    keyEquivalent:@""];
    [displayMenu addItem:[NSMenuItem separatorItem]];
    [displayMenu addItemWithTitle:app_l10n::tr(@"フルスクリーン切替", @"Toggle Full Screen")
                           action:@selector(toggleFullScreen:)
                    keyEquivalent:@"f"];
    displayItem.submenu = displayMenu;
    [mainMenu addItem:displayItem];

    NSMenuItem *ctrlItem = [[NSMenuItem alloc] init];
    NSMenu *ctrlMenu = [[NSMenu alloc] initWithTitle:app_l10n::tr(@"コントローラ", @"Controller")];
    [ctrlMenu addItemWithTitle:app_l10n::tr(@"コントローラ設定...", @"Controller Settings...")
                        action:@selector(openControllerSettings:)
                 keyEquivalent:@","];
    [ctrlMenu addItem:[NSMenuItem separatorItem]];
    _menuSwapPadAB = [ctrlMenu addItemWithTitle:app_l10n::tr(@"ゲームパッド A / B 入替", @"Swap Gamepad A / B")
                                         action:@selector(toggleSwapGamepadAB:)
                                  keyEquivalent:@""];
    _menuLeftStick = [ctrlMenu addItemWithTitle:app_l10n::tr(@"左スティックを十字キーに使用", @"Use Left Stick as D-Pad")
                                         action:@selector(toggleLeftStickDpad:)
                                  keyEquivalent:@""];
    [ctrlMenu addItem:[NSMenuItem separatorItem]];
    [ctrlMenu addItemWithTitle:app_l10n::tr(@"入力設定を初期化", @"Reset Default Bindings")
                        action:@selector(resetBindingsToDefaults:)
                 keyEquivalent:@""];
    ctrlItem.submenu = ctrlMenu;
    [mainMenu addItem:ctrlItem];

    [NSApp setMainMenu:mainMenu];
    [self refreshMenuStates];
}

- (BOOL)loadAndPowerOnRom:(NSString *)romPath {
    if (!romPath || ![[NSFileManager defaultManager] fileExistsAtPath:romPath]) {
        return NO;
    }

    NSString *corePath = [[[NSBundle mainBundle] privateFrameworksPath]
                          stringByAppendingPathComponent:@"fceumm_libretro.dylib"];
    const std::string supportDir = applicationSupportDir();

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
    [self recordRecentRom:romPath];

    _paused = NO;
    _frozen = NO;
    _resetHeld = NO;
    _cartTilt = 0;
    _cartLift = 0;
    _cartPitch = 0;
    _famicom.setCartridgePose(0, 0, 0);
    _audioEngine.setFrozen(false);
    _audioEngine.setResetHeld(false);

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
        [self saveRecentRoms];
        [self rebuildHistoryMenu];

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
    [self saveRecentRoms];
    [self rebuildHistoryMenu];
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
    [self saveDisplayPreferences];
    [self refreshMenuStates];
    [_screenView requestRedraw];
}

- (void)selectRgbMode:(id)sender {
    [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.rfMode = false; c.monochrome = false; }];
}

- (void)selectColorRfMode:(id)sender {
    [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.rfMode = true; c.monochrome = false; }];
}

- (void)selectBwRfMode:(id)sender {
    [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.rfMode = true; c.monochrome = true; }];
}

- (void)toggleInterlaced:(id)sender {
    [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.interlaced = !c.interlaced; }];
}

- (void)toggleHvBloom:(id)sender {
    [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.hvBloom = (c.hvBloom > 0.1f) ? 0.0f : 1.0f; }];
}

- (void)toggleCurvature:(id)sender {
    [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.curvature = (c.curvature > 0.1f) ? 0.0f : 1.0f; }];
}

- (void)toggleSlotMask:(id)sender {
    [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.slotMask = (c.slotMask > 0.1f) ? 0.0f : 1.0f; }];
}

- (void)selectRfMild:(id)sender {
    [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.rfMode = true; c.rfSnow = 0.5f; c.rfSignal = 0.65f; }];
}

- (void)selectRfStandard:(id)sender {
    [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.rfMode = true; c.rfSnow = 1.0f; c.rfSignal = 1.0f; }];
}

- (void)selectRfHeavy:(id)sender {
    [self applyDisplayConfig:^(CrtDisplayConfig &c) { c.rfMode = true; c.rfSnow = 1.6f; c.rfSignal = 1.35f; }];
}

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

- (void)resetConsole:(id)sender {
    _frozen = NO;
    _resetHeld = NO;
    _audioEngine.setFrozen(false);
    _audioEngine.setResetHeld(false);
    [self triggerConsoleReset];
}

- (std::string)quickStatePath {
    NSString *baseName = _loadedRomPath ? [[_loadedRomPath lastPathComponent] stringByDeletingPathExtension] : @"default";
    NSCharacterSet *unsafe = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSString *sanitized = [[baseName componentsSeparatedByCharactersInSet:unsafe] componentsJoinedByString:@"_"];
    if (sanitized.length == 0) sanitized = @"game";
    return applicationSupportDir() + "/quickstate_" + std::string([sanitized UTF8String]) + ".ss";
}

- (void)quickSave:(id)sender {
    if (_famicom.isLoaded() && _screenView.consolePowered && !_frozen) {
        _famicom.saveState([self quickStatePath]);
    }
}

- (void)quickLoad:(id)sender {
    if (_famicom.isLoaded() && _screenView.consolePowered && !_frozen) {
        _famicom.loadState([self quickStatePath]);
    }
}

- (void)toggleMute:(id)sender {
    _audioEngine.setMuted(!_audioEngine.isMuted());
    [self saveDisplayPreferences];
    [self refreshMenuStates];
}

- (void)toggleFullScreen:(id)sender {
    [_window toggleFullScreen:nil];
}

- (void)toggleFreeze:(id)sender {
    if (!_famicom.isLoaded() || !_screenView.consolePowered || _resetHeld) return;
    _frozen = !_frozen;
    _audioEngine.setFrozen(_frozen == YES);
    if (_frozen) {
        [_screenView triggerFreezeGlitch];
    }
    [self refreshMenuStates];
}

- (void)toggleConsolePower:(id)sender {
    _frozen = NO;
    _resetHeld = NO;
    _audioEngine.setFrozen(false);
    _audioEngine.setResetHeld(false);

    if (!_famicom.isLoaded()) {
        [_screenView setConsolePowered:NO instant:YES];
        _audioEngine.setConsolePowered(false);
        [self refreshMenuStates];
        return;
    }

    const BOOL powerOnNext = !_screenView.consolePowered;
    _famicom.reset();
    if (!powerOnNext && !_screenView.displayConfig.rfMode) {
        [_screenView clearToBlack];
    }
    [_screenView setConsolePowered:powerOnNext instant:NO];
    _audioEngine.setConsolePowered(powerOnNext == YES);
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

- (void)handleCartridgeContactKey:(NSEvent *)event {
    if (!_famicom.isLoaded()) return;

    const BOOL shiftDown = (event.modifierFlags & NSEventModifierFlagShift) != 0;
    const int prevTilt = _cartTilt;
    const int prevLift = _cartLift;
    const int prevPitch = _cartPitch;

    if (event.keyCode == kVK_ANSI_Backslash) {
        if (!event.isARepeat) [_screenView toggleConnectorHudPinned];
        return;
    } else if (event.keyCode == kVK_ANSI_Slash) {
        if (event.isARepeat) return;
        _cartTilt = 0;
        _cartLift = 0;
        _cartPitch = 0;
    } else if (event.keyCode == kVK_ANSI_LeftBracket) {
        _cartPitch = std::max(-8, _cartPitch - 1);
    } else if (event.keyCode == kVK_ANSI_RightBracket) {
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
        if (event.keyCode == kVK_ANSI_Slash) {
            _famicom.reseatCartridge();
        } else {
            _famicom.setCartridgePose(_cartTilt, _cartLift, _cartPitch);
        }
        if (_screenView.consolePowered && (!event.isARepeat || (std::abs(_cartTilt) & 3) == 0)) {
            [_screenView triggerCartridgeBump];
        }
    }
    [_screenView showConnectorHud];
}

- (void)crtScreenDidReceiveKeyDown:(NSEvent *)event {
    const NSEventModifierFlags cmdMods =
        event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption);

    if (cmdMods == 0 && (event.keyCode == kVK_ANSI_Comma || event.keyCode == kVK_ANSI_Period ||
                         event.keyCode == kVK_ANSI_Slash || event.keyCode == kVK_ANSI_LeftBracket ||
                         event.keyCode == kVK_ANSI_RightBracket || event.keyCode == kVK_ANSI_Backslash)) {
        [self handleCartridgeContactKey:event];
        return;
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
                _frozen = NO;
                _audioEngine.setFrozen(false);
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
    [self buildMenuBar];
    if (_settingsWindow) [_settingsWindow refreshUI];
    if (_licensesWindow) [self refreshLicensesWindowText];
    [_screenView invalidateConnectorHud];
}

- (void)selectLanguageSystem:(id)sender   { [self applyLanguageMode:AppLanguageMode::System]; }
- (void)selectLanguageJapanese:(id)sender { [self applyLanguageMode:AppLanguageMode::Japanese]; }
- (void)selectLanguageEnglish:(id)sender  { [self applyLanguageMode:AppLanguageMode::English]; }

- (void)showAboutPanel:(id)sender {
    NSString *creditsText = app_l10n::tr(
        @"エミュレーションコア: FCEUmm (libretro) — GNU GPL v2.0\n"
        @"ブラウン管シェーダ & 60ピン物理接点モデル: おくさんファミコン\n\n"
        @"サードパーティ OSS の詳細はアプリメニューの「オープンソースライセンス...」をご覧ください。",
        @"Emulation Core: FCEUmm (libretro) — GNU GPL v2.0\n"
        @"CRT Shader & 60-Pin Contact Model: Okusan Famicom CRT\n\n"
        @"See \"Open Source Licenses...\" in the app menu for third-party notices.");
    NSAttributedString *credits = [[NSAttributedString alloc]
        initWithString:creditsText
            attributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:11.0],
                NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
            }];
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        NSAboutPanelOptionApplicationName: app_l10n::tr(@"おくさんファミコン", @"Okusan Famicom CRT"),
        NSAboutPanelOptionCredits: credits
    }];
}

- (void)refreshLicensesWindowText {
    if (!_licensesWindow || !_licensesTextView) return;
    _licensesWindow.title = app_l10n::tr(@"オープンソースライセンス", @"Open Source Licenses");

    NSString *header = app_l10n::tr(
        @"おくさんファミコン — 利用しているオープンソースソフトウェア\n"
        @"========================================================\n\n"
        @"1. FCEUmm (libretro)\n"
        @"   役割: NES / ファミコンエミュレーションコア（60ピン物理・バスフック改変込み）\n"
        @"   配布元: https://github.com/libretro/libretro-fceumm\n"
        @"   ベース: FCE Ultra / FCEU-mm (Xodnizel, CaH4e3, BERO, libretro contributors)\n"
        @"   ライセンス: GNU General Public License v2.0 (GPL-2.0)\n\n"
        @"2. libretro API & libretro-common（FCEUmm に内包）\n"
        @"   役割: コア共通 C ABI およびファイル・エンコーディング補助\n"
        @"   配布元: https://github.com/libretro/libretro-common\n"
        @"   ライセンス: MIT License\n\n"
        @"3. nes_ntsc & EMU2413（FCEUmm に内包）\n"
        @"   作者: Shay Green (Blargg) / Mitsutaka Okazaki\n"
        @"   ライセンス: LGPL v2.1+ / BSD-style（各ソースヘッダ参照）\n\n",
        @"Okusan Famicom CRT — Open Source Software Acknowledgments\n"
        @"========================================================\n\n"
        @"1. FCEUmm (libretro)\n"
        @"   Role: NES / Famicom emulation core (modified with 60-pin connector & bus hooks)\n"
        @"   Upstream: https://github.com/libretro/libretro-fceumm\n"
        @"   Based on FCE Ultra / FCEU-mm by Xodnizel, CaH4e3, BERO, and contributors\n"
        @"   License: GNU General Public License v2.0 (GPL-2.0)\n\n"
        @"2. libretro API & libretro-common (bundled within FCEUmm)\n"
        @"   Role: Core C ABI and portable file/encoding helpers\n"
        @"   Upstream: https://github.com/libretro/libretro-common\n"
        @"   License: MIT License\n\n"
        @"3. nes_ntsc & EMU2413 (bundled within FCEUmm)\n"
        @"   Authors: Shay Green (Blargg) / Mitsutaka Okazaki\n"
        @"   License: LGPL v2.1+ / BSD-style (see third_party/fceumm source headers)\n\n");

    NSMutableString *body = [NSMutableString stringWithString:header];
    NSString *gplPath = [[NSBundle mainBundle] pathForResource:@"LICENSE" ofType:@"txt"];
    if (gplPath) {
        NSString *gplText = [NSString stringWithContentsOfFile:gplPath encoding:NSUTF8StringEncoding error:nil];
        if (gplText) {
            [body appendString:@"--------------------------------------------------------\n\n"];
            [body appendString:gplText];
        }
    }
    _licensesTextView.string = body;
}

- (void)showOpenSourceLicenses:(id)sender {
    if (!_licensesWindow) {
        const NSRect rect = NSMakeRect(0, 0, 620, 480);
        _licensesWindow = [[NSWindow alloc]
            initWithContentRect:rect
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        _licensesWindow.minSize = NSMakeSize(420, 300);
        [_licensesWindow center];
        _licensesWindow.releasedWhenClosed = NO;

        NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:_licensesWindow.contentView.bounds];
        scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        scrollView.hasVerticalScroller = YES;
        scrollView.borderType = NSNoBorder;

        const NSSize contentSize = scrollView.contentSize;
        NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
        textView.minSize = NSMakeSize(0.0, contentSize.height);
        textView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
        textView.verticallyResizable = YES;
        textView.horizontallyResizable = NO;
        textView.autoresizingMask = NSViewWidthSizable;
        textView.textContainer.containerSize = NSMakeSize(contentSize.width, CGFLOAT_MAX);
        textView.textContainer.widthTracksTextView = YES;
        textView.editable = NO;
        textView.selectable = YES;
        textView.textContainerInset = NSMakeSize(18, 16);
        textView.backgroundColor = [NSColor textBackgroundColor];
        textView.textColor = [NSColor textColor];
        textView.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];

        _licensesTextView = textView;
        scrollView.documentView = textView;
        _licensesWindow.contentView = scrollView;
    }

    [self refreshLicensesWindowText];
    [_licensesWindow makeKeyAndOrderFront:nil];
}

- (void)applyInputBindings:(void (^)(InputBindings &bindings))mutator {
    mutator(_bindings);
    _bindings.saveToDefaults();
    [self refreshMenuStates];
    if (_settingsWindow) [_settingsWindow refreshUI];
}

- (void)toggleSwapGamepadAB:(id)sender {
    [self applyInputBindings:^(InputBindings &b) { b.swapGamepadAB = !b.swapGamepadAB; }];
}

- (void)toggleLeftStickDpad:(id)sender {
    [self applyInputBindings:^(InputBindings &b) { b.useLeftStick = !b.useLeftStick; }];
}

- (void)resetBindingsToDefaults:(id)sender {
    [self applyInputBindings:^(InputBindings &b) { b = InputBindings::defaults(); }];
}

- (uint32_t)sampleControllerMask {
    uint32_t mask = 0;

    if (isBindingDown(_bindings.keys[FC_BTN_UP], _pressedKeys))     mask |= (1u << JOYPAD_UP);
    if (isBindingDown(_bindings.keys[FC_BTN_DOWN], _pressedKeys))   mask |= (1u << JOYPAD_DOWN);
    if (isBindingDown(_bindings.keys[FC_BTN_LEFT], _pressedKeys))   mask |= (1u << JOYPAD_LEFT);
    if (isBindingDown(_bindings.keys[FC_BTN_RIGHT], _pressedKeys))  mask |= (1u << JOYPAD_RIGHT);
    if (isBindingDown(_bindings.keys[FC_BTN_B], _pressedKeys))      mask |= (1u << JOYPAD_B);
    if (isBindingDown(_bindings.keys[FC_BTN_A], _pressedKeys))      mask |= (1u << JOYPAD_A);
    if (isBindingDown(_bindings.keys[FC_BTN_SELECT], _pressedKeys)) mask |= (1u << JOYPAD_SELECT);
    if (isBindingDown(_bindings.keys[FC_BTN_START], _pressedKeys))  mask |= (1u << JOYPAD_START);

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

        if (pad.dpad.up.pressed || stickUp)         mask |= (1u << JOYPAD_UP);
        if (pad.dpad.down.pressed || stickDown)     mask |= (1u << JOYPAD_DOWN);
        if (pad.dpad.left.pressed || stickLeft)     mask |= (1u << JOYPAD_LEFT);
        if (pad.dpad.right.pressed || stickRight)   mask |= (1u << JOYPAD_RIGHT);
        if (nesB)                                   mask |= (1u << JOYPAD_B);
        if (nesA)                                   mask |= (1u << JOYPAD_A);
        if (pad.buttonMenu.pressed)                 mask |= (1u << JOYPAD_START);
        if (optionsDown || pad.leftShoulder.pressed) mask |= (1u << JOYPAD_SELECT);

        if (_bindings.allowGamepadSaveLoad) {
            l2Held = l2Held || (pad.leftTrigger.value > 0.65f);
            r2Held = r2Held || (pad.rightTrigger.value > 0.65f);
            selectHeld = selectHeld || optionsDown || pad.leftShoulder.pressed;
        }
    }

    if (l2Held && !_prevGamepadL2) {
        [self quickSave:nil];
    }
    if (r2Held && !_prevGamepadR2 && selectHeld) {
        [self quickLoad:nil];
    }
    _prevGamepadL2 = l2Held ? YES : NO;
    _prevGamepadR2 = r2Held ? YES : NO;
    return mask;
}

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
        [_screenView advanceTvRasterFrame];
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
    [self buildMenuBar];
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
