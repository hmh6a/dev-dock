import XCTest
@testable import DevDockCore

/// End-to-end check that our built argument vector is actually accepted by the
/// real `claude` CLI and that its `stream-json` output parses into a result.
///
/// Skipped by default (it spawns `claude` and costs a little). Run with:
///   DEVDOCK_LIVE_CLAUDE=1 swift test --filter ClaudeLiveIntegrationTests
final class ClaudeLiveIntegrationTests: XCTestCase {

    func testLiveClaudeStreamParsesEndToEnd() throws {
        guard ProcessInfo.processInfo.environment["DEVDOCK_LIVE_CLAUDE"] == "1" else {
            throw XCTSkip("Set DEVDOCK_LIVE_CLAUDE=1 to run the live claude integration test")
        }

        let claudePath = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let claude = try XCTUnwrap(claudePath, "claude CLI not found")

        let config = ClaudeRunConfig(
            prompt: "reply with exactly the single word: pong",
            model: "haiku",
            effort: "low",
            permissionMode: AccessMode.safe.permissionMode,
            allowedTools: AccessMode.safe.allowedTools,
            sessionId: UUID().uuidString.lowercased(),
            resume: false
        )
        let arguments = ClaudeCommandBuilder.arguments(config) + ["--max-turns", "1"]

        let result = try CommandRunner().run(claude, arguments)

        var sawSessionStart = false
        var resultText = ""
        var sawResult = false
        var deltaCount = 0
        for line in result.stdout.split(separator: "\n") {
            for event in ClaudeStreamParser.parse(line: String(line)) {
                switch event {
                case .sessionStarted: sawSessionStart = true
                case .assistantDelta: deltaCount += 1
                case let .result(text, _, _): sawResult = true; resultText = text
                default: break
                }
            }
        }

        XCTAssertTrue(sawSessionStart, "expected a system/init event")
        XCTAssertTrue(sawResult, "expected a result event. stderr: \(result.stderr)")
        XCTAssertFalse(resultText.isEmpty, "expected non-empty result text")
        XCTAssertGreaterThan(deltaCount, 0, "expected token deltas from --include-partial-messages")
    }
}
