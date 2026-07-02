import Foundation
import DevDockCore

/// Runs Claude Code's official Remote Control server (`claude remote-control`)
/// as a managed child process, auto-confirms the prompt, and surfaces the
/// session URL + status so the user can drive their machine from the Claude
/// mobile app / claude.ai while away — all set up and monitored inside dev-dock.
@MainActor
final class RemoteControlManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case ready
        case stopped
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var sessionURL: URL?
    @Published private(set) var statusLine = ""
    @Published var workspaceURL: URL?

    private let claudeURL: URL?
    private var process: Process?
    private var streamTask: Task<Void, Never>?

    var isAvailable: Bool { claudeURL != nil }
    var isActive: Bool { phase == .starting || phase == .ready }

    init(workspaceURL: URL? = nil) {
        self.workspaceURL = workspaceURL
        self.claudeURL = ClaudeLocator.resolve()
    }

    func start() {
        guard let claudeURL, !isActive else { return }
        phase = .starting
        sessionURL = nil
        statusLine = "Starting…"
        let cwd = workspaceURL ?? FileManager.default.homeDirectoryForCurrentUser
        let name = cwd.lastPathComponent.isEmpty ? "dev-dock" : cwd.lastPathComponent
        streamTask = Task { [weak self] in
            await self?.run(claudeURL: claudeURL, name: name, cwd: cwd)
        }
    }

    func stop() {
        streamTask?.cancel()
        process?.terminate()
        process = nil
        phase = .stopped
        statusLine = ""
        sessionURL = nil
    }

    private func run(claudeURL: URL, name: String, cwd: URL) async {
        let process = Process()
        process.executableURL = claudeURL
        process.arguments = ["remote-control", "--name", name]
        process.currentDirectoryURL = cwd

        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = outPipe // merge so we parse everything together
        self.process = process

        do {
            try process.run()
        } catch {
            phase = .failed("Failed to launch: \(error.localizedDescription)")
            self.process = nil
            return
        }

        // Auto-answer "Enable Remote Control? (y/n)".
        inPipe.fileHandleForWriting.write(Data("y\n".utf8))

        do {
            for try await line in outPipe.fileHandleForReading.bytes.lines {
                if Task.isCancelled { break }
                if let signal = RemoteControlParser.parse(line: line) {
                    apply(signal)
                }
            }
        } catch {
            // Stream ended/interrupted — fall through to exit handling.
        }

        process.waitUntilExit()
        self.process = nil
        if Task.isCancelled { return } // stop() already set the phase

        if sessionURL != nil {
            phase = .stopped
        } else {
            let hint = statusLine.isEmpty
                ? "make sure you're signed in with a subscription (run `claude`, then /login)."
                : statusLine
            phase = .failed("Remote Control didn't start — \(hint)")
        }
        statusLine = ""
    }

    private func apply(_ signal: RemoteControlSignal) {
        switch signal {
        case let .url(string):
            sessionURL = URL(string: string)
            phase = .ready
            statusLine = "Ready"
        case .ready:
            phase = .ready
            statusLine = "Ready"
        case .connecting:
            statusLine = "Connecting…"
        case let .status(text):
            statusLine = text
        }
    }
}
