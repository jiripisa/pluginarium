import Foundation

/// An audio device the system lists.
public struct DeviceChoice: Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// What the selectors of the Settings screen offer, like `ChannelOptions` does for a channel.
public enum SettingsOptions {

    public static let systemDefaultNote = "Set by the system. Pick a device to change these."

    /// System default first, then the devices by name. A picked device that is gone stays listed.
    public static func devices(_ available: [DeviceChoice], current: String?, knownNames: [String: String]) -> [RouteOption<String?>] {
        let sorted = available.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var options = [RouteOption<String?>(nil, "System default")] + sorted.map { RouteOption($0.id, $0.name) }
        if let current, !available.contains(where: { $0.id == current }) {
            options.append(RouteOption(current, "\(knownNames[current] ?? current) (not connected)"))
        }
        return options
    }

    public static func sampleRates(current: Double) -> [RouteOption<Double>] {
        var rates: [Double] = [44100, 48000, 96000]
        if !rates.contains(current) { rates.append(current) }
        return rates.map { RouteOption($0, sampleRateLabel($0)) }
    }

    public static func bufferSizes(current: Int) -> [RouteOption<Int>] {
        var sizes = [64, 128, 256, 512]
        if !sizes.contains(current) { sizes.append(current) }
        return sizes.map { RouteOption($0, bufferLabel($0)) }
    }

    /// None first, then the system's sources. A stored source the system lacks is listed as not connected.
    public static func clockSources(_ sources: [String], current: String?) -> [RouteOption<String?>] {
        var options = [RouteOption<String?>(nil, "None")] + sources.map { RouteOption($0, $0) }
        if let current, !sources.contains(current) {
            options.append(RouteOption(current, "\(current) (not connected)"))
        }
        return options
    }

    /// Only a device the owner picked is given a sample rate and buffer size. With System default the
    /// device keeps what it runs at, and these show what runs.
    public static func editsDeviceValues(in settings: AppSettings) -> Bool {
        settings.audioDeviceUID != nil
    }

    public static func sampleRateLabel(_ rate: Double) -> String {
        let kilohertz = rate / 1000
        let text = kilohertz == kilohertz.rounded() ? String(Int(kilohertz)) : String(format: "%g", (kilohertz * 10).rounded() / 10)
        return "\(text) kHz"
    }

    public static func bufferLabel(_ frames: Int) -> String { "\(frames) samples" }
}
