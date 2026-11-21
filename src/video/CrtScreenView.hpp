#pragma once

#import <Cocoa/Cocoa.h>
#include <cstdint>
#include "audio/MacAudioEngine.hpp"

class FamicomCore;

/**
 * User-configurable analog television and CRT tube display options.
 */
struct CrtDisplayConfig {
    bool rfMode = true;        // false = RGB Monitor, true = VHF RF Television
    bool monochrome = false;   // true (when rfMode) = 1970s P4 B&W RF television
    bool interlaced = true;    // true = 480i scanlines, false = 240p
    float hvBloom = 1.0f;      // Flyback high-voltage bloom strength (0.0 .. 2.0)
    float curvature = 1.0f;    // CRT glass barrel curvature (0.0 .. 1.5)
    float slotMask = 1.0f;     // Shadow/slot mask intensity (0.0 .. 1.5)
    float rfSnow = 1.0f;       // RF noise floor (0.0 .. 2.0)
    float rfSignal = 1.0f;     // RF interference / chroma artifact level (0.0 .. 2.0)
};

@protocol CrtScreenDelegate <NSObject>
- (void)crtScreenDidReceiveKeyDown:(NSEvent *)event;
- (void)crtScreenDidReceiveKeyUp:(NSEvent *)event;
- (void)crtScreenDidDropRom:(NSString *)romPath;
@end

/**
 * OpenGL CRT view executing a 2-pass beam-load + NTSC/RF shader pipeline,
 * standby tuner snow, and the interactive 60-pin cartridge connector HUD.
 */
@interface CrtScreenView : NSOpenGLView

@property (nonatomic, weak) id<CrtScreenDelegate> screenDelegate;
@property (nonatomic, assign) CrtDisplayConfig displayConfig;
@property (nonatomic, readonly) BOOL consolePowered;

- (instancetype)initWithFrame:(NSRect)frameRect core:(FamicomCore *)core;
- (void)presentLatestFrame;
- (void)clearToBlack;
- (void)advanceTvRasterFrame;
- (void)setConsolePowered:(BOOL)powered instant:(BOOL)instant;
- (void)triggerFreezeGlitch;
- (void)setFreezeEffect:(FreezeStyle)style seed:(uint32_t)seed active:(BOOL)active;
- (void)advanceFreezeEffect;
- (void)triggerResetGlitch;
- (void)triggerCartridgeBump;
- (void)showConnectorHud;
- (void)toggleConnectorHudPinned;
- (BOOL)isConnectorHudVisible;
- (void)invalidateConnectorHud;
- (void)requestRedraw;

@end
