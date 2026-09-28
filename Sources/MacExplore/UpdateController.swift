import AppKit
import ExplorerCore
import ExplorerPlatform
import Sparkle

/// Sparkle owns transport, signature validation and replacement. This coordinator
/// owns consent, scheduling and the application's multi-process/data-safety gates.
@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate, NSMenuItemValidation {
    static let feed = "https://raw.githubusercontent.com/moooyooo/moooyooo-mac-explore/main/updates/appcast.xml"
    static let downloads = "https://github.com/moooyooo/moooyooo-mac-explore/releases/download/"
    private let store: UpdateSessionStore
    private let defaults: UserDefaults
    private let isBusy: () -> Bool
    private let snapshot: () -> [UpdateWorkspace]
    private let showError: (Error) -> Void
    private var updater: SPUUpdater?
    private var candidateBuild: String?
    private var timer: Task<Void, Never>?
    private var preparing = false
    private(set) var ownsUpdate = false
    private(set) var targetBuild: String?
    private var installHandler: (() -> Void)?
    private let enabled: Bool
    private static let checksKey = "MacExploreAutomaticUpdateChecks"
    private static let lastCheckKey = "MacExploreLastUpdateAttempt"

    init(store: UpdateSessionStore, enabled: Bool, defaults: UserDefaults = .standard,
         isBusy: @escaping () -> Bool, snapshot: @escaping () -> [UpdateWorkspace],
         showError: @escaping (Error) -> Void) {
        self.store = store; self.enabled = enabled; self.defaults = defaults
        self.isBusy = isBusy; self.showError = showError
        self.snapshot = snapshot
        super.init()
    }

    func start() {
        guard enabled else { return }
        let driver = UpdateUserDriver(hostBundle: .main, delegate: nil)
        driver.ready = { [weak self] in self?.targetBuild = self?.candidateBuild }
        driver.cancelled = { [weak self] in self?.targetBuild = nil; self?.installHandler = nil }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        self.updater = updater
        // Scheduling happens here so filesystem locks are acquired asynchronously
        // before Sparkle starts a check. No helper daemon or automatic network opt-in.
        updater.automaticallyChecksForUpdates = false
        updater.sendsSystemProfile = false
        do { try updater.start() } catch { showError(error); return }
        timer = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
                while !Task.isCancelled {
                    await self?.scheduledCheck()
                    try await Task.sleep(for: .seconds(15 * 60))
                }
            } catch { }
        }
    }

    func stop() { timer?.cancel(); timer = nil }

    func addMenu(to menu: NSMenu) {
        let items: [(L10n.Key, Selector)] = [
            (.checkForUpdates, #selector(checkForUpdates(_:))),
            (.automaticUpdateChecks, #selector(toggleChecks(_:))),
            (.installUpdatesOnQuit, #selector(toggleInstall(_:))),
            (.installUpdateNow, #selector(installNow(_:)))
        ]
        menu.addItem(.separator())
        for (title, action) in items {
            let item = NSMenuItem(title: L10n.text(title), action: action, keyEquivalent: "")
            item.target = self
            item.toolTip = L10n.text(enabled ? .updatesDetail : .updatesIsolated)
            menu.addItem(item)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleChecks(_:)):
            item.state = defaults.bool(forKey: Self.checksKey) ? .on : .off
            return enabled
        case #selector(toggleInstall(_:)):
            item.state = updater?.automaticallyDownloadsUpdates == true ? .on : .off
            return enabled
        case #selector(installNow(_:)):
            return enabled && targetBuild != nil && !isBusy() &&
                (installHandler != nil || updater?.canCheckForUpdates == true)
        default: return enabled && !preparing && updater?.canCheckForUpdates == true
        }
    }

    @objc private func toggleChecks(_ sender: NSMenuItem) {
        defaults.set(!defaults.bool(forKey: Self.checksKey), forKey: Self.checksKey)
        if defaults.bool(forKey: Self.checksKey) { Task { await scheduledCheck() } }
    }
    @objc private func toggleInstall(_ sender: NSMenuItem) {
        if let updater { updater.automaticallyDownloadsUpdates.toggle() }
    }
    @objc private func checkForUpdates(_ sender: Any?) { Task { await check(userInitiated: true) } }
    @objc private func installNow(_ sender: Any?) {
        guard !isBusy() else { showError(Self.busyError); return }
        guard let installHandler else {
            if targetBuild != nil { updater?.checkForUpdates() }
            return
        }
        // Sparkle permits repeated calls after the application rejects termination.
        installHandler()
    }

    private func scheduledCheck() async {
        let elapsed = Date().timeIntervalSince1970 - defaults.double(forKey: Self.lastCheckKey)
        guard defaults.bool(forKey: Self.checksKey), elapsed < 0 || elapsed >= 24 * 60 * 60 else { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        guard enabled, let updater, !preparing, updater.canCheckForUpdates else { return }
        if ownsUpdate {
            if userInitiated { updater.checkForUpdates() }
            return
        }
        preparing = true
        defer { preparing = false }
        do {
            guard !isBusy() else { throw Self.busyError }
            try await store.beginUpdate(workspaces: snapshot())
            ownsUpdate = true
            // Older versions do not participate in the advisory lease protocol.
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let urls = NSWorkspace.shared.runningApplications.filter {
                $0.processIdentifier != currentPID && $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }.compactMap(\.bundleURL)
            let bundleURL = Bundle.main.bundleURL
            let otherRunning = await Task.detached(priority: .utility) {
                let path = bundleURL.resolvingSymlinksInPath().standardizedFileURL
                return urls.contains { $0.resolvingSymlinksInPath().standardizedFileURL == path }
            }.value
            guard !otherRunning else { throw UpdateSessionError.otherInstance }
            guard !isBusy() else { throw Self.busyError }
            defaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            updater.sendsSystemProfile = false
            if userInitiated { updater.checkForUpdates() }
            else { updater.checkForUpdatesInBackground() }
        } catch {
            if ownsUpdate { await releaseUpdate() }
            if userInitiated { showError(error) }
        }
    }

    private func releaseUpdate() async {
        do { try await store.endUpdate(); ownsUpdate = false }
        catch { showError(error) } // Fail closed if the coordination store cannot be updated.
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard ownsUpdate else { throw Self.busyError }
    }

    func feedURLString(for updater: SPUUpdater) -> String? { Self.feed }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard item.signingValidationStatus == .succeeded,
              let version = UInt64(item.versionString), version > 0,
              let current = UInt64(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""),
              version > current, let url = item.fileURL,
              url.absoluteString.hasPrefix(Self.downloads), url.pathExtension == "zip",
              url.pathComponents.count == 7, !url.pathComponents.contains(".."),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { throw UpdateSessionError.invalidBuild }
        candidateBuild = item.versionString
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        targetBuild = item.versionString
        self.installHandler = installHandler
        Task { [weak self] in
            guard let self else { return }
            if !self.isBusy() {
                installHandler()
            } else { self.showError(Self.busyError) }
        }
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        targetBuild = item.versionString
        installHandler = immediateInstallHandler
        return true // Keep the update cycle and exclusive lease until quit / Install Now.
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { targetBuild = item.versionString }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .dismiss, state.stage == .installing { targetBuild = item.versionString }
        if choice == .skip { targetBuild = nil; installHandler = nil }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        // A downloaded installer may still be waiting for normal quit after the UI
        // cycle ends. Retain its lease; no second process may enter during that wait.
        if error != nil { targetBuild = nil; installHandler = nil }
        guard targetBuild == nil, ownsUpdate else { return }
        preparing = true
        Task { await releaseUpdate(); preparing = false }
    }

    var isChecking: Bool { preparing || (ownsUpdate && targetBuild == nil) }
    static var busyError: NSError {
        NSError(domain: "io.github.moooyooo.MacExplore.Update", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L10n.text(.updateBusy)])
    }
}

/// The standard driver does not report the Ready-to-Install dialog's dismissal
/// through SPUUpdaterDelegate.userDidMakeChoice. Observe that public UI callback
/// so "Install on Quit" keeps its lease and "Cancel Update" releases it.
@MainActor
final class UpdateUserDriver: SPUStandardUserDriver {
    var ready: (() -> Void)?
    var cancelled: (() -> Void)?

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        ready?()
        super.showReady(toInstallAndRelaunch: { [weak self] choice in
            if choice == .skip { self?.cancelled?() }
            reply(choice)
        })
    }

    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        cancelled?()
        super.showUpdaterError(error, acknowledgement: acknowledgement)
    }
}
