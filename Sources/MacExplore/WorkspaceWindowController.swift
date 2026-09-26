import AppKit
import ExplorerCore
import ExplorerPlatform

@MainActor
final class WorkspaceWindow: NSWindow {
    weak var workspace: WorkspaceWindowController?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            workspace?.activatePane(atWindowPoint: event.locationInWindow)
        }
        super.sendEvent(event)
    }
}

@MainActor
final class PaneChrome: FlippedView {
    let id: UUID
    let browser: ExplorerBrowserController
    let titleBar = PaneTitleBar(frame: .zero)
    let grip = ResizeHandle(frame: .zero)
    private let maximizeButton: ActionButton

    init(id: UUID, browser: ExplorerBrowserController, minimize: @escaping () -> Void,
         maximize: @escaping () -> Void, close: @escaping () -> Void) {
        self.id = id
        self.browser = browser
        self.maximizeButton = ActionButton(L10n.text(.maximizeRestore), symbol: "arrow.up.left.and.arrow.down.right", action: maximize)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        titleBar.buttons = [
            ActionButton(L10n.text(.minimize), symbol: "minus", action: minimize),
            maximizeButton,
            ActionButton(L10n.text(.close), symbol: "xmark", action: close),
        ]
        for button in titleBar.buttons {
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.toolTip = button.title
            titleBar.addSubview(button)
        }
        addSubview(browser.view)
        addSubview(titleBar)
        addSubview(grip)
        grip.setAccessibilityElement(true)
        grip.setAccessibilityRole(.button)
        grip.setAccessibilityLabel(L10n.text(.resizePaneAccessibility))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("pane-\(id)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        titleBar.frame = NSRect(x: 1, y: 1, width: max(0, bounds.width - 2), height: 33)
        browser.view.frame = NSRect(x: 1, y: 34, width: max(0, bounds.width - 2), height: max(0, bounds.height - 35))
        grip.frame = NSRect(x: bounds.width - 18, y: bounds.height - 18, width: 16, height: 16)
    }

    func update(_ pane: ExplorerPane, active: Bool) {
        let name = pane.directory.lastPathComponent.isEmpty ? "/" : pane.directory.lastPathComponent
        titleBar.label.stringValue = name
        titleBar.label.toolTip = pane.directory.path
        titleBar.active = active
        titleBar.setAccessibilityLabel(L10n.format(.movePaneAccessibility, name))
        setAccessibilityLabel(active ? L10n.format(.activePaneAccessibility, name) : name)
        layer?.borderColor = (active ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.borderWidth = active ? 2 : 1
        grip.isHidden = pane.presentation == .maximized
        maximizeButton.image = NSImage(systemSymbolName: pane.presentation == .maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", accessibilityDescription: L10n.text(.maximizeRestore))
    }
}

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    private(set) var state = Workspace()
    private var browsers: [UUID: ExplorerBrowserController] = [:]
    private var chrome: [UUID: PaneChrome] = [:]
    var onClose: (() -> Void)?
    var onDirectoryLoaded: (() -> Void)?
    var onSessionChange: (() -> Void)?
    var project: WorkspaceProjectController?
    private var suppressChanges = false
    private var closeApproved = false
    private var lastWindowFrame: NSRect?
    private let root = LayoutView()
    private let canvas = LayoutView()
    private let shelf = NSScrollView()
    private let shelfContent = FlippedView()
    private let hint = NSTextField(labelWithString: "")
    private let emptyMessage = NSTextField(labelWithString: L10n.text(.emptyWorkspace))
    private var toolbar: [NSButton] = []
    private var shelfIDs: [UUID] = []
    private var dragStart: PaneFrame?
    private var geometryMode: (id: UUID, resizing: Bool, original: PaneFrame)?
    private let number: Int

    var activeBrowser: ExplorerBrowserController? { state.activePaneID.flatMap { browsers[$0] } }
    weak var fileOperations: FileOperationController? {
        didSet { for browser in browsers.values { browser.fileOperations = fileOperations } }
    }
    var isLoadingDirectories: Bool { browsers.values.contains { $0.loading } }
    var canvasSize: CanvasSize { CanvasSize(width: canvas.bounds.width, height: canvas.bounds.height) }

    init(number: Int, directories: [URL], newWindow: @escaping () -> Void, newInstance: @escaping () -> Void,
         openProject: @escaping () -> Void = {}) {
        self.number = number
        let window = WorkspaceWindow(
            contentRect: NSRect(x: 120 + (number % 5) * 25, y: 100 + (number % 5) * 25, width: 1160, height: 770),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = L10n.format(.workspaceTitle, number)
        super.init(window: window)
        window.workspace = self
        window.delegate = self
        window.contentView = root
        root.onLayout = { [weak self] in self?.layoutWorkspace() }
        root.wantsLayer = true
        canvas.wantsLayer = true
        canvas.layer?.masksToBounds = true
        canvas.onLayout = { [weak self] in self?.layoutPanes() }
        emptyMessage.font = .systemFont(ofSize: 15)
        emptyMessage.textColor = .secondaryLabelColor
        emptyMessage.alignment = .center
        canvas.addSubview(emptyMessage)
        root.addSubview(canvas)
        toolbar = [
            ActionButton(L10n.text(.openProject), symbol: "folder", action: openProject),
            ActionButton(L10n.text(.saveProject), symbol: "square.and.arrow.down") { [weak self] in
                let project = self?.project
                Task { await project?.save() }
            },
            ActionButton(L10n.text(.addExplorer), symbol: "plus") { [weak self] in self?.addPane() },
            ActionButton(L10n.text(.addWindow), symbol: "macwindow.badge.plus", action: newWindow),
            ActionButton(L10n.text(.newProcess), symbol: "square.on.square", action: newInstance),
            ActionButton(L10n.text(.tileColumns), symbol: "rectangle.split.2x1") { [weak self] in self?.arrange(.columns) },
            ActionButton(L10n.text(.tileRows), symbol: "rectangle.split.1x2") { [weak self] in self?.arrange(.rows) },
            ActionButton(L10n.text(.cascade), symbol: "square.3.layers.3d") { [weak self] in self?.arrange(.cascade) },
        ]
        for button in toolbar { button.toolTip = button.title }
        for button in toolbar { root.addSubview(button) }
        shelf.documentView = shelfContent
        shelf.hasHorizontalScroller = true
        shelf.autohidesScrollers = true
        shelf.drawsBackground = false
        root.addSubview(shelf)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        root.addSubview(hint)
        layoutWorkspace()
        for directory in directories { addPane(directory: directory) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func addPane(directory: URL? = nil) {
        guard state.panes.count < ProjectDocument.maximumPanes else { NSSound.beep(); return }
        finishGeometry()
        let url = directory ?? activeBrowser?.directory ?? FileManager.default.homeDirectoryForCurrentUser
        let id = state.add(directory: url, canvas: canvasSize)
        installPane(state.panes.first { $0.id == id }!, settings: .init())
        render(); activeBrowser?.focusFiles(); changed()
    }

    private func installPane(_ model: ExplorerPane, settings: BrowserSettings) {
        let id = model.id
        let browser = ExplorerBrowserController(paneID: id, directory: model.directory, settings: settings)
        browser.fileOperations = fileOperations
        browsers[id] = browser
        browser.onLoadFinished = { [weak self] in self?.onDirectoryLoaded?() }
        browser.onLocationChange = { [weak self] url in
            guard let self else { return }
            let old = self.state.panes.first { $0.id == id }?.directory
            self.state.setDirectory(url, for: id)
            self.render()
            if old != url { self.changed() }
        }
        browser.onSettingsChange = { [weak self] in self?.changed() }
        browser.onSessionChange = { [weak self] in self?.onSessionChange?() }
        browser.onOpenInNewPane = { [weak self] url in self?.addPane(directory: url) }
        let pane = PaneChrome(id: id, browser: browser,
                              minimize: { [weak self] in self?.minimize(id) },
                              maximize: { [weak self] in self?.maximize(id) },
                              close: { [weak self] in self?.closePane(id) })
        chrome[id] = pane
        pane.titleBar.onBegin = { [weak self] in self?.beginDrag(id) }
        pane.titleBar.onDrag = { [weak self] dx, dy in self?.drag(id, dx: dx, dy: dy, resizing: false) }
        pane.titleBar.onDoubleClick = { [weak self] in self?.maximize(id) }
        pane.titleBar.onKeyboardAction = { [weak self] in self?.activate(id); self?.beginGeometry(resizing: false) }
        pane.grip.onBegin = { [weak self] in self?.beginDrag(id) }
        pane.grip.onDrag = { [weak self] dx, dy in self?.drag(id, dx: dx, dy: dy, resizing: true) }
        pane.grip.onKeyboardAction = { [weak self] in self?.activate(id); self?.beginGeometry(resizing: true) }
        canvas.addSubview(pane)
    }

    func activate(_ id: UUID, focus: Bool = true) {
        let previous = state.activePaneID
        if state.activePaneID != id { finishGeometry() }
        state.activate(id)
        render()
        if focus { activeBrowser?.focusFiles() }
        if previous != id { changed() }
    }

    func activatePane(atWindowPoint point: NSPoint) {
        let canvasPoint = canvas.convert(point, from: nil)
        guard canvas.bounds.contains(canvasPoint) else { return }
        for id in state.zOrder.reversed() {
            if let view = chrome[id], !view.isHidden, view.frame.contains(canvasPoint) {
                if state.activePaneID != id { activate(id, focus: false) }
                return
            }
        }
    }

    func closeActivePane() { if let id = state.activePaneID { closePane(id) } }

    func closePane(_ id: UUID) {
        if fileOperations?.isBusy == true { fileOperations?.explainPendingOperation(in: window); return }
        finishGeometry()
        browsers[id]?.stop()
        browsers.removeValue(forKey: id)
        chrome.removeValue(forKey: id)?.removeFromSuperview()
        state.close(id)
        render()
        activeBrowser?.focusFiles()
        changed()
    }

    func minimizeActivePane() { if let id = state.activePaneID { minimize(id) } }
    func maximizeActivePane() { if let id = state.activePaneID { maximize(id) } }

    private func minimize(_ id: UUID) {
        finishGeometry()
        state.minimize(id)
        render()
        activeBrowser?.focusFiles()
        changed()
    }

    private func maximize(_ id: UUID) {
        finishGeometry()
        state.toggleMaximize(id)
        render()
        activeBrowser?.focusFiles()
        changed()
    }

    func cycle(backward: Bool = false) {
        finishGeometry()
        let previous = state.activePaneID
        state.cycle(backward: backward)
        render()
        activeBrowser?.focusFiles()
        if previous != state.activePaneID { changed() }
    }

    func arrange(_ arrangement: Arrangement) {
        finishGeometry()
        state.arrange(arrangement, canvas: canvasSize)
        render()
        changed()
    }

    func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = activeBrowser?.directory
        panel.prompt = L10n.text(.open)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if let browser = self.activeBrowser { browser.navigate(to: url) }
            else { self.addPane(directory: url) }
        }
    }

    private func beginDrag(_ id: UUID) {
        activate(id, focus: false)
        guard let pane = state.activePane, pane.presentation != .maximized else { dragStart = nil; return }
        dragStart = pane.normalFrame.resolved(in: canvasSize)
    }

    private func drag(_ id: UUID, dx: CGFloat, dy: CGFloat, resizing: Bool) {
        guard var frame = dragStart else { return }
        if resizing { frame.width += dx; frame.height += dy }
        else { frame.x += dx; frame.y += dy }
        state.setFrame(frame, for: id, canvas: canvasSize)
        layoutPanes()
        changed()
    }

    func beginGeometry(resizing: Bool) {
        guard let pane = state.activePane else { return }
        if pane.presentation == .maximized { state.toggleMaximize(pane.id); changed() }
        geometryMode = (pane.id, resizing, pane.normalFrame.resolved(in: canvasSize))
        window?.makeFirstResponder(nil)
        hint.stringValue = L10n.text(resizing ? .resizeHint : .moveHint)
        render()
    }

    func handleGeometryKey(_ event: NSEvent) -> Bool {
        guard let mode = geometryMode, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if event.keyCode == 53 {
            state.setFrame(mode.original, for: mode.id, canvas: canvasSize)
            finishGeometry()
            render()
            changed()
            return true
        }
        if event.keyCode == 36 { finishGeometry(); activeBrowser?.focusFiles(); return true }
        guard [123, 124, 125, 126].contains(event.keyCode), var frame = state.activePane?.normalFrame.resolved(in: canvasSize) else { return false }
        let step: Double = event.modifierFlags.contains(.shift) ? 48 : 12
        let dx: Double = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
        let dy: Double = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
        if mode.resizing { frame.width += dx; frame.height += dy }
        else { frame.x += dx; frame.y += dy }
        state.setFrame(frame, for: mode.id, canvas: canvasSize)
        layoutPanes()
        changed()
        return true
    }

    private func finishGeometry() { geometryMode = nil; hint.stringValue = "" }

    private func layoutWorkspace() {
        let width = root.bounds.width
        let height = root.bounds.height
        // Measure full labels before choosing the compact layout, so resizing restores them.
        for (index, button) in toolbar.enumerated() { button.imagePosition = index < 2 ? .imageOnly : .imageLeading }
        let naturalWidths = toolbar.map { $0.imagePosition == .imageOnly ? CGFloat(32) : max(72, $0.intrinsicContentSize.width + 4) }
        let compact = naturalWidths.reduce(0, +) + CGFloat(toolbar.count - 1) * 6 > width - 16
        var x: CGFloat = 8
        for (index, button) in toolbar.enumerated() {
            if compact { button.imagePosition = .imageOnly }
            let buttonWidth = compact ? 32 : naturalWidths[index]
            button.frame = NSRect(x: x, y: 8, width: buttonWidth, height: 28)
            x += buttonWidth + 6
        }
        canvas.frame = NSRect(x: 6, y: 44, width: max(1, width - 12), height: max(1, height - 82))
        canvas.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        shelf.frame = NSRect(x: 8, y: height - 33, width: max(0, width - 16), height: 29)
        hint.frame = NSRect(x: 10, y: height - 30, width: max(0, width - 20), height: 20)
        layoutPanes()
    }

    private func layoutPanes() {
        emptyMessage.frame = NSRect(x: 0, y: canvas.bounds.midY - 12, width: canvas.bounds.width, height: 24)
        for pane in state.panes {
            guard let view = chrome[pane.id] else { continue }
            let frame = pane.presentation == .maximized
                ? PaneFrame(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height)
                : pane.normalFrame.resolved(in: canvasSize)
            view.frame = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        }
    }

    private func render() {
        for id in state.zOrder {
            guard let pane = state.panes.first(where: { $0.id == id }), let view = chrome[id] else { continue }
            view.isHidden = pane.presentation == .minimized
            view.update(pane, active: state.activePaneID == id)
            canvas.addSubview(view, positioned: .above, relativeTo: nil)
        }
        emptyMessage.isHidden = state.panes.contains { $0.presentation != .minimized }
        let minimized = state.panes.filter { $0.presentation == .minimized }
        if minimized.map(\.id) != shelfIDs {
            shelfIDs = minimized.map(\.id)
            shelfContent.subviews.forEach { $0.removeFromSuperview() }
            for (index, pane) in minimized.enumerated() {
                let button = ActionButton(pane.directory.lastPathComponent, symbol: "macwindow") { [weak self] in self?.activate(pane.id) }
                button.frame = NSRect(x: CGFloat(index) * 172, y: 0, width: 166, height: 25)
                button.toolTip = L10n.format(.restorePane, pane.directory.lastPathComponent)
                shelfContent.addSubview(button)
            }
            shelfContent.frame = NSRect(x: 0, y: 0, width: CGFloat(minimized.count) * 172, height: 26)
        }
        shelf.isHidden = geometryMode != nil || minimized.isEmpty
        hint.isHidden = geometryMode == nil
        layoutPanes()
    }

    func windowWillClose(_ notification: Notification) {
        project?.release()
        browsers.values.forEach { $0.stop() }
        browsers.removeAll()
        chrome.removeAll()
        onClose?()
    }

    func stopLoading() { browsers.values.forEach { $0.stop() } }

    var readyPaneItemCounts: [Int] { state.panes.compactMap { browsers[$0.id]?.readyItemCount } }

    func reloadBrowsers() { browsers.values.forEach { $0.reload() } }

    private func changed() { if !suppressChanges { project?.changed() } }

    func snapshot(name: String) -> ProjectDocument {
        var document = ProjectDocument(name: name, workspace: state)
        for i in document.panes.indices {
            document.panes[i].settings = browsers[document.panes[i].id]?.savedSettings ?? .init()
        }
        if let f = window?.frame { document.windowFrame = PaneFrame(x: f.minX, y: f.minY, width: f.width, height: f.height) }
        return document
    }

    var browserSessions: [RecoveryPane] {
        state.panes.compactMap { pane in browsers[pane.id].map { RecoveryPane(id: pane.id, state: $0.savedSession) } }
    }

    func restoreBrowserSessions(_ sessions: [RecoveryPane]) throws {
        // Validate all before applying any, including IDs and current folder consistency.
        try RecoveryWorkspace(document: snapshot(name: "Recovery"), sourceURL: nil, browserStates: sessions).validate()
        for session in sessions { try browsers[session.id]?.restoreSession(session.state) }
    }

    func restore(_ document: ProjectDocument) throws {
        let restored = try Workspace(project: document)
        suppressChanges = true
        defer { suppressChanges = false }
        finishGeometry()
        stopLoading()
        chrome.values.forEach { $0.removeFromSuperview() }
        browsers.removeAll(); chrome.removeAll()
        state = restored
        if let saved = document.windowFrame, let screen = NSScreen.screens.max(by: {
            $0.visibleFrame.intersection(NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)).width <
            $1.visibleFrame.intersection(NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)).width
        }) {
            let available = screen.visibleFrame
            let width = min(available.width, max(760, saved.width)), height = min(available.height, max(480, saved.height))
            let x = min(max(available.minX, saved.x), available.maxX - width)
            let y = min(max(available.minY, saved.y), available.maxY - height)
            window?.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
        for (pane, saved) in zip(state.panes, document.panes) { installPane(pane, settings: saved.settings) }
        render(); activeBrowser?.focusFiles()
        lastWindowFrame = window?.frame
    }

    func windowDidMove(_ notification: Notification) { frameChanged() }
    func windowDidResize(_ notification: Notification) { frameChanged() }
    private func frameChanged() {
        let previous = lastWindowFrame
        lastWindowFrame = window?.frame
        if let previous, previous != lastWindowFrame { changed() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if fileOperations?.isBusy == true {
            fileOperations?.explainPendingOperation(in: sender)
            return false
        }
        if closeApproved { return true }
        guard let project else { return true }
        Task { [weak self] in
            guard await project.confirmDiscardingChanges(), let self else { return }
            self.closeApproved = true
            self.window?.performClose(nil)
        }
        return false
    }
}
