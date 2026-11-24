#include "common/FdsBiosCache.hpp"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <vector>

namespace famicom_storage {

std::string sanitizeFilenameStem(const std::string &path, const std::string &fallback) {
    if (path.empty()) return fallback;

    const size_t slash = path.find_last_of("/\\");
    const std::string baseName = (slash == std::string::npos) ? path : path.substr(slash + 1);
    const size_t dot = baseName.find_last_of('.');
    const std::string stem = (dot == std::string::npos || dot == 0) ? baseName : baseName.substr(0, dot);

    std::string sanitized;
    sanitized.reserve(stem.size());
    for (unsigned char ch : stem) {
        if (std::isalnum(ch)) {
            sanitized.push_back(static_cast<char>(ch));
        } else {
            sanitized.push_back('_');
        }
    }
    return sanitized.empty() ? fallback : sanitized;
}

std::string quickStatePath(const std::string &supportDir, const std::string &romPath) {
    return supportDir + "/quickstate_" + sanitizeFilenameStem(romPath, "game") + ".ss";
}

std::string fdsSaveDiffPath(const std::string &supportDir, const std::string &diskPath) {
    return supportDir + "/fds_diff_" + sanitizeFilenameStem(diskPath, "fds") + ".ofds";
}

bool cacheFdsBiosIfValid(const std::string &romPath, const std::string &supportDir) {
    if (romPath.empty() || supportDir.empty()) return false;

    std::ifstream ifs(romPath, std::ios::binary);
    if (!ifs.is_open()) return false;

    ifs.seekg(0, std::ios::end);
    const std::streamoff sz = ifs.tellg();
    if (sz < 8192 || sz > 65552) return false;

    ifs.seekg(0, std::ios::beg);
    std::vector<uint8_t> buf(static_cast<size_t>(sz));
    if (!ifs.read(reinterpret_cast<char *>(buf.data()), sz)) return false;

    // Support both raw 8 KB dumps and iNES-wrapped BIOS dumps (which have 0 CHR-ROM banks).
    size_t prgStart = 0;
    if (buf.size() >= 16 && std::memcmp(buf.data(), "NES\x1a", 4) == 0) {
        if (buf[5] != 0) return false;
        prgStart = 16u + ((buf[6] & 4u) ? 512u : 0u);
    }
    if (buf.size() <= prgStart || (buf.size() - prgStart) < 8192u) return false;

    // FDS BIOS ROM lives in $E000-$FFFF: verify reset vector sits in $E000+ and contains "*NINTENDO-HVC*".
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
    if (!matched) return false;

    const std::string dest = supportDir + "/disksys.rom";
    std::ofstream ofs(dest, std::ios::binary | std::ios::trunc);
    if (!ofs.is_open()) return false;

    ofs.write(reinterpret_cast<const char *>(matched), 8192);
    return ofs.good();
}

} // namespace famicom_storage
