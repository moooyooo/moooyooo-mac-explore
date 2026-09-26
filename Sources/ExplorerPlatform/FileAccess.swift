import Darwin
import Foundation

/// Access policy is applied to an empty staging file before any private data is written.
/// POSIX mode bits alone do not override inherited macOS ACL entries.
final class FileAccess {
    let owner: uid_t
    let group: gid_t
    let mode: mode_t
    private let acl: acl_t
    private let aclText: String

    private init(owner: uid_t, group: gid_t, mode: mode_t, acl: acl_t) throws {
        self.owner = owner; self.group = group; self.mode = mode; self.acl = acl
        guard let text = acl_to_text(acl, nil) else { acl_free(UnsafeMutableRawPointer(acl)); throw posixError() }
        aclText = String(cString: text)
        acl_free(text)
    }

    deinit { acl_free(UnsafeMutableRawPointer(acl)) }

    static func read(from descriptor: Int32) throws -> FileAccess {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        var value = acl_get_fd(descriptor)
        if value == nil, errno == ENOENT || errno == ENOATTR { value = acl_init(0) }
        guard let acl = value else { throw posixError() }
        return try FileAccess(owner: info.st_uid, group: info.st_gid, mode: info.st_mode & 0o7777, acl: acl)
    }

    static func read(at url: URL) throws -> FileAccess {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        return try read(from: descriptor)
    }

    static func makePrivate(_ descriptor: Int32, directory: Bool = false) throws {
        guard let empty = acl_init(0) else { throw posixError() }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        guard acl_set_fd(descriptor, empty) == 0, fchmod(descriptor, directory ? 0o700 : 0o600) == 0 else { throw posixError() }
    }

    func apply(to descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        if info.st_uid != owner || info.st_gid != group {
            guard fchown(descriptor, owner, group) == 0 else { throw posixError() }
        }
        guard fchmod(descriptor, mode) == 0, acl_set_fd(descriptor, acl) == 0 else { throw posixError() }
    }

    func matches(_ other: FileAccess) -> Bool {
        owner == other.owner && group == other.group && mode == other.mode && aclText == other.aclText
    }

    var fingerprint: Data { Data("\(owner):\(group):\(mode):\(aclText)".utf8) }
}
