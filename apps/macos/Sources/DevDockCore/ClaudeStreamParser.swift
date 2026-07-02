import Foundation

/// Decodes the newline-delimited JSON emitted by
/// `claude -p --output-format stream-json --verbose`.
///
/// One input line can yield zero or more ``ClaudeStreamEvent`` values (an
/// assistant message may contain both text and tool-use blocks). Unknown or
/// noise lines (`rate_limit_event`, `user`, …) simply produce no events.
public enum ClaudeStreamParser {

    public static func parse(line: String) -> [ClaudeStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return []
        }

        switch type {
        case "system":
            guard (object["subtype"] as? String) == "init" else { return [] }
            return [.sessionStarted(
                sessionId: object["session_id"] as? String ?? "",
                model: object["model"] as? String ?? "",
                cwd: object["cwd"] as? String ?? "",
                agents: object["agents"] as? [String] ?? []
            )]

        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            var events: [ClaudeStreamEvent] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        events.append(.assistantText(text))
                    }
                case "tool_use":
                    // Full input is present here → format a rich "Read foo.swift (lines …)".
                    events.append(.toolUse(name: describeTool(
                        name: block["name"] as? String ?? "tool",
                        input: block["input"] as? [String: Any] ?? [:]
                    )))
                default:
                    break
                }
            }
            return events

        case "result":
            return [.result(
                text: object["result"] as? String ?? "",
                isError: (object["is_error"] as? Bool) ?? false,
                costUSD: object["total_cost_usd"] as? Double
            )]

        case "stream_event":
            return partialEvents(from: object)

        default:
            return []
        }
    }

    /// Handle `--include-partial-messages` events: token deltas, tool starts, and
    /// text-block boundaries.
    private static func partialEvents(from object: [String: Any]) -> [ClaudeStreamEvent] {
        guard let event = object["event"] as? [String: Any] else { return [] }
        switch event["type"] as? String {
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String, !text.isEmpty { return [.assistantDelta(text)] }
            case "thinking_delta":
                if let text = delta["thinking"] as? String, !text.isEmpty { return [.thinkingDelta(text)] }
            default:
                break
            }
            return []
        case "content_block_start":
            // Only text blocks matter here; tool_use is emitted (with full input)
            // from the complete assistant message so we can describe it richly.
            if let block = event["content_block"] as? [String: Any],
               (block["type"] as? String) == "text" {
                return [.assistantBlockStart]
            }
            return []
        default:
            return []
        }
    }

    /// Formats a tool call like Claude Code's activity log:
    /// "Read AIView.swift (lines 311-328)", "Edit AIView.swift", "Bash npm run dev".
    static func describeTool(name: String, input: [String: Any]) -> String {
        func base(_ path: String?) -> String {
            guard let path, !path.isEmpty else { return "" }
            return (path as NSString).lastPathComponent
        }
        func joined(_ detail: String) -> String {
            detail.isEmpty ? name : "\(name) \(detail)"
        }

        switch name {
        case "Read":
            var detail = base(input["file_path"] as? String)
            if let offset = input["offset"] as? Int {
                if let limit = input["limit"] as? Int {
                    detail += " (lines \(offset)-\(offset + limit - 1))"
                } else {
                    detail += " (from line \(offset))"
                }
            }
            return joined(detail)
        case "Edit", "Write", "NotebookEdit":
            return joined(base((input["file_path"] as? String) ?? (input["notebook_path"] as? String)))
        case "Bash":
            let command = (input["command"] as? String ?? "")
                .split(separator: "\n").first.map(String.init) ?? ""
            return joined(String(command.prefix(70)))
        case "Grep":
            return joined(String((input["pattern"] as? String ?? "").prefix(48)))
        case "Glob":
            return joined(String((input["pattern"] as? String ?? "").prefix(48)))
        case "Task":
            return joined((input["description"] as? String) ?? (input["subagent_type"] as? String) ?? "")
        case "WebFetch":
            return joined(String((input["url"] as? String ?? "").prefix(48)))
        case "WebSearch":
            return joined(String((input["query"] as? String ?? "").prefix(48)))
        default:
            return name
        }
    }
}
