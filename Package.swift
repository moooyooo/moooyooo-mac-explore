// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacExplore",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacExplore", targets: ["MacExplore"])],
    targets: [
        .target(name: "ExplorerCore"),
        .target(name: "ExplorerPlatform", dependencies: ["ExplorerCore"]),
        .executableTarget(name: "MacExplore", dependencies: ["ExplorerCore", "ExplorerPlatform"]),
        .testTarget(name: "ExplorerCoreTests", dependencies: ["ExplorerCore"]),
        .testTarget(name: "ExplorerPlatformTests", dependencies: ["ExplorerPlatform"]),
    ]
)
