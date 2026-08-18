import Foundation

/// The CPU and memory a process is currently using, as reported by `ps`.
///
/// A plain value type so the parser can be unit tested without a live system.
/// Note that these figures belong to the **process**, not to a single socket:
/// one process can own several listening ports, and they all share this usage.
public struct ProcessUsage: Equatable, Hashable, Sendable {
    /// Percentage of a single CPU core, as `ps %cpu` reports it (can exceed 100).
    public let cpuPercent: Double
    /// Percentage of physical memory, as `ps %mem` reports it.
    public let memoryPercent: Double
    /// Resident set size in kilobytes — the process's real RAM footprint.
    public let residentKB: Int

    public init(cpuPercent: Double, memoryPercent: Double, residentKB: Int) {
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.residentKB = residentKB
    }

    /// Resident memory in megabytes.
    public var residentMB: Double { Double(residentKB) / 1024 }

    /// Compact RAM label — `842 KB`, `176 MB`, `2.4 GB`.
    public var memoryLabel: String {
        let mb = residentMB
        if mb < 1 { return "\(residentKB) KB" }
        if mb < 1024 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f GB", mb / 1024)
    }

    /// Compact CPU label — `0.4%`, `8.6%`, `142%`.
    public var cpuLabel: String {
        cpuPercent >= 10
            ? String(format: "%.0f%%", cpuPercent)
            : String(format: "%.1f%%", cpuPercent)
    }
}

/// Parses the output of `ps -o pid=,%cpu=,%mem=,rss= -p <pids>` into a
/// `pid → usage` map.
///
/// Headers are suppressed by the trailing `=` on each format key, so every line
/// is four whitespace-separated numbers:
/// ```
///   846   0.4  0.7  179352
/// ```
public enum PsUsageParser {

    public static func parse(_ output: String) -> [Int: ProcessUsage] {
        var result: [Int: ProcessUsage] = [:]

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let tokens = rawLine
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard tokens.count >= 4,
                  let pid = Int(tokens[0]),
                  let cpu = Double(tokens[1]),
                  let mem = Double(tokens[2]),
                  let rss = Int(tokens[3]) else { continue }

            result[pid] = ProcessUsage(cpuPercent: cpu, memoryPercent: mem, residentKB: rss)
        }

        return result
    }
}

/// Reads live CPU / memory usage for running processes by pid.
///
/// Kept separate from ``PortScanner`` for the same reason as
/// ``ProcessDirectoryResolver``: a listening port is still worth showing when
/// its owner's usage can't be read.
public struct ProcessUsageResolver: Sendable {
    /// Absolute path to `ps` — avoids relying on `PATH`, which differs when the
    /// app is launched from Finder rather than a shell.
    public static let psPath = "/bin/ps"

    private let runner: CommandRunning

    public init(runner: CommandRunning = CommandRunner()) {
        self.runner = runner
    }

    /// Map each given pid to its current CPU / memory usage, best-effort.
    ///
    /// Never throws; pids that have already exited are simply absent. Passing no
    /// pids returns an empty map without shelling out — `ps -p ""` would be an error.
    public func resolve(pids: [Int]) -> [Int: ProcessUsage] {
        let unique = Set(pids)
        guard !unique.isEmpty else { return [:] }

        let pidList = unique.map(String.init).joined(separator: ",")
        let arguments = ["-o", "pid=,%cpu=,%mem=,rss=", "-p", pidList]
        guard let result = try? runner.run(Self.psPath, arguments) else { return [:] }
        return PsUsageParser.parse(result.stdout)
    }

    /// Resolve off the main thread. Convenient for SwiftUI view models.
    public func resolveAsync(pids: [Int]) async -> [Int: ProcessUsage] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.resolve(pids: pids))
            }
        }
    }
}
