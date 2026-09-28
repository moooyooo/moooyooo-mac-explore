import Foundation
import Testing
@testable import ExplorerPlatform

@Test func listsUnicodeNamesHiddenFilesAndNaturalOrdering() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("資料 📁"), withIntermediateDirectories: false)
    for name in ["file10.txt", "file2.txt", ".hidden", "空白 あり.txt"] {
        try Data("example".utf8).write(to: root.appendingPathComponent(name))
    }
    let entries = try await DirectoryReader.read(root)
    #expect(entries.first?.name == "資料 📁")
    #expect(entries.count == 4)
    let names = entries.map(\.name)
    #expect(try #require(names.firstIndex(of: "file2.txt")) < #require(names.firstIndex(of: "file10.txt")))
    #expect(try await DirectoryReader.read(root, showHidden: true).count == 5)
}

@Test func missingDirectoryReportsFailure() async {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
        _ = try await DirectoryReader.read(missing)
        Issue.record("Missing directory unexpectedly loaded")
    } catch { }
}

@Test func cancellationDoesNotReturnACompletedListing() async throws {
    let task = Task { try await DirectoryReader.read(FileManager.default.temporaryDirectory) }
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Cancelled read returned data")
    } catch is CancellationError { }
    catch { Issue.record("Unexpected cancellation error: \(error)") }
}

@Test(arguments: ["absolute", "relative", "chained"])
func browsesLinkedDirectoriesAndPreservesAliasURLs(linkKind: String) async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let disk = root.appendingPathComponent("Disk")
    let volumes = root.appendingPathComponent("Volumes")
    let link = volumes.appendingPathComponent("Macintosh HD")
    try manager.createDirectory(at: disk.appendingPathComponent("資料 📁"), withIntermediateDirectories: true)
    try manager.createDirectory(at: volumes, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    try Data("report".utf8).write(to: disk.appendingPathComponent("report.txt"))
    try Data("hidden".utf8).write(to: disk.appendingPathComponent(".hidden"))
    try Data("notes".utf8).write(to: disk.appendingPathComponent("資料 📁/notes.txt"))
    try manager.createSymbolicLink(atPath: disk.appendingPathComponent("Folder shortcut").path, withDestinationPath: "資料 📁")
    switch linkKind {
    case "relative": try manager.createSymbolicLink(atPath: link.path, withDestinationPath: "../Disk")
    case "chained":
        try manager.createSymbolicLink(at: root.appendingPathComponent("First link"), withDestinationURL: disk)
        try manager.createSymbolicLink(atPath: link.path, withDestinationPath: "../First link")
    default: try manager.createSymbolicLink(at: link, withDestinationURL: disk)
    }
    let volume = try #require(try await DirectoryReader.read(volumes).first)
    #expect(volume.isSymbolicLink && volume.isBrowsable)
    let entries = try await DirectoryReader.read(link)
    #expect(Set(entries.map(\.name)) == ["資料 📁", "Folder shortcut", "report.txt"])
    #expect(entries.allSatisfy { $0.url.deletingLastPathComponent().path == link.path })
    #expect(try await DirectoryReader.read(link, showHidden: true).count == 4)
    let shortcut = try #require(entries.first { $0.name == "Folder shortcut" })
    #expect(shortcut.isSymbolicLink && shortcut.isBrowsable)
    let children = try await DirectoryReader.read(shortcut.url)
    #expect(children.map(\.name) == ["notes.txt"])
    #expect(children.first?.url.deletingLastPathComponent().path == shortcut.url.path)
}

@Test(arguments: ["missing", "cycle", "file"])
func invalidDirectoryLinksReportFailure(linkKind: String) async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let link = root.appendingPathComponent("link")
    let target = root.appendingPathComponent(linkKind == "cycle" ? "link" : "target")
    if linkKind == "file" { try Data("file".utf8).write(to: target) }
    try manager.createSymbolicLink(at: link, withDestinationURL: target)
    do {
        _ = try await DirectoryReader.read(link)
        Issue.record("An invalid directory link unexpectedly loaded")
    } catch { }
}
