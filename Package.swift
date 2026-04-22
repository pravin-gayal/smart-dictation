// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SmartDictation",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SmartDictation",
            path: "Sources/SmartDictationLib"
        )
    ]
)
// No third-party dependencies — AVFoundation, Speech, AppKit, CoreGraphics are system frameworks
