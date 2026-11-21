#pragma once

#import <Foundation/Foundation.h>
#include <array>
#include <cstdint>

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

struct KeyBindingGroup {
    uint16_t primary = kUnboundKeyCode;
    uint16_t alt1 = kUnboundKeyCode;
    uint16_t alt2 = kUnboundKeyCode;
};

/**
 * Keyboard & gamepad binding configuration for Player 1, persisted in NSUserDefaults.
 */
struct InputBindings {
    std::array<KeyBindingGroup, FC_BTN_COUNT> keys;
    bool swapGamepadAB = false;
    bool useLeftStick = true;
    bool allowGamepadSaveLoad = true;

    InputBindings();
    static InputBindings defaults();

    void loadFromDefaults();
    void saveToDefaults() const;
};

NSString *keyLabelForVirtualCode(uint16_t keyCode);
