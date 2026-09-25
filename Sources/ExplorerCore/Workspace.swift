import Foundation

public enum PanePresentation: String, Codable, Sendable {
    case normal, minimized, maximized
}

public struct ExplorerPane: Identifiable, Sendable {
    public let id: UUID
    public var directory: URL
    public var normalFrame: PaneFrame
    public var presentation: PanePresentation

    public init(directory: URL, frame: PaneFrame) {
        self.id = UUID()
        self.directory = directory
        self.normalFrame = frame
        self.presentation = .normal
    }
}

public struct Workspace: Sendable {
    public private(set) var panes: [ExplorerPane] = []
    public private(set) var zOrder: [UUID] = []
    public private(set) var activePaneID: UUID?

    public init() {}

    public var activePane: ExplorerPane? { panes.first { $0.id == activePaneID } }

    @discardableResult
    public mutating func add(directory: URL, canvas: CanvasSize) -> UUID {
        let pane = ExplorerPane(directory: directory, frame: PaneLayout.cascade(index: panes.count, canvas: canvas))
        panes.append(pane)
        zOrder.append(pane.id)
        activate(pane.id)
        return pane.id
    }

    public mutating func activate(_ id: UUID) {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
        let maximized = panes.contains { $0.presentation == .maximized }
        for i in panes.indices where panes[i].presentation == .maximized { panes[i].presentation = .normal }
        panes[index].presentation = maximized ? .maximized : .normal
        activePaneID = id
        zOrder.removeAll { $0 == id }
        zOrder.append(id)
    }

    public mutating func close(_ id: UUID) {
        panes.removeAll { $0.id == id }
        zOrder.removeAll { $0 == id }
        if activePaneID == id { selectFrontmostVisible() }
    }

    public mutating func minimize(_ id: UUID) {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
        panes[index].presentation = .minimized
        if activePaneID == id { selectFrontmostVisible() }
    }

    public mutating func toggleMaximize(_ id: UUID) {
        guard let original = panes.first(where: { $0.id == id }) else { return }
        activate(id)
        if let index = panes.firstIndex(where: { $0.id == id }) {
            panes[index].presentation = original.presentation == .maximized ? .normal : .maximized
        }
    }

    public mutating func cycle(backward: Bool = false) {
        guard !panes.isEmpty else { return }
        // Insertion order is stable, unlike z-order which changes on each activation.
        let current = panes.firstIndex { $0.id == activePaneID }
        let next = current.map { ($0 + (backward ? panes.count - 1 : 1)) % panes.count } ?? 0
        activate(panes[next].id)
    }

    public mutating func setFrame(_ frame: PaneFrame, for id: UUID, canvas: CanvasSize) {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
        panes[index].normalFrame = frame.normalized(in: canvas)
        panes[index].presentation = .normal
    }

    public mutating func setDirectory(_ directory: URL, for id: UUID) {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
        panes[index].directory = directory
    }

    public mutating func arrange(_ style: Arrangement, canvas: CanvasSize) {
        let visible = panes.indices.filter { panes[$0].presentation != .minimized }
        let frames = PaneLayout.arrange(count: visible.count, style: style, canvas: canvas)
        for (index, frame) in zip(visible, frames) {
            panes[index].normalFrame = frame
            panes[index].presentation = .normal
        }
    }

    private mutating func selectFrontmostVisible() {
        activePaneID = zOrder.reversed().first { id in
            panes.contains { $0.id == id && $0.presentation != .minimized }
        }
    }
}
