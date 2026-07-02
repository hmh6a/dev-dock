import Foundation

/// A project Claude Code has been used in — one directory under
/// `~/.claude/projects/`. The real filesystem `path` comes from the `cwd` stored
/// inside the transcripts (the directory name itself is a lossy encoding).
public struct ClaudeProject: Identifiable, Hashable, Sendable {
    public let id: String          // encoded directory name
    public let path: String        // real cwd
    public let gitBranch: String?
    public let sessionCount: Int
    public let lastModified: Date

    public init(id: String, path: String, gitBranch: String?, sessionCount: Int, lastModified: Date) {
        self.id = id
        self.path = path
        self.gitBranch = gitBranch
        self.sessionCount = sessionCount
        self.lastModified = lastModified
    }

    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// A past conversation within a project — one `<session-id>.jsonl` file.
public struct ClaudeSessionSummary: Identifiable, Hashable, Sendable {
    public let id: String          // session uuid (the file name)
    public let projectPath: String
    public let title: String
    public let messageCount: Int
    public let lastModified: Date
    public let gitBranch: String?

    public init(id: String, projectPath: String, title: String, messageCount: Int, lastModified: Date, gitBranch: String?) {
        self.id = id
        self.projectPath = projectPath
        self.title = title
        self.messageCount = messageCount
        self.lastModified = lastModified
        self.gitBranch = gitBranch
    }
}

/// A single message parsed from a transcript, for replaying history in the chat.
public struct TranscriptMessage: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public let id: String
    public let role: Role
    public let text: String
    public let tools: [String]

    public init(id: String, role: Role, text: String, tools: [String]) {
        self.id = id
        self.role = role
        self.text = text
        self.tools = tools
    }
}

/// Pure parsing of Claude Code `.jsonl` transcripts. No filesystem access, so it
/// can be tested against literal sample lines.
public enum ClaudeTranscriptParser {

    public struct Summary: Sendable {
        public let title: String?
        public let cwd: String?
        public let gitBranch: String?
        public let firstTimestamp: Date?
        public let lastTimestamp: Date?
        public let messageCount: Int
    }

    /// Extract a one-line summary (title, cwd, branch, timing, count) from a
    /// transcript's lines.
    public static func summarize(lines: [String]) -> Summary {
        var aiTitle: String?
        var firstUserText: String?
        var cwd: String?
        var gitBranch: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var messageCount = 0

        for line in lines {
            guard let object = jsonObject(line) else { continue }
            let type = object["type"] as? String

            if cwd == nil, let c = object["cwd"] as? String, !c.isEmpty { cwd = c }
            if gitBranch == nil, let b = object["gitBranch"] as? String, !b.isEmpty { gitBranch = b }
            if let ts = date(object["timestamp"]) {
                if firstTimestamp == nil { firstTimestamp = ts }
                lastTimestamp = ts
            }

            switch type {
            case "ai-title":
                if let t = object["aiTitle"] as? String, !t.isEmpty { aiTitle = t }
            case "user":
                messageCount += 1
                if firstUserText == nil, (object["isSidechain"] as? Bool) != true,
                   let text = cleanText(from: object), !text.isEmpty {
                    firstUserText = text
                }
            case "assistant":
                messageCount += 1
            default:
                break
            }
        }

        let title = aiTitle ?? firstUserText.map { String($0.prefix(80)) }
        return Summary(
            title: title,
            cwd: cwd,
            gitBranch: gitBranch,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            messageCount: messageCount
        )
    }

    /// Parse user/assistant messages for replaying a conversation in the UI.
    /// Sidechain (subagent) entries are skipped to keep the main thread readable.
    public static func messages(lines: [String]) -> [TranscriptMessage] {
        var result: [TranscriptMessage] = []
        for line in lines {
            guard let object = jsonObject(line),
                  (object["isSidechain"] as? Bool) != true else { continue }
            let uuid = object["uuid"] as? String ?? UUID().uuidString

            switch object["type"] as? String {
            case "user":
                if let text = cleanText(from: object), !text.isEmpty {
                    result.append(TranscriptMessage(id: uuid, role: .user, text: text, tools: []))
                }
            case "assistant":
                let (text, tools) = assistantContent(from: object)
                if !text.isEmpty || !tools.isEmpty {
                    result.append(TranscriptMessage(id: uuid, role: .assistant, text: text, tools: tools))
                }
            default:
                break
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func jsonObject(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// User content is a string or an array of blocks. We keep visible prose and
    /// drop editor/system noise wrapped in `<…>` tags or tool results.
    private static func cleanText(from object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any] else { return nil }
        let content = message["content"]

        if let string = content as? String {
            return meaningful(string) ? string.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        guard let blocks = content as? [[String: Any]] else { return nil }

        var parts: [String] = []
        for block in blocks where (block["type"] as? String) == "text" {
            if let text = block["text"] as? String, meaningful(text) {
                parts.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private static func assistantContent(from object: [String: Any]) -> (text: String, tools: [String]) {
        guard let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return ("", []) }
        var parts: [String] = []
        var tools: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { parts.append(text) }
            case "tool_use":
                let described = ClaudeStreamParser.describeTool(
                    name: block["name"] as? String ?? "tool",
                    input: block["input"] as? [String: Any] ?? [:]
                )
                if !tools.contains(described) { tools.append(described) }
            default:
                break
            }
        }
        return (parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), tools)
    }

    private static func meaningful(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix("<") { return false }              // <ide_opened_file>, <command-name>, <system-reminder>…
        if trimmed.hasPrefix("Caveat:") { return false }
        return true
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return isoFractional.date(from: string) ?? iso.date(from: string)
    }
}
