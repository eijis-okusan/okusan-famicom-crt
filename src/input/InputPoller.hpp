#pragma once

#import <Cocoa/Cocoa.h>
#include <array>
#include <cstdint>

#include "input/InputBindings.hpp"

namespace famicom_input {

struct GamepadHotkeyState {
    bool prevL2 = false;
    bool prevR2 = false;
};

struct PollResult {
    uint32_t padMask = 0;
    bool quickSaveTriggered = false;
    bool quickLoadTriggered = false;
};

/**
 * Samples keyboard bindings and connected GCController gamepads into a NES joypad bitmask
 * along with rising-edge L2 / SELECT+R2 save-state triggers.
 */
PollResult sampleControllerInput(const InputBindings &bindings,
                                 const std::array<bool, 256> &pressedKeys,
                                 GamepadHotkeyState &hotkeys);

bool isContactFaultBootShortcut(NSEvent *event);
bool isCartridgeContactShortcut(NSEvent *event);

enum class CartridgeContactAction {
    None = 0,
    TogglePinHud,
    Reseat,
    PoseChanged,
    Unchanged
};

/**
 * Applies a cartridge-connector keyboard shortcut (tilt/lift/pitch/reseat/pin-HUD)
 * using ANSI/JIS-compatible character & keyCode matching.
 */
CartridgeContactAction applyCartridgeContactKeyEvent(NSEvent *event,
                                                     int &tilt,
                                                     int &lift,
                                                     int &pitch);

} // namespace famicom_input
