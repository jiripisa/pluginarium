import Foundation
import Testing
@testable import PluginariumCore

struct PluginStateComparisonTests {
    /// A JUCE state: the magic, the length, and the XML text with a closing zero byte.
    private func juce(root: String = #"<Synth tempo="120" date="1000" name="Init">"#, body: String = #"<PARAM id="a" value="0.5"/>"#) -> Data {
        let xml = Data((#"<?xml version="1.0" encoding="UTF-8"?> "# + root + body + "</Synth>").utf8) + Data([0])
        var size = UInt32(xml.count).littleEndian
        return Data("VC2!".utf8) + Data(bytes: &size, count: 4) + xml
    }

    private func plist(juce: Data? = nil, data: Data = Data([1, 2, 3]), name: String = "Synth") throws -> Data {
        var dictionary: [String: Any] = ["data": data, "name": name, "version": 0]
        if let juce { dictionary["jucePluginState"] = juce }
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }

    @Test func identicalStatesAreTheSameSound() throws {
        let state = try plist(juce: juce())
        #expect(PluginStateComparison.isSameSound(state, state))
    }

    @Test func aRootDateIsIgnored() throws {
        let first = try plist(juce: juce())
        let later = try plist(juce: juce(root: #"<Synth tempo="120" date="1793491511962" name="Init">"#))
        #expect(first != later)
        #expect(PluginStateComparison.isSameSound(first, later))
    }

    @Test func aRootWithoutDateIsTheSameAsOneWithIt() throws {
        let stamped = try plist(juce: juce())
        let bare = try plist(juce: juce(root: #"<Synth tempo="120" name="Init">"#))
        #expect(PluginStateComparison.isSameSound(stamped, bare))
    }

    @Test func anotherRootAttributeIsAChange() throws {
        let first = try plist(juce: juce())
        let other = try plist(juce: juce(root: #"<Synth tempo="121" date="1000" name="Init">"#))
        #expect(!PluginStateComparison.isSameSound(first, other))
    }

    @Test func aDateOnANestedElementIsAChange() throws {
        let first = try plist(juce: juce(body: #"<PARAM id="a" date="1"/>"#))
        let other = try plist(juce: juce(body: #"<PARAM id="a" date="2"/>"#))
        #expect(!PluginStateComparison.isSameSound(first, other))
    }

    @Test func aChangedParameterInTheJuceStateIsAChange() throws {
        let first = try plist(juce: juce())
        let other = try plist(juce: juce(body: #"<PARAM id="a" value="0.6"/>"#))
        #expect(!PluginStateComparison.isSameSound(first, other))
    }

    @Test func aChangeInTheBinaryDataIsAChangeEvenWithTheSameJuceState() throws {
        let first = try plist(juce: juce(), data: Data([1, 2, 3]))
        let other = try plist(juce: juce(), data: Data([1, 2, 4]))
        #expect(!PluginStateComparison.isSameSound(first, other))
    }

    @Test func aPlistWithoutJuceDataComparesByStructure() throws {
        #expect(PluginStateComparison.isSameSound(try plist(), try plist()))
        #expect(!PluginStateComparison.isSameSound(try plist(), try plist(name: "Other")))
    }

    @Test func dataThatIsNotAPlistComparesByBytes() {
        #expect(PluginStateComparison.isSameSound(Data([1]), Data([1])))
        #expect(!PluginStateComparison.isSameSound(Data([1]), Data([2])))
    }

    @Test func juceDataWithBrokenXMLComparesByBytes() throws {
        let broken = Data("VC2!".utf8) + Data([1, 0, 0, 0, 0xFF])
        #expect(PluginStateComparison.isSameSound(try plist(juce: broken), try plist(juce: broken)))
        #expect(!PluginStateComparison.isSameSound(try plist(juce: broken), try plist(juce: juce())))
    }

    @Test func aLabelStaysCleanWhenOnlyTheTimeStampDiffers() throws {
        let saved = try plist(juce: juce())
        let now = try plist(juce: juce(root: #"<Synth tempo="120" date="2000" name="Init">"#))
        let plugin = PluginSlot.fixture().plugin
        let slot = PluginSlot(plugin: plugin, displayName: "Synth", presetName: "Lead", state: now)
        #expect(PresetLabel.text(for: slot, saved: [Preset(name: "Lead", plugin: plugin, state: saved)]) == "Lead")
        #expect(PresetLabel.stateAfterWindowClosed(slot: slot, opened: saved, closed: now) == nil)
    }

    @Test func aLabelStillReadsChangedForARealChange() throws {
        let saved = try plist(juce: juce())
        let now = try plist(juce: juce(body: #"<PARAM id="a" value="0.9"/>"#))
        let plugin = PluginSlot.fixture().plugin
        let slot = PluginSlot(plugin: plugin, displayName: "Synth", presetName: "Lead", state: now)
        #expect(PresetLabel.text(for: slot, saved: [Preset(name: "Lead", plugin: plugin, state: saved)]) == "Lead (changed)")
        #expect(PresetLabel.stateAfterWindowClosed(slot: slot, opened: saved, closed: saved) == saved)
    }
}
