import Foundation
import Network
import Darwin

/// A tiny HTTP/1.1 static server that serves the installable mobile web app
/// (``PWAAssets``) over the LAN, so a phone on the same network can open
/// `http://<mac-ip>:<port>` and drive Claude Code.
@MainActor
final class PWAServer: ObservableObject {
    @Published private(set) var isRunning = false

    let port: UInt16
    private var listener: NWListener?

    init(port: UInt16 = 51890) { self.port = port }

    /// A specific IP the user picked in the Mobile tab (nil = auto-pick the best
    /// one). Lets you use a plain Wi-Fi/Ethernet address when there's no Tailscale.
    @Published var preferredIP: String?

    /// Every reachable IPv4 address on this Mac, labelled (Tailscale / Wi-Fi / …).
    var interfaces: [NetworkInfo.Interface] { NetworkInfo.allInterfaces() }

    /// The IP the URL/QR currently use: the user's pick if it's still available,
    /// otherwise the best automatic choice (Tailscale, then LAN).
    var activeIP: String? {
        if let preferredIP, interfaces.contains(where: { $0.ip == preferredIP }) {
            return preferredIP
        }
        return NetworkInfo.bestIPv4()
    }

    /// The interface backing ``activeIP`` (for its label + kind).
    var activeInterface: NetworkInfo.Interface? {
        guard let activeIP else { return nil }
        return interfaces.first { $0.ip == activeIP }
    }

    /// The URL to open on a phone, using ``activeIP``.
    var url: String {
        let host = activeIP ?? "localhost"
        return "http://\(host):\(port)"
    }

    /// Whether the active URL uses a Tailscale address (reachable off the LAN).
    var isTailscale: Bool { activeIP.map(NetworkInfo.isTailscale) ?? false }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: parameters, on: nwPort) else { return }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.isRunning = true
                case .failed, .cancelled: self?.isRunning = false
                default: break
                }
            }
        }
        listener.newConnectionHandler = { connection in
            PWAServer.serve(connection)
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    /// Largest image upload we'll accept from a phone (bytes).
    private static let maxUploadBytes = 30_000_000

    /// Handle one request. GETs serve the PWA; `POST /upload` saves an image the
    /// phone attached and returns its path so Claude can read it.
    nonisolated private static func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        receiveRequest(connection, buffer: Data())
    }

    /// Accumulate bytes until we have the full request (headers + any POST body),
    /// then route it. HTTP bodies can span several TCP segments, so we recurse.
    nonisolated private static func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            var buf = buffer
            if let data { buf.append(data) }

            guard let bodyStart = headerEnd(buf) else {
                if error == nil && !isComplete && buf.count < 65_536 {
                    receiveRequest(connection, buffer: buf)      // headers not complete yet
                } else {
                    sendResponse(connection, status: "400 Bad Request", contentType: "text/plain", body: Data("bad request".utf8))
                }
                return
            }

            let head = String(decoding: buf.prefix(bodyStart), as: UTF8.self)
            let (method, path) = requestLine(head)

            if method == "POST" && path == "/upload" {
                let length = headerValueInt(head, "content-length") ?? 0
                if length <= 0 || length > maxUploadBytes {
                    sendResponse(connection, status: "413 Payload Too Large", contentType: "text/plain", body: Data("too large".utf8))
                    return
                }
                if buf.count - bodyStart < length {
                    if error == nil && !isComplete {
                        receiveRequest(connection, buffer: buf)  // wait for the rest of the body
                    } else {
                        sendResponse(connection, status: "400 Bad Request", contentType: "text/plain", body: Data("incomplete".utf8))
                    }
                    return
                }
                let body = buf.subdata(in: bodyStart..<(bodyStart + length))
                handleUpload(connection, body: body, contentType: headerValue(head, "content-type") ?? "image/jpeg")
            } else if path == "/media" {
                handleMedia(connection, path: queryValue(rawTarget(head), "p"))
            } else {
                let (contentType, body) = PWAAssets.response(for: path)
                sendResponse(connection, status: "200 OK", contentType: contentType, body: body)
            }
        }
    }

    /// Save an uploaded image to a temp file and return its path as JSON.
    nonisolated private static func handleUpload(_ connection: NWConnection, body: Data, contentType: String) {
        let ext: String
        if contentType.contains("png") { ext = "png" }
        else if contentType.contains("gif") { ext = "gif" }
        else if contentType.contains("webp") { ext = "webp" }
        else if contentType.contains("heic") { ext = "heic" }
        else { ext = "jpg" }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dev-dock-mobile", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(UUID().uuidString + "." + ext)
        do {
            try body.write(to: file)
            let json = (try? JSONSerialization.data(withJSONObject: ["path": file.path])) ?? Data("{}".utf8)
            sendResponse(connection, status: "200 OK", contentType: "application/json", body: json)
        } catch {
            sendResponse(connection, status: "500 Internal Server Error", contentType: "text/plain", body: Data("upload failed".utf8))
        }
    }

    /// Serve an attached image back to the phone so the chat shows the picture,
    /// not the path. Restricted to files inside the system temp directory (where
    /// both phone uploads and desktop attachments live) — never arbitrary files.
    nonisolated private static func handleMedia(_ connection: NWConnection, path: String?) {
        guard let path, !path.isEmpty else {
            sendResponse(connection, status: "404 Not Found", contentType: "text/plain", body: Data("no path".utf8))
            return
        }
        let fileURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()   // also collapses ".."
        let tempDir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard fileURL.path.hasPrefix(tempDir),
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            sendResponse(connection, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
            return
        }
        let ext = fileURL.pathExtension.lowercased()
        let contentType = ext == "png" ? "image/png"
            : ext == "gif" ? "image/gif"
            : ext == "webp" ? "image/webp"
            : ext == "heic" ? "image/heic"
            : "image/jpeg"
        sendResponse(connection, status: "200 OK", contentType: contentType, body: data)
    }

    nonisolated private static func sendResponse(_ connection: NWConnection, status: String, contentType: String, body: Data) {
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Access-Control-Allow-Origin: *\r
        Cache-Control: no-cache\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Tiny HTTP parsing helpers

    /// Index just past the `\r\n\r\n` header terminator, or nil if not present.
    nonisolated private static func headerEnd(_ data: Data) -> Int? {
        let sep: [UInt8] = [13, 10, 13, 10]
        guard data.count >= 4 else { return nil }
        return data.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i <= bytes.count - 4 {
                if bytes[i] == sep[0], bytes[i+1] == sep[1], bytes[i+2] == sep[2], bytes[i+3] == sep[3] {
                    return i + 4
                }
                i += 1
            }
            return nil
        }
    }

    /// ("GET", "/path") from a request head ("GET /path?x HTTP/1.1\r\n…").
    nonisolated private static func requestLine(_ head: String) -> (method: String, path: String) {
        guard let line = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: true).first else {
            return ("GET", "/")
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return ("GET", "/") }
        let path = String(parts[1].split(separator: "?").first ?? "/")
        return (String(parts[0]).uppercased(), path)
    }

    /// Case-insensitive header lookup.
    nonisolated private static func headerValue(_ head: String, _ name: String) -> String? {
        let target = name.lowercased()
        for line in head.split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == target {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    nonisolated private static func headerValueInt(_ head: String, _ name: String) -> Int? {
        headerValue(head, name).flatMap { Int($0) }
    }

    /// The full request target incl. query ("/media?p=…").
    nonisolated private static func rawTarget(_ head: String) -> String {
        guard let line = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: true).first else { return "/" }
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : "/"
    }

    /// Value of a query parameter (percent-decoded), or nil.
    nonisolated private static func queryValue(_ target: String, _ key: String) -> String? {
        guard let query = target.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.first.map(String.init) == key else { continue }
            let raw = kv.count > 1 ? String(kv[1]) : ""
            return raw.removingPercentEncoding ?? raw
        }
        return nil
    }
}

/// Finds addresses for reaching this Mac from a phone: the Tailscale IP
/// (works from anywhere on the tailnet) or the LAN IP (same Wi-Fi).
enum NetworkInfo {
    /// One reachable IPv4 address, with a friendly label for the picker.
    struct Interface: Identifiable, Hashable {
        enum Kind: Int { case tailscale = 0, wifi = 1, ethernet = 2, other = 3 }
        let name: String        // BSD name, e.g. "en0", "utun3"
        let ip: String
        let kind: Kind
        var id: String { ip }

        var label: String {
            switch kind {
            case .tailscale: return "Tailscale"
            case .wifi: return "Wi-Fi"
            case .ethernet: return "Ethernet"
            case .other: return "Other"
            }
        }

        /// Reachability hint shown under the URL.
        var reach: String {
            kind == .tailscale ? "reachable from anywhere" : "same network only"
        }
    }

    /// Every up, non-loopback IPv4 address, de-duplicated and ordered
    /// Tailscale → Wi-Fi → Ethernet → other.
    static func allInterfaces() -> [Interface] {
        var seen = Set<String>()
        let all = addresses().compactMap { entry -> Interface? in
            guard seen.insert(entry.ip).inserted else { return nil }
            return Interface(name: entry.name, ip: entry.ip, kind: classify(name: entry.name, ip: entry.ip))
        }
        return all.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    private static func classify(name: String, ip: String) -> Interface.Kind {
        if isTailscale(ip) { return .tailscale }
        if name == "en0" { return .wifi }
        if name.hasPrefix("en") { return .ethernet }
        return .other
    }

    /// All up, non-loopback IPv4 addresses with their interface name.
    private static func addresses() -> [(name: String, ip: String)] {
        var results: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let flags = Int32(interface.ifa_flags)
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.isEmpty { results.append((String(cString: interface.ifa_name), ip)) }
            }
        }
        return results
    }

    /// Tailscale assigns addresses in the CGNAT range 100.64.0.0/10.
    static func isTailscale(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// Tailscale IPv4 if present — reachable from anywhere on your tailnet.
    static func tailscaleIPv4() -> String? {
        addresses().first { isTailscale($0.ip) }?.ip
    }

    /// LAN Wi-Fi / Ethernet IPv4 (same-network only).
    static func lanIPv4() -> String? {
        let en = addresses().filter { $0.name.hasPrefix("en") && !isTailscale($0.ip) }
        return en.first { $0.name == "en0" }?.ip ?? en.first?.ip
    }

    /// Best way to reach this Mac from a phone: Tailscale first (works remotely).
    static func bestIPv4() -> String? {
        tailscaleIPv4() ?? lanIPv4()
    }
}
