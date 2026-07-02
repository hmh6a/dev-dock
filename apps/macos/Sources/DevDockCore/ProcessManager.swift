import Foundation

/// Terminates processes. Isolated behind its own type so the destructive
/// operation is easy to find, reason about, and gate behind a confirmation.
public struct ProcessManager {
    private let runner: CommandRunning

    public init(runner: CommandRunning = CommandRunner()) {
        self.runner = runner
    }

    public enum KillError: LocalizedError {
        case failed(pid: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case let .failed(pid, message):
                return "Could not kill process \(pid): \(message)"
            }
        }
    }

    /// Terminate a process.
    ///
    /// - Parameters:
    ///   - pid: the process id to signal.
    ///   - force: when `true` sends `SIGKILL` (`-9`), otherwise a graceful `SIGTERM` (`-15`).
    public func kill(pid: Int, force: Bool = false) throws {
        let signal = force ? "-9" : "-15"
        let result = try runner.run("/bin/kill", [signal, String(pid)])
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw KillError.failed(pid: pid, message: message.isEmpty ? "exit code \(result.exitCode)" : message)
        }
    }
}
