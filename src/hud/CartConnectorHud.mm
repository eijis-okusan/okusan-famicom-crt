#import "CartConnectorHud.hpp"
#import "app/AppLocalization.hpp"
#import "core/FamicomCore.hpp"

#import <Cocoa/Cocoa.h>
#include <algorithm>
#include <cmath>
#include <cstring>

namespace cart_hud {
namespace {

// 1:1 mm scale drawing layout in logical points (rendered at 2x Retina into 1280x740).
constexpr CGFloat kPixelsPerMm   = 6.50;
constexpr CGFloat kPinPitchMm    = 2.54;
constexpr CGFloat kCenterOffsetX = 8.0;
constexpr CGFloat kFrontRowY     = 166.0;
constexpr CGFloat kBackRowY      = 126.0;

// Real HVC-001 60-pin Famicom cartridge connector physical dimensions.
constexpr CGFloat kCardWidthMm   = 78.00;
constexpr CGFloat kSlotPlayMm    = 0.35;
constexpr CGFloat kPadWidthMm    = 1.55;
constexpr CGFloat kPadBottomMm   = 1.00;
constexpr CGFloat kPadTopMm      = 7.50;
constexpr CGFloat kSpringWidthMm = 1.10;
constexpr CGFloat kSpringBotMm   = 2.50;
constexpr CGFloat kSpringTopMm   = 4.20;
constexpr CGFloat kSocketDepthMm = 10.00;
constexpr CGFloat kSocketFloorY  = 232.0;

const char *kFrontPinNames[30] = {
    "GND", "A11", "A10", "A9",  "A8",  "A7",  "A6",  "A5",  "A4",  "A3",
    "A2",  "A1",  "A0",  "R/W", "IRQ", "GND", "/RD", "CA10","PA6", "PA5",
    "PA4", "PA3", "PA2", "PA1", "PA0", "PD0", "PD1", "PD2", "PD3", "+5V"
};

const char *kBackPinNames[30] = {
    "+5V", "M2",  "A12", "A13", "A14", "D7",  "D6",  "D5",  "D4",  "D3",
    "D2",  "D1",  "D0",  "ROM", "SNI", "SNO", "/WR", "CCE", "/A13","PA7",
    "PA8", "PA9", "PA10","PA11","PA12","PA13","PD7", "PD6", "PD5", "PD4"
};

const char *describePinRole(int pinIndex, BOOL japanese) {
    static const char *const jaDescriptions[60] = {
        "GND 基準電位 (0V左端)", "CPU A11 アドレスbit11 -> PRG-ROM", "CPU A10 アドレスbit10 -> PRG-ROM",
        "CPU A9 アドレスbit9 -> PRG-ROM", "CPU A8 アドレスbit8 -> PRG-ROM", "CPU A7 アドレスbit7 -> PRG-ROM",
        "CPU A6 アドレスbit6 -> PRG-ROM", "CPU A5 アドレスbit5 -> PRG-ROM", "CPU A4 アドレスbit4 -> PRG-ROM",
        "CPU A3 アドレスbit3 -> PRG-ROM", "CPU A2 アドレスbit2 -> PRG-ROM", "CPU A1 アドレスbit1 -> PRG-ROM",
        "CPU A0 最下位アドレス -> PRG-ROM", "CPU R/W 読書切替 (H=読/L=書)", "/IRQ 外部割込 (Mapper->6502)",
        "GND 基準電位 (0V中央)", "PPU /RD CHR読出ストローブ", "CIRAM A10 画面ミラーリング制御",
        "PPU A6 タイルID bit2 (2C02->CHR)", "PPU A5 タイルID bit1 (2C02->CHR)", "PPU A4 タイルID bit0 (2C02->CHR)",
        "PPU A3 ビットプレーン0/1切替", "PPU A2 タイル内Y行 bit2", "PPU A1 タイル内Y行 bit1",
        "PPU A0 タイル内Y行 bit0", "PPU D0 画素bit0 (右端画素)", "PPU D1 画素bit1 (右2画素)",
        "PPU D2 画素bit2", "PPU D3 画素bit3 (+5V隣接)", "+5V 電源VCC (右端)",
        "+5V 電源VCC (左端)", "M2 1.79MHz CPUクロック Phi2", "CPU A12 アドレスbit12 -> PRG",
        "CPU A13 アドレスbit13 -> PRG", "CPU A14 最上位ROMアドレス", "CPU D7 命令/データbit7 (ROM->CPU)",
        "CPU D6 命令/データbit6", "CPU D5 命令/データbit5", "CPU D4 命令/データbit4",
        "CPU D3 命令/データbit3", "CPU D2 命令/データbit2", "CPU D1 命令/データbit1",
        "CPU D0 命令/データbit0 (/ROMSEL隣接)", "/ROMSEL $8000-$FFFF 選択(~A15&M2)", "Sound In 2A03音声->カセット",
        "Sound Out カセット音声->RF変調器", "PPU /WR CHR-RAM書込パルス", "CIRAM /CE 内蔵2KB VRAM有効化",
        "PPU /A13 パターン領域反転信号", "PPU A7 タイルID bit3", "PPU A8 タイルID bit4",
        "PPU A9 タイルID bit5", "PPU A10 タイルID bit6", "PPU A11 タイルID bit7",
        "PPU A12 BG($0000)/SPR($1000)選択", "PPU A13 CHR /CS (Hでネームテーブル)", "PPU D7 画素bit7 (左端画素)",
        "PPU D6 画素bit6", "PPU D5 画素bit5", "PPU D4 画素bit4 (最右端ピン!)"
    };
    static const char *const enDescriptions[60] = {
        "GND Reference (0V Left)", "CPU A11 Addr bit11 -> PRG-ROM", "CPU A10 Addr bit10 -> PRG-ROM",
        "CPU A9 Addr bit9 -> PRG-ROM", "CPU A8 Addr bit8 -> PRG-ROM", "CPU A7 Addr bit7 -> PRG-ROM",
        "CPU A6 Addr bit6 -> PRG-ROM", "CPU A5 Addr bit5 -> PRG-ROM", "CPU A4 Addr bit4 -> PRG-ROM",
        "CPU A3 Addr bit3 -> PRG-ROM", "CPU A2 Addr bit2 -> PRG-ROM", "CPU A1 Addr bit1 -> PRG-ROM",
        "CPU A0 Addr bit0 -> PRG-ROM", "CPU R/W Read/Write (H=R/L=W)", "/IRQ Mapper Ext IRQ -> 6502",
        "GND Reference (0V Center)", "PPU /RD CHR Read Strobe", "CIRAM A10 Mirroring Control",
        "PPU A6 Tile ID bit2 (2C02->CHR)", "PPU A5 Tile ID bit1 (2C02->CHR)", "PPU A4 Tile ID bit0 (2C02->CHR)",
        "PPU A3 Bitplane 0/1 Select", "PPU A2 Tile Y-row bit2", "PPU A1 Tile Y-row bit1",
        "PPU A0 Tile Y-row bit0", "PPU D0 Pixel bit0 (Rightmost)", "PPU D1 Pixel bit1",
        "PPU D2 Pixel bit2", "PPU D3 Pixel bit3 (Next to +5V)", "+5V Supply Vcc (Right)",
        "+5V Supply Vcc (Left)", "M2 1.79MHz CPU Phi2 Clock", "CPU A12 Addr bit12 -> PRG",
        "CPU A13 Addr bit13 -> PRG", "CPU A14 Top PRG ROM Addr", "CPU D7 Data bit7 (ROM->CPU)",
        "CPU D6 Data bit6", "CPU D5 Data bit5", "CPU D4 Data bit4",
        "CPU D3 Data bit3", "CPU D2 Data bit2", "CPU D1 Data bit1",
        "CPU D0 Data bit0 (Next to /ROMSEL)", "/ROMSEL $8000-$FFFF Enable", "Sound In 2A03 Audio -> Cart",
        "Sound Out Cart Audio -> RF Mod", "PPU /WR CHR-RAM Write Strobe", "CIRAM /CE Internal 2KB VRAM",
        "PPU /A13 Inverted CHR Select", "PPU A7 Tile ID bit3", "PPU A8 Tile ID bit4",
        "PPU A9 Tile ID bit5", "PPU A10 Tile ID bit6", "PPU A11 Tile ID bit7",
        "PPU A12 BG($0000)/SPR($1000)", "PPU A13 CHR /CS (H=Nametable)", "PPU D7 Pixel bit7 (Leftmost)",
        "PPU D6 Pixel bit6", "PPU D5 Pixel bit5", "PPU D4 Pixel bit4 (Edge Pin)"
    };
    if (pinIndex < 0 || pinIndex >= 60) return "";
    return japanese ? jaDescriptions[pinIndex] : enDescriptions[pinIndex];
}

struct HudTextPalette {
    NSDictionary *cornerLabel;
    NSDictionary *headerValue;
    NSDictionary *socketNote;
    NSDictionary *metrics;
    NSDictionary *rowLabel;
    NSDictionary *pinName;
    NSDictionary *inspectorTitle;
    NSDictionary *inspectorBody;
    NSDictionary *inspectorData;
    NSDictionary *legend;
    CGColorSpaceRef rgbColorSpace;
};

NSDictionary *makeTextAttrs(CGFloat size, NSFontWeight weight, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:size weight:weight],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:r green:g blue:b alpha:a]
    };
}

const HudTextPalette &textPalette() {
    static HudTextPalette palette{};
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        palette.cornerLabel    = makeTextAttrs(10.0, NSFontWeightSemibold, 0.65, 0.74, 0.84, 0.92);
        palette.headerValue    = makeTextAttrs(11.5, NSFontWeightBold,     0.96, 0.98, 1.00, 0.98);
        palette.socketNote     = makeTextAttrs( 8.5, NSFontWeightMedium,   0.78, 0.86, 0.96, 0.92);
        palette.metrics        = makeTextAttrs( 8.5, NSFontWeightSemibold, 0.86, 0.92, 0.98, 0.95);
        palette.rowLabel       = makeTextAttrs( 8.5, NSFontWeightBold,     0.65, 0.74, 0.84, 0.92);
        palette.pinName        = makeTextAttrs( 6.5, NSFontWeightBold,     0.95, 0.97, 1.00, 0.94);
        palette.inspectorTitle = makeTextAttrs( 9.0, NSFontWeightBold,     0.96, 0.98, 1.00, 0.98);
        palette.inspectorBody  = makeTextAttrs( 9.0, NSFontWeightMedium,   0.82, 0.90, 0.98, 0.94);
        palette.inspectorData  = makeTextAttrs( 9.2, NSFontWeightSemibold, 0.54, 0.94, 0.78, 0.98);
        palette.legend         = makeTextAttrs( 8.5, NSFontWeightMedium,   0.78, 0.85, 0.92, 0.90);
        palette.rgbColorSpace  = CGColorSpaceCreateDeviceRGB();
    });
    return palette;
}

/**
 * Pre-renders the static backdrop, blue connector housing, phosphor-bronze spring wipers,
 * 60 pin labels, and color legend once per language. Per-frame updates memcpy this buffer
 * first so tilting a cartridge never pays Cocoa text-layout overhead for all 60 labels.
 */
const std::vector<uint8_t> &staticTemplateBitmap(BOOL japanese) {
    static std::vector<uint8_t> templates[2];
    const int slot = japanese ? 1 : 0;
    if (!templates[slot].empty()) return templates[slot];

    std::vector<uint8_t> &templateBuffer = templates[slot];
    const HudTextPalette &palette = textPalette();
    const int bitmapW = kHudBitmapWidth;
    const int bitmapH = kHudBitmapHeight;
    const int logW = kHudLogicalWidth;
    const int logH = kHudLogicalHeight;
    templateBuffer.assign(static_cast<size_t>(bitmapW) * bitmapH * 4, 0);

    CGContextRef ctx = CGBitmapContextCreate(
        templateBuffer.data(), bitmapW, bitmapH, 8, bitmapW * 4, palette.rgbColorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!ctx) return templateBuffer;

    CGContextScaleCTM(ctx, 2.0, 2.0);

    // Translucent dark card backdrop
    CGPathRef cardOutline = CGPathCreateWithRoundedRect(CGRectMake(2, 2, logW - 4, logH - 4), 12, 12, nullptr);
    CGContextSetRGBFillColor(ctx, 0.04, 0.05, 0.07, 0.86);
    CGContextAddPath(ctx, cardOutline);
    CGContextFillPath(ctx);
    CGContextSetRGBStrokeColor(ctx, 0.72, 0.80, 0.90, 0.28);
    CGContextSetLineWidth(ctx, 1.5);
    CGContextAddPath(ctx, cardOutline);
    CGContextStrokePath(ctx);
    CGPathRelease(cardOutline);

    // Blue HVC-001 connector slot + comb ribs + fixed console leaf springs
    const CGFloat centerX = logW * 0.5 + kCenterOffsetX;
    const CGFloat slotLeftX = centerX - (kCardWidthMm * 0.5 + kSlotPlayMm) * kPixelsPerMm;
    const CGFloat slotRightX = centerX + (kCardWidthMm * 0.5 + kSlotPlayMm) * kPixelsPerMm;

    CGContextSetRGBFillColor(ctx, 0.08, 0.22, 0.44, 0.94);
    CGContextFillRect(ctx, CGRectMake(slotLeftX - 5.0, kSocketFloorY - 4.0,
                                      (slotRightX - slotLeftX) + 10.0, kSocketDepthMm * kPixelsPerMm + 4.0));
    CGContextSetRGBFillColor(ctx, 0.04, 0.08, 0.16, 0.95);
    CGContextFillRect(ctx, CGRectMake(slotLeftX, kSocketFloorY,
                                      slotRightX - slotLeftX, kSocketDepthMm * kPixelsPerMm - 2.0));

    const CGFloat combWidth = (kPinPitchMm - kSpringWidthMm) * 0.60 * kPixelsPerMm;
    CGContextSetRGBFillColor(ctx, 0.14, 0.36, 0.68, 0.55);
    for (int pos = 0; pos <= 30; ++pos) {
        const CGFloat ribX = centerX + (pos - 15.0) * kPinPitchMm * kPixelsPerMm;
        CGContextFillRect(ctx, CGRectMake(ribX - combWidth * 0.5, kSocketFloorY,
                                          combWidth, (kSocketDepthMm - 0.5) * kPixelsPerMm));
    }

    CGContextSetRGBFillColor(ctx, 0.90, 0.76, 0.40, 0.10);
    CGContextFillRect(ctx, CGRectMake(slotLeftX, kSocketFloorY + kSpringBotMm * kPixelsPerMm,
                                      slotRightX - slotLeftX, (kSpringTopMm - kSpringBotMm) * kPixelsPerMm));

    for (int pos = 0; pos < 30; ++pos) {
        const CGFloat pinX = centerX + (pos - 14.5) * kPinPitchMm * kPixelsPerMm;
        CGContextSetRGBFillColor(ctx, 0.62, 0.52, 0.28, 0.55);
        CGContextFillRect(ctx, CGRectMake(pinX - (kSpringWidthMm * 0.35) * kPixelsPerMm, kSocketFloorY,
                                          (kSpringWidthMm * 0.70) * kPixelsPerMm, kSpringBotMm * kPixelsPerMm));
        CGContextSetRGBFillColor(ctx, 0.92, 0.78, 0.44, 0.54);
        CGContextFillRect(ctx, CGRectMake(pinX - (kSpringWidthMm * 0.5) * kPixelsPerMm,
                                          kSocketFloorY + kSpringBotMm * kPixelsPerMm,
                                          kSpringWidthMm * kPixelsPerMm,
                                          (kSpringTopMm - kSpringBotMm) * kPixelsPerMm));
    }

    // Inspector panel border
    const CGRect inspectorBox = CGRectMake(12.0, 26.0, logW - 24.0, 80.0);
    CGContextSetRGBFillColor(ctx, 0.06, 0.09, 0.14, 0.90);
    CGContextFillRect(ctx, inspectorBox);
    CGContextSetRGBStrokeColor(ctx, 0.42, 0.62, 0.88, 0.50);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextStrokeRect(ctx, inspectorBox);

    NSGraphicsContext *previousGfx = [NSGraphicsContext currentContext];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO]];

    [@"PRG / CPU (L)" drawAtPoint:NSMakePoint(16, logH - 21) withAttributes:palette.cornerLabel];
    [@"PPU / CHR (R)" drawAtPoint:NSMakePoint(logW - 102, logH - 21) withAttributes:palette.cornerLabel];
    [(japanese ? @"10mm青槽" : @"10mm Slot") drawAtPoint:NSMakePoint(slotRightX + 7.0, kSocketFloorY + 26.0)
                                          withAttributes:palette.socketNote];
    [(japanese ? @"バネ" : @"Spring") drawAtPoint:NSMakePoint(12.0, kSocketFloorY + 20.0)
                                      withAttributes:palette.socketNote];
    [@"2.5-4.2" drawAtPoint:NSMakePoint(12.0, kSocketFloorY + 9.0) withAttributes:palette.socketNote];
    [(japanese ? @"手前1-30" : @"Front1-30") drawAtPoint:NSMakePoint(8.0, kFrontRowY + 4.0)
                                           withAttributes:palette.rowLabel];
    [(japanese ? @"奥31-60" : @"Back31-60") drawAtPoint:NSMakePoint(8.0, kBackRowY + 4.0)
                                          withAttributes:palette.rowLabel];

    const CGFloat tileHeight = 18.0;
    for (int pos = 0; pos < 30; ++pos) {
        const CGFloat pinX = centerX + (pos - 14.5) * kPinPitchMm * kPixelsPerMm;
        NSString *frontName = [NSString stringWithUTF8String:kFrontPinNames[pos]];
        const NSSize frontSize = [frontName sizeWithAttributes:palette.pinName];
        [frontName drawAtPoint:NSMakePoint(pinX - frontSize.width * 0.5, kFrontRowY + tileHeight + 2.0)
                withAttributes:palette.pinName];

        NSString *backName = [NSString stringWithUTF8String:kBackPinNames[pos]];
        const NSSize backSize = [backName sizeWithAttributes:palette.pinName];
        [backName drawAtPoint:NSMakePoint(pinX - backSize.width * 0.5, kBackRowY - 10.0)
               withAttributes:palette.pinName];
    }

    struct LegendEntry { CGFloat x; CGFloat r, g, b; const char *ja; const char *en; };
    static const LegendEntry legendItems[5] = {
        { 16,  0.24, 0.86, 0.50, "接続OK",            "Seated" },
        { 94,  0.96, 0.62, 0.16, "弱い(高抵抗RC)",     "Weak (High-R)" },
        { 216, 0.98, 0.86, 0.20, "怪しい(チャタ)",     "Marginal (Jitter)" },
        { 348, 0.96, 0.30, 0.30, "繋がってない(OPEN)", "Open (No Contact)" },
        { 488, 0.25, 0.88, 1.00, "隣ピン干渉(XTALK)",  "Crosstalk (XTALK)" },
    };
    for (int i = 0; i < 5; ++i) {
        CGContextSetRGBFillColor(ctx, legendItems[i].r, legendItems[i].g, legendItems[i].b, 0.98);
        CGContextFillRect(ctx, CGRectMake(legendItems[i].x, 8.0, 6.0, 6.0));
        const char *labelText = japanese ? legendItems[i].ja : legendItems[i].en;
        [[NSString stringWithUTF8String:labelText]
            drawAtPoint:NSMakePoint(legendItems[i].x + 9.0, 5.5)
            withAttributes:palette.legend];
    }

    [NSGraphicsContext setCurrentContext:previousGfx];
    CGContextRelease(ctx);
    return templateBuffer;
}

void colorForPinState(uint8_t rawState, CGFloat &r, CGFloat &g, CGFloat &b) {
    switch (rawState & 0x0Fu) {
    case 0:  r = 0.24; g = 0.86; b = 0.50; break;
    case 1:  r = 0.96; g = 0.62; b = 0.16; break;
    case 2:  r = 0.98; g = 0.86; b = 0.20; break;
    default: r = 0.96; g = 0.30; b = 0.30; break;
    }
}

void drawHeaderStatus(int width,
                      int height,
                      int tilt,
                      int lift,
                      int pitch,
                      bool pinned,
                      BOOL japanese,
                      const FamicomCore *core) {
    const HudTextPalette &palette = textPalette();
    const double leftLiftMm = static_cast<double>(core->edgeLiftUm(tilt, lift, -39000)) / 1000.0;
    const double rightLiftMm = static_cast<double>(core->edgeLiftUm(tilt, lift, +39000)) / 1000.0;

    NSString *poseText = (tilt == 0 && lift == 0 && pitch == 0)
        ? @"SEATED"
        : [NSString stringWithFormat:@"T:%+d U:%d P:%+d", tilt, lift, pitch];

    NSString *faultBadge = @"";
    if (!core->isCartridgePowered()) {
        faultBadge = japanese ? @" [通電断:砂嵐]" : @" [PWR LOST:SNOW]";
    } else if (core->isCpuJammed()) {
        faultBadge = japanese ? @" [CPU停止]" : @" [CPU JAM]";
    }

    NSString *pinBadge = pinned ? @" [LOCK:\\]" : @"";
    NSString *statusLine = [NSString stringWithFormat:@"%@%@  [L:+%.2fmm R:+%.2fmm]%@",
                            poseText, faultBadge, leftLiftMm, rightLiftMm, pinBadge];
    const NSSize textSize = [statusLine sizeWithAttributes:palette.headerValue];
    [statusLine drawAtPoint:NSMakePoint((width - textSize.width) * 0.5, height - 22)
             withAttributes:palette.headerValue];
}

void drawSocketCrossSection(CGContextRef ctx,
                            int width,
                            int tilt,
                            int lift,
                            int pitch,
                            BOOL japanese,
                            const CartPinReading *pins,
                            const FamicomCore *core) {
    const CGFloat centerX = width * 0.5 + kCenterOffsetX;
    const CGFloat latMm = static_cast<CGFloat>(core->lateralShiftUm(tilt, lift)) / 1000.0 * (tilt < 0 ? -1.0 : 1.0);
    const CGFloat drawShiftMm = std::clamp(latMm * 0.45, -kSlotPlayMm, kSlotPlayMm);
    const CGFloat slotLeftX = centerX - (kCardWidthMm * 0.5 + kSlotPlayMm) * kPixelsPerMm;
    const CGFloat slotRightX = centerX + (kCardWidthMm * 0.5 + kSlotPlayMm) * kPixelsPerMm;
    const CGFloat slotTopY = kSocketFloorY + kSocketDepthMm * kPixelsPerMm;

    const CGFloat leftRiseMm = static_cast<CGFloat>(core->edgeLiftUm(tilt, lift, -39000)) / 1000.0;
    const CGFloat rightRiseMm = static_cast<CGFloat>(core->edgeLiftUm(tilt, lift, +39000)) / 1000.0;
    const CGFloat cardLeftX = centerX + (-kCardWidthMm * 0.5 + drawShiftMm) * kPixelsPerMm;
    const CGFloat cardRightX = centerX + (+kCardWidthMm * 0.5 + drawShiftMm) * kPixelsPerMm;
    const CGFloat yLeft = kSocketFloorY + leftRiseMm * kPixelsPerMm;
    const CGFloat yRight = kSocketFloorY + rightRiseMm * kPixelsPerMm;
    const CGFloat boardHeight = 12.0 * kPixelsPerMm;
    const CGFloat slantX = -((yRight - yLeft) / (cardRightX - cardLeftX)) * boardHeight;

    // Cartridge FR4 PCB body
    CGContextSetRGBFillColor(ctx, 0.14, 0.32, 0.22, 0.38);
    CGContextSetRGBStrokeColor(ctx, 0.68, 0.86, 0.76, 0.80);
    CGContextSetLineWidth(ctx, 1.2);
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, cardLeftX + 0.6 * kPixelsPerMm, yLeft);
    CGContextAddLineToPoint(ctx, cardRightX - 0.6 * kPixelsPerMm, yRight);
    CGContextAddLineToPoint(ctx, cardRightX, yRight + 0.8 * kPixelsPerMm);
    CGContextAddLineToPoint(ctx, cardRightX + slantX, yRight + boardHeight);
    CGContextAddLineToPoint(ctx, cardLeftX + slantX, yLeft + boardHeight);
    CGContextAddLineToPoint(ctx, cardLeftX, yLeft + 0.8 * kPixelsPerMm);
    CGContextClosePath(ctx);
    CGContextDrawPath(ctx, kCGPathFillStroke);

    for (int pos = 0; pos < 30; ++pos) {
        const CGFloat frac = (pos * kPinPitchMm + (kCardWidthMm - 29.0 * kPinPitchMm) * 0.5) / kCardWidthMm;
        const CGFloat xMm = (pos - 14.5) * kPinPitchMm;
        const CGFloat padCenterX = centerX + (xMm + drawShiftMm) * kPixelsPerMm;
        const CGFloat cardBottomY = yLeft + frac * (yRight - yLeft);

        const uint8_t frontState = pins[pos].contactState & 0x0Fu;
        const uint8_t backState = pins[pos + 30].contactState & 0x0Fu;
        const uint8_t worstState = (frontState >= backState) ? pins[pos].contactState : pins[pos + 30].contactState;
        CGFloat r, g, b;
        colorForPinState(worstState, r, g, b);

        // Cartridge gold finger
        CGContextSetRGBFillColor(ctx, r * 0.70 + 0.24, g * 0.66 + 0.20, b * 0.32 + 0.08, 0.72);
        CGContextFillRect(ctx, CGRectMake(padCenterX - (kPadWidthMm * 0.5) * kPixelsPerMm,
                                          cardBottomY + kPadBottomMm * kPixelsPerMm,
                                          kPadWidthMm * kPixelsPerMm,
                                          (kPadTopMm - kPadBottomMm) * kPixelsPerMm));

        const int worstPin = (pins[pos].overlapUm <= pins[pos + 30].overlapUm) ? pos : (pos + 30);
        const CGFloat overlapMm = static_cast<CGFloat>(pins[worstPin].overlapUm) / 1000.0;
        const CGFloat riseMm = static_cast<CGFloat>(pins[worstPin].edgeLiftUm) / 1000.0;
        if (overlapMm > 0.01) {
            const CGFloat overlapBot = std::max(kSpringBotMm, kPadBottomMm + riseMm);
            const CGFloat overlapTop = std::min(kSpringTopMm, kPadTopMm + riseMm);
            if (overlapTop > overlapBot) {
                CGContextSetRGBFillColor(ctx, r, g, b, 0.96);
                CGContextFillRect(ctx, CGRectMake(centerX + (xMm - kSpringWidthMm * 0.5) * kPixelsPerMm,
                                                  kSocketFloorY + overlapBot * kPixelsPerMm,
                                                  kSpringWidthMm * kPixelsPerMm,
                                                  (overlapTop - overlapBot) * kPixelsPerMm));
            }
        } else {
            const CGFloat airGapTop = kPadBottomMm + riseMm;
            if (airGapTop > kSpringTopMm) {
                CGContextSetRGBStrokeColor(ctx, 0.98, 0.28, 0.28, 0.94);
                CGContextSetLineWidth(ctx, 1.4);
                CGContextMoveToPoint(ctx, centerX + xMm * kPixelsPerMm, kSocketFloorY + kSpringTopMm * kPixelsPerMm);
                CGContextAddLineToPoint(ctx, centerX + xMm * kPixelsPerMm, kSocketFloorY + airGapTop * kPixelsPerMm);
                CGContextStrokePath(ctx);
            }
        }
    }

    // Blue connector rim drawn over the card edges
    CGContextSetRGBStrokeColor(ctx, 0.34, 0.62, 0.96, 0.88);
    CGContextSetLineWidth(ctx, 1.5);
    CGContextMoveToPoint(ctx, slotLeftX - 5.0, slotTopY);
    CGContextAddLineToPoint(ctx, slotLeftX - 5.0, kSocketFloorY - 4.0);
    CGContextAddLineToPoint(ctx, slotRightX + 5.0, kSocketFloorY - 4.0);
    CGContextAddLineToPoint(ctx, slotRightX + 5.0, slotTopY);
    CGContextStrokePath(ctx);

    double totalAreaMm2 = 0.0;
    double maxAirGapMm = 0.0;
    int weakCount = 0, marginalCount = 0, openCount = 0, xtalkCount = 0;
    for (int i = 0; i < 60; ++i) {
        totalAreaMm2 += (static_cast<double>(pins[i].overlapUm) / 1000.0) * 1.10;
        const double gapMm = (1.00 + static_cast<double>(pins[i].edgeLiftUm) / 1000.0) - 4.20;
        if (gapMm > maxAirGapMm) maxAirGapMm = gapMm;

        switch (pins[i].contactState & 0x0Fu) {
        case 1: ++weakCount; break;
        case 2: ++marginalCount; break;
        case 3: ++openCount; break;
        default: break;
        }
        if (pins[i].contactState & 0x30u) ++xtalkCount;
    }

    const int areaPct = static_cast<int>(std::round((totalAreaMm2 / (60.0 * 1.87)) * 100.0));
    const double latShiftMm = std::abs(static_cast<double>(core->lateralShiftUm(tilt, lift)) / 1000.0);
    const double vccVolts = static_cast<double>(core->cartridgeVccMv()) / 1000.0;
    NSString *pitchLabel = japanese
        ? ((pitch == 0) ? @"水平" : (pitch > 0 ? @"奥浮" : @"手前浮"))
        : ((pitch == 0) ? @"Flat" : (pitch > 0 ? @"BackUp" : @"FrontUp"));
    NSString *metricsLine = japanese
        ? [NSString stringWithFormat:
            @"面積:%d%%(%.2fmm²) 隙間:%.2fmm 横:%.2fmm Vcc:%.2fV %@ [弱:%d 怪:%d 断:%d 隣:%d]",
            areaPct, totalAreaMm2 / 60.0, maxAirGapMm, latShiftMm, vccVolts, pitchLabel,
            weakCount, marginalCount, openCount, xtalkCount]
        : [NSString stringWithFormat:
            @"Area:%d%%(%.2fmm²) Gap:%.2fmm Lat:%.2fmm Vcc:%.2fV %@ [W:%d M:%d O:%d X:%d]",
            areaPct, totalAreaMm2 / 60.0, maxAirGapMm, latShiftMm, vccVolts, pitchLabel,
            weakCount, marginalCount, openCount, xtalkCount];
    [metricsLine drawAtPoint:NSMakePoint(12.0, 208.0) withAttributes:textPalette().metrics];
}

void drawPinRow(CGContextRef ctx, int basePinIndex, CGFloat y, int inspectedPin, const CartPinReading *pins) {
    const CGFloat centerX = kHudLogicalWidth * 0.5 + kCenterOffsetX;
    const CGFloat tileWidth = 12.6;
    const CGFloat tileHeight = 18.0;

    for (int pos = 0; pos < 30; ++pos) {
        const int pinIndex = basePinIndex + pos;
        const CGFloat pinX = centerX + (pos - 14.5) * kPinPitchMm * kPixelsPerMm;
        CGFloat r, g, b;
        colorForPinState(pins[pinIndex].contactState, r, g, b);

        const CGRect tileRect = CGRectMake(pinX - tileWidth * 0.5, y, tileWidth, tileHeight);
        CGContextSetRGBFillColor(ctx, r, g, b, 0.88);
        CGContextFillRect(ctx, tileRect);

        const CGFloat dutyBarHeight = (tileHeight - 4.0) * (static_cast<CGFloat>(pins[pinIndex].highDutyPct) / 100.0);
        if (dutyBarHeight > 0.5) {
            CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 0.42);
            CGContextFillRect(ctx, CGRectMake(pinX - 1.5, y + 2.0, 3.0, dutyBarHeight));
        }

        if (pins[pinIndex].contactState & 0x30u) {
            CGContextSetRGBStrokeColor(ctx, 0.25, 0.88, 1.0, 0.96);
            CGContextSetLineWidth(ctx, 1.4);
            CGContextStrokeRect(ctx, CGRectInset(tileRect, -1.0, -1.0));
            if ((pins[pinIndex].contactState & 0x10u) && pos > 0) {
                CGContextMoveToPoint(ctx, pinX - tileWidth * 0.5, y + tileHeight * 0.5);
                CGContextAddLineToPoint(ctx, pinX - kPinPitchMm * kPixelsPerMm + tileWidth * 0.5, y + tileHeight * 0.5);
                CGContextStrokePath(ctx);
            }
            if ((pins[pinIndex].contactState & 0x20u) && pos < 29) {
                CGContextMoveToPoint(ctx, pinX + tileWidth * 0.5, y + tileHeight * 0.5);
                CGContextAddLineToPoint(ctx, pinX + kPinPitchMm * kPixelsPerMm - tileWidth * 0.5, y + tileHeight * 0.5);
                CGContextStrokePath(ctx);
            }
        }

        if (pinIndex == inspectedPin) {
            CGContextSetRGBStrokeColor(ctx, 1.0, 1.0, 1.0, 0.98);
            CGContextSetLineWidth(ctx, 1.8);
            CGContextStrokeRect(ctx, CGRectInset(tileRect, -2.0, -2.0));
        }
    }
}

int pickDefaultInspectedPin(int selectedPin, const CartPinReading *pins) {
    if (selectedPin >= 0 && selectedPin < 60) return selectedPin;

    // Auto-focus the worst degraded pin so users immediately see the primary cause of any glitch.
    int worstPin = 21;
    uint8_t worstState = 0;
    for (int i = 0; i < 60; ++i) {
        const uint8_t contact = pins[i].contactState & 0x0Fu;
        if (contact > worstState) {
            worstState = contact;
            worstPin = i;
        }
    }
    return worstPin;
}

NSString *localizedContactLabel(uint8_t contactCode, BOOL japanese) {
    switch (contactCode) {
    case 0:  return japanese ? @"接続OK"         : @"Seated";
    case 1:  return japanese ? @"弱い(高抵抗RC)"  : @"Weak (High-R)";
    case 2:  return japanese ? @"怪しい(チャタ)"   : @"Marginal (Jitter)";
    default: return japanese ? @"繋がってない(OPEN)" : @"Open (No Contact)";
    }
}

NSString *localizedXtalkLabel(uint8_t rawState, BOOL japanese) {
    switch (rawState & 0x30u) {
    case 0x30u: return japanese ? @" + 左右隣XTALK"   : @" + L/R XTALK";
    case 0x10u: return japanese ? @" + 左隣ピンXTALK" : @" + Left XTALK";
    case 0x20u: return japanese ? @" + 右隣ピンXTALK" : @" + Right XTALK";
    default:    return @"";
    }
}

void drawPinMatrixAndInspector(CGContextRef ctx, int selectedPin, BOOL japanese, const CartPinReading *pins) {
    const HudTextPalette &palette = textPalette();
    const int inspectedPin = pickDefaultInspectedPin(selectedPin, pins);

    drawPinRow(ctx, 0, kFrontRowY, inspectedPin, pins);
    drawPinRow(ctx, 30, kBackRowY, inspectedPin, pins);

    const CartPinReading &reading = pins[inspectedPin];
    NSString *faceLabel = japanese
        ? ((inspectedPin < 30) ? @"表・手前(FRONT)" : @"裏・奥(赤側 BACK)")
        : ((inspectedPin < 30) ? @"FRONT" : @"BACK");
    NSString *pinShortName = [NSString stringWithUTF8String:(inspectedPin < 30) ? kFrontPinNames[inspectedPin]
                                                                                : kBackPinNames[inspectedPin - 30]];
    NSString *roleDesc = [NSString stringWithUTF8String:describePinRole(inspectedPin, japanese)];
    NSString *contactLabel = localizedContactLabel(reading.contactState & 0x0Fu, japanese);
    NSString *xtalkLabel = localizedXtalkLabel(reading.contactState, japanese);

    const double areaMm2 = (static_cast<double>(reading.overlapUm) / 1000.0) * 1.10;
    const int areaPct = static_cast<int>(std::round((areaMm2 / 1.87) * 100.0));
    const double gapMm = std::max(0.0, (1.00 + static_cast<double>(reading.edgeLiftUm) / 1000.0) - 4.20);
    NSString *speedLabel = japanese
        ? ((reading.activity == 2) ? @"MHz高速遷移" : ((reading.activity == 1) ? @"低速切替" : @"固定電位"))
        : ((reading.activity == 2) ? @"MHz Bus" : ((reading.activity == 1) ? @"Switching" : @"Static"));

    NSString *line1 = japanese
        ? [NSString stringWithFormat:@"選択ピン解析(クリックで切替): Pin %d [%@] %@  |  %@",
                                     inspectedPin + 1, faceLabel, pinShortName, roleDesc]
        : [NSString stringWithFormat:@"Pin Inspector (Click pin): Pin %d [%@] %@  |  %@",
                                     inspectedPin + 1, faceLabel, pinShortName, roleDesc];
    NSString *line2 = japanese
        ? [NSString stringWithFormat:@"接点状態: %@%@   面積: %.2f/1.87mm² (%d%%)   浮き: %.2fmm (隙間: %.2fmm)",
                                     contactLabel, xtalkLabel, areaMm2, areaPct,
                                     static_cast<double>(reading.edgeLiftUm) / 1000.0, gapMm]
        : [NSString stringWithFormat:@"Contact: %@%@   Area: %.2f/1.87mm² (%d%%)   Lift: %.2fmm (Gap: %.2fmm)",
                                     contactLabel, xtalkLabel, areaMm2, areaPct,
                                     static_cast<double>(reading.edgeLiftUm) / 1000.0, gapMm];
    NSString *line3 = japanese
        ? [NSString stringWithFormat:@"到来データ: High率 %u%% (%@)   誤読率 %u%%   直近バス値: $%04X -> 実効 $%04X",
                                     reading.highDutyPct, speedLabel, reading.faultRatePct,
                                     reading.drivenWord, reading.effectiveWord]
        : [NSString stringWithFormat:@"Signal: High %u%% (%@)   Fault %u%%   Bus: $%04X -> Eff $%04X",
                                     reading.highDutyPct, speedLabel, reading.faultRatePct,
                                     reading.drivenWord, reading.effectiveWord];

    [line1 drawAtPoint:NSMakePoint(20.0, 86.0) withAttributes:palette.inspectorTitle];
    [line2 drawAtPoint:NSMakePoint(20.0, 64.0) withAttributes:palette.inspectorBody];
    [line3 drawAtPoint:NSMakePoint(20.0, 42.0) withAttributes:palette.inspectorData];
}

} // namespace

bool renderConnectorHud(const FamicomCore *core,
                        int selectedPin,
                        bool pinned,
                        std::vector<uint8_t> &rgbaPixels) {
    constexpr int kPinCount = 60;
    int tilt = 0, lift = 0, pitch = 0;
    CartPinReading readings[kPinCount];
    if (!core || !core->readPinTelemetry(tilt, lift, pitch, readings, kPinCount)) return false;

    const BOOL japanese = app_l10n::usesJapaneseUI();
    const std::vector<uint8_t> &templateBytes = staticTemplateBitmap(japanese);
    if (rgbaPixels.size() != templateBytes.size()) {
        rgbaPixels.resize(templateBytes.size());
    }
    std::memcpy(rgbaPixels.data(), templateBytes.data(), templateBytes.size());

    CGContextRef ctx = CGBitmapContextCreate(
        rgbaPixels.data(), kHudBitmapWidth, kHudBitmapHeight, 8, kHudBitmapWidth * 4,
        textPalette().rgbColorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!ctx) return false;

    CGContextScaleCTM(ctx, 2.0, 2.0);
    NSGraphicsContext *previousGfx = [NSGraphicsContext currentContext];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO]];

    drawSocketCrossSection(ctx, kHudLogicalWidth, tilt, lift, pitch, japanese, readings, core);
    drawPinMatrixAndInspector(ctx, selectedPin, japanese, readings);
    drawHeaderStatus(kHudLogicalWidth, kHudLogicalHeight, tilt, lift, pitch, pinned, japanese, core);

    [NSGraphicsContext setCurrentContext:previousGfx];
    CGContextRelease(ctx);
    return true;
}

int hitTestConnectorPin(CGPoint backingPoint, CGRect hudRect) {
    if (CGRectIsEmpty(hudRect) || !CGRectContainsPoint(hudRect, backingPoint)) return -1;

    const CGFloat localX = ((backingPoint.x - hudRect.origin.x) / hudRect.size.width) * kHudLogicalWidth;
    const CGFloat localY = ((backingPoint.y - hudRect.origin.y) / hudRect.size.height) * kHudLogicalHeight;
    if (localY < 116.0 || localY > 194.0) return -1;

    const int rowBase = (localY >= 150.0) ? 0 : 30;
    const CGFloat centerX = kHudLogicalWidth * 0.5 + kCenterOffsetX;
    int closestPos = -1;
    CGFloat closestDist = 9.0;

    for (int pos = 0; pos < 30; ++pos) {
        const CGFloat pinX = centerX + (pos - 14.5) * kPinPitchMm * kPixelsPerMm;
        const CGFloat dist = std::abs(localX - pinX);
        if (dist < closestDist) {
            closestDist = dist;
            closestPos = pos;
        }
    }
    return (closestPos >= 0) ? (rowBase + closestPos) : -1;
}

} // namespace cart_hud
