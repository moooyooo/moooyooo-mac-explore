import Darwin
import Foundation
import Security
import Testing
@testable import ExplorerPlatform

/// Requires a dedicated, small disk image mounted by scripts/test-volumes.sh.
/// No test accepts a general-purpose or user-supplied data volume.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MACEXPLORE_TEST_VOLUME"] != nil))
struct VolumeOperationTests {
    private func testVolume() throws -> (URL, UInt64) {
        let path = try #require(ProcessInfo.processInfo.environment["MACEXPLORE_TEST_VOLUME"])
        let url = try StorageIO.canonicalURL(URL(fileURLWithPath: path, isDirectory: true))
        guard url.path == "/private/tmp/MacExplore-Transfer-Test",
              try url.resourceValues(forKeys: [.volumeNameKey]).volumeName == "MacExplore-Transfer-Test" else {
            throw FileOperationError.invalidLocation
        }
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { throw posixError() }
        let size = UInt64(info.f_blocks) * UInt64(info.f_bsize)
        guard size >= 32 * 1_048_576, size <= 256 * 1_048_576 else { throw FileOperationError.invalidLocation }
        return (url, size)
    }

    @Test func realDifferentVolumesCopyMoveAndUndoPreserveFolderContents() async throws {
        let (volume, _) = try testVolume()
        let host = try StorageFixture(), external = try StorageFixture(base: volume)
        defer { host.cleanup(); external.cleanup() }
        let source = host.root.appendingPathComponent("資料 🗂")
        let nested = source.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("名前 with spaces.txt")
        try Data("cross-volume content".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "nested")
        let original = try ItemSnapshot.capture(source)
        #expect(try original.root.device != ItemIdentity.read(external.root).device)
        let hostTrash = host.root.appendingPathComponent("test-trash"), externalTrash = external.root.appendingPathComponent("test-trash")
        for url in [hostTrash, externalTrash] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        let externalDevice = try ItemIdentity.read(external.root).device
        let io = FileOperationIO(trash: { source in
            let root = try ItemIdentity.read(source).device == externalDevice ? externalTrash : hostTrash
            let target = root.appendingPathComponent(UUID().uuidString)
            try MutationPaths.renameExclusively(source, to: target)
            return target
        })
        let service = FileOperations(supportDirectory: host.support, io: io)
        let copied = try await service.transfer([source], to: external.root, kind: .copy, resolve: { _ in .cancel })
        #expect(copied.completed == 1 && copied.failed == 0)
        let destination = try #require(copied.items.first?.destination)
        #expect(try ItemSnapshot.capture(destination).contentDigest == original.contentDigest)
        #expect(try FileAccess.read(at: file).matches(FileAccess.read(at: destination.appendingPathComponent("nested/名前 with spaces.txt"))))
        _ = try await service.undo()
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let moved = try await service.transfer([source], to: external.root, kind: .move, resolve: { _ in .cancel })
        #expect(moved.completed == 1 && moved.failed == 0)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try ItemSnapshot.capture(destination).contentDigest == original.contentDigest)
        _ = try await service.undo()
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try ItemSnapshot.capture(source).contentDigest == original.contentDigest)
    }

    @Test func externalVolumeNativeTrashAndUndo() async throws {
        let (volume, _) = try testVolume()
        let fixture = try StorageFixture(base: volume)
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("MacExplore-test-" + UUID().uuidString)
        try Data("synthetic volume trash".utf8).write(to: source)
        let service = FileOperations(supportDirectory: fixture.support)
        let result = try await service.trash([source])
        #expect(result.completed == 1, "\(result.items.compactMap(\.error))")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        _ = try await service.undo()
        #expect(try String(contentsOf: source, encoding: .utf8) == "synthetic volume trash")
    }

    @Test func actualDiskFullPreservesSourceAndExistingDestination() async throws {
        let (volume, size) = try testVolume()
        let host = try StorageFixture(), external = try StorageFixture(base: volume)
        defer { host.cleanup(); external.cleanup() }
        let source = host.root.appendingPathComponent("large-copy.dat")
        let destination = external.root.appendingPathComponent(source.lastPathComponent)
        try Data("existing destination".utf8).write(to: destination)
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        var block = Data(count: 1_048_576)
        let status = block.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        #expect(status == errSecSuccess)
        // Real allocated bytes, larger than the entire disposable image.
        for _ in 0..<(size / 1_048_576 + 8) { try handle.write(contentsOf: block) }
        try handle.close()
        let before = try ItemSnapshot.capture(source)
        let result = try await FileOperations(supportDirectory: host.support).transfer([source], to: external.root, kind: .copy, resolve: { _ in .replace })
        #expect(result.failed == 1 && result.completed == 0)
        let failure = try #require(result.items.first)
        #expect((failure.errorDomain == NSCocoaErrorDomain && failure.errorCode == NSFileWriteOutOfSpaceError) ||
                (failure.errorDomain == NSPOSIXErrorDomain && failure.errorCode == Int(ENOSPC)),
                "\(failure.error ?? "missing error")")
        #expect(try ItemSnapshot.capture(source) == before)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "existing destination")
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.root.path) == [source.lastPathComponent])
    }
}
