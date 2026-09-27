import Foundation

public enum FileColumn: String, Codable, CaseIterable, Sendable {
    case name, modified, kind, size
}

public struct ColumnSettings: Codable, Equatable, Sendable {
    public var column: FileColumn
    public var width: Double
    public init(_ column: FileColumn, width: Double) { self.column = column; self.width = width }
}

public struct BrowserSettings: Codable, Equatable, Sendable {
    public var columns = [ColumnSettings(.name, width: 240), .init(.modified, width: 140),
                          .init(.kind, width: 100), .init(.size, width: 80)]
    public var sortColumn: FileColumn = .name
    public var ascending = true
    public var showHidden = false
    public var showNavigation = true
    public var filter = ""
    public var treeWidth: Double = 160
    public var expandedDirectories: [URL] = []
    public var favorites: [URL] = []
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case columns, sortColumn, ascending, showHidden, showNavigation, filter, treeWidth, expandedDirectories, favorites
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        columns = try values.decode([ColumnSettings].self, forKey: .columns)
        sortColumn = try values.decode(FileColumn.self, forKey: .sortColumn)
        ascending = try values.decode(Bool.self, forKey: .ascending)
        showHidden = try values.decode(Bool.self, forKey: .showHidden)
        // Additive display preference; version-1 projects from older apps remain readable.
        showNavigation = try values.decodeIfPresent(Bool.self, forKey: .showNavigation) ?? true
        filter = try values.decode(String.self, forKey: .filter)
        treeWidth = try values.decode(Double.self, forKey: .treeWidth)
        expandedDirectories = try values.decode([URL].self, forKey: .expandedDirectories)
        favorites = try values.decode([URL].self, forKey: .favorites)
    }
}

public struct FolderReference: Codable, Equatable, Sendable {
    public var url: URL
    public var bookmark: Data?
    public init(url: URL, bookmark: Data? = nil) { self.url = url; self.bookmark = bookmark }
}

public struct SavedPane: Codable, Equatable, Sendable {
    public var id: UUID
    public var folder: FolderReference
    public var normalFrame: PaneFrame
    public var presentation: PanePresentation
    public var settings: BrowserSettings

    public init(pane: ExplorerPane, settings: BrowserSettings = .init()) {
        id = pane.id; folder = FolderReference(url: pane.directory)
        normalFrame = pane.normalFrame; presentation = pane.presentation; self.settings = settings
    }
}

public struct ProjectDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumBytes = 8 * 1_024 * 1_024
    public static let maximumPanes = 64
    public var schemaVersion = currentVersion
    public var projectID = UUID()
    public var revision = UUID()
    public var name: String
    public var windowFrame: PaneFrame?
    /// Insertion order and stacking order are separate to preserve Ctrl+Tab behavior.
    public var panes: [SavedPane]
    public var zOrder: [UUID]
    public var activePaneID: UUID?

    public init(name: String = "Untitled", workspace: Workspace = .init()) {
        self.name = name
        panes = workspace.panes.map { SavedPane(pane: $0) }
        zOrder = workspace.zOrder; activePaneID = workspace.activePaneID
    }

    public func validate() throws {
        guard schemaVersion == Self.currentVersion else { throw ProjectError.unsupportedVersion(schemaVersion) }
        guard !name.isEmpty, name.count <= 255, panes.count <= Self.maximumPanes else { throw ProjectError.invalid(L10n.text(.fieldName)) }
        let ids = Set(panes.map(\.id))
        guard ids.count == panes.count, Set(zOrder) == ids, zOrder.count == ids.count else { throw ProjectError.invalid(L10n.text(.fieldOrder)) }
        if let activePaneID {
            guard panes.contains(where: { $0.id == activePaneID && $0.presentation != .minimized }) else { throw ProjectError.invalid(L10n.text(.fieldActive)) }
        } else if panes.contains(where: { $0.presentation != .minimized }) { throw ProjectError.invalid(L10n.text(.fieldMissingActive)) }
        let maximized = panes.filter { $0.presentation == .maximized }
        guard maximized.count <= 1, maximized.first.map({ $0.id == activePaneID }) ?? true else { throw ProjectError.invalid(L10n.text(.fieldMaximized)) }
        if let frame = windowFrame {
            guard [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite),
                  abs(frame.x) <= 100_000, abs(frame.y) <= 100_000,
                  (100...20_000).contains(frame.width), (100...20_000).contains(frame.height)
            else { throw ProjectError.invalid(L10n.text(.fieldWindowFrame)) }
        }
        for pane in panes {
            let f = pane.normalFrame
            guard [f.x, f.y, f.width, f.height].allSatisfy(\.isFinite),
                  f.x >= 0, f.y >= 0, f.width > 0, f.height > 0,
                  f.x + f.width <= 1.000001, f.y + f.height <= 1.000001
            else { throw ProjectError.invalid(L10n.text(.fieldPaneFrame)) }
            guard Self.isLocalFileURL(pane.folder.url), (pane.folder.bookmark?.count ?? 0) <= 131_072 else { throw ProjectError.invalid(L10n.text(.fieldFolder)) }
            let settings = pane.settings
            guard settings.columns.count == FileColumn.allCases.count,
                  Set(settings.columns.map(\.column)) == Set(FileColumn.allCases),
                  settings.columns.allSatisfy({ $0.width.isFinite && (60...2_400).contains($0.width) }),
                  settings.treeWidth.isFinite, (100...500).contains(settings.treeWidth),
                  settings.filter.count <= 1_024, settings.expandedDirectories.count <= 256,
                  settings.favorites.count <= 32,
                  (settings.expandedDirectories + settings.favorites).allSatisfy(Self.isLocalFileURL)
            else { throw ProjectError.invalid(L10n.text(.fieldSettings)) }
        }
    }

    public static func isLocalFileURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost") &&
        url.path.hasPrefix("/") && !url.path.contains("\0") && url.path.utf8.count <= 16_384
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw ProjectError.tooLarge }
        struct Header: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        guard header.schemaVersion == currentVersion else { throw ProjectError.unsupportedVersion(header.schemaVersion) }
        let result = try decoder.decode(Self.self, from: data)
        try result.validate()
        return result
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw ProjectError.tooLarge }
        return data
    }
}

public enum ProjectError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int), invalid(String), tooLarge
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): L10n.format(.unsupportedProject, version)
        case .invalid(let field): L10n.format(.invalidProject, field)
        case .tooLarge: L10n.text(.projectTooLarge)
        }
    }
}
