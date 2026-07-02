import XCTest
@testable import DevDockCore

final class PartialStreamParsingTests: XCTestCase {

    func testTextDeltaBecomesAssistantDelta() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"1, 2, 3"}}}"#
        XCTAssertEqual(ClaudeStreamParser.parse(line: line), [.assistantDelta("1, 2, 3")])
    }

    func testTextBlockStartBecomesBlockStart() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#
        XCTAssertEqual(ClaudeStreamParser.parse(line: line), [.assistantBlockStart])
    }

    func testIgnoresMessageStartStopAndDelta() {
        XCTAssertTrue(ClaudeStreamParser.parse(line: #"{"type":"stream_event","event":{"type":"message_start","message":{}}}"#).isEmpty)
        XCTAssertTrue(ClaudeStreamParser.parse(line: #"{"type":"stream_event","event":{"type":"message_stop"}}"#).isEmpty)
        XCTAssertTrue(ClaudeStreamParser.parse(line: #"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"#).isEmpty)
    }

    func testThinkingDeltaParsed() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm let me think"}}}"#
        XCTAssertEqual(ClaudeStreamParser.parse(line: line), [.thinkingDelta("hmm let me think")])
    }

    func testPartialToolUseStartIsDropped() {
        // Rich tool detail comes from the complete assistant message, not the partial start.
        let line = #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","name":"Read"}}}"#
        XCTAssertTrue(ClaudeStreamParser.parse(line: line).isEmpty)
    }
}

final class ToolDescribeTests: XCTestCase {
    func testReadWithLineRange() {
        let desc = ClaudeStreamParser.describeTool(
            name: "Read",
            input: ["file_path": "/a/b/AIView.swift", "offset": 311, "limit": 18]
        )
        XCTAssertEqual(desc, "Read AIView.swift (lines 311-328)")
    }

    func testEditShowsBasename() {
        XCTAssertEqual(
            ClaudeStreamParser.describeTool(name: "Edit", input: ["file_path": "/x/y/api.ts"]),
            "Edit api.ts"
        )
    }

    func testBashShowsFirstLine() {
        XCTAssertEqual(
            ClaudeStreamParser.describeTool(name: "Bash", input: ["command": "npm run dev\n# noise"]),
            "Bash npm run dev"
        )
    }

    func testUnknownToolIsJustName() {
        XCTAssertEqual(ClaudeStreamParser.describeTool(name: "TodoWrite", input: [:]), "TodoWrite")
    }

    func testToolUseInAssistantMessageIsDescribed() {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/AIView.swift","offset":10,"limit":5}}]}}"#
        XCTAssertEqual(ClaudeStreamParser.parse(line: line), [.toolUse(name: "Read AIView.swift (lines 10-14)")])
    }
}

final class RemoteControlParserTests: XCTestCase {

    func testExtractsSessionURL() {
        let line = "Code anywhere with the Claude mobile app or https://claude.ai/code?environment=env_013abc"
        XCTAssertEqual(
            RemoteControlParser.parse(line: line),
            .url("https://claude.ai/code?environment=env_013abc")
        )
    }

    func testDetectsReady() {
        XCTAssertEqual(RemoteControlParser.parse(line: "·✔︎· Ready · dev-dock · main"), .ready)
    }

    func testDetectsConnecting() {
        XCTAssertEqual(RemoteControlParser.parse(line: "·|· Connecting · dev-dock · main"), .connecting)
    }

    func testStripsANSIBeforeParsing() {
        let line = "\u{1B}[32m·✔︎· Ready\u{1B}[0m · dev-dock"
        XCTAssertEqual(RemoteControlParser.parse(line: line), .ready)
    }

    func testURLSurvivesANSI() {
        let line = "\u{1B}[2mopen \u{1B}[0mhttps://claude.ai/code?environment=env_9 now"
        XCTAssertEqual(
            RemoteControlParser.parse(line: line),
            .url("https://claude.ai/code?environment=env_9")
        )
    }

    func testSkipsPromptAndBlankLines() {
        XCTAssertNil(RemoteControlParser.parse(line: "Enable Remote Control? (y/n)"))
        XCTAssertNil(RemoteControlParser.parse(line: "   "))
    }

    func testGenericStatusPassesThrough() {
        XCTAssertEqual(
            RemoteControlParser.parse(line: "Capacity: 0/32"),
            .status("Capacity: 0/32")
        )
    }
}
