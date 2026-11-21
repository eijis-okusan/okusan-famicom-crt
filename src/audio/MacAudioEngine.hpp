#pragma once

#include <cstddef>
#include <cstdint>

enum class FreezeStyle : int {
    CleanTone = 0,
    MachineGunStutter,
    PaletteCorruption,
    VramGarbage,
    SolidScreenOut,
    VoltageSagDrain,
    Count
};

/**
 * CoreAudio output stream fed from the emulation thread through a lock-free
 * ring buffer, with integrated TV speaker DSP and cartridge-freeze waveform synthesis.
 */
class MacAudioEngine {
public:
    MacAudioEngine();
    ~MacAudioEngine();

    MacAudioEngine(const MacAudioEngine &) = delete;
    MacAudioEngine &operator=(const MacAudioEngine &) = delete;

    bool start(double sampleRate);
    void stop();

    void pushFrames(const int16_t *interleavedStereo, size_t frameCount);
    void pushSilenceFrames(size_t frameCount);
    void pushFrozenFrames(size_t frameCount);

    void setMuted(bool muted);
    bool isMuted() const { return muted_; }

    void setRfTvMode(bool enabled, float rfSnow, float rfSignal);
    void setCartridgeAudioGain(float gain);
    void updateScreenMetrics(const uint32_t *xrgbPixels, unsigned width, unsigned height);
    void setConsolePowered(bool on);
    void setResetHeld(bool held);
    void setFrozen(bool frozen, FreezeStyle style = FreezeStyle::CleanTone, uint32_t seed = 0);

    size_t queuedFrames() const;
    size_t targetBufferFrames() const { return targetFrames_; }

private:
    struct RingState;
    RingState *ring_;
    bool muted_ = false;
    size_t targetFrames_ = 2048;
};
