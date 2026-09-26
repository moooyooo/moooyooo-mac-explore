import AppKit
import Foundation
import Testing
import ExplorerCore
import ExplorerPlatform
@testable import MacExplore

/// AppKit controller integration, not synthesized mouse/keyboard events or a visual test.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MACEXPLORE_TEST_APP"] != nil))
@MainActor
struct WorkspaceRestorationTests {
    private func awaitRows(_ browser: ExplorerBrowserController, _ count: Int) async throws {
        for _ in 0..<200 {
            if !browser.loading, browser.table.numberOfRows == count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.userCancelled)
    }

    @Test func rapidNavigationKeepsTheNewestRowsAndDirectoryWatch() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: folder.appendingPathComponent("one.txt"))
        }
        let controller = WorkspaceWindowController(number: 1, directories: [first], newWindow: {}, newInstance: {})
        defer { controller.stopLoading(); controller.close(); try? FileManager.default.removeItem(at: root) }
        controller.showWindow(nil)
        let browser = try #require(controller.activeBrowser)
        try await awaitRows(browser, 1)
        for index in 0..<30 {
            browser.navigate(to: index.isMultiple(of: 2) ? second : first)
            if index.isMultiple(of: 3) { try await Task.sleep(for: .milliseconds(1)) }
        }
        browser.navigate(to: second)
        browser.navigate(to: second) // Cancel after registering the same requested URL.
        try await awaitRows(browser, 1)
        #expect(browser.directory == second)
        try Data("external change".utf8).write(to: second.appendingPathComponent("two.txt"))
        try await awaitRows(browser, 2)
        #expect(browser.directory == second)
    }

    @Test func recoveringSelectionViewportAndHistoryKeepsProjectFormatSeparate() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for url in [first, second] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<200 {
            try Data("fixture".utf8).write(to: first.appendingPathComponent(String(format: "file-%03d.txt", i)))
        }
        try Data("other".utf8).write(to: second.appendingPathComponent("other.txt"))
        let store = ProjectStore(supportDirectory: root.appendingPathComponent("support"))
        let original = WorkspaceWindowController(number: 1, directories: [first], newWindow: {}, newInstance: {})
        let project = WorkspaceProjectController(workspace: original, store: store)
        original.project = project
        let restored = WorkspaceWindowController(number: 2, directories: [], newWindow: {}, newInstance: {})
        let recoveredProject = WorkspaceProjectController(workspace: restored, store: store)
        restored.project = recoveredProject
        defer {
            original.stopLoading(); project.release(); original.close()
            restored.stopLoading(); recoveredProject.release(); restored.close()
        }
        original.showWindow(nil)
        var document = project.snapshot()
        document.panes[0].settings.columns[0].width = 900
        let opened = try await store.saveAs(document, to: root.appendingPathComponent("workspace.mexplore"))
        try project.adopt(opened)
        let browser = try #require(original.activeBrowser)
        try await awaitRows(browser, 200)
        original.window?.contentView?.layoutSubtreeIfNeeded()
        let changeToken = project.changeToken
        browser.table.selectRowIndexes(IndexSet([42, 84]), byExtendingSelection: false)
        let scroll = try #require(browser.table.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 30, y: 1234))
        scroll.reflectScrolledClipView(scroll.contentView)
        let selected = browser.savedSession
        #expect(!selected.selectedNames.isEmpty && selected.topVisibleIndex > 0)
        #expect(!project.isDirty && project.changeToken == changeToken)
        browser.navigate(to: second)
        try await awaitRows(browser, 1)
        try Data("inserted".utf8).write(to: first.appendingPathComponent("aaa.txt"))
        browser.goBack()
        try await awaitRows(browser, 201)
        #expect(browser.savedSession.selectedNames == selected.selectedNames)
        #expect(browser.savedSession.topVisibleName == selected.topVisibleName)
        #expect(browser.savedSession.history.forward == second)
        let snapshot = RecoveryWorkspace(document: project.snapshot(), sourceURL: project.url, browserStates: original.browserSessions)
        let persisted = try JSONDecoder().decode(RecoveryWorkspace.self, from: JSONEncoder().encode(snapshot))
        try persisted.validate()
        let expected = browser.savedSession
        restored.showWindow(nil)
        try recoveredProject.recover(persisted.document)
        try restored.restoreBrowserSessions(persisted.browserStates ?? [])
        #expect(restored.browserSessions == persisted.browserStates) // Durable handoff while directory loading is pending.
        let recovered = try #require(restored.activeBrowser)
        try await awaitRows(recovered, 201)
        #expect(recovered.savedSession.selectedNames == expected.selectedNames)
        #expect(recovered.savedSession.topVisibleName == expected.topVisibleName)
        #expect(abs(recovered.savedSession.rowOffset - expected.rowOffset) < 0.5)
        #expect(abs(recovered.savedSession.horizontalOffset - expected.horizontalOffset) < 0.5)
        #expect(recovered.savedSession.history == expected.history)
        recovered.goForward()
        try await awaitRows(recovered, 1)
        #expect(recovered.directory == second)
    }
    @Test func toolbarAdaptsToLongTranslationsAtMinimumWindowWidth() throws {
        _ = NSApplication.shared
        let controller = WorkspaceWindowController(number: 1, directories: [], newWindow: {}, newInstance: {})
        defer { controller.close() }
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        let buttons = content.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 8)
        for button in buttons { button.title += " — extended translation" }
        window.setContentSize(NSSize(width: 760, height: 480))
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        #expect(buttons.allSatisfy { $0.imagePosition == .imageOnly && content.bounds.contains($0.frame) })
        #expect(buttons.allSatisfy { !($0.toolTip ?? "").isEmpty && !($0.accessibilityLabel() ?? "").isEmpty })
        window.setContentSize(NSSize(width: 3000, height: 700))
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        #expect(buttons.dropFirst(2).allSatisfy { $0.imagePosition == .imageLeading })
    }

    @Test func restoringViewsKeepsSettingsAndNewChangesDirty() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(supportDirectory: root.appendingPathComponent("support"))
        let controller = WorkspaceWindowController(number: 1, directories: [], newWindow: {}, newInstance: {})
        let project = WorkspaceProjectController(workspace: controller, store: store)
        controller.project = project
        defer { controller.stopLoading(); project.release(); controller.close() }
        var state = Workspace()
        let first = state.add(directory: root, canvas: .init(width: 1000, height: 700))
        let second = state.add(directory: root.appendingPathComponent("missing"), canvas: .init(width: 1000, height: 700))
        state.minimize(second); state.toggleMaximize(first)
        var document = ProjectDocument(name: "UI test", workspace: state)
        document.windowFrame = PaneFrame(x: 90_000, y: -90_000, width: 1600, height: 2000)
        document.panes[0].settings.columns.reverse()
        document.panes[0].settings.columns[0].width = 300
        document.panes[0].settings.sortColumn = .size
        document.panes[0].settings.ascending = false
        document.panes[0].settings.showHidden = true
        document.panes[0].settings.filter = "資料"
        document.panes[0].settings.treeWidth = 211
        document.panes[0].settings.favorites = [root]
        document.panes[0].settings.expandedDirectories = [root]
        let opened = try await store.saveAs(document, to: root.appendingPathComponent("view.mexplore"))
        try project.adopt(opened)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<100 {
            if controller.activeBrowser?.loading == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let restored = project.snapshot()
        #expect(restored.panes.map(\.id) == document.panes.map(\.id))
        #expect(restored.activePaneID == first)
        #expect(restored.zOrder == document.zOrder)
        #expect(restored.panes[0].settings == document.panes[0].settings)
        #expect(restored.panes[1].presentation == .minimized)
        #expect(!project.isDirty)
        #expect(NSScreen.screens.contains { $0.visibleFrame.contains(controller.window!.frame) })
        controller.arrange(.columns)
        #expect(project.isDirty)
        #expect(await project.save())
        #expect(!project.isDirty)
        let saved = try ProjectDocument.decode(Data(contentsOf: root.appendingPathComponent("view.mexplore")))
        #expect(saved.panes[0].presentation == .normal)
        #expect(saved.panes[0].settings == document.panes[0].settings)
        controller.closePane(second)
        #expect(project.isDirty && project.snapshot().panes.count == 1)
        // An invalid restore must not clear the existing usable workspace.
        var invalid = saved; invalid.activePaneID = UUID()
        #expect(throws: (any Error).self) { try controller.restore(invalid) }
        #expect(controller.state.panes.count == 1)
    }
}
