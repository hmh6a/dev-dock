import Foundation

/// Everything needed to run one `claude` turn. A stable ``sessionId`` is created
/// once per conversation; the first turn passes it via `--session-id` and every
/// later turn resumes it, so history is preserved across process invocations.
public struct ClaudeRunConfig: Sendable, Equatable {
    public var prompt: String
    public var model: String
    public var effort: String
    public var agent: String?
    public var permissionMode: String
    public var allowedTools: [String]
    public var sessionId: String
    public var resume: Bool

    public init(
        prompt: String,
        model: String,
        effort: String,
        agent: String? = nil,
        permissionMode: String,
        allowedTools: [String] = [],
        sessionId: String,
        resume: Bool
    ) {
        self.prompt = prompt
        self.model = model
        self.effort = effort
        self.agent = agent
        self.permissionMode = permissionMode
        self.allowedTools = allowedTools
        self.sessionId = sessionId
        self.resume = resume
    }
}

/// Builds the `claude` argument vector from a ``ClaudeRunConfig``. Pure and
/// order-stable so it can be asserted against in tests.
public enum ClaudeCommandBuilder {

    public static func arguments(_ config: ClaudeRunConfig) -> [String] {
        var arguments: [String] = [
            "-p", config.prompt,
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--model", config.model,
            "--effort", config.effort,
            "--permission-mode", config.permissionMode,
        ]

        if let agent = config.agent, !agent.isEmpty {
            arguments += ["--agent", agent]
        }

        if !config.allowedTools.isEmpty {
            arguments += ["--allowedTools"] + config.allowedTools
        }

        arguments += config.resume
            ? ["--resume", config.sessionId]
            : ["--session-id", config.sessionId]

        return arguments
    }
}
