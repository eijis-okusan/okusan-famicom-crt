#import "CrtScreenView.hpp"
#import "app/AppLocalization.hpp"
#import "core/FamicomCore.hpp"
#import "hud/CartConnectorHud.hpp"
#import "video/CrtShaderProgram.hpp"
#import "video/FreezeFrameGenerator.hpp"
#import "video/StatusBanner.hpp"

#import <OpenGL/gl.h>
#import <OpenGL/glext.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

namespace {

NSString *firstDroppedNesPath(NSPasteboard *pasteboard) {
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
    BOOL _glInitialized;

    CrtShaderProgram _beamLoadProg;
    CrtShaderProgram _rgbDisplayProg;
    CrtShaderProgram _rfDisplayProg;
    CrtShaderProgram _bwDisplayProg;

    GLuint _frameRingTex[4];
    int _frameRingIdx;
    GLuint _curTex;
    GLuint _prevTex;
    GLuint _eyeRingTex[2][2];
    int _eyeRingIdx[2];
    GLuint _eyeLeftTex;
    GLuint _eyeRightTex;
    GLuint _beamLoadTex;
    GLuint _beamLoadFbo;
    int _frameCounter;
    int _last3dRawEye;
    Famicom3dViewMode _view3dMode;
    BOOL _invert3dEyes;
    CrtStatusBanner _banner;
    std::vector<uint32_t> _flipBuffer;

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
    GLuint _hudTex;
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

+ (NSOpenGLPixelFormat *)defaultPixelFormat {
    NSOpenGLPixelFormatAttribute attrs[] = {
        NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersionLegacy,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAColorSize, 24,
        NSOpenGLPFAAlphaSize, 8,
        NSOpenGLPFAAccelerated,
        0
    };
    return [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
}

- (instancetype)initWithFrame:(NSRect)frameRect core:(FamicomCore *)core {
    self = [super initWithFrame:frameRect pixelFormat:[CrtScreenView defaultPixelFormat]];
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

        if ([self respondsToSelector:@selector(setWantsBestResolutionOpenGLSurface:)]) {
            self.wantsBestResolutionOpenGLSurface = YES;
        }
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    }
    return self;
}

- (void)dealloc {
    if (_glInitialized && self.openGLContext) {
        [self.openGLContext makeCurrentContext];
        crt_gl::destroyShaderProgram(_beamLoadProg);
        crt_gl::destroyShaderProgram(_rgbDisplayProg);
        crt_gl::destroyShaderProgram(_rfDisplayProg);
        crt_gl::destroyShaderProgram(_bwDisplayProg);
        for (int i = 0; i < 4; ++i) {
            if (_frameRingTex[i]) glDeleteTextures(1, &_frameRingTex[i]);
        }
        for (int e = 0; e < 2; ++e) {
            for (int b = 0; b < 2; ++b) {
                if (_eyeRingTex[e][b]) glDeleteTextures(1, &_eyeRingTex[e][b]);
            }
        }
        if (_beamLoadTex) glDeleteTextures(1, &_beamLoadTex);
        if (_hudTex) glDeleteTextures(1, &_hudTex);
        _banner.destroyGL();
        if (_beamLoadFbo) glDeleteFramebuffersEXT(1, &_beamLoadFbo);
    }
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return firstDroppedNesPath([sender draggingPasteboard]) ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSString *romPath = firstDroppedNesPath([sender draggingPasteboard]);
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

- (void)triggerFreezeGlitch {
    _transientTime = CFAbsoluteTimeGetCurrent();
    _transientPeak = 0.55f;
    _transientDecay = 28.0f;
    [self requestRedraw];
}

- (void)pushRingFramePixels:(const uint32_t *)pixels width:(unsigned)width height:(unsigned)height {
    _frameRingIdx = (_frameRingIdx + 1) & 3;
    _prevTex = _curTex;
    _curTex = _frameRingTex[_frameRingIdx];
    [self uploadTopDownPixels:pixels toTexture:_curTex width:width height:height];
}

- (void)pushRingPairPrev:(const uint32_t *)prevPixels
                     cur:(const uint32_t *)curPixels
                   width:(unsigned)width
                  height:(unsigned)height {
    [self ensureGLReady];
    [self.openGLContext makeCurrentContext];
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
        [self ensureGLReady];
        [self.openGLContext makeCurrentContext];
        [self pushRingFramePixels:_freezeGenerator.activeDisplayPixels()
                            width:_freezeGenerator.width()
                           height:_freezeGenerator.height()];
    }
    [self setNeedsDisplay:YES];
}

- (void)triggerResetGlitch {
    _transientTime = CFAbsoluteTimeGetCurrent();
    _transientPeak = 0.92f;
    _transientDecay = 18.0f;
    [self requestRedraw];
}

- (void)triggerCartridgeBump {
    _transientTime = CFAbsoluteTimeGetCurrent();
    _transientPeak = 0.42f;
    _transientDecay = 32.0f;
    [self requestRedraw];
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

- (void)ensureGLReady {
    if (_glInitialized) return;
    [self.openGLContext makeCurrentContext];

    // Disable vsync so the main timer can pace frames accurately at 60.0988 Hz.
    GLint swapInterval = 0;
    [self.openGLContext setValues:&swapInterval forParameter:NSOpenGLContextParameterSwapInterval];

    _beamLoadProg = crt_gl::linkBundledShaderProgram(@"okusan-crt-beamload", "beamload");
    _rgbDisplayProg = crt_gl::linkBundledShaderProgram(@"okusan-crt-display", "display-rgb");
    _rfDisplayProg = crt_gl::linkBundledShaderProgram(@"okusan-crt-rf-display", "display-rf");
    _bwDisplayProg = crt_gl::linkBundledShaderProgram(@"okusan-crt-bw-display", "display-bw");

    for (int i = 0; i < 4; ++i) {
        _frameRingTex[i] = crt_gl::createFrameTexture();
    }
    _frameRingIdx = 0;
    _curTex = _frameRingTex[0];
    _prevTex = _frameRingTex[3];
    for (int e = 0; e < 2; ++e) {
        for (int b = 0; b < 2; ++b) {
            _eyeRingTex[e][b] = 0;
        }
        _eyeRingIdx[e] = 0;
    }
    _eyeLeftTex = 0;
    _eyeRightTex = 0;

    glGenTextures(1, &_beamLoadTex);
    glBindTexture(GL_TEXTURE_2D, _beamLoadTex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA16F_ARB, 1, 1, 0, GL_RGBA, GL_FLOAT, nullptr);

    glGenFramebuffersEXT(1, &_beamLoadFbo);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, _beamLoadFbo);
    glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_2D, _beamLoadTex, 0);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);

    _glInitialized = YES;
}

- (void)prepareOpenGL {
    [super prepareOpenGL];
    [self ensureGLReady];
}

- (void)uploadTopDownPixels:(const uint32_t *)pixels
                  toTexture:(GLuint)texture
                      width:(unsigned)width
                     height:(unsigned)height {
    if (!pixels || width == 0 || height == 0) return;

    _flipBuffer.resize(static_cast<size_t>(width) * height);
    for (unsigned y = 0; y < height; ++y) {
        std::memcpy(_flipBuffer.data() + static_cast<size_t>(height - 1 - y) * width,
                    pixels + static_cast<size_t>(y) * width,
                    static_cast<size_t>(width) * sizeof(uint32_t));
    }
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, (GLsizei)width, (GLsizei)height,
                    GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, _flipBuffer.data());
}

- (void)presentLatestFrame {
    if (!_core) return;
    [self ensureGLReady];
    [self.openGLContext makeCurrentContext];
    const unsigned width = _core->width();
    const unsigned height = _core->height();
    [self pushRingFramePixels:_core->currentPixels() width:width height:height];
    if (_core->is3dSystemActive() && !_flipBuffer.empty()) {
        if (!_eyeRingTex[0][0]) {
            for (int e = 0; e < 2; ++e) {
                for (int b = 0; b < 2; ++b) {
                    _eyeRingTex[e][b] = crt_gl::createFrameTexture();
                }
            }
            _eyeLeftTex = _eyeRingTex[0][0];
            _eyeRightTex = _eyeRingTex[1][0];
        }
        const int eye = _core->current3dEye() & 1;
        _last3dRawEye = eye;
        const int nextSlot = 1 - _eyeRingIdx[eye];
        _eyeRingIdx[eye] = nextSlot;
        GLuint eyeTex = _eyeRingTex[eye][nextSlot];
        if (eye == 0) _eyeLeftTex = eyeTex;
        else          _eyeRightTex = eyeTex;
        glBindTexture(GL_TEXTURE_2D, eyeTex);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, (GLsizei)width, (GLsizei)height,
                        GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, _flipBuffer.data());
    }
    ++_frameCounter;
    [self setNeedsDisplay:YES];
}

- (void)clearToBlack {
    if (!_core) return;
    const unsigned width = std::max(_core->width(), 256u);
    const unsigned height = std::max(_core->height(), 240u);
    std::vector<uint32_t> black(static_cast<size_t>(width) * height, 0xFF000000u);
    [self pushRingPairPrev:black.data() cur:black.data() width:width height:height];
    for (int e = 0; e < 2; ++e) {
        for (int b = 0; b < 2; ++b) {
            if (_eyeRingTex[e][b]) {
                [self uploadTopDownPixels:black.data() toTexture:_eyeRingTex[e][b] width:width height:height];
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

- (void)drawConnectorHudAtWidth:(GLsizei)backingW height:(GLsizei)backingH alpha:(float)alpha {
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

        const bool recreate = (!_hudTex);
        crt_gl::uploadOrUpdateRgbaTexture(_hudTex,
                                          cart_hud::kHudBitmapWidth,
                                          cart_hud::kHudBitmapHeight,
                                          _hudBitmap.data(),
                                          recreate);
    } else {
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, _hudTex);
    }

    const float drawW = std::clamp((float)backingW * 0.56f, 520.0f, 1220.0f);
    const float drawH = drawW * ((float)cart_hud::kHudLogicalHeight / (float)cart_hud::kHudLogicalWidth);
    const float margin = std::max(14.0f, (float)backingW * 0.02f);
    const float originX = (float)backingW - margin - drawW;
    const float originY = margin + (float)backingH * 0.02f;
    _hudBackingRect = CGRectMake(originX, originY, drawW, drawH);

    crt_gl::drawOrthoTexturedQuad(_hudTex, backingW, backingH, originX, originY, drawW, drawH, alpha, true);
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

    const int clickedPin = cart_hud::hitTestConnectorPin(CGPointMake(backingPt.x, backingPt.y), _hudBackingRect);
    if (clickedPin >= 0) {
        _selectedPin = clickedPin;
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

- (void)computeFitted4x3ViewportForWidth:(GLsizei)backingW
                                 height:(GLsizei)backingH
                                   outX:(GLint *)outX
                                   outY:(GLint *)outY
                                   outW:(GLsizei *)outW
                                   outH:(GLsizei *)outH {
    const double targetAspect = 4.0 / 3.0;
    const double viewAspect = (backingH > 0) ? ((double)backingW / (double)backingH) : targetAspect;
    *outX = 0;
    *outY = 0;
    *outW = backingW;
    *outH = backingH;
    if (viewAspect > targetAspect) {
        *outW = (GLsizei)(backingH * targetAspect + 0.5);
        *outX = (backingW - *outW) / 2;
    } else if (viewAspect < targetAspect) {
        *outH = (GLsizei)(backingW / targetAspect + 0.5);
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

- (void)renderBeamLoadPassWithMainTex:(GLuint)mainTex
                              prevTex:(GLuint)prevTex
                               inputW:(float)inputW
                               inputH:(float)inputH {
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, _beamLoadFbo);
    glViewport(0, 0, 1, 1);
    glUseProgram(_beamLoadProg.prog);
    crt_gl::uploadIdentityMvp(_beamLoadProg);
    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, mainTex);
    crt_gl::setUniform1i(_beamLoadProg.origTexture, 0);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, prevTex);
    crt_gl::setUniform1i(_beamLoadProg.prevTexture, 1);
    crt_gl::setUniform2f(_beamLoadProg.origInputSize, inputW, inputH);
    crt_gl::setUniform2f(_beamLoadProg.origTextureSize, 512.0f, 256.0f);
    crt_gl::setUniform2f(_beamLoadProg.prevInputSize, inputW, inputH);
    crt_gl::setUniform2f(_beamLoadProg.prevTextureSize, 512.0f, 256.0f);
    crt_gl::drawFullscreenQuad();
}

- (void)computeSbsViewportsForWidth:(GLsizei)backingW
                             height:(GLsizei)backingH
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

- (void)renderSingleCrtPassWithMainTex:(GLuint)mainTex
                               prevTex:(GLuint)prevTex
                             viewportX:(GLint)viewX
                             viewportY:(GLint)viewY
                             viewportW:(GLsizei)viewW
                             viewportH:(GLsizei)viewH
                                inputW:(float)inputW
                                inputH:(float)inputH
                           cartPowered:(BOOL)cartPowered
                       shutterOverlay:(BOOL)shutterOverlay
                          shutterPhase:(int)shutterPhase {
    [self renderBeamLoadPassWithMainTex:mainTex prevTex:prevTex inputW:inputW inputH:inputH];

    if (!_displayConfig.rfMode && (!cartPowered || !_consolePowered)) {
        glUseProgram(0);
        return;
    }

    const GLsizei safeW = std::max(viewW, 1);
    const GLsizei safeH = std::max(viewH, 1);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
    glViewport(viewX, viewY, safeW, safeH);

    const CrtShaderProgram *displayProg = &_rgbDisplayProg;
    if (_displayConfig.rfMode) {
        displayProg = (_displayConfig.monochrome && _bwDisplayProg.prog) ? &_bwDisplayProg : &_rfDisplayProg;
    }
    if (displayProg && displayProg->prog) {
        glUseProgram(displayProg->prog);
        crt_gl::uploadIdentityMvp(*displayProg);

        glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, _beamLoadTex);
        crt_gl::setUniform1i(displayProg->texture, 0);
        glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, mainTex);
        crt_gl::setUniform1i(displayProg->origTexture, 1);
        glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, prevTex);
        crt_gl::setUniform1i(displayProg->prevTexture, 2);

        crt_gl::setUniform2f(displayProg->inputSize, 1.0f, 1.0f);
        crt_gl::setUniform2f(displayProg->textureSize, 1.0f, 1.0f);
        crt_gl::setUniform2f(displayProg->origInputSize, inputW, inputH);
        crt_gl::setUniform2f(displayProg->origTextureSize, 512.0f, 256.0f);
        crt_gl::setUniform2f(displayProg->outputSize, (float)safeW, (float)safeH);
        crt_gl::setUniform1i(displayProg->frameCount, _frameCounter);

        crt_gl::setUniform1f(displayProg->interlaced, _displayConfig.interlaced ? 1.0f : 0.0f);
        crt_gl::setUniform1f(displayProg->hvBloom, _displayConfig.hvBloom);
        crt_gl::setUniform1f(displayProg->curvature, _displayConfig.curvature);
        crt_gl::setUniform1f(displayProg->maskStrength, _displayConfig.slotMask);

        if (_displayConfig.rfMode) {
            float standbySnow = 0.0f;
            float powerJitter = 0.0f;
            [self computeRfStandby:&standbySnow jitter:&powerJitter cartPowered:cartPowered];
            crt_gl::setUniform1f(displayProg->rfSnow, _displayConfig.rfSnow);
            crt_gl::setUniform1f(displayProg->rfSignal, _displayConfig.rfSignal);
            crt_gl::setUniform1f(displayProg->rfStandbySnow, standbySnow);
            crt_gl::setUniform1f(displayProg->powerJitter, powerJitter);
        }

        crt_gl::drawFullscreenQuad();
        glUseProgram(0);
    }

    if (shutterOverlay) {
        // Real HVC-031 TN-LCD polarizer light loss (~42% transmittance + subtle cool slate tint & 30Hz pulse)
        const float pulseDim = (shutterPhase & 1) ? 0.44f : 0.36f;
        crt_gl::drawColorOverlayQuad(0.05f, 0.07f, 0.09f, pulseDim);
    }
}

- (void)renderFrameAtBackingWidth:(GLsizei)backingW height:(GLsizei)backingH {
    if (!_glInitialized || !_beamLoadProg.prog || !_core) {
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
        glViewport(0, 0, backingW, backingH);
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        return;
    }

    GLint viewX = 0, viewY = 0;
    GLsizei viewW = backingW, viewH = backingH;
    [self computeFitted4x3ViewportForWidth:backingW height:backingH
                                      outX:&viewX outY:&viewY outW:&viewW outH:&viewH];

    const float inputW = (float)_core->width();
    const float inputH = (float)_core->height();
    const BOOL cartPowered = _core->isLoaded() && _core->isCartridgePowered();

    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
    glViewport(0, 0, backingW, backingH);
    if (!_displayConfig.rfMode && (!cartPowered || !_consolePowered)) {
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    } else {
        glClearColor(0.004f, 0.006f, 0.008f, 1.0f);
    }
    glClear(GL_COLOR_BUFFER_BIT);

    const bool useSbs = _core->is3dSystemActive() &&
                        (_view3dMode == Famicom3dViewMode::ParallelSbs ||
                         _view3dMode == Famicom3dViewMode::CrossSbs);
    if (useSbs) {
        const BOOL isParallel = (_view3dMode == Famicom3dViewMode::ParallelSbs);
        NSRect lRect = NSZeroRect, rRect = NSZeroRect;
        [self computeSbsViewportsForWidth:backingW height:backingH parallel:isParallel outLeft:&lRect outRight:&rRect];

        const GLuint logicalLeft = _invert3dEyes ? _eyeRightTex : _eyeLeftTex;
        const GLuint logicalRight = _invert3dEyes ? _eyeLeftTex : _eyeRightTex;
        const GLuint screenLeftMain = isParallel ? logicalLeft : logicalRight;
        const GLuint screenRightMain = isParallel ? logicalRight : logicalLeft;

        [self renderSingleCrtPassWithMainTex:screenLeftMain
                                     prevTex:screenRightMain
                                   viewportX:(GLint)std::llround(lRect.origin.x)
                                   viewportY:(GLint)std::llround(lRect.origin.y)
                                   viewportW:(GLsizei)std::llround(lRect.size.width)
                                   viewportH:(GLsizei)std::llround(lRect.size.height)
                                      inputW:inputW inputH:inputH
                                 cartPowered:cartPowered
                             shutterOverlay:NO
                                shutterPhase:0];

        [self renderSingleCrtPassWithMainTex:screenRightMain
                                     prevTex:screenLeftMain
                                   viewportX:(GLint)std::llround(rRect.origin.x)
                                   viewportY:(GLint)std::llround(rRect.origin.y)
                                   viewportW:(GLsizei)std::llround(rRect.size.width)
                                   viewportH:(GLsizei)std::llround(rRect.size.height)
                                      inputW:inputW inputH:inputH
                                 cartPowered:cartPowered
                             shutterOverlay:NO
                                shutterPhase:0];
    } else {
        const BOOL scopeActive = _core->is3dSystemActive() && (_view3dMode == Famicom3dViewMode::ShutterGlasses);
        const int effPhase = _invert3dEyes ? (1 - (_last3dRawEye & 1)) : (_last3dRawEye & 1);
        [self renderSingleCrtPassWithMainTex:_curTex
                                     prevTex:_prevTex
                                   viewportX:viewX
                                   viewportY:viewY
                                   viewportW:viewW
                                   viewportH:viewH
                                      inputW:inputW inputH:inputH
                                 cartPowered:cartPowered
                             shutterOverlay:scopeActive
                                shutterPhase:effPhase];
    }

    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
    if (_hudPinned) {
        [self drawConnectorHudAtWidth:backingW height:backingH alpha:1.0f];
    } else {
        const double hudAge = CFAbsoluteTimeGetCurrent() - _hudShownTime;
        if (hudAge >= 0.0 && hudAge < 1.35) {
            const float fade = (hudAge < 1.05) ? 1.0f : static_cast<float>(1.0 - (hudAge - 1.05) / 0.30);
            if (fade > 0.01f) {
                [self drawConnectorHudAtWidth:backingW height:backingH alpha:fade];
            }
        }
    }

    const float backingScale = (self.bounds.size.width > 1.0)
                                 ? static_cast<float>(backingW) / static_cast<float>(self.bounds.size.width)
                                 : 1.0f;
    _banner.draw(backingW, backingH, backingScale);
}

- (void)drawRect:(NSRect)dirtyRect {
    [self.openGLContext makeCurrentContext];
    const NSRect backing = [self convertRectToBacking:self.bounds];
    const GLsizei backingW = std::max((GLsizei)backing.size.width, 1);
    const GLsizei backingH = std::max((GLsizei)backing.size.height, 1);
    [self renderFrameAtBackingWidth:backingW height:backingH];
    [self.openGLContext flushBuffer];
}

@end
