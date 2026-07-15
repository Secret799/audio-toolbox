// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioToolbox",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AudioToolboxCore", targets: ["AudioToolboxCore"]),
        .library(name: "AudioToolboxUI", targets: ["AudioToolboxUI"]),
        .executable(name: "AudioToolbox", targets: ["AudioToolbox"])
    ],
    targets: [
        .target(name: "AudioToolboxCore"),
        .target(name: "AudioToolboxUI", dependencies: ["AudioToolboxCore"]),
        .executableTarget(name: "AudioToolbox", dependencies: ["AudioToolboxUI"]),
        .testTarget(name: "AudioToolboxCoreTests", dependencies: ["AudioToolboxCore"])
    ]
)
