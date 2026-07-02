import Foundation

/// Discovers listening TCP ports by shelling out to `lsof` and parsing the result.
///
/// The command matches the project spec exactly:
/// `lsof -iTCP -sTCP:LISTEN -n -P`.
public struct PortScanner: Sendable {
    /// Absolute path to `lsof` on macOS. Using an absolute path avoids relying on
    /// `PATH`, which may differ when launched from Finder vs. a shell.
    public static let lsofPath = "/usr/sbin/lsof"
    public static let lsofArguments = ["-iTCP", "-sTCP:LISTEN", "-n", "-P"]

    private let runner: CommandRunning

    public init(runner: CommandRunning = CommandRunner()) {
        self.runner = runner
    }

    /// Synchronously scan for listening ports.
    public func scan() throws -> [PortEntry] {
        let result = try runner.run(Self.lsofPath, Self.lsofArguments)
        return LsofParser.parse(result.stdout)
    }

    /// Scan off the main thread. Convenient for SwiftUI view models.
    public func scanAsync() async throws -> [PortEntry] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.scan())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
