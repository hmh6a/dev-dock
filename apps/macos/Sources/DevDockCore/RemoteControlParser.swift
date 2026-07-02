import Foundation

/// Signals extracted from a line of `claude remote-control` output.
public enum RemoteControlSignal: Equatable, Sendable {
    /// The session URL to open on another device (also encodes the QR payload).
    case url(String)
    /// The server is connecting.
    case connecting
    /// The server is ready and accepting remote connections.
    case ready
    /// Any other human-readable status line.
    case status(String)
}

/// Parses `claude remote-control` terminal output (server mode) into signals.
/// Strips ANSI escapes first, so it works on raw piped output. Pure/testable.
public enum RemoteControlParser {

    public static func parse(line: String) -> RemoteControlSignal? {
        let clean = stripANSI(line).trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }

        if let url = sessionURL(in: clean) {
            return .url(url)
        }
        if clean.localizedCaseInsensitiveContains("Ready") {
            return .ready
        }
        if clean.localizedCaseInsensitiveContains("Connecting") {
            return .connecting
        }
        // Skip the interactive prompt echo and generic help lines as noise.
        if clean.hasPrefix("Enable Remote Control?") { return nil }
        return .status(clean)
    }

    /// Extract a `https://claude.ai/code?…` session URL from a line, if present.
    public static func sessionURL(in text: String) -> String? {
        guard let range = text.range(of: "https://claude.ai/code") else { return nil }
        let tail = text[range.lowerBound...]
        let url = tail.prefix { !$0.isWhitespace }
        return String(url)
    }

    /// Remove ANSI/VT100 escape sequences.
    public static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        var pending: Character? = nil

        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let char = next() {
            if char == "\u{1B}" {
                // Consume "[ … <final letter>" of a CSI sequence.
                guard let bracket = next() else { break }
                if bracket == "[" {
                    while let c = next() {
                        if c.isLetter { break }
                    }
                } else {
                    pending = bracket
                }
            } else {
                result.append(char)
            }
        }
        return result
    }
}
