#pragma once

#import <Foundation/Foundation.h>
#include <string>

struct CrtDisplayConfig;

namespace app_prefs {

inline constexpr NSUInteger kMaxRecentRoms = 10;

/// Returns (and creates if needed) the per-user Application Support folder for save states.
std::string applicationSupportDirectory();

/// Returns a filesystem-safe quick-save file path derived from `romPath`.
std::string quickStatePathForRom(NSString *romPath);

/// Returns the per-disk XOR diff file path for FDS RAM/disk writes.
std::string fdsSaveDiffPathForDisk(NSString *diskPath);

/// Validates and caches a user-supplied 8 KB FDS BIOS (`*NINTENDO-HVC*`) into Application Support (`disksys.rom`).
void cacheFdsBiosIfValid(NSString *romPath);

/// Loads CRT shader flags, 3D eye swap flag, and audio mute state from NSUserDefaults.
void loadDisplayPreferences(CrtDisplayConfig &config, bool &outMuted, bool &outInvert3dEyes);

/// Persists CRT shader flags, 3D eye swap flag, and audio mute state to NSUserDefaults.
void saveDisplayPreferences(const CrtDisplayConfig &config, bool muted, bool invert3dEyes);

/// Clears persisted display/audio/3D preference keys so defaults apply cleanly.
void clearDisplayPreferences();

/// Loads normalized, deduplicated recent ROM paths (up to `kMaxRecentRoms`).
NSMutableArray<NSString *> *loadRecentRomPaths();

/// Saves recent ROM paths to NSUserDefaults.
void saveRecentRomPaths(NSArray<NSString *> *paths);

/// Moves `romPath` to the front of `paths`, trims to `kMaxRecentRoms`, and persists.
void recordRecentRomPath(NSMutableArray<NSString *> *paths, NSString *romPath);

} // namespace app_prefs
