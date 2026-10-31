# Changelog

## Unreleased

- First version.
- Start screen with your saved configurations and the plugins each one uses, on the synth panel with walnut cheeks.
- A configuration keeps playing through device changes and comes back when its audio device returns.
- Mixer screen with a column per instrument or effect: MIDI, audio and sidechain selectors that follow the plugin and the audio device, level meters, the MIDI clock and CPU load in the top bar, and clear messages for missing plugins, MIDI devices and audio channels.
- Level meters hold each peak until it is drawn, so short notes are not missed.
- Add dialog: type a few letters, press Return, and the plugin is in. Recent plugins come first, the sound can be picked, and the routing follows the plugin. It also replaces the plugin of a channel.
- Effect slots: series rows and up to three parallel effects joined by split and merge lines, each with a menu to open the plugin, pick its preset and sidechain, add a parallel effect, move it to series or remove it. An effect that failed to load shows in red, with the reason in its tooltip.
- Plugin windows open over the mixer, follow the size the plugin asks for, and close with their plugin. Closing one notices a changed sound and marks the configuration unsaved.
- Presets: pick your own or the plugin's factory presets on a running plugin, save the current sound under a name, and choose whether the saved configuration follows. A sound that moved away from its preset reads "(changed)".
