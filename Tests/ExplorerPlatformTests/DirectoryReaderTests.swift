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
