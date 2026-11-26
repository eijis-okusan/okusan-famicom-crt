#include "audio/MacAudioEngine.hpp"

#include <AudioToolbox/AudioToolbox.h>

struct MacAudioEngine::Impl {
    AudioComponentInstance audioUnit = nullptr;
    AudioPipeline *pipeline = nullptr;

    static OSStatus audioRenderCallback(void *userData,
                                        AudioUnitRenderActionFlags * /*flags*/,
                                        const AudioTimeStamp * /*timestamp*/,
                                        UInt32 /*busNumber*/,
                                        UInt32 frameCount,
                                        AudioBufferList *ioData) {
        auto *self = static_cast<Impl *>(userData);
        auto *out = static_cast<float *>(ioData->mBuffers[0].mData);
        self->pipeline->pullOutputSamples(out, static_cast<size_t>(frameCount));
        return noErr;
    }
};

MacAudioEngine::MacAudioEngine() : impl_(new Impl()) {
    impl_->pipeline = &pipeline_;
}

MacAudioEngine::~MacAudioEngine() {
    stop();
    delete impl_;
}

bool MacAudioEngine::start(double sampleRate) {
    stop();
    pipeline_.reset(sampleRate);

    AudioComponentDescription desc{};
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_DefaultOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;

    AudioComponent component = AudioComponentFindNext(nullptr, &desc);
    if (!component) return false;
    if (AudioComponentInstanceNew(component, &impl_->audioUnit) != noErr) return false;

    AudioStreamBasicDescription streamFmt{};
    streamFmt.mSampleRate = sampleRate;
    streamFmt.mFormatID = kAudioFormatLinearPCM;
    streamFmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    streamFmt.mBytesPerPacket = sizeof(float) * 2;
    streamFmt.mFramesPerPacket = 1;
    streamFmt.mBytesPerFrame = sizeof(float) * 2;
    streamFmt.mChannelsPerFrame = 2;
    streamFmt.mBitsPerChannel = 32;

    if (AudioUnitSetProperty(impl_->audioUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input,
                             0,
                             &streamFmt,
                             sizeof(streamFmt)) != noErr) {
        stop();
        return false;
    }

    AURenderCallbackStruct callback{};
    callback.inputProc = Impl::audioRenderCallback;
    callback.inputProcRefCon = impl_;
    if (AudioUnitSetProperty(impl_->audioUnit,
                             kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input,
                             0,
                             &callback,
                             sizeof(callback)) != noErr) {
        stop();
        return false;
    }

    if (AudioUnitInitialize(impl_->audioUnit) != noErr) {
        stop();
        return false;
    }
    if (AudioOutputUnitStart(impl_->audioUnit) != noErr) {
        stop();
        return false;
    }
    return true;
}

void MacAudioEngine::stop() {
    if (impl_->audioUnit) {
        AudioOutputUnitStop(impl_->audioUnit);
        AudioUnitUninitialize(impl_->audioUnit);
        AudioComponentInstanceDispose(impl_->audioUnit);
        impl_->audioUnit = nullptr;
    }
    pipeline_.clearRing();
}

void MacAudioEngine::pushFrames(const int16_t *interleavedStereo, size_t frameCount) {
    if (!interleavedStereo) return;
    pipeline_.pushSamples(interleavedStereo, frameCount, false);
}

void MacAudioEngine::pushSilenceFrames(size_t frameCount) {
    pipeline_.pushSamples(nullptr, frameCount, false);
}

void MacAudioEngine::pushFrozenFrames(size_t frameCount) {
    pipeline_.pushSamples(nullptr, frameCount, true);
}

void MacAudioEngine::setMuted(bool muted) {
    pipeline_.setMuted(muted);
}

void MacAudioEngine::setTvAudioProfile(TvAudioProfile profile, float rfSnow, float rfSignal) {
    pipeline_.setTvAudioProfile(profile, rfSnow, rfSignal);
}

void MacAudioEngine::setCartridgeAudioGain(float gain) {
    pipeline_.setCartridgeAudioGain(gain);
}

void MacAudioEngine::updateScreenMetrics(const uint32_t *xrgbPixels, unsigned width, unsigned height) {
    pipeline_.updateScreenMetrics(xrgbPixels, width, height);
}

void MacAudioEngine::setConsolePowered(bool on) {
    pipeline_.setConsolePowered(on);
}

void MacAudioEngine::setResetHeld(bool held) {
    pipeline_.setResetHeld(held);
}

void MacAudioEngine::setFrozen(bool frozen, FreezeStyle style, uint32_t seed) {
    pipeline_.setFrozen(frozen, style, seed);
}
