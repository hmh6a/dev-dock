import Foundation

/// Discovers Claude Code agents defined as markdown files with YAML frontmatter
/// in `~/.claude/agents` and `<workspace>/.claude/agents`.
///
/// The list of *available* agents also arrives dynamically in the `system/init`
/// stream event; this catalog is what we show *before* the first message and is
/// the only source of human-readable descriptions.
public enum AgentCatalog {

    /// Parse the `name` and `description` from an agent file's YAML frontmatter.
    /// Returns `nil` if there's no usable `name`.
    public static func parseFrontmatter(_ contents: String) -> ClaudeAgent? {
        let lines = contents.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }

        var name: String?
        var description: String?
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if let value = value(of: "name", in: trimmed) { name = value }
            if let value = value(of: "description", in: trimmed) { description = value }
        }

        guard let name, !name.isEmpty else { return nil }
        return ClaudeAgent(name: name, description: description)
    }

    /// Read agent definitions from the given directories, de-duplicated by name.
    public static func discover(in directories: [URL]) -> [ClaudeAgent] {
        let fileManager = FileManager.default
        var seen: Set<String> = []
        var agents: [ClaudeAgent] = []

        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }

            for entry in entries where entry.pathExtension == "md" {
                guard let contents = try? String(contentsOf: entry, encoding: .utf8),
                      let agent = parseFrontmatter(contents),
                      seen.insert(agent.name).inserted else { continue }
                agents.append(agent)
            }
        }

        return agents.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Standard agent directories: user-global then project-local.
    public static func defaultDirectories(workspace: URL?) -> [URL] {
        var directories: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        directories.append(home.appendingPathComponent(".claude/agents"))
        if let workspace {
            directories.append(workspace.appendingPathComponent(".claude/agents"))
        }
        return directories
    }

    private static func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix("\(key):") else { return nil }
        let raw = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}
