import AppKit
import SwiftUI
import PluginariumCore

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(PluginariumCore.greeting(appName: "Pluginarium"))
                .font(.title)
            Text("Your plugins as instruments in the studio.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 640, minHeight: 400)
    }
}
