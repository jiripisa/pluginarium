# Pluginarium — project notes for Claude

Your plugins as instruments in the studio.

## Code

- Native macOS app, SwiftUI, macOS 15+. Swift Package Manager plus shell
  scripts; there is no Xcode project, so never add one.
- `Sources/PluginariumCore` holds logic without UI (no SwiftUI/AppKit) and is
  covered by `swift test` (Swift Testing). `Sources/Pluginarium` is the SwiftUI
  app and stays a thin layer over the core. New logic goes into the core,
  test first.
- Build and run: `./run.sh` (debug, logs in the terminal), `./run.sh release`,
  `./build.sh [debug|release|dist|clean]`. Details in `development_workflow.md`.
- Every user-visible change gets a line under `## Unreleased` in
  `CHANGELOG.md`; the release notes come from it.

## Rules that are easy to break

- Every Audio Unit lifecycle call (instantiate, initialize, restore,
  uninitialize, dispose, factory preset select) runs on the main thread. JUCE
  plugins crash otherwise. A `HostedPlugin` released elsewhere hands its
  disposal to the main thread.
- Never compare plugin state with stored state: plugins regenerate per-instance
  data (ids, names, time stamps). A change means the state read when the window
  opened differs from the state read when it closes, in the same instance.
- Units go before the engine, and the router before the engine.
- The render thread never allocates, locks, logs or calls Swift.
- A nil `audioDeviceUID` follows the default device and never writes its sample
  rate or buffer size. Only a device picked in Settings is written.
- Checks with audio running use silent units only. No test unit that makes a
  test signal may reach the app, and no standalone effect with a live input.
- Hardware tests with real plugins need the owner's OK.

## Releases

- Use the project skill `release` (`.claude/skills/release/SKILL.md`) for
  every release; it holds the whole procedure and its checks.
- Signing: Developer ID Application certificate and the `notary`
  notarytool profile live in the login Keychain.
