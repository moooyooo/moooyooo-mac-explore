import Foundation

/// Drop validation may touch slow or disconnected volumes, so it runs off the UI thread.
public actor FileDropPlanner {
    public init() {}
    public func plan(_ inputs: [URL], to input: URL, requested: FileTransferKind?) throws -> FileTransferKind {
        guard !inputs.isEmpty, inputs.count <= 10_000 else { throw FileOperationError.invalidLocation }
        let destination = try MutationPaths.directory(input)
        let targetDevice = try ItemIdentity.read(destination).device
        guard FileManager.default.isWritableFile(atPath: destination.path) else { throw CocoaError(.fileWriteNoPermission) }
        let sources = try inputs.map(MutationPaths.item)
        var sameVolume = true
        for source in sources {
            try Task.checkCancellation()
            try MutationPaths.ensureOutside(source, destination: destination.appendingPathComponent(source.lastPathComponent))
            if try ItemIdentity.read(source).device != targetDevice { sameVolume = false }
        }
        let kind = requested ?? (sameVolume ? .move : .copy)
        if kind == .move, sources.contains(where: { $0.deletingLastPathComponent() == destination }) {
            throw FileOperationError.conflict
        }
        return kind
    }
}
