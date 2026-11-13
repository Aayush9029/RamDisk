import Foundation
import RamDiskCore

/// Holds the last published status. XPC status calls read it without a wait for the actor, so the UI stays live during a long operation.
final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status = HelperStatus()
    private var lastPoll = Date.distantPast
    private var cancelRequested = false

    func set(_ new: HelperStatus) { lock.withLock { status = new } }

    func read() -> HelperStatus {
        lock.withLock {
            lastPoll = Date()
            return status
        }
    }

    var secondsSincePoll: TimeInterval { lock.withLock { Date().timeIntervalSince(lastPoll) } }

    var isCancelRequested: Bool {
        get { lock.withLock { cancelRequested } }
        set { lock.withLock { cancelRequested = newValue } }
    }
}

public actor HelperCore {
    private static let snapshotExclusions = DiskManager.reservedNames.sorted()

    let box = StatusBox()
    private var status = HelperStatus()
    private let support: URL
    private let binaryPath: String
    private let integrations: AgentIntegrations
    private var activeName: String?
    private var backingProcess: pid_t?
    private var lastScan = Date.distantPast
    private var usedAtLastScan: UInt64 = 0
    private var lastMaintenance = Date()
    private var lastSnapshot = Date()
    private var ticks = 0

    public init(binaryPath: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        support = home.appendingPathComponent("Library/Application Support/\(RamDiskConstants.supportFolderName)")
        self.binaryPath = binaryPath
        integrations = AgentIntegrations(home: home, command: support.appendingPathComponent("bin/ramdisk").path)
    }

    // MARK: - Lifecycle

    public func start() {
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        linkBinary()
        let hasConfiguration = loadConfiguration()
        status.helperBuild = RamDiskConstants.buildStamp(ofExecutableAt: binaryPath)
        status.helperPath = binaryPath
        activeName = DiskManager.mounted(name: status.configuration.volumeName) != nil ? status.configuration.volumeName : nil
        status.agents = integrations.statuses()
        refresh()
        publish()

        if hasConfiguration, status.configuration.mountAtLogin, !status.disk.isMounted, isFirstStartSinceBoot() {
            if let failure = createDisk() {
                status.lastError = failure
                publish()
            }
        }

        Task {
            while true {
                try? await Task.sleep(for: .seconds(1))
                tick()
            }
        }
    }

    public func shutdown() {
        if status.configuration.keepContents, status.disk.isMounted {
            saveSnapshot()
        }
    }

    private func tick() {
        ticks += 1
        refresh()
        if ticks % 5 == 0 {
            status.agents = integrations.statuses()
        }
        if status.disk.isMounted {
            let isWatched = box.secondsSincePoll < 6
            let age = Date().timeIntervalSince(lastScan)
            // A large change since the last scan would show as system space, so a watched disk scans again soon.
            let drift = status.disk.used > usedAtLastScan ? status.disk.used - usedAtLastScan : usedAtLastScan - status.disk.used
            if (isWatched && (age > 12 || (age > 2 && drift > 16 << 20))) || age > 300 {
                scan(isVisible: false)
            }
            runMaintenance()
        }
        publish()
    }

    private func runMaintenance() {
        let now = Date()
        if now.timeIntervalSince(lastMaintenance) > 600 {
            lastMaintenance = now
            let hours = status.configuration.workspaceRetentionHours
            if hours > 0, let root = status.disk.mountPath {
                Workspaces.removeIdle(root: root, olderThan: TimeInterval(hours) * 3600)
            }
        }
        if status.configuration.keepContents, now.timeIntervalSince(lastSnapshot) > 600 {
            saveSnapshot()
        }
    }

    // MARK: - Commands

    func handle(_ command: HelperCommand) -> String? {
        box.isCancelRequested = false
        defer {
            status.activity = .idle
            publish()
        }
        switch command {
        case .createDisk:
            status.lastError = nil
            return createDisk()
        case .eject(let force):
            return eject(force: force)
        case .setConfiguration(let configuration):
            return setConfiguration(configuration)
        case .rescan:
            scan(isVisible: true)
            return nil
        case .clear(let category):
            return clear(category)
        case .setAgentConnected(let kind, let connected):
            defer { status.agents = integrations.statuses() }
            do {
                try integrations.setConnected(kind, connected)
                return nil
            } catch {
                return error.localizedDescription
            }
        case .reveal(let category):
            guard let root = status.disk.mountPath else { return DiskError.notMounted.localizedDescription }
            let path = category?.relativePath.map { root + "/" + $0 } ?? root
            Shell.run("/usr/bin/open", [path])
            return nil
        case .saveSnapshot:
            guard status.disk.isMounted else { return DiskError.notMounted.localizedDescription }
            return saveSnapshot()
        case .reclaimMemory:
            return reclaimMemory()
        case .dismissError:
            status.lastError = nil
            return nil
        case .quit:
            // launchd starts the new build at the next XPC call. The RAM disk stays mounted.
            shutdown()
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                exit(0)
            }
            return nil
        }
    }

    private func createDisk() -> String? {
        let configuration = status.configuration
        status.activity = .creating
        publish()
        do {
            let disk = try DiskManager.create(name: configuration.volumeName, sizeBytes: configuration.sizeBytes)
            activeName = configuration.volumeName
            if configuration.keepContents, hasSnapshot {
                status.activity = .restoringSnapshot
                publish()
                _ = copyTree(from: snapshotURL.path, to: disk.path, deletesExtraFiles: false)
            }
            saveConfiguration()
            refresh()
            scan(isVisible: false)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func eject(force: Bool) -> String? {
        guard let name = activeName else { return DiskError.notMounted.localizedDescription }
        if status.configuration.keepContents, let failure = saveSnapshot() {
            return failure
        }
        status.activity = .ejecting
        publish()
        do {
            try DiskManager.eject(name: name, force: force)
            activeName = nil
            backingProcess = nil
            refresh()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// macOS frees the memory of a RAM disk only at eject. This copies the files to the SSD, makes a new disk, and copies them back.
    private func reclaimMemory() -> String? {
        guard let name = activeName, let root = status.disk.mountPath else {
            return DiskError.notMounted.localizedDescription
        }
        let holding = support.appendingPathComponent("Reclaim")
        let available = (try? support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard UInt64(max(available, 0)) > status.disk.used + DiskConfiguration.gigabyte else {
            return "The SSD does not have the free space to hold the files during the reclaim."
        }

        status.activity = .savingSnapshot
        publish()
        try? FileManager.default.removeItem(at: holding)
        if let failure = copyTree(from: root, to: holding.path, deletesExtraFiles: true) {
            try? FileManager.default.removeItem(at: holding)
            return failure
        }

        status.activity = .ejecting
        publish()
        do {
            try DiskManager.eject(name: name, force: false)
        } catch {
            try? FileManager.default.removeItem(at: holding)
            return error.localizedDescription
        }
        activeName = nil
        backingProcess = nil

        status.activity = .creating
        publish()
        do {
            let disk = try DiskManager.create(name: status.configuration.volumeName, sizeBytes: status.configuration.sizeBytes)
            activeName = status.configuration.volumeName
            status.activity = .restoringSnapshot
            publish()
            if let failure = copyTree(from: holding.path, to: disk.path, deletesExtraFiles: false) {
                return "\(failure) The files are in \(holding.path)."
            }
            try? FileManager.default.removeItem(at: holding)
            refresh()
            scan(isVisible: false)
            return nil
        } catch {
            refresh()
            return "\(error.localizedDescription) The files are in \(holding.path)."
        }
    }

    private func copyTree(from source: String, to destination: String, deletesExtraFiles: Bool) -> String? {
        try? FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        var arguments = ["-a"]
        if deletesExtraFiles { arguments.append("--delete") }
        for name in Self.snapshotExclusions {
            arguments += ["--exclude", "/" + name]
        }
        arguments += [source + "/", destination + "/"]
        let result = Shell.run("/usr/bin/rsync", arguments)
        return result.succeeded ? nil : "The copy did not complete. \(result.message)"
    }

    private func setConfiguration(_ new: DiskConfiguration) -> String? {
        var configuration = new
        configuration.volumeName = DiskConfiguration.sanitizedName(new.volumeName)
        configuration.sizeBytes = DiskConfiguration.clampedSize(new.sizeBytes)
        configuration.diskAlertPercent = min(max(new.diskAlertPercent, 0), 99)
        configuration.workspaceRetentionHours = max(new.workspaceRetentionHours, 0)
        if !configuration.keepContents, status.configuration.keepContents {
            try? FileManager.default.removeItem(at: snapshotURL)
        }
        status.configuration = configuration
        status.hasSnapshot = hasSnapshot
        saveConfiguration()
        return nil
    }

    private func clear(_ category: UsageCategory) -> String? {
        guard category.isClearable, let root = status.disk.mountPath else {
            return DiskError.notMounted.localizedDescription
        }
        let usedBefore = status.disk.used
        var failures = 0
        for item in UsageScanner.items(root: root) where item.category == category {
            status.activity = .clearing(category: category, path: item.url.path)
            publish()
            let size = UsageScanner.size(of: item.url) ?? 0
            do {
                try FileManager.default.removeItem(at: item.url)
                var usage = status.disk[category]
                usage.bytes -= min(size, usage.bytes)
                usage.itemCount = max(0, usage.itemCount - 1)
                status.disk[category] = usage
                status.disk.used -= min(size, status.disk.used)
                publish()
            } catch {
                failures += 1
            }
        }
        DiskManager.createFolders(root: root)
        refresh()
        scan(isVisible: false)
        let freed = usedBefore > status.disk.used ? usedBefore - status.disk.used : 0
        status.lastFreed = FreedSpace(bytes: freed, date: Date())
        return failures == 0 ? nil : "\(failures) items are in use and stay on the disk."
    }

    // MARK: - Disk state

    private func refresh() {
        status.memory = MemoryMonitor.read()
        status.hasSnapshot = hasSnapshot
        guard let name = activeName ?? Optional(status.configuration.volumeName),
              let disk = DiskManager.mounted(name: name)
        else {
            activeName = nil
            backingProcess = nil
            status.disk = DiskState()
            lastScan = .distantPast
            return
        }
        activeName = name
        if backingProcess == nil {
            backingProcess = DiskManager.backingProcess(mountPath: disk.path)
        }
        status.disk.memoryHeld = backingProcess.flatMap(DiskManager.memoryFootprint) ?? disk.used
        status.disk.isMounted = true
        status.disk.mountPath = disk.path
        status.disk.device = disk.device
        status.disk.capacity = disk.capacity
        status.disk.used = disk.used
        applySystemUsage()
    }

    private func scan(isVisible: Bool) {
        guard let root = status.disk.mountPath else { return }
        var lastUpdate = Date.distantPast
        let result = UsageScanner.scan(
            root: root,
            progress: { path in
                guard isVisible, Date().timeIntervalSince(lastUpdate) > 0.05 else { return }
                lastUpdate = Date()
                status.activity = .scanning(path: path)
                publish()
            },
            isCancelled: { box.isCancelRequested }
        )
        guard let result else { return }
        status.disk.categories = result
        applySystemUsage()
        lastScan = Date()
        usedAtLastScan = status.disk.used
    }

    /// APFS keeps space for its own structures. That space is the part of `used` that no folder explains.
    private func applySystemUsage() {
        let counted = status.disk.categories.filter { $0.category != .system }.reduce(UInt64(0)) { $0 + $1.bytes }
        status.disk[.system] = CategoryUsage(
            category: .system,
            bytes: status.disk.used > counted ? status.disk.used - counted : 0
        )
    }

    private func publish() {
        box.set(status)
    }

    // MARK: - Snapshot

    private var snapshotURL: URL { support.appendingPathComponent("Snapshot") }

    private var hasSnapshot: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: snapshotURL.path)) ?? []).isEmpty == false
    }

    @discardableResult
    private func saveSnapshot() -> String? {
        guard let root = status.disk.mountPath else { return nil }
        let previous = status.activity
        status.activity = .savingSnapshot
        publish()
        defer {
            status.activity = previous
            status.hasSnapshot = hasSnapshot
            lastSnapshot = Date()
        }
        return copyTree(from: root, to: snapshotURL.path, deletesExtraFiles: true)
    }

    // MARK: - Files

    private var configurationURL: URL { support.appendingPathComponent("config.json") }

    private func loadConfiguration() -> Bool {
        guard let data = try? Data(contentsOf: configurationURL),
              let configuration = try? JSONDecoder().decode(DiskConfiguration.self, from: data)
        else { return false }
        status.configuration = configuration
        return true
    }

    private func saveConfiguration() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(status.configuration).write(to: configurationURL, options: .atomic)
    }

    /// The helper also starts again after an app update. Only the first start after a boot mounts the disk, so a disk that the user ejected stays ejected.
    private func isFirstStartSinceBoot() -> Bool {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0 else { return true }
        let stamp = String(bootTime.tv_sec)
        let file = support.appendingPathComponent("boot")
        if (try? String(contentsOf: file, encoding: .utf8)) == stamp { return false }
        try? stamp.write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    /// Agent configurations point at this link, so they stay valid when the app moves.
    private func linkBinary() {
        let link = support.appendingPathComponent("bin/ramdisk")
        try? FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == binaryPath { return }
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: binaryPath)
    }
}
