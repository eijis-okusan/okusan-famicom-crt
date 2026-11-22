#pragma once

#import <Cocoa/Cocoa.h>

/**
 * Drives the fixed-rate emulation loop using CADisplayLink (macOS 14+ VSync lock)
 * with a 1 ms NSTimer fallback, while holding a latency-critical NSProcessInfo
 * activity assertion.
 */
@interface EmulationPacer : NSObject

- (void)startWithView:(NSView *)view
          fpsProvider:(double (^)(void))fpsProvider
            stepBlock:(void (^)(void))stepBlock;
- (void)stop;

@end
