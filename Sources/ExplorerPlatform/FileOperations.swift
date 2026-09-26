import Darwin
import Foundation
import ExplorerCore

public enum FileTransferKind: String, Sendable, Codable { case copy, move }
public enum FileConflictChoice: Sendable, Equatable { case replace, skip, keepBoth, cancel }
public struct FileConflict: Sendable {
    public let source: URL
    public let destination: URL
    public let destinationIsDirectory: Bool
}
public enum FileOperationPhase: Sendable { case preparing, copying, moving, trashing, undoing }
public struct FileOperationProgress: Sendable {
    public let current: URL
    public let completed: Int
    public let total: Int
    public let phase: FileOperationPhase
}
public enum FileItemStatus: Sendable, Equatable { case completed, skipped, failed, copyRetained }
public struct FileItemResult: Sendable {
    public let source: URL?
    public let destination: URL?
    public let status: FileItemStatus
    public let error: String?
}
public struct FileBatchResult: Sendable {
    public var items: [FileItemResult] = []
    public var cancelled = false
    public var unstarted = 0
    public var completed: Int { items.filter { $0.status == .completed }.count }
    public var failed: Int { items.filter { $0.status == .failed || $0.status == .copyRetained }.count }
}

struct FileOperationIO: Sendable {
    var forceCopyForMoves = false // Failure-injection seam for the cross-volume commit path.
    var copyFile: @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    var trash: @Sendable (URL) throws -> URL = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let resulting else { throw CocoaError(.fileWriteUnknown) }
        return resulting as URL
    }
    var beforePublish: @Sendable () throws -> Void = {}
}

/// One mutation batch per process and one lease across cooperating app processes.
/// This actor performs filesystem work away from AppKit's main actor.
public actor FileOperations {
    public typealias ConflictResolver = @Sendable (FileConflict) async -> FileConflictChoice
    public typealias ProgressHandler = @Sendable (FileOperationProgress) async -> Void
    private enum UndoAction: Sendable {
        case remove(URL, ItemSnapshot)
        case restore(URL, URL, ItemSnapshot)
        var current: URL { switch self { case .remove(let url, _), .restore(let url, _, _): url } }
        var expected: ItemSnapshot { switch self { case .remove(_, let value), .restore(_, _, let value): value } }
    }
    private struct UndoBatch: Sendable { var actions: [UndoAction]; let blocked: Bool }
    private struct TransferResult { let url: URL; let replaced: Bool; let warning: String? }
    private let support: URL
    private let io: FileOperationIO
    private var busy = false
    private var history: [UndoBatch] = []

    public init(supportDirectory: URL? = nil) {
        support = supportDirectory ?? StorageIO.supportDirectory
        io = FileOperationIO()
    }
    init(supportDirectory: URL, io: FileOperationIO) { support = supportDirectory; self.io = io }
    public var canUndo: Bool { !busy && history.last.map { !$0.blocked && !$0.actions.isEmpty } == true }

    public func retainedOperations() throws -> [FileOperationRecovery] {
        let lease = try lease(); defer { busy = false; withExtendedLifetime(lease) {} }
        return try MutationJournal.retained(in: support)
    }

    private func lease() throws -> AdvisoryLease {
        guard !busy, let lease = try AdvisoryLease.acquire(key: "file-operations", directory: support.appendingPathComponent("Locks")) else {
            throw FileOperationError.busy
        }
        busy = true
        return lease
    }
    private func remember(_ actions: [UndoAction], blocked: Bool = false) {
        guard !actions.isEmpty || blocked else { return }
        history.append(UndoBatch(actions: actions, blocked: blocked))
        if history.count > 20 { history.removeFirst() }
    }

    public func createFolder(named name: String, in input: URL) throws -> URL {
        let lease = try lease(); defer { busy = false; withExtendedLifetime(lease) {} }
        try MutationPaths.validateName(name)
        let parent = try MutationPaths.directory(input)
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        try Task.checkCancellation()
        // mkdir creates only the requested leaf and never replaces a pre-existing item.
        guard mkdir(destination.path, 0o755) == 0 else {
            if errno == EEXIST { throw FileOperationError.conflict }
            throw posixError()
        }
        remember([.remove(destination, try ItemSnapshot.capture(destination, cancellable: false))])
        return destination
    }

    public func rename(_ input: URL, to name: String) throws -> URL {
        let lease = try lease(); defer { busy = false; withExtendedLifetime(lease) {} }
        try MutationPaths.validateName(name)
        let source = try MutationPaths.item(input)
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        if source == destination { return source }
        let before = try ItemSnapshot.capture(source)
        if let target = try ItemIdentity.existing(destination),
           before.root.sameItem(as: target),
           try MutationPaths.isCaseOnlyRename(source, destination) {
            // Case-only rename on a case-insensitive volume; do not treat unrelated hard links as this case.
            guard Darwin.rename(source.path, destination.path) == 0 else { throw posixError() }
        } else { try MutationPaths.renameExclusively(source, to: destination) }
        remember([.restore(destination, source, try ItemSnapshot.capture(destination, cancellable: false))])
        return destination
    }

    public func transfer(_ inputs: [URL], to inputDirectory: URL, kind: FileTransferKind,
                         resolve: @escaping ConflictResolver, progress: @escaping ProgressHandler = { _ in },
                         beforeMove: (@Sendable (URL) async throws -> Void)? = nil,
                         afterMove: (@Sendable (URL, URL) async throws -> Void)? = nil) async throws -> FileBatchResult {
        let lease = try lease(); defer { busy = false; withExtendedLifetime(lease) {} }
        let directory = try MutationPaths.directory(inputDirectory)
        let sources = try normalizedSelection(inputs)
        var batch = FileBatchResult(), actions: [UndoAction] = []
        var blockUndo = false
        for (index, source) in sources.enumerated() {
            if Task.isCancelled { batch.cancelled = true; break }
            do {
                await progress(.init(current: source, completed: index, total: sources.count, phase: .preparing))
                var target = directory.appendingPathComponent(source.lastPathComponent)
                try MutationPaths.ensureOutside(source, destination: target)
                var previous = try ItemIdentity.existing(target).map { _ in try ItemSnapshot.capture(target) }
                if let existing = previous {
                    let choice = await resolve(.init(source: source, destination: target, destinationIsDirectory: existing.root.kind == S_IFDIR))
                    switch choice {
                    case .cancel: batch.cancelled = true
                    case .skip: batch.items.append(.init(source: source, destination: nil, status: .skipped, error: nil))
                    case .keepBoth:
                        target = try MutationPaths.unusedDestination(for: source, in: directory); previous = nil
                    case .replace:
                        if try ItemIdentity.read(source).sameItem(as: existing.root) { throw FileOperationError.conflict }
                    }
                    if batch.cancelled { break }
                    if choice == .skip { continue }
                }
                try Task.checkCancellation()
                if kind == .move { try await beforeMove?(source) }
                let result = try await transferOne(source, to: target, kind: kind, previous: previous) { current, phase in
                    await progress(.init(current: current, completed: index, total: sources.count, phase: phase))
                }
                var warning = result.warning
                if warning == nil {
                    do {
                        let snapshot = try ItemSnapshot.capture(result.url, cancellable: false)
                        actions.append(kind == .copy ? .remove(result.url, snapshot) : .restore(result.url, source, snapshot))
                        if kind == .move { try await afterMove?(source, result.url) }
                    } catch {
                        // The destination is already committed; never report that nothing happened.
                        warning = L10n.format(.fileCommittedWarning, result.url.path, error.localizedDescription)
                    }
                }
                blockUndo = blockUndo || result.replaced || warning != nil
                batch.items.append(.init(source: source, destination: result.url,
                                         status: warning == nil ? .completed : .copyRetained, error: warning))
            } catch is CancellationError { batch.cancelled = true; break }
            catch { batch.items.append(.init(source: source, destination: nil, status: .failed, error: error.localizedDescription)) }
        }
        batch.unstarted = sources.count - batch.items.count
        remember(actions, blocked: blockUndo)
        return batch
    }

    public func trash(_ inputs: [URL], progress: @escaping ProgressHandler = { _ in }) async throws -> FileBatchResult {
        let lease = try lease(); defer { busy = false; withExtendedLifetime(lease) {} }
        let sources = try normalizedSelection(inputs)
        var batch = FileBatchResult(), actions: [UndoAction] = []
        for (index, source) in sources.enumerated() {
            if Task.isCancelled { batch.cancelled = true; break }
            do {
                let before = try ItemSnapshot.capture(source)
                await progress(.init(current: source, completed: index, total: sources.count, phase: .trashing))
                try Task.checkCancellation()
                guard try ItemSnapshot.capture(source) == before else { throw FileOperationError.sourceChanged }
                let trashed = try io.trash(source)
                do {
                    actions.append(.restore(trashed, source, try await ItemSnapshot.captureAfterSystemMove(trashed)))
                    batch.items.append(.init(source: source, destination: trashed, status: .completed, error: nil))
                } catch {
                    batch.items.append(.init(source: source, destination: trashed, status: .copyRetained,
                                             error: L10n.format(.trashedWithoutUndo, trashed.path, error.localizedDescription)))
                }
            } catch is CancellationError { batch.cancelled = true; break }
            catch { batch.items.append(.init(source: source, destination: nil, status: .failed, error: error.localizedDescription)) }
        }
        batch.unstarted = sources.count - batch.items.count
        remember(actions, blocked: batch.items.contains { $0.status == .copyRetained })
        return batch
    }

    public func undo(progress: @escaping ProgressHandler = { _ in }) async throws -> FileBatchResult {
        let lease = try lease(); defer { busy = false; withExtendedLifetime(lease) {} }
        guard let batch = history.last, !batch.blocked, !batch.actions.isEmpty else { throw FileOperationError.noUndo }
        // Preflight the whole group before undoing anything.
        for action in batch.actions {
            guard try ItemSnapshot.capture(action.current).matchesForUndo(action.expected) else { throw FileOperationError.undoChanged }
            if case .restore(_, let original, _) = action,
               let target = try ItemIdentity.existing(original) {
                guard target.sameItem(as: action.expected.root),
                      try MutationPaths.isCaseOnlyRename(action.current, original) else { throw FileOperationError.undoChanged }
            }
        }
        var result = FileBatchResult()
        while let action = history.last?.actions.last {
            if Task.isCancelled { result.cancelled = true; break }
            await progress(.init(current: action.current, completed: result.items.count, total: batch.actions.count, phase: .undoing))
            guard try ItemSnapshot.capture(action.current).matchesForUndo(action.expected) else { throw FileOperationError.undoChanged }
            switch action {
            case .remove(let url, _):
                _ = try io.trash(url) // Undo never permanently deletes even an unchanged created item.
                result.items.append(.init(source: url, destination: nil, status: .completed, error: nil))
            case .restore(let current, let original, _):
                if let target = try ItemIdentity.existing(original) {
                    guard target.sameItem(as: action.expected.root),
                          try MutationPaths.isCaseOnlyRename(current, original) else { throw FileOperationError.undoChanged }
                    guard Darwin.rename(current.path, original.path) == 0 else { throw posixError() }
                } else {
                    let restored = try await transferOne(current, to: original, kind: .move, previous: nil) { _, _ in }
                    if let warning = restored.warning { throw NSError(domain: "MacExplore.FileOperations", code: 1, userInfo: [NSLocalizedDescriptionKey: warning]) }
                }
                result.items.append(.init(source: current, destination: original, status: .completed, error: nil))
            }
            history[history.count - 1].actions.removeLast()
        }
        result.unstarted = history.last?.actions.count ?? 0
        if history.last?.actions.isEmpty == true { history.removeLast() }
        return result
    }

    private func normalizedSelection(_ inputs: [URL]) throws -> [URL] {
        guard !inputs.isEmpty, inputs.count <= 10_000 else { throw FileOperationError.invalidLocation }
        let items = try Array(Set(inputs.map(MutationPaths.item))).sorted { $0.path < $1.path }
        // Selecting a folder and one of its descendants must not execute that descendant twice.
        var result: [URL] = []
        for item in items {
            if try result.contains(where: { try ItemIdentity.read($0).kind == S_IFDIR && item.path.hasPrefix($0.path + "/") }) { continue }
            result.append(item)
        }
        return result
    }

    private func copyTree(_ source: URL, to destination: URL,
                          progress: @Sendable (URL, FileOperationPhase) async -> Void) async throws {
        try Task.checkCancellation()
        let info = try ItemIdentity.read(source)
        if info.kind == S_IFDIR {
            guard mkdir(destination.path, 0o700) == 0 else { throw posixError() }
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try await copyTree(child, to: destination.appendingPathComponent(child.lastPathComponent), progress: progress)
            }
            guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) == 0 else { throw posixError() }
        } else if info.kind == S_IFREG || info.kind == S_IFLNK {
            await progress(source, .copying)
            try Task.checkCancellation()
            try io.copyFile(source, destination)
        } else { throw FileOperationError.unsupportedItem }
    }

    private func transferOne(_ source: URL, to destination: URL, kind: FileTransferKind,
                             previous: ItemSnapshot?, progress: @Sendable (URL, FileOperationPhase) async -> Void) async throws -> TransferResult {
        try MutationPaths.ensureOutside(source, destination: destination)
        let before = try ItemSnapshot.capture(source)
        let parent = try MutationPaths.directory(destination.deletingLastPathComponent())
        let sameVolume = try !io.forceCopyForMoves && before.root.device == ItemIdentity.read(parent).device
        let stage = try MutationStage(in: parent)
        let journal: MutationJournal
        do { journal = try MutationJournal(stage: stage, source: source, destination: destination, kind: kind, support: support) }
        catch { try? stage.discard(); throw error }
        defer { journal.finishIfEmpty() }
        var published = false
        do {
            if kind == .move && sameVolume {
                await progress(source, .moving)
                try Task.checkCancellation()
                guard try ItemSnapshot.capture(source) == before else { throw FileOperationError.sourceChanged }
                try MutationPaths.renameExclusively(source, to: stage.payload)
                stage.contents = .originalSource
            } else {
                try await copyTree(source, to: stage.payload, progress: progress)
                try Task.checkCancellation()
                guard try ItemSnapshot.capture(source) == before,
                      try ItemSnapshot.capture(stage.payload).contentDigest == before.contentDigest else { throw FileOperationError.sourceChanged }
            }
            try io.beforePublish()
            let warning = try publish(stage, to: destination, previous: previous)
            published = true
            if kind == .move && !sameVolume {
                do {
                    // Keep the verified copy if the source changed or cannot be moved to Trash.
                    guard try ItemSnapshot.capture(source, cancellable: false) == before else { throw FileOperationError.sourceChanged }
                    _ = try io.trash(source)
                } catch {
                    try? stage.discard()
                    return TransferResult(url: destination, replaced: previous != nil,
                                          warning: L10n.format(.moveCopyRetained, destination.path, error.localizedDescription))
                }
            }
            if warning == nil { try? stage.discard() }
            return TransferResult(url: destination, replaced: previous != nil, warning: warning)
        } catch {
            if stage.contents == .originalSource && !published {
                // Roll back only into an empty original path. Never overwrite a concurrent replacement.
                if (try? MutationPaths.renameExclusively(stage.payload, to: source)) != nil {
                    stage.contents = .disposable
                    try? stage.discard()
                }
                else {
                    throw NSError(domain: "MacExplore.FileOperations", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: L10n.format(.operationOriginalRetained, stage.payload.path, error.localizedDescription)])
                }
            } else if stage.contents == .replacedDestination {
                throw NSError(domain: "MacExplore.FileOperations", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: L10n.format(.operationOriginalRetained, stage.payload.path, error.localizedDescription)])
            } else if !published { try? stage.discard() }
            throw error
        }
    }

    private func publish(_ stage: MutationStage, to destination: URL, previous: ItemSnapshot?) throws -> String? {
        if let previous {
            guard try ItemSnapshot.capture(destination) == previous else { throw FileOperationError.destinationChanged }
            let replacement = try ItemSnapshot.capture(stage.payload)
            let stagedContents = stage.contents
            // Swap atomically so the replaced item remains available until it has been verified.
            guard renamex_np(stage.payload.path, destination.path, UInt32(RENAME_SWAP)) == 0 else { throw posixError() }
            stage.contents = .replacedDestination
            do {
                let displaced = try ItemSnapshot.capture(stage.payload, cancellable: false)
                guard displaced.root.sameItem(as: previous.root), displaced.contentDigest == previous.contentDigest else {
                    throw FileOperationError.destinationChanged
                }
            } catch {
                if (try? ItemIdentity.read(destination).sameItem(as: replacement.root)) == true,
                   renamex_np(stage.payload.path, destination.path, UInt32(RENAME_SWAP)) == 0 { stage.contents = stagedContents }
                throw error
            }
            do { _ = try io.trash(stage.payload); stage.contents = .disposable; return nil }
            catch { return L10n.format(.replacementBackupRetained, stage.payload.path, error.localizedDescription) }
        }
        try MutationPaths.renameExclusively(stage.payload, to: destination)
        stage.contents = .disposable
        return nil
    }
}
