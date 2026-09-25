import Foundation
import ExplorerCore

public struct FileEntry: Identifiable, Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymbolicLink: Bool
    public let size: Int64?
    public let modified: Date?
    public var id: URL { url }
    public var isBrowsable: Bool { isDirectory && !isPackage }

    public var kind: String {
        if isSymbolicLink { return "リンク" }
        if isPackage { return "パッケージ" }
        if isDirectory { return "フォルダ" }
        return url.pathExtension.isEmpty ? "ファイル" : "\(url.pathExtension.uppercased()) ファイル"
    }
}

public enum DirectoryReader {
    public static func read(_ directory: URL, showHidden: Bool = false) async throws -> [FileEntry] {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            ]
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys),
                options: showHidden ? [] : [.skipsHiddenFiles]
            )
            var result: [FileEntry] = []
            result.reserveCapacity(urls.count)
            for url in urls {
                try Task.checkCancellation()
                // An individual item can disappear during enumeration; keep the rest usable.
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                let target = values.isSymbolicLink == true ? try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) : nil
                result.append(FileEntry(
                    url: url, name: url.lastPathComponent,
                    isDirectory: (target?.isDirectory ?? values.isDirectory) == true,
                    isPackage: (target?.isPackage ?? values.isPackage) == true,
                    isSymbolicLink: values.isSymbolicLink == true,
                    size: values.fileSize.map(Int64.init), modified: values.contentModificationDate
                ))
            }
            try Task.checkCancellation()
            return result.sorted {
                if $0.isBrowsable != $1.isBrowsable { return $0.isBrowsable }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public static func project(_ entries: [FileEntry], settings: BrowserSettings) async throws -> [FileEntry] {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = entries.filter { settings.filter.isEmpty || $0.name.localizedStandardContains(settings.filter) }.sorted { lhs, rhs in
                if lhs.isBrowsable != rhs.isBrowsable { return lhs.isBrowsable }
                let comparison: ComparisonResult
                switch settings.sortColumn {
                case .size: comparison = (lhs.size ?? 0) == (rhs.size ?? 0) ? .orderedSame : ((lhs.size ?? 0) < (rhs.size ?? 0) ? .orderedAscending : .orderedDescending)
                case .modified: comparison = (lhs.modified ?? .distantPast).compare(rhs.modified ?? .distantPast)
                case .kind: comparison = lhs.kind.localizedStandardCompare(rhs.kind)
                case .name: comparison = lhs.name.localizedStandardCompare(rhs.name)
                }
                if comparison == .orderedSame { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
                return settings.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
