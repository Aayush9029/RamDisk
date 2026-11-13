import Foundation

/// The one line at the bottom of the panel: what to clear, or the result of the last clear.
public struct Suggestion: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case category(UsageCategory)
        case done
        case warning
        case memory
    }

    public enum Action: Equatable, Sendable {
        case clear(UsageCategory)
        case reclaim
    }

    public var tone: Tone
    public var text: String
    public var actionTitle: String?
    public var action: Action?

    init(tone: Tone, text: String, actionTitle: String? = nil, action: Action? = nil) {
        self.tone = tone
        self.text = text
        self.actionTitle = actionTitle
        self.action = action
    }

    public static let clearThreshold: UInt64 = 32 << 20
    public static let reclaimThreshold: UInt64 = 1 << 30

    public static func make(status: HelperStatus, clearing: UsageCategory?, now: Date = Date()) -> Suggestion {
        let disk = status.disk
        if let clearing {
            return Suggestion(
                tone: .category(clearing),
                text: "Clearing \(clearing.displayName.lowercased()).",
                actionTitle: title(for: clearing),
                action: .clear(clearing)
            )
        }
        if status.memory.pressure != .normal, disk.reclaimable > clearThreshold {
            return Suggestion(
                tone: .warning,
                text: "Memory pressure is high.",
                actionTitle: "Reclaim",
                action: .reclaim
            )
        }
        let rebuildable: [UsageCategory] = [.temp, .caches, .builds]
        if let best = rebuildable.map({ disk[$0] }).filter({ $0.bytes >= clearThreshold }).max(by: { $0.bytes < $1.bytes }) {
            let size = ByteFormat.string(best.bytes)
            let text = switch best.category {
            case .temp: "Temporary files use \(size)."
            case .caches: "Caches use \(size)."
            default: "Builds use \(size)."
            }
            return Suggestion(tone: .category(best.category), text: text, actionTitle: title(for: best.category), action: .clear(best.category))
        }
        if disk.reclaimable >= reclaimThreshold {
            return Suggestion(
                tone: .memory,
                text: "Deleted files hold \(ByteFormat.string(disk.reclaimable)) of memory.",
                actionTitle: "Reclaim",
                action: .reclaim
            )
        }
        if let freed = status.lastFreed, now.timeIntervalSince(freed.date) < 30, freed.bytes > 0 {
            return Suggestion(tone: .done, text: "Freed \(ByteFormat.string(freed.bytes)).")
        }
        return Suggestion(tone: .done, text: "Nothing to clear.")
    }

    private static func title(for category: UsageCategory) -> String {
        "Clear"
    }
}
