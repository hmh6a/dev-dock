import Foundation

/// Where a tool was found, and which version is on disk.
public struct CLIToolInstallation: Equatable, Hashable, Sendable {
    /// Absolute path to the executable — e.g. `/opt/homebrew/bin/mole`.
    public let path: String
    /// Version string as reported by the tool, when it could be read.
    public let version: String?

    public init(path: String, version: String? = nil) {
        self.path = path
        self.version = version
    }
}

/// Finds command-line tools on disk and reads their version.
///
/// It deliberately does **not** trust `PATH` alone: dev-dock is normally started
/// by `launchd`, which hands the app a bare `PATH` with no `/opt/homebrew/bin`,
/// so a Homebrew tool would look missing even though it is installed. The
/// Homebrew prefixes are searched explicitly, then whatever `PATH` adds.
public struct CLIToolLocator: Sendable {
    /// Locations checked before `PATH`, in order — Apple Silicon Homebrew first,
    /// then Intel Homebrew, then the system directories.
    public static let defaultSearchPaths = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    private let runner: CommandRunning
    /// Injected rather than calling `FileManager` directly so tests can describe a
    /// filesystem without creating one (and so the type stays `Sendable`).
    private let isExecutableFile: @Sendable (String) -> Bool
    private let searchPaths: [String]

    public init(
        runner: CommandRunning = CommandRunner(),
        searchPaths: [String]? = nil,
        isExecutableFile: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.runner = runner
        self.isExecutableFile = isExecutableFile
        self.searchPaths = searchPaths ?? (Self.defaultSearchPaths + Self.environmentPaths())
    }

    /// The directories in the process's own `PATH`, appended after the defaults.
    private static func environmentPaths() -> [String] {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return [] }
        return path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    /// The absolute path of `executable`, or `nil` when it isn't installed.
    public func path(forExecutable executable: String) -> String? {
        for directory in searchPaths {
            let candidate = (directory as NSString).appendingPathComponent(executable)
            if isExecutableFile(candidate) { return candidate }
        }
        return nil
    }

    /// Locate `tool` and read its version. `nil` means it isn't installed.
    ///
    /// The version is best-effort: a tool that is present but refuses to print a
    /// version still counts as installed, just without a version badge.
    public func locate(_ tool: CLITool) -> CLIToolInstallation? {
        guard let path = path(forExecutable: tool.executable) else { return nil }
        return CLIToolInstallation(path: path, version: version(ofExecutableAt: path, tool: tool))
    }

    /// Locate every tool in `tools`, off the main thread.
    public func locateAllAsync(_ tools: [CLITool]) async -> [String: CLIToolInstallation] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var result: [String: CLIToolInstallation] = [:]
                for tool in tools {
                    if let installation = self.locate(tool) { result[tool.id] = installation }
                }
                continuation.resume(returning: result)
            }
        }
    }

    private func version(ofExecutableAt path: String, tool: CLITool) -> String? {
        guard !tool.versionArguments.isEmpty,
              let result = try? runner.run(path, tool.versionArguments) else { return nil }
        // Some tools print the version to stderr; fall back to it before giving up.
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        return CLIToolVersionParser.parse(output)
    }
}

/// Pulls a bare version number out of a tool's `--version` banner.
///
/// Output shapes vary wildly (`mole` prints `Mole version 1.44.1` followed by an
/// OS line), so the first dotted-number token on the first non-empty line wins,
/// and the whole line is the fallback.
public enum CLIToolVersionParser {

    public static func parse(_ output: String) -> String? {
        guard let line = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }

        for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let candidate = token.hasPrefix("v") ? String(token.dropFirst()) : String(token)
            if looksLikeVersion(candidate) { return candidate }
        }
        return line
    }

    /// A dotted number like `1.44.1` — digits and dots only, with at least one dot.
    private static func looksLikeVersion(_ token: String) -> Bool {
        guard token.contains("."), let first = token.first, first.isNumber else { return false }
        return token.allSatisfy { $0.isNumber || $0 == "." }
    }
}
