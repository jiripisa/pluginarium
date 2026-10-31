# Pluginarium design

Date: 2026-10-31
Status: awaiting approval

## Intent

The owner runs a home studio for electronic music that works fully without a computer (dawless). A Mac mini with Ableton Live and AU plugins sits in the same studio and is always on, but using those plugins today means starting Ableton and rebuilding routing in a tool that feels too complex for the job.

Pluginarium turns the Mac mini into one more instrument, or several, inside the dawless setup. The guiding sentence, in the owner's words, is that working with it should be equivalent to switching on a hardware instrument with its power button. It is a loose relative of Apple MainStage, much simpler.

Setup is the exception and playing is the normal state. When a decision is open, prefer the option with fewer clicks between launching the app and hearing sound.

## The studio

- Audio interface and mixer: Arturia AudioFuse 16Rig, connected to the Mac mini and controlled over MIDI.
- MIDI: all devices go through an iConnectivity mioXL router, connected to the Mac mini.
- Synths and drums: Teo-5, Take-5, Roland TR-8S and others.
- Sequencers: Hapax, Midicake, Berlinan (software).
- Controllers: Arturia KeyLab, Launchpad, Oxi E16, Faderfox.
- The Mac mini is an M4 Pro model. It has a monitor, keyboard and mouse in the studio, but the owner wants to touch them as little as possible while playing.

## Goals for the first version

1. Launch the app, load a saved configuration or quickly build a new one, and play.
2. A configuration is a stack of 1 to n channels. A channel is an instrument plugin or a standalone effect.
3. Each channel is set up with plugin, preset, inputs and audio output.
4. The most common case, one plugin on the channels reserved for the Mac, is close to zero effort.
5. Effects run in series or in parallel, either as inserts behind an instrument or as a standalone effect that serves the whole studio.
6. Plugins that need audio input work: a vocoder played over MIDI with a microphone input, and a compressor with a sidechain input.
7. Plugins with tempo sync follow the MIDI clock of the studio.
8. Plugin windows open and close from the app, and plugin settings are saved as named presets.

## Non-goals for the first version

- VST and VST3 hosting. The first version hosts Audio Units only (decided by the owner).
- MIDI learn and control of plugin parameters from MIDI controllers. This is planned next, see Later.
- Fast switching between configurations during a session. One configuration is used per session.
- Sidechain from another Pluginarium channel. The sidechain source is an audio interface input.
- Latency compensation against hardware. The app runs at a low buffer size and does not delay or align anything (decided by the owner).
- Support for specific vocoder or compressor products. The first version supports any AU that exposes these inputs. The owner has bought such plugins but has not picked which ones to use.
- Faders, panning, or level mixing. The AudioFuse is the mixer.
- Recording, sequencing, arranging.
- Starting automatically when the Mac starts. The owner launches the app.

## Anti-goals

The result is a failure even if it technically works when:

- It feels like a smaller Ableton, with setup work standing between launch and sound.
- A configuration refuses to load because one plugin or device is missing.
- The owner has to look at the Mac during normal playing.

## Later

Keep these possible, do not build them yet:

- MIDI learn: the app lists a plugin's parameters that can be controlled and maps them to controllers with learn. The AU parameter lists are suitable for this (TB-303 exposes 22, JUPITER-8 97, Mariana 177 on the tested machine).
- Fast switching between configurations.
- Sidechain taken from another channel.
- Tuning latency against hardware instruments. The owner wants this after the first version.

## User interface

The approved reference is the clickable prototype in `ui-prototype/`. Open `index.html` in a browser. Where this document and the prototype differ, this document wins. Sample data in the prototype, including its device names, channel names, presets, and the two plugins marked `(sample)`, is not a requirement.

### Look

Synth front panel: dark panel, cream silk-screen legends, amber LEDs, walnut cheeks at the window edges, in the spirit of the owner's Sequential synths. Typefaces are DIN Condensed and DIN Alternate, both shipped with macOS. Interface text is in English, like the labels on the owner's gear.

### Start screen

Launching the app always opens this screen, and the owner picks what to load (decided by the owner). It has the wordmark, a list of saved configurations with the plugins each one uses, and actions for a new configuration and settings.

### Mixer screen

Channels are columns, like a mixing console, with signal flowing from top to bottom. The top bar shows the configuration name with a menu (load, new, save as), unsaved state with a Save button, MIDI clock state and tempo, CPU load and Settings.

A channel shows, top to bottom:

1. Position in the stack and a remove control.
2. Inputs, depending on the plugin (see Channels follow the plugin).
3. Plugin name and preset selector.
4. Button that opens and closes the plugin window.
5. Effect slots. Effects stacked vertically run in series. Effects side by side in one row run in parallel, joined by split and merge lines. Up to 3 effects share a row. Clicking an effect opens a menu: open or close plugin, presets, sidechain input if the plugin has one, add parallel effect, move to series, remove.
6. Level meter and audio output.

### Add dialog

A centered dialog is used to add an instrument or standalone effect, add an insert effect, and replace a missing plugin. It has search, recently used plugins, all plugins, and a preset column for the selected plugin. Enter in the search field accepts the selection, and arrow keys move it. Routing is filled in automatically and can be changed in the dialog.

A new configuration opens this dialog right away.

### Settings

Audio device, sample rate, buffer size, MIDI clock source, and the tables that map positions to default routing.

## Behaviour

### Channels follow the plugin

A channel shows only the inputs its plugin can use:

| Plugin ability | Field shown |
| --- | --- |
| Accepts MIDI | MIDI in: device and channel, or all channels |
| Has a main audio input | Audio in |
| Has a sidechain input | Sidechain in, with Off as an option |
| Always | Audio out |

A normal instrument shows MIDI in and Audio out. A vocoder played over MIDI shows MIDI in, Audio in and Audio out. A standalone compressor shows Audio in, Sidechain in and Audio out. An insert effect receives its signal from the chain, so only its sidechain input needs setting, and that happens in the effect's menu.

Audio Unit type decides where a plugin belongs. Music devices (`aumu`) and music effects (`aumf`) are listed as instruments, because they are played over MIDI. Effects (`aufx`) are listed as effects. On an instrument, Audio in offers Off and starts at Off, so a synth with an input bus never receives signal by accident. A vocoder that needs a microphone shows it as unset until the owner picks an input.

If a plugin takes its modulator through a sidechain bus instead of a main input, the same field appears as Sidechain in.

### MIDI devices

MIDI in lists the MIDI sources as macOS reports them, including virtual ports, so ports of the mioXL router and software sequencers appear under their system names. The app does not assume one port per instrument. A device behind the router may stay visible while it is switched off, so "not connected" means the MIDI source is missing from the system.

### Default routing

Default routing comes from the position in the stack. Position 1 gets the channels reserved for the Mac as one instrument, position 2 the channels reserved for a second instrument, and so on. Instruments and standalone effects have separate position tables, set once in Settings. Routing can be changed on any channel.

### Standalone effects and studio use

A standalone effect takes signal from an audio input and sends it to an audio output, so any hardware instrument can reach it through the AudioFuse.

### Tempo

Plugins with tempo sync follow the MIDI clock from the source chosen in Settings. Example: ZEN Delay on a channel follows the Hapax.

Plugins never receive MIDI clock messages. The app reads the clock and gives each plugin the tempo, the position and whether the transport is playing.

Each channel and each insert effect has a Follow Start/Stop switch, saved in the configuration (decided by the owner). Tempo always reaches the plugin.

- On: the plugin sees tempo and transport, so an arpeggiator or internal sequencer runs with the Hapax.
- Off: the plugin sees tempo only, and to it the transport is always stopped. A delay keeps its tempo, and an internal sequencer stays still. Example: a TB-303 plugin stays silent when the Hapax starts, unless it gets notes.

The switch starts off on instruments and on on effects, so a sequencer never starts a part the owner did not ask for. Notes and controllers follow the channel's MIDI in, whatever the switch says.

### Presets

A preset is a named snapshot of a plugin's state, stored per plugin and available in every configuration.

Tested on the owner's MacBook Air: TB-303 and JUPITER-8 do not expose factory presets as Audio Units, Mariana does. A VST3 probe also returned no programs from the Roland plugins, though it returned no parameters either, so that result is not conclusive. VST3 is out of scope anyway.

So the preset selector shows the owner's presets, and factory presets only when the plugin exposes them. For a plugin that exposes none, the owner picks a sound in the plugin window and saves it as a preset. The selector explains this in one line.

### Saving

- Any change to a configuration marks it unsaved.
- Saving a preset while in a saved configuration asks whether to save the configuration too.
- A preset is stored for good the moment it is saved, in every case. What waits for the configuration is only the fact that this configuration uses it.
- In a configuration that has not been saved yet, this choice is saved along with the configuration.
- Leaving a configuration with unsaved changes asks: save, don't save, or cancel. Choosing don't save never removes a preset.
- Saving a new configuration asks for a name.

### Missing plugins and devices

A configuration always loads. A channel whose plugin is missing shows that it is not installed and offers Replace plugin. A channel whose MIDI source is missing shows that it is not connected. Other channels play normally. The top bar shows No MIDI clock when clock messages stop arriving from the chosen source, whether or not the source is still present.

## Technical decisions

- Native macOS app in Swift, using Apple's audio frameworks. Audio Units need no third-party SDK, which is why AU-only was chosen. (Owner decided AU-only, the language and frameworks follow from it and are my call.)
- Target machine is the Mac mini M4 Pro. Its macOS version is not known yet, so the deployment target is macOS 15, the oldest version that model can run.
- Development happens on a MacBook Air with Xcode 26.6 and Swift 6.3. It has the Roland and Moog plugins installed but not the AudioFuse, the mioXL, ZEN Delay or Valhalla.

## Testing in the studio

The studio hardware is not available during normal development. The owner will either set up the development environment on the Mac mini or connect the MacBook Air to the AudioFuse and mioXL when in the studio.

The plan must therefore work in two stages: everything testable on the MacBook Air first, including with its built-in audio, then a defined studio session that proves the hardware paths. Studio steps must be run by the owner or with the owner present. Do not assume access to the Mac mini before that session.

The list of plugins installed on the Mac mini is collected in the studio session. Intel-only plugins are not a goal, and one that cannot load is treated as a missing plugin.

## Risks to prove early

Prove these with the smallest possible test before building on them.

1. **Preset recall.** The preset design depends on a plugin restoring the selected sound from its saved state. Proven on 2026-10-31: the owner picked a sound in TB-303 and in JUPITER-8, saved state with the probe, and both showed the same sound after restoring it in a new process.
2. **Multichannel routing.** The app must address individual inputs and outputs of the AudioFuse from one process. This is the core of the app, so it goes first in the studio session.
3. **Audio input and sidechain paths.** No plugin on the MacBook Air proves them with a real vocoder or sidechain compressor, because all its effects are Apple's and none is known to expose a sidechain. Build against a small test Audio Unit that declares these inputs, then confirm in the studio with one of the owner's purchased plugins. Which one is chosen at that point.
4. **Latency through the Mac.** Audio in and sidechain signals pass through the Mac and arrive one round trip late, and a plugin played over MIDI sounds later than hardware triggered by the same sequencer. Measure this with the AudioFuse at the default buffer size and report the numbers. There is no fixed limit, the owner judges it by ear, and any remaining offset is corrected on the sequencer for now.

## My calls

Decided while writing this, not discussed with the owner:

- A configuration stores each plugin's full state, independent of later edits to a preset of the same name.
- Parallel branches are summed equally. Balance comes from each plugin's own wet and dry controls.
- Input selectors offer mono channels as well as stereo pairs, because a vocoder microphone is mono. The prototype shows stereo pairs only.
- With no clock running, plugins get the last known tempo, or 120 BPM if there has been none.
- MIDI start, stop and continue from the clock source drive the transport that plugins see.
- CPU load in the top bar reports the app's audio load.
- `aumu` and `aumf` plugins are instruments, `aufx` plugins are effects, and Audio in on an instrument starts at Off.
- MIDI in stores system MIDI sources, and clock state is measured from incoming clock messages.
- The deployment target is macOS 15.
- A small test Audio Unit with audio and sidechain inputs is built for development.

## Left to the builder

- App architecture, project layout, audio graph design, and threading.
- Storage format and location for configurations and presets.
- How Settings stores position tables, and how many positions exist.
- Handling of plugin latency between parallel branches.
- Plugin scanning and its caching.
- Keyboard shortcuts beyond the ones the prototype has.
- Build, signing, and distribution.
