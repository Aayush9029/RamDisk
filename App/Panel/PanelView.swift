import RamDiskCore
import SwiftUI

struct PanelView: View {
    static let width: CGFloat = CGFloat(DotBar.defaultColumns) * DotBar.pitch + 40

    let model: AppModel
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            if let message = model.errorMessage {
                PanelErrorRow(model: model, message: message)
            }
        }
        .padding(20)
        .frame(width: Self.width)
        .background { PanelBackground() }
        .animation(.snappy(duration: 0.25), value: model.errorMessage)
        .animation(.smooth(duration: 0.45), value: model.disk.isMounted)
    }

    @ViewBuilder
    private var content: some View {
        switch model.helperState {
        case .ready:
            if model.disk.isMounted {
                DiskView(model: model, dismiss: dismiss)
                    .transition(.blurReplace)
            } else {
                CreateDiskView(model: model, dismiss: dismiss)
                    .transition(.blurReplace)
            }
        case .checking:
            SetupView(
                model: model,
                dismiss: dismiss,
                status: "Starting",
                message: "RamDisk starts its helper.",
                detail: "The helper creates the disk and watches the memory."
            )
        case .needsRegistration:
            SetupView(
                model: model,
                dismiss: dismiss,
                status: "Helper is off",
                message: "Turn on the RamDisk helper to create a disk.",
                detail: "The helper runs in the background and mounts your disk at login. It does not need an administrator password.",
                actionTitle: "Turn On Helper",
                action: model.turnOnHelper
            )
        case .needsApproval:
            SetupView(
                model: model,
                dismiss: dismiss,
                status: "Approval necessary",
                message: "Allow RamDisk in Login Items.",
                detail: "Open System Settings, go to General, then Login Items & Extensions, and turn on RamDisk.",
                actionTitle: "Open System Settings",
                action: model.openLoginItems
            )
        case .unreachable(let reason):
            SetupView(
                model: model,
                dismiss: dismiss,
                status: "Helper does not respond",
                message: "Restart the helper to connect again.",
                detail: reason,
                actionTitle: "Restart Helper",
                action: model.restartHelper
            )
        }
    }
}

private struct SetupView: View {
    let model: AppModel
    var dismiss: () -> Void
    let status: String
    let message: String
    let detail: String
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(value: "RamDisk", caption: status) {
                PanelMenu(model: model, dismiss: dismiss)
            }

            DotBar(widths: AnimatableVector(values: []), scan: 0, colors: [], isAnimating: model.isPanelVisible)
                .padding(.top, 16)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.9))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let actionTitle {
                    Button(actionTitle, action: action)
                        .buttonStyle(PanelButtonStyle(isProminent: true))
                }
            }
            .padding(.top, 16)
        }
    }
}
