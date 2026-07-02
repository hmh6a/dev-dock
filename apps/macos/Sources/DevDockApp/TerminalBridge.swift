import Foundation
import Darwin
import DevDockCore

/// One pseudo-terminal (PTY) running a login shell in a project directory.
/// Output bytes are delivered via ``onData`` on a background queue; input and
/// resize commands come from a connected client (the phone PWA).
final class TerminalSession {
    let id: String
    var onData: ((Data) -> Void)?
    var onExit: (() -> Void)?

    private var process: Process?
    private var masterFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let exitLock = NSLock()
    private var didExit = false

    init(id: String) { self.id = id }

    static var shellPath: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    func start(cwd: String, cols: UInt16, rows: UInt16) {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let namePtr = ptsname(master) else {
            finishExit(); return
        }
        let slave = open(String(cString: namePtr), O_RDWR | O_NOCTTY)
        guard slave >= 0 else { close(master); finishExit(); return }
        masterFD = master

        var win = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, UInt(TIOCSWINSZ), &win)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.shellPath)
        proc.arguments = ["-il"]                       // interactive login shell
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        proc.environment = env

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle
        proc.terminationHandler = { [weak self] _ in self?.finishExit() }

        process = proc
        do {
            try proc.run()
        } catch {
            close(master); close(slave); masterFD = -1; finishExit(); return
        }
        close(slave)                                   // the child holds the slave now

        let src = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global(qos: .userInitiated))
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let n = read(self.masterFD, &buffer, buffer.count)
            if n > 0 { self.onData?(Data(buffer[0..<n])) } else { self.stop() }
        }
        src.setCancelHandler { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            close(self.masterFD); self.masterFD = -1
        }
        source = src
        src.resume()
    }

    func write(_ data: Data) {
        let fd = masterFD
        guard fd >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { _ = Darwin.write(fd, base, raw.count) }
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard masterFD >= 0 else { return }
        var win = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, UInt(TIOCSWINSZ), &win)
    }

    func stop() {
        process?.terminate()
        source?.cancel()                               // cancel handler closes the fd
        source = nil
        finishExit()
    }

    private func finishExit() {
        exitLock.lock(); let already = didExit; didExit = true; exitLock.unlock()
        if !already { onExit?() }
    }
}

/// Owns the live terminal sessions and bridges them to connected clients over the
/// WebSocket. The server is the source of truth for the open shells — their
/// titles, colours, and recent output — so every device sees the same tabs and a
/// reconnecting client catches up. Gated by a user setting.
@MainActor
final class TerminalManager {
    private final class Entry {
        let session: TerminalSession
        var title: String
        var color: String
        let projectId: String?
        var buffer = Data()          // recent output, replayed to a (re)attaching client
        init(session: TerminalSession, title: String, color: String, projectId: String?) {
            self.session = session
            self.title = title
            self.color = color
            self.projectId = projectId
        }
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let maxBuffer = 120_000

    /// Push terminal output/exit to clients.
    var broadcast: ((BridgeMessage) -> Void)?
    /// Fired when the set of shells or their metadata changes (AppState → `termList`).
    var onListChanged: (() -> Void)?

    /// The user must opt in (Settings ▸ Allow terminal). Off by default.
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: "terminal.enabled") }

    /// The open shells as wire metadata, in tab order.
    func list() -> [TerminalWire] {
        order.compactMap { id in
            entries[id].map { TerminalWire(id: id, title: $0.title, color: $0.color, projectId: $0.projectId) }
        }
    }

    /// Ensure a shell exists. New → spawn it. Existing → replay its recent output
    /// so a device that just attached sees the current screen. Either way the
    /// terminal list is refreshed for all clients.
    func open(id: String, projectId: String?, cwd: String, cols: UInt16, rows: UInt16) {
        guard !id.isEmpty else { return }
        guard isEnabled else {
            let notice = "\r\n\u{1b}[31mTerminal is off. Enable it in the dev-dock app: Settings ▸ Allow terminal.\u{1b}[0m\r\n"
            broadcast?(BridgeMessage(type: .termData, termId: id, data: Data(notice.utf8).base64EncodedString()))
            broadcast?(BridgeMessage(type: .termExit, termId: id))
            return
        }

        if let entry = entries[id] {
            entry.session.resize(cols: max(2, cols), rows: max(2, rows))
            // Replay the scrollback so all views converge on the same screen.
            broadcast?(BridgeMessage(type: .termData, termId: id,
                                     data: entry.buffer.base64EncodedString(), reset: true))
            onListChanged?()
            return
        }

        let session = TerminalSession(id: id)
        let entry = Entry(session: session, title: "sh \(order.count + 1)", color: "", projectId: projectId)
        entries[id] = entry
        order.append(id)
        session.onData = { [weak self] data in
            Task { @MainActor in
                guard let self, let entry = self.entries[id] else { return }
                entry.buffer.append(data)
                if entry.buffer.count > self.maxBuffer {
                    entry.buffer.removeFirst(entry.buffer.count - self.maxBuffer)
                }
                self.broadcast?(BridgeMessage(type: .termData, termId: id, data: data.base64EncodedString()))
            }
        }
        session.onExit = { [weak self] in
            Task { @MainActor in
                self?.broadcast?(BridgeMessage(type: .termExit, termId: id))
                self?.entries[id] = nil
                self?.order.removeAll { $0 == id }
                self?.onListChanged?()
            }
        }
        session.start(cwd: cwd, cols: max(2, cols), rows: max(2, rows))
        onListChanged?()
    }

    /// Rename / recolour a shell (persists on the server, shared to all devices).
    func rename(id: String, title: String?, color: String?) {
        guard let entry = entries[id] else { return }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { entry.title = title }
        if let color { entry.color = color }
        onListChanged?()
    }

    func input(id: String, base64: String?) {
        guard let base64, let data = Data(base64Encoded: base64) else { return }
        entries[id]?.session.write(data)
    }

    func resize(id: String, cols: UInt16, rows: UInt16) {
        entries[id]?.session.resize(cols: max(2, cols), rows: max(2, rows))
    }

    func close(id: String) {
        entries[id]?.session.stop()
        entries[id] = nil
        order.removeAll { $0 == id }
        onListChanged?()
    }

    func stopAll() {
        entries.values.forEach { $0.session.stop() }
        entries.removeAll()
        order.removeAll()
    }
}
