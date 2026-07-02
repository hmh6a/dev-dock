import Foundation
import DevDockCore

/// Drives a real Claude Code conversation by spawning the `claude` CLI in
/// streaming mode, one process per turn, resuming the same session id so history
/// is preserved. Parses `stream-json` events into live UI updates.
@MainActor
final class ClaudeCodeSession: ObservableObject {
    // Conversation
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var statusText = ""
    @Published private(set) var totalCostUSD: Double = 0

    // Live working indicator: estimated output tokens + a rotating status verb.
    @Published private(set) var streamingTokens = 0
    @Published private(set) var workingVerb = "Thinking"

    // Available agents (seeded from files, enriched from the init event)
    @Published private(set) var availableAgents: [ClaudeAgent] = [.default]

    // User-selectable configuration (bound to the pickers)
    @Published var model: ClaudeModel = .default
    @Published var effort: ReasoningEffort = .default
    @Published var agent: ClaudeAgent = .default
    @Published var accessMode: AccessMode = .ask

    /// When on, tool-permission prompts in Ask mode are auto-approved (always the
    /// first option, "Yes"). Toggleable live from the phone or the VS Code panel.
    @Published var autoApprove = false

    /// The folder Claude Code runs in — the same workspace as the editor, so both
    /// see the same files. Fed by the VS Code bridge (falls back to home).
    @Published var workspaceURL: URL?

    // History browsing (from ~/.claude/projects)
    @Published private(set) var projects: [ClaudeProject] = []
    @Published private(set) var sessions: [ClaudeSessionSummary] = []
    @Published private(set) var currentProject: ClaudeProject?
    @Published private(set) var isLoadingHistory = false

    // Live-following the active session file (mirrors the VS Code conversation).
    @Published private(set) var isLive = false
    private var liveFileURL: URL?
    private var liveTask: Task<Void, Never>?

    private let historyStore = ClaudeHistoryStore()
    private let nodeURL: URL?
    private let runnerURL: URL?
    private var sessionId = UUID().uuidString.lowercased()
    private var hasStarted = false
    private var process: Process?
    private var runnerStdin: FileHandle?
    private var streamTask: Task<Void, Never>?
    /// Monotonic id of the *foreground* run. A run whose token no longer matches
    /// has been parked to the background (the user navigated away) — it keeps
    /// running to completion and writing to disk, but no longer touches the UI.
    private var runToken = 0
    private var streamedDeltas = false
    private var streamingChars = 0
    private var hasStreamedText = false
    private var verbTask: Task<Void, Never>?

    private static let workingVerbs = [
        "Ideating", "Manifesting", "Conjuring", "Pondering", "Divining",
        "Percolating", "Ruminating", "Synthesizing", "Cogitating", "Noodling",
        "Formulating", "Marinating", "Brewing", "Scheming", "Contemplating",
    ]

    /// A single status line combining the rotating verb and token estimate,
    /// used for the app subtitle and pushed to the VS Code panel.
    var displayStatus: String {
        guard isStreaming else { return statusText }
        let tokens = streamingTokens > 0 ? " · \(streamingTokens) tokens" : ""
        return "\(workingVerb)…\(tokens)"
    }

    /// A pending interactive permission request (Ask mode). Bound by the UI.
    @Published var pendingPermission: PermissionRequest?

    var isAvailable: Bool { nodeURL != nil && runnerURL != nil }

    /// Whether there's a session file we can live-follow (i.e. a resumed session).
    var canFollow: Bool { liveFileURL != nil }

    init(workspaceURL: URL? = nil) {
        self.workspaceURL = workspaceURL
        self.nodeURL = RunnerLocator.node()
        self.runnerURL = RunnerLocator.runnerScript()
        let directories = AgentCatalog.defaultDirectories(workspace: workspaceURL)
        self.availableAgents = [.default] + AgentCatalog.discover(in: directories)
    }

    /// Per-run state, so a parked (background) run keeps everything it needs
    /// (its own process + stdin) independent of the foreground conversation.
    private final class RunContext {
        let token: Int
        let assistantID: UUID
        var process: Process?
        var stdin: FileHandle?
        init(token: Int, assistantID: UUID) {
            self.token = token
            self.assistantID = assistantID
        }
    }

    private func isForeground(_ ctx: RunContext) -> Bool { ctx.token == runToken }

    /// Move the running turn to the background: it keeps streaming to completion
    /// (the SDK writes it to disk) but stops driving the UI, so we can switch to
    /// another conversation without killing it.
    private func parkForegroundRun() {
        guard isStreaming else { return }
        runToken += 1          // the running RunContext is now "background"
        streamTask = nil       // keep the Task alive (not cancelled); just drop our handle
        verbTask?.cancel()
        process = nil
        runnerStdin = nil
        pendingPermission = nil
        isStreaming = false
        statusText = ""
        streamingTokens = 0
    }

    // MARK: - Public API

    func send(_ userText: String, attachments: [URL] = []) {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !(text.isEmpty && attachments.isEmpty) else { return }

        messages.append(ChatMessage(role: .user, text: text, attachments: attachments))

        guard let nodeURL, let runnerURL else {
            messages.append(ChatMessage(
                role: .assistant,
                text: "I couldn't find `node` and the dev-dock agent runner. Run `npm install` in `agent-runner/`.",
                isError: true
            ))
            return
        }

        // Reference attached images by path so Claude reads them with the Read tool.
        let prompt: String = {
            guard !attachments.isEmpty else { return text }
            let paths = attachments.map(\.path).joined(separator: "\n")
            let lead = text.isEmpty
                ? "Please view the attached image(s) using the Read tool:"
                : text + "\n\nAttached image(s) — view them with the Read tool:"
            return lead + "\n" + paths
        }()

        let assistant = ChatMessage(role: .assistant, text: "", isStreaming: true)
        messages.append(assistant)
        let assistantID = assistant.id
        isStreaming = true
        streamedDeltas = false
        streamingChars = 0
        streamingTokens = 0
        hasStreamedText = false
        workingVerb = "Thinking"
        statusText = "Thinking…"
        startVerbRotation()

        var config: [String: Any] = [
            "prompt": prompt,
            "model": model.id,
            "effort": effort.cliValue,
            "cwd": (workspaceURL ?? FileManager.default.homeDirectoryForCurrentUser).path,
            "permissionMode": accessMode.permissionMode,
            "allowedTools": accessMode.allowedTools,
            "resume": hasStarted,
            "sessionId": sessionId,
        ]
        if agent.isDefault { config["agent"] = NSNull() } else { config["agent"] = agent.name }
        let configJSON = (try? JSONSerialization.data(withJSONObject: config))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        runToken += 1
        let ctx = RunContext(token: runToken, assistantID: assistantID)
        streamTask = Task { [weak self] in
            await self?.runStream(ctx: ctx, nodeURL: nodeURL, runnerURL: runnerURL, configJSON: configJSON)
        }
    }

    func stop() {
        streamTask?.cancel()
        verbTask?.cancel()
        process?.terminate()
        process = nil
        runnerStdin = nil
        pendingPermission = nil
        isStreaming = false
        statusText = "Stopped"
    }

    private func startVerbRotation() {
        verbTask?.cancel()
        verbTask = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                guard let self, self.isStreaming else { break }
                self.workingVerb = Self.workingVerbs[index % Self.workingVerbs.count]
                index += 1
                try? await Task.sleep(nanoseconds: 1_600_000_000)
            }
        }
    }

    /// Restart the project: hard-stop the current turn (terminates the runner,
    /// so a stuck "Thinking…" is killed) and begin a fresh conversation in the
    /// same project/workspace. Unlike ``startNewSession``, the in-flight turn is
    /// stopped, not parked in the background.
    func restart() {
        stop()                                       // terminate the runner process
        stopFollowing()
        messages.removeAll()
        sessionId = UUID().uuidString.lowercased()
        hasStarted = false
        totalCostUSD = 0
        pendingPermission = nil
        statusText = ""
    }

    /// Start a fresh conversation, keeping the current project/workspace. Any
    /// in-flight turn keeps running in the background.
    func startNewSession() {
        parkForegroundRun()
        stopFollowing()
        messages.removeAll()
        sessionId = UUID().uuidString.lowercased()
        hasStarted = false
        totalCostUSD = 0
        statusText = ""
    }

    // MARK: - Live following (mirror the active session file)

    /// Toggle live-following of the current session's transcript file.
    func toggleLive() {
        if isLive {
            stopFollowing()
        } else if liveFileURL != nil {
            startFollowing()
        }
    }

    private func startFollowing() {
        guard let fileURL = liveFileURL else { return }
        isLive = true
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            await self?.followLoop(fileURL)
        }
    }

    private func stopFollowing() {
        isLive = false
        liveTask?.cancel()
        liveTask = nil
    }

    /// Polls the session file ~1×/sec and re-syncs the conversation when it
    /// changes (e.g. new messages written by the VS Code session), unless we're
    /// mid-stream on our own turn.
    private func followLoop(_ fileURL: URL) async {
        var lastModified = modificationDate(of: fileURL)
        while !Task.isCancelled && isLive {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, isLive, !isStreaming else { continue }
            let modified = modificationDate(of: fileURL)
            if modified != lastModified {
                lastModified = modified
                await reloadFollowed()
            }
        }
    }

    private func reloadFollowed() async {
        let store = historyStore
        let sid = sessionId
        let pid = currentProject?.id ?? ""
        let transcript = await Task.detached { store.transcript(sessionID: sid, projectID: pid) }.value
        guard isLive, !isStreaming else { return }
        messages = transcript.suffix(300).map { entry in
            ChatMessage(role: entry.role == .user ? .user : .assistant, text: entry.text, tools: entry.tools)
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func reset() {
        startNewSession()
        currentProject = nil
    }

    // MARK: - Projects & history

    /// Load the list of projects from `~/.claude/projects`.
    func loadProjects() {
        isLoadingHistory = true
        let store = historyStore
        Task {
            let projects = await Task.detached { store.projects() }.value
            self.projects = projects
            self.isLoadingHistory = false
        }
    }

    /// Select a project: point the workspace at it, start a fresh chat, and load
    /// its past conversations.
    func openProject(_ project: ClaudeProject) {
        currentProject = project
        workspaceURL = URL(fileURLWithPath: project.path)
        startNewSession()
        let mergedAgents = [ClaudeAgent.default] + AgentCatalog.discover(
            in: AgentCatalog.defaultDirectories(workspace: workspaceURL)
        )
        availableAgents = mergedAgents
        loadSessions(for: project)
    }

    /// Use an arbitrary folder (outside the known projects) for a fresh chat.
    func openFolder(_ url: URL) {
        currentProject = nil
        sessions = []
        workspaceURL = url
        startNewSession()
    }

    func loadSessions(for project: ClaudeProject) {
        isLoadingHistory = true
        let store = historyStore
        let id = project.id
        Task {
            let sessions = await Task.detached { store.sessions(forProjectID: id) }.value
            self.sessions = sessions
            self.isLoadingHistory = false
        }
    }

    /// Reopen a past conversation: replay its messages and set up `--resume` so
    /// the next prompt continues that exact session on disk.
    func resume(_ summary: ClaudeSessionSummary) {
        parkForegroundRun()
        stopFollowing()
        workspaceURL = URL(fileURLWithPath: summary.projectPath)
        if currentProject?.path != summary.projectPath {
            currentProject = projects.first { $0.path == summary.projectPath }
        }
        let store = historyStore
        let sessionID = summary.id
        let projectID = currentProject?.id ?? summary.projectPath.replacingOccurrences(of: "/", with: "-")
        messages = [ChatMessage(role: .assistant, text: "", isStreaming: true)]
        statusText = "Loading conversation…"
        isLoadingHistory = true

        Task {
            let transcript = await Task.detached {
                store.transcript(sessionID: sessionID, projectID: projectID)
            }.value
            self.messages = transcript.suffix(120).map { entry in
                ChatMessage(
                    role: entry.role == .user ? .user : .assistant,
                    text: entry.text,
                    tools: entry.tools
                )
            }
            self.sessionId = sessionID
            self.hasStarted = true          // next send resumes this session
            self.isLoadingHistory = false
            self.statusText = ""
            // Follow the file so IDE / other-device edits appear in real time.
            self.liveFileURL = store.sessionFileURL(sessionID: sessionID, projectID: projectID)
            self.startFollowing()
        }
    }

    // MARK: - Streaming

    private func runStream(ctx: RunContext, nodeURL: URL, runnerURL: URL, configJSON: String) async {
        let process = Process()
        process.executableURL = nodeURL
        process.arguments = [runnerURL.path, configJSON]
        process.currentDirectoryURL = workspaceURL ?? FileManager.default.homeDirectoryForCurrentUser

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        ctx.process = process
        ctx.stdin = inPipe.fileHandleForWriting
        if isForeground(ctx) {
            self.process = process
            self.runnerStdin = ctx.stdin
        }

        do {
            try process.run()
        } catch {
            finalize(ctx: ctx, exitCode: -1, stderr: "Failed to launch runner: \(error.localizedDescription)")
            return
        }

        // Drain stderr concurrently so a chatty stderr can't deadlock stdout.
        let errorHandle = errPipe.fileHandleForReading
        let stderrTask = Task.detached { errorHandle.readDataToEndOfFile() }

        // Keep draining even if parked to the background — the SDK must finish and
        // persist the conversation to disk. (`stop()` ends it by terminating the
        // process, which closes the pipe.)
        do {
            for try await line in outPipe.fileHandleForReading.bytes.lines {
                handleLine(line, ctx: ctx)
            }
        } catch {
            // Reading interrupted; fall through to finalize.
        }

        process.waitUntilExit()
        if isForeground(ctx) {
            self.runnerStdin = nil
            pendingPermission = nil
        }
        let stderr = String(decoding: await stderrTask.value, as: UTF8.self)
        finalize(ctx: ctx, exitCode: process.terminationStatus, stderr: stderr)
    }

    /// Route a runner output line: control types (permission requests, errors) are
    /// handled here; everything else is a stream-json message for the parser.
    private func handleLine(_ line: String, ctx: RunContext) {
        if let data = line.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = object["type"] as? String {
            switch type {
            case "permission_request":
                handlePermissionRequest(object, ctx: ctx)
                return
            case "runner_error":
                if isForeground(ctx) {
                    update(ctx.assistantID) {
                        $0.text += (object["message"] as? String) ?? "Runner error"
                        $0.isError = true
                    }
                }
                return
            case "runner_done":
                return
            default:
                break
            }
        }
        guard isForeground(ctx) else { return }   // background run: drain only, no UI
        for event in ClaudeStreamParser.parse(line: line) {
            handle(event, assistantID: ctx.assistantID)
        }
    }

    // MARK: - Permissions

    private func handlePermissionRequest(_ object: [String: Any], ctx: RunContext) {
        guard let id = object["id"] as? String, let tool = object["tool"] as? String else { return }

        // A backgrounded run can't prompt the user — auto-deny so it completes
        // instead of blocking forever on approval.
        guard isForeground(ctx) else {
            writePermission(id: id, allow: false, message: "Backgrounded — denied", to: ctx.stdin)
            return
        }

        let input = object["input"] as? [String: Any] ?? [:]
        switch accessMode {
        case .full:
            respondToPermission(id: id, allow: true)          // shouldn't occur (bypass)
        case .safe:
            respondToPermission(id: id, allow: false, message: "Read-only mode — denied")
        case .ask:
            if autoApprove {
                respondToPermission(id: id, allow: true)      // "always pick the first option"
            } else {
                pendingPermission = PermissionRequest.make(
                    id: id, tool: tool, input: input,
                    sdkTitle: object["title"] as? String,
                    sdkDescription: object["description"] as? String,
                    canRemember: (object["canRemember"] as? Bool) ?? false
                )
                statusText = "Waiting for approval…"
            }
        }
    }

    /// Answer the current (or a specific) permission request (foreground run).
    func respondToPermission(id: String, allow: Bool, remember: Bool = false, message: String? = nil) {
        writePermission(id: id, allow: allow, remember: remember, message: message, to: runnerStdin)
        if pendingPermission?.id == id { pendingPermission = nil }
    }

    private func writePermission(id: String, allow: Bool, remember: Bool = false, message: String?, to stdin: FileHandle?) {
        var reply: [String: Any] = ["type": "permission", "id": id, "allow": allow]
        if remember { reply["remember"] = true }
        if let message { reply["message"] = message }
        if let data = try? JSONSerialization.data(withJSONObject: reply),
           var line = String(data: data, encoding: .utf8) {
            line += "\n"
            stdin?.write(Data(line.utf8))
        }
    }

    /// Convenience for the UI acting on the visible request.
    func answerPendingPermission(allow: Bool, remember: Bool = false, message: String? = nil) {
        guard let pending = pendingPermission else { return }
        respondToPermission(id: pending.id, allow: allow, remember: remember, message: message)
    }

    private func handle(_ event: ClaudeStreamEvent, assistantID: UUID) {
        switch event {
        case let .sessionStarted(sid, _, cwd, agents):
            if !sid.isEmpty { sessionId = sid }
            mergeAgents(names: agents)
            let folder = URL(fileURLWithPath: cwd).lastPathComponent
            statusText = folder.isEmpty ? "Working…" : "Working in \(folder)…"

        case .assistantBlockStart:
            update(assistantID) { message in
                if !message.text.isEmpty, !message.text.hasSuffix("\n") {
                    message.text += "\n\n"
                }
            }

        case let .thinkingDelta(chunk):
            streamingChars += chunk.count
            streamingTokens = streamingChars / 4

        case let .assistantDelta(chunk):
            streamedDeltas = true
            hasStreamedText = true
            streamingChars += chunk.count
            streamingTokens = streamingChars / 4
            update(assistantID) { $0.text += chunk }
            statusText = "Responding…"

        case let .assistantText(chunk):
            // Fallback for non-partial mode; ignored when deltas already streamed
            // the text (avoids duplicating it at end of turn).
            guard !streamedDeltas else { break }
            update(assistantID) { message in
                if !message.text.isEmpty { message.text += "\n\n" }
                message.text += chunk
            }
            statusText = "Responding…"

        case let .toolUse(name):
            update(assistantID) { message in
                if !message.tools.contains(name) { message.tools.append(name) }
            }
            statusText = "Using \(name)…"

        case let .result(text, isError, cost):
            if let cost { totalCostUSD += cost }
            update(assistantID) { message in
                if message.text.isEmpty { message.text = text }
                if isError { message.isError = true }
            }
        }
    }

    private func finalize(ctx: RunContext, exitCode: Int32, stderr: String) {
        // A parked (background) run finished — it already persisted to disk, and
        // its messages are no longer on screen, so there's nothing to update.
        guard isForeground(ctx) else { return }
        let assistantID = ctx.assistantID
        hasStarted = true
        isStreaming = false
        verbTask?.cancel()
        statusText = ""
        process = nil
        update(assistantID) { $0.isStreaming = false }

        if let message = messages.first(where: { $0.id == assistantID }), message.text.isEmpty {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            update(assistantID) {
                $0.text = detail.isEmpty ? "No response (runner exited with code \(exitCode))." : detail
                $0.isError = true
            }
        }
    }

    // MARK: - Helpers

    private func update(_ id: UUID, _ mutate: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&messages[index])
    }

    private func mergeAgents(names: [String]) {
        var existing = Set(availableAgents.map(\.name))
        for name in names where !name.isEmpty && name != "claude" && !existing.contains(name) {
            availableAgents.append(ClaudeAgent(name: name))
            existing.insert(name)
        }
    }
}
