import Darwin
import Foundation

/// How much memory the Mac has left (Docs/DESIGN.md, "A slow workspace"). The workspace's 4 GB are memory of the
/// Mac: when the Mac runs short, macOS compresses and swaps out parts of them, and the guest stalls while they come
/// back (2026-11-17, a 16 GB Mac: 7.9 GB compressed, 6.7 of 8 GB swap used; Chrome in the guest stopped answering,
/// the guest needed 123 s to power off).
public struct HostMemory: Equatable, Sendable {
    /// What macOS calls the free percentage (kern.memorystatus_level, as `memory_pressure` prints it).
    public var freePercent: Int
    public var swapUsedMiB: Int
    public var swapTotalMiB: Int

    public static func read() -> HostMemory {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) != 0 { level = 100 }
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) != 0 { swap = xsw_usage() }
        return HostMemory(freePercent: Int(level), swapUsedMiB: Int(swap.xsu_used >> 20),
                          swapTotalMiB: Int(swap.xsu_total >> 20))
    }

    /// Short of memory: the workspace may stall.
    public var tight: Bool {
        freePercent < 20 || (swapTotalMiB > 0 && Double(swapUsedMiB) / Double(swapTotalMiB) > 0.8)
    }

    public var summary: String {
        "\(freePercent) % free, swap \(swapUsedMiB) of \(swapTotalMiB) MB used"
    }
}
