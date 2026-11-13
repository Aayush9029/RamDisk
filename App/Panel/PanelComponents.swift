import SwiftUI

struct PanelButtonStyle: ButtonStyle {
    var isProminent = false
    var horizontalPadding: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        PanelButtonBody(configuration: configuration, isProminent: isProminent, horizontalPadding: horizontalPadding)
    }
}

private struct PanelButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isProminent: Bool
    let horizontalPadding: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isProminent ? (colorScheme == .dark ? Color.black : Color.white) : Color.primary.opacity(0.92))
            .padding(.horizontal, horizontalPadding)
            .frame(height: 24)
            .glassEffect(.regular.tint(fill).interactive(isEnabled), in: .capsule)
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(.capsule)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var fill: Color {
        if isProminent {
            return .primary.opacity(isHovered ? 1 : 0.9)
        }
        return .primary.opacity(isHovered ? 0.16 : 0.06)
    }
}

/// The glass card behind the panel content. The tint keeps the text legible above bright or dark content.
struct PanelBackground: View {
    static let cornerRadius: CGFloat = 22

    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color {
        colorScheme == .dark
            ? Color(red: 0.05, green: 0.055, blue: 0.065).opacity(0.62)
            : Color.white.opacity(0.68)
    }

    var body: some View {
        Color.clear
            .glassEffect(
                .regular.tint(tint),
                in: .rect(cornerRadius: Self.cornerRadius, style: .continuous)
            )
    }
}

struct PanelHeader<Trailing: View>: View {
    let value: String
    let caption: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value)
                .font(.system(size: 27, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.primary)
            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.5))
            Spacer(minLength: 8)
            trailing
        }
    }
}

struct PanelMenu: View {
    let model: AppModel
    var dismiss: () -> Void

    var body: some View {
        Menu {
            Button("Settings…", systemImage: "gearshape") {
                dismiss()
                model.showSettings()
            }
            if model.disk.isMounted {
                Button("Show in Finder", systemImage: "folder") {
                    model.reveal(nil)
                    dismiss()
                }
                Button("Rescan", systemImage: "arrow.clockwise") { model.rescan() }
                Button("Eject", systemImage: "eject") { model.eject() }
                    .disabled(model.isBusy)
            }
            Divider()
            Button("Quit RamDisk", systemImage: "power") { model.quit() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(PanelButtonStyle(horizontalPadding: 0))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }
}

struct PanelErrorRow: View {
    let model: AppModel
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if model.offersForceEject {
                Button("Force Eject") { model.eject(force: true) }
            }
            Button("Dismiss") { model.dismissError() }
        }
        .buttonStyle(PanelButtonStyle())
        .padding(.top, 14)
    }
}
