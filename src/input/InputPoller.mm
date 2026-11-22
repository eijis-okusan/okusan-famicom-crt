#import "input/InputPoller.hpp"

#import <Carbon/Carbon.h>
#import <GameController/GameController.h>
#include <algorithm>

namespace famicom_input {

namespace {

enum RetroJoypadBit : unsigned {
    JOYPAD_B      = 0,
    JOYPAD_SELECT = 2,
    JOYPAD_START  = 3,
    JOYPAD_UP     = 4,
    JOYPAD_DOWN   = 5,
    JOYPAD_LEFT   = 6,
    JOYPAD_RIGHT  = 7,
    JOYPAD_A      = 8,
};

bool isBindingDown(const KeyBindingGroup &group, const std::array<bool, 256> &pressedKeys) {
    return (group.primary < pressedKeys.size() && pressedKeys[group.primary]) ||
           (group.alt1    < pressedKeys.size() && pressedKeys[group.alt1])    ||
           (group.alt2    < pressedKeys.size() && pressedKeys[group.alt2]);
}

bool isPinHudToggleKey(NSEvent *event, NSString *charsIgn) {
    return [charsIgn isEqualToString:@"\\"] ||
           [charsIgn isEqualToString:@"¥"] ||
           (event.keyCode == kVK_ANSI_Backslash && ![charsIgn isEqualToString:@"]"]);
}

} // namespace

PollResult sampleControllerInput(const InputBindings &bindings,
                                 const std::array<bool, 256> &pressedKeys,
                                 GamepadHotkeyState &hotkeys) {
    PollResult result;

    static constexpr struct {
        FamicomButton button;
        unsigned bit;
    } kKeyMap[] = {
        {FC_BTN_UP,     JOYPAD_UP},
        {FC_BTN_DOWN,   JOYPAD_DOWN},
        {FC_BTN_LEFT,   JOYPAD_LEFT},
        {FC_BTN_RIGHT,  JOYPAD_RIGHT},
        {FC_BTN_B,      JOYPAD_B},
        {FC_BTN_A,      JOYPAD_A},
        {FC_BTN_SELECT, JOYPAD_SELECT},
        {FC_BTN_START,  JOYPAD_START},
    };
    for (const auto &entry : kKeyMap) {
        if (isBindingDown(bindings.keys[entry.button], pressedKeys)) {
            result.padMask |= (1u << entry.bit);
        }
    }

    bool l2Held = false;
    bool r2Held = false;
    bool selectHeld = false;
    for (GCController *controller in [GCController controllers]) {
        GCExtendedGamepad *pad = controller.extendedGamepad;
        if (!pad) continue;

        const bool optionsDown = ([pad respondsToSelector:@selector(buttonOptions)] &&
                                  pad.buttonOptions && pad.buttonOptions.pressed);
        const bool stickUp    = bindings.useLeftStick && (pad.leftThumbstick.yAxis.value > 0.35f);
        const bool stickDown  = bindings.useLeftStick && (pad.leftThumbstick.yAxis.value < -0.35f);
        const bool stickLeft  = bindings.useLeftStick && (pad.leftThumbstick.xAxis.value < -0.35f);
        const bool stickRight = bindings.useLeftStick && (pad.leftThumbstick.xAxis.value > 0.35f);

        const bool faceB = pad.buttonB.pressed || pad.buttonX.pressed;
        const bool faceA = pad.buttonA.pressed || pad.buttonY.pressed;
        const bool nesB = bindings.swapGamepadAB ? faceA : faceB;
        const bool nesA = bindings.swapGamepadAB ? faceB : faceA;

        if (pad.dpad.up.pressed || stickUp)          result.padMask |= (1u << JOYPAD_UP);
        if (pad.dpad.down.pressed || stickDown)      result.padMask |= (1u << JOYPAD_DOWN);
        if (pad.dpad.left.pressed || stickLeft)      result.padMask |= (1u << JOYPAD_LEFT);
        if (pad.dpad.right.pressed || stickRight)    result.padMask |= (1u << JOYPAD_RIGHT);
        if (nesB)                                    result.padMask |= (1u << JOYPAD_B);
        if (nesA)                                    result.padMask |= (1u << JOYPAD_A);
        if (pad.buttonMenu.pressed)                  result.padMask |= (1u << JOYPAD_START);
        if (optionsDown || pad.leftShoulder.pressed) result.padMask |= (1u << JOYPAD_SELECT);

        if (bindings.allowGamepadSaveLoad) {
            l2Held = l2Held || (pad.leftTrigger.value > 0.65f);
            r2Held = r2Held || (pad.rightTrigger.value > 0.65f);
            selectHeld = selectHeld || optionsDown || pad.leftShoulder.pressed;
        }
    }

    result.quickSaveTriggered = (l2Held && !hotkeys.prevL2);
    result.quickLoadTriggered = (r2Held && !hotkeys.prevR2 && selectHeld);
    hotkeys.prevL2 = l2Held;
    hotkeys.prevR2 = r2Held;
    return result;
}

bool isContactFaultBootShortcut(NSEvent *event) {
    NSString *chars = event.characters ?: @"";
    NSString *charsIgn = event.charactersIgnoringModifiers ?: @"";
    return [chars isEqualToString:@"@"] || [charsIgn isEqualToString:@"@"];
}

bool isCartridgeContactShortcut(NSEvent *event) {
    NSString *charsIgn = event.charactersIgnoringModifiers ?: @"";
    return event.keyCode == kVK_ANSI_Comma ||
           event.keyCode == kVK_ANSI_Period ||
           event.keyCode == kVK_ANSI_Slash ||
           [charsIgn isEqualToString:@"["] ||
           [charsIgn isEqualToString:@"]"] ||
           isPinHudToggleKey(event, charsIgn);
}

CartridgeContactAction applyCartridgeContactKeyEvent(NSEvent *event,
                                                     int &tilt,
                                                     int &lift,
                                                     int &pitch) {
    NSString *charsIgn = event.charactersIgnoringModifiers ?: @"";
    if (isPinHudToggleKey(event, charsIgn)) {
        return event.isARepeat ? CartridgeContactAction::None : CartridgeContactAction::TogglePinHud;
    }
    if (event.keyCode == kVK_ANSI_Slash) {
        if (event.isARepeat) return CartridgeContactAction::None;
        tilt = 0;
        lift = 0;
        pitch = 0;
        return CartridgeContactAction::Reseat;
    }

    const int prevTilt = tilt;
    const int prevLift = lift;
    const int prevPitch = pitch;
    const BOOL shiftDown = (event.modifierFlags & NSEventModifierFlagShift) != 0;

    if ([charsIgn isEqualToString:@"["]) {
        pitch = std::max(-8, pitch - 1);
    } else if ([charsIgn isEqualToString:@"]"]) {
        pitch = std::min(8, pitch + 1);
    } else if (event.keyCode == kVK_ANSI_Comma) {
        if (shiftDown) lift = std::min(16, lift + 1);
        else           tilt = std::max(-32, tilt - 1);
    } else if (shiftDown) {
        if (lift > 0)      lift = std::max(0, lift - 1);
        else if (tilt < 0) tilt += 1;
        else if (tilt > 0) tilt -= 1;
    } else {
        tilt = std::min(32, tilt + 1);
    }

    return (tilt != prevTilt || lift != prevLift || pitch != prevPitch)
               ? CartridgeContactAction::PoseChanged
               : CartridgeContactAction::Unchanged;
}

} // namespace famicom_input
