#pragma once

#import <Cocoa/Cocoa.h>
#import "video/CrtScreenView.hpp"

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, CrtScreenDelegate>
@end
