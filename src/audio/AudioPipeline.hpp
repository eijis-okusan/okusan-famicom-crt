#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "audio/TvSpeakerDsp.hpp"
#include "common/FamicomTypes.hpp"

/**
 * Pure C++17 portable audio mixing, ring buffering, Dynamic Rate Control (DRC),
 * TV speaker DSP, and hardware freeze waveform synthesizer.
 *
 * Designed so platform audio backends (CoreAudio on macOS, WASAPI/XAudio2 on Windows,
 * ALSA/PulseAudio/SDL2 on Linux) only wrap device lifecycle and call `pullOutputSamples()`.
 */
class AudioPipeline {
public:
    static constexpr size_t kFreezeHistoryFrames = 2048;
    static constexpr size_t kRingCapacityFrames = 16384;

    AudioPipeline();

    /// Prepares the ring buffer, DRC cursor, and DSP filter coefficients for `sampleRate` Hz.
    void reset(double sampleRate);

    /// Resets read/write indices when the audio output device stops.
    void clearRing();

    /// Pushes new emulator stereo frames, silence, or frozen APU loop samples into the ring buffer.
    void pushSamples(const int16_t *interleavedStereo, size_t frameCount, bool useFreezeLoop);

    /// Pulls `frameCount` interleaved stereo float32 frames on the real-time audio render thread.
    void pullOutputSamples(float *outInterleavedStereo, size_t frameCount);

    void setMuted(bool muted);
    bool isMuted() const { return muted_.load(std::memory_order_relaxed); }

    void setRfTvMode(bool enabled, float rfSnow, float rfSignal);
    void setCartridgeAudioGain(float gain);
    void updateScreenMetrics(const uint32_t *xrgbPixels, unsigned width, unsigned height);
    void setConsolePowered(bool on);
    void setResetHeld(bool held);
    void setFrozen(bool frozen, FreezeStyle style = FreezeStyle::CleanTone, uint32_t seed = 0);

    size_t queuedFrames() const;
    size_t targetBufferFrames() const { return targetBufferFrames_; }

private:
    uint32_t nextFreezeRand();
    void synthesizeFallbackFreezeBuzz(FreezeStyle style);
    size_t estimateDominantPeriodAmdf(const std::vector<float> &linearL,
                                      const std::vector<float> &linearR) const;
    void extractSeamlessPeriodLoop(const std::vector<float> &linearL,
                                   const std::vector<float> &linearR,
                                   size_t bestPeriod);
    void captureFreezeWaveform(FreezeStyle style, uint32_t seed);

    std::vector<float> ringBuffer_;
    std::atomic<size_t> readIndex_{0};
    std::atomic<size_t> writeIndex_{0};
    std::atomic<bool> muted_{false};

    std::atomic<bool> rfEnabled_{true};
    std::atomic<float> rfSnow_{1.0f};
    std::atomic<float> rfSignal_{1.0f};
    std::atomic<float> cartAudioGain_{1.0f};
    float smoothedCartGain_ = 1.0f;

    crt_audio::FrameLuminanceStats videoStats_;
    crt_audio::TvSpeakerDsp speakerDsp_;

    std::vector<float> recentL_;
    std::vector<float> recentR_;
    size_t recentWritePos_ = 0;
    size_t recentValidCount_ = 0;

    std::vector<float> freezeLoopL_;
    std::vector<float> freezeLoopR_;
    size_t freezeCursor_ = 0;
    FreezeStyle freezeStyle_ = FreezeStyle::CleanTone;
    uint32_t freezeSeed_ = 0;
    uint32_t freezeRng_ = 0x5A17C0DEu;
    size_t freezeSampleAge_ = 0;

    double sampleRateHz_ = 48000.0;
    size_t targetBufferFrames_ = 2496;
    double drcPos_ = 0.0;
    float prevRawL_ = 0.0f;
    float prevRawR_ = 0.0f;
    float lastRenderL_ = 0.0f;
    float lastRenderR_ = 0.0f;
};
