import AppKit
import Foundation
import Testing
import ExplorerCore
@testable import ExplorerPlatform

@Test(.enabled(if: ProcessInfo.processInfo.environment["MACEXPLORE_TEST_APP"] != nil))
@MainActor
func realApplicationsRestoreProjectsAndShowSingleWriterOwnership() async throws {
    let appPath = try #require(ProcessInfo.processInfo.environment["MACEXPLORE_TEST_APP"])
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let store = ProjectStore(supportDirectory: fixture.support)
    var document = fixture.document()
    var workspace = try Workspace(project: document)
    workspace.add(directory: fixture.root.appendingPathComponent("missing"), canvas: .init(width: 1000, height: 700))
    document = ProjectDocument(name: "App test", workspace: workspace)
    let saved = try await store.saveAs(document, to: fixture.project)
    await store.close(saved.handleID)
    func launch(_ name: String) async throws -> NSRunningApplication {
        try await InstanceLauncher.launch(applicationURL: URL(fileURLWithPath: appPath), arguments: [
            "--project", fixture.project.path, "--support-directory", fixture.support.path,
            "--diagnostics-file", fixture.root.appendingPathComponent(name).path,
        ], activates: false)
    }
    func report(_ name: String) async throws -> [String: Any] {
        let url = fixture.root.appendingPathComponent(name)
        for _ in 0..<150 {
            if FileManager.default.fileExists(atPath: url.path) { return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }
    let first = try await launch("first.json")
    defer { if !first.isTerminated { first.forceTerminate() } }
    let firstReport = try await report("first.json")
    #expect(firstReport["windows"] as? Int == 1)
    #expect(firstReport["panes"] as? Int == 2)
    #expect(firstReport["projects"] as? Int == 1)
    #expect(firstReport["readOnlyProjects"] as? Int == 0)
    #expect(firstReport["dirtyProjects"] as? Int == 0)
    let second = try await launch("second.json")
    defer { if !second.isTerminated { second.forceTerminate() } }
    let secondReport = try await report("second.json")
    #expect(secondReport["readOnlyProjects"] as? Int == 1)
    #expect(secondReport["panes"] as? Int == 2)
    #expect(secondReport["dirtyProjects"] as? Int == 0)
    #expect(first.processIdentifier != second.processIdentifier)
    #expect(first.terminate()); #expect(second.terminate())
    for _ in 0..<50 {
        if first.isTerminated && second.isTerminated { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    for (app, name) in [(first, "first.json"), (second, "second.json")] where !app.isTerminated {
        let url = fixture.root.appendingPathComponent(name).appendingPathExtension("termination.json")
        let state = (try? String(contentsOf: url, encoding: .utf8)) ?? "No termination request report received."
        print("App termination diagnostics (\(name)): \(state)")
    }
    #expect(first.isTerminated && second.isTerminated)
    // Healthy exit cleans up only each instance's own session and releases editing.
    let after = try await store.open(fixture.project)
    #expect(after.isWritable)
    #expect(after.document.projectID == saved.document.projectID)
    await store.close(after.handleID)
    let sessions = try FileManager.default.contentsOfDirectory(atPath: fixture.support.appendingPathComponent("Sessions").path)
    #expect(sessions.filter { $0.hasSuffix(".json") }.isEmpty)
}
