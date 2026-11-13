import RamDiskCore
import SwiftUI

extension UsageCategory {
    /// The bar and the legend use this order. It keeps the colors in spectrum order, with the fixed file system cost last.
    static let displayOrder: [UsageCategory] = [
        .codex, .openCode, .t3Code, .builds, .caches, .temp, .other, .claudeCode, .system,
    ]

    var barColor: BarColor {
        switch self {
        case .codex: BarColor(0x3D8BFF)
        case .openCode: BarColor(0x34D058)
        case .t3Code: BarColor(0xFF2E93)
        case .builds: BarColor(0xA862FF)
        case .caches: BarColor(0x1FD3EE)
        case .temp: BarColor(0xFFD426)
        case .other: BarColor(0xA3ACBB)
        case .claudeCode: BarColor(0xFF8A24)
        case .system: BarColor(0xFF3B50)
        }
    }

    var symbol: String {
        switch self {
        case .claudeCode: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .t3Code: "bolt.fill"
        case .openCode: "curlybraces"
        case .builds: "hammer.fill"
        case .caches: "shippingbox.fill"
        case .temp: "clock.fill"
        case .other: "doc.fill"
        case .system: "gearshape.fill"
        }
    }

    var appIcon: String? {
        switch self {
        case .claudeCode: "AgentClaudeCode"
        case .codex: "AgentCodex"
        case .t3Code: "AgentT3Code"
        case .openCode: "AgentOpenCode"
        case .builds: "IconBuilds"
        case .caches: "IconCaches"
        case .system: "IconSystem"
        default: nil
        }
    }

    var itemNoun: (one: String, many: String) {
        switch self {
        case .claudeCode, .codex, .t3Code, .openCode: ("workspace", "workspaces")
        case .builds: ("build folder", "build folders")
        default: ("item", "items")
        }
    }

    func detail(for usage: CategoryUsage) -> String {
        switch self {
        case .system:
            return "APFS keeps this space for its own records."
        default:
            guard usage.itemCount > 0 else { return "Empty." }
            let noun = usage.itemCount == 1 ? itemNoun.one : itemNoun.many
            guard usage.itemCount > 1, let largest = usage.largestName else {
                return "\(usage.itemCount) \(noun)."
            }
            return "\(usage.itemCount) \(noun). The largest is \(largest) at \(ByteFormat.string(usage.largestBytes))."
        }
    }
}

/// An agent shows its app icon. Each other category shows a symbol in its bar color.
struct CategoryIcon: View {
    let category: UsageCategory
    var size: CGFloat = 14

    var body: some View {
        if let appIcon = category.appIcon {
            Image(appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .overlay {
                    if category.agent != nil {
                        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                            .strokeBorder(.primary.opacity(0.18), lineWidth: 0.5)
                    }
                }
                .accessibilityHidden(true)
        } else {
            Image(systemName: category.symbol)
                .font(.system(size: size * 0.7, weight: .semibold))
                .foregroundStyle(category.barColor.color)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
