import SwiftUI
import Combine
import DevDockCore

/// App-wide observable state. Owns the AI session, the Remote Control manager,
/// and the WebSocket bridge server — and keeps the VS Code extension panel in
/// sync with the AI conversation in real time.
@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: AppTab = .ports

    /// The single, long-lived Claude Code chat session.
    let claude = ClaudeCodeSession()

    /// The Remote Control server manager.
    let remote = RemoteControlManager()

    /// The localhost WebSocket server the VS Code extension connects to.
    let server = BridgeServer()

    /// Serves the installable mobile web app (PWA) over the LAN.
    let pwa = PWAServer()

    /// Interactive terminals (PTYs) a connected client can open per project.
    let terminal = TerminalManager()

    private var cancellables: Set<AnyCancellable> = []

    init() {
        // A prompt / command arriving from the VS Code panel.
        server.onMessage = { [weak self] message in
            guard let self else { return }
            switch message.type {
            case .chatSend:
                if let text = message.text { self.claude.send(text) }
            case .chatStop:
                self.claude.stop()
            case .chatNew:
                self.claude.startNewSession()
            case .permissionResponse:
                if let id = message.permissionId {
                    self.claude.respondToPermission(id: id, allow: message.allow ?? false,
                                                    remember: message.remember ?? false, message: message.text)
                }
            case .listProjects:
                self.claude.loadProjects()
            case .openProject:
                if let id = message.projectId,
                   let project = self.claude.projects.first(where: { $0.id == id }) {
                    self.claude.openProject(project)   // switches workspace + loads its sessions
                }
            case .listSessions:
                if let id = message.projectId,
                   let project = self.claude.projects.first(where: { $0.id == id }) {
                    self.claude.loadSessions(for: project)
                } else if let project = self.claude.currentProject {
                    self.claude.loadSessions(for: project)
                }
            case .resumeSession:
                if let ref = message.sessionRef,
                   let summary = self.claude.sessions.first(where: { $0.id == ref }) {
                    self.claude.resume(summary)
                }
            case .setAutoApprove:
                self.claude.autoApprove = message.autoApprove ?? false
            case .restartProject:
                self.claude.restart()
            case .termOpen:
                if let id = message.termId {
                    self.terminal.open(
                        id: id,
                        projectId: message.projectId,
                        cwd: self.terminalCwd(projectId: message.projectId),
                        cols: UInt16(message.cols ?? 80),
                        rows: UInt16(message.rows ?? 24)
                    )
                }
            case .termRename:
                if let id = message.termId { self.terminal.rename(id: id, title: message.text, color: message.color) }
            case .termInput:
                if let id = message.termId { self.terminal.input(id: id, base64: message.data) }
            case .termResize:
                if let id = message.termId {
                    self.terminal.resize(id: id, cols: UInt16(message.cols ?? 80), rows: UInt16(message.rows ?? 24))
                }
            case .termClose:
                if let id = message.termId { self.terminal.close(id: id) }
            case .listDir:
                guard let root = self.fileBrowserRoot(projectId: message.projectId) else {
                    self.server.broadcast(BridgeMessage(type: .dirList, file: "", entries: []))
                    break
                }
                let result = FileBrowser.list(path: message.file ?? "", root: root)
                self.server.broadcast(BridgeMessage(type: .dirList, file: result.path,
                                                    entries: result.entries))
            case .readFile:
                guard let root = self.fileBrowserRoot(projectId: message.projectId), let path = message.file else {
                    self.server.broadcast(BridgeMessage(type: .fileContent, file: message.file,
                                                        content: "Open a project first to browse its files.", truncated: false))
                    break
                }
                if let r = FileBrowser.read(path: path, root: root) {
                    self.server.broadcast(BridgeMessage(type: .fileContent, file: r.path,
                                                        content: r.content, truncated: r.truncated))
                } else {
                    self.server.broadcast(BridgeMessage(type: .fileContent, file: message.file,
                                                        content: "Couldn't read this file.", truncated: false))
                }
            default:
                break
            }
        }
        terminal.broadcast = { [weak self] msg in self?.server.broadcast(msg) }
        // The open shells are shared across devices — push the list whenever it changes.
        terminal.onListChanged = { [weak self] in self?.broadcastTerminals() }
        // A newly-connected client gets the current conversation + open shells immediately.
        server.onConnect = { [weak self] in
            self?.broadcastConversation()
            self?.broadcastTerminals()
        }

        // Push the conversation to connected clients whenever it changes.
        claude.$messages
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.broadcastConversation() }
            .store(in: &cancellables)
        // Working-status changes (verb + tokens) also push to the panel.
        Publishers.Merge3(
            claude.$statusText.map { _ in () },
            claude.$streamingTokens.map { _ in () },
            claude.$workingVerb.map { _ in () }
        )
        .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] _ in self?.broadcastConversation() }
        .store(in: &cancellables)
        // Permission prompts push immediately (no throttle) to the panel.
        claude.$pendingPermission
            .sink { [weak self] _ in self?.broadcastConversation() }
            .store(in: &cancellables)
        // Project / conversation lists push to clients whenever they change, so a
        // phone or the extension can browse and pick any project or past chat.
        claude.$projects
            .sink { [weak self] projects in self?.broadcastProjects(projects) }
            .store(in: &cancellables)
        claude.$sessions
            .sink { [weak self] sessions in self?.broadcastSessions(sessions) }
            .store(in: &cancellables)
        // Auto-approve toggle changes push so every client reflects the new state.
        // `@Published` fires in willSet (before the value commits), so defer the
        // broadcast a turn to read the committed value.
        claude.$autoApprove
            .sink { [weak self] _ in Task { @MainActor in self?.broadcastConversation() } }
            .store(in: &cancellables)

        server.start()
        pwa.start()
    }

    /// The active project's display name (for client headers / snapshots).
    private var activeProjectName: String {
        if let project = claude.currentProject { return project.name }
        if let url = claude.workspaceURL { return url.lastPathComponent }
        return "~"
    }

    /// Root for the read-only file browser: a real opened project only — never the
    /// home folder or an arbitrary path. Returns nil when there's nothing to browse,
    /// so a remote client can only ever see files inside opened projects.
    private func fileBrowserRoot(projectId: String?) -> String? {
        if let id = projectId, let project = claude.projects.first(where: { $0.id == id }) { return project.path }
        if let project = claude.currentProject { return project.path }
        return nil
    }

    /// Where a terminal should open: the requested project, else the current one.
    private func terminalCwd(projectId: String?) -> String {
        if let id = projectId, let project = claude.projects.first(where: { $0.id == id }) { return project.path }
        if let project = claude.currentProject { return project.path }
        if let url = claude.workspaceURL { return url.path }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func broadcastConversation() {
        let wire = claude.messages.map { message in
            ChatWireMessage(
                role: message.role == .user ? "user" : "assistant",
                text: message.text,
                tools: message.tools,
                streaming: message.isStreaming,
                isError: message.isError
            )
        }
        let permission = claude.pendingPermission.map {
            PermissionWire(id: $0.id, tool: $0.tool, title: $0.title, body: $0.body, canRemember: $0.canRemember)
        }
        server.broadcast(BridgeMessage(
            type: .chatSnapshot, chat: wire, status: claude.displayStatus,
            permission: permission, projectName: activeProjectName,
            autoApprove: claude.autoApprove,
            terminalEnabled: terminal.isEnabled,
            costUSD: claude.totalCostUSD
        ))
    }

    private func broadcastProjects(_ projects: [ClaudeProject]) {
        let wire = projects.map {
            ProjectWire(id: $0.id, name: $0.name, path: $0.path, branch: $0.gitBranch,
                        sessionCount: $0.sessionCount, modified: $0.lastModified.timeIntervalSince1970)
        }
        server.broadcast(BridgeMessage(type: .projectList, projects: wire))
    }

    private func broadcastSessions(_ sessions: [ClaudeSessionSummary]) {
        let wire = sessions.map {
            SessionWire(id: $0.id, title: $0.title, messageCount: $0.messageCount,
                        modified: $0.lastModified.timeIntervalSince1970)
        }
        server.broadcast(BridgeMessage(type: .sessionList, sessions: wire, projectName: activeProjectName))
    }

    private func broadcastTerminals() {
        server.broadcast(BridgeMessage(type: .termList, terminals: terminal.list()))
    }
}
