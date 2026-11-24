#include <metal_stdlib>
using namespace metal;

// Okusan CRT Dynamics - Unified Metal 2-Pass CRT, RF, Monochrome P4, and HDR/EDR Shaders
// Outputs linear optical light in kCGColorSpaceExtendedLinearSRGB:
//   0.0 = black, 1.0 = SDR reference white, >1.0 = HDR/EDR peak luminance headroom.

struct CrtUniforms {
    float2 origInputSize;
    float2 origTextureSize;
    float2 prevInputSize;
    float2 prevTextureSize;
    float2 outputSize;
    int    frameCount;
    float  interlaced;
    float  hvBloom;
    float  curvature;
    float  maskStrength;
    float  rfSnow;
    float  rfSignal;
    float  rfStandbySnow;
    float  powerJitter;
    float  hdrHeadroom; // 1.0 = SDR display/off; >1.0 = Extended Dynamic Range headroom
    float  hdrBoost;    // 0.0 = calibrated SDR parity; 1.0 = physical CRT ABL/peak boost
};

struct OverlayUniforms {
    float4 rect;          // Normalized/viewport pixel quad (x, y, w, h)
    float2 viewportSize;  // Render target pixel size (w, h)
    float4 color;         // Color tint / alpha
    int    premultiplied; // 1 if CoreGraphics RGBA8 premultiplied sRGB, 0 if straight
};

struct FullscreenOut {
    float4 position [[position]];
    float2 texCoord;
};

struct OverlayOut {
    float4 position [[position]];
    float2 texCoord;
};

constexpr sampler kNearestClamp(coord::normalized, address::clamp_to_edge, filter::nearest);
constexpr sampler kLinearClamp(coord::normalized, address::clamp_to_edge, filter::linear);

constant float kSrcGamma = 2.25f;
constant float kBwSrcGamma = 2.02f;
constant float kDisplayInvGamma = 1.0f / 2.2f;
constant float kBeamSigmaX = 0.55f;
constant float kBeamLoadKnee = 0.14f;
constant float kHvSagExpansion = 0.015f;
constant float kBwHvSagExpansion = 0.022f;
constant float kNtscVisibleLines = 480.0f;
constant float kPi = 3.14159265f;
constant float kSubcarrierRadPerTexel = 2.09439510f; // 2 * pi / 3 per source pixel (~3.58 MHz)
constant float kHvCapBlend = 0.58f;
constant float3 kLumaWeights = float3(0.299f, 0.587f, 0.114f);
constant float3 kGunConvergence = float3(-0.13f, 0.0f, 0.16f);
constant float3 kP22Decay = float3(0.055f, 0.11f, 0.075f);

inline float glsl_mod(float x, float y) {
    return x - y * floor(x / y);
}

inline float3 srgbToLinear(float3 c) {
    float3 low = c / 12.92f;
    float3 high = pow(max((c + 0.055f) / 1.055f, 0.0f), 2.4f);
    return select(high, low, c <= 0.04045f);
}

inline float3 hdrSoftLimit(float3 c, float headroom) {
    float knee = headroom * 0.82f;
    float3 over = max(c - knee, 0.0f);
    float span = max(headroom - knee, 0.05f);
    return min(c, knee) + span * (over / (over + span));
}

// ---------- Vertex Shaders ----------

vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    // Fullscreen triangle strip in NDC, mapping top-left (uv = 0,0) -> top of NES texture (top-down upload).
    const float2 pos[4] = {
        float2(-1.0f, -1.0f),
        float2( 1.0f, -1.0f),
        float2(-1.0f,  1.0f),
        float2( 1.0f,  1.0f)
    };
    const float2 uvs[4] = {
        float2(0.0f, 1.0f),
        float2(1.0f, 1.0f),
        float2(0.0f, 0.0f),
        float2(1.0f, 0.0f)
    };
    FullscreenOut out;
    out.position = float4(pos[vid], 0.0f, 1.0f);
    out.texCoord = uvs[vid];
    return out;
}

vertex OverlayOut overlayQuadVertex(uint vid [[vertex_id]],
                                    constant OverlayUniforms &u [[buffer(0)]]) {
    // Bottom-left pixel coordinates matching AppKit / CartHudOverlay layout, mapped onto Metal NDC.
    const float2 corners[4] = {
        float2(0.0f, 0.0f),
        float2(1.0f, 0.0f),
        float2(0.0f, 1.0f),
        float2(1.0f, 1.0f)
    };
    const float2 uvs[4] = {
        float2(0.0f, 1.0f),
        float2(1.0f, 1.0f),
        float2(0.0f, 0.0f),
        float2(1.0f, 0.0f)
    };
    float2 px = u.rect.xy + corners[vid] * u.rect.zw;
    float2 ndc = (px / max(u.viewportSize, float2(1.0f))) * 2.0f - 1.0f;
    OverlayOut out;
    out.position = float4(ndc, 0.0f, 1.0f);
    out.texCoord = uvs[vid];
    return out;
}

fragment float4 overlayQuadFragment(OverlayOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    constant OverlayUniforms &u [[buffer(0)]]) {
    float4 src = tex.sample(kLinearClamp, in.texCoord);
    float3 straightSrgb = u.premultiplied ? (src.rgb / max(src.a, 1e-4f)) : src.rgb;
    float3 lin = srgbToLinear(clamp(straightSrgb, 0.0f, 1.0f));
    float a = src.a * u.color.a;
    return float4(lin * a, a);
}

fragment float4 colorQuadFragment(FullscreenOut in [[stage_in]],
                                  constant OverlayUniforms &u [[buffer(0)]]) {
    float3 lin = srgbToLinear(clamp(u.color.rgb, 0.0f, 1.0f));
    return float4(lin, u.color.a);
}

// ---------- Pass 0: Beam Load Estimator (1x1 RGBA16Float) ----------

inline float sampleBeamCurrent(texture2d<float> tex, float2 uvNorm, float2 inputSz, float2 texSz) {
    float2 activeScale = inputSz / max(texSz, float2(1.0f));
    float2 uvClamped = clamp(uvNorm, float2(0.005f), float2(0.995f)) * activeScale;
    float3 rgb = pow(max(tex.sample(kNearestClamp, uvClamped).rgb, float3(1e-6f)), float3(kSrcGamma));
    float luma = dot(rgb, kLumaWeights);
    return luma * luma;
}

fragment float4 beamloadFragment(FullscreenOut in [[stage_in]],
                                 texture2d<float> origTex [[texture(0)]],
                                 texture2d<float> prevTex [[texture(1)]],
                                 constant CrtUniforms &u [[buffer(0)]]) {
    float curSum = 0.0f;
    float prevSum = 0.0f;
    for (int iy = 0; iy < 8; ++iy) {
        float fy = (float(iy) + 0.5f) / 8.0f;
        for (int ix = 0; ix < 8; ++ix) {
            float fx = (float(ix) + 0.5f) / 8.0f;
            float2 sampleUV = float2(fx, fy);
            curSum += sampleBeamCurrent(origTex, sampleUV, u.origInputSize, u.origTextureSize);
            prevSum += sampleBeamCurrent(prevTex, sampleUV, u.prevInputSize, u.prevTextureSize);
        }
    }
    float loadNow = curSum / 64.0f;
    float loadPrev = prevSum / 64.0f;
    float dampedLoad = mix(loadPrev, loadNow, kHvCapBlend);
    return float4(dampedLoad, loadNow, 0.0f, 1.0f);
}

// ---------- Shared CRT Optical & Signal Helpers ----------

inline float3 sampleVideoPixel(texture2d<float> source, float2 texelCoord, float2 imgSz, float2 texSz) {
    float2 clamped = clamp(texelCoord, float2(0.0f), imgSz - 1.0f);
    float2 uv = (clamped + 0.5f) / max(texSz, float2(1.0f));
    return max(source.sample(kNearestClamp, uv).rgb, float3(0.0f));
}

inline float3 sampleLinearPixel(texture2d<float> source, float2 texelCoord, float2 imgSz, float2 texSz, float gammaVal) {
    return pow(max(sampleVideoPixel(source, texelCoord, imgSz, texSz), float3(1e-6f)), float3(gammaVal));
}

inline float sampleLinearLuma(texture2d<float> source, float2 texelCoord, float2 imgSz, float2 texSz) {
    float y = dot(sampleVideoPixel(source, texelCoord, imgSz, texSz), kLumaWeights);
    return pow(max(y, 1e-6f), kBwSrcGamma);
}

inline float3 sampleHorizontalBeam(texture2d<float> origTex, float2 p, float row, float2 imgSz, float2 texSz) {
    float center = floor(p.x + 0.5f);
    float3 energy = float3(0.0f);
    float3 total = float3(0.0f);
    for (int i = -2; i <= 2; ++i) {
        float x = center + float(i);
        float3 dist = float3(p.x - x) + kGunConvergence;
        float3 weight = exp(-dist * dist / (2.0f * kBeamSigmaX * kBeamSigmaX));
        energy += sampleLinearPixel(origTex, float2(x, row), imgSz, texSz, kSrcGamma) * weight;
        total += weight;
    }
    return energy / total;
}

inline float roundedBezelDistance(float2 p) {
    float2 d = abs(p) - float2(0.924f, 0.906f);
    return length(max(d, 0.0f)) + min(max(d.x, d.y), 0.0f) - 0.074f;
}

inline float hash13(float3 p3) {
    p3 = fract(p3 * 0.1031f);
    p3 += dot(p3, p3.zyx + 31.32f);
    return fract((p3.x + p3.y) * p3.z);
}

inline float hash11(float n) {
    return hash13(float3(n, n * 0.37f, 17.13f));
}

inline float sample1DBandNoise(float x, float row, float seed) {
    float i = floor(x);
    float f = fract(x);
    float u = f * f * (3.0f - 2.0f * f);
    float a = hash13(float3(i,        row, seed));
    float b = hash13(float3(i + 1.0f, row, seed));
    return mix(a, b, u) - 0.5f;
}

inline float sampleRfWaveformNoise(float x, float row, float rfSnow, float frameSeed, float impAmp, float impRate) {
    if (rfSnow <= 0.001f) return 0.0f;
    float s = glsl_mod(frameSeed, 1024.0f);
    float g1 = sample1DBandNoise(x * 0.85f,         row, s * 1.13f + 3.7f);
    float g2 = sample1DBandNoise(x * 1.35f + 17.3f, row, s * 2.41f + 19.1f);
    float g3 = sample1DBandNoise(x * 1.95f + 53.1f, row, s * 3.79f + 41.9f);
    float gauss = g1 * 0.50f + g2 * 0.35f + g3 * 0.25f;

    float impRnd = hash13(float3(floor(x * impRate), row, s * 5.17f + 7.3f));
    float impMask = smoothstep(0.91f - 0.035f * min(rfSnow, 1.5f), 0.995f, impRnd);
    float impSign = hash13(float3(floor(x * impRate), row, s * 7.03f + 29.0f)) > 0.28f ? 1.0f : -1.0f;
    return (gauss * 0.23f + impMask * impSign * impAmp) * rfSnow;
}

inline float3 rgbToYiq(float3 c) {
    return float3(
        dot(c, kLumaWeights),
        dot(c, float3(0.596f, -0.274f, -0.322f)),
        dot(c, float3(0.211f, -0.523f,  0.312f))
    );
}

inline float3 yiqToRgb(float3 yiq) {
    return float3(
        yiq.x + 0.956f * yiq.y + 0.621f * yiq.z,
        yiq.x - 0.272f * yiq.y - 0.647f * yiq.z,
        yiq.x - 1.106f * yiq.y + 1.703f * yiq.z
    );
}

inline float3 synthesizeScanlines(float3 rowA, float3 rowB, float fracY, float2 signal,
                                  float fieldParity, float loadExcess, float pixelRowsPerSrc,
                                  float interlacedFlag, float tvLineDeriv) {
    float3 picture = mix(rowA, rowB, fracY);
    if (interlacedFlag > 0.5f) {
        float tvLine = (signal.y * 0.5f + 0.5f) * kNtscVisibleLines - 0.5f;
        float dist = abs(glsl_mod(tvLine - fieldParity + 1.0f, 2.0f) - 1.0f);
        float prevDist = 1.0f - dist;
        float peakLum = max(picture.r, max(picture.g, picture.b));
        float beamWidth = 0.48f + 0.12f * sqrt(peakLum) + 0.03f * loadExcess;
        float d1 = dist / beamWidth;
        float d2 = prevDist / beamWidth;
        float currentLight = exp(-0.5f * d1 * d1);
        float residualLight = exp(-0.5f * d2 * d2);
        float fieldLight = 0.34f + 0.66f * (currentLight + 0.55f * residualLight);
        float fieldPixels = 2.0f / max(tvLineDeriv, 0.001f);
        return picture * mix(0.86f, fieldLight, smoothstep(1.8f, 4.0f, fieldPixels));
    }

    float wa = mix(0.24f, 0.42f, sqrt(max(rowA.r, max(rowA.g, rowA.b))));
    float wb = mix(0.24f, 0.42f, sqrt(max(rowB.r, max(rowB.g, rowB.b))));
    float3 scan = rowA * exp(-0.5f * fracY * fracY / (wa * wa));
    scan += rowB * exp(-0.5f * (1.0f - fracY) * (1.0f - fracY) / (wb * wb));
    return mix(picture * 0.83f, scan, smoothstep(1.35f, 3.1f, pixelRowsPerSrc));
}

inline float3 applyGlassHalation(texture2d<float> origTex, float3 rgb, float2 p, float loadExcess, float2 imgSz, float2 texSz) {
    float3 halo = float3(0.0f);
    for (int i = 0; i < 4; ++i) {
        float2 d = (i < 2) ? float2(2.6f, 0.0f) : float2(0.0f, 1.65f);
        if ((i & 1) == 0) d = -d;
        float3 neighbor = sampleLinearPixel(origTex, floor(p + d + 0.5f), imgSz, texSz, kSrcGamma);
        halo += neighbor * neighbor;
    }
    return rgb * 1.16f + halo * (0.044f + 0.036f * loadExcess);
}

inline float3 applyPhosphorMask(float3 rgb, float2 screenPx, float viewWidth, float srcWidth, float maskStrength, float hdrFactor) {
    float pitch = clamp(viewWidth / max(srcWidth * 1.35f, 1.0f), 3.0f, 6.0f);
    float maskRow = floor(screenPx.y / pitch);
    float stripe = fract(screenPx.x / pitch + 0.5f * glsl_mod(maskRow, 2.0f));
    float3 slots = 1.0f - smoothstep(float3(0.06f), float3(0.235f),
                        abs(fract(stripe - float3(0.0f, 0.3333f, 0.6667f) + 0.5f) - 0.5f));
    float rowGap = smoothstep(0.27f, 0.47f, abs(fract(screenPx.y / pitch) - 0.5f));
    float strength = mix(0.56f, 1.0f, smoothstep(360.0f, 750.0f, viewWidth)) * maskStrength;

    // With HDR headroom, deepen mask shadow floor slightly while letting phosphor centers shine brighter.
    float floorLift = mix(0.72f, 0.54f, saturate(hdrFactor * 0.45f));
    float peakSpan = mix(0.45f, 0.72f, saturate(hdrFactor * 0.45f));
    return rgb * mix(float3(1.0f), (floorLift + peakSpan * slots) * (1.0f - 0.15f * rowGap), clamp(strength, 0.0f, 1.0f));
}

// Convert calibrated linear CRT light into ExtendedLinearSRGB, preserving 1:1 SDR output
// when hdrHeadroom == 1.0 and applying physical flyback ABL + unclipped highlight expansion when > 1.0.
inline float4 finalizeCrtPixel(float3 linearLight,
                               float beamLoad,
                               float aperture,
                               float raster,
                               float3 glassSrgb,
                               float reflection,
                               float lip,
                               float dithering,
                               float hdrHeadroom,
                               float hdrBoost) {
    float effectiveHeadroom = clamp(hdrHeadroom, 1.0f, 3.5f);
    float hdrFactor = (effectiveHeadroom - 1.0f) * clamp(hdrBoost, 0.0f, 1.5f);

    float3 sdrSrgb = pow(max(linearLight, float3(1e-6f)), float3(kDisplayInvGamma)) + dithering;
    float3 baseLin = srgbToLinear(max(sdrSrgb, 0.0f));

    float3 crtLin = baseLin;
    if (hdrFactor > 0.01f) {
        // Automatic Beam Limiter (ABL): dark/mid scenes keep strong peak headroom; full-screen flashes sag gently.
        float ablGain = mix(1.0f + 0.92f * hdrFactor, 1.0f + 0.16f * hdrFactor, smoothstep(0.03f, 0.48f, beamLoad));
        float lum = max(dot(baseLin, kLumaWeights), 1e-6f);
        float peakDrive = mix(1.0f, ablGain, smoothstep(0.05f, 0.60f, lum));
        crtLin = hdrSoftLimit(baseLin * peakDrive, effectiveHeadroom);
    }

    float3 glassLin = srgbToLinear(glassSrgb * (0.74f + 0.48f * reflection + lip));
    float3 outColor = max(crtLin, 0.0f) * aperture * raster + glassLin;
    return float4(outColor, 1.0f);
}

// ---------- Pass 1A: RGB Monitor CRT ----------

struct CrtRasterGeometry {
    bool   outsideBezel;
    float  aperture;
    float  lip;
    float2 face;
    float2 signal;
    float  raster;
    float2 p;
    float  tvLineDeriv;
    float  pixelRowsPerSrc;
    float  reflection;
};

inline CrtRasterGeometry computeCrtRasterGeometry(float2 texCoord,
                                                  float2 imgSz,
                                                  float curvature,
                                                  float loadExcess,
                                                  float hvSagExpansion) {
    CrtRasterGeometry g;
    g.face = texCoord * 2.0f - 1.0f;
    float2 warp = float2(0.083f, 0.110f) * curvature;
    float2 curved = g.face * (float2(1.0f + 0.015f * curvature) + g.face.yx * g.face.yx * warp);
    float edgeDistance = roundedBezelDistance(curved);

    float hvBloom = 1.0f + hvSagExpansion * loadExcess;
    g.signal = curved / (float2(0.94f, 0.90f) * hvBloom);
    float2 signalEdge = abs(g.signal);
    g.raster = (1.0f - smoothstep(1.0f, 1.0f + 2.0f / imgSz.x, signalEdge.x))
             * (1.0f - smoothstep(1.0f, 1.0f + 2.0f / imgSz.y, signalEdge.y));

    g.p = (g.signal * 0.5f + 0.5f) * imgSz - 0.5f;
    float tvLine = (g.signal.y * 0.5f + 0.5f) * kNtscVisibleLines - 0.5f;
    g.tvLineDeriv = abs(dfdy(tvLine));
    g.pixelRowsPerSrc = 1.0f / max(abs(dfdy(g.p.y)), 0.001f);

    g.outsideBezel = (edgeDistance > 0.07f);
    g.aperture = 1.0f - smoothstep(-0.012f, 0.005f, edgeDistance);
    g.lip = exp(-abs(edgeDistance - 0.023f) * 75.0f);
    g.reflection = exp(-4.0f * dot(g.face - float2(-0.42f, 0.53f), g.face - float2(-0.42f, 0.53f)));
    return g;
}

inline void applyRfSyncJitter(thread float2 &p,
                              float frameSeed,
                              float phase,
                              float rfSnow,
                              float rfSignal,
                              float jAmt,
                              float flutterScale) {
    float lineHash = hash11(floor(p.y) + glsl_mod(frameSeed, 1024.0f) * 19.37f);
    float jitWave = sin(p.y * 0.09f + frameSeed * 1.37f) * 2.2f * jAmt;
    float jitLine = (lineHash - 0.5f) * 5.2f * jAmt;
    p.x += (lineHash - 0.5f) * flutterScale * rfSnow
         + 0.04f * sin(p.y * 1.2f + phase * 5.0f) * rfSignal
         + jitWave + jitLine;
    p.y += sin(frameSeed * 2.1f) * 1.5f * jAmt;
}

inline float sampleStandbyRfSnow(float2 p, float frameSeed, float gammaVal) {
    float sSeed = glsl_mod(frameSeed, 1024.0f);
    float rowQ = floor(p.y);
    float colQ = floor(p.x * 1.15f);
    float fineWhite = hash13(float3(colQ, rowQ, sSeed * 4.37f + 13.1f)) - 0.5f;
    float medWhite = sample1DBandNoise(p.x * 0.72f + 11.7f, rowQ, sSeed * 1.91f + 5.3f);
    float rowJitter = (hash11(rowQ + sSeed * 7.13f) - 0.5f) * 0.14f;
    float baseSnow = clamp(0.38f + 0.54f * fineWhite + 0.36f * medWhite + rowJitter, 0.02f, 0.94f);
    float scanAtten = 0.84f + 0.16f * cos(fract(p.y) * 2.0f * kPi);
    return pow(baseSnow, gammaVal) * scanAtten;
}

fragment float4 displayRgbFragment(FullscreenOut in [[stage_in]],
                                   texture2d<float> beamTex [[texture(0)]],
                                   texture2d<float> origTex [[texture(1)]],
                                   texture2d<float> prevTex [[texture(2)]],
                                   constant CrtUniforms &u [[buffer(0)]]) {
    float2 imgSz = max(u.origInputSize, float2(1.0f));
    float2 texSz = max(u.origTextureSize, float2(1.0f));
    float beamLoad = beamTex.sample(kNearestClamp, float2(0.5f, 0.5f)).r;
    float loadExcess = max(beamLoad - kBeamLoadKnee, 0.0f) * u.hvBloom;
    float phase = glsl_mod(float(u.frameCount), 4096.0f) / 59.94f;
    float fieldParity = glsl_mod(float(u.frameCount), 2.0f);

    CrtRasterGeometry geom = computeCrtRasterGeometry(in.texCoord, imgSz, u.curvature, loadExcess, kHvSagExpansion);
    float3 glass = float3(0.010f, 0.014f, 0.017f);
    if (geom.outsideBezel) {
        return float4(srgbToLinear(glass * 0.50f), 1.0f);
    }

    float y = floor(geom.p.y);
    float fracY = fract(geom.p.y);
    float3 rowA = sampleHorizontalBeam(origTex, geom.p, y, imgSz, texSz);
    float3 rowB = sampleHorizontalBeam(origTex, geom.p, y + 1.0f, imgSz, texSz);
    float3 picture = mix(rowA, rowB, fracY);
    float3 rgb = synthesizeScanlines(rowA, rowB, fracY, geom.signal, fieldParity, loadExcess,
                                     geom.pixelRowsPerSrc, u.interlaced, geom.tvLineDeriv);

    float2 q = floor(geom.p + 0.5f);
    float3 previous = sampleLinearPixel(prevTex, q, imgSz, texSz, kSrcGamma);
    rgb += max(previous - picture, 0.0f) * kP22Decay;
    rgb = applyGlassHalation(origTex, rgb, geom.p, loadExcess, imgSz, texSz);

    float viewWidth = (u.outputSize.x > 1.0f) ? u.outputSize.x : (1.0f / max(abs(dfdx(in.texCoord.x)), 0.0001f));
    float hdrFactor = max(clamp(u.hdrHeadroom, 1.0f, 3.5f) - 1.0f, 0.0f) * clamp(u.hdrBoost, 0.0f, 1.5f);
    rgb = applyPhosphorMask(rgb, in.position.xy, viewWidth, imgSz.x, u.maskStrength, hdrFactor);

    float vignette = 1.0f - 0.24f * smoothstep(0.25f, 1.85f, dot(geom.face, geom.face));
    float hum = 1.0f + 0.003f * sin(geom.p.y * 0.08f + phase * 2.0f);
    float noise = fract(sin(dot(fmod(in.position.xy, 317.0f), float2(12.9898f, 78.233f)) + phase * 17.0f) * 43758.5453f) - 0.5f;

    return finalizeCrtPixel(rgb * vignette * hum, beamLoad, geom.aperture, geom.raster, glass,
                            geom.reflection, geom.lip, noise * 0.008f, u.hdrHeadroom, u.hdrBoost);
}

// ---------- Pass 1B: Color VHF RF Television ----------

inline float3 sampleRfScanline(texture2d<float> origTex, float2 p, float row, float rfSnow, float rfSig,
                               float frameSeed, float2 imgSz, float2 texSz) {
    float subcarrierLinePhase = row * kPi + glsl_mod(frameSeed, 2.0f) * 0.45f;
    float wash = clamp(rfSig * 0.5f, 0.0f, 0.85f);
    float baseLift = 0.026f * clamp(rfSnow, 0.0f, 1.5f);

    float yAcc = 0.0f, iAcc = 0.0f, qAcc = 0.0f;
    for (int k = 0; k < 6; ++k) {
        float offset = (float(k) - 2.5f) * 0.5f;
        float xPos = p.x + offset;
        float x0 = floor(xPos);
        float fx = xPos - x0;
        float3 s0 = sampleVideoPixel(origTex, float2(x0, row), imgSz, texSz);
        float3 s1 = sampleVideoPixel(origTex, float2(x0 + 1.0f, row), imgSz, texSz);
        float3 vid = mix(s0, s1, fx);

        if (rfSig > 0.001f) {
            float3 g1 = sampleVideoPixel(origTex, float2(floor(xPos - 5.0f + 0.5f), row), imgSz, texSz);
            float3 g2 = sampleVideoPixel(origTex, float2(floor(xPos - 10.0f + 0.5f), row), imgSz, texSz);
            vid = max(float3(0.0f), vid + (0.12f * g1 - 0.04f * g2) * rfSig);
        }

        float3 yiq = rgbToYiq(vid);
        yiq.yz *= mix(1.0f, 0.82f, wash);
        yiq.x = mix(yiq.x, yiq.x * 0.88f + 0.035f, wash * 0.75f);

        float scPhase = xPos * kSubcarrierRadPerTexel + subcarrierLinePhase;
        float scCos = cos(scPhase);
        float scSin = sin(scPhase);
        float chromaDrive = mix(0.0f, 1.0f, clamp(rfSig, 0.0f, 1.5f));
        float rfCarrier = yiq.x + baseLift + chromaDrive * (yiq.y * scCos + yiq.z * scSin);

        float rfNoise = sampleRfWaveformNoise(xPos, row, rfSnow, frameSeed, 0.32f, 0.90f);
        rfNoise *= (rfNoise < 0.0f) ? mix(1.0f, 0.55f, clamp(yiq.x, 0.0f, 1.0f)) : 1.0f;

        float rfWave = rfCarrier + rfNoise;
        yAcc += rfWave * (1.0f / 6.0f);
        float rxChroma = rfCarrier + rfNoise * 0.40f;
        iAcc += rxChroma * scCos * (2.0f / 6.0f);
        qAcc += rxChroma * scSin * (2.0f / 6.0f);
    }

    float3 outYiq;
    if (rfSig <= 0.001f) {
        float3 cleanYiq = rgbToYiq(sampleVideoPixel(origTex, float2(floor(p.x + 0.5f), row), imgSz, texSz));
        outYiq = float3(yAcc, cleanYiq.y + iAcc * 0.35f, cleanYiq.z + qAcc * 0.35f);
    } else {
        outYiq = float3(yAcc, iAcc * 0.85f, qAcc * 0.85f);
    }

    float3 outVid = clamp(yiqToRgb(outYiq), float3(1e-6f), float3(1.08f));
    float3 lin = pow(outVid, float3(kSrcGamma));

    float3 convShift = kGunConvergence * 0.5f;
    float3 linL = sampleLinearPixel(origTex, float2(floor(p.x - 1.0f + 0.5f), row), imgSz, texSz, kSrcGamma);
    float3 linR = sampleLinearPixel(origTex, float2(floor(p.x + 1.0f + 0.5f), row), imgSz, texSz, kSrcGamma);
    return mix(lin, float3(linR.r, lin.g, linL.b) * 0.14f + lin * 0.86f, abs(convShift.b));
}

fragment float4 displayRfFragment(FullscreenOut in [[stage_in]],
                                  texture2d<float> beamTex [[texture(0)]],
                                  texture2d<float> origTex [[texture(1)]],
                                  texture2d<float> prevTex [[texture(2)]],
                                  constant CrtUniforms &u [[buffer(0)]]) {
    float2 imgSz = max(u.origInputSize, float2(1.0f));
    float2 texSz = max(u.origTextureSize, float2(1.0f));
    float beamLoad = beamTex.sample(kNearestClamp, float2(0.5f, 0.5f)).r;
    float loadExcess = max(beamLoad - kBeamLoadKnee, 0.0f) * u.hvBloom;
    float frameSeed = glsl_mod(float(u.frameCount), 4096.0f);
    float phase = frameSeed / 59.94f;
    float fieldParity = glsl_mod(float(u.frameCount), 2.0f);

    CrtRasterGeometry geom = computeCrtRasterGeometry(in.texCoord, imgSz, u.curvature, loadExcess, kHvSagExpansion);
    float3 glass = float3(0.010f, 0.014f, 0.017f);
    if (geom.outsideBezel) {
        return float4(srgbToLinear(glass * 0.50f), 1.0f);
    }

    float jAmt = clamp(u.powerJitter, 0.0f, 1.0f);
    applyRfSyncJitter(geom.p, frameSeed, phase, u.rfSnow, u.rfSignal, jAmt, 0.20f);

    float3 rgb;
    if (u.rfStandbySnow > 0.5f) {
        rgb = float3(sampleStandbyRfSnow(geom.p, frameSeed, kSrcGamma));
        beamLoad = 0.08f; // Keep standby static sparkle crisp in HDR
    } else {
        float effSnow = u.rfSnow + 1.45f * jAmt;
        float effSig = u.rfSignal + 0.65f * jAmt;
        float y = floor(geom.p.y);
        float fracY = fract(geom.p.y);
        float3 rowA = sampleRfScanline(origTex, geom.p, y, effSnow, effSig, frameSeed, imgSz, texSz);
        float3 rowB = sampleRfScanline(origTex, geom.p, y + 1.0f, effSnow, effSig, frameSeed, imgSz, texSz);
        float3 picture = mix(rowA, rowB, fracY);
        rgb = synthesizeScanlines(rowA, rowB, fracY, geom.signal, fieldParity, loadExcess,
                                  geom.pixelRowsPerSrc, u.interlaced, geom.tvLineDeriv);

        float2 q = floor(geom.p + 0.5f);
        float3 previous = sampleLinearPixel(prevTex, q, imgSz, texSz, kSrcGamma);
        rgb += max(previous - picture, 0.0f) * kP22Decay;
        rgb = applyGlassHalation(origTex, rgb, geom.p, loadExcess, imgSz, texSz);
    }

    float viewWidth = (u.outputSize.x > 1.0f) ? u.outputSize.x : (1.0f / max(abs(dfdx(in.texCoord.x)), 0.0001f));
    float hdrFactor = max(clamp(u.hdrHeadroom, 1.0f, 3.5f) - 1.0f, 0.0f) * clamp(u.hdrBoost, 0.0f, 1.5f);
    rgb = applyPhosphorMask(rgb, in.position.xy, viewWidth, imgSz.x, u.maskStrength, hdrFactor);

    float vignette = 1.0f - 0.24f * smoothstep(0.25f, 1.85f, dot(geom.face, geom.face));
    float agcWave = 1.0f + 0.014f * u.rfSignal * sin(geom.p.y * 0.05f + phase * 3.1f);

    return finalizeCrtPixel(rgb * vignette * agcWave, beamLoad, geom.aperture, geom.raster, glass,
                            geom.reflection, geom.lip, 0.0f, u.hdrHeadroom, u.hdrBoost);
}

// ---------- Pass 1C: Monochrome P4 Phosphor VHF RF Television ----------

inline float sampleBwRfScanline(texture2d<float> origTex, float2 p, float row, float rfSnow, float rfSig,
                                  float frameSeed, float2 imgSz, float2 texSz) {
    float subcarrierLinePhase = row * kSubcarrierRadPerTexel + glsl_mod(frameSeed, 3.0f) * 0.7f;
    float wash = clamp(rfSig * 0.42f, 0.0f, 0.75f);
    float baseLift = 0.020f * clamp(rfSnow, 0.0f, 1.5f);

    float bwAcc = 0.0f;
    for (int k = 0; k < 6; ++k) {
        float offset = (float(k) - 2.5f) * 0.60f;
        float xPos = p.x + offset;
        float bwW = (k == 2 || k == 3) ? 0.23f : ((k == 1 || k == 4) ? 0.17f : 0.10f);

        float x0 = floor(xPos);
        float fx = xPos - x0;
        float3 s0 = sampleVideoPixel(origTex, float2(x0, row), imgSz, texSz);
        float3 s1 = sampleVideoPixel(origTex, float2(x0 + 1.0f, row), imgSz, texSz);
        float3 vid = mix(s0, s1, fx);

        if (rfSig > 0.001f) {
            float3 g1 = sampleVideoPixel(origTex, float2(floor(xPos - 5.0f + 0.5f), row), imgSz, texSz);
            float3 g2 = sampleVideoPixel(origTex, float2(floor(xPos - 10.0f + 0.5f), row), imgSz, texSz);
            vid = max(float3(0.0f), vid + (0.115f * g1 - 0.038f * g2) * rfSig);
        }

        float3 yiq = rgbToYiq(vid);
        yiq.yz *= mix(1.0f, 0.88f, wash);
        yiq.x = mix(yiq.x, yiq.x * 0.90f + 0.020f, wash * 0.55f);

        float scPhase = xPos * kSubcarrierRadPerTexel + subcarrierLinePhase;
        float chromaDrive = 0.28f * clamp(rfSig, 0.0f, 1.5f);
        float rfCarrier = yiq.x + baseLift + chromaDrive * (yiq.y * cos(scPhase) + yiq.z * sin(scPhase));

        float rfNoise = sampleRfWaveformNoise(xPos, row, rfSnow, frameSeed, 0.15f, 0.75f) * 0.62f;
        rfNoise *= (rfNoise < 0.0f) ? mix(1.0f, 0.45f, clamp(yiq.x, 0.0f, 1.0f)) : 1.0f;

        bwAcc += (rfCarrier + rfNoise) * bwW;
    }

    float bwVid = clamp(bwAcc * 0.98f + 0.006f, 1e-6f, 1.06f);
    return pow(bwVid, kBwSrcGamma);
}

inline float synthesizeBwScanlines(float rowA, float rowB, float fracY, float2 signal,
                                   float fieldParity, float loadExcess, float pixelRowsPerSrc,
                                   float interlacedFlag, float tvLineDeriv) {
    float picture = mix(rowA, rowB, fracY);
    if (interlacedFlag > 0.5f) {
        float tvLine = (signal.y * 0.5f + 0.5f) * kNtscVisibleLines - 0.5f;
        float dist = abs(glsl_mod(tvLine - fieldParity + 1.0f, 2.0f) - 1.0f);
        float prevDist = 1.0f - dist;
        float beamWidth = 0.54f + 0.22f * sqrt(max(picture, 0.0f)) + 0.04f * loadExcess;
        float d1 = dist / beamWidth;
        float d2 = prevDist / beamWidth;
        float currentLight = exp(-0.5f * d1 * d1);
        float residualLight = exp(-0.5f * d2 * d2);
        float fieldLight = 0.50f + 0.50f * (currentLight + 0.55f * residualLight);
        float fieldPixels = 2.0f / max(tvLineDeriv, 0.001f);
        return picture * mix(0.91f, fieldLight, smoothstep(1.8f, 4.0f, fieldPixels));
    }

    float wa = mix(0.32f, 0.55f, sqrt(max(rowA, 0.0f)));
    float wb = mix(0.32f, 0.55f, sqrt(max(rowB, 0.0f)));
    float scan = rowA * exp(-0.5f * fracY * fracY / (wa * wa));
    scan += rowB * exp(-0.5f * (1.0f - fracY) * (1.0f - fracY) / (wb * wb));
    return mix(picture * 0.89f, scan, smoothstep(1.35f, 3.1f, pixelRowsPerSrc));
}

inline float applyBwHalation(texture2d<float> origTex, float lum, float2 p, float loadExcess, float2 imgSz, float2 texSz) {
    float haloInner = 0.0f, haloOuter = 0.0f;
    for (int i = 0; i < 4; ++i) {
        float2 d1 = (i < 2) ? float2(1.8f, 0.0f) : float2(0.0f, 1.25f);
        float2 d2 = (i < 2) ? float2(3.8f, 0.0f) : float2(0.0f, 2.50f);
        if ((i & 1) == 0) { d1 = -d1; d2 = -d2; }
        float n1 = sampleLinearLuma(origTex, floor(p + d1 + 0.5f), imgSz, texSz);
        float n2 = sampleLinearLuma(origTex, floor(p + d2 + 0.5f), imgSz, texSz);
        haloInner += n1 * n1;
        haloOuter += n2 * n2;
    }
    float halo = haloInner * 0.65f + haloOuter * 0.35f;
    return lum * 1.10f + halo * (0.072f + 0.055f * loadExcess);
}

fragment float4 displayBwFragment(FullscreenOut in [[stage_in]],
                                  texture2d<float> beamTex [[texture(0)]],
                                  texture2d<float> origTex [[texture(1)]],
                                  texture2d<float> prevTex [[texture(2)]],
                                  constant CrtUniforms &u [[buffer(0)]]) {
    float2 imgSz = max(u.origInputSize, float2(1.0f));
    float2 texSz = max(u.origTextureSize, float2(1.0f));
    float beamLoad = beamTex.sample(kNearestClamp, float2(0.5f, 0.5f)).r;
    float loadExcess = max(beamLoad - kBeamLoadKnee, 0.0f) * u.hvBloom;
    float frameSeed = glsl_mod(float(u.frameCount), 4096.0f);
    float phase = frameSeed / 59.94f;
    float fieldParity = glsl_mod(float(u.frameCount), 2.0f);

    CrtRasterGeometry geom = computeCrtRasterGeometry(in.texCoord, imgSz, u.curvature, loadExcess, kBwHvSagExpansion);
    float3 glass = float3(0.016f, 0.016f, 0.017f);
    if (geom.outsideBezel) {
        return float4(srgbToLinear(glass * 0.50f), 1.0f);
    }

    float jAmt = clamp(u.powerJitter, 0.0f, 1.0f);
    applyRfSyncJitter(geom.p, frameSeed, phase, u.rfSnow, u.rfSignal, jAmt, 0.16f);

    float lum;
    if (u.rfStandbySnow > 0.5f) {
        lum = sampleStandbyRfSnow(geom.p, frameSeed, kBwSrcGamma);
        beamLoad = 0.08f;
    } else {
        float effSnow = u.rfSnow + 1.45f * jAmt;
        float effSig = u.rfSignal + 0.65f * jAmt;
        float y = floor(geom.p.y);
        float fracY = fract(geom.p.y);
        float rowA = sampleBwRfScanline(origTex, geom.p, y, effSnow, effSig, frameSeed, imgSz, texSz);
        float rowB = sampleBwRfScanline(origTex, geom.p, y + 1.0f, effSnow, effSig, frameSeed, imgSz, texSz);
        float picture = mix(rowA, rowB, fracY);
        lum = synthesizeBwScanlines(rowA, rowB, fracY, geom.signal, fieldParity, loadExcess,
                                    geom.pixelRowsPerSrc, u.interlaced, geom.tvLineDeriv);

        float2 q = floor(geom.p + 0.5f);
        float prevY = sampleLinearLuma(prevTex, q, imgSz, texSz);
        lum += max(prevY - picture, 0.0f) * 0.175f;
        lum = applyBwHalation(origTex, lum, geom.p, loadExcess, imgSz, texSz);
    }

    float vignette = 1.0f - 0.22f * smoothstep(0.25f, 1.85f, dot(geom.face, geom.face));
    float agcWave = 1.0f + 0.014f * u.rfSignal * sin(geom.p.y * 0.05f + phase * 3.1f);
    float rawL = max(lum * vignette * agcWave, 1e-6f);
    // In SDR keep the soft P4 rolloff <= 1.25; in HDR allow P4 silver-white cathode glow to reach further cleanly.
    float hdrFactor = max(clamp(u.hdrHeadroom, 1.0f, 3.5f) - 1.0f, 0.0f) * clamp(u.hdrBoost, 0.0f, 1.5f);
    float maxMono = mix(1.25f, 2.20f, saturate(hdrFactor * 0.6f));
    float monoL = clamp(rawL / (1.0f + 0.14f * rawL), 1e-6f, maxMono);
    float3 p4Tint = mix(float3(0.98f, 0.98f, 0.97f), float3(0.98f, 0.99f, 1.00f), smoothstep(0.10f, 0.85f, monoL));

    return finalizeCrtPixel(float3(monoL) * pow(p4Tint, float3(2.2f)), beamLoad, geom.aperture, geom.raster,
                            glass, geom.reflection, geom.lip, 0.0f, u.hdrHeadroom, u.hdrBoost);
}
