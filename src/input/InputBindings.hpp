#pragma once

#import <Foundation/Foundation.h>
#include <array>
#include <cstdint>

#include "common/FamicomTypes.hpp"

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
