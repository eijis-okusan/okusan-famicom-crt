#pragma once

#import <Cocoa/Cocoa.h>

/// Presents the standard macOS About panel with bilingual attribution.
void presentAboutDialog();

/// Manages the scrollable Open Source Licenses window (GPL v2.0 + bundled OSS notices).
@interface LicensesWindowController : NSWindowController
- (void)showLicenses;
- (void)refreshLocalization;
@end
