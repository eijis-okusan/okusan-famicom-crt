#pragma once

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#include <vector>

namespace crt_mtl {
struct CrtMetalPipelines;
}

/**
 * Renders and caches a transient rounded-pill status banner in a Metal texture
 * (used for 3D System mode switches, FDS disk swaps, HDR toggles, and reset feedback).
 */
struct CrtStatusBanner {
    NSString *text = nil;
    NSString *lastRenderedText = nil;
    CFAbsoluteTime showTime = -10.0;
    id<MTLTexture> tex = nil;
    int texW = 0;
    int texH = 0;
    std::vector<uint8_t> pixels;

    void show(NSString *message);
    void draw(id<MTLDevice> device,
              id<MTLRenderCommandEncoder> enc,
              const crt_mtl::CrtMetalPipelines &pipes,
              int backW,
              int backH,
              float backingScale);
    void destroyMetal();
};
