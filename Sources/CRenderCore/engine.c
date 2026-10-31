// Engine lifecycle, MIDI, transport and metering.

#include "internal.h"

#include <mach/mach_time.h>
#include <stdlib.h>

#define PR_LOAD_SMOOTHING 0.1
#define PR_SMALLEST_PAGE 4096

void *pr_alloc(size_t size) {
    // calloc maps fresh pages lazily, and the compiler turns malloc plus memset into calloc.
    volatile char *memory = calloc(1, size);
    if (memory == NULL) return NULL;
    for (size_t i = 0; i < size; i += PR_SMALLEST_PAGE) memory[i] = 0;
    memory[size - 1] = 0;
    return (void *)memory;
}

PREngine *pr_engine_create(uint32_t maxFrames, double sampleRate) {
    if (maxFrames == 0 || !(sampleRate > 0)) return NULL;
    PREngine *engine = pr_alloc(sizeof(PREngine));
    if (engine == NULL) return NULL;

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    engine->maxFrames = maxFrames;
    atomic_init(&engine->sampleRate, sampleRate);
    engine->secondsPerTick = (double)timebase.numer / (double)timebase.denom / 1e9;
    atomic_init(&engine->block, 1);
    atomic_init(&engine->tempo, 120.0);
    return engine;
}

void pr_engine_destroy(PREngine *engine) {
    if (engine == NULL) return;
    pr_engine_collect_garbage(engine);
    free(atomic_load_explicit(&engine->pending, memory_order_acquire));
    free(engine->current);
    for (PRInputRecord *record = engine->records; record != NULL;) {
        PRInputRecord *next = record->next;
        free(record->scratch);
        free(record);
        record = next;
    }
    for (PRHostRecord *record = engine->hostRecords; record != NULL;) {
        PRHostRecord *next = record->next;
        free(record);
        record = next;
    }
    free(engine);
}

void pr_engine_set_audio_running(PREngine *engine, bool running) {
    atomic_store_explicit(&engine->audioRunning, running, memory_order_release);
}

void pr_engine_set_sample_rate(PREngine *engine, double sampleRate) {
    if (!(sampleRate > 0)) return;
    atomic_store_explicit(&engine->sampleRate, sampleRate, memory_order_relaxed);
}

double pr_sample_rate(const PREngine *engine) {
    return atomic_load_explicit(&engine->sampleRate, memory_order_relaxed);
}

// MARK: - MIDI

void pr_engine_push_midi(PREngine *engine, int32_t slot, uint8_t status, uint8_t d1, uint8_t d2) {
    if (slot < 0 || slot >= PR_MIDI_SLOTS) return;
    PRMidiRing *ring = &engine->midi[slot];
    uint32_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    if (head - tail >= PR_MIDI_RING_SIZE) return;
    ring->events[head % PR_MIDI_RING_SIZE] = (PRMidiEvent){status, d1, d2};
    atomic_store_explicit(&ring->head, head + 1, memory_order_release);
}

void pr_midi_drain(PREngine *engine, const PRGraph *graph) {
    for (uint32_t slot = 0; slot < PR_MIDI_SLOTS; slot++) {
        PRMidiRing *ring = &engine->midi[slot];
        uint32_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
        uint32_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
        if (tail == head) continue;
        AudioUnit target = graph != NULL ? graph->midiTargets[slot] : NULL;
        for (; tail != head; tail++) {
            PRMidiEvent event = ring->events[tail % PR_MIDI_RING_SIZE];
            if (target != NULL) MusicDeviceMIDIEvent(target, event.status, event.d1, event.d2, 0);
        }
        atomic_store_explicit(&ring->tail, tail, memory_order_release);
    }
}

// MARK: - Transport

void pr_engine_set_transport(PREngine *engine, double tempo, bool playing) {
    if (tempo > 0) atomic_store_explicit(&engine->tempo, tempo, memory_order_relaxed);
    atomic_store_explicit(&engine->playing, playing, memory_order_release);
}

void pr_engine_rewind_transport(PREngine *engine) {
    atomic_store_explicit(&engine->rewindRequested, true, memory_order_release);
}

void pr_transport_begin_block(PREngine *engine) {
    atomic_fetch_add(&engine->block, 1);
    // Acquire, so that a block that sees a start playing also sees the rewind called before it.
    bool playing = atomic_load_explicit(&engine->playing, memory_order_acquire);
    bool rewind = atomic_exchange_explicit(&engine->rewindRequested, false, memory_order_acquire);
    if (rewind) {
        atomic_store_explicit(&engine->beat, 0, memory_order_relaxed);
        atomic_store_explicit(&engine->timelineSample, 0, memory_order_relaxed);
    }
    atomic_store_explicit(&engine->transportChanged, rewind || playing != engine->wasPlaying, memory_order_relaxed);
    engine->wasPlaying = playing;
}

void pr_transport_advance(PREngine *engine, uint32_t frames) {
    if (!engine->wasPlaying) return;
    double tempo = atomic_load_explicit(&engine->tempo, memory_order_relaxed);
    double beat = atomic_load_explicit(&engine->beat, memory_order_relaxed);
    double sample = atomic_load_explicit(&engine->timelineSample, memory_order_relaxed);
    atomic_store_explicit(&engine->beat, beat + frames * tempo / (60.0 * pr_sample_rate(engine)), memory_order_relaxed);
    atomic_store_explicit(&engine->timelineSample, sample + frames, memory_order_relaxed);
}

// MARK: - Metering

void pr_engine_read_meters(PREngine *engine, uint32_t strip, float *left, float *right) {
    const PRGraph *graph = engine->latest;
    if (graph == NULL || strip >= graph->stripCount) {
        *left = 0;
        *right = 0;
        return;
    }
    *left = atomic_exchange_explicit(&graph->strips[strip].peak[0], 0, memory_order_relaxed);
    *right = atomic_exchange_explicit(&graph->strips[strip].peak[1], 0, memory_order_relaxed);
}

void pr_load_update(PREngine *engine, uint64_t ticks, uint32_t frames) {
    double ratio = (double)ticks * engine->secondsPerTick * pr_sample_rate(engine) / frames;
    double load = atomic_load_explicit(&engine->load, memory_order_relaxed);
    atomic_store_explicit(&engine->load, load + PR_LOAD_SMOOTHING * (ratio - load), memory_order_relaxed);
}

double pr_engine_load(PREngine *engine) {
    return atomic_load_explicit(&engine->load, memory_order_relaxed);
}
