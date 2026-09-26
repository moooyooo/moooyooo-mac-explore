import Foundation
import Testing
@testable import ExplorerPlatform

@Test func changedCutSourceAndInterruptedClaimCannotBeMoved() async throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let source = fixture.root.appendingPathComponent("item")
    try Data("original".utf8).write(to: source)
    let store = CutTransferStore(supportDirectory: fixture.support)
    let token = try await store.create([source])
    let claim = try await store.acquire(token, clipboardURLs: [source])
    try Data("external edit".utf8).write(to: source)
    await #expect(throws: CutTransferError.self) { try await claim.beginMoving(claim.sources[0]) }
    #expect(try String(contentsOf: source, encoding: .utf8) == "external edit")
    let fresh = try await store.create([source])
    do {
        let second = try await store.acquire(fresh, clipboardURLs: [source])
        try await second.beginMoving(second.sources[0])
        // No finish: simulate a failure after the durable claim. The original stays intact.
    }
    await #expect(throws: CutTransferError.self) { try await store.acquire(fresh, clipboardURLs: [source]) }
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func cutTokenDoesNotAuthorizeDifferentClipboardItems() async throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let a = fixture.root.appendingPathComponent("a"), b = fixture.root.appendingPathComponent("b")
    try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
    let store = CutTransferStore(supportDirectory: fixture.support)
    let token = try await store.create([a])
    await #expect(throws: CutTransferError.self) { try await store.acquire(token, clipboardURLs: [b]) }
}

@Test func twoRealProcessesConsumeCutRequestOnlyOnce() async throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let source = fixture.root.appendingPathComponent("source")
    let target = fixture.root.appendingPathComponent("target")
    try Data("original".utf8).write(to: source)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let token = try await CutTransferStore(supportDirectory: fixture.support).create([source])
    let request = fixture.root.appendingPathComponent("request.json")
    try JSONEncoder().encode(["token": token.uuidString, "source": source.path, "destination": target.path]).write(to: request)
    let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/StorageProbe")
    var children: [Process] = []
    defer { for child in children where child.isRunning { child.terminate() } }
    for index in 0..<2 {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["paste-cut", fixture.support.path, request.path, fixture.root.appendingPathComponent("report\(index).json").path]
        try process.run(); children.append(process)
    }
    for _ in 0..<200 {
        if children.allSatisfy({ !$0.isRunning }) { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(children.allSatisfy { !$0.isRunning && $0.terminationStatus == 0 })
    let reports = try (0..<2).map {
        try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: fixture.root.appendingPathComponent("report\($0).json")))
    }
    #expect(reports.reduce(0) { $0 + ($1["completed"] ?? 0) } == 1)
    #expect(reports.reduce(0) { $0 + ($1["failed"] ?? 0) } == 1)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try String(contentsOf: target.appendingPathComponent("source"), encoding: .utf8) == "original")
}

@Test func dropPlanningRejectsDescendantsAndDistinguishesCopyInSameFolder() async throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let folder = fixture.root.appendingPathComponent("folder")
    let child = folder.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let planner = FileDropPlanner()
    await #expect(throws: FileOperationError.self) { try await planner.plan([folder], to: child, requested: .copy) }
    await #expect(throws: FileOperationError.self) { try await planner.plan([folder], to: fixture.root, requested: .move) }
    #expect(try await planner.plan([folder], to: fixture.root, requested: .copy) == .copy)
}
