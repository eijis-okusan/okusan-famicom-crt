#import "CrtScreenView.hpp"
#import "app/AppLocalization.hpp"
#import "core/FamicomCore.hpp"
#import "hud/CartConnectorHud.hpp"
#import "video/CrtMetalPipeline.hpp"
#import "video/FreezeFrameGenerator.hpp"
#import "video/StatusBanner.hpp"

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include <algorithm>
#include <cmath>
#include <vector>

namespace {

NSString *firstDroppedRomPath(NSPasteboard *pasteboard) {
    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[[NSURL class]]
                                                       options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    for (NSURL *url in urls) {
        if (!url.isFileURL) continue;
        NSString *ext = [url.pathExtension lowercaseString];
        if ([ext isEqualToString:@"nes"] ||
            [ext isEqualToString:@"fds"] ||
            [ext isEqualToString:@"rom"] ||
            [ext isEqualToString:@"bin"]) {
            return url.path;
        }
    }
    return nil;
}

} // namespace

@implementation CrtScreenView {
    FamicomCore *_core;
    BOOL _metalReady;

    id<MTLCommandQueue> _cmdQueue;
    crt_mtl::CrtMetalPipelines _pipes;
    id<MTLTexture> _frameRingTex[4];
    int _frameRingIdx;
    id<MTLTexture> _curTex;
    id<MTLTexture> _prevTex;
    id<MTLTexture> _eyeRingTex[2][2];
    int _eyeRingIdx[2];
    id<MTLTexture> _eyeLeftTex;
    id<MTLTexture> _eyeRightTex;
    id<MTLTexture> _beamLoadTex;

    int _frameCounter;
    int _last3dRawEye;
    Famicom3dViewMode _view3dMode;
    BOOL _invert3dEyes;
    CrtStatusBanner _banner;

    BOOL _consolePowered;
    CFAbsoluteTime _powerSwitchTime;
    CFAbsoluteTime _transientTime;
    float _transientPeak;
    float _transientDecay;

    // Connector HUD overlay state & dirty-tracking cache
    CFAbsoluteTime _hudShownTime;
    BOOL _hudPinned;
    int _selectedPin;
    CGRect _hudBackingRect;
    id<MTLTexture> _hudTex;
    std::vector<uint8_t> _hudBitmap;
    CFAbsoluteTime _hudLastUploadTime;
    int _hudCachedTilt;
    int _hudCachedLift;
    int _hudCachedPitch;
    int _hudCachedPin;
    BOOL _hudCachedPinned;
    BOOL _hudCachedPowered;
    BOOL _hudCachedJammed;
    BOOL _hudNeedsRefresh;

    // Synthetic crash-screen generator so toggling freeze off restores the live game untouched
    FreezeFrameGenerator _freezeGenerator;
}

@synthesize displayConfig = _displayConfig;

#pragma mark - Initialization & HDR Layer Configuration

- (instancetype)initWithFrame:(NSRect)frameRect core:(FamicomCore *)core {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    self = [super initWithFrame:frameRect device:dev];
    if (self) {
        _core = core;
        _displayConfig = CrtDisplayConfig{};
        _consolePowered = YES;
        _powerSwitchTime = CFAbsoluteTimeGetCurrent() - 5.0;
        _transientTime = _powerSwitchTime;
        _transientPeak = 0.0f;
        _transientDecay = 28.0f;

        _hudShownTime = -1000.0;
        _hudPinned = NO;
        _selectedPin = -1;
        _hudBackingRect = CGRectZero;
        _hudLastUploadTime = -1000.0;
        _hudCachedTilt = 9999;
        _hudCachedPin = -99;
        _hudNeedsRefresh = YES;
        _view3dMode = Famicom3dViewMode::NakedCrt;
        _invert3dEyes = NO;
        _banner.showTime = -1000.0;

        self.colorPixelFormat = MTLPixelFormatRGBA16Float;
        self.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        self.paused = YES;
        self.enableSetNeedsDisplay = YES;
        self.autoResizeDrawable = YES;
        self.framebufferOnly = YES;

        [self configureMetalLayerHdr];
        [self ensureMetalReady];
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    }
    return self;
}

- (void)configureMetalLayerHdr {
    if (![self.layer isKindOfClass:[CAMetalLayer class]]) return;
    CAMetalLayer *metalLayer = static_cast<CAMetalLayer *>(self.layer);
    metalLayer.pixelFormat = MTLPixelFormatRGBA16Float;
    metalLayer.wantsExtendedDynamicRangeContent = _displayConfig.hdrEnabled ? YES : NO;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    if (cs) {
        metalLayer.colorspace = cs;
        CGColorSpaceRelease(cs);
    }
}

- (void)setDisplayConfig:(CrtDisplayConfig)displayConfig {
    _displayConfig = displayConfig;
    [self configureMetalLayerHdr];
}

- (float)activeHdrHeadroom {
    if (!_displayConfig.hdrEnabled) return 1.0f;
    NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
    if (!screen) return 1.0f;
    return std::clamp(static_cast<float>(screen.maximumExtendedDynamicRangeColorComponentValue), 1.0f, 3.5f);
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self configureMetalLayerHdr];
}

- (void)dealloc {
    _banner.destroyMetal();
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return firstDroppedRomPath([sender draggingPasteboard]) ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSString *romPath = firstDroppedRomPath([sender draggingPasteboard]);
    if (!romPath) return NO;
    if (self.screenDelegate) {
        [self.screenDelegate crtScreenDidDropRom:romPath];
    }
    return YES;
}

- (BOOL)consolePowered {
    return _consolePowered;
}

- (void)setConsolePowered:(BOOL)powered instant:(BOOL)instant {
    _consolePowered = powered;
    _powerSwitchTime = CFAbsoluteTimeGetCurrent() - (instant ? 5.0 : 0.0);
    if (!powered && instant) {
        [self clearToBlack];
    } else {
        [self requestRedraw];
    }
}

- (void)triggerTransientPeak:(float)peak decay:(float)decay {
    _transientTime = CFAbsoluteTimeGetCurrent();
    _transientPeak = peak;
    _transientDecay = decay;
    [self requestRedraw];
}

- (void)triggerFreezeGlitch {
    [self triggerTransientPeak:0.55f decay:28.0f];
}

- (void)pushRingFramePixels:(const uint32_t *)pixels width:(unsigned)width height:(unsigned)height {
    _frameRingIdx = (_frameRingIdx + 1) & 3;
    _prevTex = _curTex;
    _curTex = _frameRingTex[_frameRingIdx];
    crt_mtl::uploadTopDownBgraTexture(_curTex, pixels, width, height);
}

- (void)pushRingPairPrev:(const uint32_t *)prevPixels
                     cur:(const uint32_t *)curPixels
                   width:(unsigned)width
                  height:(unsigned)height {
    [self ensureMetalReady];
    [self pushRingFramePixels:prevPixels width:width height:height];
    [self pushRingFramePixels:curPixels width:width height:height];
}

- (void)setFreezeEffect:(FreezeStyle)style seed:(uint32_t)seed active:(BOOL)active {
    if (!_core) return;
    if (!active) {
        const BOOL wasActive = _freezeGenerator.active() ? YES : NO;
        _freezeGenerator.clear();
        if (wasActive && _core->isLoaded()) {
            [self pushRingPairPrev:_core->previousPixels()
                               cur:_core->currentPixels()
                             width:_core->width()
                            height:_core->height()];
        }
        [self requestRedraw];
        return;
    }

    _freezeGenerator.capture(style, seed, _core->width(), _core->height(),
                             _core->currentPixels(), _core->previousPixels());
    if (style != FreezeStyle::CleanTone && style != FreezeStyle::MachineGunStutter &&
        _freezeGenerator.width() > 0 && _freezeGenerator.height() > 0) {
        const uint32_t *initPx = _freezeGenerator.primaryPixels();
        [self pushRingPairPrev:initPx cur:initPx width:_freezeGenerator.width() height:_freezeGenerator.height()];
    }
    [self triggerFreezeGlitch];
}

- (void)advanceFreezeEffect {
    ++_frameCounter;
    if (_freezeGenerator.advanceFrameAndShouldUpload()) {
        [self ensureMetalReady];
        [self pushRingFramePixels:_freezeGenerator.activeDisplayPixels()
                            width:_freezeGenerator.width()
                           height:_freezeGenerator.height()];
    }
    [self setNeedsDisplay:YES];
}

- (void)triggerResetGlitch {
    [self triggerTransientPeak:0.92f decay:18.0f];
}

- (void)triggerCartridgeBump {
    [self triggerTransientPeak:0.42f decay:32.0f];
}

- (void)showConnectorHud {
    _hudShownTime = CFAbsoluteTimeGetCurrent();
    _hudNeedsRefresh = YES;
    [self requestRedraw];
}

- (void)toggleConnectorHudPinned {
    _hudPinned = !_hudPinned;
    if (_hudPinned) {
        _hudShownTime = CFAbsoluteTimeGetCurrent();
    }
    _hudNeedsRefresh = YES;
    [self requestRedraw];
}

- (BOOL)isConnectorHudVisible {
    if (_hudPinned) return YES;
    const double elapsed = CFAbsoluteTimeGetCurrent() - _hudShownTime;
    return (elapsed >= 0.0 && elapsed < 1.35);
}

- (void)invalidateConnectorHud {
    _hudNeedsRefresh = YES;
    [self requestRedraw];
}

- (void)ensureMetalReady {
    if (_metalReady || !self.device) return;
    _cmdQueue = [self.device newCommandQueue];
    if (!crt_mtl::createPipelines(self.device, self.colorPixelFormat, _pipes)) return;

    for (int i = 0; i < 4; ++i) {
        _frameRingTex[i] = crt_mtl::createFrameTexture(self.device);
    }
    _frameRingIdx = 0;
    _curTex = _frameRingTex[0];
    _prevTex = _frameRingTex[3];
    for (int e = 0; e < 2; ++e) {
        for (int b = 0; b < 2; ++b) {
            _eyeRingTex[e][b] = nil;
        }
        _eyeRingIdx[e] = 0;
    }
    _eyeLeftTex = nil;
    _eyeRightTex = nil;

    MTLTextureDescriptor *beamDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                           width:1
                                                          height:1
                                                       mipmapped:NO];
    beamDesc.storageMode = MTLStorageModePrivate;
    beamDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    _beamLoadTex = [self.device newTextureWithDescriptor:beamDesc];

    _metalReady = YES;
}

- (void)ensureStereoEyeTexturesReady {
    if (_eyeRingTex[0][0]) return;
    for (int e = 0; e < 2; ++e) {
        for (int b = 0; b < 2; ++b) {
            _eyeRingTex[e][b] = crt_mtl::createFrameTexture(self.device);
        }
    }
    _eyeLeftTex = _eyeRingTex[0][0];
    _eyeRightTex = _eyeRingTex[1][0];
}

- (void)presentLatestFrame {
    if (!_core) return;
    [self ensureMetalReady];
    const unsigned width = _core->width();
    const unsigned height = _core->height();
    [self pushRingFramePixels:_core->currentPixels() width:width height:height];
    if (_core->is3dSystemActive()) {
        [self ensureStereoEyeTexturesReady];
        const int eye = _core->current3dEye() & 1;
        _last3dRawEye = eye;
        const int nextSlot = 1 - _eyeRingIdx[eye];
        _eyeRingIdx[eye] = nextSlot;
        id<MTLTexture> eyeTex = _eyeRingTex[eye][nextSlot];
        if (eye == 0) _eyeLeftTex = eyeTex;
        else          _eyeRightTex = eyeTex;
        crt_mtl::uploadTopDownBgraTexture(eyeTex, _core->currentPixels(), width, height);
    }
    ++_frameCounter;
    [self setNeedsDisplay:YES];
}

- (void)clearToBlack {
    if (!_core) return;
    [self ensureMetalReady];
    const unsigned width = std::max(_core->width(), 256u);
    const unsigned height = std::max(_core->height(), 240u);
    std::vector<uint32_t> black(static_cast<size_t>(width) * height, 0xFF000000u);
    [self pushRingPairPrev:black.data() cur:black.data() width:width height:height];
    for (int e = 0; e < 2; ++e) {
        for (int b = 0; b < 2; ++b) {
            if (_eyeRingTex[e][b]) {
                crt_mtl::uploadTopDownBgraTexture(_eyeRingTex[e][b], black.data(), width, height);
            }
        }
    }
    ++_frameCounter;
    [self setNeedsDisplay:YES];
}

- (void)showStatusBannerText:(NSString *)text {
    if (!text || text.length == 0) return;
    _banner.show(text);
    [self setNeedsDisplay:YES];
}

- (void)show3dModeBanner {
    NSString *label = @"";
    switch (_view3dMode) {
        case Famicom3dViewMode::ShutterGlasses:
            label = app_l10n::tr(@"3D スコープ (HVC-031実機)", @"3D Scope (HVC-031 Shutter)");
            break;
        case Famicom3dViewMode::ParallelSbs:
            label = app_l10n::tr(@"3D 並行視 (ステレオ)", @"3D Parallel View (Stereo)");
            break;
        case Famicom3dViewMode::CrossSbs:
            label = app_l10n::tr(@"3D 交差視 (L/R反転)", @"3D Cross-Eyed View");
            break;
        case Famicom3dViewMode::NakedCrt:
        default:
            label = app_l10n::tr(@"3D 裸眼 (生CRT 60Hz)", @"3D Off (Raw 60Hz CRT)");
            break;
    }
    if (_invert3dEyes) {
        label = [label stringByAppendingString:app_l10n::tr(@" [L/R入替]", @" [Swap L/R]")];
    }
    [self showStatusBannerText:label];
}

- (void)advanceTvRasterFrame {
    ++_frameCounter;
    [self setNeedsDisplay:YES];
}

- (void)requestRedraw {
    [self setNeedsDisplay:YES];
}

- (void)drawConnectorHudWithEncoder:(id<MTLRenderCommandEncoder>)enc
                       backingWidth:(int)backingW
                             height:(int)backingH
                              alpha:(float)alpha {
    int tilt = 0, lift = 0, pitch = 0;
    CartPinReading unused;
    if (!_core || !_core->readPinTelemetry(tilt, lift, pitch, &unused, 0)) return;

    const BOOL powered = _core->isCartridgePowered() ? YES : NO;
    const BOOL jammed = _core->isCpuJammed() ? YES : NO;
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    const BOOL poseOrPinChanged = _hudNeedsRefresh || !_hudTex ||
                                  tilt != _hudCachedTilt || lift != _hudCachedLift || pitch != _hudCachedPitch ||
                                  _selectedPin != _hudCachedPin || _hudPinned != _hudCachedPinned ||
                                  powered != _hudCachedPowered || jammed != _hudCachedJammed;
    // Throttle routine bus-telemetry bitmap redraws (~12.5 Hz) to keep audio timing unaffected while tilting.
    const BOOL telemetryRefreshDue = (now - _hudLastUploadTime) >= 0.080;

    if (poseOrPinChanged || telemetryRefreshDue) {
        if (!cart_hud::renderConnectorHud(_core, _selectedPin, _hudPinned == YES, _hudBitmap)) return;

        _hudLastUploadTime = now;
        _hudCachedTilt = tilt;
        _hudCachedLift = lift;
        _hudCachedPitch = pitch;
        _hudCachedPin = _selectedPin;
        _hudCachedPinned = _hudPinned;
        _hudCachedPowered = powered;
        _hudCachedJammed = jammed;
        _hudNeedsRefresh = NO;
        crt_mtl::uploadOrUpdateRgbaTexture(self.device, _hudTex,
                                           cart_hud::kHudBitmapWidth, cart_hud::kHudBitmapHeight,
                                           _hudBitmap.data());
    }

    const float drawW = std::clamp(static_cast<float>(backingW) * 0.56f, 520.0f, 1220.0f);
    const float drawH = drawW * (static_cast<float>(cart_hud::kHudLogicalHeight) / static_cast<float>(cart_hud::kHudLogicalWidth));
    const float margin = std::max(14.0f, static_cast<float>(backingW) * 0.02f);
    const float originX = static_cast<float>(backingW) - margin - drawW;
    const float originY = margin + static_cast<float>(backingH) * 0.02f;
    _hudBackingRect = CGRectMake(originX, originY, drawW, drawH);

    crt_mtl::drawOverlayQuad(enc, _pipes, _hudTex, backingW, backingH, originX, originY, drawW, drawH, alpha, true);
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    [[self window] makeFirstResponder:self];
    if (![self isConnectorHudVisible] || CGRectIsEmpty(_hudBackingRect)) {
        [super mouseDown:event];
        return;
    }

    const NSPoint localPt = [self convertPoint:event.locationInWindow fromView:nil];
    const NSPoint backingPt = [self convertPointToBacking:localPt];
    if (!CGRectContainsPoint(_hudBackingRect, CGPointMake(backingPt.x, backingPt.y))) {
        [super mouseDown:event];
        return;
    }

    const int hitPin = cart_hud::hitTestConnectorPin(CGPointMake(backingPt.x, backingPt.y), _hudBackingRect);
    if (hitPin >= 0) {
        _selectedPin = hitPin;
        _hudPinned = YES;
        _hudShownTime = CFAbsoluteTimeGetCurrent();
    } else {
        _hudPinned = !_hudPinned;
        if (_hudPinned) _hudShownTime = CFAbsoluteTimeGetCurrent();
    }
    _hudNeedsRefresh = YES;
    [self requestRedraw];
}

- (void)keyDown:(NSEvent *)event {
    if (self.screenDelegate) {
        [self.screenDelegate crtScreenDidReceiveKeyDown:event];
    }
}

- (void)keyUp:(NSEvent *)event {
    if (self.screenDelegate) {
        [self.screenDelegate crtScreenDidReceiveKeyUp:event];
    }
}

- (void)computeFitted4x3ViewportForWidth:(int)backingW
                                 height:(int)backingH
                                   outX:(int *)outX
                                   outY:(int *)outY
                                   outW:(int *)outW
                                   outH:(int *)outH {
    const double targetAspect = 4.0 / 3.0;
    const double viewAspect = (backingH > 0) ? (static_cast<double>(backingW) / static_cast<double>(backingH)) : targetAspect;
    *outX = 0;
    *outY = 0;
    *outW = backingW;
    *outH = backingH;
    if (viewAspect > targetAspect) {
        *outW = static_cast<int>(backingH * targetAspect + 0.5);
        *outX = (backingW - *outW) / 2;
    } else if (viewAspect < targetAspect) {
        *outH = static_cast<int>(backingW / targetAspect + 0.5);
        *outY = (backingH - *outH) / 2;
    }
}

- (void)computeRfStandby:(float *)outStandbySnow jitter:(float *)outPowerJitter cartPowered:(BOOL)cartPowered {
    const double powerAge = CFAbsoluteTimeGetCurrent() - _powerSwitchTime;
    float standbySnow = 0.0f;
    float powerJitter = 0.0f;

    if (!_consolePowered) {
        if (powerAge < 0.085) {
            powerJitter = 1.0f - static_cast<float>(powerAge / 0.085);
        } else {
            standbySnow = 1.0f;
        }
    } else if (!cartPowered) {
        // Browned-out or disconnected cartridge power cuts the video modulator carrier.
        standbySnow = 1.0f;
    } else {
        if (powerAge < 0.16) {
            powerJitter = std::exp(-static_cast<float>(powerAge) * 16.0f);
        }
        const double bumpAge = CFAbsoluteTimeGetCurrent() - _transientTime;
        if (_transientPeak > 0.0f && bumpAge >= 0.0 && bumpAge < 0.14) {
            powerJitter = std::max(powerJitter,
                                   _transientPeak * std::exp(-static_cast<float>(bumpAge) * _transientDecay));
        }
    }
    *outStandbySnow = standbySnow;
    *outPowerJitter = powerJitter;
}

- (crt_mtl::CrtUniforms)makeUniformsWithInputW:(float)inputW
                                        inputH:(float)inputH
                                          outW:(float)outW
                                          outH:(float)outH
                                   cartPowered:(BOOL)cartPowered {
    crt_mtl::CrtUniforms u{};
    u.origInputSize = simd_make_float2(inputW, inputH);
    u.origTextureSize = simd_make_float2(512.0f, 256.0f);
    u.prevInputSize = simd_make_float2(inputW, inputH);
    u.prevTextureSize = simd_make_float2(512.0f, 256.0f);
    u.outputSize = simd_make_float2(outW, outH);
    u.frameCount = _frameCounter;
    u.interlaced = _displayConfig.interlaced ? 1.0f : 0.0f;
    u.hvBloom = _displayConfig.hvBloom;
    u.curvature = _displayConfig.curvature;
    u.maskStrength = _displayConfig.slotMask;
    u.rfSnow = _displayConfig.rfSnow;
    u.rfSignal = _displayConfig.rfSignal;
    if (_displayConfig.rfMode) {
        [self computeRfStandby:&u.rfStandbySnow jitter:&u.powerJitter cartPowered:cartPowered];
    }
    u.hdrHeadroom = [self activeHdrHeadroom];
    u.hdrBoost = _displayConfig.hdrEnabled ? 1.0f : 0.0f;
    return u;
}

- (void)encodeBeamLoadPassOnCommandBuffer:(id<MTLCommandBuffer>)cmdBuf
                                  mainTex:(id<MTLTexture>)mainTex
                                  prevTex:(id<MTLTexture>)prevTex
                                 uniforms:(const crt_mtl::CrtUniforms &)u {
    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = _beamLoadTex;
    rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
    [enc setViewport:MTLViewport{0.0, 0.0, 1.0, 1.0, 0.0, 1.0}];
    [enc setRenderPipelineState:_pipes.beamLoad];
    [enc setFragmentTexture:mainTex atIndex:0];
    [enc setFragmentTexture:prevTex atIndex:1];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [enc endEncoding];
}

- (void)computeSbsViewportsForWidth:(int)backingW
                             height:(int)backingH
                           parallel:(BOOL)isParallel
                            outLeft:(NSRect *)leftRect
                           outRight:(NSRect *)rightRect {
    const float scale = (self.bounds.size.width > 1.0)
                            ? std::max(1.0f, static_cast<float>(backingW) / static_cast<float>(self.bounds.size.width))
                            : 1.0f;
    const double gap = 22.0 * scale;
    const double marginX = 24.0 * scale;
    const double marginY = 20.0 * scale;
    double maxPairW = std::max(120.0, static_cast<double>(backingW) - marginX * 2.0);
    if (isParallel) {
        maxPairW = std::min(maxPairW, 640.0 * scale);
    }
    const double maxPairH = std::max(90.0, static_cast<double>(backingH) - marginY * 2.0);
    double eyeW = (maxPairW - gap) * 0.5;
    double eyeH = eyeW * (3.0 / 4.0);
    if (eyeH > maxPairH) {
        eyeH = maxPairH;
        eyeW = eyeH * (4.0 / 3.0);
    }
    const double totalW = eyeW * 2.0 + gap;
    const double startX = (static_cast<double>(backingW) - totalW) * 0.5;
    const double startY = (static_cast<double>(backingH) - eyeH) * 0.5;
    *leftRect = NSMakeRect(startX, startY, eyeW, eyeH);
    *rightRect = NSMakeRect(startX + eyeW + gap, startY, eyeW, eyeH);
}

- (void)encodeDisplayPassOnEncoder:(id<MTLRenderCommandEncoder>)enc
                           mainTex:(id<MTLTexture>)mainTex
                           prevTex:(id<MTLTexture>)prevTex
                         viewportX:(int)viewX
                         viewportY:(int)viewY
                         viewportW:(int)viewW
                         viewportH:(int)viewH
                          uniforms:(const crt_mtl::CrtUniforms &)u
                       cartPowered:(BOOL)cartPowered
                    shutterOverlay:(BOOL)shutterOverlay
                      shutterPhase:(int)shutterPhase {
    if (!_displayConfig.rfMode && (!cartPowered || !_consolePowered)) {
        return;
    }

    const int safeW = std::max(viewW, 1);
    const int safeH = std::max(viewH, 1);
    MTLViewport vp{static_cast<double>(viewX), static_cast<double>(viewY),
                   static_cast<double>(safeW), static_cast<double>(safeH), 0.0, 1.0};
    [enc setViewport:vp];

    id<MTLRenderPipelineState> pso = _pipes.displayRgb;
    if (_displayConfig.rfMode) {
        pso = _displayConfig.monochrome ? _pipes.displayBw : _pipes.displayRf;
    }
    crt_mtl::CrtUniforms localU = u;
    localU.outputSize = simd_make_float2(static_cast<float>(safeW), static_cast<float>(safeH));

    [enc setRenderPipelineState:pso];
    [enc setFragmentTexture:_beamLoadTex atIndex:0];
    [enc setFragmentTexture:mainTex atIndex:1];
    [enc setFragmentTexture:prevTex atIndex:2];
    [enc setFragmentBytes:&localU length:sizeof(localU) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];

    if (shutterOverlay) {
        // Real HVC-031 TN-LCD polarizer light loss (~42% transmittance + subtle cool slate tint & 30Hz pulse)
        const float pulseDim = (shutterPhase & 1) ? 0.44f : 0.36f;
        crt_mtl::drawColorQuad(enc, _pipes, 0.05f, 0.07f, 0.09f, pulseDim);
    }
}

- (void)encodeStereoSideBySideOnCommandBuffer:(id<MTLCommandBuffer>)cmdBuf
                               passDescriptor:(MTLRenderPassDescriptor *)rpd
                                 baseUniforms:(const crt_mtl::CrtUniforms &)baseU
                                     backingW:(int)backingW
                                     backingH:(int)backingH
                                  cartPowered:(BOOL)cartPowered {
    const BOOL isParallel = (_view3dMode == Famicom3dViewMode::ParallelSbs);
    NSRect lRect = NSZeroRect, rRect = NSZeroRect;
    [self computeSbsViewportsForWidth:backingW height:backingH parallel:isParallel outLeft:&lRect outRight:&rRect];

    id<MTLTexture> logicalLeft = _invert3dEyes ? _eyeRightTex : _eyeLeftTex;
    id<MTLTexture> logicalRight = _invert3dEyes ? _eyeLeftTex : _eyeRightTex;
    id<MTLTexture> screenEyes[2] = {
        isParallel ? logicalLeft : logicalRight,
        isParallel ? logicalRight : logicalLeft
    };
    const NSRect rects[2] = {lRect, rRect};

    for (int i = 0; i < 2; ++i) {
        id<MTLTexture> mainTex = screenEyes[i];
        id<MTLTexture> prevTex = screenEyes[1 - i];
        [self encodeBeamLoadPassOnCommandBuffer:cmdBuf mainTex:mainTex prevTex:prevTex uniforms:baseU];
        if (i == 1) rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;

        id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
        [self encodeDisplayPassOnEncoder:enc
                                 mainTex:mainTex
                                 prevTex:prevTex
                               viewportX:static_cast<int>(std::llround(rects[i].origin.x))
                               viewportY:static_cast<int>(std::llround(rects[i].origin.y))
                               viewportW:static_cast<int>(std::llround(rects[i].size.width))
                               viewportH:static_cast<int>(std::llround(rects[i].size.height))
                                uniforms:baseU
                             cartPowered:cartPowered
                          shutterOverlay:NO
                            shutterPhase:0];
        [enc endEncoding];
    }
}

- (void)encodeSingleViewOnCommandBuffer:(id<MTLCommandBuffer>)cmdBuf
                         passDescriptor:(MTLRenderPassDescriptor *)rpd
                           baseUniforms:(const crt_mtl::CrtUniforms &)baseU
                                  viewX:(int)viewX
                                  viewY:(int)viewY
                                  viewW:(int)viewW
                                  viewH:(int)viewH
                            cartPowered:(BOOL)cartPowered {
    [self encodeBeamLoadPassOnCommandBuffer:cmdBuf mainTex:_curTex prevTex:_prevTex uniforms:baseU];
    const BOOL scopeActive = _core->is3dSystemActive() && (_view3dMode == Famicom3dViewMode::ShutterGlasses);
    const int effPhase = _invert3dEyes ? (1 - (_last3dRawEye & 1)) : (_last3dRawEye & 1);

    id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
    [self encodeDisplayPassOnEncoder:enc
                             mainTex:_curTex
                             prevTex:_prevTex
                           viewportX:viewX
                           viewportY:viewY
                           viewportW:viewW
                           viewportH:viewH
                            uniforms:baseU
                         cartPowered:cartPowered
                      shutterOverlay:scopeActive
                        shutterPhase:effPhase];
    [enc endEncoding];
}

- (void)encodeOverlaysOnCommandBuffer:(id<MTLCommandBuffer>)cmdBuf
                       passDescriptor:(MTLRenderPassDescriptor *)rpd
                             backingW:(int)backingW
                             backingH:(int)backingH {
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
    id<MTLRenderCommandEncoder> hudEnc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
    if (_hudPinned) {
        [self drawConnectorHudWithEncoder:hudEnc backingWidth:backingW height:backingH alpha:1.0f];
    } else {
        const double hudAge = CFAbsoluteTimeGetCurrent() - _hudShownTime;
        if (hudAge >= 0.0 && hudAge < 1.35) {
            const float fade = (hudAge < 1.05) ? 1.0f : static_cast<float>(1.0 - (hudAge - 1.05) / 0.30);
            if (fade > 0.01f) {
                [self drawConnectorHudWithEncoder:hudEnc backingWidth:backingW height:backingH alpha:fade];
            }
        }
    }
    const float backingScale = (self.bounds.size.width > 1.0)
                                 ? static_cast<float>(backingW) / static_cast<float>(self.bounds.size.width)
                                 : 1.0f;
    _banner.draw(self.device, hudEnc, _pipes, backingW, backingH, backingScale);
    [hudEnc endEncoding];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [self ensureMetalReady];
    id<CAMetalDrawable> drawable = self.currentDrawable;
    if (!drawable || !_cmdQueue) return;

    const int backingW = std::max(static_cast<int>(drawable.texture.width), 1);
    const int backingH = std::max(static_cast<int>(drawable.texture.height), 1);
    const BOOL canDrawCrt = (_metalReady && _core && _curTex && _prevTex);
    const BOOL cartPowered = canDrawCrt && _core->isLoaded() && _core->isCartridgePowered();

    id<MTLCommandBuffer> cmdBuf = [_cmdQueue commandBuffer];
    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = drawable.texture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    const BOOL crtOffBlack = !canDrawCrt || (!_displayConfig.rfMode && (!cartPowered || !_consolePowered));
    rpd.colorAttachments[0].clearColor = crtOffBlack
                                             ? MTLClearColorMake(0.0, 0.0, 0.0, 1.0)
                                             : MTLClearColorMake(0.00031, 0.00046, 0.00062, 1.0);

    if (canDrawCrt) {
        int viewX = 0, viewY = 0, viewW = backingW, viewH = backingH;
        [self computeFitted4x3ViewportForWidth:backingW height:backingH
                                          outX:&viewX outY:&viewY outW:&viewW outH:&viewH];

        const crt_mtl::CrtUniforms baseU = [self makeUniformsWithInputW:static_cast<float>(_core->width())
                                                                 inputH:static_cast<float>(_core->height())
                                                                   outW:static_cast<float>(viewW)
                                                                   outH:static_cast<float>(viewH)
                                                            cartPowered:cartPowered];
        const bool useSbs = _core->is3dSystemActive() &&
                            (_view3dMode == Famicom3dViewMode::ParallelSbs ||
                             _view3dMode == Famicom3dViewMode::CrossSbs) &&
                            _eyeLeftTex && _eyeRightTex;
        if (useSbs) {
            [self encodeStereoSideBySideOnCommandBuffer:cmdBuf passDescriptor:rpd baseUniforms:baseU
                                               backingW:backingW backingH:backingH cartPowered:cartPowered];
        } else {
            [self encodeSingleViewOnCommandBuffer:cmdBuf passDescriptor:rpd baseUniforms:baseU
                                            viewX:viewX viewY:viewY viewW:viewW viewH:viewH cartPowered:cartPowered];
        }
        [self encodeOverlaysOnCommandBuffer:cmdBuf passDescriptor:rpd backingW:backingW backingH:backingH];
    } else {
        id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
        [enc endEncoding];
    }

    [cmdBuf presentDrawable:drawable];
    [cmdBuf commit];
}

@end
