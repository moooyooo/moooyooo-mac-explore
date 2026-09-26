import AppKit
import ExplorerCore
import ExplorerPlatform
import UniformTypeIdentifiers

@MainActor
final class WorkspaceProjectController {
    static let fileType = UTType(exportedAs: "io.github.moooyooo.macexplore.project", conformingTo: .json)
    weak var workspace: WorkspaceWindowController?
    private let store: ProjectStore
    private var metadata = ProjectDocument(name: L10n.text(.untitled))
    private(set) var opened: OpenProject?
    private(set) var isDirty = false
    private(set) var isBusy = false
    private var generation: UInt64 = 0
    var changeToken: UInt64 { generation }
    var onChange: (() -> Void)?
    var onSaved: ((URL) -> Void)?
    var url: URL? { opened?.url }
    var isReadOnly: Bool { opened?.isWritable == false }

    init(workspace: WorkspaceWindowController, store: ProjectStore) { self.workspace = workspace; self.store = store; updateTitle() }

    func changed() {
        generation &+= 1; isDirty = true
        updateTitle(); onChange?()
    }

    func snapshot() -> ProjectDocument {
        guard let workspace else { return metadata }
        var document = workspace.snapshot(name: metadata.name)
        document.projectID = metadata.projectID; document.revision = metadata.revision
        for i in document.panes.indices {
            if let previous = metadata.panes.first(where: { $0.id == document.panes[i].id && $0.folder.url == document.panes[i].folder.url }) {
                document.panes[i].folder.bookmark = previous.folder.bookmark
            }
        }
        return document
    }

    func adopt(_ project: OpenProject) throws {
        try workspace?.restore(project.document)
        let previous = opened
        opened = project; metadata = project.document
        generation &+= 1; isDirty = false
        updateTitle(); onChange?()
        if let previous, previous.handleID != project.handleID { Task { await store.close(previous.handleID) } }
    }

    func recover(_ document: ProjectDocument) throws {
        try workspace?.restore(document)
        metadata = document; metadata.projectID = UUID()
        metadata.name = L10n.format(.recoveredName, document.name)
        metadata.name = String(metadata.name.prefix(255))
        opened = nil; changed()
    }

    @discardableResult
    func save(asCopy: Bool = false) async -> Bool {
        guard !isBusy, let window = workspace?.window else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let destination: URL?
            if asCopy || opened == nil || isReadOnly {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [Self.fileType]
                panel.canCreateDirectories = true
                panel.nameFieldStringValue = metadata.name + ".mexplore"
                panel.directoryURL = opened?.url.deletingLastPathComponent()
                panel.title = isReadOnly ? L10n.text(.saveReadOnly) : L10n.text(.saveProject)
                guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return false }
                destination = url
            } else { destination = nil }
            let version = generation
            let document = snapshot()
            let next: OpenProject
            if let destination {
                if let opened, try await store.identity(of: destination) == store.identity(of: opened.url) {
                    next = try await store.save(document, handleID: opened.handleID)
                } else { next = try await store.saveAs(document, to: destination, replacing: true) }
            } else if let opened { next = try await store.save(document, handleID: opened.handleID) }
            else { return false }
            let old = opened
            opened = next; metadata = next.document
            isDirty = version != generation
            updateTitle(); onChange?(); onSaved?(next.url)
            if let old, old.handleID != next.handleID { await store.close(old.handleID) }
            return true
        } catch { await show(error, title: L10n.text(.saveFailed)); return false }
    }

    func confirmDiscardingChanges() async -> Bool {
        guard !isBusy else { return false }
        guard isDirty, let window = workspace?.window else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.text(.saveChangesQuestion)
        alert.informativeText = L10n.text(.saveChangesDetail)
        alert.addButton(withTitle: isReadOnly ? L10n.text(.saveAs) : L10n.text(.save))
        alert.addButton(withTitle: L10n.text(.discard))
        alert.addButton(withTitle: L10n.text(.cancel))
        isBusy = true
        let response = await alert.beginSheetModal(for: window)
        isBusy = false
        switch response {
        case .alertFirstButtonReturn: return await save() && !isDirty
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func reacquire() async {
        guard await confirmDiscardingChanges(), let opened else { return }
        isBusy = true
        defer { isBusy = false }
        do { try adopt(await store.reacquire(opened.handleID)) }
        catch { await show(error, title: L10n.text(.reacquireFailed)) }
    }

    func release() {
        if let opened { Task { await store.close(opened.handleID) } }
        opened = nil
    }

    private func updateTitle() {
        guard let window = workspace?.window else { return }
        let title = url?.deletingPathExtension().lastPathComponent ?? metadata.name
        window.title = (isReadOnly ? L10n.format(.readOnlyTitle, title) : title) + " — Moooyooo Mac Explore"
        window.isDocumentEdited = isDirty
        window.representedURL = url
        window.subtitle = opened?.readOnlyReason ?? ""
    }

    private func show(_ error: Error, title: String) async {
        guard let window = workspace?.window else { return }
        let alert = NSAlert(error: error); alert.messageText = title
        await alert.beginSheetModal(for: window)
    }
}
