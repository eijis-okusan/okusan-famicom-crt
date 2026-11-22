#import "app/LicensesWindow.hpp"
#import "app/AppLocalization.hpp"

void presentAboutDialog() {
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

@implementation LicensesWindowController {
    NSTextView *_textView;
}

- (void)ensureWindowCreated {
    if (self.window) return;

    const NSRect rect = NSMakeRect(0, 0, 620, 480);
    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:rect
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    win.minSize = NSMakeSize(420, 300);
    [win center];
    win.releasedWhenClosed = NO;

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:win.contentView.bounds];
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

    _textView = textView;
    scrollView.documentView = textView;
    win.contentView = scrollView;
    self.window = win;
}

- (void)showLicenses {
    [self ensureWindowCreated];
    [self refreshLocalization];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)refreshLocalization {
    if (!self.window || !_textView) return;
    self.window.title = app_l10n::tr(@"オープンソースライセンス", @"Open Source Licenses");

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
    _textView.string = body;
}

@end
