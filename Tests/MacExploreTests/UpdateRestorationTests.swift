import AppKit
import Foundation
import Testing
import ExplorerCore
import ExplorerPlatform
@testable import MacExplore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MACEXPLORE_TEST_APP"] != nil))
@MainActor
struct UpdateRestorationTests {
    @Test func quitIsCancelledWhileAFileOperationSheetIsOpen() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = AppCoordinator(startTime: ProcessInfo.processInfo.systemUptime)
        let controller = coordinator.createWindow(directories: [root])
        defer { controller.stopLoading(); controller.project?.release(); controller.close() }
        let browser = try #require(controller.activeBrowser)
        for _ in 0..<200 {
            if !browser.loading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let operations = try #require(controller.fileOperations)
        operations.perform(.newFolder, in: browser)
        for _ in 0..<200 {
            if controller.window?.attachedSheet != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let sheet = try #require(controller.window?.attachedSheet)
        #expect(operations.isBusy)
        #expect(coordinator.applicationShouldTerminate(NSApp) == .terminateCancel)
        func buttons(_ view: NSView) -> [NSButton] {
            var found = (view as? NSButton).map { [$0] } ?? []
            for child in view.subviews { found.append(contentsOf: buttons(child)) }
            return found
        }
        let content = try #require(sheet.contentView)
        let cancel = try #require(buttons(content).first { $0.title == L10n.text(.cancel) })
        #expect(NSApp.sendAction(try #require(cancel.action), to: cancel.target, from: cancel))
        for _ in 0..<200 {
            if !operations.isBusy { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!operations.isBusy)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func updateResumesDirtyLayoutWithoutWritingTheSavedProject() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(supportDirectory: root.appendingPathComponent("support"))
        let window = WorkspaceWindowController(number: 1, directories: [root], newWindow: {}, newInstance: {})
        let project = WorkspaceProjectController(workspace: window, store: store)
        window.project = project
        defer { window.stopLoading(); project.release(); window.close() }
        let url = root.appendingPathComponent("project.mexplore")
        let original = try await store.saveAs(project.snapshot(), to: url)
        await store.close(original.handleID)
        let bytes = try Data(contentsOf: url)
        var working = original.document
        working.panes[0].settings.showHidden = true
        working.panes[0].settings.filter = "unsaved"
        let state = UpdateWorkspace(workspace: .init(document: working, sourceURL: url),
                                    savedDigest: original.contentDigest, isDirty: true)
        try await project.resumeAfterUpdate(state)
        #expect(project.url == original.url)
        #expect(project.isDirty)
        #expect(!project.isReadOnly)
        #expect(project.snapshot().panes[0].settings == working.panes[0].settings)
        #expect(try Data(contentsOf: url) == bytes)
        if let opened = project.opened { await store.close(opened.handleID) }
    }

    @Test func externallyChangedProjectIsRecoveredAsAnUnsavedCopy() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(supportDirectory: root.appendingPathComponent("support"))
        let window = WorkspaceWindowController(number: 1, directories: [root], newWindow: {}, newInstance: {})
        let project = WorkspaceProjectController(workspace: window, store: store)
        window.project = project
        defer { window.stopLoading(); project.release(); window.close() }
        let url = root.appendingPathComponent("project.mexplore")
        let original = try await store.saveAs(project.snapshot(), to: url)
        await store.close(original.handleID)
        var foreign = original.document; foreign.name = "Edited externally"
        let bytes = try foreign.encoded()
        try bytes.write(to: url, options: .atomic)
        let state = UpdateWorkspace(workspace: .init(document: original.document, sourceURL: url),
                                    savedDigest: original.contentDigest, isDirty: true)
        try await project.resumeAfterUpdate(state)
        #expect(project.url == nil && project.isDirty)
        #expect(project.snapshot().projectID != original.document.projectID)
        #expect(project.snapshot().panes == original.document.panes)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func isolatedInstancesCannotEnableNetworkUpdateChecks() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = UpdateSessionStore(bundleURL: root, supportDirectory: root)
        let updates = UpdateController(store: gate, enabled: false, isBusy: { false }, snapshot: { [] },
                                       showError: { _ in Issue.record("Disabled updater attempted work") })
        let menu = NSMenu()
        updates.addMenu(to: menu); updates.start()
        for item in menu.items where !item.isSeparatorItem { #expect(!updates.validateMenuItem(item)) }
        await updates.check(userInitiated: true)
        #expect(!updates.ownsUpdate && updates.targetBuild == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Updates").path))
        updates.stop()
    }
}
