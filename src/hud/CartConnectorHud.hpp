#pragma once

#import <CoreGraphics/CoreGraphics.h>
#include <cstdint>
#include <vector>

class FamicomCore;

namespace cart_hud {

inline constexpr int kHudBitmapWidth = 1280;
inline constexpr int kHudBitmapHeight = 740;
inline constexpr int kHudLogicalWidth = kHudBitmapWidth / 2;
inline constexpr int kHudLogicalHeight = kHudBitmapHeight / 2;

/**
 * Renders the 1:1 mm HVC-001 60-pin connector cross-section, pin matrix,
 * and live bus inspector into rgbaPixels (kHudBitmapWidth x kHudBitmapHeight x 4).
 */
bool renderConnectorHud(const FamicomCore *core,
                        int selectedPin,
                        bool pinned,
                        std::vector<uint8_t> &rgbaPixels);

/**
 * Returns 0..59 if backingPoint falls inside one of the 60 pin tiles inside hudRect,
 * or -1 otherwise.
 */
int hitTestConnectorPin(CGPoint backingPoint, CGRect hudRect);

} // namespace cart_hud
