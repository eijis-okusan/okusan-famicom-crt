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

enum class Famicom3dViewMode : int {
    NakedCrt       = 0, // Normal 60Hz unshuttered CRT (default)
    ShutterGlasses = 1, // HVC-031 TN-LCD 30Hz shutter overlay
    ParallelSbs    = 2, // Side-by-side stereo (L | R)
    CrossSbs       = 3  // Cross-eyed side-by-side stereo (R | L)
};

@protocol CrtScreenDelegate <NSObject>
- (void)crtScreenDidReceiveKeyDown:(NSEvent *)event;
- (void)crtScreenDidReceiveKeyUp:(NSEvent *)event;
- (void)crtScreenDidDropRom:(NSString *)romPath;
@end

/**
 * OpenGL CRT view executing a 2-pass beam-load + NTSC/RF shader pipeline,
 * Famicom 3D System SBS/shutter views, standby tuner snow, and the
 * interactive 60-pin cartridge connector HUD.
 */
@interface CrtScreenView : NSOpenGLView

@property (nonatomic, weak) id<CrtScreenDelegate> screenDelegate;
@property (nonatomic, assign) CrtDisplayConfig displayConfig;
@property (nonatomic, readonly) BOOL consolePowered;
@property (nonatomic, assign) Famicom3dViewMode view3dMode;
@property (nonatomic, assign) BOOL invert3dEyes;

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
- (void)showStatusBannerText:(NSString *)text;
- (void)show3dModeBanner;
- (void)showConnectorHud;
- (void)toggleConnectorHudPinned;
- (BOOL)isConnectorHudVisible;
- (void)invalidateConnectorHud;
- (void)requestRedraw;

@end
