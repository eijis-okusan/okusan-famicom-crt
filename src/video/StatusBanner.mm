#import "video/StatusBanner.hpp"
#import "video/CrtShaderProgram.hpp"

#include <algorithm>
#include <cmath>

void CrtStatusBanner::show(NSString *message) {
    if (!message || message.length == 0) return;
    text = [message copy];
    showTime = CFAbsoluteTimeGetCurrent();
}

void CrtStatusBanner::draw(GLsizei backW, GLsizei backH, float backingScale) {
    if (!text || text.length == 0) return;
    const double elapsed = CFAbsoluteTimeGetCurrent() - showTime;
    if (elapsed < 0.0 || elapsed >= 2.2) return;
    const float alpha = (elapsed < 1.8) ? 1.0f : static_cast<float>(1.0 - (elapsed - 1.8) / 0.4);
    if (alpha <= 0.01f) return;

    const float scale = std::max(1.0f, backingScale);
    if (!tex || ![lastRenderedText isEqualToString:text]) {
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:13.0 * scale weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: [NSColor colorWithWhite:0.97 alpha:1.0]
        };
        const NSSize textSize = [text sizeWithAttributes:attrs];
        const int padX = static_cast<int>(std::ceil(12.0f * scale));
        const int padY = static_cast<int>(std::ceil(7.0f * scale));
        const int w = std::max(32, static_cast<int>(std::ceil(textSize.width)) + padX * 2);
        const int h = std::max(24, static_cast<int>(std::ceil(textSize.height)) + padY * 2);

        pixels.assign(static_cast<size_t>(w) * h * 4, 0);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(pixels.data(), w, h, 8, w * 4, cs,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(cs);
        if (ctx) {
            const CGFloat r = 7.0 * scale;
            CGPathRef pill = CGPathCreateWithRoundedRect(CGRectMake(1, 1, w - 2, h - 2), r, r, nullptr);
            CGContextAddPath(ctx, pill);
            CGContextSetRGBFillColor(ctx, 0.06, 0.07, 0.09, 0.86);
            CGContextFillPath(ctx);
            CGContextAddPath(ctx, pill);
            CGContextSetRGBStrokeColor(ctx, 0.45, 0.72, 0.96, 0.45);
            CGContextSetLineWidth(ctx, 1.0 * scale);
            CGContextStrokePath(ctx);
            CGPathRelease(pill);

            NSGraphicsContext *nsCtx = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:nsCtx];
            [text drawAtPoint:NSMakePoint(padX, padY) withAttributes:attrs];
            [NSGraphicsContext restoreGraphicsState];
            CGContextRelease(ctx);
        }

        const bool recreate = (!tex || texW != w || texH != h);
        crt_gl::uploadOrUpdateRgbaTexture(tex, w, h, pixels.data(), recreate);
        texW = w;
        texH = h;
        lastRenderedText = [text copy];
    }

    crt_gl::drawOrthoTexturedQuad(tex, backW, backH,
                                  18.0f * scale, 18.0f * scale,
                                  static_cast<float>(texW), static_cast<float>(texH),
                                  alpha, false);
}

void CrtStatusBanner::destroyGL() {
    if (tex) {
        glDeleteTextures(1, &tex);
        tex = 0;
    }
    texW = 0;
    texH = 0;
    lastRenderedText = nil;
}
