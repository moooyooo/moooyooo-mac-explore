import Darwin
import Foundation
import Testing
@testable import ExplorerPlatform

private struct OperationFixture {
    let storage: StorageFixture
    let source: URL
    let destination: URL
    let trash: URL
    init() throws {
        storage = try StorageFixture()
        source = storage.root.appendingPathComponent("source")
        destination = storage.root.appendingPathComponent("destination")
        trash = storage.root.appendingPathComponent("test-trash")
        for directory in [source, destination, trash] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
    }
    var io: FileOperationIO {
        let trash = trash
        return FileOperationIO(trash: { url in
            let target = trash.appendingPathComponent(UUID().uuidString)
            try MutationPaths.renameExclusively(url, to: target)
            return target
        })
    }
    func file(_ name: String, _ content: String = "original") throws -> URL {
        let url = source.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }
    func service(_ io: FileOperationIO? = nil) -> FileOperations {
        FileOperations(supportDirectory: storage.support, io: io ?? self.io)
    }
}

@Test func createRenameAndUndoPreserveUnicodeNames() async throws {
    let f = try OperationFixture(); defer { f.storage.cleanup() }
    let service = f.service()
    let folder = try await service.createFolder(named: "資料 🗂", in: f.destination)
    #expect(await service.undoState.kind == .newFolder)
    let renamed = try await service.rename(folder, to: "変更 済み")
    let renamedUndo = await service.undoState
    #expect(renamedUndo.kind == .rename && renamedUndo.itemCount == 1)
    #expect(FileManager.default.fileExists(atPath: renamed.path))
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    _ = try await service.undo()
    #expect(FileManager.default.fileExists(atPath: folder.path))
    #expect(await service.undoState.kind == .newFolder)
    _ = try await service.undo()
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.trash.path).count == 1)
}

@Test func copyingFoldersPreservesLinksContentsAndPermissions() async throws {
    let f = try OperationFixture(); defer { f.storage.cleanup() }
    let folder = f.source.appendingPathComponent("資料")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let child = folder.appendingPathComponent("空 白 $name.txt")
    try Data("contents".utf8).write(to: child)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: child.path)
    let link = folder.appendingPathComponent("外部")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.destination)
    let result = try await f.service().transfer([folder], to: f.destination, kind: .copy, resolve: { _ in .cancel })
    #expect(result.completed == 1 && result.failed == 0)
    let copied = f.destination.appendingPathComponent("資料")
    #expect(try ItemSnapshot.capture(folder).contentDigest == ItemSnapshot.capture(copied).contentDigest)
    #expect(try ItemIdentity.read(copied.appendingPathComponent("外部")).kind == S_IFLNK)
    #expect(try FileAccess.read(at: child).matches(FileAccess.read(at: copied.appendingPathComponent(child.lastPathComponent))))
}

@Test func fileConflictsSupportSkipKeepBothAndReplacement() async throws {
    let f = try OperationFixture(); defer { f.storage.cleanup() }
    let source = try f.file("same.txt", "new")
    let target = f.destination.appendingPathComponent("same.txt")
    try Data("old".utf8).write(to: target)
    let service = f.service()
    let skipped = try await service.transfer([source], to: f.destination, kind: .copy, resolve: { _ in .skip })
    #expect(skipped.items.first?.status == .skipped)
    #expect(try String(contentsOf: target, encoding: .utf8) == "old")
    let both = try await service.transfer([source], to: f.destination, kind: .copy, resolve: { _ in .keepBoth })
    #expect(both.completed == 1 && both.items.first?.destination?.lastPathComponent != "same.txt")
    let replaced = try await service.transfer([source], to: f.destination, kind: .copy, resolve: { _ in .replace })
    #expect(replaced.completed == 1 && replaced.failed == 0)
    #expect(try String(contentsOf: target, encoding: .utf8) == "new")
    let old = try #require(FileManager.default.contentsOfDirectory(at: f.trash, includingPropertiesForKeys: nil).first)
    #expect(try String(contentsOf: old, encoding: .utf8) == "old")
    #expect(await service.canUndo == false)
    #expect(await service.undoState.blockReason == .replacement)
}

@Test func replacingFolderKeepsOldFolderWholeAndRetainsBackupIfTrashFails() async throws {
    let f = try OperationFixture(); defer { f.storage.cleanup() }
    let source = f.source.appendingPathComponent("folder"), target = f.destination.appendingPathComponent("folder")
    for url in [source, target] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
    try Data("new".utf8).write(to: source.appendingPathComponent("new"))
    try Data("old".utf8).write(to: target.appendingPathComponent("old"))
    var io = f.io
    io.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
    let service = f.service(io)
    let result = try await service.transfer([source], to: f.destination, kind: .copy, resolve: { _ in .replace })
    #expect(result.items.first?.status == .copyRetained)
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["new"])
    let retained = try await f.service().retainedOperations() // A fresh service reads the durable journal.
    #expect(retained.count == 1)
    let directory = try #require(retained.first?.retainedDirectory)
    #expect(try String(contentsOf: directory.appendingPathComponent("payload/old"), encoding: .utf8) == "old")
    #expect(try String(contentsOf: source.appendingPathComponent("new"), encoding: .utf8) == "new")
    #expect(await service.canUndo == false)
}

@Test func caseOnlyRenameAndUndoPreserveTheItem() async throws {
    let f = try OperationFixture(); defer { f.storage.cleanup() }
    let source = try f.file("Case.txt")
    let service = f.service()
    let renamed = try await service.rename(source, to: "case.txt")
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.source.path) == ["case.txt"])
    #expect(try String(contentsOf: renamed, encoding: .utf8) == "original")
    _ = try await service.undo()
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.source.path) == ["Case.txt"])
    #expect(try await service.retainedOperations().isEmpty)
}

@Test func crossVolumeCommitKeepsCopyWhenSourceCannotBeTrashed() async throws {
    let f = try OperationFixture(); defer { f.storage.cleanup() }
    let source = try f.file("item")
    var io = f.io
    io.forceCopyForMoves = true
    io.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
    let result = try await f.service(io).transfer([source], to: f.destination, kind: .move, resolve: { _ in .cancel })
    #expect(result.items.first?.status == .copyRetained)
    #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    #expect(try String(contentsOf: f.destination.appendingPathComponent("item"), encoding: .utf8) == "original")
}

@Test func completedMoveIsReportedWhenReceiptCannotBeSaved() async throws {
    let f = try OperationFixture(); defer { f.storage.cleanup() }
    let source = try f.file("item")
    let service = f.service()
    let result = try await service.transfer([source], to: f.destination, kind: .move, resolve: { _ in .cancel },
        afterMove: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    #expect(result.items.first?.status == .copyRetained)
    #expect(result.items.first?.destination?.lastPathComponent == "item")
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try String(contentsOf: f.destination.appendingPathComponent("item"), encoding: .utf8) == "original")
    #expect(await service.canUndo == false)
}

@Test func failedCopyNeverOverwritesDestinationOrRemovesSource() async throws {
    let f = try OperationFixture(); defer { f.storage.cleanup() }
    let source = try f.file("same.txt")
    let target = f.destination.appendingPathComponent("same.txt")
    try Data("existing".utf8).write(to: target)
    var io = f.io
    io.copyFile = { _, target in
        try Data("partial".utf8).write(to: target)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    }
    let result = try await f.service(io).transfer([source], to: f.destination, kind: .copy, resolve: { _ in .replace })
    #expect(result.failed == 1 && result.completed == 0)
    #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    #expect(try String(contentsOf: target, encoding: .utf8) == "existing")
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.destination.path) == ["same.txt"])
}

@Test func copyDetectsExternalSourceAndDestinationChanges() async throws {
    let f = try OperationFixture(); defer { f.storage.cleanup() }
    let source = try f.file("changing.txt")
    let target = f.destination.appendingPathComponent(source.lastPathComponent)
    var io = f.io
    io.copyFile = { input, output in
        try FileManager.default.copyItem(at: input, to: output)
        try Data("external change".utf8).write(to: input)
    }
    let changed = try await f.service(io).transfer([source], to: f.destination, kind: .copy, resolve: { _ in .cancel })
    #expect(changed.failed == 1 && !FileManager.default.fileExists(atPath: target.path))
    io = f.io
    io.beforePublish = { try Data("created by another app".utf8).write(to: target) }
    let appeared = try await f.service(io).transfer([source], to: f.destination, kind: .copy, resolve: { _ in .cancel })
    #expect(appeared.failed == 1)
    #expect(try String(contentsOf: target, encoding: .utf8) == "created by another app")
}

@Test func cancellingInsideFolderCopyRemovesOnlyItsIncompleteCopy() async throws {
    let f = try OperationFixture(); defer { f.storage.cleanup() }
    _ = try f.file("a"); _ = try f.file("b")
    var io = f.io
    io.copyFile = { source, destination in
        try FileManager.default.copyItem(at: source, to: destination)
        withUnsafeCurrentTask { $0?.cancel() }
    }
    let service = f.service(io)
    let task = Task { try await service.transfer([f.source], to: f.destination, kind: .copy, resolve: { _ in .cancel }) }
    let result = try await task.value
    #expect(result.cancelled && result.completed == 0 && result.unstarted == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.source.path).count == 2)
}

@Test func failedMoveRestoresSourceAndKeepsConcurrentReplacement() async throws {
    let f = try OperationFixture(); defer { f.storage.cleanup() }
    let source = try f.file("data")
    var io = f.io
    io.beforePublish = { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
    let restored = try await f.service(io).transfer([source], to: f.destination, kind: .move, resolve: { _ in .cancel })
    #expect(restored.failed == 1)
    #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    io.beforePublish = {
        try Data("concurrent replacement".utf8).write(to: source)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    }
    let retained = try await f.service(io).transfer([source], to: f.destination, kind: .move, resolve: { _ in .cancel })
    #expect(retained.failed == 1)
    #expect(try String(contentsOf: source, encoding: .utf8) == "concurrent replacement")
    let stage = try #require(FileManager.default.contentsOfDirectory(at: f.destination, includingPropertiesForKeys: nil).first)
    #expect(try String(contentsOf: stage.appendingPathComponent("payload"), encoding: .utf8) == "original")
}

@Test func undoStopsWhenCreatedFileChangedAndTrashFailureDoesNotDelete() async throws {
    let f = try OperationFixture(); defer { f.storage.cleanup() }
    let source = try f.file("item")
    let service = f.service()
    let result = try await service.transfer([source], to: f.destination, kind: .copy, resolve: { _ in .cancel })
    let copied = try #require(result.items.first?.destination)
    try Data("edited".utf8).write(to: copied)
    await #expect(throws: FileOperationError.self) { try await service.undo() }
    #expect(try String(contentsOf: copied, encoding: .utf8) == "edited")
    var io = f.io
    io.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
    let failed = try await f.service(io).trash([source])
    #expect(failed.failed == 1)
    #expect(try String(contentsOf: source, encoding: .utf8) == "original")
}

@Test func fileMutationLeaseIsSharedAcrossServiceInstances() async throws {
    let f = try OperationFixture(); defer { f.storage.cleanup() }
    let acquired = try AdvisoryLease.acquire(key: "file-operations", directory: f.storage.support.appendingPathComponent("Locks"))
    let lease = try #require(acquired)
    defer { withExtendedLifetime(lease) {} }
    await #expect(throws: FileOperationError.self) { try await f.service().createFolder(named: "blocked", in: f.destination) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).isEmpty)
}
