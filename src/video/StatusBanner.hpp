#pragma once

#import <Cocoa/Cocoa.h>
#import <OpenGL/gl.h>
#include <vector>

/**
 * Renders and caches a transient rounded-pill status banner in an OpenGL texture
 * (used for 3D System mode switches, FDS disk swaps, and settings reset feedback).
 */
struct CrtStatusBanner {
    NSString *text = nil;
    NSString *lastRenderedText = nil;
    CFAbsoluteTime showTime = -10.0;
    GLuint tex = 0;
    int texW = 0;
    int texH = 0;
    std::vector<uint8_t> pixels;

    void show(NSString *message);
    void draw(GLsizei backW, GLsizei backH, float backingScale);
    void destroyGL();
};
