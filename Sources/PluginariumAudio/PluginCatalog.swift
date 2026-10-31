import AudioToolbox
import PluginariumCore

/// Four-character-code helpers shared by the audio layer.
extension PluginID {

    var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: fourCC(type),
            componentSubType: fourCC(subtype),
            componentManufacturer: fourCC(manufacturer),
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    init(_ description: AudioComponentDescription) {
        self.init(
            type: string(fourCC: description.componentType),
            subtype: string(fourCC: description.componentSubType),
            manufacturer: string(fourCC: description.componentManufacturer)
        )
    }
}

/// Codes map byte-for-byte to Latin-1 characters, so every four-byte code round-trips
/// exactly (real manufacturer codes contain bytes >= 0x80). Short strings are space-padded.
func fourCC(_ string: String) -> FourCharCode {
    var bytes = string.unicodeScalars.prefix(4).map { $0.value <= 0xFF ? UInt8($0.value) : UInt8(ascii: "?") }
    while bytes.count < 4 { bytes.append(UInt8(ascii: " ")) }
    return bytes.reduce(FourCharCode(0)) { ($0 << 8) | FourCharCode($1) }
}

func string(fourCC code: FourCharCode) -> String {
    var scalars = String.UnicodeScalarView()
    for shift in [24, 16, 8, 0] {
        scalars.append(Unicode.Scalar(UInt8((code >> FourCharCode(shift)) & 0xFF)))
    }
    return String(scalars)
}

/// Lists the installed Audio Units that can be hosted: instruments, MIDI-controlled effects and effects.
public enum PluginCatalog {

    public static func scan() -> [PluginInfo] {
        var result: [PluginInfo] = []
        for type in ["aumu", "aumf", "aufx"] {
            guard let kind = PluginKind(auType: type) else { continue }
            var wanted = AudioComponentDescription(
                componentType: fourCC(type), componentSubType: 0, componentManufacturer: 0,
                componentFlags: 0, componentFlagsMask: 0
            )
            var component: AudioComponent?
            while true {
                component = AudioComponentFindNext(component, &wanted)
                guard let found = component else { break }
                var description = AudioComponentDescription()
                AudioComponentGetDescription(found, &description)
                var cfName: Unmanaged<CFString>?
                AudioComponentCopyName(found, &cfName)
                let full = (cfName?.takeRetainedValue() as String?) ?? ""
                // Components are named "Vendor: Plugin".
                let parts = full.components(separatedBy: ": ")
                let vendor = parts.count > 1 ? parts[0] : ""
                let name = parts.count > 1 ? parts.dropFirst().joined(separator: ": ") : full
                result.append(PluginInfo(id: PluginID(description), name: name, vendor: vendor, kind: kind))
            }
        }
        return result
    }
}
