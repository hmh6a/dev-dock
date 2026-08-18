import XCTest
@testable import DevDockCore

final class CLIToolVersionParserTests: XCTestCase {

    func testPullsVersionOutOfMoleBanner() {
        let output = """
        Mole version 1.44.1
        macOS: 26.5.2
        """
        XCTAssertEqual(CLIToolVersionParser.parse(output), "1.44.1")
    }

    func testStripsLeadingV() {
        XCTAssertEqual(CLIToolVersionParser.parse("git version v2.39.5"), "2.39.5")
    }

    func testSkipsLeadingBlankLines() {
        XCTAssertEqual(CLIToolVersionParser.parse("\n\n  tool 3.0  \n"), "3.0")
    }

    func testFallsBackToTheWholeLineWhenNoVersionToken() {
        XCTAssertEqual(CLIToolVersionParser.parse("built from source"), "built from source")
    }

    func testEmptyOutputYieldsNil() {
        XCTAssertNil(CLIToolVersionParser.parse("   \n\n"))
    }
}

final class CLIToolLocatorTests: XCTestCase {

    private let mole = CLIToolCatalog.mole

    func testFindsToolInHomebrewPrefix() {
        let locator = CLIToolLocator(
            runner: StubRunner(stdout: "Mole version 1.44.1\n"),
            searchPaths: ["/opt/homebrew/bin", "/usr/local/bin"],
            isExecutableFile: { $0 == "/opt/homebrew/bin/mole" }
        )
        let found = locator.locate(mole)
        XCTAssertEqual(found?.path, "/opt/homebrew/bin/mole")
        XCTAssertEqual(found?.version, "1.44.1")
    }

    func testSearchPathsAreTriedInOrder() {
        // Present in both prefixes — the first search path must win.
        let locator = CLIToolLocator(
            runner: StubRunner(),
            searchPaths: ["/opt/homebrew/bin", "/usr/local/bin"],
            isExecutableFile: { _ in true }
        )
        XCTAssertEqual(locator.path(forExecutable: "mole"), "/opt/homebrew/bin/mole")
    }

    func testMissingToolResolvesToNil() {
        let locator = CLIToolLocator(
            runner: StubRunner(),
            searchPaths: ["/opt/homebrew/bin"],
            isExecutableFile: { _ in false }
        )
        XCTAssertNil(locator.locate(mole))
    }

    func testInstalledWithoutReadableVersionStillCounts() {
        let locator = CLIToolLocator(
            runner: FailingRunner(),
            searchPaths: ["/usr/local/bin"],
            isExecutableFile: { _ in true }
        )
        let found = locator.locate(mole)
        XCTAssertEqual(found?.path, "/usr/local/bin/mole")
        XCTAssertNil(found?.version)
    }

    func testFallsBackToStderrForVersion() {
        let locator = CLIToolLocator(
            runner: StubRunner(stdout: "", stderr: "tool 9.1\n"),
            searchPaths: ["/usr/local/bin"],
            isExecutableFile: { _ in true }
        )
        XCTAssertEqual(locator.locate(mole)?.version, "9.1")
    }

    func testInstallCommandUsesTheBrewFormula() {
        XCTAssertEqual(mole.installCommand, "brew install mole")
    }
}

private struct StubRunner: CommandRunning {
    var stdout: String = ""
    var stderr: String = ""

    func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
        CommandResult(stdout: stdout, stderr: stderr, exitCode: 0)
    }
}

private struct FailingRunner: CommandRunning {
    struct Boom: Error {}

    func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
        throw Boom()
    }
}
