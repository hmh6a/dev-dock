import XCTest
@testable import DevDockCore

final class ClaudeTranscriptParserTests: XCTestCase {

    /// Mirrors the real `.jsonl` shape: an ai-title, a user message whose first
    /// block is `<ide_opened_file>` noise, and an assistant reply with a tool_use.
    private let lines: [String] = [
        #"{"type":"ai-title","aiTitle":"Work on dev-dock project","sessionId":"s1"}"#,
        #"{"type":"user","cwd":"/Users/me/dev/dev-dock","gitBranch":"main","timestamp":"2026-07-01T19:09:41.296Z","uuid":"u1","message":{"role":"user","content":[{"type":"text","text":"<ide_opened_file>opened dev-dock.md</ide_opened_file>"},{"type":"text","text":"do this project"}]}}"#,
        #"{"type":"assistant","timestamp":"2026-07-01T19:10:00.000Z","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"On it."},{"type":"tool_use","name":"Read","input":{}}]}}"#,
    ]

    func testSummaryPrefersAiTitle() {
        let summary = ClaudeTranscriptParser.summarize(lines: lines)
        XCTAssertEqual(summary.title, "Work on dev-dock project")
        XCTAssertEqual(summary.cwd, "/Users/me/dev/dev-dock")
        XCTAssertEqual(summary.gitBranch, "main")
        XCTAssertEqual(summary.messageCount, 2)
        XCTAssertNotNil(summary.firstTimestamp)
        XCTAssertNotNil(summary.lastTimestamp)
    }

    func testTitleFallsBackToFirstMeaningfulUserText() {
        let noTitle = Array(lines.dropFirst()) // drop ai-title
        let summary = ClaudeTranscriptParser.summarize(lines: noTitle)
        // Skips the <ide_opened_file> block, uses the real prompt.
        XCTAssertEqual(summary.title, "do this project")
    }

    func testMessagesParseUserAndAssistantWithTools() {
        let messages = ClaudeTranscriptParser.messages(lines: lines)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].text, "do this project")   // noise stripped
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[1].text, "On it.")
        XCTAssertEqual(messages[1].tools, ["Read"])
    }

    func testSkipsSidechainEntries() {
        let withSidechain = lines + [
            #"{"type":"assistant","isSidechain":true,"uuid":"sc1","message":{"role":"assistant","content":[{"type":"text","text":"subagent noise"}]}}"#
        ]
        let messages = ClaudeTranscriptParser.messages(lines: withSidechain)
        XCTAssertFalse(messages.contains { $0.text.contains("subagent noise") })
    }

    func testHandlesStringContent() {
        let line = #"{"type":"user","uuid":"u","message":{"role":"user","content":"plain string prompt"}}"#
        let messages = ClaudeTranscriptParser.messages(lines: [line])
        XCTAssertEqual(messages.first?.text, "plain string prompt")
    }

    func testEmptyInput() {
        XCTAssertEqual(ClaudeTranscriptParser.summarize(lines: []).messageCount, 0)
        XCTAssertTrue(ClaudeTranscriptParser.messages(lines: []).isEmpty)
    }
}
