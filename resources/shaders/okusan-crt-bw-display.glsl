#version 120

// Okusan CRT Dynamics - Monochrome (B&W) VHF RF Television Shader
// Emulates a Showa single-electron-gun P4 phosphor monochrome CRT TV connected
// via 300-ohm VHF RF:
// - Pure scalar luminance pipeline: ZERO RGB pixels, ZERO shadow/slot mask triads,
//   ZERO 3-gun convergence error, and ZERO I/Q color decoding.
// - Unfiltered composite video detection (no 3.58 MHz chroma trap): NTSC chroma
//   naturally beats into the video amplifier as authentic monochrome 3.58 MHz dot crawl,
//   while peaking coils keep monochrome luminance edges sharp and punchy.
// - Continuous P4 silver-white phosphor with cathode-current spot blooming, P4 persistence,
//   monochrome RF snow, 300-ohm echoes, and stronger HV flyback sag.

#pragma parameter OKUSAN_RF_SNOW "RF Antenna Noise & Static" 1.0 0.0 2.0 0.1
#pragma parameter OKUSAN_RF_SIGNAL "RF Echoes & Subcarrier Beats" 1.0 0.0 2.0 0.1
#pragma parameter OKUSAN_INTERLACED "NTSC 480i Field Interlace (0=240p, 1=480i)" 1.0 0.0 1.0 1.0
#pragma parameter OKUSAN_HV_BLOOM "Flyback HV Bloom Strength" 1.0 0.0 2.0 0.1
#pragma parameter OKUSAN_CURVATURE "Tube Curvature" 1.0 0.0 1.5 0.1
#pragma parameter OKUSAN_MASK_STRENGTH "Unused in B&W" 1.0 0.0 1.5 0.1

#if defined(VERTEX)

uniform mat4 MVPMatrix;
uniform vec2 InputSize;
uniform vec2 TextureSize;
attribute vec4 VertexCoord;
attribute vec2 TexCoord;
varying vec2 vTexCoord;

void main()
{
    gl_Position = MVPMatrix * VertexCoord;
    vec2 inputScale = max(InputSize / max(TextureSize, vec2(1.0)), vec2(0.0001));
    vTexCoord = TexCoord / inputScale;
}

#elif defined(FRAGMENT)

const float SRC_GAMMA = 2.02;
const float DISPLAY_INV_GAMMA = 1.0 / 2.2;
const float BEAM_LOAD_KNEE = 0.14;
const float HV_SAG_EXPANSION = 0.022;
const float NTSC_VISIBLE_LINES = 480.0;
const float PI = 3.14159265;
const float SUBCARRIER_RAD_PER_TEXEL = 2.09439510; // 2 * pi / 3 per source pixel (~3.58 MHz)
const float RF_GHOST_NEAR_TAP = -5.0;
const float RF_GHOST_FAR_TAP = -10.0;
const float RF_GHOST_NEAR_GAIN = 0.115;
const float RF_GHOST_FAR_GAIN = 0.038;
const float RF_SYNC_FLUTTER = 0.16;
const float P4_PERSISTENCE = 0.175;
const vec3 LUMA_WEIGHTS = vec3(0.299, 0.587, 0.114);

uniform sampler2D Texture;          // Pass 0 output: damped quadratic beam load
uniform sampler2D OrigTexture;      // Current source frame
uniform sampler2D PrevTexture;      // Previous source frame for P4 phosphor persistence
uniform vec2 OrigInputSize;
uniform vec2 OrigTextureSize;
uniform vec2 OutputSize;
uniform int FrameCount;

#ifdef PARAMETER_UNIFORM
uniform float OKUSAN_RF_SNOW;
uniform float OKUSAN_RF_SIGNAL;
uniform float OKUSAN_INTERLACED;
uniform float OKUSAN_HV_BLOOM;
uniform float OKUSAN_CURVATURE;
uniform float OKUSAN_MASK_STRENGTH;
uniform float OKUSAN_RF_STANDBY_SNOW;
uniform float OKUSAN_POWER_JITTER;
#else
#define OKUSAN_RF_SNOW 1.0
#define OKUSAN_RF_SIGNAL 1.0
#define OKUSAN_INTERLACED 1.0
#define OKUSAN_HV_BLOOM 1.0
#define OKUSAN_CURVATURE 1.0
#define OKUSAN_MASK_STRENGTH 1.0
#define OKUSAN_RF_STANDBY_SNOW 0.0
#define OKUSAN_POWER_JITTER 0.0
#endif

varying vec2 vTexCoord;

float hash13(vec3 p3)
{
    p3 = fract(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}

float hash11(float n)
{
    return hash13(vec3(n, n * 0.37, 17.13));
}

float sample1DBandNoise(float x, float row, float seed)
{
    float i = floor(x);
    float f = fract(x);
    float u = f * f * (3.0 - 2.0 * f);
    float a = hash13(vec3(i,       row, seed));
    float b = hash13(vec3(i + 1.0, row, seed));
    return mix(a, b, u) - 0.5;
}

float sampleRfWaveformNoise(float x, float row, float rfSnow, float frameSeed)
{
    if (rfSnow <= 0.001) return 0.0;

    float s = mod(frameSeed, 1024.0);
    float g1 = sample1DBandNoise(x * 0.85, row, s * 1.13 + 3.7);
    float g2 = sample1DBandNoise(x * 1.35 + 17.3, row, s * 2.41 + 19.1);
    float g3 = sample1DBandNoise(x * 1.95 + 53.1, row, s * 3.79 + 41.9);
    float gauss = (g1 * 0.50 + g2 * 0.35 + g3 * 0.25);

    float impRnd = hash13(vec3(floor(x * 0.75), row, s * 5.17 + 7.3));
    float impMask = smoothstep(0.93 - 0.025 * min(rfSnow, 1.5), 0.997, impRnd);
    float impSign = hash13(vec3(floor(x * 0.75), row, s * 7.03 + 29.0)) > 0.32 ? 1.0 : -1.0;

    return (gauss * 0.13 + impMask * impSign * 0.15) * rfSnow;
}

vec3 sampleVideoPixel(sampler2D source, vec2 texelCoord, vec2 imgSz, vec2 texSz)
{
    vec2 clamped = clamp(texelCoord, vec2(0.0), imgSz - 1.0);
    vec2 uv = (clamped + 0.5) / max(texSz, vec2(1.0));
    return max(texture2D(source, uv).rgb, vec3(0.0));
}

float sampleLinearLuma(sampler2D source, vec2 texelCoord, vec2 imgSz, vec2 texSz)
{
    float y = dot(sampleVideoPixel(source, texelCoord, imgSz, texSz), LUMA_WEIGHTS);
    return pow(max(y, 1e-6), SRC_GAMMA);
}

vec3 encodeYiq(vec3 c)
{
    return vec3(
        dot(c, LUMA_WEIGHTS),
        dot(c, vec3(0.596, -0.274, -0.322)),
        dot(c, vec3(0.211, -0.523,  0.312))
    );
}

// Pure scalar monochrome RF tuner + soft home-TV IF bandwidth + gentle single-gun spot rolloff.
// Deliberately avoids sharp peaking so edges round organically like a mellow Showa B&W tube.
float sampleBwRfScanline(vec2 p, float row, float rfSnow, float rfSig, float frameSeed, vec2 imgSz, vec2 texSz)
{
    float subcarrierLinePhase = row * SUBCARRIER_RAD_PER_TEXEL + mod(frameSeed, 3.0) * 0.7;
    float wash = clamp(rfSig * 0.42, 0.0, 0.75);
    float baseLift = 0.020 * clamp(rfSnow, 0.0, 1.5);

    float bwAcc = 0.0;

    for (int k = 0; k < 6; ++k) {
        // Wider 0.60-texel span gently softens hard NES square edges into smooth analog cathode drive.
        float offset = (float(k) - 2.5) * 0.60;
        float xPos = p.x + offset;
        float bwW = (k == 2 || k == 3) ? 0.23 : ((k == 1 || k == 4) ? 0.17 : 0.10);

        float x0 = floor(xPos);
        float fx = xPos - x0;
        vec3 s0 = sampleVideoPixel(OrigTexture, vec2(x0, row), imgSz, texSz);
        vec3 s1 = sampleVideoPixel(OrigTexture, vec2(x0 + 1.0, row), imgSz, texSz);
        vec3 vid = mix(s0, s1, fx);

        if (rfSig > 0.001) {
            vec3 g1 = sampleVideoPixel(OrigTexture, vec2(floor(xPos + RF_GHOST_NEAR_TAP + 0.5), row), imgSz, texSz);
            vec3 g2 = sampleVideoPixel(OrigTexture, vec2(floor(xPos + RF_GHOST_FAR_TAP + 0.5), row), imgSz, texSz);
            vid = max(vec3(0.0), vid + (RF_GHOST_NEAR_GAIN * g1 - RF_GHOST_FAR_GAIN * g2) * rfSig);
        }

        vec3 yiq = encodeYiq(vid);
        yiq.yz *= mix(1.0, 0.88, wash);
        yiq.x = mix(yiq.x, yiq.x * 0.90 + 0.020, wash * 0.55);

        float scPhase = xPos * SUBCARRIER_RAD_PER_TEXEL + subcarrierLinePhase;
        float chromaDrive = 0.28 * clamp(rfSig, 0.0, 1.5);
        float rfCarrier = yiq.x + baseLift + chromaDrive * (yiq.y * cos(scPhase) + yiq.z * sin(scPhase));

        float rfNoise = sampleRfWaveformNoise(xPos, row, rfSnow, frameSeed);
        rfNoise *= (rfNoise < 0.0) ? mix(1.0, 0.45, clamp(yiq.x, 0.0, 1.0)) : 1.0;

        bwAcc += (rfCarrier + rfNoise) * bwW;
    }

    float bwVid = clamp(bwAcc * 0.98 + 0.006, 1e-6, 1.06);
    return pow(bwVid, SRC_GAMMA);
}

float roundedBezelDistance(vec2 p)
{
    vec2 d = abs(p) - vec2(0.924, 0.906);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - 0.074;
}

float synthesizeBwScanlines(float rowA, float rowB, float fracY, vec2 signal, float fieldParity, float loadExcess, float pixelRowsPerSrc)
{
    float picture = mix(rowA, rowB, fracY);
    if (OKUSAN_INTERLACED > 0.5) {
        float tvLine = (signal.y * 0.5 + 0.5) * NTSC_VISIBLE_LINES - 0.5;
        float dist = abs(mod(tvLine - fieldParity + 1.0, 2.0) - 1.0);
        float prevDist = 1.0 - dist;
        // Soft, generous single-gun spot profile merges scanlines gently without harsh Venetian-blind cuts.
        float beamWidth = 0.54 + 0.22 * sqrt(max(picture, 0.0)) + 0.04 * loadExcess;
        float d1 = dist / beamWidth;
        float d2 = prevDist / beamWidth;
        float currentLight = exp(-0.5 * d1 * d1);
        float residualLight = exp(-0.5 * d2 * d2);
        float fieldLight = 0.50 + 0.50 * (currentLight + 0.55 * residualLight);
        float fieldPixels = 2.0 / max(abs(dFdy(tvLine)), 0.001);
        return picture * mix(0.91, fieldLight, smoothstep(1.8, 4.0, fieldPixels));
    }

    float wa = mix(0.32, 0.55, sqrt(max(rowA, 0.0)));
    float wb = mix(0.32, 0.55, sqrt(max(rowB, 0.0)));
    float scan = rowA * exp(-0.5 * fracY * fracY / (wa * wa));
    scan += rowB * exp(-0.5 * (1.0 - fracY) * (1.0 - fracY) / (wb * wb));
    return mix(picture * 0.89, scan, smoothstep(1.35, 3.1, pixelRowsPerSrc));
}

float applyBwHalation(float lum, vec2 p, float loadExcess, vec2 imgSz, vec2 texSz)
{
    float haloInner = 0.0;
    float haloOuter = 0.0;
    for (int i = 0; i < 4; ++i) {
        vec2 d1 = i < 2 ? vec2(1.8, 0.0) : vec2(0.0, 1.25);
        vec2 d2 = i < 2 ? vec2(3.8, 0.0) : vec2(0.0, 2.50);
        if (mod(float(i), 2.0) == 0.0) { d1 = -d1; d2 = -d2; }
        float n1 = sampleLinearLuma(OrigTexture, floor(p + d1 + 0.5), imgSz, texSz);
        float n2 = sampleLinearLuma(OrigTexture, floor(p + d2 + 0.5), imgSz, texSz);
        haloInner += n1 * n1;
        haloOuter += n2 * n2;
    }
    float halo = haloInner * 0.65 + haloOuter * 0.35;
    return lum * 1.10 + halo * (0.072 + 0.055 * loadExcess);
}

void main()
{
    vec2 imgSz = max(OrigInputSize, vec2(1.0));
    vec2 texSz = max(OrigTextureSize, vec2(1.0));
    float beamLoad = texture2D(Texture, vec2(0.5, 0.5)).r;
    float loadExcess = max(beamLoad - BEAM_LOAD_KNEE, 0.0) * OKUSAN_HV_BLOOM;
    float frameSeed = mod(float(FrameCount), 4096.0);
    float phase = frameSeed / 59.94;
    float fieldParity = mod(float(FrameCount), 2.0);

    vec2 face = vTexCoord * 2.0 - 1.0;
    vec2 warp = vec2(0.083, 0.110) * OKUSAN_CURVATURE;
    vec2 curved = face * (vec2(1.0 + 0.015 * OKUSAN_CURVATURE) + face.yx * face.yx * warp);
    float edgeDistance = roundedBezelDistance(curved);
    vec3 glass = vec3(0.016, 0.016, 0.017);
    if (edgeDistance > 0.07) {
        gl_FragColor = vec4(glass * 0.50, 1.0);
        return;
    }

    float aperture = 1.0 - smoothstep(-0.012, 0.005, edgeDistance);
    float lip = exp(-abs(edgeDistance - 0.023) * 75.0);

    float hvBloom = 1.0 + HV_SAG_EXPANSION * loadExcess;
    vec2 signal = curved / (vec2(0.94, 0.90) * hvBloom);
    vec2 signalEdge = abs(signal);
    float raster = (1.0 - smoothstep(1.0, 1.0 + 2.0 / imgSz.x, signalEdge.x))
                 * (1.0 - smoothstep(1.0, 1.0 + 2.0 / imgSz.y, signalEdge.y));

    vec2 p = (signal * 0.5 + 0.5) * imgSz - 0.5;
    float lineHash = hash11(floor(p.y) + mod(frameSeed, 1024.0) * 19.37);
    float jAmt = clamp(OKUSAN_POWER_JITTER, 0.0, 1.0);
    float jitWave = sin(p.y * 0.09 + frameSeed * 1.37) * 2.2 * jAmt;
    float jitLine = (lineHash - 0.5) * 5.2 * jAmt;
    p.x += (lineHash - 0.5) * RF_SYNC_FLUTTER * OKUSAN_RF_SNOW
         + 0.04 * sin(p.y * 1.2 + phase * 5.0) * OKUSAN_RF_SIGNAL
         + jitWave + jitLine;
    p.y += sin(frameSeed * 2.1) * 1.5 * jAmt;

    float lum;
    if (OKUSAN_RF_STANDBY_SNOW > 0.5) {
        float sSeed = mod(frameSeed, 1024.0);
        float rowQ = floor(p.y);
        float colQ = floor(p.x * 1.15);
        float fineWhite = hash13(vec3(colQ, rowQ, sSeed * 4.37 + 13.1)) - 0.5;
        float medWhite = sample1DBandNoise(p.x * 0.72 + 11.7, rowQ, sSeed * 1.91 + 5.3);
        float rowJitter = (hash11(rowQ + sSeed * 7.13) - 0.5) * 0.14;
        float baseSnow = clamp(0.38 + 0.54 * fineWhite + 0.36 * medWhite + rowJitter, 0.02, 0.94);
        float scanAtten = 0.84 + 0.16 * cos(fract(p.y) * 2.0 * PI);
        lum = pow(baseSnow, SRC_GAMMA) * scanAtten;
    } else {
        float effSnow = OKUSAN_RF_SNOW + 1.45 * jAmt;
        float effSig = OKUSAN_RF_SIGNAL + 0.65 * jAmt;
        float y = floor(p.y);
        float fracY = fract(p.y);

        float rowA = sampleBwRfScanline(p, y, effSnow, effSig, frameSeed, imgSz, texSz);
        float rowB = sampleBwRfScanline(p, y + 1.0, effSnow, effSig, frameSeed, imgSz, texSz);
        float picture = mix(rowA, rowB, fracY);
        float pixelRowsPerSrc = 1.0 / max(abs(dFdy(p.y)), 0.001);
        lum = synthesizeBwScanlines(rowA, rowB, fracY, signal, fieldParity, loadExcess, pixelRowsPerSrc);

        vec2 q = floor(p + 0.5);
        float prevY = sampleLinearLuma(PrevTexture, q, imgSz, texSz);
        lum += max(prevY - picture, 0.0) * P4_PERSISTENCE;
        lum = applyBwHalation(lum, p, loadExcess, imgSz, texSz);
    }

    // Continuous mellow P4 phosphor layer: gentle highlight roll-off and creamy neutral silver-white glow.
    float vignette = 1.0 - 0.22 * smoothstep(0.25, 1.85, dot(face, face));
    float agcWave = 1.0 + 0.014 * OKUSAN_RF_SIGNAL * sin(p.y * 0.05 + phase * 3.1);
    float rawL = max(lum * vignette * agcWave, 1e-6);
    float monoL = clamp(rawL / (1.0 + 0.14 * rawL), 1e-6, 1.25);
    float emitted = pow(monoL, DISPLAY_INV_GAMMA);
    vec3 p4Tint = mix(vec3(0.98, 0.98, 0.97), vec3(0.98, 0.99, 1.00), smoothstep(0.10, 0.85, monoL));

    float reflection = exp(-4.0 * dot(face - vec2(-0.42, -0.53), face - vec2(-0.42, -0.53)));
    vec3 color = max(emitted * p4Tint, vec3(0.0)) * aperture * raster + glass * (0.74 + 0.48 * reflection + lip);
    gl_FragColor = vec4(color, 1.0);
}

#endif
