#import "AppLocalization.hpp"

namespace app_l10n {
namespace {

NSString *const kLanguagePrefKey = @"uiLanguage";

} // namespace

AppLanguageMode loadLanguageMode() {
    NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:kLanguagePrefKey];
    if ([stored isEqualToString:@"ja"]) return AppLanguageMode::Japanese;
    if ([stored isEqualToString:@"en"]) return AppLanguageMode::English;
    return AppLanguageMode::System;
}

void saveLanguageMode(AppLanguageMode mode) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    switch (mode) {
    case AppLanguageMode::Japanese:
        [defaults setObject:@"ja" forKey:kLanguagePrefKey];
        break;
    case AppLanguageMode::English:
        [defaults setObject:@"en" forKey:kLanguagePrefKey];
        break;
    case AppLanguageMode::System:
    default:
        [defaults setObject:@"auto" forKey:kLanguagePrefKey];
        break;
    }
}

BOOL usesJapaneseUI() {
    switch (loadLanguageMode()) {
    case AppLanguageMode::Japanese:
        return YES;
    case AppLanguageMode::English:
        return NO;
    case AppLanguageMode::System:
    default: {
        NSString *preferred = [NSLocale preferredLanguages].firstObject;
        return [preferred hasPrefix:@"ja"];
    }
    }
}

} // namespace app_l10n
