import Foundation

/// A selectable Claude model. `id` is what we pass to `claude --model` — an alias
/// (`opus`, `sonnet`, `haiku`) that always resolves to the latest model in that
/// tier.
public struct ClaudeModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    public static let opus = ClaudeModel(id: "opus", displayName: "Opus 4.8")
    public static let sonnet = ClaudeModel(id: "sonnet", displayName: "Sonnet 5")
    public static let haiku = ClaudeModel(id: "haiku", displayName: "Haiku 4.5")

    public static let all: [ClaudeModel] = [.opus, .sonnet, .haiku]
    public static let `default`: ClaudeModel = .opus
}

/// Reasoning effort, mapped 1:1 to `claude --effort <level>`.
public enum ReasoningEffort: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high, xhigh, max

    public var id: String { rawValue }
    public var cliValue: String { rawValue }

    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "X-High"
        case .max: return "Max"
        }
    }

    public static let `default`: ReasoningEffort = .high
}

/// A Claude Code agent the user can route the session to (`claude --agent <name>`).
/// The empty-named ``default`` runs the standard main agent (no `--agent` flag).
public struct ClaudeAgent: Identifiable, Hashable, Sendable {
    public let name: String
    public let description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }

    public var id: String { name.isEmpty ? "__default__" : name }
    public var isDefault: Bool { name.isEmpty }
    public var displayName: String { isDefault ? "Default" : name }

    public static let `default` = ClaudeAgent(name: "", description: "Standard Claude Code agent")
}

/// The session's approval policy. With the Agent SDK's `canUseTool` callback,
/// the app decides per request: auto-deny (safe), prompt the user (ask), or
/// auto-allow (full).
public enum AccessMode: String, CaseIterable, Identifiable, Sendable {
    /// Read-only: reads/searches run; edits and commands are auto-denied.
    case safe
    /// Ask: prompt for approval before editing files or running commands.
    case ask
    /// Full auto: approve everything without asking.
    case full

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .safe: return "Read-only"
        case .ask: return "Ask"
        case .full: return "Full auto"
        }
    }

    public var detail: String {
        switch self {
        case .safe: return "Reads & searches only — edits/commands denied"
        case .ask: return "Ask me before edits or running commands"
        case .full: return "Approve everything automatically"
        }
    }

    /// Value for the runner's `permissionMode`. `full` bypasses the callback
    /// entirely; the others route through `canUseTool` for our policy.
    public var permissionMode: String {
        self == .full ? "bypassPermissions" : "default"
    }

    /// Read-only tools pre-allowed in safe mode. Empty otherwise.
    public var allowedTools: [String] {
        switch self {
        case .safe: return ["Read", "Grep", "Glob", "WebFetch", "WebSearch", "NotebookRead"]
        case .ask, .full: return []
        }
    }
}

/// Events decoded from a line of `claude --output-format stream-json`.
public enum ClaudeStreamEvent: Equatable, Sendable {
    /// The `system/init` event: carries the session id, resolved model, cwd, and
    /// the list of agents available for `--agent`.
    case sessionStarted(sessionId: String, model: String, cwd: String, agents: [String])
    /// A complete assistant prose block (non-partial mode / end of turn).
    case assistantText(String)
    /// A partial token/chunk of assistant prose (with `--include-partial-messages`).
    case assistantDelta(String)
    /// A partial chunk of the model's private thinking (counts toward tokens only).
    case thinkingDelta(String)
    /// A new text block began — used to separate paragraphs when streaming deltas.
    case assistantBlockStart
    /// The assistant invoked a tool (shown as activity in the UI).
    case toolUse(name: String)
    /// The final result of a turn.
    case result(text: String, isError: Bool, costUSD: Double?)
}
