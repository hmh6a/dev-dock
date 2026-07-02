import Foundation

/// A single message in the AI conversation. Assistant messages are mutated in
/// place as the stream arrives (text appended, tool activity collected).
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }

    let id = UUID()
    let role: Role
    var text: String
    var tools: [String] = []
    var isStreaming: Bool = false
    var isError: Bool = false
    /// Local image files attached to a user message.
    var attachments: [URL] = []
}
