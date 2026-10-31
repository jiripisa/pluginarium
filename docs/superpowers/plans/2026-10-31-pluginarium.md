# Pluginarium First Version Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS app that hosts Audio Units as instruments and effects in a dawless studio, with saved configurations, per-channel routing, series and parallel effects, MIDI clock sync, and the approved synth-panel interface.

**Architecture:** Three layers under a thin SwiftUI app. `PluginariumCore` is pure Swift logic with no audio or UI imports. `PluginariumAudio` wraps Apple's audio and MIDI frameworks. `CRenderCore` is a small C target that owns everything on the real-time audio thread, because that code must not allocate, lock or touch Swift reference counts. One AUHAL unit drives a custom render graph, since `AVAudioEngine` cannot send separate sources to separate device channels.

**Tech Stack:** Swift 6 language mode, SwiftUI with AppKit plugin windows, C for the render core, AudioToolbox, CoreAudio, CoreMIDI, Swift Testing, Swift Package Manager with `build.sh` and `run.sh`.

**Spec:** `docs/superpowers/specs/2026-10-31-pluginarium-design.md`. UI reference: `ui-prototype/`.

## Global Constraints

- Deployment target macOS 15.0, Apple silicon only.
- Audio Units only: types `aumu`, `aumf`, `aufx`. No VST or VST3.
- SwiftPM only. Never create an Xcode project (`new-macos-app` rule).
- No third-party dependencies in the first version.
- Code, comments, commit messages and interface text are in English.
- Interface copy matches the prototype: "Open plugin", "Close plugin", "Add effect", "Save preset", "No MIDI clock", "Replace plugin", "Unsaved changes".
- Colors: panel `#2a2b2e`, deep `#191a1c`, raised `#333438`, legend `#ece8dc`, muted `#a9a698`, line `#55554f`, strong line `#8f8c80`, LED `#ff8a1f`, LED soft `#ffb066`, fault `#ff6a52`, walnut `#6d4529`.
- Fonts: DIN Condensed for names and headings, DIN Alternate for everything else.
- The app never sends MIDI to any device. The render thread never allocates, locks, logs or calls Swift.
- Commits have no AI attribution trailers. Check `git status` before every commit. Never push without the owner's explicit confirmation.
- Setting a sample rate or buffer size writes to a connected audio interface, so that path runs against studio hardware only during the studio session with the owner's OK.
- Every user-visible change adds a line under `## Unreleased` in `CHANGELOG.md`.

## Review Focus

1. A plugin that fails to load or initialize must leave the other channels playing and show a fault on its own channel. Test in Task 9.
2. An audio device that disappears during a session must stop audio cleanly, show the state, and resume when it returns. Test in Task 10.
3. A corrupt or unreadable configuration or preset file must be skipped, and the Start screen must list the rest. Test in Task 5.
4. Saving a preset under a name that already exists replaces it, and never creates a duplicate. Test in Task 5.
5. A configuration routed to channels the current device does not have, such as outputs 15 and 16 on MacBook speakers, must load and show a routing fault on that channel. Test in Task 9.

---

## File Structure

```
Package.swift, build.sh, run.sh, CLAUDE.md, CHANGELOG.md, development_workflow.md
Resources/                  Info.plist, entitlements, icon
Sources/
  PluginariumCore/          Models.swift, EffectChain.swift, ChannelFields.swift,
                            Routing.swift, Stores.swift, EditingSession.swift,
                            ClockTracker.swift, MIDIEvent.swift
  CRenderCore/              include/CRenderCore.h, engine.c, graph.c, host_callbacks.c
  PluginariumAudio/         PluginCatalog.swift, HostedPlugin.swift, PluginView.swift,
                            GraphBuilder.swift, ConfigurationRunner.swift,
                            DeviceCatalog.swift, AudioEngine.swift, MIDIRouter.swift
  PluginariumTestUnits/     TestUnits.swift
  pluginarium-probe/        main.swift
  Pluginarium/              PluginariumApp.swift, AppModel.swift, Theme.swift,
                            StartScreen.swift, MixerScreen.swift, ChannelView.swift,
                            EffectSlots.swift, MeterView.swift, AddSheet.swift,
                            Dialogs.swift, SettingsScreen.swift, PluginWindows.swift
Tests/
  PluginariumCoreTests/     one file per Core source file
  PluginariumAudioTests/    HostingTests, RenderCoreTests, GraphBuilderTests,
                            RunnerTests, AudioEngineTests
docs/studio-session.md
```

---

## Phase 1: Prove the risky part

### Task 1: Project skeleton

**Files:**
- Create: all skeleton files from the `new-macos-app` templates
- Modify: `Package.swift`, `.gitignore`

**Interfaces:**
- Produces: SwiftPM targets `PluginariumCore`, `CRenderCore`, `PluginariumAudio` (depends on the first two), `PluginariumTestUnits`, executables `Pluginarium` and `pluginarium-probe`, test targets `PluginariumCoreTests` and `PluginariumAudioTests`.

- [ ] **Step 1: Run the `new-macos-app` skill** with `APP=Pluginarium`, `APP_NAME=Pluginarium`, `APP_LOWER=pluginarium`, `BUNDLE_ID=io.jp4.pluginarium`, `MIN_MACOS=15.0`. Ask the owner the skill's repo, license and website questions. The target directory already exists and holds `docs/` and `ui-prototype/`, so render with `--out` into the scratchpad and move the result in without overwriting `docs/superpowers/`. Skip the skill's website steps if the owner declines a website.
- [ ] **Step 2: Add the extra targets to `Package.swift`.** `CRenderCore` needs `.linkerSettings` for `AudioToolbox` and `CoreAudio`. Add `.superpowers/` to `.gitignore`.
- [ ] **Step 3: Verify the build.** Run `swift test && ./build.sh debug`. Expected: tests pass and `build/debug/Pluginarium.app` exists.
- [ ] **Step 4: Commit.** Run `git init -b main` if the skill has not, check `git status`, then commit `chore: app skeleton`. Do not create a GitHub repo or push until the owner confirms.

### Task 2: Plugin catalog and hosted plugin

**Files:**
- Create: `Sources/PluginariumAudio/PluginCatalog.swift`, `Sources/PluginariumAudio/HostedPlugin.swift`, `Sources/PluginariumTestUnits/TestUnits.swift`, `Sources/PluginariumCore/Models.swift` (only `PluginID`, `PluginKind`, `PluginCapabilities`, `PluginInfo`)
- Test: `Tests/PluginariumAudioTests/HostingTests.swift`, `Tests/PluginariumCoreTests/CapabilitiesTests.swift`

**Interfaces:**
- Produces in Core:
  - `struct PluginID: Hashable, Codable, Sendable { var type, subtype, manufacturer: String }`, four-character codes.
  - `enum PluginKind: String, Codable, Sendable { case instrument, effect }` with `init?(auType: String)`: `aumu` and `aumf` are `.instrument`, `aufx` is `.effect`.
  - `struct PluginCapabilities: Codable, Equatable, Sendable { var acceptsMIDI, hasAudioIn, hasSidechain: Bool }` with `static func derive(auType: String, inputBusNames: [String]) -> PluginCapabilities`.
  - `struct PluginInfo: Codable, Identifiable, Sendable { var id: PluginID; var name, vendor: String; var kind: PluginKind }`.
- Produces in Audio:
  - `enum PluginCatalog { static func scan() -> [PluginInfo] }`, using `AudioComponentFindNext`.
  - `final class HostedPlugin`: `static func load(_ id: PluginID) async throws -> HostedPlugin`, `var audioUnit: AudioUnit`, `var inputBusNames: [String]`, `func configure(sampleRate: Double, maxFrames: UInt32) throws`, `func fullState() throws -> Data`, `func restore(_ state: Data) throws`, `func factoryPresets() -> [String]`, `func selectFactoryPreset(_ name: String) throws`.
- Produces in TestUnits: `public func registerTestUnits()` registers in-process, through `AUAudioUnit.registerSubclass`:
  - `aumu/PlIn/Plug`, outputs constant 0.25 while a note is held.
  - `aufx/PlFx/Plug`, one input bus, outputs input × 0.5.
  - `aufx/PlSc/Plug`, two input buses named `Input` and `Sidechain`, outputs main × 0.5 + sidechain × 0.25.
  - `aumf/PlVo/Plug`, one input bus, accepts MIDI.
  - `aufx/PlBd/Plug`, throws from `allocateRenderResources`.

- [ ] **Step 1: Write failing tests.**

```swift
@Test func deriveCapabilities() {
  #expect(PluginCapabilities.derive(auType: "aumu", inputBusNames: []) == PluginCapabilities(acceptsMIDI: true, hasAudioIn: false, hasSidechain: false))
  #expect(PluginCapabilities.derive(auType: "aumf", inputBusNames: ["Input"]) == PluginCapabilities(acceptsMIDI: true, hasAudioIn: true, hasSidechain: false))
  #expect(PluginCapabilities.derive(auType: "aumu", inputBusNames: ["Sidechain"]) == PluginCapabilities(acceptsMIDI: true, hasAudioIn: false, hasSidechain: true))
  #expect(PluginCapabilities.derive(auType: "aufx", inputBusNames: ["Input", "Sidechain"]) == PluginCapabilities(acceptsMIDI: false, hasAudioIn: true, hasSidechain: true))
}

@Test func stateRoundTripOnAppleDelay() async throws {
  let id = PluginID(type: "aufx", subtype: "dely", manufacturer: "appl")
  let first = try await HostedPlugin.load(id)
  AudioUnitSetParameter(first.audioUnit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, 12, 0)
  let second = try await HostedPlugin.load(id)
  try second.restore(try first.fullState())
  var value: AudioUnitParameterValue = 0
  AudioUnitGetParameter(second.audioUnit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, &value)
  #expect(value == 12)
}

@Test func catalogFindsTestUnitsAndKinds() {
  registerTestUnits()
  let infos = PluginCatalog.scan()
  #expect(infos.first { $0.id.subtype == "PlVo" }?.kind == .instrument)
}
```

- [ ] **Step 2: Run them.** `swift test --filter "deriveCapabilities|stateRoundTrip|catalogFinds"`. Expected: fail, symbols missing.
- [ ] **Step 3: Implement.** A bus name counts as sidechain when it contains `side` case-insensitively, or when it is the second bus of an effect. Use `AudioComponentInstantiate` so version 3 units load too, wrapped in a continuation. `fullState` is the `kAudioUnitProperty_ClassInfo` property list serialized as binary plist. `configure` sets `kAudioUnitProperty_MaximumFramesPerSlice` to `maxFrames`, a stereo Float32 deinterleaved format on every bus, falling back to mono when the unit refuses, and calls `AudioUnitInitialize`.
- [ ] **Step 4: Run tests.** Expected: pass.
- [ ] **Step 5: Commit** `feat: load and describe Audio Units`.

### Task 3: Preset recall gate (spec risk 1)

**Files:**
- Create: `Sources/PluginariumAudio/PluginView.swift`, `Sources/pluginarium-probe/main.swift`

**Interfaces:**
- Consumes: `HostedPlugin`.
- Produces: `extension HostedPlugin { @MainActor func makeView() async -> NSView? }`. Try `kAudioUnitProperty_CocoaUI` first, then `kAudioUnitProperty_RequestViewController`. `pluginarium-probe recall <type> <subtype> <manufacturer> <file>` shows the plugin in a window. On window close it writes `fullState()` to the file, or if the file exists, restores it before showing the window.

This task needs the owner, because only a person can pick a sound inside a Roland plugin window. Automated tests cannot prove this risk.

- [ ] **Step 1: Implement the probe.** It needs an `NSApplication` run loop and renders no audio.
- [ ] **Step 2: Build.** `swift build --product pluginarium-probe`. Expected: success.
- [ ] **Step 3: Run with the owner for TB-303.** Command: `.build/debug/pluginarium-probe recall aumu VasC RoCl build/tb303.state`. The owner picks a non-default sound and closes the window, then runs the same command again. Expected: the second run shows the same sound name.
- [ ] **Step 4: Repeat for JUPITER-8** with `aumu Vas6 RoCl`.
- [ ] **Step 5: Decide.** If the sound comes back for both, record the result in the spec under Risks and continue. If it does not, stop the plan and take it to the owner, because the spec says the preset design must be reopened.
- [ ] **Step 6: Commit** `feat: show plugin views and probe preset recall`.

---

## Phase 2: Core logic

### Task 4: Configuration model and effect chain

**Files:**
- Modify: `Sources/PluginariumCore/Models.swift`
- Create: `Sources/PluginariumCore/EffectChain.swift`, `Sources/PluginariumCore/ChannelFields.swift`
- Test: `Tests/PluginariumCoreTests/EffectChainTests.swift`, `Tests/PluginariumCoreTests/ChannelFieldsTests.swift`

**Interfaces:**
- Produces:
  - `enum AudioChannels: Codable, Hashable, Sendable { case mono(Int); case stereo(left: Int, right: Int) }`, zero-based device channels.
  - `enum MIDIChannelFilter: Codable, Hashable, Sendable { case all; case channel(Int) }`, 1 to 16.
  - `struct MIDIRoute: Codable, Hashable, Sendable { var sourceName: String; var channel: MIDIChannelFilter }`.
  - `struct PluginSlot: Codable, Equatable, Sendable { var plugin: PluginID; var displayName: String; var presetName: String?; var state: Data? }`.
  - `struct InsertEffect: Codable, Equatable, Identifiable, Sendable { var id: UUID; var slot: PluginSlot; var sidechainIn: AudioChannels? }`.
  - `struct Channel: Codable, Equatable, Identifiable, Sendable { var id: UUID; var kind: PluginKind; var slot: PluginSlot; var midiIn: MIDIRoute?; var audioIn: AudioChannels?; var sidechainIn: AudioChannels?; var audioOut: AudioChannels; var effects: [[InsertEffect]] }`.
  - `struct Configuration: Codable, Equatable, Identifiable, Sendable { var id: UUID; var name: String; var channels: [Channel] }`.
  - On `Channel`: `static let maxParallel = 3`, `mutating func addEffect(_:)`, `mutating func addParallel(_:toRow:) throws`, `mutating func moveToSeries(effectID:)`, `mutating func removeEffect(effectID:)`.
  - `struct ChannelFields: Equatable { var midiIn, audioIn, sidechainIn: Bool; init(kind: PluginKind, capabilities: PluginCapabilities) }`.

- [ ] **Step 1: Write failing tests.**

```swift
@Test func parallelRowIsCappedAtThree() throws {
  var channel = Channel.fixture(effectRows: [[.fixture()]])
  try channel.addParallel(.fixture(), toRow: 0)
  try channel.addParallel(.fixture(), toRow: 0)
  #expect(throws: ChainError.rowFull) { try channel.addParallel(.fixture(), toRow: 0) }
}

@Test func moveToSeriesPlacesEffectInRowBelow() throws {
  let a = InsertEffect.fixture(), b = InsertEffect.fixture()
  var channel = Channel.fixture(effectRows: [[a, b], [.fixture()]])
  channel.moveToSeries(effectID: b.id)
  #expect(channel.effects.map(\.count) == [1, 1, 1])
  #expect(channel.effects[1][0].id == b.id)
}

@Test func removingLastEffectDropsTheRow() {
  let a = InsertEffect.fixture()
  var channel = Channel.fixture(effectRows: [[a]])
  channel.removeEffect(effectID: a.id)
  #expect(channel.effects.isEmpty)
}

@Test func fieldsFollowThePlugin() {
  let synth = PluginCapabilities(acceptsMIDI: true, hasAudioIn: false, hasSidechain: false)
  #expect(ChannelFields(kind: .instrument, capabilities: synth) == ChannelFields(midiIn: true, audioIn: false, sidechainIn: false))
  let vocoder = PluginCapabilities(acceptsMIDI: true, hasAudioIn: true, hasSidechain: false)
  #expect(ChannelFields(kind: .instrument, capabilities: vocoder) == ChannelFields(midiIn: true, audioIn: true, sidechainIn: false))
  let compressor = PluginCapabilities(acceptsMIDI: false, hasAudioIn: true, hasSidechain: true)
  #expect(ChannelFields(kind: .effect, capabilities: compressor) == ChannelFields(midiIn: false, audioIn: true, sidechainIn: true))
}
```

- [ ] **Step 2: Run them.** `swift test --filter PluginariumCoreTests`. Expected: fail, symbols missing.
- [ ] **Step 3: Implement.** Add `fixture` helpers in the test target only. A standalone effect always shows Audio in, even if a plugin reports no bus.
- [ ] **Step 4: Run tests.** Expected: pass.
- [ ] **Step 5: Commit** `feat: add configuration model and effect chain rules`.

### Task 5: Default routing and stores

**Files:**
- Create: `Sources/PluginariumCore/Routing.swift`, `Sources/PluginariumCore/Stores.swift`
- Test: `Tests/PluginariumCoreTests/RoutingTests.swift`, `Tests/PluginariumCoreTests/StoresTests.swift`

**Interfaces:**
- Produces:
  - `struct InstrumentPosition: Codable, Equatable, Sendable { var midiIn: MIDIRoute?; var audioOut: AudioChannels }`.
  - `struct EffectPosition: Codable, Equatable, Sendable { var audioIn, audioOut: AudioChannels }`.
  - `struct AppSettings: Codable, Equatable, Sendable { var audioDeviceUID: String?; var sampleRate: Double; var bufferFrames: Int; var clockSource: String?; var instrumentPositions: [InstrumentPosition]; var effectPositions: [EffectPosition]; var recentPlugins: [PluginID]; static let defaults }`. Defaults: 48000, 128, 8 instrument positions on outputs 3-4 upward, 4 effect positions.
  - `struct RoutingDefaults: Equatable { var midiIn: MIDIRoute?; var audioIn, audioOut: AudioChannels? }` and `func defaultRouting(for kind: PluginKind, in: Configuration, settings: AppSettings) -> RoutingDefaults`. Beyond the table, reuse the last row.
  - `struct Preset: Codable, Equatable, Sendable { var name: String; var plugin: PluginID; var state: Data }`.
  - `final class ConfigurationStore { init(directory: URL); func loadAll() -> [Configuration]; func save(_:) throws; func delete(id: UUID) throws }`.
  - `final class PresetStore { init(directory: URL); func presets(for: PluginID) -> [Preset]; func save(_:) throws }`.
  - `final class SettingsStore { init(file: URL); func load() -> AppSettings; func save(_:) throws }`.
  - `final class CapabilityCache { init(file: URL); subscript(id: PluginID) -> PluginCapabilities? { get set } }`.
  - `enum AppPaths { static func base() -> URL }`, `~/Library/Application Support/Pluginarium`.

- [ ] **Step 1: Write failing tests.**

```swift
@Test func secondInstrumentTakesSecondPosition() {
  var settings = AppSettings.defaults
  settings.instrumentPositions = [
    .init(midiIn: .init(sourceName: "A", channel: .channel(1)), audioOut: .stereo(left: 4, right: 5)),
    .init(midiIn: .init(sourceName: "B", channel: .channel(2)), audioOut: .stereo(left: 6, right: 7)),
  ]
  let config = Configuration.fixture(channels: [.fixture(kind: .instrument), .fixture(kind: .effect)])
  #expect(defaultRouting(for: .instrument, in: config, settings: settings).audioOut == .stereo(left: 6, right: 7))
}

@Test func routingBeyondTableReusesLastRow() { /* three instruments, two rows: expect row 2 */ }

@Test func corruptConfigurationIsSkipped() throws {
  let dir = try tempDir()
  let store = ConfigurationStore(directory: dir)
  try store.save(.fixture(name: "Good"))
  try Data("{ not json".utf8).write(to: dir.appending(path: "broken.json"))
  #expect(store.loadAll().map(\.name) == ["Good"])
}

@Test func savingPresetWithSameNameReplaces() throws {
  let store = PresetStore(directory: try tempDir())
  let id = PluginID(type: "aumu", subtype: "VasC", manufacturer: "RoCl")
  try store.save(.init(name: "Bass", plugin: id, state: Data([1])))
  try store.save(.init(name: "Bass", plugin: id, state: Data([2])))
  #expect(store.presets(for: id).map(\.state) == [Data([2])])
}

@Test func settingsFileMissingGivesDefaults() throws { /* expect AppSettings.defaults */ }
```

- [ ] **Step 2: Run them.** Expected: fail.
- [ ] **Step 3: Implement.** Pretty-printed JSON, atomic writes, one file per configuration named by UUID, presets in a folder per `PluginID` with a filename derived from a hash of the name so that any name is legal. Sort configurations by name.
- [ ] **Step 4: Run tests.** Expected: pass.
- [ ] **Step 5: Commit** `feat: add default routing and persistence`.

### Task 6: Editing session rules

**Files:**
- Create: `Sources/PluginariumCore/EditingSession.swift`
- Test: `Tests/PluginariumCoreTests/EditingSessionTests.swift`

**Interfaces:**
- Produces: `struct EditingSession: Sendable { var configuration: Configuration; var isSaved: Bool; var isDirty: Bool; init(new:) ; init(saved:); mutating func edit(_ change: (inout Configuration) -> Void); mutating func markSaved(); var needsName: Bool; var leaveAction: LeaveAction; func followUpAfterPresetSaved() -> PresetFollowUp }`, with `enum LeaveAction { case proceed, askToSave }` and `enum PresetFollowUp { case askToSaveConfiguration, keepWithUnsavedConfiguration }`.

- [ ] **Step 1: Write failing tests.**

```swift
@Test func editMarksDirtyOnlyWhenChanged() {
  var session = EditingSession(saved: .fixture())
  session.edit { _ in }
  #expect(!session.isDirty)
  session.edit { $0.channels.append(.fixture()) }
  #expect(session.isDirty && session.leaveAction == .askToSave)
}

@Test func presetInSavedConfigurationAsks() {
  #expect(EditingSession(saved: .fixture()).followUpAfterPresetSaved() == .askToSaveConfiguration)
}

@Test func presetInNewConfigurationWaits() {
  #expect(EditingSession(new: .fixture()).followUpAfterPresetSaved() == .keepWithUnsavedConfiguration)
}

@Test func newConfigurationNeedsNameUntilSaved() {
  var session = EditingSession(new: .fixture(name: ""))
  #expect(session.needsName)
  session.configuration.name = "Night"
  session.markSaved()
  #expect(!session.needsName && !session.isDirty)
}
```

- [ ] **Step 2: Run them.** Expected: fail.
- [ ] **Step 3: Implement.** An empty new configuration is not dirty, matching the prototype.
- [ ] **Step 4: Run tests.** Expected: pass.
- [ ] **Step 5: Commit** `feat: add unsaved change rules`.

### Task 7: MIDI events and clock tracking

**Files:**
- Create: `Sources/PluginariumCore/MIDIEvent.swift`, `Sources/PluginariumCore/ClockTracker.swift`
- Test: `Tests/PluginariumCoreTests/MIDIEventTests.swift`, `Tests/PluginariumCoreTests/ClockTrackerTests.swift`

**Interfaces:**
- Produces:
  - `enum MIDIEvent: Equatable, Sendable { case channelVoice(status: UInt8, data1: UInt8, data2: UInt8); case clock, start, stop, resume }` with `init?(ump word: UInt32)`, for message types 1 and 2.
  - `extension MIDIChannelFilter { func matches(status: UInt8) -> Bool }`.
  - `struct ClockTracker: Sendable { mutating func receive(_ event: MIDIEvent, at seconds: Double); func tempo(at seconds: Double) -> Double; func isClockRunning(at seconds: Double) -> Bool; var isPlaying: Bool }`.

- [ ] **Step 1: Write failing tests.**

```swift
@Test func parsesNoteOnAndClock() {
  #expect(MIDIEvent(ump: 0x2091_3C64) == .channelVoice(status: 0x91, data1: 0x3C, data2: 0x64))
  #expect(MIDIEvent(ump: 0x10F8_0000) == .clock)
}

@Test func filterMatchesOneBasedChannel() {
  #expect(MIDIChannelFilter.channel(2).matches(status: 0x91))
  #expect(!MIDIChannelFilter.channel(1).matches(status: 0x91))
  #expect(MIDIChannelFilter.all.matches(status: 0x9F))
}

@Test func tempoFromTicks() {
  var tracker = ClockTracker()
  let interval = 60.0 / 124.0 / 24.0
  for tick in 0..<48 { tracker.receive(.clock, at: Double(tick) * interval) }
  #expect(abs(tracker.tempo(at: 47 * interval) - 124) < 0.1)
}

@Test func clockStopsAfterOneSecondOfSilence() {
  var tracker = ClockTracker()
  tracker.receive(.clock, at: 0)
  #expect(tracker.isClockRunning(at: 0.5))
  #expect(!tracker.isClockRunning(at: 1.1))
}

@Test func tempoKeepsLastValueThenDefaults() {
  #expect(ClockTracker().tempo(at: 0) == 120)
  // after ticks at 124 and two seconds of silence, tempo(at:) stays 124
}

@Test func transportFollowsStartStopContinue() { /* start true, stop false, resume true */ }
```

- [ ] **Step 2: Run them.** Expected: fail.
- [ ] **Step 3: Implement.** Tempo is the mean interval of up to the last 24 ticks, 24 ticks per quarter note. Ignore all other system messages and SysEx.
- [ ] **Step 4: Run tests.** Expected: pass.
- [ ] **Step 5: Commit** `feat: parse MIDI and track clock`.

---

## Phase 3: Audio

### Task 8: Render core

**Files:**
- Create: `Sources/CRenderCore/include/CRenderCore.h`, `Sources/CRenderCore/engine.c`, `Sources/CRenderCore/graph.c`, `Sources/CRenderCore/host_callbacks.c`
- Test: `Tests/PluginariumAudioTests/RenderCoreTests.swift`

**Interfaces:**
- Produces this C API:

```c
typedef struct { int32_t left, right; } PRChannels;      // right == -1: mono, left == -1: off
typedef struct { AudioUnit unit; PRChannels sidechain; uint32_t channels; } PREffect;
typedef struct { const PREffect *effects; uint32_t count; } PRRow;
typedef struct {
  AudioUnit source; PRChannels audioIn; PRChannels sidechain;
  uint32_t sourceChannels; const PRRow *rows; uint32_t rowCount;
  PRChannels audioOut; int32_t midiSlot;                 // -1: none
} PRStrip;

typedef struct PREngine PREngine;
PREngine *pr_engine_create(uint32_t maxFrames, double sampleRate);
void pr_engine_destroy(PREngine *);
void pr_engine_install_graph(PREngine *, const PRStrip *strips, uint32_t count);
void pr_engine_collect_garbage(PREngine *);              // main thread
void pr_engine_render(PREngine *, uint32_t frames,
                      const float *const *in, uint32_t inChannels,
                      float *const *out, uint32_t outChannels);
void pr_engine_push_midi(PREngine *, int32_t slot, uint8_t status, uint8_t d1, uint8_t d2);
void pr_engine_set_transport(PREngine *, double tempo, bool playing);
void pr_engine_read_meters(PREngine *, uint32_t strip, float *left, float *right);
double pr_engine_load(PREngine *);
OSStatus pr_install_host_callbacks(AudioUnit, PREngine *);
OSStatus pr_install_input_callbacks(AudioUnit, PREngine *);
```

- [ ] **Step 1: Write failing tests** using the units from Task 2. Helper `renderOnce(strips:input:) -> [[Float]]` builds an engine, renders 128 frames into 8 output channels, and returns them.

```swift
@Test func twoChannelsSumOnSharedOutput() { /* two PlIn with notes held on out 0-1: output 0.5 */ }
@Test func separateOutputsStaySeparate() { /* PlIn on out 2-3: channels 0,1 silent, 2,3 at 0.25 */ }
@Test func seriesEffectsMultiply() { /* PlIn -> PlFx -> PlFx: 0.0625 */ }
@Test func parallelBranchesSumEqually() { /* PlIn -> [PlFx, PlFx]: 0.25 */ }
@Test func standaloneEffectReadsDeviceInput() { /* in 4-5 = 0.8, PlFx: 0.4 */ }
@Test func monoInputFeedsBothSides() { /* audioIn right -1 */ }
@Test func sidechainReadsChosenInput() { /* main 0.8, sidechain 0.4 on in 2-3: 0.4 + 0.1 = 0.5 */ }
@Test func sidechainOffIsSilence() { /* left -1: 0.4 */ }
@Test func midiReachesItsSlotOnly() { /* note on slot 0: strip A sounds, strip B silent */ }
@Test func metersReportPeak() { /* 0.25 */ }
```

- [ ] **Step 2: Run them.** `swift test --filter RenderCoreTests`. Expected: fail.
- [ ] **Step 3: Implement.** `pr_engine_install_graph` copies its input and allocates all buffers up front, then swaps the current graph with a C11 atomic exchange at the start of a render. The replaced graph waits on a list for `pr_engine_collect_garbage`. `pr_install_input_callbacks` gives each unit one stable input record, set once from the main thread. At render time the strip writes its buffer pointers into that record and the AU input callback copies from them. Parallel rows copy the row input to each branch and sum the outputs equally. Plugin latency between branches is not compensated in the first version. MIDI is one lock-free single-producer ring per slot, 64 slots of 512 events, drained at the start of a render with sample offset 0.
- [ ] **Step 4: Run tests.** Expected: pass.
- [ ] **Step 5: Commit** `feat: add real-time render core`.

### Task 9: Running a configuration

**Files:**
- Create: `Sources/PluginariumAudio/GraphBuilder.swift`, `Sources/PluginariumAudio/ConfigurationRunner.swift`
- Test: `Tests/PluginariumAudioTests/GraphBuilderTests.swift`, `Tests/PluginariumAudioTests/RunnerTests.swift`

**Interfaces:**
- Consumes: `HostedPlugin`, `Configuration`, `CapabilityCache`, render core API.
- Produces:
  - `enum ChannelStatus: Equatable, Sendable { case loading, ready, pluginMissing, loadFailed(String), routingUnavailable(String) }`.
  - `@MainActor final class ConfigurationRunner { init(engine: OpaquePointer, sampleRate: Double, maxFrames: UInt32, deviceInputs: Int, deviceOutputs: Int); func apply(_ configuration: Configuration) async; var status: [UUID: ChannelStatus]; func plugin(channel: UUID, effect: UUID?) -> HostedPlugin?; func capabilities(channel: UUID) -> PluginCapabilities?; func capturingState(of: Configuration) -> Configuration; func midiSlot(channel: UUID) -> Int32? }`.

- [ ] **Step 1: Write failing tests.**

```swift
@Test func missingPluginDoesNotStopOthers() async { /* PlIn + unknown id: status ready and pluginMissing, PlIn still renders */ }
@Test func failingPluginStaysOnItsChannel() async { /* PlIn + PlBd: loadFailed on second, first renders */ }
@Test func outputBeyondDeviceIsFlagged() async { /* deviceOutputs 2, audioOut 14-15: routingUnavailable("Out 15–16"), others render */ }
@Test func inputBeyondDeviceIsFlagged() async { /* deviceInputs 0, standalone effect: routingUnavailable */ }
@Test func editingKeepsLoadedPlugins() async { /* apply, then apply with one added channel: first HostedPlugin instance is identical */ }
@Test func stateIsRestoredOnLoad() async { /* slot.state from Apple AUDelay: parameter value returns */ }
@Test func capturingStateFillsSlots() async { /* slot.state non-nil on channel and insert effect */ }
@Test func oneBadPluginInsertIsSkippedNotFatal() async { /* PlBd in a row: channel still renders, status loadFailed */ }
```

- [ ] **Step 2: Run them.** Expected: fail.
- [ ] **Step 3: Implement.** Reuse hosted plugins by channel or effect ID so an edit never reloads what is playing. Load plugins concurrently and install the graph after each finishes, so slow plugins do not hold up fast ones. On first load, write the capabilities to `CapabilityCache`. Install host and input callbacks on every unit. `GraphBuilder` is a pure mapping from channels plus hosted plugins to `PRStrip` values, and owns the C arrays until the install call returns.
- [ ] **Step 4: Run tests.** Expected: pass.
- [ ] **Step 5: Commit** `feat: run configurations through the render core`.

### Task 10: Audio devices and live engine

**Files:**
- Create: `Sources/PluginariumAudio/DeviceCatalog.swift`, `Sources/PluginariumAudio/AudioEngine.swift`
- Test: `Tests/PluginariumAudioTests/AudioEngineTests.swift`

**Interfaces:**
- Produces:
  - `struct AudioDevice: Identifiable, Equatable, Sendable { var id: String /* UID */; var name: String; var inputChannels, outputChannels: [String] }`, channel names as the system reports them.
  - `enum DeviceCatalog { static func all() -> [AudioDevice]; static func defaultOutput() -> AudioDevice? }`.
  - `@MainActor @Observable final class AudioEngine { var state: EngineState; let renderEngine: OpaquePointer; func start(settings: AppSettings) throws; func stop(); func handleDeviceChange() ; var dspLoad: Double }`, with `enum EngineState: Equatable { case stopped, running(AudioDevice), deviceMissing(String) }`.
  - `AudioEngine.init(devices: @escaping () -> [AudioDevice] = DeviceCatalog.all)`, so tests can swap the device list.

- [ ] **Step 1: Write failing tests.**

```swift
@Test func catalogListsDefaultOutput() { #expect(DeviceCatalog.defaultOutput() != nil) }

@Test func missingDeviceReportsStateWithoutThrowing() throws {
  let engine = AudioEngine(devices: { [] })
  var settings = AppSettings.defaults; settings.audioDeviceUID = "gone"
  try engine.start(settings: settings)
  #expect(engine.state == .deviceMissing("gone"))
}

@Test func deviceLossAndReturn() throws { /* start on the default output; list empties, handleDeviceChange gives deviceMissing; list returns it, gives running */ }
```

- [ ] **Step 2: Run them.** Expected: fail.
- [ ] **Step 3: Implement.** Use one `kAudioUnitSubType_HALOutput` unit with both IO elements enabled when the device has inputs, and output only when it has none, which is the case for MacBook speakers. The render callback lives in C: it pulls input with `AudioUnitRender` into preallocated buffers and calls `pr_engine_render`. Listen for `kAudioHardwarePropertyDevices`. Only call the code that sets sample rate and buffer size when the values differ from the device's current ones.
- [ ] **Step 4: Run tests.** Expected: pass.
- [ ] **Step 5: Check live sound on the MacBook.** Add `pluginarium-probe play <type> <subtype> <manufacturer>`, which plays a held C note. Run it with the MacBook built-in output with the owner's OK. Expected: audible TB-303 note, and `dspLoad` printed below 0.5.
- [ ] **Step 6: Commit** `feat: play through a live audio device`.

### Task 11: MIDI routing and tempo

**Files:**
- Create: `Sources/PluginariumAudio/MIDIRouter.swift`
- Test: `Tests/PluginariumAudioTests/MIDIRouterTests.swift`

**Interfaces:**
- Consumes: `MIDIEvent`, `ClockTracker`, `pr_engine_push_midi`, `pr_engine_set_transport`.
- Produces: `@MainActor @Observable final class MIDIRouter { init(engine: OpaquePointer); var sources: [String]; func setRoutes(_ routes: [MIDIRouteTarget]); func setClockSource(_ name: String?); var clockRunning: Bool; var tempo: Double; func handle(_ event: MIDIEvent, fromSource: String, at seconds: Double) }`, and `struct MIDIRouteTarget: Equatable { var route: MIDIRoute; var slot: Int32 }`.

- [ ] **Step 1: Write failing tests** that call `handle` directly and render through the engine.

```swift
@Test func noteGoesOnlyToMatchingRoute() { /* routes A ch1 slot 0, A ch2 slot 1: note on ch2 sounds on strip 2 only */ }
@Test func otherSourceIsIgnored() { /* source B: silence */ }
@Test func allChannelsRouteAcceptsAny() { /* .all accepts ch 16 */ }
@Test func clockFromOtherSourceIsIgnored() { /* tempo stays default */ }
@Test func clockSetsTempoSeenByPlugin() { /* 124 BPM ticks: host callback tempo reads 124 */ }
@Test func stopClearsPlayingForPlugin() { /* transport state false */ }
```

- [ ] **Step 2: Run them.** Expected: fail.
- [ ] **Step 3: Implement.** Create the port with `MIDIInputPortCreateWithProtocol` and `._1_0`, and connect every source. Notes are pushed directly from the CoreMIDI thread and never wait for the main actor. The route table is an immutable snapshot swapped atomically. Rebuild source names on `msgSetupChanged`.
- [ ] **Step 4: Run tests.** Expected: pass.
- [ ] **Step 5: Commit** `feat: route MIDI and follow clock`.

---

## Phase 4: Interface

UI tasks have no unit tests. Each one is verified by running the app and comparing a window screenshot against the matching prototype screen, using `scripts/window_id.swift` from the `new-macos-app` skill with `screencapture -x -o -l <id>`. Never capture the whole screen. Set `PLUGINARIUM_TEST_UNITS=1` to call `registerTestUnits()` at launch, so the vocoder and sidechain fields can be seen.

### Task 12: App shell, theme and Start screen

**Files:**
- Create: `Sources/Pluginarium/Theme.swift`, `AppModel.swift`, `StartScreen.swift`
- Modify: `Sources/Pluginarium/PluginariumApp.swift`

**Interfaces:**
- Consumes: stores, `AudioEngine`, `ConfigurationRunner`, `MIDIRouter`, `EditingSession`.
- Produces: `@MainActor @Observable final class AppModel` with `enum Screen { case start, mixer, settings }`, `var screen`, `var session: EditingSession?`, `var settings: AppSettings`, `var configurations: [Configuration]`, `func load(_:)`, `func newConfiguration()`, `func edit(_:)`, `func save(name: String?)`, `func leave(then:)`. `edit` calls `runner.apply` and refreshes MIDI routes. Theme exposes `Color.panel` and the other constants, `Font.panelDisplay(_:)`, `Font.panelText(_:)`, `KeyButtonStyle`, `Legend` view, and `WalnutFrame` for the 18 px cheeks.

- [ ] **Step 1: Implement** the shell and Start screen: wordmark, tagline "Your plugins as instruments in the studio.", Ready LED, configuration rows with plugin names, New configuration and Settings. Empty list states "No configurations yet" and points to New configuration.
- [ ] **Step 2: Run and compare** with prototype screen `1-start`. Expected: matching layout, and saved files listed.
- [ ] **Step 3: Commit** `feat: add app shell and start screen`.

### Task 13: Mixer screen and channels

**Files:**
- Create: `Sources/Pluginarium/MixerScreen.swift`, `ChannelView.swift`, `MeterView.swift`

**Interfaces:**
- Consumes: `AppModel`, `ChannelFields`, `ChannelStatus`, `pr_engine_read_meters`.
- Produces: `struct ChannelView: View`, `init(channel: Channel, index: Int)`.

- [ ] **Step 1: Implement** the top bar and channel columns, 188 pt wide in a horizontal scroll view. Fields come only from `ChannelFields`. On instruments, Audio in lists Off first and starts at Off. A selector lists mono channels and stereo pairs. Output selector labels follow the device, such as "Out 5–6". Meters poll at 15 Hz. Status strings: "Plugin not installed on this Mac" with Replace plugin, "<source> is not connected", "<channel> is not available on this device", "Plugin failed to load". Top bar shows "No MIDI clock" or "<source> clock, 124.0 BPM", "CPU <n> %" from `dspLoad`, and "Audio device missing" for `.deviceMissing`.
- [ ] **Step 2: Run and compare** with prototype mixer, using a configuration file with test units. Expected: matching columns, vocoder and compressor fields visible, and a live note reaching the meter from a USB keyboard or IAC port.
- [ ] **Step 3: Commit** `feat: add mixer screen`.

### Task 14: Add dialog

**Files:**
- Create: `Sources/Pluginarium/AddSheet.swift`

**Interfaces:**
- Consumes: `PluginCatalog`, `CapabilityCache`, `PresetStore`, `defaultRouting`.
- Produces: `struct AddSheet: View`, `enum AddTarget { case channel; case insert(channel: UUID, row: Int?); case replace(channel: UUID) }`.

- [ ] **Step 1: Implement** the dialog from the prototype: tabs only for `.channel`, search focused at open, Recent then All, preset column with Default sound, My presets, Factory presets or the hint "Factory sounds stay inside this plugin. Choose one in its window and save it as a preset.", and routing fields filtered by `ChannelFields`. Return accepts and arrow keys move the selection. When capabilities are unknown, load the plugin once in the background to fill the cache, and show routing fields when done. Accepting moves the plugin to the front of `recentPlugins`, keeping 5. New configuration opens this sheet immediately.
- [ ] **Step 2: Run and verify.** Keystrokes `mari`, Return add Mariana with position routing. Factory presets appear for Mariana and the hint for TB-303.
- [ ] **Step 3: Commit** `feat: add plugin picker`.

### Task 15: Effect slots, plugin windows and presets

**Files:**
- Create: `Sources/Pluginarium/EffectSlots.swift`, `PluginWindows.swift`, `Dialogs.swift`

**Interfaces:**
- Consumes: `Channel` chain methods, `HostedPlugin.makeView`, `fullState`, `restore`, `PresetStore`, `EditingSession.followUpAfterPresetSaved`.
- Produces: `@MainActor final class PluginWindows { func toggle(channel: UUID, effect: UUID?); func isOpen(channel: UUID, effect: UUID?) -> Bool; func closeAll() }`.

- [ ] **Step 1: Implement effect slots.** Rows with split and merge lines drawn by a `Shape`, up to 3 side by side, tooltip with the full name, "Sidechain from <input>" under an effect that has one, and the effect menu from the spec.
- [ ] **Step 2: Implement plugin windows.** One `NSWindow` for each open plugin holding `makeView()`, tracking the plugin's preferred size. Position is not persisted. If no view exists, show "This plugin has no window".
- [ ] **Step 3: Implement the preset menu and Save preset.** Save preset is reachable from the preset selector. Selecting a preset calls `restore`, and a factory preset calls `selectFactoryPreset`. After saving, follow `followUpAfterPresetSaved`. Dialog text matches the prototype: "Update configuration?" with Not now and Save configuration.
- [ ] **Step 4: Run and verify** the prototype flows: open TB-303, pick a sound, Save preset, confirm the follow-up question, add a parallel effect, move it to series, remove it.
- [ ] **Step 5: Commit** `feat: add effect slots, plugin windows and presets`.

### Task 16: Saving, settings and faults

**Files:**
- Modify: `Sources/Pluginarium/Dialogs.swift`, `AppModel.swift`
- Create: `Sources/Pluginarium/SettingsScreen.swift`

**Interfaces:**
- Consumes: `EditingSession.leaveAction`, `capturingState`, `DeviceCatalog`, `SettingsStore`.

- [ ] **Step 1: Implement save flows.** Save and Command-S call `capturingState` first, a new configuration asks for its name, Save as, and "Save changes?" with Don't save, Cancel and Save whenever `leaveAction` is `.askToSave`, including on app quit.
- [ ] **Step 2: Implement Settings.** Audio device, sample rate, buffer size, clock source, and both position tables. Device changes restart the engine and reapply the configuration.
- [ ] **Step 3: Run and verify.** Remove a plugin file reference by editing a saved configuration's `subtype`. Expected: "Plugin not installed on this Mac", Replace plugin works, and other channels play. Quit with unsaved changes. Expected: the save question appears.
- [ ] **Step 4: Commit** `feat: add saving flows and settings`.

---

## Phase 5: Finish

### Task 17: Full walkthrough on the MacBook Air

**Files:**
- Modify: `CHANGELOG.md`, `CLAUDE.md`, `README.md`

- [ ] **Step 1: Run everything.** `swift test && ./build.sh release`. Expected: all tests pass and the build succeeds.
- [ ] **Step 2: Walk the spec goals with the owner** on the MacBook: launch to sound with a saved configuration, one-plugin new configuration with Return only, parallel effects with Apple units, plugin window open and close, preset saved and used in a second configuration. Record pass or fail per goal in `docs/studio-session.md`.
- [ ] **Step 3: Measure startup.** Note the seconds from launch to sound with TB-303. Report it, there is no fixed limit.
- [ ] **Step 4: Commit** `docs: record first walkthrough`.

### Task 18: Studio session

**Files:**
- Create: `docs/studio-session.md` (checklist section)

The owner runs this in the studio, or Claude Code runs it there with the owner present. Get the owner's OK before the first start, because selecting the AudioFuse can write its sample rate and buffer size.

- [ ] **Step 1: Write the checklist** covering steps 2 to 7, with a results column.
- [ ] **Step 2: Inventory.** On the Mac mini run `sw_vers -productVersion` and `auval -a | grep -E '^(aumu|aufx|aumf)'`. Expected: macOS 15 or newer, and the list recorded, including ZEN Delay and Valhalla.
- [ ] **Step 3: Routing (spec risk 2).** Play a plugin to each reserved output pair on the AudioFuse. Expected: sound on exactly that pair. Feed a hardware synth into an input and run Valhalla as a standalone effect. Expected: reverb on the chosen output.
- [ ] **Step 4: MIDI.** Check how mioXL ports appear, play from Hapax and KeyLab, and confirm the channel filter. Switch off a device and record whether the port disappears. Record whether Berlinan appears as a source.
- [ ] **Step 5: Clock.** Set the Hapax as clock source and run ZEN Delay at two tempos. Expected: delay follows, transport start and stop work, and stopping the clock shows No MIDI clock.
- [ ] **Step 6: Inputs (spec risk 3).** With one of the owner's purchased vocoders and one sidechain compressor, confirm the fields appear and the signals work. Record plugins that do not expose a sidechain.
- [ ] **Step 7: Latency (spec risk 4).** Record the round trip with the AudioFuse at 128 frames and at the lowest stable buffer size. The owner judges by ear against a hardware instrument triggered by the same sequencer.
- [ ] **Step 8: Commit** the results and turn any failures into new tasks with the owner.
