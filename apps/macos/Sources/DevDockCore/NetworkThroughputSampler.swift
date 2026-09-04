import Foundation
import Darwin

/// Cumulative byte counters for the machine's network interfaces.
///
/// Like CPU ticks, these only ever grow: throughput is the difference between
/// two readings. See ``NetworkThroughput/between(_:and:elapsed:)``.
public struct NetworkTicks: Equatable, Sendable {
    public let receivedBytes: UInt64
    public let sentBytes: UInt64

    public init(receivedBytes: UInt64, sentBytes: UInt64) {
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}

/// How fast data is moving over the network right now, plus the totals the
/// counters have accumulated since the interfaces came up.
public struct NetworkThroughput: Equatable, Sendable {
    public let downloadBytesPerSecond: Double
    public let uploadBytesPerSecond: Double
    public let totalReceivedBytes: UInt64
    public let totalSentBytes: UInt64

    public init(
        downloadBytesPerSecond: Double,
        uploadBytesPerSecond: Double,
        totalReceivedBytes: UInt64,
        totalSentBytes: UInt64
    ) {
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.totalReceivedBytes = totalReceivedBytes
        self.totalSentBytes = totalSentBytes
    }

    public static let idle = NetworkThroughput(
        downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
        totalReceivedBytes: 0, totalSentBytes: 0
    )

    /// Both directions together — what the meter's headline and bar describe.
    public var combinedBytesPerSecond: Double { downloadBytesPerSecond + uploadBytesPerSecond }

    public var downloadLabel: String { ByteFormat.rate(downloadBytesPerSecond) }
    public var uploadLabel: String { ByteFormat.rate(uploadBytesPerSecond) }

    /// Throughput between two counter readings taken `elapsed` seconds apart.
    ///
    /// The first sample has nothing to compare against, so it reports idle rather
    /// than an average since the interface came up — over days of uptime that
    /// average says nothing about what the network is doing now.
    ///
    /// A counter that went backwards (an interface reset, or the 32-bit counters
    /// on some drivers wrapping) is read as zero, not as a negative rate.
    public static func between(
        _ previous: NetworkTicks?,
        and current: NetworkTicks,
        elapsed: TimeInterval
    ) -> NetworkThroughput {
        guard let previous, elapsed > 0 else {
            return NetworkThroughput(
                downloadBytesPerSecond: 0,
                uploadBytesPerSecond: 0,
                totalReceivedBytes: current.receivedBytes,
                totalSentBytes: current.sentBytes
            )
        }

        func rate(_ new: UInt64, _ old: UInt64) -> Double {
            new >= old ? Double(new - old) / elapsed : 0
        }

        return NetworkThroughput(
            downloadBytesPerSecond: rate(current.receivedBytes, previous.receivedBytes),
            uploadBytesPerSecond: rate(current.sentBytes, previous.sentBytes),
            totalReceivedBytes: current.receivedBytes,
            totalSentBytes: current.sentBytes
        )
    }
}

/// Which interfaces count toward the machine's throughput.
public enum NetworkInterfaceFilter {

    /// Only real links: Ethernet and Wi-Fi (`en0`, `eth0`) and cellular (`pdp_ip0`).
    ///
    /// Tunnels (`utun`, Tailscale, VPNs) are deliberately excluded: their traffic
    /// is also counted by the physical interface that carries it, so adding them
    /// would report every VPN byte twice. Loopback, AirDrop (`awdl`, `llw`),
    /// bridges, and virtualization interfaces never leave the Mac at all.
    public static func countsTowardThroughput(_ name: String) -> Bool {
        if name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("anpi") {
            return false
        }
        return name.hasPrefix("en") || name.hasPrefix("eth") || name.hasPrefix("pdp_ip")
    }

    /// Sum the interfaces worth counting.
    public static func total(_ counters: [(name: String, ticks: NetworkTicks)]) -> NetworkTicks {
        counters
            .filter { countsTowardThroughput($0.name) }
            .reduce(NetworkTicks(receivedBytes: 0, sentBytes: 0)) { total, entry in
                NetworkTicks(
                    receivedBytes: total.receivedBytes &+ entry.ticks.receivedBytes,
                    sentBytes: total.sentBytes &+ entry.ticks.sentBytes
                )
            }
    }
}

/// Reads the kernel's per-interface byte counters and turns consecutive readings
/// into a live transfer rate.
///
/// Stateful, like ``HostMetricsSampler`` — reuse one instance, or every sample
/// reports zero.
public final class NetworkThroughputSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: NetworkTicks?
    private var previousAt: TimeInterval?

    public init() {}

    /// Current throughput, measured against the previous call on this instance.
    public func sample() -> NetworkThroughput {
        guard let ticks = Self.readCounters().map(NetworkInterfaceFilter.total) else {
            return .idle
        }
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        let last = previous
        let lastAt = previousAt
        previous = ticks
        previousAt = now
        lock.unlock()

        return NetworkThroughput.between(last, and: ticks, elapsed: now - (lastAt ?? now))
    }

    /// Per-interface counters straight from `sysctl(NET_RT_IFLIST2)`.
    ///
    /// `NET_RT_IFLIST2` rather than `getifaddrs`, because it carries `if_data64`
    /// — 64-bit counters that don't wrap after four gigabytes on a busy link.
    static func readCounters() -> [(name: String, ticks: NetworkTicks)]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }

        // Raw allocation, not `[UInt8]`: the buffer holds C structs that we bind
        // memory to in place, and those need proper alignment.
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: size, alignment: MemoryLayout<if_msghdr2>.alignment
        )
        defer { buffer.deallocate() }
        guard sysctl(&mib, u_int(mib.count), buffer, &size, nil, 0) == 0 else { return nil }

        var counters: [(name: String, ticks: NetworkTicks)] = []
        var offset = 0
        while offset < size {
            let entry = buffer.advanced(by: offset)
            let header = entry.loadUnaligned(as: if_msghdr.self)
            let length = Int(header.ifm_msglen)
            guard length > 0 else { break }
            defer { offset += length }
            guard header.ifm_type == RTM_IFINFO2 else { continue }

            let info = entry.loadUnaligned(as: if_msghdr2.self)
            // The interface name follows the header as a link-layer address.
            let link = entry.advanced(by: MemoryLayout<if_msghdr2>.stride)
                .loadUnaligned(as: sockaddr_dl.self)
            guard let name = Self.name(of: link) else { continue }

            counters.append((
                name,
                NetworkTicks(
                    receivedBytes: info.ifm_data.ifi_ibytes,
                    sentBytes: info.ifm_data.ifi_obytes
                )
            ))
        }
        return counters
    }

    /// `sockaddr_dl.sdl_data` is a C array holding the name followed by the
    /// hardware address, with no terminator — only `sdl_nlen` says where it ends.
    private static func name(of link: sockaddr_dl) -> String? {
        let length = Int(link.sdl_nlen)
        guard length > 0 else { return nil }
        var characters = link.sdl_data
        return withUnsafeBytes(of: &characters) { raw in
            guard length <= raw.count else { return nil }
            return String(decoding: raw.prefix(length), as: UTF8.self)
        }
    }
}
