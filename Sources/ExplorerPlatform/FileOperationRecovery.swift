import Foundation

public struct FileOperationRecovery: Codable, Sendable {
    public let source: URL
    public let destination: URL
    public let retainedDirectory: URL
    public let created: Date
    public let kind: FileTransferKind
}

/// Written and flushed before a source can leave its original path. Recovery is
/// intentionally non-destructive: retained originals and backups are shown to the user.
final class MutationJournal {
    private let url: URL
    private let record: FileOperationRecovery
    init(stage: MutationStage, source: URL, destination: URL, kind: FileTransferKind, support: URL) throws {
        let directory = support.appendingPathComponent("FileOperations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent(UUID().uuidString + ".json")
        record = FileOperationRecovery(source: source, destination: destination, retainedDirectory: stage.url, created: Date(), kind: kind)
        try StorageIO.atomicWrite(JSONEncoder().encode(record), to: url, expected: nil)
    }
    func finishIfEmpty() {
        // Keep the journal whenever any payload remains, including failed rollback.
        do {
            guard try ItemIdentity.existing(record.retainedDirectory.deletingLastPathComponent()) != nil,
                  try ItemIdentity.existing(record.retainedDirectory) == nil else { return }
            try? FileManager.default.removeItem(at: url)
        } catch { /* Unreadable and offline stages must retain their recovery record. */ }
    }

    static func retained(in support: URL) throws -> [FileOperationRecovery] {
        let directory = support.appendingPathComponent("FileOperations")
        guard try ItemIdentity.existing(directory) != nil else { return [] }
        var result: [FileOperationRecovery] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            guard let data = try? StorageIO.read(url), let record = try? JSONDecoder().decode(FileOperationRecovery.self, from: data),
                  record.source.isFileURL, record.destination.isFileURL, record.retainedDirectory.isFileURL,
                  record.retainedDirectory.lastPathComponent.hasPrefix(".macexplore-operation-") else { continue }
            // Only missing stages are cleaned. Offline/unreadable locations retain their records.
            do {
                if try ItemIdentity.existing(record.retainedDirectory.deletingLastPathComponent()) != nil,
                   try ItemIdentity.existing(record.retainedDirectory) == nil { try? FileManager.default.removeItem(at: url) }
                else { result.append(record) }
            } catch { result.append(record) }
        }
        return result.sorted { $0.created < $1.created }
    }
}
