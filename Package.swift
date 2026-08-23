// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NimbusDMXHelper",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "DMXCore", targets: ["DMXCore"]),
        .executable(name: "NimbusDMXHelper", targets: ["NimbusDMXHelper"]),
        .executable(name: "dmxcli", targets: ["dmxcli"]),
    ],
    dependencies: [
        // Ours, MIT, no dependencies of its own: the GitHub-release auto-updater. Pinned by
        // Package.resolved — a new tag reaches this app only when someone bumps it here.
        .package(url: "https://github.com/njoubert/nimbus-updater.git", from: "1.2.0"),
    ],
    targets: [
        // Serial port, Enttec DMX USB Pro protocol, fixture profiles — and the updater config,
        // which the app and the CLI both need.
        .target(name: "DMXCore", dependencies: [
            .product(name: "NimbusUpdater", package: "nimbus-updater"),
        ]),
        // SwiftUI app.
        .executableTarget(
            name: "NimbusDMXHelper",
            dependencies: ["DMXCore"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        // Tiny CLI for scripting / smoke testing.
        .executableTarget(name: "dmxcli", dependencies: [
            "DMXCore",
            .product(name: "NimbusUpdater", package: "nimbus-updater"),
        ]),
    ]
)
