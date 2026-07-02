import XCTest
@testable import DevDockCore

/// Reads the real `~/.claude/projects/` on this machine. Skipped by default.
///   DEVDOCK_LIVE_CLAUDE=1 swift test --filter ClaudeHistoryStoreLiveTests
final class ClaudeHistoryStoreLiveTests: XCTestCase {

    func testReadsRealProjectsAndSessions() throws {
        guard ProcessInfo.processInfo.environment["DEVDOCK_LIVE_CLAUDE"] == "1" else {
            throw XCTSkip("Set DEVDOCK_LIVE_CLAUDE=1 to read the real ~/.claude/projects")
        }
        let store = ClaudeHistoryStore()
        let projects = store.projects()
        XCTAssertFalse(projects.isEmpty, "expected at least one real project")

        // Every project should resolve to an absolute path and have sessions.
        for project in projects {
            XCTAssertTrue(project.path.hasPrefix("/"), "path should be absolute: \(project.path)")
            XCTAssertGreaterThan(project.sessionCount, 0)
        }

        // The newest project's sessions should parse with titles.
        let sessions = store.sessions(forProjectID: projects[0].id)
        XCTAssertFalse(sessions.isEmpty)
        XCTAssertFalse(sessions[0].title.isEmpty)
        print("LIVE: \(projects.count) projects; newest '\(projects[0].name)' → \(sessions.count) sessions; latest title: \(sessions.first?.title ?? "-")")
    }
}
