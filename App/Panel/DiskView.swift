import RamDiskCore
import SwiftUI

/// The panel content for a mounted disk.
struct DiskView: View {
    let model: AppModel
    var dismiss: () -> Void

    @State private var isRevealed = false
    @State private var isIntroGlowing = false

    private var disk: DiskState { model.disk }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(value: ByteFormat.string(disk.used), caption: "of \(ByteFormat.string(disk.capacity)) used") {
                PanelMenu(model: model, dismiss: dismiss)
            }
            .animation(.snappy(duration: 0.3), value: disk.used)

            StatusLine(model: model)
                .padding(.top, 5)

            bar
                .padding(.top, 14)

            LegendGrid(model: model)
                .padding(.top, 14)

            MemoryRow(memory: model.status.memory, diskHeld: disk.memoryHeld, isAnimating: model.isPanelVisible)
                .padding(.top, 16)

            if Suggestion.make(status: model.status, clearing: model.clearing).action != nil {
                Divider()
                    .padding(.horizontal, -20)
                    .padding(.top, 16)

                SuggestionRow(model: model)
                    .padding(.top, 14)
            }
        }
        .task(id: model.introToken) {
            await playIntro()
        }
    }

    private var bar: some View {
        DotBar(
            widths: AnimatableVector(values: isRevealed ? Self.widths(disk) : []),
            scan: isScanning ? 1 : 0,
            colors: UsageCategory.displayOrder.map(\.barColor),
            hovered: model.hovered.flatMap(UsageCategory.displayOrder.firstIndex),
            emberSource: model.clearing.flatMap(UsageCategory.displayOrder.firstIndex),
            isAnimating: model.isPanelVisible
        )
        .animation(.spring(duration: 0.85, bounce: 0.12), value: isRevealed)
        .animation(.spring(duration: 0.7, bounce: 0.05), value: disk.categories)
        .animation(.easeOut(duration: 0.45), value: isScanning)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): model.hovered = category(at: point.x)
            case .ended: model.hovered = nil
            }
        }
    }

    private var isScanning: Bool {
        if isIntroGlowing { return true }
        switch model.status.activity {
        case .scanning, .creating, .restoringSnapshot: return true
        default: return false
        }
    }

    private func playIntro() async {
        isRevealed = false
        isIntroGlowing = true
        try? await Task.sleep(for: .milliseconds(60))
        isRevealed = true
        try? await Task.sleep(for: .milliseconds(900))
        isIntroGlowing = false
    }

    private func category(at x: CGFloat) -> UsageCategory? {
        let fraction = x / (CGFloat(DotBar.defaultColumns) * DotBar.pitch)
        var cursor = 0.0
        for (category, width) in zip(UsageCategory.displayOrder, Self.widths(disk)) where width > 0 {
            cursor += width
            if fraction < cursor { return category }
        }
        return nil
    }

    /// A category that holds data gets two columns or more, so a small category stays visible.
    static func widths(_ disk: DiskState, columns: Double = Double(DotBar.defaultColumns)) -> [Double] {
        guard disk.capacity > 0 else { return [] }
        var widths = UsageCategory.displayOrder.map { category -> Double in
            let bytes = disk[category].bytes
            return bytes == 0 ? 0 : max(Double(bytes) / Double(disk.capacity), 2 / columns)
        }
        let total = widths.reduce(0, +)
        if total > 1 {
            widths = widths.map { $0 / total }
        }
        return widths
    }
}

private struct StatusLine: View {
    let model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            content
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .frame(height: 16, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch model.status.activity {
        case .creating:
            label("Creating the disk")
        case .ejecting:
            label("Ejecting")
        case .savingSnapshot:
            label("Saving a copy to the SSD")
        case .restoringSnapshot:
            label("Restoring the saved copy")
        case .scanning(let path):
            label("Calculating")
            pathText(path)
        case .clearing(let category, let path):
            label("Clearing \(category.displayName.lowercased())")
            pathText(path)
        case .idle:
            idle
        }
    }

    @ViewBuilder
    private var idle: some View {
        if let hovered = model.hovered {
            let usage = model.disk[hovered]
            HStack(spacing: 5) {
                CategoryIcon(category: hovered)
                label(hovered.displayName)
            }
            Text(ByteFormat.string(usage.bytes))
                .foregroundStyle(.primary.opacity(0.6))
                .monospacedDigit()
            Text(hovered.detail(for: usage))
                .foregroundStyle(.primary.opacity(0.4))
                .truncationMode(.middle)
        } else if let freed = model.status.lastFreed, Date().timeIntervalSince(freed.date) < 8, freed.bytes > 0 {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
            label("Freed \(ByteFormat.string(freed.bytes)).")
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .fontWeight(.medium)
            .foregroundStyle(.primary.opacity(0.88))
    }

    private func pathText(_ path: String) -> some View {
        Text(path)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.4))
            .truncationMode(.middle)
    }
}

private struct LegendGrid: View {
    let model: AppModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(UsageCategory.displayOrder.filter { model.disk[$0].bytes > 0 }) { category in
                LegendRow(
                    category: category,
                    usage: model.disk[category],
                    isDimmed: model.hovered != nil && model.hovered != category,
                    isHighlighted: model.hovered == category,
                    hover: { model.hovered = $0 ? category : (model.hovered == category ? nil : model.hovered) },
                    reveal: { model.reveal(category) },
                    clear: { model.clear(category) }
                )
            }
        }
        .padding(.horizontal, -5)
    }
}

private struct LegendRow: View {
    let category: UsageCategory
    let usage: CategoryUsage
    let isDimmed: Bool
    let isHighlighted: Bool
    var hover: (Bool) -> Void
    var reveal: () -> Void
    var clear: () -> Void

    var body: some View {
        Button(action: reveal) {
            HStack(spacing: 0) {
                CategoryIcon(category: category)
                    .padding(.trailing, 5)
                Text(category.displayName)
                    .foregroundStyle(.primary.opacity(0.9))
                Spacer(minLength: 4)
                Text(usage.bytes == 0 ? "–" : ByteFormat.string(usage.bytes))
                    .foregroundStyle(.primary.opacity(0.42))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .fixedSize()
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(height: 24)
            .background(.primary.opacity(isHighlighted ? 0.07 : 0), in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isDimmed ? 0.32 : 1)
        .animation(.easeOut(duration: 0.15), value: isDimmed)
        .animation(.easeOut(duration: 0.15), value: isHighlighted)
        .onHover(perform: hover)
        .contextMenu {
            if category.relativePath != nil {
                Button("Show in Finder", systemImage: "folder", action: reveal)
            }
            if category.isClearable {
                Button("Clear \(category.displayName)", systemImage: "trash", role: .destructive, action: clear)
                    .disabled(usage.bytes == 0)
            }
        }
        .accessibilityLabel("\(category.displayName), \(ByteFormat.string(usage.bytes))")
        .help(category.relativePath == nil ? category.detail(for: usage) : "Show \(category.displayName) in Finder")
    }
}

private struct MemoryRow: View {
    let memory: MemoryStats
    let diskHeld: UInt64
    let isAnimating: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var colors: [BarColor] {
        [BarColor(colorScheme == .dark ? 0xF2EDE4 : 0x2E3138), BarColor(0x8F9BB0), BarColor(0x5E6B82), BarColor(0x7C6BD6)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Memory")
                    .fontWeight(.medium)
                    .foregroundStyle(.primary.opacity(0.88))
                Text("\(ByteFormat.string(memory.used)) of \(ByteFormat.whole(memory.total))")
                    .foregroundStyle(.primary.opacity(0.42))
                    .monospacedDigit()
                Spacer()
                if memory.pressure != .normal {
                    Text(pressureText)
                        .foregroundStyle(.primary.opacity(0.7))
                }
                Circle()
                    .fill(pressureColor)
                    .frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
            }
            .font(.system(size: 12))
            .lineLimit(1)

            DotBar(
                widths: AnimatableVector(values: widths),
                scan: 0,
                colors: colors,
                rows: 3,
                isAnimating: isAnimating
            )
            .animation(.spring(duration: 0.8), value: widths)
        }
        .accessibilityElement(children: .combine)
    }

    /// The disk pages are part of the app memory that macOS reports, so the strip takes them out of that part.
    private var widths: [Double] {
        guard memory.total > 0 else { return [] }
        let total = Double(memory.total)
        let disk = min(diskHeld, memory.app)
        return [disk, memory.app - disk, memory.wired, memory.compressed].map { Double($0) / total }
    }

    private var pressureColor: Color {
        switch memory.pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }

    private var pressureText: String {
        switch memory.pressure {
        case .normal: "Pressure normal"
        case .warning: "Pressure high"
        case .critical: "Pressure critical"
        }
    }
}

private struct SuggestionRow: View {
    let model: AppModel

    var body: some View {
        let suggestion = Suggestion.make(status: model.status, clearing: model.clearing)
        HStack(spacing: 8) {
            icon(suggestion.tone)
                .frame(width: 14)
            Text(suggestion.text)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.75))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let title = suggestion.actionTitle, let action = suggestion.action {
                Button(title) {
                    switch action {
                    case .clear(let category): model.clear(category)
                    case .reclaim: model.reclaimMemory()
                    }
                }
                .buttonStyle(PanelButtonStyle())
                .disabled(model.clearing != nil || model.isBusy)
            }
        }
        .frame(minHeight: 24)
    }

    @ViewBuilder
    private func icon(_ tone: Suggestion.Tone) -> some View {
        switch tone {
        case .category(let category):
            CategoryIcon(category: category)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.yellow)
        case .memory:
            Image(systemName: "memorychip")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.6))
        }
    }
}
