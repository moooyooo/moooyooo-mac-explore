import AppKit
import ExplorerCore
import ExplorerPlatform

@MainActor
final class FileOperationController: NSObject {
    static let cutType = NSPasteboard.PasteboardType("io.github.moooyooo.MacExplore.cut-request")
    let service: FileOperations
    private let cutStore: CutTransferStore
    private let pasteboard: NSPasteboard
    private var task: Task<Void, Never>?
    private(set) var isBusy = false
    private(set) var undoState: FileUndoState = .empty
    var canUndo: Bool { undoState.canUndo }
    var onChange: (() -> Void)?
    private var panel: NSPanel?
    private let phaseLabel = NSTextField(labelWithString: "")
    private let fileLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private var cancelling = false

    init(supportDirectory: URL? = nil, pasteboard: NSPasteboard = .general) {
        service = FileOperations(supportDirectory: supportDirectory)
        cutStore = CutTransferStore(supportDirectory: supportDirectory)
        self.pasteboard = pasteboard
        super.init()
    }

    static func clipboardURLs(_ pasteboard: NSPasteboard = .general) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return Array(urls.filter(ProjectDocument.isLocalFileURL).prefix(10_001))
    }

    func configureUndoMenuItem(_ item: NSMenuItem) {
        item.title = L10n.text(.undo)
        if isBusy { item.toolTip = L10n.text(.fileOperationWaitDetail); return }
        switch undoState.blockReason {
        case .replacement:
            item.title = L10n.text(.undoReplacementUnavailable)
            item.toolTip = L10n.text(.undoReplacementDetail)
        case .incomplete:
            item.title = L10n.text(.undoIncompleteUnavailable)
            item.toolTip = L10n.text(.undoIncompleteDetail)
        case nil:
            if let kind = undoState.kind, undoState.canUndo {
                let key: L10n.Key = switch kind {
                case .newFolder: .newFolder
                case .rename: .renameItem
                case .copy: .copy
                case .move: .moveAction
                case .trash: .moveToTrash
                }
                item.title = L10n.format(.undoFileAction, L10n.text(key), undoState.itemCount)
                item.toolTip = L10n.text(.undoFileScope)
            } else {
                item.toolTip = L10n.text(.fileUndoUnavailable) + " " + L10n.text(.undoFileScope)
            }
        }
    }

    func canPerform(_ command: AppCommand, in browser: ExplorerBrowserController?) -> Bool {
        guard !isBusy else { return false }
        if command == .undoFiles { return canUndo }
        guard let browser, browser.view.window?.attachedSheet == nil else { return false }
        let selection = browser.selectedURLs
        switch command {
        case .newFolder: return !browser.loading
        case .renameItem: return selection.count == 1
        case .copyFiles, .cutFiles, .trashFiles, .copyPath: return !selection.isEmpty
        case .pasteFiles: return !browser.loading && !Self.clipboardURLs(pasteboard).isEmpty
        default: return true
        }
    }

    func perform(_ command: AppCommand, in browser: ExplorerBrowserController?) {
        guard canPerform(command, in: browser) else { NSSound.beep(); return }
        let window = browser?.view.window
        switch command {
        case .newFolder:
            guard let browser else { return }
            let destination = browser.operationDirectory
            run(title: L10n.text(.newFolder), in: window) { [self, weak browser] in
                guard let name = await requestName(title: .newFolder, detail: L10n.format(.newFolderPrompt, destination.path),
                                                  initial: L10n.text(.newFolder), button: .createItem, in: window) else { return }
                showProgress(title: L10n.text(.newFolder))
                let url = try await service.createFolder(named: name, in: destination)
                browser?.selectAfterReload([url])
            }
        case .renameItem:
            guard let browser, let source = browser.selectedURLs.first else { return }
            run(title: L10n.text(.renameItem), in: window) { [self, weak browser] in
                guard let name = await requestName(title: .renameItem, detail: L10n.format(.renamePrompt, source.lastPathComponent),
                                                  initial: source.lastPathComponent, button: .renameAction, in: window) else { return }
                showProgress(title: L10n.text(.renameItem))
                let url = try await service.rename(source, to: name)
                browser?.selectAfterReload([url])
            }
        case .copyFiles, .cutFiles:
            guard let browser else { return }
            let sources = browser.selectedURLs
            if command == .copyFiles {
                writeClipboard(sources, cutID: nil)
                browser.showOperationStatus(L10n.format(.clipboardCopyStatus, sources.count))
            } else {
                let changeCount = pasteboard.changeCount
                run(title: L10n.text(.cuttingFiles), in: window) { [self, weak browser] in
                    showProgress(title: L10n.text(.cuttingFiles))
                    let id = try await cutStore.create(sources)
                    try Task.checkCancellation()
                    // Do not overwrite a clipboard another app changed during a large scan.
                    guard pasteboard.changeCount == changeCount else { throw CutTransferError.changed }
                    writeClipboard(sources, cutID: id)
                    browser?.showOperationStatus(L10n.format(.clipboardCutStatus, sources.count))
                }
            }
        case .pasteFiles:
            guard let browser else { return }
            let sources = Self.clipboardURLs(pasteboard)
            let token = pasteboard.string(forType: Self.cutType)
            transfer(sources, to: browser.operationDirectory, kind: token == nil ? .copy : .move, cutToken: token, browser: browser)
        case .trashFiles:
            guard let browser else { return }
            let sources = browser.selectedURLs
            run(title: L10n.text(.trashingFiles), in: window) { [self] in
                let alert = NSAlert()
                alert.messageText = L10n.format(.trashConfirm, sources.count)
                alert.informativeText = L10n.text(.trashConfirmDetail) + "\n\n" + sources.prefix(8).map(\.lastPathComponent).joined(separator: "\n")
                alert.addButton(withTitle: L10n.text(.moveToTrash))
                alert.addButton(withTitle: L10n.text(.cancel))
                guard await response(alert, in: window) == .alertFirstButtonReturn else { return }
                showProgress(title: L10n.text(.trashingFiles))
                let result = try await service.trash(sources, progress: progressHandler)
                await report(result, in: window)
            }
        case .undoFiles:
            run(title: L10n.text(.undoingFiles), in: window) { [self] in
                showProgress(title: L10n.text(.undoingFiles))
                let result = try await service.undo(progress: progressHandler)
                await report(result, in: window)
            }
        case .copyPath:
            guard let browser else { return }
            pasteboard.clearContents()
            pasteboard.setString(browser.selectedURLs.map(\.path).joined(separator: "\n"), forType: .string)
        default: break
        }
    }

    func transfer(_ inputs: [URL], to destination: URL, kind: FileTransferKind, cutToken: String? = nil,
                  browser: ExplorerBrowserController) {
        guard !isBusy else { NSSound.beep(); return }
        let window = browser.view.window
        run(title: L10n.text(kind == .move ? .movingFiles : .copyingFiles), in: window) { [self, weak browser] in
            showProgress(title: L10n.text(kind == .move ? .movingFiles : .copyingFiles))
            let claim: CutTransferClaim?
            if let cutToken {
                guard let id = UUID(uuidString: cutToken) else { throw CutTransferError.unavailable }
                claim = try await cutStore.acquire(id, clipboardURLs: inputs)
            } else { claim = nil }
            let beforeMove: (@Sendable (URL) async throws -> Void)?
            let afterMove: (@Sendable (URL, URL) async throws -> Void)?
            if let claim {
                beforeMove = { source in try await claim.beginMoving(source) }
                afterMove = { source, destination in try await claim.finishMoving(source, destination: destination) }
            } else { beforeMove = nil; afterMove = nil }
            let result: FileBatchResult
            do {
                result = try await service.transfer(claim?.sources ?? inputs, to: destination, kind: kind,
                    resolve: { [weak self] conflict in
                        guard let self else { return .cancel }
                        return await self.resolve(conflict, in: window)
                    }, progress: progressHandler,
                    beforeMove: beforeMove, afterMove: afterMove)
            } catch {
                await claim?.close()
                throw error
            }
            await claim?.close()
            browser?.selectAfterReload(result.items.compactMap(\.destination).filter {
                $0.deletingLastPathComponent().resolvingSymlinksInPath() == destination.resolvingSymlinksInPath()
            })
            await report(result, in: window)
        }
    }

    private var progressHandler: FileOperations.ProgressHandler {
        { [weak self] progress in await self?.update(progress) }
    }

    private func run(title: String, in window: NSWindow?, work: @escaping @MainActor () async throws -> Void) {
        guard task == nil else { return }
        isBusy = true
        cancelling = false
        task = Task { [self] in
            do { try await work() }
            catch is CancellationError { /* Only incomplete staged copies are discarded by the service. */ }
            catch {
                panel?.orderOut(nil)
                let alert = NSAlert(error: error)
                alert.messageText = L10n.text(.fileOperationFailed)
                _ = await response(alert, in: window)
            }
            progressIndicator.stopAnimation(nil)
            panel?.close(); panel = nil
            undoState = await service.undoState
            isBusy = false
            task = nil
            onChange?()
        }
    }

    private func writeClipboard(_ sources: [URL], cutID: UUID?) {
        let items = sources.enumerated().map { index, url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if index == 0, let cutID { item.setString(cutID.uuidString, forType: Self.cutType) }
            return item
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }

    private func requestName(title: L10n.Key, detail: String, initial: String, button: L10n.Key, in window: NSWindow?) async -> String? {
        let alert = NSAlert()
        alert.messageText = L10n.text(title)
        alert.informativeText = detail
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        field.setAccessibilityLabel(L10n.text(.itemName))
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text(button))
        alert.addButton(withTitle: L10n.text(.cancel))
        alert.window.initialFirstResponder = field
        guard await response(alert, in: window) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func resolve(_ conflict: FileConflict, in window: NSWindow?) async -> FileConflictChoice {
        if cancelling { return .cancel }
        panel?.orderOut(nil)
        let alert = NSAlert()
        alert.messageText = L10n.text(.fileConflictTitle)
        alert.informativeText = L10n.format(.fileConflictDetail, conflict.source.path, conflict.destination.path)
        if conflict.destinationIsDirectory { alert.informativeText += "\n\n" + L10n.text(.folderConflictDetail) }
        // Keep Both is the default; replacement requires an explicit choice.
        for key: L10n.Key in [.keepBoth, .skipItem, .replaceItem, .cancel] { alert.addButton(withTitle: L10n.text(key)) }
        let answer = await response(alert, in: window)
        panel?.orderFront(nil)
        if cancelling { return .cancel }
        switch answer {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .skip
        case .alertThirdButtonReturn: return .replace
        default: return .cancel
        }
    }

    private func report(_ result: FileBatchResult, in window: NSWindow?) async {
        guard result.failed > 0 || result.cancelled else { return }
        panel?.orderOut(nil)
        let alert = NSAlert()
        alert.messageText = L10n.text(.fileOperationResults)
        alert.informativeText = L10n.format(.fileResultCounts, result.completed,
            result.items.filter { $0.status == .skipped }.count, result.failed, result.unstarted)
        if result.cancelled { alert.informativeText += "\n" + L10n.text(.fileOperationCancelled) }
        let errors = result.items.filter { $0.error != nil }
        if !errors.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 470, height: 160))
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.font = .systemFont(ofSize: 12)
            text.string = errors.map { ($0.source?.lastPathComponent ?? "") + ": " + ($0.error ?? "") }.joined(separator: "\n\n")
            text.isVerticallyResizable = true
            text.textContainer?.widthTracksTextView = true
            scroll.documentView = text; scroll.hasVerticalScroller = true
            alert.accessoryView = scroll
        }
        _ = await response(alert, in: window)
    }

    private func response(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window, window.isVisible, window.attachedSheet == nil { return await alert.beginSheetModal(for: window) }
        return alert.runModal()
    }

    private func showProgress(title: String) {
        guard panel == nil else { panel?.orderFront(nil); return }
        let progress = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 160),
                               styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        progress.title = title
        progress.isReleasedWhenClosed = false
        phaseLabel.stringValue = title
        fileLabel.stringValue = ""
        countLabel.stringValue = ""
        phaseLabel.frame = NSRect(x: 20, y: 119, width: 420, height: 22)
        fileLabel.frame = NSRect(x: 20, y: 91, width: 420, height: 20)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        countLabel.frame = NSRect(x: 20, y: 27, width: 310, height: 20)
        countLabel.font = .systemFont(ofSize: 11)
        progressIndicator.frame = NSRect(x: 20, y: 65, width: 420, height: 12)
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        let cancel = NSButton(title: L10n.text(.cancel), target: self, action: #selector(cancelOperation))
        cancel.frame = NSRect(x: 340, y: 17, width: 100, height: 32)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        for view in [phaseLabel, fileLabel, countLabel, progressIndicator, cancel] { progress.contentView?.addSubview(view) }
        progress.center()
        panel = progress
        progress.orderFront(nil)
    }

    private func update(_ progress: FileOperationProgress) {
        if cancelling { phaseLabel.stringValue = L10n.text(.cancellingFiles) }
        else {
            let key: L10n.Key = switch progress.phase {
            case .preparing: .preparingFiles
            case .copying: .copyingFiles
            case .moving: .movingFiles
            case .trashing: .trashingFiles
            case .undoing: .undoingFiles
            }
            phaseLabel.stringValue = L10n.text(key)
        }
        fileLabel.stringValue = progress.current.path
        fileLabel.toolTip = progress.current.path
        countLabel.stringValue = L10n.format(.fileProgress, progress.completed, progress.total)
    }

    @objc private func cancelOperation() {
        cancelling = true
        task?.cancel()
        phaseLabel.stringValue = L10n.text(.cancellingFiles)
    }

    func explainPendingOperation(in window: NSWindow?) {
        panel?.orderFront(nil)
        guard window?.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text(.fileOperationWait)
        alert.informativeText = L10n.text(.fileOperationWaitDetail)
        alert.addButton(withTitle: L10n.text(.showFileProgress))
        alert.addButton(withTitle: L10n.text(.cancelFileOperation))
        Task {
            if await response(alert, in: window) == .alertSecondButtonReturn { cancelOperation() }
            panel?.orderFront(nil)
        }
    }

    func showRetainedOperations(in window: NSWindow?, onlyIfPresent: Bool = false) async {
        guard !isBusy else { return }
        do {
            let records = try await service.retainedOperations()
            if onlyIfPresent && records.isEmpty { return }
            let alert = NSAlert()
            alert.messageText = L10n.text(records.isEmpty ? .noRetainedOperations : .retainedOperationsMenu)
            alert.informativeText = records.isEmpty ? "" : L10n.text(.retainedOperationsDetail)
            if !records.isEmpty {
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
                let text = NSTextView(frame: scroll.bounds)
                text.isEditable = false; text.font = .systemFont(ofSize: 12)
                text.string = records.map { $0.source.path + "\n→ " + $0.destination.path + "\n" + $0.retainedDirectory.path }.joined(separator: "\n\n")
                text.isVerticallyResizable = true; text.textContainer?.widthTracksTextView = true
                scroll.documentView = text; scroll.hasVerticalScroller = true
                alert.accessoryView = scroll
                alert.addButton(withTitle: L10n.text(.revealRetainedOperations))
                alert.addButton(withTitle: L10n.text(.cancel))
            }
            if await response(alert, in: window) == .alertFirstButtonReturn, !records.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(records.map(\.retainedDirectory))
            }
        } catch {
            if !onlyIfPresent {
                let alert = NSAlert(error: error)
                _ = await response(alert, in: window)
            }
        }
    }
}
