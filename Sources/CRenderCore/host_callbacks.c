// Host callbacks: units read the engine's transport through these. Units should only call them
// while rendering, but nothing enforces that, so they touch atomics only.
//
// A unit that does not follow reads the tempo as it is, and a transport stopped at beat 0, so an
// internal sequencer has nothing to start from. A flip of its switch reads as a transport change for
// one block, or a sequencer that keys on the change would never hear of the stop. Nothing here clears
// that: a callback only loads, so every caller in the block gets the same answer.

#include "internal.h"

#include <math.h>

#define PR_BEATS_PER_BAR 4

static double current_tempo(const PREngine *engine) {
    return atomic_load_explicit(&engine->tempo, memory_order_relaxed);
}

static bool follows_transport(const PRHostRecord *record) {
    return atomic_load_explicit(&record->followsTransport, memory_order_relaxed);
}

static bool switch_flipped(const PRHostRecord *record) {
    return atomic_load(&record->flipBlock) == atomic_load(&record->engine->block);
}

static double current_beat(const PRHostRecord *record) {
    if (!follows_transport(record)) return 0;
    return atomic_load_explicit(&record->engine->beat, memory_order_relaxed);
}

static OSStatus beat_and_tempo(void *userData, Float64 *beat, Float64 *tempo) {
    const PRHostRecord *record = userData;
    if (beat != NULL) *beat = current_beat(record);
    if (tempo != NULL) *tempo = current_tempo(record->engine);
    return noErr;
}

static OSStatus musical_time_location(void *userData, UInt32 *samplesToNextBeat, Float32 *numerator,
                                      UInt32 *denominator, Float64 *downbeat) {
    const PRHostRecord *record = userData;
    double beat = current_beat(record);
    if (samplesToNextBeat != NULL) {
        double untilNext = ceil(beat) - beat;
        *samplesToNextBeat = (UInt32)(untilNext * 60.0 / current_tempo(record->engine) * pr_sample_rate(record->engine));
    }
    if (numerator != NULL) *numerator = PR_BEATS_PER_BAR;
    if (denominator != NULL) *denominator = 4;
    if (downbeat != NULL) *downbeat = floor(beat / PR_BEATS_PER_BAR) * PR_BEATS_PER_BAR;
    return noErr;
}

static OSStatus transport_state(void *userData, Boolean *playing, Boolean *recording, Boolean *changed,
                                Float64 *sample, Boolean *cycling, Float64 *cycleStart, Float64 *cycleEnd) {
    const PRHostRecord *record = userData;
    const PREngine *engine = record->engine;
    bool follows = follows_transport(record);
    if (playing != NULL) *playing = follows && atomic_load_explicit(&engine->playing, memory_order_relaxed);
    if (recording != NULL) *recording = false;
    if (changed != NULL) {
        *changed = switch_flipped(record) || (follows && atomic_load_explicit(&engine->transportChanged, memory_order_relaxed));
    }
    if (sample != NULL) *sample = follows ? atomic_load_explicit(&engine->timelineSample, memory_order_relaxed) : 0;
    if (cycling != NULL) *cycling = false;
    if (cycleStart != NULL) *cycleStart = 0;
    if (cycleEnd != NULL) *cycleEnd = 0;
    return noErr;
}

/// Apple's AudioUnitSDK, and the plugins built on it, call only this older form.
static OSStatus legacy_transport_state(void *userData, Boolean *playing, Boolean *changed, Float64 *sample,
                                       Boolean *cycling, Float64 *cycleStart, Float64 *cycleEnd) {
    return transport_state(userData, playing, NULL, changed, sample, cycling, cycleStart, cycleEnd);
}

static PRHostRecord *find_record(const PREngine *engine, AudioUnit unit) {
    for (PRHostRecord *record = engine->hostRecords; record != NULL; record = record->next) {
        if (record->unit == unit) return record;
    }
    return NULL;
}

static PRHostRecord *add_record(PREngine *engine, AudioUnit unit) {
    PRHostRecord *record = pr_alloc(sizeof(PRHostRecord));
    if (record == NULL) return NULL;
    record->unit = unit;
    record->engine = engine;
    record->next = engine->hostRecords;
    engine->hostRecords = record;
    return record;
}

static HostCallbackInfo callback_info(PRHostRecord *record) {
    return (HostCallbackInfo){
        .hostUserData = record,
        .beatAndTempoProc = beat_and_tempo,
        .musicalTimeLocationProc = musical_time_location,
        .transportStateProc = legacy_transport_state,
        .transportStateProc2 = transport_state,
    };
}

HostCallbackInfo pr_host_callback_info(PREngine *engine, AudioUnit unit) {
    PRHostRecord *record = find_record(engine, unit);
    return record != NULL ? callback_info(record) : (HostCallbackInfo){0};
}

OSStatus pr_install_host_callbacks(AudioUnit unit, PREngine *engine) {
    PRHostRecord *record = find_record(engine, unit);
    if (record == NULL) record = add_record(engine, unit);
    if (record == NULL) return kAudio_MemFullError;

    // Off even when the record exists: a disposed unit's address can come back as a new unit.
    atomic_store_explicit(&record->followsTransport, false, memory_order_relaxed);
    atomic_store(&record->flipBlock, 0);
    HostCallbackInfo info = callback_info(record);
    return AudioUnitSetProperty(unit, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0, &info, sizeof(info));
}

void pr_engine_set_follows_transport(PREngine *engine, AudioUnit unit, bool follows) {
    PRHostRecord *record = find_record(engine, unit);
    if (record == NULL) return;
    // Every edit of a configuration sets every plugin again, and only a real flip may report one.
    if (atomic_exchange_explicit(&record->followsTransport, follows, memory_order_relaxed) == follows) return;

    // The next block reports it. This looks again in case that block began during these two steps,
    // since a mark on a block that has gone by would lose the flip. Then two blocks report it.
    uint64_t flipBlock;
    do {
        flipBlock = atomic_load(&engine->block) + 1;
        atomic_store(&record->flipBlock, flipBlock);
    } while (atomic_load(&engine->block) >= flipBlock);
}
