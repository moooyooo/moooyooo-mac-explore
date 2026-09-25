import AppKit
import Foundation
import Testing
@testable import ExplorerPlatform

/// Opt in with MACEXPLORE_TEST_APP pointing at an already built .app.
/// Exercises the actual launching service and independent processes, without UI automation.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACEXPLORE_TEST_APP"] != nil))
@MainActor
func independentAppProcesses() async throws {
    let appPath = try #require(ProcessInfo.processInfo.environment["MACEXPLORE_TEST_APP"])
    let appURL = URL(fileURLWithPath: appPath)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let firstReport = directory.appendingPathComponent("first.json")
    let secondReport = directory.appendingPathComponent("second.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try await InstanceLauncher.launch(applicationURL: appURL, arguments: [
        "--demo", "--folder", directory.path, "--diagnostics-file", firstReport.path,
    ], activates: false)
    defer { if !first.isTerminated { first.forceTerminate() } }
    let second = try await InstanceLauncher.launch(applicationURL: appURL, arguments: [
        "--folder", directory.path, "--diagnostics-file", secondReport.path,
    ], activates: false)
    defer { if !second.isTerminated { second.forceTerminate() } }

    #expect(first.processIdentifier != second.processIdentifier)
    for _ in 0..<150 {
        if FileManager.default.fileExists(atPath: firstReport.path), FileManager.default.fileExists(atPath: secondReport.path) { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    let firstData = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: firstReport)) as? [String: Any])
    let secondData = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: secondReport)) as? [String: Any])
    #expect(firstData["windows"] as? Int == 2)
    #expect(firstData["panes"] as? Int == 6)
    #expect(secondData["windows"] as? Int == 1)
    #expect(firstData["instanceID"] as? String != secondData["instanceID"] as? String)
    #expect(first.terminate())
    for _ in 0..<50 {
        if first.isTerminated { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(first.isTerminated)
    #expect(!second.isTerminated)
    #expect(second.terminate())
    for _ in 0..<50 {
        if second.isTerminated { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(second.isTerminated)
}
