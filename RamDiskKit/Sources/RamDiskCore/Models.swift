import Foundation

public enum RamDiskConstants {
    public static let teamID = "6Q29HJZ4AG"

    // macOS binds an agent label to the first app path that registers it. A debug build has its own label,
    // bundle ID, and support folder, so a run from the build folder cannot take over the installed app.
    #if DEBUG
    public static let machService = "com.optimalapps.RamDisk.agent.debug"
    public static let supportFolderName = "RamDisk-Debug"
    #else
    public static let machService = "com.optimalapps.RamDisk.agent"
    public static let supportFolderName = "RamDisk"
    #endif

    public static let agentPlistName = machService + ".plist"
    public static let mcpServerName = "ramdisk"

    /// Changes with each build of the helper binary. The app uses it to find a helper process that runs an old build.
    public static func buildStamp(ofExecutableAt path: String) -> String {
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return date.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
    }
}

public enum AgentKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case claudeCode, codex, t3Code, openCode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .t3Code: "T3 Code"
        case .openCode: "OpenCode"
        }
    }

    public var folderName: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .t3Code: "t3code"
        case .openCode: "opencode"
        }
    }

    public var category: UsageCategory {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        case .t3Code: .t3Code
        case .openCode: .openCode
        }
    }
}

public enum UsageCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case claudeCode, codex, t3Code, openCode, builds, caches, temp, other, system

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .t3Code: "T3 Code"
        case .openCode: "OpenCode"
        case .builds: "Builds"
        case .caches: "Caches"
        case .temp: "Temporary"
        case .other: "Other"
        case .system: "System"
        }
    }

    public var agent: AgentKind? {
        AgentKind.allCases.first { $0.category == self }
    }

    /// The path of the category folder, relative to the volume root. `other` and `system` have no folder.
    public var relativePath: String? {
        switch self {
        case .builds: "builds"
        case .caches: "caches"
        case .temp: "tmp"
        case .other, .system: nil
        default: agent.map { "agents/\($0.folderName)" }
        }
    }

    public var isClearable: Bool { self != .system }
}

public struct DiskConfiguration: Codable, Equatable, Sendable {
    public var volumeName: String
    public var sizeBytes: UInt64
    public var mountAtLogin: Bool
    public var keepContents: Bool
    /// 0 turns the alert off.
    public var diskAlertPercent: Int
    public var memoryAlerts: Bool
    /// 0 keeps idle workspaces.
    public var workspaceRetentionHours: Int

    public init(
        volumeName: String = "RamDisk",
        sizeBytes: UInt64 = DiskConfiguration.defaultSize(),
        mountAtLogin: Bool = true,
        keepContents: Bool = false,
        diskAlertPercent: Int = 90,
        memoryAlerts: Bool = true,
        workspaceRetentionHours: Int = 0
    ) {
        self.volumeName = volumeName
        self.sizeBytes = sizeBytes
        self.mountAtLogin = mountAtLogin
        self.keepContents = keepContents
        self.diskAlertPercent = diskAlertPercent
        self.memoryAlerts = memoryAlerts
        self.workspaceRetentionHours = workspaceRetentionHours
    }

    public static let gigabyte: UInt64 = 1 << 30
    public static let minimumSize: UInt64 = gigabyte / 4

    public static func defaultSize(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> UInt64 {
        max(gigabyte, (physicalMemory / 4 / gigabyte) * gigabyte)
    }

    public static func clampedSize(_ size: UInt64, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> UInt64 {
        min(max(size, minimumSize), physicalMemory)
    }

    public static func sanitizedName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(name.unicodeScalars.filter(allowed.contains)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "RamDisk" : String(cleaned.prefix(27))
    }
}

public struct CategoryUsage: Codable, Equatable, Sendable, Identifiable {
    public var category: UsageCategory
    public var bytes: UInt64
    public var itemCount: Int
    public var largestName: String?
    public var largestBytes: UInt64

    public var id: UsageCategory { category }

    public init(category: UsageCategory, bytes: UInt64 = 0, itemCount: Int = 0, largestName: String? = nil, largestBytes: UInt64 = 0) {
        self.category = category
        self.bytes = bytes
        self.itemCount = itemCount
        self.largestName = largestName
        self.largestBytes = largestBytes
    }
}

public struct DiskState: Codable, Equatable, Sendable {
    public var isMounted = false
    public var mountPath: String?
    public var device: String?
    public var capacity: UInt64 = 0
    public var used: UInt64 = 0
    /// The memory that macOS holds for the disk. Deleted files do not lower it; only an eject does.
    public var memoryHeld: UInt64 = 0
    public var categories: [CategoryUsage] = UsageCategory.allCases.map { CategoryUsage(category: $0) }

    public init() {}

    public var free: UInt64 { capacity > used ? capacity - used : 0 }
    public var reclaimable: UInt64 { memoryHeld > used ? memoryHeld - used : 0 }

    public subscript(category: UsageCategory) -> CategoryUsage {
        get { categories.first { $0.category == category } ?? CategoryUsage(category: category) }
        set {
            if let index = categories.firstIndex(where: { $0.category == category }) {
                categories[index] = newValue
            } else {
                categories.append(newValue)
            }
        }
    }
}

public enum MemoryPressure: String, Codable, Sendable {
    case normal, warning, critical
}

public struct MemoryStats: Codable, Equatable, Sendable {
    public var total: UInt64 = 0
    public var app: UInt64 = 0
    public var wired: UInt64 = 0
    public var compressed: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var pressure: MemoryPressure = .normal

    public init() {}

    public var used: UInt64 { min(total, app + wired + compressed) }
}

public enum Activity: Codable, Equatable, Sendable {
    case idle
    case creating
    case ejecting
    case scanning(path: String)
    case clearing(category: UsageCategory, path: String)
    case savingSnapshot
    case restoringSnapshot

    public var isBusy: Bool { self != .idle }
}

public struct AgentStatus: Codable, Equatable, Sendable, Identifiable {
    public var kind: AgentKind
    public var isInstalled: Bool
    public var isConnected: Bool
    public var detail: String

    public var id: AgentKind { kind }

    public init(kind: AgentKind, isInstalled: Bool, isConnected: Bool, detail: String) {
        self.kind = kind
        self.isInstalled = isInstalled
        self.isConnected = isConnected
        self.detail = detail
    }
}

public struct FreedSpace: Codable, Equatable, Sendable {
    public var bytes: UInt64
    public var date: Date

    public init(bytes: UInt64, date: Date) {
        self.bytes = bytes
        self.date = date
    }
}

public struct HelperStatus: Codable, Equatable, Sendable {
    public var configuration = DiskConfiguration()
    public var disk = DiskState()
    public var memory = MemoryStats()
    public var activity = Activity.idle
    public var agents: [AgentStatus] = []
    public var lastError: String?
    public var lastFreed: FreedSpace?
    public var hasSnapshot = false
    public var helperBuild = ""
    public var helperPath = ""

    public init() {}
}

public enum HelperCommand: Codable, Equatable, Sendable {
    case createDisk
    case eject(force: Bool)
    case setConfiguration(DiskConfiguration)
    case rescan
    case clear(UsageCategory)
    case setAgentConnected(AgentKind, Bool)
    case reveal(UsageCategory?)
    case saveSnapshot
    case reclaimMemory
    case dismissError
    case quit
}

@objc public protocol HelperXPCProtocol {
    func status(reply: @escaping @Sendable (Data) -> Void)
    func run(_ command: Data, reply: @escaping @Sendable (String?) -> Void)
}
