import SwiftUI

enum SettingsTab: String, Hashable, CaseIterable {
    case disk
    case agents
    case general

    var title: String {
        switch self {
        case .disk: "Disk"
        case .agents: "Agents"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .disk: "externaldrive"
        case .agents: "sparkles"
        case .general: "gearshape"
        }
    }

    var fill: Color {
        switch self {
        case .disk: .blue
        case .agents: .purple
        case .general: .indigo
        }
    }
}
