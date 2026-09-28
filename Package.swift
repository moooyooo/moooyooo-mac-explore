// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacExplore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacExplore", targets: ["MacExplore"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "ExplorerCore", resources: [.process("Resources")]),
        .target(name: "ExplorerPlatform", dependencies: ["ExplorerCore"]),
        .executableTarget(name: "MacExplore", dependencies: [
            "ExplorerCore", "ExplorerPlatform", .product(name: "Sparkle", package: "Sparkle")
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "StorageProbe", dependencies: ["ExplorerCore", "ExplorerPlatform"], path: "Tests/Support/StorageProbe"),
        .executableTarget(name: "UpdateProbe", dependencies: [
            "ExplorerCore", "ExplorerPlatform", .product(name: "Sparkle", package: "Sparkle")
        ], path: "Tests/Support/UpdateProbe",
           linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "BrowserBenchmark", dependencies: ["ExplorerCore", "ExplorerPlatform"], path: "Tools/BrowserBenchmark"),
        .testTarget(name: "ExplorerCoreTests", dependencies: ["ExplorerCore"]),
        .testTarget(name: "ExplorerPlatformTests", dependencies: ["ExplorerPlatform", "StorageProbe"]),
        .testTarget(name: "MacExploreTests", dependencies: ["MacExplore", "ExplorerCore", "ExplorerPlatform"]),
    ]
)
