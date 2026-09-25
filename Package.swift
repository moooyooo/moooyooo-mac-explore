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
        .executableTarget(name: "StorageProbe", dependencies: ["ExplorerCore", "ExplorerPlatform"], path: "Tests/Support/StorageProbe"),
        .executableTarget(name: "BrowserBenchmark", dependencies: ["ExplorerCore", "ExplorerPlatform"], path: "Tools/BrowserBenchmark"),
        .testTarget(name: "ExplorerCoreTests", dependencies: ["ExplorerCore"]),
        .testTarget(name: "ExplorerPlatformTests", dependencies: ["ExplorerPlatform", "StorageProbe"]),
        .testTarget(name: "MacExploreTests", dependencies: ["MacExplore", "ExplorerCore", "ExplorerPlatform"]),
    ]
)
