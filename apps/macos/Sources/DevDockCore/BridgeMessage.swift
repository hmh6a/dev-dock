import Foundation

/// The wire protocol shared between the macOS app and the `dev-dock-vscode`
/// extension, exchanged as JSON over a localhost WebSocket.
///
/// The Swift and TypeScript sides must keep this in sync. The schema is a single
/// flat envelope with a required ``type`` and a set of optional fields so it maps
/// cleanly to JSON on both sides. See `docs/websocket-protocol.md`.
public enum BridgeMessageType: String, Codable, Sendable {
    // Editor → Dock (context updates)
    case hello
    case workspaceInfo
    case activeFile
    case selection

    // Dock → Editor (commands)
    case openFile
    case createFile
    case replaceSelection
    case insertText
    case runTerminalCommand

    // Chat sync (dev-dock app ↔ extension webview panel)
    case chatSnapshot         // app → clients: the full conversation state (+ pending permission)
    case chatSend             // client → app: user submitted a message
    case chatStop             // client → app: stop the current stream
    case chatNew              // client → app: start a new conversation
    case permissionResponse   // client → app: answer to a permission request

    // Project / conversation browsing (client picks any project + past chat)
    case listProjects         // client → app: send me the project list
    case openProject          // client → app: switch to project `projectId`
    case listSessions         // client → app: send past conversations (optionally for `projectId`)
    case resumeSession        // client → app: reopen conversation `sessionRef`
    case projectList          // app → clients: available projects
    case sessionList          // app → clients: past conversations for the current project

    // Settings / lifecycle
    case setAutoApprove       // client → app: toggle auto-approve of tool prompts
    case restartProject       // client → app: stop the running turn + fresh chat, same project

    // Terminal (interactive PTY for the phone PWA)
    case termOpen             // client → app: open a shell (termId, projectId?, cols, rows)
    case termInput            // client → app: keystrokes (termId, data = base64)
    case termResize           // client → app: resize (termId, cols, rows)
    case termClose            // client → app: close the shell (termId)
    case termData             // app → client: output bytes (termId, data = base64, reset?)
    case termExit             // app → client: the shell ended (termId)
    case termRename           // client → app: set a shell's title/color (termId, text=title, color)
    case termList             // app → client: the open shells (terminals) — shared across devices

    // File browser (read-only, within the active project)
    case listDir              // client → app: list a directory (file = path, empty = project root)
    case readFile             // client → app: read a file (file = path)
    case dirList              // app → client: directory entries (file = path, entries)
    case fileContent          // app → client: file contents (file = path, content, truncated)

    // Meta
    case ack
    case error
}

/// An open terminal session, shared across devices (for `termList`).
public struct TerminalWire: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var color: String
    public var projectId: String?

    public init(id: String, title: String, color: String, projectId: String?) {
        self.id = id
        self.title = title
        self.color = color
        self.projectId = projectId
    }
}

/// One entry in a directory listing.
public struct FileEntryWire: Codable, Sendable, Equatable {
    public var name: String
    public var isDir: Bool
    public var size: Int

    public init(name: String, isDir: Bool, size: Int) {
        self.name = name
        self.isDir = isDir
        self.size = size
    }
}

/// A project available to open remotely. Mirrors `ClaudeProject`.
public struct ProjectWire: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var path: String
    public var branch: String?
    public var sessionCount: Int
    public var modified: Double        // epoch seconds, for a relative-time label

    public init(id: String, name: String, path: String, branch: String?, sessionCount: Int, modified: Double) {
        self.id = id
        self.name = name
        self.path = path
        self.branch = branch
        self.sessionCount = sessionCount
        self.modified = modified
    }
}

/// A past conversation available to resume remotely. Mirrors `ClaudeSessionSummary`.
public struct SessionWire: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var messageCount: Int
    public var modified: Double        // epoch seconds

    public init(id: String, title: String, messageCount: Int, modified: Double) {
        self.id = id
        self.title = title
        self.messageCount = messageCount
        self.modified = modified
    }
}

/// A pending tool-permission request, carried inside a `chatSnapshot`.
public struct PermissionWire: Codable, Sendable, Equatable {
    public var id: String
    public var tool: String
    public var title: String
    public var body: String
    /// Whether an "always allow" option is available (a third choice).
    public var canRemember: Bool

    public init(id: String, tool: String, title: String, body: String, canRemember: Bool = false) {
        self.id = id
        self.tool = tool
        self.title = title
        self.body = body
        self.canRemember = canRemember
    }
}

/// One message in a synced conversation, sent over the bridge.
public struct ChatWireMessage: Codable, Sendable, Equatable {
    public var role: String        // "user" | "assistant"
    public var text: String
    public var tools: [String]
    public var streaming: Bool
    public var isError: Bool

    public init(role: String, text: String, tools: [String] = [], streaming: Bool = false, isError: Bool = false) {
        self.role = role
        self.text = text
        self.tools = tools
        self.streaming = streaming
        self.isError = isError
    }
}

public struct BridgeMessage: Codable, Sendable, Equatable {
    public var type: BridgeMessageType

    /// Absolute path of the active workspace root.
    public var workspace: String?
    /// Absolute path of the active file.
    public var file: String?
    /// Language identifier of the active file (e.g. `swift`, `typescript`).
    public var language: String?
    /// Full document text or command payload text.
    public var text: String?
    /// Currently selected text in the editor.
    public var selection: String?
    /// Shell command to run in the integrated terminal (`runTerminalCommand`).
    public var command: String?
    /// File contents for `createFile`.
    public var content: String?
    /// 1-based line, used by `openFile` to reveal a location.
    public var line: Int?
    /// 1-based column, used by `openFile` to reveal a location.
    public var column: Int?
    /// Correlates a command with its `ack`/`error` reply.
    public var requestId: String?
    /// Full conversation snapshot for `chatSnapshot`.
    public var chat: [ChatWireMessage]?
    /// A short status line (e.g. "Responding…") accompanying a snapshot.
    public var status: String?
    /// A pending permission request in a `chatSnapshot` (nil = none).
    public var permission: PermissionWire?
    /// The request id for a `permissionResponse`.
    public var permissionId: String?
    /// The allow/deny decision for a `permissionResponse`.
    public var allow: Bool?
    /// "Always allow" (persist the SDK's suggested rules) for a `permissionResponse`.
    public var remember: Bool?
    /// Available projects, for a `projectList`.
    public var projects: [ProjectWire]?
    /// Past conversations, for a `sessionList`.
    public var sessions: [SessionWire]?
    /// The project to open (`openProject`) or whose sessions to list (`listSessions`).
    public var projectId: String?
    /// The conversation id to resume (`resumeSession`).
    public var sessionRef: String?
    /// The active project's display name, carried in `chatSnapshot`/`sessionList`.
    public var projectName: String?
    /// Auto-approve toggle: set by `setAutoApprove`, echoed in `chatSnapshot`.
    public var autoApprove: Bool?
    /// Whether the terminal is allowed (Settings), echoed in `chatSnapshot`.
    public var terminalEnabled: Bool?
    /// Terminal session id for `term*` messages.
    public var termId: String?
    /// Base64 payload for `termInput` / `termData`.
    public var data: String?
    /// Terminal size for `termOpen` / `termResize`.
    public var cols: Int?
    public var rows: Int?
    /// Directory entries for `dirList`.
    public var entries: [FileEntryWire]?
    /// Whether a `fileContent` payload was truncated (too large).
    public var truncated: Bool?
    /// Running session cost in USD, carried in `chatSnapshot` (dashboard).
    public var costUSD: Double?
    /// Open terminals for `termList`.
    public var terminals: [TerminalWire]?
    /// A terminal tab colour (`termRename`, hex like "#3fb950" or "").
    public var color: String?
    /// Whether a `termData` payload is a full scrollback replay (reset the view first).
    public var reset: Bool?

    public init(
        type: BridgeMessageType,
        workspace: String? = nil,
        file: String? = nil,
        language: String? = nil,
        text: String? = nil,
        selection: String? = nil,
        command: String? = nil,
        content: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        requestId: String? = nil,
        chat: [ChatWireMessage]? = nil,
        status: String? = nil,
        permission: PermissionWire? = nil,
        permissionId: String? = nil,
        allow: Bool? = nil,
        remember: Bool? = nil,
        projects: [ProjectWire]? = nil,
        sessions: [SessionWire]? = nil,
        projectId: String? = nil,
        sessionRef: String? = nil,
        projectName: String? = nil,
        autoApprove: Bool? = nil,
        terminalEnabled: Bool? = nil,
        termId: String? = nil,
        data: String? = nil,
        cols: Int? = nil,
        rows: Int? = nil,
        entries: [FileEntryWire]? = nil,
        truncated: Bool? = nil,
        costUSD: Double? = nil,
        terminals: [TerminalWire]? = nil,
        color: String? = nil,
        reset: Bool? = nil
    ) {
        self.type = type
        self.workspace = workspace
        self.file = file
        self.language = language
        self.text = text
        self.selection = selection
        self.command = command
        self.content = content
        self.line = line
        self.column = column
        self.requestId = requestId
        self.chat = chat
        self.status = status
        self.permission = permission
        self.permissionId = permissionId
        self.allow = allow
        self.remember = remember
        self.projects = projects
        self.sessions = sessions
        self.projectId = projectId
        self.sessionRef = sessionRef
        self.projectName = projectName
        self.autoApprove = autoApprove
        self.terminalEnabled = terminalEnabled
        self.termId = termId
        self.data = data
        self.cols = cols
        self.rows = rows
        self.entries = entries
        self.truncated = truncated
        self.costUSD = costUSD
        self.terminals = terminals
        self.color = color
        self.reset = reset
    }
}

public extension BridgeMessage {
    /// Encode to compact JSON.
    func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    func jsonString() throws -> String {
        String(decoding: try jsonData(), as: UTF8.self)
    }

    /// Decode from JSON received on the socket.
    static func decode(from data: Data) throws -> BridgeMessage {
        try JSONDecoder().decode(BridgeMessage.self, from: data)
    }

    static func decode(from string: String) throws -> BridgeMessage {
        try decode(from: Data(string.utf8))
    }
}
