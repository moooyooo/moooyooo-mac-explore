import Foundation

public struct NavigationHistory: Sendable {
    public private(set) var entries: [URL] = []
    public private(set) var index = -1
    public init() {}

    public var current: URL? { entries.indices.contains(index) ? entries[index] : nil }
    public var back: URL? { index > 0 ? entries[index - 1] : nil }
    public var forward: URL? { index + 1 < entries.count ? entries[index + 1] : nil }

    /// Call only after a directory has successfully loaded.
    public mutating func visit(_ url: URL) {
        guard current != url else { return }
        entries = Array(entries.prefix(index + 1))
        entries.append(url)
        // Avoid unbounded history in long-lived workspaces.
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        index = entries.count - 1
    }

    public mutating func goBack() { if back != nil { index -= 1 } }
    public mutating func goForward() { if forward != nil { index += 1 } }
}
