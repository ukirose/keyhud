// swift-tools-version:5.9
import PackageDescription

// Split into a library plus a one-line executable so the logic can be tested. The
// alternative — a single executable target — cannot be imported by a test target, and the
// hand-rolled harness under verify/ can only reach what it can drive through a process
// boundary. PanelContent, KeyboardLayout.locate and the modifier decoding are pure
// functions that were previously only observable by looking at a rendered panel.
let package = Package(
    name: "KeyHUD",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "KeyHUDCore", path: "Sources/KeyHUDCore"),
        .executableTarget(name: "KeyHUDApp", dependencies: ["KeyHUDCore"], path: "Sources/KeyHUDApp"),
        .testTarget(name: "KeyHUDCoreTests", dependencies: ["KeyHUDCore"], path: "Tests/KeyHUDCoreTests"),
    ]
)
