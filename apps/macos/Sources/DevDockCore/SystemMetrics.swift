import Foundation

// MARK: - Byte formatting

/// Human-readable byte labels.
///
/// macOS itself is inconsistent here, so we are deliberately inconsistent in the
/// same way: Finder and Disk Utility report **storage** in decimal units (a
/// 512 GB SSD reads as 512 GB), while memory is quoted in binary units (a Mac
/// sold as "24 GB" reports 25,769,803,776 bytes). Matching each keeps our
/// numbers equal to the ones the user can check elsewhere.
public enum ByteFormat {

    /// Storage-style label, decimal units — `1.4 TB`, `243 GB`, `812 MB`.
    public static func storage(_ bytes: Int64) -> String {
        label(bytes, base: 1000, units: ["B", "KB", "MB", "GB", "TB", "PB"])
    }

    /// Memory-style label, binary units — `24 GB`, `1.8 GB`, `640 MB`.
    public static func memory(_ bytes: Int64) -> String {
        label(bytes, base: 1024, units: ["B", "KB", "MB", "GB", "TB"])
    }

    /// Transfer-rate label, decimal units the way networking quotes them —
    /// `1.2 MB/s`, `840 KB/s`, `0 B/s`.
    public static func rate(_ bytesPerSecond: Double) -> String {
        let bytes = Int64(max(0, bytesPerSecond.rounded()))
        return storage(bytes) + "/s"
    }

    private static func label(_ bytes: Int64, base: Double, units: [String]) -> String {
        guard bytes > 0 else { return "0 B" }
        var value = Double(bytes)
        var index = 0
        while value >= base, index < units.count - 1 {
            value /= base
            index += 1
        }
        // Bytes and kilobytes are never fractional; above that, keep one decimal
        // until the number is big enough that the decimal is just noise — and
        // drop a trailing ".0", so installed RAM reads "24 GB", not "24.0 GB".
        if index <= 1 || value >= 100 { return String(format: "%.0f %@", value, units[index]) }
        if (value * 10).rounded().truncatingRemainder(dividingBy: 10) == 0 {
            return String(format: "%.0f %@", value, units[index])
        }
        return String(format: "%.1f %@", value, units[index])
    }
}

/// Percentages the way the rest of the app writes them — `0.4%`, `8%`, `37%`.
///
/// One decimal below ten, where it carries information, and none above it or
/// when the value is whole anyway: `8.0%` is just a wider way to write `8%`.
public enum PercentFormat {
    public static func short(_ percent: Double) -> String {
        let rounded = (percent * 10).rounded() / 10
        if percent >= 10 || rounded == rounded.rounded() {
            return String(format: "%.0f%%", percent)
        }
        return String(format: "%.1f%%", percent)
    }
}

// MARK: - CPU

/// A raw snapshot of the kernel's cumulative CPU tick counters.
///
/// Ticks only ever increase, so a single reading says nothing about *current*
/// load — usage is the difference between two readings. See ``CPUUsage/between(_:and:)``.
public struct CPUTicks: Equatable, Sendable {
    public let user: UInt64
    public let system: UInt64
    public let idle: UInt64
    public let nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public var total: UInt64 { user &+ system &+ idle &+ nice }
}

/// How busy the CPU has been over the interval between two tick readings.
public struct CPUUsage: Equatable, Sendable {
    public let userPercent: Double
    public let systemPercent: Double
    public let idlePercent: Double

    public init(userPercent: Double, systemPercent: Double, idlePercent: Double) {
        self.userPercent = userPercent
        self.systemPercent = systemPercent
        self.idlePercent = idlePercent
    }

    /// Everything that isn't idle — the headline figure.
    public var usedPercent: Double { max(0, min(100, 100 - idlePercent)) }

    public var usedLabel: String { PercentFormat.short(usedPercent) }

    /// Usage between two tick readings. `previous` is nil on the very first
    /// sample, in which case the counters are read as an average since boot —
    /// roughly right, and replaced by a real delta one interval later.
    public static func between(_ previous: CPUTicks?, and current: CPUTicks) -> CPUUsage {
        let base = previous ?? CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let user = current.user &- base.user
        let system = current.system &- base.system
        let idle = current.idle &- base.idle
        let nice = current.nice &- base.nice
        let total = Double(user &+ system &+ idle &+ nice)
        guard total > 0 else { return CPUUsage(userPercent: 0, systemPercent: 0, idlePercent: 100) }

        return CPUUsage(
            // `nice` is just user time at a lower priority — folded in so the
            // three percentages always add up to 100.
            userPercent: Double(user &+ nice) / total * 100,
            systemPercent: Double(system) / total * 100,
            idlePercent: Double(idle) / total * 100
        )
    }
}

// MARK: - Memory

/// Physical memory, split the way Activity Monitor splits it.
public struct MemoryUsage: Equatable, Sendable {
    /// Installed physical RAM.
    public let totalBytes: Int64
    /// Anonymous memory owned by apps (Activity Monitor's "App Memory").
    public let appBytes: Int64
    /// Memory the kernel cannot page out.
    public let wiredBytes: Int64
    /// Memory held by the compressor.
    public let compressedBytes: Int64
    /// File-backed pages — reclaimable, so not counted as used.
    public let cachedBytes: Int64
    public let freeBytes: Int64
    public let pressure: MemoryPressureLevel

    public init(
        totalBytes: Int64,
        appBytes: Int64,
        wiredBytes: Int64,
        compressedBytes: Int64,
        cachedBytes: Int64,
        freeBytes: Int64,
        pressure: MemoryPressureLevel = .normal
    ) {
        self.totalBytes = totalBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.freeBytes = freeBytes
        self.pressure = pressure
    }

    /// "Memory Used" as Activity Monitor defines it: app + wired + compressed.
    /// Cached files are excluded — the system hands them back on demand.
    public var usedBytes: Int64 { appBytes + wiredBytes + compressedBytes }

    public var usedFraction: Double {
        totalBytes > 0 ? min(1, Double(usedBytes) / Double(totalBytes)) : 0
    }

    public var usedPercent: Double { usedFraction * 100 }
}

/// The kernel's own verdict on memory pressure (`kern.memorystatus_vm_pressure_level`),
/// which is a better warning sign than the used/total ratio on a Mac that
/// compresses aggressively.
public enum MemoryPressureLevel: Int, Sendable, Equatable {
    case normal = 1
    case warning = 2
    case critical = 4

    public init(rawLevel: Int32) {
        self = MemoryPressureLevel(rawValue: Int(rawLevel)) ?? .normal
    }

    public var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

// MARK: - GPU

/// Live utilization of one graphics device.
public struct GPUUsage: Equatable, Sendable, Identifiable {
    /// Marketing-ish name — `Apple M4 Pro GPU`, `AMD Radeon Pro 5500M`.
    public let name: String
    /// Overall device utilization, 0–100.
    public let utilizationPercent: Double
    /// Shader/renderer share, when the driver reports it.
    public let rendererPercent: Double?
    /// Tiler share, on Apple Silicon's tile-based GPU.
    public let tilerPercent: Double?
    /// Memory the GPU currently has mapped (unified memory on Apple Silicon).
    public let inUseMemoryBytes: Int64?

    public var id: String { name }

    public init(
        name: String,
        utilizationPercent: Double,
        rendererPercent: Double? = nil,
        tilerPercent: Double? = nil,
        inUseMemoryBytes: Int64? = nil
    ) {
        self.name = name
        self.utilizationPercent = utilizationPercent
        self.rendererPercent = rendererPercent
        self.tilerPercent = tilerPercent
        self.inUseMemoryBytes = inUseMemoryBytes
    }

    public var utilizationLabel: String { PercentFormat.short(utilizationPercent) }
}

/// Pulls the numbers out of an `IOAccelerator` entry's `PerformanceStatistics`
/// dictionary. Kept pure so it can be tested against a captured dictionary
/// instead of a live GPU.
public enum GPUPerformanceStatistics {

    public static func usage(name: String, statistics: [String: Any]) -> GPUUsage {
        GPUUsage(
            name: name,
            utilizationPercent: percent(statistics["Device Utilization %"])
                ?? percent(statistics["GPU Core Utilization"]).map { $0 / 10_000_000 }
                ?? 0,
            rendererPercent: percent(statistics["Renderer Utilization %"]),
            tilerPercent: percent(statistics["Tiler Utilization %"]),
            inUseMemoryBytes: bytes(statistics["In use system memory"])
                ?? bytes(statistics["vramUsedBytes"])
        )
    }

    private static func percent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return max(0, min(100, number.doubleValue))
    }

    private static func bytes(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, number.int64Value > 0 else { return nil }
        return number.int64Value
    }
}

// MARK: - Storage

/// Capacity of one mounted volume.
public struct VolumeUsage: Equatable, Sendable, Identifiable {
    public let name: String
    public let path: String
    public let totalBytes: Int64
    /// Space actually available to the user — this is the "Available" figure
    /// Finder shows, which counts purgeable space the system can reclaim.
    public let freeBytes: Int64
    /// The boot volume, shown first and used for the headline figure.
    public let isRoot: Bool

    public var id: String { path }

    public init(name: String, path: String, totalBytes: Int64, freeBytes: Int64, isRoot: Bool) {
        self.name = name
        self.path = path
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isRoot = isRoot
    }

    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    public var usedFraction: Double {
        totalBytes > 0 ? min(1, Double(usedBytes) / Double(totalBytes)) : 0
    }

    public var usedPercent: Double { usedFraction * 100 }
}

// MARK: - Temperature

/// Which part of the machine a temperature sensor belongs to.
public enum ThermalGroup: String, Sendable, Equatable, CaseIterable {
    case cpu
    case gpu
    /// A die sensor that covers the whole system-on-chip — on Apple Silicon the
    /// CPU and GPU share it, so it stands in for both.
    case soc
    case storage
    case battery
    case other

    public var label: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .soc: return "SoC die"
        case .storage: return "Storage"
        case .battery: return "Battery"
        case .other: return "Other"
        }
    }
}

/// One named sensor and its current reading, in degrees Celsius.
public struct TemperatureReading: Equatable, Sendable, Identifiable {
    public let sensor: String
    public let celsius: Double
    public let group: ThermalGroup

    public var id: String { sensor }

    public init(sensor: String, celsius: Double, group: ThermalGroup) {
        self.sensor = sensor
        self.celsius = celsius
        self.group = group
    }

    public var label: String { String(format: "%.0f°C", celsius) }
}

/// Everything the thermal sensors say, reduced to the two figures the UI leads
/// with plus the full list behind them.
public struct ThermalSnapshot: Equatable, Sendable {
    public let cpu: Double?
    public let gpu: Double?
    /// True when CPU and GPU are both quoting the same shared die sensor because
    /// this Mac exposes no separately-named CPU/GPU sensors — every Apple Silicon
    /// chip since M3 reports only generic `PMU tdie` sensors.
    public let isSharedDie: Bool
    public let readings: [TemperatureReading]

    public init(cpu: Double?, gpu: Double?, isSharedDie: Bool, readings: [TemperatureReading]) {
        self.cpu = cpu
        self.gpu = gpu
        self.isSharedDie = isSharedDie
        self.readings = readings
    }

    public static let empty = ThermalSnapshot(cpu: nil, gpu: nil, isSharedDie: false, readings: [])

    public var isAvailable: Bool { cpu != nil || gpu != nil || !readings.isEmpty }
}

/// Turns a pile of raw `(sensor name, °C)` pairs into a ``ThermalSnapshot``.
///
/// Pure, so the naming rules — which differ per chip generation — can be tested
/// against captured sensor names instead of whatever Mac happens to run the suite.
public enum ThermalSensorClassifier {

    /// Anything outside this range is a disconnected or bogus sensor.
    private static let plausible: ClosedRange<Double> = 1...150

    public static func group(for sensorName: String) -> ThermalGroup {
        let name = sensorName.lowercased()
        // GPU first: "GPU MTR Temp Sensor1" would also match the CPU rules below.
        if name.contains("gpu") { return .gpu }
        if name.contains("pacc") || name.contains("eacc") || name.contains("cpu")
            || name.contains("acc mtr") { return .cpu }
        if name.contains("nand") || name.contains("ssd") || name.contains("nvme") { return .storage }
        if name.contains("battery") || name.contains("gas gauge") { return .battery }
        // "PMU tcal" is a calibration reference, not a die: it sits at a fixed
        // value while the machine heats up, so it must not drag the die reading.
        if name.contains("tcal") { return .other }
        // Apple Silicon die sensors: "PMU tdie3", "PMU tdev5", plus the SoC-wide
        // sensors named on M1/M2.
        if name.contains("tdie") || name.contains("tdev")
            || name.contains("soc") || name.contains("pmu t") { return .soc }
        return .other
    }

    /// Reduce raw readings to a snapshot.
    ///
    /// Sensors repeat — a chip has a dozen `PMU tdie` dies and several battery
    /// gauges — so same-named readings are averaged into one entry. The headline
    /// CPU/GPU figures then take the **hottest** sensor in the group, since
    /// throttling follows the hot spot, not the average.
    public static func summarize(_ raw: [(name: String, celsius: Double)]) -> ThermalSnapshot {
        var sums: [String: (total: Double, count: Int)] = [:]
        for reading in raw where plausible.contains(reading.celsius) {
            let entry = sums[reading.name] ?? (0, 0)
            sums[reading.name] = (entry.total + reading.celsius, entry.count + 1)
        }
        guard !sums.isEmpty else { return .empty }

        let readings = sums
            .map { name, entry in
                TemperatureReading(
                    sensor: name,
                    celsius: entry.total / Double(entry.count),
                    group: group(for: name)
                )
            }
            .sorted { $0.celsius > $1.celsius }

        func hottest(_ group: ThermalGroup) -> Double? {
            readings.filter { $0.group == group }.map(\.celsius).max()
        }

        let die = hottest(.soc)
        let cpu = hottest(.cpu)
        let gpu = hottest(.gpu)

        return ThermalSnapshot(
            cpu: cpu ?? die,
            gpu: gpu ?? die,
            isSharedDie: cpu == nil && gpu == nil && die != nil,
            readings: readings
        )
    }
}

// MARK: - Snapshot

/// One complete reading of the machine: everything the System tab shows.
public struct SystemSnapshot: Equatable, Sendable {
    public let cpu: CPUUsage
    public let memory: MemoryUsage
    public let gpus: [GPUUsage]
    public let volumes: [VolumeUsage]
    public let network: NetworkThroughput
    public let thermal: ThermalSnapshot
    public let hardware: SystemHardware
    public let takenAt: Date

    public init(
        cpu: CPUUsage,
        memory: MemoryUsage,
        gpus: [GPUUsage],
        volumes: [VolumeUsage],
        network: NetworkThroughput = .idle,
        thermal: ThermalSnapshot,
        hardware: SystemHardware,
        takenAt: Date = Date()
    ) {
        self.cpu = cpu
        self.memory = memory
        self.gpus = gpus
        self.volumes = volumes
        self.network = network
        self.thermal = thermal
        self.hardware = hardware
        self.takenAt = takenAt
    }

    /// The boot volume — the one the headline storage figure describes.
    public var rootVolume: VolumeUsage? {
        volumes.first(where: \.isRoot) ?? volumes.first
    }

    /// Volumes other than the boot disk (external drives, extra partitions).
    public var otherVolumes: [VolumeUsage] {
        guard let root = rootVolume else { return volumes }
        return volumes.filter { $0.id != root.id }
    }

    /// The GPU the UI leads with.
    public var primaryGPU: GPUUsage? { gpus.first }
}

/// Static facts about the machine, read once and shown as context.
public struct SystemHardware: Equatable, Sendable {
    /// `Apple M4 Pro`, `Intel Core i9-9880H`.
    public let chip: String
    public let coreCount: Int
    public let memoryBytes: Int64

    public init(chip: String, coreCount: Int, memoryBytes: Int64) {
        self.chip = chip
        self.coreCount = coreCount
        self.memoryBytes = memoryBytes
    }

    public static let unknown = SystemHardware(chip: "Mac", coreCount: 0, memoryBytes: 0)
}
