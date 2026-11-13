import RamDiskCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    @AppStorage("settingsTab") private var selectedTab: SettingsTab = .disk
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: sidebarSelection) {
                Section("RamDisk") {
                    sidebarRow(.disk)
                    sidebarRow(.agents)
                }

                Section("App") {
                    sidebarRow(.general)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(SettingsLayout.sidebarWidth)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            pane
                .id(selectedTab)
                .transition(.opacity)
                .navigationTitle(selectedTab.title)
                .navigationSplitViewColumnWidth(SettingsLayout.detailWidth)
        }
        .navigationSplitViewStyle(.balanced)
        .animation(.easeOut(duration: 0.16), value: selectedTab)
    }

    private var sidebarSelection: Binding<SettingsTab?> {
        Binding(get: { selectedTab }, set: { selectedTab = $0 ?? selectedTab })
    }

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        HStack(spacing: 11) {
            SettingsIconTile(symbol: tab.symbol, fill: tab.fill, size: 25)
            Text(tab.title)
                .font(.body.weight(.medium))
        }
        .padding(.vertical, 5)
        .tag(tab)
    }

    @ViewBuilder
    private var pane: some View {
        switch selectedTab {
        case .disk: DiskPane(model: model)
        case .agents: AgentsPane(model: model)
        case .general: GeneralPane(model: model)
        }
    }
}

private struct DiskPane: View {
    let model: AppModel

    @State private var name = ""
    @State private var size = 0.0

    private static let step = Double(DiskConfiguration.gigabyte / 2)

    private var configuration: DiskConfiguration { model.status.configuration }
    private var steppedSize: Double { (size / Self.step).rounded() * Self.step }

    var body: some View {
        SettingsPaneLayout {
            SettingsPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(ByteFormat.whole(UInt64(steppedSize)))
                            .font(.system(size: 27, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("of \(ByteFormat.whole(model.physicalMemory)) memory")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((steppedSize / Double(model.physicalMemory) * 100).rounded()))%")
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .animation(.snappy(duration: 0.2), value: steppedSize)

                    DotBar(
                        widths: AnimatableVector(values: [steppedSize / Double(model.physicalMemory)]),
                        scan: 0,
                        colors: [BarColor(0x3D8BFF)],
                        rows: 9
                    )
                    .animation(.spring(duration: 0.35, bounce: 0.1), value: steppedSize)

                    PanelSlider(
                        value: $size,
                        range: Self.step * 2...Double(model.physicalMemory),
                        tint: .accentColor,
                        onEnded: commitSize
                    )
                }
                .frame(width: CGFloat(DotBar.defaultColumns) * DotBar.pitch)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }

            SettingsPanel {
                SettingsControlRow(title: "Name", symbol: "externaldrive", tint: .blue) {
                    SettingsTextField(placeholder: "RamDisk", text: $name, isMonospaced: false)
                        .frame(width: 200)
                        .onSubmit(commitName)
                }

                SettingsCardDivider()

                SettingsControlRow(title: "Mount at Login", symbol: "power", tint: .gray) {
                    SettingsSwitch(isOn: configuration.mountAtLogin) { value in
                        model.update { $0.mountAtLogin = value }
                    }
                }

                SettingsCardDivider()

                SettingsControlRow(
                    title: "Keep Contents",
                    description: "Copy the disk to the SSD at eject and each 10 minutes. Restore the copy at the next mount.",
                    symbol: "clock.arrow.circlepath",
                    tint: .green
                ) {
                    SettingsSwitch(isOn: configuration.keepContents) { value in
                        model.update { $0.keepContents = value }
                    }
                }
            }

            if model.needsRemount {
                SettingsPanel {
                    SettingsControlRow(
                        title: "Remount Necessary",
                        description: configuration.keepContents
                            ? "The mounted disk uses the old name or size. A remount restores its contents."
                            : "The mounted disk uses the old name or size. A remount erases the disk.",
                        symbol: "exclamationmark.triangle",
                        tint: .orange
                    ) {
                        SettingsActionButton(title: "Remount", action: model.remount)
                            .disabled(model.isBusy)
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: configuration) { load() }
    }

    private func load() {
        name = configuration.volumeName
        size = Double(configuration.sizeBytes)
    }

    private func commitName() {
        name = DiskConfiguration.sanitizedName(name)
        model.update { $0.volumeName = name }
    }

    private func commitSize() {
        size = steppedSize
        model.update { $0.sizeBytes = UInt64(size) }
    }
}

private struct AgentsPane: View {
    let model: AppModel

    private static let retentionChoices = [0: "Never", 1: "After 1 hour", 6: "After 6 hours", 24: "After 1 day", 168: "After 1 week"]

    var body: some View {
        SettingsPaneLayout {
            SettingsPanel {
                ForEach(model.status.agents) { agent in
                    if agent.id != model.status.agents.first?.id {
                        SettingsCardDivider()
                    }
                    SettingsControlRow(title: agent.kind.displayName, description: agent.detail) {
                        CategoryIcon(category: agent.kind.category, size: 26)
                    } control: {
                        if agent.kind == .t3Code {
                            Text(agent.isConnected ? "Connected" : "Not connected")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            SettingsSwitch(isOn: agent.isConnected) { model.setAgent(agent.kind, connected: $0) }
                                .disabled(!agent.isInstalled)
                        }
                    }
                }
            }

            SettingsPanel {
                SettingsControlRow(
                    title: "Remove Idle Workspaces",
                    description: "Delete a workspace folder that no agent used for this time.",
                    symbol: "trash",
                    tint: .red
                ) {
                    SettingsMenuPicker(
                        values: Self.retentionChoices.keys.sorted(),
                        selection: model.status.configuration.workspaceRetentionHours,
                        title: { Self.retentionChoices[$0] ?? "\($0) hours" }
                    ) { hours in
                        model.update { $0.workspaceRetentionHours = hours }
                    }
                }
            }
        }
    }
}

private struct GeneralPane: View {
    let model: AppModel

    private static let alertChoices = [0: "Off", 75: "At 75%", 90: "At 90%", 95: "At 95%"]

    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

    private static let toolPath = "~/Library/Application Support/\(RamDiskConstants.supportFolderName)/bin/ramdisk"

    var body: some View {
        SettingsPaneLayout {
            SettingsPanel {
                SettingsControlRow(
                    title: "Launch at Login",
                    description: "Open RamDisk automatically when you log in.",
                    symbol: "power",
                    tint: .gray
                ) {
                    SettingsSwitch(isOn: launchesAtLogin, onChange: setLaunchesAtLogin)
                }
            }

            SettingsPanel {
                SettingsControlRow(
                    title: "Disk Almost Full",
                    description: "Send a notification when the disk reaches this level.",
                    symbol: "externaldrive.badge.exclamationmark",
                    tint: .orange
                ) {
                    SettingsMenuPicker(
                        values: Self.alertChoices.keys.sorted(),
                        selection: model.status.configuration.diskAlertPercent,
                        title: { Self.alertChoices[$0] ?? "At \($0)%" }
                    ) { percent in
                        model.update { $0.diskAlertPercent = percent }
                    }
                }

                SettingsCardDivider()

                SettingsControlRow(
                    title: "High Memory Pressure",
                    description: "Send a notification when macOS reports high memory pressure.",
                    symbol: "gauge.with.needle",
                    tint: .pink
                ) {
                    SettingsSwitch(isOn: model.status.configuration.memoryAlerts) { value in
                        model.update { $0.memoryAlerts = value }
                    }
                }
            }

            SettingsPanel {
                SettingsControlRow(title: "Command Line Tool", description: Self.toolPath, symbol: "terminal", tint: .black) {
                    SettingsActionButton(title: "Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.toolPath, forType: .string)
                    }
                }
            }
        }
    }

    private func setLaunchesAtLogin(_ isOn: Bool) {
        do {
            if isOn { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}
