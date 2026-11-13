import SwiftUI

struct SettingsPaneLayout<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content()
            }
            .frame(width: SettingsLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, SettingsLayout.contentPadding)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { SettingsBackdrop() }
    }
}

struct SettingsActionButton: View {
    let title: String
    var tint = Color.accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 2)
        }
        .buttonStyle(.glassProminent)
        .tint(tint)
        .controlSize(.small)
    }
}

struct SettingsControlRow<Icon: View, Control: View>: View {
    let title: String
    var description: String?
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            icon()

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 48)
    }
}

extension SettingsControlRow where Icon == SettingsIconTile {
    init(title: String, description: String? = nil, symbol: String, tint: Color = .gray, @ViewBuilder control: @escaping () -> Control) {
        self.init(title: title, description: description, icon: { SettingsIconTile(symbol: symbol, fill: tint, size: 26) }, control: control)
    }
}

struct SettingsCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.65))
            .frame(height: 1)
    }
}
