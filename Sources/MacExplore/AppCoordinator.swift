import AppKit
import ExplorerCore
import ExplorerPlatform

@objc(ExplorerApplication)
final class ExplorerApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, (delegate as? AppCoordinator)?.handleKey(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    let instanceID = UUID()
    private var windows: [WorkspaceWindowController] = []
    private var sequence = 0
    private let startTime: TimeInterval
    private var firstDirectoryTime: TimeInterval?
    private var reportURL: URL?
    private var reportScheduled = false
    private var projectStore = ProjectStore()
    private var recentStore = RecentProjectStore()
    private var sessionStore: SessionStore?
    private var sessionTask: Task<Void, Never>?
    private var sessionReady = false
    private var terminating = false
    private var pendingProjectURLs: [URL] = []
    private var launched = false
    private var opening: Set<String> = []
    private let recentMenu = NSMenu(title: L10n.text(.recentProjects))
    private var workspaceObserver: NSObjectProtocol?
    private var recoveryErrorShown = false
    private var instanceArguments: [String] = []

    init(startTime: TimeInterval) { self.startTime = startTime }

    private var current: WorkspaceWindowController? {
        (NSApp.keyWindow?.windowController as? WorkspaceWindowController)
            ?? (NSApp.mainWindow?.windowController as? WorkspaceWindowController)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        buildMenus()
        let arguments = Array(CommandLine.arguments.dropFirst())
        var folders: [URL] = []
        var supportDirectory: URL?
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--folder", index + 1 < arguments.count {
                index += 1
                folders.append(URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath, isDirectory: true))
            } else if arguments[index] == "--diagnostics-file", index + 1 < arguments.count {
                index += 1
                reportURL = URL(fileURLWithPath: arguments[index])
            } else if arguments[index] == "--project", index + 1 < arguments.count {
                index += 1
                pendingProjectURLs.append(URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath))
            } else if arguments[index] == "--support-directory", index + 1 < arguments.count {
                index += 1
                supportDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            }
            index += 1
        }
        if let supportDirectory {
            instanceArguments = ["--support-directory", supportDirectory.path]
            projectStore = ProjectStore(supportDirectory: supportDirectory)
            recentStore = RecentProjectStore(supportDirectory: supportDirectory)
        }
        if let language = LanguageSettings.argument() { instanceArguments += ["--language", language.rawValue] }
        let session = SessionStore(instanceID: instanceID, supportDirectory: supportDirectory)
        sessionStore = session
        Task {
            do { try await session.start(); sessionReady = true; scheduleRecovery() }
            catch { await showError(error, title: L10n.text(.recoverySaveFailed)) }
            await refreshRecentMenu()
        }
        if folders.isEmpty { folders = [FileManager.default.homeDirectoryForCurrentUser] }
        if arguments.contains("--demo") {
            let demo = (0..<3).map { folders[$0 % folders.count] }
            createWindow(directories: demo)
            createWindow(directories: demo)
        } else if pendingProjectURLs.isEmpty { createWindow(directories: folders) }
        launched = true
        let projects = pendingProjectURLs; pendingProjectURLs = []
        for url in projects { Task { await openProject(url) } }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.windows.forEach { $0.reloadBrowsers() } }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    func createWindow(directories: [URL]? = nil) -> WorkspaceWindowController {
        sequence += 1
        let controller = WorkspaceWindowController(
            number: sequence,
            directories: directories ?? [FileManager.default.homeDirectoryForCurrentUser],
            newWindow: { [weak self] in self?.createWindow() },
            newInstance: { [weak self] in self?.launchInstance() },
            openProject: { [weak self] in self?.chooseProject(switching: false) }
        )
        let project = WorkspaceProjectController(workspace: controller, store: projectStore)
        controller.project = project
        project.onChange = { [weak self] in self?.scheduleRecovery() }
        project.onSaved = { [weak self] url in self?.recordRecent(url) }
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
            self?.scheduleRecovery()
        }
        controller.onDirectoryLoaded = { [weak self] in self?.directoryLoaded() }
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.activeBrowser?.focusFiles()
        scheduleRecovery()
        return controller
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { createWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionTask?.cancel()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        for controller in windows { controller.stopLoading() }
    }

    func applicationDidBecomeActive(_ notification: Notification) { windows.forEach { $0.reloadBrowsers() } }

    func application(_ sender: NSApplication, open urls: [URL]) {
        if !launched { pendingProjectURLs += urls; return }
        for url in urls { Task { await openProject(url) } }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateCancel }
        guard !windows.contains(where: { $0.project?.isBusy == true || $0.window?.attachedSheet != nil }) else { return .terminateCancel }
        terminating = true
        Task {
            var confirmed: [(WorkspaceProjectController, UInt64)] = []
            for controller in windows {
                if await controller.project?.confirmDiscardingChanges() == false {
                    terminating = false; sender.reply(toApplicationShouldTerminate: false); return
                }
                if let project = controller.project { confirmed.append((project, project.changeToken)) }
            }
            guard confirmed.allSatisfy({ $0.0.changeToken == $0.1 }) else {
                terminating = false; scheduleRecovery(); sender.reply(toApplicationShouldTerminate: false); return
            }
            sessionTask?.cancel()
            do { try await sessionStore?.finish() }
            catch { /* Keep the last recovery file if cleanup fails. */ }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func launchInstance(arguments: [String] = []) {
        Task {
            do { try await InstanceLauncher.launch(arguments: instanceArguments + arguments) }
            catch {
                let alert = NSAlert(error: error)
                alert.messageText = L10n.text(.instanceFailed)
                alert.runModal()
            }
        }
    }

    @objc private func menuCommand(_ sender: NSMenuItem) {
        if let command = AppCommand(rawValue: sender.tag) { perform(command) }
    }

    func perform(_ command: AppCommand) {
        guard !terminating else { return }
        switch command {
        case .newPane: if let current { current.addPane() } else { createWindow() }
        case .newWindow: createWindow()
        case .newInstance: launchInstance()
        case .openFolder: current?.chooseFolder()
        case .closePane: current?.closeActivePane()
        case .closeWindow: current?.window?.performClose(nil)
        case .back: current?.activeBrowser?.goBack()
        case .forward: current?.activeBrowser?.goForward()
        case .up: current?.activeBrowser?.goUp()
        case .refresh: current?.activeBrowser?.reload()
        case .focusAddress: current?.activeBrowser?.focusAddress()
        case .focusSearch: current?.activeBrowser?.focusSearch()
        case .nextPane: current?.cycle()
        case .previousPane: current?.cycle(backward: true)
        case .maximize: current?.maximizeActivePane()
        case .minimize: current?.minimizeActivePane()
        case .columns: current?.arrange(.columns)
        case .rows: current?.arrange(.rows)
        case .cascade: current?.arrange(.cascade)
        case .move: current?.beginGeometry(resizing: false)
        case .resize: current?.beginGeometry(resizing: true)
        case .shortcuts: showShortcuts()
        case .diagnostics: showDiagnostics()
        case .openProject: chooseProject(switching: false)
        case .switchProject: chooseProject(switching: true)
        case .saveProject: let project = current?.project; Task { await project?.save() }
        case .saveProjectAs: let project = current?.project; Task { await project?.save(asCopy: true) }
        case .reacquireProject: let project = current?.project; Task { await project?.reacquire() }
        case .recoverSession: Task { await recoverSession() }
        case .favorite: current?.activeBrowser?.toggleFavorite()
        case .openInNewPane: current?.activeBrowser?.openSelectionInNewPane()
        case .projectInNewInstance:
            if let url = current?.project?.url { launchInstance(arguments: ["--project", url.path]) }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(changeLanguage(_:)) {
            menuItem.state = (menuItem.representedObject as? String) == LanguageSettings.preference().rawValue ? .on : .off
            return !terminating
        }
        if (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        guard let command = AppCommand(rawValue: menuItem.tag) else { return true }
        switch command {
        case .newPane, .newWindow, .newInstance, .shortcuts, .diagnostics, .openProject, .recoverSession: return !terminating
        case .saveProject, .saveProjectAs, .switchProject: return current != nil && current?.project?.isBusy == false
        case .reacquireProject: return current?.project?.opened != nil && current?.project?.isBusy == false
        case .projectInNewInstance: return current?.project?.url != nil
        case .openFolder, .closeWindow: return current != nil
        case .nextPane, .previousPane, .columns, .rows, .cascade: return current?.state.panes.isEmpty == false
        default: return current?.state.activePaneID != nil
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard let window = NSApp.keyWindow, window is WorkspaceWindow, window.attachedSheet == nil else { return false }
        let editor = window.firstResponder as? NSTextView
        if editor?.hasMarkedText() == true { return false }
        if current?.handleGeometryKey(event) == true { return true }
        var flags: KeyModifiers = []
        if event.modifierFlags.contains(.command) { flags.insert(.command) }
        if event.modifierFlags.contains(.control) { flags.insert(.control) }
        if event.modifierFlags.contains(.option) { flags.insert(.option) }
        if event.modifierFlags.contains(.shift) { flags.insert(.shift) }
        guard let action = Shortcuts.resolve(
            key: event.charactersIgnoringModifiers ?? "", code: event.keyCode, modifiers: flags,
            editingText: editor?.isEditable == true, composingText: editor?.hasMarkedText() == true
        ) else { return false }
        switch action {
        case .command(let command): perform(command)
        case .edit(let selector): return NSApp.sendAction(NSSelectorFromString(selector), to: nil, from: nil)
        case .selectFiles: current?.activeBrowser?.table.selectAll(nil)
        case .cycleFocus(let backward): current?.activeBrowser?.cycleFocus(backward: backward)
        }
        return true
    }

    private func buildMenus() {
        let bar = NSMenu()
        NSApp.mainMenu = bar
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            bar.addItem(item)
            return submenu
        }
        func add(_ menu: NSMenu, _ title: String, _ command: AppCommand, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: key)
            item.target = self
            item.tag = command.rawValue
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        let app = menu("Moooyooo Mac Explore")
        app.addItem(withTitle: L10n.text(.about), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let languageItem = NSMenuItem(title: L10n.text(.languageMenu), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu(title: languageItem.title)
        for (language, key): (AppLanguage, L10n.Key) in [(.system, .languageSystem), (.en, .languageEnglish), (.ja, .languageJapanese)] {
            let item = NSMenuItem(title: L10n.text(key), action: #selector(changeLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        app.addItem(languageItem)
        app.addItem(.separator())
        app.addItem(withTitle: L10n.text(.hideApp), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: L10n.text(.quitApp), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = menu(L10n.text(.menuFile))
        add(file, L10n.text(.newExplorer), .newPane, "n")
        add(file, L10n.text(.newMDIWindow), .newWindow, "n", [.command, .option])
        add(file, L10n.text(.launchProcess), .newInstance)
        file.addItem(.separator())
        add(file, L10n.text(.chooseFolder), .openFolder, "o", [.command, .shift])
        add(file, L10n.text(.openSelectionInPane), .openInNewPane)
        file.addItem(.separator())
        add(file, L10n.text(.closeExplorer), .closePane, "w")
        add(file, L10n.text(.closeMDIWindow), .closeWindow, "w", [.command, .shift])

        let project = menu(L10n.text(.menuProject))
        add(project, L10n.text(.newProject), .newWindow)
        add(project, L10n.text(.chooseProject), .openProject, "o")
        add(project, L10n.text(.switchProject), .switchProject)
        add(project, L10n.text(.projectNewProcess), .projectInNewInstance)
        let recent = NSMenuItem(title: recentMenu.title, action: nil, keyEquivalent: "")
        recent.submenu = recentMenu; project.addItem(recent)
        recentMenu.delegate = self
        project.addItem(.separator())
        add(project, L10n.text(.saveProjectMenu), .saveProject, "s")
        add(project, L10n.text(.saveAsMenu), .saveProjectAs, "s", [.command, .shift])
        add(project, L10n.text(.reacquireProject), .reacquireProject)
        project.addItem(.separator())
        add(project, L10n.text(.recoverSession), .recoverSession)

        let edit = menu(L10n.text(.menuEdit))
        for (title, selector, key) in [(L10n.text(.undo), "undo:", "z"), (L10n.text(.cut), "cut:", "x"), (L10n.text(.copy), "copy:", "c"), (L10n.text(.paste), "paste:", "v"), (L10n.text(.selectAll), "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        let view = menu(L10n.text(.menuView))
        add(view, L10n.text(.refresh), .refresh, "r")
        add(view, L10n.text(.searchFolder), .focusSearch, "f")
        add(view, L10n.text(.toggleFavorite), .favorite)
        let go = menu(L10n.text(.menuGo))
        add(go, L10n.text(.back), .back, "[")
        add(go, L10n.text(.forward), .forward, "]")
        add(go, L10n.text(.parentFolder), .up, "\u{f700}")
        add(go, L10n.text(.goToPath), .focusAddress, "l")
        let window = menu(L10n.text(.menuWindow))
        add(window, L10n.text(.nextExplorer), .nextPane, "\t", .control)
        add(window, L10n.text(.previousExplorer), .previousPane, "\t", [.control, .shift])
        window.addItem(.separator())
        add(window, L10n.text(.maximizePane), .maximize)
        add(window, L10n.text(.minimizePane), .minimize)
        add(window, L10n.text(.movePane), .move)
        add(window, L10n.text(.resizePane), .resize)
        window.addItem(.separator())
        add(window, L10n.text(.tileColumns), .columns)
        add(window, L10n.text(.tileRows), .rows)
        add(window, L10n.text(.cascadeMenu), .cascade)
        window.addItem(.separator())
        NSApp.windowsMenu = window
        let help = menu(L10n.text(.menuHelp))
        add(help, L10n.text(.shortcutList), .shortcuts)
        add(help, L10n.text(.diagnostics), .diagnostics)
        NSApp.helpMenu = help
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let language = AppLanguage(rawValue: value) else { return }
        UserDefaults.standard.set(language.rawValue, forKey: LanguageSettings.preferenceKey)
        // An explicit launch override is no longer needed for subsequent child processes.
        if let index = instanceArguments.firstIndex(of: "--language") { instanceArguments.removeSubrange(index...index + 1) }
        let alert = NSAlert()
        alert.messageText = L10n.text(.languageNextLaunch)
        alert.informativeText = L10n.text(.languageNextLaunchDetail)
        alert.runModal()
    }

    private func showShortcuts() {
        let alert = NSAlert()
        alert.messageText = L10n.text(.shortcutsTitle)
        alert.informativeText = L10n.text(.shortcutsBody)
        alert.runModal()
    }

    private func diagnostics() -> [String: Any] {
        var data: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "instanceID": instanceID.uuidString,
            "windows": windows.count,
            "panes": windows.reduce(0) { $0 + $1.state.panes.count },
            "projects": windows.compactMap { $0.project?.opened }.count,
            "readOnlyProjects": windows.filter { $0.project?.isReadOnly == true }.count,
            "physicalFootprintBytes": ProcessMetrics.physicalFootprint() ?? 0,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "language": L10n.current.language.rawValue,
            "preferredLocalizations": Bundle.main.preferredLocalizations,
            "localizationBundled": Localizer.resourceBundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL
                == Bundle.main.resourceURL?.appendingPathComponent("MacExplore_ExplorerCore.bundle").resolvingSymlinksInPath().standardizedFileURL,
            "menuTitles": NSApp.mainMenu?.items.map(\.title) ?? [],
        ]
        if let firstDirectoryTime { data["firstDirectorySecondsFromMain"] = firstDirectoryTime }
        return data
    }

    private func showDiagnostics() {
        let data = diagnostics()
        let alert = NSAlert()
        alert.messageText = L10n.text(.diagnostics)
        let footprint = Double(ProcessMetrics.physicalFootprint() ?? 0) / 1_048_576
        alert.informativeText = L10n.format(.diagnosticsBody, ProcessInfo.processInfo.processIdentifier,
                                          instanceID.uuidString, windows.count, data["panes"] as? Int ?? 0,
                                          footprint, ProcessInfo.processInfo.operatingSystemVersionString)
        alert.runModal()
    }

    private func directoryLoaded() {
        if firstDirectoryTime == nil { firstDirectoryTime = ProcessInfo.processInfo.systemUptime - startTime }
        guard let reportURL, !reportScheduled else { return }
        reportScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject: self.diagnostics(), options: [.prettyPrinted, .sortedKeys])
                try await Task.detached(priority: .utility) {
                    try data.write(to: reportURL, options: .atomic)
                }.value
            } catch {
                // This opt-in diagnostic output does not contain file or folder names.
                fputs("MacExplore: could not write diagnostic report.\n", stderr)
            }
        }
    }

    private func chooseProject(switching: Bool) {
        let target = switching ? current : nil
        guard !switching || target?.project?.isBusy == false else { return }
        let window = current?.window
        Task {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [WorkspaceProjectController.fileType]
            panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.title = switching ? L10n.text(.switchProjectTitle) : L10n.text(.openProjectWindow)
            let response: NSApplication.ModalResponse
            if let window { response = await panel.beginSheetModal(for: window) }
            else { response = await panel.begin() }
            if response == .OK, let url = panel.url { await openProject(url, replacing: target) }
        }
    }

    private func openProject(_ url: URL, replacing target: WorkspaceWindowController? = nil) async {
        do {
            let identity = try await projectStore.identity(of: url)
            guard !opening.contains(identity) else { return }
            opening.insert(identity)
            defer { opening.remove(identity) }
            for controller in windows {
                if let existing = controller.project?.url, try await projectStore.identity(of: existing) == identity {
                    controller.window?.makeKeyAndOrderFront(nil); return
                }
            }
            let opened = try await projectStore.open(url)
            if let target, !windows.contains(where: { $0 === target }) {
                await projectStore.close(opened.handleID); return
            }
            if let target, await target.project?.confirmDiscardingChanges() != true {
                await projectStore.close(opened.handleID); return
            }
            let controller = target ?? createWindow(directories: [])
            do {
                try controller.project?.adopt(opened)
                controller.window?.makeKeyAndOrderFront(nil)
                recordRecent(opened.url)
            } catch { await projectStore.close(opened.handleID); throw error }
        } catch {
            await showError(error, title: L10n.text(.openProjectFailed))
            if windows.isEmpty { createWindow() }
        }
    }

    private func recordRecent(_ url: URL) {
        Task {
            do { try await recentStore.record(url); await refreshRecentMenu() }
            catch { await showError(error, title: L10n.text(.recentUpdateFailed)) }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { if menu === recentMenu { Task { await refreshRecentMenu() } } }

    private func refreshRecentMenu() async {
        let urls = (try? await recentStore.list()) ?? []
        recentMenu.removeAllItems()
        for url in urls {
            let item = NSMenuItem(title: url.deletingPathExtension().lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = url; item.toolTip = url.path
            recentMenu.addItem(item)
        }
        if urls.isEmpty {
            let item = NSMenuItem(title: L10n.text(.noRecentProjects), action: nil, keyEquivalent: "")
            item.isEnabled = false; recentMenu.addItem(item)
        }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Task { await openProject(url) }
    }

    private func recoverySnapshot() -> [RecoveryWorkspace] {
        windows.compactMap { controller in
            guard let project = controller.project else { return nil }
            return RecoveryWorkspace(document: project.snapshot(), sourceURL: project.url)
        }
    }

    private func scheduleRecovery() {
        guard sessionReady, !terminating, let sessionStore else { return }
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, !Task.isCancelled, !self.terminating else { return }
            do { try await sessionStore.update(self.recoverySnapshot()) }
            catch {
                guard !self.recoveryErrorShown else { return }
                self.recoveryErrorShown = true
                await self.showError(error, title: L10n.text(.recoveryWriteFailed))
            }
        }
    }

    private func recoverSession() async {
        guard let sessionStore else { return }
        do {
            let sessions = try await sessionStore.available()
            let alert = NSAlert()
            alert.messageText = sessions.isEmpty ? L10n.text(.noRecovery) : L10n.text(.chooseRecovery)
            alert.informativeText = L10n.text(.recoveryDetail)
            guard !sessions.isEmpty else { alert.runModal(); return }
            let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
            let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
            formatter.locale = L10n.locale
            for session in sessions { choices.addItem(withTitle: formatter.string(from: session.updated) + " · " + L10n.format(.windowCount, session.workspaces.count)) }
            alert.accessoryView = choices
            alert.addButton(withTitle: L10n.text(.recover)); alert.addButton(withTitle: L10n.text(.cancel))
            let response: NSApplication.ModalResponse
            if let window = current?.window { response = await alert.beginSheetModal(for: window) }
            else { response = alert.runModal() }
            guard response == .alertFirstButtonReturn else { return }
            let session = try await sessionStore.claim(sessions[choices.indexOfSelectedItem].id)
            do {
                for workspace in session.workspaces {
                    let controller = createWindow(directories: [])
                    try controller.project?.recover(workspace.document)
                }
                // Durable handoff before removing the original crashed instance's data.
                try await sessionStore.update(recoverySnapshot())
                try await sessionStore.finishClaim(session.id, consumed: true)
            } catch {
                try? await sessionStore.finishClaim(session.id, consumed: false)
                throw error
            }
        } catch { await showError(error, title: L10n.text(.recoveryFailed)) }
    }

    private func showError(_ error: Error, title: String) async {
        let alert = NSAlert(error: error); alert.messageText = title
        if let window = current?.window, window.attachedSheet == nil { await alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}
