#import "ControllerSettingsWindow.hpp"
#import "app/AppLocalization.hpp"
#import <Carbon/Carbon.h>
#import <GameController/GameController.h>

namespace {

NSString *buttonLabel(int index) {
    static NSString *const jaLabels[FC_BTN_COUNT] = {
        @"上 (UP)", @"下 (DOWN)", @"左 (LEFT)", @"右 (RIGHT)",
        @"B ボタン", @"A ボタン", @"SELECT", @"START"
    };
    static NSString *const enLabels[FC_BTN_COUNT] = {
        @"Up (UP)", @"Down (DOWN)", @"Left (LEFT)", @"Right (RIGHT)",
        @"B Button", @"A Button", @"SELECT", @"START"
    };
    if (index < 0 || index >= FC_BTN_COUNT) return @"";
    return app_l10n::usesJapaneseUI() ? jaLabels[index] : enLabels[index];
}

} // namespace

@interface ControllerSettingsWindow () <NSWindowDelegate>
@end

@implementation ControllerSettingsWindow {
    InputBindings *_bindings;
    void (^_onChange)(void);
    NSTextField *_headerLabel;
    NSTextField *_buttonNameLabels[FC_BTN_COUNT];
    NSTextField *_bindingLabels[FC_BTN_COUNT];
    NSButton *_changeButtons[FC_BTN_COUNT];
    NSButton *_swapABCheckbox;
    NSButton *_leftStickCheckbox;
    NSButton *_quickSaveCheckbox;
    NSTextField *_gamepadStatusLabel;
    NSButton *_resetButton;
    NSButton *_closeButton;
    int _listeningButton;
    id _keyMonitor;
}

- (instancetype)initWithBindings:(InputBindings *)bindings onChange:(void (^)(void))onChange {
    const NSRect rect = NSMakeRect(0, 0, 440, 430);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:rect
                                                   styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = app_l10n::tr(@"コントローラ設定 (1P)", @"Controller Settings (1P)");
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        _bindings = bindings;
        _onChange = [onChange copy];
        _listeningButton = -1;
        window.delegate = self;
        [self buildLayout];
        [self refreshUI];
    }
    return self;
}

- (void)dealloc {
    [self stopListening];
}

- (void)stopListening {
    if (_keyMonitor) {
        [NSEvent removeMonitor:_keyMonitor];
        _keyMonitor = nil;
    }
    _listeningButton = -1;
}

- (void)windowWillClose:(NSNotification *)notification {
    [self stopListening];
}

- (void)buildLayout {
    NSView *root = self.window.contentView;
    const CGFloat width = root.bounds.size.width;
    CGFloat y = root.bounds.size.height - 34.0;

    NSTextField *header = [NSTextField labelWithString:@""];
    header.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    header.frame = NSMakeRect(20, y, width - 40, 20);
    [root addSubview:header];
    _headerLabel = header;
    y -= 28.0;

    for (int i = 0; i < FC_BTN_COUNT; ++i) {
        NSTextField *nameLabel = [NSTextField labelWithString:@""];
        nameLabel.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightMedium];
        nameLabel.frame = NSMakeRect(24, y, 105, 20);
        [root addSubview:nameLabel];
        _buttonNameLabels[i] = nameLabel;

        NSTextField *keyLabel = [NSTextField labelWithString:@"--"];
        keyLabel.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightBold];
        keyLabel.frame = NSMakeRect(136, y, 165, 20);
        [root addSubview:keyLabel];
        _bindingLabels[i] = keyLabel;

        NSButton *changeBtn = [NSButton buttonWithTitle:@"" target:self action:@selector(onClickAssignKey:)];
        changeBtn.tag = i;
        changeBtn.frame = NSMakeRect(width - 104, y - 3, 80, 24);
        [root addSubview:changeBtn];
        _changeButtons[i] = changeBtn;

        y -= 28.0;
    }

    NSBox *divider = [[NSBox alloc] initWithFrame:NSMakeRect(20, y + 6, width - 40, 1)];
    divider.boxType = NSBoxSeparator;
    [root addSubview:divider];
    y -= 16.0;

    _gamepadStatusLabel = [NSTextField labelWithString:@""];
    _gamepadStatusLabel.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    _gamepadStatusLabel.textColor = [NSColor secondaryLabelColor];
    _gamepadStatusLabel.frame = NSMakeRect(20, y, width - 40, 18);
    [root addSubview:_gamepadStatusLabel];
    y -= 26.0;

    _swapABCheckbox = [NSButton checkboxWithTitle:@"" target:self action:@selector(onToggleOption:)];
    _swapABCheckbox.frame = NSMakeRect(20, y, width - 40, 20);
    [root addSubview:_swapABCheckbox];
    y -= 24.0;

    _leftStickCheckbox = [NSButton checkboxWithTitle:@"" target:self action:@selector(onToggleOption:)];
    _leftStickCheckbox.frame = NSMakeRect(20, y, width - 40, 20);
    [root addSubview:_leftStickCheckbox];
    y -= 24.0;

    _quickSaveCheckbox = [NSButton checkboxWithTitle:@"" target:self action:@selector(onToggleOption:)];
    _quickSaveCheckbox.frame = NSMakeRect(20, y, width - 40, 20);
    [root addSubview:_quickSaveCheckbox];

    _resetButton = [NSButton buttonWithTitle:@"" target:self action:@selector(onResetDefaults:)];
    _resetButton.frame = NSMakeRect(20, 16, 140, 28);
    [root addSubview:_resetButton];

    _closeButton = [NSButton buttonWithTitle:@"" target:self.window action:@selector(performClose:)];
    _closeButton.frame = NSMakeRect(width - 104, 16, 84, 28);
    [root addSubview:_closeButton];
}

- (void)refreshUI {
    self.window.title = app_l10n::tr(@"コントローラ設定 (1P)", @"Controller Settings (1P)");
    _headerLabel.stringValue = app_l10n::tr(@"キーボード割り当て (変更を押して入力)",
                                            @"Keyboard Bindings (Click Change, then press a key)");
    _swapABCheckbox.title = app_l10n::tr(@"ゲームパッドの A / B ボタンを入れ替える",
                                         @"Swap Gamepad A / B Buttons");
    _leftStickCheckbox.title = app_l10n::tr(@"左アナログスティックを十字キー入力に使う",
                                            @"Use Left Analog Stick as D-Pad");
    _quickSaveCheckbox.title = app_l10n::tr(@"L2 でクイックセーブ / Select+R2 でロード",
                                            @"L2 Quick Save / Select + R2 Quick Load");
    _resetButton.title = app_l10n::tr(@"初期設定に戻す", @"Reset Defaults");
    _closeButton.title = app_l10n::tr(@"閉じる", @"Close");

    for (int i = 0; i < FC_BTN_COUNT; ++i) {
        _buttonNameLabels[i].stringValue = buttonLabel(i);
        if (_listeningButton == i) {
            _bindingLabels[i].stringValue = app_l10n::tr(@"キーを入力... (Esc取消)", @"Press a key... (Esc cancels)");
            _bindingLabels[i].textColor = [NSColor systemOrangeColor];
            _changeButtons[i].title = app_l10n::tr(@"待機中", @"Listening");
            continue;
        }

        const KeyBindingGroup &group = _bindings->keys[i];
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (group.primary != kUnboundKeyCode) [parts addObject:keyLabelForVirtualCode(group.primary)];
        if (group.alt1 != kUnboundKeyCode)    [parts addObject:keyLabelForVirtualCode(group.alt1)];
        if (group.alt2 != kUnboundKeyCode)    [parts addObject:keyLabelForVirtualCode(group.alt2)];

        _bindingLabels[i].stringValue = parts.count
            ? [parts componentsJoinedByString:@" / "]
            : app_l10n::tr(@"未設定", @"Unbound");
        _bindingLabels[i].textColor = [NSColor labelColor];
        _changeButtons[i].title = app_l10n::tr(@"変更", @"Change");
    }

    _swapABCheckbox.state = _bindings->swapGamepadAB ? NSControlStateValueOn : NSControlStateValueOff;
    _leftStickCheckbox.state = _bindings->useLeftStick ? NSControlStateValueOn : NSControlStateValueOff;
    _quickSaveCheckbox.state = _bindings->allowGamepadSaveLoad ? NSControlStateValueOn : NSControlStateValueOff;

    NSArray<GCController *> *pads = [GCController controllers];
    if (pads.count > 0) {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (GCController *pad in pads) {
            [names addObject:(pad.vendorName ?: @"Gamepad")];
        }
        _gamepadStatusLabel.stringValue = [NSString stringWithFormat:@"%@%@",
                                           app_l10n::tr(@"接続中パッド: ", @"Connected Gamepad: "),
                                           [names componentsJoinedByString:@", "]];
    } else {
        _gamepadStatusLabel.stringValue = app_l10n::tr(@"接続中パッド: なし (接続すると自動認識)",
                                                       @"Connected Gamepad: None (Auto-detected)");
    }
}

- (void)onClickAssignKey:(NSButton *)sender {
    const int targetButton = (int)sender.tag;
    if (_listeningButton == targetButton) {
        [self stopListening];
        [self refreshUI];
        return;
    }

    [self stopListening];
    _listeningButton = targetButton;
    [self refreshUI];

    __weak ControllerSettingsWindow *weakSelf = self;
    _keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        ControllerSettingsWindow *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_listeningButton < 0) return event;

        const uint16_t keyCode = event.keyCode;
        if (keyCode != kVK_Escape) {
            // Unbind this key from other actions so one key doesn't fire two buttons.
            for (int b = 0; b < FC_BTN_COUNT; ++b) {
                if (b == strongSelf->_listeningButton) continue;
                KeyBindingGroup &other = strongSelf->_bindings->keys[b];
                if (other.primary == keyCode) other.primary = kUnboundKeyCode;
                if (other.alt1 == keyCode)    other.alt1 = kUnboundKeyCode;
                if (other.alt2 == keyCode)    other.alt2 = kUnboundKeyCode;
            }
            strongSelf->_bindings->keys[strongSelf->_listeningButton].primary = keyCode;
            strongSelf->_bindings->saveToDefaults();
            if (strongSelf->_onChange) strongSelf->_onChange();
        }
        [strongSelf stopListening];
        [strongSelf refreshUI];
        return nil;
    }];
}

- (void)onToggleOption:(id)sender {
    _bindings->swapGamepadAB = (_swapABCheckbox.state == NSControlStateValueOn);
    _bindings->useLeftStick = (_leftStickCheckbox.state == NSControlStateValueOn);
    _bindings->allowGamepadSaveLoad = (_quickSaveCheckbox.state == NSControlStateValueOn);
    _bindings->saveToDefaults();
    if (_onChange) _onChange();
}

- (void)onResetDefaults:(id)sender {
    [self stopListening];
    *_bindings = InputBindings::defaults();
    _bindings->saveToDefaults();
    [self refreshUI];
    if (_onChange) _onChange();
}

@end
