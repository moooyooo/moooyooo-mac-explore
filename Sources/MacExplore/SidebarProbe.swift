#if DEBUG
import AppKit
import ExplorerCore
import Darwin

/// Sends AppKit events only to this disposable process's own window.
/// Its normal NSApplication.run loop avoids Swift Testing's async-main tracking-loop issue.
@MainActor
enum SidebarProbe {
    static func start(to destination: URL,
                      workspace: @escaping @MainActor () -> WorkspaceWindowController?,
                      finish: @escaping @MainActor () async -> Void) {
        Task {
            let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                let home = fixture.appendingPathComponent("Home")
                let initial = fixture.appendingPathComponent("Initial")
                for folder in [initial, home, home.appendingPathComponent("Downloads"), home.appendingPathComponent("Documents")] {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                var ready: WorkspaceWindowController?
                for _ in 0..<100 {
                    try await Task.sleep(for: .milliseconds(100))
                    if let candidate = workspace(), !candidate.isLoadingDirectories,
                       candidate.window?.attachedSheet == nil { ready = candidate; break }
                }
                guard let ready, let window = ready.window, let parent = window.contentView as? LayoutView,
                      let browser = ready.activeBrowser, let browserView = browser.view as? LayoutView,
                      let tree = browser.children.first as? FolderTreeController else { throw ProbeError.notReady }
                let parentLayout = parent.onLayout, browserLayout = browserView.onLayout
                let navigation = tree.onNavigate
                var parentCount = 0, browserCount = 0, navigationCount = 0
                parent.onLayout = { parentCount += 1; parentLayout?() }
                browserView.onLayout = { browserCount += 1; browserLayout?() }
                tree.onNavigate = { url in navigationCount += 1; navigation?(url) }
                var results: [[String: Any]] = []
                for paneCount in [1, 2] {
                    if paneCount == 2 { ready.addPane(directory: initial) }
                    for width in [760.0, 1180.0] {
                        window.setContentSize(NSSize(width: width, height: 900))
                        if paneCount == 2 { ready.arrange(.rows) }
                        window.makeKeyAndOrderFront(nil)
                        for expanded in [false, true] {
                            for rootIndex in [0, 1] {
                                browser.navigate(to: initial)
                                tree.configure(expanded: expanded ? [home] : [], favorites: [], showHidden: false, homeDirectory: home)
                                try await Task.sleep(for: .milliseconds(400))
                                parent.layoutSubtreeIfNeeded()
                                window.displayIfNeeded()
                                if paneCount == 2, let last = ready.state.panes.last { ready.activate(last.id) }
                                navigationCount = 0
                                let item = tree.outlineView(tree.outline, child: rootIndex, ofItem: nil)
                                let row = tree.outline.rect(ofRow: tree.outline.row(forItem: item))
                                let point = tree.outline.convert(NSPoint(x: 65, y: row.midY), to: nil)
                                guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                                      let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, eventNumber: 1, clickCount: 1, pressure: 0) else { throw ProbeError.noEvent }
                                NSApp.postEvent(up, atStart: true)
                                window.sendEvent(down)
                                try await Task.sleep(for: .seconds(1))
                                parentCount = 0; browserCount = 0
                                try await Task.sleep(for: .seconds(1))
                                let expected = rootIndex == 0 ? home : home.appendingPathComponent("Downloads")
                                results.append([
                                    "paneCount": paneCount, "width": width, "expanded": expanded, "rootIndex": rootIndex,
                                    "navigationCount": navigationCount,
                                    "parentLayoutsWhileIdle": parentCount, "browserLayoutsWhileIdle": browserCount,
                                    "selectedDestinationCorrect": browser.directory.standardizedFileURL == expected.standardizedFileURL,
                                    "selectionPreserved": tree.selectedURL?.standardizedFileURL == expected.standardizedFileURL,
                                    "settled": !browser.loading,
                                    "focusPreserved": window.firstResponder === tree.outline,
                                ])
                            }
                        }
                    }
                }
                let passed = results.allSatisfy {
                    $0["navigationCount"] as? Int == 1 && $0["selectedDestinationCorrect"] as? Bool == true &&
                    $0["selectionPreserved"] as? Bool == true && $0["settled"] as? Bool == true &&
                    $0["focusPreserved"] as? Bool == true &&
                    ($0["parentLayoutsWhileIdle"] as? Int ?? 100) < 10 && ($0["browserLayoutsWhileIdle"] as? Int ?? 100) < 10
                }
                let data = try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": results], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: destination, options: .atomic)
                await finish()
                try? FileManager.default.removeItem(at: fixture)
                exit(passed ? 0 : 1)
            } catch {
                FileHandle.standardError.write(Data("Sidebar probe failed.\n".utf8))
                await finish()
                try? FileManager.default.removeItem(at: fixture)
                exit(1)
            }
        }
    }
    private enum ProbeError: Error { case notReady, noEvent }
}
#endif
