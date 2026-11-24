#include "video/CrtLayoutMath.hpp"

#include <algorithm>
#include <cmath>

namespace crt_layout {

CrtViewportRect computeFitted4x3Viewport(int backingW, int backingH) {
    constexpr double kTargetAspect = 4.0 / 3.0;
    const double viewAspect = (backingH > 0)
        ? (static_cast<double>(backingW) / static_cast<double>(backingH))
        : kTargetAspect;

    CrtViewportRect vp{0, 0, backingW, backingH};
    if (viewAspect > kTargetAspect) {
        vp.w = static_cast<int>(backingH * kTargetAspect + 0.5);
        vp.x = (backingW - vp.w) / 2;
    } else if (viewAspect < kTargetAspect) {
        vp.h = static_cast<int>(backingW / kTargetAspect + 0.5);
        vp.y = (backingH - vp.h) / 2;
    }
    return vp;
}

void computeSbsStereoViewports(int backingW,
                               int backingH,
                               float backingScale,
                               bool isParallel,
                               CrtViewportRect &outLeft,
                               CrtViewportRect &outRight) {
    const double scale = static_cast<double>(std::max(1.0f, backingScale));
    const double gap = 22.0 * scale;
    const double marginX = 24.0 * scale;
    const double marginY = 20.0 * scale;

    double maxPairW = std::max(120.0, static_cast<double>(backingW) - marginX * 2.0);
    if (isParallel) {
        // Limit side-by-side stereo width so naked-eye parallel fusion stays within ~65 mm IPD.
        maxPairW = std::min(maxPairW, 640.0 * scale);
    }
    const double maxPairH = std::max(90.0, static_cast<double>(backingH) - marginY * 2.0);

    double eyeW = (maxPairW - gap) * 0.5;
    double eyeH = eyeW * (3.0 / 4.0);
    if (eyeH > maxPairH) {
        eyeH = maxPairH;
        eyeW = eyeH * (4.0 / 3.0);
    }

    const double totalW = eyeW * 2.0 + gap;
    const double startX = (static_cast<double>(backingW) - totalW) * 0.5;
    const double startY = (static_cast<double>(backingH) - eyeH) * 0.5;

    outLeft = {
        static_cast<int>(std::llround(startX)),
        static_cast<int>(std::llround(startY)),
        static_cast<int>(std::llround(eyeW)),
        static_cast<int>(std::llround(eyeH)),
    };
    outRight = {
        static_cast<int>(std::llround(startX + eyeW + gap)),
        static_cast<int>(std::llround(startY)),
        static_cast<int>(std::llround(eyeW)),
        static_cast<int>(std::llround(eyeH)),
    };
}

void computeRfStandbyAndJitter(bool consolePowered,
                               bool cartPowered,
                               double powerAgeSec,
                               double transientAgeSec,
                               float transientPeak,
                               float transientDecay,
                               float &outStandbySnow,
                               float &outPowerJitter) {
    float standbySnow = 0.0f;
    float powerJitter = 0.0f;

    if (!consolePowered) {
        if (powerAgeSec < 0.085) {
            powerJitter = 1.0f - static_cast<float>(powerAgeSec / 0.085);
        } else {
            standbySnow = 1.0f;
        }
    } else if (!cartPowered) {
        // Browned-out or disconnected cartridge power cuts the video modulator carrier.
        standbySnow = 1.0f;
    } else {
        if (powerAgeSec < 0.16) {
            powerJitter = std::exp(-static_cast<float>(powerAgeSec) * 16.0f);
        }
        if (transientPeak > 0.0f && transientAgeSec >= 0.0 && transientAgeSec < 0.14) {
            powerJitter = std::max(powerJitter,
                                   transientPeak * std::exp(-static_cast<float>(transientAgeSec) * transientDecay));
        }
    }

    outStandbySnow = standbySnow;
    outPowerJitter = powerJitter;
}

} // namespace crt_layout
