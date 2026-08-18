import XCTest
@testable import DevDockCore

/// Covers the pure classification rules behind the "this Mac" address list.
final class NetworkInterfaceTests: XCTestCase {

    // MARK: - Kind classification

    func testTailscaleAddressIsRecognizedOnAPlainUtunDevice() {
        // Tailscale runs over an anonymous `utun` device; only the CGNAT range
        // 100.64.0.0/10 identifies it.
        XCTAssertEqual(NetworkInterfaceClassifier.kind(interface: "utun4", ip: "100.64.0.12"), .tailscale)
        XCTAssertEqual(NetworkInterfaceClassifier.kind(interface: "utun9", ip: "100.127.255.1"), .tailscale)
    }

    func testNonTailscaleUtunIsAPlainVPN() {
        XCTAssertEqual(NetworkInterfaceClassifier.kind(interface: "utun3", ip: "10.8.0.6"), .vpn)
    }

    func testCarrierGradeRangeBoundaries() {
        XCTAssertTrue(NetworkInterfaceClassifier.isTailscaleAddress("100.64.0.1"))
        XCTAssertTrue(NetworkInterfaceClassifier.isTailscaleAddress("100.127.0.1"))
        XCTAssertFalse(NetworkInterfaceClassifier.isTailscaleAddress("100.63.255.1"))
        XCTAssertFalse(NetworkInterfaceClassifier.isTailscaleAddress("100.128.0.1"))
        XCTAssertFalse(NetworkInterfaceClassifier.isTailscaleAddress("192.168.0.189"))
    }

    func testHardwareHintDecidesWiFiVersusEthernet() {
        // `en0` is Wi-Fi on a laptop and wired on a Mac mini — never guess.
        XCTAssertEqual(
            NetworkInterfaceClassifier.kind(interface: "en0", ip: "192.168.0.189", hardware: .wifi),
            .wifi
        )
        XCTAssertEqual(
            NetworkInterfaceClassifier.kind(interface: "en0", ip: "192.168.0.189", hardware: .ethernet),
            .ethernet
        )
    }

    func testVirtualBridgesAreClassifiedSeparately() {
        XCTAssertEqual(NetworkInterfaceClassifier.kind(interface: "bridge100", ip: "192.168.64.1"), .virtualNetwork)
        XCTAssertEqual(NetworkInterfaceClassifier.kind(interface: "vmenet0", ip: "192.168.66.1"), .virtualNetwork)
    }

    func testLoopbackIsClassifiedFromNameOrFlag() {
        XCTAssertEqual(NetworkInterfaceClassifier.kind(interface: "lo0", ip: "127.0.0.1"), .loopback)
        XCTAssertEqual(NetworkInterfaceClassifier.kind(interface: "xx0", ip: "127.0.0.1", isLoopback: true), .loopback)
    }

    // MARK: - Building the display list

    private let sample = [
        RawInterfaceAddress(interface: "lo0", ip: "127.0.0.1", isLoopback: true),
        RawInterfaceAddress(interface: "utun4", ip: "100.64.0.12"),
        RawInterfaceAddress(interface: "awdl0", ip: "169.254.3.4"),
        RawInterfaceAddress(interface: "en0", ip: "192.168.0.189"),
        RawInterfaceAddress(interface: "anpi0", ip: "10.0.0.2"),
        RawInterfaceAddress(interface: "en5", ip: "192.168.1.20")
    ]

    func testNoiseInterfacesAndLinkLocalAreDropped() {
        let addresses = NetworkInterfaceClassifier.addresses(
            from: sample,
            hardwareTypes: ["en0": .wifi, "en5": .ethernet]
        )
        let interfaces = addresses.map(\.interface)
        XCTAssertFalse(interfaces.contains("awdl0"), "AirDrop link-local address must not be listed")
        XCTAssertFalse(interfaces.contains("anpi0"), "Internal management interface must not be listed")
        XCTAssertFalse(interfaces.contains("lo0"), "Loopback is excluded unless explicitly requested")
    }

    func testAddressesAreOrderedWiFiEthernetThenTailscale() {
        let addresses = NetworkInterfaceClassifier.addresses(
            from: sample,
            hardwareTypes: ["en0": .wifi, "en5": .ethernet]
        )
        XCTAssertEqual(addresses.map(\.ip), ["192.168.0.189", "192.168.1.20", "100.64.0.12"])
        XCTAssertEqual(addresses.map(\.kind), [.wifi, .ethernet, .tailscale])
    }

    func testSystemNameLabelsHardwareButNotTunnels() {
        let addresses = NetworkInterfaceClassifier.addresses(
            from: sample,
            displayNames: ["en0": "Wi-Fi", "utun4": "utun4"],
            hardwareTypes: ["en0": .wifi, "en5": .ethernet]
        )
        XCTAssertEqual(addresses.first(where: { $0.interface == "en0" })?.label, "Wi-Fi")
        // The system name for a tunnel is just "utun4", which tells nobody anything.
        XCTAssertEqual(addresses.first(where: { $0.interface == "utun4" })?.label, "Tailscale")
        XCTAssertEqual(addresses.first(where: { $0.interface == "en5" })?.label, "Ethernet")
    }

    func testLoopbackCanBeIncludedOnDemand() {
        let addresses = NetworkInterfaceClassifier.addresses(from: sample, includeLoopback: true)
        XCTAssertEqual(addresses.last?.ip, "127.0.0.1", "Loopback sorts last")
    }

    func testDuplicateAddressesAppearOnce() {
        let duplicated = [
            RawInterfaceAddress(interface: "en0", ip: "192.168.0.189"),
            RawInterfaceAddress(interface: "en0", ip: "192.168.0.189")
        ]
        XCTAssertEqual(NetworkInterfaceClassifier.addresses(from: duplicated).count, 1)
    }

    func testURLForAPort() {
        let address = NetworkAddress(interface: "utun4", ip: "100.64.0.12", kind: .tailscale, label: "Tailscale")
        XCTAssertEqual(address.urlString(port: 3000), "http://100.64.0.12:3000")
    }

    // MARK: - Port reachability

    func testWildcardBindsAreReachableFromOtherMachines() {
        for address in ["*", "0.0.0.0", "::", "[::]"] {
            XCTAssertTrue(
                PortEntry(pid: 1, process: "node", address: address, port: 3000).isReachableFromNetwork,
                "\(address) binds every interface"
            )
        }
    }

    func testLoopbackBindsAreLocalOnly() {
        for address in ["127.0.0.1", "[::1]"] {
            XCTAssertFalse(
                PortEntry(pid: 1, process: "node", address: address, port: 3000).isReachableFromNetwork,
                "\(address) is only reachable from this Mac"
            )
        }
    }

    // MARK: - Live system read

    func testLiveScanReturnsWellFormedAddresses() {
        // Machine-dependent: a Mac with no network at all yields an empty list,
        // which is a valid result. Everything returned must be sane, though.
        for address in NetworkInterfaceScanner().scan() {
            XCTAssertFalse(address.ip.isEmpty)
            XCTAssertFalse(address.label.isEmpty)
            XCTAssertFalse(address.interface.isEmpty)
            XCTAssertNotEqual(address.kind, .loopback)
        }
    }
}
