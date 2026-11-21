#pragma once

#include <cstdint>
#include <random>

class FamicomCore;

/**
 * A combined 3-DOF physical pose and explicit per-pin electrical fault mask
 * representing a single cold-boot cartridge contact state on the HVC-001 slot.
 */
struct CartridgeFaultPlan {
    int tilt = 0;            // Lateral rock (-32..+32; negative lifts PRG, positive lifts PPU)
    int lift = 0;            // Vertical pull-up (0..16)
    int pitch = 0;           // Front/back rock (-8..+8)
    uint64_t weakMask = 0;   // Bitmask (bits 0..59) forcing high-resistance WEAK contact
    uint64_t openMask = 0;   // Bitmask (bits 0..59) forcing disconnected OPEN contact
};

/**
 * Generates an organic random contact-fault pattern spanning all 60 cartridge pins
 * (0..29 Front, 30..59 Back), freely mixing single oxidized pins, 2..4 adjacent
 * pin clusters, opposing slot pairs, and optional 3-DOF seating skew.
 */
CartridgeFaultPlan generateRandomContactFault(int attempt, std::mt19937 &rng);

/**
 * Tests whether a candidate fault plan powers the cartridge, faults at least one pin,
 * and produces visible video detail within the first 46 frames instead of dying
 * silently on frame 0 (while still allowing genuine mid-boot crashes).
 */
bool probeFaultBootViability(FamicomCore &core, const CartridgeFaultPlan &plan);

/**
 * Picks a randomized contact-fault boot configuration verified to produce visible
 * hardware glitching rather than an immediate unrecoverable black screen.
 */
CartridgeFaultPlan selectViableRandomFaultBoot(FamicomCore &core);
