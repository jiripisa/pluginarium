// Graph build, hand-over to the render thread, and render.

#include "internal.h"

#include <mach/mach_time.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define PR_SCRATCH_BUFFERS (PR_INPUT_BUSES * PR_BUS_CHANNELS + 1)
#define PR_STRIP_BUFFERS 3
#define PR_OUTPUT_CEILING 4.0f // +12 dB

static inline uint32_t pr_min(uint32_t a, uint32_t b) { return a < b ? a : b; }

// MARK: - Input callback (render thread)

static void copy_or_silence(float *dest, const float *source, uint32_t available, uint32_t frames) {
    uint32_t copied = source != NULL ? pr_min(available, frames) : 0;
    if (copied > 0) memcpy(dest, source, copied * sizeof(float));
    if (copied < frames) memset(dest + copied, 0, (frames - copied) * sizeof(float));
}

/// A mono bus takes both sides at 0.5 each, the same rule as a mono output.
static void mix_down(float *dest, const PRSignal *signal, uint32_t frames) {
    if (signal->left == signal->right) {
        copy_or_silence(dest, signal->left, signal->frames, frames);
        return;
    }
    uint32_t mixed = pr_min(signal->frames, frames);
    for (uint32_t i = 0; i < mixed; i++) {
        float left = signal->left != NULL ? signal->left[i] : 0;
        float right = signal->right != NULL ? signal->right[i] : 0;
        dest[i] = 0.5f * (left + right);
    }
    if (mixed < frames) memset(dest + mixed, 0, (frames - mixed) * sizeof(float));
}

/// Each main and sidechain channel has its own buffer; anything beyond those shares the last one,
/// which is only ever silent.
static float *scratch_buffer(const PRInputRecord *record, uint32_t bus, uint32_t channel) {
    uint32_t index = PR_SCRATCH_BUFFERS - 1;
    if (bus < PR_INPUT_BUSES && channel < PR_BUS_CHANNELS) index = bus * PR_BUS_CHANNELS + channel;
    return record->scratch + index * record->capacity;
}

/// Always copies, so a unit working in place cannot change a signal another stage reads.
/// Version 2 units often pull with NULL buffers and expect the callback to supply them.
static OSStatus input_callback(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timeStamp,
                               UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)flags;
    (void)timeStamp;
    const PRInputRecord *record = refCon;
    static const PRSignal silence = {NULL, NULL, 0};
    const PRSignal *signal = bus < PR_INPUT_BUSES ? &record->buses[bus] : &silence;

    for (uint32_t channel = 0; channel < data->mNumberBuffers; channel++) {
        AudioBuffer *buffer = &data->mBuffers[channel];
        uint32_t writable = frames;
        if (buffer->mData == NULL) {
            if (frames > record->capacity) return kAudioUnitErr_TooManyFramesToProcess;
            buffer->mData = scratch_buffer(record, bus, channel);
            buffer->mDataByteSize = frames * sizeof(float);
        } else {
            writable = pr_min(frames, buffer->mDataByteSize / sizeof(float));
        }
        float *dest = buffer->mData;
        if (data->mNumberBuffers == 1) {
            mix_down(dest, signal, writable);
        } else {
            const float *source = channel == 0 ? signal->left : channel == 1 ? signal->right : NULL;
            copy_or_silence(dest, source, signal->frames, writable);
        }
    }
    return noErr;
}

// MARK: - Render (render thread)

static PRSignal device_signal(PRChannels channels, const float *const *in, uint32_t inChannels,
                              uint32_t offset, uint32_t frames) {
    PRSignal signal = {NULL, NULL, frames};
    if (channels.left < 0 || in == NULL) return signal;
    if ((uint32_t)channels.left < inChannels && in[channels.left] != NULL) {
        signal.left = in[channels.left] + offset;
    }
    if (channels.right < 0) {
        signal.right = signal.left;
    } else if ((uint32_t)channels.right < inChannels && in[channels.right] != NULL) {
        signal.right = in[channels.right] + offset;
    }
    return signal;
}

static void silence_non_finite(float *samples, uint32_t frames) {
    for (uint32_t i = 0; i < frames; i++) {
        if (!isfinite(samples[i])) samples[i] = 0;
    }
}

/// Keeps what leaves a strip, or reaches a device channel, finite and within the ceiling. This clips,
/// so it only holds a runaway signal back from the speakers, and is no limiter.
static void guard_output(float *samples, uint32_t frames) {
    silence_non_finite(samples, frames);
    for (uint32_t i = 0; i < frames; i++) {
        samples[i] = fminf(fmaxf(samples[i], -PR_OUTPUT_CEILING), PR_OUTPUT_CEILING);
    }
}

/// Renders one unit into stereo buffers. A failed render leaves them silent. A non-finite sample goes
/// here, before a parallel branch sums with it or the next stage takes it into its state. Finite
/// samples stay as they are: a stage may run hot if a later one brings the level down.
static void render_stage(const PRNode *node, const PRSignal *main, const PRSignal *sidechain,
                         float *const *dest, uint32_t frames, const AudioTimeStamp *timeStamp) {
    OSStatus status = kAudioUnitErr_Uninitialized;
    if (node->unit != NULL) {
        struct {
            UInt32 count;
            AudioBuffer buffers[PR_BUS_CHANNELS];
        } list;
        list.count = node->channels;
        for (uint32_t channel = 0; channel < node->channels; channel++) {
            list.buffers[channel].mNumberChannels = 1;
            list.buffers[channel].mDataByteSize = frames * sizeof(float);
            list.buffers[channel].mData = dest[channel];
        }
        if (node->record != NULL) {
            node->record->buses[0] = *main;
            node->record->buses[1] = *sidechain;
        }
        AudioUnitRenderActionFlags flags = 0;
        status = AudioUnitRender(node->unit, &flags, timeStamp, 0, frames, (AudioBufferList *)&list);
        if (node->record != NULL) {
            // These point into this block's buffers, which may not outlive it.
            node->record->buses[0] = (PRSignal){NULL, NULL, 0};
            node->record->buses[1] = (PRSignal){NULL, NULL, 0};
        }
    }
    if (status != noErr) {
        memset(dest[0], 0, frames * sizeof(float));
        memset(dest[1], 0, frames * sizeof(float));
        return;
    }
    silence_non_finite(dest[0], frames);
    if (node->channels == 1) {
        memcpy(dest[1], dest[0], frames * sizeof(float));
    } else {
        silence_non_finite(dest[1], frames);
    }
}

static void add(float *dest, const float *source, uint32_t frames) {
    for (uint32_t i = 0; i < frames; i++) dest[i] += source[i];
}

static float peak_of(const float *samples, uint32_t frames) {
    float peak = 0;
    for (uint32_t i = 0; i < frames; i++) {
        float level = fabsf(samples[i]);
        if (level > peak) peak = level;
    }
    return peak;
}

/// Raises the stored peak, which pr_engine_read_meters takes and resets from the control thread.
/// The compare-exchange loop keeps a read between the load and the store from losing the new peak.
static void update_meters(PRStripNode *strip, float *const *signal, uint32_t frames) {
    for (uint32_t side = 0; side < PR_BUS_CHANNELS; side++) {
        float peak = peak_of(signal[side], frames);
        float stored = atomic_load_explicit(&strip->peak[side], memory_order_relaxed);
        while (peak > stored &&
               !atomic_compare_exchange_weak_explicit(&strip->peak[side], &stored, peak, memory_order_relaxed,
                                                      memory_order_relaxed)) {
        }
    }
}

static void write_output(PRChannels channels, float *const *signal, float *const *out, uint32_t outChannels,
                         uint32_t offset, uint32_t frames) {
    if (channels.left < 0) return;
    bool leftFits = (uint32_t)channels.left < outChannels && out[channels.left] != NULL;
    if (channels.right < 0) {
        if (!leftFits) return;
        float *dest = out[channels.left] + offset;
        for (uint32_t i = 0; i < frames; i++) dest[i] += 0.5f * (signal[0][i] + signal[1][i]);
        return;
    }
    if (leftFits) add(out[channels.left] + offset, signal[0], frames);
    if ((uint32_t)channels.right < outChannels && out[channels.right] != NULL) {
        add(out[channels.right] + offset, signal[1], frames);
    }
}

static void render_strip(PRStripNode *strip, uint32_t offset, uint32_t frames,
                         const float *const *in, uint32_t inChannels,
                         float *const *out, uint32_t outChannels, const AudioTimeStamp *timeStamp) {
    float *const *signal = strip->buffers[0];
    float *const *rowOutput = strip->buffers[1];
    float *const *branch = strip->buffers[2];

    PRSignal mainInput = device_signal(strip->audioIn, in, inChannels, offset, frames);
    PRSignal sidechain = device_signal(strip->source.sidechain, in, inChannels, offset, frames);
    render_stage(&strip->source, &mainInput, &sidechain, signal, frames, timeStamp);

    for (uint32_t r = 0; r < strip->rowCount; r++) {
        const PRRowNode *row = &strip->rows[r];
        if (row->count == 0) continue;
        PRSignal rowInput = {signal[0], signal[1], frames};
        for (uint32_t e = 0; e < row->count; e++) {
            const PRNode *effect = &row->effects[e];
            sidechain = device_signal(effect->sidechain, in, inChannels, offset, frames);
            render_stage(effect, &rowInput, &sidechain, e == 0 ? rowOutput : branch, frames, timeStamp);
            if (e > 0) {
                add(rowOutput[0], branch[0], frames);
                add(rowOutput[1], branch[1], frames);
            }
        }
        float *const *swap = signal;
        signal = rowOutput;
        rowOutput = swap;
    }

    // Before the meter, so it shows what the device gets.
    guard_output(signal[0], frames);
    guard_output(signal[1], frames);
    update_meters(strip, signal, frames);
    write_output(strip->audioOut, signal, out, outChannels, offset, frames);
}

/// Every strip is within the ceiling, but several on one channel can sum past it.
static void guard_device_output(float *const *out, uint32_t outChannels, uint32_t offset, uint32_t frames) {
    for (uint32_t channel = 0; channel < outChannels; channel++) {
        if (out[channel] != NULL) guard_output(out[channel] + offset, frames);
    }
}

/// Takes the newest installed graph. The replaced one is finished with once this returns.
static void take_pending_graph(PREngine *engine) {
    PRGraph *pending = atomic_exchange_explicit(&engine->pending, NULL, memory_order_acq_rel);
    if (pending == NULL) return;
    if (engine->current != NULL) pr_graph_retire(engine, engine->current);
    engine->current = pending;
    // Release: the caller may dispose units this thread rendered in earlier blocks.
    atomic_store_explicit(&engine->takenGeneration, pending->generation, memory_order_release);
}

void pr_engine_render(PREngine *engine, uint32_t frames,
                      const float *const *in, uint32_t inChannels,
                      float *const *out, uint32_t outChannels) {
    uint64_t started = mach_absolute_time();
    for (uint32_t channel = 0; channel < outChannels; channel++) {
        if (out[channel] != NULL) memset(out[channel], 0, frames * sizeof(float));
    }
    if (frames == 0) return;

    take_pending_graph(engine);
    PRGraph *graph = engine->current;
    pr_transport_begin_block(engine);
    pr_midi_drain(engine, graph);

    for (uint32_t offset = 0; offset < frames;) {
        uint32_t chunk = pr_min(frames - offset, engine->maxFrames);
        AudioTimeStamp timeStamp = {0};
        timeStamp.mSampleTime = engine->sampleTime;
        timeStamp.mFlags = kAudioTimeStampSampleTimeValid;
        if (graph != NULL) {
            for (uint32_t s = 0; s < graph->stripCount; s++) {
                render_strip(&graph->strips[s], offset, chunk, in, inChannels, out, outChannels, &timeStamp);
            }
            guard_device_output(out, outChannels, offset, chunk);
        }
        engine->sampleTime += chunk;
        pr_transport_advance(engine, chunk);
        offset += chunk;
    }
    pr_load_update(engine, mach_absolute_time() - started, frames);
}

// MARK: - Graph build (control thread)

static PRInputRecord *find_record(const PREngine *engine, AudioUnit unit) {
    for (PRInputRecord *record = engine->records; record != NULL; record = record->next) {
        if (record->unit == unit) return record;
    }
    return NULL;
}

static PRInputRecord *add_record(PREngine *engine, AudioUnit unit) {
    PRInputRecord *record = pr_alloc(sizeof(PRInputRecord));
    if (record == NULL) return NULL;
    record->scratch = pr_alloc(PR_SCRATCH_BUFFERS * (size_t)engine->maxFrames * sizeof(float));
    if (record->scratch == NULL) {
        free(record);
        return NULL;
    }
    record->unit = unit;
    record->capacity = engine->maxFrames;
    record->next = engine->records;
    engine->records = record;
    return record;
}

OSStatus pr_install_input_callbacks(AudioUnit unit, PREngine *engine) {
    UInt32 buses = 0;
    UInt32 size = sizeof(buses);
    OSStatus status = AudioUnitGetProperty(unit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &buses, &size);
    if (status != noErr) return status;

    PRInputRecord *record = find_record(engine, unit);
    if (record == NULL) record = add_record(engine, unit);
    if (record == NULL) return kAudio_MemFullError;

    // Set even when the record exists: a disposed unit's address can come back as a new unit.
    AURenderCallbackStruct callback = {input_callback, record};
    for (UInt32 bus = 0; bus < buses; bus++) {
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, bus, &callback, sizeof(callback));
        if (status != noErr) return status;
    }
    return noErr;
}

static uint32_t clamp_channels(uint32_t channels) {
    return channels < 2 ? 1 : PR_BUS_CHANNELS;
}

static PRNode make_node(const PREngine *engine, AudioUnit unit, PRChannels sidechain, uint32_t channels) {
    PRNode node = {unit, NULL, sidechain, clamp_channels(channels)};
    if (unit != NULL) node.record = find_record(engine, unit);
    return node;
}

static size_t graph_size(const PRStrip *strips, uint32_t count, uint32_t maxFrames) {
    size_t size = sizeof(PRGraph) + count * sizeof(PRStripNode);
    for (uint32_t s = 0; s < count; s++) {
        size += strips[s].rowCount * sizeof(PRRowNode);
        for (uint32_t r = 0; r < strips[s].rowCount; r++) {
            size += strips[s].rows[r].count * sizeof(PRNode);
        }
    }
    return size + count * (size_t)(PR_STRIP_BUFFERS * PR_BUS_CHANNELS) * maxFrames * sizeof(float);
}

static PRGraph *build_graph(const PREngine *engine, const PRStrip *strips, uint32_t count) {
    PRGraph *graph = pr_alloc(graph_size(strips, count, engine->maxFrames));
    if (graph == NULL) return NULL;

    // Everything lives in one block: structs first, then samples, so alignment needs no padding.
    char *cursor = (char *)(graph + 1);
    graph->strips = (PRStripNode *)cursor;
    graph->stripCount = count;
    cursor += count * sizeof(PRStripNode);

    for (uint32_t s = 0; s < count; s++) {
        const PRStrip *strip = &strips[s];
        PRStripNode *node = &graph->strips[s];
        node->source = make_node(engine, strip->source, strip->sidechain, strip->sourceChannels);
        node->audioIn = strip->audioIn;
        node->audioOut = strip->audioOut;
        node->rows = (PRRowNode *)cursor;
        node->rowCount = strip->rowCount;
        cursor += strip->rowCount * sizeof(PRRowNode);

        int32_t slot = strip->midiSlot;
        if (slot >= 0 && slot < PR_MIDI_SLOTS && graph->midiTargets[slot] == NULL) {
            graph->midiTargets[slot] = strip->source;
        }
    }
    for (uint32_t s = 0; s < count; s++) {
        const PRStrip *strip = &strips[s];
        PRStripNode *node = &graph->strips[s];
        for (uint32_t r = 0; r < strip->rowCount; r++) {
            const PRRow *row = &strip->rows[r];
            node->rows[r].effects = (PRNode *)cursor;
            node->rows[r].count = row->count;
            cursor += row->count * sizeof(PRNode);
            for (uint32_t e = 0; e < row->count; e++) {
                const PREffect *effect = &row->effects[e];
                node->rows[r].effects[e] = make_node(engine, effect->unit, effect->sidechain, effect->channels);
            }
        }
    }
    for (uint32_t s = 0; s < count; s++) {
        for (uint32_t b = 0; b < PR_STRIP_BUFFERS; b++) {
            for (uint32_t side = 0; side < PR_BUS_CHANNELS; side++) {
                graph->strips[s].buffers[b][side] = (float *)cursor;
                cursor += engine->maxFrames * sizeof(float);
            }
        }
    }
    return graph;
}

void pr_graph_retire(PREngine *engine, PRGraph *graph) {
    PRGraph *head = atomic_load_explicit(&engine->retired, memory_order_relaxed);
    do {
        graph->next = head;
    } while (!atomic_compare_exchange_weak_explicit(&engine->retired, &head, graph,
                                                    memory_order_release, memory_order_relaxed));
}

uint64_t pr_engine_install_graph(PREngine *engine, const PRStrip *strips, uint32_t count) {
    PRGraph *graph = build_graph(engine, strips, count);
    if (graph == NULL) return UINT64_MAX; // nothing was replaced: the previous graph stays
    graph->generation = ++engine->installedGeneration;
    engine->latest = graph;
    PRGraph *unused = atomic_exchange_explicit(&engine->pending, graph, memory_order_acq_rel);
    if (unused != NULL) pr_graph_retire(engine, unused);
    return graph->generation;
}

bool pr_engine_is_generation_taken(PREngine *engine, uint64_t generation) {
    if (generation == UINT64_MAX) return false; // a failed install: its units must never be disposed
    if (!atomic_load_explicit(&engine->audioRunning, memory_order_acquire)) return true;
    return atomic_load_explicit(&engine->takenGeneration, memory_order_acquire) >= generation;
}

void pr_engine_collect_garbage(PREngine *engine) {
    PRGraph *graph = atomic_exchange_explicit(&engine->retired, NULL, memory_order_acquire);
    while (graph != NULL) {
        PRGraph *next = graph->next;
        free(graph);
        graph = next;
    }
}
