import Foundation

/// Private recovery state, deliberately excluded from the portable project document.
public struct BrowserSession: Codable, Equatable, Sendable {
    public static let maximumSelection = 100_000
    public var history: NavigationHistory
    public var selectedNames: [String]
    public var topVisibleName: String?
    public var topVisibleIndex: Int
    public var rowOffset: Double
    public var horizontalOffset: Double

    public init(history: NavigationHistory = .init(), selectedNames: [String] = [], topVisibleName: String? = nil,
                topVisibleIndex: Int = 0, rowOffset: Double = 0, horizontalOffset: Double = 0) {
        self.history = history; self.selectedNames = selectedNames; self.topVisibleName = topVisibleName
        self.topVisibleIndex = topVisibleIndex; self.rowOffset = rowOffset; self.horizontalOffset = horizontalOffset
    }

    public func validate() throws {
        try history.validate()
        func validName(_ name: String) -> Bool {
            !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && name.utf8.count <= 1_024
        }
        guard selectedNames.count <= Self.maximumSelection, selectedNames.allSatisfy(validName),
              Set(selectedNames).count == selectedNames.count,
              topVisibleName.map(validName) ?? true,
              (0...10_000_000).contains(topVisibleIndex), rowOffset.isFinite, (0...100).contains(rowOffset),
              horizontalOffset.isFinite, (0...100_000).contains(horizontalOffset) else {
            throw ProjectError.invalid(L10n.text(.fieldSession))
        }
    }
}
