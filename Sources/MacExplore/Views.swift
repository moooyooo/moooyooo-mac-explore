import AppKit

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class LayoutView: FlippedView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

final class ActionButton: NSButton {
    var handler: (() -> Void)?

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 12)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            imagePosition = .imageLeading
        }
        handler = action
        target = self
        self.action = #selector(invoke)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func invoke() { handler?() }
}

final class FileTableView: NSTableView {
    var onOpen: (() -> Void)?
    var onBack: (() -> Void)?
    var onContextMenu: (() -> NSMenu)?

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row < 0 { deselectAll(nil) }
        else if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        window?.makeFirstResponder(self)
        return onContextMenu?()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.isEmpty {
            if event.keyCode == 36 || event.keyCode == 76 { onOpen?(); return }
            if event.keyCode == 51 { onBack?(); return }
        }
        super.keyDown(with: event)
    }
}

class DragHandle: FlippedView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onKeyboardAction: (() -> Void)?
    private var origin = NSPoint.zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onDoubleClick { onDoubleClick(); return }
        origin = event.locationInWindow
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x - origin.x, origin.y - event.locationInWindow.y)
    }

    override func accessibilityPerformPress() -> Bool {
        onKeyboardAction?()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onKeyboardAction?() }
        else { super.keyDown(with: event) }
    }
}

final class PaneTitleBar: DragHandle {
    let label = NSTextField(labelWithString: "")
    var buttons: [NSButton] = []
    var active = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        (active ? NSColor.controlAccentColor.withAlphaComponent(0.14) : NSColor.controlBackgroundColor).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 10, y: 8, width: max(0, bounds.width - 112), height: 18)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: bounds.width - CGFloat(3 - index) * 29 - 4, y: 4, width: 27, height: 25)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSButton { return hit }
        return self
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: max(0, bounds.width - 96), height: bounds.height), cursor: .openHand)
    }
}

final class ResizeHandle: DragHandle {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        let path = NSBezierPath()
        for offset in [CGFloat(4), 8, 12] {
            path.move(to: NSPoint(x: bounds.width - offset, y: bounds.height - 2))
            path.line(to: NSPoint(x: bounds.width - 2, y: bounds.height - offset))
        }
        path.stroke()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
}
