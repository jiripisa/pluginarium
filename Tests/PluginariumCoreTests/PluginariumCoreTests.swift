import Testing
@testable import PluginariumCore

@Suite("PluginariumCore")
struct PluginariumCoreTests {

    @Test("Greeting names the app")
    func greetingNamesTheApp() {
        #expect(PluginariumCore.greeting(appName: "Pluginarium") == "Welcome to Pluginarium")
    }
}
