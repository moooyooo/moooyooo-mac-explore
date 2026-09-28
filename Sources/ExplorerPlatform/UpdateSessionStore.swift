import CryptoKit
import Darwin
import Foundation
import ExplorerCore

public enum UpdateSessionError: Error, LocalizedError {
    case otherInstance, installing, invalidBuild
    public var errorDescription: String? {
        switch self {
        case .otherInstance: L10n.text(.updateOtherInstance)
        case .installing: L10n.text(.updateInstalling)
        case .invalidBuild: L10n.text(.updateInvalidBuild)
        }
    }
}

/// The digest of the original bytes allows reattachment even when bookmark
/// resolution changes a folder's URL spelling in the in-memory document.
/// Externally edited or missing projects are recovered as unsaved copies instead.
public struct UpdateWorkspace: Codable, Sendable {
    public var workspace: RecoveryWorkspace
    public var savedDigest: String?
    public var isDirty: Bool
    public init(workspace: RecoveryWorkspace, savedDigest: String?, isDirty: Bool) {
        self.workspace = workspace; self.savedDigest = savedDigest; self.isDirty = isDirty
    }
    public func validate() throws {
        try workspace.validate()
        guard (workspace.sourceURL == nil) == (savedDigest == nil) else { throw StorageError.invalidFile }
        if let savedDigest {
            guard savedDigest.count == 64, savedDigest.allSatisfy(\.isHexDigit) else { throw StorageError.invalidFile }
        }
    }
}

public struct UpdateRestart: Codable, Sendable {
    public let schemaVersion: Int
    public let targetBuild: UInt64
    public let bootIdentifier: String
    public let workspaces: [UpdateWorkspace]
}

/// Shared live leases allow independent processes. A short admission lock serializes
/// registration and SH -> EX conversion, avoiding flock's non-atomic upgrade race.
/// The exclusive lease covers the entire update cycle, including installation on quit.
/// A durable marker spans the interval between parent exit and installer completion.
public actor UpdateSessionStore {
    private let directory: URL
    private let locks: URL
    private var liveLease: AdvisoryLease?
    private var restartClaim: AdvisoryLease?
    private var exclusive = false
    private var committed = false
    private var build: UInt64 = 0
    private var boot = ""
    private let testBootIdentifier: String?

    public init(bundleURL: URL, supportDirectory: URL? = nil, testBootIdentifier: String? = nil) {
        // Canonicalization is completed off the UI thread in register().
        directory = (supportDirectory ?? StorageIO.supportDirectory).appendingPathComponent("Updates")
        locks = directory
        self.bundleURL = bundleURL
        self.testBootIdentifier = testBootIdentifier
    }
    private let bundleURL: URL
    private var key = ""
    private var marker: URL { directory.appendingPathComponent(key + ".json") }

    public func register(build: String) async throws -> UpdateRestart? {
        guard liveLease == nil, let version = UInt64(build), version > 0 else { throw UpdateSessionError.invalidBuild }
        self.build = version
        boot = try testBootIdentifier ?? Self.bootIdentifier()
        let canonical = try StorageIO.key(for: StorageIO.canonicalURL(bundleURL))
        key = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let admission = try await admit()
        defer { admission.release() }
        let pending: UpdateRestart?
        if let data = try StorageIO.existingData(marker) {
            pending = try JSONDecoder().decode(UpdateRestart.self, from: data)
            guard let pending, pending.schemaVersion == 1, pending.targetBuild > 0,
                  pending.workspaces.count <= 32 else { throw StorageError.invalidFile }
            for workspace in pending.workspaces { try workspace.validate() }
            // Never let an old executable start while the installer is replacing it.
            // No time-based expiry: a slow installer must not defeat this barrier.
            // After a full OS reboot, no helper from the interrupted transaction
            // can remain alive. The old build may safely recover without replacing
            // anything. A wall-clock timeout cannot provide that guarantee.
            guard version >= pending.targetBuild || pending.bootIdentifier != boot
            else { throw UpdateSessionError.installing }
        } else { pending = nil }
        guard let lease = try AdvisoryLease.acquire(key: key + "-live", directory: locks, shared: true)
        else { throw UpdateSessionError.installing }
        liveLease = lease
        if pending != nil {
            restartClaim = try AdvisoryLease.acquire(key: key + "-restart", directory: locks)
            if restartClaim != nil { return pending }
        }
        return nil
    }

    public func beginUpdate(workspaces: [UpdateWorkspace] = []) async throws {
        let admission = try await admit()
        defer { admission.release() }
        guard liveLease != nil else { throw StorageError.closed }
        guard !exclusive else { return }
        guard restartClaim == nil, try StorageIO.existingData(marker) == nil else { throw UpdateSessionError.installing }
        liveLease?.release(); liveLease = nil
        if let lease = try AdvisoryLease.acquire(key: key + "-live", directory: locks) {
            liveLease = lease; exclusive = true
            do {
                // Sparkle can install on process death once its helper is prepared.
                // Protect even a hard crash during download, before normal quit.
                guard build < UInt64.max else { throw UpdateSessionError.invalidBuild }
                try writeRestart(target: build + 1, workspaces: workspaces)
                committed = false
            } catch {
                liveLease?.release()
                liveLease = try AdvisoryLease.acquire(key: key + "-live", directory: locks, shared: true)
                exclusive = false
                throw error
            }
        } else {
            liveLease = try AdvisoryLease.acquire(key: key + "-live", directory: locks, shared: true)
            guard liveLease != nil else { throw StorageError.locked }
            throw UpdateSessionError.otherInstance
        }
    }

    public func endUpdate() async throws {
        guard exclusive else { return }
        let admission = try await admit()
        defer { admission.release() }
        // A committed restart is only consumed by the installed build.
        guard !committed else { return }
        if try StorageIO.existingData(marker) != nil { try FileManager.default.removeItem(at: marker) }
        liveLease?.release()
        liveLease = try AdvisoryLease.acquire(key: key + "-live", directory: locks, shared: true)
        guard liveLease != nil else { throw StorageError.locked }
        exclusive = false
    }

    public func prepareRestart(targetBuild: String, workspaces: [UpdateWorkspace]) throws {
        guard exclusive else { throw StorageError.closed }
        guard let target = UInt64(targetBuild), target > build else { throw UpdateSessionError.invalidBuild }
        try writeRestart(target: target, workspaces: workspaces)
        committed = true
    }

    private func writeRestart(target: UInt64, workspaces: [UpdateWorkspace]) throws {
        guard workspaces.count <= 32 else { throw ProjectError.tooLarge }
        for workspace in workspaces { try workspace.validate() }
        let data = try JSONEncoder().encode(UpdateRestart(schemaVersion: 1, targetBuild: target,
                                                          bootIdentifier: boot, workspaces: workspaces))
        guard data.count <= ProjectDocument.maximumBytes else { throw ProjectError.tooLarge }
        try StorageIO.atomicWrite(data, to: marker, expected: StorageIO.existingData(marker))
    }

    /// Call only after the new process has durably recorded all restored workspaces.
    public func finishRestart() throws {
        guard restartClaim != nil else { return }
        try FileManager.default.removeItem(at: marker)
        restartClaim?.release(); restartClaim = nil
    }

    /// Process exit releases leases too. Explicit close is useful for isolated tests.
    public func close() {
        liveLease?.release(); liveLease = nil
        restartClaim?.release(); restartClaim = nil
        exclusive = false
        committed = false
    }

    private func admit() async throws -> AdvisoryLease {
        for _ in 0..<80 {
            if let lease = try AdvisoryLease.acquire(key: key + "-admission", directory: locks) { return lease }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw StorageError.locked
    }

    private static func bootIdentifier() throws -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1, size < 128 else { throw posixError() }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { throw posixError() }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
