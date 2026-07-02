import XCTest
@testable import DevDockCore

final class PortEntryTests: XCTestCase {

    func testLoopbackURL() {
        let entry = PortEntry(pid: 1, process: "node", address: "127.0.0.1", port: 3000)
        XCTAssertEqual(entry.localURLString, "http://127.0.0.1:3000")
    }

    func testWildcardMapsToLocalhost() {
        let entry = PortEntry(pid: 1, process: "docker", address: "*", port: 8080)
        XCTAssertEqual(entry.localURLString, "http://localhost:8080")
    }

    func testAnyAddressMapsToLocalhost() {
        XCTAssertEqual(
            PortEntry(pid: 1, process: "x", address: "0.0.0.0", port: 80).browserHost,
            "localhost"
        )
    }

    func testIPv6LoopbackMapsToLocalhost() {
        let entry = PortEntry(pid: 1, process: "x", address: "[::1]", port: 5000)
        XCTAssertEqual(entry.localURLString, "http://localhost:5000")
    }

    func testURLIsValid() {
        let entry = PortEntry(pid: 1, process: "node", address: "127.0.0.1", port: 3000)
        XCTAssertNotNil(entry.localURL)
    }

    func testIdentityIncludesPortAndAddress() {
        let a = PortEntry(pid: 5, process: "n", address: "127.0.0.1", port: 3000)
        let b = PortEntry(pid: 5, process: "n", address: "127.0.0.1", port: 4000)
        XCTAssertNotEqual(a.id, b.id)
    }
}
