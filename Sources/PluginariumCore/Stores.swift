import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: "io.jp4.pluginarium", category: "store")

private func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}

private func write<T: Encodable>(_ value: T, to url: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try makeEncoder().encode(value).write(to: url, options: .atomic)
}

private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        logger.error("Skipping corrupt file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        return nil
    }
}

/// Hex-encoded SHA-256, a filename that is legal for any input.
private func hashedName(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func jsonFiles(in directory: URL) -> [URL] {
    let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return urls.filter { $0.pathExtension == "json" }
}

public enum AppPaths {
    /// `~/Library/Application Support/Pluginarium`
    public static func base() -> URL {
        URL.applicationSupportDirectory.appending(path: "Pluginarium", directoryHint: .isDirectory)
    }
}

public struct Preset: Codable, Equatable, Sendable {
    public var name: String
    public var plugin: PluginID
    public var state: Data

    public init(name: String, plugin: PluginID, state: Data) {
        self.name = name
        self.plugin = plugin
        self.state = state
    }
}

/// One JSON file per configuration, named by its UUID.
public final class ConfigurationStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func file(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    /// All readable configurations sorted by name; corrupt files are logged and skipped.
    public func loadAll() -> [Configuration] {
        jsonFiles(in: directory)
            .compactMap { read(Configuration.self, from: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func save(_ configuration: Configuration) throws {
        try write(configuration, to: file(for: configuration.id))
    }

    /// Deleting an unknown ID does nothing.
    public func delete(id: UUID) throws {
        let url = file(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// Presets live in a folder per plugin; file names are hashes so any preset name is legal.
public final class PresetStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func folder(for plugin: PluginID) -> URL {
        let key = [plugin.type, plugin.subtype, plugin.manufacturer].joined(separator: "\u{0}")
        return directory.appending(path: hashedName(key), directoryHint: .isDirectory)
    }

    public func presets(for plugin: PluginID) -> [Preset] {
        jsonFiles(in: folder(for: plugin))
            .compactMap { read(Preset.self, from: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A preset with the same name for the same plugin is replaced.
    public func save(_ preset: Preset) throws {
        try write(preset, to: folder(for: preset.plugin).appending(path: "\(hashedName(preset.name)).json"))
    }
}

public final class SettingsStore {
    private let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// Defaults when the file is missing or corrupt.
    public func load() -> AppSettings {
        read(AppSettings.self, from: file) ?? .defaults
    }

    public func save(_ settings: AppSettings) throws {
        try write(settings, to: file)
    }
}

/// Plugin capabilities remembered between launches; writes through on every change.
public final class CapabilityCache {
    private let file: URL
    private var entries: [String: PluginCapabilities]

    public init(file: URL) {
        self.file = file
        entries = read([String: PluginCapabilities].self, from: file) ?? [:]
    }

    private static func key(_ id: PluginID) -> String {
        [id.type, id.subtype, id.manufacturer].joined(separator: "\u{0}")
    }

    public subscript(id: PluginID) -> PluginCapabilities? {
        get { entries[Self.key(id)] }
        set {
            entries[Self.key(id)] = newValue
            do {
                try write(entries, to: file)
            } catch {
                logger.error("Cannot write capability cache: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
