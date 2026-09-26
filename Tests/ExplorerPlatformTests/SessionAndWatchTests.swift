import Foundation
import Testing
import ExplorerCore
@testable import ExplorerPlatform

@Test func recoveryExcludesLiveOwnersAndClaimsCrashedSessionsExclusively() async throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let deadID = UUID()
    var owner: SessionStore? = SessionStore(instanceID: deadID, supportDirectory: fixture.support)
    let reader = SessionStore(instanceID: UUID(), supportDirectory: fixture.support)
    let competitor = SessionStore(instanceID: UUID(), supportDirectory: fixture.support)
    try await owner?.start(); try await reader.start(); try await competitor.start()
    let workspace = RecoveryWorkspace(document: fixture.document(), sourceURL: fixture.project)
    try await owner?.update([workspace])
    #expect(try await reader.available().isEmpty)
    owner = nil // Simulates loss of the owner without normal session cleanup.
    let available = try await reader.available()
    #expect(available.map(\.id) == [deadID])
    let recovered = try await reader.claim(deadID)
    #expect(recovered.workspaces[0].document == workspace.document)
    await #expect(throws: (any Error).self) { try await competitor.claim(deadID) }
    #expect(try await competitor.available().isEmpty)
    try await reader.update(recovered.workspaces)
    try await reader.finishClaim(deadID, consumed: true)
    #expect(try await competitor.available().isEmpty)
    try await reader.finish(); try await competitor.finish()
}

@Test func corruptRecoveryDoesNotHideValidSessionsAndIsPreserved() async throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let reader = SessionStore(instanceID: UUID(), supportDirectory: fixture.support)
    try await reader.start()
    let corrupt = fixture.support.appendingPathComponent("Sessions/\(UUID().uuidString).json")
    try Data("broken".utf8).write(to: corrupt)
    #expect(try await reader.available().isEmpty)
    #expect(try String(contentsOf: corrupt, encoding: .utf8) == "broken")
    try await reader.finish()
}

@Test func browserRecoveryPersistsPrivatelyAndInvalidUpdatesPreservePriorState() async throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let id = UUID()
    let store = SessionStore(instanceID: id, supportDirectory: fixture.support)
    try await store.start()
    let document = fixture.document()
    let pane = try #require(document.panes.first)
    let history = try NavigationHistory(entries: [pane.folder.url], index: 0)
    let state = BrowserSession(history: history, selectedNames: ["資料.txt"], topVisibleName: "資料.txt", rowOffset: 5)
    var recovery = RecoveryWorkspace(document: document, sourceURL: fixture.project, browserStates: [RecoveryPane(id: pane.id, state: state)])
    try await store.update([recovery])
    let file = fixture.support.appendingPathComponent("Sessions/\(id.uuidString).json")
    let baseline = try Data(contentsOf: file)
    let decoded = try JSONDecoder().decode(RecoverySession.self, from: baseline)
    #expect(decoded.workspaces.first?.browserStates?.first?.state == state)
    #expect(try ItemIdentity.read(file).mode & 0o777 == 0o600)
    recovery.browserStates = [RecoveryPane(id: UUID(), state: state)]
    await #expect(throws: (any Error).self) { try await store.update([recovery]) }
    #expect(try Data(contentsOf: file) == baseline)
    var wrongFolder = state
    wrongFolder.history = try NavigationHistory(entries: [URL(fileURLWithPath: "/tmp/different")], index: 0)
    recovery.browserStates = [RecoveryPane(id: pane.id, state: wrongFolder)]
    await #expect(throws: (any Error).self) { try await store.update([recovery]) }
    #expect(try Data(contentsOf: file) == baseline)
    let projectJSON = String(decoding: try document.encoded(), as: UTF8.self)
    #expect(!projectJSON.contains("selectedNames") && !projectJSON.contains("rowOffset"))
    try await store.finish()
}

@Test func recoveryWithoutBrowserStateRemainsCompatible() throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let previous = RecoveryWorkspace(document: fixture.document(), sourceURL: nil)
    let data = try JSONEncoder().encode(previous)
    #expect(!String(decoding: data, as: UTF8.self).contains("browserStates"))
    let decoded = try JSONDecoder().decode(RecoveryWorkspace.self, from: data)
    try decoded.validate()
    #expect(decoded.browserStates == nil)
}

@Test func concurrentRecentUpdatesMergeInsteadOfOverwriting() async throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let first = RecentProjectStore(supportDirectory: fixture.support), second = RecentProjectStore(supportDirectory: fixture.support)
    let urls = (0..<20).map { fixture.root.appendingPathComponent("\($0).mexplore") }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for (i, url) in urls.enumerated() {
            let store = i.isMultiple(of: 2) ? first : second
            group.addTask { try await store.record(url) }
        }
        try await group.waitForAll()
    }
    #expect(Set(try await first.list()) == Set(urls))
    try await second.record(urls[0])
    #expect(try await first.list().first == urls[0])
    #expect(try await first.list().count == 20)
}

private actor EventCounter {
    var count = 0
    func increment() { count += 1 }
}

@Test func unusedDirectorySubscriptionIsReleased() async throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let center = DirectoryWatchCenter()
    // Navigation can be cancelled after registration but before iteration starts.
    _ = try await center.events(at: fixture.root)
    for _ in 0..<100 {
        if await center.watchedDirectoryCount == 0 { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await center.watchedDirectoryCount == 0)
}

@Test(arguments: [false, true]) func watchersShareStreamsDetectContentChangesAndReleaseOnCancellation(inTemporaryDirectory: Bool) async throws {
    let build = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/watch-tests")
    let fixture = try StorageFixture(base: inTemporaryDirectory ? FileManager.default.temporaryDirectory : build); defer { fixture.cleanup() }
    let center = DirectoryWatchCenter()
    let first = try await center.events(at: fixture.root), second = try await center.events(at: fixture.root)
    #expect(await center.watchedDirectoryCount == 1)
    let a = EventCounter(), b = EventCounter()
    let firstTask = Task { for await _ in first { await a.increment() } }
    let secondTask = Task { for await _ in second { await b.increment() } }
    defer { firstTask.cancel(); secondTask.cancel() }
    let file = fixture.root.appendingPathComponent("changed.txt")
    try Data("initial".utf8).write(to: file)
    for _ in 0..<100 {
        let countA = await a.count, countB = await b.count
        if countA > 0 && countB > 0 { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    let old = await a.count
    #expect(old > 0)
    #expect(await b.count > 0)
    // A write inside an existing file must be noticed, not only directory entries.
    let handle = try FileHandle(forWritingTo: file)
    try handle.write(contentsOf: Data("updated".utf8)); try handle.close()
    for _ in 0..<100 {
        if await a.count > old { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(await a.count > old)
    firstTask.cancel(); await firstTask.value
    #expect(await center.watchedDirectoryCount == 1)
    secondTask.cancel(); await secondTask.value
    for _ in 0..<50 {
        if await center.watchedDirectoryCount == 0 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await center.watchedDirectoryCount == 0)
    for _ in 0..<50 {
        let events = try await center.events(at: fixture.root)
        let task = Task { for await _ in events {} }
        task.cancel(); await task.value
    }
    for _ in 0..<50 {
        if await center.watchedDirectoryCount == 0 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await center.watchedDirectoryCount == 0)
}

@Test func directoryProjectionAndSymbolicFolderNavigation() async throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let child = fixture.root.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let link = fixture.root.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: child)
    for name in ["資料10.txt", "資料2.txt", "other.txt"] { try Data(name.utf8).write(to: fixture.root.appendingPathComponent(name)) }
    let entries = try await DirectoryReader.read(fixture.root)
    #expect(entries.first { $0.url.lastPathComponent == "linked" }?.isBrowsable == true)
    var settings = BrowserSettings(); settings.filter = "資料"; settings.ascending = false
    #expect(try await DirectoryReader.project(entries, settings: settings).map(\.name) == ["資料10.txt", "資料2.txt"])
}
