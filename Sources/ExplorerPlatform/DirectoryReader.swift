import Foundation

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
                result.append(FileEntry(
                    url: url, name: url.lastPathComponent,
                    isDirectory: values.isDirectory == true, isPackage: values.isPackage == true,
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
}
