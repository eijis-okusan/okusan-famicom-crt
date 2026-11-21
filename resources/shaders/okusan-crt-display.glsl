#version 120

// Okusan CRT Dynamics - Pass 1: 525-Line Interlaced RGB CRT Display
// Synthesizes NTSC 480i field alternation (or 240p scanlines), flyback HV bloom,
// RGB gun convergence, P22 phosphor decay, glass halation, and aperture slots.

#pragma parameter OKUSAN_INTERLACED "NTSC 480i Field Interlace (0=240p, 1=480i)" 1.0 0.0 1.0 1.0
#pragma parameter OKUSAN_HV_BLOOM "Flyback HV Bloom Strength" 1.0 0.0 2.0 0.1
#pragma parameter OKUSAN_CURVATURE "Tube Curvature" 1.0 0.0 1.5 0.1
#pragma parameter OKUSAN_MASK_STRENGTH "Phosphor Slot Mask" 1.0 0.0 1.5 0.1

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
    // Remap pass UVs to [0, 1] across the viewport regardless of POT padding.
    vec2 inputScale = max(InputSize / max(TextureSize, vec2(1.0)), vec2(0.0001));
    vTexCoord = TexCoord / inputScale;
}

#elif defined(FRAGMENT)

const float SRC_GAMMA = 2.25;
const float DISPLAY_INV_GAMMA = 1.0 / 2.2;
const float BEAM_SIGMA_X = 0.55;
const float BEAM_LOAD_KNEE = 0.14;
const float HV_SAG_EXPANSION = 0.015;
const float NTSC_VISIBLE_LINES = 480.0; // 525 total NTSC lines minus 45 vertical blanking lines
const vec3 GUN_CONVERGENCE = vec3(-0.13, 0.0, 0.16);
const vec3 P22_DECAY = vec3(0.055, 0.11, 0.075);

uniform sampler2D Texture;          // Pass 0 output: damped quadratic beam load
uniform sampler2D OrigTexture;      // Current source frame
uniform sampler2D PrevTexture;      // Previous source frame for phosphor persistence
uniform vec2 OrigInputSize;
uniform vec2 OrigTextureSize;
uniform vec2 OutputSize;
uniform int FrameCount;

#ifdef PARAMETER_UNIFORM
uniform float OKUSAN_INTERLACED;
uniform float OKUSAN_HV_BLOOM;
uniform float OKUSAN_CURVATURE;
uniform float OKUSAN_MASK_STRENGTH;
#else
#define OKUSAN_INTERLACED 1.0
#define OKUSAN_HV_BLOOM 1.0
#define OKUSAN_CURVATURE 1.0
#define OKUSAN_MASK_STRENGTH 1.0
#endif

varying vec2 vTexCoord;

vec3 sampleLinearPixel(sampler2D source, vec2 texelCoord, vec2 imgSz, vec2 texSz)
{
    vec2 clamped = clamp(texelCoord, vec2(0.0), imgSz - 1.0);
    vec2 uv = (clamped + 0.5) / max(texSz, vec2(1.0));
    return pow(max(texture2D(source, uv).rgb, vec3(1e-6)), vec3(SRC_GAMMA));
}

// 5-tap horizontal RGB beam aperture with slight analog gun convergence offset.
vec3 sampleHorizontalBeam(vec2 p, float row, vec2 imgSz, vec2 texSz)
{
    float center = floor(p.x + 0.5);
    vec3 energy = vec3(0.0);
    vec3 total = vec3(0.0);
    for (int i = -2; i <= 2; ++i) {
        float x = center + float(i);
        vec3 dist = vec3(p.x - x) + GUN_CONVERGENCE;
        vec3 weight = exp(-dist * dist / (2.0 * BEAM_SIGMA_X * BEAM_SIGMA_X));
        energy += sampleLinearPixel(OrigTexture, vec2(x, row), imgSz, texSz) * weight;
        total += weight;
    }
    return energy / total;
}

// Signed distance to the rounded bezel aperture in curved face space [-1, 1].
float roundedBezelDistance(vec2 p)
{
    vec2 d = abs(p) - vec2(0.924, 0.906);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - 0.074;
}

// Render either 525-line 480i alternating fields or progressive 240p scanlines.
vec3 synthesizeScanlines(vec3 rowA, vec3 rowB, float fracY, vec2 signal, float fieldParity, float loadExcess, float pixelRowsPerSrc)
{
    vec3 picture = mix(rowA, rowB, fracY);
    if (OKUSAN_INTERLACED > 0.5) {
        float tvLine = (signal.y * 0.5 + 0.5) * NTSC_VISIBLE_LINES - 0.5;
        float dist = abs(mod(tvLine - fieldParity + 1.0, 2.0) - 1.0);
        float prevDist = 1.0 - dist;
        float peakLum = max(picture.r, max(picture.g, picture.b));
        float beamWidth = 0.48 + 0.12 * sqrt(peakLum) + 0.03 * loadExcess;
        float d1 = dist / beamWidth;
        float d2 = prevDist / beamWidth;
        float currentLight = exp(-0.5 * d1 * d1);
        float residualLight = exp(-0.5 * d2 * d2);
        float fieldLight = 0.34 + 0.66 * (currentLight + 0.55 * residualLight);
        float fieldPixels = 2.0 / max(abs(dFdy(tvLine)), 0.001);
        return picture * mix(0.86, fieldLight, smoothstep(1.8, 4.0, fieldPixels));
    }

    float wa = mix(0.24, 0.42, sqrt(max(rowA.r, max(rowA.g, rowA.b))));
    float wb = mix(0.24, 0.42, sqrt(max(rowB.r, max(rowB.g, rowB.b))));
    vec3 scan = rowA * exp(-0.5 * fracY * fracY / (wa * wa));
    scan += rowB * exp(-0.5 * (1.0 - fracY) * (1.0 - fracY) / (wb * wb));
    return mix(picture * 0.83, scan, smoothstep(1.35, 3.1, pixelRowsPerSrc));
}

// 4-tap axial glass halation weighted by squared neighbor intensity and HV load.
vec3 applyGlassHalation(vec3 rgb, vec2 p, float loadExcess, vec2 imgSz, vec2 texSz)
{
    vec3 halo = vec3(0.0);
    for (int i = 0; i < 4; ++i) {
        vec2 d = i < 2 ? vec2(2.6, 0.0) : vec2(0.0, 1.65);
        if (mod(float(i), 2.0) == 0.0) d = -d;
        vec3 neighbor = sampleLinearPixel(OrigTexture, floor(p + d + 0.5), imgSz, texSz);
        halo += neighbor * neighbor;
    }
    return rgb * 1.16 + halo * (0.044 + 0.036 * loadExcess);
}

// Staggered RGB phosphor slot mask scaled to preserve fine pitch across HiDPI and 1x viewports.
vec3 applyPhosphorMask(vec3 rgb, vec2 screen, float viewWidth, float srcWidth)
{
    float pitch = clamp(viewWidth / max(srcWidth * 1.35, 1.0), 3.0, 6.0);
    float maskRow = floor(screen.y / pitch);
    float stripe = fract(screen.x / pitch + 0.5 * mod(maskRow, 2.0));
    vec3 slots = 1.0 - smoothstep(vec3(0.06), vec3(0.235),
                     abs(fract(stripe - vec3(0.0, 0.3333, 0.6667) + 0.5) - 0.5));
    float rowGap = smoothstep(0.27, 0.47, abs(fract(screen.y / pitch) - 0.5));
    float strength = mix(0.56, 1.0, smoothstep(360.0, 750.0, viewWidth)) * OKUSAN_MASK_STRENGTH;
    return rgb * mix(vec3(1.0), (0.72 + 0.45 * slots) * (1.0 - 0.15 * rowGap), clamp(strength, 0.0, 1.0));
}

void main()
{
    vec2 imgSz = max(OrigInputSize, vec2(1.0));
    vec2 texSz = max(OrigTextureSize, vec2(1.0));
    float beamLoad = texture2D(Texture, vec2(0.5, 0.5)).r;
    float loadExcess = max(beamLoad - BEAM_LOAD_KNEE, 0.0) * OKUSAN_HV_BLOOM;
    float phase = mod(float(FrameCount), 4096.0) / 59.94;
    float fieldParity = mod(float(FrameCount), 2.0);

    vec2 face = vTexCoord * 2.0 - 1.0;
    vec2 warp = vec2(0.083, 0.110) * OKUSAN_CURVATURE;
    vec2 curved = face * (vec2(1.0 + 0.015 * OKUSAN_CURVATURE) + face.yx * face.yx * warp);
    float edgeDistance = roundedBezelDistance(curved);
    vec3 glass = vec3(0.010, 0.014, 0.017);
    if (edgeDistance > 0.07) {
        gl_FragColor = vec4(glass * 0.50, 1.0);
        return;
    }

    float aperture = 1.0 - smoothstep(-0.012, 0.005, edgeDistance);
    float lip = exp(-abs(edgeDistance - 0.023) * 75.0);

    // Anode HV sag slightly expands raster size during bright screen flashes.
    float hvBloom = 1.0 + HV_SAG_EXPANSION * loadExcess;
    vec2 signal = curved / (vec2(0.94, 0.90) * hvBloom);
    vec2 signalEdge = abs(signal);
    float raster = (1.0 - smoothstep(1.0, 1.0 + 2.0 / imgSz.x, signalEdge.x))
                 * (1.0 - smoothstep(1.0, 1.0 + 2.0 / imgSz.y, signalEdge.y));

    vec2 p = (signal * 0.5 + 0.5) * imgSz - 0.5;
    float y = floor(p.y);
    float fracY = fract(p.y);

    vec3 rowA = sampleHorizontalBeam(p, y, imgSz, texSz);
    vec3 rowB = sampleHorizontalBeam(p, y + 1.0, imgSz, texSz);
    vec3 picture = mix(rowA, rowB, fracY);
    float pixelRowsPerSrc = 1.0 / max(abs(dFdy(p.y)), 0.001);
    vec3 rgb = synthesizeScanlines(rowA, rowB, fracY, signal, fieldParity, loadExcess, pixelRowsPerSrc);

    // Short phosphor decay biased toward P22 green/cyan phosphors.
    vec2 q = floor(p + 0.5);
    vec3 previous = sampleLinearPixel(PrevTexture, q, imgSz, texSz);
    rgb += max(previous - picture, 0.0) * P22_DECAY;

    rgb = applyGlassHalation(rgb, p, loadExcess, imgSz, texSz);
    float viewWidth = OutputSize.x > 1.0 ? OutputSize.x : (1.0 / max(abs(dFdx(vTexCoord.x)), 0.0001));
    rgb = applyPhosphorMask(rgb, gl_FragCoord.xy, viewWidth, imgSz.x);

    float vignette = 1.0 - 0.24 * smoothstep(0.25, 1.85, dot(face, face));
    float hum = 1.0 + 0.003 * sin(p.y * 0.08 + phase * 2.0);
    vec3 light = pow(max(rgb * vignette * hum, vec3(1e-6)), vec3(DISPLAY_INV_GAMMA));
    float noise = fract(sin(dot(mod(gl_FragCoord.xy, 317.0), vec2(12.9898, 78.233)) + phase * 17.0) * 43758.5453) - 0.5;
    light += noise * 0.008;

    float reflection = exp(-4.0 * dot(face - vec2(-0.42, -0.53), face - vec2(-0.42, -0.53)));
    vec3 color = max(light, vec3(0.0)) * aperture * raster + glass * (0.74 + 0.48 * reflection + lip);
    gl_FragColor = vec4(color, 1.0);
}

#endif
