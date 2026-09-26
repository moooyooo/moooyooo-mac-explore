import CryptoKit
import Darwin
import Foundation
import ExplorerCore

public enum FileOperationError: Error, LocalizedError, Sendable {
    case invalidName, invalidLocation, busy, conflict, sourceChanged, destinationChanged
    case insideSource, unsupportedItem, undoChanged, noUndo

    public var errorDescription: String? {
        switch self {
        case .invalidName: L10n.text(.invalidItemName)
        case .invalidLocation: L10n.text(.invalidOperationLocation)
        case .busy: L10n.text(.fileOperationBusy)
        case .conflict: L10n.text(.fileOperationConflict)
        case .sourceChanged: L10n.text(.fileOperationSourceChanged)
        case .destinationChanged: L10n.text(.fileOperationDestinationChanged)
        case .insideSource: L10n.text(.fileOperationInsideSource)
        case .unsupportedItem: L10n.text(.fileOperationUnsupported)
        case .undoChanged: L10n.text(.fileUndoChanged)
        case .noUndo: L10n.text(.fileUndoUnavailable)
        }
    }
}

struct ItemIdentity: Equatable, Sendable, Codable {
    let device: dev_t
    let inode: ino_t
    let kind: mode_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    let mode: mode_t
    let links: nlink_t
    let flags: UInt32
    let owner: uid_t
    let group: gid_t

    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; kind = info.st_mode & S_IFMT
        size = info.st_size; modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        mode = info.st_mode; links = info.st_nlink; flags = info.st_flags
        owner = info.st_uid; group = info.st_gid
    }

    static func read(_ url: URL) throws -> Self {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixError() }
        return Self(info)
    }

    static func existing(_ url: URL) throws -> Self? {
        do { return try read(url) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
    }

    func sameItem(as other: Self) -> Bool { device == other.device && inode == other.inode && kind == other.kind }

    var digestData: Data {
        Data("\(device):\(inode):\(kind):\(size):\(modifiedSeconds):\(modifiedNanos):\(changedSeconds):\(changedNanos):\(mode):\(links):\(flags):\(owner):\(group)".utf8)
    }

    var undoData: Data {
        // Our own rename/Trash changes ctime, and adding then undoing a child changes
        // directory mtime. Neither changes the contents that Undo must preserve.
        let time = kind == S_IFDIR ? "" : ":\(size):\(modifiedSeconds):\(modifiedNanos)"
        return Data("\(device):\(inode):\(kind):\(mode):\(links):\(flags):\(owner):\(group)\(time)".utf8)
    }
}

/// A streaming, recursive snapshot. Links are fingerprinted as links, never traversed.
/// Identity/ctime detect replacements; content digests also protect Undo on coarse timestamp volumes.
struct ItemSnapshot: Equatable, Sendable, Codable {
    let root: ItemIdentity
    let identityDigest: Data
    let contentDigest: Data
    let undoDigest: Data
    let count: Int

    func matchesForUndo(_ other: Self) -> Bool {
        count == other.count && undoDigest == other.undoDigest && contentDigest == other.contentDigest
    }

    static func captureAfterSystemMove(_ url: URL) async throws -> Self {
        // macOS may finish writing Trash metadata after trashItem returns.
        // Retry only unstable snapshots; permission/IO failures still propagate.
        for attempt in 0..<8 {
            do { return try capture(url, cancellable: false) }
            catch FileOperationError.sourceChanged {
                if attempt == 7 { throw FileOperationError.sourceChanged }
                // A completed filesystem mutation must finish its bookkeeping even
                // when the user cancels the remaining batch.
                await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
            }
        }
        throw FileOperationError.sourceChanged
    }

    static func capture(_ url: URL, cancellable: Bool = true) throws -> Self {
        let root = try ItemIdentity.read(url)
        var identities = SHA256(), contents = SHA256(), undo = SHA256()
        var count = 0
        func append(_ value: Data, to hash: inout SHA256) {
            var size = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &size) { hash.update(bufferPointer: $0) }
            hash.update(data: value)
        }
        func walk(_ item: URL, relative: String, depth: Int) throws {
            if cancellable { try Task.checkCancellation() }
            guard depth <= 512 else { throw FileOperationError.unsupportedItem }
            let before = try ItemIdentity.read(item)
            count += 1
            append(Data(relative.utf8), to: &identities)
            append(before.digestData, to: &identities)
            append(Data(relative.utf8), to: &undo)
            append(before.undoData, to: &undo)
            if before.kind != S_IFLNK { append(try FileAccess.read(at: item).fingerprint, to: &undo) }
            append(Data(relative.utf8), to: &contents)
            append(Data(String(before.kind).utf8), to: &contents)
            // Finder tags and resource forks are part of the file, too.
            for attribute in try extendedAttributes(item) { append(attribute, to: &contents) }
            switch before.kind {
            case S_IFDIR:
                let children = try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
                for child in children { try walk(child, relative: relative + "/" + child.lastPathComponent, depth: depth + 1) }
            case S_IFREG:
                let descriptor = Darwin.open(item.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard descriptor >= 0 else { throw posixError() }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var info = stat()
                guard fstat(descriptor, &info) == 0, ItemIdentity(info) == before else { throw FileOperationError.sourceChanged }
                var digest = SHA256()
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    if cancellable { try Task.checkCancellation() }
                    digest.update(data: chunk)
                }
                append(Data(digest.finalize()), to: &contents)
                guard fstat(descriptor, &info) == 0, ItemIdentity(info) == before else { throw FileOperationError.sourceChanged }
            case S_IFLNK:
                append(Data(try FileManager.default.destinationOfSymbolicLink(atPath: item.path).utf8), to: &contents)
            default: throw FileOperationError.unsupportedItem
            }
            guard try ItemIdentity.read(item) == before else { throw FileOperationError.sourceChanged }
        }
        try walk(url, relative: "", depth: 0)
        guard try ItemIdentity.read(url) == root else { throw FileOperationError.sourceChanged }
        return Self(root: root, identityDigest: Data(identities.finalize()), contentDigest: Data(contents.finalize()),
                    undoDigest: Data(undo.finalize()), count: count)
    }

    private static func extendedAttributes(_ url: URL) throws -> [Data] {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOTSUP { return [] }
            throw posixError()
        }
        guard size <= 1_048_576 else { throw FileOperationError.unsupportedItem }
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard listxattr(url.path, &buffer, size, XATTR_NOFOLLOW) == size else { throw FileOperationError.sourceChanged }
        let names = buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }.sorted()
        var result: [Data] = []
        for name in names {
            let length = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard length >= 0 else { throw posixError() }
            // Bound memory for malformed attributes; retain the original on refusal.
            guard length <= 64 * 1_048_576 else { throw FileOperationError.unsupportedItem }
            var data = Data(count: length)
            let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
            guard read == length else { throw FileOperationError.sourceChanged }
            result += [Data(name.utf8), Data(SHA256.hash(data: data))]
        }
        return result
    }
}

enum MutationPaths {
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= 255 else { throw FileOperationError.invalidName }
    }

    /// Resolve the parent but retain the final link itself for copy/move/trash operations.
    static func item(_ input: URL) throws -> URL {
        guard ProjectDocument.isLocalFileURL(input) else { throw FileOperationError.invalidLocation }
        let normalized = input.standardizedFileURL
        guard normalized.path != "/" else { throw FileOperationError.invalidLocation }
        let name = normalized.lastPathComponent
        try validateName(name)
        return try directory(normalized.deletingLastPathComponent()).appendingPathComponent(name)
    }

    static func directory(_ input: URL) throws -> URL {
        let url = try StorageIO.canonicalURL(input)
        guard try ItemIdentity.read(url).kind == S_IFDIR else { throw FileOperationError.invalidLocation }
        return url
    }

    static func ensureOutside(_ source: URL, destination: URL) throws {
        if try ItemIdentity.read(source).kind == S_IFDIR {
            let canonical = try directory(source)
            let parent = try directory(destination.deletingLastPathComponent())
            guard parent != canonical, !parent.path.hasPrefix(canonical.path + "/") else { throw FileOperationError.insideSource }
        }
    }

    static func renameExclusively(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw FileOperationError.conflict }
            throw posixError()
        }
    }

    static func isCaseOnlyRename(_ source: URL, _ destination: URL) throws -> Bool {
        guard source.deletingLastPathComponent() == destination.deletingLastPathComponent(),
              source.lastPathComponent.lowercased() == destination.lastPathComponent.lowercased() else { return false }
        return try source.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false
    }

    static func unusedDestination(for source: URL, in directory: URL) throws -> URL {
        let name = source.lastPathComponent
        let isDirectory = try ItemIdentity.read(source).kind == S_IFDIR
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let copied = L10n.format(.copiedItemName, stem)
        for index in 1...10_000 {
            let suffix = index == 1 ? "" : " (\(index))"
            let candidate = directory.appendingPathComponent(copied + suffix + (ext.isEmpty ? "" : "." + ext))
            if try ItemIdentity.existing(candidate) == nil { return candidate }
        }
        throw FileOperationError.conflict
    }
}

/// A private same-volume staging directory. An interrupted operation retains its staged
/// payload instead of exposing an incomplete destination or removing a user's original.
final class MutationStage {
    enum Contents { case disposable, originalSource, replacedDestination }
    let url: URL
    let payload: URL
    var contents = Contents.disposable
    private let identity: ItemIdentity

    init(in parent: URL) throws {
        url = parent.appendingPathComponent(".macexplore-operation-" + UUID().uuidString, isDirectory: true)
        payload = url.appendingPathComponent("payload")
        guard mkdir(url.path, 0o700) == 0 else { throw posixError() }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        try FileAccess.makePrivate(descriptor, directory: true)
        identity = try ItemIdentity.read(url)
    }

    /// Only call for a disposable copy or an empty stage; moved originals are explicitly retained.
    func discard() throws {
        guard contents == .disposable else { throw FileOperationError.destinationChanged }
        guard let current = try ItemIdentity.existing(url), identity.sameItem(as: current) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
