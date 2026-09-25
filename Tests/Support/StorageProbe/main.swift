import Foundation
import ExplorerCore
import ExplorerPlatform

/// Test-only child process. Never bundled in the application.
@main struct StorageProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5 else { return }
        let store = ProjectStore(supportDirectory: URL(fileURLWithPath: args[2]))
        let opened = try await store.open(URL(fileURLWithPath: args[3]))
        var result: [String: Bool] = ["writable": opened.isWritable]
        if args[1] == "save" {
            var document = opened.document; document.name = "child saved"
            do { _ = try await store.save(document, handleID: opened.handleID); result["saved"] = true }
            catch { result["saved"] = false }
        }
        try JSONSerialization.data(withJSONObject: result).write(to: URL(fileURLWithPath: args[4]), options: .atomic)
        if args[1] == "hold" { try await Task.sleep(for: .seconds(180)) }
        await store.close(opened.handleID)
    }
}
