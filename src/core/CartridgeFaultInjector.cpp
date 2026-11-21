#include "core/CartridgeFaultInjector.hpp"
#include "core/FamicomCore.hpp"

#include <algorithm>

namespace {

constexpr int kPinsPerFace = 30;
constexpr int kTotalPins = 60;
constexpr int kMaxProbeAttempts = 8;
constexpr int kProbeFrameCount = 46;

int randRange(std::mt19937 &rng, int minInclusive, int maxInclusive) {
    std::uniform_int_distribution<int> dist(minInclusive, maxInclusive);
    return dist(rng);
}

/**
 * Returns true if pin index `p` carries core 6502 instruction/address/control traffic
 * whose simultaneous hard failure prevents reset-vector execution altogether.
 * (Indices match 0-based hardware order: Front 0..29, Back 30..59.)
 */
bool isCpuCriticalPin(int p) {
    // Front CPU A11..A0 (1..12), R/W (13); Back M2 (31), CPU A12..D0 (32..42), /ROMSEL (43).
    return (p >= 1 && p <= 13) || (p >= 31 && p <= 43);
}

/**
 * Quick luma/chroma variety check used during cold-boot probing so we accept screens
 * with visible text, sprites, or jailbars rather than completely blank frames.
 */
bool frameHasVisibleDetail(const uint32_t *pixels, unsigned width, unsigned height) {
    if (!pixels || width == 0 || height == 0) return false;

    uint32_t distinctColors[4] = {};
    int uniqueCount = 0;
    int brightSamples = 0;
    const size_t total = static_cast<size_t>(width) * height;

    // Sample every 67th pixel (~1,000 pixels on 256x240) to inspect quickly without allocating.
    for (size_t i = 0; i < total; i += 67) {
        const uint32_t rgb = pixels[i] & 0x00FFFFFFu;
        const uint32_t sum = ((rgb >> 16) & 0xFFu) + ((rgb >> 8) & 0xFFu) + (rgb & 0xFFu);
        if (sum >= 110u) ++brightSamples;

        bool seen = false;
        for (int k = 0; k < uniqueCount; ++k) {
            if (distinctColors[k] == rgb) {
                seen = true;
                break;
            }
        }
        if (!seen && uniqueCount < 4) {
            distinctColors[uniqueCount++] = rgb;
        }
        if (brightSamples >= 18 && uniqueCount >= 3) return true;
    }
    return false;
}

/**
 * Real dual power pins (GND1/GND2 and +5V L/R) rarely both go completely open at once
 * unless the cartridge is physically unseated; keep at least one rail at WEAK resistance
 * so brownout/bounce effects can still trigger cleanly.
 */
void preventDualRailOpenBlackout(uint64_t &weakMask, uint64_t &openMask, std::mt19937 &rng) {
    constexpr uint64_t kBothGnd = (1ULL << 0) | (1ULL << 15);
    constexpr uint64_t kBothVcc = (1ULL << 29) | (1ULL << 30);

    if ((openMask & kBothGnd) == kBothGnd) {
        const int keepWeak = randRange(rng, 0, 1) == 0 ? 15 : 0;
        openMask &= ~(1ULL << keepWeak);
        weakMask |= (1ULL << keepWeak);
    }
    if ((openMask & kBothVcc) == kBothVcc) {
        const int keepWeak = randRange(rng, 0, 1) == 0 ? 30 : 29;
        openMask &= ~(1ULL << keepWeak);
        weakMask |= (1ULL << keepWeak);
    }
}

void markFaultedPin(CartridgeFaultPlan &plan,
                    int pinIndex,
                    int openChancePct,
                    int attempt,
                    int &cpuFaultCount,
                    std::mt19937 &rng) {
    if (pinIndex < 0 || pinIndex >= kTotalPins) return;

    if (isCpuCriticalPin(pinIndex)) {
        // After repeated unbootable probes, dial back CPU-bus open probability gently.
        const int maxCpuFaults = (attempt >= 4) ? 2 : 4;
        if (cpuFaultCount >= maxCpuFaults) return;
        ++cpuFaultCount;
    }

    int effectiveOpenPct = isCpuCriticalPin(pinIndex) ? std::min(22, openChancePct / 3) : openChancePct;
    if (attempt >= 2 && isCpuCriticalPin(pinIndex)) effectiveOpenPct = 0;

    if (randRange(rng, 0, 99) < effectiveOpenPct) {
        plan.openMask |= (1ULL << pinIndex);
        plan.weakMask &= ~(1ULL << pinIndex);
    } else if (((plan.openMask >> pinIndex) & 1ULL) == 0ULL) {
        plan.weakMask |= (1ULL << pinIndex);
    }
}

void markAdjacentCluster(CartridgeFaultPlan &plan,
                         int startPos,
                         int faceOffset,
                         int length,
                         int openChancePct,
                         int attempt,
                         int &cpuFaultCount,
                         std::mt19937 &rng) {
    for (int offset = 0; offset < length; ++offset) {
        const int pos = startPos + offset;
        if (pos >= kPinsPerFace) break;
        markFaultedPin(plan, faceOffset + pos, openChancePct, attempt, cpuFaultCount, rng);
    }
}

std::mt19937 &sharedRng() {
    static std::mt19937 rng{std::random_device{}()};
    return rng;
}

} // namespace

CartridgeFaultPlan generateRandomContactFault(int attempt, std::mt19937 &rng) {
    CartridgeFaultPlan plan;

    // Mix optional physical 3-DOF seating skew (~40% chance) with direct oxidized/dirty pin spots.
    if (randRange(rng, 0, 4) < 2) {
        const int dir = randRange(rng, 0, 3);
        if (dir == 1) {
            plan.tilt = -randRange(rng, 4, 10);
        } else if (dir >= 2) {
            plan.tilt = randRange(rng, 4, 14);
        }
        plan.lift = randRange(rng, 0, 2);
        plan.pitch = randRange(rng, -2, 2);
    }

    const int spotCount = randRange(rng, 1, 3);
    const int openChancePct = randRange(rng, 25, 89);
    int cpuFaultCount = 0;

    for (int spot = 0; spot < spotCount; ++spot) {
        const int pos = randRange(rng, 0, kPinsPerFace - 1);
        const int faceOffset = (randRange(rng, 0, 1) == 0) ? 0 : kPinsPerFace;
        const int shapeRoll = randRange(rng, 0, 9);

        if (shapeRoll < 4) {
            // Single oxidized pin or dust speck
            markFaultedPin(plan, faceOffset + pos, openChancePct, attempt, cpuFaultCount, rng);
        } else if (shapeRoll < 8) {
            // Contiguous 2..4 pin smudge/corrosion cluster
            const int length = randRange(rng, 2, 4);
            markAdjacentCluster(plan, pos, faceOffset, length, openChancePct, attempt, cpuFaultCount, rng);
        } else {
            // Matched front + back contact spot at the same longitudinal slot position
            markFaultedPin(plan, pos, openChancePct, attempt, cpuFaultCount, rng);
            markFaultedPin(plan, kPinsPerFace + pos, openChancePct, attempt, cpuFaultCount, rng);
        }
    }

    if ((plan.weakMask | plan.openMask) == 0ULL) {
        plan.weakMask |= (1ULL << randRange(rng, 0, kTotalPins - 1));
    }

    preventDualRailOpenBlackout(plan.weakMask, plan.openMask, rng);
    return plan;
}

bool probeFaultBootViability(FamicomCore &core, const CartridgeFaultPlan &plan) {
    core.setPinFaultMasks(plan.weakMask, plan.openMask);
    core.setCartridgePose(plan.tilt, plan.lift, plan.pitch);
    if (!core.isCartridgePowered()) return false;

    // Ensure at least one pin is genuinely degraded (e.g., if tilt/lift alone stayed seated).
    CartPinReading readings[kTotalPins];
    int tilt = 0, lift = 0, pitch = 0;
    bool hasDegradedPin = false;
    if (core.readPinTelemetry(tilt, lift, pitch, readings, kTotalPins)) {
        for (int i = 0; i < kTotalPins; ++i) {
            if ((readings[i].contactState & 0x0Fu) != 0u) {
                hasDegradedPin = true;
                break;
            }
        }
    }
    if (!hasDegradedPin) return false;

    core.reset();
    for (int frame = 0; frame < kProbeFrameCount; ++frame) {
        core.runFrame(0, nullptr);
        if (!core.isCartridgePowered()) return false;

        // Sampling every 6 frames after boot init keeps probe latency negligible on UI click/key.
        if (frame >= 14 && (((frame - 14) % 6) == 0 || frame == kProbeFrameCount - 1)) {
            if (frameHasVisibleDetail(core.currentPixels(), core.width(), core.height())) {
                return true;
            }
        }
        if (core.isCpuJammed()) {
            // Accept genuine mid-boot CPU hangs if something already rendered before halting.
            return frameHasVisibleDetail(core.currentPixels(), core.width(), core.height());
        }
    }
    return false;
}

CartridgeFaultPlan selectViableRandomFaultBoot(FamicomCore &core) {
    std::mt19937 &rng = sharedRng();
    CartridgeFaultPlan fallback;

    for (int attempt = 0; attempt < kMaxProbeAttempts; ++attempt) {
        CartridgeFaultPlan candidate = generateRandomContactFault(attempt, rng);
        if (attempt == 0) fallback = candidate;
        if (probeFaultBootViability(core, candidate)) {
            return candidate;
        }
    }

    // Guaranteed-visible PPU/CIRAM fallback if every random attempt stalled before PPU init.
    fallback.tilt = randRange(rng, 4, 9);
    fallback.weakMask = (1ULL << 17) | (1ULL << 44) | (1ULL << 47);
    fallback.openMask = (1ULL << randRange(rng, 19, 26));
    return fallback;
}
