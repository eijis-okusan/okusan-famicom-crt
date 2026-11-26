#pragma once

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#include <cstdint>
#include <simd/simd.h>

namespace crt_mtl {

/// Shader parameters uploaded per frame for Pass 0 (beam load) and Pass 1 (RGB / RF / B&W CRT).
/// Field layout mirrors `struct CrtUniforms` inside `resources/shaders/okusan-crt.metal`.
struct CrtUniforms {
    simd_float2 origInputSize;
    simd_float2 origTextureSize;
    simd_float2 prevInputSize;
    simd_float2 prevTextureSize;
    simd_float2 outputSize;
    int32_t     frameCount;
    float       interlaced;
    float       hvBloom;
    float       curvature;
    float       maskStrength;
    float       rfSnow;
    float       rfSignal;
    float       rfStandbySnow;
    float       powerJitter;
    float       hdrHeadroom;
    float       hdrBoost;
};

/// Quad bounds and tint parameters for HUD / banner / 3D-shutter overlay draws.
struct OverlayUniforms {
    simd_float4 rect;
    simd_float2 viewportSize;
    simd_float4 color;
    int32_t     premultiplied;
};

/// Compiled Metal render pipeline states for the full 2-pass CRT + overlay chain.
struct CrtMetalPipelines {
    id<MTLRenderPipelineState> beamLoad = nil;
    id<MTLRenderPipelineState> displayRgb = nil;
    id<MTLRenderPipelineState> displayRf = nil;
    id<MTLRenderPipelineState> displayBw = nil;
    id<MTLRenderPipelineState> displayX68k31k = nil;
    id<MTLRenderPipelineState> overlayPremul = nil;
    id<MTLRenderPipelineState> colorAlpha = nil;
};

/// Compiles `shaders/okusan-crt.metal` at runtime and builds all CRT and overlay pipelines.
bool createPipelines(id<MTLDevice> device, MTLPixelFormat colorFormat, CrtMetalPipelines &out);

/// Allocates a 512x256 BGRA8Unorm shared-memory texture cleared to black for NES video uploads.
id<MTLTexture> createFrameTexture(id<MTLDevice> device);

/// Uploads top-down XRGB/BGRA NES pixels directly without row flipping (Metal origin matches NES).
void uploadTopDownBgraTexture(id<MTLTexture> tex, const uint32_t *pixels, unsigned width, unsigned height);

/// Creates or updates a shared RGBA8Unorm texture from CoreGraphics bitmap data.
void uploadOrUpdateRgbaTexture(id<MTLDevice> device,
                               __strong id<MTLTexture> &tex,
                               int width,
                               int height,
                               const void *rgbaPixels);

/// Draws a textured screen-space overlay quad (HUD or status banner), decoding sRGB to linear light.
void drawOverlayQuad(id<MTLRenderCommandEncoder> enc,
                     const CrtMetalPipelines &pipes,
                     id<MTLTexture> tex,
                     int viewW,
                     int viewH,
                     float x,
                     float y,
                     float w,
                     float h,
                     float alpha,
                     bool premultiplied);

/// Draws a fullscreen translucent color quad (used for the HVC-031 3D Scope TN-LCD shutter tint).
void drawColorQuad(id<MTLRenderCommandEncoder> enc,
                   const CrtMetalPipelines &pipes,
                   float r,
                   float g,
                   float b,
                   float a);

} // namespace crt_mtl
