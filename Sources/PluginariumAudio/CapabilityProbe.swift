import PluginariumCore

/// What loading a plugin once tells: its capabilities and the factory presets it lists.
public struct ProbeResult: Equatable, Sendable {
    public var capabilities: PluginCapabilities
    public var factoryPresets: [String]
}

/// Finds out what a plugin needs by loading it, for the Add dialog before the plugin is in a
/// configuration. The plugin is not initialized and goes away when the probe ends.
public enum CapabilityProbe {

    /// Nil when the plugin cannot be loaded. Runs off the calling actor, since loading can take a while.
    public static func probe(_ id: PluginID) async -> ProbeResult? {
        await Task.detached(priority: .utility) { () -> ProbeResult? in
            guard let plugin = try? await HostedPlugin.load(id) else { return nil }
            return ProbeResult(
                capabilities: .derive(auType: id.type, inputBusNames: plugin.inputBusNames),
                factoryPresets: plugin.factoryPresets()
            )
        }.value
    }
}
