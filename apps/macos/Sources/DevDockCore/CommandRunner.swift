import Foundation

/// A thin, testable wrapper around `Foundation.Process` for running short-lived
/// command-line tools and capturing their output.
///
/// Kept separate from the services that use it so those services can be unit
/// tested against a stub runner without spawning real processes.
public protocol CommandRunning: Sendable {
    func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult
}

public struct CommandResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public struct CommandRunner: CommandRunning {
    public init() {}

    public func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // Drain both pipes *before* waiting so a large output can't deadlock us.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }
}
