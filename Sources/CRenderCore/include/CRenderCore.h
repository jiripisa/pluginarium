#ifndef CRenderCore_h
#define CRenderCore_h

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

// Real-time render core.
//
// Threads:
// - pr_engine_render runs on the audio thread and never allocates, locks or blocks. So does the
//   render callback of a PRDeviceLink, which calls it.
// - pr_engine_push_midi takes one producer thread per slot.
// - pr_engine_set_transport and pr_engine_rewind_transport can be called from any thread.
// - Everything else belongs to one control thread, the main thread in the app.

/// Device channels. left == -1: off. right == -1: mono.
typedef struct { int32_t left, right; } PRChannels;

/// channels is the unit's channel count, 1 or 2.
typedef struct { AudioUnit unit; PRChannels sidechain; uint32_t channels; } PREffect;

/// Effects in one row run in parallel and their outputs sum. Rows run in series.
typedef struct { const PREffect *effects; uint32_t count; } PRRow;

/// A standalone effect is a strip whose source is the effect itself.
typedef struct {
    AudioUnit source;
    PRChannels audioIn;
    PRChannels sidechain;
    uint32_t sourceChannels;
    const PRRow *rows;
    uint32_t rowCount;
    PRChannels audioOut;
    int32_t midiSlot; // -1: none
} PRStrip;

typedef struct PREngine PREngine;

/// Returns NULL when maxFrames is 0 or sampleRate is not positive.
PREngine *pr_engine_create(uint32_t maxFrames, double sampleRate);

/// Call only after audio has stopped. Frees all graphs and input records.
void pr_engine_destroy(PREngine *engine);

/// Copies its input and allocates all buffers; the arrays can be released on return.
/// The new graph takes over at the start of the next render. Returns its generation, which
/// increases by one per install.
///
/// Returns UINT64_MAX when allocation fails. Nothing was replaced: the previous graph stays, the
/// caller keeps every unit, and the value must not be passed to pr_engine_is_generation_taken.
///
/// A caller keeps every unit of a replaced graph alive until pr_engine_is_generation_taken
/// returns true for the generation that replaced it.
uint64_t pr_engine_install_graph(PREngine *engine, const PRStrip *strips, uint32_t count);

/// True once a render has started a block with this generation or a newer one, so no render can
/// still use an older graph. True for every generation while audio is not running, since no render
/// is coming. Always false for UINT64_MAX, so misuse leaks units instead of disposing live ones.
bool pr_engine_is_generation_taken(PREngine *engine, uint64_t generation);

/// Tells the engine whether a render can run at the same time as a disposal. The default is false,
/// which requires that no render runs concurrently with a disposal. Set it true before the first
/// render, and false only after the device has fully stopped.
void pr_engine_set_audio_running(PREngine *engine, bool running);

/// The rate the beat and load calculations use. Call only while audio is stopped. A rate that is
/// not positive keeps the last one.
void pr_engine_set_sample_rate(PREngine *engine, double sampleRate);

/// Frees graphs the render thread has finished with.
void pr_engine_collect_garbage(PREngine *engine);

/// Clears out, then renders every strip of the current graph. A block larger than
/// maxFrames renders in chunks. Output is not clipped.
void pr_engine_render(PREngine *engine, uint32_t frames,
                      const float *const *in, uint32_t inChannels,
                      float *const *out, uint32_t outChannels);

/// Queues a MIDI message for the strip on slot 0...63. Other slots are ignored,
/// and a full ring drops the message.
void pr_engine_push_midi(PREngine *engine, int32_t slot, uint8_t status, uint8_t d1, uint8_t d2);

/// A tempo that is not positive keeps the last one. The default is 120 BPM, stopped.
void pr_engine_set_transport(PREngine *engine, double tempo, bool playing);

/// Takes beat and timeline sample back to zero on the render thread, at the start of the next
/// block, which tells units the transport changed. Playing or stopped stays as it is. To start
/// from zero, call this before the pr_engine_set_transport that starts playing, and a block that
/// plays will also see the rewind.
void pr_engine_rewind_transport(PREngine *engine);

/// The highest peak of the strip in the newest installed graph since the last read, which this
/// resets, so a meter polled slower than the blocks still sees every peak. 0 for a strip that does
/// not exist. Control thread only.
void pr_engine_read_meters(PREngine *engine, uint32_t strip, float *left, float *right);

/// Smoothed ratio of render time to block duration.
double pr_engine_load(PREngine *engine);

/// Installs beat, tempo and transport callbacks reading the engine's transport.
OSStatus pr_install_host_callbacks(AudioUnit unit, PREngine *engine);

/// The callbacks pr_install_host_callbacks gives a unit. The property itself cannot be read back.
HostCallbackInfo pr_host_callback_info(PREngine *engine);

/// Gives the unit its input record and sets the render callback on every input bus. Call it
/// before installing a graph with the unit. Safe to call again for the same unit. Bus 0 carries
/// the main input, bus 1 the sidechain, and any further bus reads silence.
OSStatus pr_install_input_callbacks(AudioUnit unit, PREngine *engine);

/// Joins one AUHAL unit to the engine: the unit's render callback pulls the device's input, then
/// renders the engine into the device's output.
typedef struct PRDeviceLink PRDeviceLink;

/// Allocates everything the callback uses, so call it while stopped. unit is only used when
/// inChannels is above 0, and input frames beyond maxFrames in one block read as silence, as do
/// frames the unit cannot deliver. Returns NULL when maxFrames or outChannels is 0, or allocation
/// fails.
PRDeviceLink *pr_device_link_create(PREngine *engine, AudioUnit unit, uint32_t maxFrames,
                                    uint32_t inChannels, uint32_t outChannels);

/// The callback to set on the unit's input scope, element 0.
AURenderCallbackStruct pr_device_link_render_callback(PRDeviceLink *link);

/// A callback that starts after this writes silence and leaves the engine alone.
void pr_device_link_close(PRDeviceLink *link);

/// True while no callback is running. Once the link is closed, true also means no callback will
/// reach the engine again, whatever the unit does next.
bool pr_device_link_is_idle(PRDeviceLink *link);

/// Call only after the unit has been disposed.
void pr_device_link_destroy(PRDeviceLink *link);

#endif
