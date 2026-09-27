import Foundation
import Testing
@testable import ExplorerCore

private func sampleProject() -> ProjectDocument {
    var workspace = Workspace()
    let size = CanvasSize(width: 1200, height: 800)
    let first = workspace.add(directory: URL(fileURLWithPath: "/example/資料 🗂"), canvas: size)
    let second = workspace.add(directory: URL(fileURLWithPath: "/example/output"), canvas: size)
    workspace.minimize(second); workspace.toggleMaximize(first)
    var document = ProjectDocument(name: "作業環境", workspace: workspace)
    document.windowFrame = PaneFrame(x: -100, y: 120, width: 1160, height: 800)
    document.panes[0].settings.columns.reverse()
    document.panes[0].settings.columns[0].width = 321
    document.panes[0].settings.sortColumn = .modified
    document.panes[0].settings.ascending = false
    document.panes[0].settings.showHidden = true
    document.panes[0].settings.showNavigation = false
    document.panes[0].settings.filter = "資料"
    document.panes[0].settings.expandedDirectories = [URL(fileURLWithPath: "/example")]
    return document
}

@Test func projectRoundTripPreservesWorkspaceAndViewSettings() throws {
    let original = sampleProject()
    let decoded = try ProjectDocument.decode(original.encoded())
    #expect(decoded == original)
    let restored = try Workspace(project: decoded)
    #expect(restored.activePaneID == original.activePaneID)
    #expect(restored.zOrder == original.zOrder)
    #expect(restored.panes[0].presentation == .maximized)
    #expect(restored.panes[1].presentation == .minimized)
    #expect(restored.panes.map(\.directory) == original.panes.map(\.folder.url))
}

@Test func projectRejectsUnknownVersionBeforeRequiringCurrentFields() throws {
    #expect(throws: ProjectError.unsupportedVersion(999)) { try ProjectDocument.decode(Data(#"{"schemaVersion":999}"#.utf8)) }
    #expect(throws: (any Error).self) { try ProjectDocument.decode(Data("broken JSON".utf8)) }
    #expect(throws: ProjectError.tooLarge) { try ProjectDocument.decode(Data(repeating: 32, count: ProjectDocument.maximumBytes + 1)) }
}

@Test func oldProjectWithoutNavigationPreferenceUsesVisibleTree() throws {
    let original = sampleProject()
    var json = try #require(JSONSerialization.jsonObject(with: original.encoded()) as? [String: Any])
    var panes = try #require(json["panes"] as? [[String: Any]])
    for index in panes.indices {
        var settings = try #require(panes[index]["settings"] as? [String: Any])
        settings.removeValue(forKey: "showNavigation")
        panes[index]["settings"] = settings
    }
    json["panes"] = panes
    let decoded = try ProjectDocument.decode(JSONSerialization.data(withJSONObject: json))
    #expect(decoded.schemaVersion == 1)
    #expect(decoded.panes.allSatisfy { $0.settings.showNavigation })
    #expect(decoded.panes[0].settings.columns == original.panes[0].settings.columns)
    #expect(decoded.panes[0].settings.expandedDirectories == original.panes[0].settings.expandedDirectories)
}

@Test func projectRejectsInvalidIdentitiesGeometryAndURLs() {
    let invalid: [(inout ProjectDocument) -> Void] = [
        { $0.panes[1].id = $0.panes[0].id }, { $0.activePaneID = UUID() },
        { $0.zOrder.reverse(); $0.zOrder.append(UUID()) },
        { $0.panes[0].normalFrame.width = .infinity }, { $0.panes[0].normalFrame.x = -1 },
        { $0.panes[0].normalFrame.height = 2 }, { $0.windowFrame?.width = .nan },
        { $0.panes[0].folder.url = URL(string: "https://example.invalid")! },
        { $0.panes[0].folder.url = URL(string: "file://remote/example")! },
        { $0.panes[0].settings.columns.removeLast() }, { $0.panes[0].settings.treeWidth = .nan },
        { $0.panes[0].settings.filter = String(repeating: "x", count: 1025) },
        { $0.panes[1].presentation = .maximized }, { $0.activePaneID = nil },
    ]
    for mutate in invalid {
        var document = sampleProject(); mutate(&document)
        #expect(throws: (any Error).self) { try document.validate() }
    }
}

@Test func projectShortcutsRespectIMEAndUseBothModifierFamilies() {
    for flag in [KeyModifiers.command, .control] {
        #expect(Shortcuts.resolve(key: "s", code: 1, modifiers: flag, editingText: true, composingText: false) == .command(.saveProject))
        #expect(Shortcuts.resolve(key: "o", code: 31, modifiers: flag, editingText: false, composingText: false) == .command(.openProject))
        #expect(Shortcuts.resolve(key: "s", code: 1, modifiers: [flag, .shift], editingText: false, composingText: false) == .command(.saveProjectAs))
        #expect(Shortcuts.resolve(key: "s", code: 1, modifiers: flag, editingText: true, composingText: true) == nil)
    }
}
