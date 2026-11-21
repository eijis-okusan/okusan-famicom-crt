#include "MacAudioEngine.hpp"
#include "TvSpeakerDsp.hpp"

#include <AudioToolbox/AudioToolbox.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <limits>
#include <vector>

struct MacAudioEngine::RingState {
    static constexpr size_t kFreezeHistoryFrames = 2048;
    static constexpr size_t kRingCapacityFrames = 16384;

    AudioComponentInstance audioUnit = nullptr;
    std::vector<float> ringBuffer; // Interleaved stereo float32
    std::atomic<size_t> readIndex{0};
    std::atomic<size_t> writeIndex{0};
    std::atomic<bool> muted{false};

    std::atomic<bool> rfEnabled{true};
    std::atomic<float> rfSnow{1.0f};
    std::atomic<float> rfSignal{1.0f};
    std::atomic<float> cartAudioGain{1.0f};
    float smoothedCartGain = 1.0f;

    crt_audio::FrameLuminanceStats videoStats;
    crt_audio::TvSpeakerDsp speakerDsp;

    // Circular history used to synthesize a realistic pitch-locked buzz when the console freezes.
    std::vector<float> recentL;
    std::vector<float> recentR;
    size_t recentWritePos = 0;
    size_t recentValidCount = 0;

    std::vector<float> freezeLoopL;
    std::vector<float> freezeLoopR;
    size_t freezeCursor = 0;
    FreezeStyle freezeStyle = FreezeStyle::CleanTone;
    uint32_t freezeSeed = 0;
    uint32_t freezeRng = 0x5A17C0DEu;
    size_t freezeSampleAge = 0;
    double freezeFracPos = 0.0;
    double sampleRateHz = 48000.0;

    uint32_t nextFreezeRand() {
        freezeRng ^= freezeRng << 13;
        freezeRng ^= freezeRng >> 17;
        freezeRng ^= freezeRng << 5;
        return freezeRng;
    }

    void captureFreezeWaveform(FreezeStyle style, uint32_t seed) {
        freezeCursor = 0;
        freezeStyle = style;
        freezeSeed = seed;
        freezeRng = seed ? seed : 0x5A17C0DEu;
        freezeSampleAge = 0;
        freezeFracPos = 0.0;

        if (recentValidCount < 256) {
            freezeLoopL.assign(1, 0.0f);
            freezeLoopR.assign(1, 0.0f);
            return;
        }

        const size_t count = recentValidCount;
        std::vector<float> linearL(count), linearR(count);
        const size_t oldest = (count == kFreezeHistoryFrames) ? recentWritePos : 0;
        for (size_t i = 0; i < count; ++i) {
            const size_t idx = (oldest + i) % kFreezeHistoryFrames;
            linearL[i] = recentL[idx];
            linearR[i] = recentR[idx];
        }

        float peak = 0.0f;
        const size_t tailLen = std::min<size_t>(count, 800);
        for (size_t i = count - tailLen; i < count; ++i) {
            peak = std::max(peak, std::max(std::abs(linearL[i]), std::abs(linearR[i])));
        }

        if (style == FreezeStyle::MachineGunStutter) {
            // Grab ~28-56 ms verbatim without zero-cross smoothing for choppy CPU-loop stutter.
            const size_t minStut = std::min<size_t>(count, static_cast<size_t>(sampleRateHz * 0.028));
            const size_t maxStut = std::min<size_t>(count, static_cast<size_t>(sampleRateHz * 0.056));
            const size_t span = std::max<size_t>(1, maxStut - minStut);
            const size_t stutLen = std::max<size_t>(256, minStut + (nextFreezeRand() % span));
            const size_t start = count - stutLen;
            freezeLoopL.assign(linearL.begin() + static_cast<ptrdiff_t>(start), linearL.end());
            freezeLoopR.assign(linearR.begin() + static_cast<ptrdiff_t>(start), linearR.end());
            if (peak < 0.008f) {
                for (size_t i = 0; i < stutLen; ++i) {
                    const float env = (i < stutLen / 3) ? 0.065f : 0.0f;
                    const float buzz = ((i / 90) & 1u) ? env : -env;
                    freezeLoopL[i] += buzz;
                    freezeLoopR[i] += buzz;
                }
            }
            return;
        }

        if (style == FreezeStyle::VramGarbage) {
            const size_t sliceLen = std::min<size_t>(count, 170 + (nextFreezeRand() % 180));
            const size_t start = count - sliceLen;
            freezeLoopL.assign(linearL.begin() + static_cast<ptrdiff_t>(start), linearL.end());
            freezeLoopR.assign(linearR.begin() + static_cast<ptrdiff_t>(start), linearR.end());
            if (peak < 0.008f) {
                for (size_t i = 0; i < sliceLen; ++i) {
                    const float square = (i < sliceLen / 2) ? 0.048f : -0.048f;
                    freezeLoopL[i] = square;
                    freezeLoopR[i] = square;
                }
            }
            return;
        }

        if (peak < 0.004f) {
            if (style == FreezeStyle::PaletteCorruption) {
                const size_t buzzLen = std::max<size_t>(64, static_cast<size_t>(std::round(sampleRateHz / 120.0)));
                freezeLoopL.resize(buzzLen);
                freezeLoopR.resize(buzzLen);
                for (size_t i = 0; i < buzzLen; ++i) {
                    const float pulse = (i < buzzLen / 4) ? 0.055f : -0.025f;
                    freezeLoopL[i] = pulse;
                    freezeLoopR[i] = pulse;
                }
            } else {
                freezeLoopL.assign(1, 0.0f);
                freezeLoopR.assign(1, 0.0f);
            }
            return;
        }

        // Estimate dominant pitch period in [64..800] samples (~750..60 Hz) via AMDF.
        const size_t window = std::min<size_t>(256, count / 3);
        const size_t maxPeriod = std::min<size_t>(800, count - window - 8);
        size_t bestPeriod = std::min<size_t>(240, maxPeriod);
        double lowestError = std::numeric_limits<double>::max();

        for (size_t period = 64; period <= maxPeriod; ++period) {
            double error = 0.0;
            for (size_t j = 0; j < window; ++j) {
                const float cur = 0.5f * (linearL[count - 1 - j] + linearR[count - 1 - j]);
                const float lagged = 0.5f * (linearL[count - 1 - j - period] + linearR[count - 1 - j - period]);
                error += std::abs(cur - lagged);
            }
            // Slight penalty against multiples/subharmonics unless genuinely cleaner.
            error *= (1.0 + 0.00015 * static_cast<double>(period));
            if (error < lowestError) {
                lowestError = error;
                bestPeriod = period;
            }
        }

        // Align loop end to an upward zero-crossing to eliminate wraparound clicks.
        size_t loopEnd = count - 1;
        const size_t searchFloor = (count > bestPeriod + 32)
            ? std::max(count - 256, bestPeriod)
            : bestPeriod;
        for (size_t i = count - 2; i > searchFloor; --i) {
            const float prev = 0.5f * (linearL[i - 1] + linearR[i - 1]);
            const float curr = 0.5f * (linearL[i] + linearR[i]);
            if (prev <= 0.0f && curr > 0.0f) {
                loopEnd = i;
                break;
            }
        }

        const size_t loopStart = (loopEnd >= bestPeriod) ? (loopEnd - bestPeriod) : 0;
        const size_t loopLen = std::max<size_t>(1, loopEnd - loopStart);
        freezeLoopL.assign(linearL.begin() + static_cast<ptrdiff_t>(loopStart),
                           linearL.begin() + static_cast<ptrdiff_t>(loopStart + loopLen));
        freezeLoopR.assign(linearR.begin() + static_cast<ptrdiff_t>(loopStart),
                           linearR.begin() + static_cast<ptrdiff_t>(loopStart + loopLen));

        // 4-sample micro-crossfade across the loop seam.
        const size_t seamSamples = std::min<size_t>(4, loopLen / 4);
        for (size_t i = 0; i < seamSamples; ++i) {
            const float alpha = static_cast<float>(i + 1) / static_cast<float>(seamSamples + 1);
            freezeLoopL[i] = freezeLoopL[loopLen - 1] * (1.0f - alpha) + freezeLoopL[i] * alpha;
            freezeLoopR[i] = freezeLoopR[loopLen - 1] * (1.0f - alpha) + freezeLoopR[i] * alpha;
        }
    }

    void pushSamples(const int16_t *interleavedStereo, size_t frameCount, bool useFreezeLoop) {
        if (frameCount == 0) return;

        const size_t r = readIndex.load(std::memory_order_acquire);
        const size_t w = writeIndex.load(std::memory_order_relaxed);
        const size_t used = (w >= r) ? (w - r) : (kRingCapacityFrames - r + w);
        const size_t freeFrames = kRingCapacityFrames - 1 - used;
        const size_t framesToWrite = std::min(frameCount, freeFrames);

        const bool rfOn = rfEnabled.load(std::memory_order_relaxed);
        const float snowLevel = rfSnow.load(std::memory_order_relaxed);
        const float signalLevel = rfSignal.load(std::memory_order_relaxed);
        const float targetGain = cartAudioGain.load(std::memory_order_relaxed);

        // Smooth cartridge SND IN/OUT contact attenuation over ~5 ms to prevent crackles while tilting.
        constexpr float gainAlpha = 0.0045f;
        constexpr float int16Scale = 1.0f / 32768.0f;

        for (size_t i = 0; i < framesToWrite; ++i) {
            smoothedCartGain += (targetGain - smoothedCartGain) * gainAlpha;
            float inL = 0.0f;
            float inR = 0.0f;

            if (useFreezeLoop && !freezeLoopL.empty()) {
                const size_t loopSize = freezeLoopL.size();
                if (freezeStyle == FreezeStyle::VoltageSagDrain && loopSize > 1) {
                    const double ageSec = static_cast<double>(freezeSampleAge) / std::max(sampleRateHz, 8000.0);
                    const double droop = std::min(1.0, ageSec / 2.4);
                    const double speed = 1.0 - 0.58 * droop;
                    const float gain = static_cast<float>(1.0 - 0.85 * droop);
                    const size_t i0 = static_cast<size_t>(freezeFracPos) % loopSize;
                    const size_t i1 = (i0 + 1) % loopSize;
                    const float frac = static_cast<float>(freezeFracPos - std::floor(freezeFracPos));
                    inL = (freezeLoopL[i0] * (1.0f - frac) + freezeLoopL[i1] * frac) * gain;
                    inR = (freezeLoopR[i0] * (1.0f - frac) + freezeLoopR[i1] * frac) * gain;
                    if ((nextFreezeRand() & 1023u) < static_cast<uint32_t>(12 + droop * 28.0)) {
                        const float crackle = (static_cast<int32_t>(nextFreezeRand() & 255u) - 128) * 0.00055f;
                        inL += crackle;
                        inR += crackle;
                    }
                    freezeFracPos += speed;
                    if (freezeFracPos >= static_cast<double>(loopSize)) {
                        freezeFracPos -= static_cast<double>(loopSize) * std::floor(freezeFracPos / static_cast<double>(loopSize));
                    }
                    ++freezeSampleAge;
                } else {
                    size_t sampleIdx = freezeCursor;
                    if (freezeStyle == FreezeStyle::PaletteCorruption) {
                        sampleIdx = (freezeCursor / 3u) * 3u;
                        inL = std::clamp(freezeLoopL[sampleIdx] * 1.25f, -0.95f, 0.95f);
                        inR = std::clamp(freezeLoopR[sampleIdx] * 1.25f, -0.95f, 0.95f);
                    } else if (freezeStyle == FreezeStyle::VramGarbage) {
                        inL = freezeLoopL[sampleIdx];
                        inR = freezeLoopR[sampleIdx];
                        if ((freezeSampleAge % 2900u) < 160u) {
                            inL *= 0.25f;
                            inR *= 0.25f;
                        }
                        ++freezeSampleAge;
                    } else {
                        inL = freezeLoopL[sampleIdx];
                        inR = freezeLoopR[sampleIdx];
                    }
                    freezeCursor = (freezeCursor + 1) % loopSize;
                }
            } else if (interleavedStereo) {
                inL = static_cast<float>(interleavedStereo[i * 2 + 0]) * int16Scale * smoothedCartGain;
                inR = static_cast<float>(interleavedStereo[i * 2 + 1]) * int16Scale * smoothedCartGain;
                recentL[recentWritePos] = inL;
                recentR[recentWritePos] = inR;
                recentWritePos = (recentWritePos + 1) % kFreezeHistoryFrames;
                if (recentValidCount < kFreezeHistoryFrames) ++recentValidCount;
            }

            float outL = inL;
            float outR = inR;
            speakerDsp.processStereoSample(inL, inR, rfOn, snowLevel, signalLevel, videoStats, outL, outR);
            const size_t dst = ((w + i) % kRingCapacityFrames) * 2;
            ringBuffer[dst + 0] = outL;
            ringBuffer[dst + 1] = outR;
        }
        writeIndex.store((w + framesToWrite) % kRingCapacityFrames, std::memory_order_release);
    }

    static OSStatus audioRenderCallback(void *userData,
                                        AudioUnitRenderActionFlags * /*flags*/,
                                        const AudioTimeStamp * /*timestamp*/,
                                        UInt32 /*busNumber*/,
                                        UInt32 frameCount,
                                        AudioBufferList *ioData) {
        auto *self = static_cast<RingState *>(userData);
        float *out = static_cast<float *>(ioData->mBuffers[0].mData);
        const size_t requested = frameCount;

        const size_t r = self->readIndex.load(std::memory_order_relaxed);
        const size_t w = self->writeIndex.load(std::memory_order_acquire);
        const size_t available = (w >= r) ? (w - r) : (kRingCapacityFrames - r + w);

        if (self->muted.load(std::memory_order_relaxed) || available == 0) {
            std::fill(out, out + requested * 2, 0.0f);
            if (available > 0) {
                const size_t discard = std::min(available, requested);
                self->readIndex.store((r + discard) % kRingCapacityFrames, std::memory_order_release);
            }
            return noErr;
        }

        const size_t toRead = std::min(available, requested);
        for (size_t i = 0; i < toRead; ++i) {
            const size_t src = ((r + i) % kRingCapacityFrames) * 2;
            out[i * 2 + 0] = self->ringBuffer[src + 0];
            out[i * 2 + 1] = self->ringBuffer[src + 1];
        }
        if (toRead < requested) {
            std::fill(out + toRead * 2, out + requested * 2, 0.0f);
        }
        self->readIndex.store((r + toRead) % kRingCapacityFrames, std::memory_order_release);
        return noErr;
    }
};

MacAudioEngine::MacAudioEngine() : ring_(new RingState()) {
    ring_->ringBuffer.assign(RingState::kRingCapacityFrames * 2, 0.0f);
    ring_->recentL.assign(RingState::kFreezeHistoryFrames, 0.0f);
    ring_->recentR.assign(RingState::kFreezeHistoryFrames, 0.0f);
}

MacAudioEngine::~MacAudioEngine() {
    stop();
    delete ring_;
}

bool MacAudioEngine::start(double sampleRate) {
    stop();
    ring_->sampleRateHz = sampleRate;
    // Keep ~52 ms queued ahead to absorb AppKit key-repeat cadence jitter when holding tilt keys.
    targetFrames_ = static_cast<size_t>(sampleRate * 0.052);
    ring_->smoothedCartGain = ring_->cartAudioGain.load(std::memory_order_relaxed);
    ring_->speakerDsp.configure(sampleRate);

    AudioComponentDescription desc{};
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_DefaultOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;

    AudioComponent component = AudioComponentFindNext(nullptr, &desc);
    if (!component) return false;
    if (AudioComponentInstanceNew(component, &ring_->audioUnit) != noErr) return false;

    AudioStreamBasicDescription streamFmt{};
    streamFmt.mSampleRate = sampleRate;
    streamFmt.mFormatID = kAudioFormatLinearPCM;
    streamFmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    streamFmt.mBytesPerPacket = sizeof(float) * 2;
    streamFmt.mFramesPerPacket = 1;
    streamFmt.mBytesPerFrame = sizeof(float) * 2;
    streamFmt.mChannelsPerFrame = 2;
    streamFmt.mBitsPerChannel = 32;

    if (AudioUnitSetProperty(ring_->audioUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input,
                             0,
                             &streamFmt,
                             sizeof(streamFmt)) != noErr) {
        stop();
        return false;
    }

    AURenderCallbackStruct callback{};
    callback.inputProc = RingState::audioRenderCallback;
    callback.inputProcRefCon = ring_;
    if (AudioUnitSetProperty(ring_->audioUnit,
                             kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input,
                             0,
                             &callback,
                             sizeof(callback)) != noErr) {
        stop();
        return false;
    }

    if (AudioUnitInitialize(ring_->audioUnit) != noErr) {
        stop();
        return false;
    }
    if (AudioOutputUnitStart(ring_->audioUnit) != noErr) {
        stop();
        return false;
    }
    return true;
}

void MacAudioEngine::stop() {
    if (ring_->audioUnit) {
        AudioOutputUnitStop(ring_->audioUnit);
        AudioUnitUninitialize(ring_->audioUnit);
        AudioComponentInstanceDispose(ring_->audioUnit);
        ring_->audioUnit = nullptr;
    }
    ring_->readIndex.store(0);
    ring_->writeIndex.store(0);
}

void MacAudioEngine::pushFrames(const int16_t *interleavedStereo, size_t frameCount) {
    if (!interleavedStereo) return;
    ring_->pushSamples(interleavedStereo, frameCount, false);
}

void MacAudioEngine::pushSilenceFrames(size_t frameCount) {
    ring_->pushSamples(nullptr, frameCount, false);
}

void MacAudioEngine::pushFrozenFrames(size_t frameCount) {
    ring_->pushSamples(nullptr, frameCount, true);
}

void MacAudioEngine::setMuted(bool muted) {
    muted_ = muted;
    ring_->muted.store(muted, std::memory_order_relaxed);
}

void MacAudioEngine::setRfTvMode(bool enabled, float rfSnow, float rfSignal) {
    ring_->rfEnabled.store(enabled, std::memory_order_relaxed);
    ring_->rfSnow.store(rfSnow, std::memory_order_relaxed);
    ring_->rfSignal.store(rfSignal, std::memory_order_relaxed);
}

void MacAudioEngine::setCartridgeAudioGain(float gain) {
    ring_->cartAudioGain.store(std::clamp(gain, 0.0f, 1.0f), std::memory_order_relaxed);
}

void MacAudioEngine::updateScreenMetrics(const uint32_t *xrgbPixels, unsigned width, unsigned height) {
    if (!ring_->rfEnabled.load(std::memory_order_relaxed)) return;
    ring_->videoStats = crt_audio::FrameLuminanceStats::fromXrgb8888(xrgbPixels, width, height);
}

void MacAudioEngine::setConsolePowered(bool on) {
    ring_->speakerDsp.setConsolePowered(on);
    if (!on) {
        ring_->speakerDsp.setResetHeld(false);
        ring_->recentValidCount = 0;
    }
}

void MacAudioEngine::setResetHeld(bool held) {
    ring_->speakerDsp.setResetHeld(held);
}

void MacAudioEngine::setFrozen(bool frozen, FreezeStyle style, uint32_t seed) {
    if (frozen) {
        ring_->captureFreezeWaveform(style, seed);
    } else {
        ring_->freezeCursor = 0;
        ring_->freezeFracPos = 0.0;
        ring_->freezeSampleAge = 0;
    }
}

size_t MacAudioEngine::queuedFrames() const {
    const size_t r = ring_->readIndex.load(std::memory_order_acquire);
    const size_t w = ring_->writeIndex.load(std::memory_order_acquire);
    return (w >= r) ? (w - r) : (RingState::kRingCapacityFrames - r + w);
}
