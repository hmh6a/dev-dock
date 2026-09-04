import Foundation

/// Locates `node` and the bundled `agent-runner/runner.mjs` that drives the
/// Claude Agent SDK (which powers interactive permission approvals).
enum RunnerLocator {
    static func node() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            home.appendingPathComponent(".nvm/current/bin/node").path,
            "/usr/bin/node",
        ]
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return viaLoginShell("node")
    }

    /// Find `agent-runner/runner.mjs`: an env override, then inside the app
    /// bundle's resources (how the released `.app` ships it), then by walking up
    /// from the executable (how it is found when run from a checkout).
    static func runnerScript() -> URL? {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["DEVDOCK_AGENT_RUNNER"],
           fileManager.isReadableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        // A packaged build carries the runner in `Contents/Resources`, which is
        // not on the walk-up path from `Contents/MacOS`.
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("agent-runner/runner.mjs"),
           fileManager.isReadableFile(atPath: bundled.path) {
            return bundled
        }

        var searchRoots: [URL] = []
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            searchRoots.append(executable.deletingLastPathComponent())
        }
        searchRoots.append(URL(fileURLWithPath: fileManager.currentDirectoryPath))

        for root in searchRoots {
            var dir = root
            for _ in 0..<8 {
                let candidate = dir.appendingPathComponent("agent-runner/runner.mjs")
                if fileManager.isReadableFile(atPath: candidate.path) { return candidate }
                let parent = dir.deletingLastPathComponent()
                if parent == dir { break }
                dir = parent
            }
        }
        return nil
    }

    private static func viaLoginShell(_ tool: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(tool)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
