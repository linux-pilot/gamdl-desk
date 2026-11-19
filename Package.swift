// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GamdlDesk",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (argument building, link parsing, output parsing, process control): unit-tested.
        .target(name: "GamdlCore"),
        // SwiftUI app. build.sh wraps the binary in "Gamdl Desk.app".
        .executableTarget(name: "GamdlDesk", dependencies: ["GamdlCore"]),
        .testTarget(name: "GamdlCoreTests", dependencies: ["GamdlCore"]),
    ]
)
