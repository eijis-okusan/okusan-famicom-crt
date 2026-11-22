#pragma once

#include <cstdint>
#include <vector>
#include "audio/MacAudioEngine.hpp"

/**
 * Generates deterministic, hardware-authentic NES crash screens for the
 * "Freeze Famicom (F)" feature without touching the emulator's live state.
 *
 * Pure C++17 (no Cocoa/OpenGL dependencies) so the same crash visuals can be
 * shared across macOS and future desktop frontends.
 */
class FreezeFrameGenerator {
public:
    void capture(FreezeStyle style,
                 uint32_t seed,
                 unsigned width,
                 unsigned height,
                 const uint32_t *currentPixels,
                 const uint32_t *previousPixels);

    void clear();
    bool advanceFrameAndShouldUpload();

    bool active() const { return active_; }
    unsigned width() const { return width_; }
    unsigned height() const { return height_; }
    const uint32_t *primaryPixels() const { return primaryFrame_.data(); }
    const uint32_t *activeDisplayPixels() const;

private:
    bool active_ = false;
    FreezeStyle style_ = FreezeStyle::CleanTone;
    uint32_t rng_ = 0xCAFEBABEu;
    int tick_ = 0;
    unsigned width_ = 0;
    unsigned height_ = 0;
    std::vector<uint32_t> primaryFrame_;
    std::vector<uint32_t> alternateFrame_;
};
