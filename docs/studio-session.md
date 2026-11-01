# Studio session

Two parts: what was walked through on the MacBook Air and the MOTU M4 (Task 17,
done), and the checklist for the studio (Task 18, not run yet). Spec:
[design](superpowers/specs/2026-10-31-pluginarium-design.md).

## MacBook walkthrough results (Task 17)

The owner walked the goals on the MacBook Air and reported that everything
works and that opening and closing a plugin causes no "Unsaved changes". Three
more passes were run on the MacBook with the MOTU M4 as the default output, with
the owner's approval and no device picked in Settings, so nothing was written to
the device. Plugins used: Roland TB-303 and JUPITER-8, Apple units, Mariana.

| Spec goal | Result | Notes |
| --- | --- | --- |
| 1. Launch, load a saved configuration, play | Pass | Owner's walkthrough. |
| 2. Configuration as a stack of channels | Pass | Four plugins loaded at once in the performance runs. |
| 3. Plugin, preset, inputs and audio output per channel | Pass | Presets saved and used in a second configuration. Factory presets only where the plugin exposes them. |
| 4. One plugin, close to zero effort | Pass | New configuration with Return only. A new channel whose default output is beyond the device takes the first free stereo pair. |
| 5. Effects in series or parallel | Pass | Parallel effects with Apple units. |
| 6. Plugins with audio input or sidechain | Limited | Covered by a test unit only. A real vocoder and sidechain compressor wait for the studio. |
| 7. Tempo sync with MIDI clock | Limited | Follow Start/Stop proven on a real TB-303 both ways and during playback. Tempo from a real clock source not tried here. |
| 8. Plugin windows and named presets | Pass, with a limit | Open and close work. A false "changed" mark on Mariana is fixed. See below. |

Timings, from the ledger:

- Four plugins ready in 1.5 to 1.7 s (1.57 s, then 1.67 s on the latest build).
- Longest stall of the interface while a plugin loads: 0.53 s, once 1.05 s; an
  earlier build with Mariana showed 1.2 s. First-time selection of a plugin
  stalls the interface about 1.3 s by design.
- CPU load with four plugins: 17 percent idle.
- Launch to sound with TB-303: no figure was recorded. The spec sets no limit.
- Quit takes 1.5 to 2.3 s with no window open.

### What is unproven

- A real knob change on Mariana. Its sign-in panel blocks the controls, so a
  change made by hand could not be tried. Open and close with no change gives no
  false mark, and a TB-303 change is detected correctly.
- Everything by ear. The passes checked meters, routing and state, and sound on
  Out 3-4 of the M4 in stretches under 3 s. Nobody judged sound quality.
- An activated Mariana. The runs used an unactivated one. Repeat on the owner's
  install.
- Real hardware paths: see the checklist below.

### Known limits found in the walkthrough

- With a plugin window open and a changed sound, Command-S is disabled and the
  bar reads Saved until the window closes.
- The render core has no limiter, DC block or non-finite guard.

## Studio session checklist (Task 18)

Not run yet. The owner runs it in the studio, or Claude Code runs it there with
the owner present. Fill the Result column as you go.

**Before the first start: get the owner's OK.** Picking the AudioFuse in
Settings can write its sample rate and buffer size. A followed System default
writes nothing: with no device picked the app adopts the device's current rate
and buffer. Hardware tests with real plugins also need the owner's OK. Keep
monitors low for the first start, and use silent units only.

Notes for the session:

- Loading a plugin stalls the interface briefly, by design: every Audio Unit
  lifecycle call runs on the main thread. Audio on other channels keeps running.
- Test units that output non-audio signals never reach the app. Do not use a
  standalone effect with a live input as a look check.

| Step | What to do | Expected | Result |
| --- | --- | --- | --- |
| 2. Inventory | On the Mac mini run `sw_vers -productVersion` and `auval -a \| grep -E '^(aumu\|aufx\|aumf)'`. | macOS 15 or newer. The list is recorded, including ZEN Delay and Valhalla. | |
| 3a. Routing (risk 2) | Play a plugin to each reserved output pair on the AudioFuse. | Sound on exactly that pair. | |
| 3b. Standalone effect | Feed a hardware synth into an input and run Valhalla as a standalone effect. | Reverb on the chosen output. | |
| 4a. MIDI ports | Check how mioXL ports appear. Play from Hapax and KeyLab. | Ports listed under system names. Notes arrive. | |
| 4b. Channel filter | Send on a channel other than the one set. | The filter holds. | |
| 4c. Switch-off | Switch off a device and record whether its port disappears. | Recorded. | |
| 4d. Berlinan | Record whether Berlinan appears as a source. | Recorded. | |
| 5. Clock | Set the Hapax as clock source and run ZEN Delay at two tempos. Start and stop the transport. Stop the clock. | Delay follows the tempo. Start and stop work. The bar shows No MIDI clock. | |
| 6. Inputs (risk 3) | With one purchased vocoder and one sidechain compressor, check the fields and the signals. Record plugins that expose no sidechain. | Fields appear and the signals work. | |
| 7. Latency (risk 4) | Record the round trip with the AudioFuse at 128 frames and at the lowest stable buffer size. Judge by ear against a hardware instrument triggered by the same sequencer. | Numbers recorded, owner's judgement noted. | |

Hardware paths that no test could reach, from the ledger. Run each once:

| Check | What to do | Result |
| --- | --- | --- |
| AUHAL with input enabled | Run a configuration with an audio input on the AudioFuse. Input signal arrives. | |
| Device writes with a picked device | After the owner's OK, pick the AudioFuse in Settings. Change sample rate and buffer size. They are applied and read back. | |
| Rate change on a device with inputs | Change the rate while inputs are in use. Audio recovers, no crash. | |
| Real device unplug | Unplug the interface while running, then plug it back. The configuration keeps going and returns when the device returns. | |
| `DeviceListListener` | Plug and unplug a device. The device list in Settings updates. | |
| Stop timeout | Quit and restart with audio running. Stop returns without hanging. | |
| Real CoreMIDI delivery through the mioXL | Play notes and clock from a real source through the mioXL. They arrive, and sources added later are connected. | |

After the session, commit the results and turn any failures into new tasks with
the owner.
