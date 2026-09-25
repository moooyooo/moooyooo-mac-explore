import CoreServices
import Foundation

private final class EventContext: @unchecked Sendable {
    let path: String
    let changed: @Sendable () -> Void
    init(path: String, changed: @escaping @Sendable () -> Void) { self.path = path; self.changed = changed }
}

private final class EventStream: @unchecked Sendable {
    private let stream: FSEventStreamRef

    init(url: URL, changed: @escaping @Sendable () -> Void) throws {
        let box = EventContext(path: url.path, changed: changed)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<EventContext>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in if let pointer { Unmanaged<EventContext>.fromOpaque(pointer).release() } },
            copyDescription: nil
        )
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        guard let stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<EventContext>.fromOpaque(info).takeUnretainedValue()
            let strings = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let rescan = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged |
                                kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
            for i in 0..<count {
                let path = String(cString: strings[i])
                if flags[i] & rescan != 0 || path == box.path || (path as NSString).deletingLastPathComponent == box.path {
                    box.changed(); break
                }
            }
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, UInt32(flags))
        else { throw CocoaError(.fileReadUnknown) }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            throw CocoaError(.fileReadNoPermission)
        }
        self.stream = stream
    }

    deinit { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
}

/// One native stream per canonical directory, shared by all panes in this process.
/// No timer scans. Bounded streams and newest-only buffers prevent event backlogs.
public actor DirectoryWatchCenter {
    public static let shared = DirectoryWatchCenter()
    private struct Entry {
        let stream: EventStream
        var listeners: [UUID: AsyncStream<Void>.Continuation]
    }
    private var entries: [URL: Entry] = [:]
    public init() {}

    public var watchedDirectoryCount: Int { entries.count }

    public func events(at input: URL) throws -> AsyncStream<Void> {
        let url = try StorageIO.canonicalURL(input)
        let id = UUID()
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        if entries[url] == nil {
            guard entries.count < 128 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EMFILE)) }
            let stream = try EventStream(url: url) { [weak self] in Task { await self?.emit(url) } }
            entries[url] = Entry(stream: stream, listeners: [:])
        }
        entries[url]?.listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.remove(id, at: url) } }
        return events
    }

    private func emit(_ url: URL) { entries[url]?.listeners.values.forEach { $0.yield(()) } }
    private func remove(_ id: UUID, at url: URL) {
        entries[url]?.listeners.removeValue(forKey: id)
        if entries[url]?.listeners.isEmpty == true { entries.removeValue(forKey: url) }
    }
}
