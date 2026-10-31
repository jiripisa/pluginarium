/// Pluginarium logic that needs no UI. Keep it free of SwiftUI/AppKit so
/// `swift test` covers it quickly; the app target only presents it.
public enum PluginariumCore {

    /// The text the empty skeleton window shows. Replace with real logic.
    public static func greeting(appName: String) -> String {
        "Welcome to \(appName)"
    }
}
