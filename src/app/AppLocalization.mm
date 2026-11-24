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
        [defaults setObject:@[@"ja"] forKey:@"AppleLanguages"];
        break;
    case AppLanguageMode::English:
        [defaults setObject:@"en" forKey:kLanguagePrefKey];
        [defaults setObject:@[@"en"] forKey:@"AppleLanguages"];
        break;
    case AppLanguageMode::System:
    default:
        [defaults setObject:@"auto" forKey:kLanguagePrefKey];
        [defaults removeObjectForKey:@"AppleLanguages"];
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
        NSArray<NSString *> *globalLangs =
            [[[NSUserDefaults standardUserDefaults] persistentDomainForName:NSGlobalDomain]
                objectForKey:@"AppleLanguages"];
        NSString *preferred = globalLangs.firstObject ?: [NSLocale preferredLanguages].firstObject;
        return [preferred hasPrefix:@"ja"];
    }
    }
}

} // namespace app_l10n
