import Foundation
import Testing
@testable import PluginariumCore

private func info(_ name: String, vendor: String = "", kind: PluginKind = .instrument) -> PluginInfo {
    PluginInfo(id: PluginID(type: kind == .effect ? "aufx" : "aumu", subtype: name, manufacturer: "Test"), name: name, vendor: vendor, kind: kind)
}

@Suite("AddPicker")
struct AddPickerTests {
    let mariana = info("Mariana", vendor: "Roland")
    let tb303 = info("TB-303", vendor: "Roland")
    let minimoog = info("Minimoog", vendor: "Moog")
    let reverb = info("Hall", vendor: "Roland", kind: .effect)

    var catalog: [PluginInfo] { [mariana, tb303, minimoog, reverb] }

    @Test("Only plugins of the wanted kind are listed")
    func filtersKind() {
        let listing = AddPicker.listing(of: catalog, kind: .effect, query: "", recent: [])
        #expect(listing.all.map(\.name) == ["Hall"])
    }

    @Test("Search matches name and vendor, ignoring case and surrounding spaces")
    func filtersQuery() {
        #expect(AddPicker.listing(of: catalog, kind: .instrument, query: " MARI ", recent: []).all.map(\.name) == ["Mariana"])
        #expect(AddPicker.listing(of: catalog, kind: .instrument, query: "moog", recent: []).all.map(\.name) == ["Minimoog"])
        #expect(AddPicker.listing(of: catalog, kind: .instrument, query: "nothing", recent: []).all.isEmpty)
    }

    @Test("Recent come first in recent order, then the rest; missing recent ones are skipped")
    func recentFirst() {
        let gone = PluginID(type: "aumu", subtype: "Gone", manufacturer: "Test")
        let listing = AddPicker.listing(of: catalog, kind: .instrument, query: "", recent: [minimoog.id, gone, reverb.id, mariana.id])
        #expect(listing.recent.map(\.name) == ["Minimoog", "Mariana"])
        #expect(listing.others.map(\.name) == ["TB-303"])
        #expect(listing.all.map(\.name) == ["Minimoog", "Mariana", "TB-303"])
    }

    @Test("A selection that still matches stays, otherwise the first candidate is chosen")
    func selection() {
        let listing = AddPicker.listing(of: catalog, kind: .instrument, query: "", recent: [tb303.id])
        #expect(AddPicker.selection(keeping: mariana.id, in: listing) == mariana.id)
        #expect(AddPicker.selection(keeping: nil, in: listing) == tb303.id)
        let narrowed = AddPicker.listing(of: catalog, kind: .instrument, query: "moog", recent: [])
        #expect(AddPicker.selection(keeping: mariana.id, in: narrowed) == minimoog.id)
        let empty = AddPicker.listing(of: catalog, kind: .instrument, query: "zzz", recent: [])
        #expect(AddPicker.selection(keeping: mariana.id, in: empty) == nil)
    }

    @Test("Arrow keys move through the list and wrap around")
    func movement() {
        let listing = AddPicker.listing(of: catalog, kind: .instrument, query: "", recent: [])
        #expect(AddPicker.moved(from: mariana.id, by: 1, in: listing) == tb303.id)
        #expect(AddPicker.moved(from: minimoog.id, by: 1, in: listing) == mariana.id)
        #expect(AddPicker.moved(from: mariana.id, by: -1, in: listing) == minimoog.id)
        #expect(AddPicker.moved(from: nil, by: 1, in: listing) == mariana.id)
        #expect(AddPicker.moved(from: nil, by: -1, in: listing) == minimoog.id)
        let empty = AddPicker.listing(of: catalog, kind: .instrument, query: "zzz", recent: [])
        #expect(AddPicker.moved(from: nil, by: 1, in: empty) == nil)
    }

    @Test("Recent plugins: new one in front, no duplicates, five kept")
    func recentUpdate() {
        let ids = (0..<6).map { PluginID(type: "aumu", subtype: "P\($0)", manufacturer: "Test") }
        #expect(AddPicker.recent(adding: ids[1], to: [ids[0], ids[1], ids[2]]) == [ids[1], ids[0], ids[2]])
        #expect(AddPicker.recent(adding: ids[5], to: Array(ids[0..<5])) == [ids[5], ids[0], ids[1], ids[2], ids[3]])
    }

    // MARK: - Building channels

    let routing = AddRouting(
        midiIn: MIDIRoute(sourceName: "Keys", channel: .channel(2)),
        audioIn: .stereo(left: 4, right: 5),
        sidechainIn: .mono(0),
        audioOut: .stereo(left: 2, right: 3)
    )

    @Test("Fields before capabilities are known")
    func unknownFields() {
        #expect(AddPicker.fields(kind: .instrument, capabilities: nil) == ChannelFields(midiIn: true, audioIn: false, sidechainIn: false))
        #expect(AddPicker.fields(kind: .effect, capabilities: nil) == ChannelFields(midiIn: false, audioIn: true, sidechainIn: false))
    }

    @Test("A new instrument takes MIDI and out, and audio in only when the plugin has it")
    func newInstrument() {
        let caps = PluginCapabilities(acceptsMIDI: true, hasAudioIn: false, hasSidechain: false)
        let channel = AddPicker.channel(plugin: mariana, preset: .defaultSound, routing: routing, capabilities: caps)
        #expect(channel.kind == .instrument)
        #expect(channel.slot == PluginSlot(plugin: mariana.id, displayName: "Mariana"))
        #expect(channel.midiIn == routing.midiIn)
        #expect(channel.audioIn == nil)
        #expect(channel.sidechainIn == nil)
        #expect(channel.audioOut == routing.audioOut)
        #expect(channel.effects.isEmpty)
    }

    @Test("A new effect with a sidechain keeps audio and sidechain in")
    func newEffect() {
        let caps = PluginCapabilities(acceptsMIDI: false, hasAudioIn: true, hasSidechain: true)
        let channel = AddPicker.channel(plugin: reverb, preset: .defaultSound, routing: routing, capabilities: caps)
        #expect(channel.kind == .effect)
        #expect(channel.midiIn == nil)
        #expect(channel.audioIn == routing.audioIn)
        #expect(channel.sidechainIn == routing.sidechainIn)
    }

    @Test("Unknown capabilities use the fields shown meanwhile")
    func newWithUnknownCapabilities() {
        let instrument = AddPicker.channel(plugin: mariana, preset: .defaultSound, routing: routing, capabilities: nil)
        #expect(instrument.midiIn == routing.midiIn)
        #expect(instrument.audioIn == nil && instrument.sidechainIn == nil)
        let effect = AddPicker.channel(plugin: reverb, preset: .defaultSound, routing: routing, capabilities: nil)
        #expect(effect.midiIn == nil)
        #expect(effect.audioIn == routing.audioIn)
        #expect(effect.sidechainIn == nil)
    }

    @Test("Presets set the slot: default none, saved name and state, factory name only")
    func presets() {
        let state = Data([1, 2, 3])
        let saved = AddPicker.slot(plugin: mariana, preset: .saved(Preset(name: "Pad", plugin: mariana.id, state: state)))
        #expect(saved.presetName == "Pad" && saved.state == state)
        let factory = AddPicker.slot(plugin: mariana, preset: .factory("Bell"))
        #expect(factory.presetName == "Bell" && factory.state == nil)
        let plain = AddPicker.slot(plugin: mariana, preset: .defaultSound)
        #expect(plain.presetName == nil && plain.state == nil)
    }

    @Test("Replacing keeps id, MIDI, out and effects, and fits audio in and sidechain to the new plugin")
    func replacing() {
        let effect = InsertEffect.fixture()
        let old = Channel(
            kind: .instrument, slot: .fixture(), midiIn: routing.midiIn, audioIn: .mono(1),
            sidechainIn: .mono(2), audioOut: routing.audioOut, effects: [[effect]]
        )
        let withInput = PluginCapabilities(acceptsMIDI: true, hasAudioIn: true, hasSidechain: false)
        let kept = AddPicker.replacing(old, with: tb303, preset: .factory("Acid"), capabilities: withInput)
        #expect(kept.id == old.id && kept.kind == old.kind)
        #expect(kept.slot.plugin == tb303.id && kept.slot.presetName == "Acid")
        #expect(kept.midiIn == old.midiIn && kept.audioOut == old.audioOut && kept.effects == old.effects)
        #expect(kept.audioIn == .mono(1))
        #expect(kept.sidechainIn == nil)

        let noInput = PluginCapabilities(acceptsMIDI: true, hasAudioIn: false, hasSidechain: true)
        let cleared = AddPicker.replacing(old, with: tb303, preset: .defaultSound, capabilities: noInput)
        #expect(cleared.audioIn == nil)
        #expect(cleared.sidechainIn == .mono(2))
    }

    @Test("Replacing a plugin puts Follow Start/Stop back on the default")
    func replacingResetsFollowStartStop() {
        var instrument = Channel.fixture(kind: .instrument)
        instrument.slot.followsTransport = true
        let replaced = AddPicker.replacing(instrument, with: tb303, preset: .defaultSound, capabilities: nil)
        #expect(replaced.slot.followsTransport == nil)
        #expect(!replaced.followsTransport)

        var standalone = Channel.fixture(kind: .effect)
        standalone.slot.followsTransport = false
        #expect(AddPicker.replacing(standalone, with: tb303, preset: .defaultSound, capabilities: nil).followsTransport)
    }

    @Test("An effect is inserted as a new row, or into a row next to the others")
    func inserting() {
        let first = InsertEffect.fixture()
        var channel = Channel.fixture(effectRows: [[first]])
        let series = InsertEffect.fixture()
        AddPicker.insert(series, into: &channel, row: nil)
        #expect(channel.effects == [[first], [series]])
        let parallel = InsertEffect.fixture()
        AddPicker.insert(parallel, into: &channel, row: 0)
        #expect(channel.effects == [[first, parallel], [series]])
        let beyond = InsertEffect.fixture()
        AddPicker.insert(beyond, into: &channel, row: 9)
        #expect(channel.effects.last == [beyond])
        var full = Channel.fixture(effectRows: [(0..<Channel.maxParallel).map { _ in InsertEffect.fixture() }])
        AddPicker.insert(.fixture(), into: &full, row: 0)
        #expect(full.effects.map(\.count) == [Channel.maxParallel, 1])
    }
}
