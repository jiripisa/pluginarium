// Host callbacks: units read the engine's transport through these. Units should only call them
// while rendering, but nothing enforces that, so they touch atomics only.

#include "internal.h"

#include <math.h>

#define PR_BEATS_PER_BAR 4

static double current_tempo(const PREngine *engine) {
    return atomic_load_explicit(&engine->tempo, memory_order_relaxed);
}

static double current_beat(const PREngine *engine) {
    return atomic_load_explicit(&engine->beat, memory_order_relaxed);
}

static OSStatus beat_and_tempo(void *userData, Float64 *beat, Float64 *tempo) {
    const PREngine *engine = userData;
    if (beat != NULL) *beat = current_beat(engine);
    if (tempo != NULL) *tempo = current_tempo(engine);
    return noErr;
}

static OSStatus musical_time_location(void *userData, UInt32 *samplesToNextBeat, Float32 *numerator,
                                      UInt32 *denominator, Float64 *downbeat) {
    const PREngine *engine = userData;
    double beat = current_beat(engine);
    if (samplesToNextBeat != NULL) {
        double untilNext = ceil(beat) - beat;
        *samplesToNextBeat = (UInt32)(untilNext * 60.0 / current_tempo(engine) * engine->sampleRate);
    }
    if (numerator != NULL) *numerator = PR_BEATS_PER_BAR;
    if (denominator != NULL) *denominator = 4;
    if (downbeat != NULL) *downbeat = floor(beat / PR_BEATS_PER_BAR) * PR_BEATS_PER_BAR;
    return noErr;
}

static OSStatus transport_state(void *userData, Boolean *playing, Boolean *recording, Boolean *changed,
                                Float64 *sample, Boolean *cycling, Float64 *cycleStart, Float64 *cycleEnd) {
    const PREngine *engine = userData;
    if (playing != NULL) *playing = atomic_load_explicit(&engine->playing, memory_order_relaxed);
    if (recording != NULL) *recording = false;
    if (changed != NULL) *changed = atomic_load_explicit(&engine->transportChanged, memory_order_relaxed);
    if (sample != NULL) *sample = atomic_load_explicit(&engine->timelineSample, memory_order_relaxed);
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

HostCallbackInfo pr_host_callback_info(PREngine *engine) {
    return (HostCallbackInfo){
        .hostUserData = engine,
        .beatAndTempoProc = beat_and_tempo,
        .musicalTimeLocationProc = musical_time_location,
        .transportStateProc = legacy_transport_state,
        .transportStateProc2 = transport_state,
    };
}

OSStatus pr_install_host_callbacks(AudioUnit unit, PREngine *engine) {
    HostCallbackInfo info = pr_host_callback_info(engine);
    return AudioUnitSetProperty(unit, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0, &info, sizeof(info));
}
