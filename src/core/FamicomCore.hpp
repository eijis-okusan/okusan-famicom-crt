#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

/**
 * Snapshot of electrical contact state and recent bus traffic for one pin
 * on the HVC-001 60-pin cartridge edge connector.
 */
struct CartPinReading {
    uint8_t  contactState = 0;  // Lower nibble: 0=OK, 1=Weak, 2=Marginal, 3=Open; bits 4..5: XTALK flags
    uint8_t  highDutyPct = 0;   // Observed percentage of samples at logic HIGH
    uint8_t  activity = 0;      // 0=static, 1=slow edge, 2=active bus traffic
    uint8_t  faultRatePct = 0;  // Observed bit-corruption percentage
    int16_t  edgeLiftUm = 0;    // Vertical displacement above seated baseline (micrometers)
    int16_t  overlapUm = 0;     // Spring-to-pad vertical overlap length (micrometers)
    uint16_t drivenWord = 0;    // Last word placed onto the bus before contact degradation
    uint16_t effectiveWord = 0; // Effective word seen by CPU/PPU after pin faults
};

/**
 * Wraps the modified libretro-fceumm shared library, owning the active ROM
 * instance, double-buffered XRGB8888 video frames, and 3-DOF cartridge pose API.
 */
class FamicomCore {
public:
    using AudioFrameSink = std::function<void(const int16_t *interleavedStereo, size_t frameCount)>;

    FamicomCore();
    ~FamicomCore();

    FamicomCore(const FamicomCore &) = delete;
    FamicomCore &operator=(const FamicomCore &) = delete;

    bool load(const std::string &coreLibraryPath,
              const std::string &romPath,
              const std::string &systemDir,
              const std::string &saveDir);
    void unload();
    bool isLoaded() const;

    void runFrame(uint32_t pad1Mask, const AudioFrameSink &audioSink);
    void reset();

    // Cartridge mechanical pose (tilt: -32..+32, lift: 0..16, pitch: -8..+8) & per-pin fault masks
    void setCartridgePose(int tilt, int lift, int pitch);
    void setPinFaultMasks(uint64_t weakMask, uint64_t openMask);
    void reseatCartridge();

    bool readPinTelemetry(int &tilt, int &lift, int &pitch, CartPinReading *outReadings, int maxPins) const;
    int  edgeLiftUm(int tilt, int lift, int xOffsetUm) const;
    int  lateralShiftUm(int tilt, int lift) const;
    float cartridgeAudioGain() const;
    bool isCartridgePowered() const;
    int  cartridgeVccMv() const;
    bool isCpuJammed() const;
    uint16_t cpuProgramCounter() const;

    bool saveState(const std::string &path) const;
    bool loadState(const std::string &path);

    unsigned width() const { return frameWidth_; }
    unsigned height() const { return frameHeight_; }
    double fps() const { return frameRate_; }
    double sampleRate() const { return sampleRate_; }
    const uint32_t *currentPixels() const { return currentFrame_.data(); }
    const uint32_t *previousPixels() const { return previousFrame_.data(); }

private:
    struct CoreState;
    CoreState *state_;
    unsigned frameWidth_ = 256;
    unsigned frameHeight_ = 240;
    double frameRate_ = 60.0988;
    double sampleRate_ = 48000.0;
    std::vector<uint32_t> currentFrame_;
    std::vector<uint32_t> previousFrame_;
};
