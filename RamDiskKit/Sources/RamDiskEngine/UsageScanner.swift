import Foundation
import RamDiskCore

enum UsageScanner {
    struct Item {
        var url: URL
        var category: UsageCategory
    }

    /// The top-level items of each category. An item is one workspace, one build folder, or one loose file.
    static func items(root: String) -> [Item] {
        let manager = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        var items: [Item] = []
        var claimed: Set<String> = ["agents"]

        for category in UsageCategory.allCases {
            guard let relative = category.relativePath else { continue }
            if category.agent == nil { claimed.insert(relative) }
            for child in children(of: rootURL.appendingPathComponent(relative)) {
                items.append(Item(url: child, category: category))
            }
        }

        let agentFolders = Set(AgentKind.allCases.map(\.folderName))
        for child in children(of: rootURL.appendingPathComponent("agents")) where !agentFolders.contains(child.lastPathComponent) {
            items.append(Item(url: child, category: .other))
        }
        let top = (try? manager.contentsOfDirectory(atPath: root)) ?? []
        for name in top where !claimed.contains(name) && !DiskManager.reservedNames.contains(name) {
            items.append(Item(url: rootURL.appendingPathComponent(name), category: .other))
        }
        return items
    }

    static func scan(
        root: String,
        progress: (String) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) -> [CategoryUsage]? {
        var usage = Dictionary(uniqueKeysWithValues: UsageCategory.allCases.map { ($0, CategoryUsage(category: $0)) })
        for item in items(root: root) {
            if isCancelled() { return nil }
            progress(item.url.path)
            guard let bytes = size(of: item.url, progress: progress, isCancelled: isCancelled) else { return nil }
            var entry = usage[item.category]!
            entry.bytes += bytes
            entry.itemCount += 1
            if bytes >= entry.largestBytes {
                entry.largestBytes = bytes
                entry.largestName = item.url.lastPathComponent
            }
            usage[item.category] = entry
        }
        return UsageCategory.allCases.map { usage[$0]! }
    }

    static func size(
        of url: URL,
        progress: (String) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) -> UInt64? {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        var total = allocatedSize(url, keys: keys)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else {
            return total
        }
        var visited = 0
        for case let child as URL in enumerator {
            total += allocatedSize(child, keys: keys)
            visited += 1
            if visited % 256 == 0 {
                if isCancelled() { return nil }
                progress(child.deletingLastPathComponent().path)
            }
        }
        return total
    }

    private static func allocatedSize(_ url: URL, keys: Set<URLResourceKey>) -> UInt64 {
        UInt64((try? url.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
    }

    private static func children(of url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.lastPathComponent != ".DS_Store" }
    }
}
