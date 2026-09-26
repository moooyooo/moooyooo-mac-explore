import Darwin
import Foundation
import Testing
@testable import ExplorerPlatform

private func setACL(_ text: String, on url: URL) throws {
    guard let acl = acl_from_text(text) else { throw posixError() }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard acl_set_file(url.path, ACL_TYPE_EXTENDED, acl) == 0 else { throw posixError() }
}

private let inheritedReadACL = "!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow,file_inherit,directory_inherit:read,readattr,readextattr,readsecurity\n"
private let explicitDenyACL = "!#acl 1\nuser:FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE:nobody:4294967294:deny:read\n"

@Test func projectReplacementPreservesAccessBeforeWritingAndOnCommit() throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let original = Data("original".utf8)
    try original.write(to: fixture.project)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.project.path)
    try setACL(explicitDenyACL, on: fixture.project)
    let access = try FileAccess.read(at: fixture.project)
    try setACL(inheritedReadACL, on: fixture.root)
    try StorageIO.atomicWrite(Data("saved".utf8), to: fixture.project, expected: original) { handle, data in
        #expect(try access.matches(FileAccess.read(from: handle.fileDescriptor)))
        try handle.write(contentsOf: data)
    }
    #expect(try access.matches(FileAccess.read(at: fixture.project)))
}

@Test func newProjectDoesNotInheritSharedReadPermissions() throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    try setACL(inheritedReadACL, on: fixture.root)
    try StorageIO.atomicWrite(Data("private".utf8), to: fixture.project, expected: nil) { handle, data in
        var info = stat()
        #expect(fstat(handle.fileDescriptor, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        if let acl = acl_get_fd(handle.fileDescriptor) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            #expect(acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1)
        } else { #expect(errno == ENOENT || errno == ENOATTR) }
        try handle.write(contentsOf: data)
    }
}

@Test func changingPermissionsDuringSavePreservesOriginal() throws {
    let fixture = try StorageFixture(); defer { fixture.cleanup() }
    let original = Data("original".utf8)
    try original.write(to: fixture.project)
    #expect(throws: StorageError.self) {
        try StorageIO.atomicWrite(Data("changed".utf8), to: fixture.project, expected: original) { handle, data in
            try handle.write(contentsOf: data)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.project.path)
        }
    }
    #expect(try Data(contentsOf: fixture.project) == original)
}
