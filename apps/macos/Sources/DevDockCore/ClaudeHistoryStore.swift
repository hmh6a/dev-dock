import Foundation

/// Reads projects and past conversations from `~/.claude/projects/`.
///
/// Filesystem access lives here; the actual transcript parsing is delegated to
/// the pure ``ClaudeTranscriptParser`` so the logic stays testable.
public struct ClaudeHistoryStore: Sendable {
    public let projectsRoot: URL

    /// Cap how many sessions we read per project to keep listing snappy.
    public var maxSessionsPerProject = 60

    public init(root: URL? = nil) {
        self.projectsRoot = root
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// All projects, most-recently-used first.
    public func projects() -> [ClaudeProject] {
        let fileManager = FileManager.default
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else { return [] }

        var projects: [ClaudeProject] = []
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let sessionFiles = jsonlFiles(in: dir)
            guard !sessionFiles.isEmpty else { continue }

            // Real path + branch come from the newest transcript's first lines.
            let newest = sessionFiles[0]
            let head = readLines(newest, max: 5)
            let summary = ClaudeTranscriptParser.summarize(lines: head)
            let path = summary.cwd ?? decodePath(from: dir.lastPathComponent)
            let modified = modificationDate(of: newest) ?? Date(timeIntervalSince1970: 0)

            projects.append(ClaudeProject(
                id: dir.lastPathComponent,
                path: path,
                gitBranch: summary.gitBranch,
                sessionCount: sessionFiles.count,
                lastModified: modified
            ))
        }
        return projects.sorted { $0.lastModified > $1.lastModified }
    }

    /// Sessions within a project directory, most recent first.
    public func sessions(forProjectID encodedID: String) -> [ClaudeSessionSummary] {
        let dir = projectsRoot.appendingPathComponent(encodedID)
        let files = jsonlFiles(in: dir).prefix(maxSessionsPerProject)

        var sessions: [ClaudeSessionSummary] = []
        for file in files {
            let lines = readLines(file)
            let summary = ClaudeTranscriptParser.summarize(lines: lines)
            guard summary.messageCount > 0 else { continue }
            let sessionID = file.deletingPathExtension().lastPathComponent
            sessions.append(ClaudeSessionSummary(
                id: sessionID,
                projectPath: summary.cwd ?? decodePath(from: encodedID),
                title: summary.title ?? "Untitled conversation",
                messageCount: summary.messageCount,
                lastModified: summary.lastTimestamp ?? modificationDate(of: file) ?? Date(timeIntervalSince1970: 0),
                gitBranch: summary.gitBranch
            ))
        }
        return sessions.sorted { $0.lastModified > $1.lastModified }
    }

    /// Parsed messages of one conversation, for replaying it in the UI.
    public func transcript(sessionID: String, projectID encodedID: String) -> [TranscriptMessage] {
        return ClaudeTranscriptParser.messages(lines: readLines(sessionFileURL(sessionID: sessionID, projectID: encodedID)))
    }

    /// Absolute path to a session's transcript file (used for live following).
    public func sessionFileURL(sessionID: String, projectID encodedID: String) -> URL {
        projectsRoot
            .appendingPathComponent(encodedID)
            .appendingPathComponent("\(sessionID).jsonl")
    }

    // MARK: - Filesystem helpers

    private func jsonlFiles(in directory: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "jsonl" }
            .sorted { (modificationDate(of: $0) ?? .distantPast) > (modificationDate(of: $1) ?? .distantPast) }
    }

    private func readLines(_ url: URL, max: Int? = nil) -> [String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if let max { return Array(lines.prefix(max)) }
        return lines
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Best-effort fallback when a transcript has no `cwd`: turn the encoded
    /// directory name back into a path. Lossy (dashes are ambiguous) so only used
    /// as a last resort.
    private func decodePath(from encoded: String) -> String {
        encoded.hasPrefix("-") ? encoded.replacingOccurrences(of: "-", with: "/") : encoded
    }
}
