import Foundation
import RamDiskCore

public enum DiskError: LocalizedError, Equatable {
    case volumeNameInUse(String)
    case attachFailed(String)
    case formatFailed(String)
    case ejectFailed(String)
    case notMounted

    public var errorDescription: String? {
        switch self {
        case .volumeNameInUse(let name): "A different volume with the name “\(name)” is mounted. Change the disk name in Settings."
        case .attachFailed(let reason): "macOS did not allocate the RAM disk. \(reason)"
        case .formatFailed(let reason): "macOS did not format the RAM disk. \(reason)"
        case .ejectFailed(let reason): "The disk is in use. \(reason)"
        case .notMounted: "The RAM disk is not mounted."
        }
    }
}

struct MountedDisk: Equatable {
    var path: String
    var device: String
    var capacity: UInt64
    var used: UInt64
}

enum DiskManager {
    static let markerName = ".ramdisk"
    static let reservedNames: Set<String> = [
        markerName, ".metadata_never_index", ".fseventsd", ".Trashes", ".Spotlight-V100",
        ".DS_Store", ".TemporaryItems", ".DocumentRevisions-V100",
    ]

    static func mountPath(for name: String) -> String { "/Volumes/\(name)" }

    static func mounted(name: String) -> MountedDisk? {
        let path = mountPath(for: name)
        guard FileManager.default.fileExists(atPath: path + "/" + markerName) else { return nil }
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let device = withUnsafePointer(to: &info.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let blockSize = UInt64(info.f_bsize)
        let capacity = UInt64(info.f_blocks) * blockSize
        let available = UInt64(info.f_bavail) * blockSize
        return MountedDisk(path: path, device: device, capacity: capacity, used: capacity > available ? capacity - available : 0)
    }

    /// The `diskimages-helper` process that holds the pages of the disk mounted at `path`.
    static func backingProcess(mountPath path: String) -> pid_t? {
        let info = Shell.run("/usr/bin/hdiutil", ["info"])
        guard info.succeeded else { return nil }
        return backingProcess(mountPath: path, hdiutilInfo: info.output)
    }

    static func backingProcess(mountPath path: String, hdiutilInfo: String) -> pid_t? {
        for block in hdiutilInfo.components(separatedBy: "================================================") {
            let lines = block.split(separator: "\n")
            guard lines.contains(where: { $0.hasPrefix("image-path") && $0.contains("ram://") }),
                  lines.contains(where: { $0.hasSuffix("\t" + path) }),
                  let line = lines.first(where: { $0.hasPrefix("process ID") }),
                  let value = line.split(separator: ":").last
            else { continue }
            return pid_t(value.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func memoryFootprint(of pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage.ri_phys_footprint : nil
    }

    static func create(name: String, sizeBytes: UInt64) throws -> MountedDisk {
        if let existing = mounted(name: name) { return existing }
        let path = mountPath(for: name)
        if FileManager.default.fileExists(atPath: path) {
            throw DiskError.volumeNameInUse(name)
        }

        let sectors = sizeBytes / 512
        let attach = Shell.run("/usr/bin/hdiutil", ["attach", "-nomount", "ram://\(sectors)"])
        let device = attach.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard attach.succeeded, device.hasPrefix("/dev/") else {
            throw DiskError.attachFailed(attach.message)
        }

        let format = Shell.run("/usr/sbin/diskutil", ["eraseVolume", "APFS", name, device])
        guard format.succeeded else {
            Shell.run("/usr/bin/hdiutil", ["detach", device, "-force"])
            throw DiskError.formatFailed(format.message)
        }

        let manager = FileManager.default
        manager.createFile(atPath: path + "/" + markerName, contents: Data(device.utf8))
        // Spotlight and FSEvents logs cost CPU and space on a disk that holds only scratch files.
        manager.createFile(atPath: path + "/.metadata_never_index", contents: nil)
        try? manager.createDirectory(atPath: path + "/.fseventsd", withIntermediateDirectories: true)
        manager.createFile(atPath: path + "/.fseventsd/no_log", contents: nil)
        createFolders(root: path)

        guard let disk = mounted(name: name) else {
            throw DiskError.formatFailed("The volume did not mount at \(path).")
        }
        return disk
    }

    static func createFolders(root: String) {
        for category in UsageCategory.allCases {
            guard let relative = category.relativePath else { continue }
            try? FileManager.default.createDirectory(atPath: root + "/" + relative, withIntermediateDirectories: true)
        }
    }

    static func eject(name: String, force: Bool) throws {
        guard let disk = mounted(name: name) else { throw DiskError.notMounted }
        var arguments = ["detach", disk.path]
        if force { arguments.append("-force") }
        let result = Shell.run("/usr/bin/hdiutil", arguments)
        guard result.succeeded else {
            throw DiskError.ejectFailed(result.message)
        }
    }
}
