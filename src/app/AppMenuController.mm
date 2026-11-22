#import "app/AppMenuController.hpp"
#import "app/AppLocalization.hpp"
#import "input/InputBindings.hpp"
#import "video/CrtScreenView.hpp"

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

    NSMenuItem *langRootItem = [[NSMenuItem alloc] initWithTitle:app_l10n::tr(@"言語 / Language", @"Language")
                                                          action:nil
                                                   keyEquivalent:@""];
    NSMenu *langMenu = [[NSMenu alloc] initWithTitle:langRootItem.title];
    _menuLangSystem = [langMenu addItemWithTitle:app_l10n::tr(@"システムに合わせる", @"Follow System")
                                          action:@selector(selectLanguageSystem:)
                                   keyEquivalent:@""];
    _menuLangSystem.target = target;

    _menuLangJapanese = [langMenu addItemWithTitle:@"日本語"
                                            action:@selector(selectLanguageJapanese:)
                                     keyEquivalent:@""];
    _menuLangJapanese.target = target;

    _menuLangEnglish = [langMenu addItemWithTitle:@"English"
                                           action:@selector(selectLanguageEnglish:)
                                    keyEquivalent:@""];
    _menuLangEnglish.target = target;

    langRootItem.submenu = langMenu;
    [appMenu addItem:langRootItem];

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

    add(app_l10n::tr(@"NES ROM を開く...", @"Open NES ROM..."), @selector(openRomDialog:), @"o");
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
    NSMenu *displayMenu = [[NSMenu alloc] initWithTitle:app_l10n::tr(@"CRT ディスプレイ", @"CRT Display")];
    displayMenu.autoenablesItems = NO;

    auto add = [&](NSString *title, SEL sel, NSString *key) {
        NSMenuItem *item = [displayMenu addItemWithTitle:title action:sel keyEquivalent:key];
        item.target = target;
        return item;
    };

    _menuPower = add(app_l10n::tr(@"ファミコン電源 (O)", @"Famicom Power (O)"), @selector(toggleConsolePower:), @"");
    add(app_l10n::tr(@"接触不良起動 / スイッチOFF (@)", @"Contact Fault Boot / Power Off (@)"),
        @selector(toggleBadBootSwitch:), @"");
    [displayMenu addItem:[NSMenuItem separatorItem]];

    _menuRgb  = add(app_l10n::tr(@"RGB モニター (okusan-crt-rgb)", @"RGB Monitor (okusan-crt-rgb)"), @selector(selectRgbMode:), @"1");
    _menuRf   = add(app_l10n::tr(@"カラー RF テレビ (okusan-crt-rf)", @"Color RF Television (okusan-crt-rf)"), @selector(selectColorRfMode:), @"2");
    _menuBwRf = add(app_l10n::tr(@"白黒 RF テレビ (P4蛍光体)", @"B&W RF Television (P4 Phosphor)"), @selector(selectBwRfMode:), @"3");
    [displayMenu addItem:[NSMenuItem separatorItem]];

    _menuInterlaced = add(app_l10n::tr(@"525本 480i インターレース (OFF = 240p)",
                                         @"525-Line 480i Interlace (Off = 240p)"),
                          @selector(toggleInterlaced:), @"i");
    _menuHvBloom   = add(app_l10n::tr(@"フライバック HV ブルーム", @"Flyback HV Bloom"), @selector(toggleHvBloom:), @"b");
    _menuCurvature = add(app_l10n::tr(@"ブラウン管曲率 (OFF = 平面)", @"Tube Curvature (Off = Flat)"), @selector(toggleCurvature:), @"c");
    _menuSlotMask  = add(app_l10n::tr(@"蛍光体スロットマスク", @"Phosphor Slot Mask"), @selector(toggleSlotMask:), @"k");
    [displayMenu addItem:[NSMenuItem separatorItem]];

    add(app_l10n::tr(@"RF ノイズ: 弱 (0.5x)", @"RF Static: Mild (0.5x)"), @selector(selectRfMild:), @"");
    add(app_l10n::tr(@"RF ノイズ: 標準 (1.0x)", @"RF Static: Standard (1.0x)"), @selector(selectRfStandard:), @"");
    add(app_l10n::tr(@"RF ノイズ: 強 (1.6x)", @"RF Static: Heavy (1.6x)"), @selector(selectRfHeavy:), @"");
    [displayMenu addItem:[NSMenuItem separatorItem]];

    add(app_l10n::tr(@"フルスクリーン切替", @"Toggle Full Screen"), @selector(toggleFullScreen:), @"f");

    displayItem.submenu = displayMenu;
    return displayItem;
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
                        consolePowered:(BOOL)consolePowered
                         inputBindings:(const InputBindings &)bindings {
    const BOOL isBwMode = config.rfMode && config.monochrome;

    _menuRgb.state = !config.rfMode ? NSControlStateValueOn : NSControlStateValueOff;
    _menuRf.state = (config.rfMode && !config.monochrome) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuBwRf.state = isBwMode ? NSControlStateValueOn : NSControlStateValueOff;
    _menuInterlaced.state = config.interlaced ? NSControlStateValueOn : NSControlStateValueOff;
    _menuHvBloom.state = (config.hvBloom > 0.1f) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuCurvature.state = (config.curvature > 0.1f) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuSlotMask.state = (config.slotMask > 0.1f && !isBwMode) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuSlotMask.enabled = !isBwMode;

    _menuMute.state = muted ? NSControlStateValueOn : NSControlStateValueOff;
    _menuPause.state = paused ? NSControlStateValueOn : NSControlStateValueOff;
    _menuFreeze.state = frozen ? NSControlStateValueOn : NSControlStateValueOff;
    _menuPower.state = consolePowered ? NSControlStateValueOn : NSControlStateValueOff;
    _menuSwapPadAB.state = bindings.swapGamepadAB ? NSControlStateValueOn : NSControlStateValueOff;
    _menuLeftStick.state = bindings.useLeftStick ? NSControlStateValueOn : NSControlStateValueOff;

    const AppLanguageMode langMode = app_l10n::loadLanguageMode();
    _menuLangSystem.state = (langMode == AppLanguageMode::System) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuLangJapanese.state = (langMode == AppLanguageMode::Japanese) ? NSControlStateValueOn : NSControlStateValueOff;
    _menuLangEnglish.state = (langMode == AppLanguageMode::English) ? NSControlStateValueOn : NSControlStateValueOff;
}

@end
