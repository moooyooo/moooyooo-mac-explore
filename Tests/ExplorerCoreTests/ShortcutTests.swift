import Testing
@testable import ExplorerCore

@Test func imeCompositionNeverRoutesToWorkspaceCommands() {
    for flags in [KeyModifiers.command, .control, .option, []] {
        for (key, code): (String, UInt16) in [("n", 45), ("w", 13), ("", 123), ("", 96)] {
            #expect(Shortcuts.resolve(key: key, code: code, modifiers: flags, editingText: true, composingText: true) == nil)
        }
    }
}

@Test func textEditingKeepsOptionArrowsAndControlEditingInTheField() {
    #expect(Shortcuts.resolve(key: "", code: 123, modifiers: .option, editingText: true, composingText: false) == nil)
    #expect(Shortcuts.resolve(key: "", code: 123, modifiers: .option, editingText: false, composingText: false) == .command(.back))
    #expect(Shortcuts.resolve(key: "a", code: 0, modifiers: .control, editingText: true, composingText: false) == .edit("selectAll:"))
    #expect(Shortcuts.resolve(key: "a", code: 0, modifiers: .control, editingText: false, composingText: false) == .selectFiles)
}

@Test func childAndParentShortcutsHaveDifferentScopes() {
    #expect(Shortcuts.resolve(key: "n", code: 45, modifiers: .control, editingText: false, composingText: false) == .command(.newPane))
    #expect(Shortcuts.resolve(key: "n", code: 45, modifiers: [.control, .option], editingText: false, composingText: false) == .command(.newWindow))
    #expect(Shortcuts.resolve(key: "w", code: 13, modifiers: [.command, .shift], editingText: false, composingText: false) == .command(.closeWindow))
    #expect(Shortcuts.resolve(key: "", code: 48, modifiers: [.control, .shift], editingText: true, composingText: false) == .command(.previousPane))
}

@Test func operatingSystemShortcutsAreNotClaimed() {
    #expect(Shortcuts.resolve(key: "", code: 48, modifiers: .command, editingText: false, composingText: false) == nil)
    #expect(Shortcuts.resolve(key: " ", code: 49, modifiers: .control, editingText: true, composingText: false) == nil)
    #expect(Shortcuts.resolve(key: "", code: 126, modifiers: .control, editingText: false, composingText: false) == nil)
}
