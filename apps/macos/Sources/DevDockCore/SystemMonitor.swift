import Foundation

/// Assembles one ``SystemSnapshot`` from the individual readers — CPU, memory,
/// GPU, storage, temperatures.
///
/// Reuse a single instance: CPU usage is measured between consecutive samples
/// (see ``HostMetricsSampler``), and the thermal reader caches its sensor list.
public final class SystemMonitor: @unchecked Sendable {

    /// How long volume capacities are reused before being re-read. Disk usage
    /// barely moves between polls, and each scan touches every mounted filesystem
    /// — no reason to pay for it on a 2-second refresh.
    private static let storageCacheLifetime: TimeInterval = 15

    private let sampler = HostMetricsSampler()
    private let networkSampler = NetworkThroughputSampler()
    private let gpuReader = GPUMetricsReader()
    private let storageReader = StorageMetricsReader()
    private let thermalReader = ThermalSensorReader()
    private let hardware = HostMetricsSampler.hardware()
    private let queue = DispatchQueue(label: "dev-dock.system-monitor", qos: .userInitiated)

    private let lock = NSLock()
    private var cachedVolumes: [VolumeUsage] = []
    private var volumesReadAt: Date?

    public init() {}

    /// Read everything. Blocking — call it off the main thread, or use
    /// ``snapshotAsync()``.
    public func snapshot() -> SystemSnapshot {
        SystemSnapshot(
            cpu: sampler.sampleCPU(),
            memory: sampler.sampleMemory(),
            gpus: gpuReader.scan(),
            volumes: volumes(),
            network: networkSampler.sample(),
            thermal: thermalReader.read(),
            hardware: hardware
        )
    }

    /// Read everything off the main thread. The refresh loop in the UI uses this.
    public func snapshotAsync() async -> SystemSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.snapshot())
            }
        }
    }

    /// Whether this Mac reports any temperature at all, so the UI can explain
    /// itself instead of showing two empty dials.
    public var supportsTemperature: Bool { thermalReader.isSupported }

    private func volumes() -> [VolumeUsage] {
        lock.lock()
        let cached = cachedVolumes
        let readAt = volumesReadAt
        lock.unlock()

        if let readAt, Date().timeIntervalSince(readAt) < Self.storageCacheLifetime, !cached.isEmpty {
            return cached
        }

        let fresh = storageReader.scan()
        lock.lock()
        cachedVolumes = fresh
        volumesReadAt = Date()
        lock.unlock()
        return fresh
    }
}
