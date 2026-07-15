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
    dependencies: [
        .package(url: "https://github.com/sbooth/CXXTagLib.git", exact: "2.3.0")
    ],
    targets: [
        .target(
            name: "CSafeFileBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CTagLibBridge",
            dependencies: [.product(name: "taglib", package: "CXXTagLib")],
            publicHeadersPath: "include"
        ),
        .target(name: "AudioToolboxCore", dependencies: ["CTagLibBridge", "CSafeFileBridge"]),
        .target(name: "AudioToolboxUI", dependencies: ["AudioToolboxCore"]),
        .executableTarget(name: "AudioToolbox", dependencies: ["AudioToolboxUI"]),
        .testTarget(name: "AudioToolboxCoreTests", dependencies: ["AudioToolboxCore"]),
        .testTarget(
            name: "AudioToolboxIntegrationTests",
            dependencies: ["AudioToolboxCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
