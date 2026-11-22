#import "app/AppPreferences.hpp"
#import "video/CrtScreenView.hpp"

#include <algorithm>
#include <cstring>
#include <fstream>
#include <vector>

namespace app_prefs {

namespace {

NSString *sanitizedStem(NSString *path, NSString *fallback) {
    NSString *baseName = path ? [[path lastPathComponent] stringByDeletingPathExtension] : fallback;
    NSCharacterSet *unsafe = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSString *sanitized = [[baseName componentsSeparatedByCharactersInSet:unsafe] componentsJoinedByString:@"_"];
    return (sanitized.length == 0) ? fallback : sanitized;
}

} // namespace

std::string applicationSupportDirectory() {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = dirs.firstObject ?: NSTemporaryDirectory();
    NSString *appDir = [base stringByAppendingPathComponent:@"Okusan-Famicom-CRT-Player"];
    [[NSFileManager defaultManager] createDirectoryAtPath:appDir withIntermediateDirectories:YES attributes:nil error:nil];
    return std::string([appDir UTF8String]);
}

std::string quickStatePathForRom(NSString *romPath) {
    return applicationSupportDirectory() + "/quickstate_" +
           std::string([sanitizedStem(romPath, @"game") UTF8String]) + ".ss";
}

std::string fdsSaveDiffPathForDisk(NSString *diskPath) {
    return applicationSupportDirectory() + "/fds_diff_" +
           std::string([sanitizedStem(diskPath, @"fds") UTF8String]) + ".ofds";
}

void cacheFdsBiosIfValid(NSString *romPath) {
    if (!romPath || romPath.length == 0) return;
    std::ifstream ifs([romPath UTF8String], std::ios::binary);
    if (!ifs.is_open()) return;
    ifs.seekg(0, std::ios::end);
    const std::streamoff sz = ifs.tellg();
    if (sz < 8192 || sz > 65552) return;
    ifs.seekg(0, std::ios::beg);
    std::vector<uint8_t> buf(static_cast<size_t>(sz));
    if (!ifs.read(reinterpret_cast<char *>(buf.data()), sz)) return;

    size_t prgStart = 0;
    if (buf.size() >= 16 && std::memcmp(buf.data(), "NES\x1a", 4) == 0) {
        if (buf[5] != 0) return; // FDS BIOS never uses CHR-ROM
        prgStart = 16u + ((buf[6] & 4u) ? 512u : 0u);
    }
    if (buf.size() <= prgStart || (buf.size() - prgStart) < 8192u) return;

    static constexpr char kHvcSig[] = "*NINTENDO-HVC*";
    const size_t numChunks = (buf.size() - prgStart) / 8192u;
    const uint8_t *matched = nullptr;
    for (size_t idx = numChunks; idx > 0; --idx) {
        const uint8_t *chunk = buf.data() + prgStart + (idx - 1) * 8192u;
        if (chunk[0x1FFD] >= 0xE0) {
            const uint8_t *end = chunk + 8192u;
            if (std::search(chunk, end, kHvcSig, kHvcSig + 14) != end) {
                matched = chunk;
                break;
            }
        }
    }
    if (!matched) return;

    const std::string dest = applicationSupportDirectory() + "/disksys.rom";
    std::ofstream ofs(dest, std::ios::binary | std::ios::trunc);
    if (ofs.is_open()) {
        ofs.write(reinterpret_cast<const char *>(matched), 8192);
    }
}

void loadDisplayPreferences(CrtDisplayConfig &config, bool &outMuted, bool &outInvert3dEyes) {
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
    [defaults removeObjectForKey:@"view3dMode"]; // 3D System always boots in unshuttered 60Hz Naked CRT
    if ([defaults objectForKey:@"invert3dEyes"]) outInvert3dEyes = [defaults boolForKey:@"invert3dEyes"];
}

void saveDisplayPreferences(const CrtDisplayConfig &config, bool muted, bool invert3dEyes) {
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
    [defaults setBool:invert3dEyes forKey:@"invert3dEyes"];
}

void clearDisplayPreferences() {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray<NSString *> *keys = @[
        @"useRf", @"monochrome", @"interlaced",
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
