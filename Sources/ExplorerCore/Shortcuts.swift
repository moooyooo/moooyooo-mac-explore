public enum AppCommand: Int, Sendable {
    case newPane, newWindow, newInstance, openFolder, closePane, closeWindow
    case back, forward, up, refresh, focusAddress, focusSearch
    case nextPane, previousPane, maximize, minimize, columns, rows, cascade, move, resize
    case shortcuts, diagnostics
    case openProject, switchProject, saveProject, saveProjectAs, reacquireProject, recoverSession
    case projectInNewInstance
    case favorite, openInNewPane
    case newFolder, renameItem, trashFiles, copyFiles, cutFiles, pasteFiles, undoFiles, copyPath, contextMenu, selectAll
    case recoverFileOperations
}

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1)
    public static let control = Self(rawValue: 2)
    public static let option = Self(rawValue: 4)
    public static let shift = Self(rawValue: 8)
}

public enum ShortcutAction: Equatable, Sendable {
    case command(AppCommand)
    case edit(String)
    case selectFiles
    case cycleFocus(backward: Bool)
}

public enum Shortcuts {
    public static func resolve(key: String, code: UInt16, modifiers flags: KeyModifiers,
                               editingText: Bool, composingText: Bool) -> ShortcutAction? {
        guard !composingText else { return nil }
        let key = key.lowercased()
        if flags == .command || flags == .control {
            let commands: [String: AppCommand] = ["n": .newPane, "w": .closePane, "l": .focusAddress, "r": .refresh, "f": .focusSearch, "s": .saveProject, "o": .openProject]
            if let command = commands[key] { return .command(command) }
            if flags == .command, !editingText {
                if key == "[" { return .command(.back) }
                if key == "]" { return .command(.forward) }
                if code == 126 { return .command(.up) }
                if code == 51 { return .command(.trashFiles) }
            }
            if !editingText, let command = ["c": AppCommand.copyFiles, "x": .cutFiles, "v": .pasteFiles, "z": .undoFiles][key] {
                return .command(command)
            }
            if !editingText, key == "a" { return .selectFiles }
            if flags == .control {
                if code == 48 { return .command(.nextPane) }
                if editingText, let selector = ["a": "selectAll:", "c": "copy:", "x": "cut:", "v": "paste:", "z": "undo:"][key] {
                    return .edit(selector)
                }
                if key == "a" { return .selectFiles }
            }
        } else if flags == [.command, .option] || flags == [.control, .option] {
            if key == "n" { return .command(.newWindow) }
        } else if flags == [.command, .shift] || flags == [.control, .shift] {
            if key == "n" { return .command(.newFolder) }
            if key == "w" { return .command(.closeWindow) }
            if key == "s" { return .command(.saveProjectAs) }
            if key == "o" { return .command(.openFolder) }
            if flags == [.control, .shift], code == 48 { return .command(.previousPane) }
        } else if flags == .option, !editingText {
            if code == 123 { return .command(.back) }
            if code == 124 { return .command(.forward) }
            if code == 126 { return .command(.up) }
            if key == "d" { return .command(.focusAddress) }
        } else if flags.isEmpty {
            if !editingText, code == 120 { return .command(.renameItem) }
            if !editingText, code == 117 { return .command(.trashFiles) }
            if code == 96 { return .command(.refresh) }
            if code == 99 { return .command(.focusSearch) }
            if code == 97 { return .cycleFocus(backward: false) }
        } else if flags == .shift {
            if code == 97 { return .cycleFocus(backward: true) }
            if !editingText, code == 109 { return .command(.contextMenu) }
        }
        return nil
    }
}
