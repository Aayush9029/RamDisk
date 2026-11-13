import Darwin
import Foundation
import RamDiskCore

enum MemoryMonitor {
    static func read() -> MemoryStats {
        var stats = MemoryStats()
        stats.total = ProcessInfo.processInfo.physicalMemory

        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = UInt64(sysconf(_SC_PAGESIZE))
            let internalPages = UInt64(info.internal_page_count)
            let purgeable = UInt64(info.purgeable_count)
            stats.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            stats.wired = UInt64(info.wire_count) * page
            stats.compressed = UInt64(info.compressor_page_count) * page
        }

        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            stats.pressure = switch level {
            case 4: .critical
            case 2: .warning
            default: .normal
            }
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            stats.swapUsed = swap.xsu_used
        }
        return stats
    }
}
