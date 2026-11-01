import PluginariumCore

/// What loading a plugin once tells: its capabilities and the factory presets it lists.
public struct ProbeResult: Equatable, Sendable {
    public var capabilities: PluginCapabilities
    public var factoryPresets: [String]
}

/// Finds out what a plugin needs by loading it, for the Add dialog before the plugin is in a
/// configuration. The plugin is not initialized and goes away when the probe ends.
public enum CapabilityProbe {

    /// Nil when the plugin cannot be loaded. A plugin lives on the main thread, so this holds up the
    /// interface for as long as the plugin takes to load and to go. Run one at a time.
    @MainActor
    public static func probe(_ id: PluginID) async -> ProbeResult? {
        await HostedPlugin.letInterfaceDraw()
        guard let plugin = try? await HostedPlugin.load(id) else { return nil }
        return ProbeResult(
            capabilities: .derive(auType: id.type, inputBusNames: plugin.inputBusNames),
            factoryPresets: plugin.factoryPresets()
        )
    }
}
