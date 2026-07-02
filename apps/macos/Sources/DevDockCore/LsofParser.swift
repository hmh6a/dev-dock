import Foundation

/// Parses the textual output of
/// `lsof -iTCP -sTCP:LISTEN -n -P`
/// into a list of ``PortEntry`` values.
///
/// The parser is deliberately tolerant: `lsof` columns are whitespace separated
/// but the `COMMAND` field can contain spaces and the `NAME` field varies between
/// IPv4 and IPv6. Rather than relying on fixed column indexes we anchor on two
/// reliable landmarks — the first all-numeric token (the PID) and the address
/// token that precedes `(LISTEN)`.
public enum LsofParser {

    /// Parse raw `lsof` output into de-duplicated, port-sorted entries.
    public static func parse(_ output: String) -> [PortEntry] {
        var results: [PortEntry] = []
        var seen: Set<String> = []

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("COMMAND") else { continue }

            let tokens = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard tokens.count >= 3 else { continue }

            // PID: the first purely-numeric token. Everything before it is the command.
            guard let pidIndex = tokens.firstIndex(where: isAllDigits),
                  pidIndex > 0,
                  let pid = Int(tokens[pidIndex]) else { continue }
            let process = tokens[0..<pidIndex].joined(separator: " ")

            guard let addressToken = addressToken(in: tokens),
                  let (address, port) = splitAddressPort(addressToken) else { continue }

            let entry = PortEntry(pid: pid, process: process, address: address, port: port)
            if seen.insert(entry.id).inserted {
                results.append(entry)
            }
        }

        return results.sorted { lhs, rhs in
            lhs.port == rhs.port ? lhs.process < rhs.process : lhs.port < rhs.port
        }
    }

    private static func isAllDigits(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy(\.isNumber)
    }

    /// The `NAME` token holding `address:port`. It is the token immediately before
    /// `(LISTEN)`; if that marker is missing we fall back to the last token that
    /// looks like an address (contains a colon).
    private static func addressToken(in tokens: [String]) -> String? {
        if let listenIndex = tokens.firstIndex(where: { $0.uppercased().contains("LISTEN") }),
           listenIndex > 0 {
            return tokens[listenIndex - 1]
        }
        return tokens.last(where: { $0.contains(":") })
    }

    /// Split `127.0.0.1:3000`, `*:8080`, or `[::1]:5000` into address + port.
    private static func splitAddressPort(_ token: String) -> (address: String, port: Int)? {
        guard let colonIndex = token.lastIndex(of: ":") else { return nil }
        let address = String(token[token.startIndex..<colonIndex])
        let portString = String(token[token.index(after: colonIndex)...])
        guard let port = Int(portString), port > 0, port <= 65_535 else { return nil }
        return (address.isEmpty ? "*" : address, port)
    }
}
