#import "app/AppPreferences.hpp"
#import "common/FamicomTypes.hpp"
#import "common/FdsBiosCache.hpp"

#include <string>

namespace app_prefs {

std::string applicationSupportDirectory() {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = dirs.firstObject ?: NSTemporaryDirectory();
    NSString *appDir = [base stringByAppendingPathComponent:@"Okusan-Famicom-CRT-Player"];
    [[NSFileManager defaultManager] createDirectoryAtPath:appDir withIntermediateDirectories:YES attributes:nil error:nil];
    return std::string([appDir UTF8String]);
}

std::string quickStatePathForRom(NSString *romPath) {
    const std::string utf8 = romPath ? std::string([romPath UTF8String]) : std::string();
    return famicom_storage::quickStatePath(applicationSupportDirectory(), utf8);
}

std::string fdsSaveDiffPathForDisk(NSString *diskPath) {
    const std::string utf8 = diskPath ? std::string([diskPath UTF8String]) : std::string();
    return famicom_storage::fdsSaveDiffPath(applicationSupportDirectory(), utf8);
}

void cacheFdsBiosIfValid(NSString *romPath) {
    if (!romPath || romPath.length == 0) return;
    famicom_storage::cacheFdsBiosIfValid(std::string([romPath UTF8String]), applicationSupportDirectory());
}

void loadDisplayPreferences(CrtDisplayConfig &config, bool &outMuted, bool &outInvert3dEyes) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"useRf"])        config.rfMode = [defaults boolForKey:@"useRf"];
    if ([defaults objectForKey:@"monochrome"])   config.monochrome = [defaults boolForKey:@"monochrome"];
    if ([defaults objectForKey:@"x68k31k"])      config.x68k31kMode = [defaults boolForKey:@"x68k31k"];
    if ([defaults objectForKey:@"compositeAv"])  config.compositeMode = [defaults boolForKey:@"compositeAv"];
    if ([defaults objectForKey:@"interlaced"])   config.interlaced = [defaults boolForKey:@"interlaced"];
    if ([defaults objectForKey:@"hdrEnabled"])   config.hdrEnabled = [defaults boolForKey:@"hdrEnabled"];
    if ([defaults objectForKey:@"hvBloom"])      config.hvBloom = [defaults floatForKey:@"hvBloom"];
    if ([defaults objectForKey:@"curvature"])    config.curvature = [defaults floatForKey:@"curvature"];
    if ([defaults objectForKey:@"maskStrength"]) config.slotMask = [defaults floatForKey:@"maskStrength"];
    if ([defaults objectForKey:@"rfSnow"])       config.rfSnow = [defaults floatForKey:@"rfSnow"];
    if ([defaults objectForKey:@"rfSignal"])     config.rfSignal = [defaults floatForKey:@"rfSignal"];
    if ([defaults objectForKey:@"muted"])        outMuted = [defaults boolForKey:@"muted"];
    [defaults removeObjectForKey:@"view3dMode"]; // 3D System always boots in unshuttered 60Hz Naked CRT
    if ([defaults objectForKey:@"invert3dEyes"]) outInvert3dEyes = [defaults boolForKey:@"invert3dEyes"];
}

void saveDisplayPreferences(const CrtDisplayConfig &config, bool muted, bool invert3dEyes) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:config.rfMode forKey:@"useRf"];
    [defaults setBool:config.monochrome forKey:@"monochrome"];
    [defaults setBool:config.x68k31kMode forKey:@"x68k31k"];
    [defaults setBool:config.compositeMode forKey:@"compositeAv"];
    [defaults setBool:config.interlaced forKey:@"interlaced"];
    [defaults setBool:config.hdrEnabled forKey:@"hdrEnabled"];
    [defaults setFloat:config.hvBloom forKey:@"hvBloom"];
    [defaults setFloat:config.curvature forKey:@"curvature"];
    [defaults setFloat:config.slotMask forKey:@"maskStrength"];
    [defaults setFloat:config.rfSnow forKey:@"rfSnow"];
    [defaults setFloat:config.rfSignal forKey:@"rfSignal"];
    [defaults setBool:muted forKey:@"muted"];
    [defaults setBool:invert3dEyes forKey:@"invert3dEyes"];
}

void clearDisplayPreferences() {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray<NSString *> *keys = @[
        @"useRf", @"monochrome", @"x68k31k", @"compositeAv", @"interlaced", @"hdrEnabled",
        @"hvBloom", @"curvature", @"maskStrength",
        @"rfSnow", @"rfSignal", @"muted",
        @"view3dMode", @"invert3dEyes"
    ];
    for (NSString *key in keys) {
        [defaults removeObjectForKey:key];
    }
}

NSMutableArray<NSString *> *loadRecentRomPaths() {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (id entry in [defaults arrayForKey:@"recentRoms"]) {
        if (![entry isKindOfClass:[NSString class]]) continue;
        NSString *normalized = [(NSString *)entry stringByStandardizingPath];
        if (normalized.length == 0 || [result containsObject:normalized]) continue;
        [result addObject:normalized];
        if (result.count >= kMaxRecentRoms) break;
    }
    return result;
}

void saveRecentRomPaths(NSArray<NSString *> *paths) {
    [[NSUserDefaults standardUserDefaults] setObject:[paths copy] forKey:@"recentRoms"];
}

void recordRecentRomPath(NSMutableArray<NSString *> *paths, NSString *romPath) {
    if (!paths || !romPath || romPath.length == 0) return;
    NSString *normalized = [romPath stringByStandardizingPath];
    [paths removeObject:normalized];
    [paths insertObject:normalized atIndex:0];
    while (paths.count > kMaxRecentRoms) {
        [paths removeLastObject];
    }
    saveRecentRomPaths(paths);
}

} // namespace app_prefs
