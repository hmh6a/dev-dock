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
    /// The owning process's current working directory, if it could be resolved.
    /// This is the project folder the server was started from — e.g.
    /// `/Users/me/Documents/GitHub/yas/yas-api`.
    public let workingDirectory: String?
    /// Live CPU / memory usage of the owning process, when it could be read.
    /// Shared by every port the same pid owns — it is a per-process figure.
    public let usage: ProcessUsage?

    /// Stable identity for SwiftUI lists. A single process can own several ports,
    /// so the address and port are part of the identity.
    public var id: String { "\(pid)-\(address)-\(port)" }

    public init(
        pid: Int,
        process: String,
        address: String,
        port: Int,
        workingDirectory: String? = nil,
        usage: ProcessUsage? = nil
    ) {
        self.pid = pid
        self.process = process
        self.address = address
        self.port = port
        self.workingDirectory = workingDirectory
        self.usage = usage
    }

    /// A copy of this entry with its working directory filled in.
    public func withWorkingDirectory(_ path: String?) -> PortEntry {
        PortEntry(pid: pid, process: process, address: address, port: port, workingDirectory: path, usage: usage)
    }

    /// A copy of this entry with its owner's CPU / memory usage filled in.
    public func withUsage(_ usage: ProcessUsage?) -> PortEntry {
        PortEntry(pid: pid, process: process, address: address, port: port, workingDirectory: workingDirectory, usage: usage)
    }

    /// The last path component of ``workingDirectory`` — the project folder name a
    /// developer recognizes (e.g. `yas-api`). `nil` when the directory is unknown
    /// or the filesystem root (`/`), which carries no useful project name.
    public var folderName: String? {
        guard var path = workingDirectory, !path.isEmpty else { return nil }
        // Drop a trailing slash so `/a/b/` still yields `b`.
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path != "/" else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
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

    /// `true` when the socket is bound to every interface (`*`, `0.0.0.0`, `::`),
    /// which means the port is also reachable from other machines — over Wi-Fi,
    /// Ethernet, or Tailscale — not just from this Mac.
    public var isReachableFromNetwork: Bool {
        switch address {
        case "*", "0.0.0.0", "::", "[::]", "":
            return true
        default:
            return false
        }
    }

    /// The URL for reaching this port at a specific host, e.g. a LAN or
    /// Tailscale address: `http://100.64.0.12:3000`.
    public func urlString(host: String) -> String {
        "http://\(host):\(port)"
    }
}
