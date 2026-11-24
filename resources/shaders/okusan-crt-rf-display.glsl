#version 120

// Okusan CRT Dynamics - Pass 1: Loose VHF RF NTSC Signal & Noise Emulation
// Emulates NTSC YIQ composite encoding on each scanline, cable echo ghosts,
// loose-antenna thermal Gaussian + impulse noise before demodulation, and
// 6-tap orthogonal subcarrier demodulation (naturally producing white/color snow,
// 3.58 MHz cross-color on fine detail, and chroma dot crawl) over the 480i CRT.

#pragma parameter OKUSAN_RF_SNOW "RF Antenna Noise & Static" 1.0 0.0 2.0 0.1
#pragma parameter OKUSAN_RF_SIGNAL "RF Echoes, Washout & Subcarrier Leaks" 1.0 0.0 2.0 0.1
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
    vec2 inputScale = max(InputSize / max(TextureSize, vec2(1.0)), vec2(0.0001));
    vTexCoord = TexCoord / inputScale;
}

#elif defined(FRAGMENT)

const float SRC_GAMMA = 2.25;
const float DISPLAY_INV_GAMMA = 1.0 / 2.2;
const float BEAM_LOAD_KNEE = 0.14;
const float HV_SAG_EXPANSION = 0.015;
const float NTSC_VISIBLE_LINES = 480.0;
const float PI = 3.14159265;
const float SUBCARRIER_RAD_PER_TEXEL = 2.09439510; // 2 * pi / 3 per source pixel (~3.58 MHz)
const float RF_GHOST_NEAR_TAP = -5.0;
const float RF_GHOST_FAR_TAP = -10.0;
const float RF_GHOST_NEAR_GAIN = 0.12;
const float RF_GHOST_FAR_GAIN = 0.04;
const float RF_CHROMA_NOISE_PASSBAND = 0.40;
const float RF_SYNC_FLUTTER = 0.20;
const vec3 LUMA_WEIGHTS = vec3(0.299, 0.587, 0.114);
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

// Sin-free integer-independent hashes so GPU fast-math cannot introduce periodic banding.
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

// Continuous 1D band-limited analog noise along a single scanline (uncorrelated across lines).
float sample1DBandNoise(float x, float row, float seed)
{
    float i = floor(x);
    float f = fract(x);
    float u = f * f * (3.0 - 2.0 * f);
    float a = hash13(vec3(i,       row, seed));
    float b = hash13(vec3(i + 1.0, row, seed));
    return mix(a, b, u) - 0.5;
}

// Emulate RF receiver IF thermal Gaussian noise + impulse static along scanline x.
float sampleRfWaveformNoise(float x, float row, float rfSnow, float frameSeed)
{
    if (rfSnow <= 0.001) return 0.0;

    float s = mod(frameSeed, 1024.0);
    // Sum independent 1D bands (~0.85x and ~1.45x texel rate) for approximate Gaussian distribution.
    float g1 = sample1DBandNoise(x * 0.85, row, s * 1.13 + 3.7);
    float g2 = sample1DBandNoise(x * 1.35 + 17.3, row, s * 2.41 + 19.1);
    float g3 = sample1DBandNoise(x * 1.95 + 53.1, row, s * 3.79 + 41.9);
    float gauss = (g1 * 0.50 + g2 * 0.35 + g3 * 0.25);

    // Non-linear IF envelope detector creates stronger bright white impulse snow bursts.
    float impRnd = hash13(vec3(floor(x * 0.90), row, s * 5.17 + 7.3));
    float impMask = smoothstep(0.91 - 0.035 * min(rfSnow, 1.5), 0.995, impRnd);
    float impSign = hash13(vec3(floor(x * 0.90), row, s * 7.03 + 29.0)) > 0.28 ? 1.0 : -1.0;

    return (gauss * 0.23 + impMask * impSign * 0.32) * rfSnow;
}

vec3 sampleVideoPixel(sampler2D source, vec2 texelCoord, vec2 imgSz, vec2 texSz)
{
    vec2 clamped = clamp(texelCoord, vec2(0.0), imgSz - 1.0);
    vec2 uv = (clamped + 0.5) / max(texSz, vec2(1.0));
    return max(texture2D(source, uv).rgb, vec3(0.0));
}

vec3 sampleLinearPixel(sampler2D source, vec2 texelCoord, vec2 imgSz, vec2 texSz)
{
    return pow(max(sampleVideoPixel(source, texelCoord, imgSz, texSz), vec3(1e-6)), vec3(SRC_GAMMA));
}

vec3 rgbToYiq(vec3 c)
{
    return vec3(
        dot(c, LUMA_WEIGHTS),
        dot(c, vec3(0.596, -0.274, -0.322)),
        dot(c, vec3(0.211, -0.523,  0.312))
    );
}

vec3 yiqToRgb(vec3 yiq)
{
    return vec3(
        yiq.x + 0.956 * yiq.y + 0.621 * yiq.z,
        yiq.x - 0.272 * yiq.y - 0.647 * yiq.z,
        yiq.x - 1.106 * yiq.y + 1.703 * yiq.z
    );
}

// Emulate NTSC RF transmission & TV demodulation across one scanline:
// 1) Encode RGB -> YIQ + cable reflection ghosts + 3.58 MHz subcarrier modulation.
// 2) Inject RF thermal & impulse waveform noise directly onto the modulated RF signal.
// 3) Demodulate across one full subcarrier cycle (6 taps at 0.5px = 60 deg steps),
//    which orthogonally recovers flat colors while naturally producing cross-color on
//    white detail, chroma dot crawl, and realistic luminance + chroma RF snow.
vec3 sampleRfScanline(vec2 p, float row, float rfSnow, float rfSig, float frameSeed, vec2 imgSz, vec2 texSz)
{
    float subcarrierLinePhase = row * PI + mod(frameSeed, 2.0) * 0.45;
    float wash = clamp(rfSig * 0.5, 0.0, 0.85);
    float baseLift = 0.026 * clamp(rfSnow, 0.0, 1.5);

    float yAcc = 0.0;
    float iAcc = 0.0;
    float qAcc = 0.0;

    // 6 taps spanning [-1.25, +1.25] texels (exact 360-degree subcarrier period).
    for (int k = 0; k < 6; ++k) {
        float offset = (float(k) - 2.5) * 0.5;
        float xPos = p.x + offset;

        // Piecewise linear source sample preserves subpixel positions smoothly.
        float x0 = floor(xPos);
        float fx = xPos - x0;
        vec3 s0 = sampleVideoPixel(OrigTexture, vec2(x0, row), imgSz, texSz);
        vec3 s1 = sampleVideoPixel(OrigTexture, vec2(x0 + 1.0, row), imgSz, texSz);
        vec3 vid = mix(s0, s1, fx);

        // Add RF cable reflection echoes before modulation/detection.
        if (rfSig > 0.001) {
            vec3 g1 = sampleVideoPixel(OrigTexture, vec2(floor(xPos + RF_GHOST_NEAR_TAP + 0.5), row), imgSz, texSz);
            vec3 g2 = sampleVideoPixel(OrigTexture, vec2(floor(xPos + RF_GHOST_FAR_TAP + 0.5), row), imgSz, texSz);
            vid = max(vec3(0.0), vid + (RF_GHOST_NEAR_GAIN * g1 - RF_GHOST_FAR_GAIN * g2) * rfSig);
        }

        vec3 yiq = rgbToYiq(vid);
        // Weak-signal AGC fade slightly lowers contrast/chroma without shifting hues.
        yiq.yz *= mix(1.0, 0.82, wash);
        yiq.x = mix(yiq.x, yiq.x * 0.88 + 0.035, wash * 0.75);

        // Modulate luma + I/Q onto the 3.58 MHz RF carrier and add RF channel noise.
        float scPhase = xPos * SUBCARRIER_RAD_PER_TEXEL + subcarrierLinePhase;
        float scCos = cos(scPhase);
        float scSin = sin(scPhase);
        float chromaDrive = mix(0.0, 1.0, clamp(rfSig, 0.0, 1.5));
        float rfCarrier = yiq.x + baseLift + chromaDrive * (yiq.y * scCos + yiq.z * scSin);

        float rfNoise = sampleRfWaveformNoise(xPos, row, rfSnow, frameSeed);
        // Slightly suppress dark negative spikes over already bright video peaks.
        rfNoise *= (rfNoise < 0.0) ? mix(1.0, 0.55, clamp(yiq.x, 0.0, 1.0)) : 1.0;

        float rfWave = rfCarrier + rfNoise;
        yAcc += rfWave * (1.0 / 6.0);
        float rxChroma = rfCarrier + rfNoise * RF_CHROMA_NOISE_PASSBAND;
        iAcc += rxChroma * scCos * (2.0 / 6.0);
        qAcc += rxChroma * scSin * (2.0 / 6.0);
    }

    // In clean mode (rfSig == 0), keep crisp RGB chroma untouched while keeping RF snow if requested.
    vec3 outYiq;
    if (rfSig <= 0.001) {
        vec3 cleanYiq = rgbToYiq(sampleVideoPixel(OrigTexture, vec2(floor(p.x + 0.5), row), imgSz, texSz));
        outYiq = vec3(yAcc, cleanYiq.y + iAcc * 0.35, cleanYiq.z + qAcc * 0.35);
    } else {
        // Temper excessive HF color aliasing slightly on pure chroma bursts while keeping natural color snow.
        outYiq = vec3(yAcc, iAcc * 0.85, qAcc * 0.85);
    }

    // Subtle analog RGB convergence offset before converting demodulated video voltage to linear light.
    vec3 outVid = clamp(yiqToRgb(outYiq), vec3(1e-6), vec3(1.08));
    vec3 lin = pow(outVid, vec3(SRC_GAMMA));

    // Apply mild gun convergence shift along crisp edges from neighboring horizontal taps.
    vec3 convShift = GUN_CONVERGENCE * 0.5;
    vec3 linL = sampleLinearPixel(OrigTexture, vec2(floor(p.x - 1.0 + 0.5), row), imgSz, texSz);
    vec3 linR = sampleLinearPixel(OrigTexture, vec2(floor(p.x + 1.0 + 0.5), row), imgSz, texSz);
    return mix(lin, vec3(linR.r, lin.g, linL.b) * 0.14 + lin * 0.86, abs(convShift.b));
}

float roundedBezelDistance(vec2 p)
{
    vec2 d = abs(p) - vec2(0.924, 0.906);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - 0.074;
}

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
    float frameSeed = mod(float(FrameCount), 4096.0);
    float phase = frameSeed / 59.94;
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

    vec3 rgb;
    if (OKUSAN_RF_STANDBY_SNOW > 0.5) {
        // Unmodulated TV RF white-noise static snow ("砂嵐") when Famicom console is powered off
        float sSeed = mod(frameSeed, 1024.0);
        float rowQ = floor(p.y);
        float colQ = floor(p.x * 1.15);
        float fineWhite = hash13(vec3(colQ, rowQ, sSeed * 4.37 + 13.1)) - 0.5;
        float medWhite = sample1DBandNoise(p.x * 0.72 + 11.7, rowQ, sSeed * 1.91 + 5.3);
        float rowJitter = (hash11(rowQ + sSeed * 7.13) - 0.5) * 0.14;
        float baseSnow = clamp(0.38 + 0.54 * fineWhite + 0.36 * medWhite + rowJitter, 0.02, 0.94);
        vec3 snowCol = vec3(baseSnow);
        vec3 scanAtten = vec3(0.84 + 0.16 * cos(fract(p.y) * 2.0 * PI));
        rgb = pow(snowCol, vec3(SRC_GAMMA)) * scanAtten;
    } else {
        float effSnow = OKUSAN_RF_SNOW + 1.45 * jAmt;
        float effSig = OKUSAN_RF_SIGNAL + 0.65 * jAmt;
        float y = floor(p.y);
        float fracY = fract(p.y);

        vec3 rowA = sampleRfScanline(p, y, effSnow, effSig, frameSeed, imgSz, texSz);
        vec3 rowB = sampleRfScanline(p, y + 1.0, effSnow, effSig, frameSeed, imgSz, texSz);
        vec3 picture = mix(rowA, rowB, fracY);
        float pixelRowsPerSrc = 1.0 / max(abs(dFdy(p.y)), 0.001);
        rgb = synthesizeScanlines(rowA, rowB, fracY, signal, fieldParity, loadExcess, pixelRowsPerSrc);

        vec2 q = floor(p + 0.5);
        vec3 previous = sampleLinearPixel(PrevTexture, q, imgSz, texSz);
        rgb += max(previous - picture, 0.0) * P22_DECAY;
        rgb = applyGlassHalation(rgb, p, loadExcess, imgSz, texSz);
    }
    float viewWidth = OutputSize.x > 1.0 ? OutputSize.x : (1.0 / max(abs(dFdx(vTexCoord.x)), 0.0001));
    rgb = applyPhosphorMask(rgb, gl_FragCoord.xy, viewWidth, imgSz.x);

    float vignette = 1.0 - 0.24 * smoothstep(0.25, 1.85, dot(face, face));
    float agcWave = 1.0 + 0.014 * OKUSAN_RF_SIGNAL * sin(p.y * 0.05 + phase * 3.1);
    vec3 light = pow(max(rgb * vignette * agcWave, vec3(1e-6)), vec3(DISPLAY_INV_GAMMA));

    float reflection = exp(-4.0 * dot(face - vec2(-0.42, -0.53), face - vec2(-0.42, -0.53)));
    vec3 color = max(light, vec3(0.0)) * aperture * raster + glass * (0.74 + 0.48 * reflection + lip);
    gl_FragColor = vec4(color, 1.0);
}

#endif
