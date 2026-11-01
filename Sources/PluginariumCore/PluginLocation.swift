import Foundation

/// Where a plugin sits in a configuration: a channel's own plugin, or one of its effects.
public struct PluginLocation: Hashable, Sendable {
    public var channel: UUID
    public var effect: UUID?

    public init(channel: UUID, effect: UUID? = nil) {
        self.channel = channel
        self.effect = effect
    }
}

extension Channel {
    /// The row holding the effect.
    public func row(of effect: UUID) -> Int? {
        effects.firstIndex { row in row.contains { $0.id == effect } }
    }
}

extension Configuration {
    public func slot(at location: PluginLocation) -> PluginSlot? {
        guard let channel = channels.first(where: { $0.id == location.channel }) else { return nil }
        guard let effect = location.effect else { return channel.slot }
        return channel.effects.joined().first { $0.id == effect }?.slot
    }

    /// Whether `plugin` is still what sits at `location`. It stays while its effect moves between rows.
    public func holds(_ plugin: PluginID, at location: PluginLocation) -> Bool {
        slot(at: location)?.plugin == plugin
    }

    /// Changes the slot at `location`. A plugin that is gone is ignored.
    public mutating func updateSlot(at location: PluginLocation, _ change: (inout PluginSlot) -> Void) {
        guard let channel = channels.firstIndex(where: { $0.id == location.channel }) else { return }
        guard let effect = location.effect else {
            change(&channels[channel].slot)
            return
        }
        for row in channels[channel].effects.indices {
            guard let index = channels[channel].effects[row].firstIndex(where: { $0.id == effect }) else { continue }
            change(&channels[channel].effects[row][index].slot)
            return
        }
    }
}
