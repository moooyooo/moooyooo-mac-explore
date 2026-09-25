import Foundation
import Testing
@testable import ExplorerCore

private let canvas = CanvasSize(width: 1200, height: 720)
private let folder = URL(fileURLWithPath: "/example", isDirectory: true)

@Test func maximizePreservesNormalFrameAndTransfersOnActivation() {
    var state = Workspace()
    let first = state.add(directory: folder, canvas: canvas)
    let second = state.add(directory: folder, canvas: canvas)
    let original = state.panes[0].normalFrame
    state.toggleMaximize(first)
    #expect(state.activePane?.presentation == .maximized)
    state.activate(second)
    #expect(state.panes.filter { $0.presentation == .maximized }.count == 1)
    state.activate(first)
    state.toggleMaximize(first)
    #expect(state.activePane?.normalFrame == original)
    #expect(state.activePane?.presentation == .normal)
}

@Test func cyclingUsesStableOrderInsteadOfBouncingBetweenFrontmostPanes() {
    var state = Workspace()
    let ids = (0..<3).map { _ in state.add(directory: folder, canvas: canvas) }
    for id in ids {
        state.cycle()
        #expect(state.activePaneID == id)
    }
    state.cycle(backward: true)
    #expect(state.activePaneID == ids[1])
}

@Test func minimizingAndClosingNeverLeaveDanglingActivePane() {
    var state = Workspace()
    let first = state.add(directory: folder, canvas: canvas)
    let second = state.add(directory: folder, canvas: canvas)
    state.minimize(second)
    #expect(state.activePaneID == first)
    state.close(first)
    #expect(state.activePaneID == nil)
    state.cycle()
    #expect(state.activePaneID == second)
    #expect(state.activePane?.presentation == .normal)
    state.close(second)
    #expect(state.panes.isEmpty && state.zOrder.isEmpty && state.activePaneID == nil)
}

@Test func layoutKeepsControlsReachableAfterResizeAndInvalidInput() {
    for size in [canvas, CanvasSize(width: 120, height: 90)] {
        for frame in [
            PaneFrame(x: -300, y: 5000, width: 2000, height: 900),
            PaneFrame(x: .nan, y: .infinity, width: -.infinity, height: .nan),
        ] {
            let result = frame.constrained(to: size)
            #expect(result.x >= 0 && result.y >= 0)
            #expect(result.width > 0 && result.height > 0)
            #expect(result.x + result.width <= size.width)
            #expect(result.y + result.height <= size.height)
        }
    }
}

@Test func tilingDoesNotOverlapWhenSpaceIsAvailable() {
    for style in [Arrangement.columns, .rows] {
        let frames = PaneLayout.arrange(count: 6, style: style, canvas: canvas).map { $0.resolved(in: canvas) }
        #expect(frames.count == 6)
        for a in frames.indices {
            for b in frames.indices where a < b {
                let xOverlap = min(frames[a].x + frames[a].width, frames[b].x + frames[b].width) - max(frames[a].x, frames[b].x)
                let yOverlap = min(frames[a].y + frames[a].height, frames[b].y + frames[b].height) - max(frames[a].y, frames[b].y)
                #expect(xOverlap <= 0.001 || yOverlap <= 0.001)
            }
        }
    }
}

@Test func navigationDropsForwardBranchAndBoundsMemory() {
    var history = NavigationHistory()
    let urls = (0..<220).map { URL(fileURLWithPath: "/example/\($0)") }
    for url in urls { history.visit(url) }
    #expect(history.entries.count == 200)
    history.goBack()
    #expect(history.forward == urls.last)
    history.visit(folder)
    #expect(history.current == folder && history.forward == nil)
    history.visit(folder)
    #expect(history.entries.count == 200)
}
