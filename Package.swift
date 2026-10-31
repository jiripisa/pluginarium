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
    ],
    targets: [
        .target(
            name: "PluginariumCore",
            path: "Sources/PluginariumCore"
        ),
        .executableTarget(
            name: "Pluginarium",
            dependencies: [
                "PluginariumCore",
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
    ]
)
