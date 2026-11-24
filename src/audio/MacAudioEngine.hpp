#pragma once

#include <cstddef>
#include <cstdint>

#include "audio/AudioPipeline.hpp"
#include "common/FamicomTypes.hpp"

/**
 * macOS CoreAudio (AudioUnit) output driver backed by the portable `AudioPipeline`
 * DSP + lock-free ring buffer.
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
    bool isMuted() const { return pipeline_.isMuted(); }

    void setRfTvMode(bool enabled, float rfSnow, float rfSignal);
    void setCartridgeAudioGain(float gain);
    void updateScreenMetrics(const uint32_t *xrgbPixels, unsigned width, unsigned height);
    void setConsolePowered(bool on);
    void setResetHeld(bool held);
    void setFrozen(bool frozen, FreezeStyle style = FreezeStyle::CleanTone, uint32_t seed = 0);

    size_t queuedFrames() const { return pipeline_.queuedFrames(); }
    size_t targetBufferFrames() const { return pipeline_.targetBufferFrames(); }

private:
    struct Impl;
    Impl *impl_;
    AudioPipeline pipeline_;
};
