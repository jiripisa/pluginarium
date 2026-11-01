# Pluginarium

Your plugins as instruments in the studio.

Pluginarium turns a Mac into one more instrument, or several, in a studio that
works without a computer. Pick a saved configuration, and the plugins in it play
over MIDI through the audio channels you chose. It is meant to feel like
switching on a hardware synth, not like starting a DAW.

Native macOS app (SwiftUI, macOS 15 or later), built with Swift Package
Manager and shell scripts; no Xcode project.

## Requirements

- macOS 15 or later.
- Audio Units only. VST and VST3 are not hosted.
- Xcode command line tools to build.

## Build and run

```
./run.sh            # debug build, runs in the terminal with logs (Ctrl+C quits)
./run.sh release    # optimized build, opens the app
swift test          # tests
./build.sh dist     # signed, notarized DMG (needs a Developer ID, see development_workflow.md)
```

Details: [development_workflow.md](development_workflow.md).

## More

- Design and goals: [docs/superpowers/specs/2026-10-31-pluginarium-design.md](docs/superpowers/specs/2026-10-31-pluginarium-design.md)
- Walkthrough results and studio checklist: [docs/studio-session.md](docs/studio-session.md)

## License

GPL-3.0, see [LICENSE](LICENSE).
