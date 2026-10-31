#ifndef CRenderCore_internal_h
#define CRenderCore_internal_h

#include "CRenderCore.h"

#include <stdatomic.h>

#define PR_MIDI_SLOTS 64
#define PR_MIDI_RING_SIZE 512 // power of two
#define PR_INPUT_BUSES 2      // main, sidechain
#define PR_BUS_CHANNELS 2

_Static_assert(__atomic_always_lock_free(sizeof(double), 0), "the render thread needs lock-free atomics");

/// Read-only samples for one input bus. A NULL side is silence.
typedef struct {
    const float *left;
    const float *right;
    uint32_t frames;
} PRSignal;

/// One per unit, for the life of the engine: the unit's input callback points at it.
/// buses is written by the render thread around AudioUnitRender and read by the callback,
/// which runs inside that call.
typedef struct PRInputRecord {
    struct PRInputRecord *next; // control thread only
    AudioUnit unit;             // control thread only
    PRSignal buses[PR_INPUT_BUSES];
    uint32_t capacity;          // frames per scratch buffer
    float *scratch;             // handed to units that pull with NULL buffers
} PRInputRecord;

typedef struct {
    AudioUnit unit;
    PRInputRecord *record; // NULL: the unit reads silence
    PRChannels sidechain;
    uint32_t channels;     // 1 or 2
} PRNode;

typedef struct {
    PRNode *effects;
    uint32_t count;
} PRRowNode;

typedef struct {
    PRNode source;
    PRChannels audioIn;
    PRChannels audioOut;
    PRRowNode *rows;
    uint32_t rowCount;
    float *buffers[3][PR_BUS_CHANNELS]; // row input, row output, parallel branch
    _Atomic(float) peak[PR_BUS_CHANNELS];
} PRStripNode;

/// A complete, immutable routing, in one allocation.
typedef struct PRGraph {
    struct PRGraph *next; // link in PREngine.retired
    PRStripNode *strips;
    uint32_t stripCount;
    AudioUnit midiTargets[PR_MIDI_SLOTS];
} PRGraph;

typedef struct {
    uint8_t status, d1, d2;
} PRMidiEvent;

/// Single producer, single consumer. head and tail run free; the index is taken modulo the size.
typedef struct {
    _Atomic(uint32_t) head;
    _Atomic(uint32_t) tail;
    PRMidiEvent events[PR_MIDI_RING_SIZE];
} PRMidiRing;

struct PREngine {
    uint32_t maxFrames;
    double sampleRate;
    double secondsPerTick;

    _Atomic(PRGraph *) pending; // newest graph no render has taken yet
    _Atomic(PRGraph *) retired; // stack of graphs waiting for pr_engine_collect_garbage

    // Control thread only.
    PRGraph *latest; // newest installed graph, which stays alive until the next install
    PRInputRecord *records;

    // Render thread only.
    PRGraph *current;
    double sampleTime;
    bool wasPlaying;

    _Atomic(double) tempo;
    _Atomic(bool) playing;
    _Atomic(bool) transportChanged;
    _Atomic(double) beat;
    _Atomic(double) timelineSample;
    _Atomic(double) load;

    PRMidiRing midi[PR_MIDI_SLOTS];
};

/// Zeroed memory with its pages touched, so the render thread never takes a page fault on it.
/// size must not be 0.
void *pr_alloc(size_t size);

/// Pushes onto the retired stack. Lock-free: called from the render and control threads.
void pr_graph_retire(PREngine *engine, PRGraph *graph);

// Render thread helpers, in engine.c.
void pr_midi_drain(PREngine *engine, const PRGraph *graph);
void pr_transport_begin_block(PREngine *engine);
void pr_transport_advance(PREngine *engine, uint32_t frames);
void pr_load_update(PREngine *engine, uint64_t ticks, uint32_t frames);

#endif
