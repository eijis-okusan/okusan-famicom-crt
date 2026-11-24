#pragma once

#include <string>

/**
 * Portable filesystem-naming and Famicom Disk System (FDS) BIOS detection helpers.
 * Pure C++17 so save-path naming and BIOS verification behave identically across platforms.
 */
namespace famicom_storage {

/// Returns an ASCII-safe filename stem derived from `path` (falls back to `fallback` if empty).
std::string sanitizeFilenameStem(const std::string &path, const std::string &fallback);

/// Builds the quick-save `.ss` path inside `supportDir` for `romPath`.
std::string quickStatePath(const std::string &supportDir, const std::string &romPath);

/// Builds the per-disk `.ofds` XOR save-diff path inside `supportDir` for `diskPath`.
std::string fdsSaveDiffPath(const std::string &supportDir, const std::string &diskPath);

/// Inspects a user-supplied ROM/binary file (`disksys.rom`, raw 8 KB, or `.nes` dump),
/// locates an authentic 8 KB `*NINTENDO-HVC*` FDS BIOS block, and caches it as `<supportDir>/disksys.rom`.
/// Returns true when a valid BIOS block was detected and written.
bool cacheFdsBiosIfValid(const std::string &romPath, const std::string &supportDir);

} // namespace famicom_storage
