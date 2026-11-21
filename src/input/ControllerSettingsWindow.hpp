#pragma once

#import <Cocoa/Cocoa.h>
#import "InputBindings.hpp"

@interface ControllerSettingsWindow : NSWindowController

- (instancetype)initWithBindings:(InputBindings *)bindings
                        onChange:(void (^)(void))onChange;
- (void)refreshUI;

@end
