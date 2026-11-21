#import "InputBindings.hpp"
#import <Carbon/Carbon.h>

namespace {

const char *const kPrefButtonNames[FC_BTN_COUNT] = {
    "up", "down", "left", "right", "b", "a", "select", "start"
};

} // namespace

InputBindings::InputBindings() {
    keys[FC_BTN_UP]     = {kVK_UpArrow,    kVK_ANSI_W,     kUnboundKeyCode};
    keys[FC_BTN_DOWN]   = {kVK_DownArrow,  kVK_ANSI_S,     kUnboundKeyCode};
    keys[FC_BTN_LEFT]   = {kVK_LeftArrow,  kVK_ANSI_A,     kUnboundKeyCode};
    keys[FC_BTN_RIGHT]  = {kVK_RightArrow, kVK_ANSI_D,     kUnboundKeyCode};
    keys[FC_BTN_B]      = {kVK_ANSI_X,     kVK_ANSI_J,     kUnboundKeyCode};
    keys[FC_BTN_A]      = {kVK_ANSI_Z,     kVK_ANSI_K,     kVK_Space};
    keys[FC_BTN_SELECT] = {kVK_Tab,        kVK_RightShift, kUnboundKeyCode};
    keys[FC_BTN_START]  = {kVK_Return,     kUnboundKeyCode, kUnboundKeyCode};
    swapGamepadAB = false;
    useLeftStick = true;
    allowGamepadSaveLoad = true;
}

InputBindings InputBindings::defaults() {
    return InputBindings();
}

void InputBindings::loadFromDefaults() {
    *this = InputBindings::defaults();
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (int i = 0; i < FC_BTN_COUNT; ++i) {
        NSString *pref1 = [NSString stringWithFormat:@"ctrl.key1.%s", kPrefButtonNames[i]];
        NSString *pref2 = [NSString stringWithFormat:@"ctrl.key2.%s", kPrefButtonNames[i]];
        NSString *pref3 = [NSString stringWithFormat:@"ctrl.key3.%s", kPrefButtonNames[i]];
        if ([defaults objectForKey:pref1]) keys[i].primary = (uint16_t)[defaults integerForKey:pref1];
        if ([defaults objectForKey:pref2]) keys[i].alt1    = (uint16_t)[defaults integerForKey:pref2];
        if ([defaults objectForKey:pref3]) keys[i].alt2    = (uint16_t)[defaults integerForKey:pref3];
    }
    if ([defaults objectForKey:@"ctrl.swapGamepadAB"]) {
        swapGamepadAB = [defaults boolForKey:@"ctrl.swapGamepadAB"];
    }
    if ([defaults objectForKey:@"ctrl.useLeftStick"]) {
        useLeftStick = [defaults boolForKey:@"ctrl.useLeftStick"];
    }
    if ([defaults objectForKey:@"ctrl.allowGamepadSaveLoad"]) {
        allowGamepadSaveLoad = [defaults boolForKey:@"ctrl.allowGamepadSaveLoad"];
    }
}

void InputBindings::saveToDefaults() const {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (int i = 0; i < FC_BTN_COUNT; ++i) {
        [defaults setInteger:keys[i].primary forKey:[NSString stringWithFormat:@"ctrl.key1.%s", kPrefButtonNames[i]]];
        [defaults setInteger:keys[i].alt1    forKey:[NSString stringWithFormat:@"ctrl.key2.%s", kPrefButtonNames[i]]];
        [defaults setInteger:keys[i].alt2    forKey:[NSString stringWithFormat:@"ctrl.key3.%s", kPrefButtonNames[i]]];
    }
    [defaults setBool:swapGamepadAB forKey:@"ctrl.swapGamepadAB"];
    [defaults setBool:useLeftStick forKey:@"ctrl.useLeftStick"];
    [defaults setBool:allowGamepadSaveLoad forKey:@"ctrl.allowGamepadSaveLoad"];
}

NSString *keyLabelForVirtualCode(uint16_t keyCode) {
    switch (keyCode) {
    case kUnboundKeyCode:    return @"--";
    case kVK_UpArrow:        return @"↑";
    case kVK_DownArrow:      return @"↓";
    case kVK_LeftArrow:      return @"←";
    case kVK_RightArrow:     return @"→";
    case kVK_Return:         return @"Return";
    case kVK_Tab:            return @"Tab";
    case kVK_Space:          return @"Space";
    case kVK_Delete:         return @"Delete";
    case kVK_RightShift:     return @"RShift";
    case kVK_Shift:          return @"LShift";
    case kVK_ANSI_A:         return @"A";
    case kVK_ANSI_B:         return @"B";
    case kVK_ANSI_C:         return @"C";
    case kVK_ANSI_D:         return @"D";
    case kVK_ANSI_E:         return @"E";
    case kVK_ANSI_F:         return @"F";
    case kVK_ANSI_G:         return @"G";
    case kVK_ANSI_H:         return @"H";
    case kVK_ANSI_I:         return @"I";
    case kVK_ANSI_J:         return @"J";
    case kVK_ANSI_K:         return @"K";
    case kVK_ANSI_L:         return @"L";
    case kVK_ANSI_M:         return @"M";
    case kVK_ANSI_N:         return @"N";
    case kVK_ANSI_O:         return @"O";
    case kVK_ANSI_P:         return @"P";
    case kVK_ANSI_Q:         return @"Q";
    case kVK_ANSI_R:         return @"R";
    case kVK_ANSI_S:         return @"S";
    case kVK_ANSI_T:         return @"T";
    case kVK_ANSI_U:         return @"U";
    case kVK_ANSI_V:         return @"V";
    case kVK_ANSI_W:         return @"W";
    case kVK_ANSI_X:         return @"X";
    case kVK_ANSI_Y:         return @"Y";
    case kVK_ANSI_Z:         return @"Z";
    case kVK_ANSI_0:         return @"0";
    case kVK_ANSI_1:         return @"1";
    case kVK_ANSI_2:         return @"2";
    case kVK_ANSI_3:         return @"3";
    case kVK_ANSI_4:         return @"4";
    case kVK_ANSI_5:         return @"5";
    case kVK_ANSI_6:         return @"6";
    case kVK_ANSI_7:         return @"7";
    case kVK_ANSI_8:         return @"8";
    case kVK_ANSI_9:         return @"9";
    case kVK_ANSI_Semicolon: return @";";
    case kVK_ANSI_Quote:     return @"'";
    case kVK_ANSI_Minus:     return @"-";
    case kVK_ANSI_Equal:     return @"=";
    default:
        return [NSString stringWithFormat:@"Key#%u", keyCode];
    }
}
