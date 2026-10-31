# Pluginarium

Your plugins as instruments in the studio.

Native macOS app (SwiftUI, macOS 15 or later), built with Swift Package
Manager and shell scripts; no Xcode project.

## Build and run

You need the Xcode command line tools.

```
./run.sh            # debug build, runs in the terminal with logs (Ctrl+C quits)
./run.sh release    # optimized build, opens the app
swift test          # tests
./build.sh dist     # signed, notarized DMG (needs a Developer ID, see development_workflow.md)
```

Details: [development_workflow.md](development_workflow.md).

## License

GPL-3.0, see [LICENSE](LICENSE).
