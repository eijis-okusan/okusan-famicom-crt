#include "video/FreezeFrameGenerator.hpp"

#include <algorithm>

namespace {

uint32_t nextXorshift32(uint32_t &state) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
}

uint32_t scalePixelRgb(uint32_t pixel, float rMul, float gMul, float bMul) {
    const uint32_t r = static_cast<uint32_t>(std::clamp(((pixel >> 16) & 0xFFu) * rMul, 0.0f, 255.0f));
    const uint32_t g = static_cast<uint32_t>(std::clamp(((pixel >> 8) & 0xFFu) * gMul, 0.0f, 255.0f));
    const uint32_t b = static_cast<uint32_t>(std::clamp((pixel & 0xFFu) * bMul, 0.0f, 255.0f));
    return 0xFF000000u | (r << 16) | (g << 8) | b;
}

void buildMachineGunStutterFrame(unsigned width,
                                 unsigned height,
                                 const uint32_t *sourcePixels,
                                 std::vector<uint32_t> &outAlternate,
                                 uint32_t &rng) {
    const size_t pixelCount = static_cast<size_t>(width) * height;
    outAlternate.assign(sourcePixels, sourcePixels + pixelCount);

    const unsigned splitY = 48u + (nextXorshift32(rng) % std::max(1u, height - 96u));
    const unsigned shiftX = 2u + (nextXorshift32(rng) % 7u);
    for (unsigned y = splitY; y < height; ++y) {
        uint32_t *row = outAlternate.data() + static_cast<size_t>(y) * width;
        std::rotate(row, row + (shiftX % width), row + width);
    }
}

void applyPaletteCorruption(unsigned width,
                            unsigned height,
                            std::vector<uint32_t> &pixels,
                            uint32_t &rng) {
    const uint32_t variant = nextXorshift32(rng) % 4u;
    const unsigned splitY = 32u + (nextXorshift32(rng) % std::max(1u, height - 64u));
    const unsigned splitShift = (nextXorshift32(rng) & 1u)
        ? (4u + (nextXorshift32(rng) % 28u))
        : 0u;

    static constexpr uint32_t kBandMasks[4] = {
        0x00FF00FFu, 0x0000FFFFu, 0x00FFFF00u, 0x0033CC66u
    };

    for (unsigned y = 0; y < height; ++y) {
        uint32_t *row = pixels.data() + static_cast<size_t>(y) * width;
        if (y >= splitY && splitShift > 0) {
            std::rotate(row, row + (splitShift % width), row + width);
        }
        const unsigned band = (y >> 4) & 3u;
        for (unsigned x = 0; x < width; ++x) {
            const uint32_t px = row[x];
            if (variant == 0) {
                row[x] = scalePixelRgb(px, 1.38f, 0.36f, 0.36f); // PPU $2001 heavy Red emphasis
            } else if (variant == 1) {
                row[x] = scalePixelRgb(px, 0.36f, 0.48f, 1.42f); // PPU $2001 heavy Blue emphasis
            } else if (variant == 2) {
                const uint32_t r = (px >> 16) & 0xFFu;
                const uint32_t g = (px >> 8) & 0xFFu;
                const uint32_t b = px & 0xFFu;
                row[x] = 0xFF000000u | (g << 16) | (b << 8) | (r ^ 0xFFu);
            } else {
                row[x] = 0xFF000000u | ((px ^ kBandMasks[band]) & 0x00FFFFFFu);
            }
        }
    }
}

void applyVramGarbage(unsigned width,
                      unsigned height,
                      const uint32_t *originalPixels,
                      std::vector<uint32_t> &pixels,
                      uint32_t &rng) {
    const unsigned tileCols = width / 8u;
    const unsigned tileRows = height / 8u;
    if (tileCols == 0 || tileRows == 0) return;

    std::vector<uint32_t> tileCoords;
    tileCoords.reserve(48);
    for (unsigned t = 0; t < 48; ++t) {
        const unsigned tx = nextXorshift32(rng) % tileCols;
        const unsigned ty = nextXorshift32(rng) % tileRows;
        tileCoords.push_back(tx | (ty << 16));
    }

    // Scatter intact 8x8 tile slices across the screen as though nametable pointers corrupted.
    for (int copy = 0; copy < 76; ++copy) {
        const uint32_t packed = tileCoords[nextXorshift32(rng) % tileCoords.size()];
        const unsigned srcX = (packed & 0xFFFFu) * 8u;
        const unsigned srcY = (packed >> 16) * 8u;
        const unsigned dstX = (nextXorshift32(rng) % tileCols) * 8u;
        const unsigned dstY = (nextXorshift32(rng) % tileRows) * 8u;
        for (unsigned py = 0; py < 8; ++py) {
            for (unsigned px = 0; px < 8; ++px) {
                pixels[static_cast<size_t>(dstY + py) * width + (dstX + px)] =
                    originalPixels[static_cast<size_t>(srcY + py) * width + (srcX + px)];
            }
        }
    }

    // Overwrite 28 random tiles with stripped 2bpp diagonal garbage patterns.
    for (int blk = 0; blk < 28; ++blk) {
        const unsigned dstX = (nextXorshift32(rng) % tileCols) * 8u;
        const unsigned dstY = (nextXorshift32(rng) % tileRows) * 8u;
        const uint32_t colA = pixels[static_cast<size_t>(nextXorshift32(rng) % height) * width
                                     + (nextXorshift32(rng) % width)];
        const uint32_t colB = originalPixels[static_cast<size_t>(nextXorshift32(rng) % height) * width
                                             + (nextXorshift32(rng) % width)] ^ 0x0055AA33u;
        const uint32_t bitPattern = nextXorshift32(rng);
        for (unsigned py = 0; py < 8; ++py) {
            for (unsigned px = 0; px < 8; ++px) {
                const bool highBit = ((bitPattern >> ((py + px) & 15u)) & 1u) != 0;
                pixels[static_cast<size_t>(dstY + py) * width + (dstX + px)] =
                    0xFF000000u | ((highBit ? colB : colA) & 0x00FFFFFFu);
            }
        }
    }
}

} // namespace

void FreezeFrameGenerator::capture(FreezeStyle style,
                                   uint32_t seed,
                                   unsigned width,
                                   unsigned height,
                                   const uint32_t *currentPixels,
                                   const uint32_t *previousPixels) {
    if (!currentPixels || width == 0 || height == 0) return;

    active_ = true;
    style_ = style;
    rng_ = seed ? seed : 0xCAFEBABEu;
    tick_ = 0;
    width_ = width;
    height_ = height;

    const size_t pixelCount = static_cast<size_t>(width) * height;
    primaryFrame_.assign(currentPixels, currentPixels + pixelCount);

    if (style == FreezeStyle::MachineGunStutter) {
        const uint32_t *altSrc = previousPixels ? previousPixels : currentPixels;
        buildMachineGunStutterFrame(width, height, altSrc, alternateFrame_, rng_);
    } else if (style == FreezeStyle::PaletteCorruption) {
        applyPaletteCorruption(width, height, primaryFrame_, rng_);
    } else if (style == FreezeStyle::VramGarbage) {
        applyVramGarbage(width, height, currentPixels, primaryFrame_, rng_);
    }
}

void FreezeFrameGenerator::clear() {
    active_ = false;
    tick_ = 0;
}

bool FreezeFrameGenerator::advanceFrameAndShouldUpload() {
    if (!active_ || width_ == 0 || height_ == 0) return false;
    ++tick_;
    return (style_ == FreezeStyle::MachineGunStutter) &&
           !primaryFrame_.empty() &&
           !alternateFrame_.empty() &&
           ((tick_ % 2) == 0);
}

const uint32_t *FreezeFrameGenerator::activeDisplayPixels() const {
    if (style_ == FreezeStyle::MachineGunStutter && ((tick_ / 2) & 1) != 0 && !alternateFrame_.empty()) {
        return alternateFrame_.data();
    }
    return primaryFrame_.data();
}
