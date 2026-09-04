import SwiftUI
import DevDockCore

/// Drives the System tab: polls the machine while the tab is on screen and keeps
/// a short rolling history so each meter can draw a sparkline.
@MainActor
final class SystemViewModel: ObservableObject {

    /// How often the meters refresh. Fast enough to feel live, slow enough that
    /// watching the tab is not itself a load on the machine.
    static let refreshInterval: TimeInterval = 2
    /// Samples kept per meter — two minutes of history at the interval above.
    static let historyLength = 60

    @Published private(set) var snapshot: SystemSnapshot?
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    /// Combined network throughput in bytes per second — kept raw, because a
    /// link has no fixed capacity to turn it into a percentage against.
    @Published private(set) var networkHistory: [Double] = []
    @Published private(set) var isRefreshing = false
    /// False on Macs whose temperatures we can't read (Intel models report theirs
    /// through the SMC, which this build doesn't talk to).
    @Published private(set) var temperatureSupported = true

    private let monitor = SystemMonitor()
    private var pollTask: Task<Void, Never>?

    var hardware: SystemHardware { snapshot?.hardware ?? .unknown }

    /// The machine, for the header. Core count and installed RAM are left to the
    /// CPU and Memory cards rather than repeated here.
    var hardwareSummary: String {
        snapshot?.hardware.chip ?? "Reading…"
    }

    /// Begin polling. Safe to call again — an existing loop is left running, so
    /// switching tabs back and forth doesn't stack up timers.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000))
            }
        }
    }

    /// Stop polling when the tab goes away — no reason to keep sampling for a
    /// view nobody is looking at.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        isRefreshing = true
        let reading = await monitor.snapshotAsync()
        snapshot = reading
        append(reading)
        temperatureSupported = reading.thermal.isAvailable
        isRefreshing = false
    }

    private func append(_ reading: SystemSnapshot) {
        cpuHistory = trimmed(cpuHistory, adding: reading.cpu.usedPercent)
        memoryHistory = trimmed(memoryHistory, adding: reading.memory.usedPercent)
        gpuHistory = trimmed(gpuHistory, adding: reading.primaryGPU?.utilizationPercent ?? 0)
        networkHistory = trimmed(networkHistory, adding: reading.network.combinedBytesPerSecond)
    }

    /// The scale the network meter draws against: the busiest moment in the last
    /// two minutes, with a 1 MB/s floor so an idle link isn't shown as saturated.
    var networkPeakBytesPerSecond: Double {
        max(networkHistory.max() ?? 0, 1_000_000)
    }

    /// Network history as a share of that peak, which is what ``Sparkline`` draws.
    var networkHistoryPercent: [Double] {
        let peak = networkPeakBytesPerSecond
        return networkHistory.map { $0 / peak * 100 }
    }

    private func trimmed(_ history: [Double], adding value: Double) -> [Double] {
        var next = history
        next.append(value)
        if next.count > Self.historyLength {
            next.removeFirst(next.count - Self.historyLength)
        }
        return next
    }

    deinit { pollTask?.cancel() }
}
