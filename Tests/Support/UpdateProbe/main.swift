import AppKit
import CryptoKit
import ExplorerCore
import ExplorerPlatform
import Sparkle

/// Synthetic updater host, never bundled in MacExplore. Uses a disposable signing
/// key and a unique bundle ID. Allows real replacement/relaunch without user input.
@main @MainActor
struct UpdateProbe {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--generate-key" {
            let key = Curve25519.Signing.PrivateKey()
            let url = URL(fileURLWithPath: args[2])
            FileManager.default.createFile(atPath: url.path, contents: key.rawRepresentation.base64EncodedData(),
                                           attributes: [.posixPermissions: 0o600])
            print(key.publicKey.rawRepresentation.base64EncodedString())
            return
        }
        if args.count == 4, args[1] == "--verify-feed" {
            let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
            let delimiter = Data("<!-- sparkle-signatures:\n".utf8)
            guard let range = data.range(of: delimiter),
                  let tail = String(data: data[range.upperBound...], encoding: .utf8),
                  let signatureLine = tail.split(separator: "\n").first(where: { $0.hasPrefix("edSignature: ") }),
                  let lengthLine = tail.split(separator: "\n").first(where: { $0.hasPrefix("length: ") }),
                  let length = Int(lengthLine.dropFirst(8)), length == range.lowerBound,
                  tail == "\(signatureLine)\n\(lengthLine)\n-->\n",
                  let signature = Data(base64Encoded: String(signatureLine.dropFirst(13))),
                  let publicKey = Data(base64Encoded: args[3]),
                  try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
                    .isValidSignature(signature, for: data.prefix(length)) else { exit(1) }
            print("Signed feed verified with public key.")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let coordinator = ProbeCoordinator()
        app.delegate = coordinator
        withExtendedLifetime(coordinator) { app.run() }
    }
}

@MainActor final class ProbeCoordinator: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "UpdateProbeRoot") as! String)
    lazy var gate = UpdateSessionStore(bundleURL: Bundle.main.bundleURL, supportDirectory: root.appendingPathComponent("support"))
    var updater: SPUUpdater?
    var rejectedOnce = false
    var target: String?
    let workspaces = [UpdateWorkspace(workspace: .init(document: ProjectDocument(name: "Synthetic update workspace"), sourceURL: nil),
                                     savedDigest: nil, isDirty: true)]

    func record(_ name: String, _ data: [String: Any]) {
        try! JSONSerialization.data(withJSONObject: data, options: .sortedKeys)
            .write(to: root.appendingPathComponent(name + ".json"), options: .atomic)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
                let saved = try await gate.register(build: build)
                if build == "2" {
                    guard saved?.workspaces.first?.workspace.document.name == "Synthetic update workspace" else { exit(3) }
                    try await gate.finishRestart()
                    record("installed", ["build": build, "restored": true])
                    exit(0)
                }
                try await gate.beginUpdate(workspaces: workspaces)
                let driver = ProbeDriver(hostBundle: .main, delegate: nil)
                driver.host = self
                let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
                self.updater = updater
                updater.automaticallyChecksForUpdates = false
                try updater.start()
                try await Task.sleep(for: .milliseconds(200))
                updater.checkForUpdates()
            } catch { record("failed", ["description": error.localizedDescription]); exit(1) }
        }
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard item.signingValidationStatus == .succeeded else {
            throw NSError(domain: "UpdateProbe", code: 10, userInfo: [NSLocalizedDescriptionKey: "Untrusted appcast"])
        }
        target = item.versionString
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            record("failed", ["domain": (error as NSError).domain, "code": (error as NSError).code])
            Task { try? await gate.endUpdate(); exit(1) }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !rejectedOnce {
            rejectedOnce = true
            record("busy-deferred", ["deferred": true])
            return .terminateCancel
        }
        Task {
            do {
                try await gate.prepareRestart(targetBuild: target ?? "", workspaces: workspaces)
                sender.reply(toApplicationShouldTerminate: true)
            } catch { record("failed", ["description": error.localizedDescription]); exit(1) }
        }
        return .terminateLater
    }
}

@MainActor final class ProbeDriver: SPUStandardUserDriver {
    weak var host: ProbeCoordinator?
    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.install) }
    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.install) }
    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    override func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                                      retryTerminatingApplication: @escaping () -> Void) {
        guard !applicationTerminated else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            retryTerminatingApplication()
        }
    }
}
