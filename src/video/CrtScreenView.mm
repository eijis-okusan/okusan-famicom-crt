#import "CrtScreenView.hpp"
#import "core/FamicomCore.hpp"
#import "hud/CartConnectorHud.hpp"
#import "video/FreezeFrameGenerator.hpp"

#import <OpenGL/gl.h>
#import <OpenGL/glext.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

std::string loadBundledShader(NSString *shaderName) {
    NSString *path = [[NSBundle mainBundle] pathForResource:shaderName ofType:@"glsl" inDirectory:@"shaders"];
    if (!path) {
        std::fprintf(stderr, "Missing shader resource: %s.glsl\n", [shaderName UTF8String]);
        return "";
    }
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return text ? std::string([text UTF8String]) : "";
}

// RetroArch-style single-file shaders switch between VERTEX and FRAGMENT sections via #define.
std::string injectDefinesAfterVersion(const std::string &source, const std::string &defines) {
    const size_t firstNewline = source.find('\n');
    if (firstNewline == std::string::npos) return defines + "\n" + source;
    return source.substr(0, firstNewline + 1) + defines + "\n" + source.substr(firstNewline + 1);
}

GLuint compileShaderStage(GLenum stageType, const std::string &source, const char *label) {
    GLuint shader = glCreateShader(stageType);
    const char *raw = source.c_str();
    glShaderSource(shader, 1, &raw, nullptr);
    glCompileShader(shader);

    GLint status = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (!status) {
        char infoLog[4096] = {0};
        glGetShaderInfoLog(shader, sizeof(infoLog) - 1, nullptr, infoLog);
        std::fprintf(stderr, "Shader compile error (%s):\n%s\n", label, infoLog);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

GLuint linkShaderProgram(const std::string &source, const char *label) {
    if (source.empty()) return 0;

    GLuint vertexShader = compileShaderStage(
        GL_VERTEX_SHADER,
        injectDefinesAfterVersion(source, "#define VERTEX\n#define PARAMETER_UNIFORM\n"),
        label);
    GLuint fragmentShader = compileShaderStage(
        GL_FRAGMENT_SHADER,
        injectDefinesAfterVersion(source, "#define FRAGMENT\n#define PARAMETER_UNIFORM\n"),
        label);
    if (!vertexShader || !fragmentShader) {
        if (vertexShader) glDeleteShader(vertexShader);
        if (fragmentShader) glDeleteShader(fragmentShader);
        return 0;
    }

    GLuint program = glCreateProgram();
    glAttachShader(program, vertexShader);
    glAttachShader(program, fragmentShader);
    glBindAttribLocation(program, 0, "VertexCoord");
    glBindAttribLocation(program, 1, "TexCoord");
    glLinkProgram(program);
    glDeleteShader(vertexShader);
    glDeleteShader(fragmentShader);

    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) {
        char infoLog[4096] = {0};
        glGetProgramInfoLog(program, sizeof(infoLog) - 1, nullptr, infoLog);
        std::fprintf(stderr, "Shader link error (%s):\n%s\n", label, infoLog);
        glDeleteProgram(program);
        return 0;
    }
    return program;
}

void drawFullscreenQuad() {
    static const float vertices[4][2] = {{-1.f, -1.f}, {1.f, -1.f}, {-1.f, 1.f}, {1.f, 1.f}};
    static const float texCoords[4][2] = {{0.f, 0.f}, {1.f, 0.f}, {0.f, 1.f}, {1.f, 1.f}};
    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, vertices);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, texCoords);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
}

void uploadIdentityMvp(GLuint program) {
    static const float identity[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
    const GLint loc = glGetUniformLocation(program, "MVPMatrix");
    if (loc >= 0) glUniformMatrix4fv(loc, 1, GL_FALSE, identity);
}

NSString *firstDroppedNesPath(NSPasteboard *pasteboard) {
    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[[NSURL class]]
                                                       options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    for (NSURL *url in urls) {
        if (url.isFileURL && [[url.pathExtension lowercaseString] isEqualToString:@"nes"]) {
            return url.path;
        }
    }
    return nil;
}

GLuint createFrameTexture() {
    GLuint tex = 0;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    std::vector<uint32_t> blank(512 * 256, 0xFF000000u);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 512, 256, 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, blank.data());
    return tex;
}

} // namespace

@implementation CrtScreenView {
    FamicomCore *_core;
    BOOL _glInitialized;

    GLuint _beamLoadProg;
    GLuint _rgbDisplayProg;
    GLuint _rfDisplayProg;
    GLuint _bwDisplayProg;

    GLuint _currentFrameTex;
    GLuint _previousFrameTex;
    GLuint _beamLoadTex;
    GLuint _beamLoadFbo;
    int _frameCounter;
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
        if (_beamLoadProg) glDeleteProgram(_beamLoadProg);
        if (_rgbDisplayProg) glDeleteProgram(_rgbDisplayProg);
        if (_rfDisplayProg) glDeleteProgram(_rfDisplayProg);
        if (_bwDisplayProg) glDeleteProgram(_bwDisplayProg);
        if (_currentFrameTex) glDeleteTextures(1, &_currentFrameTex);
        if (_previousFrameTex) glDeleteTextures(1, &_previousFrameTex);
        if (_beamLoadTex) glDeleteTextures(1, &_beamLoadTex);
        if (_hudTex) glDeleteTextures(1, &_hudTex);
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

- (void)setFreezeEffect:(FreezeStyle)style seed:(uint32_t)seed active:(BOOL)active {
    if (!_core) return;
    if (!active) {
        const BOOL wasActive = _freezeGenerator.active() ? YES : NO;
        _freezeGenerator.clear();
        if (wasActive && _core->isLoaded()) {
            [self ensureGLReady];
            [self.openGLContext makeCurrentContext];
            [self uploadTopDownPixels:_core->previousPixels() toTexture:_previousFrameTex
                                width:_core->width() height:_core->height()];
            [self uploadTopDownPixels:_core->currentPixels() toTexture:_currentFrameTex
                                width:_core->width() height:_core->height()];
        }
        [self requestRedraw];
        return;
    }

    _freezeGenerator.capture(style, seed, _core->width(), _core->height(),
                             _core->currentPixels(), _core->previousPixels());
    if (style != FreezeStyle::CleanTone && style != FreezeStyle::MachineGunStutter &&
        _freezeGenerator.width() > 0 && _freezeGenerator.height() > 0) {
        [self ensureGLReady];
        [self.openGLContext makeCurrentContext];
        [self uploadTopDownPixels:_freezeGenerator.primaryPixels()
                        toTexture:_currentFrameTex
                            width:_freezeGenerator.width()
                           height:_freezeGenerator.height()];
        [self uploadTopDownPixels:_freezeGenerator.primaryPixels()
                        toTexture:_previousFrameTex
                            width:_freezeGenerator.width()
                           height:_freezeGenerator.height()];
    }
    [self triggerFreezeGlitch];
}

- (void)advanceFreezeEffect {
    ++_frameCounter;
    if (_freezeGenerator.advanceFrameAndShouldUpload()) {
        [self ensureGLReady];
        [self.openGLContext makeCurrentContext];
        std::swap(_currentFrameTex, _previousFrameTex);
        [self uploadTopDownPixels:_freezeGenerator.activeDisplayPixels()
                        toTexture:_currentFrameTex
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

    _beamLoadProg = linkShaderProgram(loadBundledShader(@"okusan-crt-beamload"), "beamload");
    _rgbDisplayProg = linkShaderProgram(loadBundledShader(@"okusan-crt-display"), "display-rgb");
    _rfDisplayProg = linkShaderProgram(loadBundledShader(@"okusan-crt-rf-display"), "display-rf");
    _bwDisplayProg = linkShaderProgram(loadBundledShader(@"okusan-crt-bw-display"), "display-bw");

    _currentFrameTex = createFrameTexture();
    _previousFrameTex = createFrameTexture();

    glGenTextures(1, &_beamLoadTex);
    glBindTexture(GL_TEXTURE_2D, _beamLoadTex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA16F_ARB, 32, 32, 0, GL_RGBA, GL_FLOAT, nullptr);

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
    std::swap(_currentFrameTex, _previousFrameTex);
    [self uploadTopDownPixels:_core->currentPixels()
                    toTexture:_currentFrameTex
                        width:_core->width()
                       height:_core->height()];
    ++_frameCounter;
    [self setNeedsDisplay:YES];
}

- (void)clearToBlack {
    if (!_core) return;
    [self ensureGLReady];
    [self.openGLContext makeCurrentContext];
    const unsigned width = std::max(_core->width(), 256u);
    const unsigned height = std::max(_core->height(), 240u);
    std::vector<uint32_t> black(static_cast<size_t>(width) * height, 0xFF000000u);
    [self uploadTopDownPixels:black.data() toTexture:_currentFrameTex width:width height:height];
    [self uploadTopDownPixels:black.data() toTexture:_previousFrameTex width:width height:height];
    ++_frameCounter;
    [self setNeedsDisplay:YES];
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

        glActiveTexture(GL_TEXTURE0);
        if (!_hudTex) {
            glGenTextures(1, &_hudTex);
            glBindTexture(GL_TEXTURE_2D, _hudTex);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8,
                         cart_hud::kHudBitmapWidth, cart_hud::kHudBitmapHeight,
                         0, GL_RGBA, GL_UNSIGNED_BYTE, _hudBitmap.data());
        } else {
            glBindTexture(GL_TEXTURE_2D, _hudTex);
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0,
                            cart_hud::kHudBitmapWidth, cart_hud::kHudBitmapHeight,
                            GL_RGBA, GL_UNSIGNED_BYTE, _hudBitmap.data());
        }
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

    glViewport(0, 0, backingW, backingH);
    glMatrixMode(GL_PROJECTION);
    glPushMatrix();
    glLoadIdentity();
    glOrtho(0, backingW, 0, backingH, -1, 1);
    glMatrixMode(GL_MODELVIEW);
    glPushMatrix();
    glLoadIdentity();

    glEnable(GL_TEXTURE_2D);
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glColor4f(alpha, alpha, alpha, alpha);

    glBegin(GL_QUADS);
    glTexCoord2f(0.0f, 1.0f); glVertex2f(originX, originY);
    glTexCoord2f(1.0f, 1.0f); glVertex2f(originX + drawW, originY);
    glTexCoord2f(1.0f, 0.0f); glVertex2f(originX + drawW, originY + drawH);
    glTexCoord2f(0.0f, 0.0f); glVertex2f(originX, originY + drawH);
    glEnd();

    glDisable(GL_BLEND);
    glDisable(GL_TEXTURE_2D);
    glColor4f(1.0f, 1.0f, 1.0f, 1.0f);
    glPopMatrix();
    glMatrixMode(GL_PROJECTION);
    glPopMatrix();
    glMatrixMode(GL_MODELVIEW);
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

- (void)renderBeamLoadPassWithInputW:(float)inputW inputH:(float)inputH {
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, _beamLoadFbo);
    glViewport(0, 0, 32, 32);
    glUseProgram(_beamLoadProg);
    uploadIdentityMvp(_beamLoadProg);
    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, _currentFrameTex);
    glUniform1i(glGetUniformLocation(_beamLoadProg, "OrigTexture"), 0);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, _previousFrameTex);
    glUniform1i(glGetUniformLocation(_beamLoadProg, "PrevTexture"), 1);
    glUniform2f(glGetUniformLocation(_beamLoadProg, "OrigInputSize"), inputW, inputH);
    glUniform2f(glGetUniformLocation(_beamLoadProg, "OrigTextureSize"), 512.0f, 256.0f);
    glUniform2f(glGetUniformLocation(_beamLoadProg, "PrevInputSize"), inputW, inputH);
    glUniform2f(glGetUniformLocation(_beamLoadProg, "PrevTextureSize"), 512.0f, 256.0f);
    drawFullscreenQuad();
}

- (void)renderFrameAtBackingWidth:(GLsizei)backingW height:(GLsizei)backingH {
    if (!_glInitialized || !_beamLoadProg || !_core) {
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
    [self renderBeamLoadPassWithInputW:inputW inputH:inputH];

    const BOOL cartPowered = _core->isLoaded() && _core->isCartridgePowered();
    if (!_displayConfig.rfMode && (!cartPowered || !_consolePowered)) {
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
        glViewport(0, 0, backingW, backingH);
        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
    } else {
        const GLsizei safeW = std::max(viewW, 1);
        const GLsizei safeH = std::max(viewH, 1);
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
        glViewport(0, 0, backingW, backingH);
        glClearColor(0.004f, 0.006f, 0.008f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glViewport(viewX, viewY, safeW, safeH);

        GLuint displayProg = _rgbDisplayProg;
        if (_displayConfig.rfMode) {
            displayProg = (_displayConfig.monochrome && _bwDisplayProg) ? _bwDisplayProg : _rfDisplayProg;
        }
        if (displayProg) {
            glUseProgram(displayProg);
            uploadIdentityMvp(displayProg);

            glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, _beamLoadTex);
            glUniform1i(glGetUniformLocation(displayProg, "Texture"), 0);
            glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, _currentFrameTex);
            glUniform1i(glGetUniformLocation(displayProg, "OrigTexture"), 1);
            glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, _previousFrameTex);
            glUniform1i(glGetUniformLocation(displayProg, "PrevTexture"), 2);

            glUniform2f(glGetUniformLocation(displayProg, "InputSize"), 32.0f, 32.0f);
            glUniform2f(glGetUniformLocation(displayProg, "TextureSize"), 32.0f, 32.0f);
            glUniform2f(glGetUniformLocation(displayProg, "OrigInputSize"), inputW, inputH);
            glUniform2f(glGetUniformLocation(displayProg, "OrigTextureSize"), 512.0f, 256.0f);
            glUniform2f(glGetUniformLocation(displayProg, "OutputSize"), (float)safeW, (float)safeH);
            glUniform1i(glGetUniformLocation(displayProg, "FrameCount"), _frameCounter);

            glUniform1f(glGetUniformLocation(displayProg, "OKUSAN_INTERLACED"), _displayConfig.interlaced ? 1.0f : 0.0f);
            glUniform1f(glGetUniformLocation(displayProg, "OKUSAN_HV_BLOOM"), _displayConfig.hvBloom);
            glUniform1f(glGetUniformLocation(displayProg, "OKUSAN_CURVATURE"), _displayConfig.curvature);
            glUniform1f(glGetUniformLocation(displayProg, "OKUSAN_MASK_STRENGTH"), _displayConfig.slotMask);

            if (_displayConfig.rfMode) {
                float standbySnow = 0.0f;
                float powerJitter = 0.0f;
                [self computeRfStandby:&standbySnow jitter:&powerJitter cartPowered:cartPowered];
                glUniform1f(glGetUniformLocation(displayProg, "OKUSAN_RF_SNOW"), _displayConfig.rfSnow);
                glUniform1f(glGetUniformLocation(displayProg, "OKUSAN_RF_SIGNAL"), _displayConfig.rfSignal);
                glUniform1f(glGetUniformLocation(displayProg, "OKUSAN_RF_STANDBY_SNOW"), standbySnow);
                glUniform1f(glGetUniformLocation(displayProg, "OKUSAN_POWER_JITTER"), powerJitter);
            }

            drawFullscreenQuad();
            glUseProgram(0);
        }
    }

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
