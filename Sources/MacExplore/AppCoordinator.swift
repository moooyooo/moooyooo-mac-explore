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
final class AppCoordinator: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let instanceID = UUID()
    private var windows: [WorkspaceWindowController] = []
    private var sequence = 0
    private let startTime: TimeInterval
    private var firstDirectoryTime: TimeInterval?
    private var reportURL: URL?
    private var reportScheduled = false

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
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--folder", index + 1 < arguments.count {
                index += 1
                folders.append(URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath, isDirectory: true))
            } else if arguments[index] == "--diagnostics-file", index + 1 < arguments.count {
                index += 1
                reportURL = URL(fileURLWithPath: arguments[index])
            }
            index += 1
        }
        if folders.isEmpty { folders = [FileManager.default.homeDirectoryForCurrentUser] }
        if arguments.contains("--demo") {
            let demo = (0..<3).map { folders[$0 % folders.count] }
            createWindow(directories: demo)
            createWindow(directories: demo)
        } else { createWindow(directories: folders) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func createWindow(directories: [URL]? = nil) {
        sequence += 1
        let controller = WorkspaceWindowController(
            number: sequence,
            directories: directories ?? [FileManager.default.homeDirectoryForCurrentUser],
            newWindow: { [weak self] in self?.createWindow() },
            newInstance: { [weak self] in self?.launchInstance() }
        )
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        controller.onDirectoryLoaded = { [weak self] in self?.directoryLoaded() }
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.activeBrowser?.focusFiles()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { createWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        for controller in windows { controller.stopLoading() }
    }

    private func launchInstance() {
        Task {
            do { try await InstanceLauncher.launch() }
            catch {
                let alert = NSAlert(error: error)
                alert.messageText = "別プロセスを起動できませんでした"
                alert.runModal()
            }
        }
    }

    @objc private func menuCommand(_ sender: NSMenuItem) {
        if let command = AppCommand(rawValue: sender.tag) { perform(command) }
    }

    func perform(_ command: AppCommand) {
        switch command {
        case .newPane: if let current { current.addPane() } else { createWindow() }
        case .newWindow: createWindow()
        case .newInstance: launchInstance()
        case .openFolder: current?.chooseFolder()
        case .closePane: current?.closeActivePane()
        case .closeWindow: current?.close()
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
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        guard let command = AppCommand(rawValue: menuItem.tag) else { return true }
        switch command {
        case .newPane, .newWindow, .newInstance, .shortcuts, .diagnostics: return true
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
        app.addItem(withTitle: "Moooyooo Mac Exploreについて", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Moooyooo Mac Exploreを隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Moooyooo Mac Exploreを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = menu("ファイル")
        add(file, "新しいExplorer", .newPane, "n")
        add(file, "新しいMDIウィンドウ", .newWindow, "n", [.command, .option])
        add(file, "別プロセスで起動", .newInstance)
        file.addItem(.separator())
        add(file, "フォルダを開く…", .openFolder, "o", [.command, .shift])
        file.addItem(.separator())
        add(file, "Explorerを閉じる", .closePane, "w")
        add(file, "MDIウィンドウを閉じる", .closeWindow, "w", [.command, .shift])

        let edit = menu("編集")
        for (title, selector, key) in [("元に戻す", "undo:", "z"), ("切り取り", "cut:", "x"), ("コピー", "copy:", "c"), ("貼り付け", "paste:", "v"), ("すべて選択", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        let view = menu("表示")
        add(view, "更新", .refresh, "r")
        add(view, "このフォルダ内を検索", .focusSearch, "f")
        let go = menu("移動")
        add(go, "戻る", .back, "[")
        add(go, "進む", .forward, "]")
        add(go, "上の階層", .up, "\u{f700}")
        add(go, "パスへ移動", .focusAddress, "l")
        let window = menu("ウィンドウ")
        add(window, "次のExplorer", .nextPane, "\t", .control)
        add(window, "前のExplorer", .previousPane, "\t", [.control, .shift])
        window.addItem(.separator())
        add(window, "子画面を最大化／復元", .maximize)
        add(window, "子画面を最小化", .minimize)
        add(window, "子画面を移動…", .move)
        add(window, "子画面のサイズを変更…", .resize)
        window.addItem(.separator())
        add(window, "左右に整列", .columns)
        add(window, "上下に整列", .rows)
        add(window, "重ねて表示", .cascade)
        window.addItem(.separator())
        NSApp.windowsMenu = window
        let help = menu("ヘルプ")
        add(help, "ショートカット一覧", .shortcuts)
        add(help, "診断情報", .diagnostics)
        NSApp.helpMenu = help
    }

    private func showShortcuts() {
        let alert = NSAlert()
        alert.messageText = "主なショートカット"
        alert.informativeText = "Explorer追加: Cmd / Ctrl + N\n親ウィンドウ追加: Cmd / Ctrl + Option + N\n子を閉じる: Cmd / Ctrl + W\n親を閉じる: Cmd / Ctrl + Shift + W\n次／前の子: Ctrl + Tab / Ctrl + Shift + Tab\nパス入力: Cmd / Ctrl + L\n戻る／進む: Option + ← / →\n上の階層: Option + ↑\n更新: F5 / Cmd + R\nフォルダ内検索: Cmd / Ctrl + F\n開く: Enter\n子の移動・サイズ変更: ウィンドウメニュー\n\nファイルの書き換え操作とプロジェクト保存は、現在の開発版では未対応です。"
        alert.runModal()
    }

    private func diagnostics() -> [String: Any] {
        var data: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "instanceID": instanceID.uuidString,
            "windows": windows.count,
            "panes": windows.reduce(0) { $0 + $1.state.panes.count },
            "physicalFootprintBytes": ProcessMetrics.physicalFootprint() ?? 0,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        if let firstDirectoryTime { data["firstDirectorySecondsFromMain"] = firstDirectoryTime }
        return data
    }

    private func showDiagnostics() {
        let data = diagnostics()
        let alert = NSAlert()
        alert.messageText = "診断情報"
        let footprint = Double(ProcessMetrics.physicalFootprint() ?? 0) / 1_048_576
        alert.informativeText = "PID: \(data["pid"]!)\nインスタンス: \(instanceID.uuidString)\n親ウィンドウ: \(windows.count)\nExplorer: \(data["panes"]!)\nメモリ: \(String(format: "%.1f", footprint)) MiB\n\(data["os"]!)"
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
}
