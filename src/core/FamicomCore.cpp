#include "FamicomCore.hpp"
#include "common/DynamicLibrary.hpp"

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <utility>

namespace {

// Minimal subset of libretro ABI structures so this host builds without external headers.
struct RetroGameInfo {
    const char *path;
    const void *data;
    size_t size;
    const char *meta;
};

struct RetroSystemInfo {
    const char *libraryName;
    const char *libraryVersion;
    const char *validExtensions;
    bool needFullpath;
    bool blockExtract;
};

struct RetroGameGeometry {
    unsigned baseWidth;
    unsigned baseHeight;
    unsigned maxWidth;
    unsigned maxHeight;
    float aspectRatio;
};

struct RetroSystemTiming {
    double fps;
    double sampleRate;
};

struct RetroSystemAvInfo {
    RetroGameGeometry geometry;
    RetroSystemTiming timing;
};

struct RetroVariable {
    const char *key;
    const char *value;
};

struct RetroLogCallback {
    void (*log)(int level, const char *fmt, ...);
};

} // namespace

struct FamicomCore::CoreState {
    DynamicLibrary library;
    bool loaded = false;
    std::string systemDir;
    std::string saveDir;
    uint32_t pad1Buttons = 0;
    unsigned pixelFormat = 1; // RETRO_PIXEL_FORMAT_XRGB8888
    AudioFrameSink audioSink;

    std::vector<uint32_t> *currentFrame = nullptr;
    std::vector<uint32_t> *previousFrame = nullptr;
    unsigned *frameWidth = nullptr;
    unsigned *frameHeight = nullptr;

    // Standard libretro entrypoints
    void (*retro_set_environment)(bool (*)(unsigned, void *)) = nullptr;
    void (*retro_set_video_refresh)(void (*)(const void *, unsigned, unsigned, size_t)) = nullptr;
    void (*retro_set_audio_sample)(void (*)(int16_t, int16_t)) = nullptr;
    void (*retro_set_audio_sample_batch)(size_t (*)(const int16_t *, size_t)) = nullptr;
    void (*retro_set_input_poll)(void (*)()) = nullptr;
    void (*retro_set_input_state)(int16_t (*)(unsigned, unsigned, unsigned, unsigned)) = nullptr;
    void (*retro_init)() = nullptr;
    void (*retro_deinit)() = nullptr;
    void (*retro_get_system_info)(RetroSystemInfo *) = nullptr;
    void (*retro_get_system_av_info)(RetroSystemAvInfo *) = nullptr;
    void (*retro_set_controller_port_device)(unsigned, unsigned) = nullptr;
    void (*retro_reset)() = nullptr;
    void (*retro_run)() = nullptr;
    size_t (*retro_serialize_size)() = nullptr;
    bool (*retro_serialize)(void *, size_t) = nullptr;
    bool (*retro_unserialize)(const void *, size_t) = nullptr;
    bool (*retro_load_game)(const RetroGameInfo *) = nullptr;
    void (*retro_unload_game)() = nullptr;

    // 60-pin cartridge physics extensions exported by our patched fceumm build
    void (*okusan_set_cart_contact)(int, int) = nullptr;
    void (*okusan_set_cart_contact3)(int, int, int) = nullptr;
    void (*okusan_set_pin_fault_masks)(uint64_t, uint64_t) = nullptr;
    void (*okusan_reseat_cart_contact)() = nullptr;
    void (*okusan_get_pin_telemetry60)(int *, int *, int *, CartPinReading *, int) = nullptr;
    int (*okusan_cart_edge_rise_um)(int, int, int) = nullptr;
    int (*okusan_cart_lat_shift_um)(int, int) = nullptr;
    int (*okusan_get_audio_contact_q)() = nullptr;
    int (*okusan_cart_is_powered)() = nullptr;
    int (*okusan_cart_vcc_mv)() = nullptr;
    int (*okusan_get_cpu_jammed)() = nullptr;
    uint16_t (*okusan_get_cpu_pc)() = nullptr;

    // Famicom 3D System ($4016 OUT1) shutter telemetry
    int (*okusan_get_3d_system_active)() = nullptr;
    int (*okusan_get_3d_current_eye)() = nullptr;

    // Famicom Disk System (HVC-022) live drive & fault extensions
    int (*okusan_fds_is_active)() = nullptr;
    void (*okusan_fds_get_status)(int *, int *, int *, int *, uint32_t *, uint32_t *, int *) = nullptr;
    int (*okusan_fds_hot_swap_disk)(const uint8_t *, uint32_t) = nullptr;
    void (*okusan_fds_eject_disk)() = nullptr;
    void (*okusan_fds_set_side)(int) = nullptr;
    void (*okusan_fds_clear_fault)() = nullptr;
    int (*okusan_fds_trigger_random_fault)(uint32_t) = nullptr;
    uint8_t *(*okusan_fds_get_side_ptr)(int, const uint8_t **) = nullptr;

    static CoreState *activeInstance;

    static void onCoreLog(int level, const char *fmt, ...) {
        // Skip verbose debug/info chatter from the core; keep warnings and errors visible.
        if (level < 2) return;
        va_list args;
        va_start(args, fmt);
        std::vfprintf(stderr, fmt, args);
        va_end(args);
    }

    static bool onEnvironment(unsigned cmd, void *data) {
        if (!activeInstance) return false;
        switch (cmd) {
        case 3: // RETRO_ENVIRONMENT_GET_CAN_DUPE
            if (data) *static_cast<bool *>(data) = true;
            return true;
        case 9: // RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY
            if (data) *static_cast<const char **>(data) = activeInstance->systemDir.c_str();
            return true;
        case 10: // RETRO_ENVIRONMENT_SET_PIXEL_FORMAT
            if (data) activeInstance->pixelFormat = *static_cast<unsigned *>(data);
            return activeInstance->pixelFormat == 1 || activeInstance->pixelFormat == 2;
        case 15: // RETRO_ENVIRONMENT_GET_VARIABLE
            if (data) {
                auto *var = static_cast<RetroVariable *>(data);
                // Keep all 256x240 active pixels visible; CRT bezel overscan is shaped by the shader.
                if (var->key && std::strcmp(var->key, "fceumm_overscan_h") == 0) {
                    var->value = "disabled";
                    return true;
                }
                if (var->key && std::strcmp(var->key, "fceumm_overscan_v") == 0) {
                    var->value = "disabled";
                    return true;
                }
                var->value = nullptr;
            }
            return false;
        case 17: // RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE
            if (data) *static_cast<bool *>(data) = false;
            return true;
        case 27: // RETRO_ENVIRONMENT_GET_LOG_INTERFACE
            if (data) static_cast<RetroLogCallback *>(data)->log = onCoreLog;
            return true;
        case 31: // RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY
            if (data) *static_cast<const char **>(data) = activeInstance->saveDir.c_str();
            return true;
        default:
            return false;
        }
    }

    static void onVideoRefresh(const void *pixels, unsigned width, unsigned height, size_t pitchBytes) {
        if (!activeInstance || !pixels || !activeInstance->currentFrame || !activeInstance->previousFrame) {
            return;
        }

        // Preserve the previous frame so the CRT shader can simulate phosphor persistence / beam load.
        std::swap(*activeInstance->currentFrame, *activeInstance->previousFrame);
        *activeInstance->frameWidth = width;
        *activeInstance->frameHeight = height;

        const size_t pixelCount = static_cast<size_t>(width) * height;
        if (activeInstance->currentFrame->size() != pixelCount) {
            activeInstance->currentFrame->assign(pixelCount, 0);
        }
        if (activeInstance->previousFrame->size() != pixelCount) {
            activeInstance->previousFrame->assign(pixelCount, 0);
        }

        const auto *srcBytes = static_cast<const uint8_t *>(pixels);
        uint32_t *dstPixels = activeInstance->currentFrame->data();

        if (activeInstance->pixelFormat == 1) { // XRGB8888
            for (unsigned y = 0; y < height; ++y) {
                std::memcpy(dstPixels + static_cast<size_t>(y) * width,
                            srcBytes + static_cast<size_t>(y) * pitchBytes,
                            static_cast<size_t>(width) * sizeof(uint32_t));
            }
        } else if (activeInstance->pixelFormat == 2) { // RGB565 fallback
            for (unsigned y = 0; y < height; ++y) {
                const auto *row = reinterpret_cast<const uint16_t *>(srcBytes + static_cast<size_t>(y) * pitchBytes);
                for (unsigned x = 0; x < width; ++x) {
                    const uint16_t rgb565 = row[x];
                    const uint32_t r = ((rgb565 >> 11) & 0x1Fu) * 255u / 31u;
                    const uint32_t g = ((rgb565 >> 5) & 0x3Fu) * 255u / 63u;
                    const uint32_t b = (rgb565 & 0x1Fu) * 255u / 31u;
                    dstPixels[static_cast<size_t>(y) * width + x] = 0xFF000000u | (r << 16) | (g << 8) | b;
                }
            }
        }
    }

    static void onAudioSample(int16_t left, int16_t right) {
        if (!activeInstance || !activeInstance->audioSink) return;
        const int16_t stereoFrame[2] = {left, right};
        activeInstance->audioSink(stereoFrame, 1);
    }

    static size_t onAudioBatch(const int16_t *samples, size_t frameCount) {
        if (activeInstance && activeInstance->audioSink && samples && frameCount > 0) {
            activeInstance->audioSink(samples, frameCount);
        }
        return frameCount;
    }

    static void onInputPoll() {}

    static int16_t onInputState(unsigned port, unsigned device, unsigned /*index*/, unsigned buttonId) {
        if (!activeInstance || port != 0 || device != 1 || buttonId >= 16) return 0;
        return ((activeInstance->pad1Buttons >> buttonId) & 1u) ? 1 : 0;
    }

    void clearCustomSymbols() {
        okusan_set_cart_contact = nullptr;
        okusan_set_cart_contact3 = nullptr;
        okusan_set_pin_fault_masks = nullptr;
        okusan_reseat_cart_contact = nullptr;
        okusan_get_pin_telemetry60 = nullptr;
        okusan_cart_edge_rise_um = nullptr;
        okusan_cart_lat_shift_um = nullptr;
        okusan_get_audio_contact_q = nullptr;
        okusan_cart_is_powered = nullptr;
        okusan_cart_vcc_mv = nullptr;
        okusan_get_cpu_jammed = nullptr;
        okusan_get_cpu_pc = nullptr;
        okusan_get_3d_system_active = nullptr;
        okusan_get_3d_current_eye = nullptr;
        okusan_fds_is_active = nullptr;
        okusan_fds_get_status = nullptr;
        okusan_fds_hot_swap_disk = nullptr;
        okusan_fds_eject_disk = nullptr;
        okusan_fds_set_side = nullptr;
        okusan_fds_clear_fault = nullptr;
        okusan_fds_trigger_random_fault = nullptr;
        okusan_fds_get_side_ptr = nullptr;
    }
};

FamicomCore::CoreState *FamicomCore::CoreState::activeInstance = nullptr;

FamicomCore::FamicomCore() : state_(new CoreState()) {
    currentFrame_.assign(256 * 240, 0);
    previousFrame_.assign(256 * 240, 0);
    state_->currentFrame = &currentFrame_;
    state_->previousFrame = &previousFrame_;
    state_->frameWidth = &frameWidth_;
    state_->frameHeight = &frameHeight_;
}

FamicomCore::~FamicomCore() {
    unload();
    delete state_;
}

bool FamicomCore::load(const std::string &coreLibraryPath,
                       const std::string &romPath,
                       const std::string &systemDir,
                       const std::string &saveDir) {
    unload();

    state_->systemDir = systemDir;
    state_->saveDir = saveDir;
    if (!state_->library.open(coreLibraryPath)) {
        return false;
    }

    bool symbolsOk = true;
    symbolsOk &= state_->library.resolve("retro_set_environment", state_->retro_set_environment);
    symbolsOk &= state_->library.resolve("retro_set_video_refresh", state_->retro_set_video_refresh);
    symbolsOk &= state_->library.resolve("retro_set_audio_sample", state_->retro_set_audio_sample);
    symbolsOk &= state_->library.resolve("retro_set_audio_sample_batch", state_->retro_set_audio_sample_batch);
    symbolsOk &= state_->library.resolve("retro_set_input_poll", state_->retro_set_input_poll);
    symbolsOk &= state_->library.resolve("retro_set_input_state", state_->retro_set_input_state);
    symbolsOk &= state_->library.resolve("retro_init", state_->retro_init);
    symbolsOk &= state_->library.resolve("retro_deinit", state_->retro_deinit);
    symbolsOk &= state_->library.resolve("retro_get_system_info", state_->retro_get_system_info);
    symbolsOk &= state_->library.resolve("retro_get_system_av_info", state_->retro_get_system_av_info);
    symbolsOk &= state_->library.resolve("retro_set_controller_port_device", state_->retro_set_controller_port_device);
    symbolsOk &= state_->library.resolve("retro_reset", state_->retro_reset);
    symbolsOk &= state_->library.resolve("retro_run", state_->retro_run);
    symbolsOk &= state_->library.resolve("retro_serialize_size", state_->retro_serialize_size);
    symbolsOk &= state_->library.resolve("retro_serialize", state_->retro_serialize);
    symbolsOk &= state_->library.resolve("retro_unserialize", state_->retro_unserialize);
    symbolsOk &= state_->library.resolve("retro_load_game", state_->retro_load_game);
    symbolsOk &= state_->library.resolve("retro_unload_game", state_->retro_unload_game);
    if (!symbolsOk) {
        unload();
        return false;
    }

    // Optional extensions (present in our patched fceumm binary).
    state_->library.resolve("okusan_set_cart_contact", state_->okusan_set_cart_contact);
    state_->library.resolve("okusan_set_cart_contact3", state_->okusan_set_cart_contact3);
    state_->library.resolve("okusan_set_pin_fault_masks", state_->okusan_set_pin_fault_masks);
    state_->library.resolve("okusan_reseat_cart_contact", state_->okusan_reseat_cart_contact);
    state_->library.resolve("okusan_get_pin_telemetry60", state_->okusan_get_pin_telemetry60);
    state_->library.resolve("okusan_cart_edge_rise_um", state_->okusan_cart_edge_rise_um);
    state_->library.resolve("okusan_cart_lat_shift_um", state_->okusan_cart_lat_shift_um);
    state_->library.resolve("okusan_get_audio_contact_q", state_->okusan_get_audio_contact_q);
    state_->library.resolve("okusan_cart_is_powered", state_->okusan_cart_is_powered);
    state_->library.resolve("okusan_cart_vcc_mv", state_->okusan_cart_vcc_mv);
    state_->library.resolve("okusan_get_cpu_jammed", state_->okusan_get_cpu_jammed);
    state_->library.resolve("okusan_get_cpu_pc", state_->okusan_get_cpu_pc);
    state_->library.resolve("okusan_get_3d_system_active", state_->okusan_get_3d_system_active);
    state_->library.resolve("okusan_get_3d_current_eye", state_->okusan_get_3d_current_eye);
    state_->library.resolve("okusan_fds_is_active", state_->okusan_fds_is_active);
    state_->library.resolve("okusan_fds_get_status", state_->okusan_fds_get_status);
    state_->library.resolve("okusan_fds_hot_swap_disk", state_->okusan_fds_hot_swap_disk);
    state_->library.resolve("okusan_fds_eject_disk", state_->okusan_fds_eject_disk);
    state_->library.resolve("okusan_fds_set_side", state_->okusan_fds_set_side);
    state_->library.resolve("okusan_fds_clear_fault", state_->okusan_fds_clear_fault);
    state_->library.resolve("okusan_fds_trigger_random_fault", state_->okusan_fds_trigger_random_fault);
    state_->library.resolve("okusan_fds_get_side_ptr", state_->okusan_fds_get_side_ptr);

    CoreState::activeInstance = state_;
    state_->retro_set_environment(CoreState::onEnvironment);
    state_->retro_init();
    state_->retro_set_video_refresh(CoreState::onVideoRefresh);
    state_->retro_set_audio_sample(CoreState::onAudioSample);
    state_->retro_set_audio_sample_batch(CoreState::onAudioBatch);
    state_->retro_set_input_poll(CoreState::onInputPoll);
    state_->retro_set_input_state(CoreState::onInputState);

    std::ifstream romFile(romPath, std::ios::binary);
    if (!romFile.is_open()) {
        unload();
        return false;
    }
    std::vector<uint8_t> romData((std::istreambuf_iterator<char>(romFile)), {});
    RetroGameInfo gameInfo{romPath.c_str(), romData.data(), romData.size(), nullptr};
    if (!state_->retro_load_game(&gameInfo)) {
        unload();
        return false;
    }

    state_->retro_set_controller_port_device(0, 1); // Port 0 -> Standard Joypad
    RetroSystemAvInfo avInfo{};
    state_->retro_get_system_av_info(&avInfo);
    if (avInfo.geometry.baseWidth > 0 && avInfo.geometry.baseHeight > 0) {
        frameWidth_ = avInfo.geometry.baseWidth;
        frameHeight_ = avInfo.geometry.baseHeight;
    }
    if (avInfo.timing.fps > 1.0) frameRate_ = avInfo.timing.fps;
    if (avInfo.timing.sampleRate > 1000.0) sampleRate_ = avInfo.timing.sampleRate;

    currentFrame_.assign(static_cast<size_t>(frameWidth_) * frameHeight_, 0);
    previousFrame_.assign(static_cast<size_t>(frameWidth_) * frameHeight_, 0);
    state_->loaded = true;
    return true;
}

void FamicomCore::unload() {
    if (state_->library.isOpen()) {
        if (state_->loaded && state_->retro_unload_game) state_->retro_unload_game();
        if (state_->retro_deinit) state_->retro_deinit();
        state_->library.close();
    }
    if (CoreState::activeInstance == state_) {
        CoreState::activeInstance = nullptr;
    }
    state_->clearCustomSymbols();
    state_->audioSink = nullptr;
    state_->loaded = false;
}

bool FamicomCore::isLoaded() const {
    return state_->loaded;
}

void FamicomCore::setCartridgePose(int tilt, int lift, int pitch) {
    if (!state_->loaded) return;
    if (state_->okusan_set_cart_contact3) {
        state_->okusan_set_cart_contact3(tilt, lift, pitch);
    } else if (state_->okusan_set_cart_contact) {
        state_->okusan_set_cart_contact(tilt, lift);
    }
}

void FamicomCore::setPinFaultMasks(uint64_t weakMask, uint64_t openMask) {
    if (!state_->loaded || !state_->okusan_set_pin_fault_masks) return;
    state_->okusan_set_pin_fault_masks(weakMask, openMask);
}

void FamicomCore::reseatCartridge() {
    if (!state_->loaded) return;
    if (state_->okusan_reseat_cart_contact) {
        state_->okusan_reseat_cart_contact();
    } else {
        setCartridgePose(0, 0, 0);
    }
}

bool FamicomCore::readPinTelemetry(int &tilt, int &lift, int &pitch, CartPinReading *outReadings, int maxPins) const {
    if (state_->loaded && state_->okusan_get_pin_telemetry60) {
        state_->okusan_get_pin_telemetry60(&tilt, &lift, &pitch, outReadings, maxPins);
        return true;
    }
    tilt = 0;
    lift = 0;
    pitch = 0;
    return false;
}

int FamicomCore::edgeLiftUm(int tilt, int lift, int xOffsetUm) const {
    if (state_->loaded && state_->okusan_cart_edge_rise_um) {
        return state_->okusan_cart_edge_rise_um(tilt, lift, xOffsetUm);
    }
    return 0;
}

int FamicomCore::lateralShiftUm(int tilt, int lift) const {
    if (state_->loaded && state_->okusan_cart_lat_shift_um) {
        return state_->okusan_cart_lat_shift_um(tilt, lift);
    }
    return 0;
}

float FamicomCore::cartridgeAudioGain() const {
    if (state_->loaded && state_->okusan_get_audio_contact_q) {
        return static_cast<float>(state_->okusan_get_audio_contact_q()) / 256.0f;
    }
    return 1.0f;
}

bool FamicomCore::isCartridgePowered() const {
    if (!state_->loaded) return false;
    return !state_->okusan_cart_is_powered || (state_->okusan_cart_is_powered() != 0);
}

int FamicomCore::cartridgeVccMv() const {
    if (!state_->loaded) return 0;
    return state_->okusan_cart_vcc_mv ? state_->okusan_cart_vcc_mv() : 5000;
}

bool FamicomCore::isCpuJammed() const {
    return state_->loaded && state_->okusan_get_cpu_jammed && (state_->okusan_get_cpu_jammed() != 0);
}

uint16_t FamicomCore::cpuProgramCounter() const {
    return (state_->loaded && state_->okusan_get_cpu_pc) ? state_->okusan_get_cpu_pc() : 0;
}

bool FamicomCore::is3dSystemActive() const {
    return state_->loaded && state_->okusan_get_3d_system_active && (state_->okusan_get_3d_system_active() != 0);
}

int FamicomCore::current3dEye() const {
    return (state_->loaded && state_->okusan_get_3d_current_eye) ? state_->okusan_get_3d_current_eye() : 0;
}

bool FamicomCore::isFdsActive() const {
    return state_->loaded && state_->okusan_fds_is_active && (state_->okusan_fds_is_active() != 0);
}

FdsDriveStatus FamicomCore::fdsDriveStatus() const {
    FdsDriveStatus status{};
    if (!state_->loaded || !state_->okusan_fds_is_active || !state_->okusan_fds_get_status) {
        return status;
    }
    status.active = (state_->okusan_fds_is_active() != 0);
    if (!status.active) return status;

    int motor = 0;
    int rw = 0;
    state_->okusan_fds_get_status(&status.insertedSide, &status.totalSides,
                                  &motor, &rw,
                                  &status.seekSeq, &status.latchSeq, &status.faultMode);
    status.motorOn = (motor != 0);
    status.rwActivity = (rw != 0);
    return status;
}

int FamicomCore::hotSwapFdsDisk(const std::string &path) {
    if (!state_->loaded || !state_->okusan_fds_hot_swap_disk) return 0;
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs.is_open()) return 0;
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(ifs)), {});
    if (bytes.empty()) return 0;
    return state_->okusan_fds_hot_swap_disk(bytes.data(), static_cast<uint32_t>(bytes.size()));
}

void FamicomCore::ejectFdsDisk() {
    if (state_->loaded && state_->okusan_fds_eject_disk) {
        state_->okusan_fds_eject_disk();
    }
}

void FamicomCore::setFdsDiskSide(int side) {
    if (state_->loaded && state_->okusan_fds_set_side) {
        state_->okusan_fds_set_side(side);
    }
}

void FamicomCore::clearFdsFault() {
    if (state_->loaded && state_->okusan_fds_clear_fault) {
        state_->okusan_fds_clear_fault();
    }
}

int FamicomCore::triggerRandomFdsFault() {
    if (!state_->loaded || !state_->okusan_fds_trigger_random_fault) return 0;
    return state_->okusan_fds_trigger_random_fault(static_cast<uint32_t>(arc4random()));
}

bool FamicomCore::saveFdsDiskDiff(const std::string &savePath) const {
    if (!state_->loaded || !state_->okusan_fds_get_side_ptr || !isFdsActive()) return false;
    const FdsDriveStatus status = fdsDriveStatus();
    if (status.totalSides <= 0 || status.totalSides > 8) return false;

    constexpr size_t kSideBytes = 65500;
    std::vector<uint8_t> diffBuf(kSideBytes);
    std::vector<uint8_t> payload;
    const char magic[8] = {'O', 'F', 'D', 'S', 'D', 'I', 'F', 'F'};
    payload.insert(payload.end(), magic, magic + 8);
    const uint32_t sideCount = static_cast<uint32_t>(status.totalSides);
    payload.push_back(static_cast<uint8_t>(sideCount & 0xFFu));
    payload.push_back(static_cast<uint8_t>((sideCount >> 8) & 0xFFu));
    payload.push_back(static_cast<uint8_t>((sideCount >> 16) & 0xFFu));
    payload.push_back(static_cast<uint8_t>((sideCount >> 24) & 0xFFu));

    bool anyDiff = false;
    for (int s = 0; s < status.totalSides; ++s) {
        const uint8_t *orig = nullptr;
        const uint8_t *cur = state_->okusan_fds_get_side_ptr(s, &orig);
        bool dirty = false;
        if (cur && orig) {
            for (size_t i = 0; i < kSideBytes; ++i) {
                const uint8_t d = cur[i] ^ orig[i];
                diffBuf[i] = d;
                if (d != 0) dirty = true;
            }
        }
        payload.push_back(dirty ? 1 : 0);
        if (dirty) {
            anyDiff = true;
            payload.insert(payload.end(), diffBuf.begin(), diffBuf.end());
        }
    }

    if (!anyDiff) return true;
    std::ofstream ofs(savePath, std::ios::binary);
    if (!ofs.is_open()) return false;
    ofs.write(reinterpret_cast<const char *>(payload.data()), static_cast<std::streamsize>(payload.size()));
    return ofs.good();
}

bool FamicomCore::loadFdsDiskDiff(const std::string &savePath) {
    if (!state_->loaded || !state_->okusan_fds_get_side_ptr || !isFdsActive()) return false;
    std::ifstream ifs(savePath, std::ios::binary);
    if (!ifs.is_open()) return false;
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(ifs)), {});
    if (bytes.size() < 12 || std::memcmp(bytes.data(), "OFDSDIFF", 8) != 0) return false;

    const uint32_t sideCount = static_cast<uint32_t>(bytes[8]) |
                               (static_cast<uint32_t>(bytes[9]) << 8) |
                               (static_cast<uint32_t>(bytes[10]) << 16) |
                               (static_cast<uint32_t>(bytes[11]) << 24);
    const FdsDriveStatus status = fdsDriveStatus();
    if (sideCount == 0 || sideCount > static_cast<uint32_t>(status.totalSides)) return false;

    constexpr size_t kSideBytes = 65500;
    size_t pos = 12;
    for (uint32_t s = 0; s < sideCount; ++s) {
        if (pos >= bytes.size()) return false;
        const uint8_t dirty = bytes[pos++];
        if (dirty) {
            if (pos + kSideBytes > bytes.size()) return false;
            const uint8_t *orig = nullptr;
            uint8_t *cur = state_->okusan_fds_get_side_ptr(static_cast<int>(s), &orig);
            if (cur && orig) {
                for (size_t i = 0; i < kSideBytes; ++i) {
                    cur[i] = orig[i] ^ bytes[pos + i];
                }
            }
            pos += kSideBytes;
        }
    }
    return true;
}

void FamicomCore::runFrame(uint32_t pad1Mask, const AudioFrameSink &audioSink) {
    if (!state_->loaded) return;
    CoreState::activeInstance = state_;
    state_->pad1Buttons = pad1Mask;
    state_->audioSink = audioSink;
    state_->retro_run();
}

void FamicomCore::reset() {
    if (state_->loaded && state_->retro_reset) {
        CoreState::activeInstance = state_;
        state_->retro_reset();
    }
}

bool FamicomCore::saveState(const std::string &path) const {
    if (!state_->loaded || !state_->retro_serialize_size || !state_->retro_serialize) return false;
    const size_t size = state_->retro_serialize_size();
    if (size == 0) return false;

    std::vector<uint8_t> buffer(size);
    if (!state_->retro_serialize(buffer.data(), size)) return false;

    std::ofstream out(path, std::ios::binary);
    if (!out.is_open()) return false;
    out.write(reinterpret_cast<const char *>(buffer.data()), static_cast<std::streamsize>(size));
    return out.good();
}

bool FamicomCore::loadState(const std::string &path) {
    if (!state_->loaded || !state_->retro_unserialize) return false;

    std::ifstream in(path, std::ios::binary);
    if (!in.is_open()) return false;
    std::vector<uint8_t> buffer((std::istreambuf_iterator<char>(in)), {});
    if (buffer.empty()) return false;
    return state_->retro_unserialize(buffer.data(), buffer.size());
}
