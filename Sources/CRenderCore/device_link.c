// The AUHAL render callback, which joins a device to the engine.

#include "internal.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#define PR_INPUT_ELEMENT 1

struct PRDeviceLink {
    PREngine *engine;
    AudioUnit unit;
    uint32_t capacity; // frames per input channel
    uint32_t inChannels;
    uint32_t outChannels;

    // Sequentially consistent together: the callback raises inCallback and then reads closed, the
    // control thread raises closed and then reads inCallback, so at least one sees the other.
    _Atomic(bool) inCallback;
    _Atomic(bool) closed;

    // All in the block after this struct.
    const float **in;
    float **out;
    AudioBufferList *inputList;
};

// MARK: - Render callback (render thread)

/// Device input for this block, or NULL for silence.
static const float *const *pull_input(PRDeviceLink *link, const AudioTimeStamp *timeStamp, uint32_t frames) {
    if (link->inChannels == 0 || frames > link->capacity) return NULL;

    // A unit can leave these changed after a render, so every pull sets them again.
    AudioBufferList *list = link->inputList;
    list->mNumberBuffers = link->inChannels;
    for (uint32_t channel = 0; channel < link->inChannels; channel++) {
        list->mBuffers[channel].mNumberChannels = 1;
        list->mBuffers[channel].mDataByteSize = frames * sizeof(float);
        list->mBuffers[channel].mData = (void *)link->in[channel];
    }
    AudioUnitRenderActionFlags flags = 0;
    OSStatus status = AudioUnitRender(link->unit, &flags, timeStamp, PR_INPUT_ELEMENT, frames, list);
    return status == noErr ? link->in : NULL;
}

static void write_silence(AudioUnitRenderActionFlags *flags, AudioBufferList *data) {
    for (uint32_t buffer = 0; buffer < data->mNumberBuffers; buffer++) {
        if (data->mBuffers[buffer].mData == NULL) continue;
        memset(data->mBuffers[buffer].mData, 0, data->mBuffers[buffer].mDataByteSize);
    }
    *flags |= kAudioUnitRenderAction_OutputIsSilence;
}

static OSStatus render_callback(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timeStamp,
                                UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)bus;
    PRDeviceLink *link = refCon;
    atomic_store_explicit(&link->inCallback, true, memory_order_seq_cst);
    if (atomic_load_explicit(&link->closed, memory_order_seq_cst)) {
        write_silence(flags, data);
    } else {
        const float *const *in = pull_input(link, timeStamp, frames);
        uint32_t outChannels = data->mNumberBuffers < link->outChannels ? data->mNumberBuffers : link->outChannels;
        for (uint32_t channel = 0; channel < outChannels; channel++) {
            link->out[channel] = data->mBuffers[channel].mData;
        }
        pr_engine_render(link->engine, frames, in, in != NULL ? link->inChannels : 0, link->out, outChannels);
    }
    atomic_store_explicit(&link->inCallback, false, memory_order_seq_cst);
    return noErr;
}

// MARK: - Control thread

PRDeviceLink *pr_device_link_create(PREngine *engine, AudioUnit unit, uint32_t maxFrames,
                                    uint32_t inChannels, uint32_t outChannels) {
    if (maxFrames == 0 || outChannels == 0) return NULL;

    size_t inPointers = inChannels * sizeof(const float *);
    size_t outPointers = outChannels * sizeof(float *);
    size_t list = offsetof(AudioBufferList, mBuffers) + inChannels * sizeof(AudioBuffer);
    size_t samples = (size_t)inChannels * maxFrames * sizeof(float);

    // Everything lives in one block, samples last, so alignment needs no padding.
    PRDeviceLink *link = pr_alloc(sizeof(PRDeviceLink) + inPointers + outPointers + list + samples);
    if (link == NULL) return NULL;

    char *cursor = (char *)(link + 1);
    link->in = (const float **)cursor;
    cursor += inPointers;
    link->out = (float **)cursor;
    cursor += outPointers;
    link->inputList = (AudioBufferList *)cursor;
    cursor += list;
    for (uint32_t channel = 0; channel < inChannels; channel++) {
        link->in[channel] = (const float *)cursor;
        cursor += maxFrames * sizeof(float);
    }

    link->engine = engine;
    link->unit = unit;
    link->capacity = maxFrames;
    link->inChannels = inChannels;
    link->outChannels = outChannels;
    return link;
}

AURenderCallbackStruct pr_device_link_render_callback(PRDeviceLink *link) {
    return (AURenderCallbackStruct){render_callback, link};
}

void pr_device_link_close(PRDeviceLink *link) {
    atomic_store_explicit(&link->closed, true, memory_order_seq_cst);
}

bool pr_device_link_is_idle(PRDeviceLink *link) {
    return !atomic_load_explicit(&link->inCallback, memory_order_seq_cst);
}

void pr_device_link_destroy(PRDeviceLink *link) {
    free(link);
}
