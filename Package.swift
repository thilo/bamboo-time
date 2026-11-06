// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BambooTime",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "BambooTime"),
        .testTarget(name: "BambooTimeTests", dependencies: ["BambooTime"]),
    ]
)
