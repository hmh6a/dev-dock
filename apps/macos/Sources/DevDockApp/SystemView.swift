import SwiftUI
import DevDockCore

/// The System tab: live CPU, memory, GPU, and storage load for the whole machine,
/// with CPU and GPU temperature alongside them.
///
/// The Ports tab shows what a *single process* is using; this is the other half —
/// what the Mac as a whole has left to give.
///
/// The four headline meters are stacked one under another as compact rows, so
/// they are all on screen at once — a cockpit you glance at, not a page you
/// scroll. The numbers behind each headline are one hover away in the tooltip,
/// and extra volumes and the full sensor list sit underneath.
struct SystemView: View {
    @StateObject private var viewModel = SystemViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: DS.gap) {
                    if let snapshot = viewModel.snapshot {
                        meters(for: snapshot)
                        if !snapshot.otherVolumes.isEmpty {
                            OtherVolumesCard(volumes: snapshot.otherVolumes)
                        }
                        SensorsCard(thermal: snapshot.thermal)
                    } else {
                        loadingState
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(DS.contentPadding)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    /// One full-width row per resource, in the order a developer asks about them.
    /// Spaced a little tighter than the rest of the app so all four rows, plus
    /// the sensor list, clear the panel's smallest height without scrolling.
    private func meters(for snapshot: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CPUTile(snapshot: snapshot, history: viewModel.cpuHistory)
            MemoryTile(memory: snapshot.memory, history: viewModel.memoryHistory)
            GPUTile(
                gpu: snapshot.primaryGPU,
                temperature: snapshot.thermal.gpu,
                isSharedDie: snapshot.thermal.isSharedDie,
                history: viewModel.gpuHistory
            )
            StorageTile(volume: snapshot.rootVolume)
            NetworkTile(
                network: snapshot.network,
                history: viewModel.networkHistoryPercent,
                peakBytesPerSecond: viewModel.networkPeakBytesPerSecond
            )
        }
    }

    private var header: some View {
        SectionHeader("System", subtitle: viewModel.hardwareSummary) {
            HStack(spacing: 2) {
                if viewModel.snapshot == nil {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 26, height: 24)
                }
                IconButton(systemImage: "arrow.clockwise", help: "Refresh now") {
                    Task { await viewModel.refresh() }
                }
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Reading the machine…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Tiles

private struct CPUTile: View {
    let snapshot: SystemSnapshot
    let history: [Double]

    var body: some View {
        MeterTile(
            title: "CPU",
            systemImage: "cpu",
            value: snapshot.cpu.usedLabel,
            detail: "\(PercentFormat.short(snapshot.cpu.userPercent)) user · \(PercentFormat.short(snapshot.cpu.systemPercent)) sys",
            tint: LoadTint.forLoad(snapshot.cpu.usedPercent),
            segments: [
                .init(fraction: snapshot.cpu.userPercent / 100, color: LoadTint.forLoad(snapshot.cpu.usedPercent)),
                .init(fraction: snapshot.cpu.systemPercent / 100, color: LoadTint.forLoad(snapshot.cpu.usedPercent).opacity(0.45))
            ],
            history: history,
            temperature: snapshot.thermal.cpu,
            temperatureIsShared: snapshot.thermal.isSharedDie,
            tooltip: """
            \(snapshot.hardware.chip) · \(snapshot.hardware.coreCount) cores
            User \(PercentFormat.short(snapshot.cpu.userPercent)) · System \(PercentFormat.short(snapshot.cpu.systemPercent)) · Idle \(PercentFormat.short(snapshot.cpu.idlePercent))
            """
        )
    }
}

private struct MemoryTile: View {
    let memory: MemoryUsage
    let history: [Double]

    var body: some View {
        MeterTile(
            title: "Memory",
            systemImage: "memorychip",
            value: PercentFormat.short(memory.usedPercent),
            detail: "\(ByteFormat.memory(memory.usedBytes)) of \(ByteFormat.memory(memory.totalBytes))",
            tint: tint,
            segments: [
                .init(fraction: fraction(memory.appBytes), color: tint),
                .init(fraction: fraction(memory.wiredBytes), color: tint.opacity(0.55)),
                .init(fraction: fraction(memory.compressedBytes), color: tint.opacity(0.3))
            ],
            history: history,
            // Pressure is the one number worth interrupting the layout for: it is
            // how a Mac tells you it is about to start swapping.
            badge: memory.pressure == .normal ? nil : Badge(
                text: memory.pressure.label,
                tint: memory.pressure == .critical ? .red : .orange
            ),
            tooltip: """
            App \(ByteFormat.memory(memory.appBytes)) · Wired \(ByteFormat.memory(memory.wiredBytes))
            Compressed \(ByteFormat.memory(memory.compressedBytes)) · Cached \(ByteFormat.memory(memory.cachedBytes))
            Pressure: \(memory.pressure.label)
            """
        )
    }

    private var tint: Color { LoadTint.forLoad(memory.usedPercent) }

    private func fraction(_ bytes: Int64) -> Double {
        memory.totalBytes > 0 ? Double(bytes) / Double(memory.totalBytes) : 0
    }
}

private struct GPUTile: View {
    let gpu: GPUUsage?
    let temperature: Double?
    let isSharedDie: Bool
    let history: [Double]

    var body: some View {
        if let gpu {
            MeterTile(
                title: "GPU",
                systemImage: "cube.transparent",
                value: gpu.utilizationLabel,
                detail: detail(for: gpu),
                tint: LoadTint.forLoad(gpu.utilizationPercent),
                segments: [
                    .init(fraction: gpu.utilizationPercent / 100, color: LoadTint.forLoad(gpu.utilizationPercent))
                ],
                history: history,
                temperature: temperature,
                temperatureIsShared: isSharedDie,
                tooltip: tooltip(for: gpu)
            )
        } else {
            Card {
                UnavailableTile(
                    systemImage: "cube.transparent",
                    title: "GPU",
                    message: "No device reporting."
                )
            }
        }
    }

    private func detail(for gpu: GPUUsage) -> String {
        if let memory = gpu.inUseMemoryBytes { return "\(ByteFormat.memory(memory)) in use" }
        return gpu.name
    }

    private func tooltip(for gpu: GPUUsage) -> String {
        var lines = [gpu.name]
        if let renderer = gpu.rendererPercent, let tiler = gpu.tilerPercent {
            lines.append("Renderer \(PercentFormat.short(renderer)) · Tiler \(PercentFormat.short(tiler))")
        }
        if let memory = gpu.inUseMemoryBytes {
            lines.append("In use \(ByteFormat.memory(memory))")
        }
        return lines.joined(separator: "\n")
    }
}

private struct StorageTile: View {
    let volume: VolumeUsage?

    var body: some View {
        if let volume {
            MeterTile(
                title: "Storage",
                systemImage: "internaldrive",
                value: PercentFormat.short(volume.usedPercent),
                detail: "\(ByteFormat.storage(volume.freeBytes)) free",
                tint: StorageTint.forUsage(volume.usedPercent),
                segments: [.init(fraction: volume.usedFraction, color: StorageTint.forUsage(volume.usedPercent))],
                // A disk fills up over weeks, not seconds — a sparkline of it
                // would be a flat line, so the tile keeps the space for the numbers.
                history: [],
                tooltip: """
                \(volume.name)
                Used \(ByteFormat.storage(volume.usedBytes)) · Free \(ByteFormat.storage(volume.freeBytes))
                Total \(ByteFormat.storage(volume.totalBytes))
                """
            )
        } else {
            Card {
                UnavailableTile(
                    systemImage: "internaldrive",
                    title: "Storage",
                    message: "No volume reporting."
                )
            }
        }
    }
}

/// Live transfer rate over the Mac's real links.
///
/// Unlike the other meters there is no capacity to fill, so the bar is drawn
/// against the busiest moment of the last two minutes: it answers "is this
/// link busy right now, compared with how busy it has been" rather than
/// pretending to know the line speed.
private struct NetworkTile: View {
    let network: NetworkThroughput
    let history: [Double]
    let peakBytesPerSecond: Double

    var body: some View {
        MeterTile(
            title: "Network",
            systemImage: "arrow.up.arrow.down",
            value: "↓ \(network.downloadLabel)",
            detail: "↑ \(network.uploadLabel) · \(ByteFormat.storage(Int64(network.totalReceivedBytes))) in · \(ByteFormat.storage(Int64(network.totalSentBytes))) out",
            tint: .accentColor,
            segments: [
                .init(fraction: network.downloadBytesPerSecond / peakBytesPerSecond, color: .accentColor),
                .init(fraction: network.uploadBytesPerSecond / peakBytesPerSecond, color: .accentColor.opacity(0.45))
            ],
            history: history,
            valueFontSize: 17,
            tooltip: """
            Down \(network.downloadLabel) · Up \(network.uploadLabel)
            Since the interfaces came up: \(ByteFormat.storage(Int64(network.totalReceivedBytes))) in, \(ByteFormat.storage(Int64(network.totalSentBytes))) out
            Wi-Fi, Ethernet and cellular only — VPN tunnels ride on those, so counting them too would double every byte.
            """
        )
    }
}

/// One compact meter. Name, sparkline, temperature and the headline percentage
/// share the top line; the load bar and its line of context get the full width
/// underneath, which is what keeps them readable in a 400-point-wide panel
/// instead of being squeezed into a column and truncated.
private struct MeterTile: View {
    let title: String
    let systemImage: String
    let value: String
    let detail: String
    let tint: Color
    let segments: [BarSegment]
    let history: [Double]
    var temperature: Double?
    var temperatureIsShared = false
    var badge: Badge?
    /// Percentages are short and can shout; a rate label like `↓ 12.4 MB/s` needs
    /// the smaller size to stay on one line.
    var valueFontSize: CGFloat = 23
    var tooltip: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    Sparkline(values: history, tint: tint)
                        .frame(width: 62, height: 20)

                    if let temperature {
                        TemperatureBadge(celsius: temperature, isShared: temperatureIsShared)
                    }

                    Text(value)
                        .font(.system(size: valueFontSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint)
                        .monospacedDigit()
                }

                SegmentedBar(segments: segments, height: 8)

                HStack(spacing: 5) {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let badge {
                        Text(badge.text)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(badge.tint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(badge.tint.opacity(0.15)))
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .help(tooltip)
    }
}

private struct UnavailableTile: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 88, alignment: .leading)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Extra volumes

/// External drives and extra partitions, listed only when there are any — the
/// boot disk already has its own tile.
private struct OtherVolumesCard: View {
    let volumes: [VolumeUsage]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(volumes) { volume in
                    HStack(spacing: 6) {
                        Image(systemName: "externaldrive")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(volume.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        SegmentedBar(
                            segments: [.init(fraction: volume.usedFraction, color: StorageTint.forUsage(volume.usedPercent))],
                            height: 7
                        )
                        .frame(minWidth: 40)
                        Text("\(ByteFormat.storage(volume.freeBytes)) free")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .help("\(volume.path) — \(ByteFormat.storage(volume.usedBytes)) used of \(ByteFormat.storage(volume.totalBytes))")
                }
            }
        }
    }
}

// MARK: - Sensors

private struct SensorsCard: View {
    let thermal: ThermalSnapshot
    @State private var expanded = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                if thermal.isAvailable {
                    DisclosureGroup(isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(thermal.readings) { reading in
                                HStack(spacing: 6) {
                                    Text(reading.group.label)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 62, alignment: .leading)
                                    Text(reading.sensor)
                                        .font(.system(size: 13))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(reading.label)
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                        .foregroundStyle(TemperatureTint.forCelsius(reading.celsius))
                                }
                            }
                            if thermal.isSharedDie {
                                Text("This Mac names no separate CPU and GPU sensors, so both quote the hottest system-on-chip die sensor.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "thermometer.medium")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("All sensors")
                                .font(.system(size: 14, weight: .semibold))
                            Text("\(thermal.readings.count)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    UnavailableTile(
                        systemImage: "thermometer.medium.slash",
                        title: "Temperature",
                        message: "This Mac doesn't expose readable thermal sensors."
                    )
                }
            }
        }
    }
}

// MARK: - Shared pieces

private struct Badge {
    let text: String
    let tint: Color
}

/// One slice of a stacked usage bar.
private struct BarSegment: Identifiable {
    let fraction: Double
    let color: Color
    var id: String { "\(fraction)-\(color.description)" }
}

private struct SegmentedBar: View {
    let segments: [BarSegment]
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                HStack(spacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(0, geometry.size.width * min(1, max(0, segment.fraction))))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.25), value: segments.map(\.fraction))
    }
}

/// A two-minute history line. Always drawn on a 0–100 scale so a quiet CPU looks
/// quiet — auto-scaling would make 2% noise look like a spike.
private struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let points = self.points(in: geometry.size)
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.addLines(points)
                    }
                    .stroke(tint.opacity(0.85), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))

                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                        path.addLines(points)
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.22), tint.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        // Anchor the line to the right edge so a fresh, half-full history grows
        // in from the left instead of stretching.
        let capacity = max(values.count, SystemViewModel.historyLength)
        let step = size.width / CGFloat(capacity - 1)
        let offset = size.width - step * CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let clamped = min(100, max(0, value))
            return CGPoint(
                x: offset + step * CGFloat(index),
                y: size.height - size.height * CGFloat(clamped / 100)
            )
        }
    }
}

private struct TemperatureBadge: View {
    let celsius: Double
    var isShared = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 10, weight: .semibold))
            Text(String(format: "%.0f°C", celsius))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(TemperatureTint.forCelsius(celsius))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(TemperatureTint.forCelsius(celsius).opacity(0.13)))
        .fixedSize()
        .help(isShared
              ? "Hottest system-on-chip die sensor — this Mac reports no separate CPU and GPU sensors."
              : "Hottest sensor in this group.")
    }
}

/// Meters warm from the accent color to orange to red as a resource fills up —
/// the same language the per-process chips in the Ports tab use.
private enum LoadTint {
    static func forLoad(_ percent: Double) -> Color {
        switch percent {
        case ..<60: return .accentColor
        case ..<85: return .orange
        default: return .red
        }
    }
}

/// Storage warms up later than CPU: a disk is only worrying once it is nearly full.
private enum StorageTint {
    static func forUsage(_ percent: Double) -> Color {
        switch percent {
        case ..<75: return .accentColor
        case ..<90: return .orange
        default: return .red
        }
    }
}

private enum TemperatureTint {
    static func forCelsius(_ celsius: Double) -> Color {
        switch celsius {
        case ..<65: return .secondary
        case ..<85: return .orange
        default: return .red
        }
    }
}
