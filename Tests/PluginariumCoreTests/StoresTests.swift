import Foundation
import Testing
@testable import PluginariumCore

private let vasc = PluginID(type: "aumu", subtype: "VasC", manufacturer: "RoCl")

@Test func corruptConfigurationIsSkipped() throws {
    let dir = try tempDir()
    let store = ConfigurationStore(directory: dir)
    try store.save(.fixture(name: "Good"))
    try Data("{ not json".utf8).write(to: dir.appending(path: "broken.json"))
    #expect(store.loadAll().map(\.name) == ["Good"])
}

@Test func configurationsAreSortedByNameAndOverwrittenById() throws {
    let store = ConfigurationStore(directory: try tempDir())
    var b = Configuration.fixture(name: "b")
    try store.save(b)
    try store.save(.fixture(name: "A"))
    b.name = "c"
    try store.save(b)
    #expect(store.loadAll().map(\.name) == ["A", "c"])
}

@Test func deleteRemovesConfigurationAndUnknownIdIsNoOp() throws {
    let store = ConfigurationStore(directory: try tempDir())
    let config = Configuration.fixture(name: "X")
    try store.save(config)
    try store.delete(id: UUID())
    #expect(store.loadAll().count == 1)
    try store.delete(id: config.id)
    #expect(store.loadAll().isEmpty)
}

@Test func savingPresetWithSameNameReplaces() throws {
    let store = PresetStore(directory: try tempDir())
    try store.save(.init(name: "Bass", plugin: vasc, state: Data([1])))
    try store.save(.init(name: "Bass", plugin: vasc, state: Data([2])))
    #expect(store.presets(for: vasc).map(\.state) == [Data([2])])
}

@Test func presetsAreSortedCaseInsensitivelyAndAnyNameIsLegal() throws {
    let store = PresetStore(directory: try tempDir())
    let odd = PluginID(type: "aufx", subtype: "a/b ", manufacturer: "é\u{FF}.")
    for name in ["bravo", "Alpha", "../x/y", "Charlie"] {
        try store.save(.init(name: name, plugin: odd, state: Data()))
    }
    #expect(store.presets(for: odd).map(\.name) == ["../x/y", "Alpha", "bravo", "Charlie"])
    #expect(store.presets(for: vasc).isEmpty)
}

@Test func settingsFileMissingGivesDefaults() throws {
    let store = SettingsStore(file: try tempDir().appending(path: "settings.json"))
    #expect(store.load() == AppSettings.defaults)
}

@Test func settingsRoundTripAndCorruptFileGivesDefaults() throws {
    let file = try tempDir().appending(path: "settings.json")
    let store = SettingsStore(file: file)
    var settings = AppSettings.defaults
    settings.bufferFrames = 256
    settings.recentPlugins = [vasc]
    try store.save(settings)
    #expect(store.load() == settings)
    try Data("garbage".utf8).write(to: file)
    #expect(store.load() == AppSettings.defaults)
}

@Test func settingsFileWithoutRecentPluginsKeepsEverythingElse() throws {
    let file = try tempDir().appending(path: "settings.json")
    let store = SettingsStore(file: file)
    var settings = AppSettings.defaults
    settings.audioDeviceUID = "fuse"
    settings.sampleRate = 96000
    settings.bufferFrames = 256
    settings.clockSource = "Keys"
    settings.instrumentPositions = [.init(midiIn: .init(sourceName: "Keys", channel: .channel(3)), audioOut: .stereo(left: 4, right: 5))]
    settings.effectPositions = []
    settings.recentPlugins = [vasc]
    try store.save(settings)

    var fields = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(fields.removeValue(forKey: "recentPlugins") != nil)
    try JSONSerialization.data(withJSONObject: fields).write(to: file)

    settings.recentPlugins = []
    #expect(store.load() == settings)
}

@Test func settingsFileWithoutTheOptionalFieldsReads() throws {
    let file = try tempDir().appending(path: "settings.json")
    let store = SettingsStore(file: file)
    try store.save(.defaults)
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(!text.contains("audioDeviceUID"))
    #expect(!text.contains("clockSource"))
    #expect(store.load() == AppSettings.defaults)
}

@Test func capabilityCachePersistsAndSurvivesCorruption() throws {
    let file = try tempDir().appending(path: "caps.json")
    let caps = PluginCapabilities(acceptsMIDI: true, hasAudioIn: false, hasSidechain: false)
    let cache = CapabilityCache(file: file)
    #expect(cache[vasc] == nil)
    cache[vasc] = caps
    #expect(CapabilityCache(file: file)[vasc] == caps)
    cache[vasc] = nil
    #expect(CapabilityCache(file: file)[vasc] == nil)
    try Data("garbage".utf8).write(to: file)
    #expect(CapabilityCache(file: file)[vasc] == nil)
}

@Test func appPathsBaseIsPluginariumApplicationSupport() {
    #expect(AppPaths.base().path.hasSuffix("Library/Application Support/Pluginarium"))
}

@Suite("CapabilityCache presets")
struct CapabilityCachePresetTests {
    let plugin = PluginID(type: "aumu", subtype: "Mari", manufacturer: "Test")
    let caps = PluginCapabilities(acceptsMIDI: true, hasAudioIn: false, hasSidechain: false)

    @Test("Factory presets are remembered with the capabilities")
    func remembered() throws {
        let file = try tempDir().appending(path: "capabilities.json")
        let cache = CapabilityCache(file: file)
        #expect(cache.factoryPresets(for: plugin) == nil)
        cache.store(caps, factoryPresets: ["Bell", "Pad"], for: plugin)
        let again = CapabilityCache(file: file)
        #expect(again[plugin] == caps)
        #expect(again.factoryPresets(for: plugin) == ["Bell", "Pad"])
    }

    @Test("A cache file from before factory presets still reads")
    func oldFile() throws {
        let file = try tempDir().appending(path: "capabilities.json")
        let key = [plugin.type, plugin.subtype, plugin.manufacturer].joined(separator: "\u{0}")
        let old = try JSONEncoder().encode([key: caps])
        try old.write(to: file)
        let cache = CapabilityCache(file: file)
        #expect(cache[plugin] == caps)
        #expect(cache.factoryPresets(for: plugin) == nil)
    }

    @Test("Setting capabilities alone keeps the presets known")
    func subscriptKeepsPresets() throws {
        let cache = CapabilityCache(file: try tempDir().appending(path: "capabilities.json"))
        cache.store(caps, factoryPresets: ["Bell"], for: plugin)
        cache[plugin] = caps
        #expect(cache.factoryPresets(for: plugin) == ["Bell"])
    }
}
