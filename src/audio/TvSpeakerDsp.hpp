#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace crt_audio {

// Direct Form II Transposed biquad filter for the TV speaker EQ and RF static shaping.
struct BiquadFilter {
    float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f;
    float a1 = 0.0f, a2 = 0.0f;
    float z1 = 0.0f, z2 = 0.0f;

    void reset() {
        z1 = 0.0f;
        z2 = 0.0f;
    }

    float process(float x) {
        const float y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        // Flush denormals to avoid CPU spikes during silent passages.
        if (std::abs(z1) < 1e-20f) z1 = 0.0f;
        if (std::abs(z2) < 1e-20f) z2 = 0.0f;
        return y;
    }

    void setHighPass(double sampleRate, double cutoffHz, double q) {
        const double w0 = 2.0 * M_PI * cutoffHz / sampleRate;
        const double cosw = std::cos(w0);
        const double alpha = std::sin(w0) / (2.0 * q);
        const double a0 = 1.0 + alpha;
        b0 = static_cast<float>(((1.0 + cosw) * 0.5) / a0);
        b1 = static_cast<float>(-(1.0 + cosw) / a0);
        b2 = b0;
        a1 = static_cast<float>((-2.0 * cosw) / a0);
        a2 = static_cast<float>((1.0 - alpha) / a0);
    }

    void setLowPass(double sampleRate, double cutoffHz, double q) {
        const double w0 = 2.0 * M_PI * cutoffHz / sampleRate;
        const double cosw = std::cos(w0);
        const double alpha = std::sin(w0) / (2.0 * q);
        const double a0 = 1.0 + alpha;
        b0 = static_cast<float>(((1.0 - cosw) * 0.5) / a0);
        b1 = static_cast<float>((1.0 - cosw) / a0);
        b2 = b0;
        a1 = static_cast<float>((-2.0 * cosw) / a0);
        a2 = static_cast<float>((1.0 - alpha) / a0);
    }

    void setPeaking(double sampleRate, double centerHz, double q, double gainDb) {
        const double amp = std::pow(10.0, gainDb / 40.0);
        const double w0 = 2.0 * M_PI * centerHz / sampleRate;
        const double cosw = std::cos(w0);
        const double alpha = std::sin(w0) / (2.0 * q);
        const double a0 = 1.0 + alpha / amp;
        b0 = static_cast<float>((1.0 + alpha * amp) / a0);
        b1 = static_cast<float>((-2.0 * cosw) / a0);
        b2 = static_cast<float>((1.0 - alpha * amp) / a0);
        a1 = static_cast<float>((-2.0 * cosw) / a0);
        a2 = static_cast<float>((1.0 - alpha / amp) / a0);
    }
};

/**
 * Per-frame video summary sampled in vertical bands so bright text boxes or high-contrast
 * transitions leak realistically into the 4.5 MHz NTSC sound intercarrier ("intercarrier buzz").
 */
struct FrameLuminanceStats {
    static constexpr size_t kBandCount = 16;

    float avgLuma = 0.0f;
    float whitePeakLoad = 0.0f;
    float chromaLoad = 0.0f;
    float horizontalEdgeLoad = 0.0f;
    std::array<float, kBandCount> bandEnergy{};

    static FrameLuminanceStats fromXrgb8888(const uint32_t *pixels, unsigned width, unsigned height) {
        FrameLuminanceStats stats;
        if (!pixels || width == 0 || height == 0) return stats;

        double sumLuma = 0.0;
        double sumWhite = 0.0;
        double sumChroma = 0.0;
        double sumEdges = 0.0;
        unsigned sampleCount = 0;

        std::array<double, kBandCount> bandSum{};
        std::array<unsigned, kBandCount> bandSamples{};

        constexpr float inv255 = 1.0f / 255.0f;
        for (unsigned y = 0; y < height; y += 4) {
            const size_t band = std::min<size_t>(kBandCount - 1, (static_cast<size_t>(y) * kBandCount) / height);
            const uint32_t *row = pixels + static_cast<size_t>(y) * width;
            float prevLuma = 0.0f;

            for (unsigned x = 0; x < width; x += 4) {
                const uint32_t pixel = row[x];
                const float r = static_cast<float>((pixel >> 16) & 0xFFu) * inv255;
                const float g = static_cast<float>((pixel >> 8) & 0xFFu) * inv255;
                const float b = static_cast<float>(pixel & 0xFFu) * inv255;

                const float luma = 0.299f * r + 0.587f * g + 0.114f * b;
                const float maxChan = std::max({r, g, b});
                const float minChan = std::min({r, g, b});
                const float chroma = (maxChan - minChan) * (0.35f + 0.65f * luma);
                const float whiteExcess = std::max(0.0f, (luma - 0.62f) / 0.38f);
                const float edge = (x > 0) ? std::abs(luma - prevLuma) : 0.0f;
                prevLuma = luma;

                sumLuma += luma;
                sumWhite += whiteExcess;
                sumChroma += chroma;
                sumEdges += edge;
                ++sampleCount;

                bandSum[band] += 0.60f * whiteExcess + 0.45f * chroma + 0.55f * edge;
                ++bandSamples[band];
            }
        }

        if (sampleCount > 0) {
            const float invSamples = 1.0f / static_cast<float>(sampleCount);
            stats.avgLuma = static_cast<float>(sumLuma) * invSamples;
            stats.whitePeakLoad = std::clamp(static_cast<float>(sumWhite) * invSamples * 2.2f, 0.0f, 1.0f);
            stats.chromaLoad = std::clamp(static_cast<float>(sumChroma) * invSamples * 2.4f, 0.0f, 1.0f);
            stats.horizontalEdgeLoad = std::clamp(static_cast<float>(sumEdges) * invSamples * 3.5f, 0.0f, 1.0f);
        }
        for (size_t i = 0; i < kBandCount; ++i) {
            if (bandSamples[i] > 0) {
                stats.bandEnergy[i] = std::clamp(static_cast<float>(bandSum[i] / bandSamples[i]) * 2.0f, 0.0f, 1.0f);
            }
        }
        return stats;
    }
};

/**
 * Models the audio path of a small 1980s monaural 14-inch CRT television connected
 * over VHF RF: narrow paper-cone speaker EQ, screen-modulated 60 Hz buzz, FM hiss,
 * standby snow static when unpowered, and de-clicked power/reset gates.
 */
class TvSpeakerDsp {
public:
    TvSpeakerDsp() { configure(48000.0); }

    void configure(double sampleRate) {
        sampleRate_ = std::max(sampleRate, 8000.0);

        // Two cascaded 580 Hz HPFs + two 2850 Hz LPFs mimic a small paper cone in a plastic bezel;
        // the 740 Hz scoop and 1650 Hz peak reproduce that characteristic nasal TV mid-range.
        hpfStage1_.setHighPass(sampleRate_, 580.0, 0.72);
        hpfStage2_.setHighPass(sampleRate_, 580.0, 0.72);
        hollowDip_.setPeaking(sampleRate_, 740.0, 0.90, -4.5);
        coneResonance_.setPeaking(sampleRate_, 1650.0, 1.95, +6.5);
        lpfStage1_.setLowPass(sampleRate_, 2850.0, 0.75);
        lpfStage2_.setLowPass(sampleRate_, 2850.0, 0.75);

        // Band-limit RF FM demodulator hiss and open-tuner standby snow.
        hissLpf_.setLowPass(sampleRate_, 3500.0, 0.707);
        tunerSnowHpf_.setHighPass(sampleRate_, 380.0, 0.707);
        tunerSnowLpf_.setLowPass(sampleRate_, 6200.0, 0.707);

        hpfStage1_.reset();
        hpfStage2_.reset();
        hollowDip_.reset();
        coneResonance_.reset();
        lpfStage1_.reset();
        lpfStage2_.reset();
        hissLpf_.reset();
        tunerSnowHpf_.reset();
        tunerSnowLpf_.reset();

        syncPhase_ = 0.0;
        humPhase_ = 0.0;
        buzzEnvelope_ = 0.0f;
        bandEnvelope_ = 0.0f;
        rfWetMix_ = 0.0f;
        consolePowered_ = true;
        powerGate_ = 1.0f;
        resetHeld_ = false;
        resetGate_ = 1.0f;
        heldSampleL_ = 0.0f;
        heldSampleR_ = 0.0f;
    }

    void setConsolePowered(bool on) { consolePowered_ = on; }
    void setResetHeld(bool held) { resetHeld_ = held; }

    void processStereoSample(float inL, float inR,
                             bool rfEnabled, float rfSnow, float rfSignal,
                             const FrameLuminanceStats &videoStats,
                             float &outL, float &outR) {
        // Exponential/linear short ramps prevent DC pop when toggling POWER (20 ms) or holding RESET (8 ms).
        const float targetPowerGate = consolePowered_ ? 1.0f : 0.0f;
        const float powerStep = 1.0f / static_cast<float>(sampleRate_ * 0.020);
        if (powerGate_ < targetPowerGate) powerGate_ = std::min(targetPowerGate, powerGate_ + powerStep);
        else if (powerGate_ > targetPowerGate) powerGate_ = std::max(targetPowerGate, powerGate_ - powerStep);

        const float targetResetGate = resetHeld_ ? 0.0f : 1.0f;
        const float resetStep = 1.0f / static_cast<float>(sampleRate_ * 0.008);
        if (resetGate_ < targetResetGate) resetGate_ = std::min(targetResetGate, resetGate_ + resetStep);
        else if (resetGate_ > targetResetGate) resetGate_ = std::max(targetResetGate, resetGate_ - resetStep);

        const bool gameRunning = consolePowered_ && !resetHeld_;
        if (gameRunning) {
            heldSampleL_ = inL;
            heldSampleR_ = inR;
        } else {
            heldSampleL_ *= 0.995f;
            heldSampleR_ *= 0.995f;
        }

        const float gatedL = (gameRunning ? inL : heldSampleL_) * (powerGate_ * resetGate_);
        const float gatedR = (gameRunning ? inR : heldSampleR_) * (powerGate_ * resetGate_);

        // 12 ms crossfade when switching RGB <-> RF monitor presets.
        const float targetWet = rfEnabled ? 1.0f : 0.0f;
        const float mixStep = 1.0f / static_cast<float>(sampleRate_ * 0.012);
        if (rfWetMix_ < targetWet) rfWetMix_ = std::min(targetWet, rfWetMix_ + mixStep);
        else if (rfWetMix_ > targetWet) rfWetMix_ = std::max(targetWet, rfWetMix_ - mixStep);

        if (rfWetMix_ <= 0.0001f) {
            outL = gatedL;
            outR = gatedR;
            return;
        }

        const float mono = 0.5f * (gatedL + gatedR);

        // Advance NTSC 59.94 Hz vertical sweep to sample per-band video load into the sound carrier.
        syncPhase_ += 59.94 / sampleRate_;
        if (syncPhase_ >= 1.0) syncPhase_ -= 1.0;
        const float fieldPos = static_cast<float>(syncPhase_);

        const size_t bandIndex = std::min<size_t>(FrameLuminanceStats::kBandCount - 1,
                                                  static_cast<size_t>(fieldPos * FrameLuminanceStats::kBandCount));
        const float bandTarget = consolePowered_ ? videoStats.bandEnergy[bandIndex] : 0.0f;
        bandEnvelope_ += (bandTarget - bandEnvelope_) * 0.045f;

        const float totalVideoDrive = consolePowered_
            ? std::clamp(0.35f * videoStats.avgLuma + 0.55f * videoStats.whitePeakLoad +
                             0.45f * videoStats.chromaLoad + 0.30f * videoStats.horizontalEdgeLoad,
                         0.0f, 1.35f)
            : 0.0f;
        buzzEnvelope_ += (totalVideoDrive - buzzEnvelope_) * 0.0025f;

        const float vSyncPulse = std::exp(-fieldPos * 38.0f) - 0.58f * std::exp(-fieldPos * 165.0f);
        const float fieldSawtooth = 0.5f - fieldPos;
        const float omega = static_cast<float>(2.0 * M_PI) * fieldPos;
        const float carrierHarmonics = 0.38f * std::sin(12.0f * omega)
                                     + 0.36f * std::sin(18.0f * omega)
                                     + 0.28f * std::sin(26.0f * omega);
        const float videoBuzz = std::max(0.0f, bandEnvelope_) * (0.35f + 0.65f * carrierHarmonics);

        humPhase_ += 120.0 / sampleRate_;
        if (humPhase_ >= 1.0) humPhase_ -= 1.0;
        const float powerHum = std::sin(static_cast<float>(2.0 * M_PI * humPhase_));

        const float whiteNoise = nextNoiseSample();
        const float demodHiss = hissLpf_.process(whiteNoise);

        const float snowScale = std::clamp(0.65f + 0.35f * rfSnow, 0.35f, 1.8f);
        const float signalScale = std::clamp(0.70f + 0.30f * rfSignal, 0.45f, 1.6f);
        const float buzzScale = (0.45f + 1.25f * buzzEnvelope_) * powerGate_;
        const float hissMasking = 1.08f - 0.28f * std::clamp(buzzEnvelope_, 0.0f, 1.0f);

        const float baseBuzz = (0.024f * vSyncPulse + 0.0075f * fieldSawtooth) * buzzScale;
        const float rfInterference =
            (baseBuzz + 0.020f * videoBuzz * powerGate_ + 0.0025f * powerHum * powerGate_) * signalScale +
            (0.0068f * demodHiss * hissMasking) * snowScale * powerGate_;

        float speakerOut = mono + rfInterference;
        speakerOut = hpfStage1_.process(speakerOut);
        speakerOut = hpfStage2_.process(speakerOut);
        speakerOut = hollowDip_.process(speakerOut);
        speakerOut = coneResonance_.process(speakerOut);
        speakerOut = lpfStage1_.process(speakerOut);
        speakerOut = lpfStage2_.process(speakerOut);
        speakerOut = std::tanh(speakerOut * 1.48f) * 0.85f;

        // Open-tuner snow fades in inversely with consoleGate when powered off or browned out.
        const float tunerSnow = tunerSnowLpf_.process(tunerSnowHpf_.process(whiteNoise)) * (0.036f * snowScale);
        speakerOut += tunerSnow * (1.0f - powerGate_);

        if (rfWetMix_ >= 0.9999f) {
            outL = speakerOut;
            outR = speakerOut;
        } else {
            outL = gatedL * (1.0f - rfWetMix_) + speakerOut * rfWetMix_;
            outR = gatedR * (1.0f - rfWetMix_) + speakerOut * rfWetMix_;
        }
    }

private:
    float nextNoiseSample() {
        rngState_ ^= rngState_ << 13;
        rngState_ ^= rngState_ >> 17;
        rngState_ ^= rngState_ << 5;
        return static_cast<float>(static_cast<int32_t>(rngState_)) * (1.0f / 2147483648.0f);
    }

    double sampleRate_ = 48000.0;
    BiquadFilter hpfStage1_;
    BiquadFilter hpfStage2_;
    BiquadFilter hollowDip_;
    BiquadFilter coneResonance_;
    BiquadFilter lpfStage1_;
    BiquadFilter lpfStage2_;
    BiquadFilter hissLpf_;
    BiquadFilter tunerSnowHpf_;
    BiquadFilter tunerSnowLpf_;

    double syncPhase_ = 0.0;
    double humPhase_ = 0.0;
    float buzzEnvelope_ = 0.0f;
    float bandEnvelope_ = 0.0f;
    uint32_t rngState_ = 0x6D2B79F5u;
    float rfWetMix_ = 0.0f;

    bool consolePowered_ = true;
    float powerGate_ = 1.0f;
    bool resetHeld_ = false;
    float resetGate_ = 1.0f;
    float heldSampleL_ = 0.0f;
    float heldSampleR_ = 0.0f;
};

} // namespace crt_audio
