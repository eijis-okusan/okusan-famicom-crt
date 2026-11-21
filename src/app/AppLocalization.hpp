#pragma once

#import <Foundation/Foundation.h>

enum class AppLanguageMode : NSInteger {
    System = 0,
    Japanese = 1,
    English = 2,
};

namespace app_l10n {

AppLanguageMode loadLanguageMode();
void saveLanguageMode(AppLanguageMode mode);

/// Returns YES when UI should be rendered in Japanese based on saved preference or macOS locale.
BOOL usesJapaneseUI();

/// Convenience helper returning the localized NSString for inline Japanese/English pairs.
inline NSString *tr(NSString *ja, NSString *en) {
    return usesJapaneseUI() ? ja : en;
}

} // namespace app_l10n
