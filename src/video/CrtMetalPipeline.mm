#import "video/CrtMetalPipeline.hpp"

#include <cstdio>
#include <vector>

namespace crt_mtl {

namespace {

id<MTLRenderPipelineState> buildPipeline(id<MTLDevice> device,
                                         id<MTLLibrary> library,
                                         NSString *vertexName,
                                         NSString *fragmentName,
                                         MTLPixelFormat format,
                                         bool enableBlend,
                                         bool premultipliedBlend) {
    id<MTLFunction> vert = [library newFunctionWithName:vertexName];
    id<MTLFunction> frag = [library newFunctionWithName:fragmentName];
    if (!vert || !frag) {
        std::fprintf(stderr, "Missing Metal shader entrypoints: %s / %s\n",
                     [vertexName UTF8String], [fragmentName UTF8String]);
        return nil;
    }

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vert;
    desc.fragmentFunction = frag;
    desc.colorAttachments[0].pixelFormat = format;
    if (enableBlend) {
        desc.colorAttachments[0].blendingEnabled = YES;
        desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        desc.colorAttachments[0].sourceRGBBlendFactor =
            premultipliedBlend ? MTLBlendFactorOne : MTLBlendFactorSourceAlpha;
        desc.colorAttachments[0].sourceAlphaBlendFactor =
            premultipliedBlend ? MTLBlendFactorOne : MTLBlendFactorSourceAlpha;
        desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    }

    NSError *err = nil;
    id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (!pso) {
        std::fprintf(stderr, "Metal pipeline error (%s): %s\n",
                     [fragmentName UTF8String], err ? [[err localizedDescription] UTF8String] : "unknown");
    }
    return pso;
}

} // namespace

bool createPipelines(id<MTLDevice> device, MTLPixelFormat colorFormat, CrtMetalPipelines &out) {
    if (!device) return false;
    NSString *path = [[NSBundle mainBundle] pathForResource:@"okusan-crt" ofType:@"metal" inDirectory:@"shaders"];
    if (!path) {
        std::fprintf(stderr, "Missing bundled Metal shader: shaders/okusan-crt.metal\n");
        return false;
    }

    NSError *readErr = nil;
    NSString *source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readErr];
    if (!source) {
        std::fprintf(stderr, "Failed to read okusan-crt.metal: %s\n",
                     readErr ? [[readErr localizedDescription] UTF8String] : "unknown");
        return false;
    }

    // Compile the unified .metal source at startup so Xcode's offline MetalToolchain is not required.
    NSError *compErr = nil;
    MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
    id<MTLLibrary> library = [device newLibraryWithSource:source options:opts error:&compErr];
    if (!library) {
        std::fprintf(stderr, "Metal shader compile error:\n%s\n",
                     compErr ? [[compErr localizedDescription] UTF8String] : "unknown");
        return false;
    }

    out.beamLoad = buildPipeline(device, library, @"fullscreenVertex", @"beamloadFragment",
                                 MTLPixelFormatRGBA16Float, false, false);
    out.displayRgb = buildPipeline(device, library, @"fullscreenVertex", @"displayRgbFragment",
                                   colorFormat, false, false);
    out.displayRf = buildPipeline(device, library, @"fullscreenVertex", @"displayRfFragment",
                                  colorFormat, false, false);
    out.displayBw = buildPipeline(device, library, @"fullscreenVertex", @"displayBwFragment",
                                  colorFormat, false, false);
    out.displayX68k31k = buildPipeline(device, library, @"fullscreenVertex", @"displayX68k31kFragment",
                                       colorFormat, false, false);
    out.displayComposite = buildPipeline(device, library, @"fullscreenVertex", @"displayCompositeFragment",
                                         colorFormat, false, false);
    out.overlayPremul = buildPipeline(device, library, @"overlayQuadVertex", @"overlayQuadFragment",
                                      colorFormat, true, true);
    out.colorAlpha = buildPipeline(device, library, @"fullscreenVertex", @"colorQuadFragment",
                                   colorFormat, true, false);
    return out.beamLoad && out.displayRgb && out.displayRf && out.displayBw &&
           out.displayX68k31k && out.displayComposite && out.overlayPremul && out.colorAlpha;
}

id<MTLTexture> createFrameTexture(id<MTLDevice> device) {
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:512
                                                          height:256
                                                       mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [device newTextureWithDescriptor:desc];
    std::vector<uint32_t> blank(512 * 256, 0xFF000000u);
    [tex replaceRegion:MTLRegionMake2D(0, 0, 512, 256)
           mipmapLevel:0
             withBytes:blank.data()
           bytesPerRow:512 * sizeof(uint32_t)];
    return tex;
}

void uploadTopDownBgraTexture(id<MTLTexture> tex, const uint32_t *pixels, unsigned width, unsigned height) {
    if (!tex || !pixels || width == 0 || height == 0) return;
    [tex replaceRegion:MTLRegionMake2D(0, 0, width, height)
           mipmapLevel:0
             withBytes:pixels
           bytesPerRow:static_cast<NSUInteger>(width) * sizeof(uint32_t)];
}

void uploadOrUpdateRgbaTexture(id<MTLDevice> device,
                               __strong id<MTLTexture> &tex,
                               int width,
                               int height,
                               const void *rgbaPixels) {
    if (!device || !rgbaPixels || width <= 0 || height <= 0) return;
    if (!tex || static_cast<int>(tex.width) != width || static_cast<int>(tex.height) != height) {
        MTLTextureDescriptor *desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:static_cast<NSUInteger>(width)
                                                              height:static_cast<NSUInteger>(height)
                                                           mipmapped:NO];
        desc.storageMode = MTLStorageModeShared;
        desc.usage = MTLTextureUsageShaderRead;
        tex = [device newTextureWithDescriptor:desc];
    }
    [tex replaceRegion:MTLRegionMake2D(0, 0, static_cast<NSUInteger>(width), static_cast<NSUInteger>(height))
           mipmapLevel:0
             withBytes:rgbaPixels
           bytesPerRow:static_cast<NSUInteger>(width) * 4];
}

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
                     bool premultiplied) {
    if (!enc || !pipes.overlayPremul || !tex) return;
    MTLViewport vp{0.0, 0.0, static_cast<double>(viewW), static_cast<double>(viewH), 0.0, 1.0};
    [enc setViewport:vp];
    [enc setRenderPipelineState:pipes.overlayPremul];

    OverlayUniforms u{};
    u.rect = simd_make_float4(x, y, w, h);
    u.viewportSize = simd_make_float2(static_cast<float>(viewW), static_cast<float>(viewH));
    u.color = simd_make_float4(1.0f, 1.0f, 1.0f, alpha);
    u.premultiplied = premultiplied ? 1 : 0;

    [enc setVertexBytes:&u length:sizeof(u) atIndex:0];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc setFragmentTexture:tex atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

void drawColorQuad(id<MTLRenderCommandEncoder> enc,
                   const CrtMetalPipelines &pipes,
                   float r,
                   float g,
                   float b,
                   float a) {
    if (!enc || !pipes.colorAlpha) return;
    [enc setRenderPipelineState:pipes.colorAlpha];
    OverlayUniforms u{};
    u.color = simd_make_float4(r, g, b, a);
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

} // namespace crt_mtl
