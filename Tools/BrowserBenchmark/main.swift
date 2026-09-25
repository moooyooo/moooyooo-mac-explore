import Foundation
import ExplorerCore
import ExplorerPlatform

/// Read-only benchmark of enumeration plus the initial filtered/sorted projection.
/// AppKit row rendering, window creation and cold disk caches are not measured here.
@main struct BrowserBenchmark {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else {
            print("Usage: swift run -c release BrowserBenchmark FOLDER [RUNS]")
            return
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let runs = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 10 : 10
        guard (1...100).contains(runs) else { throw CocoaError(.validationNumberTooLarge) }
        var durations: [Double] = []
        var count = 0
        for _ in 0..<runs {
            let start = ProcessInfo.processInfo.systemUptime
            let entries = try await DirectoryReader.read(folder)
            count = try await DirectoryReader.project(entries, settings: .init()).count
            durations.append(ProcessInfo.processInfo.systemUptime - start)
        }
        let sorted = durations.sorted()
        let output: [String: Any] = [
            "scope": "DirectoryReader + projection; no AppKit rendering", "items": count, "runs": runs,
            "seconds": durations, "p95Seconds": sorted[max(0, Int(ceil(Double(runs) * 0.95)) - 1)],
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physicalFootprintBytes": ProcessMetrics.physicalFootprint() ?? 0,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
