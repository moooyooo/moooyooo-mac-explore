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
