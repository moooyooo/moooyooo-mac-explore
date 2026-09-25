import CryptoKit
import Darwin
import Foundation
import ExplorerCore

public enum StorageError: Error, LocalizedError {
    case locked, externalChange, hardLink, notLocal, invalidFile, closed
    public var errorDescription: String? {
        switch self {
        case .locked: "別のウィンドウまたはプロセスが編集中です。別名保存するか、編集権を再取得してください。"
        case .externalChange: "保存先が外部で変更されました。上書きを停止しました。別名保存するか、最新の内容を開き直してください。"
        case .hardLink: "ハードリンクされたプロジェクトには保存できません。別名保存してください。"
        case .notLocal: "プロジェクトはローカルディスクに保存してください。"
        case .invalidFile: "通常のローカルファイルを指定してください。"
        case .closed: "プロジェクトは閉じられています。"
        }
    }
}

/// A stable sidecar inode is never unlinked. Closing the descriptor, including on crash,
/// releases the kernel lock. O_CLOEXEC prevents ownership leaking into launched processes.
final class AdvisoryLease: @unchecked Sendable {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }

    static func acquire(key: String, directory: URL) throws -> AdvisoryLease? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = directory.appendingPathComponent(digest + ".lock").path
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            Darwin.close(descriptor); throw StorageError.invalidFile
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; Darwin.close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return AdvisoryLease(descriptor)
    }
}

func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

enum StorageIO {
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.moooyooo.MacExplore", isDirectory: true)
    }

    static func canonicalURL(_ url: URL) throws -> URL {
        guard ProjectDocument.isLocalFileURL(url) else { throw StorageError.invalidFile }
        // Foundation may abbreviate /private/var back to /var after resolving it.
        // POSIX realpath preserves the spelling reported by FSEvents and the kernel.
        if let path = realpath(url.path, nil) {
            defer { free(path) }
            return URL(fileURLWithPath: String(cString: path))
        }
        guard errno == ENOENT else { throw posixError() }
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { throw posixError() }
        defer { free(parent) }
        return URL(fileURLWithPath: String(cString: parent), isDirectory: true).appendingPathComponent(url.lastPathComponent)
    }

    static func key(for url: URL) throws -> String {
        let parent = url.deletingLastPathComponent()
        let values = try parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let path = url.path.precomposedStringWithCanonicalMapping
        return values.volumeSupportsCaseSensitiveNames == false ? path.lowercased() : path
    }

    static func checkWritableFile(_ url: URL) throws {
        let values = try url.deletingLastPathComponent().resourceValues(forKeys: [.volumeIsLocalKey])
        if values.volumeIsLocal == false { throw StorageError.notLocal }
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw StorageError.invalidFile }
            guard info.st_nlink == 1 else { throw StorageError.hardLink }
            guard FileManager.default.isWritableFile(atPath: url.path) else { throw CocoaError(.fileWriteNoPermission) }
        } else if errno != ENOENT { throw posixError() }
    }

    static func read(_ url: URL, limit: Int = ProjectDocument.maximumBytes) throws -> Data {
        // Bound the read itself; a metadata size check alone races a growing file.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw StorageError.invalidFile }
        guard info.st_size <= limit else { throw ProjectError.tooLarge }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ProjectError.tooLarge }
        return data
    }

    static func existingData(_ url: URL) throws -> Data? {
        do { return try read(url) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
    }

    /// Stage in the destination directory, flush, then rename. A failed staging write
    /// leaves the original untouched. The check immediately before rename narrows the
    /// unavoidable race with applications which ignore our advisory lock.
    static func atomicWrite(_ data: Data, to url: URL, expected: Data?,
                            stage: ((FileHandle, Data) throws -> Void)? = nil) throws {
        try checkWritableFile(url)
        guard try existingData(url) == expected else { throw StorageError.externalChange }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".macexplore-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        if let stage { try stage(handle, data) } else { try handle.write(contentsOf: data) }
        try handle.synchronize()
        try handle.close()
        try checkWritableFile(url)
        guard try existingData(url) == expected else { throw StorageError.externalChange }
        if expected == nil {
            // RENAME_EXCL also closes the race where another app creates the new target.
            guard renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw StorageError.externalChange }
                throw posixError()
            }
        } else {
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw posixError() }
        }
        // Best effort directory flush; rename has committed, so an unsupported flush
        // must not be reported as a failed save of the already committed revision.
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        if parent >= 0 { _ = fsync(parent); Darwin.close(parent) }
    }
}

public struct OpenProject: Sendable {
    public let handleID: UUID
    public let url: URL
    public let document: ProjectDocument
    public let isWritable: Bool
    public let readOnlyReason: String?
}

public actor ProjectStore {
    private struct HeldProject {
        var url: URL
        var baseline: Data
        var lease: AdvisoryLease?
    }
    private var projects: [UUID: HeldProject] = [:]
    private let lockDirectory: URL

    public init(supportDirectory: URL? = nil) {
        lockDirectory = (supportDirectory ?? StorageIO.supportDirectory).appendingPathComponent("Locks", isDirectory: true)
    }

    public func identity(of url: URL) throws -> String { try StorageIO.key(for: StorageIO.canonicalURL(url)) }

    public func open(_ input: URL) throws -> OpenProject {
        let url = try StorageIO.canonicalURL(input)
        var lease: AdvisoryLease?
        var reason: String?
        do {
            try StorageIO.checkWritableFile(url)
            lease = try AdvisoryLease.acquire(key: StorageIO.key(for: url), directory: lockDirectory)
            if lease == nil { reason = StorageError.locked.localizedDescription }
        } catch { reason = error.localizedDescription }
        let data = try StorageIO.read(url)
        let document = try Self.resolveFolders(in: ProjectDocument.decode(data))
        let id = UUID()
        projects[id] = HeldProject(url: url, baseline: data, lease: lease)
        return OpenProject(handleID: id, url: url, document: document, isWritable: lease != nil, readOnlyReason: reason)
    }

    public func close(_ id: UUID) { projects.removeValue(forKey: id) }

    public func save(_ document: ProjectDocument, handleID: UUID) throws -> OpenProject {
        guard var held = projects[handleID] else { throw StorageError.closed }
        guard held.lease != nil else { throw StorageError.locked }
        var next = try Self.bookmarkFolders(in: document)
        next.revision = UUID()
        let data = try next.encoded()
        try StorageIO.atomicWrite(data, to: held.url, expected: held.baseline)
        held.baseline = data
        projects[handleID] = held
        return OpenProject(handleID: handleID, url: held.url, document: next, isWritable: true, readOnlyReason: nil)
    }

    public func saveAs(_ document: ProjectDocument, to input: URL, replacing: Bool = false) throws -> OpenProject {
        let url = try StorageIO.canonicalURL(input)
        try StorageIO.checkWritableFile(url)
        guard let lease = try AdvisoryLease.acquire(key: StorageIO.key(for: url), directory: lockDirectory) else { throw StorageError.locked }
        return try withExtendedLifetime(lease) {
            let previous = try StorageIO.existingData(url)
            guard replacing || previous == nil else { throw StorageError.externalChange }
            var next = try Self.bookmarkFolders(in: document)
            next.projectID = UUID(); next.revision = UUID()
            next.name = String(url.deletingPathExtension().lastPathComponent.prefix(255))
            let data = try next.encoded()
            try StorageIO.atomicWrite(data, to: url, expected: previous)
            let id = UUID()
            projects[id] = HeldProject(url: url, baseline: data, lease: lease)
            return OpenProject(handleID: id, url: url, document: next, isWritable: true, readOnlyReason: nil)
        }
    }

    /// Caller confirms discarding/saving local changes before this reload.
    /// Failure preserves the existing handle and its original baseline.
    public func reacquire(_ id: UUID) throws -> OpenProject {
        guard var held = projects[id] else { throw StorageError.closed }
        let lease: AdvisoryLease
        if let existing = held.lease { lease = existing }
        else {
            try StorageIO.checkWritableFile(held.url)
            guard let acquired = try AdvisoryLease.acquire(key: StorageIO.key(for: held.url), directory: lockDirectory) else { throw StorageError.locked }
            lease = acquired
        }
        return try withExtendedLifetime(lease) {
            let data = try StorageIO.read(held.url)
            let document = try Self.resolveFolders(in: ProjectDocument.decode(data))
            held.baseline = data; held.lease = lease
            projects[id] = held
            return OpenProject(handleID: id, url: held.url, document: document, isWritable: true, readOnlyReason: nil)
        }
    }

    static func bookmarkFolders(in input: ProjectDocument) throws -> ProjectDocument {
        try input.validate()
        var document = input
        for i in document.panes.indices {
            let url = document.panes[i].folder.url
            if let bookmark = try? url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil) {
                document.panes[i].folder.bookmark = bookmark
            }
        }
        return document
    }

    static func resolveFolders(in input: ProjectDocument) throws -> ProjectDocument {
        var document = input
        for i in document.panes.indices {
            guard let data = document.panes[i].folder.bookmark else { continue }
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
               ProjectDocument.isLocalFileURL(url) {
                document.panes[i].folder.url = url
                if stale { document.panes[i].folder.bookmark = nil }
            }
        }
        try document.validate()
        return document
    }
}
