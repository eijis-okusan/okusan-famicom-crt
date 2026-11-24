#pragma once

#include "common/FamicomTypes.hpp"

/**
 * Pure C++17 CRT viewport geometry and RF modulator warmup/standby envelope math.
 * Shared across Metal and future Vulkan/Direct3D/OpenGL rendering backends.
 */
namespace crt_layout {

/// Returns the largest 4:3 CRT tube viewport centered inside `(backingW, backingH)`.
CrtViewportRect computeFitted4x3Viewport(int backingW, int backingH);

/// Computes left and right eye viewports for parallel (65mm IPD cap) or cross-eyed 3D SBS viewing.
void computeSbsStereoViewports(int backingW,
                               int backingH,
                               float backingScale,
                               bool isParallel,
                               CrtViewportRect &outLeft,
                               CrtViewportRect &outRight);

/// Computes RF tuner static snow (`0..1`) and sync flutter/jitter (`0..1`) from power switch and bump state.
void computeRfStandbyAndJitter(bool consolePowered,
                               bool cartPowered,
                               double powerAgeSec,
                               double transientAgeSec,
                               float transientPeak,
                               float transientDecay,
                               float &outStandbySnow,
                               float &outPowerJitter);

} // namespace crt_layout
