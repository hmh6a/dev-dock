import XCTest
@testable import DevDockCore

/// A `CommandRunning` stub so services can be tested without spawning processes.
private struct StubRunner: CommandRunning {
    var result: CommandResult
    var recorded: RecordedBox = RecordedBox()

    final class RecordedBox: @unchecked Sendable {
        var launchPath: String?
        var arguments: [String]?
    }

    func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
        recorded.launchPath = launchPath
        recorded.arguments = arguments
        return result
    }
}

final class PortScannerTests: XCTestCase {
    func testScanRunsLsofWithSpecArgumentsAndParses() throws {
        let stub = StubRunner(result: CommandResult(
            stdout: "node 42 me 1u IPv4 0x0 0t0 TCP 127.0.0.1:3000 (LISTEN)\n",
            stderr: "",
            exitCode: 0
        ))
        let scanner = PortScanner(runner: stub)
        let entries = try scanner.scan()

        XCTAssertEqual(stub.recorded.launchPath, "/usr/sbin/lsof")
        XCTAssertEqual(stub.recorded.arguments, ["-iTCP", "-sTCP:LISTEN", "-n", "-P"])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.port, 3000)
    }
}

final class ProcessManagerTests: XCTestCase {
    func testGracefulKillSendsSigterm() throws {
        let stub = StubRunner(result: CommandResult(stdout: "", stderr: "", exitCode: 0))
        let manager = ProcessManager(runner: stub)
        try manager.kill(pid: 4242)
        XCTAssertEqual(stub.recorded.launchPath, "/bin/kill")
        XCTAssertEqual(stub.recorded.arguments, ["-15", "4242"])
    }

    func testForceKillSendsSigkill() throws {
        let stub = StubRunner(result: CommandResult(stdout: "", stderr: "", exitCode: 0))
        let manager = ProcessManager(runner: stub)
        try manager.kill(pid: 7, force: true)
        XCTAssertEqual(stub.recorded.arguments, ["-9", "7"])
    }

    func testNonZeroExitThrows() {
        let stub = StubRunner(result: CommandResult(stdout: "", stderr: "No such process", exitCode: 1))
        let manager = ProcessManager(runner: stub)
        XCTAssertThrowsError(try manager.kill(pid: 999999))
    }
}

final class BridgeMessageTests: XCTestCase {
    func testRoundTripEncodesAndDecodes() throws {
        let original = BridgeMessage(
            type: .runTerminalCommand,
            command: "npm run dev",
            requestId: "abc-123"
        )
        let json = try original.jsonString()
        let decoded = try BridgeMessage.decode(from: json)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.type, .runTerminalCommand)
        XCTAssertEqual(decoded.command, "npm run dev")
    }

    func testDecodesEditorContextMessage() throws {
        let json = #"{"type":"activeFile","file":"/a/b.ts","language":"typescript"}"#
        let message = try BridgeMessage.decode(from: json)
        XCTAssertEqual(message.type, .activeFile)
        XCTAssertEqual(message.file, "/a/b.ts")
        XCTAssertEqual(message.language, "typescript")
        XCTAssertNil(message.selection)
    }
}
