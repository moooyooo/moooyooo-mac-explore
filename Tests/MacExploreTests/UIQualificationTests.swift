import AppKit
import Darwin
import Foundation
import QuartzCore
import Testing
import ExplorerCore
import ExplorerPlatform
@testable import MacExplore

/// Opt-in Release measurements using synthetic files. Run scripts/benchmark-ui.sh.
/// Native rendering is submitted to AppKit; this does not measure the display's scanout.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MACEXPLORE_PERFORMANCE_DIRECTORY"] != nil))
@MainActor
struct UIQualificationTests {
    private final class WeakBrowser {
        weak var value: ExplorerBrowserController?
        init(_ value: ExplorerBrowserController?) { self.value = value }
    }
    private var output: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACEXPLORE_PERFORMANCE_DIRECTORY"]!)
    }

    private func fixture(_ count: Int, under root: URL) async throws -> URL {
        try await Task.detached {
            let folder = root.appendingPathComponent("items-\(count)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<count {
                let url = folder.appendingPathComponent(String(format: "file-%06d.txt", index))
                try Data("synthetic fixture\n".utf8).write(to: url)
            }
            return folder
        }.value
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool, seconds: Double = 15) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.userCancelled)
    }

    private func draw(_ window: NSWindow?) {
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        CATransaction.flush()
    }

    private func navigate(_ browser: ExplorerBrowserController, to folder: URL, count: Int) async throws -> Double {
        var finished: Double?
        let start = ProcessInfo.processInfo.systemUptime
        browser.onLoadFinished = {
            draw(browser.view.window)
            finished = ProcessInfo.processInfo.systemUptime
        }
        defer { browser.onLoadFinished = nil }
        browser.navigate(to: folder)
        try await waitUntil({ finished != nil }, seconds: 120)
        #expect(browser.readyItemCount == count)
        return try #require(finished) - start
    }

    private func p95(_ values: [Double]) -> Double {
        values.sorted()[max(0, Int(ceil(Double(values.count) * 0.95)) - 1)]
    }

    private func write(_ name: String, _ measurements: [String: Any]) throws {
        func hardware(_ key: String) -> String {
            var size = 0
            guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0, size < 1024 else { return "unknown" }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "unknown" }
            return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        var data = measurements
        data["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        data["hardwareModel"] = hardware("hw.model")
        data["cpu"] = hardware("machdep.cpu.brand_string")
        data["physicalMemoryBytes"] = ProcessInfo.processInfo.physicalMemory
        data["language"] = L10n.current.language.rawValue
        #if DEBUG
        data["configuration"] = "debug"
        Issue.record("Qualification requires scripts/test.sh -c release.")
        #else
        data["configuration"] = "release"
        #endif
        let json = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: output.appendingPathComponent(name + ".json"), options: .atomic)
    }

    @Test func directoryDisplayAndLargeFolderResponsiveness() async throws {
        _ = NSApplication.shared
        let root = output.appendingPathComponent("listing-fixtures")
        defer { try? FileManager.default.removeItem(at: root) }
        let small = try await fixture(1_000, under: root)
        let medium = try await fixture(10_000, under: root)
        let large = try await fixture(100_000, under: root)
        let controller = WorkspaceWindowController(number: 1, directories: [small], newWindow: {}, newInstance: {})
        defer { controller.stopLoading(); controller.close() }
        controller.showWindow(nil)
        let browser = try #require(controller.activeBrowser)
        try await waitUntil { browser.readyItemCount == 1_000 }
        var results: [String: Any] = [
            "scope": "Path confirmation through sorted native table layout and drawing submission",
            "cache": "Warm local filesystem; generated small UTF-8 text files",
        ]
        for (folder, count, budget) in [(small, 1_000, 0.3), (medium, 10_000, 1.0)] {
            var samples: [Double] = []
            for _ in 0..<10 { samples.append(try await navigate(browser, to: folder, count: count)) }
            results["items\(count)"] = ["seconds": samples, "p95Seconds": p95(samples), "budgetSeconds": budget]
            #expect(p95(samples) <= budget)
        }
        var previous = ProcessInfo.processInfo.systemUptime
        var maximumGap = 0.0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                let now = ProcessInfo.processInfo.systemUptime
                maximumGap = max(maximumGap, now - previous); previous = now
            }
        }
        defer { heartbeat.cancel() }
        await Task.yield()
        let duration = try await navigate(browser, to: large, count: 100_000)
        maximumGap = max(maximumGap, ProcessInfo.processInfo.systemUptime - previous)
        heartbeat.cancel()
        results["items100000"] = [
            "seconds": duration, "maximumMainActorHeartbeatGapSeconds": maximumGap,
            "testProcessPhysicalFootprintBytes": ProcessMetrics.physicalFootprint() ?? 0,
        ]
        try write("listing", results)
        // Responsiveness guard, separate from the 1,000/10,000-item display budgets.
        #expect(maximumGap < 0.25)
    }

    @Test func fiftyPaneCyclesReleaseBrowsersAndWatches() async throws {
        _ = NSApplication.shared
        let root = output.appendingPathComponent("lifecycle-fixtures")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try await fixture(1_000, under: root)
        let baseline = await DirectoryWatchCenter.shared.watchedDirectoryCount
        let controller = WorkspaceWindowController(number: 1, directories: [], newWindow: {}, newInstance: {})
        defer { controller.stopLoading(); controller.close() }
        controller.showWindow(nil)
        var footprints: [UInt64] = []
        for _ in 0..<50 {
            controller.addPane(directory: folder)
            let browser = WeakBrowser(controller.activeBrowser)
            try await waitUntil { browser.value?.readyItemCount == 1_000 }
            draw(controller.window)
            controller.closeActivePane()
            try await waitUntil { browser.value == nil }
            for _ in 0..<100 {
                if await DirectoryWatchCenter.shared.watchedDirectoryCount == baseline { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await DirectoryWatchCenter.shared.watchedDirectoryCount == baseline)
            draw(controller.window)
            footprints.append(try #require(ProcessMetrics.physicalFootprint()))
        }
        let first = footprints.prefix(10).sorted()[5], last = footprints.suffix(10).sorted()[5]
        let growth = Int64(last) - Int64(first)
        try write("lifecycle", [
            "cycles": 50, "itemsPerPane": 1_000, "allBrowsersReleased": true,
            "watchCountBefore": baseline, "watchCountAfter": await DirectoryWatchCenter.shared.watchedDirectoryCount,
            "testProcessPhysicalFootprintBytesAfterEachClose": footprints,
            "lastTenMedianMinusFirstTenMedianBytes": growth,
            "growthGuardBytes": 16 * 1_048_576,
        ])
        // Allows Cocoa warm caches while guarding sustained retention. Weak ownership
        // and exact watch counts above also verify resources that a plateau could hide.
        #expect(growth < 16 * 1_048_576)
    }

    private func launch(_ appURL: URL, folder: URL, report: URL, projects: [URL] = []) async throws -> (NSRunningApplication, [String: Any], Double) {
        var arguments = ["--folder", folder.path, "--language", "en", "--shortcuts", "explorer",
                         "--support-directory", output.appendingPathComponent("app-state").path,
                         "--diagnostics-file", report.path]
        for project in projects { arguments += ["--project", project.path] }
        let started = ProcessInfo.processInfo.systemUptime
        let app = try await InstanceLauncher.launch(applicationURL: appURL, arguments: arguments, activates: false)
        do {
            try await waitUntil { FileManager.default.fileExists(atPath: report.path) }
            let data = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
            let ready = try #require(data["firstDirectoryReadySystemUptime"] as? Double)
            #expect(data["readyPaneItemCounts"] as? [Int] == Array(repeating: 1_000, count: projects.isEmpty ? 1 : 6))
            return (app, data, ready - started)
        } catch {
            app.forceTerminate()
            throw error
        }
    }

    private func terminate(_ app: NSRunningApplication) async throws {
        #expect(app.terminate())
        try await waitUntil { app.isTerminated }
    }

    private nonisolated static func cpuSeconds(_ pid: pid_t) async throws -> Double {
        try await Task.detached {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-p", String(pid), "-o", "time="]
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
            let parts = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
            guard !parts.isEmpty, parts.allSatisfy({ Double($0) != nil }) else { throw CocoaError(.fileReadCorruptFile) }
            return parts.reduce(0.0) { $0 * 60 + Double($1)! }
        }.value
    }

    @Test func packagedWarmLaunchMemoryAndConcurrentProcessIdle() async throws {
        let appURL = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MACEXPLORE_TEST_APP"]))
        let root = output.appendingPathComponent("app-fixtures")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try await fixture(1_000, under: root)
        var projects: [URL] = []
        for parent in 0..<2 {
            var workspace = Workspace()
            for pane in 0..<3 {
                let unique = try await fixture(1_000, under: root.appendingPathComponent("window-\(parent)-pane-\(pane)"))
                workspace.add(directory: unique, canvas: .init(width: 1000, height: 700))
            }
            let project = root.appendingPathComponent("window-\(parent).mexplore")
            try ProjectDocument(name: "Performance \(parent)", workspace: workspace).encoded().write(to: project)
            projects.append(project)
        }
        var samples: [Double] = [], footprints: [UInt64] = []
        for iteration in 0...10 {
            let (app, report, time) = try await launch(appURL, folder: folder, report: output.appendingPathComponent("launch-\(iteration).json"))
            defer { if !app.isTerminated { app.forceTerminate() } }
            if iteration > 0 {
                samples.append(time)
                footprints.append(try #require(report["physicalFootprintBytes"] as? UInt64))
            }
            try await terminate(app)
        }
        let (single, singleReport, _) = try await launch(appURL, folder: folder, report: output.appendingPathComponent("single-idle.json"))
        defer { if !single.isTerminated { single.forceTerminate() } }
        let (multi, multiReport, _) = try await launch(appURL, folder: folder, report: output.appendingPathComponent("multi-idle.json"), projects: projects)
        defer { if !multi.isTerminated { multi.forceTerminate() } }
        let before = try await [Self.cpuSeconds(single.processIdentifier), Self.cpuSeconds(multi.processIdentifier)]
        let start = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(60))
        let after = try await [Self.cpuSeconds(single.processIdentifier), Self.cpuSeconds(multi.processIdentifier)]
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let cpu = zip(before, after).map { ($1 - $0) / elapsed * 100 }
        let singleMemory = try #require(singleReport["physicalFootprintBytes"] as? UInt64)
        let multiMemory = try #require(multiReport["physicalFootprintBytes"] as? UInt64)
        let appBytes = try await Task.detached {
            let files = try #require(FileManager.default.enumerator(at: appURL, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]))
            var bytes = 0
            while let url = files.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true { bytes += values.fileSize ?? 0 }
            }
            return bytes
        }.value
        try write("application", [
            "scope": "Release .app via NSWorkspace; request through native table drawing submission",
            "warmupLaunchesExcluded": 1, "itemsPerPane": 1_000, "warmLaunchSeconds": samples,
            "applicationLanguage": singleReport["language"] ?? "unknown",
            "sixPaneDataset": "Six distinct directories, three panes in each of two project windows",
            "warmLaunchP95Seconds": p95(samples), "singlePanePhysicalFootprintSamplesBytes": footprints,
            "singlePanePhysicalFootprintBytes": singleMemory, "sixPanePhysicalFootprintBytes": multiMemory,
            "concurrentProcessPhysicalFootprintTotalBytes": singleMemory + multiMemory,
            "idleSeconds": elapsed, "idleCPUPercentByProcess": cpu, "idleCPUPercentTotal": cpu.reduce(0, +),
            "appBytes": appBytes,
        ])
        try await terminate(single); try await terminate(multi)
        #expect(p95(samples) <= 1.0)
        #expect(footprints.allSatisfy { $0 <= 150 * 1_048_576 })
        #expect(singleMemory <= 150 * 1_048_576 && multiMemory <= 350 * 1_048_576)
        #expect(cpu.allSatisfy { $0 < 1 })
        #expect(appBytes <= 50 * 1_048_576)
    }
}
