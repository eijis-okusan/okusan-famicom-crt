#import "app/AppMenuController.hpp"
#import "app/AppLocalization.hpp"
#import "core/FamicomCore.hpp"
#import "input/InputBindings.hpp"
#import "video/CrtScreenView.hpp"

#include <algorithm>

namespace {

void assignUnmodifiedFunctionKey(unichar fnKey, NSMenuItem *item) {
    item.keyEquivalent = [NSString stringWithCharacters:&fnKey length:1];
    item.keyEquivalentModifierMask = 0;
}

} // namespace

@implementation AppMenuController {
    NSMenu *_historyMenu;

    NSMenuItem *_menuRgb;
    NSMenuItem *_menuRf;
    NSMenuItem *_menuBwRf;
    NSMenuItem *_menuX68k31k;
    NSMenuItem *_menuPresetRgbFlat;
    NSMenuItem *_menuPresetRfCurvedNoise;
    NSMenuItem *_menuInterlaced;
    NSMenuItem *_menuHdr;
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

    NSMenuItem *_menu3dItem;
    NSMenuItem *_mode3dItems[4];
    NSMenuItem *_invert3dEyesItem;

    NSMenuItem *_diskTopItem;
    NSMenu *_diskMenu;
    NSMenuItem *_diskFlipItem;
    NSMenuItem *_diskEjectItem;
    NSMenuItem *_diskInsertSideItems[8];
    NSMenuItem *_diskFaultItem;

    BOOL _lastMenu3dActive;
    BOOL _lastMenuFdsActive;
    int _lastMenuFdsInserted;
    int _lastMenuFdsSides;
}

- (NSMenuItem *)buildApplicationMenuWithTarget:(id)target {
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] init];

    NSMenuItem *about = [appMenu addItemWithTitle:app_l10n::tr(@"おくさんファミコンについて", @"About Okusan Famicom CRT")
                                           action:@selector(showAboutPanel:)
                                    keyEquivalent:@""];
    about.target = target;

    NSMenuItem *licenses = [appMenu addItemWithTitle:app_l10n::tr(@"オープンソースライセンス...", @"Open Source Licenses...")
                                              action:@selector(showOpenSourceLicenses:)
                                       keyEquivalent:@""];
    licenses.target = target;

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *langRootItem = [[NSMenuItem alloc] initWithTitle:app_l10n::tr(@"言語", @"Language")
                                                          action:nil
                                                   keyEquivalent:@""];
    NSMenu *langMenu = [[NSMenu alloc] initWithTitle:langRootItem.title];
    _menuLangSystem = [langMenu addItemWithTitle:app_l10n::tr(@"システムに合わせる", @"Follow System")
                                          action:@selector(selectLanguageSystem:)
                                   keyEquivalent:@""];
    _menuLangSystem.target = target;

    _menuLangJapanese = [langMenu addItemWithTitle:app_l10n::tr(@"日本語", @"Japanese")
                                            action:@selector(selectLanguageJapanese:)
                                     keyEquivalent:@""];
    _menuLangJapanese.target = target;

    _menuLangEnglish = [langMenu addItemWithTitle:app_l10n::tr(@"英語", @"English")
                                           action:@selector(selectLanguageEnglish:)
                                    keyEquivalent:@""];
    _menuLangEnglish.target = target;

    langRootItem.submenu = langMenu;
    [appMenu addItem:langRootItem];

    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *resetAllItem = [appMenu addItemWithTitle:app_l10n::tr(@"すべての設定を初期値に戻す...", @"Reset All Settings to Defaults...")
                                                  action:@selector(resetAllSettingsToDefaults:)
                                           keyEquivalent:@""];
    resetAllItem.target = target;

    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:app_l10n::tr(@"おくさんファミコンを終了", @"Quit Okusan Famicom CRT")
                       action:@selector(terminate:)
                keyEquivalent:@"q"];

    appItem.submenu = appMenu;
    return appItem;
}

- (NSMenuItem *)buildEmulatorMenuWithTarget:(id)target {
    NSMenuItem *emuItem = [[NSMenuItem alloc] init];
    NSMenu *emuMenu = [[NSMenu alloc] initWithTitle:app_l10n::tr(@"エミュレータ", @"Emulator")];

    auto add = [&](NSString *title, SEL sel, NSString *key) {
        NSMenuItem *item = [emuMenu addItemWithTitle:title action:sel keyEquivalent:key];
        item.target = target;
        return item;
    };

    add(app_l10n::tr(@"ロム / ディスクを開く...", @"Open ROM / FDS..."), @selector(openRomDialog:), @"o");
    [emuMenu addItem:[NSMenuItem separatorItem]];
    _menuPause = add(app_l10n::tr(@"一時停止", @"Pause"), @selector(togglePause:), @"p");
    _menuFreeze = add(app_l10n::tr(@"接触フリーズ (F)", @"Freeze Famicom (F)"), @selector(toggleFreeze:), @"");
    add(app_l10n::tr(@"リセット (R長押し)", @"Reset (Hold R)"), @selector(resetConsole:), @"r");
    [emuMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quickSaveItem = add(app_l10n::tr(@"クイックセーブ", @"Quick Save"), @selector(quickSave:), @"");
    assignUnmodifiedFunctionKey(NSF5FunctionKey, quickSaveItem);

    NSMenuItem *quickLoadItem = add(app_l10n::tr(@"クイックロード", @"Quick Load"), @selector(quickLoad:), @"");
    assignUnmodifiedFunctionKey(NSF8FunctionKey, quickLoadItem);

    [emuMenu addItem:[NSMenuItem separatorItem]];
    _menuMute = add(app_l10n::tr(@"ミュート", @"Mute Audio"), @selector(toggleMute:), @"m");

    emuItem.submenu = emuMenu;
    return emuItem;
}

- (NSMenuItem *)buildDisplayMenuWithTarget:(id)target {
    NSMenuItem *displayItem = [[NSMenuItem alloc] init];
    NSMenu *displayMenu = [[NSMenu alloc] initWithTitle:app_l10n::tr(@"ディスプレイ", @"CRT Display")];
    displayMenu.autoenablesItems = NO;

    auto add = [&](NSString *title, SEL sel, NSString *key) {
        NSMenuItem *item = [displayMenu addItemWithTitle:title action:sel keyEquivalent:key];
        item.target = target;
        return item;
    };

    _menuPower = add(app_l10n::tr(@"ファミコン電源 (O)", @"Famicom Power (O)"), @selector(toggleConsolePower:), @"");
    add(app_l10n::tr(@"接触不良起動 / スイッチオフ (@)", @"Contact Fault Boot / Power Off (@)"),
        @selector(toggleBadBootSwitch:), @"");
    [displayMenu addItem:[NSMenuItem separatorItem]];

    _menuRgb     = add(app_l10n::tr(@"RGB モニター接続", @"RGB Monitor"), @selector(selectRgbMode:), @"1");
    _menuRf      = add(app_l10n::tr(@"カラー RF テレビ接続", @"Color RF Television"), @selector(selectColorRfMode:), @"2");
    _menuBwRf    = add(app_l10n::tr(@"白黒 RF テレビ (P4蛍光体)", @"B&W RF Television (P4 Phosphor)"), @selector(selectBwRfMode:), @"3");
    _menuX68k31k = add(app_l10n::tr(@"CZ-612D 31kHz", @"CZ-612D 31kHz"),
                       @selector(selectX68k31kMode:), @"6");
    [displayMenu addItem:[NSMenuItem separatorItem]];
    _menuPresetRgbFlat       = add(app_l10n::tr(@"プリセット: RGB + フラット", @"Preset: RGB + Flat"),
                                   @selector(selectPresetRgbFlat:), @"4");
    _menuPresetRfCurvedNoise = add(app_l10n::tr(@"プリセット: RF + 湾曲・ノイズ付き", @"Preset: RF + Curved & Noise"),
                                   @selector(selectPresetRfCurvedNoise:), @"5");
    [displayMenu addItem:[NSMenuItem separatorItem]];

    _menuInterlaced = add(app_l10n::tr(@"525本 480i インターレース (オフで 240p)",
                                         @"525-Line 480i Interlace (Off = 240p)"),
                          @selector(toggleInterlaced:), @"i");
    _menuHdr       = add(app_l10n::tr(@"HDR ブラウン管ピーク強調", @"HDR CRT Luminance (EDR)"),
                         @selector(toggleHdr:), @"d");
    _menuHvBloom   = add(app_l10n::tr(@"フライバック高圧ブルーム", @"Flyback HV Bloom"), @selector(toggleHvBloom:), @"b");
    _menuCurvature = add(app_l10n::tr(@"ブラウン管の湾曲 (オフで平面)", @"Tube Curvature (Off = Flat)"), @selector(toggleCurvature:), @"c");
    _menuSlotMask  = add(app_l10n::tr(@"蛍光体スロットマスク", @"Phosphor Slot Mask"), @selector(toggleSlotMask:), @"k");
    [displayMenu addItem:[NSMenuItem separatorItem]];

    add(app_l10n::tr(@"RF ノイズ: 弱 (0.5倍)", @"RF Static: Mild (0.5x)"), @selector(selectRfMild:), @"");
    add(app_l10n::tr(@"RF ノイズ: 標準 (1.0倍)", @"RF Static: Standard (1.0x)"), @selector(selectRfStandard:), @"");
    add(app_l10n::tr(@"RF ノイズ: 強 (1.6倍)", @"RF Static: Heavy (1.6x)"), @selector(selectRfHeavy:), @"");
    [displayMenu addItem:[NSMenuItem separatorItem]];

    _menu3dItem = [[NSMenuItem alloc] initWithTitle:app_l10n::tr(@"ファミコン 3Dシステム (G)", @"Famicom 3D System (G)")
                                             action:nil
                                      keyEquivalent:@""];
    NSMenu *menu3d = [[NSMenu alloc] initWithTitle:_menu3dItem.title];
    menu3d.autoenablesItems = NO;
    NSString *mode3dTitles[4] = {
        app_l10n::tr(@"裸眼 (60Hz 交互表示)", @"Raw 60Hz CRT (Unshuttered)"),
        app_l10n::tr(@"3Dスコープ実機 (液晶シャッター＋残像)", @"3D Scope (HVC-031 Shutter + Glow)"),
        app_l10n::tr(@"並行視 (左右分割・瞳孔間制限)", @"Parallel SBS (65mm IPD Cap)"),
        app_l10n::tr(@"交差視 (左右分割・左右反転)", @"Cross-Eyed SBS (R | L)")
    };
    for (int i = 0; i < 4; ++i) {
        NSMenuItem *item = [menu3d addItemWithTitle:mode3dTitles[i]
                                             action:@selector(select3dModeFromMenu:)
                                      keyEquivalent:@""];
        item.target = target;
        item.tag = i;
        _mode3dItems[i] = item;
    }
    [menu3d addItem:[NSMenuItem separatorItem]];
    _invert3dEyesItem = [menu3d addItemWithTitle:app_l10n::tr(@"左右の映像を入れ替える", @"Swap Left / Right Eyes")
                                          action:@selector(toggleInvert3dEyes:)
                                   keyEquivalent:@""];
    _invert3dEyesItem.target = target;
    _menu3dItem.submenu = menu3d;
    _menu3dItem.hidden = YES;
    _menu3dItem.enabled = NO;
    [displayMenu addItem:_menu3dItem];
    [displayMenu addItem:[NSMenuItem separatorItem]];

    add(app_l10n::tr(@"フルスクリーン切替", @"Toggle Full Screen"), @selector(toggleFullScreen:), @"f");

    displayItem.submenu = displayMenu;
    return displayItem;
}

- (NSMenuItem *)buildDiskMenuWithTarget:(id)target {
    _diskTopItem = [[NSMenuItem alloc] init];
    _diskMenu = [[NSMenu alloc] initWithTitle:app_l10n::tr(@"ディスク", @"Disk")];
    _diskMenu.autoenablesItems = NO;

    auto add = [&](NSString *title, SEL sel) {
        NSMenuItem *item = [_diskMenu addItemWithTitle:title action:sel keyEquivalent:@""];
        item.target = target;
        return item;
    };

    add(app_l10n::tr(@"ディスクを入れ替える...", @"Hot-Swap Disk (.fds)..."), @selector(openFdsHotSwapDialog:));
    [_diskMenu addItem:[NSMenuItem separatorItem]];
    _diskFlipItem = add(app_l10n::tr(@"ディスクを裏返す (C)", @"Flip Disk Side (C)"), @selector(flipFdsDisk:));
    _diskEjectItem = add(app_l10n::tr(@"ディスクを抜く (E)", @"Eject Disk (E)"), @selector(ejectFdsDisk:));
    [_diskMenu addItem:[NSMenuItem separatorItem]];

    for (int s = 0; s < 8; ++s) {
        NSString *title = nil;
        if (s == 0) {
            title = app_l10n::tr(@"A面を入れる (1)", @"Insert Side A (1)");
        } else if (s == 1) {
            title = app_l10n::tr(@"B面を入れる (2)", @"Insert Side B (2)");
        } else {
            const int diskNo = 1 + (s / 2);
            const char sideCh = (s & 1) ? 'B' : 'A';
            NSString *keyHint = (s < 4) ? [NSString stringWithFormat:@" (%d)", s + 1] : @"";
            title = app_l10n::tr(
                [NSString stringWithFormat:@"ディスク %d %c面を入れる%@", diskNo, sideCh, keyHint],
                [NSString stringWithFormat:@"Insert Disk %d Side %c%@", diskNo, sideCh, keyHint]);
        }
        NSMenuItem *sideItem = add(title, @selector(insertFdsSideFromMenu:));
        sideItem.tag = s;
        _diskInsertSideItems[s] = sideItem;
    }

    [_diskMenu addItem:[NSMenuItem separatorItem]];
    _diskFaultItem = add(app_l10n::tr(@"エラー再読込 (ランダム故障) (T)", @"Simulate Read Error (Random Fault) (T)"),
                         @selector(triggerFdsRandomFault:));

    _diskTopItem.submenu = _diskMenu;
    _diskTopItem.hidden = YES;
    return _diskTopItem;
}

- (NSMenuItem *)buildControllerMenuWithTarget:(id)target {
    NSMenuItem *ctrlItem = [[NSMenuItem alloc] init];
    NSMenu *ctrlMenu = [[NSMenu alloc] initWithTitle:app_l10n::tr(@"コントローラ", @"Controller")];

    auto add = [&](NSString *title, SEL sel, NSString *key) {
        NSMenuItem *item = [ctrlMenu addItemWithTitle:title action:sel keyEquivalent:key];
        item.target = target;
        return item;
    };

    add(app_l10n::tr(@"コントローラ設定...", @"Controller Settings..."), @selector(openControllerSettings:), @",");
    [ctrlMenu addItem:[NSMenuItem separatorItem]];
    _menuSwapPadAB = add(app_l10n::tr(@"ゲームパッド A / B 入替", @"Swap Gamepad A / B"), @selector(toggleSwapGamepadAB:), @"");
    _menuLeftStick = add(app_l10n::tr(@"左スティックを十字キーに使用", @"Use Left Stick as D-Pad"), @selector(toggleLeftStickDpad:), @"");
    [ctrlMenu addItem:[NSMenuItem separatorItem]];
    add(app_l10n::tr(@"入力設定を初期化", @"Reset Default Bindings"), @selector(resetBindingsToDefaults:), @"");

    ctrlItem.submenu = ctrlMenu;
    return ctrlItem;
}

- (void)installMenuBarWithTarget:(id)target {
    NSMenu *mainMenu = [[NSMenu alloc] init];
    [mainMenu addItem:[self buildApplicationMenuWithTarget:target]];
    [mainMenu addItem:[self buildEmulatorMenuWithTarget:target]];

    NSMenuItem *historyItem = [[NSMenuItem alloc] init];
    _historyMenu = [[NSMenu alloc] initWithTitle:app_l10n::tr(@"履歴", @"History")];
    _historyMenu.autoenablesItems = NO;
    historyItem.submenu = _historyMenu;
    [mainMenu addItem:historyItem];

    [mainMenu addItem:[self buildDisplayMenuWithTarget:target]];
    [mainMenu addItem:[self buildDiskMenuWithTarget:target]];
    [mainMenu addItem:[self buildControllerMenuWithTarget:target]];

    [NSApp setMainMenu:mainMenu];
}

- (void)rebuildHistoryMenuWithPaths:(NSArray<NSString *> *)recentPaths
                         activePath:(NSString *)activeRomPath
                             target:(id)target {
    if (!_historyMenu) return;
    [_historyMenu removeAllItems];

    if (recentPaths.count == 0) {
        NSMenuItem *emptyItem = [_historyMenu addItemWithTitle:app_l10n::tr(@"(履歴なし)", @"No Recent ROMs")
                                                        action:nil
                                                 keyEquivalent:@""];
        emptyItem.enabled = NO;
        [_historyMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *clearItem = [_historyMenu addItemWithTitle:app_l10n::tr(@"履歴をクリア", @"Clear History")
                                                        action:@selector(clearRecentRoms:)
                                                 keyEquivalent:@""];
        clearItem.target = target;
        clearItem.enabled = NO;
        return;
    }

    NSString *normalizedActive = activeRomPath ? [activeRomPath stringByStandardizingPath] : nil;
    for (NSUInteger i = 0; i < recentPaths.count; ++i) {
        NSString *romPath = recentPaths[i];
        NSString *displayName = [[romPath lastPathComponent] stringByDeletingPathExtension];
        if (displayName.length == 0) {
            displayName = romPath.lastPathComponent.length ? romPath.lastPathComponent : romPath;
        }
        NSString *itemTitle = [NSString stringWithFormat:@"%lu. %@", (unsigned long)(i + 1), displayName];
        NSMenuItem *item = [_historyMenu addItemWithTitle:itemTitle
                                                   action:@selector(playRecentRom:)
                                            keyEquivalent:@""];
        item.target = target;
        item.representedObject = romPath;
        item.toolTip = romPath;
        item.enabled = YES;
        item.state = (normalizedActive && [normalizedActive isEqualToString:romPath])
            ? NSControlStateValueOn
            : NSControlStateValueOff;
    }

    [_historyMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *clearItem = [_historyMenu addItemWithTitle:app_l10n::tr(@"履歴をクリア", @"Clear History")
                                                    action:@selector(clearRecentRoms:)
                                             keyEquivalent:@""];
    clearItem.target = target;
    clearItem.enabled = YES;
}

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
                             fdsStatus:(const FdsDriveStatus &)fdsStatus {
    const BOOL isBwMode = config.rfMode && config.monochrome;
    const BOOL isX68kMode = !config.rfMode && config.x68k31kMode;

    _menuRgb.state = (!config.rfMode && !isX68kMode) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuRf.state = (config.rfMode && !config.monochrome) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuBwRf.state = isBwMode ? NSControlStateValueOn : NSControlStateValueOff;
    _menuX68k31k.state = isX68kMode ? NSControlStateValueOn : NSControlStateValueOff;
    _menuPresetRgbFlat.state = (!config.rfMode && !isX68kMode && config.curvature < 0.1f)
                                   ? NSControlStateValueOn
                                   : NSControlStateValueOff;
    _menuPresetRfCurvedNoise.state = (config.rfMode && !config.monochrome &&
                                      config.curvature > 0.1f && config.rfSnow > 0.1f)
                                         ? NSControlStateValueOn
                                         : NSControlStateValueOff;
    _menuInterlaced.enabled = !isX68kMode;
    _menuInterlaced.state = (!isX68kMode && config.interlaced) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuHdr.state = config.hdrEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    _menuHvBloom.state = (config.hvBloom > 0.1f) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuCurvature.state = (config.curvature > 0.1f) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuSlotMask.state = (config.slotMask > 0.1f && !isBwMode) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuSlotMask.enabled = !isBwMode;

    _menuMute.state = muted ? NSControlStateValueOn : NSControlStateValueOff;
    _menuPause.state = paused ? NSControlStateValueOn : NSControlStateValueOff;
    _menuFreeze.state = frozen ? NSControlStateValueOn : NSControlStateValueOff;
    _menuPower.state = (coreLoaded && consolePowered) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuSwapPadAB.state = bindings.swapGamepadAB ? NSControlStateValueOn : NSControlStateValueOff;
    _menuLeftStick.state = bindings.useLeftStick ? NSControlStateValueOn : NSControlStateValueOff;

    const AppLanguageMode langMode = app_l10n::loadLanguageMode();
    _menuLangSystem.state = (langMode == AppLanguageMode::System) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuLangJapanese.state = (langMode == AppLanguageMode::Japanese) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuLangEnglish.state = (langMode == AppLanguageMode::English) ? NSControlStateValueOn : NSControlStateValueOff;

    const BOOL threeD = (coreLoaded && threeDActive) ? YES : NO;
    _menu3dItem.hidden = !threeD;
    _menu3dItem.enabled = threeD;
    for (int i = 0; i < 4; ++i) {
        _mode3dItems[i].state = (static_cast<int>(view3dMode) == i) ? NSControlStateValueOn : NSControlStateValueOff;
        _mode3dItems[i].enabled = threeD;
    }
    _invert3dEyesItem.state = invert3dEyes ? NSControlStateValueOn : NSControlStateValueOff;
    _invert3dEyesItem.enabled = threeD;
    _lastMenu3dActive = threeD;

    const BOOL fdsOn = (coreLoaded && fdsStatus.active) ? YES : NO;
    _diskTopItem.hidden = !fdsOn;
    if (fdsOn) {
        const BOOL hasDisk = (fdsStatus.insertedSide >= 0);
        const BOOL canFlip = (hasDisk && fdsStatus.totalSides >= 2);
        _diskFlipItem.enabled = canFlip;
        _diskEjectItem.enabled = hasDisk;
        for (int s = 0; s < 8; ++s) {
            NSMenuItem *item = _diskInsertSideItems[s];
            const BOOL showSlot = (s < std::max(2, fdsStatus.totalSides));
            item.hidden = !showSlot;
            item.enabled = (!hasDisk && s < fdsStatus.totalSides);
            item.state = (fdsStatus.insertedSide == s) ? NSControlStateValueOn : NSControlStateValueOff;
        }
        _diskFaultItem.enabled = (fdsStatus.totalSides > 0);
    }
    _lastMenuFdsActive = fdsOn;
    _lastMenuFdsInserted = fdsStatus.insertedSide;
    _lastMenuFdsSides = fdsStatus.totalSides;
}

- (BOOL)needsDynamicMenuSyncForThreeD:(BOOL)threeDActive
                            fdsStatus:(const FdsDriveStatus &)fdsStatus {
    return (threeDActive != _lastMenu3dActive) ||
           ((fdsStatus.active ? YES : NO) != _lastMenuFdsActive) ||
           (fdsStatus.insertedSide != _lastMenuFdsInserted) ||
           (fdsStatus.totalSides != _lastMenuFdsSides);
}

@end
