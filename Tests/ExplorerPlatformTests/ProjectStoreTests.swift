import Darwin
import Foundation
import Testing
import ExplorerCore
@testable import ExplorerPlatform

struct StorageFixture {
    let root: URL
    var support: URL { root.appendingPathComponent("support") }
    var project: URL { root.appendingPathComponent("作業 🗂.mexplore") }
    init(base: URL = FileManager.default.temporaryDirectory) throws {
        root = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func document() -> ProjectDocument {
        var workspace = Workspace()
        workspace.add(directory: root, canvas: .init(width: 1000, height: 700))
        return ProjectDocument(name: "example", workspace: workspace)
    }
}

@Test func explicitLeaseReleaseIsIdempotentAndAllowsImmediateReacquisition() throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let first = try #require(try AdvisoryLease.acquire(key: "test", directory: fixture.support))
    first.release()
    let second = try #require(try AdvisoryLease.acquire(key: "test", directory: fixture.support))
    defer { second.release() }
    first.release() // Must not close a descriptor subsequently reused for the next owner.
    #expect(try AdvisoryLease.acquire(key: "test", directory: fixture.support) == nil)
}

@Test func savingReloadingAndCompetingOwners() async throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let first = ProjectStore(supportDirectory: fixture.support), second = ProjectStore(supportDirectory: fixture.support)
    let original = fixture.document()
    let saved = try await first.saveAs(original, to: fixture.project)
    #expect(saved.document.projectID != original.projectID)
    let opened = try await second.open(fixture.project)
    #expect(!opened.isWritable)
    await #expect(throws: (any Error).self) { try await second.save(opened.document, handleID: opened.handleID) }
    var changed = saved.document; changed.name = "更新"
    let updated = try await first.save(changed, handleID: saved.handleID)
    #expect(updated.document.revision != saved.document.revision)
    #expect(try ProjectDocument.decode(Data(contentsOf: fixture.project)).name == "更新")
    let copy = try await second.saveAs(opened.document, to: fixture.root.appendingPathComponent("別名.mexplore"))
    #expect(copy.isWritable && copy.document.projectID != saved.document.projectID)
    await first.close(saved.handleID)
    let acquired = try await second.reacquire(opened.handleID)
    #expect(acquired.isWritable && acquired.document.name == "更新")
    await second.close(acquired.handleID); await second.close(copy.handleID)
}

@Test func externalChangesAndDeletionNeverGetSilentlyOverwritten() async throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let store = ProjectStore(supportDirectory: fixture.support)
    let saved = try await store.saveAs(fixture.document(), to: fixture.project)
    let foreign = Data("foreign content".utf8)
    try foreign.write(to: fixture.project, options: .atomic)
    await #expect(throws: (any Error).self) { try await store.save(saved.document, handleID: saved.handleID) }
    #expect(try Data(contentsOf: fixture.project) == foreign)
    await #expect(throws: (any Error).self) { try await store.reacquire(saved.handleID) }
    try FileManager.default.removeItem(at: fixture.project)
    await #expect(throws: (any Error).self) { try await store.save(saved.document, handleID: saved.handleID) }
    #expect(!FileManager.default.fileExists(atPath: fixture.project.path))
    await store.close(saved.handleID)
}

@Test func atomicStagingFailureAndConcurrentChangePreserveOriginal() throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let original = Data("original".utf8), next = Data("next".utf8)
    try original.write(to: fixture.project)
    #expect(throws: (any Error).self) {
        try StorageIO.atomicWrite(next, to: fixture.project, expected: original) { handle, _ in
            try handle.write(contentsOf: Data("partial".utf8))
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        }
    }
    #expect(try Data(contentsOf: fixture.project) == original)
    let foreign = Data("external update".utf8)
    #expect(throws: (any Error).self) {
        try StorageIO.atomicWrite(next, to: fixture.project, expected: original) { handle, data in
            try handle.write(contentsOf: data)
            try foreign.write(to: fixture.project, options: .atomic)
        }
    }
    #expect(try Data(contentsOf: fixture.project) == foreign)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).filter { $0.hasSuffix(".tmp") }.isEmpty)
}

@Test func aliasesShareLockAndHardLinksAreReadOnly() async throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let store = ProjectStore(supportDirectory: fixture.support), other = ProjectStore(supportDirectory: fixture.support)
    let saved = try await store.saveAs(fixture.document(), to: fixture.project)
    let symlink = fixture.root.appendingPathComponent("alias.mexplore")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.project)
    let alias = try await other.open(symlink)
    #expect(!alias.isWritable)
    #expect(try await store.identity(of: symlink) == store.identity(of: fixture.project))
    let hardLink = fixture.root.appendingPathComponent("hard.mexplore")
    try FileManager.default.linkItem(at: fixture.project, to: hardLink)
    let hard = try await other.open(hardLink)
    #expect(!hard.isWritable)
    let data = try Data(contentsOf: fixture.project)
    await #expect(throws: (any Error).self) { try await store.save(saved.document, handleID: saved.handleID) }
    #expect(try Data(contentsOf: hardLink) == data)
    await store.close(saved.handleID); await other.close(alias.handleID); await other.close(hard.handleID)
}

@Test func movedFolderResolvesFromBookmark() async throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let folder = fixture.root.appendingPathComponent("original", isDirectory: true)
    let moved = fixture.root.appendingPathComponent("renamed", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var document = fixture.document(); document.panes[0].folder.url = folder
    let store = ProjectStore(supportDirectory: fixture.support)
    let saved = try await store.saveAs(document, to: fixture.project)
    #expect(saved.document.panes[0].folder.bookmark != nil)
    await store.close(saved.handleID)
    try FileManager.default.moveItem(at: folder, to: moved)
    let reopened = try await store.open(fixture.project)
    #expect(reopened.document.panes[0].folder.url.lastPathComponent == "renamed")
    await store.close(reopened.handleID)
}

@Test func readOnlyProjectCanBeOpenedButCannotBeReplaced() async throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let store = ProjectStore(supportDirectory: fixture.support)
    let original = try fixture.document().encoded()
    try original.write(to: fixture.project)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fixture.project.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.project.path) }
    let opened = try await store.open(fixture.project)
    #expect(!opened.isWritable)
    await #expect(throws: (any Error).self) { try await store.save(opened.document, handleID: opened.handleID) }
    #expect(try Data(contentsOf: fixture.project) == original)
    let copy = try await store.saveAs(opened.document, to: fixture.root.appendingPathComponent("writable.mexplore"))
    #expect(copy.isWritable)
    await store.close(opened.handleID); await store.close(copy.handleID)
}

@Test func twoRealProcessesAndCrashReleaseTheProjectLock() async throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let store = ProjectStore(supportDirectory: fixture.support)
    let saved = try await store.saveAs(fixture.document(), to: fixture.project)
    await store.close(saved.handleID)
    let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/StorageProbe")
    func launch(_ mode: String, _ report: String) throws -> Process {
        let process = Process(); process.executableURL = executable
        process.arguments = [mode, fixture.support.path, fixture.project.path, fixture.root.appendingPathComponent(report).path]
        try process.run(); return process
    }
    func report(_ name: String) async throws -> [String: Bool] {
        let url = fixture.root.appendingPathComponent(name)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) { return try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: url)) }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }
    let owner = try launch("hold", "owner.json")
    defer { if owner.isRunning { kill(owner.processIdentifier, SIGKILL); owner.waitUntilExit() } }
    #expect(try await report("owner.json")["writable"] == true)
    let competitor = try launch("save", "competitor.json")
    defer { if competitor.isRunning { kill(competitor.processIdentifier, SIGKILL); competitor.waitUntilExit() } }
    let result = try await report("competitor.json")
    #expect(result["writable"] == false && result["saved"] == false)
    #expect(try ProjectDocument.decode(Data(contentsOf: fixture.project)).name == saved.document.name)
    #expect(kill(owner.processIdentifier, SIGKILL) == 0)
    owner.waitUntilExit()
    let survivor = try await store.open(fixture.project)
    #expect(survivor.isWritable)
    _ = try await store.save(survivor.document, handleID: survivor.handleID)
    await store.close(survivor.handleID)
}
