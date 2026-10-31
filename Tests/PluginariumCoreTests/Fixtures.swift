import Foundation
@testable import PluginariumCore

extension PluginSlot {
    static func fixture() -> PluginSlot {
        PluginSlot(
            plugin: PluginID(type: "aufx", subtype: "test", manufacturer: "Test"),
            displayName: "Test Plugin",
            presetName: nil,
            state: nil
        )
    }
}

extension InsertEffect {
    static func fixture() -> InsertEffect {
        InsertEffect(id: UUID(), slot: .fixture(), sidechainIn: nil)
    }
}

extension Channel {
    static func fixture(kind: PluginKind = .instrument, effectRows: [[InsertEffect]] = []) -> Channel {
        Channel(
            id: UUID(),
            kind: kind,
            slot: .fixture(),
            midiIn: nil,
            audioIn: nil,
            sidechainIn: nil,
            audioOut: .stereo(left: 0, right: 1),
            effects: effectRows
        )
    }
}

extension Configuration {
    static func fixture(name: String = "Test", channels: [Channel] = []) -> Configuration {
        Configuration(id: UUID(), name: name, channels: channels)
    }
}
