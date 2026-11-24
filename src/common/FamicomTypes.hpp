#pragma once

#include <cstdint>

/**
 * Pure C++17 domain types shared across the emulator core, DSP audio pipeline,
 * video layout math, and platform frontends without pulling in OS frameworks.
 */

/// User-configurable analog television and CRT tube display options.
struct CrtDisplayConfig {
    bool rfMode = true;        // false = RGB Monitor, true = VHF RF Television
    bool monochrome = false;   // true (when rfMode) = 1970s P4 B&W RF television
    bool interlaced = true;    // true = 480i alternating fields, false = 240p
    bool hdrEnabled = true;    // true = unlock HDR/EDR headroom + CRT ABL physics
    float hvBloom = 1.0f;      // Flyback high-voltage bloom strength (0.0 .. 2.0)
    float curvature = 1.0f;    // CRT glass barrel curvature (0.0 .. 1.5)
    float slotMask = 1.0f;     // Phosphor shadow/slot mask intensity (0.0 .. 1.5)
    float rfSnow = 1.0f;       // RF noise floor (0.0 .. 2.0)
    float rfSignal = 1.0f;     // RF interference / chroma artifact level (0.0 .. 2.0)

    /// Returns a flat-screen RGB monitor preset while preserving interlace/HDR preferences.
    static CrtDisplayConfig rgbFlatPreset(const CrtDisplayConfig &base) {
        CrtDisplayConfig next = base;
        next.rfMode = false;
        next.monochrome = false;
        next.curvature = 0.0f;
        return next;
    }

    /// Returns a curved consumer Color RF TV preset with standard snow & interference enabled.
    static CrtDisplayConfig rfCurvedNoisePreset(const CrtDisplayConfig &base) {
        CrtDisplayConfig next = base;
        next.rfMode = true;
        next.monochrome = false;
        next.curvature = 1.0f;
        next.hvBloom = 1.0f;
        next.slotMask = 1.0f;
        next.rfSnow = 1.0f;
        next.rfSignal = 1.0f;
        return next;
    }
};

/// Presentation modes for Famicom 3D System ($4016 OUT1 shutter) titles.
enum class Famicom3dViewMode : int {
    NakedCrt       = 0, // Normal 60 Hz unshuttered CRT (default)
    ShutterGlasses = 1, // HVC-031 TN-LCD 30 Hz shutter simulation
    ParallelSbs    = 2, // Side-by-side parallel stereo (L | R)
    CrossSbs       = 3  // Cross-eyed side-by-side stereo (R | L)
};

/// Deterministic hardware crash profiles shared between FreezeFrameGenerator and AudioPipeline.
enum class FreezeStyle : int {
    CleanTone = 0,
    MachineGunStutter,
    PaletteCorruption,
    VramGarbage,
    Count
};

/// Standard Famicom / NES Player 1 controller button order (matches libretro RETRO_DEVICE_ID_JOYPAD_*).
enum FamicomButton : int {
    FC_BTN_UP = 0,
    FC_BTN_DOWN,
    FC_BTN_LEFT,
    FC_BTN_RIGHT,
    FC_BTN_B,
    FC_BTN_A,
    FC_BTN_SELECT,
    FC_BTN_START,
    FC_BTN_COUNT
};

inline constexpr uint16_t kUnboundKeyCode = 0xFFFFu;

/// Platform-neutral slot holding up to three virtual key codes bound to one Famicom button.
struct KeyBindingGroup {
    uint16_t primary = kUnboundKeyCode;
    uint16_t alt1 = kUnboundKeyCode;
    uint16_t alt2 = kUnboundKeyCode;
};

/// Integer viewport bounds in backing-store pixels.
struct CrtViewportRect {
    int x = 0;
    int y = 0;
    int w = 0;
    int h = 0;
};
