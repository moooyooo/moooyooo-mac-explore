import AppKit
import Foundation
import Testing
import ExplorerCore
@testable import MacExplore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MACEXPLORE_TEST_APP"] != nil))
@MainActor
struct FolderNavigationTests {
    private func awaitCondition(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.userCancelled)
    }

    @Test(arguments: [760.0, 1180.0])
    func workspaceLayoutSettlesAfterSelectingHome(width: Double) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = WorkspaceWindowController(number: 1, directories: [root], newWindow: {}, newInstance: {})
        let window = try #require(workspace.window)
        window.setContentSize(NSSize(width: width, height: 600))
        workspace.showWindow(nil)
        defer { workspace.stopLoading(); workspace.close(); try? FileManager.default.removeItem(at: root) }
        let browser = try #require(workspace.activeBrowser)
        let tree = try #require(browser.children.first as? FolderTreeController)
        try await awaitCondition { !browser.loading }
        let parent = try #require(window.contentView as? LayoutView)
        let browserView = try #require(browser.view as? LayoutView)
        let parentLayout = parent.onLayout, browserLayout = browserView.onLayout
        var parentCount = 0, browserCount = 0
        parent.onLayout = { parentCount += 1; parentLayout?() }
        browserView.onLayout = { browserCount += 1; browserLayout?() }
        #expect(window.makeFirstResponder(tree.outline))
        tree.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await Task.sleep(for: .seconds(1))
        parentCount = 0; browserCount = 0
        try await Task.sleep(for: .seconds(1))
        #expect(parentCount < 10)
        #expect(browserCount < 10)
        #expect(!browser.loading)
        #expect(window.firstResponder === tree.outline)
    }

    @Test func selectingAnExpandedFolderSettlesAndRefreshDoesNotNavigateAgain() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("Home"), initial = root.appendingPathComponent("Initial")
        for folder in [home, initial, home.appendingPathComponent("Documents"), home.appendingPathComponent("Downloads")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var settings = BrowserSettings()
        settings.favorites = [home]
        settings.expandedDirectories = [home]
        let browser = ExplorerBrowserController(paneID: UUID(), directory: initial, settings: settings)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = browser.view
        window.orderFront(nil)
        defer { browser.stop(); window.close(); try? FileManager.default.removeItem(at: root) }
        let tree = try #require(browser.children.first as? FolderTreeController)
        try await awaitCondition { !browser.loading && tree.outline.numberOfRows == 7 }
        let navigate = tree.onNavigate
        var navigationCount = 0
        tree.onNavigate = { url in navigationCount += 1; navigate?(url) }
        tree.outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        try await awaitCondition { !browser.loading && browser.directory == home }
        try await Task.sleep(for: .seconds(1))
        #expect(navigationCount == 1)
        #expect(tree.selectedURL == home)
        #expect(tree.outline.numberOfRows == 7)

        tree.refresh(home)
        try await Task.sleep(for: .seconds(1))
        #expect(navigationCount == 1)
        #expect(!browser.loading)
        #expect(tree.selectedURL == home)
    }

    @Test func selectingHomeDoesNotContinuouslyReload() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let browser = ExplorerBrowserController(paneID: UUID(), directory: root)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = browser.view
        window.orderFront(nil)
        defer { browser.stop(); window.close(); try? FileManager.default.removeItem(at: root) }
        let tree = try #require(browser.children.first as? FolderTreeController)
        try await awaitCondition { !browser.loading }
        let navigate = tree.onNavigate
        var navigationCount = 0
        var finishedCount = 0
        tree.onNavigate = { url in navigationCount += 1; navigate?(url) }
        browser.onLoadFinished = { finishedCount += 1 }
        tree.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await awaitCondition { !browser.loading && navigationCount > 0 }
        try await Task.sleep(for: .seconds(2))
        #expect(navigationCount == 1)
        #expect(finishedCount <= 2)
        #expect(!browser.loading)
    }

    @Test func refreshingExpandedTreePreservesSelectionWhenEarlierRowsChange() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for name in ["Bravo", "Charlie"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = FolderTreeController()
        tree.configure(expanded: [root], favorites: [root], showHidden: false)
        defer { tree.stop() }
        try await awaitCondition { tree.outline.numberOfRows == 7 }
        tree.outline.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        let selected = tree.selectedURL
        #expect(selected?.lastPathComponent == "Charlie")
        var unwantedNavigation = 0
        tree.onNavigate = { _ in unwantedNavigation += 1 }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Alpha"), withIntermediateDirectories: true)
        tree.refresh(root)
        try await awaitCondition { tree.outline.numberOfRows == 8 }
        #expect(tree.selectedURL == selected)
        #expect(unwantedNavigation == 0)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Charlie"))
        tree.refresh(root)
        try await awaitCondition { tree.outline.numberOfRows == 7 }
        #expect(tree.selectedURL == nil)
        #expect(unwantedNavigation == 0)
    }

    @Test func treeRefreshKeepsTheVisibleFolderInPlace() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for index in 0..<40 {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(String(format: "folder-%02d", index)),
                                                     withIntermediateDirectories: true)
        }
        let tree = FolderTreeController()
        tree.configure(expanded: [root], favorites: [root], showHidden: false)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tree.view
        window.orderFront(nil)
        defer { tree.stop(); window.close(); try? FileManager.default.removeItem(at: root) }
        try await awaitCondition { tree.outline.numberOfRows == 45 }
        tree.view.layoutSubtreeIfNeeded()
        tree.outline.selectRowIndexes(IndexSet(integer: 25), byExtendingSelection: false)
        tree.outline.scrollRowToVisible(25)
        let scroll = try #require(tree.view as? NSScrollView)
        let firstRow = tree.outline.rows(in: tree.outline.visibleRect).location
        let anchor = try #require(tree.outline.item(atRow: firstRow))
        let offset = scroll.contentView.bounds.minY - tree.outline.rect(ofRow: firstRow).minY
        let selected = tree.selectedURL
        #expect(scroll.contentView.bounds.minY > 0)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Alpha"), withIntermediateDirectories: true)
        tree.refresh(root)
        try await awaitCondition { tree.outline.numberOfRows == 46 }
        let newRow = tree.outline.row(forItem: anchor)
        let newOffset = scroll.contentView.bounds.minY - tree.outline.rect(ofRow: newRow).minY
        #expect(newRow == firstRow + 1)
        #expect(abs(newOffset - offset) < 0.5)
        #expect(tree.selectedURL == selected)
    }
}
