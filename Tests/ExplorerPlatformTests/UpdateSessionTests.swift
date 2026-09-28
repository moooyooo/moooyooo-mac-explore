import Darwin
import Foundation
import Testing
import ExplorerCore
@testable import ExplorerPlatform

struct UpdateSessionTests {
    @Test func interruptedCheckRecoversAfterRebootWithoutTrustingATimeout() async throws {
        let f = try StorageFixture(); defer { f.cleanup() }
        let original = UpdateSessionStore(bundleURL: f.root, supportDirectory: f.support, testBootIdentifier: "boot-a")
        _ = try await original.register(build: "7")
        let snapshot = UpdateWorkspace(workspace: .init(document: f.document(), sourceURL: nil),
                                       savedDigest: nil, isDirty: true)
        try await original.beginUpdate(workspaces: [snapshot])
        await original.close() // Hard crash before the installer (or normal quit).
        let sameBoot = UpdateSessionStore(bundleURL: f.root, supportDirectory: f.support, testBootIdentifier: "boot-a")
        await #expect(throws: (any Error).self) { _ = try await sameBoot.register(build: "7") }
        let rebooted = UpdateSessionStore(bundleURL: f.root, supportDirectory: f.support, testBootIdentifier: "boot-b")
        let saved = try #require(try await rebooted.register(build: "7"))
        #expect(saved.workspaces.first?.workspace.document == snapshot.workspace.document)
        try await rebooted.finishRestart()
        try await rebooted.beginUpdate(); try await rebooted.endUpdate()
        await rebooted.close()
    }
    @Test func liveInstancesPreventUpdatingAndUpdatesPreventNewInstances() async throws {
        let f = try StorageFixture(); defer { f.cleanup() }
        let a = UpdateSessionStore(bundleURL: f.root, supportDirectory: f.support)
        let b = UpdateSessionStore(bundleURL: f.root, supportDirectory: f.support)
        #expect(try await a.register(build: "7") == nil)
        #expect(try await b.register(build: "7") == nil)
        await #expect(throws: (any Error).self) { try await a.beginUpdate() }
        await #expect(throws: (any Error).self) { try await b.beginUpdate() }
        await b.close()
        try await a.beginUpdate()
        await #expect(throws: (any Error).self) { _ = try await b.register(build: "7") }
        try await a.endUpdate()
        #expect(try await b.register(build: "7") == nil)
        await a.close(); await b.close()
    }

    @Test func concurrentUpgradesNeverEvictAnotherLiveInstance() async throws {
        let f = try StorageFixture(); defer { f.cleanup() }
        let stores = (0..<6).map { _ in UpdateSessionStore(bundleURL: f.root, supportDirectory: f.support) }
        for store in stores { _ = try await store.register(build: "7") }
        let winners = await withTaskGroup(of: Bool.self) { group in
            for store in stores {
                group.addTask { do { try await store.beginUpdate(); return true } catch { return false } }
            }
            var count = 0
            for await won in group { if won { count += 1 } }
            return count
        }
        #expect(winners == 0)
        for store in stores { await store.close() }
    }

    @Test func durableHandoffBlocksOldBuildAndIsConsumedOnceByTheNewBuild() async throws {
        let f = try StorageFixture(); defer { f.cleanup() }
        let owner = UpdateSessionStore(bundleURL: f.root, supportDirectory: f.support)
        _ = try await owner.register(build: "7"); try await owner.beginUpdate()
        let snapshot = UpdateWorkspace(workspace: .init(document: f.document(), sourceURL: nil),
                                       savedDigest: nil, isDirty: true)
        try await owner.prepareRestart(targetBuild: "8", workspaces: [snapshot])
        // A prepared marker survives owner exit and does not expire with wall time.
        await owner.close()
        let old = UpdateSessionStore(bundleURL: f.root, supportDirectory: f.support)
        await #expect(throws: (any Error).self) { _ = try await old.register(build: "7") }
        let first = UpdateSessionStore(bundleURL: f.root, supportDirectory: f.support)
        let second = UpdateSessionStore(bundleURL: f.root, supportDirectory: f.support)
        let restart = try #require(try await first.register(build: "8"))
        #expect(restart.workspaces.count == 1 && restart.workspaces[0].isDirty)
        #expect(restart.workspaces[0].workspace.document == snapshot.workspace.document)
        #expect(try await second.register(build: "8") == nil)
        await #expect(throws: (any Error).self) { try await first.beginUpdate() }
        // Simulate the restored process crashing before durably consuming its state.
        await first.close(); await second.close()
        let survivor = UpdateSessionStore(bundleURL: f.root, supportDirectory: f.support)
        #expect(try await survivor.register(build: "8") != nil)
        try await survivor.finishRestart()
        try await survivor.beginUpdate()
        try await survivor.endUpdate()
        await survivor.close()
        let next = UpdateSessionStore(bundleURL: f.root, supportDirectory: f.support)
        #expect(try await next.register(build: "8") == nil)
        await next.close()
    }

    @Test func invalidSnapshotsAndDowngradesNeverCommitARestart() async throws {
        let f = try StorageFixture(); defer { f.cleanup() }
        let gate = UpdateSessionStore(bundleURL: f.root, supportDirectory: f.support)
        _ = try await gate.register(build: "7"); try await gate.beginUpdate()
        await #expect(throws: (any Error).self) { try await gate.prepareRestart(targetBuild: "7", workspaces: []) }
        var document = f.document(); document.panes[0].folder.url = URL(string: "https://example.invalid")!
        let invalid = UpdateWorkspace(workspace: .init(document: document, sourceURL: nil), savedDigest: nil, isDirty: true)
        await #expect(throws: (any Error).self) { try await gate.prepareRestart(targetBuild: "8", workspaces: [invalid]) }
        try await gate.endUpdate(); await gate.close()
        let next = UpdateSessionStore(bundleURL: f.root, supportDirectory: f.support)
        #expect(try await next.register(build: "7") == nil)
        await next.close()
    }

    @Test func aliasesCoordinateWhileSeparateAppCopiesAreIndependent() async throws {
        let f = try StorageFixture(); defer { f.cleanup() }
        let app = f.root.appendingPathComponent("App.app")
        let alias = f.root.appendingPathComponent("Alias.app")
        let other = f.root.appendingPathComponent("Other.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        let a = UpdateSessionStore(bundleURL: app, supportDirectory: f.support)
        let b = UpdateSessionStore(bundleURL: alias, supportDirectory: f.support)
        let c = UpdateSessionStore(bundleURL: other, supportDirectory: f.support)
        _ = try await a.register(build: "7"); _ = try await b.register(build: "7"); _ = try await c.register(build: "7")
        await #expect(throws: (any Error).self) { try await a.beginUpdate() }
        try await c.beginUpdate()
        await a.close(); await b.close(); await c.close()
    }

    @Test func realProcessCrashReleasesLiveLeaseWithoutDiscardingTheParent() async throws {
        let f = try StorageFixture(); defer { f.cleanup() }
        let parent = UpdateSessionStore(bundleURL: f.root, supportDirectory: f.support)
        _ = try await parent.register(build: "7")
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/StorageProbe")
        let report = f.root.appendingPathComponent("child-ready")
        let child = Process(); child.executableURL = executable
        child.arguments = ["hold-update", f.support.path, f.root.path, report.path]
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: report.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(FileManager.default.fileExists(atPath: report.path))
        await #expect(throws: (any Error).self) { try await parent.beginUpdate() }
        #expect(kill(child.processIdentifier, SIGKILL) == 0); child.waitUntilExit()
        try await parent.beginUpdate()
        try await parent.endUpdate(); await parent.close()
    }
}
