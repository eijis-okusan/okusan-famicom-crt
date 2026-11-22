#import "app/AppPreferences.hpp"
#import "video/CrtScreenView.hpp"

namespace app_prefs {

std::string applicationSupportDirectory() {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = dirs.firstObject ?: NSTemporaryDirectory();
    NSString *appDir = [base stringByAppendingPathComponent:@"Okusan-Famicom-CRT-Player"];
    [[NSFileManager defaultManager] createDirectoryAtPath:appDir withIntermediateDirectories:YES attributes:nil error:nil];
    return std::string([appDir UTF8String]);
}

std::string quickStatePathForRom(NSString *romPath) {
    NSString *baseName = romPath ? [[romPath lastPathComponent] stringByDeletingPathExtension] : @"default";
    NSCharacterSet *unsafe = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSString *sanitized = [[baseName componentsSeparatedByCharactersInSet:unsafe] componentsJoinedByString:@"_"];
    if (sanitized.length == 0) sanitized = @"game";
    return applicationSupportDirectory() + "/quickstate_" + std::string([sanitized UTF8String]) + ".ss";
}

void loadDisplayPreferences(CrtDisplayConfig &config, bool &outMuted) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"useRf"])        config.rfMode = [defaults boolForKey:@"useRf"];
    if ([defaults objectForKey:@"monochrome"])   config.monochrome = [defaults boolForKey:@"monochrome"];
    if ([defaults objectForKey:@"interlaced"])   config.interlaced = [defaults boolForKey:@"interlaced"];
    if ([defaults objectForKey:@"hvBloom"])      config.hvBloom = [defaults floatForKey:@"hvBloom"];
    if ([defaults objectForKey:@"curvature"])    config.curvature = [defaults floatForKey:@"curvature"];
    if ([defaults objectForKey:@"maskStrength"]) config.slotMask = [defaults floatForKey:@"maskStrength"];
    if ([defaults objectForKey:@"rfSnow"])       config.rfSnow = [defaults floatForKey:@"rfSnow"];
    if ([defaults objectForKey:@"rfSignal"])     config.rfSignal = [defaults floatForKey:@"rfSignal"];
    if ([defaults objectForKey:@"muted"])        outMuted = [defaults boolForKey:@"muted"];
}

void saveDisplayPreferences(const CrtDisplayConfig &config, bool muted) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:config.rfMode forKey:@"useRf"];
    [defaults setBool:config.monochrome forKey:@"monochrome"];
    [defaults setBool:config.interlaced forKey:@"interlaced"];
    [defaults setFloat:config.hvBloom forKey:@"hvBloom"];
    [defaults setFloat:config.curvature forKey:@"curvature"];
    [defaults setFloat:config.slotMask forKey:@"maskStrength"];
    [defaults setFloat:config.rfSnow forKey:@"rfSnow"];
    [defaults setFloat:config.rfSignal forKey:@"rfSignal"];
    [defaults setBool:muted forKey:@"muted"];
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
