// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Schneefall",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SnowCore"),
        .executableTarget(name: "Schneefall", dependencies: ["SnowCore"]),
        .testTarget(name: "SnowCoreTests", dependencies: ["SnowCore"]),
    ],
    swiftLanguageModes: [.v5]
)
