import AppKit
import ExplorerCore

@MainActor
enum BrowserViewMenu {
    static let sortItems: [(L10n.Key, AppCommand)] = [
        (.columnName, .sortName), (.columnModified, .sortModified),
        (.columnKind, .sortKind), (.columnSize, .sortSize),
    ]

    static func column(for command: AppCommand) -> FileColumn? {
        switch command {
        case .sortName: .name
        case .sortModified: .modified
        case .sortKind: .kind
        case .sortSize: .size
        default: nil
        }
    }
}

/// Uses only standard controls so order and widths can be edited with a keyboard.
@MainActor
enum ColumnSettingsSheet {
    static func present(_ columns: [ColumnSettings], in window: NSWindow) async -> [ColumnSettings]? {
        let header = [L10n.text(.columnsMenu), L10n.text(.columnOrder), L10n.text(.columnWidth)]
            .map { NSTextField(labelWithString: $0) as NSView }
        var rows = [header]
        var controls: [(FileColumn, NSPopUpButton, NSTextField)] = []
        for (index, setting) in columns.enumerated() {
            let key: L10n.Key = switch setting.column {
            case .name: .columnName
            case .modified: .columnModified
            case .kind: .columnKind
            case .size: .columnSize
            }
            let label = NSTextField(labelWithString: L10n.text(key))
            let order = NSPopUpButton()
            order.addItems(withTitles: ["1", "2", "3", "4"])
            order.selectItem(at: index)
            order.setAccessibilityLabel(L10n.text(key) + " · " + L10n.text(.columnOrder))
            order.setAccessibilityIdentifier("column-order-" + setting.column.rawValue)
            let width = NSTextField(string: String(Int(setting.width)))
            width.setAccessibilityLabel(L10n.text(key) + " · " + L10n.text(.columnWidth))
            width.setAccessibilityIdentifier("column-width-" + setting.column.rawValue)
            width.widthAnchor.constraint(equalToConstant: 90).isActive = true
            rows.append([label, order, width])
            controls.append((setting.column, order, width))
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10; grid.columnSpacing = 20
        grid.xPlacement = .leading
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        let message = NSTextField(wrappingLabelWithString: "")
        message.font = .systemFont(ofSize: 11)
        message.textColor = .systemRed
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: max(360, grid.frame.width), height: grid.frame.height + 48))
        grid.frame.origin.y = 48
        message.frame = NSRect(x: 0, y: 0, width: accessory.frame.width, height: 40)
        accessory.addSubview(grid); accessory.addSubview(message)
        let alert = NSAlert()
        alert.messageText = L10n.text(.columnsMenu)
        alert.informativeText = L10n.text(.columnsDetail)
        alert.accessoryView = accessory
        let apply = alert.addButton(withTitle: L10n.text(.apply))
        alert.addButton(withTitle: L10n.text(.cancel))
        let form = ColumnSettingsForm(controls: controls, apply: apply, message: message)
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return nil }
        return form.values
    }
}

/// Keep invalid values in the same sheet, and prevent Apply until every field is valid.
@MainActor
private final class ColumnSettingsForm: NSObject, NSTextFieldDelegate {
    private let controls: [(FileColumn, NSPopUpButton, NSTextField)]
    private let apply: NSButton
    private let message: NSTextField

    init(controls: [(FileColumn, NSPopUpButton, NSTextField)], apply: NSButton, message: NSTextField) {
        self.controls = controls; self.apply = apply; self.message = message
        super.init()
        for (_, order, field) in controls {
            field.delegate = self
            order.target = self
            order.action = #selector(validateControls)
        }
        validateControls()
    }

    var values: [ColumnSettings]? {
        var result: [(Int, ColumnSettings)] = []
        for (column, order, field) in controls {
            guard let width = Double(field.stringValue), width.isFinite, (60...2400).contains(width) else { return nil }
            result.append((order.indexOfSelectedItem, .init(column, width: width)))
        }
        guard result.count == 4, Set(result.map(\.0)) == Set(0..<4) else { return nil }
        return result.sorted { $0.0 < $1.0 }.map(\.1)
    }

    func controlTextDidChange(_ obj: Notification) { validateControls() }

    @objc private func validateControls() {
        let valid = values != nil
        apply.isEnabled = valid
        message.stringValue = valid ? "" : L10n.text(.columnsInvalid)
        apply.toolTip = valid ? nil : L10n.text(.columnsInvalid)
    }
}
