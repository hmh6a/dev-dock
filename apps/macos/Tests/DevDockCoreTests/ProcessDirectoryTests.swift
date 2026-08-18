import XCTest
@testable import DevDockCore

final class LsofCwdParserTests: XCTestCase {

    /// Representative `lsof -a -d cwd -p <pids> -Fn` field output.
    private let sample = """
    p73181
    fcwd
    n/Users/hmh/Documents/GitHub/dudes/yas/yas-api
    p619
    fcwd
    n/
    p20609
    fcwd
    n/Users/hmh/.vscode/extensions/pylance/dist
    """

    func testMapsPidsToDirectories() {
        let map = LsofCwdParser.parse(sample)
        XCTAssertEqual(map[73181], "/Users/hmh/Documents/GitHub/dudes/yas/yas-api")
        XCTAssertEqual(map[619], "/")
        XCTAssertEqual(map.count, 3)
    }

    func testHandlesPathsWithSpaces() {
        let map = LsofCwdParser.parse("p42\nfcwd\nn/Users/me/Application Support/go\n")
        XCTAssertEqual(map[42], "/Users/me/Application Support/go")
    }

    func testEmptyInput() {
        XCTAssertTrue(LsofCwdParser.parse("").isEmpty)
    }
}

final class PortEntryFolderTests: XCTestCase {

    func testFolderNameIsLastPathComponent() {
        let entry = PortEntry(pid: 1, process: "node", address: "*", port: 4040,
                              workingDirectory: "/Users/hmh/Documents/GitHub/dudes/yas/yas-api")
        XCTAssertEqual(entry.folderName, "yas-api")
    }

    func testFolderNameIgnoresTrailingSlash() {
        let entry = PortEntry(pid: 1, process: "node", address: "*", port: 4040,
                              workingDirectory: "/Users/hmh/projects/api/")
        XCTAssertEqual(entry.folderName, "api")
    }

    func testFolderNameNilForRoot() {
        let entry = PortEntry(pid: 1, process: "x", address: "*", port: 80, workingDirectory: "/")
        XCTAssertNil(entry.folderName)
    }

    func testFolderNameNilWhenUnknown() {
        let entry = PortEntry(pid: 1, process: "x", address: "*", port: 80)
        XCTAssertNil(entry.folderName)
    }

    func testWithWorkingDirectoryPreservesIdentity() {
        let base = PortEntry(pid: 7, process: "node", address: "127.0.0.1", port: 3000)
        let enriched = base.withWorkingDirectory("/tmp/app")
        XCTAssertEqual(base.id, enriched.id)
        XCTAssertEqual(enriched.folderName, "app")
    }
}

final class ProcessDirectoryResolverTests: XCTestCase {

    private struct StubRunner: CommandRunning {
        var result: CommandResult
        final class Box: @unchecked Sendable { var arguments: [String]? }
        var recorded = Box()
        func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
            recorded.arguments = arguments
            return result
        }
    }

    func testResolvesForGivenPids() {
        let stub = StubRunner(result: CommandResult(
            stdout: "p42\nfcwd\nn/Users/me/api\n", stderr: "", exitCode: 0))
        let resolver = ProcessDirectoryResolver(runner: stub)
        let map = resolver.resolve(pids: [42])
        XCTAssertEqual(map[42], "/Users/me/api")
    }

    func testEmptyPidsDoesNotShellOut() {
        let stub = StubRunner(result: CommandResult(stdout: "everything", stderr: "", exitCode: 0))
        let resolver = ProcessDirectoryResolver(runner: stub)
        let map = resolver.resolve(pids: [])
        XCTAssertTrue(map.isEmpty)
        // Must not run `lsof -p ""`, which would list every process.
        XCTAssertNil(stub.recorded.arguments)
    }
}
