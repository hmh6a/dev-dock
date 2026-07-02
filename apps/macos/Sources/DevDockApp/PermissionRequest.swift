import Foundation

/// An interactive tool-permission request surfaced by the Agent SDK's
/// `canUseTool` callback (relayed through the runner). The user answers Yes / No
/// / "do this instead".
struct PermissionRequest: Identifiable, Equatable {
    let id: String
    let tool: String
    let title: String
    let body: String
    /// Whether the SDK offered "always allow" suggestions — i.e. a third option
    /// ("Yes, and don't ask again") beyond plain Allow / Deny.
    var canRemember: Bool = false

    /// Build a human-friendly request from the runner's `{tool, input}`. Uses the
    /// SDK-provided `title`/`description` when present (clearer than our guess).
    static func make(
        id: String,
        tool: String,
        input: [String: Any],
        sdkTitle: String? = nil,
        sdkDescription: String? = nil,
        canRemember: Bool = false
    ) -> PermissionRequest {
        let title: String
        let body: String
        switch tool {
        case "Bash":
            title = "Allow this command?"
            body = (input["command"] as? String) ?? ""
        case "Write":
            title = "Allow writing \(base(input["file_path"]))?"
            body = String((input["content"] as? String ?? "").prefix(400))
        case "Edit", "NotebookEdit":
            title = "Allow editing \(base(input["file_path"] ?? input["notebook_path"]))?"
            body = shortInput(input, keys: ["old_string", "new_string"])
        default:
            title = "Allow \(tool)?"
            body = shortInput(input, keys: [])
        }
        let finalTitle = (sdkTitle?.isEmpty == false) ? sdkTitle! : title
        let finalBody = (sdkDescription?.isEmpty == false) ? (sdkDescription! + (body.isEmpty ? "" : "\n\n" + body)) : body
        return PermissionRequest(id: id, tool: tool, title: finalTitle, body: finalBody, canRemember: canRemember)
    }

    private static func base(_ value: Any?) -> String {
        guard let path = value as? String, !path.isEmpty else { return "file" }
        return (path as NSString).lastPathComponent
    }

    private static func shortInput(_ input: [String: Any], keys: [String]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: input),
           let string = String(data: data, encoding: .utf8) {
            return String(string.prefix(400))
        }
        return ""
    }
}
