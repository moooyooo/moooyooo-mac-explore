import AppKit
import Foundation
import Testing
import ExplorerCore
@testable import ExplorerPlatform

/// Launch the relocated distributable, not the executable in SwiftPM's build tree.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACEXPLORE_TEST_APP"] != nil))
@MainActor
func relocatedApplicationsUseBundledEnglishAndJapaneseResources() async throws {
    let appPath = try #require(ProcessInfo.processInfo.environment["MACEXPLORE_TEST_APP"])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let relocated = root.appendingPathComponent("Mac Explore.app")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: appPath), to: relocated)
    let directory = root.appendingPathComponent("資料")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (language, fileMenu) in [("en", "File"), ("ja", "ファイル")] {
        let report = root.appendingPathComponent(language + ".json")
        let app = try await InstanceLauncher.launch(applicationURL: relocated, arguments: [
            "--language", language, "--folder", directory.path,
            "--support-directory", root.appendingPathComponent("support").path,
            "--diagnostics-file", report.path,
        ], activates: false)
        defer { if !app.isTerminated { app.forceTerminate() } }
        for _ in 0..<150 {
            if FileManager.default.fileExists(atPath: report.path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let data = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
        #expect(data["language"] as? String == language)
        #expect((data["preferredLocalizations"] as? [String])?.first == language)
        #expect(data["localizationBundled"] as? Bool == true)
        #expect((data["menuTitles"] as? [String])?.contains(fileMenu) == true)
        #expect(data["panes"] as? Int == 1)
        #expect(app.terminate())
        for _ in 0..<50 {
            if app.isTerminated { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(app.isTerminated)
    }
}
