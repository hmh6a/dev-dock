// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DevDock",
    platforms: [
        .macOS(.v13) // MenuBarExtra requires macOS 13+
    ],
    products: [
        .executable(name: "DevDock", targets: ["DevDockApp"]),
        .library(name: "DevDockCore", targets: ["DevDockCore"])
    ],
    targets: [
        // Pure, testable logic: models, parsing, system services, bridge protocol.
        .target(
            name: "DevDockCore"
        ),
        // The SwiftUI menu bar application. Kept thin — delegates all logic to DevDockCore.
        .executableTarget(
            name: "DevDockApp",
            dependencies: ["DevDockCore"]
        ),
        .testTarget(
            name: "DevDockCoreTests",
            dependencies: ["DevDockCore"]
        )
    ]
)
