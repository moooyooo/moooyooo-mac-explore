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
    private func awaitCondition(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.userCancelled)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        var result = [view]
        for child in view.subviews { result.append(contentsOf: descendants(child)) }
        return result
    }

    private func click(_ title: String, in view: NSView) throws {
        let button = try #require(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == title })
        try #require(button.isEnabled)
        // performClick's animation can stop Swift's async-main run loop. Exercise
        // the native action here; physical pointer/animation checks remain separate.
        #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
    }

    @Test func viewCommandsPreserveSelectionAndIndependentPaneSettings() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", ".hidden.txt"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }
        let controller = WorkspaceWindowController(number: 1, directories: [folder], newWindow: {}, newInstance: {})
        let store = ProjectStore(supportDirectory: root.appendingPathComponent("support"))
        let project = WorkspaceProjectController(workspace: controller, store: store)
        controller.project = project
        defer {
            controller.stopLoading(); project.release(); controller.close()
            try? FileManager.default.removeItem(at: root)
        }
        controller.showWindow(nil)
        let first = try #require(controller.activeBrowser)
        controller.addPane(directory: folder)
        let second = try #require(controller.activeBrowser)
        try await awaitRows(first, 2)
        try await awaitRows(second, 2)
        second.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let selected = second.selectedURLs
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            var result = menu.items
            for item in menu.items {
                if let submenu = item.submenu { result.append(contentsOf: items(submenu)) }
            }
            return result
        }
        func invokeContext(_ command: AppCommand) throws -> NSMenuItem {
            second.focusFiles()
            let item = try #require(items(second.contextMenu()).first { $0.action != nil && $0.tag == command.rawValue })
            #expect(second.validateMenuItem(item))
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            return item
        }
        let descending = try invokeContext(.sortDescending)
        try await awaitCondition { !second.loading }
        #expect(second.selectedURLs == selected)
        #expect(second.table.selectedRow == 1)
        #expect(first.savedSettings.ascending && !second.savedSettings.ascending)
        #expect(second.validateMenuItem(descending) && descending.state == .on)
        let navigation = NSMenuItem(title: L10n.text(.navigationPane), action: nil, keyEquivalent: "")
        second.performViewCommand(.toggleNavigation)
        #expect(!second.savedSettings.showNavigation && first.savedSettings.showNavigation)
        #expect(second.validateViewMenuItem(navigation, command: .toggleNavigation) == true && navigation.state == .off)
        let tree = try #require(second.children.first as? FolderTreeController)
        #expect(tree.view.isHidden)
        _ = try invokeContext(.toggleHidden)
        try await awaitRows(second, 3)
        #expect(first.table.numberOfRows == 2 && !first.savedSettings.showHidden)
        #expect(project.isDirty)
        let saved = try await store.saveAs(project.snapshot(), to: root.appendingPathComponent("view.mexplore"))
        await store.close(saved.handleID)
        let decoded = try ProjectDocument.decode(Data(contentsOf: root.appendingPathComponent("view.mexplore")))
        #expect(decoded.panes.first { $0.id == second.paneID }?.settings == second.savedSettings)
        second.performViewCommand(.toggleNavigation)
        #expect(second.savedSettings.showNavigation)
    }

    @Test func columnSheetRejectsInvalidInputAppliesOrderAndCancelsChanges() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let controller = WorkspaceWindowController(number: 1, directories: [root], newWindow: {}, newInstance: {})
        defer { controller.stopLoading(); controller.close(); try? FileManager.default.removeItem(at: root) }
        controller.showWindow(nil)
        let window = try #require(controller.window), browser = try #require(controller.activeBrowser)
        try await awaitRows(browser, 0)
        let initial = browser.savedSettings.columns
        browser.performViewCommand(.columnSettings)
        try await awaitCondition { window.attachedSheet != nil }
        let content = try #require(window.attachedSheet?.contentView)
        let controls = descendants(content)
        let nameWidth = try #require(controls.first { $0.accessibilityIdentifier() == "column-width-name" } as? NSTextField)
        nameWidth.stringValue = "NaN"
        nameWidth.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: nameWidth))
        let apply = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == L10n.text(.apply) })
        #expect(!apply.isEnabled)
        try await awaitCondition {
            window.attachedSheet.map { self.descendants($0.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == L10n.text(.columnsInvalid) } } == true
        }
        #expect(browser.savedSettings.columns == initial)
        nameWidth.stringValue = "420"
        nameWidth.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: nameWidth))
        for (index, column) in initial.enumerated() {
            let order = try #require(controls.first { $0.accessibilityIdentifier() == "column-order-" + column.column.rawValue } as? NSPopUpButton)
            order.selectItem(at: 3 - index)
            #expect(NSApp.sendAction(try #require(order.action), to: order.target, from: order))
            if index == 0 { #expect(!apply.isEnabled) } // Duplicate positions are rejected too.
        }
        #expect(apply.isEnabled)
        try click(L10n.text(.apply), in: content)
        try await awaitCondition { window.attachedSheet == nil && browser.savedSettings.columns.first?.column == .size }
        #expect(browser.savedSettings.columns.map(\.column) == initial.reversed().map(\.column))
        #expect(browser.savedSettings.columns.last?.width == 420)
        let applied = browser.savedSettings
        browser.performViewCommand(.columnSettings)
        try await awaitCondition { window.attachedSheet != nil }
        let cancelledContent = try #require(window.attachedSheet?.contentView)
        let cancelledWidth = try #require(descendants(cancelledContent).first { $0.accessibilityIdentifier() == "column-width-name" } as? NSTextField)
        cancelledWidth.stringValue = "800"
        try click(L10n.text(.cancel), in: cancelledContent)
        try await awaitCondition { window.attachedSheet == nil }
        #expect(browser.savedSettings == applied)
        browser.performViewCommand(.resetColumns)
        #expect(browser.savedSettings.columns == initial)
    }

    @Test func unavailableFolderCanRetryOrReturnWithoutActingOnStaleRows() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("files"), missing = root.appendingPathComponent("missing")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: folder.appendingPathComponent("data.txt"))
        let clipboard = NSPasteboard(name: .init(UUID().uuidString))
        let operations = FileOperationController(supportDirectory: root.appendingPathComponent("support"), pasteboard: clipboard)
        let controller = WorkspaceWindowController(number: 1, directories: [folder], newWindow: {}, newInstance: {})
        controller.fileOperations = operations
        defer { controller.stopLoading(); controller.close(); clipboard.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        controller.showWindow(nil)
        let browser = try #require(controller.activeBrowser)
        try await awaitRows(browser, 1)
        browser.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        browser.focusFiles()
        operations.perform(.copyFiles, in: browser)
        browser.navigate(to: missing)
        try await awaitCondition { !browser.loading }
        let errorView = try #require(descendants(browser.view).first { $0.accessibilityIdentifier() == "unavailable-\(browser.paneID)" })
        let message = try #require(descendants(browser.view).first { $0.accessibilityIdentifier() == "location-error" } as? NSTextField)
        #expect(!errorView.isHidden && browser.table.enclosingScrollView?.isHidden == true)
        #expect(message.stringValue.contains(missing.path) && message.stringValue.contains("\n\n"))
        #expect(!message.stringValue.contains("\\n"))
        for command in [AppCommand.newFolder, .copyFiles, .pasteFiles, .renameItem, .trashFiles] {
            #expect(!operations.canPerform(command, in: browser))
        }
        #expect(browser.tableView(browser.table, pasteboardWriterForRow: 0) == nil)
        try click(L10n.text(.dismissLocationError), in: errorView)
        #expect(errorView.isHidden && browser.directory == folder)
        #expect(browser.selectedURLs.first?.lastPathComponent == "data.txt")
        browser.navigate(to: missing)
        try await awaitCondition { !browser.loading }
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        try Data("reconnected".utf8).write(to: missing.appendingPathComponent("recovered.txt"))
        try click(L10n.text(.retry), in: errorView)
        try await awaitCondition { !browser.loading && browser.directory == missing }
        #expect(errorView.isHidden && browser.readyItemCount == 1)
        #expect(browser.savedSession.history.back == folder)
        #expect(operations.canPerform(.newFolder, in: browser))
    }

    @Test func customPaneLayersFollowLightDarkLightChanges() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let controller = WorkspaceWindowController(number: 1, directories: [root], newWindow: {}, newInstance: {})
        defer { controller.stopLoading(); controller.close(); try? FileManager.default.removeItem(at: root) }
        controller.showWindow(nil)
        let window = try #require(controller.window), browser = try #require(controller.activeBrowser)
        try await awaitRows(browser, 0)
        let layers = descendants(try #require(window.contentView)).compactMap { $0 as? FlippedView }
            .filter { $0.semanticBackground != nil }
        #expect(layers.count >= 3) // Workspace, browser and divider.
        func colors() throws -> [NSColor] {
            try layers.map { view in
                let color = try #require(view.layer?.backgroundColor)
                return try #require(NSColor(cgColor: color)?.usingColorSpace(.deviceRGB))
            }
        }
        window.appearance = NSAppearance(named: .aqua)
        window.display()
        let light = try colors()
        window.appearance = NSAppearance(named: .darkAqua)
        window.display()
        try await awaitCondition { browser.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
        let dark = try colors()
        #expect(zip(light, dark).allSatisfy { $0 != $1 })
        window.appearance = NSAppearance(named: .aqua)
        window.display()
        #expect(try colors() == light)
    }

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
