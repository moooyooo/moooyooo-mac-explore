import Foundation
import ExplorerCore

public struct RecoveryPane: Codable, Equatable, Sendable {
    public var id: UUID
    public var state: BrowserSession
    public init(id: UUID, state: BrowserSession) { self.id = id; self.state = state }
}

public struct RecoveryWorkspace: Codable, Sendable {
    public var document: ProjectDocument
    public var sourceURL: URL?
    public var browserStates: [RecoveryPane]?
    public init(document: ProjectDocument, sourceURL: URL?, browserStates: [RecoveryPane]? = nil) {
        self.document = document; self.sourceURL = sourceURL; self.browserStates = browserStates
    }
    public func validate() throws {
        try document.validate()
        guard sourceURL.map(ProjectDocument.isLocalFileURL) ?? true else { throw StorageError.invalidFile }
        if let browserStates {
            let ids = browserStates.map(\.id), panes = Dictionary(uniqueKeysWithValues: document.panes.map { ($0.id, $0) })
            guard ids.count <= document.panes.count, Set(ids).count == ids.count else { throw StorageError.invalidFile }
            for browser in browserStates {
                guard let pane = panes[browser.id] else { throw StorageError.invalidFile }
                try browser.state.validate()
                if let current = browser.state.history.current {
                    guard current.standardizedFileURL == pane.folder.url.standardizedFileURL else { throw StorageError.invalidFile }
                }
            }
        }
    }
}

public struct RecoverySession: Codable, Sendable, Identifiable {
    public var id: UUID
    public var updated: Date
    public var workspaces: [RecoveryWorkspace]
}

/// An instance lock, rather than a PID, identifies a live owner. A crashed session is
/// claimed under that same lock before recovery, so two processes cannot consume it.
public actor SessionStore {
    private let directory: URL
    private let instanceID: UUID
    private var lease: AdvisoryLease?
    private var claimed: [UUID: AdvisoryLease] = [:]

    public init(instanceID: UUID, supportDirectory: URL? = nil) {
        self.instanceID = instanceID
        directory = (supportDirectory ?? StorageIO.supportDirectory).appendingPathComponent("Sessions", isDirectory: true)
    }

    public func start() throws {
        guard lease == nil else { return }
        lease = try AdvisoryLease.acquire(key: instanceID.uuidString, directory: directory.appendingPathComponent("Locks"))
        guard lease != nil else { throw StorageError.locked }
    }

    public func update(_ workspaces: [RecoveryWorkspace]) throws {
        guard lease != nil else { throw StorageError.closed }
        guard workspaces.count <= 32 else { throw ProjectError.tooLarge }
        for workspace in workspaces { try workspace.validate() }
        let session = RecoverySession(id: instanceID, updated: Date(), workspaces: workspaces)
        let data = try JSONEncoder().encode(session)
        guard data.count <= ProjectDocument.maximumBytes else { throw ProjectError.tooLarge }
        let url = sessionURL(instanceID)
        try StorageIO.atomicWrite(data, to: url, expected: StorageIO.existingData(url))
    }

    public func available() throws -> [RecoverySession] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var sessions: [RecoverySession] = []
        for url in urls where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), id != instanceID,
                  let candidate = try AdvisoryLease.acquire(key: id.uuidString, directory: directory.appendingPathComponent("Locks")) else { continue }
            defer { candidate.release() }
            try? withExtendedLifetime(candidate) {
                let session = try JSONDecoder().decode(RecoverySession.self, from: StorageIO.read(url))
                guard session.id == id, session.workspaces.count <= 32 else { return }
                for workspace in session.workspaces { try workspace.validate() }
                if !session.workspaces.isEmpty { sessions.append(session) }
            }
        }
        return sessions.sorted { $0.updated > $1.updated }
    }

    public func claim(_ id: UUID) throws -> RecoverySession {
        guard id != instanceID, claimed[id] == nil,
              let candidate = try AdvisoryLease.acquire(key: id.uuidString, directory: directory.appendingPathComponent("Locks")) else { throw StorageError.locked }
        var handedOff = false
        defer { if !handedOff { candidate.release() } }
        return try withExtendedLifetime(candidate) {
            let session = try JSONDecoder().decode(RecoverySession.self, from: StorageIO.read(sessionURL(id)))
            guard session.id == id, session.workspaces.count <= 32 else { throw StorageError.invalidFile }
            for workspace in session.workspaces { try workspace.validate() }
            claimed[id] = candidate
            handedOff = true
            return session
        }
    }

    public func finishClaim(_ id: UUID, consumed: Bool) throws {
        guard claimed[id] != nil else { throw StorageError.closed }
        if consumed { try FileManager.default.removeItem(at: sessionURL(id)) }
        claimed.removeValue(forKey: id)?.release()
    }

    public func finish() throws {
        guard lease != nil else { return }
        let url = sessionURL(instanceID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        lease?.release(); lease = nil
    }

    private func sessionURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}

public actor RecentProjectStore {
    private let directory: URL
    public init(supportDirectory: URL? = nil) { directory = supportDirectory ?? StorageIO.supportDirectory }

    public func list() throws -> [URL] {
        let url = directory.appendingPathComponent("RecentProjects.json")
        guard let data = try StorageIO.existingData(url) else { return [] }
        return try JSONDecoder().decode([URL].self, from: data).filter(ProjectDocument.isLocalFileURL).prefix(20).map { $0 }
    }

    public func record(_ url: URL) async throws {
        // Short, cancellable contention retries; always reread while holding the lock.
        for _ in 0..<40 {
            if let lease = try AdvisoryLease.acquire(key: "recent-projects", directory: directory.appendingPathComponent("Locks")) {
                defer { lease.release() }
                try withExtendedLifetime(lease) {
                    let file = directory.appendingPathComponent("RecentProjects.json")
                    let previous = try StorageIO.existingData(file)
                    var urls = previous.flatMap { try? JSONDecoder().decode([URL].self, from: $0) } ?? []
                    urls.removeAll { $0 == url || !ProjectDocument.isLocalFileURL($0) }; urls.insert(url, at: 0)
                    try StorageIO.atomicWrite(JSONEncoder().encode(Array(urls.prefix(20))), to: file, expected: previous)
                }
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw StorageError.locked
    }
}
