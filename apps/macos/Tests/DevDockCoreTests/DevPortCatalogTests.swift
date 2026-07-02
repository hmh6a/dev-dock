import XCTest
@testable import DevDockCore

final class DevPortCatalogTests: XCTestCase {

    func testRecognizesCommonDevPorts() {
        XCTAssertTrue(DevPortCatalog.isDevPort(3000))
        XCTAssertTrue(DevPortCatalog.isDevPort(5173))
        XCTAssertTrue(DevPortCatalog.isDevPort(5432))
        XCTAssertEqual(DevPortCatalog.label(for: 5173), "Vite")
        XCTAssertEqual(DevPortCatalog.label(for: 5432), "PostgreSQL")
    }

    func testUnknownPortIsNotDev() {
        XCTAssertFalse(DevPortCatalog.isDevPort(54321))
        XCTAssertNil(DevPortCatalog.label(for: 54321))
    }

    func testPortEntryConveniences() {
        let vite = PortEntry(pid: 1, process: "node", address: "127.0.0.1", port: 5173)
        XCTAssertTrue(vite.isDevPort)
        XCTAssertEqual(vite.serviceLabel, "Vite")

        let random = PortEntry(pid: 2, process: "x", address: "*", port: 54321)
        XCTAssertFalse(random.isDevPort)
        XCTAssertNil(random.serviceLabel)
    }
}
