import XCTest
@testable import DevDockCore

final class ClaudeStreamParserTests: XCTestCase {

    func testParsesInitEvent() {
        let line = #"{"type":"system","subtype":"init","cwd":"/private/tmp","session_id":"abc-123","model":"claude-haiku-4-5-20251001","agents":["claude","Explore","Plan"]}"#
        let events = ClaudeStreamParser.parse(line: line)
        XCTAssertEqual(events, [
            .sessionStarted(
                sessionId: "abc-123",
                model: "claude-haiku-4-5-20251001",
                cwd: "/private/tmp",
                agents: ["claude", "Explore", "Plan"]
            )
        ])
    }

    func testParsesAssistantTextBlock() {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hello there friend."}]},"session_id":"abc"}"#
        XCTAssertEqual(ClaudeStreamParser.parse(line: line), [.assistantText("Hello there friend.")])
    }

    func testParsesAssistantWithTextAndToolUse() {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Let me look."},{"type":"tool_use","name":"Read","input":{}}]}}"#
        XCTAssertEqual(ClaudeStreamParser.parse(line: line), [
            .assistantText("Let me look."),
            .toolUse(name: "Read"),
        ])
    }

    func testParsesResultEvent() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","total_cost_usd":0.15,"session_id":"abc"}"#
        XCTAssertEqual(ClaudeStreamParser.parse(line: line), [
            .result(text: "Done.", isError: false, costUSD: 0.15)
        ])
    }

    func testIgnoresNoiseAndBlankLines() {
        XCTAssertTrue(ClaudeStreamParser.parse(line: "").isEmpty)
        XCTAssertTrue(ClaudeStreamParser.parse(line: "not json").isEmpty)
        XCTAssertTrue(ClaudeStreamParser.parse(line: #"{"type":"rate_limit_event"}"#).isEmpty)
    }
}

final class ClaudeCommandBuilderTests: XCTestCase {

    func testFirstTurnUsesSessionIdAndFlags() {
        let config = ClaudeRunConfig(
            prompt: "hi",
            model: "opus",
            effort: "high",
            permissionMode: "default",
            allowedTools: ["Read", "Grep"],
            sessionId: "sess-1",
            resume: false
        )
        let args = ClaudeCommandBuilder.arguments(config)
        XCTAssertEqual(Array(args.prefix(2)), ["-p", "hi"])
        XCTAssertTrue(args.contains("--output-format"))
        XCTAssertTrue(args.contains("stream-json"))
        XCTAssertEqual(neighbor(of: "--model", in: args), "opus")
        XCTAssertEqual(neighbor(of: "--effort", in: args), "high")
        XCTAssertEqual(neighbor(of: "--permission-mode", in: args), "default")
        XCTAssertEqual(neighbor(of: "--session-id", in: args), "sess-1")
        XCTAssertFalse(args.contains("--resume"))
        // allowedTools are passed variadically after the flag.
        let idx = args.firstIndex(of: "--allowedTools")!
        XCTAssertEqual(Array(args[(idx + 1)...(idx + 2)]), ["Read", "Grep"])
    }

    func testResumeTurnUsesResume() {
        let config = ClaudeRunConfig(
            prompt: "again",
            model: "sonnet",
            effort: "low",
            agent: "Explore",
            permissionMode: "bypassPermissions",
            sessionId: "sess-1",
            resume: true
        )
        let args = ClaudeCommandBuilder.arguments(config)
        XCTAssertEqual(neighbor(of: "--resume", in: args), "sess-1")
        XCTAssertFalse(args.contains("--session-id"))
        XCTAssertEqual(neighbor(of: "--agent", in: args), "Explore")
    }

    func testDefaultAgentOmitsAgentFlag() {
        let config = ClaudeRunConfig(
            prompt: "x", model: "opus", effort: "high",
            agent: "", permissionMode: "default", sessionId: "s", resume: false
        )
        XCTAssertFalse(ClaudeCommandBuilder.arguments(config).contains("--agent"))
    }

    private func neighbor(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

final class AgentCatalogTests: XCTestCase {

    func testParsesFrontmatter() {
        let file = """
        ---
        name: code-reviewer
        description: Reviews diffs for bugs.
        model: opus
        ---

        You are a reviewer.
        """
        let agent = AgentCatalog.parseFrontmatter(file)
        XCTAssertEqual(agent?.name, "code-reviewer")
        XCTAssertEqual(agent?.description, "Reviews diffs for bugs.")
    }

    func testRejectsFileWithoutFrontmatter() {
        XCTAssertNil(AgentCatalog.parseFrontmatter("# just a heading\nno frontmatter"))
    }

    func testRejectsFrontmatterWithoutName() {
        let file = "---\ndescription: no name here\n---\n"
        XCTAssertNil(AgentCatalog.parseFrontmatter(file))
    }
}

final class AccessModeTests: XCTestCase {
    func testSafeModeIsReadOnly() {
        XCTAssertEqual(AccessMode.safe.permissionMode, "default")
        XCTAssertFalse(AccessMode.safe.allowedTools.contains("Write"))
        XCTAssertTrue(AccessMode.safe.allowedTools.contains("Read"))
    }

    func testAskRoutesThroughCallback() {
        XCTAssertEqual(AccessMode.ask.permissionMode, "default")
        XCTAssertTrue(AccessMode.ask.allowedTools.isEmpty)
    }

    func testFullModeBypassesPermissions() {
        XCTAssertEqual(AccessMode.full.permissionMode, "bypassPermissions")
        XCTAssertTrue(AccessMode.full.allowedTools.isEmpty)
    }

    func testThreeDistinctModes() {
        XCTAssertEqual(AccessMode.allCases.count, 3)
        XCTAssertTrue(AccessMode.safe.allowedTools.contains("Read"))
    }
}
