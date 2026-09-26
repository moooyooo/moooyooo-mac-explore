import Foundation
import ExplorerCore
import ExplorerPlatform

/// Test-only child process. Never bundled in the application.
@main struct StorageProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5 else { return }
        if args[1] == "paste-cut" {
            let input = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
            let support = URL(fileURLWithPath: args[2])
            var report = ["completed": 0, "failed": 0]
            do {
                let id = UUID(uuidString: input["token"]!)!
                let claim = try await CutTransferStore(supportDirectory: support).acquire(id, clipboardURLs: [URL(fileURLWithPath: input["source"]!)])
                let result = try await FileOperations(supportDirectory: support).transfer(claim.sources,
                    to: URL(fileURLWithPath: input["destination"]!), kind: .move, resolve: { _ in .cancel },
                    beforeMove: { try await claim.beginMoving($0) },
                    afterMove: { try await claim.finishMoving($0, destination: $1) })
                report["completed"] = result.completed; report["failed"] = result.failed
            } catch { report["failed"] = 1 }
            try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: args[4]), options: .atomic)
            return
        }
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
