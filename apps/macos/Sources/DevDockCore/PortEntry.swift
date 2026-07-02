import Foundation

/// A single listening TCP port discovered on the local machine.
///
/// This is the core domain model for the **Ports** tab. It is intentionally a
/// plain value type so it can be created and asserted against in unit tests
/// without touching the system.
public struct PortEntry: Identifiable, Equatable, Hashable, Sendable {
    /// The process id that owns the listening socket.
    public let pid: Int
    /// The (possibly truncated) command name reported by `lsof`.
    public let process: String
    /// The bind address exactly as reported by `lsof` — e.g. `127.0.0.1`, `*`, `[::1]`.
    public let address: String
    /// The listening port number.
    public let port: Int

    /// Stable identity for SwiftUI lists. A single process can own several ports,
    /// so the address and port are part of the identity.
    public var id: String { "\(pid)-\(address)-\(port)" }

    public init(pid: Int, process: String, address: String, port: Int) {
        self.pid = pid
        self.process = process
        self.address = address
        self.port = port
    }

    /// A host that is safe to open in a browser.
    ///
    /// Wildcard / any-address binds (`*`, `0.0.0.0`, `::`) and IPv6 loopback are
    /// normalized to `localhost`, which is friendlier and always reachable.
    public var browserHost: String {
        switch address {
        case "*", "0.0.0.0", "::", "[::]", "":
            return "localhost"
        case "[::1]", "::1":
            return "localhost"
        default:
            return address
        }
    }

    /// The URL string a user would open to reach this port, e.g. `http://localhost:3000`.
    public var localURLString: String {
        "http://\(browserHost):\(port)"
    }

    /// The URL a user would open to reach this port.
    public var localURL: URL? {
        URL(string: localURLString)
    }
}
