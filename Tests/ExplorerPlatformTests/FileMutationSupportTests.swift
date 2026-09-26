import Darwin
import Foundation
import Testing
@testable import ExplorerPlatform

@Test func mutationSnapshotsDetectContentChangesWithRestoredModificationTime() throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let file = fixture.root.appendingPathComponent("data.txt")
    try Data("old".utf8).write(to: file)
    let previous = try ItemSnapshot.capture(fixture.root)
    let date = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
    try Data("new".utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    let next = try ItemSnapshot.capture(fixture.root)
    #expect(next != previous)
    #expect(next.contentDigest != previous.contentDigest)
}

@Test func mutationSnapshotsDoNotFollowSymbolicLinksOrOpenPipes() throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let link = fixture.root.appendingPathComponent("loop")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
    #expect(try ItemSnapshot.capture(fixture.root).count == 2)
    let normalized = try MutationPaths.item(link)
    #expect(normalized.lastPathComponent == "loop")
    #expect(try ItemIdentity.read(normalized).sameItem(as: ItemIdentity.read(link)))
    #expect(try ItemIdentity.read(normalized).kind == S_IFLNK)
    let pipe = fixture.root.appendingPathComponent("pipe")
    #expect(mkfifo(pipe.path, 0o600) == 0)
    #expect(throws: FileOperationError.self) { try ItemSnapshot.capture(fixture.root) }
}

@Test func mutationsRejectTraversalAndDestinationInsideSourceIncludingAliases() throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    for name in ["", ".", "..", "a/b", "a\0b"] {
        #expect(throws: FileOperationError.self) { try MutationPaths.validateName(name) }
    }
    let folder = fixture.root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let alias = fixture.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
    #expect(throws: FileOperationError.self) {
        try MutationPaths.ensureOutside(folder, destination: alias.appendingPathComponent("copy"))
    }
}

@Test func exclusivePublicationKeepsExistingDestination() throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let source = fixture.root.appendingPathComponent("source")
    let target = fixture.root.appendingPathComponent("target")
    try Data("original".utf8).write(to: target)
    try Data("new".utf8).write(to: source)
    #expect(throws: FileOperationError.self) { try MutationPaths.renameExclusively(source, to: target) }
    #expect(try Data(contentsOf: target) == Data("original".utf8))
    #expect(try Data(contentsOf: source) == Data("new".utf8))
}
