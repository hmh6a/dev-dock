import Foundation
import Darwin

/// Reads CPU load and physical-memory breakdown straight from the Mach kernel.
///
/// No subprocess: `top` and `vm_stat` would cost a fork every poll, and the same
/// numbers are one `host_statistics64` call away.
///
/// CPU usage is a *rate*, so the sampler is stateful — it keeps the previous tick
/// reading and reports the delta. A single instance must therefore be reused
/// across polls; making a new one each time would report the average since boot
/// every time. It is a reference type with a lock so a view model can safely hand
/// it to a background queue.
public final class HostMetricsSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previousTicks: CPUTicks?

    public init() {}

    // MARK: - CPU

    /// Current CPU usage, measured against the previous call on this instance.
    public func sampleCPU() -> CPUUsage {
        guard let ticks = Self.readTicks() else {
            return CPUUsage(userPercent: 0, systemPercent: 0, idlePercent: 100)
        }
        lock.lock()
        let previous = previousTicks
        previousTicks = ticks
        lock.unlock()
        return CPUUsage.between(previous, and: ticks)
    }

    /// Cumulative CPU tick counters for the whole machine.
    static func readTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    // MARK: - Memory

    /// Current physical-memory breakdown.
    public func sampleMemory() -> MemoryUsage {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return MemoryUsage(
                totalBytes: total, appBytes: 0, wiredBytes: 0,
                compressedBytes: 0, cachedBytes: 0, freeBytes: total,
                pressure: Self.pressureLevel()
            )
        }

        let page = Int64(vm_kernel_page_size)
        func bytes(_ pages: UInt32) -> Int64 { Int64(pages) * page }

        // App memory is anonymous (non file-backed) memory minus what is purgeable
        // — the same subtraction Activity Monitor makes.
        let app = max(0, bytes(info.internal_page_count) - bytes(info.purgeable_count))

        return MemoryUsage(
            totalBytes: total,
            appBytes: app,
            wiredBytes: bytes(info.wire_count),
            compressedBytes: bytes(info.compressor_page_count),
            cachedBytes: bytes(info.external_page_count) + bytes(info.purgeable_count),
            freeBytes: bytes(info.free_count) - bytes(info.speculative_count),
            pressure: Self.pressureLevel()
        )
    }

    /// The kernel's memory-pressure verdict, or ``MemoryPressureLevel/normal``
    /// when the sysctl is unavailable.
    static func pressureLevel() -> MemoryPressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .normal
        }
        return MemoryPressureLevel(rawLevel: level)
    }

    // MARK: - Hardware

    /// Static machine facts — chip name, core count, installed RAM.
    public static func hardware() -> SystemHardware {
        SystemHardware(
            chip: sysctlString("machdep.cpu.brand_string") ?? "Mac",
            coreCount: ProcessInfo.processInfo.processorCount,
            memoryBytes: Int64(ProcessInfo.processInfo.physicalMemory)
        )
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
