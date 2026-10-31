# Changelog

## Unreleased

- First version.
- Start screen with your saved configurations and the plugins each one uses, on the synth panel with walnut cheeks.
- A configuration keeps playing through device changes and comes back when its audio device returns.
- Mixer screen with a column per instrument or effect: MIDI, audio and sidechain selectors that follow the plugin and the audio device, level meters, the MIDI clock and CPU load in the top bar, and clear messages for missing plugins, MIDI devices and audio channels.
- Level meters hold each peak until it is drawn, so short notes are not missed.
- Add dialog: type a few letters, press Return, and the plugin is in. Recent plugins come first, the sound can be picked, and the routing follows the plugin. It also replaces the plugin of a channel.
- Effect slots: series rows and up to three parallel effects joined by split and merge lines, each with a menu to open the plugin, pick its preset and sidechain, add a parallel effect, move it to series or remove it. An effect that failed to load shows in red, with the reason in its tooltip.
- Plugin windows open over the mixer, follow the size the plugin asks for, step aside for dialogs and Settings, and close with their plugin. Closing one, or an audio device change, notices a changed sound and marks the configuration unsaved.
- Presets: pick your own or the plugin's factory presets on a running plugin, save the current sound under a name, and choose whether the saved configuration follows. A sound that moved away from its preset reads "(changed)".
- Saving: Save, Save as and a name for a new configuration, in the top bar and the File menu with Command-S and Command-Shift-S. Leaving a configuration with unsaved changes, or quitting, asks "Save changes?". A plugin whose sound cannot be read keeps its last saved sound, and a configuration that cannot be written stays unsaved. A plugin you did not touch stays on "Default sound" after saving.
- Settings (Command-comma, from the Start screen and the mixer): audio device, sample rate and buffer size, MIDI clock source, and the default routing of instrument and effect positions. With System default the device keeps its own sample rate and buffer size, and these show what runs.
- Fixed a crash when a plugin was unloaded.
