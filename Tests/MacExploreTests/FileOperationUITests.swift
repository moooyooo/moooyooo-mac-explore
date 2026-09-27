import AppKit
import Foundation
import Testing
import ExplorerCore
import ExplorerPlatform
@testable import MacExplore

/// Invokes native menu actions and sheet controls with synthetic files and a private
/// pasteboard. This does not replace real mouse/keyboard or Finder interoperability checks.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MACEXPLORE_TEST_APP"] != nil))
@MainActor
struct FileOperationUITests {
    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.userCancelled)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func invoke(_ command: AppCommand, browser: ExplorerBrowserController) throws {
        let menu = browser.contextMenu()
        let item = try #require(menu.items.first { $0.tag == command.rawValue && $0.action != nil })
        #expect(browser.validateMenuItem(item))
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    }

    @Test func nativeNewFolderAndRenameSheetsOperateOnTheActiveExplorer() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let operations = FileOperationController(supportDirectory: root.appendingPathComponent("state"), pasteboard: NSPasteboard(name: .init(UUID().uuidString)))
        let controller = WorkspaceWindowController(number: 1, directories: [folder], newWindow: {}, newInstance: {})
        controller.fileOperations = operations
        defer { controller.stopLoading(); controller.close(); try? FileManager.default.removeItem(at: root) }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        let browser = try #require(controller.activeBrowser)
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { !browser.loading }
        try invoke(.newFolder, browser: browser)
        try await waitUntil { window.attachedSheet != nil }
        func enter(_ name: String, buttonTitle: String) throws {
            let sheet = try #require(window.attachedSheet)
            let views = descendants(try #require(sheet.contentView))
            let field = try #require(views.compactMap { $0 as? NSTextField }.first { $0.isEditable })
            field.stringValue = name
            let button = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == buttonTitle })
            #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
        }
        try enter("資料 UI 🗂", buttonTitle: L10n.text(.createItem))
        try await waitUntil { !operations.isBusy && browser.table.numberOfRows == 1 && browser.table.selectedRow == 0 }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("資料 UI 🗂").path))
        browser.focusFiles()
        try invoke(.renameItem, browser: browser)
        try await waitUntil { window.attachedSheet != nil }
        try enter("名前変更 済み", buttonTitle: L10n.text(.renameAction))
        try await waitUntil { !operations.isBusy && browser.selectedURLs.first?.lastPathComponent == "名前変更 済み" }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("資料 UI 🗂").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("名前変更 済み").path))
        let undo = try #require(browser.contextMenu().items.first { $0.tag == AppCommand.undoFiles.rawValue })
        #expect(browser.validateMenuItem(undo))
        #expect(undo.title == L10n.format(.undoFileAction, L10n.text(.renameItem), 1))
        #expect(undo.toolTip == L10n.text(.undoFileScope))
    }

    @Test func contextCopyCutAndPasteTransferFoldersAcrossPanes() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        let nested = source.appendingPathComponent("Folder")
        for url in [nested, target] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data("test content".utf8).write(to: nested.appendingPathComponent("data.txt"))
        let clipboard = NSPasteboard(name: .init(UUID().uuidString))
        let operations = FileOperationController(supportDirectory: root.appendingPathComponent("state"), pasteboard: clipboard)
        let controller = WorkspaceWindowController(number: 1, directories: [source], newWindow: {}, newInstance: {})
        controller.fileOperations = operations
        defer { controller.stopLoading(); controller.close(); clipboard.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        controller.showWindow(nil)
        let first = try #require(controller.activeBrowser)
        try await waitUntil { !first.loading && first.table.numberOfRows == 1 }
        first.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        first.focusFiles()
        try invoke(.copyFiles, browser: first)
        #expect(FileOperationController.clipboardURLs(clipboard).first?.lastPathComponent == "Folder")
        controller.addPane(directory: target)
        let second = try #require(controller.activeBrowser)
        try await waitUntil { !second.loading }
        try invoke(.pasteFiles, browser: second)
        try await waitUntil { !operations.isBusy && second.table.numberOfRows == 1 }
        #expect(try String(contentsOf: target.appendingPathComponent("Folder/data.txt"), encoding: .utf8) == "test content")
        #expect(FileManager.default.fileExists(atPath: nested.path))
        // Move a distinct folder back so this test never uses the user's Trash.
        let moving = target.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: target.appendingPathComponent("Folder"), to: moving)
        second.reload()
        try await waitUntil { !second.loading && second.table.numberOfRows == 1 }
        second.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        second.focusFiles()
        try invoke(.cutFiles, browser: second)
        try await waitUntil { !operations.isBusy }
        #expect(FileManager.default.fileExists(atPath: moving.path))
        controller.activate(first.paneID)
        try invoke(.pasteFiles, browser: first)
        try await waitUntil { !operations.isBusy && first.table.numberOfRows == 2 }
        #expect(!FileManager.default.fileExists(atPath: moving.path))
        #expect(try String(contentsOf: source.appendingPathComponent("Moved/data.txt"), encoding: .utf8) == "test content")
        try invoke(.undoFiles, browser: first)
        try await waitUntil { !operations.isBusy }
        #expect(FileManager.default.fileExists(atPath: moving.path))
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("Moved").path))
    }

    @Test func nativeTrashConfirmationAndUndoRestoreSyntheticFile() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let item = folder.appendingPathComponent("MacExplore synthetic trash test.txt")
        try Data("synthetic data only".utf8).write(to: item)
        let clipboard = NSPasteboard(name: .init(UUID().uuidString))
        let operations = FileOperationController(supportDirectory: root.appendingPathComponent("state"), pasteboard: clipboard)
        let controller = WorkspaceWindowController(number: 1, directories: [folder], newWindow: {}, newInstance: {})
        controller.fileOperations = operations
        defer { controller.stopLoading(); controller.close(); clipboard.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        controller.showWindow(nil)
        let window = try #require(controller.window), browser = try #require(controller.activeBrowser)
        try await waitUntil { !browser.loading && browser.table.numberOfRows == 1 }
        browser.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        browser.focusFiles()
        try invoke(.trashFiles, browser: browser)
        try await waitUntil { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet?.contentView)
        let button = try #require(descendants(sheet).compactMap { $0 as? NSButton }.first { $0.title == L10n.text(.moveToTrash) })
        #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
        for _ in 0..<100 {
            if !operations.isBusy { break }
            if let content = window.attachedSheet?.contentView, content !== sheet {
                let controls = descendants(content)
                let errors: [String] = controls.compactMap { ($0 as? NSTextField)?.stringValue ?? ($0 as? NSTextView)?.string }.filter { !$0.isEmpty }
                Issue.record("Unexpected Trash result: \(errors.joined(separator: " | "))")
                if let button = controls.compactMap({ $0 as? NSButton }).first, let action = button.action {
                    _ = NSApp.sendAction(action, to: button.target, from: button)
                }
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await waitUntil { !operations.isBusy }
        #expect(!FileManager.default.fileExists(atPath: item.path))
        #expect(operations.canUndo)
        operations.perform(.undoFiles, in: browser)
        try await waitUntil { !operations.isBusy }
        #expect(try String(contentsOf: item, encoding: .utf8) == "synthetic data only")
    }
}
