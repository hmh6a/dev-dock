import XCTest
@testable import DevDockCore

final class LsofParserTests: XCTestCase {

    /// Representative real-world `lsof -iTCP -sTCP:LISTEN -n -P` output covering
    /// IPv4, IPv6, wildcard binds, a truncated command name, and duplicate rows.
    private let sample = """
    COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    node      12345 hussam   23u  IPv4 0x1a2b3c4d5e6f7a8b      0t0  TCP 127.0.0.1:3000 (LISTEN)
    node      12345 hussam   24u  IPv6 0x1a2b3c4d5e6f7a8c      0t0  TCP [::1]:3000 (LISTEN)
    com.docke   999 hussam   30u  IPv4 0x2b3c4d5e6f7a8b9c      0t0  TCP *:8080 (LISTEN)
    Postgres    777 hussam    7u  IPv4 0x3c4d5e6f7a8b9cad      0t0  TCP 127.0.0.1:5432 (LISTEN)
    Postgres    777 hussam    7u  IPv4 0x3c4d5e6f7a8b9cad      0t0  TCP 127.0.0.1:5432 (LISTEN)
    """

    func testParsesAllUniqueEntries() {
        let entries = LsofParser.parse(sample)
        // Five data rows, one is an exact duplicate → 4 unique.
        XCTAssertEqual(entries.count, 4)
    }

    func testParsesFieldsCorrectly() {
        let entries = LsofParser.parse(sample)
        let three = entries.first { $0.port == 3000 && $0.address == "127.0.0.1" }
        XCTAssertEqual(three?.pid, 12345)
        XCTAssertEqual(three?.process, "node")

        let docker = entries.first { $0.port == 8080 }
        XCTAssertEqual(docker?.address, "*")
        XCTAssertEqual(docker?.pid, 999)
        XCTAssertEqual(docker?.process, "com.docke")
    }

    func testParsesIPv6Address() {
        let entries = LsofParser.parse(sample)
        let v6 = entries.first { $0.address == "[::1]" }
        XCTAssertNotNil(v6)
        XCTAssertEqual(v6?.port, 3000)
    }

    func testResultsAreSortedByPort() {
        let ports = LsofParser.parse(sample).map(\.port)
        XCTAssertEqual(ports, ports.sorted())
    }

    func testSkipsHeaderAndBlankLines() {
        let entries = LsofParser.parse("\n\nCOMMAND PID\n\n")
        XCTAssertTrue(entries.isEmpty)
    }

    func testIgnoresMalformedRows() {
        let entries = LsofParser.parse("garbage line with no port\nnode 100 u TCP notaport (LISTEN)")
        XCTAssertTrue(entries.isEmpty)
    }

    func testEmptyInput() {
        XCTAssertTrue(LsofParser.parse("").isEmpty)
    }
}
