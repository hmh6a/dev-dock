import Foundation
import Network
import DevDockCore

/// A localhost WebSocket **server** the `dev-dock-vscode` extension connects to.
/// Broadcasts conversation snapshots to all clients and forwards incoming
/// messages (e.g. a prompt typed in the VS Code panel) back to the app.
@MainActor
final class BridgeServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var clientCount = 0

    /// Called with each decoded message from a client (on the main actor).
    var onMessage: ((BridgeMessage) -> Void)?
    /// Called when a new client finishes connecting (send it a fresh snapshot).
    var onConnect: (() -> Void)?

    private let port: UInt16
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(port: UInt16 = 51888) { self.port = port }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: parameters, on: nwPort) else { return }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.isRunning = true
                case .failed, .cancelled: self?.isRunning = false
                default: break
                }
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        clientCount = 0
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    func broadcast(_ message: BridgeMessage) {
        guard !connections.isEmpty, let data = try? message.jsonData() else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [metadata])
        for connection in connections.values {
            connection.send(content: data, contentContext: context, isComplete: true,
                            completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        clientCount = connections.count

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.onConnect?()
                case .failed, .cancelled:
                    self?.connections[id] = nil
                    self?.clientCount = self?.connections.count ?? 0
                default:
                    break
                }
            }
        }
        receive(on: connection)
        connection.start(queue: .main)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty, let message = try? BridgeMessage.decode(from: data) {
                Task { @MainActor in self?.onMessage?(message) }
            }
            if error == nil {
                Task { @MainActor in self?.receive(on: connection) }
            }
        }
    }
}
