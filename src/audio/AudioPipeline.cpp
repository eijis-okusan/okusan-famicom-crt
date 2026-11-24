#include "audio/AudioPipeline.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

AudioPipeline::AudioPipeline()
    : ringBuffer_(kRingCapacityFrames * 2, 0.0f),
      recentL_(kFreezeHistoryFrames, 0.0f),
      recentR_(kFreezeHistoryFrames, 0.0f) {}

void AudioPipeline::reset(double sampleRate) {
    sampleRateHz_ = sampleRate;
    // Keep ~52 ms queued ahead to absorb UI key-repeat jitter while adjusting cartridge tilt.
    targetBufferFrames_ = static_cast<size_t>(sampleRate * 0.052);
    drcPos_ = 0.0;
    prevRawL_ = 0.0f;
    prevRawR_ = 0.0f;
    smoothedCartGain_ = cartAudioGain_.load(std::memory_order_relaxed);
    speakerDsp_.configure(sampleRate);
    lastRenderL_ = 0.0f;
    lastRenderR_ = 0.0f;

    const size_t prefill = std::min(targetBufferFrames_, kRingCapacityFrames / 2);
    std::fill(ringBuffer_.begin(), ringBuffer_.begin() + prefill * 2, 0.0f);
    readIndex_.store(0, std::memory_order_relaxed);
    writeIndex_.store(prefill, std::memory_order_release);
}

void AudioPipeline::clearRing() {
    readIndex_.store(0, std::memory_order_relaxed);
    writeIndex_.store(0, std::memory_order_relaxed);
}

uint32_t AudioPipeline::nextFreezeRand() {
    freezeRng_ ^= freezeRng_ << 13;
    freezeRng_ ^= freezeRng_ >> 17;
    freezeRng_ ^= freezeRng_ << 5;
    return freezeRng_;
}

void AudioPipeline::synthesizeFallbackFreezeBuzz(FreezeStyle style) {
    if (style == FreezeStyle::MachineGunStutter) {
        const size_t stutLen = std::max<size_t>(256, static_cast<size_t>(sampleRateHz_ * 0.036));
        freezeLoopL_.resize(stutLen);
        freezeLoopR_.resize(stutLen);
        for (size_t i = 0; i < stutLen; ++i) {
            const float env = (i < stutLen / 3) ? 0.065f : 0.0f;
            const float buzz = ((i / 90) & 1u) ? env : -env;
            freezeLoopL_[i] = buzz;
            freezeLoopR_[i] = buzz;
        }
        return;
    }

    if (style == FreezeStyle::VramGarbage) {
        const size_t sliceLen = 170 + (nextFreezeRand() % 180);
        freezeLoopL_.resize(sliceLen);
        freezeLoopR_.resize(sliceLen);
        for (size_t i = 0; i < sliceLen; ++i) {
            const float square = (i < sliceLen / 2) ? 0.048f : -0.048f;
            freezeLoopL_[i] = square;
            freezeLoopR_[i] = square;
        }
        return;
    }

    const double hz = (style == FreezeStyle::PaletteCorruption) ? 120.0 : 180.0;
    const size_t buzzLen = std::max<size_t>(64, static_cast<size_t>(std::round(sampleRateHz_ / hz)));
    freezeLoopL_.resize(buzzLen);
    freezeLoopR_.resize(buzzLen);
    for (size_t i = 0; i < buzzLen; ++i) {
        const float pulse = (i < buzzLen / 4) ? 0.055f : -0.025f;
        freezeLoopL_[i] = pulse;
        freezeLoopR_[i] = pulse;
    }
}

size_t AudioPipeline::estimateDominantPeriodAmdf(const std::vector<float> &linearL,
                                                 const std::vector<float> &linearR) const {
    const size_t count = linearL.size();
    const size_t window = std::min<size_t>(256, count / 3);
    const size_t maxPeriod = std::min<size_t>(800, count - window - 8);
    size_t bestPeriod = std::min<size_t>(240, maxPeriod);
    double lowestError = std::numeric_limits<double>::max();

    // Average Magnitude Difference Function over ~60..750 Hz finds the clean fundamental pitch.
    for (size_t period = 64; period <= maxPeriod; ++period) {
        double error = 0.0;
        for (size_t j = 0; j < window; ++j) {
            const float cur = 0.5f * (linearL[count - 1 - j] + linearR[count - 1 - j]);
            const float lagged = 0.5f * (linearL[count - 1 - j - period] + linearR[count - 1 - j - period]);
            error += std::abs(cur - lagged);
        }
        error *= (1.0 + 0.00015 * static_cast<double>(period));
        if (error < lowestError) {
            lowestError = error;
            bestPeriod = period;
        }
    }
    return bestPeriod;
}

void AudioPipeline::extractSeamlessPeriodLoop(const std::vector<float> &linearL,
                                              const std::vector<float> &linearR,
                                              size_t bestPeriod) {
    const size_t count = linearL.size();
    size_t loopEnd = count - 1;
    const size_t searchFloor = (count > bestPeriod + 32)
        ? std::max(count - 256, bestPeriod)
        : bestPeriod;

    // Snap the loop boundary to an upward zero-crossing so the sustained freeze hum does not click.
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
    freezeLoopL_.assign(linearL.begin() + static_cast<ptrdiff_t>(loopStart),
                        linearL.begin() + static_cast<ptrdiff_t>(loopStart + loopLen));
    freezeLoopR_.assign(linearR.begin() + static_cast<ptrdiff_t>(loopStart),
                        linearR.begin() + static_cast<ptrdiff_t>(loopStart + loopLen));

    const size_t seamSamples = std::min<size_t>(4, loopLen / 4);
    for (size_t i = 0; i < seamSamples; ++i) {
        const float alpha = static_cast<float>(i + 1) / static_cast<float>(seamSamples + 1);
        freezeLoopL_[i] = freezeLoopL_[loopLen - 1] * (1.0f - alpha) + freezeLoopL_[i] * alpha;
        freezeLoopR_[i] = freezeLoopR_[loopLen - 1] * (1.0f - alpha) + freezeLoopR_[i] * alpha;
    }
}

void AudioPipeline::captureFreezeWaveform(FreezeStyle style, uint32_t seed) {
    freezeCursor_ = 0;
    freezeStyle_ = style;
    freezeSeed_ = seed;
    freezeRng_ = seed ? seed : 0x5A17C0DEu;
    freezeSampleAge_ = 0;

    if (recentValidCount_ < 256) {
        synthesizeFallbackFreezeBuzz(style);
        return;
    }

    const size_t count = recentValidCount_;
    std::vector<float> linearL(count), linearR(count);
    const size_t oldest = (count == kFreezeHistoryFrames) ? recentWritePos_ : 0;
    for (size_t i = 0; i < count; ++i) {
        const size_t idx = (oldest + i) % kFreezeHistoryFrames;
        linearL[i] = recentL_[idx];
        linearR[i] = recentR_[idx];
    }

    float peak = 0.0f;
    const size_t tailLen = std::min<size_t>(count, 800);
    for (size_t i = count - tailLen; i < count; ++i) {
        peak = std::max(peak, std::max(std::abs(linearL[i]), std::abs(linearR[i])));
    }

    if (style == FreezeStyle::MachineGunStutter || style == FreezeStyle::VramGarbage) {
        size_t sliceLen = 0;
        if (style == FreezeStyle::MachineGunStutter) {
            const size_t minStut = std::min<size_t>(count, static_cast<size_t>(sampleRateHz_ * 0.028));
            const size_t maxStut = std::min<size_t>(count, static_cast<size_t>(sampleRateHz_ * 0.056));
            const size_t span = std::max<size_t>(1, maxStut - minStut);
            sliceLen = std::max<size_t>(256, minStut + (nextFreezeRand() % span));
        } else {
            sliceLen = std::min<size_t>(count, 170 + (nextFreezeRand() % 180));
        }
        const size_t start = count - sliceLen;
        freezeLoopL_.assign(linearL.begin() + static_cast<ptrdiff_t>(start), linearL.end());
        freezeLoopR_.assign(linearR.begin() + static_cast<ptrdiff_t>(start), linearR.end());
        if (peak < 0.008f) {
            synthesizeFallbackFreezeBuzz(style);
        }
        return;
    }

    if (peak < 0.004f) {
        if (style == FreezeStyle::PaletteCorruption) {
            synthesizeFallbackFreezeBuzz(style);
        } else {
            freezeLoopL_.assign(1, 0.0f);
            freezeLoopR_.assign(1, 0.0f);
        }
        return;
    }

    const size_t bestPeriod = estimateDominantPeriodAmdf(linearL, linearR);
    extractSeamlessPeriodLoop(linearL, linearR, bestPeriod);
}

void AudioPipeline::pushSamples(const int16_t *interleavedStereo, size_t frameCount, bool useFreezeLoop) {
    if (frameCount == 0) return;

    const size_t r = readIndex_.load(std::memory_order_acquire);
    const size_t w = writeIndex_.load(std::memory_order_relaxed);
    const size_t used = (w >= r) ? (w - r) : (kRingCapacityFrames - r + w);
    const size_t freeFrames = kRingCapacityFrames - 1 - used;

    const bool rfOn = rfEnabled_.load(std::memory_order_relaxed);
    const float snowLevel = rfSnow_.load(std::memory_order_relaxed);
    const float signalLevel = rfSignal_.load(std::memory_order_relaxed);
    const float targetGain = cartAudioGain_.load(std::memory_order_relaxed);

    // Smooth cartridge SND IN/OUT contact attenuation over ~5 ms to prevent crackles while tilting.
    constexpr float gainAlpha = 0.0045f;
    constexpr float int16Scale = 1.0f / 32768.0f;

    // Dynamic Rate Control (<= +-1.2%) locks audio queue fill level when display VSync-locked.
    const double err = static_cast<double>(used) - static_cast<double>(targetBufferFrames_);
    const double drcStep = std::clamp(1.0 + err / 60000.0, 0.988, 1.012);

    if (!useFreezeLoop && interleavedStereo) {
        for (size_t i = 0; i < frameCount; ++i) {
            const float rawL = static_cast<float>(interleavedStereo[i * 2 + 0]) * int16Scale;
            const float rawR = static_cast<float>(interleavedStereo[i * 2 + 1]) * int16Scale;
            recentL_[recentWritePos_] = rawL * smoothedCartGain_;
            recentR_[recentWritePos_] = rawR * smoothedCartGain_;
            recentWritePos_ = (recentWritePos_ + 1) % kFreezeHistoryFrames;
            if (recentValidCount_ < kFreezeHistoryFrames) ++recentValidCount_;
        }

        size_t written = 0;
        while (drcPos_ < static_cast<double>(frameCount) && written < freeFrames) {
            const size_t i0 = static_cast<size_t>(drcPos_);
            const float frac = static_cast<float>(drcPos_ - static_cast<double>(i0));
            const float sPrevL = (i0 == 0) ? prevRawL_ : static_cast<float>(interleavedStereo[(i0 - 1) * 2 + 0]) * int16Scale;
            const float sPrevR = (i0 == 0) ? prevRawR_ : static_cast<float>(interleavedStereo[(i0 - 1) * 2 + 1]) * int16Scale;
            const float sCurrL = static_cast<float>(interleavedStereo[i0 * 2 + 0]) * int16Scale;
            const float sCurrR = static_cast<float>(interleavedStereo[i0 * 2 + 1]) * int16Scale;

            smoothedCartGain_ += (targetGain - smoothedCartGain_) * gainAlpha;
            const float inL = (sPrevL + (sCurrL - sPrevL) * frac) * smoothedCartGain_;
            const float inR = (sPrevR + (sCurrR - sPrevR) * frac) * smoothedCartGain_;

            float outL = inL;
            float outR = inR;
            speakerDsp_.processStereoSample(inL, inR, rfOn, snowLevel, signalLevel, videoStats_, outL, outR);
            const size_t dst = ((w + written) % kRingCapacityFrames) * 2;
            ringBuffer_[dst + 0] = outL;
            ringBuffer_[dst + 1] = outR;
            ++written;
            drcPos_ += drcStep;
        }
        drcPos_ -= static_cast<double>(frameCount);
        if (drcPos_ < 0.0) drcPos_ = 0.0;
        prevRawL_ = static_cast<float>(interleavedStereo[(frameCount - 1) * 2 + 0]) * int16Scale;
        prevRawR_ = static_cast<float>(interleavedStereo[(frameCount - 1) * 2 + 1]) * int16Scale;
        writeIndex_.store((w + written) % kRingCapacityFrames, std::memory_order_release);
        return;
    }

    const size_t drcCount = static_cast<size_t>(std::llround(static_cast<double>(frameCount) / drcStep));
    const size_t framesToWrite = std::min(drcCount, freeFrames);
    drcPos_ = 0.0;
    prevRawL_ = 0.0f;
    prevRawR_ = 0.0f;

    for (size_t i = 0; i < framesToWrite; ++i) {
        smoothedCartGain_ += (targetGain - smoothedCartGain_) * gainAlpha;
        float inL = 0.0f;
        float inR = 0.0f;

        if (useFreezeLoop && !freezeLoopL_.empty()) {
            const size_t loopSize = freezeLoopL_.size();
            size_t sampleIdx = freezeCursor_;
            if (freezeStyle_ == FreezeStyle::PaletteCorruption) {
                sampleIdx = (freezeCursor_ / 3u) * 3u;
                inL = std::clamp(freezeLoopL_[sampleIdx] * 1.25f, -0.95f, 0.95f);
                inR = std::clamp(freezeLoopR_[sampleIdx] * 1.25f, -0.95f, 0.95f);
            } else if (freezeStyle_ == FreezeStyle::VramGarbage) {
                inL = freezeLoopL_[sampleIdx];
                inR = freezeLoopR_[sampleIdx];
                if ((freezeSampleAge_ % 2900u) < 160u) {
                    inL *= 0.25f;
                    inR *= 0.25f;
                }
                ++freezeSampleAge_;
            } else {
                inL = freezeLoopL_[sampleIdx];
                inR = freezeLoopR_[sampleIdx];
            }
            freezeCursor_ = (freezeCursor_ + 1) % loopSize;
        }

        float outL = inL;
        float outR = inR;
        speakerDsp_.processStereoSample(inL, inR, rfOn, snowLevel, signalLevel, videoStats_, outL, outR);
        const size_t dst = ((w + i) % kRingCapacityFrames) * 2;
        ringBuffer_[dst + 0] = outL;
        ringBuffer_[dst + 1] = outR;
    }
    writeIndex_.store((w + framesToWrite) % kRingCapacityFrames, std::memory_order_release);
}

void AudioPipeline::pullOutputSamples(float *outInterleavedStereo, size_t frameCount) {
    if (!outInterleavedStereo || frameCount == 0) return;

    const size_t r = readIndex_.load(std::memory_order_relaxed);
    const size_t w = writeIndex_.load(std::memory_order_acquire);
    const size_t available = (w >= r) ? (w - r) : (kRingCapacityFrames - r + w);

    if (muted_.load(std::memory_order_relaxed)) {
        lastRenderL_ = 0.0f;
        lastRenderR_ = 0.0f;
        std::fill(outInterleavedStereo, outInterleavedStereo + frameCount * 2, 0.0f);
        if (available > 0) {
            const size_t discard = std::min(available, frameCount);
            readIndex_.store((r + discard) % kRingCapacityFrames, std::memory_order_release);
        }
        return;
    }

    const size_t toRead = std::min(available, frameCount);
    for (size_t i = 0; i < toRead; ++i) {
        const size_t src = ((r + i) % kRingCapacityFrames) * 2;
        outInterleavedStereo[i * 2 + 0] = ringBuffer_[src + 0];
        outInterleavedStereo[i * 2 + 1] = ringBuffer_[src + 1];
    }
    if (toRead > 0) {
        lastRenderL_ = outInterleavedStereo[(toRead - 1) * 2 + 0];
        lastRenderR_ = outInterleavedStereo[(toRead - 1) * 2 + 1];
    }
    // Exponential underrun tail avoids hard step clicks if the producer lags by one frame.
    for (size_t i = toRead; i < frameCount; ++i) {
        lastRenderL_ *= 0.985f;
        lastRenderR_ *= 0.985f;
        outInterleavedStereo[i * 2 + 0] = lastRenderL_;
        outInterleavedStereo[i * 2 + 1] = lastRenderR_;
    }
    if (toRead > 0) {
        readIndex_.store((r + toRead) % kRingCapacityFrames, std::memory_order_release);
    }
}

void AudioPipeline::setMuted(bool muted) {
    muted_.store(muted, std::memory_order_relaxed);
}

void AudioPipeline::setRfTvMode(bool enabled, float rfSnow, float rfSignal) {
    rfEnabled_.store(enabled, std::memory_order_relaxed);
    rfSnow_.store(rfSnow, std::memory_order_relaxed);
    rfSignal_.store(rfSignal, std::memory_order_relaxed);
}

void AudioPipeline::setCartridgeAudioGain(float gain) {
    cartAudioGain_.store(std::clamp(gain, 0.0f, 1.0f), std::memory_order_relaxed);
}

void AudioPipeline::updateScreenMetrics(const uint32_t *xrgbPixels, unsigned width, unsigned height) {
    if (!rfEnabled_.load(std::memory_order_relaxed)) return;
    videoStats_ = crt_audio::FrameLuminanceStats::fromXrgb8888(xrgbPixels, width, height);
}

void AudioPipeline::setConsolePowered(bool on) {
    speakerDsp_.setConsolePowered(on);
    if (!on) {
        speakerDsp_.setResetHeld(false);
        recentValidCount_ = 0;
    }
}

void AudioPipeline::setResetHeld(bool held) {
    speakerDsp_.setResetHeld(held);
}

void AudioPipeline::setFrozen(bool frozen, FreezeStyle style, uint32_t seed) {
    if (frozen) {
        captureFreezeWaveform(style, seed);
    } else {
        freezeCursor_ = 0;
        freezeSampleAge_ = 0;
    }
}

size_t AudioPipeline::queuedFrames() const {
    const size_t r = readIndex_.load(std::memory_order_acquire);
    const size_t w = writeIndex_.load(std::memory_order_acquire);
    return (w >= r) ? (w - r) : (kRingCapacityFrames - r + w);
}
