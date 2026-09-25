import AppKit
import ExplorerCore
import ExplorerPlatform

@MainActor
final class ExplorerBrowserController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let paneID: UUID
    private(set) var directory: URL
    var onLocationChange: ((URL) -> Void)?
    var onLoadFinished: (() -> Void)?
    private var history = NavigationHistory()
    private var entries: [FileEntry] = []
    private var visibleEntries: [FileEntry] = []
    private var loadTask: Task<Void, Never>?
    private var generation = UUID()
    private(set) var loading = false
    private var errorMessage: String?
    private let root = LayoutView()
    let address = NSTextField()
    let search = NSSearchField()
    let table = FileTableView()
    private let scroll = NSScrollView()
    private let sidebar = FlippedView()
    private let status = NSTextField(labelWithString: "")
    private let hiddenToggle = NSButton(checkboxWithTitle: "隠し項目", target: nil, action: nil)
    private var navButtons: [NSButton] = []
    private var places: [NSButton] = []
    private var showHidden = false
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    enum Navigation { case visit, back, forward, reload }

    init(paneID: UUID, directory: URL) {
        self.paneID = paneID
        self.directory = directory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { loadTask?.cancel() }

    override func loadView() {
        view = root
        root.onLayout = { [weak self] in self?.layoutContents() }
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        navButtons = [
            ActionButton("戻る", symbol: "chevron.left") { [weak self] in self?.goBack() },
            ActionButton("進む", symbol: "chevron.right") { [weak self] in self?.goForward() },
            ActionButton("上へ", symbol: "arrow.up") { [weak self] in self?.goUp() },
            ActionButton("更新", symbol: "arrow.clockwise") { [weak self] in self?.reload() },
        ]
        for button in navButtons {
            button.toolTip = button.title
            button.imagePosition = .imageOnly
            root.addSubview(button)
        }
        address.font = .systemFont(ofSize: 12)
        address.placeholderString = "フォルダのパス"
        address.target = self
        address.action = #selector(enteredAddress)
        address.setAccessibilityLabel("フォルダのパス")
        address.setAccessibilityIdentifier("address-\(paneID)")
        root.addSubview(address)
        search.placeholderString = "このフォルダ内を検索"
        search.setAccessibilityLabel("このフォルダ内を検索")
        search.delegate = self
        root.addSubview(search)
        hiddenToggle.target = self
        hiddenToggle.action = #selector(toggleHidden)
        hiddenToggle.font = .systemFont(ofSize: 11)
        root.addSubview(hiddenToggle)

        let columns: [(String, String, CGFloat)] = [
            ("name", "名前", 240), ("modified", "更新日時", 140), ("kind", "種類", 100), ("size", "サイズ", 80),
        ]
        for (key, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.width = width
            column.minWidth = 60
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
        table.setAccessibilityLabel("ファイル一覧")
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        root.addSubview(scroll)

        let home = FileManager.default.homeDirectoryForCurrentUser
        let shortcuts: [(String, String, URL)] = [
            ("ホーム", "house", home),
            ("ダウンロード", "arrow.down.circle", home.appendingPathComponent("Downloads", isDirectory: true)),
            ("コンピュータ", "internaldrive", URL(fileURLWithPath: "/", isDirectory: true)),
            ("ボリューム", "externaldrive", URL(fileURLWithPath: "/Volumes", isDirectory: true)),
        ]
        for (name, icon, url) in shortcuts {
            let button = ActionButton(name, symbol: icon) { [weak self] in self?.navigate(to: url) }
            button.isBordered = false
            button.alignment = .left
            sidebar.addSubview(button)
            places.append(button)
        }
        root.addSubview(sidebar)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        root.addSubview(status)
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
        hiddenToggle.frame = NSRect(x: 8, y: 38, width: 96, height: 24)
        search.frame = NSRect(x: 111, y: 39, width: max(60, width - 119), height: 24)
        let sidebarWidth: CGFloat = width >= 540 ? 125 : 0
        sidebar.isHidden = sidebarWidth == 0
        sidebar.frame = NSRect(x: 5, y: 70, width: sidebarWidth, height: max(0, height - 96))
        for (i, button) in places.enumerated() { button.frame = NSRect(x: 0, y: CGFloat(i) * 29, width: 124, height: 27) }
        scroll.frame = NSRect(x: 5 + sidebarWidth, y: 70, width: max(0, width - sidebarWidth - 10), height: max(0, height - 96))
        status.frame = NSRect(x: 8, y: max(0, height - 23), width: max(0, width - 32), height: 18)
    }

    func navigate(to url: URL, via navigation: Navigation = .visit) {
        guard url.isFileURL else { return }
        loadTask?.cancel()
        let request = UUID()
        generation = request
        loading = true
        errorMessage = nil
        status.stringValue = "読み込み中…"
        address.stringValue = url.path
        let includeHidden = showHidden
        loadTask = Task { [weak self] in
            do {
                let result = try await DirectoryReader.read(url, showHidden: includeHidden)
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.entries = result
                self.directory = url
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
                self.onLoadFinished?()
            } catch {
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.loading = false
                self.errorMessage = "開けません: \(error.localizedDescription)"
                self.address.stringValue = self.directory.path
                self.updateStatus()
                self.onLoadFinished?()
            }
        }
    }

    func stop() { loadTask?.cancel(); loadTask = nil }
    func reload() { navigate(to: directory, via: history.current == nil ? .visit : .reload) }
    func goBack() { if let url = history.back { navigate(to: url, via: .back) } }
    func goForward() { if let url = history.forward { navigate(to: url, via: .forward) } }
    func goUp() { navigate(to: directory.deletingLastPathComponent()) }
    func focusAddress() { view.window?.makeFirstResponder(address); address.selectText(nil) }
    func focusSearch() { view.window?.makeFirstResponder(search) }
    func focusFiles() { view.window?.makeFirstResponder(table) }

    func cycleFocus(backward: Bool = false) {
        let editor = view.window?.firstResponder as? NSTextView
        if editor?.delegate === address { backward ? focusFiles() : focusSearch() }
        else if editor?.delegate === search { backward ? focusAddress() : focusFiles() }
        else { backward ? focusSearch() : focusAddress() }
    }

    @objc private func enteredAddress() {
        let path = (address.stringValue as NSString).expandingTildeInPath
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : directory.appendingPathComponent(path, isDirectory: true)
        navigate(to: url.standardizedFileURL)
    }

    @objc private func toggleHidden() { showHidden = hiddenToggle.state == .on; reload() }

    @objc func openSelected() {
        guard visibleEntries.indices.contains(table.selectedRow) else { return }
        let item = visibleEntries[table.selectedRow]
        if item.isBrowsable { navigate(to: item.url) }
        else { NSWorkspace.shared.open(item.url) }
    }

    func controlTextDidChange(_ obj: Notification) { if obj.object as? NSSearchField === search { applyFilterAndSort() } }

    private func applyFilterAndSort() {
        let selection = Set(table.selectedRowIndexes.compactMap { visibleEntries.indices.contains($0) ? visibleEntries[$0].url : nil })
        let query = search.stringValue
        visibleEntries = entries.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
        let descriptor = table.sortDescriptors.first
        let key = descriptor?.key ?? "name"
        let ascending = descriptor?.ascending ?? true
        visibleEntries.sort { lhs, rhs in
            if lhs.isBrowsable != rhs.isBrowsable { return lhs.isBrowsable }
            let comparison: ComparisonResult
            switch key {
            case "size": comparison = (lhs.size ?? 0) == (rhs.size ?? 0) ? .orderedSame : ((lhs.size ?? 0) < (rhs.size ?? 0) ? .orderedAscending : .orderedDescending)
            case "modified": comparison = (lhs.modified ?? .distantPast).compare(rhs.modified ?? .distantPast)
            case "kind": comparison = lhs.kind.localizedStandardCompare(rhs.kind)
            default: comparison = lhs.name.localizedStandardCompare(rhs.name)
            }
            if comparison == .orderedSame { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        table.reloadData()
        table.selectRowIndexes(IndexSet(visibleEntries.indices.filter { selection.contains(visibleEntries[$0].url) }), byExtendingSelection: false)
        updateStatus()
    }

    private func updateStatus() {
        status.stringValue = errorMessage ?? "\(visibleEntries.count) 項目" + (table.numberOfSelectedRows > 0 ? " · \(table.numberOfSelectedRows) 項目を選択" : "")
        status.toolTip = status.stringValue
        status.textColor = errorMessage == nil ? .secondaryLabelColor : .systemRed
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleEntries.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateStatus() }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { applyFilterAndSort() }

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
        case "size": cell.textField?.stringValue = item.isDirectory ? "—" : item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        default: break
        }
        return cell
    }
}
