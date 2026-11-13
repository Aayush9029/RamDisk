import AppKit
import Observation
import RamDiskCore
import SwiftUI

enum HelperState: Equatable {
    case checking
    case needsRegistration
    case needsApproval
    case ready
    case unreachable(String)
}

@MainActor
@Observable
final class AppModel {
    private(set) var status = HelperStatus()
    private(set) var helperState = HelperState.checking
    private(set) var hasLoadedStatus = false
    var hovered: UsageCategory?
    var draftSize: UInt64 = DiskConfiguration.defaultSize()
    var errorMessage: String?
    private(set) var offersForceEject = false
    /// The category that shows the ember effect. It stays set for a moment after a fast clear, so the effect is visible.
    private(set) var clearing: UsageCategory?
    /// Increases each time the panel opens. The bar plays its intro when the value changes.
    private(set) var introToken = 0
    private(set) var isPanelVisible = false
    var isSettingsVisible = false
    var showSettings: () -> Void = {}

    private let helper: HelperClient
    private let notifier = Notifier()
    private var pollTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var didRequestHelperRestart = false
    private var didTryRegistration = false
    private var didTryRecovery = false

    let physicalMemory = ProcessInfo.processInfo.physicalMemory

    init(helper: HelperClient = .live) {
        self.helper = helper
    }

    var disk: DiskState { status.disk }
    var isBusy: Bool { status.activity.isBusy }
    var isWatched: Bool { isPanelVisible || isSettingsVisible }

    // MARK: - Lifecycle

    func start() {
        // The disk needs the helper, so the app registers it. A helper that the user turned off in System Settings stays off.
        if !didTryRegistration, [.notRegistered, .notFound].contains(helper.registration()) {
            didTryRegistration = true
            turnOnHelper()
            return
        }
        refreshRegistration()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    private var pollInterval: Duration {
        guard helperState == .ready else { return .seconds(2) }
        if !isWatched { return .seconds(10) }
        return isBusy || clearing != nil ? .milliseconds(120) : .milliseconds(900)
    }

    func panelDidOpen() {
        isPanelVisible = true
        introToken += 1
        if disk.isMounted, !isBusy {
            run(.rescan)
        }
        wake()
    }

    func panelDidClose() {
        isPanelVisible = false
        hovered = nil
    }

    /// Restarts the poll loop, so a change shows without a wait for the idle interval.
    func wake() {
        start()
    }

    private func refreshRegistration() {
        switch helper.registration() {
        case .enabled:
            if helperState != .ready, !isUnreachable { helperState = .checking }
        case .requiresApproval:
            helperState = .needsApproval
        case .notRegistered, .notFound:
            helperState = .needsRegistration
        }
    }

    private var isUnreachable: Bool {
        if case .unreachable = helperState { return true }
        return false
    }

    private func poll() async {
        guard helper.registration() == .enabled else {
            refreshRegistration()
            return
        }
        do {
            let new = try await helper.status()
            consecutiveFailures = 0
            if !didRequestHelperRestart, new.helperPath != helper.bundledPath() {
                // The registration points at a different copy of the app, for example after a move to /Applications.
                didRequestHelperRestart = true
                restartHelper()
                return
            }
            if !didRequestHelperRestart, new.helperBuild != helper.bundledBuild() {
                didRequestHelperRestart = true
                try? await helper.run(.quit)
                return
            }
            apply(new)
        } catch {
            consecutiveFailures += 1
            guard consecutiveFailures >= 3 else { return }
            // A job that launchd lost comes back with a new registration. One automatic try is sufficient.
            if didTryRecovery {
                helperState = .unreachable(error.localizedDescription)
            } else {
                didTryRecovery = true
                restartHelper()
            }
        }
    }

    private func apply(_ new: HelperStatus) {
        if !hasLoadedStatus || (!new.disk.isMounted && !isBusy && status.configuration != new.configuration) {
            draftSize = new.configuration.sizeBytes
        }
        hasLoadedStatus = true
        helperState = .ready
        if status != new {
            status = new
        }
        if let lastError = new.lastError, errorMessage == nil {
            errorMessage = lastError
            run(.dismissError)
        }
        notifier.evaluate(new)
    }

    // MARK: - Helper setup

    func turnOnHelper() {
        do {
            try helper.register()
        } catch {
            if helper.registration() != .requiresApproval {
                errorMessage = "macOS did not register the helper. \(error.localizedDescription)"
            }
        }
        refreshRegistration()
        wake()
    }

    func openLoginItems() {
        helper.openLoginItems()
    }

    func restartHelper() {
        Task {
            await helper.unregister()
            try? await Task.sleep(for: .milliseconds(400))
            consecutiveFailures = 0
            helperState = .checking
            turnOnHelper()
        }
    }

    // MARK: - Intents

    func createDisk() {
        var configuration = status.configuration
        configuration.sizeBytes = draftSize
        Task {
            await send(.setConfiguration(configuration))
            await send(.createDisk)
            introToken += 1
        }
    }

    func eject(force: Bool = false) {
        dismissError()
        Task {
            if await !send(.eject(force: force)), !force {
                offersForceEject = true
            }
        }
    }

    func dismissError() {
        errorMessage = nil
        offersForceEject = false
    }

    func rescan() {
        introToken += 1
        run(.rescan)
    }

    func reclaimMemory() {
        Task {
            await send(.reclaimMemory)
            introToken += 1
        }
    }

    func reveal(_ category: UsageCategory?) {
        run(.reveal(category))
    }

    func clear(_ category: UsageCategory) {
        guard clearing == nil else { return }
        clearing = category
        Task {
            async let minimum: Void? = try? Task.sleep(for: .milliseconds(1400))
            await send(.clear(category))
            _ = await minimum
            clearing = nil
        }
    }

    func setAgent(_ kind: AgentKind, connected: Bool) {
        run(.setAgentConnected(kind, connected))
    }

    func update(_ change: (inout DiskConfiguration) -> Void) {
        var configuration = status.configuration
        change(&configuration)
        guard configuration != status.configuration else { return }
        status.configuration = configuration
        run(.setConfiguration(configuration))
    }

    /// The mounted disk keeps its size and name. A change needs a new disk.
    var needsRemount: Bool {
        guard disk.isMounted, let path = disk.mountPath else { return false }
        let mountedName = URL(fileURLWithPath: path).lastPathComponent
        let difference = disk.capacity > status.configuration.sizeBytes
            ? disk.capacity - status.configuration.sizeBytes
            : status.configuration.sizeBytes - disk.capacity
        return mountedName != status.configuration.volumeName || difference > status.configuration.sizeBytes / 20
    }

    func remount() {
        Task {
            guard await send(.eject(force: false)) else { return }
            await send(.createDisk)
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func run(_ command: HelperCommand) {
        Task { await send(command) }
    }

    @discardableResult
    private func send(_ command: HelperCommand) async -> Bool {
        do {
            try await helper.run(command)
            await poll()
            return true
        } catch {
            if command != .dismissError, command != .rescan {
                errorMessage = error.localizedDescription
            }
            await poll()
            return false
        }
    }
}
