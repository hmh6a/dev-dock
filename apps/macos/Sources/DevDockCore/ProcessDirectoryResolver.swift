import Foundation

/// Parses the field-mode (`-Fn`) output of
/// `lsof -a -d cwd -p <pids> -Fn`
/// into a `pid → current-working-directory` map.
///
/// Field-mode output is a stream of one-value-per-line records where the first
/// character identifies the field. For a cwd query it looks like:
/// ```
/// p12209        ← process id
/// fcwd          ← file descriptor (always "cwd" here; ignored)
/// n/Users/me/project   ← the directory path
/// ```
/// Anchoring on these single-character field tags is unambiguous even when a
/// path contains spaces, which plain column parsing could not handle.
public enum LsofCwdParser {

    /// Parse field-mode cwd output into `pid → directory`.
    public static func parse(_ output: String) -> [Int: String] {
        var result: [Int: String] = [:]
        var currentPID: Int?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch tag {
            case "p":
                currentPID = Int(value)
            case "n":
                if let pid = currentPID { result[pid] = value }
            default:
                continue // `f` (file descriptor) and any other field are irrelevant.
            }
        }

        return result
    }
}

/// Resolves the current working directory of running processes by pid.
///
/// Kept separate from ``PortScanner`` so the (best-effort, permission-sensitive)
/// directory lookup is an independent, testable step: a listening port is still
/// useful even when its owner's cwd can't be read.
public struct ProcessDirectoryResolver: Sendable {
    /// Absolute path to `lsof`, matching ``PortScanner`` — avoids relying on `PATH`.
    public static let lsofPath = "/usr/sbin/lsof"

    private let runner: CommandRunning

    public init(runner: CommandRunning = CommandRunner()) {
        self.runner = runner
    }

    /// Map each given pid to its current working directory, best-effort.
    ///
    /// Processes we lack permission to inspect are simply absent from the result;
    /// this never throws. Passing no pids returns an empty map without shelling
    /// out — important, since `lsof -p ""` would list *every* process.
    public func resolve(pids: [Int]) -> [Int: String] {
        let unique = Set(pids)
        guard !unique.isEmpty else { return [:] }

        let pidList = unique.map(String.init).joined(separator: ",")
        let arguments = ["-a", "-d", "cwd", "-p", pidList, "-Fn"]
        guard let result = try? runner.run(Self.lsofPath, arguments) else { return [:] }
        return LsofCwdParser.parse(result.stdout)
    }

    /// Resolve off the main thread. Convenient for SwiftUI view models.
    public func resolveAsync(pids: [Int]) async -> [Int: String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.resolve(pids: pids))
            }
        }
    }
}
