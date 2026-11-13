import RamDiskCore
import SwiftUI

/// The panel content when no disk is mounted: choose a share of the memory and create the disk.
struct CreateDiskView: View {
    let model: AppModel
    var dismiss: () -> Void

    private static let step = Double(DiskConfiguration.gigabyte / 2)
    private static let colors = [BarColor(0x3D8BFF), BarColor(0x7C8798)]

    private var total: Double { Double(model.physicalMemory) }
    private var share: Double { Double(model.draftSize) / total }
    @State private var fill = 1.0

    private var isCreating: Bool { model.status.activity == .creating || model.status.activity == .restoringSnapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(value: ByteFormat.whole(model.draftSize), caption: "of \(ByteFormat.whole(model.physicalMemory)) memory") {
                PanelMenu(model: model, dismiss: dismiss)
            }
            .animation(.snappy(duration: 0.2), value: model.draftSize)

            HStack(spacing: 8) {
                Text(isCreating ? "Creating the disk" : "Not mounted")
                    .fontWeight(.medium)
                    .foregroundStyle(.primary.opacity(0.88))
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .frame(height: 16)
            .padding(.top, 5)

            DotBar(
                widths: AnimatableVector(values: widths),
                scan: isCreating ? 1 : 0,
                colors: Self.colors,
                isAnimating: model.isPanelVisible
            )
            .animation(.spring(duration: 0.35, bounce: 0.1), value: model.draftSize)
            .onChange(of: isCreating) { _, creating in
                guard creating else { return }
                // The bar fills again from zero with a bright front, in a loop, until the disk mounts.
                fill = 0
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) { fill = 1 }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    setShare(value.location.x / (CGFloat(DotBar.defaultColumns) * DotBar.pitch))
                }
            )
            .padding(.top, 14)

            PanelSlider(
                value: Binding(get: { Double(model.draftSize) }, set: { setSize($0) }),
                range: Self.step * 2...total,
                tint: Self.colors[0].color
            )
            .padding(.top, 14)
            .opacity(isCreating ? 0.25 : 1)
            .animation(.easeOut(duration: 0.25), value: isCreating)
            .accessibilityLabel("Disk size")
            .accessibilityValue(ByteFormat.whole(model.draftSize))

            HStack(spacing: 8) {
                Image(systemName: isLarge ? "exclamationmark.triangle.fill" : "memorychip")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isLarge ? .yellow : .primary.opacity(0.5))
                    .frame(width: 14)
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.75))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(isCreating ? "Creating…" : "Create Disk") { model.createDisk() }
                    .buttonStyle(PanelButtonStyle(isProminent: true))
                    .disabled(model.isBusy)
            }
            .frame(minHeight: 24)
            .padding(.top, 14)
        }
        .disabled(isCreating)
    }

    private var isLarge: Bool { share > 0.8 }

    private var caption: String {
        let percent = Int((share * 100).rounded())
        if isLarge {
            return "\(percent)% of memory. macOS can swap."
        }
        let memory = model.status.memory
        let free = memory.total > memory.used ? memory.total - memory.used : 0
        return "\(percent)% of memory, \(ByteFormat.string(free)) free"
    }

    /// The blue part is the disk. The gray part is the memory that is in use now, cut off at the end of the bar.
    private var widths: [Double] {
        let used = Double(model.status.memory.used) / total
        return isCreating ? [share * fill] : [share, max(0, min(used, 1 - share))]
    }

    private func setShare(_ fraction: Double) {
        setSize(min(max(fraction, 0), 1) * total)
    }

    private func setSize(_ bytes: Double) {
        let stepped = (bytes / Self.step).rounded() * Self.step
        model.draftSize = DiskConfiguration.clampedSize(UInt64(max(stepped, Self.step * 2)), physicalMemory: model.physicalMemory)
    }
}
