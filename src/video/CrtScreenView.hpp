#pragma once

#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#include <cstdint>
#include "common/FamicomTypes.hpp"

class FamicomCore;

@protocol CrtScreenDelegate <NSObject>
- (void)crtScreenDidReceiveKeyDown:(NSEvent *)event;
- (void)crtScreenDidReceiveKeyUp:(NSEvent *)event;
- (void)crtScreenDidDropRom:(NSString *)romPath;
@end

/**
 * Metal CRT view executing a 2-pass beam-load + NTSC/RF/HDR-EDR shader pipeline,
 * Famicom 3D System SBS/shutter views, standby tuner snow, and the
 * interactive 60-pin cartridge connector HUD.
 */
@interface CrtScreenView : MTKView

@property (nonatomic, weak) id<CrtScreenDelegate> screenDelegate;
@property (nonatomic, assign) CrtDisplayConfig displayConfig;
@property (nonatomic, readonly) BOOL consolePowered;
@property (nonatomic, readonly) float activeHdrHeadroom;
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
