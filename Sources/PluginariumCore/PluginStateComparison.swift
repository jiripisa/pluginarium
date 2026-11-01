import Foundation

/// Tells whether two saved plugin states hold the same sound. JUCE plugins stamp the time of each
/// read into their state, so a byte compare sees a change in a plugin nobody touched.
public enum PluginStateComparison {

    /// True if `first` and `second` differ at most in the time stamp JUCE writes to the root element of
    /// its state. Everything else, including binary data, must match exactly. A state that cannot be
    /// decoded compares byte for byte.
    public static func isSameSound(_ first: Data, _ second: Data) -> Bool {
        if first == second { return true }
        guard let one = try? PropertyListSerialization.propertyList(from: first, options: [], format: nil),
            let other = try? PropertyListSerialization.propertyList(from: second, options: [], format: nil)
        else { return false }
        return (normalized(one) as AnyObject).isEqual(normalized(other))
    }

    private static let juceMagic = Data("VC2!".utf8)
    private static let juceHeaderSize = 8

    /// `value` with every JUCE state in it stripped of its time stamp and length.
    private static func normalized(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]: return dictionary.mapValues(normalized)
        case let array as [Any]: return array.map(normalized)
        case let data as Data: return withoutTimeStamp(data) ?? data
        default: return value
        }
    }

    /// The XML of a JUCE state without the root's `date` attribute, or nil if `data` is not a JUCE
    /// state with readable XML. The length in the header goes too, as it follows the text.
    private static func withoutTimeStamp(_ data: Data) -> Data? {
        guard data.starts(with: juceMagic), data.count > juceHeaderSize,
            let text = String(data: data.dropFirst(juceHeaderSize), encoding: .utf8),
            let root = rootTag(in: text)
        else { return nil }
        var stripped = text
        if let stamp = text[root].range(of: #"\sdate="[^"]*""#, options: .regularExpression) {
            stripped.removeSubrange(stamp)
        }
        return juceMagic + Data(stripped.utf8)
    }

    /// The range of the root element's start tag, after the XML declaration.
    private static func rootTag(in text: String) -> Range<String.Index>? {
        var index = text.startIndex
        if let declaration = text.range(of: "?>"), text.hasPrefix("<?") { index = declaration.upperBound }
        guard let start = text[index...].firstIndex(of: "<") else { return nil }
        var quote: Character?
        var cursor = start
        while cursor < text.endIndex {
            let character = text[cursor]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return start..<text.index(after: cursor)
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }
}
