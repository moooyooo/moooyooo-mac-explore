import Foundation
import Testing
@testable import ExplorerCore

@Test func browserSessionRejectsInvalidSelectionScrollAndHistory() throws {
    let a = URL(fileURLWithPath: "/tmp/first"), b = URL(fileURLWithPath: "/tmp/second")
    let history = try NavigationHistory(entries: [a, b], index: 0)
    let state = BrowserSession(history: history, selectedNames: ["資料 🗂", "file.txt"],
                               topVisibleName: "file.txt", topVisibleIndex: 24, rowOffset: 4.5, horizontalOffset: 30)
    let decoded = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(state))
    try decoded.validate()
    #expect(decoded == state && decoded.history.forward == b)
    var invalid = state; invalid.selectedNames = ["../outside"]
    #expect(throws: ProjectError.self) { try invalid.validate() }
    invalid = state; invalid.selectedNames = ["same", "same"]
    #expect(throws: ProjectError.self) { try invalid.validate() }
    invalid = state; invalid.rowOffset = .infinity
    #expect(throws: ProjectError.self) { try invalid.validate() }
    invalid = state; invalid.topVisibleIndex = -1
    #expect(throws: ProjectError.self) { try invalid.validate() }
    let badIndex = Data(#"{"entries":[],"index":9223372036854775807}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(NavigationHistory.self, from: badIndex) }
    #expect(throws: ProjectError.self) { try NavigationHistory(entries: [URL(string: "https://example.invalid")!], index: 0) }
}
