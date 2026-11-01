// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pluginarium",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        // The macOS app (bundle assembled by build.sh — see development_workflow.md §2).
        .executable(name: "Pluginarium", targets: ["Pluginarium"]),
        // App logic without UI — what `swift test` covers.
        .library(name: "PluginariumCore", targets: ["PluginariumCore"]),
        // Command-line probe for the audio layer.
        .executable(name: "pluginarium-probe", targets: ["pluginarium-probe"]),
    ],
    dependencies: [
        // Auto-update: the standard updater for apps outside the App Store;
        // EdDSA-signed appcast on GitHub Pages.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        .target(
            name: "PluginariumCore",
            path: "Sources/PluginariumCore"
        ),
        // Real-time render core in C.
        .target(
            name: "CRenderCore",
            path: "Sources/CRenderCore",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        // Audio Unit hosting and audio engine.
        .target(
            name: "PluginariumAudio",
            dependencies: ["PluginariumCore", "CRenderCore"],
            path: "Sources/PluginariumAudio"
        ),
        // Test Audio Units for tests, and the safe ones for the debug app. Empty in a release.
        .target(
            name: "PluginariumTestUnits",
            path: "Sources/PluginariumTestUnits",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "pluginarium-probe",
            dependencies: ["PluginariumAudio", "PluginariumTestUnits", "CRenderCore"],
            path: "Sources/pluginarium-probe"
        ),
        .executableTarget(
            name: "Pluginarium",
            dependencies: [
                "PluginariumCore",
                "PluginariumAudio",
                "PluginariumTestUnits",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Pluginarium",
            linkerSettings: [
                // Embedded frameworks ship in Contents/Frameworks (build.sh).
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "PluginariumCoreTests",
            dependencies: ["PluginariumCore"],
            path: "Tests/PluginariumCoreTests"
        ),
        .testTarget(
            name: "PluginariumAudioTests",
            dependencies: ["PluginariumAudio", "PluginariumTestUnits", "CRenderCore", "PluginariumCore"],
            path: "Tests/PluginariumAudioTests"
        ),
    ]
)
