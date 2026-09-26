import AppKit
import ExplorerCore
import ExplorerPlatform

@MainActor
final class ExplorerBrowserController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let paneID: UUID
    private(set) var directory: URL
    var onLocationChange: ((URL) -> Void)?
    var onLoadFinished: (() -> Void)?
    var onSettingsChange: (() -> Void)?
    var onOpenInNewPane: ((URL) -> Void)?
    private var settings: BrowserSettings
    private var history = NavigationHistory()
    private var entries: [FileEntry] = []
    private var visibleEntries: [FileEntry] = []
    private var loadTask: Task<Void, Never>?
    private var projectionTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var watchedURL: URL?
    private var projectionGeneration = UUID()
    private var generation = UUID()
    private(set) var loading = false
    private var errorMessage: String?
    private let root = LayoutView()
    let address = NSTextField()
    let search = NSSearchField()
    let table = FileTableView()
    private let scroll = NSScrollView()
    private let tree = FolderTreeController()
    private let divider = DragHandle()
    private let breadcrumb = NSPathControl()
    private var originalTreeWidth: Double = 160
    private var configuring = true
    private let status = NSTextField(labelWithString: "")
    private let hiddenToggle = NSButton(checkboxWithTitle: L10n.text(.hiddenItems), target: nil, action: nil)
    private var navButtons: [NSButton] = []
    private var watchWarning: String?
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    enum Navigation { case visit, back, forward, reload }

    init(paneID: UUID, directory: URL, settings: BrowserSettings = .init()) {
        self.paneID = paneID
        self.directory = directory
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { loadTask?.cancel(); projectionTask?.cancel(); watchTask?.cancel(); refreshTask?.cancel() }

    override func loadView() {
        view = root
        root.onLayout = { [weak self] in self?.layoutContents() }
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        navButtons = [
            ActionButton(L10n.text(.back), symbol: "chevron.left") { [weak self] in self?.goBack() },
            ActionButton(L10n.text(.forward), symbol: "chevron.right") { [weak self] in self?.goForward() },
            ActionButton(L10n.text(.up), symbol: "arrow.up") { [weak self] in self?.goUp() },
            ActionButton(L10n.text(.refresh), symbol: "arrow.clockwise") { [weak self] in self?.reload() },
        ]
        for button in navButtons {
            button.toolTip = button.title
            button.imagePosition = .imageOnly
            root.addSubview(button)
        }
        address.font = .systemFont(ofSize: 12)
        address.placeholderString = L10n.text(.folderPath)
        address.target = self
        address.action = #selector(enteredAddress)
        address.setAccessibilityLabel(L10n.text(.folderPath))
        address.setAccessibilityIdentifier("address-\(paneID)")
        root.addSubview(address)
        search.placeholderString = L10n.text(.searchFolder)
        search.setAccessibilityLabel(L10n.text(.searchFolder))
        search.delegate = self
        search.stringValue = settings.filter
        root.addSubview(search)
        hiddenToggle.target = self
        hiddenToggle.action = #selector(toggleHidden)
        hiddenToggle.font = .systemFont(ofSize: 11)
        hiddenToggle.state = settings.showHidden ? .on : .off
        root.addSubview(hiddenToggle)

        let columns: [(String, String, CGFloat)] = [
            ("name", L10n.text(.columnName), 240), ("modified", L10n.text(.columnModified), 140), ("kind", L10n.text(.columnKind), 100), ("size", L10n.text(.columnSize), 80),
        ]
        for stored in settings.columns {
            guard let (key, title, _) = columns.first(where: { $0.0 == stored.column.rawValue }) else { continue }
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.width = stored.width
            column.minWidth = 60
            column.maxWidth = 2_400
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(column)
        }
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onOpen = { [weak self] in self?.openSelected() }
        table.onBack = { [weak self] in self?.goBack() }
        table.setAccessibilityLabel(L10n.text(.fileList))
        table.sortDescriptors = [NSSortDescriptor(key: settings.sortColumn.rawValue, ascending: settings.ascending)]
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        root.addSubview(scroll)

        breadcrumb.pathStyle = .standard
        breadcrumb.isEditable = false
        breadcrumb.target = self
        breadcrumb.action = #selector(clickedBreadcrumb)
        breadcrumb.doubleAction = #selector(clickedBreadcrumb)
        breadcrumb.url = directory
        breadcrumb.setAccessibilityLabel(L10n.text(.breadcrumbs))
        root.addSubview(breadcrumb)
        addChild(tree)
        root.addSubview(tree.view)
        tree.onNavigate = { [weak self] url in self?.navigate(to: url) }
        tree.onExpandedChange = { [weak self] urls in self?.settings.expandedDirectories = urls; self?.onSettingsChange?() }
        tree.configure(expanded: settings.expandedDirectories, favorites: settings.favorites, showHidden: settings.showHidden)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.setAccessibilityElement(true)
        divider.setAccessibilityRole(.button)
        divider.setAccessibilityLabel(L10n.text(.resizeTree))
        divider.onBegin = { [weak self] in self?.originalTreeWidth = self?.settings.treeWidth ?? 160 }
        divider.onDrag = { [weak self] dx, _ in
            guard let self else { return }
            self.settings.treeWidth = min(500, max(100, self.originalTreeWidth + dx))
            self.layoutContents(); self.onSettingsChange?()
        }
        divider.onKeyboardAction = { [weak self] in
            guard let self else { return }
            self.settings.treeWidth = self.settings.treeWidth >= 300 ? 100 : self.settings.treeWidth + 50
            self.layoutContents(); self.onSettingsChange?()
        }
        root.addSubview(divider)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        root.addSubview(status)
        configuring = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigate(to: directory)
    }

    private func layoutContents() {
        let width = root.bounds.width
        let height = root.bounds.height
        for i in 0..<3 { navButtons[i].frame = NSRect(x: 5 + CGFloat(i) * 29, y: 5, width: 27, height: 27) }
        navButtons[3].frame = NSRect(x: width - 34, y: 5, width: 28, height: 27)
        address.frame = NSRect(x: 95, y: 7, width: max(40, width - 134), height: 24)
        let hiddenWidth = max(96, hiddenToggle.intrinsicContentSize.width)
        hiddenToggle.frame = NSRect(x: 8, y: 38, width: hiddenWidth, height: 24)
        search.frame = NSRect(x: hiddenWidth + 23, y: 39, width: max(60, width - hiddenWidth - 31), height: 24)
        breadcrumb.frame = NSRect(x: 7, y: 68, width: max(0, width - 14), height: 22)
        let sidebarWidth: CGFloat = width >= 500 ? min(settings.treeWidth, width * 0.42) : 0
        tree.view.isHidden = sidebarWidth == 0
        divider.isHidden = sidebarWidth == 0
        tree.view.frame = NSRect(x: 5, y: 95, width: sidebarWidth, height: max(0, height - 121))
        divider.frame = NSRect(x: 5 + sidebarWidth, y: 95, width: 5, height: max(0, height - 121))
        scroll.frame = NSRect(x: 10 + sidebarWidth, y: 95, width: max(0, width - sidebarWidth - 15), height: max(0, height - 121))
        status.frame = NSRect(x: 8, y: max(0, height - 23), width: max(0, width - 32), height: 18)
    }

    func navigate(to url: URL, via navigation: Navigation = .visit) {
        guard url.isFileURL else { return }
        loadTask?.cancel()
        let request = UUID()
        generation = request
        loading = true
        errorMessage = nil
        status.stringValue = L10n.text(.loading)
        address.stringValue = url.path
        let includeHidden = settings.showHidden
        loadTask = Task { [weak self] in
            do {
                await self?.watch(url)
                let result = try await DirectoryReader.read(url, showHidden: includeHidden)
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.entries = result
                self.directory = url
                self.breadcrumb.url = url
                switch navigation {
                case .visit: self.history.visit(url)
                case .back: self.history.goBack()
                case .forward: self.history.goForward()
                case .reload: break
                }
                self.loading = false
                self.navButtons[0].isEnabled = self.history.back != nil
                self.navButtons[1].isEnabled = self.history.forward != nil
                self.applyFilterAndSort()
                self.onLocationChange?(url)
                self.tree.refresh(url)
            } catch {
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.loading = false
                self.errorMessage = Self.locationError(error)
                self.address.stringValue = self.directory.path
                self.updateStatus()
                self.onLoadFinished?()
            }
        }
    }

    func stop() {
        loadTask?.cancel(); loadTask = nil
        projectionTask?.cancel(); projectionTask = nil
        watchTask?.cancel(); watchTask = nil
        refreshTask?.cancel(); refreshTask = nil
        watchedURL = nil; tree.stop()
    }
    func reload() { navigate(to: directory, via: history.current == nil ? .visit : .reload) }
    func goBack() { if let url = history.back { navigate(to: url, via: .back) } }
    func goForward() { if let url = history.forward { navigate(to: url, via: .forward) } }
    func goUp() { navigate(to: directory.deletingLastPathComponent()) }
    func focusAddress() { view.window?.makeFirstResponder(address); address.selectText(nil) }
    func focusSearch() { view.window?.makeFirstResponder(search) }
    func focusFiles() { view.window?.makeFirstResponder(table) }

    var savedSettings: BrowserSettings {
        var result = settings
        result.columns = table.tableColumns.compactMap { column in FileColumn(rawValue: column.identifier.rawValue).map { ColumnSettings($0, width: column.width) } }
        return result
    }

    func toggleFavorite() {
        if settings.favorites.contains(directory) { settings.favorites.removeAll { $0 == directory } }
        else if settings.favorites.count < 32 { settings.favorites.append(directory) }
        tree.configure(expanded: settings.expandedDirectories, favorites: settings.favorites, showHidden: settings.showHidden)
        onSettingsChange?()
    }

    func openSelectionInNewPane() {
        guard visibleEntries.indices.contains(table.selectedRow), visibleEntries[table.selectedRow].isBrowsable else { return }
        onOpenInNewPane?(visibleEntries[table.selectedRow].url)
    }

    func cycleFocus(backward: Bool = false) {
        let editor = view.window?.firstResponder as? NSTextView
        if editor?.delegate === address { backward ? focusFiles() : focusSearch() }
        else if editor?.delegate === search { backward ? focusAddress() : focusTreeOrFiles() }
        else if view.window?.firstResponder === tree.outline { backward ? focusSearch() : focusFiles() }
        else if backward {
            if tree.view.isHidden { focusSearch() } else { focusTreeOrFiles() }
        } else { focusAddress() }
    }

    private func focusTreeOrFiles() {
        if tree.view.isHidden { focusFiles() } else { view.window?.makeFirstResponder(tree.outline) }
    }

    @objc private func clickedBreadcrumb() {
        if let url = breadcrumb.clickedPathItem?.url ?? breadcrumb.url { navigate(to: url) }
    }

    @objc private func enteredAddress() {
        let path = (address.stringValue as NSString).expandingTildeInPath
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : directory.appendingPathComponent(path, isDirectory: true)
        navigate(to: url.standardizedFileURL)
    }

    @objc private func toggleHidden() {
        settings.showHidden = hiddenToggle.state == .on
        tree.configure(expanded: settings.expandedDirectories, favorites: settings.favorites, showHidden: settings.showHidden)
        onSettingsChange?(); reload()
    }

    @objc func openSelected() {
        guard !loading, visibleEntries.indices.contains(table.selectedRow) else { return }
        let item = visibleEntries[table.selectedRow]
        if item.isBrowsable { navigate(to: item.url) }
        else if !NSWorkspace.shared.open(item.url) { errorMessage = L10n.text(.openFileFailed); updateStatus() }
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === search {
            settings.filter = String(search.stringValue.prefix(1_024))
            applyFilterAndSort(); onSettingsChange?()
        }
    }

    private func applyFilterAndSort() {
        let selection = Set(table.selectedRowIndexes.compactMap { visibleEntries.indices.contains($0) ? visibleEntries[$0].url : nil })
        projectionTask?.cancel()
        let request = UUID(); projectionGeneration = request
        let input = entries, options = settings
        projectionTask = Task { [weak self] in
            guard let result = try? await DirectoryReader.project(input, settings: options), !Task.isCancelled,
                  let self, self.projectionGeneration == request else { return }
            self.visibleEntries = result
            self.table.reloadData()
            self.table.selectRowIndexes(IndexSet(result.indices.filter { selection.contains(result[$0].url) }), byExtendingSelection: false)
            self.updateStatus()
            self.onLoadFinished?()
        }
    }

    private func updateStatus() {
        var parts = [L10n.format(.itemCount, visibleEntries.count)]
        if table.numberOfSelectedRows > 0 { parts.append(L10n.format(.selectedCount, table.numberOfSelectedRows)) }
        if let watchWarning { parts.append(watchWarning) }
        status.stringValue = errorMessage ?? parts.joined(separator: " · ")
        status.toolTip = status.stringValue
        status.textColor = errorMessage == nil ? .secondaryLabelColor : .systemRed
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleEntries.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateStatus() }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !configuring else { return }
        settings.sortColumn = FileColumn(rawValue: table.sortDescriptors.first?.key ?? "name") ?? .name
        settings.ascending = table.sortDescriptors.first?.ascending ?? true
        applyFilterAndSort(); onSettingsChange?()
    }
    func tableViewColumnDidMove(_ notification: Notification) { if !configuring { onSettingsChange?() } }
    func tableViewColumnDidResize(_ notification: Notification) { if !configuring { onSettingsChange?() } }
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        visibleEntries.indices.contains(row) ? visibleEntries[row].name : nil
    }

    private func watch(_ url: URL) async {
        guard watchedURL != url else { return }
        watchTask?.cancel(); watchTask = nil; watchedURL = url
        do {
            let events = try await DirectoryWatchCenter.shared.events(at: url)
            guard !Task.isCancelled else { return }
            watchWarning = nil
            watchTask = Task { [weak self] in
                for await _ in events {
                    guard !Task.isCancelled else { break }
                    self?.scheduleRefresh(for: url)
                }
            }
        } catch { watchedURL = nil; watchWarning = L10n.text(.watchUnavailable) }
    }

    private func scheduleRefresh(for url: URL) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, self.directory == url else { return }
            self.reload()
        }
    }

    private static func locationError(_ error: Error) -> String {
        let ns = error as NSError
        if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError) ||
            (ns.domain == NSPOSIXErrorDomain && [13, 1].contains(ns.code)) { return L10n.text(.folderPermission) }
        if (ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code)) ||
            (ns.domain == NSPOSIXErrorDomain && ns.code == 2) { return L10n.text(.folderMissing) }
        return L10n.format(.openFailed, error.localizedDescription)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, visibleEntries.indices.contains(row) else { return nil }
        let item = visibleEntries[row]
        let identifier = column.identifier
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView { cell = reused }
        else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: identifier.rawValue == "name" ? 26 : 5),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            if identifier.rawValue == "name" {
                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(icon)
                cell.imageView = icon
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
                ])
            }
        }
        switch identifier.rawValue {
        case "name":
            cell.textField?.stringValue = item.name
            cell.imageView?.image = NSImage(systemSymbolName: item.isBrowsable ? "folder.fill" : (item.isPackage ? "shippingbox" : "doc"), accessibilityDescription: nil)
            cell.imageView?.contentTintColor = item.isBrowsable ? .systemBlue : .secondaryLabelColor
        case "modified": cell.textField?.stringValue = item.modified.map { dateFormatter.string(from: $0) } ?? "—"
        case "kind": cell.textField?.stringValue = item.kind
        case "size": cell.textField?.stringValue = item.isDirectory ? "—" : item.size.map { $0.formatted(.byteCount(style: .file).locale(L10n.locale)) } ?? "—"
        default: break
        }
        return cell
    }
}
