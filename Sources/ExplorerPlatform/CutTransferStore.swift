import Foundation
import ExplorerCore

public enum CutTransferError: Error, LocalizedError, Sendable {
    case unavailable, changed
    public var errorDescription: String? {
        switch self {
        case .unavailable: L10n.text(.cutRequestUnavailable)
        case .changed: L10n.text(.cutRequestChanged)
        }
    }
}

private struct CutRecord: Codable, Sendable {
    enum State: String, Codable { case ready, moving, completed }
    struct Item: Codable, Sendable { let url: URL; let snapshot: ItemSnapshot; var state: State }
    let id: UUID
    let created: Date
    var items: [Item]
}

/// The clipboard carries a random identifier, never instructions to mutate arbitrary paths.
/// A private, expiring record and a process-wide kernel lease establish ownership.
public actor CutTransferStore {
    private let support: URL
    public init(supportDirectory: URL? = nil) { support = supportDirectory ?? StorageIO.supportDirectory }

    public func create(_ inputs: [URL]) throws -> UUID {
        guard !inputs.isEmpty, inputs.count <= 10_000 else { throw FileOperationError.invalidLocation }
        let urls = try Array(Set(inputs.map(MutationPaths.item))).sorted { $0.path < $1.path }
        let record = CutRecord(id: UUID(), created: Date(), items: try urls.map {
            CutRecord.Item(url: $0, snapshot: try ItemSnapshot.capture($0), state: .ready)
        })
        let directory = support.appendingPathComponent("FileTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try StorageIO.atomicWrite(JSONEncoder().encode(record), to: directory.appendingPathComponent(record.id.uuidString + ".json"), expected: nil)
        return record.id
    }

    public func acquire(_ id: UUID, clipboardURLs inputs: [URL]) throws -> CutTransferClaim {
        guard let lease = try AdvisoryLease.acquire(key: "cut-" + id.uuidString, directory: support.appendingPathComponent("Locks")) else {
            throw FileOperationError.busy
        }
        let url = support.appendingPathComponent("FileTransfers").appendingPathComponent(id.uuidString + ".json")
        let data: Data
        let record: CutRecord
        do { data = try StorageIO.read(url); record = try JSONDecoder().decode(CutRecord.self, from: data) }
        catch { throw CutTransferError.unavailable }
        // Completed source paths can be absent, so normalize their parent without reading the item.
        let urls = try Set(inputs.map(MutationPaths.item))
        guard record.id == id, record.created.timeIntervalSinceNow > -86_400,
              record.created.timeIntervalSinceNow < 60, Set(record.items.map(\.url)) == urls,
              !record.items.contains(where: { $0.state == .moving }),
              record.items.contains(where: { $0.state == .ready }) else { throw CutTransferError.unavailable }
        return CutTransferClaim(record: record, url: url, baseline: data, lease: lease)
    }
}

public actor CutTransferClaim {
    public nonisolated let sources: [URL]
    private var record: CutRecord
    private let url: URL
    private var baseline: Data
    private let lease: AdvisoryLease

    fileprivate init(record: CutRecord, url: URL, baseline: Data, lease: AdvisoryLease) {
        self.record = record; self.url = url; self.baseline = baseline; self.lease = lease
        sources = record.items.filter { $0.state == .ready }.map(\.url)
    }

    public func beginMoving(_ source: URL) throws {
        guard let index = record.items.firstIndex(where: { $0.url == source }), record.items[index].state == .ready else {
            throw CutTransferError.unavailable
        }
        guard try ItemSnapshot.capture(source) == record.items[index].snapshot else { throw CutTransferError.changed }
        // Persist before mutation. If the process dies, another process must not retry this source.
        record.items[index].state = .moving
        try save()
    }

    public func finishMoving(_ source: URL, destination: URL) throws {
        guard let index = record.items.firstIndex(where: { $0.url == source }), record.items[index].state == .moving else {
            throw CutTransferError.unavailable
        }
        record.items[index].state = .completed
        // Selecting a folder plus a child consumes the child's request together with its parent.
        for child in record.items.indices where record.items[child].url.path.hasPrefix(source.path + "/") {
            record.items[child].state = .completed
        }
        try save()
    }

    private func save() throws {
        let data = try JSONEncoder().encode(record)
        try StorageIO.atomicWrite(data, to: url, expected: baseline)
        baseline = data
        withExtendedLifetime(lease) {}
    }
}
