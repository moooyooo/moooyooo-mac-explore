#if DEBUG
import AppKit
import ExplorerCore
import Darwin

/// Documentation-only export of this process's own AppKit view hierarchy.
/// It does not read the desktop, WindowServer surfaces, or another application's UI.
@MainActor
enum WindowCapture {
    static func start(to destination: URL, appearance: NSAppearance.Name = .aqua,
                      workspace: @escaping @MainActor () -> WorkspaceWindowController?,
                      finish: @escaping @MainActor () async -> Void) {
        Task {
            do {
                var ready: WorkspaceWindowController?
                var settled = 0
                for _ in 0..<200 {
                    try await Task.sleep(for: .milliseconds(100))
                    if let candidate = workspace(), candidate.project?.opened != nil,
                       candidate.project?.isBusy == false, !candidate.isLoadingDirectories,
                       candidate.window?.attachedSheet == nil {
                        settled += 1
                        if settled >= 5 { ready = candidate; break }
                    } else { settled = 0 }
                }
                guard let ready, let window = ready.window, let content = window.contentView,
                      let view = content.superview else {
                    throw CaptureError.notReady
                }
                window.appearance = NSAppearance(named: appearance)
                window.makeKeyAndOrderFront(nil)
                view.layoutSubtreeIfNeeded()
                window.display()
                // Allow asynchronous AppKit drawing to settle after changing appearance.
                try await Task.sleep(for: .milliseconds(300))
                view.layoutSubtreeIfNeeded()
                window.display()
                // Draw from the opaque window frame so AppKit includes layer-backed controls,
                // but export only our content area, not the system-managed title bar.
                let region = view.convert(content.bounds, from: content)
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: region) else {
                    throw CaptureError.noBitmap
                }
                view.cacheDisplay(in: region, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw CaptureError.noBitmap
                }
                try png.write(to: destination, options: .withoutOverwriting)
                let metadata: [String: Any] = [
                    "language": L10n.current.language.rawValue,
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                    "renderer": "NSView.cacheDisplay",
                    "region": "window-content",
                    "appearance": appearance == .darkAqua ? "darkAqua" : "aqua",
                    "pixelWidth": bitmap.pixelsWide,
                    "pixelHeight": bitmap.pixelsHigh,
                    "paneCount": ready.state.panes.count,
                    "menuTitles": NSApp.mainMenu?.items.map(\.title) ?? [],
                ]
                try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                    .write(to: destination.deletingPathExtension().appendingPathExtension("json"), options: .withoutOverwriting)
                await finish()
                // This explicit debug command is a disposable documentation process.
                // Do not route it through unsaved-layout confirmation sheets.
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Window export failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    private enum CaptureError: Error { case notReady, noBitmap }
}
#endif
