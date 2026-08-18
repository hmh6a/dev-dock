import XCTest
@testable import DevDockCore

final class PsUsageParserTests: XCTestCase {

    /// Representative `ps -o pid=,%cpu=,%mem=,rss= -p <pids>` output — headerless,
    /// right-aligned, variable leading whitespace.
    private let sample = """
      846   0.4  0.7 179352
     8256   8.6  0.4 109260
    99007   0.8  0.2  42420
    """

    func testMapsPidsToUsage() {
        let map = PsUsageParser.parse(sample)
        XCTAssertEqual(map.count, 3)
        XCTAssertEqual(map[846], ProcessUsage(cpuPercent: 0.4, memoryPercent: 0.7, residentKB: 179352))
        XCTAssertEqual(map[8256]?.cpuPercent, 8.6)
        XCTAssertEqual(map[99007]?.residentKB, 42420)
    }

    func testSkipsMalformedAndHeaderLines() {
        let map = PsUsageParser.parse("  PID %CPU %MEM   RSS\n  846   0.4  0.7 179352\ngarbage\n")
        XCTAssertEqual(map.count, 1)
        XCTAssertNotNil(map[846])
    }

    func testEmptyOutputYieldsEmptyMap() {
        XCTAssertTrue(PsUsageParser.parse("").isEmpty)
    }

    func testMemoryLabelScalesWithSize() {
        XCTAssertEqual(ProcessUsage(cpuPercent: 0, memoryPercent: 0, residentKB: 842).memoryLabel, "842 KB")
        XCTAssertEqual(ProcessUsage(cpuPercent: 0, memoryPercent: 0, residentKB: 179352).memoryLabel, "175 MB")
        XCTAssertEqual(ProcessUsage(cpuPercent: 0, memoryPercent: 0, residentKB: 2_516_582).memoryLabel, "2.4 GB")
    }

    func testCpuLabelDropsDecimalWhenBusy() {
        XCTAssertEqual(ProcessUsage(cpuPercent: 0.4, memoryPercent: 0, residentKB: 0).cpuLabel, "0.4%")
        XCTAssertEqual(ProcessUsage(cpuPercent: 142.7, memoryPercent: 0, residentKB: 0).cpuLabel, "143%")
    }

    func testResolverReturnsEmptyWithoutShellingOutForNoPids() {
        let runner = SpyRunner()
        let resolved = ProcessUsageResolver(runner: runner).resolve(pids: [])
        XCTAssertTrue(resolved.isEmpty)
        XCTAssertTrue(runner.invocations.isEmpty, "ps must not run with an empty pid list")
    }

    func testResolverQueriesPsWithUniquePids() {
        let runner = SpyRunner(stdout: "  846   0.4  0.7 179352\n")
        let resolved = ProcessUsageResolver(runner: runner).resolve(pids: [846, 846])
        XCTAssertEqual(resolved[846]?.residentKB, 179352)
        XCTAssertEqual(runner.invocations.first?.path, "/bin/ps")
        XCTAssertEqual(runner.invocations.first?.arguments, ["-o", "pid=,%cpu=,%mem=,rss=", "-p", "846"])
    }
}

/// Records what would have been executed instead of spawning a real process.
private final class SpyRunner: CommandRunning, @unchecked Sendable {
    struct Invocation { let path: String; let arguments: [String] }

    private(set) var invocations: [Invocation] = []
    private let stdout: String

    init(stdout: String = "") { self.stdout = stdout }

    func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
        invocations.append(Invocation(path: launchPath, arguments: arguments))
        return CommandResult(stdout: stdout, stderr: "", exitCode: 0)
    }
}
