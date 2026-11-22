#import "app/EmulationPacer.hpp"

#import <QuartzCore/QuartzCore.h>
#include <mach/mach_time.h>

#include <algorithm>
#include <cmath>

namespace {

uint64_t monotonicNowNs() {
    static mach_timebase_info_data_t timebase{};
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    return (mach_absolute_time() * timebase.numer) / timebase.denom;
}

} // namespace

@implementation EmulationPacer {
    NSTimer *_frameTimer;
    API_AVAILABLE(macos(14.0)) CADisplayLink *_displayLink;
    id<NSObject> _latencyActivity;
    double (^_fpsProvider)(void);
    void (^_stepBlock)(void);
    double _frameAccumSec;
    CFTimeInterval _lastDlTs;
    uint64_t _nextFrameDeadlineNs;
}

- (void)startWithView:(NSView *)view
          fpsProvider:(double (^)(void))fpsProvider
            stepBlock:(void (^)(void))stepBlock {
    [self stop];
    _fpsProvider = [fpsProvider copy];
    _stepBlock = [stepBlock copy];
    _frameAccumSec = 0.0;
    _lastDlTs = 0.0;
    _nextFrameDeadlineNs = 0;

    _latencyActivity = [[NSProcessInfo processInfo]
        beginActivityWithOptions:(NSActivityUserInteractive | NSActivityLatencyCritical)
                          reason:@"Famicom Real-Time Audio/Video"];

    if (@available(macOS 14.0, *)) {
        _displayLink = [view displayLinkWithTarget:self selector:@selector(onDisplayLink:)];
        _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 60);
        [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } else {
        _frameTimer = [NSTimer timerWithTimeInterval:0.001
                                              target:self
                                            selector:@selector(onTimerTick:)
                                            userInfo:nil
                                             repeats:YES];
        _frameTimer.tolerance = 0.0;
        [[NSRunLoop currentRunLoop] addTimer:_frameTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)stop {
    if (@available(macOS 14.0, *)) {
        [_displayLink invalidate];
        _displayLink = nil;
    }
    [_frameTimer invalidate];
    _frameTimer = nil;
    if (_latencyActivity) {
        [[NSProcessInfo processInfo] endActivity:_latencyActivity];
        _latencyActivity = nil;
    }
    _fpsProvider = nil;
    _stepBlock = nil;
}

- (void)onDisplayLink:(CADisplayLink *)link API_AVAILABLE(macos(14.0)) {
    if (!_stepBlock) return;
    const CFTimeInterval dt = (_lastDlTs > 0.0)
                                  ? (link.targetTimestamp - _lastDlTs)
                                  : (link.targetTimestamp - link.timestamp);
    _lastDlTs = link.targetTimestamp;
    const double clampedDt = std::clamp(dt, 0.001, 0.050);
    const double fps = _fpsProvider ? std::max(_fpsProvider(), 50.0) : 60.0988;
    const double framePeriod = 1.0 / fps;

    int stepsToRun = 0;
    if (std::abs(clampedDt - framePeriod) < 0.0015 || (clampedDt > framePeriod && clampedDt <= 0.036)) {
        // 60 Hz display (including single missed refresh): keep strict 1:1 VSync lock without double-step bursts;
        // Audio DRC absorbs any tiny clock delta smoothly.
        _frameAccumSec = 0.0;
        stepsToRun = 1;
    } else if (std::abs(clampedDt * 2.0 - framePeriod) < 0.0020) {
        // 120 Hz ProMotion: lock cleanly to every 2nd VSync (60.00 Hz).
        _frameAccumSec += clampedDt;
        if (_frameAccumSec >= framePeriod - clampedDt * 0.5) {
            _frameAccumSec = 0.0;
            stepsToRun = 1;
        }
    } else {
        _frameAccumSec += clampedDt;
        while (_frameAccumSec >= framePeriod && stepsToRun < 2) {
            _frameAccumSec -= framePeriod;
            ++stepsToRun;
        }
    }

    for (int s = 0; s < stepsToRun; ++s) {
        _stepBlock();
    }
}

- (void)onTimerTick:(NSTimer *)timer {
    if (!_stepBlock) return;
    const double fps = _fpsProvider ? std::max(_fpsProvider(), 50.0) : 60.0988;
    const double nominalPeriodNs = 1e9 / fps;
    const uint64_t now = monotonicNowNs();
    if (_nextFrameDeadlineNs == 0) _nextFrameDeadlineNs = now;
    if (now < _nextFrameDeadlineNs) return;

    _stepBlock();

    _nextFrameDeadlineNs += static_cast<uint64_t>(nominalPeriodNs);
    if (now > _nextFrameDeadlineNs + static_cast<uint64_t>(nominalPeriodNs * 3.0)) {
        _nextFrameDeadlineNs = now;
    }
}

- (void)dealloc {
    [self stop];
}

@end
