import AppKit
import ExplorerPlatform

@MainActor
private final class FolderNode {
    let url: URL?
    var name: String
    var children: [FolderNode]?
    var task: Task<Void, Never>?
    init(_ url: URL?, name: String? = nil) { self.url = url; self.name = name ?? url?.lastPathComponent ?? "読み込み中…" }
    deinit { task?.cancel() }
}

@MainActor
final class FolderTreeController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private var roots: [FolderNode] = []
    private var expanded: Set<URL> = []
    private var favorites: [URL] = []
    private var hidden = false
    private var reloading = false
    var onNavigate: ((URL) -> Void)?
    var onExpandedChange: (([URL]) -> Void)?

    override func loadView() {
        view = scroll
        let column = NSTableColumn(identifier: .init("folder"))
        column.width = 180
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 25
        outline.indentationPerLevel = 12
        outline.dataSource = self; outline.delegate = self
        outline.setAccessibilityLabel("フォルダツリー")
        scroll.documentView = outline
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
    }

    func configure(expanded urls: [URL], favorites: [URL], showHidden: Bool) {
        _ = view
        stop()
        expanded = Set(urls); self.favorites = favorites; hidden = showHidden
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots = [FolderNode(home, name: "ホーム"), FolderNode(home.appendingPathComponent("Downloads"), name: "ダウンロード")]
        roots += favorites.map { FolderNode($0, name: "★ " + $0.lastPathComponent) }
        roots += [FolderNode(URL(fileURLWithPath: "/"), name: "コンピュータ"), FolderNode(URL(fileURLWithPath: "/Volumes"), name: "ボリューム")]
        reloading = true
        outline.reloadData()
        restoreExpansion(roots)
        reloading = false
    }

    func stop() {
        func cancel(_ nodes: [FolderNode]) { for node in nodes { node.task?.cancel(); node.task = nil; cancel(node.children ?? []) } }
        cancel(roots)
    }

    func refresh(_ url: URL) {
        func visit(_ nodes: [FolderNode]) {
            for node in nodes {
                if node.url?.standardizedFileURL == url.standardizedFileURL, outline.isItemExpanded(node) { load(node) }
                else { visit(node.children ?? []) }
            }
        }
        visit(roots)
    }

    private func restoreExpansion(_ nodes: [FolderNode]) {
        for node in nodes where node.url.map(expanded.contains) == true { outline.expandItem(node) }
    }

    private func load(_ node: FolderNode) {
        guard let url = node.url else { return }
        node.task?.cancel()
        if node.children == nil { node.children = [FolderNode(nil)] }
        let showHidden = hidden
        node.task = Task { [weak self, weak node] in
            do {
                let entries = try await DirectoryReader.read(url, showHidden: showHidden)
                guard !Task.isCancelled, let self, let node else { return }
                let old = Dictionary((node.children ?? []).compactMap { child in child.url.map { ($0, child) } }, uniquingKeysWith: { a, _ in a })
                node.children = entries.filter(\.isBrowsable).map { old[$0.url] ?? FolderNode($0.url) }
                self.reloading = true
                self.outline.reloadItem(node, reloadChildren: true)
                self.restoreExpansion(node.children ?? [])
                self.reloading = false
                node.task = nil
            } catch {
                guard !Task.isCancelled, let self, let node else { return }
                node.children = [FolderNode(nil, name: "開けません（再展開で更新）")]
                self.outline.reloadItem(node, reloadChildren: true)
                node.task = nil
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? FolderNode)?.children?.count ?? (item == nil ? roots.count : 1) }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FolderNode {
            if node.children == nil { node.children = [FolderNode(nil)] }
            return node.children![index]
        }
        return roots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FolderNode)?.url != nil }
    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FolderNode, let url = node.url else { return }
        expanded.insert(url)
        load(node)
        if !reloading { changed() }
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !reloading, let node = notification.userInfo?["NSObject"] as? FolderNode, let url = node.url else { return }
        func release(_ node: FolderNode) {
            node.task?.cancel(); node.task = nil
            if let url = node.url { expanded.remove(url) }
            node.children?.forEach(release)
            node.children = nil
        }
        release(node)
        expanded.remove(url)
        changed()
    }
    private func changed() { onExpandedChange?(Array(expanded).sorted { $0.path < $1.path }.prefix(256).map { $0 }) }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, let node = outline.item(atRow: outline.selectedRow) as? FolderNode, let url = node.url else { return }
        onNavigate?(url)
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? FolderNode)?.url != nil }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("folderCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label); cell.textField = label
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        cell.textField?.stringValue = node.name
        cell.textField?.textColor = node.url == nil ? .secondaryLabelColor : .labelColor
        cell.toolTip = node.url?.path
        return cell
    }
}
