import Foundation
import RamDiskCore

public struct Workspace: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var owner: String
    public var modified: Date
}

public enum WorkspaceError: LocalizedError, Equatable {
    case outsideWorkspaces(String)

    public var errorDescription: String? {
        switch self {
        case .outsideWorkspaces(let path): "\(path) is not a RamDisk workspace."
        }
    }
}

public enum Workspaces {
    public static func slug(_ name: String?) -> String {
        let source = (name ?? "").lowercased()
        var slug = ""
        for scalar in source.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                slug.unicodeScalars.append(scalar)
            } else if !slug.hasSuffix("-"), !slug.isEmpty {
                slug.append("-")
            }
        }
        slug = String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "workspace" : slug
    }

    /// `owner` is an agent folder name. An unknown MCP client gets the folder `other`.
    public static func create(root: String, owner: String, name: String?) throws -> String {
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let path = "\(root)/agents/\(owner)/\(slug(name))-\(suffix)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    public static func list(root: String) -> [Workspace] {
        let manager = FileManager.default
        let agents = root + "/agents"
        var result: [Workspace] = []
        for owner in (try? manager.contentsOfDirectory(atPath: agents)) ?? [] {
            let names = (try? manager.contentsOfDirectory(atPath: agents + "/" + owner)) ?? []
            for name in names where name != ".DS_Store" {
                let path = "\(agents)/\(owner)/\(name)"
                result.append(Workspace(
                    name: name,
                    path: path,
                    owner: owner,
                    modified: lastActivity(of: URL(fileURLWithPath: path))
                ))
            }
        }
        return result.sorted { $0.modified > $1.modified }
    }

    public static func remove(root: String, path: String) throws {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = URL(fileURLWithPath: root).standardizedFileURL.path + "/agents/"
        let components = target.dropFirst(prefix.count).split(separator: "/")
        guard target.hasPrefix(prefix), components.count == 2 else {
            throw WorkspaceError.outsideWorkspaces(path)
        }
        try FileManager.default.removeItem(atPath: target)
    }

    @discardableResult
    public static func removeIdle(root: String, olderThan interval: TimeInterval, now: Date = Date()) -> Int {
        var removed = 0
        for workspace in list(root: root) where now.timeIntervalSince(workspace.modified) > interval {
            if (try? FileManager.default.removeItem(atPath: workspace.path)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// A folder date changes only when a direct child changes, so the newest direct child counts too.
    private static func lastActivity(of url: URL) -> Date {
        let key: Set<URLResourceKey> = [.contentModificationDateKey]
        var newest = (try? url.resourceValues(forKeys: key))?.contentModificationDate ?? .distantPast
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(key))) ?? []
        for child in children {
            if let date = (try? child.resourceValues(forKeys: key))?.contentModificationDate, date > newest {
                newest = date
            }
        }
        return newest
    }
}
